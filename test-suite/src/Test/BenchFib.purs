-- | Benchmark: non-tail recursion / call + closure overhead.
-- | fib is doubly self-recursive in argument position, so neither the
-- | optimizer nor any backend can trampoline it -- it is a pure stress test
-- | of function-call cost (curried-closure allocation + `any` boxing on the
-- | Go backends, native calls on JS). Result fits in int32, so all backends
-- | agree on the checksum.
module Test.BenchFib where

import Prelude

import Effect (Effect)
import Effect.Console (log)

fib :: Int -> Int
fib n = if n < 2 then n else fib (n - 1) + fib (n - 2)

main :: Effect Unit
main = log (show (fib 33))
