# 0008. The Unused pass, and why liveness is structural

- Status: Accepted (landed 2026-07-31)
- Date: 2026-07-31

## Context

Go rejects an unused local outright — `declared and not used` is a **compile
error**, not a warning. Every other target in the family (JS, Python, Julia,
Erlang) merely tolerates or warns. So a pattern binder or `let` binding whose
body never mentions it is fatal in Go alone.

`SPIKE-NOTES.md` predicted this precisely: *"Graft purerl's `Unused` as soon as
a corpus module binds-and-ignores a field. Trivial doesn't, so the spike
artifact is clean."* Our own differential corpus never binds-and-ignores.
`tests/purs/passing` does it **38 times** — the single largest cause of
Gnomon's Gate B4 failures, and the reason it trailed its siblings at 81.6%
while they sat at 90.4%.

Note what this says about corpora: the deferral was correct *and* the gap was
invisible for as long as we only ran code we had written ourselves.

## Decision

Drop bindings the code cannot reference — but **treat pattern binders and let
bindings differently**, because their right-hand sides are not alike.

**Pattern binders are deleted.** A pattern bind's RHS is always a pure
projection out of an already-evaluated scrutinee (`_v0`,
`_v1.(V).Fields[0]`), guarded by the tag check that precedes it. There is no
effect, no panic and no divergence to preserve.

**Let bindings become `_ = expr`.** A `let` RHS is an arbitrary expression, and
the JS reference *evaluates* it. A divergent or throwing RHS must therefore
diverge or throw here too. Assigning to the blank identifier keeps the
evaluation and drops the binding. Deleting it would be a silent semantic
divergence from the reference — exactly the class of bug the differential
corpus exists to catch, so introducing one to satisfy a compiler error would
be self-defeating.

**Liveness is computed over CoreFn, never over rendered Go.** `usedIdents`
walks the expression collecting local `Var` references. It deliberately
**ignores shadowing** and so over-approximates. That errs in the only safe
direction: a retained-but-unused binder reproduces the existing compile error
(no regression), whereas a dropped-but-used binder would be a miscompile.

**One liveness predicate, shared.** `rootLive` decides whether a case scrutinee
is needed — true iff some alternative tests it or binds a name that alternative
uses — and `usedIdents` applies the *same* predicate when descending into a
`Case`. Because both agree, the analysis reaches its fixpoint by construction.

## Why the shared predicate is load-bearing

A first cut that merely filtered unused binders fixed 34 of 38. The surviving
four are the whole argument for this ADR.

**`3388` — dropping one binder makes another dead.**

```purescript
let x = { a: 42, b: "foo" }
    { a, b } = x { a = 43 }   -- a, b unused
```

`genCase` correctly drops the scrutinee binding, which kills the last use of
the `let` binding feeding it — but the `let` had already been ruled live,
because in CoreFn the scrutinee is `Var v`. This needs a fixpoint. Sharing one
predicate gets it without iterating to convergence.

**`Guards` — text scanning cannot see scope.** The predecessor, `rootUsed`,
grepped rendered Go for a `_v0` token. A **nested** case reusing `_v0` in an
inner scope made the outer root look alive. The bug is not the regex; it is
asking a question about binding structure of a string that has none.

The sharp corner is record patterns. `ObjectLiteral` binders emit **no**
condition, only field projections, so a record pattern binding nothing used is
entirely dead. Every other literal binder emits an equality or length check and
stays live regardless. That asymmetry *is* `3388`.

## Consequences

- Gnomon: **279/342 = 81.6% → 339/347 = 97.7%** on `tests/purs/passing`, level
  with Pythia. Zero `declared and not used` remain.
- The psgo oracle lane is unchanged at 556/561, 0 failures — the pass alters
  which bindings are emitted, never what the program computes.
- `rootUsed` and `prettyStmtOf` are retired. GHC's own unused-binding warning
  confirmed they were dead, which is a pleasing way to close the loop.
- **The over-approximation is deliberate and not yet exercised.** A binder kept
  alive only by a shadowed inner reference of the same name would still fail to
  compile. No corpus test hits this. If one ever does, the fix is a
  scope-aware walk, not a wider net.
- This pass is Gnomon-specific by necessity, not by preference: it exists
  because Go's unused-local rule is an error. The *analysis* is target-neutral
  and would transfer if another target ever needed it.
