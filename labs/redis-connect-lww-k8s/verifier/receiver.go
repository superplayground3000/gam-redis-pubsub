package main

import (
	"context"
	"errors"
	"sync/atomic"
	"time"

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

// processStreams folds one or more XStream results into the receiver's state.
// Each message increments the received counter regardless of payload validity;
// the latency tracker is only updated when the payload parses and yields a ts_ns.
// lastID is advanced to the highest message ID seen.
//
// Package-private only so tests can call it directly with synthetic XStreams
// to avoid needing a live Redis.
func (r *Receiver) processStreams(streams []redis.XStream, nowNs int64) {
	for _, st := range streams {
		for _, msg := range st.Messages {
			if v, ok := msg.Values["value"].(string); ok {
				if ts, err := extractTsNs(v); err == nil {
					r.latency.RecordAt(ts, nowNs)
				}
			}
			r.received.Add(1)
			r.lastID = msg.ID
		}
	}
}

// Run drives the XREAD BLOCK loop. Returns when ctx is cancelled.
// The caller must call this via a goroutine wrapped in sync.WaitGroup so
// accessors (Count, Errors, Latency) can be read race-safely after wg.Wait().
func (r *Receiver) Run(ctx context.Context) {
	r.lastID = "0-0"
	for {
		if ctx.Err() != nil {
			return
		}
		res, err := r.rdb.XRead(ctx, &redis.XReadArgs{
			Streams: []string{r.stream, r.lastID},
			Block:   250 * time.Millisecond,
			Count:   1000,
		}).Result()
		if err != nil {
			if errors.Is(err, redis.Nil) || errors.Is(err, context.DeadlineExceeded) {
				continue
			}
			if ctx.Err() != nil {
				return
			}
			r.errCount.Add(1)
			time.Sleep(50 * time.Millisecond)
			continue
		}
		r.processStreams(res, time.Now().UnixNano())
	}
}
