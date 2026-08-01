-- | The shapes. Deliberately boring, deliberately small, deliberately fixed.
-- |
-- | This is not a benchmark game and the shapes are not chosen to flatter
-- | anyone. The question they answer is **"has this backend drifted against
-- | itself?"** — so what matters is that a shape stays the same forever and
-- | that its cost is attributable to one identifiable thing.
-- |
-- | Two design rules the shapes obey:
-- |
-- | 1. **Every shape returns an `Int` checksum.** The runner diffs checksums
-- |    across backends before it looks at a single timing. A benchmark that
-- |    computes the wrong answer quickly is the classic way for a performance
-- |    suite to go green while the thing it measures rots.
-- |
-- | 2. **Shapes come in subtractable pairs.** `ffi-call` and `loop-fore` are
-- |    the same loop over the same `Ref` and differ only by the crossing, so
-- |    their difference is the seam. `loop-null` is that loop with no body at
-- |    all, so it is the harness's own floor. Reporting the floor as a shape
-- |    beats hiding it inside every other number.
module Bench.Shapes
  ( loopNull
  , loopNaive
  , loopTailRec
  , loopForE
  , loopST
  , foldList
  , foldArray
  , mapArray
  , stringAppend
  , stringJoin
  , recordUpdate
  , ffiCall
  , ffiArray
  ) where

import Prelude

import Bench.Clock (ffiInc, ffiSumArray)
import Control.Monad.Rec.Class (Step(..), tailRecM)
import Control.Monad.ST as ST
import Control.Monad.ST.Ref as STRef
import Data.Array as Array
import Data.Foldable (foldl)
import Data.List as List
import Data.String.CodeUnits as CU
import Data.String.Common (joinWith)
import Effect (Effect, forE)
import Effect.Ref as Ref

--------------------------------------------------------------------------
-- Counted loops, four ways
--
-- The same computation written four ways, which is the whole finding of
-- 2026-08-01 turned into a permanent measurement. On Jurist these differ by
-- three orders of magnitude, because `loopNaive` builds a chain of binds
-- whose *type* nests one level per iteration while the other three hand the
-- iteration to a host loop. On a runtime that does not specialise on closure
-- types they should differ by a small constant.
--
-- The gap between `loop-naive` and `loop-fore` IS the metric. It is expected
-- to be large on Jurist and near 1 elsewhere; what would be a finding is
-- either of those changing.
--------------------------------------------------------------------------

-- | The floor: the harness's own loop, with no body. Every `forE`-based shape
-- | below inherits this, so it is measured rather than assumed negligible.
loopNull :: Int -> Effect Int
loopNull n = do
  forE 0 n \_ -> pure unit
  pure n

-- | Recursion through `*>`. The natural thing to write, and the pathological
-- | one on Jurist. Its sizes are kept small in the schedule for that reason —
-- | see the note there.
loopNaive :: Int -> Effect Int
loopNaive n = do
  r <- Ref.new 0
  let
    go i
      | i >= n = Ref.read r
      | otherwise = Ref.modify_ (_ + 1) r *> go (i + 1)
  go 0

-- | The same loop through `MonadRec`, which is the portable answer when the
-- | iteration count is not known up front.
loopTailRec :: Int -> Effect Int
loopTailRec n = do
  r <- Ref.new 0
  _ <-
    tailRecM
      ( \i ->
          if i >= n then pure (Done unit)
          else Ref.modify_ (_ + 1) r $> Loop (i + 1)
      )
      0
  Ref.read r

-- | The same loop handed to the host. One closure, called n times.
loopForE :: Int -> Effect Int
loopForE n = do
  r <- Ref.new 0
  forE 0 n \_ -> Ref.modify_ (_ + 1) r
  Ref.read r

-- | The same loop in `ST`: host iteration, real mutation, pure at the
-- | boundary. The shape a numeric kernel should actually be written in.
loopST :: Int -> Effect Int
loopST n = pure
  ( ST.run do
      r <- STRef.new 0
      ST.for 0 n \_ -> void (STRef.modify (_ + 1) r)
      STRef.read r
  )

--------------------------------------------------------------------------
-- Structures
--
-- `foldList` is the tag-tuple probe. On Jurist a `Cons` cell's type contains
-- its tail's type (ADR-0001), so an n-deep list has a type whose size is
-- proportional to n — a 20-deep `Cons` already prints as 453 characters.
-- Whether that COSTS what the Effect case costs is the open question this
-- shape exists to answer (task #53 step 3), and it is why the list and array
-- folds are separate shapes rather than one: they compute the same checksum
-- over the same numbers, and differ only in the representation walked.
--------------------------------------------------------------------------

foldList :: Int -> Effect Int
foldList n = pure (foldl (+) 0 (List.range 1 n))

foldArray :: Int -> Effect Int
foldArray n = pure (foldl (+) 0 (Array.range 1 n))

mapArray :: Int -> Effect Int
mapArray n = pure (foldl (+) 0 (map (_ + 1) (Array.range 1 n)))

--------------------------------------------------------------------------
-- Strings
--
-- `stringAppend` is quadratic by construction on any runtime with immutable
-- strings; that is the point. It is here so that a backend switching to a
-- rope, a builder, or an accidental O(n^2) copy shows up as a change in the
-- curve rather than in a bug report. `stringJoin` is the same result built
-- the way it should be, and the ratio between them is the interesting number.
--------------------------------------------------------------------------

stringAppend :: Int -> Effect Int
stringAppend n = do
  r <- Ref.new ""
  forE 0 n \_ -> Ref.modify_ (_ <> "x") r
  s <- Ref.read r
  pure (CU.length s)

stringJoin :: Int -> Effect Int
stringJoin n = pure (CU.length (joinWith "," (Array.replicate n "x")))

--------------------------------------------------------------------------
-- Records
--
-- Record update is the operation whose cost is most invisible in the source:
-- `v { a = v.a + 1 }` looks like a field write and is a whole-record copy on
-- every backend we have. Three fields of three different types, so a backend
-- specialising on homogeneous records does not get an unrepresentative win.
--------------------------------------------------------------------------

recordUpdate :: Int -> Effect Int
recordUpdate n = do
  r <- Ref.new { a: 0, b: "x", c: 1.0 }
  forE 0 n \_ -> Ref.modify_ (\v -> v { a = v.a + 1 }) r
  v <- Ref.read r
  pure v.a

--------------------------------------------------------------------------
-- The FFI seam — the second axis
--
-- `ffiCall` is `loopForE` with `ffiInc` in place of `(_ + 1)`. Identical
-- loop, identical `Ref`, identical iteration count; the ONLY difference is
-- that the increment happens on the far side of the seam. Their difference
-- is therefore the per-call cost of crossing it, which is the number that
-- decides whether "call the host's library" is a cheap idea or an expensive
-- one — and that is the whole premise of the polyglot claim.
--------------------------------------------------------------------------

ffiCall :: Int -> Effect Int
ffiCall n = do
  r <- Ref.new 0
  forE 0 n \_ -> Ref.modify_ ffiInc r
  Ref.read r

-- | One crossing, n elements. Against `foldArray` — same array, same sum,
-- | walked on the near side — this is what marshalling costs.
ffiArray :: Int -> Effect Int
ffiArray n = pure (ffiSumArray (Array.range 1 n))
