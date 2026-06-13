-- | Coverage: Data.Map / Data.Set (ordered-collections) -- balanced-tree
-- | insert/delete/lookup/union and Ord-dictionary-driven ordering. The library
-- | is PureScript, so JS and Go run the SAME tree algorithm; output must match
-- | byte-for-byte (deterministic key order).
module Test.Maps where

import Prelude

import Data.Foldable (sum)
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Set as Set
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Console (log)

t :: String -> String -> Effect Unit
t name v = log ("TEST " <> name <> ": " <> v)

m0 :: Map.Map String Int
m0 = Map.fromFoldable [ Tuple "c" 3, Tuple "a" 1, Tuple "b" 2 ]

main :: Effect Unit
main = do
  log "=== Test.Maps ==="
  t "lookup-hit" (show (Map.lookup "b" m0))
  t "lookup-miss" (show (Map.lookup "z" m0))
  t "insert" (show (Map.lookup "d" (Map.insert "d" 4 m0)))
  t "delete-size" (show (Map.size (Map.delete "a" m0)))
  t "size" (show (Map.size m0))
  t "member" (show (Map.member "c" m0))
  t "values-sum" (show (sum (Map.values m0)))
  t "toUnfoldable-ordered" (show (Map.toUnfoldable m0 :: Array (Tuple String Int)))
  t "union-size" (show (Map.size (Map.union m0 (Map.singleton "x" 9))))
  t "insertWith" (show (Map.lookup "a" (Map.insertWith (+) "a" 10 m0)))
  -- Set
  let s0 = Set.fromFoldable [ 3, 1, 2, 3, 1 ]
  t "set-size" (show (Set.size s0))
  t "set-member" (show (Set.member 2 s0))
  t "set-toArray-ordered" (show (Set.toUnfoldable s0 :: Array Int))
  t "set-insert" (show (Set.size (Set.insert 5 s0)))
  t "set-union" (show (Set.toUnfoldable (Set.union s0 (Set.fromFoldable [ 4, 5 ])) :: Array Int))
