package main

import "sync/atomic"

type Counters struct {
	Sent     atomic.Int64
	Errors   atomic.Int64
	Inflight atomic.Int64
}

// Reset zeroes the measured totals. Inflight is a LIVE gauge of in-progress
// pipelines owned solely by worker Add(+1)/Add(-1) pairs — zeroing it here would
// let a concurrent in-flight batch's Add(-1) drive it negative, so it is left
// untouched.
func (c *Counters) Reset() {
	c.Sent.Store(0)
	c.Errors.Store(0)
}
