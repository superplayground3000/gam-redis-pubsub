// $LAB/verifier/quiescence.go
package main

import (
	"context"
	"log"
	"time"
)

// WaitQuiescent blocks until the source consumer group has drained app.events
// AND the sink JetStream consumer has zero pending — or the deadline fires.
// Returns true if quiesced, false on timeout (caller must NOT assert on timeout).
func WaitQuiescent(ctx context.Context, central *RedisClient, sourceGroup, natsURL, stream string, deadline time.Duration) bool {
	end := time.Now().Add(deadline)
	for {
		if ctx.Err() != nil || time.Now().After(end) {
			log.Printf("WARN: pipeline did not quiesce within %s", deadline)
			return false
		}
		srcOK := false
		if lag, err := central.GroupLag(ctx, "app.events", sourceGroup); err == nil && lag == 0 {
			srcOK = true
		}
		sinkOK := false
		if snap, err := ScrapeJSZ(ctx, natsURL, stream); err == nil && snap.MaxPending == 0 {
			sinkOK = true
		}
		if srcOK && sinkOK {
			return true
		}
		select {
		case <-ctx.Done():
			return false
		case <-time.After(250 * time.Millisecond):
		}
	}
}
