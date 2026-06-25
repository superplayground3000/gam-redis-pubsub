package main

import "sort"

// ConsumerState is the JetStream pull-consumer's ack oracle at quiescence.
type ConsumerState struct {
	NumPending    uint64 // messages not yet delivered
	NumAckPending int    // delivered-but-not-acked (in-flight)
}

type Verdict struct {
	Profile          string `json:"profile"`
	N                int    `json:"n"`
	InflightAtDelete int    `json:"inflight_at_delete"`
	Lost             []int  `json:"lost"`
	DupCount         int    `json:"dup_count"`
	Drained          bool   `json:"drained"`
	Verdict          struct {
		Pass bool `json:"pass"`
	} `json:"verdict"`
}

// Reconcile classifies every index 1..n from the applied-counter ledger.
//
//	applied[i] == 0 (drained)  -> LOST (acked-without-apply): the failure
//	applied[i] >= 2            -> redelivered duplicate (safe, counted)
//
// PASS requires: zero lost AND consumer fully drained AND DELETE landed mid-flight.
func Reconcile(profile string, n, inflightAtDelete int, applied map[int]int, cs ConsumerState) Verdict {
	lost := make([]int, 0)
	dup := 0
	for i := 1; i <= n; i++ {
		c := applied[i]
		if c == 0 {
			lost = append(lost, i)
		} else if c > 1 {
			dup += c - 1
		}
	}
	sort.Ints(lost)

	drained := cs.NumPending == 0 && cs.NumAckPending == 0
	v := Verdict{
		Profile:          profile,
		N:                n,
		InflightAtDelete: inflightAtDelete,
		Lost:             lost,
		DupCount:         dup,
		Drained:          drained,
	}
	v.Verdict.Pass = len(lost) == 0 && drained && inflightAtDelete > 0
	return v
}
