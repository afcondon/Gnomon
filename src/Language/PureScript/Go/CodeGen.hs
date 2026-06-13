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
        GoIIFE (concatMap genLetBind binds ++ [ GoReturn (genExpr body) ])

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
    genLetBind :: CoreFn.Bind CoreFn.Ann -> [GoStmt]
    genLetBind (CoreFn.NonRec _ ident expr) =
      -- `var x any = ...`, not `x := ...`: forces interface type so a later
      -- `x.(func(any) any)(arg)` works even when the RHS is a closure literal.
      [ GoVarDef (identToGoName ident) (genExpr expr) ]
    genLetBind (CoreFn.Rec bindings) =
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
          -- A scrutinee that no pattern actually references must NOT be bound:
          -- Go treats an unused `:=` local as a compile error. Scrutinees are
          -- pure CoreFn expressions, so dropping an unreferenced binding is
          -- semantics-preserving. (Minimal inline form of the Unused pass.)
          altText = T.concat (map prettyStmtOf altStmts)
          scrutBindings =
            [ GoAssign ("_v" <> tshow i) (genExpr e)
            | (i, e) <- zip [0 :: Int ..] scruts
            , rootUsed i altText ]
          failStmt = GoPanic ("Pattern match failed in module " <> escapeGoString currentModuleText)
      in GoIIFE (scrutBindings ++ altStmts ++ [ failStmt ])

    -- | One alternative -> an @if cond { binders; return body }@ block.
    genAlt :: [GoExpr] -> CoreFn.CaseAlternative CoreFn.Ann -> [GoStmt]
    genAlt roots (CoreFn.CaseAlternative binders result) =
      let patResults = zipWith genPattern roots binders
          conds = concatMap fst patResults
          binds = concatMap snd patResults
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

-- | Render a GoStmt to text (used to scan for scrutinee-root usage).
prettyStmtOf :: GoStmt -> Text
prettyStmtOf = Pretty.prettyStmt

-- | Does scrutinee root @_v<i>@ appear in the rendered alternatives? Matches
-- the exact token (not followed by a digit, so @_v1@ does not match @_v10@).
rootUsed :: Int -> Text -> Bool
rootUsed i txt = scan txt
  where
    tok = "_v" <> tshow i
    scan t = case T.breakOn tok t of
      (_, "") -> False
      (_, rest) ->
        let after = T.drop (T.length tok) rest
        in case T.uncons after of
             Just (c, _) | c >= '0' && c <= '9' -> scan (T.drop (T.length tok) rest)
             _ -> True
