# 0003. TCO trampoline

- Status: Accepted (recorded as Deferred; landed with Test.Recursion)
- Date: 2026-06-13 (promoted and status-corrected 2026-07-30)

## Context

PureScript's self-recursive tail calls must not consume the target stack.
Jurist solved this with a trampoline; Go has no TCO of its own.

## Decision

Port Jurist's trampoline verbatim, attaching in `generateBind` / `genLetBind`.

Originally recorded as **Deferred to Phase 2** on the grounds that it was not
on the critical path for the smallest corpus modules. That deferral expired
when `Test.Recursion` landed; the mechanism is in place and `Test.Recursion`
is green at 16 assertions.

## Consequences

- Deep non-tail recursion still costs — see the supported-scenarios work
  (backend-viability Gate D11), where trampolined non-tail recursion is named
  as a shape we explicitly do *not* stand behind.
