-- | Coverage: monad transformers -- the State monad (a newtype over `s -> Tuple a s`
-- | with a tower of Functor/Apply/Bind/MonadState dictionaries) driven through
-- | do-notation and Traversable. The kind of dictionary-heavy plumbing the narrow
-- | corpus never touched.
module Test.Transformers where

import Prelude

import Control.Monad.State (State, evalState, execState, get, modify_, put, runState)
import Data.Traversable (traverse)
import Effect (Effect)
import Effect.Console (log)

counter :: State Int Int
counter = do
  modify_ (_ + 1)
  modify_ (_ + 1)
  n <- get
  put (n * 10)
  get

labelAll :: Array String -> State Int (Array String)
labelAll = traverse \s -> do
  n <- get
  modify_ (_ + 1)
  pure (show n <> ":" <> s)

t :: String -> String -> Effect Unit
t name v = log ("TEST " <> name <> ": " <> v)

main :: Effect Unit
main = do
  log "=== Test.Transformers ==="
  t "runState" (show (runState counter 0))
  t "evalState" (show (evalState counter 5))
  t "execState" (show (execState counter 5))
  t "stateful-traverse" (show (runState (labelAll [ "a", "b", "c" ]) 0))
