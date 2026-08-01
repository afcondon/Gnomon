-- | The only foreign in the performance corpus, and it carries two jobs.
-- |
-- | **The clock.** Timing happens *inside* PureScript so that every backend
-- | runs byte-identical measurement code. A harness written once per backend
-- | in the host language would drift, and the drift would be invisible: it
-- | would look like a performance difference.
-- |
-- | **The FFI probes.** `ffiInc` is the smallest possible crossing of the
-- | seam — one `Int` in, one `Int` out — so `ffi-call` minus `loop-fore`
-- | isolates the per-call cost of the boundary itself, both shapes being
-- | otherwise the same loop over the same `Ref`. `ffiSumArray` crosses a
-- | whole array in one call, so it measures marshalling rather than call
-- | overhead.
-- |
-- | A caveat worth stating rather than hiding: a host compiler is free to
-- | inline `ffiInc`, because on the far side of the seam it is an ordinary
-- | function in that language. Where that happens the measured cost is the
-- | honest cost *for a trivial foreign* and is a floor, not a typical value.
module Bench.Clock
  ( nowNs
  , flushOut
  , ffiInc
  , ffiSumArray
  ) where

import Data.Unit (Unit)
import Effect (Effect)

-- | Monotonic clock, nanoseconds, as a `Number`.
-- |
-- | `Number` holds integral values exactly up to 2^53 ns — about 104 days —
-- | so no precision is lost at any duration this harness will ever see, and
-- | using `Number` avoids the Int-width question the backends disagree on.
foreign import nowNs :: Effect Number

-- | Flush stdout after every emitted line.
-- |
-- | Not cosmetic. A runtime that block-buffers stdout when it is redirected
-- | — Julia does — yields NOTHING at all when a shape runs long, so a lane
-- | that dies on a timeout dies with no information about which shape hung.
-- | Flushing per line turns "the perf lane hung" into "the perf lane hung on
-- | fold-list at n=400", and makes every measurement taken before the hang a
-- | result rather than a casualty.
foreign import flushOut :: Effect Unit

-- | `\x -> x + 1`, on the far side of the FFI seam.
foreign import ffiInc :: Int -> Int

-- | Sum an array, on the far side of the FFI seam. Crossing cost scales with
-- | the array rather than with the number of calls.
foreign import ffiSumArray :: Array Int -> Int
