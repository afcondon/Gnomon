#!/bin/zsh
# backend-go conformance: build the PS backend, emit Go for the whole corpus
# (one corefn dir), then for each corpus module swap the entrypoint, `go build`
# the whole package, run it, and diff against the JS reference. A module is
# "green" if byte-identical, or differs ONLY on the seeded
# INT64/ASTRAL/STACK/NEGZERO ledger
# (Go int has no int32 wrap; Go strings count codepoints not UTF-16 units).
#
# Usage: ./run_conformance.sh
set -e
HERE=${0:A:h}
JSREF="$HERE/../test-suite"
# Scratch paths are PER RUN, not fixed. All three optimizer lanes previously
# wrote /tmp/js_out.txt, so running two of them at once silently crossed their
# reference output and produced diffs full of another module's tests — three
# invented failures that looked exactly like real regressions. A gate whose
# result depends on what else is running is not a gate.
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
OUT=/tmp/bgo-conf
# Corpus modules are DISCOVERED, never listed by hand -- a hand-maintained list
# is how Test.Maps sat unexecuted in this repo for weeks. Benchmarks are the
# only exclusion: they measure rather than assert and print no TEST lines.
mods=(${(f)"$(cd "$JSREF/src/Test" && ls *.purs | sed 's/\.purs$//' | grep -v '^Bench')"})

echo "==> building backend-go"
(cd "$HERE" && spago build >/dev/null 2>&1)

# Per-entry pruning means each program is emitted for its OWN main: emitting
# --main Test.X prunes away every binding unreachable from Test.X.main (and
# writes its own entrypoint.go), so we emit once per module into a clean dir.
# The seeded divergence ledger, as name markers. See the per-line check
# below for why markers rather than a list of (module, test) pairs.
LEDGER_MARKERS="INT64|ASTRAL|STACK|NEGZERO"
pass=0; ledger=0; bad=0
for m in $mods; do
  mod="Test.$m"
  rm -rf "$OUT"
  # The emit step and the JS reference step are guarded rather than bare. Both
  # used to run under `set -e` with their output silenced, so a failure in
  # either killed the whole lane mid-loop having printed NOTHING about it — the
  # log simply stopped after the previous module's OK line. That is a gate that
  # can fail invisibly, which is the same fault as a gate that passes
  # invisibly. Report it against the module, count it bad, keep going.
  if ! (cd "$HERE" && spago run -- --corefn-dir "$JSREF/output" --output-dir "$OUT" --main "$mod" >/dev/null 2>"$TMPD/emit_err.txt"); then
    echo "[$mod] EMIT-ERR: $(grep -v '^$' "$TMPD/emit_err.txt" | tail -1 | head -c 160)"; bad=$((bad+1)); continue
  fi
  cp "$HERE/runtime.go" "$OUT/runtime.go"
  if ! (cd "$OUT" && go build -o "$TMPD/bgo_bin" *.go 2>"$TMPD/be.txt"); then echo "[$mod] BUILD-ERR: $(head -3 "$TMPD/be.txt" | tail -1)"; bad=$((bad+1)); continue; fi
  if ! "$TMPD/bgo_bin" > "$TMPD/go_out.txt" 2>"$TMPD/go_err.txt"; then echo "[$mod] RUN-ERR: $(grep -m1 panic "$TMPD/go_err.txt")"; bad=$((bad+1)); continue; fi
  if ! node --input-type=module -e "import(\"$JSREF/output/$mod/index.js\").then(x => x.main())" > "$TMPD/js_out.txt" 2>"$TMPD/js_err.txt"; then
    echo "[$mod] JSREF-ERR: $(grep -v '^$' "$TMPD/js_err.txt" | tail -1 | head -c 160)"; bad=$((bad+1)); continue
  fi
  nfiles=$(ls "$OUT"/*.go | wc -l | tr -d ' ')
  if diff -q "$TMPD/js_out.txt" "$TMPD/go_out.txt" >/dev/null; then
    echo "[$mod] OK identical ($(wc -l <"$TMPD/go_out.txt"|tr -d ' ') lines, $nfiles files)"; pass=$((pass+1))
  # STACK belongs here too: both lanes' Effect.Exception.stackImpl returns
  # Nothing (neither Go representation carries a stack), and the ORACLE lane
  # has always ledgered it — this script's narrower pattern was the only reason
  # Test.Exceptions read as a failure. Keep the two ledgers in step.
  else
    # Every DIVERGING LINE must carry a ledger marker, not merely one of them.
    # `grep -q` over the whole diff passes a module that has one ledgered
    # divergence AND one real regression — which is precisely how a gate stays
    # green while it is broken. Test.Boundaries was doing exactly that: 13 of
    # its ledgered entries had no marker and rode in on the ASTRAL/INT64 ones.
    #
    # This works because a ledgered divergence names its own cause: the
    # convention is an INT64- / ASTRAL- / STACK- / NEGZERO- prefix on the test
    # name, so both this lane and the oracle lane's explicit pair list read the
    # same signal out of the same string, and there is no second list to drift.
    unledgered="$(diff "$TMPD/js_out.txt" "$TMPD/go_out.txt" \
                  | grep -E '^[<>]' | grep -viE "$LEDGER_MARKERS" || true)"
    if [ -z "$unledgered" ]; then
      echo "[$mod] OK ledger-only ($LEDGER_MARKERS, $nfiles files)"; ledger=$((ledger+1))
    else
      echo "[$mod] FAIL:"; echo "$unledgered" | head -8; bad=$((bad+1))
    fi
  fi
done
echo "=== $pass identical + $ledger ledger-only = $((pass+ledger))/${#mods[@]} green; $bad bad ==="
[ $bad -eq 0 ]
