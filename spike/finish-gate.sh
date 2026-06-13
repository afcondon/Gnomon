#!/usr/bin/env bash
# Finish the spike go/no-go gate from a session that CAN execute binaries.
# The delegated spike session built the compiler (stack build = green) but could
# not run purs/psgo/go/gofmt. This script closes the loop end-to-end.
set -euo pipefail
cd "$(dirname "$0")/.."        # purescript-go/
ROOT="$PWD"
SPIKE="$ROOT/spike"

echo "== 1. compile Trivial.purs -> corefn + js reference =="
rm -rf "$SPIKE/output"
purs compile --codegen corefn,js "$SPIKE/Trivial.purs"
# purs writes ./output/Trivial/. Put the JS FFI where the js codegen expects it,
# then re-run if needed. (purs picks up Trivial.js sibling automatically.)

echo "== 2. JS reference output =="
node --input-type=module -e 'import("./output/Trivial/index.js").then(m=>m.main())' | tee "$SPIKE/ref.txt"

echo "== 3. run psgo: corefn -> output-go/main.go (+ gofmt post-pass) =="
stack run psgo -- "$ROOT/output" "$ROOT/output-go"

echo "== 4. gofmt check (should be a no-op if Make's post-pass ran) =="
gofmt -l "$ROOT/output-go/main.go" && echo "gofmt-clean"

echo "== 5. go run the generated Go =="
( cd "$ROOT/output-go" && go run main.go ) | tee "$SPIKE/go.txt"

echo "== 6. diff reference vs Go (modulo INT64/ASTRAL ledger; none here) =="
diff "$SPIKE/ref.txt" "$SPIKE/go.txt" && echo "GREEN: byte-identical" || echo "RED: see diff"
