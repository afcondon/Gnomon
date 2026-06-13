{-# LANGUAGE OverloadedStrings #-}

-- |
-- Naming / identifier utilities for the Go backend.
--
-- Adapted from Julia's @CodeGen.Common@. Module names join segments with
-- underscores (@Data.Array@ -> @Data_Array@). Top-level names are emitted as
-- @<Module>_<ident>@ in a single flat package (plan ADR-0004 option b), so
-- there is no cross-package qualification at the Go level. Identifiers keep
-- camelCase; non-identifier chars are escaped; Go reserved words get a suffix.
--
module Language.PureScript.Go.CodeGen.Common
  ( goModulePrefix
  , goTopName
  , identToGoName
  , runIdent'
  , psStringToText
  , escapeGoString
  , nameIsGoReserved
  ) where

import Prelude
import Data.Char (isAlpha, isDigit)
import Data.Text (Text, uncons, singleton, pack)
import qualified Data.Text as T
import Data.Word (Word16)
import Language.PureScript.Names
    ( ModuleName(..), Ident(InternalIdent), runIdent
    , InternalIdentData(RuntimeLazyFactory, Lazy) )
import Language.PureScript.PSString (PSString, decodeStringEither)
import Numeric (showHex)

-- | Module-name prefix used to disambiguate top-level names in the flat
-- package, e.g. @Data.Maybe@ -> @Data_Maybe@.
goModulePrefix :: ModuleName -> Text
goModulePrefix (ModuleName name) = T.intercalate "_" (T.splitOn "." name)

-- | A fully-qualified top-level name in the flat package:
-- @Data.Maybe@ + @fromMaybe@ -> @Data_Maybe_fromMaybe@.
goTopName :: ModuleName -> Ident -> Text
goTopName mn ident = goModulePrefix mn <> "_" <> identToGoName ident

-- | Local identifier -> a valid Go identifier (camelCase preserved).
-- Go-reserved words get a trailing @_@. To keep this a BIJECTION (so the
-- PureScript identifiers @map@ and @map_@ -- which legitimately coexist, e.g.
-- @Control.Monad.ST.Internal@'s @map@ binding alongside its foreign @map_@ --
-- never collide), escape a name whenever its trailing-underscore-stripped CORE
-- is reserved. Thus @map@ -> @map_@, @map_@ -> @map__@: distinct stays distinct.
identToGoName :: Ident -> Text
identToGoName ident =
  let name = toGoIdent (runIdent' ident)
      core = T.dropWhileEnd (== '_') name
  in if nameIsGoReserved core then name <> "_" else name

-- | Lower-level char-escaping for identifiers.
toGoIdent :: Text -> Text
toGoIdent v = case uncons v of
  Just (h, t) -> replaceFirst h <> T.concatMap replaceChar t
  Nothing -> v
  where
    replaceChar '.'  = "_"
    replaceChar '$'  = "S_"
    replaceChar '\'' = "P_"     -- prime -> P_ (Go has no unicode-prime-as-ident idiom)
    replaceChar '-'  = "_"
    replaceChar c | isValidGoChar c = singleton c
    replaceChar c = "_u" <> hex 4 c

    replaceFirst x
      | isAlpha x || x == '_' = singleton x
      | otherwise = "_" <> replaceChar x

    isValidGoChar c = isAlpha c || isDigit c || c == '_'

-- | Raw text from an Ident, handling internal identifiers.
runIdent' :: Ident -> Text
runIdent' = \case
  InternalIdent RuntimeLazyFactory -> "_runtime_lazy"
  InternalIdent (Lazy name) -> "_lazy_" <> name
  other -> runIdent other

-- | A PSString -> escaped body for a Go double-quoted string literal.
psStringToText :: PSString -> Text
psStringToText a = foldMap escapeChar (decodeStringEither a)
  where
    escapeChar :: Either Word16 Char -> Text
    escapeChar (Left w)  = "\\u" <> hex 4 w
    escapeChar (Right c) = replaceBasicEscape c

replaceBasicEscape :: Char -> Text
replaceBasicEscape '\b' = "\\b"
replaceBasicEscape '\t' = "\\t"
replaceBasicEscape '\n' = "\\n"
replaceBasicEscape '\f' = "\\f"
replaceBasicEscape '\r' = "\\r"
replaceBasicEscape '"'  = "\\\""
replaceBasicEscape '\\' = "\\\\"
replaceBasicEscape c    = singleton c

-- | Escape plain Text for a Go string literal body.
escapeGoString :: Text -> Text
escapeGoString = T.concatMap replaceBasicEscape

hex :: (Enum a) => Int -> a -> Text
hex width c =
  let hs = showHex (fromEnum c) "" in
  pack (replicate (width - length hs) '0' <> hs)

-- | Go reserved words.
nameIsGoReserved :: Text -> Bool
nameIsGoReserved name = name `elem` goReserved

goReserved :: [Text]
goReserved =
  [ "break", "case", "chan", "const", "continue"
  , "default", "defer", "else", "fallthrough", "for"
  , "func", "go", "goto", "if", "import"
  , "interface", "map", "package", "range", "return"
  , "select", "struct", "switch", "type", "var"
  -- predeclared identifiers we must not shadow at top level
  , "any", "nil", "true", "false", "iota"
  , "len", "cap", "make", "new", "append", "panic"
  , "string", "int", "int64", "float64", "bool", "byte", "rune"
  ]
