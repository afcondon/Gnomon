-- | ADT construction, pattern matching, newtype erasure, derived instances.
module Test.ADTs where

import Prelude

import Data.Either (Either(..), either)
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.Newtype (class Newtype, unwrap, over)
import Data.Tuple (Tuple(..), fst, snd, swap)
import Effect (Effect)
import Effect.Console (log)

data Color = Red | Green | Blue

derive instance eqColor :: Eq Color
derive instance ordColor :: Ord Color

instance showColor :: Show Color where
  show = case _ of
    Red -> "Red"
    Green -> "Green"
    Blue -> "Blue"

data Shape
  = Circle Number
  | Rect Number Number
  | Tri Number Number Number

newtype Age = Age Int

derive instance newtypeAge :: Newtype Age _

data Tree = Leaf | Node Tree Int Tree

insert :: Int -> Tree -> Tree
insert x = case _ of
  Leaf -> Node Leaf x Leaf
  Node l v r
    | x < v -> Node (insert x l) v r
    | x > v -> Node l v (insert x r)
    | otherwise -> Node l v r

inorder :: Tree -> Array Int
inorder = case _ of
  Leaf -> []
  Node l v r -> inorder l <> [ v ] <> inorder r

area :: Shape -> Number
area = case _ of
  Circle r -> 3.14159265 * r * r
  Rect w h -> w * h
  Tri a b c ->
    let s = (a + b + c) / 2.0
    in s * (s - a) * (s - b) * (s - c)

classify :: Shape -> String
classify s
  | area s > 100.0 = "large"
  | area s > 10.0 = "medium"
  | otherwise = "small"

t :: String -> String -> Effect Unit
t name v = log ("TEST " <> name <> ": " <> v)

main :: Effect Unit
main = do
  log "=== Test.ADTs ==="
  t "show-nullary" (show Red)
  t "eq-same" (show (Red == Red))
  t "eq-diff" (show (Red == Blue))
  t "ord-lt" (show (compare Red Blue))
  t "ord-gt" (show (compare Blue Green))
  t "ord-eq" (show (compare Green Green))
  t "max-color" (show (max Red Blue))
  t "area-circle" (show (area (Circle 2.0)))
  t "area-rect" (show (area (Rect 3.0 4.0)))
  t "classify-small" (classify (Circle 1.0))
  t "classify-medium" (classify (Rect 4.0 4.0))
  t "classify-large" (classify (Rect 20.0 20.0))
  t "newtype-unwrap" (show (unwrap (Age 41)))
  t "newtype-over" (show (unwrap (over Age (_ + 1) (Age 41) :: Age)))
  t "maybe-just" (show (Just 5))
  t "maybe-nothing" (show (Nothing :: Maybe Int))
  t "maybe-map" (show (map (_ * 2) (Just 21)))
  t "maybe-fromMaybe" (show (fromMaybe 0 (Just 7)))
  t "maybe-fold" (maybe "none" show (Just 3))
  t "either-left" (show (Left 1 :: Either Int String))
  t "either-right" (show (Right "ok" :: Either Int String))
  t "either-fold" (either show identity (Right "yes" :: Either Int String))
  t "either-map" (show (map (_ + 1) (Right 1 :: Either String Int)))
  t "tuple-show" (show (Tuple 1 "a"))
  t "tuple-fst" (show (fst (Tuple 1 "a")))
  t "tuple-snd" (snd (Tuple 1 "a"))
  t "tuple-swap" (show (swap (Tuple 1 "a")))
  t "nested-maybe" (show (Just (Tuple (Just 1) (Nothing :: Maybe Int))))
  t "tree-inorder" (show (inorder (insert 2 (insert 3 (insert 1 (insert 2 Leaf))))))
  t "eq-array-adt" (show ([ Red, Green ] == [ Red, Green ]))
  t "ord-maybe" (show (compare (Just 1) (Just 2)))
  t "ord-nothing" (show (compare Nothing (Just 1)))
