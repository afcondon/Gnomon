-- | Pattern matching shapes: literals, arrays, records, nesting, named
-- | binders, guards with fall-through, and multi-scrutinee cases.
module Test.PatternMatch where

import Prelude

import Data.Maybe (Maybe(..))
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Console (log)

t :: String -> String -> Effect Unit
t name v = log ("TEST " <> name <> ": " <> v)

intLit :: Int -> String
intLit = case _ of
  0 -> "zero"
  1 -> "one"
  _ -> "many"

strLit :: String -> String
strLit = case _ of
  "" -> "empty"
  "hi" -> "greeting"
  _ -> "other"

charLit :: Char -> String
charLit = case _ of
  'a' -> "first"
  'z' -> "last"
  _ -> "middle"

boolLit :: Boolean -> String
boolLit = case _ of
  true -> "T"
  false -> "F"

arrayPat :: Array Int -> String
arrayPat = case _ of
  [] -> "empty"
  [ x ] -> "one:" <> show x
  [ x, _ ] -> "two-first:" <> show x
  [ _, _, z ] -> "three-last:" <> show z
  _ -> "many"

recordPat :: { x :: Int, y :: Int } -> String
recordPat = case _ of
  { x: 0, y } -> "on-y-axis:" <> show y
  { x, y: 0 } -> "on-x-axis:" <> show x
  { x, y } -> show (x + y)

nested :: Maybe (Tuple Int (Array Int)) -> String
nested = case _ of
  Just (Tuple n [ a, b ]) -> show (n + a + b)
  Just (Tuple n _) -> "n:" <> show n
  Nothing -> "none"

named :: Maybe Int -> String
named = case _ of
  m@(Just x) | x > 5 -> "big " <> show m
  Just x -> "small " <> show x
  Nothing -> "none"

multi :: Int -> Int -> String
multi a b = case a, b of
  0, 0 -> "origin"
  0, _ -> "y-axis"
  _, 0 -> "x-axis"
  x, y | x == y -> "diagonal"
  _, _ -> "general"

guardsFall :: Int -> String
guardsFall n = case n of
  x | x > 100 -> "huge"
    | x > 10 -> "big"
  _ -> "small"

main :: Effect Unit
main = do
  log "=== Test.PatternMatch ==="
  t "int-0" (intLit 0)
  t "int-1" (intLit 1)
  t "int-9" (intLit 9)
  t "str-empty" (strLit "")
  t "str-hi" (strLit "hi")
  t "str-other" (strLit "yo")
  t "char-a" (charLit 'a')
  t "char-m" (charLit 'm')
  t "bool-true" (boolLit true)
  t "array-empty" (arrayPat [])
  t "array-one" (arrayPat [ 7 ])
  t "array-two" (arrayPat [ 7, 8 ])
  t "array-three" (arrayPat [ 7, 8, 9 ])
  t "array-many" (arrayPat [ 1, 2, 3, 4 ])
  t "record-y-axis" (recordPat { x: 0, y: 5 })
  t "record-x-axis" (recordPat { x: 5, y: 0 })
  t "record-general" (recordPat { x: 2, y: 3 })
  t "nested-pair" (nested (Just (Tuple 1 [ 2, 3 ])))
  t "nested-other" (nested (Just (Tuple 1 [ 2, 3, 4 ])))
  t "nested-none" (nested Nothing)
  t "named-big" (named (Just 9))
  t "named-small" (named (Just 3))
  t "multi-origin" (multi 0 0)
  t "multi-y" (multi 0 5)
  t "multi-diag" (multi 4 4)
  t "multi-general" (multi 1 2)
  t "guards-huge" (guardsFall 500)
  t "guards-big" (guardsFall 50)
  t "guards-small" (guardsFall 5)
  -- where + let + if-then-else
  t "let-in" (let a = 3 in show (a * a))
  t "if-then-else" (if 1 < 2 then "lt" else "ge")
