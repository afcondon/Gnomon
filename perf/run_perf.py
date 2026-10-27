#!/usr/bin/env python3
"""
The performance canary.

Builds the shared shape corpus once with `purs --codegen corefn,js`, generates
Go with psgo, runs the SAME harness on both backends, and compares the result
against a recorded baseline.

The question it answers is "has this backend drifted against ITSELF?" — not
"which runtime is faster". Cross-runtime numbers fall out and are printed,
but they are not the claim and must not become the framing: the shapes are
chosen to be attributable, not to be representative of real programs.

WHY THE BASELINE STORES RATIOS, NOT MILLISECONDS
------------------------------------------------
An absolute baseline is worthless the moment it leaves the machine that
recorded it — a laptop on battery, a busy CI runner and an M4 disagree by
more than any interesting regression. So each shape is normalised, within its
own backend and its own run, against a calibration shape (`loop-fore` at
n=1000). Machine speed cancels, and what remains is the shape's cost
*relative to a plain host loop on the same runtime* — which is exactly the
quantity that should not move when the code generator changes.

Two derived numbers are gated:

  rel  steady(shape) / steady(loop-fore@1000)   — cost relative to a host loop
  f/s  first / steady                           — how much of the first call
                                                  is compilation

`f/s` is the type-nesting signal in one number. It is ~1 on a runtime that
does not compile per call site and grows with n exactly where specialisation
is happening.

WHY THERE IS ALSO A SPEED INDEX
-------------------------------
Normalising by the same run's calibration shape cancels machine speed, and it
cancels a code-generator change that moves every shape by the same factor
just as thoroughly: the calibration shape is compiled by the same backend.
Pythia#3 made every closure-heavy shape about 20 % faster and the ratios saw
nothing (REVIEW-2026-10, X3 c). So each backend also gets one number per run
from OUTSIDE itself: the speed index, the geometric mean over the gated shapes
of steady(backend) / steady(js) for the same shape in the same run. The JS
reference is compiled by `purs`, which no change in this repo touches, so a
uniform change here moves the index by its own size. The mean over many
shapes is also far quieter than any one ratio, which is what lets its
tolerance be tight enough to see 20 %.

WHY THE BASELINE IS PER MACHINE
-------------------------------
"Machine-independent" turned out to be false for both numbers: the first run
on GitHub's x86 runners put gated JS ratios at 2.17x and 0.38x of the M4
baseline with nothing changed, and V8 and the other runtimes do not speed up
together across CPUs. So a baseline belongs to the machine that recorded it,
`baselines/<machine>.json`. On a machine with no baseline (every CI runner)
the drift gate does not run, and the output says so in as many words.

Checksums are compared across backends BEFORE any timing is looked at. A
benchmark that computes the wrong answer quickly is the classic way for a
performance suite to stay green while what it measures rots.

Usage:
    cd perf
    python3 run_perf.py                      # build + run + check
    python3 run_perf.py --skip-build
    python3 run_perf.py --backends js        # subset
    python3 run_perf.py --update-baseline    # re-record THIS machine's
                                             # baseline (say why in the commit)
    python3 run_perf.py --json out.json
"""

import argparse
import json
import math
import os
import platform
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

HERE = Path(__file__).resolve().parent
BASELINES = HERE / "baselines"

SCHEMA = "1"
BASELINE_SCHEMA = "2"

# The calibration shape. Everything is expressed relative to this, per
# backend, per run. `loop-fore` is the right choice because it is the
# cheapest thing that still touches the whole representation — a host loop, a
# closure call and a Ref write per iteration — so it tracks general runtime
# speed without tracking any one shape's pathology.
#
# The SIZE matters as much as the shape, and n=1000 was the wrong one. At five
# reps that is six thousand iterations, which is not enough work for a tiering
# JIT to finish tiering: JS steady at n=1000 was measured at 114, 135, 167,
# 188 and 196 us on the same machine on the same day. A calibration that moves
# by 1.7x moves every ratio derived from it by 1.7x, so the noise floor of the
# whole lane was set by its own denominator. n=10000 is ten times the work and
# lands past the warm-up on every runtime measured. The tell that this was
# real: loop-fore@10000 read rel 10.4 on Jurist (linear in n, as a host loop
# should be) but 6.3 on JS — not because the JS loop is sublinear, but because
# its denominator was too slow.
CALIBRATION = ("loop-fore", 10000)

# How far a ratio may move before it is reported. This now has a measurement
# behind it rather than a guess: six back-to-back runs of all three backends
# on an idle M4 MBP, 2026-08-01. Over the GATED population (see below) the
# worst run-to-run spread was 1.69x, the 90th percentile 1.21x and the median
# 1.10x — so 2.0 leaves 1.18x of headroom over the worst thing noise did in
# six tries, and still catches any regression of 2x or more.
#
# The number did not need to change; the population did. Over ALL measured
# rows the worst spread was 5.74x, so a 2.0 gate applied to everything would
# have fired on noise more or less every run. That is the whole finding.
#
# Tighten toward the 90th percentile once a few weeks of CI runs say what the
# tail really looks like — six samples underestimate it.
TOLERANCE = 2.0

# How far a backend's speed index (see the header) may move, as a factor
# either way, before the gate fires. perf/README.md has the runs behind it:
# ten back-to-back runs (median of 3 rounds each) on the loaded Mac Mini M4,
# Go lanes at GOMAXPROCS=1, put the worst index spread at 1.033x for psgo and
# 1.074x for backend-go, so 1.10 sits above the noise and well inside the
# ~20 % uniform change that Pythia#3 made and the old ratios could not see.
# The same value as Pythia's and Jurist's, on purpose.
INDEX_TOLERANCE = 1.10

# Two filters decide whether a row is GATED (counts toward failure) or merely
# reported. Both express the same idea: a measurement has to carry information
# before it is allowed to fail a build.
#
#   1. Only the largest n of each shape. The smaller sizes are there to show
#      the CURVE — superlinearity, and f/s growing with n, which is the
#      type-nesting signal. A curve point is a diagnostic, not a threshold.
#   2. Only shapes whose steady time clears this floor. Below it, scheduler
#      noise and timer resolution dominate: `ffi-array@1600` on the JS
#      reference is ~20 us and swings 1.5x between runs while doing exactly
#      the same work.
#
# The floor is absolute because the things it guards against are absolute. It
# is therefore a property of the machine that RECORDED the baseline, and the
# decision travels with the baseline rather than being recomputed per run —
# otherwise a shape sitting near the line would gate on one run and not the
# next. On a slower machine this excludes rows that would have been
# measurable there, which loses a little coverage and never invents an alarm.
GATE_MIN_STEADY_US = 50.0

def machine_id():
    """Who recorded a baseline: host name and CPU. A CI runner's host name is
    fresh every run, so CI never finds a baseline, and says so."""
    host = platform.node().split(".")[0].lower() or "unknown-host"
    cpu = platform.processor() or platform.machine()
    try:
        if sys.platform == "darwin":
            # Every Mac's node name can be plain "Mac"; the Bonjour name is
            # the one that tells two of them apart.
            host = subprocess.run(["scutil", "--get", "LocalHostName"],
                                  capture_output=True, text=True).stdout.strip() or host
            cpu = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"],
                                 capture_output=True, text=True).stdout.strip() or cpu
        elif Path("/proc/cpuinfo").exists():
            for line in Path("/proc/cpuinfo").read_text().splitlines():
                if line.startswith("model name"):
                    cpu = line.split(":", 1)[1].strip()
                    break
    except OSError:
        pass
    return re.sub(r"[^a-z0-9]+", "-", f"{host} {cpu}".lower()).strip("-")


def baseline_path():
    return BASELINES / f"{machine_id()}.json"


def not_run(title, msg):
    """A line in the log and, on GitHub Actions, a warning annotation on the
    run, so that a gate or lane that did not run cannot be read as one that
    passed."""
    print(f"NOT RUN — {title}: {msg}")
    if os.environ.get("GITHUB_ACTIONS") == "true":
        print(f"::warning title={title} NOT RUN::{msg}")


BENCH_RE = re.compile(
    r"^BENCH (\S+) (\d+) ([-\d.eE+]+) ([-\d.eE+]+) (-?\d+)\s*$"
)
SCHEMA_RE = re.compile(r"^BENCH-SCHEMA (\S+)\s*$")


def sh(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, cwd=HERE, **kw)


# ------------------------------------------------------------------ build --

def build():
    print("• materializing deps (spago build)...", file=sys.stderr)
    r = sh(["spago", "build"])
    if r.returncode != 0:
        sys.stderr.write(r.stdout + r.stderr)
        sys.exit(f"spago build failed ({r.returncode})")

    print("• resolving sources (spago)...", file=sys.stderr)
    r = sh(["spago", "sources"])
    if r.returncode != 0:
        sys.stderr.write(r.stdout + r.stderr)
        sys.exit(f"spago sources failed ({r.returncode})")
    globs = r.stdout.split()

    print("• purs compile --codegen corefn,js...", file=sys.stderr)
    r = sh(["purs", "compile", "--codegen", "corefn,js"] + globs)
    if r.returncode != 0:
        sys.stderr.write(r.stdout + r.stderr)
        sys.exit(f"purs compile failed ({r.returncode})")

    # psgo MUST run with cwd = this directory. It locates a user foreign the
    # way purs locates a `.js` — `<dir>/<Module>.go` next to the source, from
    # the CoreFn modulePath, which is relative to wherever purs ran. Invoked
    # from the repo root it silently looks for `src/Bench/Clock.go` THERE,
    # warns that no co-located file exists, and emits a main.go that will not
    # compile. The failure is a Go "undefined:" error several steps later.
    print("• psgo output -> output-go/Bench.Main...", file=sys.stderr)
    GO_OUT.mkdir(parents=True, exist_ok=True)
    r = sh(["stack", "--stack-yaml", "../stack.yaml", "run", "psgo", "--",
            "output", str(GO_OUT.relative_to(HERE)), "--entry", "Bench.Main"])
    if r.returncode != 0:
        noise = ("ghcup", "GHC install", "Cabal file", "package.yaml",
                 "cabal was modified")
        tail = "\n".join(l for l in (r.stdout + r.stderr).splitlines()
                         if not any(k in l for k in noise))
        sys.stderr.write(tail[-2000:])
        sys.exit(f"psgo failed ({r.returncode})")
    if not (GO_OUT / "main.go").exists():
        sys.exit("psgo produced no main.go")
    if not (GO_OUT / "Clock_foreign.go").exists():
        sys.exit("psgo did not copy the co-located Bench.Clock foreign — "
                 "run_perf.py must run with cwd = perf/")


# -------------------------------------------------------------------- run --

JS_PATH = "./output/Bench.Main/index.js"

GO_OUT = HERE / "output-go" / "Bench.Main"

# `go run` compiles before it runs, but that happens at process level, outside
# the harness's clock — so unlike Julia's per-call-site compilation it does not
# show up in first-call timings, and f/s stays meaningful.
COMMANDS = {
    "js": ["node", "--input-type=module", "-e",
           f'import("{JS_PATH}").then(m => m.main())'],
    "go": (["go", "run", "main.go", "prelude.go", "Clock_foreign.go"], GO_OUT),
}

# The optimizer lane runs the same corpus through backend-go
# (purescript-backend-optimizer's IR) with its own runtime.go. It owns the TCO
# and unboxing work, and until this lane joined the canary nothing guarded its
# performance at all (REVIEW-2026-10, G8 and X3 d). Its command needs a staged
# directory, so main() fills it in.
COMMANDS["backend-go"] = None

RUNNERS = list(COMMANDS)

# Both Go lanes run on ONE P. The corpus is single-threaded, and on the M4 a
# Go process with the default GOMAXPROCS lands, per process and at random, in
# a fast or a slow mode for its first shapes: psgo's loop-null@10000 measured
# ~187 us or ~440 us in 9 of 20 fresh processes, and backend-go's calibration
# shape loop-fore@10000 ~400 us or ~910 us, which moved every backend-go ratio
# by 2.2x at once. With GOMAXPROCS=1 the slow mode showed in 1 of 20 and 0 of
# 30 processes (2026-10-27, perf/README.md). It costs psgo ~15 % on
# allocation-heavy shapes (no parallel GC), which is fine for a canary that
# compares the backend with itself, and it is the same setting every run.
GO_ENV = {**os.environ, "GOMAXPROCS": "1"}
ENV = {"go": GO_ENV, "backend-go": GO_ENV}

OPTIMIZER = HERE.parent.parent / "purescript-backend-optimizer"
BACKEND_GO = HERE.parent / "backend-go"


def stage_backend_go():
    """Emit Bench.Main through backend-go into a scratch directory and build
    it, as backend-go/run_conformance.sh does. -> (command, None) or (None,
    why). Building here keeps `go build` outside the timed process."""
    if not OPTIMIZER.is_dir():
        return None, (f"../{OPTIMIZER.name} is not checked out beside this "
                      "repo, so the optimizer lane has no compiler")
    out = Path(tempfile.mkdtemp(prefix="perf-backend-go-"))
    # spago can rewrite the dependency ranges in spago.yaml on a build
    # (review X7); put the tracked file back so a perf run leaves the tree as
    # it found it.
    config = (BACKEND_GO / "spago.yaml").read_bytes()
    try:
        builds = run_emit(out)
    finally:
        (BACKEND_GO / "spago.yaml").write_bytes(config)
    for cmd, r in builds:
        if r.returncode != 0:
            sys.stderr.write(r.stdout[-2000:] + r.stderr[-2000:])
            sys.exit(f"backend-go: {' '.join(cmd[:2])} failed ({r.returncode})")
    shutil.copy(BACKEND_GO / "runtime.go", out / "runtime.go")
    # backend-go looks for a co-located foreign relative to ITS cwd, where
    # perf/'s CoreFn modulePaths do not resolve, so the corpus's one foreign
    # is supplied here, from the same file psgo copies.
    shutil.copy(HERE / "src" / "Bench" / "Clock.go", out / "Bench_Clock_foreign.go")
    r = subprocess.run("go build -o bench *.go", shell=True, cwd=out,
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stderr[-2000:])
        sys.exit("backend-go: go build failed")
    return ([str(out / "bench")], out), None


def run_emit(out):
    results = []
    for cmd in (["spago", "build"],
                ["spago", "run", "--", "--corefn-dir", str(HERE / "output"),
                 "--output-dir", str(out), "--main", "Bench.Main"]):
        r = subprocess.run(cmd, cwd=BACKEND_GO, capture_output=True, text=True)
        results.append((cmd, r))
        if r.returncode != 0:
            break
    return results

# Per-backend wall clock. A shape CAN exceed any sensible timeout — fold-list
# at n=1600 did not finish in ten minutes on Jurist — so the timeout is a
# normal outcome here rather than an error, and the corpus flushes per line
# precisely so that everything measured before the cut survives it.
TIMEOUT = 600


def run_backend(name, echo=False):
    """Stream the corpus, returning (lines, timed_out).

    Streaming rather than capturing, because a lane that dies on a timeout
    with nothing on stdout tells you only that it died. With per-line flushes
    on the corpus side, a timeout still yields every shape that completed —
    and WHICH shape it died on, which is the more useful half.
    """
    cmd, cwd = COMMANDS[name] if isinstance(COMMANDS[name], tuple) \
        else (COMMANDS[name], HERE)
    proc = subprocess.Popen(
        cmd, cwd=cwd, text=True, env=ENV.get(name),
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    lines = []

    # The read has to happen off the main thread. Iterating proc.stdout here
    # would block inside the shape that hangs, and the timeout would never be
    # reached — which is the failure mode this whole function exists to avoid.
    def pump():
        for line in proc.stdout:
            lines.append(line.rstrip("\n"))
            if echo:
                print(f"    {lines[-1]}", file=sys.stderr)

    reader = threading.Thread(target=pump, daemon=True)
    reader.start()

    timed_out = False
    try:
        proc.wait(timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        timed_out = True
        proc.kill()
        proc.wait()
    reader.join(timeout=10)

    stderr = proc.stderr.read() if proc.stderr else ""
    if not timed_out and proc.returncode != 0:
        sys.stderr.write(stderr[-2000:])
        sys.exit(f"{name} exited {proc.returncode}")
    return lines, timed_out


def parse(lines, who, timed_out):
    """-> {(shape, n): {"first": us, "steady": us, "checksum": int}}"""
    seen_schema = None
    rows = {}
    for line in lines:
        m = SCHEMA_RE.match(line)
        if m:
            seen_schema = m.group(1)
            continue
        m = BENCH_RE.match(line)
        if m:
            shape, n, first, steady, checksum = m.groups()
            rows[(shape, int(n))] = {
                "first": float(first),
                "steady": float(steady),
                "checksum": int(checksum),
            }
    if seen_schema is None:
        sys.exit(f"{who}: no BENCH-SCHEMA line — the corpus did not run")
    if seen_schema != SCHEMA:
        sys.exit(f"{who}: corpus schema {seen_schema}, runner expects {SCHEMA}")
    if not rows:
        sys.exit(f"{who}: schema line but no BENCH lines")
    if timed_out:
        print(f"  {who}: TIMED OUT after {TIMEOUT}s — "
              f"{len(rows)} measurements completed, the rest are DNF",
              file=sys.stderr)
    return rows


def median_rows(rounds, who):
    """Per shape, the median steady and first time over the rounds. A shape
    that is DNF in any round is DNF. A checksum that differs between rounds
    of the same backend is a nondeterministic benchmark, which is a failure."""
    keys = set(rounds[0]).intersection(*rounds[1:])
    out = {}
    for key in keys:
        sums = {r[key]["checksum"] for r in rounds}
        if len(sums) > 1:
            sys.exit(f"{who}: {key[0]}@{key[1]} checksum differs between "
                     f"rounds: {sorted(sums)}")
        out[key] = {
            "first": statistics.median(r[key]["first"] for r in rounds),
            "steady": statistics.median(r[key]["steady"] for r in rounds),
            "checksum": sums.pop(),
        }
    return out


def derive(rows, who):
    """Add machine-independent ratios. Returns (derived, calibration_us)."""
    cal = rows.get(CALIBRATION)
    if cal is None:
        sys.exit(f"{who}: calibration shape {CALIBRATION} missing")
    base = cal["steady"]
    if base <= 0.0:
        sys.exit(f"{who}: calibration shape measured as {base} us — "
                 "clock resolution too coarse to normalise against")
    largest = {}
    for shape, n in rows:
        largest[shape] = max(largest.get(shape, 0), n)
    out = {}
    for key, v in rows.items():
        steady = v["steady"]
        shape, n = key
        out[key] = {
            **v,
            "rel": steady / base,
            # A steady time at or below clock resolution makes f/s
            # meaningless rather than large; report it as absent.
            "fs": (v["first"] / steady) if steady > 0.0 else None,
            "gated": n == largest[shape] and steady >= GATE_MIN_STEADY_US,
        }
    return out, base


def speed_index(results, rows_for):
    """-> {backend: (index, [row names])}. See the header: the geometric mean
    over gated shapes of steady(backend)/steady(js), same shape, same run.
    `rows_for(backend)` names the shapes, so a check uses exactly the
    baseline's set, and a shape that did not finish is reported rather than
    silently shifting the mean."""
    js = results.get("js")
    out = {}
    if js is None:
        return out
    for b, rows in results.items():
        if b == "js":
            continue
        logs, used = [], []
        for name in rows_for(b):
            shape, n = name.rsplit("@", 1)
            key = (shape, int(n))
            if key in rows and key in js and js[key]["steady"] > 0:
                logs.append(math.log(rows[key]["steady"] / js[key]["steady"]))
                used.append(name)
        if logs:
            out[b] = (math.exp(sum(logs) / len(logs)), used)
    return out


def gated_names(rows):
    return sorted(f"{k[0]}@{k[1]}" for k, v in rows.items() if v["gated"])


# ------------------------------------------------------------------ check --

def check_checksums(results):
    """Cross-backend equivalence. A real gate, and it runs first.

    Returns (divergences, unmeasured). Only the first is a failure: a shape
    that did not complete on one backend is a fact about that backend, and it
    is reported as DNF in the table rather than as a wrong answer.
    """
    divergences, unmeasured = [], []
    keys = set()
    for rows in results.values():
        keys |= set(rows)
    for key in sorted(keys):
        vals = {b: rows[key]["checksum"]
                for b, rows in results.items() if key in rows}
        missing = [b for b in results if key not in results[b]]
        if missing:
            unmeasured.append(
                f"{key[0]}@{key[1]}: DNF on {', '.join(sorted(missing))}")
        if len(set(vals.values())) > 1:
            detail = ", ".join(f"{b}={v}" for b, v in sorted(vals.items()))
            divergences.append(f"{key[0]}@{key[1]}: checksums differ — {detail}")
    return divergences, unmeasured


def check_index(results, baseline, rounds):
    """Each backend's speed index against the baseline's. -> (lines, hard)

    Each round's own index is printed too. Their spread is this run's noise,
    measured rather than assumed: when it is wider than the tolerance, the
    verdict is labelled NOISY, because on that run the gate cannot tell a
    change of that size from the machine's load."""
    lines, hard = [], 0
    recorded = baseline.get("index", {})
    rows_for = lambda b: recorded.get(b, {}).get("rows", [])
    now = speed_index(results, rows_for)
    per_round = [speed_index(r, rows_for) for r in rounds]
    for b in sorted(results):
        if b == "js":
            continue
        was = recorded.get(b)
        if was is None:
            lines.append(f"  {b}: no speed index in this machine's baseline")
            hard += 1
            continue
        if b not in now:
            lines.append(f"  {b}: none of the index shapes were measured")
            hard += 1
            continue
        idx, used = now[b]
        missing = sorted(set(was["rows"]) - set(used))
        factor = idx / was["index"]
        moved = factor > INDEX_TOLERANCE or factor < 1.0 / INDEX_TOLERANCE
        hard += bool(moved or missing)
        each = [r[b][0] for r in per_round if b in r]
        spread = max(each) / min(each) if each else 1.0
        noisy = spread > INDEX_TOLERANCE
        lines.append(f"  {b}: speed index {was['index']:.3f} -> {idx:.3f} x js "
                     f"[{factor:.3f}x, tolerance {INDEX_TOLERANCE}x] "
                     f"{'MOVED' if moved else 'ok'}"
                     + (f"; DNF on {', '.join(missing)}" if missing else ""))
        lines.append(f"      rounds: {', '.join(f'{x:.3f}' for x in each)} "
                     f"(spread {spread:.3f}x)"
                     + ("  NOISY: wider than the tolerance, so this run "
                        "cannot vouch for the verdict; re-run on a quieter "
                        "machine" if noisy else ""))
    return lines, hard


def check_baseline(results, baseline):
    """Drift against the recorded ratios.

    Returns (drifts, n_gated). Each drift carries whether it is gated, and
    gatedness comes from the BASELINE, not from this run — see the comment on
    GATE_MIN_STEADY_US for why the decision has to be the fixed one.
    """
    drifts, n_gated = [], 0
    for backend, rows in results.items():
        recorded = baseline.get("backends", {}).get(backend)
        if recorded is None:
            drifts.append((backend, None, None,
                           "no baseline recorded for this backend", True))
            continue
        for key in sorted(rows):
            name = f"{key[0]}@{key[1]}"
            was = recorded.get(name)
            if was is None:
                # A shape the baseline has never seen cannot be checked, but
                # its absence is a real change to the corpus, so it gates.
                drifts.append((backend, name, None,
                               "new shape, not in baseline", True))
                continue
            gated = bool(was.get("gated"))
            n_gated += gated
            now = rows[key]["rel"]
            old = was["rel"]
            if old <= 0:
                continue
            factor = now / old
            if factor > TOLERANCE or factor < 1.0 / TOLERANCE:
                drifts.append((backend, name, factor,
                               f"rel {fmt_rel(old)} -> {fmt_rel(now)}", gated))
    return drifts, n_gated


# ----------------------------------------------------------------- report --

def report(results, calibrations):
    backends = sorted(results)
    keys = sorted({k for rows in results.values() for k in rows},
                  key=lambda k: (k[0], k[1]))

    print()
    for b in backends:
        print(f"calibration  {b}: {CALIBRATION[0]}@{CALIBRATION[1]} "
              f"= {calibrations[b]:.2f} us steady")
    for b, (idx, used) in sorted(speed_index(
            results, lambda b: gated_names(results[b])).items()):
        print(f"speed index  {b}: {idx:.3f} x js (geomean over {len(used)} "
              f"gated shapes, this run)")
    print()

    head = f"{'shape':<16}{'n':>7}"
    for b in backends:
        head += f"  |{b + ' steady us':>14}{'rel':>9}{'f/s':>10}"
    print(head)
    print("-" * len(head))

    last_shape = None
    for key in keys:
        shape, n = key
        if last_shape is not None and shape != last_shape:
            print()
        last_shape = shape
        row = f"{shape:<16}{n:>7}"
        for b in backends:
            v = results[b].get(key)
            if v is None:
                # DNF is a result. Blanking it would read as "not run".
                row += f"  |{'DNF':>14}{'—':>9}{'—':>10}"
            else:
                row += (f"  |{v['steady']:>14.2f}"
                        f"{fmt_rel(v['rel']):>9}{fmt_fs(v['fs']):>10}")
        print(row)


def fmt_rel(x):
    # Sub-0.01 shapes are the cheap ones, and rounding them all to "0.00"
    # throws away the only thing that distinguishes them. Since the
    # calibration moved to n=10000 every ratio is ten times smaller, so the
    # cheap end needs a fourth place to stay legible.
    if x < 0.001:
        return f"{x:.4f}"
    return f"{x:.3f}" if x < 0.01 else f"{x:.2f}"


def fmt_fs(x):
    if x is None:
        return "—"
    # Three-digit-plus ratios are the compilation signal; a decimal place on
    # 18651.8 is noise, and it is what overflowed the column.
    return f"{x:.0f}x" if x >= 100 else f"{x:.1f}x"


# A shape whose steady time moves by more than this between ROUNDS of one run
# (on the backend or on JS) is left out of the speed index when a baseline is
# recorded. psgo's loop-null@10000 is the case that forced it: per process it
# runs at ~187 us or ~440 us, about half the time each (it is the corpus's
# first shape, so it likely catches the process before it settles). A 2.4x
# coin flip in one of eleven shapes moves the index by 2.4^(1/11) = 1.08 on
# its own, and no median over three rounds fixes a 50/50 split. The shape is
# still measured, printed and ratio-gated; it just cannot vote in the index.
# Recording at a higher --repeat makes a bimodal shape likelier to show both
# modes while recording; the baseline here was recorded at the default.
UNSTABLE_ROUND_SPREAD = 1.5


def round_spread(rounds, backend, name):
    shape, n = name.rsplit("@", 1)
    key = (shape, int(n))
    vals = [r[backend][key]["steady"] for r in rounds
            if key in r.get(backend, {}) and r[backend][key]["steady"] > 0]
    return max(vals) / min(vals) if len(vals) > 1 else 1.0


def index_rows(results, rounds):
    """-> (rows_for, unstable): the gated shapes that may vote in each
    backend's index, and the ones excluded for round-to-round instability."""
    unstable = {}
    for b in results:
        if b == "js":
            continue
        for name in gated_names(results[b]):
            spread = max(round_spread(rounds, b, name),
                         round_spread(rounds, "js", name))
            if spread > UNSTABLE_ROUND_SPREAD:
                unstable.setdefault(b, {})[name] = round(spread, 2)
    return (lambda b: [n for n in gated_names(results[b])
                       if n not in unstable.get(b, {})]), unstable


def to_baseline(results, rounds=()):
    rows_for, unstable = index_rows(results, rounds)
    return {
        "schema": BASELINE_SCHEMA,
        "machine": machine_id(),
        "calibration": {"shape": CALIBRATION[0], "n": CALIBRATION[1]},
        "tolerance": TOLERANCE,
        "index_tolerance": INDEX_TOLERANCE,
        "gate_min_steady_us": GATE_MIN_STEADY_US,
        "note": ("Ratios, not milliseconds — see the header of run_perf.py. "
                 "`rel` is steady/steady(calibration) within the same backend "
                 "and run; `fs` is first/steady; `index` is the geometric mean "
                 "of steady(backend)/steady(js) over `rows`, same run. None of "
                 "them transfers between machines, so this file speaks only "
                 "for the machine named in `machine`."),
        "index": {
            b: {"index": round(idx, 6), "rows": used,
                "unstable": unstable.get(b, {})}
            for b, (idx, used) in sorted(speed_index(results, rows_for).items())
        },
        "backends": {
            b: {
                f"{k[0]}@{k[1]}": {
                    "rel": round(v["rel"], 6),
                    "fs": None if v["fs"] is None else round(v["fs"], 2),
                    "checksum": v["checksum"],
                    "gated": v["gated"],
                }
                for k, v in sorted(rows.items())
            }
            for b, rows in sorted(results.items())
        },
    }


# ------------------------------------------------------------------- main --

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--skip-build", action="store_true")
    ap.add_argument("--backends", default="js,go,backend-go",
                    help="comma-separated subset of: " + ",".join(RUNNERS))
    ap.add_argument("--echo", action="store_true",
                    help="stream BENCH lines as they arrive (a long shape "
                         "looks like a hang otherwise)")
    ap.add_argument("--repeat", type=int, default=3, metavar="N",
                    help="run every backend N times, interleaved, and use the "
                         "median per shape (default 3; the speed index's "
                         "tolerance was set at 3)")
    ap.add_argument("--update-baseline", action="store_true")
    ap.add_argument("--json", metavar="PATH",
                    help="write the full measurement to PATH")
    ap.add_argument("--gate-drift", action="store_true",
                    help="exit non-zero on baseline drift as well as on "
                         "checksum divergence (off until the lane has a "
                         "variance history)")
    args = ap.parse_args()

    wanted = [b.strip() for b in args.backends.split(",") if b.strip()]
    unknown = [b for b in wanted if b not in RUNNERS]
    if unknown:
        sys.exit(f"unknown backend(s): {', '.join(unknown)}")

    if not args.skip_build:
        build()

    if "backend-go" in wanted:
        COMMANDS["backend-go"], why = stage_backend_go()
        if why:
            not_run("Perf canary, backend-go lane", why)
            wanted.remove("backend-go")

    # Rounds are INTERLEAVED (js, go, backend-go, js, go, ...) rather than
    # one backend at a time, so that a change in machine load during the run
    # lands on the numerator and the denominator of the speed index alike.
    measured = {b: [] for b in wanted}
    for i in range(args.repeat):
        for b in wanted:
            print(f"• running {b}, round {i + 1}/{args.repeat} "
                  f"(up to {TIMEOUT}s)...", file=sys.stderr)
            lines, timed_out = run_backend(b, echo=args.echo)
            measured[b].append(parse(lines, b, timed_out))
    results, calibrations = {}, {}
    for b in wanted:
        results[b], calibrations[b] = derive(median_rows(measured[b], b), b)
    rounds = [{b: derive(measured[b][i], b)[0] for b in wanted}
              for i in range(args.repeat)]

    report(results, calibrations)

    failures = 0

    divergences, unmeasured = check_checksums(results)
    print()
    if divergences:
        print("CHECKSUMS — DIVERGENT")
        for p in divergences:
            print(f"  {p}")
        failures += 1
    elif len(results) > 1:
        print("checksums: identical across " + ", ".join(sorted(results)))
    else:
        print("checksums: single backend, nothing to cross-check")
    for p in unmeasured:
        print(f"  DNF  {p}")

    if args.update_baseline:
        path = baseline_path()
        BASELINES.mkdir(exist_ok=True)
        path.write_text(json.dumps(to_baseline(results, rounds), indent=2) + "\n")
        print(f"baseline: rewritten (baselines/{path.name}) — "
              "say why in the commit message")
    elif not baseline_path().exists():
        recorded = sorted(p.stem for p in BASELINES.glob("*.json"))
        not_run("Perf drift gate",
                f"no baseline recorded on this machine ({machine_id()}); "
                f"baselines exist for: {', '.join(recorded) or 'none'}. "
                "Drift is not checked here; checksums still gate.")
    else:
        baseline = json.loads(baseline_path().read_text())
        if baseline.get("schema") != BASELINE_SCHEMA:
            not_run("Perf drift gate",
                    f"baselines/{baseline_path().name} has schema "
                    f"{baseline.get('schema')}, expected {BASELINE_SCHEMA}; "
                    "re-record it with --update-baseline")
        else:
            print(f"baseline: baselines/{baseline_path().name}")
            index_lines, index_hard = check_index(results, baseline, rounds)
            print(f"SPEED INDEX (tolerance {INDEX_TOLERANCE}x either way)")
            for line in index_lines:
                print(line)
            drifts, n_gated = check_baseline(results, baseline)
            hard = [d for d in drifts if d[4]]
            if drifts:
                print(f"DRIFT (tolerance {TOLERANCE}x, {n_gated} gated rows)")
                for backend, name, factor, why, gated in drifts:
                    f = "" if factor is None else f"  [{factor:.2f}x]"
                    tail = ("" if gated
                            else "  (report only — see GATE_MIN_STEADY_US)")
                    print(f"  {backend}  {name or ''}: {why}{f}{tail}")
            else:
                print(f"ratios: no shape moved more than {TOLERANCE}x "
                      f"({n_gated} gated rows)")
            if (hard or index_hard) and args.gate_drift:
                failures += 1

    if args.json:
        Path(args.json).write_text(json.dumps(
            {"schema": SCHEMA,
             "calibration_us": calibrations,
             "backends": {b: {f"{k[0]}@{k[1]}": v for k, v in rows.items()}
                          for b, rows in results.items()}},
            indent=2) + "\n")
        print(f"wrote {args.json}")

    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
