-- | Effect sequencing, Refs, the Effect loop combinators, and
-- | Effect.Uncurried round-trips.
module Test.Effects where

import Prelude

import Data.Array as A
import Effect (Effect, forE, whileE, foreachE)
import Effect.Console (log)
import Effect.Ref as Ref
import Effect.Uncurried (EffectFn2, mkEffectFn2, runEffectFn2)
import Effect.Unsafe (unsafePerformEffect)

t :: String -> String -> Effect Unit
t name v = log ("TEST " <> name <> ": " <> v)

addRef :: EffectFn2 Int Int Int
addRef = mkEffectFn2 \a b -> pure (a + b)

main :: Effect Unit
main = do
  log "=== Test.Effects ==="
  -- do-notation sequencing and pure
  x <- pure 5
  t "pure-bind" (show x)
  t "map-effect" (show (unsafePerformEffect (map (_ + 1) (pure 1))))
  t "apply-effect" (show (unsafePerformEffect ((+) <$> pure 1 <*> pure 2)))
  -- Refs
  r <- Ref.new 10
  v0 <- Ref.read r
  t "ref-read" (show v0)
  Ref.write 20 r
  v1 <- Ref.read r
  t "ref-write" (show v1)
  Ref.modify_ (_ + 5) r
  v2 <- Ref.read r
  t "ref-modify" (show v2)
  v3 <- Ref.modify' (\s -> { state: s * 2, value: s }) r
  v4 <- Ref.read r
  t "ref-modify-prime-value" (show v3)
  t "ref-modify-prime-state" (show v4)
  -- forE
  acc <- Ref.new 0
  forE 1 11 \i -> Ref.modify_ (_ + i) acc
  forSum <- Ref.read acc
  t "forE-sum" (show forSum)
  -- whileE
  c <- Ref.new 0
  whileE (map (_ < 50) (Ref.read c)) (Ref.modify_ (_ + 7) c)
  whileV <- Ref.read c
  t "whileE" (show whileV)
  -- foreachE
  items <- Ref.new []
  foreachE [ 3, 1, 2 ] \i -> Ref.modify_ (\xs -> A.snoc xs (i * 10)) items
  collected <- Ref.read items
  t "foreachE" (show collected)
  -- Effect.Uncurried round-trip
  s <- runEffectFn2 addRef 20 22
  t "effectfn2" (show s)
  -- nested do / let in do
  let y = x + 1
  z <- pure (y * 2)
  t "do-let" (show z)
  -- discard
  _ <- pure 99
  t "discard" "ok"
