package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
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
	if *mode == "chaos" && *chaosAtS <= 0 {
		log.Fatal("--chaos-at-s must be > 0 when --mode=chaos")
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
	tmp, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".tmp-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	enc := json.NewEncoder(tmp)
	enc.SetIndent("", "  ")
	if err := enc.Encode(v); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpName)
		return err
	}
	return os.Rename(tmpName, path)
}

func Run(ctx context.Context, cfg RunConfig) (Report, error) {
	central := NewStreamClient(cfg.RedisCentral)
	defer central.Close()
	region := NewStreamClient(cfg.RedisRegion)
	defer region.Close()

	// 1+2. Trim streams to zero so we measure only this tier's traffic.
	if err := central.Trim(ctx, "app.events"); err != nil {
		return Report{}, fmt.Errorf("trim app.events: %w", err)
	}
	if err := region.Trim(ctx, "region-events"); err != nil {
		return Report{}, fmt.Errorf("trim region-events: %w", err)
	}

	// 3. Reset writer counters.
	if err := PostReset(ctx, cfg.WriterURL); err != nil {
		return Report{}, err
	}

	// Best-effort pause writer on any return path.
	defer func() {
		c, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = PostRate(c, cfg.WriterURL, 0)
	}()

	// 4-6. Start the receiver — single goroutine, joined via WaitGroup.
	receiver := NewReceiver(cfg.RedisRegion, "region-events")
	defer receiver.Close()
	receiverCtx, cancelRecv := context.WithCancel(ctx)
	defer cancelRecv() // safety net; explicit cancel below is the live path

	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		receiver.Run(receiverCtx)
	}()

	// 7. Warmup at half rate.
	if err := PostRate(ctx, cfg.WriterURL, cfg.Tier/2); err != nil {
		return Report{}, err
	}
	sleep(ctx, cfg.Warmup)

	// 8. Sustain at full rate.
	if err := PostRate(ctx, cfg.WriterURL, cfg.Tier); err != nil {
		return Report{}, err
	}

	sampler := &Sampler{
		WriterURL: cfg.WriterURL, ConnectSrc: cfg.ConnectSrc,
		ConnectSink: cfg.ConnectSink, NATSURL: cfg.NATSURL,
		NATSStream: cfg.NATSStream,
		Central:    central, Region: region,
	}

	startedAt := time.Now()
	sustainEnd := startedAt.Add(cfg.Duration)

	ticker := time.NewTicker(1 * time.Second)
	defer ticker.Stop()

	var snaps []Snapshot
	for time.Now().Before(sustainEnd) {
		select {
		case <-ctx.Done():
			return Report{}, ctx.Err()
		case <-ticker.C:
			snaps = append(snaps, sampler.Tick(ctx))
		}
	}

	// 9. Drain.
	if err := PostRate(ctx, cfg.WriterURL, 0); err != nil {
		return Report{}, err
	}
	// 10. drain ticker loop.
	drainEnd := time.Now().Add(cfg.Drain)
	for time.Now().Before(drainEnd) {
		select {
		case <-ctx.Done():
			return Report{}, ctx.Err()
		case <-ticker.C:
			snaps = append(snaps, sampler.Tick(ctx))
		}
	}

	// 11. Pipeline quiescence (profile-aware).
	quiescenceTimedOut := waitForPipelineQuiescence(
		ctx, cfg.Profile, central, cfg.NATSURL, cfg.NATSStream, 10*time.Second)
	if ctx.Err() != nil {
		return Report{}, ctx.Err()
	}

	// 12. Tail-flush window for the receiver.
	sleep(ctx, 500*time.Millisecond)
	if ctx.Err() != nil {
		return Report{}, ctx.Err()
	}

	// Final tick to capture post-drain snapshot fields (Sent, Errors, Connect, NATS.Bytes).
	final := sampler.Tick(ctx)
	snaps = append(snaps, final)

	// 13. Cancel receiver; 14. wait for it to fully exit.
	cancelRecv()
	wg.Wait()

	// 15. Synchronized end-of-run XLEN cut for trimmed math.
	finalRegionXLen := readFinalRegionXLen(ctx, region, snaps)

	// 16. Build report.
	return buildReport(cfg, startedAt, snaps, receiver, finalRegionXLen, quiescenceTimedOut), nil
}

func buildReport(
	cfg RunConfig,
	startedAt time.Time,
	snaps []Snapshot,
	receiver *Receiver,
	finalRegionXLen int64,
	quiescenceTimedOut bool,
) Report {
	r := Report{
		Tier: cfg.Tier, Mode: cfg.Mode, Profile: cfg.Profile,
		StartedAt: startedAt, DurationS: int(cfg.Duration.Seconds()),
		RateTarget: cfg.Tier,
		Latency:    receiver.Latency(),
		SLO:        cfg.SLO,
	}

	// Sent + errors + Connect + NATS.Bytes are end-of-run values from the last snapshot.
	// Received is sourced from the streaming receiver, not the snapshot XLEN — receiver
	// is untainted by region-events MAXLEN trimming.
	r.Received = receiver.Count()
	r.ReceivedErrors = receiver.Errors()
	r.QuiescenceTimeout = quiescenceTimedOut
	r.Redis.RegionXLenFinal = finalRegionXLen
	r.Trimmed = r.Received - r.Redis.RegionXLenFinal
	if r.Trimmed < 0 {
		r.Trimmed = 0
	}
	if len(snaps) > 0 {
		last := snaps[len(snaps)-1]
		r.Sent = int64(last.WriterMetrics["stress_writer_sent_total"])
		r.Errors = int64(last.WriterMetrics["stress_writer_errors_total"])
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

	// Per-snapshot rate samples computed from actual wall clock between ticks,
	// not assumed-1s intervals. Counter resets (negative delta) zero the sample.
	var minRate float64 = 1e18
	var sumRate, samples float64
	var lastSent int64
	var lastAt time.Time
	var maxXLen, maxPending int64
	for i, snap := range snaps {
		sent := int64(snap.WriterMetrics["stress_writer_sent_total"])
		// Only count snapshots while the writer's rate_target matches the tier (i.e.
		// during sustain). Drain-window snapshots have rate_target=0 and would otherwise
		// pull the average down toward zero.
		rateTarget := int(snap.WriterMetrics["stress_writer_rate_target"])
		if i > 0 && rateTarget == cfg.Tier {
			deltaSec := snap.At.Sub(lastAt).Seconds()
			if deltaSec > 0 {
				deltaCount := float64(sent - lastSent)
				if deltaCount < 0 {
					deltaCount = 0
				}
				rate := deltaCount / deltaSec
				sumRate += rate
				samples++
				if rate < minRate {
					minRate = rate
				}
			}
		}
		lastSent = sent
		lastAt = snap.At
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

// readFinalRegionXLen returns XLEN("region-events") with bounded retries.
// On persistent failure it falls back to the last snapshot's RegionXLen so
// that a transient Redis hiccup at end-of-run never corrupts the trimmed
// math by leaving finalRegionXLen at zero. The fallback value is at most
// one snapshot tick (~1s) stale. See spec §6.4.
func readFinalRegionXLen(ctx context.Context, region xlenReader, snaps []Snapshot) int64 {
	const attempts = 3
	var lastErr error
	for i := 0; i < attempts; i++ {
		if x, err := region.XLen(ctx, "region-events"); err == nil {
			return x
		} else {
			lastErr = err
		}
		if ctx.Err() != nil {
			break
		}
		select {
		case <-ctx.Done():
		case <-time.After(100 * time.Millisecond):
		}
	}
	log.Printf("WARN: final XLEN(region-events) failed after %d attempts: %v; falling back to last snapshot", attempts, lastErr)
	if len(snaps) > 0 {
		return snaps[len(snaps)-1].RegionXLen
	}
	return 0
}
