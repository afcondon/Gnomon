-- | Benchmark: higher-order fold / dictionary dispatch / boxing.
-- | foldl comes through the Foldable dictionary and applies a curried binary
-- | lambda once per element -- on the Go backends that is a `func(any) any`
-- | type-assert + call + Int boxing per step, the cost the `any` runtime pays
-- | that native JS does not. We fold a 5000-element array `reps` times, taking
-- | the running sum mod a prime so the checksum stays in int32 and agrees
-- | across backends.
module Test.BenchFold where

import Prelude

import Data.Array as A
import Data.Foldable (foldl)
import Effect (Effect)
import Effect.Console (log)

driver :: Array Int -> Int -> Int -> Int
driver arr acc reps =
  if reps == 0 then acc
  else driver arr ((acc + foldl (\a x -> a + x) 0 arr) `mod` 1000003) (reps - 1)

main :: Effect Unit
main = log (show (driver (A.range 1 5000) 0 1000))
