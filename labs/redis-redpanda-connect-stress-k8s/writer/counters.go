package main

import "sync/atomic"

type Counters struct {
	Sent     atomic.Int64
	Errors   atomic.Int64
	Inflight atomic.Int64
	// SetGaps counts events where SET succeeded but XADD failed: the key was
	// written to central Redis but no stream event was emitted, so connect
	// will never propagate the change to regional Redis.
	SetGaps atomic.Int64
}

func (c *Counters) Reset() {
	c.Sent.Store(0)
	c.Errors.Store(0)
	c.Inflight.Store(0)
	c.SetGaps.Store(0)
}
