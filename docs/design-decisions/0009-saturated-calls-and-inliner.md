# 0009. Saturated calls and the purs inliner set

- Status: Accepted (2026-10-27)
- Supersedes: the "curried unary closures" line of [ADR-0001](0001-runtime-representation.md)
  for calls of known-arity top-level functions; the curried closure stays as
  the representation of a function *value*.
- Cross-backend: review X1 (`purescript-backends/REVIEW-2026-10.md`), the same
  decision in Pythia and Jurist.

## Context

ADR-0001 made every function a curried unary closure and every call
`f.(func(any) any)(x)`: one interface assertion and one closure call per
argument. A three-argument call cost 53.7 ns and 5 allocations, against
5.7 ns and none for a plain Go call, and `fib 25` ran 17.7× slower than
with plain calls (review G2).

The objection, written in backend-go's header and in Jurist's ADR-0001, was
that `App f args` is a syntactic spine, not a saturation guarantee. That is
true for an *unknown* head. It is false for a head that is a top-level
binding defined as a lambda chain n deep and applied to at least n
arguments: such a call is saturated by construction, and purerl has always
emitted `f/n` plus a curried wrapper for exactly this case. psgo sees the
whole program in one pass, and backend-go collects every module before it
emits any, so the arity map is one fold over the declarations.

Andrew's framing (brief `BRIEF-x1-saturated-calls.md`): if PureScript is a
thin layer over robust runtimes, optimising calls is worth an extra pass, and
where the JS world has a mechanism (purescript-functions, `Uncurried`) we
should do the same or something analogous.

## Decision

**Both lanes, saturated calls.** A top-level binding `f = \p1 .. pn -> body`
emits two declarations:

- `func _sat_M_f(p1 any, .., pn any) any { body }`, a plain Go func (a
  self-tail-recursive one loops inside it, ADR-0003);
- `M_f`, the curried closure, now a wrapper that collects n arguments and
  calls `_sat_M_f`. It is what escapes into first-class use.

A call whose head is such a binding and which supplies k ≥ n arguments
becomes `_sat_M_f(a1, .., an)`, with the other k − n applied curried. A
mutually recursive loop group in backend-go is left curried: its members are
wrappers over one dispatch loop.

**psgo only, the purs inliner set** (`CoreImp/Optimizer/Inliner.hs`, rule for
rule where Go can say it). backend-go gets these from
purescript-backend-optimizer's IR already (`UncurriedApp`, typed `PrimOp`s,
`CtorSaturated`), so it needs none of them:

- `runFnN f a..` and `mkFnN (\a.. -> e)` (N = 0, 2..10), `runEffectFnN` /
  `mkEffectFnN` and the `ST` forms: direct calls and variadic funcs;
- primitive ops through a known dictionary (`add semiringInt`, `eq eqString`,
  `lessThan ordNumber`, `conj heytingAlgebraBoolean`, `negate ringNumber`, the
  `zero`/`one`/`top`/`bottom` constants), `Data.Int.Bits`, `unsafeIndex`,
  `unsafeCoerce`, `identity categoryFn`;
- looking through a module-level alias such as `negate = Data.Ring.negate
  ringNumber`, which CoreFn floats out of every method use (purs's
  "expander");
- saturated constructors built in place: `V{..}`, a dictionary map, or the
  argument itself for a newtype.

Each inlined op means what the prelude.go shim it replaces means, which is
what the JS operator means except where the ledger already says otherwise
(`Int` is not wrapped). Where Go cannot say the same thing it says something
analogous: `Boolean` has no `<` in Go, so `lessThan ordBoolean a b` is
`!a && b`.

**Negative zero.** `negate` on `Number` is unary minus, as on JS. Go's
constants are exact, and a constant `-0.0` is `+0.0`, so a literal `-0.0` is
negated at run time in both lanes, never written as a constant. Two literal
operands are never left to fold as a Go constant either (`0.1 + 0.2` would
be exactly `0.3`).

## Consequences

- The NEGZERO ledger cause is gone. Its seven entries went STALE on both
  lanes and were deleted, not loosened.
- The FFI convention is untouched. Foreigns are not declarations, so they
  never enter the arity map and stay curried; user and library foreigns see
  the same values as before.
- Generated code grows about 15 % (an extra func per known function), and
  `go build` of the corpus took about 40 % longer on the Mini under load.
  `psgo` itself did not get measurably slower. The numbers are in the PR.
- Only *top-level* bindings are saturated. A local `let` function and a call
  through a dictionary method stay curried, unless the dictionary is known
  and the op is one of the inlined primitives.
