package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/redis/go-redis/v9"
)

func main() {
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo})))

	addr := getenv("REDIS_ADDR", "redis-sink:6379")
	maxMessages := atoiOr("MAX_MESSAGES", 100)
	deadlineSec := atoiOr("DEADLINE_SECONDS", 120)

	slog.Info("starting client", "addr", addr, "max", maxMessages, "deadline_s", deadlineSec)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	rdb, err := connectRedis(ctx, addr, 10, time.Second)
	if err != nil {
		slog.Error("redis connect failed", "err", err)
		os.Exit(1)
	}
	defer rdb.Close()

	deadline := time.Now().Add(time.Duration(deadlineSec) * time.Second)
	seen := make(map[int64]int64) // event id → latency_ns
	ticker := time.NewTicker(200 * time.Millisecond)
	defer ticker.Stop()

	for len(seen) < maxMessages {
		select {
		case <-ctx.Done():
			slog.Info("interrupted before all events seen", "seen", len(seen), "expected", maxMessages)
			os.Exit(1)
		case <-ticker.C:
		}

		if time.Now().After(deadline) {
			fmt.Printf("DEADLINE_EXCEEDED: saw %d/%d events\n", len(seen), maxMessages)
			os.Exit(1)
		}

		keys, err := scanAll(ctx, rdb, "event:*")
		if err != nil {
			slog.Warn("scan failed", "err", err)
			continue
		}

		for _, key := range keys {
			idStr := strings.TrimPrefix(key, "event:")
			id, err := strconv.ParseInt(idStr, 10, 64)
			if err != nil {
				continue
			}
			if _, ok := seen[id]; ok {
				continue
			}

			getCtx, getCancel := context.WithTimeout(ctx, 2*time.Second)
			vals, err := rdb.HMGet(getCtx, key, "produced_at_ns", "observed_at_ns").Result()
			getCancel()
			if err != nil || len(vals) != 2 {
				continue
			}
			producedStr, ok := vals[0].(string)
			if !ok {
				continue
			}
			observedStr, ok := vals[1].(string)
			if !ok {
				continue
			}
			produced, err := strconv.ParseInt(producedStr, 10, 64)
			if err != nil {
				continue
			}
			observed, err := strconv.ParseInt(observedStr, 10, 64)
			if err != nil {
				continue
			}

			latency := observed - produced
			seen[id] = latency
			fmt.Printf("observed id=%d latency_ms=%.3f count=%d/%d\n",
				id, float64(latency)/1e6, len(seen), maxMessages)
		}
	}

	// Compute stats over all observed events.
	latencies := make([]int64, 0, len(seen))
	for _, l := range seen {
		latencies = append(latencies, l)
	}
	sort.Slice(latencies, func(i, j int) bool { return latencies[i] < latencies[j] })

	p := func(pct int) int64 {
		if len(latencies) == 0 {
			return 0
		}
		idx := pct * len(latencies) / 100
		if idx >= len(latencies) {
			idx = len(latencies) - 1
		}
		return latencies[idx]
	}

	fmt.Printf("\n=== LATENCY STATS ===\n")
	fmt.Printf("events_observed: %d\n", len(seen))
	fmt.Printf("min_ms: %.3f\n", float64(latencies[0])/1e6)
	fmt.Printf("p50_ms: %.3f\n", float64(p(50))/1e6)
	fmt.Printf("p99_ms: %.3f\n", float64(p(99))/1e6)
	fmt.Printf("max_ms: %.3f\n", float64(latencies[len(latencies)-1])/1e6)
}

func scanAll(ctx context.Context, rdb *redis.Client, pattern string) ([]string, error) {
	var keys []string
	var cursor uint64
	for {
		scanCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
		batch, next, err := rdb.Scan(scanCtx, cursor, pattern, 1000).Result()
		cancel()
		if err != nil {
			return nil, err
		}
		keys = append(keys, batch...)
		if next == 0 {
			break
		}
		cursor = next
	}
	return keys, nil
}

func connectRedis(ctx context.Context, addr string, attempts int, delay time.Duration) (*redis.Client, error) {
	for i := 0; i < attempts; i++ {
		rdb := redis.NewClient(&redis.Options{Addr: addr})
		pingCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
		err := rdb.Ping(pingCtx).Err()
		cancel()
		if err == nil {
			slog.Info("redis connected", "addr", addr, "attempt", i+1)
			return rdb, nil
		}
		_ = rdb.Close()
		slog.Warn("redis connect attempt failed", "addr", addr, "attempt", i+1, "err", err)
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(delay):
		}
	}
	return nil, fmt.Errorf("could not connect to redis %s after %d attempts", addr, attempts)
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func atoiOr(k string, def int) int {
	if v := os.Getenv(k); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}
