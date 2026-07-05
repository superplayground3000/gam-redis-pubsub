// $LAB/verifier/quiescence.go
package verifier

import (
	"context"
	"log"
	"time"
)

// quiesceStablePolls is how many CONSECUTIVE polls must observe a fully-drained
// pipeline before we declare quiescence. A single drained reading is unreliable
// because the event hands off across stages (source PEL -> NATS publish -> sink
// consumer pull -> region SET -> ack): at any instant one stage can read zero
// while the message is mid-flight to the next. Requiring 3 consecutive drained
// polls (~750ms of continuous quiet) closes those hand-off windows.
const quiesceStablePolls = 3

// WaitQuiescent blocks until the pipeline is drained for `quiesceStablePolls`
// consecutive polls — or the deadline fires. Drained means: the source consumer
// group has BOTH lag==0 AND pending==0 (PEL empty: entries delivered AND acked,
// so the source has finished publishing to NATS) AND the sink JetStream consumer
// has MaxPending==0. Returns true if quiesced, false on timeout (caller must NOT
// assert on timeout).
func WaitQuiescent(ctx context.Context, central *RedisClient, sourceGroup, natsURL, stream string, deadline time.Duration) bool {
	end := time.Now().Add(deadline)
	stable := 0
	for {
		if ctx.Err() != nil || time.Now().After(end) {
			log.Printf("WARN: pipeline did not quiesce within %s", deadline)
			return false
		}
		// Source is drained only when lag==0 AND pending==0 (PEL empty). lag alone
		// drops to 0 when an entry is merely delivered to the PEL, before the source
		// pod has published it to NATS and acked — a false-quiescence trap.
		srcOK := false
		if lag, pending, err := central.GroupBacklog(ctx, "app.events", sourceGroup); err == nil && lag == 0 && pending == 0 {
			srcOK = true
		}
		// MaxPending is the max num_pending across the stream's JetStream consumers.
		// For KV_CDC that equals the sink durable's pending because the stream has
		// exactly one JetStream consumer (cdc_sink); the SOURCE side drains via the
		// Redis consumer group (checked above), not a NATS consumer.
		sinkOK := false
		if snap, err := ScrapeJSZ(ctx, natsURL, stream); err == nil && snap.MaxPending == 0 {
			sinkOK = true
		}
		if srcOK && sinkOK {
			stable++
			if stable >= quiesceStablePolls {
				return true
			}
		} else {
			stable = 0
		}
		select {
		case <-ctx.Done():
			return false
		case <-time.After(250 * time.Millisecond):
		}
	}
}
