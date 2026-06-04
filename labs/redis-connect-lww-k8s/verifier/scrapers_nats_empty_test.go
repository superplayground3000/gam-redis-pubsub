package main

import (
	"context"
	"testing"
	"time"
)

// When the operator runs the collector against external NATS with no
// monitoring URL configured (--nats=""), the collector must return zero
// values without attempting an HTTP fetch — otherwise the run aborts at
// the first sampler tick.
func TestNATSScraperEmptyURLIsNoOp(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	// ScrapeJSZ is the function in nats.go that hits <baseURL>/jsz
	stats, err := ScrapeJSZ(ctx, "", "APP_EVENTS")
	if err != nil {
		t.Fatalf("expected nil err for empty URL, got %v", err)
	}
	// NATSSnap fields: Messages, Bytes, MaxPending
	if stats.MaxPending != 0 || stats.Bytes != 0 || stats.Messages != 0 {
		t.Fatalf("expected zero stats, got %+v", stats)
	}
}
