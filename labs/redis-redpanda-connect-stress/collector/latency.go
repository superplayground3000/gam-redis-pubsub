package main

import (
	"encoding/json"
	"fmt"

	"github.com/HdrHistogram/hdrhistogram-go"
)

func extractTsNs(value string) (int64, error) {
	var p struct {
		TsNs int64 `json:"ts_ns"`
	}
	if err := json.Unmarshal([]byte(value), &p); err != nil {
		return 0, err
	}
	if p.TsNs == 0 {
		return 0, fmt.Errorf("ts_ns missing or zero")
	}
	return p.TsNs, nil
}

type LatencyTracker struct {
	h *hdrhistogram.Histogram
}

func NewLatencyTracker() *LatencyTracker {
	// Range 1 microsecond .. 60 seconds, 3 significant figures.
	return &LatencyTracker{h: hdrhistogram.New(1, 60_000_000, 3)}
}

func (l *LatencyTracker) RecordAt(tsNs, nowNs int64) {
	dUs := (nowNs - tsNs) / 1_000
	if dUs < 1 {
		dUs = 1
	}
	_ = l.h.RecordValue(dUs)
}

type LatencySummary struct {
	P50Ms   float64 `json:"p50"`
	P95Ms   float64 `json:"p95"`
	P99Ms   float64 `json:"p99"`
	MaxMs   float64 `json:"max"`
	Samples int64   `json:"samples"`
}

func (l *LatencyTracker) Summary() LatencySummary {
	usToMs := func(us int64) float64 { return float64(us) / 1000.0 }
	return LatencySummary{
		P50Ms:   usToMs(l.h.ValueAtQuantile(50)),
		P95Ms:   usToMs(l.h.ValueAtQuantile(95)),
		P99Ms:   usToMs(l.h.ValueAtQuantile(99)),
		MaxMs:   usToMs(l.h.Max()),
		Samples: l.h.TotalCount(),
	}
}
