module Main where

import Prelude

import ArgParse.Basic (ArgParser)
import ArgParse.Basic as ArgParser
import Data.Array as Array
import Data.Either (Either(..))
import Data.Map as Map
import Data.Maybe (Maybe(..))
import Data.Set as Set
import Data.String as String
import Dodo as Dodo
import Effect (Effect)
import Effect.Aff (Aff, launchAff_)
import Effect.Class.Console as Console
import Node.Encoding (Encoding(..))
import Node.FS.Aff as FS
import Node.FS.Perms as Perms
import Node.Path (FilePath)
import Node.Path as Path
import Node.Process as Process
import PureScript.Backend.Optimizer.Codegen.Go (codegenModule)
import PureScript.Backend.Optimizer.Codegen.Go.Builder (basicBuildMain)
import PureScript.Backend.Optimizer.CoreFn (ModuleName(..))
import PureScript.Backend.Optimizer.Semantics.Foreign (coreForeignSemantics)

type BuildArgs =
  { coreFnDir :: FilePath
  , outputDir :: FilePath
  }

argParser :: ArgParser BuildArgs
argParser =
  ArgParser.fromRecord
    { coreFnDir:
        ArgParser.argument [ "--corefn-dir" ]
          "Path to input directory containing corefn.json files (default ./output)."
          # ArgParser.default (Path.concat [ ".", "output" ])
    , outputDir:
        ArgParser.argument [ "--output-dir" ]
          "Path to output directory for Go files (default ./output-go-opt)."
          # ArgParser.default (Path.concat [ ".", "output-go-opt" ])
    }
    <* ArgParser.flagHelp

main :: Effect Unit
main = do
  args <- Array.drop 2 <$> Process.argv
  case ArgParser.parseArgs "backend-go" "PureScript Go backend (optimizer IR)." argParser args of
    Left err -> Console.error (ArgParser.printArgError err)
    Right buildArgs -> launchAff_ (build buildArgs)

build :: BuildArgs -> Aff Unit
build args = basicBuildMain
  { resolveCoreFnDirectory: pure args.coreFnDir
  , resolveExternalDirectives: pure Map.empty
  , analyzeCustom: \_ _ -> Nothing
  , foreignSemantics: coreForeignSemantics
  , onCodegenBefore: mkdirp args.outputDir
  , onCodegenAfter: pure unit
  , onPrepareModule: \_ coreFnMod -> pure coreFnMod
  , onCodegenModule: \_ _ backendMod _ -> do
      let
        ModuleName name = backendMod.name
        formatted = Dodo.print Dodo.plainText Dodo.twoSpaces (codegenModule { intTags: false } backendMod)
        fileName = String.replaceAll (String.Pattern ".") (String.Replacement "_") name <> ".go"
      FS.writeTextFile UTF8 (Path.concat [ args.outputDir, fileName ]) formatted
  , traceIdents: Set.empty
  }

mkdirp :: FilePath -> Aff Unit
mkdirp = flip FS.mkdir' { recursive: true, mode: Perms.mkPerms Perms.all Perms.all Perms.all }
