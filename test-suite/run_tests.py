#!/usr/bin/env python3
"""
Cross-backend differential test runner for purescript-go (psgo).

Builds the test modules once with `purs --codegen corefn,js` (via spago),
then for every Test.* module:

  * runs the JS backend  (node, the reference semantics), and
  * runs the Go backend  (psgo emits the module's transitive closure to
    output-go/<Module>/main.go, then `go run`),

and diffs their TEST lines:

    TEST <name>: <value>

A test passes when JS and Go print byte-identical values, or when it is in
divergences.json with exactly the two values recorded there (judged by
ledger.py, the same judge backend-go's lane uses). Ledgered divergences are
reported but don't fail the run; an entry that is no longer true does.

Usage:
    cd test-suite
    python3 run_tests.py                # build + run everything
    python3 run_tests.py --skip-build   # reuse existing output/
    python3 run_tests.py Effects        # only modules matching a substring

Exit code: 0 iff no unexpected divergences and no module-level errors.
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

import ledger

HERE = Path(__file__).resolve().parent
GO_ROOT = HERE.parent                       # purescript-go/
OUTPUT_GO = GO_ROOT / "output-go"

# Every Test.* module under src/, benchmarks excluded (Bench* emit no TEST
# lines). Keep this list complete: six modules sat in src/ unlisted until
# 2026-07-30, so they had never run in the differential harness at all.
# Modules are DISCOVERED from src/Test/, never listed by hand.
#
# A hand-maintained list is the runner-completeness hazard: a module gets
# written, never added to the list, and the suite reports green over source it
# has not compiled. That is exactly how Test.Maps sat unexecuted in the Gnomon
# corpus, and how one module went unlisted here. Discovery makes adding a
# corpus module a one-file operation and makes skipping one impossible by
# accident.
#
# Only deliberate exclusions are named, and each one has to say why.
EXCLUDED_MODULES = {
    # Benchmarks: they measure rather than assert, print no TEST lines, and
    # their runtime would dominate the lane. They belong to the performance
    # lane, not the differential one.
    "Test.BenchFib",
    "Test.BenchFold",
    "Test.BenchLocal",
    "Test.BenchLoop",
}


def discover_test_modules():
    found = sorted(
        f"Test.{p.stem}" for p in (HERE / "src" / "Test").glob("*.purs")
    )
    if not found:
        sys.exit("no Test.*.purs found under src/Test — wrong working directory?")
    return [m for m in found if m not in EXCLUDED_MODULES]


TEST_MODULES = discover_test_modules()

# Deliberate divergences live in divergences.json, with BOTH values and a
# cause, and are judged by ledger.py -- the same judge the optimizer lane uses.
# A name alone used to be enough to pass a ledgered test whatever it printed.
LEDGER = ledger.load("psgo")

# Modules that cannot run yet because a foreign this backend does not supply
# is missing outright — a GAP, not a divergence and not a regression. Kept in
# TEST_MODULES so the gap stays visible on every run rather than being deleted
# and forgotten; reported, but not failed.
#
# Each entry must name the missing module, and each must appear as MISSING in
# the portability index (purescript-julia/bin/portability-index.py). Closing
# the gap means deleting the line here — nothing else.
KNOWN_UNSUPPORTED: dict[str, str] = {
    # Empty: both entries (Data.Show.Generic, Effect.Exception) were closed on
    # 2026-07-30 by authoring the shims in runtime/prelude.go.
}



def sh(cmd, cwd=HERE, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, cwd=cwd, **kw)


def build():
    # Materialize dependency sources (spago build fetches/unpacks; its JS
    # output is unused -- the corefn,js compile below regenerates everything).
    print("• materializing deps (spago build)...", file=sys.stderr)
    r = sh(["spago", "build"])
    if r.returncode != 0:
        sys.stderr.write(r.stdout + r.stderr)
        sys.exit(f"spago build failed ({r.returncode})")
    # spago won't forward --codegen, so resolve source globs via `spago
    # sources` and drive purs directly with both codegen targets.
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


def run_js(module):
    path = f"./output/{module}/index.js"
    if not (HERE / path).exists():
        return None, f"missing {path}"
    r = sh(["node", "--input-type=module", "-e",
            f'import("{path}").then(m => m.main())'], timeout=120)
    if r.returncode != 0:
        return None, f"node exit {r.returncode}: {r.stderr.strip()[:300]}"
    return r.stdout, None


def run_go(module):
    out_dir = OUTPUT_GO / module
    out_dir.mkdir(parents=True, exist_ok=True)
    # psgo: emit this module's transitive closure -> <out_dir>/main.go.
    r = sh(["stack", "run", "psgo", "--",
            str(HERE / "output"), str(out_dir), "--entry", module],
           cwd=GO_ROOT, timeout=300)
    if r.returncode != 0:
        # Strip the stack/ghcup build noise to surface the real psgo failure.
        tail = "\n".join(l for l in (r.stdout + r.stderr).splitlines()
                         if not re.search(r"ghcup|ghc-install|GHC install|"
                                          r"cabal was modified|Cabal file|package.yaml", l))
        return None, f"psgo exit {r.returncode}: {tail.strip()[-400:]}"
    main_go = out_dir / "main.go"
    if not main_go.exists():
        return None, "psgo produced no main.go"
    # go run the emitted files (main.go + the static prelude.go, same package).
    r = sh(["go", "run", "main.go", "prelude.go"], cwd=out_dir, timeout=300)
    if r.returncode != 0:
        return None, f"go exit {r.returncode}: {r.stderr.strip()[:400]}"
    return r.stdout, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("filter", nargs="?", default="")
    ap.add_argument("--skip-build", action="store_true")
    args = ap.parse_args()

    if not args.skip_build:
        build()

    modules = [m for m in TEST_MODULES if args.filter.lower() in m.lower()]
    total = passed = known = 0
    bad, errors, gaps = [], [], []

    for mod in modules:
        if mod in KNOWN_UNSUPPORTED:
            gaps.append((mod, KNOWN_UNSUPPORTED[mod]))
            print(f"{mod}: GAP ({KNOWN_UNSUPPORTED[mod]})", file=sys.stderr)
            continue
        js_out, js_err = run_js(mod)
        go_out, go_err = run_go(mod)
        if js_err or go_err:
            err = js_err or go_err
            errors.append((mod, err))
            print(f"{mod}: ERROR {err}", file=sys.stderr)
            continue
        v = LEDGER.judge(mod, js_out, go_out)
        for line in v.lines("go"):
            print(line, file=sys.stderr)
        total += v.total
        passed += v.identical
        known += len(v.known)
        if not v.ok:
            bad.append(mod)
        print(f"{mod}: {v.identical} identical, {len(v.known)} ledgered, "
              f"{len(v.fail) + len(v.mismatch)} fail"
              + (f", {len(v.stale)} stale" if v.stale else ""), file=sys.stderr)

    # Only a full run can say an entry's module has left the corpus.
    if not args.filter:
        for m, t in LEDGER.unvisited(TEST_MODULES):
            bad.append(m)
            print(f"  STALE     {m}/{t}: module is not in the corpus"
                  f" — remove it from divergences.json", file=sys.stderr)

    print(f"\n{passed}/{total} identical, {known} known divergences "
          f"(values checked), {len(gaps)} unsupported, {len(bad)} modules "
          f"failing, {len(errors)} module errors", file=sys.stderr)
    sys.exit(0 if not bad and not errors else 1)

if __name__ == "__main__":
    main()
