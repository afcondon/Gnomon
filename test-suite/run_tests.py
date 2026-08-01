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

A test passes when JS and Go print byte-identical values. Divergences listed
in KNOWN_DIVERGENCES are reported but don't fail the run; they document
deliberate representation differences inherited from the Julia backend
(UTF-16 code units vs codepoints; int32 wrap vs int64 exactness).

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

# Deliberate divergences (module, test-name), inherited verbatim from the
# Julia backend's ledger (Go is 64-bit-int + UTF-8 exactly as Julia is):
# - ASTRAL-: JS counts UTF-16 code units; Go counts codepoints. BMP-identical.
# - INT64-:  JS wraps every Int op to int32 (`|0`); Go keeps int exactness.
#            The JS values here are the OVERFLOWED ones.
KNOWN_DIVERGENCES = {
    ("Test.Strings", "ASTRAL-cu-length-emoji"),
    ("Test.Strings", "ASTRAL-cu-take-emoji"),
    ("Test.Recursion", "INT64-sumTo-1e6"),
    ("Test.Recursion", "INT64-fact-20"),
    # STACK-: JS captures a stack when an Error is CONSTRUCTED; Go has a stack
    # only while panicking, never on an error value. `Maybe` is the honest type.
    ("Test.Exceptions", "STACK-present-on-construction"),
    # ---- Test.Boundaries -------------------------------------------
    # The boundary tables are a systematic enumeration, so unlike the
    # rest of the corpus they are EXPECTED to turn up divergences: that
    # is what they are for. Each one below has been triaged to a cause,
    # and anything that turned out to be a bug was fixed rather than
    # listed -- nine of them were, including three crashes.
    #
    # INT32: JS wraps every Int operation to int32 (`|0`); these
    # backends run wider arithmetic, so the JS values here are the
    # OVERFLOWED ones. `topInt`/`bottomInt` are `foreign import`s that
    # every backend chooses, and all three copied JS's while running
    # wider arithmetic underneath -- which is the whole of the
    # incoherence, and Gate C9's to settle.
    ("Test.Boundaries", "int-top-plus-1"),
    ("Test.Boundaries", "int-bottom-minus-1"),
    ("Test.Boundaries", "int-negate-bottom"),
    ("Test.Boundaries", "int-abs-bottom"),
    ("Test.Boundaries", "int-negate-bottom-gt-top"),
    ("Test.Boundaries", "int-top-times-2"),
    ("Test.Boundaries", "int-bottom-times-2"),
    ("Test.Boundaries", "int-top-plus-top"),
    ("Test.Boundaries", "int-top-times-top"),
    ("Test.Boundaries", "int-quot-bottom-by-neg1"),
    ("Test.Boundaries", "int-lcm-top-top"),
    # REM0: `Int.rem x 0` is NaN on JS -- a value that is not an Int at
    # all. No backend with a real integer type can reproduce it; all
    # three answer 0.
    ("Test.Boundaries", "int-rem-zero"),
    # NEGZERO: `purs`'s JS backend INLINES `Data.Ring.negate` to unary
    # minus, so `-0.0` there is a genuine negative zero. `negate` is not
    # a class member -- it is `negate a = zero - a` in the Prelude -- so
    # a faithful CoreFn lowering computes `0.0 - 0.0`, which IEEE says
    # is POSITIVE zero. Everything below follows from that one
    # difference, and the sign of a zero is observable through `1/x`,
    # `atan2`, `min`/`max` and `pow`. Not a shim bug: there is no shim
    # to fix. Closing it means matching the inliner in each codegen.
    ("Test.Boundaries", "num-sign-of-negzero"),
    ("Test.Boundaries", "num-sign-of-negzero-plus-negzero"),
    ("Test.Boundaries", "num-sign-of-sqrt-negzero"),
    ("Test.Boundaries", "num-min-zeros"),
    ("Test.Boundaries", "num-pow-negzero-neg1"),
    ("Test.Boundaries", "num-atan2-zero-negzero"),
    # ASTRAL: JS counts UTF-16 code units; these backends count
    # codepoints. Identical for BMP text.
    ("Test.Boundaries", "char-astral-length"),
    ("Test.Boundaries", "char-astral-take-1"),
    ("Test.Boundaries", "char-astral-take-2"),
    # SURROGATE: a Go string is UTF-8 and cannot hold a lone
    # surrogate, so one round-trips as U+FFFD. Structural, not a
    # shim choice.
    ("Test.Boundaries", "char-fromCharCode-high-surrogate"),
    ("Test.Boundaries", "char-fromCharCode-low-surrogate"),
    # NEGZERO, in a real library: `perturbGen` folds float32ToInt32's bit
    # pattern into QuickCheck's seed, and the sign bit of -0.0 is part of that
    # pattern. So the sign of a zero changes WHICH TEST CASES QuickCheck
    # generates. Same single cause as the Test.Boundaries NEGZERO block (#48);
    # this is what it costs downstream.
    ("Test.NullableRandom", "perturb-neg-zero"),
}

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

TEST_LINE = re.compile(r"^TEST ([^:]+): (.*)$")


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


def parse_tests(stdout):
    tests, order = {}, []
    for line in (stdout or "").splitlines():
        m = TEST_LINE.match(line)
        if m:
            tests[m.group(1)] = m.group(2)
            order.append(m.group(1))
    return tests, order


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("filter", nargs="?", default="")
    ap.add_argument("--skip-build", action="store_true")
    args = ap.parse_args()

    if not args.skip_build:
        build()

    modules = [m for m in TEST_MODULES if args.filter.lower() in m.lower()]
    total = passed = known = 0
    failures, errors, gaps = [], [], []

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
        js_tests, js_order = parse_tests(js_out)
        go_tests, _ = parse_tests(go_out)
        mod_pass = mod_fail = 0
        for name in js_order:
            total += 1
            jsv, gov = js_tests.get(name), go_tests.get(name)
            if jsv == gov:
                passed += 1
                mod_pass += 1
            elif (mod, name) in KNOWN_DIVERGENCES:
                known += 1
                print(f"  KNOWN  {mod}/{name}: js={jsv!r} go={gov!r}", file=sys.stderr)
            else:
                mod_fail += 1
                failures.append((mod, name, jsv, gov))
                print(f"  FAIL   {mod}/{name}: js={jsv!r} go={gov!r}", file=sys.stderr)
        missing = set(js_tests) - set(go_tests)
        extra = set(go_tests) - set(js_tests)
        if missing or extra:
            errors.append((mod, f"line mismatch missing={missing} extra={extra}"))
        print(f"{mod}: {mod_pass} pass, {mod_fail} fail", file=sys.stderr)

    print(f"\n{passed}/{total} identical, {known} known divergences, "
          f"{len(gaps)} unsupported, {len(failures)} failures, "
          f"{len(errors)} module errors", file=sys.stderr)
    sys.exit(0 if not failures and not errors else 1)


if __name__ == "__main__":
    main()
