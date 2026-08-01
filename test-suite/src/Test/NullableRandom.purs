-- | `Data.Nullable`, `Effect.Random` and `Test.QuickCheck.Gen`'s
-- | `float32ToInt32` — three small packages from the safe-subset work list.
-- |
-- | `Effect.Random` is the awkward one for a differential suite: its whole
-- | point is that it does NOT produce the same answer twice, so there is no
-- | value to diff. What CAN be diffed is the contract — in range, not
-- | constant, and an `Int` range that is uniform enough to be believable. A
-- | test that printed the number would be worse than useless: it would fail
-- | on every run and get ledgered as a known divergence, which is how a real
-- | divergence would then hide.
-- |
-- | `float32ToInt32` is the opposite: a pure bit pattern with exactly one
-- | right answer per input, and QuickCheck derives its seed from it, so
-- | getting it wrong silently changes every generated test everywhere.
module Test.NullableRandom where

import Prelude

import Data.Maybe (Maybe(..))
import Data.Nullable as N
import Effect (Effect)
import Effect.Console (log)
import Effect.Random as Random
import Effect.Ref as Ref
import Test.QuickCheck.Gen (evalGen, chooseInt, perturbGen, uniform)
import Random.LCG (mkSeed)

t :: String -> String -> Effect Unit
t name v = log ("TEST " <> name <> ": " <> v)

main :: Effect Unit
main = do
  log "=== Test.NullableRandom ==="
  nullable
  bits
  random

--------------------------------------------------------------------------
-- Data.Nullable
--------------------------------------------------------------------------

nullable :: Effect Unit
nullable = do
  t "null-toMaybe" (show (N.toMaybe (N.null :: N.Nullable Int)))
  t "notNull-toMaybe" (show (N.toMaybe (N.notNull 42)))
  t "toNullable-Nothing" (show (N.toMaybe (N.toNullable (Nothing :: Maybe Int))))
  t "toNullable-Just" (show (N.toMaybe (N.toNullable (Just 7))))
  -- The Fn3 `nullable` is not exported; `toMaybe` is how it is reached, and
  -- it has to be fully saturated through runFn3 on the way.
  --
  -- A Nullable of a FALSY value must still be non-null: the JS foreign tests
  -- `a == null`, not `!a`. A shim that tested truthiness passes everything
  -- above and fails all four of these.
  t "toMaybe-of-zero" (show (N.toMaybe (N.notNull 0)))
  t "toMaybe-of-false" (show (N.toMaybe (N.notNull false)))
  t "toMaybe-of-empty-string" (show (N.toMaybe (N.notNull "")))
  t "toMaybe-of-nan" (show (N.toMaybe (N.notNull (0.0 / 0.0))))
  -- Round trips both ways.
  t "roundtrip-just" (show (N.toMaybe (N.toNullable (N.toMaybe (N.notNull 3)))))
  t "roundtrip-nothing"
    (show (N.toMaybe (N.toNullable (N.toMaybe (N.null :: N.Nullable Int)))))
  -- Eq and Ord go through the same eliminator.
  t "eq-null-null" (show ((N.null :: N.Nullable Int) == N.null))
  t "eq-null-value" (show ((N.null :: N.Nullable Int) == N.notNull 1))
  t "eq-value-value" (show (N.notNull 1 == N.notNull 1))
  t "compare-null-value"
    (show (compare (N.null :: N.Nullable Int) (N.notNull 1)))

--------------------------------------------------------------------------
-- Test.QuickCheck.Gen.float32ToInt32 — a bit pattern, not a conversion
--
-- The foreign is not exported, so it is reached the way a user reaches it:
-- `perturbGen` folds its result into the seed. That makes this a better test
-- than calling it directly would be — it pins the bits AND the path they
-- travel. Everything here is deterministic given a fixed seed, so it diffs
-- byte-for-byte despite living in a random-number library.
--------------------------------------------------------------------------

probe :: Number -> String
probe n =
  show (evalGen (perturbGen n (chooseInt 0 1000000))
                { newSeed: mkSeed 1234, size: 10 })

bits :: Effect Unit
bits = do
  t "perturb-zero" (probe 0.0)
  t "NEGZERO-perturb-neg-zero" (probe (-0.0))
  t "perturb-one" (probe 1.0)
  t "perturb-neg-one" (probe (-1.0))
  t "perturb-two" (probe 2.0)
  t "perturb-half" (probe 0.5)
  t "perturb-third" (probe (1.0 / 3.0))
  t "perturb-pi" (probe 3.141592653589793)
  t "perturb-tiny" (probe 1.0e-40)
  t "perturb-huge" (probe 1.0e39)
  t "perturb-neg-huge" (probe (-1.0e39))
  t "perturb-inf" (probe (1.0 / 0.0))
  t "perturb-neg-inf" (probe (-1.0 / 0.0))
  t "perturb-nan" (probe (0.0 / 0.0))
  t "perturb-f32-max" (probe 3.4028234663852886e38)
  t "perturb-f32-min-normal" (probe 1.1754943508222875e-38)
  -- the unperturbed generator, as a control
  t "unperturbed" (show (evalGen (chooseInt 0 1000000)
                                 { newSeed: mkSeed 1234, size: 10 }))
  t "uniform" (show (evalGen uniform { newSeed: mkSeed 99, size: 10 }))

--------------------------------------------------------------------------
-- Effect.Random — diffable by contract, never by value
--------------------------------------------------------------------------

random :: Effect Unit
random = do
  -- In [0, 1). Drawn many times so a shim returning a constant, or one using
  -- an inclusive upper bound, shows up rather than getting lucky.
  inRange <- Ref.new true
  distinct <- Ref.new 0
  first <- Random.random
  for_ 120 \_ -> do
    x <- Random.random
    when (x < 0.0 || x >= 1.0) (Ref.write false inRange)
    when (x /= first) (Ref.modify_ (_ + 1) distinct)
  ok <- Ref.read inRange
  n <- Ref.read distinct
  t "random-in-range" (show ok)
  t "random-not-constant" (show (n > 110))

  -- randomInt is inclusive at BOTH ends, which is the easy thing to get wrong.
  intOk <- Ref.new true
  sawLo <- Ref.new false
  sawHi <- Ref.new false
  for_ 120 \_ -> do
    i <- Random.randomInt 1 4
    when (i < 1 || i > 4) (Ref.write false intOk)
    when (i == 1) (Ref.write true sawLo)
    when (i == 4) (Ref.write true sawHi)
  a <- Ref.read intOk
  b <- Ref.read sawLo
  c <- Ref.read sawHi
  t "randomInt-in-range" (show a)
  t "randomInt-hits-low" (show b)
  t "randomInt-hits-high" (show c)

  -- A degenerate range must still terminate and be exact.
  d <- Random.randomInt 7 7
  t "randomInt-degenerate" (show d)

  -- randomRange respects its bounds.
  rOk <- Ref.new true
  for_ 80 \_ -> do
    x <- Random.randomRange 2.5 3.5
    when (x < 2.5 || x >= 3.5) (Ref.write false rOk)
  e <- Ref.read rOk
  t "randomRange-in-range" (show e)

  -- randomBool must produce both.
  tt <- Ref.new false
  ff <- Ref.new false
  for_ 80 \_ -> do
    x <- Random.randomBool
    when x (Ref.write true tt)
    when (not x) (Ref.write true ff)
  g <- Ref.read tt
  h <- Ref.read ff
  t "randomBool-both" (show (g && h))

-- | A plain counted loop. `Data.Array.replicate` plus `traverse_` would pull
-- | a chunk of Data.Array into every backend's reachability set for no reason.
for_ :: Int -> (Int -> Effect Unit) -> Effect Unit
for_ n f = go 0
  where
  go i
    | i >= n = pure unit
    | otherwise = f i *> go (i + 1)
