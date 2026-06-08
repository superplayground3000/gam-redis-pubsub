package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/redis/go-redis/v9"
)

func main() {
	addr := flag.String("region", envOr("REGION_ADDR", "redis-region:6379"), "region redis addr")
	horizon := flag.Duration("horizon", durEnv("GC_HORIZON", 5*time.Minute), "tombstone GC horizon")
	interval := flag.Duration("interval", durEnv("GC_INTERVAL", 30*time.Second), "sweep interval")
	metricsAddr := flag.String("metrics", ":9090", "metrics listen addr")
	flag.Parse()

	rdb := redis.NewClient(&redis.Options{Addr: *addr})
	s := &Sweeper{RDB: rdb, HorizonMs: horizon.Milliseconds(), ScanCount: 500}

	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		c := make(chan os.Signal, 1)
		signal.Notify(c, syscall.SIGINT, syscall.SIGTERM)
		<-c
		cancel()
	}()

	http.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte("ok")) })
	http.HandleFunc("/metrics", func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintf(w, "gc_reaped_total %d\n", s.Reaped)
		fmt.Fprintf(w, "gc_tombstones %d\n", s.Tombstones)
		fmt.Fprintf(w, "gc_oldest_tombstone_age_ms %d\n", s.OldestAgeMs)
	})
	go func() { log.Fatal(http.ListenAndServe(*metricsAddr, nil)) }()

	t := time.NewTicker(*interval)
	defer t.Stop()
	for {
		n, err := s.SweepOnce(ctx, time.Now().UnixMilli())
		if err != nil && ctx.Err() == nil {
			log.Printf("sweep error: %v", err)
		} else if n > 0 {
			log.Printf("reaped %d tombstones (total %d, oldest %dms)", n, s.Reaped, s.OldestAgeMs)
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func durEnv(k string, d time.Duration) time.Duration {
	if v := os.Getenv(k); v != "" {
		if p, err := time.ParseDuration(v); err == nil {
			return p
		}
	}
	return d
}
