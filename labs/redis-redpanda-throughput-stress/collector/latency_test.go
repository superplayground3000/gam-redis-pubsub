package main

import (
	"testing"

	"github.com/redis/go-redis/v9"
)

func TestExtractSyncLatencyMs_OK(t *testing.T) {
	fields := map[string]any{
		"t_send_ms":  "1700000000000",
		"applied_ms": "1700000000123",
	}
	got, err := extractSyncLatencyMs(fields)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != 123 {
		t.Fatalf("got %d, want 123", got)
	}
}

func TestExtractSyncLatencyMs_MissingFields(t *testing.T) {
	if _, err := extractSyncLatencyMs(map[string]any{"t_send_ms": "1"}); err == nil {
		t.Error("expected error when applied_ms missing")
	}
	if _, err := extractSyncLatencyMs(map[string]any{"applied_ms": "1"}); err == nil {
		t.Error("expected error when t_send_ms missing")
	}
}

func TestExtractSyncLatencyMs_NegativeClamped(t *testing.T) {
	// Clock skew or out-of-order edge case: applied_ms < t_send_ms.
	// Should not panic; tracker handles the clamp internally.
	fields := map[string]any{
		"t_send_ms":  "1700000000200",
		"applied_ms": "1700000000100",
	}
	got, err := extractSyncLatencyMs(fields)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != -100 {
		t.Fatalf("got %d, want -100 (raw delta; clamp happens in tracker)", got)
	}
}

func TestLatencyTracker_RecordsMs(t *testing.T) {
	lt := NewLatencyTracker()
	lt.RecordMs(10)
	lt.RecordMs(50)
	lt.RecordMs(200)
	s := lt.Summary()
	if s.Samples != 3 {
		t.Fatalf("Samples = %d, want 3", s.Samples)
	}
	if s.P99Ms < 100 || s.P99Ms > 250 {
		t.Errorf("P99 = %v, want roughly 200", s.P99Ms)
	}
}

func TestLatencyTracker_ClampsNegative(t *testing.T) {
	lt := NewLatencyTracker()
	lt.RecordMs(-50) // should be clamped to 1ms (or smallest valid), not panic
	lt.RecordMs(10)
	if lt.Summary().Samples != 2 {
		t.Fatalf("Samples = %d, want 2", lt.Summary().Samples)
	}
}

func TestLatencyTracker_NegativeDeltasCounted(t *testing.T) {
	lt := NewLatencyTracker()
	lt.RecordMs(-5)
	lt.RecordMs(-1)
	lt.RecordMs(0)
	lt.RecordMs(10) // positive — should not increment negCount
	if lt.NegativeDeltas() != 3 {
		t.Fatalf("NegativeDeltas = %d, want 3", lt.NegativeDeltas())
	}
}

func TestExtractSyncLatencyMs_FloatString(t *testing.T) {
	// Reproduces the Bloblang scientific-notation regression: collector must
	// accept "1.77...e+12" as if it were the integer 1770000000000.
	fields := map[string]any{
		"t_send_ms":  "1779782642100",
		"applied_ms": "1.7797826422187412e+12",
	}
	got, err := extractSyncLatencyMs(fields)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	// Expect roughly 118 (= 1779782642218 - 1779782642100). Allow ±2 for float truncation.
	if got < 116 || got > 120 {
		t.Fatalf("got %d, want ~118 (±2 for float trunc)", got)
	}
}

// Compile-time sanity: latency.go references redis.XMessage internally.
var _ redis.XMessage
