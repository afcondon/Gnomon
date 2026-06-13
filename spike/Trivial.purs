-- | Hand-written trivial module for the spike. Self-contained: its own FFI
-- | (goLog, goConcat, goIntToString) so the foreign surface is tiny and fully
-- | controlled. Exercises: Literal, Var, App, Abs, Let, Case, Constructor,
-- | local recursion-free arithmetic. No Prelude dictionaries.
module Trivial where

foreign import data Effect :: Type -> Type
foreign import data Unit :: Type

foreign import goLog :: String -> Effect Unit
foreign import goConcat :: String -> String -> String
foreign import goIntToString :: Int -> String
foreign import goAdd :: Int -> Int -> Int
foreign import goMul :: Int -> Int -> Int
foreign import pureEffect :: forall a. a -> Effect a
foreign import bindEffect :: forall a b. Effect a -> (a -> Effect b) -> Effect b

-- A local ADT to exercise Constructor + Case.
data Shape = Circle Int | Rect Int Int

area :: Shape -> Int
area s = case s of
  Circle r -> goMul (goMul 3 r) r
  Rect w h -> goMul w h

-- A let-binding + lambda + application.
label :: String -> Int -> String
label name n =
  let prefix = goConcat name ": "
  in goConcat prefix (goIntToString n)

main :: Effect Unit
main =
  bindEffect (goLog "=== Trivial ===") \_ ->
  bindEffect (goLog (label "TEST circle" (area (Circle 4)))) \_ ->
  bindEffect (goLog (label "TEST rect" (area (Rect 3 5)))) \_ ->
  bindEffect (goLog (label "TEST add" (goAdd 40 2))) \_ ->
  goLog "TEST done: ok"
