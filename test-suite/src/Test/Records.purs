-- | Coverage: record update (the `Update` IR node), nested/chained updates,
-- | and field-from-self updates. Forces the codegen path that was `_todo`.
module Test.Records where

import Prelude

import Effect (Effect)
import Effect.Console (log)

type Point = { x :: Int, y :: Int, label :: String }

moveX :: Int -> Point -> Point
moveX dx p = p { x = p.x + dx }

bump :: Point -> Point
bump p = p { x = p.x + 1, y = p.y + 1 }

relabel :: String -> Point -> Point
relabel s p = p { label = s }

showP :: Point -> String
showP p = "{x:" <> show p.x <> ",y:" <> show p.y <> ",label:" <> p.label <> "}"

-- nested record update
type Box = { tag :: String, point :: Point }

reposition :: Box -> Box
reposition b = b { point = b.point { x = 0, y = 0 } }

t :: String -> String -> Effect Unit
t name v = log ("TEST " <> name <> ": " <> v)

main :: Effect Unit
main = do
  log "=== Test.Records ==="
  let p0 = { x: 1, y: 2, label: "a" }
  t "moveX" (showP (moveX 10 p0))
  t "bump" (showP (bump p0))
  t "relabel" (showP (relabel "z" p0))
  t "chained" (showP ((p0 { x = 5 }) { y = 6 }))
  t "from-self" (showP (p0 { x = p0.y, y = p0.x }))
  t "preserve" (showP ((moveX 3 p0) { label = "moved" }))
  let b0 = { tag: "b", point: p0 }
  t "nested" (showP (reposition b0).point)
  t "nested-tag" (reposition b0).tag
