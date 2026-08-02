-- | The seam-tax lane: what does it cost to reach a real foreign library from
-- | PureScript, versus reaching it from a plain program in that language?
-- |
-- | This is the question the backends exist to answer and the one neither of
-- | the other lanes asks. The differential corpus asks whether meaning
-- | survives; the canary asks whether a backend has drifted against itself.
-- | Both can pass while the answer here is "no, and therefore don't".
-- |
-- | ## The design, and why the sweep is the result
-- |
-- | A single ratio would be worthless, because the tax is not a property of
-- | the backend — it is a property of **how much work each crossing buys**.
-- | Two measurements already in hand say so loudly:
-- |
-- |   * the Stability Atlas crosses 13 times with 9,000 floats and pays 0.2 %;
-- |   * Grid Explorer crossed 42 times with ~1,000 records and paid 44.7 %,
-- |     until the payload was narrowed and it fell to 8.1 %.
-- |
-- | Same seam machinery, two orders of magnitude apart. So this lane holds
-- | the call count fixed and sweeps the two axes that actually move the
-- | answer:
-- |
-- |   * **work per call** — `horizonPeriods`, how long the solver integrates;
-- |   * **payload per call** — `nSamples`, how much comes back.
-- |
-- | The output is a curve, and the useful reading is where it crosses into
-- | acceptable. "Is this practical?" has no scalar answer; "a crossing pays
-- | for itself above roughly N microseconds of library work" does.
-- |
-- | ## What is deliberately NOT done here
-- |
-- | The loop stays in PureScript. Handing the whole grid to the foreign side
-- | would make these numbers beautiful and would measure a different
-- | architecture — the one the seam rule forbids, where our algorithm lives
-- | in the foreign file. `native/seam_native.*` runs the identical loop in the
-- | host language, so the comparison is like for like.
module Seam.Main (main) where

import Prelude

import Data.Array as Array
import Data.Int as Int
import Data.Maybe (Maybe(..))
import Effect (Effect, forE)
import Effect.Console (log)
import Effect.Ref as Ref
import Seam.Kernel (flushOut, foreignNs, nowNs, callLibrary, callLibraryPayload, payloadWork, resetForeignNs, workLadder)

-- | Bumped when the emitted line format changes, so a runner reading an old
-- | corpus fails loudly rather than misparsing it.
schemaVersion :: String
schemaVersion = "1"

-- | Sun–Jupiter, as everywhere else in this repo.
mu :: Number
mu = 9.54e-4

-- | Calls per measurement. Fixed across the whole sweep on purpose: the axis
-- | under test is work per crossing, and letting the count drift would
-- | confound it.
calls :: Int
calls = 400

-- | Deterministic shape dials for call `i`, varied so the run is not one input
-- | repeated. Cheap integer arithmetic — it must not show up in the
-- | measurement, and every native arm computes it identically.
paramsFor :: Int -> { a :: Number, e :: Number }
paramsFor i =
  { a: 0.35 + 0.5 * toN (mod (i * 37) 101) / 100.0
  , e: 0.30 * toN (mod (i * 53) 97) / 96.0
  }
  where
  toN :: Int -> Number
  toN = Int.toNumber

-- | The ladder comes from the backend (`Seam.Kernel.workLadder`), calibrated
-- | so every runtime covers the same range of MICROSECONDS of library work
-- | per call — roughly 170 us to 10 ms — which is the regime where the
-- | crossing stops being noise and starts being the bill. Hard-coding it here
-- | would compare different things on different backends.
horizons :: Array Number
horizons = workLadder

-- | Payload ladder, in samples returned per call. 1 is the thin control;
-- | 1024 returns 2,048 `Number`s per crossing.
payloads :: Array Int
payloads = [ 1, 16, 128, 1024 ]

-- | Repetitions after the first. Steady state is a min-of-reps and min
-- | converges fast, so three is enough on the axis that is not in question.
reps :: Int
reps = 3

type Run = { total :: Number, inLib :: Number, checksum :: Number }

-- | `SEAM <axis> <param> <calls> <first-us> <steady-us> <in-lib-us> <checksum>`
-- |
-- | Mirrors the canary's `BENCH` and the differential suite's `TEST`: a line
-- | a human can read in raw output and a runner can parse without a library.
-- |
-- | **First and steady are separate, and the separation is load-bearing.**
-- | The first reading of this lane on Jurist measured 3.6 s against 73 ms for
-- | the steady state — FIFTY times, essentially all of it the runtime
-- | compiling the solver's specialised types on first use. Averaging that in
-- | would have reported a seam tax that was really a compile, which is the
-- | identical mistake that made Jurist's first performance number ("170 ms per
-- | iteration") uninterpretable.
-- |
-- | `in-lib-us` is charged by the foreign itself, so `steady - in-lib` is the
-- | crossing plus this loop — the part that is ours to be billed for. (The
-- | binder is `inLib` because `foreign` is a keyword.)
emit :: String -> String -> Number -> Run -> Effect Unit
emit axis param first r =
  log $ "SEAM " <> axis <> " " <> param <> " " <> show calls
    <> " " <> show (first / 1000.0)
    <> " " <> show (r.total / 1000.0)
    <> " " <> show (r.inLib / 1000.0)
    <> " " <> show r.checksum

-- | Run `body` once for the first-call number, then `reps` more, keeping the
-- | fastest whole pass and ITS in-library time rather than the two taken from
-- | different passes — otherwise the parts can exceed the whole, which is the
-- | same trap `compare.jl` fell into on the Atlas this morning.
timed :: Effect Run -> Effect { first :: Number, best :: Run }
timed body = do
  r0 <- body
  best <- Ref.new r0
  forE 0 reps \_ -> do
    r <- body
    Ref.modify_ (\b -> if r.total < b.total then r else b) best
  b <- Ref.read best
  pure { first: r0.total, best: b }

-- | The thin-payload sweep: one library call per iteration, one `Number` back.
runWork :: Number -> Effect Unit
runWork horizon = do
  res <- timed do
    resetForeignNs
    acc <- Ref.new 0.0
    t0 <- nowNs
    forE 0 calls \i -> do
      let p = paramsFor i
      Ref.modify_ (_ + callLibrary mu p.a p.e horizon) acc
    t1 <- nowNs
    f <- foreignNs
    c <- Ref.read acc
    pure { total: t1 - t0, inLib: f, checksum: c }
  emit "work" (show horizon) res.first res.best
  flushOut

-- | The payload sweep: same call count, same library work, more coming back.
runPayload :: Int -> Effect Unit
runPayload nSamples = do
  res <- timed do
    resetForeignNs
    acc <- Ref.new 0.0
    t0 <- nowNs
    forE 0 calls \i -> do
      let p = paramsFor i
      -- Sum rather than retain: holding 400 arrays would measure the
      -- allocator's patience instead of the crossing.
      let xs = callLibraryPayload mu p.a p.e payloadWork nSamples
      Ref.modify_ (_ + Array.foldl (+) 0.0 xs) acc
    t1 <- nowNs
    f <- foreignNs
    c <- Ref.read acc
    pure { total: t1 - t0, inLib: f, checksum: c }
  emit "payload" (show nSamples) res.first res.best
  flushOut

-- | Flat iteration by index. `for_` over an array folds with `>>=` and would
-- | build a bind chain as long as the schedule — the exact shape that is
-- | pathological on this backend (perf/, 2026-08-01). A harness that
-- | reproduced the pathology while measuring something else would add its own
-- | cost to every number.
main :: Effect Unit
main = do
  log ("SEAM-SCHEMA " <> schemaVersion)
  flushOut
  forE 0 (Array.length horizons) \i ->
    case Array.index horizons i of
      Nothing -> pure unit
      Just h -> runWork h
  forE 0 (Array.length payloads) \i ->
    case Array.index payloads i of
      Nothing -> pure unit
      Just n -> runPayload n
