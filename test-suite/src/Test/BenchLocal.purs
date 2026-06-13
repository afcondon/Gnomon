-- | Benchmark: the local `where go` tail-loop idiom (TCO Stage 2a). Identical
-- | workload to BenchLoop but the counter is a LOCAL recursive helper rather than
-- | a top-level binding -- the most common real-world shape. Pre-Stage-2 this was
-- | stack recursion (like the oracle); post-Stage-2 it is a Go `for {}`.
module Test.BenchLocal where

import Prelude

import Effect (Effect)
import Effect.Console (log)

countLocal :: Int -> Int
countLocal n0 = go 0 n0
  where
  go :: Int -> Int -> Int
  go acc k = if k == 0 then acc else go (acc + 1) (k - 1)

driver :: Int -> Int -> Int
driver acc reps =
  if reps == 0 then acc
  else driver (acc + (if countLocal 1000000 == 1000000 then 1 else 0)) (reps - 1)

main :: Effect Unit
main = log (show (driver 0 30))
