# 0001. Runtime representation

- Status: Accepted
- Date: 2026-06-13 (promoted from SPIKE-NOTES 2026-07-30)

## Context

Every backend in the family has to choose how PureScript values appear in the
target. Go is statically typed with no variants, which is the pressure this
decision resolves.

## Decision

- `any` everywhere. No attempt to recover PureScript types in Go types.
- Curried unary closures — one argument per `func`, as the JS backend emits.
- ADTs as `V{Tag, Fields}`.
- Records and dictionaries as `map[string]any`.
- Effects as `func() any`; `nil` is `Unit`.

Considered and rejected: struct-per-constructor ADTs (the WASM backend's
approach), which Jurist's ADR-0001 also rejected. It buys target-language
legibility at the cost of a representation that no longer matches the reference
backend, and the differential method depends on that match.

## Consequences

- Inherits Jurist's INT64 / ASTRAL divergence ledger unchanged: Go `int` does
  not wrap to 32 bits and Go strings count code points, exactly as Julia.
- Implemented in `src/Language/PureScript/Go/CodeGen.hs` and `Foreigns.hs`.
