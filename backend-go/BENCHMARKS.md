# backend-go benchmarks (Phase 2, Path B)

Three workloads, three backends — **node** (purs JS, the reference), **backend-go**
(Path B, optimizer IR), **psgo** (Phase 1 naive CoreFn walk, the correctness
oracle). Reproduce with `./run_bench.sh`. All workloads print a bounded checksum
that agrees across all three backends (no `INT64`/`ASTRAL` divergence), so this
also double-checks correctness.

Measured 2026-06-13 on the MBP (median of 3 warm runs, real seconds), **after the
Stage-1 TCO landed** (single self-recursive top-level loops → Go `for {}`):

| Workload | Stresses | node (JS) | backend-go | psgo (oracle) | Path B vs node | Path B vs oracle |
|---|---|---:|---:|---:|---:|---:|
| `BenchFib` — `fib 33` | non-tail recursion + int arithmetic | 0.06 | **0.05** | 1.12 | ~tied | **22× faster** |
| `BenchFold` — `foldl (+)` 5000×1000 | HOF / Foldable dict / boxing | 0.06 | 0.13 | 0.23 | ~2.2× slower | 1.8× faster |
| `BenchLoop` — `countTo 1e6` ×30 | deep tail recursion | 0.11 | 0.50 | 5.45 | ~4.5× slower | **11× faster** |

Checksums (all three backends agree): `3524578` / `462494` / `30`.

### Stage-1 TCO impact (`BenchLoop`)

| | pre-TCO | post-TCO | speedup |
|---|---:|---:|---:|
| backend-go | 2.10s | **0.50s** | **4.2×** |
| gap to node | ~19× | ~4.5× | — |

TCO turned `countTo`/`driver` from stack recursion (two curried `func(any) any`
type-asserts + a real Go frame per iteration) into a flat `for {}` with register
reassignment + `continue`. The remaining ~4.5× gap to node is no longer call or
stack overhead — it's the **`any`-boxing tax** on the per-iteration `_intAdd`/
`_intEq` (V8 JITs the loop to unboxed int ops). That is the *next* lever
(concrete typing / unboxing, or an inline table), not TCO.

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

**2. TCO was the #1 lever, and it's now landed (Stage 1).** Pre-TCO `BenchLoop`
was ~19× node; deep tail loops paid full curried-call + boxing cost *and* grew
real Go stack frames. Stage-1 TCO (single self-recursive top-level functions →
`for {}`, consuming the optimizer's own `Codegen.Tco.analyze`) cut it to ~4.5×
node — a 4.2× win on that workload. The remaining gap is the per-iteration
`any`-boxing tax, not control flow. Still open: local `where go` loops, mutual
recursion, and join points (Stage 2), plus a codegen inline table for the
`BenchFold` ~2.2× HOF/boxing gap.

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
