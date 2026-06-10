// $LAB/writer/main.go
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
	streamMaxLen := envInt("STREAM_MAXLEN", 100_000)
	workers := envInt("WORKERS", 8)
	pipelineDepth := envInt("PIPELINE_DEPTH", 50)
	initialRate := envInt("INITIAL_RATE", 0)
	keySpaceSize := envInt("KEY_SPACE_SIZE", 1000)
	payloadBytes := envInt("PAYLOAD_BYTES", 200)
	maxRate := envInt("MAX_RATE", 20_000)
	healthAddr := envStr("HEALTH_ADDR", ":8081")
	mix := OpMix{
		Create: envInt("OP_CREATE", 40),
		Update: envInt("OP_UPDATE", 40),
		Delete: envInt("OP_DELETE", 10),
		Rename: envInt("OP_RENAME", 10),
	}

	// Validate config before doing any work. A rename op needs at least two
	// distinct keys, and rand.Int63n(0) panics — so the key space must be >= 2.
	if keySpaceSize < 2 {
		log.Fatalf("KEY_SPACE_SIZE (%d) must be >= 2", keySpaceSize)
	}
	if !mix.Valid() {
		log.Fatalf("op-mix invalid: each of OP_CREATE/UPDATE/DELETE/RENAME must be >= 0 and their sum > 0 (got %+v)", mix)
	}

	rdb := redis.NewClient(&redis.Options{Addr: addr, PoolSize: workers * 2})
	defer rdb.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	lim := NewLimiter()
	lim.Set(initialRate)
	counters := &Counters{}
	state := NewRunState()

	var wg sync.WaitGroup
	for i := 0; i < workers; i++ {
		w := &Worker{
			ID: i, RDB: rdb, StreamKey: streamKey, StreamMaxLen: int64(streamMaxLen),
			PipelineDepth: pipelineDepth, PayloadBytes: payloadBytes, KeySpaceSize: int64(keySpaceSize),
			Mix: mix, Lim: lim, Counters: counters, State: state,
		}
		wg.Add(1)
		go func() { defer wg.Done(); w.Run(ctx) }()
	}

	srv := &Server{Lim: lim, Counters: counters, MaxRate: maxRate, State: state,
		HealthCheck: func() bool {
			c, cf := context.WithTimeout(context.Background(), 500*time.Millisecond)
			defer cf()
			return rdb.Ping(c).Err() == nil
		}}
	mux := http.NewServeMux()
	srv.Register(mux)
	httpSrv := &http.Server{Addr: healthAddr, Handler: mux}
	go func() {
		log.Printf("writer listening on %s", healthAddr)
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
		log.Printf("WARN: %s=%q not an int, using %d", k, v, def)
		return def
	}
	return n
}
