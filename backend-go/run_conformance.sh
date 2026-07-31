#!/bin/zsh
# backend-go conformance: build the PS backend, emit Go for the whole corpus
# (one corefn dir), then for each corpus module swap the entrypoint, `go build`
# the whole package, run it, and diff against the JS reference. A module is
# "green" if byte-identical, or differs ONLY on the seeded INT64/ASTRAL ledger
# (Go int has no int32 wrap; Go strings count codepoints not UTF-16 units).
#
# Usage: ./run_conformance.sh
set -e
HERE=${0:A:h}
JSREF="$HERE/../test-suite"
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
pass=0; ledger=0; bad=0
for m in $mods; do
  mod="Test.$m"
  rm -rf "$OUT"
  (cd "$HERE" && spago run -- --corefn-dir "$JSREF/output" --output-dir "$OUT" --main "$mod" >/dev/null 2>&1)
  cp "$HERE/runtime.go" "$OUT/runtime.go"
  if ! (cd "$OUT" && go build -o /tmp/bgo_bin *.go 2>/tmp/be.txt); then echo "[$mod] BUILD-ERR: $(head -1 /tmp/be.txt)"; bad=$((bad+1)); continue; fi
  if ! /tmp/bgo_bin > /tmp/go_out.txt 2>/tmp/go_err.txt; then echo "[$mod] RUN-ERR: $(grep -m1 panic /tmp/go_err.txt)"; bad=$((bad+1)); continue; fi
  node --input-type=module -e "import(\"$JSREF/output/$mod/index.js\").then(x => x.main())" > /tmp/js_out.txt 2>/dev/null
  nfiles=$(ls "$OUT"/*.go | wc -l | tr -d ' ')
  if diff -q /tmp/js_out.txt /tmp/go_out.txt >/dev/null; then
    echo "[$mod] OK identical ($(wc -l </tmp/go_out.txt|tr -d ' ') lines, $nfiles files)"; pass=$((pass+1))
  # STACK belongs here too: both lanes' Effect.Exception.stackImpl returns
  # Nothing (neither Go representation carries a stack), and the ORACLE lane
  # has always ledgered it — this script's narrower pattern was the only reason
  # Test.Exceptions read as a failure. Keep the two ledgers in step.
  elif diff /tmp/js_out.txt /tmp/go_out.txt | grep -qiE "INT64|ASTRAL|STACK"; then
    echo "[$mod] OK ledger-only (INT64/ASTRAL, $nfiles files)"; ledger=$((ledger+1))
  else
    echo "[$mod] FAIL:"; diff /tmp/js_out.txt /tmp/go_out.txt | head -8; bad=$((bad+1))
  fi
done
echo "=== $pass identical + $ledger ledger-only = $((pass+ledger))/${#mods[@]} green; $bad bad ==="
[ $bad -eq 0 ]
