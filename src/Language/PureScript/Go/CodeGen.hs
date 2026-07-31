{-# LANGUAGE OverloadedStrings #-}

-- |
-- CoreFn -> Go code generation, STATEMENT-FORM, via the Go AST.
--
-- This is the pivot from the Julia/Python family emitter. Julia/Python compile
-- every CoreFn expression to ONE target expression (ternary chains, walrus
-- IIFEs). Go has no ternary, no expression-if, statement-bodied closures, and
-- static typing, so we emit to a structured Go AST (GoExpr/GoStmt/GoDecl,
-- grafted in shape from purerl) and pretty-print + gofmt it.
--
-- Statement scope inside an expression is handled by a zero-arg IIFE
-- (@func() any { ... }()@), Go's analogue of Julia's @begin...end@ IIFE.
--
-- Runtime representation (ADR 0001):
--   * Functions: curried unary closures @func(x any) any { return ... }@;
--     application is @f.(func(any) any)(x)@.
--   * ADT values: @V{Tag:"Just", Fields:[]any{x}}@. Constructors are curried
--     closures building a V. Nullary ctors are a bare V value.
--   * Newtype constructors: identity closure.
--   * Typeclass dicts / records: @map[string]any@.
--   * Arrays: @[]any@. Effects: @func() any@ thunks. Unit/undefined: nil.
--
-- Spike scope: Literal, Var, App, Abs, Case, Let, Accessor, ObjectUpdate,
-- Constructor. TCO trampoline (ADR 0003) and the Unused pass are deferred --
-- noted where they would attach.
--
module Language.PureScript.Go.CodeGen
  ( generateModule
  ) where

import Prelude

import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T

import qualified Language.PureScript as P
import qualified Language.PureScript.CoreFn as CoreFn
import Language.PureScript.PSString (PSString, decodeString)

import Language.PureScript.Go.CodeGen.AST
import Language.PureScript.Go.CodeGen.Common
import qualified Language.PureScript.Go.CodeGen.Pretty as Pretty

-- | Generate the top-level Go declarations for one module.
generateModule :: CoreFn.Module CoreFn.Ann -> [GoDecl]
generateModule cfModule = concatMap generateBind (CoreFn.moduleDecls cfModule)
  where
    currentModule :: P.ModuleName
    currentModule = CoreFn.moduleName cfModule

    currentModuleText :: Text
    currentModuleText = case currentModule of P.ModuleName mn -> mn

    -- One top-level binding -> one var decl (flat package, mangled name).
    -- NB: TCO trampoline (ADR 0003) and smart Rec lazy-thunk partitioning
    -- attach here; deferred for the spike. Rec is treated as a list of vars
    -- (Go allows forward refs within a package; true value-cycles would need
    -- the lazy-thunk helper -- not exercised by the spike modules).
    generateBind :: CoreFn.Bind CoreFn.Ann -> [GoDecl]
    generateBind (CoreFn.NonRec _ ident expr) =
      [ GoVarDecl (goTopName currentModule ident) (genExpr expr) ]
    generateBind (CoreFn.Rec bindings) =
      [ GoVarDecl (goTopName currentModule ident) (genExpr expr)
      | ((_, ident), expr) <- bindings ]

    -- | CoreFn expression -> GoExpr.
    genExpr :: CoreFn.Expr CoreFn.Ann -> GoExpr
    genExpr = \case
      CoreFn.Literal _ lit -> genLiteral lit

      -- Prim.undefined -> nil
      CoreFn.Var _ (P.Qualified (P.ByModuleName (P.ModuleName "Prim")) (P.Ident "undefined")) ->
        GoNil

      CoreFn.Var _ qi -> genVar qi

      CoreFn.Abs _ arg body ->
        GoClosure (identToGoName arg) [ GoReturn (genExpr body) ]

      CoreFn.App _ fn arg ->
        GoCurriedApp (genExpr fn) (genExpr arg)

      CoreFn.Let _ binds body ->
        GoIIFE (genLetGroup binds body ++ [ GoReturn (genExpr body) ])

      CoreFn.Case _ scruts alts ->
        genCase scruts alts

      CoreFn.Accessor _ field expr ->
        GoMapIndex (genExpr expr) (psKey field)

      CoreFn.ObjectUpdate _ expr _ updates ->
        -- copy-merge: build a fresh map, copy the old, overwrite. Emitted as
        -- an IIFE so it is statement-form (Go has no map-literal spread).
        let base = genExpr expr
            copyStmts =
              [ GoAssign "_m" (GoRaw "map[string]any{}")
              , GoRawStmt ("for _k, _v := range (" <> prettyOf base <> ").(map[string]any) { _m[_k] = _v }")
              ] ++
              [ GoRawStmt ("_m[\"" <> psKey k <> "\"] = " <> prettyOf (genExpr v))
              | (k, v) <- updates ] ++
              [ GoReturn (GoVar "_m") ]
        in GoIIFE copyStmts

      CoreFn.Constructor ann _ (P.ProperName ctor) fields ->
        genConstructor ann ctor fields

    -- | Constructors.
    genConstructor :: CoreFn.Ann -> Text -> [P.Ident] -> GoExpr
    genConstructor ann ctor fields = case ann of
      -- Newtype: identity closure.
      (_, _, Just CoreFn.IsNewtype) ->
        GoClosure "_x" [ GoReturn (GoVar "_x") ]
      -- Typeclass dictionary: curried builder of a map[string]any.
      (_, _, Just CoreFn.IsTypeClassConstructor) ->
        let dict = GoMapLit [ (runIdent' f, GoVar (identToGoName f)) | f <- fields ]
        in curriedOver fields dict
      -- Data constructor: curried builder of a V tag-struct.
      _ ->
        let adt = GoADT (escapeGoString ctor) [ GoVar (identToGoName f) | f <- fields ]
        in curriedOver fields adt

    -- | Wrap a body in N curried unary closures, one per field/param.
    curriedOver :: [P.Ident] -> GoExpr -> GoExpr
    curriedOver fields body =
      foldr (\f acc -> GoClosure (identToGoName f) [ GoReturn acc ]) body fields

    -- | Let bindings -> statements. Local recursion via closure capture
    -- (Go closures capture by reference). TCO for local @go@ deferred.
    -- | A whole @let@ group. Each binding is emitted knowing what can still
    -- refer to it: every LATER binding's right-hand side, plus the let body.
    -- (A binding is routinely used only by its successor, never by the body —
    -- scoping by body alone would wrongly drop it.)
    genLetGroup :: [CoreFn.Bind CoreFn.Ann] -> CoreFn.Expr CoreFn.Ann -> [GoStmt]
    genLetGroup binds body = concat (zipWith genLetBind laterUses binds)
      where
        laterUses =
          [ Set.unions (usedIdents body : map bindUsedIdents (drop (i + 1) binds))
          | i <- [0 .. length binds - 1] ]

    genLetBind :: Set P.Ident -> CoreFn.Bind CoreFn.Ann -> [GoStmt]
    genLetBind used (CoreFn.NonRec _ ident expr)
      -- Unused let binding: Go rejects the declaration, but the RHS must STILL
      -- be evaluated — the JS reference evaluates it, so a divergent or
      -- throwing RHS has to diverge or throw here too. Assigning to the blank
      -- identifier keeps the evaluation and drops the binding. (Unlike a
      -- pattern binder, a let RHS is an arbitrary expression, so deleting it
      -- outright would not be semantics-preserving.)
      | not (ident `Set.member` used) =
          [ GoRawStmt ("_ = " <> prettyOf (genExpr expr)) ]
      -- `var x any = ...`, not `x := ...`: forces interface type so a later
      -- `x.(func(any) any)(arg)` works even when the RHS is a closure literal.
      | otherwise = [ GoVarDef (identToGoName ident) (genExpr expr) ]
    genLetBind _ (CoreFn.Rec bindings) =
      -- Declare-then-assign so self/mutual refs resolve (Go := would not allow
      -- forward ref within a block). Use var + reassign.
      [ GoRawStmt ("var " <> identToGoName ident <> " any") | ((_, ident), _) <- bindings ] ++
      [ GoRawStmt (identToGoName ident <> " = " <> prettyOf (genExpr expr))
      | ((_, ident), expr) <- bindings ]

    -- | Case -> an IIFE whose body is a sequence of @if cond { return ... }@,
    -- one per alternative, ending in a panic (pattern-match failure).
    -- This is the statement-form replacement for Julia's ternary chain.
    genCase :: [CoreFn.Expr CoreFn.Ann] -> [CoreFn.CaseAlternative CoreFn.Ann] -> GoExpr
    genCase scruts alts =
      let roots = [ GoVar ("_v" <> tshow i) | i <- [0 .. length scruts - 1] ]
          altStmts = concatMap (genAlt roots) alts
          -- A scrutinee no pattern actually needs must NOT be bound: Go treats
          -- an unused local as a compile error. Decided STRUCTURALLY over the
          -- CoreFn binders (`rootLive`) rather than by scanning rendered Go for
          -- a `_v<i>` token — the scan is blind to scope, so a nested case
          -- reusing `_v0` kept the outer root alive (test `Guards`).
          --
          -- Dropping is semantics-preserving because a scrutinee whose root is
          -- dead is one that no alternative tests or binds, and CoreFn case
          -- scrutinees are pure. `usedIdents` applies the SAME predicate, so a
          -- let binding that only fed a dead root goes dead too (test `3388`) —
          -- that is the fixpoint, obtained by agreeing on one liveness rule
          -- instead of iterating.
          scrutBindings =
            [ GoAssign ("_v" <> tshow i) (genExpr e)
            | (i, e) <- zip [0 :: Int ..] scruts
            , rootLive i alts ]
          failStmt = GoPanic ("Pattern match failed in module " <> escapeGoString currentModuleText)
      in GoIIFE (scrutBindings ++ altStmts ++ [ failStmt ])

    -- | One alternative -> an @if cond { binders; return body }@ block.
    genAlt :: [GoExpr] -> CoreFn.CaseAlternative CoreFn.Ann -> [GoStmt]
    genAlt roots alt@(CoreFn.CaseAlternative binders result) =
      let patResults = zipWith genPattern roots binders
          conds = concatMap fst patResults
          -- Drop pattern binders the alternative never references: Go rejects an
          -- unused local outright. Safe to DELETE rather than blank-assign,
          -- because a pattern bind's RHS is always a pure projection out of an
          -- already-evaluated scrutinee (`_v0`, `_v1.(V).Fields[0]`) guarded by
          -- the tag check that precedes it — no effect, no panic, to preserve.
          used = Set.map identToGoName (altUsedIdents alt)
          binds = [ s | s <- concatMap snd patResults, goBindUsed used s ]
          bodyStmts = case result of
            Right body -> binds ++ [ GoReturn (genExpr body) ]
            Left guards ->
              binds ++
              [ GoIf (asBool (genExpr g)) [ GoReturn (genExpr b) ] | (g, b) <- guards ]
          cond = andAll conds
      in case cond of
           -- Unconditional alt: wrap in a block so its pattern binders are
           -- scoped to this alternative. Without the block, two equational
           -- clauses binding the same names (e.g. `splitAt n xs | n < 1 = ..;
           -- splitAt n xs = ..`) both emit `n := ..; xs := ..` into the shared
           -- IIFE block -> Go's "no new variables on left side of :=". If a
           -- guarded body falls through (no guard matched) execution continues
           -- to the next alt's block, preserving the fall-through model.
           Nothing -> [ GoBlockStmt bodyStmts ]
           Just c  -> [ GoIf c bodyStmts ]

    -- | Pattern -> (conditions, binding statements) against a scrutinee expr.
    genPattern :: GoExpr -> CoreFn.Binder CoreFn.Ann -> ([GoExpr], [GoStmt])
    genPattern scrut = \case
      CoreFn.NullBinder _ -> ([], [])
      CoreFn.VarBinder _ ident ->
        ([], [ GoAssign (identToGoName ident) scrut ])
      CoreFn.LiteralBinder _ lit -> genLitPattern scrut lit
      CoreFn.ConstructorBinder ann _ (P.Qualified _ (P.ProperName ctorName)) subBinders ->
        case ann of
          (_, _, Just CoreFn.IsNewtype) ->
            case subBinders of
              [inner] -> genPattern scrut inner
              _ -> ([], [])
          _ ->
            -- tag check + recurse into Fields[i]
            let tagCheck = GoBinary "==" (GoRaw (prettyOf scrut <> ".(V).Tag"))
                                         (GoString (escapeGoString ctorName))
                fieldOf i = GoRaw (prettyOf scrut <> ".(V).Fields[" <> tshow i <> "]")
                subResults = zipWith (\i b -> genPattern (fieldOf i) b) [0 :: Int ..] subBinders
                subConds = concatMap fst subResults
                subBinds = concatMap snd subResults
            in (tagCheck : subConds, subBinds)
      CoreFn.NamedBinder _ ident inner ->
        let (c, b) = genPattern scrut inner
        in (c, GoAssign (identToGoName ident) scrut : b)

    genLitPattern :: GoExpr -> CoreFn.Literal (CoreFn.Binder CoreFn.Ann) -> ([GoExpr], [GoStmt])
    genLitPattern scrut = \case
      CoreFn.NumericLiteral (Left n)  -> ([ GoBinary "==" scrut (GoInt n) ], [])
      CoreFn.NumericLiteral (Right n) -> ([ GoBinary "==" scrut (GoFloat n) ], [])
      CoreFn.StringLiteral s          -> ([ GoBinary "==" scrut (GoString (psStringToText s)) ], [])
      CoreFn.CharLiteral c            -> ([ GoBinary "==" scrut (GoString (escapeGoString (T.singleton c))) ], [])
      CoreFn.BooleanLiteral b         -> ([ GoBinary "==" scrut (GoBool b) ], [])
      CoreFn.ArrayLiteral binders ->
        let lenCheck = GoBinary "=="
                         (GoRaw ("len(" <> prettyOf scrut <> ".([]any))"))
                         (GoInt (fromIntegral (length binders)))
            elemOf i = GoSliceIndex scrut (GoInt (fromIntegral i))
            sub = zipWith (\i b -> genPattern (elemOf i) b) [0 :: Int ..] binders
        in (lenCheck : concatMap fst sub, concatMap snd sub)
      CoreFn.ObjectLiteral fields ->
        let sub = [ genPattern (GoMapIndex scrut (psKey k)) b | (k, b) <- fields ]
        in (concatMap fst sub, concatMap snd sub)

    genLiteral :: CoreFn.Literal (CoreFn.Expr CoreFn.Ann) -> GoExpr
    genLiteral = \case
      CoreFn.NumericLiteral (Left n)  -> GoInt n
      CoreFn.NumericLiteral (Right n) -> GoFloat n
      CoreFn.StringLiteral s          -> GoString (psStringToText s)
      CoreFn.CharLiteral c            -> GoString (escapeGoString (T.singleton c))
      CoreFn.BooleanLiteral b         -> GoBool b
      CoreFn.ArrayLiteral exprs       -> GoSliceLit (map genExpr exprs)
      CoreFn.ObjectLiteral fields     -> GoMapLit [ (psKey k, genExpr v) | (k, v) <- fields ]

    -- | A Var: same-module refs use the mangled flat-package name; foreign-
    -- module refs use the same flat name (all modules live in one package).
    genVar :: P.Qualified P.Ident -> GoExpr
    genVar (P.Qualified qb ident) = case qb of
      P.ByModuleName mn -> GoVar (goTopName mn ident)
      P.BySourcePos _   -> GoVar (identToGoName ident)

    psKey :: PSString -> Text
    psKey s = case decodeString s of
      Just str -> escapeGoString str
      Nothing  -> psStringToText s

-- | Combine conditions with &&; Nothing means "always true".
andAll :: [GoExpr] -> Maybe GoExpr
andAll [] = Nothing
andAll (c:cs) = Just (foldl (GoBinary "&&") c cs)

-- | A guard expression has PureScript type @Boolean@ but is emitted as an
-- @any@-typed Go value (a Var or curried application); Go's @if@ needs a real
-- @bool@, so assert it. A bare boolean literal is already a Go bool.
asBool :: GoExpr -> GoExpr
asBool e@(GoBool _) = e
asBool e            = GoRaw (prettyOf e <> ".(bool)")

tshow :: Show a => a -> Text
tshow = T.pack . show

-- | Render a GoExpr to text for the GoRaw escape hatches above.
prettyOf :: GoExpr -> Text
prettyOf = Pretty.prettyExpr

-- | Every LOCAL identifier referenced anywhere in an expression.
--
-- This is the Unused pass's oracle (ADR-0003 deferred it; Gate B4 forced it).
-- Go rejects an unused local with "declared and not used", so a pattern binder
-- or let binding the body never mentions is a COMPILE ERROR, not a warning.
--
-- Deliberately IGNORES SHADOWING and so over-approximates: an inner binding
-- that reuses a name still counts as a reference to the outer one. That errs in
-- the only safe direction — a retained-but-unused binder reproduces today's
-- error (no regression), whereas a dropped-but-used binder would be a
-- miscompile. Module-qualified refs are top-level and never locals, so they are
-- skipped.
usedIdents :: CoreFn.Expr CoreFn.Ann -> Set P.Ident
usedIdents = go
  where
    go :: CoreFn.Expr CoreFn.Ann -> Set P.Ident
    go = \case
      CoreFn.Var _ (P.Qualified (P.BySourcePos _) ident) -> Set.singleton ident
      CoreFn.Var _ _ -> Set.empty
      CoreFn.Literal _ lit -> goLit lit
      CoreFn.Constructor{} -> Set.empty
      CoreFn.Accessor _ _ e -> go e
      CoreFn.ObjectUpdate _ e _ fs -> Set.union (go e) (Set.unions (map (go . snd) fs))
      CoreFn.Abs _ _ body -> go body
      CoreFn.App _ f a -> Set.union (go f) (go a)
      -- Only a LIVE scrutinee counts as a use of the names inside it: an
      -- alternative that neither tests nor binds position i means scrutinee i
      -- is never emitted, so whatever it referenced may itself be dead. Same
      -- predicate genCase uses, which is what makes the two agree.
      CoreFn.Case _ scruts alts ->
        Set.unions
          ( [ go e | (i, e) <- zip [0 :: Int ..] scruts, rootLive i alts ]
            ++ map goAlt alts )
      CoreFn.Let _ binds body ->
        Set.unions (go body : map goBind binds)

    goAlt :: CoreFn.CaseAlternative CoreFn.Ann -> Set P.Ident
    goAlt (CoreFn.CaseAlternative _ result) = case result of
      Right body -> go body
      Left guards -> Set.unions [ Set.union (go g) (go b) | (g, b) <- guards ]

    goBind :: CoreFn.Bind CoreFn.Ann -> Set P.Ident
    goBind (CoreFn.NonRec _ _ e) = go e
    goBind (CoreFn.Rec bs) = Set.unions [ go e | (_, e) <- bs ]

    goLit :: CoreFn.Literal (CoreFn.Expr CoreFn.Ann) -> Set P.Ident
    goLit = \case
      CoreFn.ArrayLiteral es -> Set.unions (map go es)
      CoreFn.ObjectLiteral fs -> Set.unions (map (go . snd) fs)
      _ -> Set.empty

-- | Keep a pattern-binder statement only if its bound Go name is referenced.
-- Anything that is not a plain binder assignment is always kept.
goBindUsed :: Set Text -> GoStmt -> Bool
goBindUsed used = \case
  GoAssign n _ -> n `Set.member` used
  _            -> True

-- | Does a binder still NEED its scrutinee once unused binds are dropped?
--
-- True iff it tests the value (any condition is emitted) or binds a name the
-- alternative actually uses. This is the structural replacement for scanning
-- rendered Go for a @_v<i>@ token: the text scan cannot see scope, so a NESTED
-- case reusing @_v0@ made the OUTER root look live (test `Guards`).
binderLive :: Set P.Ident -> CoreFn.Binder CoreFn.Ann -> Bool
binderLive used = \case
  CoreFn.NullBinder _ -> False
  CoreFn.VarBinder _ ident -> ident `Set.member` used
  CoreFn.NamedBinder _ ident inner ->
    ident `Set.member` used || binderLive used inner
  CoreFn.ConstructorBinder ann _ _ subs -> case ann of
    -- A newtype ctor emits no tag check — it is erased to its inner binder.
    (_, _, Just CoreFn.IsNewtype) -> any (binderLive used) subs
    _ -> True  -- the tag check is a real condition
  CoreFn.LiteralBinder _ lit -> litBinderLive used lit

-- | Record patterns emit NO condition (only field projections), so a record
-- pattern binding nothing used is entirely dead — that is test `3388`, where
-- `let { a, b } = x { a = 43 }` with `a`/`b` unused leaves the scrutinee dead.
-- Every other literal binder emits an equality or length check.
litBinderLive :: Set P.Ident -> CoreFn.Literal (CoreFn.Binder CoreFn.Ann) -> Bool
litBinderLive used = \case
  CoreFn.ObjectLiteral fields -> any (binderLive used . snd) fields
  _ -> True

-- | Is scrutinee root @i@ needed by any alternative?
rootLive :: Int -> [CoreFn.CaseAlternative CoreFn.Ann] -> Bool
rootLive i alts = any live alts
  where
    live alt@(CoreFn.CaseAlternative binders _) =
      case drop i binders of
        (b : _) -> binderLive (altUsedIdents alt) b
        []      -> False

-- | The identifiers referenced by a bind group's right-hand sides.
bindUsedIdents :: CoreFn.Bind CoreFn.Ann -> Set P.Ident
bindUsedIdents (CoreFn.NonRec _ _ e) = usedIdents e
bindUsedIdents (CoreFn.Rec bs) = Set.unions [ usedIdents e | (_, e) <- bs ]

-- | The identifiers an alternative's RESULT (body, or all its guards) uses.
altUsedIdents :: CoreFn.CaseAlternative CoreFn.Ann -> Set P.Ident
altUsedIdents (CoreFn.CaseAlternative _ result) = case result of
  Right body -> usedIdents body
  Left guards -> Set.unions [ Set.union (usedIdents g) (usedIdents b) | (g, b) <- guards ]
