# The performance canary

The differential suite answers *does this mean the same thing on both
runtimes?* This lane answers the other half: *and does it still cost what it
cost yesterday?*

```bash
cd perf
python3 run_perf.py                    # build, run, check
python3 run_perf.py --skip-build --echo # re-run, streaming
python3 run_perf.py --update-baseline   # re-record (say why in the commit)
```

## What it is for

Until now nothing in this repo would have noticed a code-generator change
that made a common shape ten times slower. The type-nesting finding of
2026-08-01 — a 1,000-iteration `Effect` loop taking 14 seconds — was found by
accident, while writing a test for something else. That is not a process.

The question the lane asks is **"has this backend drifted against itself?"**
Cross-runtime numbers fall out of the table and are printed, but they are not
the claim and should not become the framing. The shapes are chosen to be
*attributable*, not to be representative of real programs, so "Julia is
faster than JavaScript at X" is not a conclusion this lane supports.

## Two axes

The shapes cover both halves of what "performance of PureScript on this
runtime" means:

- **common computational patterns** — counted loops four ways, folds over a
  list and over an array, `map`, string building, record update
- **cost of the FFI seam** — `ffi-call` is `loop-fore` with the increment
  moved to the far side of the boundary, so their difference is the per-call
  crossing cost; `ffi-array` crosses once with n elements, so it measures
  marshalling instead

## Three design decisions worth knowing

**Timing lives in PureScript** (`Bench.Main`), not in the runner. Every
backend therefore executes byte-identical measurement code. A per-backend
harness written in the host language is the obvious alternative and it is
worse: it drifts, and the drift is invisible because it presents as a
performance difference.

**First call and steady state are reported separately.** Conflating them is
what made Jurist's first performance number uninterpretable — "170 ms per
iteration" was 99% compilation. Sizes for a shape run in ascending order
within one process and the first call at each size is timed on its own. That
first call is not a warm-up artefact to be discarded; on Julia a size that
demands types no smaller size demanded compiles again, so *first-call cost
growing with n* is the type-nesting signal itself.

**The baseline stores ratios, not milliseconds.** An absolute baseline is
worthless the moment it leaves the machine that recorded it. Each shape is
normalised, within its own backend and its own run, against `loop-fore` at
n=1000:

| column | meaning |
|---|---|
| `rel` | steady(shape) / steady(calibration) — cost relative to a plain host loop on the same runtime |
| `f/s` | first / steady — how much of the first call is compilation |

Machine speed cancels, so the baseline is portable to CI. `f/s` is the
type-nesting signal in one number: ~1 on a runtime that does not compile per
call site, and large — and *staying* large as n grows — exactly where
specialisation is happening.

## Checksums gate; timings report

Every shape returns an `Int` checksum, and the runner diffs checksums across
backends **before it looks at a single timing**. A benchmark that computes
the wrong answer quickly is the classic way for a performance suite to stay
green while the thing it measures rots.

Drift against the baseline is reported but does not fail the lane yet
(`--gate-drift` turns it into a failure). The tolerance is a loose 2× because
this lane has no variance history: a canary that cries wolf gets muted, which
is strictly worse than one that is slightly deaf. Tighten it once a few weeks
of runs say what the real noise is.

A shape that does not complete is recorded as **DNF** rather than crashing
the lane — see below for why that is a normal outcome here.

## What the first run found (2026-08-01, M4 MBP)

**Gnomon has no compilation signal, and the whole corpus runs in 2.3 s.**
`f/s` sits at 1.0–1.5× for essentially every shape at every size. Go compiles
ahead of time at process level, outside the harness's clock, so the
type-nesting pathology that costs Jurist 7.1 seconds on a 100-element `foldl`
over a `List` costs Gnomon nothing measurable: `fold-list` reads 1.1× at
n=100.

Together with the same result on Pythia, that closes a stated limit of the
Jurist finding
(`purescript-julia/docs/PERFORMANCE-FINDING-2026-08-01-type-nesting.md`),
which said "nothing was checked on Pythia or Gnomon" and noted that
confirming it would make type nesting the family's first genuinely
runtime-specific performance finding. It is.

What Gnomon does show is the cost of the `any`-boxed representation:

- `loop-tailrec` is the most expensive loop shape (rel ~29 at n=10000) —
  `MonadRec`'s trampoline allocates a `Step` per iteration, and every one of
  them is an interface value.
- `ST`'s advantage over `forE` is smaller here than on the JS reference. At
  n=10000, `loop-st` is 0.62× `loop-fore` on Gnomon against 0.30× on JS — a
  win on both, but half the win. Worth a look, and worth stating as a ratio
  between two shapes rather than as either shape's `rel`, which is normalised
  against `loop-fore` at a *different* n.
- `ffi-array` is very cheap relative to everything else: one crossing and a
  native Go loop over `[]any` beats every PureScript-side traversal.

**A gotcha the lane found in psgo, worth knowing before writing any user
FFI.** psgo locates a user foreign the way purs locates a `.js` — a
co-located `<dir>/<Module>.go`, resolved from the CoreFn `modulePath`, which
is relative to *wherever purs ran*. Run psgo from the repo root and it looks
for `src/Bench/Clock.go` **there**, warns that no co-located file exists, and
emits a `main.go` that cannot compile — surfacing several steps later as a Go
`undefined:` error naming symbols you did write. `run_perf.py` therefore runs
psgo with `cwd = perf/` and asserts that `Clock_foreign.go` was copied before
going further.

**Why the schedule is ordered the way it is.** The pathological shapes run
last, so a lane that hits its timeout still delivers most of the table, and
the corpus flushes stdout after every line so that a timeout yields both the
completed measurements and the identity of the shape that hung. Both came from
Jurist's first run; they cost nothing here and the corpus is shared.

## Files

| | |
|---|---|
| `src/Bench/Shapes.purs` | the shapes — **shared corpus**, byte-identical across the three backend repos |
| `src/Bench/Main.purs` | the harness and the schedule — also shared |
| `src/Bench/Clock.purs` | the one foreign: a monotonic clock, a stdout flush, and the two FFI probes |
| `src/Bench/Clock.js`, `src/Bench/Clock.go` | its implementations, co-located with the `.purs` |
| `run_perf.py` | build, run, derive ratios, compare — **per-backend** |
| `baseline.json` | recorded ratios and checksums |

`src/Bench/Shapes.purs` and `src/Bench/Main.purs` are byte-identical to the
copies in `purescript-julia/perf/` and `purescript-python/perf/`; `md5` them
before changing either, and change all three together.
