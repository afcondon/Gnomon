-- | Typeclass dictionary dispatch: derived and chained instances,
-- | superclass access, monoids, records, and Bounded.
module Test.Dictionaries where

import Prelude

import Data.Enum (fromEnum)
import Data.Foldable (foldMap)
import Data.Int (odd)
import Data.List (List(..), (:))
import Data.List as L
import Data.Maybe (Maybe(..))
import Data.Monoid (power, guard)
import Data.Monoid.Additive (Additive(..))
import Data.Monoid.Conj (Conj(..))
import Data.Monoid.Disj (Disj(..))
import Data.Newtype (unwrap)
import Data.Ord (clamp, between)
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Console (log)

t :: String -> String -> Effect Unit
t name v = log ("TEST " <> name <> ": " <> v)

main :: Effect Unit
main = do
  log "=== Test.Dictionaries ==="
  -- Eq / Ord on compound structures (dictionary chains)
  t "eq-nested" (show (Just (Tuple 1 "a") == Just (Tuple 1 "a")))
  t "eq-nested-diff" (show (Just (Tuple 1 "a") == Just (Tuple 2 "a")))
  t "ord-array-lex" (show (compare [ 1, 2 ] [ 1, 3 ]))
  t "ord-array-len" (show (compare [ 1, 2 ] [ 1, 2, 0 ]))
  t "ord-tuple" (show (compare (Tuple 1 "b") (Tuple 1 "a")))
  t "min-max" (show (Tuple (min 3 5) (max 3 5)))
  t "clamp" (show (clamp 0 10 15))
  t "between" (show (between 0 10 5))
  -- Semigroup / Monoid
  t "monoid-string" ("a" <> mempty <> "b")
  t "monoid-array" (show ([ 1 ] <> mempty <> [ 2 ]))
  t "semigroup-maybe" (show (Just "a" <> Just "b"))
  t "semigroup-maybe-nothing" (show (Just "a" <> Nothing))
  t "monoid-additive" (show (unwrap (foldMap Additive [ 1, 2, 3 ])))
  t "monoid-conj" (show (unwrap (foldMap Conj [ true, true ])))
  t "monoid-disj" (show (unwrap (foldMap Disj [ false, true ])))
  t "monoid-power" (power "ab" 3)
  t "monoid-guard" (show (guard true "yes" :: String))
  t "monoid-guard-false" (show (guard false "yes" :: String))
  -- Functor / Apply / Bind across structures
  t "functor-maybe" (show (map (_ + 1) (Just 1)))
  t "apply-maybe" (show ((+) <$> Just 1 <*> Just 2))
  t "apply-maybe-nothing" (show ((+) <$> Just 1 <*> (Nothing :: Maybe Int)))
  t "bind-maybe" (show (Just 5 >>= \v -> Just (v * 2)))
  t "ado-maybe" (show (lift2 Tuple (Just 1) (Just "x")))
  t "functor-function" (show ((map (_ + 1) (_ * 2)) 5))
  t "compose" (show (((_ + 1) <<< (_ * 2)) 5))
  t "compose-flipped" (show (((_ + 1) >>> (_ * 2)) 5))
  -- List (pure-PS structure exercising dictionaries heavily)
  t "list-build" (show (1 : 2 : 3 : Nil))
  t "list-map" (show (map (_ * 2) (L.fromFoldable [ 1, 2, 3 ])))
  t "list-reverse" (show (L.reverse (L.fromFoldable [ 1, 2, 3 ])))
  t "list-length" (show (L.length (L.range 1 100)))
  t "list-filter" (show (L.filter odd (L.range 1 10)))
  t "list-toArray" (show (L.toUnfoldable (L.range 1 5) :: Array Int))
  -- Bounded
  t "bounded-int-top" (show (top :: Int))
  t "bounded-int-bottom" (show (bottom :: Int))
  t "bounded-char-bottom" (show (fromEnum (bottom :: Char)))
  t "bounded-boolean" (show (Tuple (top :: Boolean) (bottom :: Boolean)))
  -- HeytingAlgebra
  t "bool-and" (show (true && false))
  t "bool-or" (show (true || false))
  t "bool-not" (show (not true))
  -- Show for records
  t "show-record" (show { name: "Ada", age: 36 })
  t "show-nested-record" (show { p: { x: 1.5, y: 2.5 }, tag: "pt" })
  -- record update
  t "record-update" (show ((\r -> r { age = r.age + 1 }) { name: "Ada", age: 36 }))
  where
  lift2 f a b = f <$> a <*> b
