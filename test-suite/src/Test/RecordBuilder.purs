-- | `Record.Builder` and `Record.Unsafe.Union` — the `record` package's
-- | foreigns.
-- |
-- | Written because Gate B5 found `record` sitting outside the safe subset on
-- | Gnomon alone, and that one package was worth 15 others downstream. The
-- | shims were then written; this is what says they mean the same thing.
-- |
-- | The property worth testing, and the reason `Builder` exists at all: it
-- | copies ONCE via `copyRecord` and every step after that MUTATES the copy,
-- | so a chain of n builders is one allocation rather than n. A shim author
-- | reading `unsafeInsert` as a pure function would write something correct
-- | that quietly throws that away — and no test of the RESULT would notice.
-- | The `source-untouched-after-*` cases are the ones that would: each builds
-- | from a record and then reads the ORIGINAL back.
module Test.RecordBuilder where

import Prelude

import Record.Builder (build, buildFromScratch, delete, insert, merge, modify,
                       rename, union)
import Record.Unsafe.Union (unsafeUnion)
import Effect (Effect)
import Effect.Console (log)
import Type.Proxy (Proxy(..))

t :: String -> String -> Effect Unit
t name v = log ("TEST " <> name <> ": " <> v)

type XY = { x :: Int, y :: Int }

showXY :: XY -> String
showXY r = "{x:" <> show r.x <> ",y:" <> show r.y <> "}"

main :: Effect Unit
main = do
  log "=== Test.RecordBuilder ==="

  let src = { x: 1, y: 2 }

  -- insert / modify / delete / rename, each through `build`
  t "insert"
    (let r = build (insert (Proxy :: Proxy "z") 3) src
     in showXY { x: r.x, y: r.y } <> ",z:" <> show r.z)
  t "modify"
    (showXY (build (modify (Proxy :: Proxy "x") (_ + 10)) src))
  t "modify-changes-type"
    (let r = build (modify (Proxy :: Proxy "x") show) src
     in "x:" <> r.x <> ",y:" <> show r.y)
  t "delete"
    (let r = build (delete (Proxy :: Proxy "y")) src in "x:" <> show r.x)
  t "rename"
    (let r = build (rename (Proxy :: Proxy "y") (Proxy :: Proxy "w")) src
     in "x:" <> show r.x <> ",w:" <> show r.w)

  -- composition: the whole point is that these chain
  t "chained"
    (let r = build (insert (Proxy :: Proxy "z") 3
                     >>> modify (Proxy :: Proxy "x") (_ * 2)
                     >>> delete (Proxy :: Proxy "y")) src
     in "x:" <> show r.x <> ",z:" <> show r.z)

  -- THE test the shim can fail while every result-shaped test passes: if
  -- `copyRecord` did not really copy, the mutation would reach `src`.
  t "source-untouched-after-insert"
    (let _ = build (insert (Proxy :: Proxy "z") 99) src in showXY src)
  t "source-untouched-after-modify"
    (let _ = build (modify (Proxy :: Proxy "x") (_ + 1000)) src in showXY src)
  t "source-untouched-after-delete"
    (let _ = build (delete (Proxy :: Proxy "y")) src in showXY src)
  t "source-untouched-after-rename"
    (let _ = build (rename (Proxy :: Proxy "y") (Proxy :: Proxy "w")) src
     in showXY src)
  t "build-twice-same"
    (let a = build (modify (Proxy :: Proxy "x") (_ + 1)) src
         b = build (modify (Proxy :: Proxy "x") (_ + 1)) src
     in showXY a <> "|" <> showXY b)

  t "buildFromScratch"
    (let r = buildFromScratch (insert (Proxy :: Proxy "a") 1
                                >>> insert (Proxy :: Proxy "b") 2)
     in "a:" <> show r.a <> ",b:" <> show r.b)

  -- merge / union: which side wins on a collision is the whole contract
  t "merge"
    (let r = build (merge { y: 20, z: 30 }) src
     in "x:" <> show r.x <> ",y:" <> show r.y <> ",z:" <> show r.z)
  t "union"
    (let r = build (union { z: 30 }) src
     in "x:" <> show r.x <> ",y:" <> show r.y <> ",z:" <> show r.z)

  -- Record.Unsafe.Union, called directly: LEFT wins.
  t "unsafeUnion-left-wins"
    (let r = unsafeUnion { x: 1, y: 2 } { y: 99, z: 3 } :: { x :: Int, y :: Int, z :: Int }
     in "x:" <> show r.x <> ",y:" <> show r.y <> ",z:" <> show r.z)
  t "unsafeUnion-disjoint"
    (let r = unsafeUnion { x: 1 } { z: 3 } :: { x :: Int, z :: Int }
     in "x:" <> show r.x <> ",z:" <> show r.z)
  t "unsafeUnion-empty-right"
    (let r = unsafeUnion { x: 1 } {} :: { x :: Int } in "x:" <> show r.x)
  t "unsafeUnion-sources-untouched"
    (let a = { x: 1, y: 2 }
         _ = unsafeUnion a { y: 99, z: 3 } :: { x :: Int, y :: Int, z :: Int }
     in showXY a)
