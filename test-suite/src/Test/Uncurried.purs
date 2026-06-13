-- | Data.Function.Uncurried round-trips and Data.Function combinators.
module Test.Uncurried where

import Prelude

import Data.Function (on, applyFlipped)
import Data.Function.Uncurried (Fn0, Fn2, Fn3, Fn5, mkFn0, mkFn2, mkFn3, mkFn5, runFn0, runFn2, runFn3, runFn5)
import Effect (Effect)
import Effect.Console (log)

t :: String -> String -> Effect Unit
t name v = log ("TEST " <> name <> ": " <> v)

f0 :: Fn0 Int
f0 = mkFn0 \_ -> 42

f2 :: Fn2 Int Int Int
f2 = mkFn2 \a b -> a * 10 + b

f3 :: Fn3 Int Int Int Int
f3 = mkFn3 \a b c -> a * 100 + b * 10 + c

f5 :: Fn5 Int Int Int Int Int Int
f5 = mkFn5 \a b c d e -> a + b + c + d + e

main :: Effect Unit
main = do
  log "=== Test.Uncurried ==="
  t "fn0" (show (runFn0 f0))
  t "fn2" (show (runFn2 f2 1 2))
  t "fn3" (show (runFn3 f3 1 2 3))
  t "fn5" (show (runFn5 f5 1 2 3 4 5))
  t "fn2-partial" (show (map (runFn2 f2 7) [ 1, 2 ]))
  t "on" (show ((compare `on` negate) 1 2))
  t "applyFlipped" (show (5 `applyFlipped` (_ + 1)))
  t "flip" (show (flip (-) 1 10))
  t "const" (show (const 1 "ignored"))
