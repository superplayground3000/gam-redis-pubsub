package main

import (
	"context"
	"encoding/json"
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"
)

type RunConfig struct {
	Tier         int
	Mode         string
	Profile      string
	Duration     time.Duration
	Warmup       time.Duration
	Drain        time.Duration
	WriterURL    string
	RedisCentral string
	RedisRegion  string
	NATSURL      string
	NATSStream   string
	ConnectSrc   string
	ConnectSink  string
	ChaosAtS     float64
	ChaosDurS    int
	SLO          SLO
}

func main() {
	var (
		tier         = flag.Int("tier", 0, "target msg/s (required)")
		mode         = flag.String("mode", "throughput", "throughput|latency|chaos")
		profile      = flag.String("profile", "alo", "alo|amo|eoe")
		duration     = flag.Duration("duration", 30*time.Second, "sustain window")
		warmup       = flag.Duration("warmup", 5*time.Second, "warmup window")
		drain        = flag.Duration("drain", 10*time.Second, "drain window")
		out          = flag.String("out", "/reports/run.json", "report JSON path")
		writerURL    = flag.String("writer", "http://writer:8081", "writer URL")
		central      = flag.String("redis-central", "redis-central:6379", "")
		region       = flag.String("redis-region", "redis-region:6379", "")
		natsURL      = flag.String("nats", "http://nats:8222", "NATS monitoring URL")
		natsStream   = flag.String("nats-stream", "APP_EVENTS", "JetStream stream name")
		connectSrc   = flag.String("connect-src", "http://connect-source:4195", "")
		connectSink  = flag.String("connect-sink", "http://connect-sink:4195", "")
		chaosAtS     = flag.Float64("chaos-at-s", 0, "seconds into sustain to record chaos lag (harness drives the kill)")
		chaosDur     = flag.Int("chaos-duration", 8, "outage seconds (recorded only)")
		sloRatePct   = flag.Float64("slo-rate-pct", 0.95, "")
		sloP99Ms     = flag.Float64("slo-p99-ms", 1000, "")
		sloAllowMiss = flag.Bool("slo-allow-missing", false, "")
	)
	flag.Parse()
	if *tier <= 0 {
		log.Fatal("--tier required (>0)")
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() {
		c := make(chan os.Signal, 1)
		signal.Notify(c, syscall.SIGINT, syscall.SIGTERM)
		<-c
		cancel()
	}()

	cfg := RunConfig{
		Tier: *tier, Mode: *mode, Profile: *profile,
		Duration: *duration, Warmup: *warmup, Drain: *drain,
		WriterURL:    *writerURL,
		RedisCentral: *central, RedisRegion: *region,
		NATSURL: *natsURL, NATSStream: *natsStream,
		ConnectSrc: *connectSrc, ConnectSink: *connectSink,
		ChaosAtS: *chaosAtS, ChaosDurS: *chaosDur,
		SLO: SLO{
			RateMinPct: *sloRatePct, LatencyP99Ms: *sloP99Ms,
			AllowMissing: *sloAllowMiss,
		},
	}

	r, err := Run(ctx, cfg)
	if err != nil {
		log.Fatalf("run failed: %v", err)
	}

	if err := writeJSON(*out, r); err != nil {
		log.Fatalf("write %s: %v", *out, err)
	}
	log.Printf("report written to %s; verdict.pass=%v", *out, r.Verdict.Pass)
	if !r.Verdict.Pass {
		os.Exit(1)
	}
}

func writeJSON(path string, v any) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	enc := json.NewEncoder(f)
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}

func Run(ctx context.Context, cfg RunConfig) (Report, error) {
	central := NewStreamClient(cfg.RedisCentral)
	defer central.Close()
	region := NewStreamClient(cfg.RedisRegion)
	defer region.Close()

	// 1. Trim streams to zero so we measure only this tier's traffic.
	_ = central.Trim(ctx, "app.events")
	_ = region.Trim(ctx, "region-events")

	// 2. Reset writer counters.
	if err := PostReset(ctx, cfg.WriterURL); err != nil {
		return Report{}, err
	}

	// 3. Warmup at half rate.
	if err := PostRate(ctx, cfg.WriterURL, cfg.Tier/2); err != nil {
		return Report{}, err
	}
	sleep(ctx, cfg.Warmup)

	// 4. Sustain at full rate.
	if err := PostRate(ctx, cfg.WriterURL, cfg.Tier); err != nil {
		return Report{}, err
	}

	sampler := &Sampler{
		WriterURL: cfg.WriterURL, ConnectSrc: cfg.ConnectSrc,
		ConnectSink: cfg.ConnectSink, NATSURL: cfg.NATSURL,
		NATSStream: cfg.NATSStream,
		Central:    central, Region: region,
		Latency: NewLatencyTracker(),
	}
	sampler.Init()

	startedAt := time.Now()
	sustainEnd := startedAt.Add(cfg.Duration)

	ticker := time.NewTicker(1 * time.Second)
	defer ticker.Stop()

	var snaps []Snapshot
	// Sustain window
	for time.Now().Before(sustainEnd) {
		select {
		case <-ctx.Done():
			return Report{}, ctx.Err()
		case <-ticker.C:
			snaps = append(snaps, sampler.Tick(ctx))
		}
	}

	// 5. Drain.
	if err := PostRate(ctx, cfg.WriterURL, 0); err != nil {
		return Report{}, err
	}
	drainEnd := time.Now().Add(cfg.Drain)
	for time.Now().Before(drainEnd) {
		select {
		case <-ctx.Done():
			return Report{}, ctx.Err()
		case <-ticker.C:
			snaps = append(snaps, sampler.Tick(ctx))
		}
	}

	// 6. Final snapshot
	final := sampler.Tick(ctx)
	snaps = append(snaps, final)

	return buildReport(cfg, startedAt, snaps, sampler.Latency.Summary()), nil
}

func buildReport(cfg RunConfig, startedAt time.Time, snaps []Snapshot, lat LatencySummary) Report {
	r := Report{
		Tier: cfg.Tier, Mode: cfg.Mode, Profile: cfg.Profile,
		StartedAt: startedAt, DurationS: int(cfg.Duration.Seconds()),
		RateTarget: cfg.Tier,
		Latency:    lat,
		SLO:        cfg.SLO,
	}

	// Sent + errors are end-of-run values from the last snapshot.
	if len(snaps) > 0 {
		last := snaps[len(snaps)-1]
		r.Sent = int64(last.WriterMetrics["stress_writer_sent_total"])
		r.Errors = int64(last.WriterMetrics["stress_writer_errors_total"])
		r.Received = last.RegionXLen
		r.Redis.RegionXLenFinal = last.RegionXLen
		r.Connect.SourceIn = int64(last.ConnectSrc["input_received"])
		r.Connect.SourceOut = int64(last.ConnectSrc["output_sent"])
		r.Connect.SinkIn = int64(last.ConnectSink["input_received"])
		r.Connect.SinkOut = int64(last.ConnectSink["output_sent"])
		r.NATS.Bytes = last.NATS.Bytes
	}
	r.Missing = r.Sent - r.Received
	if r.Missing < 0 {
		r.Missing = 0
	}
	if r.Sent > 0 {
		r.MissingPct = float64(r.Missing) / float64(r.Sent) * 100.0
	}

	// Per-second sent deltas → achieved rate avg/min, central XLen max, NATS pending max.
	var minRate float64 = 1e18
	var sumRate, samples float64
	var lastSent int64
	var maxXLen, maxPending int64
	for i, snap := range snaps {
		sent := int64(snap.WriterMetrics["stress_writer_sent_total"])
		if i > 0 {
			delta := float64(sent - lastSent)
			if delta < 0 {
				delta = 0
			}
			sumRate += delta
			samples++
			if delta < minRate {
				minRate = delta
			}
		}
		lastSent = sent
		if snap.CentralXLen > maxXLen {
			maxXLen = snap.CentralXLen
		}
		if snap.NATS.MaxPending > maxPending {
			maxPending = snap.NATS.MaxPending
		}
	}
	if samples > 0 {
		r.RateAchievedAvg = sumRate / samples
		r.RateAchievedMin = minRate
	}
	r.Redis.CentralXLenMax = maxXLen
	r.NATS.PendingMax = maxPending

	if cfg.Mode == "chaos" && cfg.ChaosAtS > 0 {
		r.Chaos = &ChaosInfo{
			Action:         "kill-connect-sink",
			DownAtS:        int(cfg.ChaosAtS),
			DurationS:      cfg.ChaosDurS,
			RecoveryLagMax: maxPending,
		}
	}

	r.Verdict = ComputeVerdict(VerdictInput{
		Mode: cfg.Mode, RateTarget: cfg.Tier,
		RateAchievedAvg: r.RateAchievedAvg,
		Missing:         r.Missing,
		LatencyP99Ms:    r.Latency.P99Ms,
		SLO:             cfg.SLO,
	})
	return r
}

func sleep(ctx context.Context, d time.Duration) {
	select {
	case <-ctx.Done():
	case <-time.After(d):
	}
}
