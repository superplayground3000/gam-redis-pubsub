// client: from a single "region", measure per-shard XADD and XREVRANGE latency
// against each of the three streams (one stream per shard, pinned via hash tag).
//
// One client process per region. Each tick: write to all 3 streams, read most
// recent entry from all 3 streams, emit one JSON-Lines record per operation to
// /shared/measurements.jsonl and to stdout.
//
// We deliberately do NOT use go-redis's ClusterClient + CLUSTER SHARDS topology
// discovery. The lab pins one stream per shard via tags.json, so the client opens
// three direct connections (one per shard's announced hostname) and routes by
// known shard ownership. This isolates the demonstrated property — "stream
// access cost is RTT(client, owning shard)" — from any cluster client routing
// quirks.

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"sync"
	"syscall"
	"time"

	"github.com/redis/go-redis/v9"
)

type Tags struct {
	RedisA string `json:"redis-a"`
	RedisB string `json:"redis-b"`
	RedisC string `json:"redis-c"`
}

type Measurement struct {
	Ts          string  `json:"ts"`
	Region      string  `json:"region"`
	Op          string  `json:"op"`
	TargetShard string  `json:"target_shard"`
	Stream      string  `json:"stream"`
	LatencyMs   float64 `json:"latency_ms"`
	Seq         int     `json:"seq"`
	Err         string  `json:"err,omitempty"`
}

type shardTarget struct {
	name    string // "redis-a"
	addr    string // "redis-a.local:6001"
	stream  string // "stream:{t17}"
	client  *redis.Client
}

func main() {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)

	region := getenv("REGION", "a")
	sharedDir := getenv("SHARED_DIR", "/shared")
	intervalMs, _ := strconv.Atoi(getenv("MEASURE_INTERVAL_MS", "1000"))
	if intervalMs <= 0 {
		intervalMs = 1000
	}
	measurementsFile := filepath.Join(sharedDir, "measurements.jsonl")

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	if err := waitForFile(ctx, filepath.Join(sharedDir, "cluster-ready"), 120*time.Second); err != nil {
		logger.Error("waiting for cluster-ready", "err", err)
		os.Exit(1)
	}
	if err := waitForFile(ctx, filepath.Join(sharedDir, "proxies-ready"), 60*time.Second); err != nil {
		logger.Error("waiting for proxies-ready", "err", err)
		os.Exit(1)
	}

	tags, err := readTags(filepath.Join(sharedDir, "tags.json"))
	if err != nil {
		logger.Error("reading tags.json", "err", err)
		os.Exit(1)
	}
	logger.Info("loaded tags", "region", region, "redis-a", tags.RedisA, "redis-b", tags.RedisB, "redis-c", tags.RedisC)

	targets := []*shardTarget{
		{name: "redis-a", addr: "redis-a.local:6001", stream: fmt.Sprintf("stream:{%s}", tags.RedisA)},
		{name: "redis-b", addr: "redis-b.local:6002", stream: fmt.Sprintf("stream:{%s}", tags.RedisB)},
		{name: "redis-c", addr: "redis-c.local:6003", stream: fmt.Sprintf("stream:{%s}", tags.RedisC)},
	}

	for _, t := range targets {
		t.client = redis.NewClient(&redis.Options{
			Addr:         t.addr,
			DialTimeout:  10 * time.Second,
			ReadTimeout:  15 * time.Second,
			WriteTimeout: 15 * time.Second,
			MaxRetries:   0,
		})
	}
	defer func() {
		for _, t := range targets {
			_ = t.client.Close()
		}
	}()

	// Initial ping confirms the per-region toxiproxy + DNS aliasing works for each shard.
	for _, t := range targets {
		pingCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
		_, err := t.client.Ping(pingCtx).Result()
		cancel()
		if err != nil {
			logger.Error("initial ping failed", "shard", t.name, "addr", t.addr, "err", err)
			os.Exit(1)
		}
		logger.Info("connected", "shard", t.name, "addr", t.addr, "stream", t.stream)
	}

	f, err := os.OpenFile(measurementsFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		logger.Error("opening measurements file", "err", err)
		os.Exit(1)
	}
	defer f.Close()

	emitter := &lineEmitter{f: f}

	ticker := time.NewTicker(time.Duration(intervalMs) * time.Millisecond)
	defer ticker.Stop()

	seq := 0
	for {
		select {
		case <-ctx.Done():
			logger.Info("shutting down", "region", region)
			return
		case <-ticker.C:
			seq++
			runTick(ctx, region, seq, targets, emitter)
		}
	}
}

func runTick(ctx context.Context, region string, seq int, targets []*shardTarget, em *lineEmitter) {
	xadds := make(map[string]float64, len(targets))
	xreads := make(map[string]float64, len(targets))

	for _, t := range targets {
		// XADD
		opCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
		t0 := time.Now()
		_, addErr := t.client.XAdd(opCtx, &redis.XAddArgs{
			Stream: t.stream,
			Values: map[string]interface{}{
				"origin": region,
				"seq":    seq,
			},
		}).Result()
		addElapsed := time.Since(t0).Seconds() * 1000.0
		cancel()
		em.emit(Measurement{
			Ts:          t0.UTC().Format(time.RFC3339Nano),
			Region:      region,
			Op:          "XADD",
			TargetShard: t.name,
			Stream:      t.stream,
			LatencyMs:   addElapsed,
			Seq:         seq,
			Err:         errString(addErr),
		})
		xadds[t.name] = addElapsed

		// XREVRANGE  (read most recent entry; the "replay" probe)
		opCtx, cancel = context.WithTimeout(ctx, 30*time.Second)
		t0 = time.Now()
		_, readErr := t.client.XRevRangeN(opCtx, t.stream, "+", "-", 1).Result()
		readElapsed := time.Since(t0).Seconds() * 1000.0
		cancel()
		em.emit(Measurement{
			Ts:          t0.UTC().Format(time.RFC3339Nano),
			Region:      region,
			Op:          "XREVRANGE",
			TargetShard: t.name,
			Stream:      t.stream,
			LatencyMs:   readElapsed,
			Seq:         seq,
			Err:         errString(readErr),
		})
		xreads[t.name] = readElapsed
	}

	// Human-readable summary so `docker compose logs -f client-X` tells the story.
	fmt.Printf("region=%s tick=%d XADD: redis-a=%6.1fms redis-b=%6.1fms redis-c=%6.1fms\n",
		region, seq, xadds["redis-a"], xadds["redis-b"], xadds["redis-c"])
	fmt.Printf("region=%s tick=%d READ: redis-a=%6.1fms redis-b=%6.1fms redis-c=%6.1fms\n",
		region, seq, xreads["redis-a"], xreads["redis-b"], xreads["redis-c"])
}

// --- emitter ---

// lineEmitter serialises writes from this client. Concurrent writers (one per
// region) append to the same /shared/measurements.jsonl; with O_APPEND each
// write(2) is atomic for small payloads on Linux, but we still mutex to keep
// stdout in lockstep with the file.
type lineEmitter struct {
	mu sync.Mutex
	f  *os.File
}

func (l *lineEmitter) emit(m Measurement) {
	line, err := json.Marshal(m)
	if err != nil {
		slog.Error("marshalling measurement", "err", err)
		return
	}
	line = append(line, '\n')
	l.mu.Lock()
	defer l.mu.Unlock()
	if _, err := l.f.Write(line); err != nil {
		slog.Error("writing measurement", "err", err)
	}
}

// --- helpers ---

func waitForFile(ctx context.Context, path string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(path); err == nil {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(500 * time.Millisecond):
		}
	}
	return fmt.Errorf("timeout waiting for %s", path)
}

func readTags(path string) (Tags, error) {
	var t Tags
	data, err := os.ReadFile(path)
	if err != nil {
		return t, fmt.Errorf("read %s: %w", path, err)
	}
	if err := json.Unmarshal(data, &t); err != nil {
		return t, fmt.Errorf("parse %s: %w", path, err)
	}
	if t.RedisA == "" || t.RedisB == "" || t.RedisC == "" {
		return t, fmt.Errorf("tags.json missing one or more shards: %+v", t)
	}
	return t, nil
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func errString(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}
