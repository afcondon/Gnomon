-- | Recursion shapes: the TCO trampoline (top-level, local go, guards),
-- | closure capture inside trampolined loops, plain recursion, mutual
-- | recursion, and MonadRec.
module Test.Recursion where

import Prelude

import Control.Monad.Rec.Class (Step(..), tailRec)
import Data.Array as A
import Data.Function (applyN)
import Effect (Effect)
import Effect.Console (log)

t :: String -> String -> Effect Unit
t name v = log ("TEST " <> name <> ": " <> v)

-- top-level accumulator loop: trampolined on both backends
sumTo :: Int -> Int -> Int
sumTo acc n = case n of
  0 -> acc
  _ -> sumTo (acc + n) (n - 1)

-- depth probe that cannot overflow int32: counts iterations
countTo :: Int -> Int -> Int
countTo acc n = case n of
  0 -> acc
  _ -> countTo (acc + 1) (n - 1)

-- local `go`: Let-bound Rec
triangle :: Int -> Int
triangle n0 = go 0 n0
  where
  go :: Int -> Int -> Int
  go acc k = case k of
    0 -> acc
    _ -> go (acc + k) (k - 1)

-- tail recursion through guards
collatzSteps :: Int -> Int -> Int
collatzSteps steps n
  | n == 1 = steps
  | mod n 2 == 0 = collatzSteps (steps + 1) (n / 2)
  | otherwise = collatzSteps (steps + 1) (3 * n + 1)

-- NOT tail recursive: self-call in argument position stays plain
fact :: Int -> Int
fact n = case n of
  0 -> 1
  _ -> n * fact (n - 1)

-- mutual recursion: not trampolined (kept shallow)
isEven :: Int -> Boolean
isEven n = case n of
  0 -> true
  _ -> isOdd (n - 1)

isOdd :: Int -> Boolean
isOdd n = case n of
  0 -> false
  _ -> isEven (n - 1)

-- closure-capture probe: each iteration's lambda must capture THAT
-- iteration's k
chain :: Int -> (Int -> Int) -> Int -> Int
chain k f = case k of
  0 -> f
  _ -> chain (k - 1) (\x -> f x + k)

-- accumulate an array inside a trampolined loop
collect :: Int -> Array Int -> Array Int
collect n acc = case n of
  0 -> acc
  _ -> collect (n - 1) (A.snoc acc n)

-- MonadRec (counting, so no int32 overflow at depth 10^6)
countRec :: Int -> Int
countRec n0 = tailRec go { acc: 0, n: n0 }
  where
  go { acc, n } =
    if n == 0 then Done acc
    else Loop { acc: acc + 1, n: n - 1 }

main :: Effect Unit
main = do
  log "=== Test.Recursion ==="
  t "sumTo-small" (show (sumTo 0 100))
  t "sumTo-60k" (show (sumTo 0 60000))
  t "countTo-1e6" (show (countTo 0 1000000))
  t "triangle-60k" (show (triangle 60000))
  t "collatz-27" (show (collatzSteps 0 27))
  t "collatz-deepish" (show (collatzSteps 0 97))
  t "fact-10" (show (fact 10))
  t "fact-12" (show (fact 12))
  -- INT64- prefix: documented divergence. JS wraps every Int op |0;
  -- the Julia backend keeps Int64 exactness.
  t "INT64-sumTo-1e6" (show (sumTo 0 1000000))
  t "INT64-fact-20" (show (fact 20))
  t "mutual-even" (show (isEven 100))
  t "mutual-odd" (show (isOdd 101))
  t "chain-probe" (show (chain 3 identity 0))
  t "chain-deep" (show (chain 1000 identity 0))
  t "collect-trampoline" (show (A.length (collect 50000 [])))
  t "collect-content" (show (A.take 3 (collect 5 [])))
  t "applyN" (show (applyN (_ + 2) 1000 0))
  t "tailRec-deep" (show (countRec 1000000))
