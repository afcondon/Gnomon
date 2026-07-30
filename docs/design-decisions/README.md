# Design decisions (ADRs) — Gnomon

Gnomon's decisions were **recorded when taken**, not backfilled, but they lived
as a compressed list in `SPIKE-NOTES.md` while the sibling backends kept
numbered files. The README's claim of "the same ADR discipline" was therefore
half-true: the discipline was real, the artefact was not shared. These files
promote that list to the family's form, verbatim in substance, with the status
each decision actually has today.

Provenance for 0001–0006 is `SPIKE-NOTES.md` § "ADRs recorded (decided, not
backfilled)"; 0007 records a decision visible only in the repo's shape.

| ADR | subject | status |
|---|---|---|
| [0001](0001-runtime-representation.md) | Runtime representation | Accepted |
| [0002](0002-statement-form-via-go-ast.md) | Statement-form via Go AST + gofmt | Accepted |
| [0003](0003-tco-trampoline.md) | TCO trampoline | Accepted (was Deferred) |
| [0004](0004-module-layout.md) | Flat package, no loader | Accepted |
| [0005](0005-ffi-doctrine.md) | FFI doctrine | Accepted |
| [0006](0006-conformance-first.md) | Conformance-first | Accepted |
| [0007](0007-two-implementations.md) | Two implementations: oracle + optimizer | Accepted |

The family's fuller treatments live in Jurist's `docs/design-decisions/`, which
Gnomon inherits where it does not diverge — notably ADR-0004 (differential
conformance) and ADR-0008 (same-seed fuzzing, Proposed).
