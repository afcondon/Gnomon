# The seam-tax lane (Gnomon)

**What does it cost to reach a real Go library from PureScript, versus reaching
it from a plain Go program?**

```bash
python3 run_seam.py                 # build both arms, run, compare
python3 run_seam.py --skip-build
python3 run_seam.py --json
```

Third of three. `src/Seam/Kernel.purs` and `src/Seam/Main.purs` are
**byte-identical** across `purescript-julia/perf-seam`,
`purescript-python/perf-seam` and this one — as the canary's shapes and the
differential corpus are. Only the FFI, the native arm and the calibrated ladder
differ. See the Jurist README for the full design rationale.

## Why gzip, and why that is not a weakness

The other two lanes bind an ODE solver, because reaching a numerics stack is
the reason to be on Julia or Python. **That is not the reason to be on Go.**
Go's draw is overwhelmingly its *standard library* — compression, crypto,
`encoding/json`, `net/http`, `regexp` — so `compress/gzip` is the honest
analogue of "the library you came here for", and it needs no module fetch.

Binding a different callee does not weaken the comparison, because what is
measured is the **seam**, and a boundary does not know what is on the far side
of it. The three lanes bear that out: fixed crossing costs of 1.7 µs, 6.6 µs
and 8.0 µs against three completely unrelated libraries.

### The ladder had to be calibrated by measurement

gzip carries **~80 µs of fixed setup per call** on this machine — a 32 KB
window allocation dominates a small input — so its cost is roughly
`80 + 13.7 µs per KB`. A first ladder of 0.5–48 KB spanned only 85–658 µs, a
**7.7× range** where the other two backends span 60×, and would have measured
the flat part of the curve. The shipped ladder (8–705 KB) buys 147 µs → 9.8 ms.

## Results — 2026-08-02, M4 MBP, Go 1.26.4

```
  work/call     poly      native    tax    distort   crossing
  us            ms        ms                         us/call
  ---------------------------------------------------------
       147       61.6      58.8    1.05     1.04       1.28
       326      138.0     130.4    1.06     1.05       1.67
      1027      415.8     410.7    1.01     1.01       2.26
      3408     1356.3    1363.4    0.99     0.99       5.20
      9774     3927.7    3909.7    1.00     1.00       8.06
```

**Tax 0.99–1.06× across a 60× range.** Fit:
`crossing ≈ 1.7 us + 0.07 % of the library call` — **the cheapest boundary of
the three**, which is what one would expect of a compiled runtime with no JIT
warm-up and no interpreter dispatch on the call path.

**This lane is noisier than the other two, and the table says so:** a 0.99×
means the polyglot arm came out *faster* than native on that row, which is
contention or scheduler noise, not a result. Two full runs gave per-row taxes
of `1.05 / 1.01 / 1.03 / 1.00 / 1.00` and `1.05 / 1.06 / 1.01 / 0.99 / 1.00`.

The **fitted** quantities are what reproduce, and they reproduce exactly:
crossing `1.7 us` and marshalling `25 ns/Number` on both runs. That is the
argument for reporting a fit over a curve rather than quoting any single cell —
the cell is noise-limited and the fit is not.

### Payload: Go sits between the other two, for a reason you can name

```
  samples returned   poly      native    tax    crossing
                     ms        ms               us/call
  ------------------------------------------------------
      1 (2 Numbers)   423.4     416.1   1.02      3.01
     16 (32)          421.0     413.2   1.02      3.51
    128 (256)         445.6     415.4   1.07     10.62
   1024 (2048)        464.8     416.0   1.12     55.29
```

Fitted per element, all three lanes:

| | `Array Number` is | per `Number` | 1,000-element return |
|---|---|---:|---:|
| **Jurist** (purejl) | `Vector{Float64}`, unboxed contiguous | **~1.9 ns** | ~2 µs |
| **Gnomon** (psgo) | `[]any`, boxed slice | **~25 ns** | ~25 µs |
| **Pythia** (purepy) | `list` of Python floats | **~104 ns** | ~104 µs |

This was **predicted before it was measured**, from the FFI convention alone:
psgo represents `Array a` as `[]any`, so every `float64` is boxed into an
interface — a heap allocation each — which should land it above Julia's
unboxed vector and below Python's full object model. It came out at 13× Julia
and a quarter of Python.

The point is that the ordering is **structural, not incidental**: it follows
from how each backend represents `Array Number`, and it would not change with
a faster machine or a different library.

## The verdict

**Practical, and the cheapest seam of the three.** A crossing is ~1.7 µs, so a
call needs only ~34 µs of library work for the boundary to fall under 5 % —
against ~130 µs on Jurist and ~160 µs on Pythia. Payload discipline matters
about 13× more than on Julia and about 4× less than on Python.

## Caveats

- One library, one problem shape. gzip returns a byte slice; a library whose
  natural return is a large struct graph would exercise marshalling harder.
- `go run` compiles before the harness's clock starts, so unlike Julia the
  first-call column here is warm-up, not compilation, and is much less
  dramatic.
- `reps = 3`, min-of-reps. Read 1.00× as "indistinguishable".
- The cheap work rows are the noisiest cells in the table: ~150 µs per call
  against a 1.7 µs crossing is a ratio close to the run-to-run spread, which is
  why one run produced a 0.99×. Trust the fit, not the cell.
