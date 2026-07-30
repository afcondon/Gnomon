# 0006. Conformance-first

- Status: Accepted
- Date: 2026-06-13 (promoted from SPIKE-NOTES 2026-07-30)

## Context

Jurist's ADR-0004 established differential conformance: the same FFI-free
source compiled by the reference (JS) backend and by ours, both run, output
diffed byte-for-byte, deliberate differences named in a ledger.

## Decision

Adopt the corpus and runner **in shape**, sharing the `Test.*` modules with the
siblings rather than writing a Go-specific suite. A backend claim is whatever
the differential gate says and nothing more.

## Consequences

- Recorded at a documented **red** baseline (`test-suite/BASELINE.md`,
  2026-06-13): all modules failing for one reason, 229 unauthored foreign
  shims. Publishing the red baseline rather than waiting for green is the
  discipline working.
- Now green at 556/561 with 5 ledgered divergences.
- Gnomon led the family on corpus breadth for a while — `Classes`, `Generic`,
  `Records`, `Transformers`, `Maps`, `NumLoop` existed here and nowhere else,
  which meant the "shared" corpus was not in fact shared. Levelled 2026-07-30,
  and the runners now **discover** modules from `src/Test/` so the asymmetry
  cannot recur silently.
