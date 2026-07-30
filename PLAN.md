# `purescript-go` — Two-Phase Build Plan

**Handoff for a dedicated session in a fresh context.** You are picking up a
PureScript → Go compiler backend. A go/no-go spike is **already done and verified
GREEN** (2026-06-13): `purs → CoreFn → psgo → gofmt → go run` produced output
**byte-identical** to the JS backend for a hand-written module. Your job is to
build it out in two phases:

- **Phase 1 — the reference backend:** correct, un-optimized, `any`-runtime
  source-emitter. Walk the shared conformance corpus to green. *Low risk, grind.*
- **Phase 2 — the performant backend:** monomorphised + inlined, concrete-typed
  Go. *Research-flavored; this is the part a real customer (Mark Eibes) wants.*

The two are **layers of one effort**, not rivals: Phase 1 is the conformance-tested
**correctness oracle** that every Phase 2 optimization must match byte-for-byte.

---

## Orientation — read these first, in this order

1. **`purescript-backends/purescript-go-day-one-plan.md`** — the architectural
   spec. Runtime-representation table, the six ADRs, the module-by-module
   skeleton (what's copied from Julia vs grafted from purerl), and §0.5 (why this
   backend exists at all, and the honest psgo comparison). **Phase 1 mechanics
   live there; this file does not duplicate them.**
2. **`purescript-backends/purescript-go/SPIKE-NOTES.md`** — what the spike built
   and learned; several ADRs already drafted (0002 statement-form, 0004 module
   layout). The codegen already compiles and typechecks against real CoreFn.
3. **`purescript-backends/purescript-go/spike/finish-gate.sh`** + `Trivial.purs`
   — the verified end-to-end gate. Re-runnable proof the pipeline works.

### The one operational gotcha — sandboxed subagents cannot execute binaries
If you delegate to subagents: they **can** `stack build` but are **denied
execution** of `purs`, `go`, `gofmt`, `stack run`, and the compiled `psgo`
(documented delegation-sandbox limit). **The emit → gofmt → go-run → diff gate
must run in the *main* session.** Build in subagents if you like; run conformance
from the main loop.

### What exists on disk (all under `purescript-backends/purescript-go/`)
`src/Language/PureScript/Go/{Make,CodeGen,Foreigns}.hs` +
`CodeGen/{AST,Pretty,Common}.hs`; `app/`; `purescript-go.cabal`; `stack.yaml`(+lock,
copied from Julia so deps resolve from cache — **no cold build**); `SPIKE-NOTES.md`;
`output-go/main.go` (working artifact); `spike/`. **Not yet copied in:** the shared
`test-suite/` corpus (Phase 1 step 1).

---

## Phase 1 — the reference backend

**Goal:** CoreFn → `any`/`interface{}` Go source-emitter that walks the shared
`Test.*` corpus to **green**, modulo the inherited divergence ledger. Go is
64-bit-int + UTF-8 like Julia, so it inherits Julia's `INT64-*`/`ASTRAL-*`
divergences **verbatim** — the target is "match Julia/JS modulo that ledger,"
i.e. ~422/426-equivalent, not "JS byte-identical."

**Architecture:** see day-one-plan §2–4. In one breath: everything is `any`;
curried unary closures; ADTs as `V{Tag string; Fields []any}`; records/dicts as
`map[string]any`; `Effect a` as `func() any`; **statement-form** function bodies
(no ternary/expression-`if` — Go has neither); emit to a small Go AST, pretty-print,
then `gofmt`. Lean on Go packages + toolchain init order — **no loader** (Julia
needed one; Go doesn't).

### Progress (session 2, 2026-06-13) — read SPIKE-NOTES.md "Session 2" for detail
- **Gate VERIFIED for real** (was hand-traced): finish-gate.sh ran end-to-end
  byte-identical.
- **Step 1 DONE**: corpus + Go differential runner + psgo `--entry`/reachability +
  honest red baseline (`test-suite/BASELINE.md`, `FOREIGN_WORKLIST.txt`: 229 shims).
- **Core foreign layer DONE** (~56 shims) — now a separate embedded `runtime/
  prelude.go` (ADR-0004 refinement; see below).
- **Four codegen fixes DONE**: guard `.(bool)`; unused-scrutinee elision; direct
  lambda application; `func init()` in topo/eager-dependency order (cycle dodge).
- **Lazy init DONE** (force-on-use memoized thunks; purs's `$runtime_lazy` analog).
  This was the gateway — and **first greens landed**: Test.ADTs 32/32,
  Test.PatternMatch 31/31, Test.Uncurried 9/9, byte-identical to JS (72 tests).
- **NEXT**: the module-specific foreign grind (pure red→green walk now — structural
  risks retired). Unique missing shims: Dictionaries 26, Numbers 37, STTests 38,
  Recursion 73 (also TCO trampoline ADR-0003), Arrays 85, Effects 97, Strings 117.

### Task sequence
1. **Copy the corpus.** `purescript-julia/test-suite/{src/Test/*.purs, run_tests.py,
   output/}` → `purescript-go/test-suite/`. Adapt the runner to expect
   `output-go/<Module>.go`, `go run` per `Test.*`. Run it → **intended red**. *(DONE
   — runner emits per-module `output-go/<Module>/{main,prelude}.go`.)*
2. **Walk modules red → green**, smallest first:
   `Effects(66) → Dictionaries(80) → ADTs(99) → Strings(102) → Recursion(105) →
   PatternMatch(112) → Arrays(116) → Numbers(135) → STTests(136)`.
   (`Uncurried` drags in a big foreign surface — do it after the cheap wins, not
   first.) `genExpr`/`genPattern` already cover every CoreFn node shape these use.
3. **Re-author `Foreigns.hs` shim bodies in Go on demand** as each module pulls
   them in. Doctrine = Julia ADR-0002 verbatim: read the *real JS foreign*, mirror
   it, `any`-typed; "constructors across, handles back"; only the co-maintained
   core shims encode the representation. Ship a **repr-canary** (`examples/repr-canary`).
4. **Graft purerl's `Optimizer/Unused.hs`** the first time a case-binder is bound
   and ignored (Go: unused local `:=` is a *compile error*). Note from the spike:
   discard *parameters* (`$__unused`) are legal in Go, so `\_ ->` lambdas need no
   pass — only unused `:=` locals do.
5. **Graft the TCO trampoline** (Julia ADR-0003) when `Test.Recursion` lands. Go
   has no TCO guarantee; same tagged-pair dispatch loop over a `for`, same
   per-iteration-call shape (Go has the identical loop-var-capture gotcha).
6. **Graft purerl's `MagicDo.hs`** if/when deep `Effect` nesting bites (watch
   `STTests`/`Effects`) — collapses `do` chains, avoids closure-stack growth.
7. **Record ADRs 0001–0006** in the family format as you go (day-one-plan §4 lists
   them; 0002/0004 are drafted in SPIKE-NOTES). Decisions, not backfill.

### Definition of done (Phase 1)
Corpus green with a documented `KNOWN_DIVERGENCES` ledger (INT64/ASTRAL, seeded
from Julia); the repr-canary passing; a benchmark-harness skeleton (copy
`purescript-python/bench/run_bench.py`'s shape) so Phase 2 has a baseline to
measure against; a README pointing newcomers at the current compiler. Estimated
~2–2.5k lines, a handful of focused sessions. **This is grind against a measurable
corpus — design risk was retired by the spike.**

---

## Phase 2 — the performant backend

This is the part **Mark Eibes** independently wants ("a completely monomorphised,
highly-inlined golang backend" — Discord, ~early June 2026). **Talk to Mark before
committing the architecture** (see Stakeholder, below): his real headache decides
which sub-phase matters most.

### Why Phase 1 is slow (the four taxes)
1. **`any`-boxing** — every value is `interface{}`; every use is a type assertion
   (`.(int)`, `.(string)`). Defeats Go's escape analysis and inlining.
2. **Curried closures** — `f(x)(y)(z)` is three closure allocations/calls where
   the source meant one.
3. **Dictionary dispatch** — type-class methods go through `map[string]any` lookups.
4. **No inlining** of generated glue.

### The performance program = three transforms
- **(A) Uncurry / arity-raise.** Recover saturated multi-arg calls → real
  `func(x, y, z any) any`, called directly. Kills tax #2. *This is what
  `purescript-backend-optimizer` and purerl's optimizer already do.*
- **(B) Monomorphise / dictionary-specialise.** The hard one. Whole-program,
  dictionary-directed specialization: at each call the resolved instance
  dictionary is a *known* value, so specialize the polymorphic function to its
  concrete type with the dict inlined and β-reduced. Kills tax #3 and *unlocks*
  concrete typing. Fall back to boxed `any` for the undecidable tail (polymorphic
  recursion, higher-rank). "Completely monomorphised" is an asymptote; **"monomorphise
  where decidable, box otherwise" is the shippable version.**
- **(C) Concrete-type / unbox.** Once a function is monomorphic, emit real Go
  types: `Int→int`, `Number→float64`, `String→string`, `Boolean→bool`,
  `Array a→[]T`, records→generated structs, **ADTs→typed per-constructor structs**
  (the WASM backend's struct-ADT approach, which Julia's ADR-0001 deliberately
  deferred — adopt it here). Kills tax #1; lets Go's own inliner/escape-analysis fire.

### The architecture fork — the key Phase 2 decision
- **Path A — hand-roll the passes on our own Go AST.** Reference: **purerl's
  `CodeGen/Optimizer/` (LOCAL)** — `Inliner`, `MagicDo`, `Memoize`, `Unused` are
  living proof you can hand-write a solid optimizer suite for a CoreFn-derived
  backend without external tooling. Keeps one codebase; the `any` path stays as
  the fallback/oracle. Cost: you re-implement transform (A) that the optimizer
  gives for free.
- **Path B — consume `purescript-backend-optimizer` IR.** Faubion/Arista's
  backend-agnostic optimizer (NOT local — clone it) emits IR with **(A)
  uncurrying + inlining already done**. You add only (B) + (C). References (clone
  as study material): **`purescript-backend-erl`** (Erlang via the IR) and
  **`purescm`** (Chez Scheme via the IR) — both are optimizer-IR consumers.
  Cost: two codebases (Phase 1 and Phase 2 share the corpus, not code).

**The caveat that holds for both paths:** purerl, backend-erl, and purescm all
target *dynamically-typed* runtimes (Erlang, Scheme) — **none of them monomorphise
or do concrete typing.** Transforms (B) and (C) are **genuinely new ground**. The
conceptual references are **MLton** (whole-program monomorphise + defunctionalize
for SML) and **Rust** (monomorphised generics), not any existing PS backend.

*Lean:* Path B if Mark is already on backend-optimizer IR (compose with his work);
Path A if staying self-contained and using the spike's AST is more important than
reusing his uncurrying. Decide with Mark's answer in hand.

### Staging — what makes a research feature shippable
Each stage is independently shippable, **conformance-gated** (must preserve
byte-identical corpus output) and **benchmarked** (vs the Phase 1 `any` baseline,
vs Arvanitis's old `psgo`, vs JS):
- **2a — uncurrying/arity-raising.** Big win, low risk. Removes the closure tax.
- **2b — concrete primitive typing + typed ADT structs** for the *already-monomorphic*
  core (functions with no type-class constraints). Medium win, medium risk.
- **2c — dictionary-directed monomorphisation** of polymorphic functions, with the
  boxed-`any` fallback. The research lift; do it last, behind the corpus gate.

### Stakeholder — Mark Eibes
Before building, get his **real headache** with existing options. The right
sub-phase priority depends on whether he wants startup time / a tiny static binary
(2a + dead-code), raw throughput (2b/2c), goroutine interop, or something else.
He maintains rowtype-yoga/yoga-postgres; Andrew has a direct line and prefers
upstream/joint collaboration. See memory `project_go_backend_eibes_customer`.

### Definition of done (Phase 2)
Not "completely monomorphised" (that's an asymptote) but: **a benchmark table**
showing each staged win against the baseline + psgo + JS, with the corpus still
green at every stage, and the boxed fallback guaranteeing it always compiles and
runs. Ship the staged wins; document what stays boxed and why.

---

## Cross-cutting

- **The conformance corpus is the correctness gate for BOTH phases.** Nothing
  lands red. Phase 2 optimizations are only valid if output stays byte-identical.
- **Reference-hub tie-in.** This build fills the Go column(s) of
  `afc-work/docs/backends/backend-comparison.md` (currently stale — it
  lists Go as "to be added"). Keep that table updated as phases land; the "run the
  same program" strip it calls for **is** the differential corpus. The
  `docs/backends/adding-a-backend.md` guide was effectively validated by the spike.
- **Comparison baseline.** Arvanitis's `purescript-native` (psgo, LOCAL) is the
  native-binary perf baseline Phase 2 measures against — it's the tuned,
  monomorphised-ish incumbent. (Reviving it to current purs is likely *more* work
  than this build — see day-one-plan §0.5 — but it's the honest yardstick.)

## Reference map (absolute paths + external)
- **Skeleton + ADRs (copy/port):** `purescript-backends/purescript-julia/`
  (Jurist) and `purescript-backends/purescript-python/` (purepy, sibling +
  lambda-lifting ADR).
- **Grafts + optimizer reference:** `purescript-backends/purerl/` — `CodeGen/AST.hs`,
  `Pretty.hs`, `CodeGen/Optimizer/{Inliner,MagicDo,Memoize,Unused}.hs`,
  `CheckedWrapper.hs`, `Types.hs`.
- **WASM struct-ADT / typed-representation reference:**
  `purescript-backends/purescript-backend-wasm/` (its ADRs 0007/0016/0023).
- **External (clone for Phase 2):** `purescript-backend-optimizer` (Faubion/Arista),
  `purescript-backend-erl` (purerl org), `purescm` (Chez Scheme). Conceptual:
  MLton, Rust generics.
- **Memory:** `project_go_backend_eibes_customer`, `project_delegation_sandbox_limits`,
  `project_yoga_upstream_collaboration`.
