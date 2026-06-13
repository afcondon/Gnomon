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
- ✅ Emits coherent Go for all ~200 corpus modules (helper-based `any` runtime).
- ⬜ `runtime.go` + a `main()` emitter; then close the conformance loop against
  the Phase 1 corpus (diff vs JS, same `KNOWN_DIVERGENCES` ledger).
- ⬜ Not-yet-handled IR nodes (emit `_todo`): `Update`, `LetRec`, `Uncurried*`.
- ⬜ Stage 2a proper: emit native Go multi-arg funcs from multi-arg `Abs`
  (currently desugared to curried unary closures = Phase 1 semantics).
