-- | Entry-point reachability over the optimized IR.
-- |
-- | LANGUAGE-NEUTRAL: this computes which top-level bindings are reachable from a
-- | program's entry point purely by graph-reachability over the IR's `Var`
-- | reference edges. There is nothing Go- (or Julia-, or Python-) specific here --
-- | it operates only on `BackendModule`/`NeutralExpr`. It is strictly more
-- | aggressive than the optimizer's whole-program DCE, which retains everything
-- | exported-and-referenced-by-any-module; an *entry* prune additionally discards
-- | exported-but-unused-by-THIS-program code (e.g. `Effect.Exception` dragged in
-- | transitively by `transformers` but never reached from a `State`-only `main`).
-- |
-- | This belongs upstream in `purescript-backend-optimizer` so every consumer
-- | (backend-es, purescm, Jurist, purepy, …) gets smaller builds and a smaller
-- | foreign surface for free. It lives here for now to land the backend-go MVP
-- | buildability win; lifting it upstream is a clean, mechanical move.
module PureScript.Backend.Optimizer.Reachability
  ( reachableFromEntry
  , pruneModule
  ) where

import Prelude

import Data.Array as Array
import Data.Foldable (foldMap)
import Data.List as List
import Data.Map (Map)
import Data.Map as Map
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Set (Set)
import Data.Set as Set
import Data.Tuple (Tuple(..))
import PureScript.Backend.Optimizer.Convert (BackendModule)
import PureScript.Backend.Optimizer.CoreFn (Ident, Qualified(..))
import PureScript.Backend.Optimizer.Semantics (NeutralExpr(..))
import PureScript.Backend.Optimizer.Syntax (BackendSyntax(..))

-- | The set of top-level bindings reachable from `entry`, across all modules.
-- | Nodes are module-qualified idents; edges are the `Var` references in each
-- | binding's body. Foreign idents and saturated-constructor tags create no
-- | edges (foreigns live in the runtime; `CtorSaturated` inlines its tag), which
-- | is exactly right -- they need no IR binding kept.
reachableFromEntry :: Qualified Ident -> Array BackendModule -> Set (Qualified Ident)
reachableFromEntry entry modules = bfs (Set.singleton entry) (List.singleton entry)
  where
  graph :: Map (Qualified Ident) (Set (Qualified Ident))
  graph = Map.fromFoldable do
    m <- modules
    grp <- m.bindings
    Tuple ident expr <- grp.bindings
    pure (Tuple (Qualified (Just m.name) ident) (collectVars expr))

  bfs seen = case _ of
    List.Nil -> seen
    List.Cons q rest ->
      let
        fresh = Set.filter (\r -> not (Set.member r seen))
          (fromMaybe Set.empty (Map.lookup q graph))
      in
        bfs (Set.union seen fresh) (List.fromFoldable fresh <> rest)

-- | All module-qualified `Var` references in an expression tree (recurses via the
-- | `Foldable`/`Functor` structure of `BackendSyntax`).
collectVars :: NeutralExpr -> Set (Qualified Ident)
collectVars (NeutralExpr syn) = here <> foldMap collectVars syn
  where
  here = case syn of
    Var q -> Set.singleton q
    _ -> Set.empty

-- | Drop every binding not in `reachable`. Returns `Nothing` if the module has no
-- | reachable bindings left (caller skips emitting it entirely). Reachability
-- | guarantees no dangling reference: a kept binding only references bindings that
-- | are themselves reachable.
pruneModule :: Set (Qualified Ident) -> BackendModule -> Maybe BackendModule
pruneModule reachable m =
  let
    groups = Array.mapMaybe pruneGroup m.bindings
  in
    if Array.null groups then Nothing
    else Just (m { bindings = groups })
  where
  pruneGroup grp =
    let
      kept = Array.filter (\(Tuple ident _) -> Set.member (Qualified (Just m.name) ident) reachable) grp.bindings
    in
      if Array.null kept then Nothing else Just (grp { bindings = kept })
