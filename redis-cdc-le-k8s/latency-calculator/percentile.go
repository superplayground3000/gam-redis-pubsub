// Nearest-rank percentile and per-bucket summary statistics.
package main

import (
	"math"
	"sort"
)

// Stats is the summary block emitted for each report bucket (overall / per-op).
type Stats struct {
	Count  int     `json:"count"`
	MinMs  int64   `json:"min_ms"`
	MaxMs  int64   `json:"max_ms"`
	MeanMs float64 `json:"mean_ms"`
	P50Ms  int64   `json:"p50_ms"`
	P95Ms  int64   `json:"p95_ms"`
	P99Ms  int64   `json:"p99_ms"`
}

// Percentile returns the nearest-rank percentile (p in [0,100]) of an
// ascending-sorted slice. Empty slice returns 0.
func Percentile(sorted []int64, p float64) int64 {
	n := len(sorted)
	if n == 0 {
		return 0
	}
	rank := int(math.Ceil(p / 100 * float64(n)))
	if rank < 1 {
		rank = 1
	}
	if rank > n {
		rank = n
	}
	return sorted[rank-1]
}

// Summarize computes count/min/max/mean and p50/p95/p99 over latencies (any order).
func Summarize(latencies []int64) Stats {
	n := len(latencies)
	if n == 0 {
		return Stats{}
	}
	s := append([]int64(nil), latencies...)
	sort.Slice(s, func(i, j int) bool { return s[i] < s[j] })
	var sum int64
	for _, v := range s {
		sum += v
	}
	return Stats{
		Count:  n,
		MinMs:  s[0],
		MaxMs:  s[n-1],
		MeanMs: float64(sum) / float64(n),
		P50Ms:  Percentile(s, 50),
		P95Ms:  Percentile(s, 95),
		P99Ms:  Percentile(s, 99),
	}
}
