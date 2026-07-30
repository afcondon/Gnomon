# 0004. Module layout: one flat package, no loader

- Status: Accepted
- Date: 2026-06-13 (promoted from SPIKE-NOTES 2026-07-30)

## Context

Jurist needed a loader (its ADR-0006) because Julia modules and PureScript
modules do not nest compatibly. Go's package system is flatter and its
initialisation order is defined, so the question is open again.

## Decision

Option (b): a **single flat Go package**, one `var` per top-level PureScript
binding, `Module_ident` name mangling, and **no loader**.

## Consequences

- Import cycles between PureScript modules cannot become Go import cycles,
  because there is only one package.
- Value-level CAF cycles still need laziness. Refined during the spike into a
  separate `runtime/prelude.go` rather than Haskell string literals — see the
  SPIKE-NOTES "ADR-0004 refinement" section — with per-thunk `sync.Once` making
  lazy CAF thunks thread-safe.
- `Module_ident` mangling is what the flat-prelude form costs the portability
  index: it cannot inspect Gnomon per-module the way it can the others.
