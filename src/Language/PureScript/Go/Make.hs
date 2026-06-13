{-# LANGUAGE OverloadedStrings #-}

-- |
-- Build orchestration for the Go backend.
--
-- Reads @corefn.json@ for every compiled module, emits ONE flat-package Go
-- file (@main.go@) containing: a package header + imports, the runtime
-- preamble (V struct, helpers), the built-in FFI shims, every emitted
-- module's mangled top-level vars, and a @func main()@ that runs the
-- entrypoint module's @main@ effect thunk. The whole file is piped through
-- @gofmt@.
--
-- Plan ADR-0004 option (b): single flat package, one var per top-level
-- binding, names mangled @Module_ident@. No loader (Go's package init handles
-- ordering).
--
-- Multi-module / conformance refinement of ADR-0004: when an entrypoint
-- module is named (e.g. @Test.Effects@), restrict emission to that module's
-- transitive import closure, emitted dependencies-first (topological). This
-- lets each Test.* corpus module be walked to green INDEPENDENTLY -- a single
-- unimplemented node or missing foreign shim in some unrelated library module
-- no longer blocks every test. Without an entrypoint, behaviour is unchanged
-- (emit all user modules, run Main / the sole module with a @main@).
--
module Language.PureScript.Go.Make
  ( compile
  , CompileOptions(..)
  ) where

import Prelude

import Control.Monad (forM, forM_, when, unless)
import Data.Aeson (decodeFileStrict)
import Data.Aeson.Types (parseMaybe)
import Data.List (find, isPrefixOf)
import Data.Maybe (catMaybes, mapMaybe)
import qualified Data.Map as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory (createDirectoryIfMissing)
import System.Exit (ExitCode(..))
import System.FilePath ((</>))
import System.FilePath.Glob (glob)
import System.Process (readProcessWithExitCode)

import qualified Language.PureScript as P
import qualified Language.PureScript.CoreFn as CoreFn
import qualified Language.PureScript.CoreFn.FromJSON as CoreFn

import Language.PureScript.Go.CodeGen (generateModule)
import Language.PureScript.Go.CodeGen.Common (goModulePrefix)
import Language.PureScript.Go.CodeGen.Pretty (prettyProgram)
import Language.PureScript.Go.Foreigns (preludeFile)

data CompileOptions = CompileOptions
  { inputDir :: FilePath
  , outputDir :: FilePath
  -- | When @Just mn@, restrict emission to the transitive import closure of
  -- module @mn@ and run its @main@. When @Nothing@, emit all user modules and
  -- run Main / the sole module with a top-level @main@.
  , entryModule :: Maybe String
  }

compile :: CompileOptions -> IO ()
compile opts = do
  let coreFnGlob = inputDir opts </> "*" </> "corefn.json"
  corefnFiles <- glob coreFnGlob

  when (null corefnFiles) $
    putStrLn "No corefn.json files found. Run purs --codegen corefn first."

  unless (null corefnFiles) $ do
    createDirectoryIfMissing True (outputDir opts)

    mods <- fmap catMaybes . forM corefnFiles $ \f -> do
      mJson <- decodeFileStrict f
      case mJson >>= parseMaybe CoreFn.moduleFromJSON of
        Nothing -> putStrLn ("Error: failed to parse " ++ f) >> return Nothing
        Just (_v, m) -> return (Just m)

    let userMods = filter (not . isPrimMod . CoreFn.moduleName) mods
        byName   = Map.fromList [ (CoreFn.moduleName m, m) | m <- userMods ]

        -- The entrypoint: an explicitly-named module, else Main, else the
        -- sole module carrying a top-level `main`.
        mainMod = case entryModule opts of
          Just s  -> Map.lookup (P.ModuleName (T.pack s)) byName
          Nothing -> find ((== P.ModuleName "Main") . CoreFn.moduleName) userMods
                     `orElse` find hasMain userMods

        -- Emission set, dependencies-first. With an entrypoint, restrict to
        -- its transitive closure; otherwise emit everything.
        orderedNames = loadOrder userMods mainMod
        emitMods = mapMaybe (`Map.lookup` byName) orderedNames

        decls = concatMap generateModule emitMods
        body  = prettyProgram decls
        -- main is a generated binding, so it is a lazy thunk: _force it to the
        -- Effect value (itself a `func() any`), then run that effect.
        mainCall = case mainMod of
          Just m  -> "_force(" <> goModulePrefix (CoreFn.moduleName m) <> "_main).(func() any)()"
          Nothing -> ""   -- nothing to run
        file = assembleFile body mainCall

    putStrLn $ "Emitting " ++ show (length emitMods) ++ " of "
            ++ show (length userMods) ++ " user modules"
            ++ maybe "" (\s -> " (closure of " ++ s ++ ")") (entryModule opts)

    -- Report reachable modules that have foreign imports -- each is a shim we
    -- must have authored in Foreigns.hs (or a Go compile error follows). This
    -- is the per-module foreign-gap signal for the red->green walk.
    let foreignMods = [ mn | m <- emitMods
                           , let mn = CoreFn.moduleName m
                           , not (null (CoreFn.moduleForeign m)) ]
    unless (null foreignMods) $ do
      putStrLn $ "Reachable modules with foreign imports (need Go shims): "
              ++ show (length foreignMods)
      forM_ foreignMods $ \(P.ModuleName mn) ->
        putStrLn ("  FOREIGN " ++ T.unpack mn)

    -- The static prelude (runtime + foreign shims) is a sibling package-main
    -- file; the generated module bodies + main live in main.go. Both are
    -- gofmt'd; run with `go run main.go prelude.go`.
    let preludePath = outputDir opts </> "prelude.go"
        mainPath    = outputDir opts </> "main.go"
    TIO.writeFile preludePath preludeFile
    TIO.writeFile mainPath file
    putStrLn $ "Wrote: " ++ mainPath ++ " + " ++ preludePath

    -- gofmt post-pass (formats + reports syntax errors) on both files.
    mapM_ gofmtInPlace [preludePath, mainPath]
    putStrLn "Done."

-- | Run gofmt over a file in place; report syntax errors.
gofmtInPlace :: FilePath -> IO ()
gofmtInPlace path = do
  (code, out, err) <- readProcessWithExitCode "gofmt" [path] ""
  case code of
    ExitSuccess   -> TIO.writeFile path (T.pack out) >> putStrLn ("gofmt OK: " ++ path)
    ExitFailure n -> putStrLn ("gofmt FAILED (" ++ show n ++ ") on " ++ path ++ ":\n" ++ err)

isPrimMod :: P.ModuleName -> Bool
isPrimMod (P.ModuleName n) = "Prim" `isPrefixOf` T.unpack n

hasMain :: CoreFn.Module CoreFn.Ann -> Bool
hasMain m = any bindHasMain (CoreFn.moduleDecls m)
  where
    bindHasMain (CoreFn.NonRec _ i _) = i == P.Ident "main"
    bindHasMain (CoreFn.Rec bs) = any (\((_, i), _) -> i == P.Ident "main") bs

-- | First Just, else the second.
orElse :: Maybe a -> Maybe a -> Maybe a
orElse (Just x) _ = Just x
orElse Nothing y  = y

-- | Dependencies-first module order. When an entrypoint module is given,
-- restrict to its transitive import closure; otherwise order everything.
-- (Ported from Jurist's loadOrder; we keep only the ordering, not the loader.)
loadOrder :: [CoreFn.Module CoreFn.Ann] -> Maybe (CoreFn.Module CoreFn.Ann) -> [P.ModuleName]
loadOrder mods mainMod =
  let compiled = Set.fromList (map CoreFn.moduleName mods)
      depsOf = Map.fromList
        [ ( CoreFn.moduleName m
          , dedupe [ d | d <- map snd (CoreFn.moduleImports m)
                       , d /= CoreFn.moduleName m
                       , d `Set.member` compiled ] )
        | m <- mods ]
      roots = case mainMod of
        Just m  -> [CoreFn.moduleName m]
        Nothing -> map CoreFn.moduleName mods
      -- DFS post-order: dependencies emitted before dependents.
      visit (visited, acc) mn
        | mn `Set.member` visited = (visited, acc)
        | otherwise =
            let (visited', acc') =
                  foldl visit (Set.insert mn visited, acc)
                        (Map.findWithDefault [] mn depsOf)
            in (visited', acc' ++ [mn])
  in snd (foldl visit (Set.empty, []) roots)

dedupe :: Ord a => [a] -> [a]
dedupe = go Set.empty
  where
    go _ [] = []
    go seen (x:xs)
      | x `Set.member` seen = go seen xs
      | otherwise = x : go (Set.insert x seen) xs

-- | Assemble main.go: the generated module bodies + the entrypoint runner.
-- The runtime (V struct, helpers) and foreign shims live in the sibling
-- prelude.go (same @package main@), so this file needs no imports of its own --
-- everything it references (V, Module_member shims, other module vars) is in
-- the same package.
assembleFile :: Text -> Text -> Text
assembleFile body mainCall = T.unlines
  [ "// Generated by psgo. Do not edit. Run with: go run main.go prelude.go"
  , "package main"
  , ""
  , body
  , ""
  , "func main() {"
  , "  " <> mainCall
  , "}"
  ]
