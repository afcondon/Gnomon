-- | Data.String surface: Common, CodeUnits, CodePoints, Unsafe.
-- | ASCII and BMP unicode agree across backends; astral-plane tests are
-- | listed in the runner's KNOWN_DIVERGENCES (JS counts UTF-16 code
-- | units, the Julia backend counts codepoints).
module Test.Strings where

import Prelude

import Data.Maybe (Maybe(..))
import Data.String (Pattern(..), Replacement(..))
import Data.String as S
import Data.String.CodeUnits as CU
import Data.String.Common as SC
import Effect (Effect)
import Effect.Console (log)

t :: String -> String -> Effect Unit
t name v = log ("TEST " <> name <> ": " <> v)

main :: Effect Unit
main = do
  log "=== Test.Strings ==="
  -- Common
  t "toUpper" (SC.toUpper "hello")
  t "toLower" (SC.toLower "HeLLo")
  t "trim" (SC.trim "  pad  ")
  t "trim-empty" (show (SC.trim "   "))
  t "joinWith" (SC.joinWith "-" [ "a", "b", "c" ])
  t "joinWith-empty" (SC.joinWith "x" [])
  t "split" (show (SC.split (Pattern ",") "a,b,c"))
  t "split-none" (show (SC.split (Pattern ";") "a,b"))
  t "split-trailing" (show (SC.split (Pattern ",") "a,b,"))
  t "split-empty-pat" (show (SC.split (Pattern "") "abc"))
  t "split-empty-both" (show (SC.split (Pattern "") ""))
  t "split-empty-str" (show (SC.split (Pattern ",") ""))
  t "replace" (SC.replace (Pattern "l") (Replacement "L") "hello")
  t "replace-missing" (SC.replace (Pattern "z") (Replacement "L") "hello")
  t "replaceAll" (SC.replaceAll (Pattern "l") (Replacement "L") "hello")
  t "replaceAll-multi" (SC.replaceAll (Pattern "ab") (Replacement "x") "ababab")
  t "localeCompare-lt" (show (SC.localeCompare "a" "b"))
  t "localeCompare-eq" (show (SC.localeCompare "a" "a"))
  t "null-empty" (show (SC.null ""))
  t "null-nonempty" (show (SC.null "a"))
  -- CodeUnits
  t "cu-length" (show (CU.length "hello"))
  t "cu-length-empty" (show (CU.length ""))
  t "cu-length-bmp" (show (CU.length "café"))
  t "cu-charAt-ok" (show (CU.charAt 1 "abc"))
  t "cu-charAt-oob" (show (CU.charAt 3 "abc"))
  t "cu-charAt-neg" (show (CU.charAt (-1) "abc"))
  t "cu-singleton" (CU.singleton 'x')
  t "cu-fromCharArray" (CU.fromCharArray [ 'a', 'b' ])
  t "cu-toCharArray" (show (CU.toCharArray "abc"))
  t "cu-toChar-ok" (show (CU.toChar "a"))
  t "cu-toChar-long" (show (CU.toChar "ab"))
  t "cu-take" (CU.take 3 "purescript")
  t "cu-take-more" (CU.take 99 "abc")
  t "cu-take-neg" (show (CU.take (-1) "abc"))
  t "cu-drop" (CU.drop 4 "purescript")
  t "cu-drop-more" (show (CU.drop 99 "abc"))
  t "cu-countPrefix" (show (CU.countPrefix (_ == 'a') "aabbc"))
  t "cu-indexOf" (show (CU.indexOf (Pattern "ll") "hello"))
  t "cu-indexOf-missing" (show (CU.indexOf (Pattern "z") "hello"))
  t "cu-indexOf-empty" (show (CU.indexOf (Pattern "") "hello"))
  t "cu-indexOf-from" (show (CU.indexOf' (Pattern "l") 3 "hello"))
  t "cu-indexOf-from-oob" (show (CU.indexOf' (Pattern "l") 9 "hello"))
  t "cu-lastIndexOf" (show (CU.lastIndexOf (Pattern "l") "hello"))
  t "cu-lastIndexOf-from" (show (CU.lastIndexOf' (Pattern "l") 2 "hello"))
  t "cu-slice" (CU.slice 1 3 "abcde")
  t "cu-slice-neg" (CU.slice (-3) (-1) "abcde")
  t "cu-slice-cross" (show (CU.slice 3 1 "abcde"))
  t "cu-splitAt" (show (CU.splitAt 2 "abcde"))
  t "cu-splitAt-zero" (show (CU.splitAt 0 "ab"))
  t "cu-splitAt-end" (show (CU.splitAt 5 "ab"))
  t "cu-stripPrefix" (show (CU.stripPrefix (Pattern "ab") "abcd"))
  t "cu-stripSuffix" (show (CU.stripSuffix (Pattern "cd") "abcd"))
  t "cu-contains" (show (CU.contains (Pattern "bc") "abcd"))
  -- CodePoints (Data.String re-exports)
  t "cp-length" (show (S.length "hello"))
  t "cp-length-bmp" (show (S.length "café"))
  t "cp-take" (S.take 2 "café")
  t "cp-drop" (S.drop 2 "café")
  t "cp-indexOf" (show (S.indexOf (Pattern "fé") "café"))
  t "cp-codePointAt" (show (S.codePointAt 1 "abc"))
  t "cp-toCodePointArray" (show (S.toCodePointArray "ab"))
  t "cp-fromCodePointArray" (S.fromCodePointArray (S.toCodePointArray "hi"))
  t "cp-countPrefix" (show (S.countPrefix (_ == S.codePointFromChar 'a') "aab"))
  t "cp-singleton" (S.singleton (S.codePointFromChar 'z'))
  -- string ordering and append
  t "string-compare" (show (compare "abc" "abd"))
  t "string-compare-len" (show (compare "ab" "abc"))
  t "string-eq" (show ("abc" == "abc"))
  t "string-append" ("foo" <> "bar")
  t "show-string-escape" (show "a\"b\\c")
  t "show-string-newline" (show "a\nb")
  -- char
  t "char-show" (show 'x')
  t "char-compare" (show (compare 'a' 'b'))
  -- astral plane: KNOWN DIVERGENCE (JS UTF-16 code units vs codepoints)
  t "ASTRAL-cu-length-emoji" (show (CU.length "😀"))
  t "ASTRAL-cu-take-emoji" (CU.take 1 "😀x")
  t "cp-length-emoji" (show (S.length "😀"))
