package main

import (
	"context"
	"log"
	"time"
)

type Snapshot struct {
	At            time.Time
	WriterMetrics map[string]float64
	ConnectSrc    map[string]float64
	ConnectSink   map[string]float64
	CentralXLen   int64
	RegionXLen    int64
	NATS          NATSSnap
}

type Sampler struct {
	WriterURL    string
	ConnectSrc   string
	ConnectSink  string
	NATSURL      string
	NATSStream   string
	Central      *StreamClient
	Region       *StreamClient
}

// Tick takes a single snapshot of all instrumented services.
func (s *Sampler) Tick(ctx context.Context) Snapshot {
	now := time.Now()
	snap := Snapshot{At: now}
	c, cancel := context.WithTimeout(ctx, 1500*time.Millisecond)
	defer cancel()

	// Writer scrape errors are logged because the writer is the lab's source of truth;
	// connect-src/sink and infra errors below are intentionally swallowed — at 1Hz during
	// chaos drills they would flood logs, and the report will show 0/nil for that tick.
	if m, err := scrapePromMetrics(c, s.WriterURL+"/metrics"); err == nil {
		snap.WriterMetrics = m
	} else {
		log.Printf("scrape writer: %v", err)
	}
	if m, err := scrapePromMetrics(c, s.ConnectSrc+"/metrics"); err == nil {
		snap.ConnectSrc = m
	}
	if m, err := scrapePromMetrics(c, s.ConnectSink+"/metrics"); err == nil {
		snap.ConnectSink = m
	}
	if x, err := s.Central.XLen(c, "app.events"); err == nil {
		snap.CentralXLen = x
	}
	if x, err := s.Region.XLen(c, "region-events"); err == nil {
		snap.RegionXLen = x
	}
	if n, err := ScrapeJSZ(c, s.NATSURL, s.NATSStream); err == nil {
		snap.NATS = n
	}
	return snap
}

