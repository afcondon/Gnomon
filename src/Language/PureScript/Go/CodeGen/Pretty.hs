{-# LANGUAGE OverloadedStrings #-}

-- |
-- Pretty-print the Go AST to Text.
--
-- Deliberately simple: it emits SYNTACTICALLY correct Go with naive spacing
-- and newlines, then the caller pipes the whole file through @gofmt@ (see
-- Make.hs) which fixes indentation, alignment and idiomatic spacing. This is
-- the "cheap robustness win" from the plan -- it sidesteps an entire class of
-- pretty-printer bugs. gofmt does NOT fix semantic problems (unused vars /
-- imports); those are the Unused pass's job.
--
-- Modelled on the SHAPE of purerl's @Pretty.hs@ (recursive render over a
-- structured AST) but far smaller, because gofmt absorbs the layout work.
--
module Language.PureScript.Go.CodeGen.Pretty
  ( prettyDecls
  , prettyProgram
  , prettyExpr
  , prettyStmt
  ) where

import Prelude
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Set as Set

import Language.PureScript.Go.CodeGen.AST

prettyDecls :: [GoDecl] -> Text
prettyDecls = T.intercalate "\n\n" . map prettyDecl

-- | Render the generated top-level declarations as a Go program body.
--
-- All generated @var X any = <expr>@ bindings are split into zero-value
-- declarations @var X any@ plus assignments inside a single @func init()@,
-- emitted in DEPENDENCY (topological) order. This solves two problems at once:
--
--   * Go's package-level cycle detector (conservatively) rejects ANY reference
--     a var initializer makes back to itself or into a cycle -- even one buried
--     in a closure that never runs at init time (self-recursive @gcd@, or the
--     mutually-referential @monad/bind/apply@ dictionary chain). @init()@
--     bodies are not analyzed for cycles, so the assignments are accepted.
--
--   * Value-level CAFs that ARE evaluated eagerly (e.g. a dictionary built by
--     applying another dictionary) must see their dependencies already
--     assigned. Topological order guarantees a binding's (non-cyclic)
--     dependencies are assigned before it. Cyclic references resolve at call
--     time, because Go closures capture the package var by reference.
--
-- Non-var declarations (func/raw) stay at the top level unchanged. The static
-- prelude (prelude.go) keeps ordinary var initializers; Go runs those before
-- any init(), and the generated code depends on the prelude, not vice versa.
prettyProgram :: [GoDecl] -> Text
prettyProgram ds =
  let others = [ d | d <- ds, not (isVarDecl d) ]
      vars   = [ (n, e) | GoVarDecl n e <- ds ]
      names  = Set.fromList (map fst vars)
      -- Each generated binding becomes a memoized lazy thunk; references to
      -- generated bindings are forced on use (see Note on lazy init in this
      -- module). var-decls and init-assignments are emitted in declaration
      -- order -- order is irrelevant because nothing runs until first force.
      varDecls = T.intercalate "\n" [ "var " <> n <> " any" | (n, _) <- vars ]
      initBody = T.intercalate "\n"
        [ n <> " = _lazy(func() any { return " <> prettyExpr (forceRefs names e) <> " })"
        | (n, e) <- vars ]
      initFn   = "func init() {\n" <> initBody <> "\n}"
  in T.intercalate "\n\n"
       (  map prettyDecl others
       ++ [ varDecls | not (null vars) ]
       ++ [ initFn   | not (null vars) ]
       )
  where
    isVarDecl (GoVarDecl _ _) = True
    isVarDecl _               = False

-- Note on lazy init
-- -----------------
-- Generated top-level bindings form cyclic value-level clusters (the standard
-- typeclass-dictionary chains: Functor/Apply/Applicative/Bind/Monad refer to
-- one another). A strict, ordered initialization cannot satisfy them because
-- some edges are eager (a dict built by applying another dict) while the cycle
-- is only broken by lazy `\_ -> dict` closures -- and the eager edges can be
-- transitive through function calls, defeating any static ordering. purs solves
-- this with its `$runtime_lazy` thunk runtime; we mirror it: every generated
-- binding is `_lazy(func() any { return <init> })` and every reference to a
-- generated binding is `_force(X)`. Initialization is fully on-demand and
-- memoized, so the clusters resolve at first use regardless of order. Prelude
-- shims (in prelude.go) are NOT thunks, so references to them are left bare;
-- they are distinguished by name (the generated-binding name set).

-- | Rewrite every reference to a GENERATED binding (a name in @gen@) into a
-- force, @_force(name)@. Structural @GoVar@ references are rewritten directly;
-- the @GoRaw@/@GoRawStmt@ escape hatches carry already-rendered text, so their
-- generated-name tokens are patched textually (locals and prelude shims are not
-- in @gen@ and are left untouched).
forceRefs :: Set.Set Text -> GoExpr -> GoExpr
forceRefs gen = goE
  where
    goE e = case e of
      GoVar n | n `Set.member` gen -> GoRaw ("_force(" <> n <> ")")
              | otherwise           -> e
      GoDotted{}       -> e
      GoCurriedApp f a -> GoCurriedApp (goE f) (goE a)
      GoCall f as      -> GoCall (goE f) (map goE as)
      GoClosure p body -> GoClosure p (map goS body)
      GoIIFE body      -> GoIIFE (map goS body)
      GoSliceLit es    -> GoSliceLit (map goE es)
      GoMapLit kvs     -> GoMapLit [ (k, goE v) | (k, v) <- kvs ]
      GoADT t fs       -> GoADT t (map goE fs)
      GoMapIndex x k   -> GoMapIndex (goE x) k
      GoSliceIndex x i -> GoSliceIndex (goE x) (goE i)
      GoBinary op a b  -> GoBinary op (goE a) (goE b)
      GoRaw t          -> GoRaw (patchTokens gen t)
      _                -> e            -- literals / nil
    goS s = case s of
      GoReturn e       -> GoReturn (goE e)
      GoAssign n e     -> GoAssign n (goE e)
      GoVarDef n e     -> GoVarDef n (goE e)
      GoExprStmt e     -> GoExprStmt (goE e)
      GoIf c body      -> GoIf (goE c) (map goS body)
      GoBlockStmt body -> GoBlockStmt (map goS body)
      GoRawStmt t      -> GoRawStmt (patchTokens gen t)
      GoPanic m        -> GoPanic m

-- | Patch generated-binding name tokens in opaque rendered Go text: each
-- maximal identifier run that is a generated name becomes @_force(name)@.
patchTokens :: Set.Set Text -> Text -> Text
patchTokens gen = T.concat . map patch . T.groupBy sameClass
  where
    patch t
      | not (T.null t) && isIdentChar (T.head t) && t `Set.member` gen
                  = "_force(" <> t <> ")"
      | otherwise = t
    sameClass a b = isIdentChar a == isIdentChar b

isIdentChar :: Char -> Bool
isIdentChar c = c == '_' || (c >= 'a' && c <= 'z')
                || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')

prettyDecl :: GoDecl -> Text
prettyDecl = \case
  GoVarDecl name e ->
    "var " <> name <> " any = " <> prettyExpr e
  GoFuncDecl name params body ->
    "func " <> name <> "(" <> params' <> ") any {\n"
      <> prettyStmts body <> "\n}"
    where params' = T.intercalate ", " [ p <> " any" | p <- params ]
  GoRawDecl raw -> raw

prettyStmts :: [GoStmt] -> Text
prettyStmts = T.intercalate "\n" . map prettyStmt

prettyStmt :: GoStmt -> Text
prettyStmt = \case
  GoReturn e       -> "return " <> prettyExpr e
  GoAssign name e  -> name <> " := " <> prettyExpr e
  GoVarDef name e  -> "var " <> name <> " any = " <> prettyExpr e
  GoExprStmt e     -> prettyExpr e
  GoIf cond body   -> "if " <> prettyExpr cond <> " {\n" <> prettyStmts body <> "\n}"
  GoBlockStmt body -> "{\n" <> prettyStmts body <> "\n}"
  GoPanic msg      -> "panic(\"" <> msg <> "\")"
  GoRawStmt raw    -> raw

prettyExpr :: GoExpr -> Text
prettyExpr = \case
  GoInt n      -> T.pack (show n)
  GoFloat d    -> T.pack (show d)
  GoString s   -> "\"" <> s <> "\""
  GoBool True  -> "true"
  GoBool False -> "false"
  GoNil        -> "nil"
  GoVar v      -> v
  GoDotted p n -> p <> "." <> n
  GoRaw raw    -> raw

  -- Curried unary application: f.(func(any) any)(x).
  -- When the callee is a closure LITERAL its Go type is already the concrete
  -- func(any) any, not an interface, so the type assertion is illegal (Go only
  -- asserts on interface types) -- call it directly. This is the `(\_ -> e) x`
  -- / immediately-applied-lambda case.
  GoCurriedApp fn@(GoClosure _ _) arg ->
    "(" <> prettyExpr fn <> ")(" <> prettyExpr arg <> ")"
  GoCurriedApp fn arg ->
    "(" <> prettyExpr fn <> ").(func(any) any)(" <> prettyExpr arg <> ")"

  -- Raw call: f(a, b)
  GoCall fn args ->
    prettyExpr fn <> "(" <> T.intercalate ", " (map prettyExpr args) <> ")"

  -- Curried unary closure literal.
  GoClosure param body ->
    "func(" <> param <> " any) any {\n" <> prettyStmts body <> "\n}"

  -- Immediately-invoked zero-arg closure (statement scope as an expression).
  GoIIFE body ->
    "func() any {\n" <> prettyStmts body <> "\n}()"

  GoSliceLit es ->
    "[]any{" <> T.intercalate ", " (map prettyExpr es) <> "}"

  GoMapLit kvs ->
    "map[string]any{" <>
      T.intercalate ", " [ "\"" <> k <> "\": " <> prettyExpr v | (k, v) <- kvs ] <>
    "}"

  -- ADT literal: V{Tag: "Just", Fields: []any{x}}
  GoADT tag fields ->
    "V{Tag: \"" <> tag <> "\", Fields: []any{" <>
      T.intercalate ", " (map prettyExpr fields) <> "}}"

  -- Map index with type assertion to map[string]any then string key.
  GoMapIndex e k ->
    "(" <> prettyExpr e <> ").(map[string]any)[\"" <> k <> "\"]"

  -- Slice index with type assertion.
  GoSliceIndex e i ->
    "(" <> prettyExpr e <> ").([]any)[" <> prettyExpr i <> "]"

  GoBinary op a b ->
    "(" <> prettyExpr a <> " " <> op <> " " <> prettyExpr b <> ")"
