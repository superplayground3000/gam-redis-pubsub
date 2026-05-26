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
	Mode         string // "batch" | "single"
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
	SLO          SLO
}

func main() {
	var (
		tier        = flag.Int("tier", 0, "target msg/s (required)")
		mode        = flag.String("mode", "batch", "batch|single")
		duration    = flag.Duration("duration", 30*time.Second, "sustain window")
		warmup      = flag.Duration("warmup", 5*time.Second, "warmup window")
		drain       = flag.Duration("drain", 10*time.Second, "drain window")
		out         = flag.String("out", "/reports/run.json", "report JSON path")
		writerURL   = flag.String("writer", "http://writer:8081", "writer URL")
		central     = flag.String("redis-central", "redis-central:6379", "")
		region      = flag.String("redis-region", "redis-region:6379", "")
		natsURL     = flag.String("nats", "http://nats:8222", "NATS monitoring URL")
		natsStream  = flag.String("nats-stream", "APP_EVENTS", "JetStream stream name")
		connectSrc  = flag.String("connect-src", "http://connect-source:4195", "")
		connectSink = flag.String("connect-sink", "http://connect-sink:4195", "")
		sloRatePct  = flag.Float64("slo-rate-pct", 0.90, "")
		sloP99Ms    = flag.Float64("slo-p99-ms", -1, "<=0 means no p99 gate (calibration mode)")
	)
	flag.Parse()
	if *tier <= 0 {
		log.Fatal("--tier required (>0)")
	}
	if *mode != "batch" && *mode != "single" {
		log.Fatalf("--mode must be batch|single, got %q", *mode)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() {
		c := make(chan os.Signal, 1)
		signal.Notify(c, syscall.SIGINT, syscall.SIGTERM)
		<-c
		cancel()
	}()

	slo := SLO{RateMinPct: *sloRatePct}
	if *sloP99Ms > 0 {
		v := *sloP99Ms
		slo.LatencyP99MsMax = &v
	}

	cfg := RunConfig{
		Tier: *tier, Mode: *mode,
		Duration: *duration, Warmup: *warmup, Drain: *drain,
		WriterURL:    *writerURL,
		RedisCentral: *central, RedisRegion: *region,
		NATSURL: *natsURL, NATSStream: *natsStream,
		ConnectSrc: *connectSrc, ConnectSink: *connectSink,
		SLO: slo,
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

	if err := central.Trim(ctx, "app.events"); err != nil {
		return Report{}, fmt.Errorf("trim app.events: %w", err)
	}
	if err := region.Trim(ctx, "region-events"); err != nil {
		return Report{}, fmt.Errorf("trim region-events: %w", err)
	}
	if err := PostReset(ctx, cfg.WriterURL); err != nil {
		return Report{}, err
	}

	defer func() {
		c, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = PostRate(c, cfg.WriterURL, 0, "")
	}()

	receiver := NewReceiver(cfg.RedisRegion, "region-events")
	defer receiver.Close()
	receiverCtx, cancelRecv := context.WithCancel(ctx)
	defer cancelRecv()

	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		receiver.Run(receiverCtx)
	}()

	// Arm the writer's mode before warmup (rate=tier/2, mode=cfg.Mode).
	if err := PostRate(ctx, cfg.WriterURL, cfg.Tier/2, cfg.Mode); err != nil {
		return Report{}, err
	}
	sleep(ctx, cfg.Warmup)

	if err := PostRate(ctx, cfg.WriterURL, cfg.Tier, ""); err != nil {
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

	if err := PostRate(ctx, cfg.WriterURL, 0, ""); err != nil {
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

	quiescenceTimedOut := waitForPipelineQuiescence(
		ctx, central, cfg.NATSURL, cfg.NATSStream, 10*time.Second)
	if ctx.Err() != nil {
		return Report{}, ctx.Err()
	}

	sleep(ctx, 1500*time.Millisecond) // tail-flush; see spec §5 step 10
	if ctx.Err() != nil {
		return Report{}, ctx.Err()
	}

	snaps = append(snaps, sampler.Tick(ctx))
	cancelRecv()
	wg.Wait()

	finalRegionXLen := readFinalRegionXLen(ctx, region, snaps)
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
		Tier: cfg.Tier, Mode: cfg.Mode,
		StartedAt: startedAt, DurationS: int(cfg.Duration.Seconds()),
		RateTarget:  cfg.Tier,
		SyncLatency: receiver.Latency(),
		SLO:         cfg.SLO,
	}
	r.Received = receiver.Count()
	r.ReceivedErrors = receiver.Errors()
	r.QuiescenceTimeout = quiescenceTimedOut
	r.Redis.RegionXLenFinal = finalRegionXLen
	r.Trimmed = r.Received - r.Redis.RegionXLenFinal
	if r.Trimmed < 0 {
		r.Trimmed = 0
	}
	r.ReceivedByPattern = map[string]int64{
		"employee": receiver.CountByPattern("employee"),
		"role":     receiver.CountByPattern("role"),
		"org":      receiver.CountByPattern("org"),
	}
	// Carry-forward the most recent successful scrape per source. A failed final
	// scrape would otherwise silently zero r.Sent and make r.Missing meaningless.
	// Track separately because writer/connect/nats can each fail independently.
	var lastWriterOK, lastSrcOK, lastSinkOK *Snapshot
	for i := len(snaps) - 1; i >= 0; i-- {
		s := &snaps[i]
		if lastWriterOK == nil && s.WriterOK() {
			lastWriterOK = s
		}
		if lastSrcOK == nil && s.ConnectSrcOK() {
			lastSrcOK = s
		}
		if lastSinkOK == nil && s.ConnectSinkOK() {
			lastSinkOK = s
		}
		if lastWriterOK != nil && lastSrcOK != nil && lastSinkOK != nil {
			break
		}
	}
	if lastWriterOK != nil {
		r.Sent = int64(lastWriterOK.WriterMetrics["stress_writer_sent_total"])
		r.Errors = int64(lastWriterOK.WriterMetrics["stress_writer_errors_total"])
	}
	if lastSrcOK != nil {
		r.Connect.SourceIn = int64(lastSrcOK.ConnectSrc["input_received"])
		r.Connect.SourceOut = int64(lastSrcOK.ConnectSrc["output_sent"])
	}
	if lastSinkOK != nil {
		r.Connect.SinkIn = int64(lastSinkOK.ConnectSink["input_received"])
		r.Connect.SinkOut = int64(lastSinkOK.ConnectSink["output_sent"])
	}
	// NATS bytes: use the last non-zero value (or 0 if never sampled successfully).
	for i := len(snaps) - 1; i >= 0; i-- {
		if snaps[i].NATS.Bytes > 0 {
			r.NATS.Bytes = snaps[i].NATS.Bytes
			break
		}
	}
	r.Missing = r.Sent - r.Received
	if r.Missing < 0 {
		r.Missing = 0
	}
	if r.Sent > 0 {
		r.MissingPct = float64(r.Missing) / float64(r.Sent) * 100.0
	}
	if r.Received > r.Sent && r.Sent > 0 {
		log.Printf("WARN: received (%d) > sent (%d) — possible scrape failure; missing is unreliable", r.Received, r.Sent)
	}
	r.LatencyParseErrors = receiver.LatencyParseErrors()
	if r.LatencyParseErrors > 0 {
		log.Printf("WARN: %d latency-field parse failures detected (out of %d received). sync_latency histogram excludes these — interpret with caution.", r.LatencyParseErrors, r.Received)
	}
	r.NegativeLatencyDeltas = receiver.NegativeLatencyDeltas()
	if r.NegativeLatencyDeltas > 0 {
		log.Printf("WARN: %d negative sync-latency deltas observed (clock skew or wrong-field path). Clamped to 1ms in histogram.", r.NegativeLatencyDeltas)
	}

	var minRate float64 = 1e18
	var sumRate, samples float64
	var lastSent int64
	var lastAt time.Time
	var maxXLen, maxPending int64
	for i, snap := range snaps {
		sent := int64(snap.WriterMetrics["stress_writer_sent_total"])
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

	r.Verdict = ComputeVerdict(VerdictInput{
		RateTarget:      cfg.Tier,
		RateAchievedAvg: r.RateAchievedAvg,
		Missing:         r.Missing,
		LatencyP99Ms:    r.SyncLatency.P99Ms,
		SLO:             cfg.SLO,
	})
	if cfg.SLO.LatencyP99MsMax == nil {
		log.Printf("WARN: p99 latency gate is SKIPPED (calibration mode). Run produced p99=%.1fms but verdict ignored it. Set --slo-p99-ms to gate.", r.SyncLatency.P99Ms)
	}
	return r
}

func sleep(ctx context.Context, d time.Duration) {
	select {
	case <-ctx.Done():
	case <-time.After(d):
	}
}

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
