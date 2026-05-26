package main

import (
	"strconv"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"
)

func TestReceiver_ProcessCountsAndPatternsAndLatency(t *testing.T) {
	r := &Receiver{
		stream:  "region-events",
		latency: NewLatencyTracker(),
	}
	now := time.Now().UnixMilli()
	mk := func(id string, pat string, latMs int64) redis.XMessage {
		return redis.XMessage{
			ID: id,
			Values: map[string]any{
				"value":      `{"event_id":"x","ts_ns":1,"seq":1,"pad":""}`,
				"key":        "lb:company:active:{employee:1}",
				"event_id":   "x",
				"pattern":    pat,
				"t_send_ms":  strconv.FormatInt(now-latMs, 10),
				"applied_ms": strconv.FormatInt(now, 10),
			},
		}
	}
	streams := []redis.XStream{{
		Stream: "region-events",
		Messages: []redis.XMessage{
			mk("1-0", "employee", 10),
			mk("2-0", "role", 50),
			mk("3-0", "org", 100),
			mk("4-0", "employee", 200),
		},
	}}
	r.processStreams(streams)

	if r.Count() != 4 {
		t.Fatalf("Count = %d, want 4", r.Count())
	}
	if r.CountByPattern("employee") != 2 {
		t.Errorf("employee = %d, want 2", r.CountByPattern("employee"))
	}
	if r.CountByPattern("role") != 1 {
		t.Errorf("role = %d, want 1", r.CountByPattern("role"))
	}
	if r.CountByPattern("org") != 1 {
		t.Errorf("org = %d, want 1", r.CountByPattern("org"))
	}
	sum := r.Latency()
	if sum.Samples != 4 {
		t.Fatalf("latency Samples = %d, want 4", sum.Samples)
	}
	if sum.MaxMs < 150 {
		t.Errorf("MaxMs = %v, want >= 150", sum.MaxMs)
	}
}

func TestReceiver_LatencyParseErrorsCounted(t *testing.T) {
	r := &Receiver{stream: "region-events", latency: NewLatencyTracker()}
	streams := []redis.XStream{{
		Stream: "region-events",
		Messages: []redis.XMessage{
			{ID: "1-0", Values: map[string]any{"pattern": "employee"}},                                           // missing t_send_ms + applied_ms
			{ID: "2-0", Values: map[string]any{"pattern": "role", "t_send_ms": "not-an-int", "applied_ms": "1"}}, // bad parse
		},
	}}
	r.processStreams(streams)
	if r.Count() != 2 {
		t.Fatalf("Count = %d, want 2", r.Count())
	}
	if r.LatencyParseErrors() != 2 {
		t.Fatalf("LatencyParseErrors = %d, want 2", r.LatencyParseErrors())
	}
	if r.Latency().Samples != 0 {
		t.Fatalf("latency Samples = %d, want 0 (all parses failed)", r.Latency().Samples)
	}
}

func TestReceiver_UnknownPatternStillCounted(t *testing.T) {
	r := &Receiver{stream: "region-events", latency: NewLatencyTracker()}
	now := time.Now().UnixMilli()
	streams := []redis.XStream{{
		Stream: "region-events",
		Messages: []redis.XMessage{{
			ID: "1-0",
			Values: map[string]any{
				"pattern":    "garbage",
				"t_send_ms":  strconv.FormatInt(now-1, 10),
				"applied_ms": strconv.FormatInt(now, 10),
			},
		}},
	}}
	r.processStreams(streams)
	if r.Count() != 1 {
		t.Fatalf("Count = %d, want 1", r.Count())
	}
	if got := r.CountByPattern("garbage"); got != 0 {
		t.Errorf("unknown pattern bucket = %d, want 0", got)
	}
}
