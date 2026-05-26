package main

import (
	"context"
	"errors"
	"sync/atomic"
	"time"

	"github.com/redis/go-redis/v9"
)

type Receiver struct {
	rdb              *redis.Client
	stream           string
	latency          *LatencyTracker
	received         atomic.Int64
	errCount         atomic.Int64
	latencyParseErrs atomic.Int64
	// Per-pattern counters: index aligns with PatternEmployee/PatternRole/PatternOrg.
	byPattern [3]atomic.Int64
	lastID    string
}

func NewReceiver(addr, stream string) *Receiver {
	return &Receiver{
		rdb:     redis.NewClient(&redis.Options{Addr: addr}),
		stream:  stream,
		latency: NewLatencyTracker(),
	}
}

func (r *Receiver) Count() int64                 { return r.received.Load() }
func (r *Receiver) Errors() int64                { return r.errCount.Load() }
func (r *Receiver) Latency() LatencySummary      { return r.latency.Summary() }
func (r *Receiver) LatencyParseErrors() int64    { return r.latencyParseErrs.Load() }
func (r *Receiver) NegativeLatencyDeltas() int64 { return r.latency.NegativeDeltas() }
func (r *Receiver) Close() error                 { return r.rdb.Close() }

func (r *Receiver) CountByPattern(name string) int64 {
	switch name {
	case "employee":
		return r.byPattern[0].Load()
	case "role":
		return r.byPattern[1].Load()
	case "org":
		return r.byPattern[2].Load()
	}
	return 0
}

func (r *Receiver) processStreams(streams []redis.XStream) {
	for _, st := range streams {
		for _, msg := range st.Messages {
			r.received.Add(1)
			if d, err := extractSyncLatencyMs(msg.Values); err == nil {
				r.latency.RecordMs(d)
			} else {
				r.latencyParseErrs.Add(1)
			}
			if v, ok := msg.Values["pattern"].(string); ok {
				switch v {
				case "employee":
					r.byPattern[0].Add(1)
				case "role":
					r.byPattern[1].Add(1)
				case "org":
					r.byPattern[2].Add(1)
				}
			}
			r.lastID = msg.ID
		}
	}
}

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
		r.processStreams(res)
	}
}
