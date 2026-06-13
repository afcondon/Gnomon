{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

-- |
-- The static Go prelude: runtime representation helpers (the @V@ struct,
-- curry/eq/show/ord helpers) plus the foreign-shim catalogue (the analogue of
-- Julia's 820-line @Foreigns.hs@). It is authored as REAL Go in
-- @runtime/prelude.go@ -- gofmt-checked, syntax-highlighted, directly testable
-- with @go run@ -- and embedded into the psgo binary at compile time. psgo
-- writes it out verbatim as @prelude.go@ alongside the generated @main.go@
-- (both @package main@), and the runner does @go run main.go prelude.go@.
--
-- ADR-0004 refinement: the family's Julia backend emits a separate
-- @purejl_runtime.jl@; we do the same with @prelude.go@ rather than inlining
-- the catalogue as Haskell string literals. This keeps the 200+ foreign shims
-- maintainable as ordinary Go. ADR-0005 (FFI doctrine) still holds: each shim
-- mirrors the real JS foreign in @output/<Module>/foreign.js@.
--
module Language.PureScript.Go.Foreigns
  ( preludeFile
  ) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.FileEmbed (embedStringFile)

-- | The complete @prelude.go@ source, embedded from @runtime/prelude.go@ at
-- compile time (path relative to the package root).
preludeFile :: Text
preludeFile = T.pack $(embedStringFile "runtime/prelude.go")
