-- | Coverage + unboxing: a pure-Number self-recursive loop (all registers
-- | float64). Exercises the KNumber branch of the loop-register unboxing
-- | (native float64 arithmetic + comparison, box once at exit). IEEE-754 doubles
-- | are bit-identical on Go float64 and JS Number, so output matches byte-for-byte.
module Test.NumLoop where

import Prelude

import Effect (Effect)
import Effect.Console (log)

-- geometric series: acc + x + x/2 + x/4 + … until x underflows the threshold.
-- acc :: Number, x :: Number — uniform-Number, so it unboxes to a float64 loop.
geom :: Number -> Number -> Number
geom acc x = if x < 0.000001 then acc else geom (acc + x) (x * 0.5)

-- a Number loop with division (native float `/`)
harmonicish :: Number -> Number -> Number
harmonicish acc x = if x > 1000.0 then acc else harmonicish (acc + 1.0 / x) (x + 1.0)

t :: String -> String -> Effect Unit
t name v = log ("TEST " <> name <> ": " <> v)

main :: Effect Unit
main = do
  log "=== Test.NumLoop ==="
  t "geom-1" (show (geom 0.0 1.0))
  t "geom-100" (show (geom 0.0 100.0))
  t "harmonic" (show (harmonicish 0.0 1.0))
