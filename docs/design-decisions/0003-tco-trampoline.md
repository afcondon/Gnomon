# 0003. TCO trampoline

- Status: Accepted; implemented 2026-10-26 as a `for {}` loop, not a trampoline
- Date: 2026-06-13 (promoted and status-corrected 2026-07-30; corrected again 2026-10-26)

## Context

PureScript's self-recursive tail calls must not consume the target stack.
Jurist solved this with a trampoline; Go has no TCO of its own.

## Decision

Port Jurist's trampoline verbatim, attaching in `generateBind` / `genLetBind`.

Originally recorded as **Deferred to Phase 2** on the grounds that it was not
on the critical path for the smallest corpus modules. That deferral expired
when `Test.Recursion` landed; the mechanism is in place and `Test.Recursion`
is green at 16 assertions.

### Correction, 2026-10-26

The paragraph above was wrong about psgo: no trampoline had landed in the
oracle code generator. `Test.Recursion` was green because it stops at 10^6,
and Go's growable goroutine stack (1 GB limit) absorbs that depth as plain
recursion. At 10^7 the same shape died with `fatal error: stack overflow`.
`Test.DeepTailCalls` (10^7, Gnomon-only so far) now pins it.

What landed instead is not Jurist's trampoline but a loop, since Go has
statements: a binding whose body calls itself, saturated and only in tail
position, compiles to `for {}` over per-call state (`_tco0..`), with fresh
per-iteration copies of the parameters so closures built in the loop capture
their own iteration's values, and tail calls compiled as `_tco0, .. = args;
continue`. It applies to top-level and let-bound `Rec` bindings
(`CodeGen.hs`, "Self tail calls"). Mutual tail calls are NOT looped.

## Consequences

- Mutual tail recursion (`isEven`/`isOdd`) still uses the Go stack.

- Deep non-tail recursion still costs — see the supported-scenarios work
  (backend-viability Gate D11), where trampolined non-tail recursion is named
  as a shape we explicitly do *not* stand behind.
