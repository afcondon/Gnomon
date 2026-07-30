-- | `Data.Map` and `Data.Set` — the standard-library lane.
-- |
-- | Added 2026-07-30. Until then no module in this corpus had imported
-- | `ordered-collections` on ANY backend, so the most-used container in the
-- | ecosystem had never been compiled here. It turned out not to work at all:
-- | `Data.Map.Internal.foldrWithIndex` miscompiled, and since the failure was
-- | in a module-level binding it killed any importing program before `main`.
-- | See `docs/RECURSIVE-LET-BINDING-ISSUE.md`.
-- |
-- | The point of this module is coverage of the *library*, not of `Map`'s
-- | algorithms — it is the balancing, folding and traversal code inside
-- | `ordered-collections` that exercises codegen paths nothing else reaches.
module Test.OrderedCollections where

import Prelude

import Data.Array as Array
import Data.Foldable (foldr, foldl, sum)
import Data.FoldableWithIndex (foldrWithIndex, foldlWithIndex)
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Set as Set
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Console (log)

t :: String -> String -> Effect Unit
t name v = log ("TEST " <> name <> ": " <> v)

pairs :: Array (Tuple String Int)
pairs =
  [ Tuple "delta" 4
  , Tuple "alpha" 1
  , Tuple "echo" 5
  , Tuple "bravo" 2
  , Tuple "charlie" 3
  ]

sample :: Map String Int
sample = Map.fromFoldable pairs

-- | Enough entries to force the size-balanced tree to rotate on insert and
-- | delete, so the balancing code actually runs.
wide :: Map Int Int
wide = Map.fromFoldable (map (\k -> Tuple k (k * k)) (Array.range 1 32))

main :: Effect Unit
main = do
  -- construction and lookup
  t "size" (show (Map.size sample))
  t "lookup-hit" (show (Map.lookup "charlie" sample))
  t "lookup-miss" (show (Map.lookup "foxtrot" sample))
  t "member" (show (Map.member "alpha" sample))

  -- ordered traversal — the reason a Map is worth having
  t "keys" (show (Array.fromFoldable (Map.keys sample)))
  t "values" (show (Array.fromFoldable (Map.values sample)))
  t "toUnfoldable" (show (Map.toUnfoldable sample :: Array (Tuple String Int)))

  -- insert / delete / update
  t "insert" (show (Map.toUnfoldable (Map.insert "foxtrot" 6 sample) :: Array (Tuple String Int)))
  t "insert-overwrite" (show (Map.lookup "alpha" (Map.insert "alpha" 99 sample)))
  t "delete" (show (Array.fromFoldable (Map.keys (Map.delete "charlie" sample))))
  t "delete-missing" (show (Map.size (Map.delete "foxtrot" sample)))
  t "alter-add" (show (Map.lookup "golf" (Map.alter (const (Just 7)) "golf" sample)))
  t "alter-remove" (show (Map.size (Map.alter (const Nothing) "alpha" sample)))
  t "update" (show (Map.lookup "bravo" (Map.update (\v -> Just (v * 10)) "bravo" sample)))

  -- folds, including the indexed folds that broke
  t "foldr" (show (foldr (+) 0 sample))
  t "foldl" (show (foldl (+) 0 sample))
  t "sum" (show (sum sample))
  t "foldrWithIndex" (show (foldrWithIndex (\k v acc -> k <> show v <> acc) "" sample))
  t "foldlWithIndex" (show (foldlWithIndex (\k acc v -> acc <> k <> show v) "" sample))
  t "functor" (show (Map.toUnfoldable (map (_ * 2) sample) :: Array (Tuple String Int)))

  -- combining
  t "union" (show (Array.fromFoldable (Map.keys (Map.union sample (Map.singleton "hotel" 8)))))
  t "union-left-biased" (show (Map.lookup "alpha" (Map.union sample (Map.singleton "alpha" 99))))
  t "intersectionWith"
    (show (Map.toUnfoldable (Map.intersectionWith (+) sample (Map.singleton "alpha" 10))
             :: Array (Tuple String Int)))
  t "difference" (show (Array.fromFoldable (Map.keys (Map.difference sample (Map.singleton "alpha" 0)))))
  t "empty" (show (Map.isEmpty (Map.empty :: Map String Int)))

  -- a tree big enough to have been rebalanced
  t "wide-size" (show (Map.size wide))
  t "wide-lookup" (show (Map.lookup 17 wide))
  t "wide-sum" (show (sum wide))
  t "wide-keys-after-deletes"
    (show (Array.fromFoldable (Map.keys (foldr Map.delete wide (Array.range 1 28)))))
  t "wide-findMin" (show (Map.findMin wide))
  t "wide-findMax" (show (Map.findMax wide))
  t "lookup-default" (show (fromMaybe 0 (Map.lookup 999 wide)))

  -- Data.Set rides on the same tree
  let s1 = Set.fromFoldable [ 5, 3, 1, 4, 1, 5, 9, 2, 6 ]
      s2 = Set.fromFoldable [ 2, 4, 6, 8 ]
  t "set-size" (show (Set.size s1))
  t "set-toArray" (show (Array.fromFoldable s1))
  t "set-member" (show (Set.member 9 s1))
  t "set-union" (show (Array.fromFoldable (Set.union s1 s2)))
  t "set-intersection" (show (Array.fromFoldable (Set.intersection s1 s2)))
  t "set-difference" (show (Array.fromFoldable (Set.difference s1 s2)))
  t "set-insert-delete" (show (Array.fromFoldable (Set.delete 9 (Set.insert 7 s1))))
  t "set-sum" (show (sum s1))
