// The native arm of the seam-tax lane: the SAME loop, the SAME library calls,
// written as a plain Go program with no PureScript anywhere.
//
// Correspondence with src/Seam/Main.purs is the whole experiment, so it is
// maintained deliberately and narrowly:
//
//   - identical call count (400), identical shape-dial schedule, identical
//     work ladder and payload sizes;
//   - identical gzip configuration (DefaultCompression) over identical bytes;
//   - identical ACCUMULATION ORDER, so the checksums match. Floating-point
//     addition is not associative, and the Jurist lane's gate caught two
//     separate association bugs in its native arm before this one was written.
//     A per-array subtotal from 0.0, then one add, is what matches
//     `Ref.modify_ (_ + Array.foldl (+) 0.0 xs)`.
//
// The workload body is duplicated from src/Seam/Kernel.go rather than shared.
// That is intentional: sharing it would make the two arms the same code path,
// and there would be nothing left to compare. The ONE thing that differs on
// purpose is the payload type — []float64 here against the []any that psgo's
// `Array Number` forces on the polyglot arm — because that difference IS the
// marshalling cost the payload axis exists to price.
//
//	go run native/seam_native.go

package main

import (
	"bytes"
	"compress/gzip"
	"fmt"
	"os"
	"time"
)

const (
	calls  = 400
	reps   = 3
	schema = "1"
)

// Must match src/Seam/Kernel.go's workLadder / payloadWork exactly.
var workLadder = []float64{8.0, 24.0, 75.0, 245.0, 705.0}

const payloadWork = 75.0

var payloads = []int{1, 16, 128, 1024}

func seamPayload(n int, seed uint32) []byte {
	b := make([]byte, n)
	s := seed*2654435761 + 1
	for i := range b {
		s = s*1664525 + 1013904223
		b[i] = byte(s>>24) ^ byte(i/64)
	}
	return b
}

var foreignNs float64

func gzipOnce(d1, d2, d3, work float64) (float64, []byte) {
	n := int(work * 1024.0)
	if n < 1 {
		n = 1
	}
	seed := uint32(d1*1000.0) ^ uint32(d2*7919.0) ^ uint32(d3*104729.0)
	src := seamPayload(n, seed)

	var buf bytes.Buffer
	zw, _ := gzip.NewWriterLevel(&buf, gzip.DefaultCompression)
	_, _ = zw.Write(src)
	_ = zw.Close()
	out := buf.Bytes()
	return float64(len(out)), out
}

func callLibrary(d1, d2, d3, work float64) float64 {
	t0 := time.Now()
	size, _ := gzipOnce(d1, d2, d3, work)
	foreignNs += float64(time.Since(t0).Nanoseconds())
	return size
}

func callLibraryPayload(d1, d2, d3, work float64, nSamples int) []float64 {
	t0 := time.Now()
	_, out := gzipOnce(d1, d2, d3, work)
	res := make([]float64, 2*nSamples)
	m := len(out)
	for i := 0; i < nSamples; i++ {
		j := i % m
		k := (i + 1) % m
		res[2*i] = float64(out[j])
		res[2*i+1] = float64(out[k])
	}
	foreignNs += float64(time.Since(t0).Nanoseconds())
	return res
}

// Mirrors Seam.Main.paramsFor — integer arithmetic, so it costs nothing and
// both arms visit exactly the same inputs.
func paramsFor(i int) (float64, float64) {
	return 0.35 + 0.5*float64((i*37)%101)/100.0,
		0.30 * float64((i*53)%97) / 96.0
}

type run struct {
	total    float64
	inlib    float64
	checksum float64
}

// One first pass for the warm-up-dominated number, then reps more keeping the
// fastest WHOLE pass and its own in-library time. Taking the two from
// different passes is how a split ends up summing to more than the whole.
func timed(body func() run) (float64, run) {
	r0 := body()
	best := r0
	for i := 0; i < reps; i++ {
		r := body()
		if r.total < best.total {
			best = r
		}
	}
	return r0.total, best
}

func emit(axis string, param any, first float64, r run) {
	fmt.Printf("SEAM %s %v %d %g %g %g %g\n",
		axis, param, calls, first/1000.0, r.total/1000.0, r.inlib/1000.0, r.checksum)
	_ = os.Stdout
}

func runWork(work float64) {
	first, best := timed(func() run {
		foreignNs = 0
		acc := 0.0
		t0 := time.Now()
		for i := 0; i < calls; i++ {
			a, e := paramsFor(i)
			acc += callLibrary(9.54e-4, a, e, work)
		}
		return run{float64(time.Since(t0).Nanoseconds()), foreignNs, acc}
	})
	emit("work", work, first, best)
}

func runPayload(n int) {
	first, best := timed(func() run {
		foreignNs = 0
		acc := 0.0
		t0 := time.Now()
		for i := 0; i < calls; i++ {
			a, e := paramsFor(i)
			xs := callLibraryPayload(9.54e-4, a, e, payloadWork, n)
			sub := 0.0
			for _, v := range xs {
				sub += v
			}
			acc += sub
		}
		return run{float64(time.Since(t0).Nanoseconds()), foreignNs, acc}
	})
	emit("payload", n, first, best)
}

func main() {
	fmt.Println("SEAM-SCHEMA", schema)
	for _, w := range workLadder {
		runWork(w)
	}
	for _, n := range payloads {
		runPayload(n)
	}
}
