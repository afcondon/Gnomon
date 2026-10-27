-- | Self tail calls deep enough that only a real loop survives them.
-- |
-- | `Test.Recursion` stops at 10^6, which Go's growable stack absorbs even as
-- | plain recursion. At 10^7 plain recursion through the IIFEs that `case` and
-- | `let` compile to dies with `fatal error: stack overflow` on Go, while the
-- | JS reference runs it as a loop. So every deep row here is a test that the
-- | code generator turned the self tail call into iteration.
-- |
-- | Gnomon-only for now: the shared corpus is byte-identical across Gnomon,
-- | Jurist and Pythia, and this module should join it there too.
module Test.DeepTailCalls where

import Prelude

import Data.Array as A
import Data.Maybe (Maybe(..))
import Effect (Effect)
import Effect.Console (log)

t :: String -> String -> Effect Unit
t name v = log ("TEST " <> name <> ": " <> v)

deep :: Int
deep = 10000000

-- The reviewed shape: if-then-else, top level.
countDown :: Int -> Int -> Int
countDown acc n = if n == 0 then acc else countDown (acc + 1) (n - 1)

-- The same loop as a local `go` (a let-bound Rec group).
countLocal :: Int -> Int
countLocal n0 = go 0 n0
  where
  go acc n = if n == 0 then acc else go (acc + 1) (n - 1)

-- Tail calls under a let and a nested case, two of them.
stepper :: Int -> Int -> Int
stepper acc n =
  let m = n - 1 in
  case n of
    0 -> acc
    _ -> case mod n 3 of
      0 -> stepper (acc + 2) m
      _ -> stepper (acc + 1) m

-- Tail calls through guards.
guarded :: Int -> Int -> Int
guarded acc n
  | n == 0 = acc
  | mod n 2 == 0 = guarded (acc + 2) (n - 1)
  | otherwise = guarded (acc - 1) (n - 1)

-- A parameter the body never reads.
ignoresFirst :: Int -> Int -> Int
ignoresFirst _ n = if n == 0 then 0 else ignoresFirst n (n - 1)

-- A pattern that rebinds a parameter's name.
rebinding :: Int -> Maybe Int -> Int
rebinding n m = case m of
  Nothing -> n
  Just n' | n' >= deep -> n'
  Just n -> rebinding (n + 7) (Just (n + 1))

-- A partially applied loop, applied twice: running it must not disturb the
-- arguments its prefix captured.
countFrom :: Int -> Int -> Int
countFrom acc n = if n == 0 then acc else countFrom (acc + 1) (n - 1)

-- Closures built inside the loop must keep their own iteration's value.
closures :: Int -> Array (Int -> Int) -> Array (Int -> Int)
closures k acc = if k == 0 then acc else closures (k - 1) (A.snoc acc (\x -> x + k))

main :: Effect Unit
main = do
  log "=== Test.DeepTailCalls ==="
  t "countDown-1e7" (show (countDown 0 deep))
  t "countLocal-1e7" (show (countLocal deep))
  t "stepper-1e7" (show (stepper 0 deep))
  t "guarded-1e7" (show (guarded 0 deep))
  t "ignoresFirst-1e7" (show (ignoresFirst 5 deep))
  t "rebinding-small" (show (rebinding 0 (Just (deep - 3))))
  t "rebinding-nothing" (show (rebinding 4 Nothing))
  let f = countFrom 5
  t "partial-reuse" (show [ f 3, f 10, f 0 ])
  t "closure-capture" (show (map (_ $ 0) (closures 4 [])))
