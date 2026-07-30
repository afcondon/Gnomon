#!/usr/bin/env bash
# Conformance lane for Gnomon (psgo) — the mechanical gate for any change to
# the code generator or the runtime prelude. Mirrors the sibling Jurist and
# Pythia backends' bin/conformance.sh.
#
# Gnomon has TWO implementations (ADR-0007) and therefore two gates, which are
# not interchangeable:
#
#   1. The ORACLE lane — `psgo` (Haskell, src/) walking raw CoreFn, run over the
#      shared Test.* corpus and diffed byte-for-byte against the JS backend.
#      This is what any correctness claim rests on.
#   2. The OPTIMIZER lane — backend-go/ (PureScript) consuming
#      purescript-backend-optimizer's IR. Same corpus, different path through
#      the compiler.
#
# Neither lane sees the third axis — whether a library needs a foreign this
# backend does not supply. That is the portability index
# (../purescript-julia/bin/portability-index.py).
#
# Corpus modules are DISCOVERED from test-suite/src/Test/, never listed by
# hand: a hand-maintained list is how Test.Maps sat unexecuted here for weeks.
#
# Prereqs on PATH: stack, purs, spago, node, go, python3.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ONLY="${1:-both}"

echo "==> building psgo (stack)"
stack build

if [[ "$ONLY" == "both" || "$ONLY" == "oracle" ]]; then
  echo "==> oracle lane: psgo over the shared corpus (test-suite)"
  ( cd test-suite && python3 run_tests.py )
fi

if [[ "$ONLY" == "both" || "$ONLY" == "optimizer" ]]; then
  echo "==> optimizer lane: backend-go over the shared corpus"
  if [[ -d ../purescript-backend-optimizer ]]; then
    ( cd backend-go && ./run_conformance.sh )
  else
    echo "    SKIPPED — ../purescript-backend-optimizer not checked out."
    echo "    The optimizer lane needs it as a local sibling (see backend-go/README.md)."
  fi
fi

echo "==> conformance lane GREEN"
