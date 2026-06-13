{-# LANGUAGE OverloadedStrings #-}

-- |
-- A small, purpose-built Go AST: GoExpr / GoStmt / GoDecl.
--
-- This is the "statement-form" intermediate that Julia/Python lack. It is
-- modelled on the SHAPE of purerl's @CodeGen/AST.hs@ (structured AST,
-- pretty-printed, optimizer passes over it) but retargeted to Go and trimmed
-- to exactly what the spike needs. Everything in the runtime is @any@
-- (Go's @interface{}@), so the AST carries no types.
--
module Language.PureScript.Go.CodeGen.AST
  ( GoExpr(..)
  , GoStmt(..)
  , GoDecl(..)
  ) where

import Prelude
import Data.Text (Text)

-- | Go expressions. All values are @any@ at runtime.
data GoExpr
  = GoInt Integer                     -- ^ 42
  | GoFloat Double                    -- ^ 3.14
  | GoString Text                     -- ^ already-escaped Go string literal body
  | GoBool Bool                       -- ^ true / false
  | GoNil                             -- ^ nil (Unit / undefined)
  | GoVar Text                        -- ^ a local or top-level identifier
  | GoDotted Text Text                -- ^ pkg.Name  (here: same-package mangled ref or runtime call)
  -- | Call a value that is statically a curried unary closure:
  --   @f.(func(any) any)(x)@.  We model the type-assertion + call as one node.
  | GoCurriedApp GoExpr GoExpr
  -- | A "raw" call: @f(args...)@ with no type assertion (runtime helpers, FFI).
  | GoCall GoExpr [GoExpr]
  -- | A curried unary closure literal: @func(x any) any { <stmts> }@
  | GoClosure Text [GoStmt]
  -- | Immediately-invoked zero-arg closure: @func() any { <stmts> }()@.
  -- This is how statement-form scopes (Case, Let) appear in expression
  -- position -- Go's statement-bodied analogue of Julia's IIFE / Python's
  -- walrus-tuple.
  | GoIIFE [GoStmt]
  -- | Composite literals
  | GoSliceLit [GoExpr]               -- ^ []any{ ... }
  | GoMapLit [(Text, GoExpr)]         -- ^ map[string]any{ "k": v, ... }
  -- | An ADT value:  V{Tag: "Just", Fields: []any{x}}
  | GoADT Text [GoExpr]
  -- | Index into a map[string]any:  m["k"]   (used for record/dict access)
  | GoMapIndex GoExpr Text
  -- | Index into a slice:  s[i]
  | GoSliceIndex GoExpr GoExpr
  -- | Binary op (used by pretty for conditions): a == b, a && b, len(x) == n
  | GoBinary Text GoExpr GoExpr
  -- | A pre-rendered raw Go expression escape hatch (FFI shim bodies, runtime helpers)
  | GoRaw Text
  deriving (Show, Eq)

-- | Go statements (the thing the family emitter could not produce).
data GoStmt
  = GoReturn GoExpr                   -- ^ return e
  | GoAssign Text GoExpr              -- ^ x := e
  -- | @var x any = e@. Unlike @:=@ this forces the binding to interface type,
  -- so a subsequent @x.(func(any) any)(arg)@ assertion is legal even when @e@
  -- is a concrete closure literal. Used for non-recursive @let@ bindings.
  | GoVarDef Text GoExpr
  | GoExprStmt GoExpr                 -- ^ e   (effectful call in statement position)
  | GoIf GoExpr [GoStmt]              -- ^ if cond { body }   (no else; fall-through model)
  | GoBlockStmt [GoStmt]              -- ^ { ... }
  | GoPanic Text                      -- ^ panic("...")  (pattern-match failure)
  | GoRawStmt Text                    -- ^ pre-rendered raw statement
  deriving (Show, Eq)

-- | Top-level Go declarations.
data GoDecl
  = GoVarDecl Text GoExpr             -- ^ var x any = e
  | GoFuncDecl Text [Text] [GoStmt]   -- ^ func name(params...) any { body }  (rare; closures preferred)
  | GoRawDecl Text                    -- ^ pre-rendered (runtime preamble, FFI)
  deriving (Show, Eq)
