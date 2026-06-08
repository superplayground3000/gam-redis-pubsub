package main

import "time"

// Sample is one observation of the cluster at time T.
type Sample struct {
	T            time.Time        `json:"t"`
	Consumed     map[string]int64 `json:"consumed"`       // pod -> consumed counter
	ActiveStreams int              `json:"active_streams"` // sum of /streams counts across pods
}

// roseCount returns how many pods strictly increased their counter from a to b,
// over the UNION of pods seen in either sample (a pod absent on one side reads 0
// there). consumed:* counters are monotonic, so a pod present only in `a` cannot
// be a rise; iterating the union just makes that explicit and avoids missing a pod
// that newly appears in `b`.
func roseCount(a, b Sample) int {
	n := 0
	seen := make(map[string]struct{}, len(a.Consumed)+len(b.Consumed))
	for pod := range a.Consumed {
		seen[pod] = struct{}{}
	}
	for pod := range b.Consumed {
		seen[pod] = struct{}{}
	}
	for pod := range seen {
		if b.Consumed[pod] > a.Consumed[pod] {
			n++
		}
	}
	return n
}

// total sums all per-pod counters in a sample.
func total(s Sample) int64 {
	var t int64
	for _, v := range s.Consumed {
		t += v
	}
	return t
}

// SingleActive is true iff every consecutive pair has exactly one pod rising AND
// every sample reports exactly one active stream. This is steady-state Proof A.
func SingleActive(series []Sample) bool {
	if len(series) < 2 {
		return false
	}
	for _, s := range series {
		if s.ActiveStreams != 1 {
			return false
		}
	}
	for i := 1; i < len(series); i++ {
		if roseCount(series[i-1], series[i]) != 1 {
			return false
		}
	}
	return true
}

// OverlapPairs counts consecutive sample-pairs where >=2 distinct pods' counters
// rose simultaneously — the measured dual-active window (Proof B1).
func OverlapPairs(series []Sample) int {
	n := 0
	for i := 1; i < len(series); i++ {
		if roseCount(series[i-1], series[i]) >= 2 {
			n++
		}
	}
	return n
}

// GapPairs counts consecutive sample-pairs where the grand total did not increase
// — the measured zero-active window (Proof B2). Caller ensures the writer is sending.
func GapPairs(series []Sample) int {
	n := 0
	for i := 1; i < len(series); i++ {
		if total(series[i]) <= total(series[i-1]) {
			n++
		}
	}
	return n
}
