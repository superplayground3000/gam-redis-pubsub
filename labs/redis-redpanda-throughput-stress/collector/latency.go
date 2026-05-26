package main

import (
	"fmt"
	"strconv"

	"github.com/HdrHistogram/hdrhistogram-go"
)

// extractSyncLatencyMs reads t_send_ms and applied_ms from Redis stream entry
// fields (both stamped as milliseconds since epoch — t_send_ms by the writer
// at central XADD time, applied_ms by Connect-sink immediately before regional
// SET). Returns the signed delta in ms (caller clamps).
func extractSyncLatencyMs(fields map[string]any) (int64, error) {
	tSend, err := readMsField(fields, "t_send_ms")
	if err != nil {
		return 0, err
	}
	applied, err := readMsField(fields, "applied_ms")
	if err != nil {
		return 0, err
	}
	return applied - tSend, nil
}

func readMsField(fields map[string]any, name string) (int64, error) {
	v, ok := fields[name]
	if !ok {
		return 0, fmt.Errorf("field %q missing", name)
	}
	s, ok := v.(string)
	if !ok {
		return 0, fmt.Errorf("field %q has type %T, want string", name, v)
	}
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("field %q not int: %w", name, err)
	}
	return n, nil
}

type LatencyTracker struct {
	h        *hdrhistogram.Histogram
	negCount int64
}

func NewLatencyTracker() *LatencyTracker {
	// Range 1 ms .. 300 000 ms (5 min). Sync-latency is in ms already; no us conversion.
	return &LatencyTracker{h: hdrhistogram.New(1, 300_000, 3)}
}

// NegativeDeltas returns the count of RecordMs calls that received a negative
// input (clock skew or wrong-field path). The negative value was clamped to 1
// for histogram correctness, but the count is preserved for diagnostics.
func (l *LatencyTracker) NegativeDeltas() int64 { return l.negCount }

// RecordMs clamps negatives to 1 (clock-skew artifact) and ceils to the histogram max.
func (l *LatencyTracker) RecordMs(d int64) {
	if d < 1 {
		l.negCount++
		d = 1
	}
	if d > 300_000 {
		d = 300_000
	}
	_ = l.h.RecordValue(d)
}

type LatencySummary struct {
	P50Ms   float64 `json:"p50"`
	P95Ms   float64 `json:"p95"`
	P99Ms   float64 `json:"p99"`
	P999Ms  float64 `json:"p999"`
	MaxMs   float64 `json:"max"`
	Samples int64   `json:"count"`
}

func (l *LatencyTracker) Summary() LatencySummary {
	f := func(q float64) float64 { return float64(l.h.ValueAtQuantile(q)) }
	return LatencySummary{
		P50Ms:   f(50),
		P95Ms:   f(95),
		P99Ms:   f(99),
		P999Ms:  f(99.9),
		MaxMs:   float64(l.h.Max()),
		Samples: l.h.TotalCount(),
	}
}
