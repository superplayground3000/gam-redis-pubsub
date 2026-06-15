// $LAB/writer/counters.go
package main

import "sync/atomic"

// Counters are process-lifetime totals exported on /metrics.
type Counters struct {
	Sent     atomic.Int64 // total events XADDed
	Errors   atomic.Int64
	Inflight atomic.Int64
	Created  atomic.Int64
	Updated  atomic.Int64
	Deleted  atomic.Int64
	Renamed  atomic.Int64
}

func (c *Counters) bump(op string) {
	switch op {
	case "create":
		c.Created.Add(1)
	case "update":
		c.Updated.Add(1)
	case "delete":
		c.Deleted.Add(1)
	case "rename":
		c.Renamed.Add(1)
	}
}

func (c *Counters) Reset() {
	c.Sent.Store(0)
	c.Errors.Store(0)
	c.Created.Store(0)
	c.Updated.Store(0)
	c.Deleted.Store(0)
	c.Renamed.Store(0)
}
