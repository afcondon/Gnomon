# The performance canary

The differential suite answers *does this mean the same thing on both
runtimes?* This lane answers the other half: *and does it still cost what it
cost yesterday?*

```bash
cd perf
python3 run_perf.py                    # build, run, check
python3 run_perf.py --skip-build --echo # re-run, streaming
python3 run_perf.py --update-baseline   # re-record THIS machine's baseline (say why in the commit)
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
n=10000:

| column | meaning |
|---|---|
| `rel` | steady(shape) / steady(calibration) — cost relative to a plain host loop on the same runtime |
| `f/s` | first / steady — how much of the first call is compilation |

Machine speed was meant to cancel, making the baseline portable to CI. It
did not: see "Per-machine baselines" below. `f/s` is the
type-nesting signal in one number: ~1 on a runtime that does not compile per
call site, and large — and *staying* large as n grows — exactly where
specialisation is happening.

## Checksums gate; timings report

Every shape returns an `Int` checksum, and the runner diffs checksums across
backends **before it looks at a single timing**. A benchmark that computes
the wrong answer quickly is the classic way for a performance suite to stay
green while the thing it measures rots.

## Drift gates too, but only on rows that can carry a gate

Timing drift is a failure as well (`--gate-drift`, on in `bin/conformance.sh`).
It was not, when the lane was first built, and what changed is worth stating
precisely, because it is not what it looks like.

**The tolerance did not change.** It is still 2×. What changed is the
population it applies to, and the size of the thing everything is divided by.

The original calibration was `loop-fore` at n=1000, which at five reps is six
thousand iterations — not enough work for a tiering JIT to finish tiering.
The JS reference measured that shape at 114, 135, 167, 188 and 196 µs on the
same idle machine on the same day. Every `rel` in the table is divided by that
number, so the lane's noise floor was being set by its own denominator. The
tell was visible in the baseline and went unread: `loop-fore@10000` recorded
`rel` 10.4 on Jurist — linear in n, as a host loop should be — but 6.3 on JS,
not because the JS loop is sublinear but because its denominator was slow.
At n=10000 the calibration reads 1020/1027/1023 µs across runs.

That fixed the denominator but not the tail. Six back-to-back runs of all
three backends (2026-08-01, idle M4 MBP) put the worst run-to-run spread at:

| population | rows | median | 90th | worst |
|---|---|---|---|---|
| every measured row | 258 | 1.13× | 1.35× | **5.74×** |
| largest n of each shape | 78 | 1.10× | 1.26× | 1.69× |
| steady ≥ 50 µs | 123 | 1.10× | 1.27× | 5.74× |
| **both — the gated population** | 56 | 1.10× | 1.21× | **1.69×** |

A 2× gate over the first row would have fired on noise nearly every run. Over
the last it has 1.18× of headroom over the worst thing noise managed in six
tries. So the runner marks a row **gated** when it is both:

1. **the largest n of that shape** — the smaller sizes exist to show the
   *curve*, superlinearity and `f/s` growth, which is a diagnostic and not a
   threshold; and
2. **above `GATE_MIN_STEADY_US`** (50 µs) — below that, scheduler noise and
   timer resolution dominate. `ffi-array@1600` on the JS reference is ~20 µs
   and swings 1.5× between runs while doing identical work.

Ungated rows are still measured, still printed, and still reported as drift —
they just carry `(report only)` and cannot fail a build. Nothing is hidden.

The gate flag is decided when the baseline is **recorded**, and travels in it.
Recomputing it per run would make a shape near the 50 µs line gate on one run
and not the next. It is therefore a property of the recording machine: on a
slower box this excludes rows that would have been measurable there, which
costs a little coverage and never invents an alarm.

Two consequences worth knowing:

- `fold-array` is never gated on any backend, by design. It is `fold-list`'s
  control rather than a subject, and array traversal is gated through
  `map-array` instead.
- `ffi-array` and `string-join` run to n=12800 for no reason other than this.
  At 1600 both sat under the floor on every backend, so neither was gated
  anywhere — and `ffi-array` is one of the two shapes that measure the FFI
  axis this corpus was built around. **A shape that cannot fail the gate is
  not protected by it.**

Tighten toward the 90th percentile once a few weeks of CI runs say what the
tail really looks like; six samples underestimate it.

A shape that does not complete is recorded as **DNF** rather than crashing
the lane — see below for why that is a normal outcome here.

## The speed index, per-machine baselines, and the optimizer lane (2026-10-27)

Three holes, found in the October review (REVIEW-2026-10, X3 c–e; G8):

**A uniform change was invisible.** Every `rel` is divided by the same run's
`loop-fore`, which the same backend compiled, so a change that slows every
shape alike cancels out of every ratio. Each backend now also gets a **speed
index**: the geometric mean, over its gated shapes, of steady(backend) /
steady(js) for the same shape in the same run. `purs` compiles the JS
reference and nothing in this repo touches it, so a uniform change moves the
index by its own size. It is gated at **1.10x either way**.

**The baseline was not portable.** The first green CI run put gated JS ratios
at 2.17x and 0.38x of the M4 baseline with nothing changed. A baseline now
belongs to the machine that recorded it: `baselines/<host>-<cpu>.json`. A
machine with none, which means every CI runner since their host names are
fresh, prints `NOT RUN — Perf drift gate` and, on Actions, a warning
annotation. Checksums gate everywhere. The MBP's old `baseline.json` is
gone. Its host was never recorded, so it could not be matched to a machine;
record one there with `--update-baseline`.

**backend-go had no performance guard at all** (G8), though it owns the TCO
and unboxing work. The canary now runs it as a third lane, emitted through
the optimizer as backend-go's conformance lane does, when
`../purescript-backend-optimizer` is checked out, and says NOT RUN when it
is not.

Each run takes the median of 3 interleaved rounds (`--repeat`), and prints
each round's index. A run whose rounds spread wider than the tolerance says
so (`NOISY`), because it cannot vouch for its verdict.

**Both Go lanes run with GOMAXPROCS=1.** With the default, a Go process on
the M4 lands, per process and at random, in a fast or a slow mode for its
first shapes. psgo's `loop-null@10000` measured ~187 µs or ~440 µs, slow in
9 of 20 fresh processes. backend-go's calibration shape `loop-fore@10000`
measured ~400 µs or ~910 µs, and when it landed slow every backend-go ratio
moved by 2.2x at once, enough to fail main's per-shape gate on noise. GOGC=off
and asyncpreemptoff did not change it; GOMAXPROCS=1 brought it to 1 in 20 and
0 in 30. The corpus is single-threaded, so one P is the honest
configuration; it costs psgo ~15 % on allocation-heavy shapes (no parallel
GC), the same every run. As a backstop, a shape whose steady time varies by
more than 1.5x between the rounds of the recording run is left out of the
index (`unstable` in the baseline file); it is still measured and
ratio-gated.

Noise on the Mac Mini M4 (loaded, other sessions running), 10 back-to-back
runs at the default `--repeat 3`:

| | psgo index | backend-go index |
|---|---|---|
| default GOMAXPROCS | 3.02 – 3.45 (spread **1.141x**) | 1.155 – 1.208 (1.047x) |
| GOMAXPROCS=1 | 3.41 – 3.53 (spread **1.033x**) | 1.181 – 1.269 (1.074x) |

Then 14 gated runs against the recorded baseline, unchanged tree: all
passed, the largest deviation 1.033x (psgo) and 0.932x (backend-go, one
run, while the JS side drifted).

What the index catches, demonstrated with planted changes:

- A fixed cost on every Effect step in psgo's runtime (bind, pure, Ref
  access, each `forE`/`whileE` iteration) moved the psgo index by 1.27–1.30x
  over three runs: MOVED, exit 1. On the same runs no gated per-shape ratio
  passed 2.0x (largest `loop-null` 1.69x); several moved *down*, because the
  calibration shape slowed too. backend-go, not planted, stayed at
  1.02x.
- The compiler as it was before Gnomon#3 (TCO) moved the psgo index only
  1.03–1.05x: ok, and correctly so. The corpus never recurses deep enough
  for TCO to matter (≤1e4), which is G8's other half.

## First calls and start-up, with a tolerance per runtime (2026-10-27)

The speed index is steady state only. Jurist#3 cut the corpus's first calls
on Julia from 7.3 s to 0.55 s, which is the change a Julia user feels most,
and no gated number moved. So each run now records two more numbers per
backend, identically in all three repos (the header of `run_perf.py` has the
reasoning):

- **first-call index**: the sum of first-call times over every shape and
  size, divided by the same sum on JS in the same run;
- **start-up**: ms from spawning the process to its first line of output,
  the median over rounds, against this machine's baseline in ms. It is not a
  ratio to JS, because node's ~60 ms start-up moved 30 % between runs under
  load while Julia's 9.3 s moved under 2 %.

Gnomon's psgo lane now runs a binary built in `build()` rather than `go run`,
so start-up times the program and not Go's compiler.

### Tolerances

| runtime | first-call index | start-up |
|---|---|---|
| Julia | 1.25x | 1.25x |
| Python | 2.0x | not gated |
| Go | 1.5x | not gated |

A number that is not gated is still printed on every run, and the line says
`not gated on <runtime>, recorded only`.

### The noise behind them

Every run of an unchanged tree at `--repeat 3`. The Mac Mini M4 was at load
10–14 throughout (an smbd copy holding about seven cores); there was no
quieter window. BlackStar (Intel i5-6267U, 4 cores, Linux) was idle, each
run starting at a 1-minute load of 0.46–0.49; its runs used julia 1.13.1
against the Mini's 1.12.6.

| lane | first-call index, Mini | spread | idle BlackStar | spread | start-up, Mini | spread | BlackStar |
|---|---|---|---|---|---|---|---|
| jl | 65.1–68.6x js (9 runs) | 1.05 | 56.3–57.7x (4) | 1.03 | 9.25–9.40 s | 1.02 | 21.2 s |
| backend-jl | 29.6–35.1x | 1.19 | 18.9–19.4x | 1.03 | 278–295 ms | 1.06 | 576–593 ms |
| py | 14.6–21.3x (7 runs) | 1.46 | 11.1–11.6x | 1.05 | 27–74 ms | 2.74 | 55–56 ms |
| backend-py | 0.87–1.24x | 1.42 | 0.94–0.98x | 1.05 | 19–38 ms | 2.00 | 30–35 ms |
| go | 3.20–3.49x (7 runs) | 1.09 | 2.57–2.71x | 1.06 | 3–4 ms | — | 2 ms |
| backend-go | 0.76–0.82x | 1.08 | 0.59–0.65x | 1.10 | 3–5 ms | — | 2 ms |

Most of the Mini's spread is load: on the idle machine every first-call
index stays within 1.10x. The tolerances are set for the loaded Mini, the
machine that gates, so on a quiet machine they are looser than they need to
be. Julia's started at the speed index's 1.10 and moved to 1.25 after one
run of an unchanged tree read backend-jl at 0.902x.

Start-up on the Jurist oracle lane is 9.3 s on the Mini: loading and
compiling the emitted program before any PureScript runs. That is
seventeen times its first calls and thirty times backend-jl's start-up.

### Replaying Jurist#3

`main` from before Jurist#3 (b62de96, with this `run_perf.py`) against the
baseline recorded after it, alternating with `main`, `--gate-drift`, at
the first Julia tolerance of 1.10:

| run | jl first-call index | backend-jl first-call index | steady index | exit |
|---|---|---|---|---|
| before #3, 1 | 12.77x MOVED | 15.43x MOVED | ok (0.98x, 1.06x) | 1 |
| before #3, 2 | 12.95x MOVED | 15.72x MOVED | ok (0.97x, 1.06x) | 1 |
| main, 1 | 1.02x ok | 0.90x: MOVED at the first tolerance, 1.10; ok at 1.25 | ok | 1 (at 1.10) |
| main, 2 | 1.03x ok | 1.02x ok | ok | 0 |

The steady index passed the pre-#3 tree both times, and the per-shape drift
on `fold-list` was report-only. Only the first-call index saw the change.

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
| `baselines/<host>-<cpu>.json` | one machine's recorded ratios, speed index, first-call index, start-up and checksums |

`src/Bench/Shapes.purs` and `src/Bench/Main.purs` are byte-identical to the
copies in `purescript-julia/perf/` and `purescript-python/perf/`; `md5` them
before changing either, and change all three together.
