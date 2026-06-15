# Gnomon — purescript-go (`psgo`)

A PureScript backend that compiles to Go. **Gnomon** — the rod whose
shadow tells the truth — is the Go member of the polyglot-PureScript
backends family, alongside [Jurist](../purescript-julia/) (PureScript →
Julia, *the judge*) and [Pythia](../purescript-python/) (PureScript →
Python, *the oracle*). The three share the same architecture, the same
ADR discipline, and the same differential-conformance method over a
shared `Test.*` corpus.

## Status

**Phase 1 — reference backend.** The end-to-end differential harness is
working: `purs corefn,js` → `psgo --entry` (per-module reachability
pruning) → `go run` → diff against the JS backend. The code generator and
runtime (`runtime/prelude.go`) produce running Go from CoreFn — see
`output-go/main.go` for a working artifact and `SPIKE-NOTES.md` for how
the spike was driven green.

Conformance is at a **documented red baseline** (`test-suite/BASELINE.md`,
2026-06-13): all 10 corpus modules are red for a single reason — the
foreign-shim catalogue (`Foreigns.hs`) is not yet authored. The worklist
is `test-suite/FOREIGN_WORKLIST.txt` (229 distinct foreign functions,
costed per module). Greening the corpus is the Phase 1 remaining work;
the two-phase plan is in `PLAN.md`.

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
