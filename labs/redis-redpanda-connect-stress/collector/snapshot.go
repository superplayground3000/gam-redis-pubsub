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
	Latency      *LatencyTracker
	LastRegionID string
}

// Tick takes a single snapshot AND pulls latency samples from region-events.
func (s *Sampler) Tick(ctx context.Context) Snapshot {
	now := time.Now()
	snap := Snapshot{At: now}
	c, cancel := context.WithTimeout(ctx, 1500*time.Millisecond)
	defer cancel()

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

	// Latency samples from region-events
	msgs, newLast, err := s.Region.XRangeSinceID(c, "region-events", s.LastRegionID, 200)
	if err == nil {
		nowNs := time.Now().UnixNano()
		for _, m := range msgs {
			v, ok := m.Values["value"].(string)
			if !ok {
				continue
			}
			ts, err := extractTsNs(v)
			if err != nil {
				continue
			}
			s.Latency.RecordAt(ts, nowNs)
		}
		s.LastRegionID = newLast
	}
	return snap
}

func (s *Sampler) Init() {
	if s.LastRegionID == "" {
		s.LastRegionID = "0-0"
	}
}
