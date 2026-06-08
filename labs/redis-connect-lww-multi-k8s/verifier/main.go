package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	var (
		rate        = flag.Int("rate", 5000, "target msg/s")
		epochSeed   = flag.String("epoch", "", "unique per-run epoch token (required)")
		duration    = flag.Duration("duration", 30*time.Second, "sustain window")
		warmup      = flag.Duration("warmup", 5*time.Second, "warmup window")
		drain       = flag.Duration("drain", 10*time.Second, "drain window")
		extendOnce  = flag.Bool("extend-once", true, "extend sustain once if stale==0 before declaring inconclusive")
		writerURL   = flag.String("writer", "http://writer:8081", "writer URL")
		region      = flag.String("redis-region", "redis-region:6379", "")
		central     = flag.String("redis-central", "redis-central:6379", "")
		connectSinkDNS  = flag.String("connect-sink-dns", "connect-sink-headless", "headless Service DNS name resolving to every sink pod IP")
		connectSinkPort = flag.String("connect-sink-port", "4195", "sink pod metrics port")
		natsURL     = flag.String("nats", "http://nats:8222", "NATS monitoring URL")
		natsStream  = flag.String("nats-stream", "APP_EVENTS", "")
		sampleN     = flag.Int("empty-sample", 64, "keys to probe for empty-store precondition")
	)
	flag.Parse()
	if *epochSeed == "" {
		log.Fatal("--epoch required (unique per run)")
	}
	epoch := mintEpoch(*epochSeed)

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() {
		c := make(chan os.Signal, 1)
		signal.Notify(c, syscall.SIGINT, syscall.SIGTERM)
		<-c
		cancel()
	}()

	regionC := NewStreamClient(*region)
	defer regionC.Close()
	centralC := NewStreamClient(*central)
	defer centralC.Close()

	// 0. Trim streams so we measure only this run.
	_ = centralC.Trim(ctx, "app.events")
	_ = regionC.Trim(ctx, "region-events")

	// 1. Reset writer to the fresh epoch; capture boot0.
	if err := PostResetEpoch(ctx, *writerURL, epoch); err != nil {
		log.Fatalf("reset writer: %v", err)
	}
	st0, err := FetchState(ctx, *writerURL)
	if err != nil {
		log.Fatalf("state0: %v", err)
	}
	// The writer must have ADOPTED our epoch — otherwise a silent no-op reset
	// would let us certify a verdict for the wrong key namespace.
	if st0.Epoch != epoch {
		log.Fatalf("writer did not adopt epoch %q (reports %q): reset was a no-op?", epoch, st0.Epoch)
	}
	boot0 := st0.BootID

	// 2. Empty-store precondition (region must have no ver for the epoch's keys).
	storeEmpty, err := StoreEmptyForEpoch(ctx, regionC, epoch, *sampleN)
	if err != nil {
		log.Fatalf("empty-store probe: %v", err)
	}

	// 3. Warmup at half rate.
	_ = PostRate(ctx, *writerURL, *rate/2)
	sleep(ctx, *warmup)

	// 4. Baseline the cumulative sink counters at SUSTAIN START (after warmup). The
	// connect-sink counters are cumulative since the pod started, so all proof
	// signals are deltas against this baseline. A failed baseline scrape would make
	// the deltas garbage (full lifetime counters), so it is a hard precondition fail.
	sinkBase, err := NewSinkBaseline(ctx, *connectSinkDNS, *connectSinkPort)
	if err != nil {
		log.Fatalf("baseline scrape (sink pods via %s): %v", *connectSinkDNS, err)
	}
	log.Printf("aggregating lww_apply across %d sink pods", sinkBase.PodCount())

	// 5. Sustain at full rate, sampling throughput each second. lastSent is seeded
	// from a FRESH scrape at the start of each window (not a shared closure var) so
	// the extend-once call doesn't divide a whole window's cumulative delta by ~1s.
	_ = PostRate(ctx, *writerURL, *rate)
	runStale := func(window time.Duration) (int64, int64, int64, float64) {
		end := time.Now().Add(window)
		ticker := time.NewTicker(time.Second)
		defer ticker.Stop()
		lastSent, _ := scrapeWriterSent(ctx, *writerURL)
		lastAt := time.Now()
		var sumRate, n float64
		for time.Now().Before(end) {
			select {
			case <-ctx.Done():
				return 0, 0, 0, 0
			case <-ticker.C:
				sent, ok := scrapeWriterSent(ctx, *writerURL)
				if !ok {
					continue // skip this sample; don't corrupt lastSent with a 0
				}
				dt := time.Since(lastAt).Seconds()
				if dt > 0 && sent >= lastSent {
					sumRate += float64(sent-lastSent) / dt
					n++
				}
				lastSent, lastAt = sent, time.Now()
			}
		}
		a, s, d, serr := sinkBase.Delta(ctx)
		if serr != nil {
			log.Fatalf("end-of-window sink aggregation: %v", serr)
		}
		rateAvg := 0.0
		if n > 0 {
			rateAvg = sumRate / n
		}
		return a, s, d, rateAvg
	}
	applied, stale, duplicate, rateAvg := runStale(*duration)

	// 6. Drain + quiescence so all in-flight messages settle before we compare.
	// quiesceOK tracks whether the pipeline actually drained; a timeout makes the
	// comparison premature, so it fails the verdict (see ComputeLWWVerdict).
	_ = PostRate(ctx, *writerURL, 0)
	sleep(ctx, *drain)
	quiesceOK := !waitForPipelineQuiescence(ctx, "lww", centralC, *natsURL, *natsStream, 10*time.Second)
	sleep(ctx, 1500*time.Millisecond)

	// 6b. If no reordering was observed, extend once before declaring inconclusive.
	if stale == 0 && *extendOnce {
		log.Printf("stale==0 after first window; extending once")
		_ = PostRate(ctx, *writerURL, *rate)
		a, s, d, r2 := runStale(*duration)
		applied, stale, duplicate = a, s, d
		if r2 > rateAvg {
			rateAvg = r2
		}
		_ = PostRate(ctx, *writerURL, 0)
		sleep(ctx, *drain)
		quiesceOK = !waitForPipelineQuiescence(ctx, "lww", centralC, *natsURL, *natsStream, 10*time.Second)
		sleep(ctx, 1500*time.Millisecond)
	}

	// 7. Final source-of-truth + boot recheck.
	stFinal, err := FetchState(ctx, *writerURL)
	if err != nil {
		log.Fatalf("stateFinal: %v", err)
	}
	if stFinal.Epoch != epoch {
		log.Fatalf("writer epoch changed mid-run to %q (expected %q)", stFinal.Epoch, epoch)
	}
	bootOK := stFinal.BootID == boot0

	// 8. Per-key version comparison.
	checked, mismatches, regressions, err := CompareVersions(ctx, regionC, stFinal)
	if err != nil {
		log.Fatalf("compare versions: %v", err)
	}

	wpk := 0.0
	if stFinal.DistinctKeys > 0 {
		wpk = float64(stFinal.TotalVersions) / float64(stFinal.DistinctKeys)
	}

	res := LWWResult{
		Epoch: epoch, KeysChecked: checked, Mismatches: mismatches, Regressions: regressions,
		Applied: applied, Stale: stale, Duplicate: duplicate,
		WritesPerKeyAvg: wpk, RateTarget: *rate, RateAchievedAvg: rateAvg,
		BootOK: bootOK, StoreEmptyAtStart: storeEmpty, QuiescenceOK: quiesceOK,
	}
	emit(res)
}

func emit(res LWWResult) {
	rep := Report{LWW: res, Verdict: ComputeLWWVerdict(res)}
	b, _ := json.Marshal(rep)
	fmt.Printf("RESULT_JSON:%s\n", b)
	log.Printf("verdict.pass=%v reason=%q stale=%d mismatches=%d rate=%.1f wpk=%.1f",
		rep.Verdict.Pass, rep.Verdict.Reason, res.Stale, res.Mismatches, res.RateAchievedAvg, res.WritesPerKeyAvg)
}

func sleep(ctx context.Context, d time.Duration) {
	select {
	case <-ctx.Done():
	case <-time.After(d):
	}
}
