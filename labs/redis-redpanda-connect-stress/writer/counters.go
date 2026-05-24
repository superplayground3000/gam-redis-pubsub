package main

import "sync/atomic"

type Counters struct {
	Sent     atomic.Int64
	Errors   atomic.Int64
	Inflight atomic.Int64
}

func (c *Counters) Reset() {
	c.Sent.Store(0)
	c.Errors.Store(0)
	c.Inflight.Store(0)
}
