-- | Coverage: Generic deriving + genericShow -- the ubiquitous real-world idiom.
-- | Exercises Data.Generic.Rep's Sum/Product/Constructor/Argument/NoArguments
-- | representation and the recursive-instance resolution genericShow needs.
module Test.Generic where

import Prelude

import Data.Generic.Rep (class Generic)
import Data.Show.Generic (genericShow)
import Effect (Effect)
import Effect.Console (log)

data Shape = Circle Int | Rect Int Int | Dot

derive instance Generic Shape _
instance Show Shape where
  show = genericShow

data Tree = Leaf Int | Branch Tree Tree

derive instance Generic Tree _
instance Show Tree where
  show x = genericShow x

t :: String -> String -> Effect Unit
t name v = log ("TEST " <> name <> ": " <> v)

main :: Effect Unit
main = do
  log "=== Test.Generic ==="
  t "circle" (show (Circle 5))
  t "rect" (show (Rect 3 4))
  t "dot" (show Dot)
  t "tree" (show (Branch (Leaf 1) (Branch (Leaf 2) (Leaf 3))))
  t "array-of" (show [ Circle 1, Dot, Rect 2 3 ])
