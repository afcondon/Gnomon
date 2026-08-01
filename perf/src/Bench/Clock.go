package main

// Co-located foreign for Bench.Clock, found the way purs finds a `.js`:
// `<dir>/<Module>.go` next to the `.purs`. psgo copies it into the output as a
// sibling `package main` file, so `go run *.go` resolves these symbols.
//
// Conventions: an `Effect a` is `func() any`; a unary PureScript function is
// `func(any) any`; `Int` is `int`, `Number` is `float64`, `Array a` is `[]any`.

import (
	"fmt"
	"os"
	"time"
)

// Monotonic. time.Now() carries a monotonic reading on every platform Go
// supports, and time.Since uses it — so this is immune to a wall-clock jump
// mid-run, which a Unix-nanos subtraction would not be.
var _benchClockEpoch = time.Now()

var Bench_Clock_nowNs any = func() any {
	return float64(time.Since(_benchClockEpoch).Nanoseconds())
}

// os.Stdout is unbuffered in Go, so there is nothing to flush; the shim
// exists because the corpus is shared and calls it on every backend.
var Bench_Clock_flushOut any = func() any {
	_ = fmt.Sprint()
	_ = os.Stdout
	return nil
}

var Bench_Clock_ffiInc any = func(x any) any {
	return x.(int) + 1
}

var Bench_Clock_ffiSumArray any = func(xs any) any {
	s := 0
	for _, x := range xs.([]any) {
		s += x.(int)
	}
	return s
}
