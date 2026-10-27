# CLAUDE.md — Gnomon (PureScript → Go, `psgo`)

Guidance for agents working in this repo. Read the family section once. It
is the same in all three backend repos, and it carries the intent that the
rest of the design follows from. The part after it is specific to Gnomon.

Gnomon inherits Jurist's fuller treatment of the shared decisions where it
doesn't diverge. In particular, Jurist ADR-0004 (differential conformance)
applies here.

<!-- FAMILY SECTION: identical in Jurist, Pythia and Gnomon. Edit all three together. -->

## What this family is for

Jurist (Julia), Pythia (Python) and Gnomon (Go) are full backends for the
PureScript language, peers of the JavaScript backend, built on one shared
architecture. They exist for one claim:

> **One typed model of your state, checked once, running wherever the
> computation belongs.**

That claim has two halves, and they differ in how well they are established:

1. **Assurance.** The ADTs, records and types you write mean the same thing
   on every backend you target. "Make illegal states unrepresentable" then
   holds across a multi-language computation, not just within one runtime.
   PureScript is the consistent typed layer above the runtimes. It is chosen
   as a satisfice, not out of purity. This half is what the conformance
   harness exists to prove, and it is the load-bearing half.
2. **Reach.** Each runtime has things the others lack. Julia has symbolic
   computation and ModelingToolkit, and real shared-memory threading. Python
   has gravity: numpy, scipy, pandapower, DuckDB. Go has a single static
   binary with no runtime to install. A computation should run where it is
   most cleanly expressed, as mathematicians move a problem into the
   representation where it is easiest to solve. That analogy is the
   motivation, not the argument: the argument stands without it.

The layout comes from Kevin Jameson's *Multi-Platform Code Management*
(O'Reilly, 1994), with one change: his shared source still carried
per-platform `#ifdef`, and ours carries **none**. Program logic lives in one
FFI-free core, and all per-runtime variation is pushed to the FFI seam.
Write-once-run-anywhere is neither achievable nor desirable, because it would
annul the differences that make a second runtime worth having. So the rule
is: **divergence is surfaced, never concealed.**

## Rules that follow from it

**Should this be on another runtime at all?** Decide in this order:

- **Capability:** it is impossible on JS (a CAS, a static binary). Proceed:
  the cost of crossing the seam is a design input, not a decision input.
- **Frontier:** the point is a foreign library. Price the seam:
  `tax ≈ 1 + prop + (fixed_µs + perNumber_ns × N/1000) / W`, where W is the
  µs of library work per crossing and N is the Numbers PureScript folds per
  crossing. Measured fixed costs are about 1.7 µs on Go, 6.6 µs on Julia
  and 8.0 µs on Python, plus well under 1 % of the call. A tax over 1.05
  means the seam is too fine-grained, not that the runtime is too slow.
- **Neither:** stay on JS. Where the same source has been measured on
  another backend it was slower: hot numeric loops on Julia ran about 70×
  slower than on Node. Elsewhere it is unmeasured, and the structural
  reasons (V8's JIT; curried closures and `Effect` thunks in our output)
  point the same way. Never claim, or chase, a same-algorithm speed-up.

**The seam rule.** The FFI holds a call into a foreign library, **never your
algorithm**. A core that is FFI-free compiles under the stock JS backend too,
and that is what lets the differential harness check your logic byte for
byte. Logic that drifts into a foreign file escapes the harness.

**Descriptions across, handles back.** For library-shaped work, PureScript
builds a typed *description* (a value, an eDSL term) and crosses the seam
once. The runtime computes natively and returns *handles*, and an explicit
step materialises results back. Callbacks across the seam per inner-loop
step are the anti-pattern: slow, and opaque to the runtime's optimiser.

**Representation independence.** User and library foreigns never depend on
how this backend represents an ADT or record. The PureScript side hands in
constructors and eliminators (`fooImpl Just Nothing`), and only the
primitive contracts may be assumed. The core-library shims are the one
exception: they are co-maintained with the code generator and may encode
the representation.

**Reference semantics are flagged by name.** When code must match another
language to the bit (Haskell's 64-bit `Int`, Parsec's errors), the
divergence lives in a module named for the reference (`Haskell.Int`, one
day `Julia.Float`). That module is held to the reference by an oracle that
runs the reference itself, and it never redefines a standard name with a
different meaning.

**Coerce foreign values at the seam.** A `Number` that comes back from a
library may be `numpy.float64`, `Float32` or `BigFloat`. Normalise it where
it crosses, because the differential corpus cannot see that population.

## The harness comes first, always

The project stands or falls on consistency. The harness's job is to mark,
clearly, **what can and cannot be relied on as multi-platform code**. When a
harness fix and a performance win compete, fix the harness, then re-measure
the win through it.

- **The JavaScript backend is the reference.** The shared `Test.*` corpus
  (identical in all three repos, FFI-free) is compiled once, run on JS and
  on this backend, and diffed line for line, including the lines that are
  not `TEST` results. A line passes if it is byte-identical, or if it
  matches a ledger entry exactly.
- **The divergence ledger** is the finite, enumerated list of deliberate
  differences. From the X3 harness work on (October 2026) it is
  `test-suite/divergences.json`. Each entry records the JS value, this
  backend's value and a cause, and one judge (`test-suite/ledger.py`) serves
  every lane:
  - **MISMATCH** when a value moves off its recorded one;
  - **STALE** when an entry stops being needed.

  Causes include `INT32-WRAP` (JS wraps Int to 32 bits), `REM-ZERO`,
  `ASTRAL` (UTF-16 code units against code points), `NEGZERO` and `STACK`.
  The cause is a field, so no rule may depend on a test's name. Before X3
  the ledger was a bare list of names that passed whatever they printed.
  That is the hole X3 closed; don't reintroduce it.
- **Two implementations, on purpose.** The Haskell compiler walking raw
  CoreFn is the reference implementation, and the correctness claims rest on
  it. The PureScript implementation `backend-*/`, which consumes
  `purescript-backend-optimizer`'s IR, is the fast path. **Both lanes are
  diffed against JS**, not against each other. The Haskell side only
  supplies the runtime and shims that the optimizer lane must reuse rather
  than fork.
- **`tests/purs/passing`**, the compiler team's own suite, is a second
  corpus, because ours only covers cases someone thought of. It is run by
  hand through the sibling `purs-corpus` harness, and **nothing gates on
  it**.
- **Know what "CI is green" vouches for.** It covers the oracle lane and the
  perf checksums. CI has no `purescript-backend-optimizer` checkout and no
  machine baseline, so the optimizer lane and the perf drift gate show
  **NOT RUN** there. Run them locally before claiming them.
- **A claim is whatever the gate says, and nothing more.** Our ADRs and
  READMEs have been wrong: an ADR claimed TCO the code didn't have, and a
  README claimed an `Int` wrap that didn't happen. Verify against the code
  and the gate, and fix the document when they disagree.
- **Never get to green by weakening a test**: no new name-pattern
  exemptions, no ledger entry without the JS value, no skipped lane passing
  silently. If a lane cannot run somewhere, it must print **NOT RUN** and
  say why.
- **Don't quote conformance figures from memory or from a README.** They
  move with the corpus. Run the gate and quote its output.
- **Fix it in the family.** The three backends share a skeleton and a
  corpus, so a bug in one is a question for the other two. In October 2026
  the same wrong `div` for negative divisors turned up in all three. Fix the
  backend itself, never shim around it in a program that uses it.

## How we work here

- **ADR discipline** (`docs/design-decisions/`). One decision per record.
  Never delete old text: strike it through and append a dated note. A
  reversal is a new record that supersedes the old one. Only the index is
  edited by overwrite. Numbering is per repo, so name the repo when citing an
  ADR from outside it.
- **Performance claims** come from the repo's own canaries (`perf/`,
  `perf-seam/`), as before and after, with the machine named. From X3 on,
  drift is gated three ways:
  - **per-machine baselines** in `perf/baselines/<host>-<cpu>.json`, because
    a baseline from one machine does not transfer to another;
  - a **speed index against JS**, which catches a change that moves every
    benchmark at once;
  - **`--repeat`**, with a NOISY label when runs disagree.

  A deliberate speed change re-records this machine's baseline
  (`--update-baseline`) in the same PR.
- **Read the existing docs before designing.** The big decisions (runtime
  representation, the FFI doctrine, TCO, conformance) are in the ADRs, and a
  change that reverses one needs a new ADR, not just code.
- **Words with a local meaning:**
  - *core*: the FFI-free logic.
  - *seam*: the FFI boundary.
  - *lane*: one harness run path (the oracle lane, the optimizer lane, a seam
    lane).
  - *ledger*: the divergence list.
  - *canary*: a regression guard. The performance canary measures each
    backend against its own baseline and, from X3 on, against JS. Jurist
    also has a representation canary, which pins its ADR-0001 table.
  - *oracle*: whatever a lane is checked against. That is JS for both
    implementations here, and GHC for `Haskell.*` modules. The Haskell
    implementation is also called "the oracle" in the ADRs, meaning the
    reference implementation. Pythia's nickname, "the oracle", is
    unrelated.

<!-- END FAMILY SECTION -->

## This backend: Gnomon

**Why Go.** Capability: **one static binary, no runtime to install** on the
target. Gnomon is the *primary* platform for Bosun, a process supervisor
written in PureScript, and Node is only its development shell. So a gap
here blocks a real program, and the fix belongs in the backend, never in a
workaround in Bosun.

**Two implementations** ([ADR-0007](docs/design-decisions/0007-two-implementations.md)):
- `psgo` (`src/`, Haskell, raw CoreFn) is the oracle, and its runtime is
  `runtime/prelude.go`.
- `backend-go/` (PureScript, on backend-optimizer's IR) owns the unboxing
  and other optimizer gains.

**Unlike Jurist and Pythia, Gnomon still has two forked runtimes.**
`runtime/prelude.go` and `backend-go/runtime.go` have drifted: hundreds of
lines of diff, regex shims only in one, `sync.Once` CAFs only in
`backend-go`. That fork is the reason the siblings gate against a second
copy. Don't add to either runtime without checking the other, and prefer
work that converges them.

**Representation:**
- **ADTs:** tagged structs, `V{Tag string, Fields []any}`.
- **Records and dictionaries:** `map[string]any`.
- **Functions:** curried unary closures, applied as `f.(func(any) any)(x)`.
- **`Effect`:** a thunk, `func() any`.
- **Statement form:** code is built as a Go AST and printed through gofmt
  ([ADR-0002](docs/design-decisions/0002-statement-form-via-go-ast.md)).
- **Packages:** one flat package with no loader ([ADR-0004](docs/design-decisions/0004-module-layout.md)).
- **Liveness:** structural, via the Unused pass ([ADR-0008](docs/design-decisions/0008-unused-pass.md)).
- **Tail calls:** self tail calls compile to a `for {}` loop since
  2026-10-26 ([ADR-0003](docs/design-decisions/0003-tco-trampoline.md)).
  Before that there was no TCO at all, whatever the ADR said. Only *self*
  tail calls are covered: mutual recursion still grows the stack.

**`Int` does not wrap to int32**, although Go has `int32` natively and an
old README claimed it wrapped. Whether to make it int32 is an **open
decision** for the maintainer, so don't change it unasked.

**FFI** ([ADR-0005](docs/design-decisions/0005-ffi-doctrine.md)):
- In the `backend-go` lane, a program's own foreigns co-locate with the
  `.purs` as `<Module>.go`, in `package main`, defining
  `var <Module>_<name> any = …`.
- Per-package library foreigns live in `backend-go/foreign/`. They are deliberately
  over-included, because the optimizer can erase a module whose foreigns a
  surviving sibling still calls.
- A program's own foreigns are linked only for modules this entry point
  emitted, so an unrelated module's Go imports don't leak into the build.

**Commands:**
- `stack build`
- `bin/conformance.sh`: the gate.
- `cd test-suite && python3 run_tests.py`: the differential suite.
- `stack exec psgo -- output output-go --entry Main`, then `go run`.
- `backend-go/bin/backend-go` runs the optimizer lane from the program's
  directory, and rebuilds itself when `src/` is newer.

The toolchain comes from Nix via `.envrc`. Run `stack` inside that shell.
CI pins GHC 9.8.4 to match `lts-23.18`.

**Known traps:**
- **`psgo` exits 0 on failure**: a CoreFn parse error, a gofmt error, an
  unknown `--entry`. There is no `exitFailure` anywhere in `app/` or
  `src/`. Until that small fix lands, never trust its exit code alone, and
  check that it wrote the output.
- The oracle lane runs `go run main.go prelude.go`, so it never compiles
  user FFI.
- On `main`, the performance canary guards only `psgo`. The X3 harness PR
  adds a `backend-go` runner.
- `patchTokens` (`src/Language/PureScript/Go/CodeGen/Pretty.hs`) rewrites identifier tokens in rendered text,
  possibly including inside string literals. User locals keep their
  PureScript names, so `_m` and `_force` can be captured.
- The optimizer lane takes `purescript-backend-optimizer` as an unpinned
  sibling checkout, and upstream `b8d96a9` broke it. Pin to `4810dc0` until
  that is fixed.

