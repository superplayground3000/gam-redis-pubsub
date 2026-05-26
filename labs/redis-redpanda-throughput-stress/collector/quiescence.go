package main

import (
	"context"
	"log"
	"time"
)

// xlenReader is the minimal subset used by waitForPipelineQuiescence.
// (Name kept for diff continuity with parent; GroupLag is the load-bearing call.)
type xlenReader interface {
	XLen(ctx context.Context, key string) (int64, error)
	GroupLag(ctx context.Context, stream, group string) (int64, error)
}

// waitForPipelineQuiescence polls every 250ms until both conditions hold for
// one poll or the deadline elapses.
//
//	Source-side: GroupLag("app.events", "propagator") == 0
//	Sink-side:   ScrapeJSZ(natsURL, natsStream).MaxPending == 0
//
// Returns true if the deadline fired.
//
// XLEN is intentionally NOT used: Redis streams don't shrink on ack, so XLEN
// never drops back to zero during a run. Parent lab regressed on this exact
// mistake (commit bdf31a9); we inherit the fixed signal.
func waitForPipelineQuiescence(
	ctx context.Context,
	central xlenReader,
	natsURL, natsStream string,
	deadline time.Duration,
) (timedOut bool) {
	end := time.Now().Add(deadline)
	for {
		if ctx.Err() != nil {
			return true
		}
		if time.Now().After(end) {
			log.Printf("WARN: pipeline did not quiesce within %s", deadline)
			return true
		}
		sourceOK := false
		if lag, err := central.GroupLag(ctx, "app.events", "propagator"); err == nil && lag == 0 {
			sourceOK = true
		}
		sinkOK := false
		if snap, err := ScrapeJSZ(ctx, natsURL, natsStream); err == nil && snap.MaxPending == 0 {
			sinkOK = true
		}
		if sourceOK && sinkOK {
			return false
		}
		select {
		case <-ctx.Done():
			return true
		case <-time.After(250 * time.Millisecond):
		}
	}
}
