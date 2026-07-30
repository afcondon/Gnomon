# 0005. FFI doctrine — "constructors across, handles back"

- Status: Accepted
- Date: 2026-06-13 (promoted from SPIKE-NOTES 2026-07-30)

## Context

The family's rule (Jurist ADR-0002) is that a foreign shim mirrors the *real
JS foreign* rather than reimplementing the function, and that shims do not
encode the runtime representation — otherwise every representation change
becomes a shim rewrite.

## Decision

Adopt the doctrine, with one scoped exception: **core** shims in `Foreigns.hs`
(now `runtime/prelude.go`) *may* encode the `V` / `map[string]any`
representation, because they are the layer that defines it.

Application-level foreigns may not. They receive and return handles.

## Consequences

- Keeps the core layer small and the boundary explicit.
- The corollary rule, arrived at later during the exhibit work: *your own
  algorithm is not a foreign function*. See
  `docs/kb/architecture/backend-exhibit-lessons.md`.
