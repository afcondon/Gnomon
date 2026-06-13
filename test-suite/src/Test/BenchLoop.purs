-- | Benchmark: tail-recursion / loop overhead (the TCO-relevant probe).
-- | countTo is a self-tail-recursive accumulator; a backend with TCO turns it
-- | into a loop, one without it leans on the host stack (Go's grows; JS's would
-- | overflow, so we keep each loop at 1e6 which V8 turns into a while-loop via
-- | purs's optimizer). We run it `reps` times via an outer tail loop. countTo
-- | only ever adds 1, so the result is bounded (= n) and all backends agree.
module Test.BenchLoop where

import Prelude

import Effect (Effect)
import Effect.Console (log)

countTo :: Int -> Int -> Int
countTo acc n = if n == 0 then acc else countTo (acc + 1) (n - 1)

-- outer tail loop: run countTo `reps` times, accumulate a bounded checksum
driver :: Int -> Int -> Int
driver acc reps =
  if reps == 0 then acc
  else driver (acc + (if countTo 0 1000000 == 1000000 then 1 else 0)) (reps - 1)

main :: Effect Unit
main = log (show (driver 0 30))
