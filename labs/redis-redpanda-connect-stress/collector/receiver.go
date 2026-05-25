package main

import (
	"sync/atomic"

	"github.com/redis/go-redis/v9"
)

// Receiver runs a streaming XREAD consumer against region-events.
// It is the source of truth for received-count and end-to-end latency in v2.
//
// Run is the single goroutine that mutates lastID and latency. The atomic
// counters (received, errCount) are race-safe for concurrent reads via the
// accessors; latency must be read only after Run has returned (caller
// enforces this via sync.WaitGroup — see lifecycle in main.go).
type Receiver struct {
	rdb      *redis.Client
	stream   string
	latency  *LatencyTracker
	received atomic.Int64
	errCount atomic.Int64
	lastID   string // touched only by Run() goroutine
}

func NewReceiver(addr, stream string) *Receiver {
	return &Receiver{
		rdb:     redis.NewClient(&redis.Options{Addr: addr}),
		stream:  stream,
		latency: NewLatencyTracker(),
	}
}

func (r *Receiver) Count() int64            { return r.received.Load() }
func (r *Receiver) Errors() int64           { return r.errCount.Load() }
func (r *Receiver) Latency() LatencySummary { return r.latency.Summary() }
func (r *Receiver) Close() error            { return r.rdb.Close() }
