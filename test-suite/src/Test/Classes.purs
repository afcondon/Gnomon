-- | Coverage: idiomatic typeclass-driven code -- Maybe/Either monads, Traversable,
-- | a user-defined class + instances (incl. a superclass + a parametric instance),
-- | and Functor/Apply/Bind chains. This is the shape of real PureScript the narrow
-- | corpus didn't exercise.
module Test.Classes where

import Prelude

import Data.Either (Either(..), either)
import Data.Foldable (foldr, sum)
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.Traversable (traverse, sequence)
import Effect (Effect)
import Effect.Console (log)

t :: String -> String -> Effect Unit
t name v = log ("TEST " <> name <> ": " <> v)

-- user class with a default-ish method built on the primitive one
class Describe a where
  describe :: a -> String

data Colour = Red | Green | Blue

instance Describe Colour where
  describe = case _ of
    Red -> "red"
    Green -> "green"
    Blue -> "blue"

-- parametric instance (uses the element instance)
instance Describe a => Describe (Array a) where
  describe xs = "[" <> foldr (\x acc -> describe x <> acc) "]" xs

-- Maybe/Either monadic plumbing
safeDiv :: Int -> Int -> Maybe Int
safeDiv _ 0 = Nothing
safeDiv a b = Just (a / b)

chain :: Int -> Maybe Int
chain n = do
  a <- safeDiv 100 n
  b <- safeDiv a 2
  pure (a + b)

parsePos :: Int -> Either String Int
parsePos n
  | n > 0 = Right n
  | otherwise = Left ("not positive: " <> show n)

main :: Effect Unit
main = do
  log "=== Test.Classes ==="
  t "describe-colour" (describe Green)
  t "describe-array" (describe [ Red, Blue, Green ])
  t "maybe-chain-ok" (show (chain 5))
  t "maybe-chain-zero" (show (chain 0))
  t "fromMaybe" (show (fromMaybe (-1) (chain 0)))
  t "maybe-fold" (maybe "none" show (chain 4))
  t "either-right" (either ("L:" <> _) show (parsePos 7))
  t "either-left" (either ("L:" <> _) show (parsePos (-3)))
  t "traverse-ok" (show (traverse (safeDiv 12) [ 1, 2, 3 ]))
  t "traverse-fail" (show (traverse (safeDiv 12) [ 1, 0, 3 ]))
  t "sequence" (show (sequence [ Just 1, Just 2, Just 3 ]))
  t "sequence-fail" (show (sequence [ Just 1, Nothing, Just 3 ]))
  t "functor-map" (show (map (_ + 1) (Just 41)))
  t "apply" (show ((+) <$> Just 1 <*> Just 2))
  t "sum-array" (show (sum [ 1, 2, 3, 4, 5 ]))
