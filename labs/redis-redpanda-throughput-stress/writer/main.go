package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"sync"
	"syscall"
	"time"

	"github.com/redis/go-redis/v9"
)

func main() {
	addr := envStr("REDIS_ADDR", "redis-central:6379")
	streamKey := envStr("STREAM_KEY", "app.events")
	streamMaxLen := envInt("STREAM_MAXLEN", 2_000_000)
	workers := envInt("WORKERS", 16)
	batchMax := envInt("BATCH_MAX", 500)
	initialRate := envInt("INITIAL_RATE", 0)
	cardinality := envInt("PATTERN_CARDINALITY", 20_000)
	payloadBytes := envInt("PAYLOAD_BYTES", 1024)
	maxRate := envInt("MAX_RATE", 60_000)
	healthAddr := envStr("HEALTH_ADDR", ":8081")
	initialMode := envStr("INITIAL_MODE", "batch")
	weightsStr := envStr("PATTERN_WEIGHTS", "33,33,34")
	keySeed := int64(envInt("KEY_SEED", 42))

	weights, err := ParsePatternWeights(weightsStr)
	if err != nil {
		log.Fatalf("PATTERN_WEIGHTS: %v", err)
	}
	picker, err := NewPicker(weights)
	if err != nil {
		log.Fatalf("NewPicker: %v", err)
	}
	keyGen := NewKeyGen(KeyGenConfig{Cardinality: cardinality, Seed: keySeed})

	rdb := redis.NewClient(&redis.Options{Addr: addr, PoolSize: workers * 2})
	defer rdb.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	lim := NewLimiter()
	lim.Set(initialRate)
	mode := NewModeStore(initialMode)
	counters := &Counters{}

	var wg sync.WaitGroup
	for i := 0; i < workers; i++ {
		w := &Worker{
			ID: i, RDB: rdb,
			StreamKey:    streamKey,
			StreamMaxLen: int64(streamMaxLen),
			BatchMax:     batchMax,
			PayloadBytes: payloadBytes,
			Cardinality:  cardinality,
			Lim:          lim,
			Counters:     counters,
			Mode:         mode,
			KeyGen:       keyGen,
			Picker:       picker,
		}
		wg.Add(1)
		go func() { defer wg.Done(); w.Run(ctx) }()
	}

	srv := &Server{
		Lim: lim, Counters: counters, Mode: mode, MaxRate: maxRate,
		HealthCheck: func() bool {
			c, cf := context.WithTimeout(context.Background(), 500*time.Millisecond)
			defer cf()
			return rdb.Ping(c).Err() == nil
		},
	}
	mux := http.NewServeMux()
	srv.Register(mux)

	httpSrv := &http.Server{Addr: healthAddr, Handler: mux}
	go func() {
		log.Printf("writer listening on %s (initial mode=%s)", healthAddr, mode.Name())
		if err := httpSrv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("http server: %v", err)
		}
	}()

	sigC := make(chan os.Signal, 1)
	signal.Notify(sigC, syscall.SIGINT, syscall.SIGTERM)
	<-sigC
	log.Println("shutdown: draining")
	lim.Set(0)
	httpSrv.Shutdown(context.Background())
	cancel()
	wg.Wait()
}

func envStr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func envInt(k string, def int) int {
	v := os.Getenv(k)
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		log.Printf("WARN: %s=%q is not a valid int, using default %d", k, v, def)
		return def
	}
	return n
}
