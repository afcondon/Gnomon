package main

// The foreign side of the seam-tax lane, Gnomon edition. Co-located with
// Kernel.purs, found the way purs finds a `.js`.
//
// Rule for this file: it contains a LIBRARY CALL and the marshalling around
// it, and nothing else. No loop, no schedule, no algorithm — those live in
// PureScript, which is the whole point of the measurement.
//
// ## Why gzip and not a numerics library
//
// The other two backends bind an ODE solver, because reaching a numerics
// stack is the reason to be on Julia or Python. That is not the reason to be
// on Go. Go's draw is overwhelmingly its STANDARD LIBRARY — compression,
// crypto, encoding/json, net/http, regexp — so binding `compress/gzip` is
// the honest analogue of "the library you came here for", and it needs no
// module fetch.
//
// Binding a different callee does not weaken the comparison, because what is
// measured is the SEAM, and a boundary does not know what is on the far side
// of it. The first two runtimes bear that out: the fixed crossing came to
// 6.6 us on Jurist and 8.0 us on Pythia against completely different
// libraries.
//
// Conventions (from Bench.Clock, the canary's foreign): an `Effect a` is
// `func() any`; a curried PureScript function is nested `func(any) any`;
// `Int` is `int`, `Number` is `float64`, `Array a` is `[]any`.

import (
	"bytes"
	"compress/gzip"
	"fmt"
	"os"
	"time"
)

// --- the workload ------------------------------------------------------------

// Deterministic, compressible-but-not-trivially-so bytes. Pure noise would
// make gzip's work proportional to input with no matching, and a constant run
// would make it trivial; a cheap LCG mixed with a slow sawtooth gives gzip
// real matches to find, which is what makes this a representative call rather
// than a memcpy.
func _seamPayload(n int, seed uint32) []byte {
	b := make([]byte, n)
	s := seed*2654435761 + 1
	for i := range b {
		s = s*1664525 + 1013904223
		b[i] = byte(s>>24) ^ byte(i/64)
	}
	return b
}

var _seamClockEpoch = time.Now()

// Nanoseconds spent INSIDE the library, summed by the foreign itself. This is
// what makes structural distortion computable without a profiler.
var _seamForeignNs float64

// --- instrumentation ---------------------------------------------------------

var Seam_Kernel_nowNs any = func() any {
	return float64(time.Since(_seamClockEpoch).Nanoseconds())
}

// os.Stdout is unbuffered in Go, so there is nothing to flush; the shim exists
// because the corpus is shared and calls it on every backend.
var Seam_Kernel_flushOut any = func() any {
	_ = fmt.Sprint()
	_ = os.Stdout
	return nil
}

var Seam_Kernel_foreignNs any = func() any { return _seamForeignNs }

var Seam_Kernel_resetForeignNs any = func() any {
	_seamForeignNs = 0
	return nil
}

// --- the seam ----------------------------------------------------------------

// The shared PureScript passes three shape dials and a work dial. Here the
// shape dials seed the input so each call compresses different bytes, and the
// work dial IS the input size in kilobytes — gzip's cost is close to linear
// in input length, which makes it a clean two-orders-of-magnitude dial.
func _gzipOnce(d1, d2, d3, work float64) (float64, []byte) {
	n := int(work * 1024.0)
	if n < 1 {
		n = 1
	}
	seed := uint32(d1*1000.0) ^ uint32(d2*7919.0) ^ uint32(d3*104729.0)
	src := _seamPayload(n, seed)

	var buf bytes.Buffer
	zw, _ := gzip.NewWriterLevel(&buf, gzip.DefaultCompression)
	_, _ = zw.Write(src)
	_ = zw.Close()
	out := buf.Bytes()
	return float64(len(out)), out
}

// callLibrary :: Number -> Number -> Number -> Number -> Number
// Returns the compressed size — the THINNEST possible payload, one Number, so
// that whatever the crossing costs here is call overhead and not marshalling.
var Seam_Kernel_callLibrary any = func(d1 any) any {
	return func(d2 any) any {
		return func(d3 any) any {
			return func(work any) any {
				t0 := time.Now()
				size, _ := _gzipOnce(d1.(float64), d2.(float64), d3.(float64), work.(float64))
				_seamForeignNs += float64(time.Since(t0).Nanoseconds())
				return size
			}
		}
	}
}

// callLibraryPayload :: Number -> Number -> Number -> Number -> Int -> Array Number
// The same call, but nSamples samples of the compressed output come back
// instead of one scalar — so the difference against callLibrary at equal work
// is marshalling per element, with call count and library work held fixed.
//
// NOTE `[]any`: PureScript's `Array Number` is a slice of BOXED values on this
// backend, not a `[]float64`. That is the psgo representation, not a choice
// made here, and it is exactly what the payload axis is measuring.
var Seam_Kernel_callLibraryPayload any = func(d1 any) any {
	return func(d2 any) any {
		return func(d3 any) any {
			return func(work any) any {
				return func(nSamples any) any {
					t0 := time.Now()
					_, out := _gzipOnce(d1.(float64), d2.(float64), d3.(float64), work.(float64))
					n := nSamples.(int)
					// Two Numbers per sample, matching the other backends'
					// flat [x0,y0,x1,y1,...] so the per-element price is
					// comparable across runtimes.
					res := make([]any, 2*n)
					m := len(out)
					for i := 0; i < n; i++ {
						j := i % m
						k := (i + 1) % m
						res[2*i] = float64(out[j])
						res[2*i+1] = float64(out[k])
					}
					_seamForeignNs += float64(time.Since(t0).Nanoseconds())
					return res
				}
			}
		}
	}
}

// --- the calibrated ladders --------------------------------------------------
//
// The axis under test is MICROSECONDS of library work bought per crossing; the
// work dial is only what moves it. Each backend calibrates its own ladder to
// span the same microsecond range (~170 us to ~10 ms), so the shared PureScript
// stays byte-identical. Units here are kilobytes of input to gzip.
// Calibrated by measurement, not by guess: gzip carries ~80 us of FIXED
// setup per call on this machine (a 32 KB window allocation dominates a
// small input), so cost is ~80 + 13.7 us per KB. A first ladder of
// 0.5-48 KB spanned only 85-658 us -- a 7.7x range where the other two
// backends span 60x -- and would have measured the flat part of the
// curve. These sizes buy roughly 190 / 410 / 1100 / 3400 / 9700 us.
var Seam_Kernel_workLadder any = []any{8.0, 24.0, 75.0, 245.0, 705.0}

// The middle of the ladder, so the payload axis varies payload against a
// representative amount of work rather than an extreme.
var Seam_Kernel_payloadWork any = 75.0
