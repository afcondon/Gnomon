# 0007. Two implementations: a correctness oracle and an optimizer consumer

- Status: Accepted
- Date: 2026-06-15 / 2026-06-19 (recorded 2026-07-30)

## Context

This decision was never written down; it was visible only in the repo's shape,
which is precisely the kind of thing an ADR set exists to prevent. A reader
finds two backends here and no statement of which is canonical.

## Decision

Gnomon carries **two** PureScript→Go implementations, deliberately:

- **Phase 1 — `psgo`** (`src/`, Haskell). Walks raw CoreFn. This is the
  **byte-identical correctness oracle** and what the differential suite
  (`test-suite/run_tests.py`) drives. It stays.
- **Phase 2 — `backend-go/`** (PureScript). Consumes
  `purescript-backend-optimizer`'s `BackendSyntax` / `NeutralExpr` IR instead
  of raw CoreFn, and is driven by `backend-go/run_conformance.sh`.

Path B takes work already done by the optimizer rather than hand-rolling it:
uncurrying (`Abs (NonEmptyArray params)`), typed PrimOps (`Op2 (OpIntNum
OpAdd)` rather than `Semiring` dictionary lookups — a large slice of dictionary
elimination for free), MagicDo effect special-casing, plus inlining and
whole-program dead-code elimination.

## Consequences

- **Gnomon is the family's answer to "would we have to fork
  backend-optimizer?"** — no: it can be consumed as a library, and this is the
  working demonstration.
- Two conformance entry points is the visible cost, and they are not
  interchangeable: `run_tests.py` gates the oracle, `run_conformance.sh` gates
  the optimizer path. Both should be reachable from `bin/conformance.sh`.
- The oracle is what any correctness claim rests on. Performance claims, when
  they come, belong to Path B — and neither has been measured yet
  (backend-viability Gate D11).
