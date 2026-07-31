# Gnomon — purescript-go (`psgo`)

A PureScript backend that compiles to Go. **Gnomon** — the rod whose
shadow tells the truth — is the Go member of the polyglot-PureScript
backends family, alongside [Jurist](../purescript-julia/) (PureScript →
Julia, *the judge*) and [Pythia](../purescript-python/) (PureScript →
Python, *the oracle*). The three share the same architecture, the same
ADR discipline ([`docs/design-decisions/`](docs/design-decisions/)), and the
same differential-conformance method over a genuinely shared `Test.*` corpus.

## Status

**Tier 1 — conformant core.** The core language and the core libraries are
proven byte-for-byte against the JavaScript backend on the shared corpus:

```
556/561 identical, 5 known divergences, 0 failures     ./bin/conformance.sh
```

The 5 are the standing ledger (`test-suite/run_tests.py`): 2 ASTRAL, 2 INT64,
1 STACK. Jurist and Pythia report the identical figure over the identical
corpus, which is the method working.

### And against the compiler's own test suite

That corpus is one **we wrote**, so it can only prove parity on cases someone
thought of. `purescript/purescript`'s `tests/purs/passing` is the suite the
compiler team wrote to *define the language*:

```
339/347 = 97.7%   tests/purs/passing @ v0.15.15   (purs-corpus/run_corpus.py)
```

Jurist and Pythia score **exactly the same 339/347**, and 4 of the 6 remaining
causes are common to more than one backend — the failures are in the shared
model, not in this lowering. Full analysis:
`docs/kb/reference/purs-corpus-b4-results.md` in the `docs` repo.

The headline from first contact was **`CODEGEN_ERR` = 0**: across 364 tests
probing rank-N types, functional dependencies, instance chains, `Coercible`
and typelevel symbols, nothing made the code generator refuse or crash.

**It is not yet a general-purpose backend.** No `Aff`, so every program is
`Effect`-only and synchronous; ~40 packages exercised, and no measurement of
what fraction of the registry compiles; `Data.String.Regex` is the one
outstanding foreign; and a failure surfaces as a Go panic rather than a
PureScript source position. The gated route out of Tier 1 is
`docs/kb/architecture/backend-viability.md` in the `docs` repo.

Phase 1 opened at a **documented red baseline** — all modules failing, 229
unauthored foreign shims (`test-suite/FOREIGN_WORKLIST.txt`). That history is
kept at the foot of `test-suite/BASELINE.md` rather than deleted: publishing
red before green was the point of [ADR-0006](docs/design-decisions/0006-conformance-first.md).

There are **two implementations here on purpose** — see
[ADR-0007](docs/design-decisions/0007-two-implementations.md). `psgo` (`src/`,
Haskell, raw CoreFn) is the correctness oracle; `backend-go/` (PureScript)
consumes `purescript-backend-optimizer`'s IR. Both are reachable from
`bin/conformance.sh`. Correctness claims rest on the oracle.

## How it works

`psgo` is a from-scratch CoreFn → Go code generator (Haskell). It consumes
the CoreFn JSON that `purs` emits and writes Go, plus a small runtime
prelude. Representation (see `SPIKE-NOTES.md`): ADTs are tagged structs
`V{Tag string, Fields []any}`, records and dicts are `map[string]any`,
functions are curried unary closures, and effects are zero-argument
thunks `func() any`. Lazy CAFs are made thread-safe with a per-thunk
`sync.Once`.

## Usage

```bash
# Build the compiler
stack build

# In a spago project: emit CoreFn alongside JS
spago build --purs-args "--codegen corefn"   # or drive purs directly

# Generate Go (per-module entry pruning)
stack exec psgo -- output output-go --entry Main

# Run
go run output-go/main.go
```

## Conformance

```bash
cd test-suite
python3 run_tests.py          # purs corefn,js + psgo per-module + go run + diff
```

The `Test.*` corpus is shared with Jurist and Pythia — one family
conformance kit, per-backend divergence ledgers.

## Repository layout

- `src/`, `app/` — the compiler (Haskell)
- `runtime/` — the Go runtime prelude
- `test-suite/` — the differential conformance suite (`BASELINE.md`,
  `FOREIGN_WORKLIST.txt`)
- `spike/`, `SPIKE-NOTES.md` — the bring-up spike and its notes
- `PLAN.md`, `STORYBOARD.md` — the two-phase build plan
