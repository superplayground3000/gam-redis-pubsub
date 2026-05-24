package main

import (
	"testing"
	"time"
)

func TestExtractTsNsFromValue(t *testing.T) {
	body := `{"event_id":"abc","ts_ns":1700000000000000000,"seq":1,"pad":"xxxx"}`
	got, err := extractTsNs(body)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if got != 1700000000000000000 {
		t.Errorf("got %d, want 1700000000000000000", got)
	}
}

func TestExtractTsNsMissingField(t *testing.T) {
	if _, err := extractTsNs(`{"event_id":"abc"}`); err == nil {
		t.Errorf("expected error on missing ts_ns")
	}
}

func TestLatencyTrackerRecordAndPercentiles(t *testing.T) {
	lt := NewLatencyTracker()
	now := time.Now().UnixNano()
	// Record three samples at 10ms, 50ms, 200ms relative to now.
	lt.RecordAt(now-10*int64(time.Millisecond), now)
	lt.RecordAt(now-50*int64(time.Millisecond), now)
	lt.RecordAt(now-200*int64(time.Millisecond), now)
	s := lt.Summary()
	if s.Samples != 3 {
		t.Errorf("Samples=%d, want 3", s.Samples)
	}
	// p99 must be >= 200ms (highest sample)
	if s.P99Ms < 200 {
		t.Errorf("P99Ms=%.2f, want >= 200", s.P99Ms)
	}
	// p50 must be >= 10ms and <= 200ms
	if s.P50Ms < 10 || s.P50Ms > 200 {
		t.Errorf("P50Ms=%.2f, want in [10,200]", s.P50Ms)
	}
}

func TestExtractTsNsRejectsNegative(t *testing.T) {
	if _, err := extractTsNs(`{"event_id":"abc","ts_ns":-1}`); err == nil {
		t.Errorf("expected error on negative ts_ns")
	}
}

func TestLatencyTrackerClampsOverRange(t *testing.T) {
	lt := NewLatencyTracker()
	now := int64(400_000_000_000_000_000) // arbitrary now
	// Sample 400 seconds old → above the 300s max
	lt.RecordAt(now-400_000_000_000_000_000+1, now)
	s := lt.Summary()
	if s.Samples != 1 {
		t.Errorf("Samples=%d, want 1 (over-range sample should be clamped, not dropped)", s.Samples)
	}
	// Max should be ~300s (300000ms) — clamped, not exact.
	if s.MaxMs < 290_000 || s.MaxMs > 310_000 {
		t.Errorf("MaxMs=%.2f, want near 300000 after clamp", s.MaxMs)
	}
}
