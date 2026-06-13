# backend-go benchmarks (Phase 2, Path B)

Three workloads, three backends — **node** (purs JS, the reference), **backend-go**
(Path B, optimizer IR), **psgo** (Phase 1 naive CoreFn walk, the correctness
oracle). Reproduce with `./run_bench.sh`. All workloads print a bounded checksum
that agrees across all three backends (no `INT64`/`ASTRAL` divergence), so this
also double-checks correctness.

First run measured 2026-06-13 on the MBP (median of 3 warm runs, real seconds):

| Workload | Stresses | node (JS) | backend-go | psgo (oracle) | Path B vs node | Path B vs oracle |
|---|---|---:|---:|---:|---:|---:|
| `BenchFib` — `fib 33` | non-tail recursion + int arithmetic | 0.06 | **0.05** | 1.12 | ~tied | **22× faster** |
| `BenchFold` — `foldl (+)` 5000×1000 | HOF / Foldable dict / boxing | 0.06 | 0.14 | 0.23 | ~2.3× slower | 1.6× faster |
| `BenchLoop` — `countTo 1e6` ×30 | deep tail recursion (no TCO) | 0.11 | 2.10 | 5.40 | **~19× slower** | 2.5× faster |

Checksums (all three backends agree): `3524578` / `462494` / `30`.

## What the numbers say

**1. The optimizer IR delivered a real, measured win over the naive walk
(1.6×–22×).** backend-go beats the Phase-1 oracle on *every* workload, and the
margin tracks primitive-operator density. The headline is `fib`: the oracle emits

```go
(_force(Test_BenchFib_lessThan)).(func(any) any)(n)).(func(any) any)(2)   // n < 2
```

— `<`, `+`, `-` routed through **`Ord`/`Ring` dictionary** members, ~28M lookups
across `fib 33`'s ~7M calls. backend-go emits

```go
if _truthy(_intLt(v0_n, 2)) { ... _intAdd(..., ...) ... _intSub(v0_n, 1) ... }
```

— **native typed primops, no dictionary** — straight from the optimizer's
`Op2 (OpIntOrd OpLt)` etc. That primitive-dict-elimination *is* the 22×. This is
the Path B thesis, measured: the IR's free transforms are worth real time.

**2. The residual gap to node is concentrated in deep tail loops — TCO is the
#1 lever.** `BenchLoop` is ~19× node; the other two are ≤2.3×. backend-go has no
TCO (Phase 1 leaned on Go's growable goroutine stack), so a 1e6-deep tail loop
pays full curried-call + boxing cost on every iteration *and* grows real stack
frames. Both reference consumers invest a whole TCO layer here (backend-es's
`TcoExpr` analysis + join points + dispatch-loop codegen); we do not. This
confirms the post-conformance roadmap: **TCO first**, then a codegen inline table
for known saturated builtins (the `BenchFold` ~2.3× gap is the boxing/HOF tax that
an inline table would chip at).

**3. On call-heavy, primop-dense code backend-go already matches V8** (`fib`
~tied), and beats the naive oracle everywhere — so the `any`-boxed representation
is not, by itself, the bottleneck. Tail-loop call overhead is.

## Caveats

- `node`'s sub-100ms numbers sit near its ~40ms process-startup floor, so the
  small ratios (`fib` tie, `fold` 2.3×) are noisier than the large ones. The two
  load-bearing conclusions — Path B ≫ oracle, and TCO is the gap to node — rest on
  the large, robust gaps (22× and 19×).
- Go binaries are `go build` optimized; node is cold-JIT per run. Both Go backends
  are compared as compiled binaries (fair to each other).
