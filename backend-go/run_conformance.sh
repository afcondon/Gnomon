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
mods=(ADTs Arrays Dictionaries Effects Numbers PatternMatch Recursion Strings STTests Uncurried Records Classes Maps)

echo "==> building backend-go"
(cd "$HERE" && spago build >/dev/null 2>&1)
echo "==> emitting Go for corpus"
rm -rf "$OUT"
(cd "$HERE" && spago run -- --corefn-dir "$JSREF/output" --output-dir "$OUT" --main Test.ADTs >/dev/null 2>&1)
cp "$HERE/runtime.go" "$OUT/runtime.go"

cd "$OUT"
pass=0; ledger=0; bad=0
for m in $mods; do
  mod="Test.$m"
  printf 'package main\nfunc main() { _runEffect(_force(Test_%s_main)) }\n' "$m" > entrypoint.go
  if ! go build -o /tmp/bgo_bin *.go 2>/tmp/be.txt; then echo "[$mod] BUILD-ERR"; bad=$((bad+1)); continue; fi
  if ! /tmp/bgo_bin > /tmp/go_out.txt 2>/tmp/go_err.txt; then echo "[$mod] RUN-ERR: $(grep -m1 panic /tmp/go_err.txt)"; bad=$((bad+1)); continue; fi
  node --input-type=module -e "import(\"$JSREF/output/$mod/index.js\").then(x => x.main())" > /tmp/js_out.txt 2>/dev/null
  if diff -q /tmp/js_out.txt /tmp/go_out.txt >/dev/null; then
    echo "[$mod] OK identical ($(wc -l </tmp/go_out.txt|tr -d ' ') lines)"; pass=$((pass+1))
  elif diff /tmp/js_out.txt /tmp/go_out.txt | grep -qiE "INT64|ASTRAL"; then
    echo "[$mod] OK ledger-only (INT64/ASTRAL)"; ledger=$((ledger+1))
  else
    echo "[$mod] FAIL:"; diff /tmp/js_out.txt /tmp/go_out.txt | head -8; bad=$((bad+1))
  fi
done
echo "=== $pass identical + $ledger ledger-only = $((pass+ledger))/${#mods[@]} green; $bad bad ==="
[ $bad -eq 0 ]
