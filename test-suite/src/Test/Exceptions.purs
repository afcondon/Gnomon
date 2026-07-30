-- | `Effect.Exception` — throwing, catching, and the shape of an `Error`.
-- |
-- | Added 2026-07-30, when the portability index showed `Effect.Exception`
-- | MISSING on all three backends: exceptions were unusable anywhere off
-- | JavaScript, and nothing said so. The gap was invisible until the index
-- | scanned the union of the backends' package closures rather than one of
-- | them.
-- |
-- | Everything asserted here is observable from portable PureScript, so it
-- | must agree byte-for-byte with the JS reference. Stack traces are
-- | deliberately not compared — every runtime formats them differently, and
-- | the corpus only ever tests what a portable program can rely on.
module Test.Exceptions where

import Prelude

import Data.Either (Either(..), either, isLeft, isRight)
import Data.Maybe (Maybe(..), isJust)
import Effect (Effect)
import Effect.Console (log)
import Effect.Exception (Error, catchException, error, message, name, stack, throw, throwException, try)

t :: String -> String -> Effect Unit
t label value = log ("TEST " <> label <> ": " <> value)

-- | The value carried out of a catch, so the handler's result is observable
-- | rather than just its having run.
describe :: Error -> String
describe e = name e <> "/" <> message e

main :: Effect Unit
main = do
  -- construction, without any throwing
  t "message" (message (error "boom"))
  t "name" (name (error "boom"))
  t "message-empty" (show (message (error "")))

  -- throw and catch round-trip
  caught <- catchException (\e -> pure (describe e)) (throwException (error "kaboom"))
  t "catch-thrown" caught

  -- the handler is not run when nothing throws
  quiet <- catchException (\_ -> pure "handler") (pure "body")
  t "catch-no-throw" quiet

  -- `throw` is `throwException <<< error`
  viaThrow <- catchException (\e -> pure (message e)) (throw "via-throw")
  t "catch-throw" viaThrow

  -- `try` reifies the exception as an Either
  r1 :: Either Error String <- try (pure "fine")
  t "try-ok" (either describe identity r1)
  t "try-ok-isRight" (show (isRight r1))

  r2 :: Either Error String <- try (throw "lifted")
  t "try-err" (either message identity r2)
  t "try-err-isLeft" (show (isLeft r2))

  -- catching is not a one-shot: a second throw inside a handler still throws
  nested <- catchException
              (\outer -> pure ("outer:" <> message outer))
              (catchException (\inner -> throw ("re:" <> message inner))
                              (throw "first"))
  t "catch-rethrow" nested

  -- an Error value can be carried and inspected without being thrown
  let held = error "held"
  t "held-message" (message held)
  t "held-not-thrown" (show (message held == "held"))

  -- `stack` is genuinely runtime-specific, and the honest thing is to let the
  -- corpus say so rather than to write an assertion weak enough to pass
  -- everywhere. JavaScript captures a stack when the Error is CONSTRUCTED;
  -- Python attaches a traceback only once an exception has been raised, and
  -- Julia does not attach one to a value at all. `Maybe` is exactly the right
  -- type for that, and this is a registered divergence, not a bug.
  t "STACK-present-on-construction" (show (isJust (stack (error "st"))))

  -- ordering: effects before a throw still happen
  ordered <- catchException (\e -> pure (message e)) do
    _ <- pure unit
    throw "after-effects"
  t "effects-before-throw" ordered
