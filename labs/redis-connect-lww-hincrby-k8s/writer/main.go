package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"log"
	mrand "math/rand"
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
	keySpaceSize := envInt("KEY_SPACE_SIZE", 32)
	payloadBytes := envInt("PAYLOAD_BYTES", 200)
	maxRate := envInt("MAX_RATE", 20_000)
	healthAddr := envStr("HEALTH_ADDR", ":8081")
	opWSet := envInt("OP_W_SET", 8)
	opWDelete := envInt("OP_W_DELETE", 1)
	opWRename := envInt("OP_W_RENAME", 1)

	rdb := redis.NewClient(&redis.Options{Addr: addr, PoolSize: workers * 2})
	defer rdb.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel() // safety net; explicit cancel() in shutdown handler is the live path

	lim := NewLimiter()
	lim.Set(initialRate)
	counters := &Counters{}

	// Workers draw ids from a SHARED [0, KeySpaceSize) space so they contend on the
	// same keys (multi-writer-same-key). Per-key version monotonicity is preserved by
	// the Redis HINCRBY minter, not by partitioning the keyspace — but we still want
	// at least as many keys as workers so contention is meaningful.
	if keySpaceSize < workers {
		log.Fatalf("KEY_SPACE_SIZE (%d) must be >= WORKERS (%d)", keySpaceSize, workers)
	}

	minter := NewMinter(rdb)
	epochHolder := &EpochHolder{}
	weights := OpWeights{Set: opWSet, Delete: opWDelete, Rename: opWRename}
	seed := time.Now().UnixNano()
	bootID := newBootID()

	var wg sync.WaitGroup
	for i := 0; i < workers; i++ {
		w := &Worker{
			ID: i, Workers: workers, RDB: rdb,
			StreamKey:     streamKey,
			StreamMaxLen:  int64(streamMaxLen),
			PipelineDepth: pipelineDepth,
			PayloadBytes:  payloadBytes,
			KeySpaceSize:  int64(keySpaceSize),
			Lim:           lim,
			Counters:      counters,
			Minter:        minter,
			// Each worker gets its own *rand.Rand to avoid sharing one across goroutines.
			Ops:         NewOpPicker(weights, mrand.New(mrand.NewSource(seed+int64(i)))),
			EpochHolder: epochHolder,
		}
		wg.Add(1)
		go func() { defer wg.Done(); w.Run(ctx) }()
	}

	srv := &Server{
		Lim: lim, Counters: counters, MaxRate: maxRate,
		Epoch: epochHolder, BootID: bootID,
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
		log.Printf("writer listening on %s (boot_id=%s)", healthAddr, bootID)
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

// newBootID returns a random 8-byte hex id, stable for the process lifetime.
func newBootID() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
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
