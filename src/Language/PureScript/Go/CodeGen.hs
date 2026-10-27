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
-- Constructor. Self tail calls compile to a @for {}@ loop (ADR 0003; see
-- "Self tail calls" below); the Unused pass is ADR 0008.
--
-- Saturated calls and the inliner (ADR 0009; see "Saturated calls" below):
-- a top-level binding that is an n-deep lambda chain also gets a plain Go
-- func of n parameters, and a call that supplies at least n arguments calls
-- it directly. The curried closure stays, and is what escapes into
-- first-class use. Then purs's JS inliner set: runFnN/mkFnN and their
-- Effect/ST forms, primitive ops through a known dictionary, saturated
-- constructors.
--
module Language.PureScript.Go.CodeGen
  ( generateModule
  , Known
  , knownBindings
  ) where

import Prelude

import Data.Map (Map)
import qualified Data.Map as Map
import Data.Set (Set)
import qualified Data.Set as Set
import Text.Read (readMaybe)
import Data.Text (Text)
import qualified Data.Text as T

import qualified Language.PureScript as P
import qualified Language.PureScript.CoreFn as CoreFn
import Language.PureScript.PSString (PSString, decodeString)

import Language.PureScript.Go.CodeGen.AST
import Language.PureScript.Go.CodeGen.Common
import qualified Language.PureScript.Go.CodeGen.Pretty as Pretty

-- | What the whole program knows about one top-level binding (ADR 0009).
data KnownDef
  = KnownFn Int            -- ^ a lambda chain this many parameters deep
  | KnownCtor CtorShape    -- ^ a constructor
  -- | A top-level name applied to top-level names, such as the
  -- @negate = Data.Ring.negate ringNumber@ that CoreFn floats out of every
  -- use of a dictionary method. purs's inliner looks through these (its
  -- "expander"), and so do we.
  | KnownAlias P.ModuleName P.Ident [CoreFn.Expr CoreFn.Ann]

data CtorShape
  = CtorNewtype            -- ^ erased: the constructor is the identity
  | CtorDict [P.Ident]     -- ^ a type-class dictionary: a map of its fields
  | CtorData Text Int      -- ^ a data constructor: tag and field count

-- | Every emitted top-level binding whose shape is known, keyed by module.
type Known = Map (P.ModuleName, P.Ident) KnownDef

-- | The arity map: one fold over every emitted module's declarations, so a
-- call in one module is saturated against a definition in another. Foreigns
-- are not declarations, so they never appear and stay curried.
knownBindings :: [CoreFn.Module CoreFn.Ann] -> Known
knownBindings mods = Map.fromList
  [ ((CoreFn.moduleName m, ident), k)
  | m <- mods
  , bind <- CoreFn.moduleDecls m
  , (ident, expr) <- case bind of
      CoreFn.NonRec _ i e -> [(i, e)]
      CoreFn.Rec bs -> [ (i, e) | ((_, i), e) <- bs ]
  , Just k <- [knownDef expr] ]
  where
    knownDef = \case
      CoreFn.Constructor ann _ (P.ProperName ctor) fields -> Just . KnownCtor $ case ann of
        (_, _, Just CoreFn.IsNewtype) -> CtorNewtype
        (_, _, Just CoreFn.IsTypeClassConstructor) -> CtorDict fields
        _ -> CtorData (escapeGoString ctor) (length fields)
      expr@(CoreFn.App {})
        | (CoreFn.Var _ (P.Qualified (P.ByModuleName mn) i), args) <- unApp expr
        , all isTopVar args -> Just (KnownAlias mn i args)
      expr -> case length (fst (peelAbs expr)) of
        0 -> Nothing
        n -> Just (KnownFn n)
    isTopVar = \case
      CoreFn.Var _ (P.Qualified (P.ByModuleName _) _) -> True
      _ -> False

-- | The Go func behind a saturated call of the top-level binding @name@.
-- Generated top-level names start with a module name, so never with @_@.
satName :: Text -> Text
satName name = "_sat_" <> name

-- | Generate the top-level Go declarations for one module.
generateModule :: Known -> CoreFn.Module CoreFn.Ann -> [GoDecl]
generateModule known cfModule = concatMap generateBind (CoreFn.moduleDecls cfModule)
  where
    currentModule :: P.ModuleName
    currentModule = CoreFn.moduleName cfModule

    currentModuleText :: Text
    currentModuleText = case currentModule of P.ModuleName mn -> mn

    -- One top-level binding -> one var decl (flat package, mangled name).
    -- Rec is treated as a list of vars (Go allows forward refs within a
    -- package; value-cycles are resolved by the lazy init in Pretty.hs). A
    -- binding that calls ITSELF in tail position becomes a loop (genRecBind);
    -- mutual tail calls between bindings of one group stay ordinary calls.
    generateBind :: CoreFn.Bind CoreFn.Ann -> [GoDecl]
    generateBind (CoreFn.NonRec _ ident expr) = topBind False ident expr
    generateBind (CoreFn.Rec bindings) =
      concat [ topBind True ident expr | ((_, ident), expr) <- bindings ]

    -- A known-arity function (ADR 0009) is two declarations: the plain Go
    -- func that saturated calls reach, and the curried closure, now a thin
    -- wrapper over it, for first-class use. A self-tail-recursive binding
    -- loops inside the func.
    topBind :: Bool -> P.Ident -> CoreFn.Expr CoreFn.Ann -> [GoDecl]
    topBind recursive ident expr = case Map.lookup (currentModule, ident) known of
      Just (KnownFn n) ->
        let (params, body) = peelAbs expr
            isSelf = topSelf ident
            stmts = case if recursive then tryTco isSelf ident expr else Nothing of
              Just (ps, b) -> tcoStmts isSelf ps b
              Nothing -> [ GoReturn (genExpr body) ]
            args = [ "_a" <> tshow i | i <- [0 .. n - 1] ]
            wrapper = foldr (\a acc -> GoClosure a [ GoReturn acc ])
                            (GoCall (GoVar (satName name)) (map GoVar args)) args
        in [ GoFuncDecl (satName name) (funcParams params) stmts
           , GoVarDecl name wrapper ]
      _ -> [ GoVarDecl name (if recursive then genRecBind (topSelf ident) ident expr
                                          else genExpr expr) ]
      where name = goTopName currentModule ident

    -- A reference to the top-level binding @ident@ of this module.
    topSelf :: P.Ident -> SelfRef
    topSelf ident (P.Qualified qb i) = i == ident && qb == P.ByModuleName currentModule

    -- A reference to the let-bound @ident@ (locals are qualified by position).
    localSelf :: P.Ident -> SelfRef
    localSelf ident (P.Qualified qb i) = i == ident && case qb of
      P.BySourcePos _ -> True
      P.ByModuleName _ -> False

    -- | One binding of a Rec group: a loop when TCO applies, else as usual.
    genRecBind :: SelfRef -> P.Ident -> CoreFn.Expr CoreFn.Ann -> GoExpr
    genRecBind isSelf ident expr = case tryTco isSelf ident expr of
      Just (params, body) -> genTco isSelf params body
      Nothing -> genExpr expr

    -- ---------------------------------------------------------------
    -- Self tail calls (ADR 0003)
    -- ---------------------------------------------------------------
    --
    -- A binding @f = \p0 -> .. -> \pk -> body@ whose body calls @f@ with
    -- exactly k+1 arguments, and only in tail position, compiles to
    --
    --   func(p0 any) any { return ... func(pk any) any {
    --     _tco0, ..., _tcok := p0, ..., pk       // this call's own state
    --     for {
    --       p0 := _tco0; _ = p0                   // fresh per iteration
    --       ...
    --       <body; a tail call is `_tco0, .. = a0, ..; continue`,
    --              any other tail value is `return e`>
    --     }
    --   } ... }
    --
    -- Two hazards shape it:
    --
    --   * Closure capture. A closure built in one iteration must keep THAT
    --     iteration's values. Go closures capture variables, not values, so
    --     the body reads fresh @:=@ copies declared inside the loop block,
    --     never the loop state, which is reassigned.
    --
    --   * Partial application. The outer curried closures' parameters are
    --     shared by every later application of the partially applied
    --     function (@let f = go 0 in f 1 + f 2@). The loop therefore copies
    --     them into state local to the innermost call and never writes them.
    --
    -- Tail positions are compiled as statements directly in the loop body
    -- (through Case and Let, never into an IIFE), because @continue@ cannot
    -- cross a function boundary. A self reference anywhere else -- an
    -- argument, a scrutinee, a let right-hand side, inside a lambda, or an
    -- unsaturated call -- disqualifies the binding, which then compiles as
    -- plain recursion exactly as before. Mutual recursion is not looped.

    genTco :: SelfRef -> [P.Ident] -> CoreFn.Expr CoreFn.Ann -> GoExpr
    genTco isSelf params body =
      let names = map identToGoName params
          innermost = GoClosure (last names) (tcoStmts isSelf params body)
      in foldr (\nm acc -> GoClosure nm [ GoReturn acc ]) innermost (init names)

    -- | The loop itself, as the body of the innermost closure or of a
    -- saturated func: copy the parameters into loop state, then loop.
    tcoStmts :: SelfRef -> [P.Ident] -> CoreFn.Expr CoreFn.Ann -> [GoStmt]
    tcoStmts isSelf params body =
      let names = map identToGoName params
          used = usedIdents body
          -- A param the body can see: used, and not hidden by a later param
          -- of the same name (only the last of duplicates is in scope).
          live = [ p `Set.member` used && p `notElem` drop (i + 1) params
                 | (i, p) <- zip [0 :: Int ..] params ]
          st i = "_tco" <> tshow i
          liveIx = [ (i, nm) | (i, nm, True) <- zip3 [0 :: Int ..] names live ]
          inits = [ GoAssign (st i) (GoVar nm) | (i, nm) <- liveIx ]
          -- `_ = p` keeps Go quiet when usedIdents over-approximates (it
          -- ignores shadowing, so a param rebound by a pattern still counts).
          copies = concat [ [ GoAssign nm (GoVar (st i)), GoSet ["_"] [GoVar nm] ]
                          | (i, nm) <- liveIx ]
          loopBody = copies ++ tailStmts isSelf live body
      in inits ++ [ GoFor loopBody ]

    -- | An expression in tail position of a TCO loop, as statements. Every
    -- path ends in @continue@ (self call), @return@, or a pattern-match panic.
    tailStmts :: SelfRef -> [Bool] -> CoreFn.Expr CoreFn.Ann -> [GoStmt]
    tailStmts isSelf live = go
      where
        go expr = case selfCall isSelf (length live) expr of
          Just args ->
            let assigns =
                  [ (if isLive then "_tco" <> tshow i else "_", e)
                  | (i, isLive, a) <- zip3 [0 :: Int ..] live args
                  , let e = genExpr a
                  -- a dead argument is still evaluated, as JS evaluates it;
                  -- but `_ = nil` is not legal Go, and nil has no effect.
                  , isLive || e /= GoNil ]
            in [ GoSet (map fst assigns) (map snd assigns) | not (null assigns) ]
               ++ [ GoContinue ]
          Nothing -> case expr of
            -- Own block, so the let's names (and a nested let reusing them)
            -- never collide with the loop's param copies.
            CoreFn.Let _ binds body -> [ GoBlockStmt (genLetGroup binds body ++ go body) ]
            CoreFn.Case _ scruts alts -> genCaseStmts go scruts alts
            other -> [ GoReturn (genExpr other) ]

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

      e@(CoreFn.App {}) -> genApp e

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

    -- ---------------------------------------------------------------
    -- Saturated calls and the inliner (ADR 0009)
    -- ---------------------------------------------------------------
    --
    -- An application spine @f a1 .. ak@ whose head is a top-level name:
    --
    --   * an inliner rule for that name (purs's JS CoreImp set, below)
    --     replaces the call outright;
    --   * else a known function of arity n <= k is called directly,
    --     @_sat_f(a1, .., an)@, and the rest applied curried;
    --   * else a known constructor applied to all its fields is built in
    --     place.
    --
    -- Anything else, an unknown head or too few arguments, is the curried
    -- application it always was. Arguments are pure expressions, and the
    -- intermediate closures of a lambda chain do nothing but capture, so
    -- calling all at once changes no result.
    genApp :: CoreFn.Expr CoreFn.Ann -> GoExpr
    genApp e = case unApp e of
      (CoreFn.Var _ (P.Qualified (P.ByModuleName mn) ident), args)
        | Just (k, r) <- inlineApp mn ident args <|> saturate mn ident args ->
            applyRest r (drop k args)
        -- Through an alias, when that reaches past the alias's own
        -- arguments into the call's.
        | Just (KnownAlias amn aident pre) <- Map.lookup (mn, ident) known
        , let args' = pre ++ args
        , Just (k, r) <- inlineApp amn aident args' <|> saturate amn aident args'
        , k > length pre ->
            applyRest r (drop k args')
      (hd, args) -> applyRest (genExpr hd) args
      where
        applyRest = foldl (\acc a -> GoCurriedApp acc (genExpr a))
        a <|> b = maybe b Just a

    -- | A call of a known binding with enough arguments: how many it takes,
    -- and the call.
    saturate :: P.ModuleName -> P.Ident -> [CoreFn.Expr CoreFn.Ann] -> Maybe (Int, GoExpr)
    saturate mn ident args = case Map.lookup (mn, ident) known of
      Just (KnownFn n) | length args >= n ->
        Just (n, GoCall (GoVar (satName (goTopName mn ident))) (map genExpr (take n args)))
      Just (KnownCtor CtorNewtype) | (a : _) <- args -> Just (1, genExpr a)
      Just (KnownCtor (CtorData tag n)) | n > 0, length args >= n ->
        Just (n, GoADT tag (map genExpr (take n args)))
      Just (KnownCtor (CtorDict fields)) | not (null fields), length args >= length fields ->
        Just (length fields, GoMapLit (zip (map runIdent' fields) (map genExpr args)))
      _ -> Nothing

    -- | purs's JS inliner (CoreImp/Optimizer/Inliner.hs), rule for rule where
    -- Go can say the same thing. Each primitive op means exactly what the
    -- prelude.go shim it replaces means, which is what the JS operator means
    -- except where the ledger already says otherwise (Int is not wrapped to
    -- 32 bits). The one deliberate change is `negate` on Number: unary minus,
    -- as JS, so `negate 0.0` is -0.0 and the NEGZERO entries close.
    inlineApp :: P.ModuleName -> P.Ident -> [CoreFn.Expr CoreFn.Ann] -> Maybe (Int, GoExpr)
    inlineApp (P.ModuleName mn) (P.Ident fn) args
      -- Uncurried functions: Fn and EffectFn are variadic Go funcs.
      | mn == "Data.Function.Uncurried", Just n <- suffix "runFn", n /= 1
      , (f : rest) <- args, length rest >= n =
          Just (n + 1, GoTypedCall "func(...any) any" (genExpr f) (map genExpr (take n rest)))
      | mn == "Data.Function.Uncurried", Just n <- suffix "mkFn", n /= 1
      , (f : _) <- args, Just body <- uncurried n f (\b -> [ GoReturn (genExpr b) ]) =
          Just (1, body)
      | mn `elem` ["Effect.Uncurried", "Control.Monad.ST.Uncurried"]
      , Just n <- suffix "runEffectFn" <|> suffix "runSTFn", n >= 1
      , (f : rest) <- args, length rest >= n =
          Just (n + 1, GoThunk [ GoReturn (GoTypedCall "func(...any) any" (genExpr f)
                                                         (map genExpr (take n rest))) ])
      | mn `elem` ["Effect.Uncurried", "Control.Monad.ST.Uncurried"]
      , Just n <- suffix "mkEffectFn" <|> suffix "mkSTFn", n >= 1
      , (f : _) <- args
      , Just body <- uncurried n f (\b -> [ GoReturn (GoTypedCall "func() any" (genExpr b) []) ]) =
          Just (1, body)
      -- Primitive ops through a known dictionary.
      | (CoreFn.Var _ (P.Qualified (P.ByModuleName (P.ModuleName dm)) (P.Ident dict)) : rest) <- args
      , Just op <- lookup (mn, fn, dm, dict) dictOps =
          case (op, rest) of
            (OpBinary t r o, x : y : _) -> Just (3, binaryOp t r o x y)
            (OpUnary t o, x : _) -> Just (2, unaryOp t o x)
            (OpValue v, _) -> Just (1, v)
            _ -> Nothing
      | mn == "Data.Int.Bits", Just o <- lookup fn bitOps, x : y : _ <- args =
          Just (2, bitOp o (genExpr x) (genExpr y))
      | mn == "Data.Int.Bits", fn == "complement", x : _ <- args =
          Just (1, GoTyped "int" (GoCall (GoVar "_toInt32") [ GoUnary "^" (bitOperand (genExpr x)) ]))
      | mn == "Data.Array", fn == "unsafeIndex"
      , CoreFn.Var {} : arr : i : _ <- args =
          Just (3, GoSliceIndex (boxLit (genExpr arr)) (operand "int" (genExpr i)))
      | mn == "Unsafe.Coerce", fn == "unsafeCoerce", x : _ <- args = Just (1, genExpr x)
      | mn == "Control.Category", fn == "identity"
      , CoreFn.Var _ (P.Qualified (P.ByModuleName (P.ModuleName "Control.Category")) (P.Ident "categoryFn")) : x : _ <- args =
          Just (2, genExpr x)
      where
        suffix pre = T.stripPrefix pre fn >>= readMaybe . T.unpack >>= \n ->
          if n >= 0 && n <= (10 :: Int) then Just n else Nothing
        a <|> b = maybe b Just a
    inlineApp _ _ _ = Nothing

    -- | @mkFnN (\a1 .. aN -> body)@ as a variadic func, when the argument is
    -- a lambda chain at least N deep (purs's @collectArgs@). @mkFn0@ takes
    -- the one Unit-typed lambda and binds its parameter to nil.
    uncurried :: Int -> CoreFn.Expr CoreFn.Ann -> (CoreFn.Expr CoreFn.Ann -> [GoStmt]) -> Maybe GoExpr
    uncurried n f finish =
      let (params, _) = peelAbs f
          take' = max n 1
          body = dropAbs take' f
          binds
            | n == 0 = [ GoVarDef nm GoNil | p <- take 1 params, let nm = identToGoName p ]
            | otherwise =
                [ GoAssign nm (GoRaw ("_args[" <> tshow i <> "]"))
                | (i, p) <- zip [0 :: Int ..] (take n params)
                , p `notElem` drop (i + 1) (take n params)
                , let nm = identToGoName p ]
          keep = [ GoSet ["_"] [GoVar nm] | s <- binds, nm <- boundName s ]
      in if length params >= take' then Just (GoVariadic (binds ++ keep ++ finish body))
                                   else Nothing
      where
        boundName = \case
          GoAssign nm _ -> [nm]
          GoVarDef nm _ -> [nm]
          _ -> []

    binaryOp :: Text -> Text -> Text -> CoreFn.Expr CoreFn.Ann -> CoreFn.Expr CoreFn.Ann -> GoExpr
    binaryOp t resultT o x y =
      let a = operand t (genExpr x)
          b = operand t (genExpr y)
          -- Two literals would make a Go CONSTANT expression, computed
          -- exactly rather than in IEEE arithmetic (0.1 + 0.2 == 0.3), and a
          -- constant zero divisor is a compile error. Unbox one at run time.
          (a', b') | isLit a && isLit b = (nonConst t a, b)
                   | o == "/" && isLit b = (a, nonConst t b)
                   | otherwise = (a, b)
      in GoTyped resultT $ case o of
           -- Go has no ordering on bool; these say what false < true says.
           "b<"  -> GoBinary "&&" (GoUnary "!" a') b'
           "b<=" -> GoBinary "||" (GoUnary "!" a') b'
           "b>"  -> GoBinary "&&" a' (GoUnary "!" b')
           "b>=" -> GoBinary "||" a' (GoUnary "!" b')
           _     -> GoBinary o a' b'

    -- A literal operand of negate would be negated as a constant, and a
    -- constant -0.0 is +0.0 in Go.
    unaryOp :: Text -> Text -> CoreFn.Expr CoreFn.Ann -> GoExpr
    unaryOp t o x =
      let a = operand t (genExpr x)
      in GoTyped t (GoUnary o (if isLit a then nonConst t a else a))

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
    -- (Go closures capture by reference); a self-tail-recursive local @go@
    -- becomes a loop (genRecBind).
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
      [ GoRawStmt (identToGoName ident <> " = " <> prettyOf (genRecBind (localSelf ident) ident expr))
      | ((_, ident), expr) <- bindings ]

    -- | Case -> an IIFE whose body is a sequence of @if cond { return ... }@,
    -- one per alternative, ending in a panic (pattern-match failure).
    -- This is the statement-form replacement for Julia's ternary chain.
    genCase :: [CoreFn.Expr CoreFn.Ann] -> [CoreFn.CaseAlternative CoreFn.Ann] -> GoExpr
    genCase scruts alts = GoIIFE (genCaseStmts (\b -> [ GoReturn (genExpr b) ]) scruts alts)

    -- | The statements of a case, parameterised by how a result expression in
    -- an alternative is finished: @return e@ inside genCase's IIFE, or the
    -- loop-aware tail compilation of a TCO body.
    genCaseStmts :: (CoreFn.Expr CoreFn.Ann -> [GoStmt])
                 -> [CoreFn.Expr CoreFn.Ann] -> [CoreFn.CaseAlternative CoreFn.Ann] -> [GoStmt]
    genCaseStmts finish scruts alts =
      let roots = [ GoVar ("_v" <> tshow i) | i <- [0 .. length scruts - 1] ]
          altStmts = concatMap (genAlt finish roots) alts
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
          -- `var _vN any`, never `:=`: a literal or a constructor literal
          -- would otherwise give the root a concrete Go type, and every
          -- assertion on it (and on a binder copied from it) would fail.
          scrutBindings =
            [ GoVarDef ("_v" <> tshow i) (genExpr e)
            | (i, e) <- zip [0 :: Int ..] scruts
            , rootLive i alts ]
          failStmt = GoPanic ("Pattern match failed in module " <> escapeGoString currentModuleText)
      in scrutBindings ++ altStmts ++ [ failStmt ]

    -- | One alternative -> an @if cond { binders; return body }@ block.
    genAlt :: (CoreFn.Expr CoreFn.Ann -> [GoStmt])
           -> [GoExpr] -> CoreFn.CaseAlternative CoreFn.Ann -> [GoStmt]
    genAlt finish roots alt@(CoreFn.CaseAlternative binders result) =
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
            Right body -> binds ++ finish body
            Left guards ->
              binds ++
              [ GoIf (asBool (genExpr g)) (finish b) | (g, b) <- guards ]
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
      -- A Go constant -0.0 is +0.0, so negative zero is negated at run time.
      CoreFn.NumericLiteral (Right n)
        | n == 0 && isNegativeZero n -> GoTyped "float64" (GoUnary "-" (nonConst "float64" (GoFloat 0)))
        | otherwise -> GoFloat n
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

-- | Does a variable reference mean the binding being compiled?
type SelfRef = P.Qualified P.Ident -> Bool

-- | Parameter names for a saturated func. Go rejects a repeated parameter
-- name, where a curried chain merely shadows; only the last of duplicates is
-- visible to the body, so the earlier ones become @_@.
funcParams :: [P.Ident] -> [Text]
funcParams params =
  [ if p `elem` drop (i + 1) params then "_" else identToGoName p
  | (i, p) <- zip [0 :: Int ..] params ]

dropAbs :: Int -> CoreFn.Expr CoreFn.Ann -> CoreFn.Expr CoreFn.Ann
dropAbs n (CoreFn.Abs _ _ body) | n > 0 = dropAbs (n - 1) body
dropAbs _ e = e

-- | One inlined dictionary operation (ADR 0009).
data DictOp
  = OpBinary Text Text Text   -- ^ operand Go type, result Go type, operator
  | OpUnary Text Text         -- ^ operand Go type, operator
  | OpValue GoExpr            -- ^ a constant (@zero@, @top@, ...)

-- | purs's @inlineCommonOperators@ and @inlineCommonValues@, keyed by
-- (method module, method, dictionary module, dictionary).
dictOps :: [((Text, Text, Text, Text), DictOp)]
dictOps =
  [ (("Data.Semiring", "add", "Data.Semiring", "semiringInt"), OpBinary "int" "int" "+")
  , (("Data.Semiring", "mul", "Data.Semiring", "semiringInt"), OpBinary "int" "int" "*")
  , (("Data.Semiring", "add", "Data.Semiring", "semiringNumber"), OpBinary "float64" "float64" "+")
  , (("Data.Semiring", "mul", "Data.Semiring", "semiringNumber"), OpBinary "float64" "float64" "*")
  , (("Data.Semiring", "zero", "Data.Semiring", "semiringInt"), OpValue (GoInt 0))
  , (("Data.Semiring", "one", "Data.Semiring", "semiringInt"), OpValue (GoInt 1))
  , (("Data.Semiring", "zero", "Data.Semiring", "semiringNumber"), OpValue (GoFloat 0))
  , (("Data.Semiring", "one", "Data.Semiring", "semiringNumber"), OpValue (GoFloat 1))
  , (("Data.Ring", "sub", "Data.Ring", "ringInt"), OpBinary "int" "int" "-")
  , (("Data.Ring", "sub", "Data.Ring", "ringNumber"), OpBinary "float64" "float64" "-")
  , (("Data.Ring", "negate", "Data.Ring", "ringInt"), OpUnary "int" "-")
  , (("Data.Ring", "negate", "Data.Ring", "ringNumber"), OpUnary "float64" "-")
  , (("Data.EuclideanRing", "div", "Data.EuclideanRing", "euclideanRingNumber"), OpBinary "float64" "float64" "/")
  , (("Data.Semigroup", "append", "Data.Semigroup", "semigroupString"), OpBinary "string" "string" "+")
  , (("Data.HeytingAlgebra", "conj", "Data.HeytingAlgebra", "heytingAlgebraBoolean"), OpBinary "bool" "bool" "&&")
  , (("Data.HeytingAlgebra", "disj", "Data.HeytingAlgebra", "heytingAlgebraBoolean"), OpBinary "bool" "bool" "||")
  , (("Data.HeytingAlgebra", "not", "Data.HeytingAlgebra", "heytingAlgebraBoolean"), OpUnary "bool" "!")
  , (("Data.Bounded", "top", "Data.Bounded", "boundedBoolean"), OpValue (GoBool True))
  , (("Data.Bounded", "bottom", "Data.Bounded", "boundedBoolean"), OpValue (GoBool False))
  ] ++
  [ (("Data.Eq", m, "Data.Eq", d), OpBinary t "bool" o)
  | (d, t) <- [("eqInt", "int"), ("eqNumber", "float64"), ("eqString", "string"), ("eqChar", "string"), ("eqBoolean", "bool")]
  , (m, o) <- [("eq", "=="), ("notEq", "!=")] ] ++
  [ (("Data.Ord", m, "Data.Ord", d), OpBinary t "bool" o)
  | (d, t) <- [("ordInt", "int"), ("ordNumber", "float64"), ("ordString", "string"), ("ordChar", "string")]
  , (m, o) <- [("lessThan", "<"), ("lessThanOrEq", "<="), ("greaterThan", ">"), ("greaterThanOrEq", ">=")] ] ++
  [ (("Data.Ord", m, "Data.Ord", "ordBoolean"), OpBinary "bool" "bool" o)
  | (m, o) <- [("lessThan", "b<"), ("lessThanOrEq", "b<="), ("greaterThan", "b>"), ("greaterThanOrEq", "b>=")] ]

-- | Data.Int.Bits, as the prelude.go shims compute them: int32 results, and
-- shift counts masked to 5 bits.
data BitOp = BitAnd | BitOr | BitXor | BitShl | BitShr | BitZshr

bitOps :: [(Text, BitOp)]
bitOps = [ ("and", BitAnd), ("or", BitOr), ("xor", BitXor)
         , ("shl", BitShl), ("shr", BitShr), ("zshr", BitZshr) ]

bitOp :: BitOp -> GoExpr -> GoExpr -> GoExpr
bitOp o x y =
  let a = bitOperand x
      b = bitOperand y
      call f e = GoCall (GoVar f) [e]
      count = call "uint" (GoBinary "&" b (GoInt 31))
  in GoTyped "int" $ case o of
       BitAnd  -> call "_toInt32" (GoBinary "&" a b)
       BitOr   -> call "_toInt32" (GoBinary "|" a b)
       BitXor  -> call "_toInt32" (GoBinary "^" a b)
       BitShl  -> call "int" (call "int32" (GoBinary "<<" (call "uint32" a) count))
       BitShr  -> call "int" (GoBinary ">>" (call "int32" (call "uint32" a)) count)
       BitZshr -> call "int" (GoBinary ">>" (call "uint32" a) count)

-- | Bit operands are always unboxed at run time: a constant conversion such
-- as @uint32(-1)@ is a compile error in Go, not a wrap.
bitOperand :: GoExpr -> GoExpr
bitOperand e = case operand "int" e of
  x | isLit x -> nonConst "int" x
  x -> x

-- | An operand of an inlined op, unboxed to Go type @t@: an inlined op of
-- the same type is taken bare, a literal stays a literal, anything else is
-- asserted out of @any@.
operand :: Text -> GoExpr -> GoExpr
operand t = \case
  GoTyped t' x | t' == t -> x
  e | isLit e -> e
  e -> GoAssert t e

-- | A literal unboxed at run time, so it is no longer a Go constant.
nonConst :: Text -> GoExpr -> GoExpr
nonConst t e = GoAssert t (GoTyped "" e)

isLit :: GoExpr -> Bool
isLit = \case
  GoInt _ -> True
  GoFloat _ -> True
  GoString _ -> True
  GoBool _ -> True
  _ -> False

-- | An array literal has the concrete type @[]any@, which cannot be asserted.
boxLit :: GoExpr -> GoExpr
boxLit e@(GoSliceLit _) = GoTyped "" e
boxLit e = e

-- | @f a1 .. an@ as @(f, [a1 .. an])@.
unApp :: CoreFn.Expr CoreFn.Ann -> (CoreFn.Expr CoreFn.Ann, [CoreFn.Expr CoreFn.Ann])
unApp = go []
  where
    go args (CoreFn.App _ fn arg) = go (arg : args) fn
    go args other = (other, args)

-- | The arguments of a self call saturated at exactly @n@ arguments.
selfCall :: SelfRef -> Int -> CoreFn.Expr CoreFn.Ann -> Maybe [CoreFn.Expr CoreFn.Ann]
selfCall isSelf n e@(CoreFn.App {}) = case unApp e of
  (CoreFn.Var _ q, args) | isSelf q && length args == n -> Just args
  _ -> Nothing
selfCall _ _ _ = Nothing

peelAbs :: CoreFn.Expr CoreFn.Ann -> ([P.Ident], CoreFn.Expr CoreFn.Ann)
peelAbs (CoreFn.Abs _ arg body) = let (ps, b) = peelAbs body in (arg : ps, b)
peelAbs other = ([], other)

-- | TCO applicability, after Jurist's @tryTco@: a lambda chain whose body
-- calls itself at least once, and ONLY as saturated tail calls. Also refused
-- when anything inside rebinds the name (a param, let or pattern called the
-- same), since then a syntactic match on the name is not a self reference.
tryTco :: SelfRef -> P.Ident -> CoreFn.Expr CoreFn.Ann
       -> Maybe ([P.Ident], CoreFn.Expr CoreFn.Ann)
tryTco isSelf self expr =
  let (params, body) = peelAbs expr
      n = length params
  in if n > 0 && self `notElem` params && not (rebinds self body)
          && hasSelfTailCall isSelf n body && tcoOk isSelf n body
       then Just (params, body)
       else Nothing

-- | Is there a saturated self call in some tail position?
hasSelfTailCall :: SelfRef -> Int -> CoreFn.Expr CoreFn.Ann -> Bool
hasSelfTailCall isSelf n = go
  where
    go expr = case selfCall isSelf n expr of
      Just _ -> True
      Nothing -> case expr of
        CoreFn.Case _ _ alts -> any altHas alts
        CoreFn.Let _ _ body -> go body
        _ -> False
    altHas (CoreFn.CaseAlternative _ result) = case result of
      Right b -> go b
      Left guards -> any (go . snd) guards

-- | Every self reference is a saturated call in tail position.
tcoOk :: SelfRef -> Int -> CoreFn.Expr CoreFn.Ann -> Bool
tcoOk isSelf n = go True
  where
    noSelf = not . mentions isSelf
    go tailPos expr = case expr of
      e@(CoreFn.App {}) -> case selfCall isSelf n e of
        Just args -> tailPos && all noSelf args
        Nothing -> noSelf e
      CoreFn.Case _ scruts alts ->
        let altOk (CoreFn.CaseAlternative _ result) = case result of
              Right b -> go tailPos b
              Left guards -> all (\(g, b) -> noSelf g && go tailPos b) guards
        in all noSelf scruts && all altOk alts
      CoreFn.Let _ binds body ->
        let bindOk (CoreFn.NonRec _ _ e) = noSelf e
            bindOk (CoreFn.Rec bs) = all (noSelf . snd) bs
        in all bindOk binds && go tailPos body
      other -> noSelf other

-- | Does the expression reference the binding anywhere at all?
mentions :: SelfRef -> CoreFn.Expr CoreFn.Ann -> Bool
mentions isSelf = go
  where
    go = \case
      CoreFn.Var _ q -> isSelf q
      CoreFn.Literal _ lit -> case lit of
        CoreFn.ArrayLiteral es -> any go es
        CoreFn.ObjectLiteral fs -> any (go . snd) fs
        _ -> False
      CoreFn.Constructor {} -> False
      CoreFn.Accessor _ _ e -> go e
      CoreFn.ObjectUpdate _ e _ fs -> go e || any (go . snd) fs
      CoreFn.Abs _ _ body -> go body
      CoreFn.App _ f a -> go f || go a
      CoreFn.Case _ scruts alts -> any go scruts || any goAlt alts
      CoreFn.Let _ binds body -> go body || any goBind binds
    goAlt (CoreFn.CaseAlternative _ result) = case result of
      Right b -> go b
      Left guards -> any (\(g, b) -> go g || go b) guards
    goBind (CoreFn.NonRec _ _ e) = go e
    goBind (CoreFn.Rec bs) = any (go . snd) bs

-- | Does anything inside bind the identifier (lambda, let, or pattern)?
rebinds :: P.Ident -> CoreFn.Expr CoreFn.Ann -> Bool
rebinds x = go
  where
    go = \case
      CoreFn.Literal _ lit -> case lit of
        CoreFn.ArrayLiteral es -> any go es
        CoreFn.ObjectLiteral fs -> any (go . snd) fs
        _ -> False
      CoreFn.Var {} -> False
      CoreFn.Constructor {} -> False
      CoreFn.Accessor _ _ e -> go e
      CoreFn.ObjectUpdate _ e _ fs -> go e || any (go . snd) fs
      CoreFn.Abs _ arg body -> arg == x || go body
      CoreFn.App _ f a -> go f || go a
      CoreFn.Case _ scruts alts -> any go scruts || any goAlt alts
      CoreFn.Let _ binds body -> go body || any goBind binds
    goAlt (CoreFn.CaseAlternative binders result) =
      any binderBinds binders || case result of
        Right b -> go b
        Left guards -> any (\(g, b) -> go g || go b) guards
    goBind (CoreFn.NonRec _ i e) = i == x || go e
    goBind (CoreFn.Rec bs) = any (\((_, i), e) -> i == x || go e) bs
    binderBinds = \case
      CoreFn.NullBinder _ -> False
      CoreFn.VarBinder _ i -> i == x
      CoreFn.NamedBinder _ i b -> i == x || binderBinds b
      CoreFn.ConstructorBinder _ _ _ bs -> any binderBinds bs
      CoreFn.LiteralBinder _ lit -> case lit of
        CoreFn.ArrayLiteral bs -> any binderBinds bs
        CoreFn.ObjectLiteral fs -> any (binderBinds . snd) fs
        _ -> False

-- | Combine conditions with &&; Nothing means "always true".
andAll :: [GoExpr] -> Maybe GoExpr
andAll [] = Nothing
andAll (c:cs) = Just (foldl (GoBinary "&&") c cs)

-- | A guard expression has PureScript type @Boolean@ but is emitted as an
-- @any@-typed Go value (a Var or curried application); Go's @if@ needs a real
-- @bool@, so assert it. A bare boolean literal is already a Go bool.
asBool :: GoExpr -> GoExpr
asBool e@(GoBool _) = e
asBool (GoTyped "bool" e) = e
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
