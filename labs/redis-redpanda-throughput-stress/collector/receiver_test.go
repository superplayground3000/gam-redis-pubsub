package main

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
)

func TestNewReceiverInitialState(t *testing.T) {
	r := NewReceiver("redis-region:6379", "region-events")
	defer r.Close()
	if c := r.Count(); c != 0 {
		t.Errorf("Count()=%d, want 0", c)
	}
	if e := r.Errors(); e != 0 {
		t.Errorf("Errors()=%d, want 0", e)
	}
	s := r.Latency()
	if s.Samples != 0 {
		t.Errorf("Latency().Samples=%d, want 0", s.Samples)
	}
}

func makeXStream(stream string, msgs []redis.XMessage) []redis.XStream {
	return []redis.XStream{{Stream: stream, Messages: msgs}}
}

func makePayload(t *testing.T, tsNs int64) string {
	t.Helper()
	b, err := json.Marshal(map[string]any{
		"event_id": "abc",
		"ts_ns":    tsNs,
		"seq":      int64(1),
		"pad":      "xxxx",
	})
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestReceiverProcessStreamsCountsAndAdvancesLastID(t *testing.T) {
	r := NewReceiver("127.0.0.1:0", "region-events")
	defer r.Close()
	now := time.Now().UnixNano()
	msgs := []redis.XMessage{
		{ID: "1-0", Values: map[string]any{"value": makePayload(t, now-50_000_000)}},
		{ID: "1-1", Values: map[string]any{"value": makePayload(t, now-20_000_000)}},
		{ID: "2-0", Values: map[string]any{"value": makePayload(t, now-10_000_000)}},
	}
	r.processStreams(makeXStream("region-events", msgs), now)
	if c := r.Count(); c != 3 {
		t.Errorf("Count()=%d, want 3", c)
	}
	if r.lastID != "2-0" {
		t.Errorf("lastID=%q, want %q", r.lastID, "2-0")
	}
	if s := r.Latency(); s.Samples != 3 {
		t.Errorf("Latency().Samples=%d, want 3", s.Samples)
	}
}

func TestReceiverProcessStreamsCountsBadPayloadButSkipsLatency(t *testing.T) {
	r := NewReceiver("127.0.0.1:0", "region-events")
	defer r.Close()
	now := time.Now().UnixNano()
	msgs := []redis.XMessage{
		{ID: "1-0", Values: map[string]any{"value": "not json"}},
		{ID: "1-1", Values: map[string]any{"other": "no value field"}},
		{ID: "1-2", Values: map[string]any{"value": makePayload(t, now-30_000_000)}},
	}
	r.processStreams(makeXStream("region-events", msgs), now)
	if c := r.Count(); c != 3 {
		t.Errorf("Count()=%d, want 3 (all three messages counted regardless of payload)", c)
	}
	if s := r.Latency(); s.Samples != 1 {
		t.Errorf("Latency().Samples=%d, want 1 (only the valid payload recorded)", s.Samples)
	}
}
