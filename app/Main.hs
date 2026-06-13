{-# LANGUAGE OverloadedStrings #-}

module Main where

import Prelude
import System.Environment (getArgs)
import Language.PureScript.Go.Make (compile, CompileOptions(..))

-- | Usage:
--   psgo [INPUT_DIR] [OUTPUT_DIR] [--entry Module.Name]
-- The optional --entry restricts emission to that module's transitive import
-- closure and runs its `main` (per-test conformance driving). Without it, all
-- user modules are emitted and Main / the sole module with `main` is run.
main :: IO ()
main = do
  args <- getArgs
  let (entry, positional) = takeEntry args
      opts inp out = CompileOptions { inputDir = inp, outputDir = out, entryModule = entry }
  case positional of
    []                -> compile (opts "output" "output-go")
    [input]           -> compile (opts input "output-go")
    [input, output]   -> compile (opts input output)
    _                 -> putStrLn "Usage: psgo [INPUT_DIR] [OUTPUT_DIR] [--entry Module.Name]"

-- | Pull a @--entry NAME@ pair out of the argument list, returning the name
-- (if present) and the remaining positional arguments.
takeEntry :: [String] -> (Maybe String, [String])
takeEntry = go (Nothing, [])
  where
    go (_, acc) ("--entry":name:rest) = go (Just name, acc) rest
    go (e, acc) (x:rest)              = go (e, acc ++ [x]) rest
    go acc []                         = acc
