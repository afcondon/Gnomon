#!/bin/zsh
# backend-go perf benchmark: time three workloads on three backends --
#   node (purs JS, the reference)   vs
#   backend-go (Path B, optimizer IR)   vs
#   psgo (Phase 1 naive CoreFn walk, the correctness oracle).
#
# Workloads (test-suite/src/Test/Bench*.purs), each a single timed `main`:
#   BenchFib   fib 33            -- non-tail recursion + int arithmetic
#   BenchFold  foldl (+) 5000*1000 -- higher-order / Foldable dict / boxing
#   BenchLoop  countTo 1e6 * 30   -- deep tail recursion (the TCO probe)
#
# All three print a bounded checksum that agrees across backends (no INT64 /
# ASTRAL divergence), so this doubles as a sanity check. Reports the median of
# 3 warm runs (discards a cold first run). Requires: purs, spago, go, node, stack.
#
# Usage: ./run_bench.sh
set -e
HERE=${0:A:h}
ROOT="$HERE/.."
TS="$ROOT/test-suite"
mods=(BenchFib BenchFold BenchLoop)

med3() {  # print median of 3 `time -p` real-seconds for command "$@"
  local t=()
  "$@" >/dev/null 2>&1 || true            # warm (cold first run discarded)
  for i in 1 2 3; do
    t+=( $( { /usr/bin/time -p "$@" >/dev/null; } 2>&1 | awk '/^real/{print $2}' ) )
  done
  printf '%s\n' "${t[@]}" | sort -n | sed -n 2p
}

echo "==> compiling corpus (corefn,js)"
( cd "$TS" && spago build >/dev/null 2>&1 && eval "purs compile --codegen corefn,js $(spago sources 2>/dev/null | tr '\n' ' ')" >/dev/null 2>&1 )

echo "==> emitting backend-go (Path B)"
( cd "$HERE" && spago build >/dev/null 2>&1 && spago run -- --corefn-dir "$TS/output" --output-dir /tmp/bgo-bench --main Test.BenchFib >/dev/null 2>&1 )
cp "$HERE/runtime.go" /tmp/bgo-bench/runtime.go

echo "==> building psgo (oracle)"
( cd "$ROOT" && stack build >/dev/null 2>&1 )
PSGO="$(cd "$ROOT" && stack path --local-install-root)/bin/psgo"

printf '\n%-10s %12s %14s %14s\n' "workload" "node(JS)" "backend-go" "psgo(oracle)"
printf '%-10s %12s %14s %14s\n' "--------" "--------" "----------" "------------"
for m in $mods; do
  # node
  js=$(cd "$TS" && med3 node --input-type=module -e "import('./output/Test.$m/index.js').then(x=>x.main())")
  # backend-go: whole-program package, swap entrypoint, optimized build
  ( cd /tmp/bgo-bench && printf 'package main\nfunc main() { _runEffect(_force(Test_%s_main)) }\n' "$m" > entrypoint.go && go build -o /tmp/bgo_$m *.go )
  bg=$(med3 /tmp/bgo_$m)
  # psgo: --entry prune, optimized build
  out=/tmp/psgo-bench/Test.$m; mkdir -p "$out"
  ( cd "$ROOT" && "$PSGO" "$TS/output" "$out" --entry "Test.$m" >/dev/null 2>&1 )
  ( cd "$out" && go build -o /tmp/psgo_$m main.go prelude.go )
  pg=$(med3 /tmp/psgo_$m)
  printf '%-10s %11ss %13ss %13ss\n' "$m" "$js" "$bg" "$pg"
done
echo "\n(median of 3 warm runs, real seconds; lower is better)"
