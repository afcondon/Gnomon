# 0002. Statement-form via a Go AST, pretty-printer and gofmt

- Status: Accepted
- Date: 2026-06-13 (promoted from SPIKE-NOTES 2026-07-30)

## Context

Jurist and Pythia emit expressions and can lean on their targets accepting
expression-position blocks (Python via lambda lifting, Julia via `begin`). Go
distinguishes statements from expressions strictly, so the family's
expression-emitter shape does not carry over.

## Decision

Emit a small typed Go AST — `GoExpr` / `GoStmt` / `GoDecl` in
`CodeGen/AST.hs` — print it with a naive but correct pretty-printer
(`CodeGen/Pretty.hs`), and run `gofmt` as a post-pass in `Make.hs` so layout is
not our problem.

Statement scope in expression position becomes a zero-argument IIFE:
`func() any { … }()`.

This is the **pivot away from the family's expression emitter**, and the main
architectural divergence between Gnomon and its siblings.

## Consequences

- purerl was used as a *shape reference* only. Its AST is Erlang-shaped (atoms,
  tuples, map patterns, specs, traversal combinators); the plan had budgeted
  grafting ~760 lines of it. In practice a purpose-built ~70-line Go AST
  (12 `GoExpr`, 7 `GoStmt`, 3 `GoDecl` constructors) was cheaper and clearer.
- gofmt in the pipeline means generated Go is idiomatic to read, which matters
  for an exhibit whose claim is that a Go programmer can inspect the output.
