# backend-go — Phase 2, Path B (purescript-backend-optimizer)

A **PureScript** PureScript→Go backend that consumes the optimized IR from
[`purescript-backend-optimizer`](https://github.com/aristanetworks/purescript-backend-optimizer),
rather than walking raw CoreFn ourselves (that is Phase 1, the Haskell `psgo`
on `main`, which stays as the byte-identical **correctness oracle**).

## Why Path B

The optimizer's IR (`BackendSyntax` / `NeutralExpr`) arrives with work already
done that we'd otherwise hand-roll:

- **Uncurrying** — `Abs (NonEmptyArray params)` / `App f args` come pre-collected.
- **Typed PrimOps** — arithmetic/comparison are `Op2 (OpIntNum OpAdd) …` etc.,
  not `Semiring`/`Eq` dictionary lookups. A big slice of dictionary elimination
  for free.
- **Effect special-casing** — `EffectBind`/`EffectPure`/`EffectDefer` (MagicDo
  built in); no monadic bind-closure towers.
- Inlining + whole-program dead-code elimination.

## Layout

- `src/Main.purs` — CLI driver; calls `basicBuildMain` and writes one
  `<Module>.go` per module into the output dir.
- `src/PureScript/Backend/Optimizer/Codegen/Go/Builder.purs` — verbatim port of
  backend-es's generic `basicBuildMain` (reads/sorts corefn.json, merges inline
  directives, folds `buildModules`). Nothing ES-specific.
- `src/PureScript/Backend/Optimizer/Codegen/Go.purs` — `codegenModule`: the IR
  walk → Go source text (gofmt does layout, as in Phase 1).
- `../../purescript-backend-optimizer` — the optimizer, referenced as a local
  `path` extra-package in `spago.yaml`.

## Build / run

```bash
spago build
spago run -- --corefn-dir <dir-of-corefn.json> --output-dir <out>
```

## Runtime ABI the codegen currently assumes (runtime.go — TODO)

Codegen emits an `any`-runtime in the Phase 1 shape, but uses **`any`-taking
helper functions** for every PrimOp and branch test (Go forbids `.(T)` on a
concrete type, so a literal operand can't be asserted inline — helpers assert
internally instead). A `runtime.go` must define, all `func(... any) any` unless
noted:

| Helper | Meaning |
|--------|---------|
| `V{Tag string; Fields []any}` | ADT value (struct, not pointer) |
| `_truthy(any) bool` | unwrap a boolean condition |
| `_isTag(v, tag) any` (bool) | `v.(V).Tag == tag` |
| `_not / _and / _or` | boolean ops |
| `_intNeg/_numNeg/_bitNot/_arrayLength` | unary |
| `_intAdd/Sub/Mul/Div`, `_numAdd/Sub/Mul/Div` | numeric (Int wraps int32) |
| `_intEq/Ne/Gt/Ge/Lt/Le`, `_num…`, `_str…`, `_char…`, `_bool…` | ordering |
| `_bitAnd/_bitOr/_bitXor/_shl/_shr/_zshr` | Int bitwise (int32 semantics) |
| `_strAppend`, `_arrayIndex(arr, i)` | string/array |
| `_refNew/_refRead/_refWrite` | Effect.Ref / ST cells |
| `_runEffect(thunk) any` | force a `func() any` effect |
| `_fail(msg)`, `_todo(what)` | partial match / unimplemented node |

Most of this is a port of Phase 1's `runtime/prelude.go`; the deltas are the
helper-call ABI above and the Effect thunk model (`EffectBind` → sequenced
`_runEffect` calls).

## Status

- ✅ Builds against the optimizer; `codegenModule` typechecks against the live IR.
- ✅ `runtime.go` (ported from Phase 1 `prelude.go` + the helper ABI) and a
  `main()` emitter (`entrypoint.go`).
- ✅ **Conformance: 10/10 corpus modules green** — 8 byte-identical to the JS
  reference, 2 (Recursion, Strings) differ only on the seeded INT64/ASTRAL
  ledger, exactly matching Phase 1. Reproduce: `./run_conformance.sh`.
- ✅ Implemented IR nodes: `Var/Local/Lit/App/Abs/Accessor/CtorSaturated/CtorDef/
  Let/LetRec/EffectBind/EffectPure/EffectDefer/Branch/PrimOp/PrimEffect/
  PrimUndefined/Fail/Uncurried{,Effect}{Abs,App}`.
- ⬜ Still `_todo`: `Update` (record update) — no corpus test hits it yet.
- ❌ ~~Stage 2a: native Go multi-arg from ordinary `Abs`/`App`~~ — **abandoned
  after reading the references.** Neither reference consumer does this: backend-es
  emits `esCurriedFunction` + a folded one-arg `EsCall` spine
  (`Codegen/EcmaScript/Convert.purs`), purescm emits `mkCurriedFn`/`runCurriedFn`
  (nested unary lambdas). Both reserve native multi-arg for `Uncurried*` only —
  which we already do. The optimizer's `App f args` is a *syntactic spine*, not a
  saturation guarantee (f may be partial/over-applied), so a native `f(a,b,c)`
  would be unsound on a strict-arity target like Go. **We have already banked every
  cheap uncurrying win the IR offers.**
- ✅ **Benchmarked** vs the Phase-1 oracle + node (JS) — see `BENCHMARKS.md`
  (`./run_bench.sh`). Result: the optimizer IR is a measured **1.6×–22×** win over
  the naive oracle (biggest where primop density is highest — `fib` is 22× via
  primitive dict-elimination), backend-go ~ties node on call-heavy code, and the
  **only large gap to node is deep tail loops (~19×)** — confirming TCO as the #1
  lever with data.
- ✅ **TCO Stages 1 + 2** → Go `for {}` dispatch loops, consuming the optimizer's
  own `Codegen.Tco.analyze` (see `loopBindings`/`selfLoopClosure`/`genStmts` in
  `Go.purs`). Covers: single self-recursive **top-level** functions (Stage 1) and
  **local `where go`** loops + **mutual recursion** (Stage 2). Self-recursion is a
  `for {}` with register double-buffering; mutual recursion is one internal
  branch-dispatch loop (`_tcomut<tag>`, branch register selects the member) plus a
  thin curried wrapper per member. Measured **4.2×** on `BenchLoop` (2.10s →
  0.50s); the local idiom `BenchLocal` performs like the top-level loop (0.59s)
  rather than stack recursion (oracle 6.31s). Opt-in per binding — join points and
  effect loops still fall through to the correct curried emission, so conformance
  stays 10/10.
- ⬜ Remaining levers, in priority order: (1) **join points** (a local `Let`-bound
  function tail-called from branches — backend-es's `toTcoJoin`/`codegenTcoJoin`),
  and **effect-loop TCO** (recursive `Effect` loops, currently stack recursion).
  (2) A codegen-side **inline table** (`inlineApp` analog) for known saturated
  builtins, and/or concrete typing to kill the per-iteration `any`-boxing tax (the
  residual `BenchLoop` ~4.5× and `BenchFold` ~2.3× gaps to node).
- ⬜ Whole-program build currently compiles all ~200 modules into one package;
  a per-entry prune (cf Phase 1 `--entry`) would speed `go build`.

### Runtime notes / decisions
- `_lazy` returns a distinct `*_thunk`; `_force` unwraps thunks and passes
  direct values (foreign shims) through — so per-module codegen needn't know the
  global generated-vs-foreign name set, and lazy thunks don't collide with
  `Effect a` (`func() any`).
- `OpBooleanAnd`/`Or` emit native short-circuiting `&&`/`||` (via `_truthy`),
  NOT helper calls — the optimizer relies on short-circuit (e.g.
  `isTag Just && p(field0)` must not touch `field0` when the ctor isn't `Just`).
- Non-finite `Number` literals emit `_posInf/_negInf/_nan` (PureScript `show`
  would render `Infinity`/`NaN`, invalid Go).
- Files starting with `_` are ignored by the Go toolchain, hence `entrypoint.go`.
