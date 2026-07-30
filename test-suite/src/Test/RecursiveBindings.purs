-- | Recursive LOCAL bindings, across the shapes that take different codegen
-- | paths.
-- |
-- | Added 2026-07-30 after `Data.Map` turned out to be unusable on the Python
-- | backend. The corpus already had `Test.Recursion`, and it passed — because
-- | every recursion in it is either top-level (a module-global name, late-bound
-- | in every target) or tail-recursive (eliminated by the TCO transform before
-- | codegen sees it). Neither exercises the path that breaks.
-- |
-- | The distinction that matters is not "does it recurse" but "how does the
-- | self-reference reach the body":
-- |
-- |   * free variable in an inline closure  -> late-bound, fine everywhere
-- |   * explicit captured argument after
-- |     the body is lambda-lifted           -> must be bound BEFORE the
-- |                                            right-hand side is evaluated
-- |
-- | A container fold is the ordinary way to land in the second case, which is
-- | why `Data.Map.Internal.foldrWithIndex` found it and nothing here did.
module Test.RecursiveBindings where

import Prelude

import Data.Function.Uncurried (Fn2, mkFn2, runFn2)
import Effect (Effect)
import Effect.Console (log)

t :: String -> String -> Effect Unit
t label value = log ("TEST " <> label <> ": " <> value)

data Tree = Leaf | Node Tree Int Tree

sample :: Tree
sample = Node (Node Leaf 1 Leaf) 2 (Node Leaf 3 Leaf)

-- | Local, non-tail, body simple enough to stay inline. The self-reference is
-- | a free variable in a closure, so ordinary lexical scoping handles it.
factLocal :: Int -> Int
factLocal n0 = go n0
  where
  go k = if k <= 1 then 1 else k * go (k - 1)

-- | Local, non-tail, uncurried, and a constructor case in the body — enough
-- | for the body to be lifted. This is the exact shape of
-- | `Data.Map.Internal`'s `go`, and recursing in two positions means TCO
-- | cannot rescue it.
sumTree :: Tree -> Int
sumTree t0 = runFn2 go t0 0
  where
  go :: Fn2 Tree Int Int
  go = mkFn2 \node acc -> case node of
    Leaf -> acc
    Node l v r -> runFn2 go l (v + runFn2 go r acc)

-- | Mutually recursive local bindings — the same knot with two names.
evenOddLocal :: Int -> Boolean
evenOddLocal n0 = isEven n0
  where
  isEven k = if k == 0 then true else isOdd (k - 1)
  isOdd k = if k == 0 then false else isEven (k - 1)

main :: Effect Unit
main = do
  t "factLocal" (show (factLocal 5))
  t "sumTree" (show (sumTree sample))
  t "evenOddLocal" (show (evenOddLocal 10))
