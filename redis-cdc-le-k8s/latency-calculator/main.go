// latency-calculator: consume the region cdc:latency stream, keep a rolling
// window, and periodically write a p50/p95/p99 JSON report. Region-Redis only.
package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/redis/go-redis/v9"
)

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func envInt(k string, def int) int {
	if v := os.Getenv(k); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
		log.Printf("WARN: %s=%q not an int, using %d", k, os.Getenv(k), def)
	}
	return def
}

func main() {
	addr := env("REGION_ADDR", "redis-region:6379")
	stream := env("STREAM", "cdc:latency")
	windowSec := envInt("WINDOW_SEC", 60)
	intervalSec := envInt("INTERVAL_SEC", 10)
	reportPath := env("REPORT_PATH", "/reports/latency-report.json")

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	rdb := redis.NewClient(&redis.Options{Addr: addr})
	defer rdb.Close()

	cons := NewConsumer(rdb, stream)
	if err := cons.Seek(ctx); err != nil {
		log.Printf("seek (continuing from 0-0): %v", err)
	}
	win := NewWindow(int64(windowSec) * 1000)
	cfg := ConfigMeta{IntervalSec: intervalSec, WindowSec: windowSec, Stream: stream}

	log.Printf("latency-calculator: addr=%s stream=%s window=%ds interval=%ds report=%s",
		addr, stream, windowSec, intervalSec, reportPath)

	ticker := time.NewTicker(time.Duration(intervalSec) * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			log.Print("shutting down")
			return
		case t := <-ticker.C:
			samples, err := cons.Poll(ctx)
			if err != nil {
				log.Printf("poll: %v", err)
				continue
			}
			for _, s := range samples {
				win.Add(s)
			}
			nowMs := t.UnixMilli()
			win.Evict(nowMs)
			rep := BuildReport(win, nowMs, cfg)
			if err := WriteReportAtomic(reportPath, rep); err != nil {
				log.Printf("write report: %v", err)
				continue
			}
			log.Printf("report: count=%d p50=%d p95=%d p99=%d dropped_neg=%d",
				rep.Overall.Count, rep.Overall.P50Ms, rep.Overall.P95Ms,
				rep.Overall.P99Ms, rep.Overall.DroppedNegative)
		}
	}
}
