#!/bin/zsh
# backend-go conformance: build the PS backend, emit Go for the whole corpus
# (one corefn dir), then for each corpus module swap the entrypoint, `go build`
# the whole package, run it, and diff against the JS reference. A module is
# "green" if byte-identical, or differs ONLY on entries of the divergence
# ledger (test-suite/divergences.json), with exactly the values recorded
# there. The judge is test-suite/ledger.py, the same one the oracle lane uses,
# so the two lanes cannot disagree about what counts as a known divergence.
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
OUT="$TMPD/out"
# Corpus modules are DISCOVERED, never listed by hand -- a hand-maintained list
# is how Test.Maps sat unexecuted in this repo for weeks. Benchmarks are the
# only exclusion: they measure rather than assert and print no TEST lines.
mods=(${(f)"$(cd "$JSREF/src/Test" && ls *.purs | sed 's/\.purs$//' | grep -v '^Bench')"})

echo "==> building backend-go"
# Not silenced. It was, and against an optimizer whose API had moved the build
# failed, `spago run` below ran whatever stale output/ it found, and the lane
# reported on a program nobody had built (review X7).
(cd "$HERE" && spago build)

# Per-entry pruning means each program is emitted for its OWN main: emitting
# --main Test.X prunes away every binding unreachable from Test.X.main (and
# writes its own entrypoint.go), so we emit once per module into a clean dir.
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
  # Every TEST line is judged by name against the ledger, with values. The
  # lane used to exempt any diff line matching INT64|ASTRAL|STACK|NEGZERO, so
  # a regression in any test whose NAME carried one of those words passed
  # (review X3 b).
  if verdict="$(python3 "$JSREF/ledger.py" compare --lane backend-go "$mod" "$TMPD/js_out.txt" "$TMPD/go_out.txt")"; then
    if diff -q "$TMPD/js_out.txt" "$TMPD/go_out.txt" >/dev/null; then
      echo "[$mod] OK identical ($(wc -l <"$TMPD/go_out.txt"|tr -d ' ') lines, $nfiles files)"; pass=$((pass+1))
    else
      echo "[$mod] OK ledger-only (${verdict##*RESULT }, $nfiles files)"; ledger=$((ledger+1))
    fi
  else
    echo "[$mod] FAIL:"; echo "$verdict" | grep -v '^  KNOWN' | head -12; bad=$((bad+1))
  fi
done
# An entry whose module has left the corpus is stale on this lane too.
if ! python3 "$JSREF/ledger.py" stale --lane backend-go "${mods[@]/#/Test.}"; then bad=$((bad+1)); fi
echo "=== $pass identical + $ledger ledger-only = $((pass+ledger))/${#mods[@]} green; $bad bad ==="
[ $bad -eq 0 ]
