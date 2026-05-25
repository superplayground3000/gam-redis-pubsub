package main

import (
	"context"
	"log"
	"time"
)

// xlenReader is the minimal subset of *StreamClient used by waitForPipelineQuiescence.
// Defining it as an interface lets quiescence_test.go pass a fake without a real Redis.
type xlenReader interface {
	XLen(ctx context.Context, key string) (int64, error)
	GroupLag(ctx context.Context, stream, group string) (int64, error)
}

// waitForPipelineQuiescence polls every 250 ms until either the profile-specific
// quiescence condition holds for one poll, or the deadline elapses.
// Returns true if the deadline fired (the pipeline did not quiesce in time),
// false if quiescence was observed.
//
// Profile conditions (spec §6.3.1):
//
//	alo, eoe: XLEN(app.events) == 0 AND ScrapeJSZ.MaxPending == 0
//	amo:      XLEN(app.events) == 0 only
func waitForPipelineQuiescence(
	ctx context.Context,
	profile string,
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
			log.Printf("WARN: pipeline did not quiesce within %s (profile=%s)", deadline, profile)
			return true
		}
		// Source is quiesced when the consumer group has read every entry in app.events.
		// Note: Redis streams don't shrink on ack, so XLEN is not the right metric here.
		sourceOK := false
		if lag, err := central.GroupLag(ctx, "app.events", "propagator"); err == nil && lag == 0 {
			sourceOK = true
		}
		sinkOK := true
		if profile == "alo" || profile == "eoe" {
			sinkOK = false
			if snap, err := ScrapeJSZ(ctx, natsURL, natsStream); err == nil && snap.MaxPending == 0 {
				sinkOK = true
			}
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
