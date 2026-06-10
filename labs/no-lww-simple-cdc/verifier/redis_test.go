// $LAB/verifier/redis_test.go
package main

import (
	"context"
	"strings"
	"testing"
	"time"
)

func TestEventValuesOrder(t *testing.T) {
	vals := eventValues(map[string]string{"op": "create", "kv_key": "k", "event_id": "e", "body": "{}"})
	// must be an even-length key/value slice and include op/event_id
	if len(vals)%2 != 0 {
		t.Fatalf("odd-length values: %d", len(vals))
	}
	found := map[string]bool{}
	for i := 0; i < len(vals); i += 2 {
		found[vals[i].(string)] = true
	}
	for _, k := range []string{"event_id", "op", "kv_key", "old_key", "new_key", "ts", "body"} {
		if !found[k] {
			t.Fatalf("missing field %q in %v", k, vals)
		}
	}
}

// TestGroupLagFailsClosed verifies that a non-"no such key" Redis error (here a
// connection failure to a dead address) propagates instead of being swallowed as
// lag 0 — so WaitQuiescent fails closed. No live Redis needed: the unreachable
// address with a short deadline yields a dial/timeout error whose text does NOT
// contain "no such key", exercising the propagate branch.
func TestGroupLagFailsClosed(t *testing.T) {
	c := NewRedisClient("127.0.0.1:1") // reserved, refuses connections
	defer c.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	lag, err := c.GroupLag(ctx, "app.events", "cdc_propagator")
	if err == nil {
		t.Fatalf("expected a propagated error on unreachable Redis, got lag=%d err=nil", lag)
	}
	if strings.Contains(strings.ToLower(err.Error()), "no such key") {
		t.Fatalf("test setup wrong: error should not be a missing-stream error: %v", err)
	}
}
