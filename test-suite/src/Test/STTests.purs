-- | ST: STRef, the ST loop combinators, and the full STArray surface.
module Test.STTests where

import Prelude

import Control.Monad.ST (ST)
import Control.Monad.ST as ST
import Control.Monad.ST.Ref as Ref
import Data.Array.ST as STA
import Data.Maybe (Maybe)
import Effect (Effect)
import Effect.Console (log)

t :: String -> String -> Effect Unit
t name v = log ("TEST " <> name <> ": " <> v)

buildAndSort :: forall r. ST r (Array Int)
buildAndSort = do
  arr <- STA.new
  _ <- STA.push 3 arr
  _ <- STA.push 1 arr
  _ <- STA.pushAll [ 5, 2, 4 ] arr
  _ <- STA.sort arr
  STA.freeze arr

main :: Effect Unit
main = do
  log "=== Test.STTests ==="
  -- STRef
  t "stref-basic"
    ( show
        ( ST.run do
            r <- Ref.new 1
            _ <- Ref.write 5 r
            _ <- Ref.modify (_ * 10) r
            Ref.read r
        )
    )
  t "st-for"
    ( show
        ( ST.run do
            r <- Ref.new 0
            ST.for 0 10 \i -> void (Ref.modify (_ + i) r)
            Ref.read r
        )
    )
  t "st-while"
    ( show
        ( ST.run do
            r <- Ref.new 1
            ST.while ((_ < 1000) <$> Ref.read r) (void (Ref.modify (_ * 2) r))
            Ref.read r
        )
    )
  t "st-foreach"
    ( show
        ( ST.run do
            r <- Ref.new 0
            ST.foreach [ 1, 2, 3, 4 ] \i -> void (Ref.modify (_ + i) r)
            Ref.read r
        )
    )
  -- STArray
  t "starray-build-sort" (show (ST.run buildAndSort))
  t "starray-pop"
    ( show
        ( ST.run do
            arr <- STA.thaw [ 1, 2, 3 ]
            p <- STA.pop arr
            frozen <- STA.freeze arr
            pure (show p <> "|" <> show frozen)
        )
    )
  t "starray-shift"
    ( show
        ( ST.run do
            arr <- STA.thaw [ 1, 2, 3 ]
            s <- STA.shift arr
            frozen <- STA.freeze arr
            pure (show s <> "|" <> show frozen)
        )
    )
  t "starray-unshift"
    ( show
        ( ST.run do
            arr <- STA.thaw [ 3, 4 ]
            _ <- STA.unshiftAll [ 1, 2 ] arr
            STA.freeze arr
        )
    )
  t "starray-peek-ok" (show (ST.run (STA.thaw [ 10, 20 ] >>= STA.peek 1) :: Maybe Int))
  t "starray-peek-oob" (show (ST.run (STA.thaw [ 10, 20 ] >>= STA.peek 5) :: Maybe Int))
  t "starray-poke"
    ( show
        ( ST.run do
            arr <- STA.thaw [ 1, 2, 3 ]
            ok <- STA.poke 1 99 arr
            frozen <- STA.freeze arr
            pure (show ok <> "|" <> show frozen)
        )
    )
  t "starray-poke-oob"
    ( show
        ( ST.run do
            arr <- STA.thaw [ 1 ]
            ok <- STA.poke 5 99 arr
            frozen <- STA.freeze arr
            pure (show ok <> "|" <> show frozen)
        )
    )
  t "starray-splice"
    ( show
        ( ST.run do
            arr <- STA.thaw [ 1, 2, 3, 4, 5 ]
            removed <- STA.splice 1 2 [ 9, 9, 9 ] arr
            frozen <- STA.freeze arr
            pure (show removed <> "|" <> show frozen)
        )
    )
  t "starray-length"
    ( show
        ( ST.run do
            arr <- STA.thaw [ 1, 2, 3 ]
            STA.length arr
        )
    )
  -- freeze is a copy: later mutation must not leak
  t "starray-freeze-copies"
    ( show
        ( ST.run do
            arr <- STA.thaw [ 1, 2 ]
            frozen <- STA.freeze arr
            _ <- STA.push 3 arr
            pure frozen
        )
    )
