-- | `Data.Number.Format` and `Data.Lazy` — two more standard-library modules
-- | that no corpus had ever compiled.
-- |
-- | Added 2026-07-30 while closing Gnomon's foreign gaps. `Data.Number.Format`
-- | is the interesting one: it is JavaScript's `Number.prototype.toFixed` /
-- | `toExponential` / `toPrecision`, so every non-JS backend has to reproduce
-- | V8's formatting rules rather than reach for its own. The systematic trap
-- | is exponent rendering — JS writes `e+2` where most standard libraries
-- | write `e+02`.
module Test.Formatting where

import Prelude

import Data.Lazy (defer, force)
import Data.Number.Format (exponential, fixed, precision, toString, toStringWith)
import Effect (Effect)
import Effect.Console (log)
import Effect.Ref as Ref
import Effect.Unsafe (unsafePerformEffect)

t :: String -> String -> Effect Unit
t name v = log ("TEST " <> name <> ": " <> v)

main :: Effect Unit
main = do
  -- toString: the general JS number rendering
  t "toString-int" (toString 42.0)
  t "toString-frac" (toString 3.14159)
  t "toString-neg" (toString (-0.5))
  t "toString-big" (toString 1.0e21)
  t "toString-small" (toString 1.0e-7)

  -- fixed: digits after the point
  t "fixed-0" (toStringWith (fixed 0) 3.7)
  t "fixed-2" (toStringWith (fixed 2) 3.14159)
  t "fixed-2-pad" (toStringWith (fixed 2) 1.5)
  t "fixed-4-neg" (toStringWith (fixed 4) (-2.5))
  t "fixed-0-int" (toStringWith (fixed 0) 100.0)

  -- exponential: the exponent format is where runtimes disagree
  t "exponential-2" (toStringWith (exponential 2) 150.0)
  t "exponential-0" (toStringWith (exponential 0) 150.0)
  t "exponential-3-small" (toStringWith (exponential 3) 0.000123)
  t "exponential-1-neg" (toStringWith (exponential 1) (-4200.0))
  t "exponential-2-large" (toStringWith (exponential 2) 1.23456e15)

  -- precision: significant digits, and the fixed/exponential switch
  t "precision-3" (toStringWith (precision 3) 3.14159)
  t "precision-1" (toStringWith (precision 1) 123.456)
  t "precision-5" (toStringWith (precision 5) 0.0001234)
  t "precision-2-large" (toStringWith (precision 2) 123456.0)
  t "precision-4-tiny" (toStringWith (precision 4) 1.0e-8)

  -- Data.Lazy: the value is computed at most once, and only on force
  counter <- Ref.new 0
  let lazyVal = defer \_ -> 21 * 2
  t "lazy-not-forced" (show 0)
  t "lazy-force" (show (force lazyVal))
  t "lazy-force-again" (show (force lazyVal))
  t "lazy-map" (show (force (map (_ + 1) lazyVal)))

  -- Memoisation is observable through a Ref: a thunk with an effect in it must
  -- run ONCE however many times it is forced. The earlier version of this
  -- block read a counter that nothing ever wrote, so it passed whether or not
  -- Data.Lazy memoised anything -- it asserted the initial value of a Ref.
  -- Here the thunk actually increments, and the count is the assertion: three
  -- forces, one evaluation. A Data.Lazy that re-evaluates reads 3 and fails.
  let
    counted = defer \_ -> unsafePerformEffect do
      Ref.modify_ (_ + 1) counter
      pure 7
  t "lazy-memo-1" (show (force counted))
  t "lazy-memo-2" (show (force counted + force counted))
  n <- Ref.read counter
  t "lazy-memo-evaluated-once" (show n)
