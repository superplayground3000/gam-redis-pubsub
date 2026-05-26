package main

import (
	"testing"
	"time"
)

// TestBuildReport_RateLoopSkipsFailedScrapes is a regression test for the
// rate-loop bug where a failed writer scrape (empty WriterMetrics map) would
// reset lastSent/lastAt to 0/scrape-time and corrupt the next interval's
// delta math. The fix gates the loop body on snap.WriterOK() and skips
// empty snapshots entirely, so the next successful snapshot computes its
// delta against the previous SUCCESSFUL one.
func TestBuildReport_RateLoopSkipsFailedScrapes(t *testing.T) {
	cfg := RunConfig{
		Tier: 1000, Mode: "batch",
		Duration: 3 * time.Second,
		SLO:      SLO{RateMinPct: 0.9, LatencyP99MsMax: nil},
	}
	startedAt := time.Date(2026, 5, 26, 12, 0, 0, 0, time.UTC)
	snaps := []Snapshot{
		// t=0s: 0 sent, rate_target=1000 (start of sustain).
		{At: startedAt, WriterMetrics: map[string]float64{"stress_writer_sent_total": 0, "stress_writer_rate_target": 1000}},
		// t=1s: 1000 sent -> delta = 1000/s.
		{At: startedAt.Add(1 * time.Second), WriterMetrics: map[string]float64{"stress_writer_sent_total": 1000, "stress_writer_rate_target": 1000}},
		// t=2s: scrape FAILED (empty map). Must be skipped, not corrupt the next delta.
		{At: startedAt.Add(2 * time.Second), WriterMetrics: map[string]float64{}},
		// t=3s: 3000 sent. With the fix: delta vs t=1s = 2000 over 2s = 1000/s (correct).
		// Without the fix: delta vs t=2s (lastSent=0, lastAt=t=2s) = 3000/1s = 3000/s (wrong).
		{At: startedAt.Add(3 * time.Second), WriterMetrics: map[string]float64{"stress_writer_sent_total": 3000, "stress_writer_rate_target": 1000}},
	}
	receiver := &Receiver{stream: "region-events", latency: NewLatencyTracker()}
	receiver.received.Store(2950)

	r := buildReport(cfg, startedAt, snaps, receiver, 0, false)

	if r.RateAchievedAvg < 950 || r.RateAchievedAvg > 1050 {
		t.Errorf("RateAchievedAvg = %v, want ~1000 (failed scrape should not corrupt)", r.RateAchievedAvg)
	}
	if r.Sent != 3000 {
		t.Errorf("Sent = %d, want 3000 (carry-forward from last successful scrape)", r.Sent)
	}
}
