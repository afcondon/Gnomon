-- | The harness, and the schedule.
-- |
-- | Timing lives here rather than in the runner so that every backend
-- | executes byte-identical measurement code. A per-backend harness written
-- | in the host language is the obvious alternative and it is worse: it
-- | drifts, and the drift is invisible because it presents as a performance
-- | difference.
-- |
-- | ## First call vs steady state
-- |
-- | The two are reported separately and the distinction is load-bearing.
-- | Conflating them is exactly what made Jurist's first performance number
-- | ("170 ms per iteration") uninterpretable: it was 99% compilation.
-- |
-- | Within a single process, sizes for a shape run in ASCENDING order and the
-- | first call at each size is timed on its own. That is not a warm-up
-- | artefact to be discarded — it is the measurement. On Julia, a size that
-- | demands types no smaller size demanded will compile again, so *first-call
-- | cost growing with n* is precisely the type-nesting signal. A harness that
-- | warmed up and threw the first call away would have hidden the entire
-- | 2026-08-01 finding.
-- |
-- | ## Why the shape, not the number
-- |
-- | Every shape runs at several sizes because superlinearity is the signal
-- | and a single size hides it completely. `loopNaive` looks merely slow at
-- | n = 100 and looks like a hang at n = 4000; only the curve says which
-- | world you are in.
module Bench.Main (main) where

import Prelude

import Bench.Clock (flushOut, nowNs)
import Bench.Shapes as S
import Data.Array as Array
import Data.Maybe (Maybe(..))
import Effect (Effect, forE)
import Effect.Console (log)
import Effect.Ref as Ref

-- | Bumped when the emitted line format changes, so a runner reading an old
-- | corpus fails loudly instead of misparsing it.
schemaVersion :: String
schemaVersion = "1"

type Shape =
  { name :: String
  , sizes :: Array Int
  , reps :: Int
  , run :: Int -> Effect Int
  }

-- | Sizes are per-shape, and ORDER MATTERS — both were settled by the lane's
-- | first run rather than chosen up front.
-- |
-- | **Why the cheap shapes go first.** A shape can take longer than any
-- | sensible timeout, so the schedule is ordered so that a lane which dies
-- | still delivers most of the table. `loop-naive` and `fold-list` are last
-- | because they are the two known-pathological shapes on Jurist.
-- |
-- | **Why `fold-list` stops at 100.** Measured 2026-08-01 on Jurist: first
-- | call 9.5 s at n = 100, **235 s at n = 400**, and n = 1600 did not finish
-- | in ten minutes. An n-deep `Cons` has an n-deep type (ADR-0001), so the
-- | compiler does work proportional to the *data* — that is the tag-tuple
-- | cost, and this is it measured rather than inferred. The sizes here are
-- | the largest that keep the lane bounded, and the interesting number is
-- | the growth between them, not any one of them.
-- |
-- | **Why `fold-array` shares those sizes.** It is `fold-list`'s control —
-- | same numbers, same sum, same checksum, different representation walked.
-- | Comparing them at different n would compare nothing. It stays uncapped
-- | and ungated for that reason: it is a control, not a subject, and array
-- | traversal is gated through `map-array` instead.
-- |
-- | **Why `ffi-array` and `string-join` reach 12800.** The runner only gates
-- | a shape at its largest n and only above an absolute floor, because below
-- | that scheduler noise dominates (see `GATE_MIN_STEADY_US` in
-- | `run_perf.py`). At 1600 both of these land around 12–20 us on the JS
-- | reference, so *neither was gated on any backend* — and `ffi-array` is
-- | one of the two shapes that measure the FFI axis this corpus was built
-- | around. A shape that cannot fail the gate is not protected by it. 12800
-- | puts both comfortably clear at a cost of well under a millisecond.
-- |
-- | `reps` is small everywhere. Steady state is a min-of-reps and min
-- | converges fast; more reps would buy precision on the axis that is not in
-- | question.
shapes :: Array Shape
shapes =
  [ { name: "loop-null", sizes: [ 100, 1000, 10000 ], reps: 5, run: S.loopNull }
  , { name: "loop-fore", sizes: [ 100, 1000, 10000 ], reps: 5, run: S.loopForE }
  , { name: "loop-st", sizes: [ 100, 1000, 10000 ], reps: 5, run: S.loopST }
  , { name: "loop-tailrec", sizes: [ 100, 1000, 10000 ], reps: 5, run: S.loopTailRec }
  , { name: "ffi-call", sizes: [ 100, 1000, 10000 ], reps: 5, run: S.ffiCall }
  , { name: "record-update", sizes: [ 100, 1000, 10000 ], reps: 5, run: S.recordUpdate }
  , { name: "map-array", sizes: [ 100, 400, 1600 ], reps: 5, run: S.mapArray }
  , { name: "string-join", sizes: [ 100, 400, 1600, 12800 ], reps: 5, run: S.stringJoin }
  , { name: "string-append", sizes: [ 100, 400, 1600 ], reps: 3, run: S.stringAppend }
  , { name: "ffi-array", sizes: [ 100, 400, 1600, 12800 ], reps: 5, run: S.ffiArray }
  -- The pair, at shared sizes: the ADT probe and its flat control.
  , { name: "fold-array", sizes: [ 10, 25, 50, 100 ], reps: 5, run: S.foldArray }
  , { name: "fold-list", sizes: [ 10, 25, 50, 100 ], reps: 5, run: S.foldList }
  -- Last, and capped: 552 ms first call at n = 160 on Jurist, 224 s at 1000.
  , { name: "loop-naive", sizes: [ 10, 20, 40, 80, 160 ], reps: 3, run: S.loopNaive }
  ]

-- | `BENCH <shape> <n> <first-us> <steady-us> <checksum>`
-- |
-- | Mirrors the differential suite's `TEST <name>: <value>` convention, for
-- | the same reason: a line format a human can read in raw output and a
-- | runner can parse without a library.
measure :: Shape -> Int -> Effect Unit
measure sh n = do
  t0 <- nowNs
  checksum <- sh.run n
  t1 <- nowNs
  best <- Ref.new (t1 - t0)
  forE 0 sh.reps \_ -> do
    a <- nowNs
    _ <- sh.run n
    b <- nowNs
    Ref.modify_ (min (b - a)) best
  steady <- Ref.read best
  log $ "BENCH " <> sh.name
    <> " "
    <> show n
    <> " "
    <> show ((t1 - t0) / 1000.0)
    <> " "
    <> show (steady / 1000.0)
    <> " "
    <> show checksum
  flushOut

-- | Flat iteration, deliberately. `for_` over an array folds with `>>=` and
-- | would build a bind chain as long as the schedule — which is the very
-- | shape `loop-naive` exists to measure. A harness that reproduced the
-- | pathology while measuring it would add its own cost to every number.
main :: Effect Unit
main = do
  log ("BENCH-SCHEMA " <> schemaVersion)
  flushOut
  forE 0 (Array.length shapes) \i ->
    case Array.index shapes i of
      Nothing -> pure unit
      Just sh ->
        forE 0 (Array.length sh.sizes) \j ->
          case Array.index sh.sizes j of
            Nothing -> pure unit
            Just n -> measure sh n
