# Scrollytelling storyboard — "How a slow backend got faster than V8"

A scroll-driven, diagrammed telling of the purescript-go Phase-2 port: the arc
from a correct-but-500×-too-slow PureScript→Go backend to one that beats node on
tight loops, including the two false starts. Every frame is backed by **real
measured data and real emitted code** — nothing illustrative.

- **Eventual home:** the polyglot blog (Halogen + Hylograph viz stack). This doc
  lives with the port so it grows as new chapters land; it migrates to the blog
  when we build it.
- **Companion to:** `afc-work/docs/backends/optimizer-ir-vs-handrolled-passes.md`
  (that post is the *theory* — Path A vs B; this is the *diary* — what actually
  happened).
- **Source narrative:** `SPIKE-NOTES.md` Session 4. **Source data:** `backend-go/BENCHMARKS.md`.
- **Design language:** Swiss / International — hairline rules, type-driven labels,
  one accent for "now", grey for "was", restrained palette, generous whitespace.

## The hero visual: one descending track

A single horizontal **log-scale time axis** ("time to run `countTo 1e6 ×30`",
~10 ms → ~10 s). A dot for backend-go **leaps left** (faster) at each scroll beat,
leaving grey ghosts at prior positions. Two fixed reference rules: the **oracle**
and **node/V8**. The piece builds to one moment — the dot **crossing left of the
node line**.

Measured anchor points (median of 3 warm runs, MBP, 2026-06-13; from BENCHMARKS.md
+ the benchmark commit history):

| stage | backend-go BenchLoop | note |
|---|---:|---|
| psgo oracle (Phase 1, naive CoreFn walk) | **5.4 s** | far-right reference rule |
| Path B baseline (typed primops, no TCO) | **2.1 s** | first dot position |
| + TCO (for-loop) | **0.50 s** | |
| + unboxing (native int) | **0.01 s** | crosses left of node ← money shot |
| node / V8 (reference) | 0.11 s | left reference rule |

Paired with a **code panel** showing the *same function* `countTo` morphing at
each beat (diff-highlighted). Decide at build time: panel synced to scroll vs
static diptychs between scenes.

## The scroll beats

| # | Prose beat | Hero track | Code panel (`countTo`) |
|---|---|---|---|
| 1 | "A PureScript→Go backend. Correct, and 500× too slow." | dot at oracle 5.4 s | dictionary dispatch |
| 2 | The fork: hand-roll passes (A) vs consume the optimizer IR (B). *The surprise: the optimizer is PureScript* → B is a second codebase. | branch-diagram interlude | — |
| 3 | The IR pays out free: typed PrimOps kill dictionary dispatch. | dot → 2.1 s (ghost at 5.4) | native primops, curried recursion |
| 4 | **Backtrack ①** — "emit native multi-arg!" Read the refs first: both keep it curried; the spine isn't a saturation guarantee → *unsound*. Pruned. | dot holds; a side-branch greys out | struck-through sketch |
| 5 | Measure. The one big gap is tail loops: 19× node. | annotate the 2.1 s→node gap | curried-closure recursion, flagged "stack" |
| 6 | TCO: turn recursion into a `for {}`. | dot → 0.50 s | the `for {}` with double-buffered registers |
| 7 | **Backtrack ②** — join points / effect loops? Investigated: marginal (shims already native loops). Pruned. | dot holds; second side-branch greys | — |
| 8 | The real fish: every iteration still *boxes* an int. Unbox it. | dot → 0.01 s — **crosses left of node** | native `int`, box once at exit |
| 9 | Coda: the arc, and two lessons — *read before you code; measure before you optimize.* | full track: all ghosts + both pruned branches | — |

## Supporting diagrams (interludes, not scroll-pinned)

- **Decision tree** (beat 2, recurring): the Path A / Path B fork, with the two
  backtracks as branches that visibly *prune* as you pass them. Tells the
  non-linear truth the headline number hides.
- **Boxing micro-animation** (beat 8): one loop iteration — a value inflating into
  a heap `any` box (allocation) every cycle, then the native version where it just
  stays an `int`. Makes "boxing tax" visceral.

## Code panels — the four `countTo` stages

These are the real emitted Go. Reconstruct any exactly with `git show`/rebuild;
verbatim where captured.

**Stage 1 — oracle (dictionary dispatch).** `<`/`+`/`-` routed through Ord/Ring
dictionary members (shown for `fib`; `countTo` is the same shape):
```go
_v0 := ((_force(Test_BenchFib_lessThan)).(func(any) any)(n)).(func(any) any)(2)
```
*(exact `countTo`: build psgo from `main`/7a59976, emit Test.BenchLoop.)*

**Stage 2 — Path B baseline (typed primops, curried recursion).** Native primops,
but a curried-closure self-call per iteration (stack recursion).
*(exact: `git show 2d4bd87` codegen + rebuild; reconstruct at build time.)*

**Stage 3 — TCO (`for {}`, boxed registers).** Verbatim, commit 1ac19c0:
```go
Test_BenchLoop_countTo = _lazy(func() any { return func(_c0_0 any) any { return func(_c0_1 any) any {
  _r0_0 := _c0_0
  _r0_1 := _c0_1
  for {
    var v0_acc any = _r0_0
    var v1_n any = _r0_1
    if _truthy(_intEq(v1_n, 0)) { return v0_acc }
    _r0_0 = _intAdd(v0_acc, 1)
    _r0_1 = _intSub(v1_n, 1)
    continue
  }
} } })
```

**Stage 4 — unboxing (native `int`).** Verbatim, commit beef361 (HEAD):
```go
Test_BenchLoop_countTo = _lazy(func() any { return func(_c0_0 any) any { return func(_c0_1 any) any {
  _r0_0 := _c0_0.(int)
  _r0_1 := _c0_1.(int)
  for {
    var v0_acc int = _r0_0
    var v1_n int = _r0_1
    if (v1_n == 0) { return any(v0_acc) }
    _r0_0 = (v0_acc + 1)
    _r0_1 = (v1_n - 1)
    continue
  }
} } })
```
The diff between Stages 3 and 4 is the whole "unboxing" beat: `.(int)` at entry,
`int` registers, native `+`/`-`/`==`, `any(...)` box once at the leaf.

## Chapters (extend as the port grows)

Each optimization stage = one scroll beat: a measured before→after on the hero
track plus an emitted-code diff in the panel. Append here as new chapters land:

- ✅ Ch.1 Path B + conformance (the IR's free wins; the 22× `fib` dict-elim)
- ✅ Ch.2 TCO stages 1–2 (2.1 s → 0.50 s)
- ✅ Ch.3 Unboxing MVP (0.50 s → 0.01 s, crosses node)
- ⬜ Ch.4 (next) Calling-convention / HOF unboxing — the `BenchFold` ~2.2× gap.
  When it lands: add a `BenchFold` track + the foldl-accumulator code diff.
- ⬜ further chapters as Phase 2 continues…

To add a chapter: record the measured before/after in BENCHMARKS.md, capture the
emitted-code diff, and append a beat row + a code panel here.
