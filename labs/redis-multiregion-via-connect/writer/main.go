package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/google/uuid"
	"github.com/redis/go-redis/v9"
)

type keyDef struct {
	Pattern string
	Key     string
}

var keys = []keyDef{
	{"company", "lb:company:employees:id:55688"},
	{"company", "lb:company:employees:id:55689"},
	{"company", "lb:company:employees:id:55690"},
	{"functions", "lb:functions:groups:id:89889"},
	{"functions", "lb:functions:groups:id:89890"},
	{"functions", "lb:functions:groups:id:89891"},
	{"general", "lb:general:items:id:9123"},
	{"general", "lb:general:items:id:9124"},
	{"general", "lb:general:items:id:9125"},
}

type valuePayload struct {
	V       int    `json:"v"`
	EventID string `json:"event_id"`
	TSendMs int64  `json:"t_send_ms"`
}

func main() {
	addr := getenv("REDIS_ADDR", "redis-central:6379")
	streamKey := getenv("STREAM_KEY", "app.events")
	intervalMs, err := strconv.Atoi(getenv("WRITE_INTERVAL_MS", "1000"))
	if err != nil || intervalMs <= 0 {
		log.Fatalf("invalid WRITE_INTERVAL_MS")
	}
	healthAddr := getenv("HEALTH_ADDR", ":8081")

	rdb := redis.NewClient(&redis.Options{Addr: addr})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	for i := 0; i < 30; i++ {
		if err := rdb.Ping(ctx).Err(); err == nil {
			break
		}
		time.Sleep(time.Second)
	}

	var ready atomic.Bool
	ready.Store(true)

	go func() {
		mux := http.NewServeMux()
		mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
			if ready.Load() {
				w.WriteHeader(200)
				_, _ = w.Write([]byte("ok"))
				return
			}
			w.WriteHeader(500)
		})
		log.Printf("health listening on %s", healthAddr)
		if err := http.ListenAndServe(healthAddr, mux); err != nil {
			log.Printf("health server stopped: %v", err)
		}
	}()

	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)
	go func() { <-sigs; cancel() }()

	rng := rand.New(rand.NewSource(time.Now().UnixNano()))
	tick := time.NewTicker(time.Duration(intervalMs) * time.Millisecond)
	defer tick.Stop()

	log.Printf("writer started: addr=%s stream=%s interval=%dms keys=%d", addr, streamKey, intervalMs, len(keys))

	idx := 0
	for {
		select {
		case <-ctx.Done():
			ready.Store(false)
			log.Printf("shutting down")
			return
		case <-tick.C:
			k := keys[idx%len(keys)]
			idx++
			evID := uuid.NewString()
			nowMs := time.Now().UnixMilli()
			payload := valuePayload{V: rng.Intn(1_000_000), EventID: evID, TSendMs: nowMs}
			body, _ := json.Marshal(payload)

			pipe := rdb.TxPipeline()
			pipe.Set(ctx, k.Key, string(body), 0)
			pipe.XAdd(ctx, &redis.XAddArgs{
				Stream: streamKey,
				Values: map[string]interface{}{
					"event_id":  evID,
					"key":       k.Key,
					"value":     string(body),
					"pattern":   k.Pattern,
					"t_send_ms": fmt.Sprintf("%d", nowMs),
				},
			})
			if _, err := pipe.Exec(ctx); err != nil {
				log.Printf("write error key=%s err=%v", k.Key, err)
				continue
			}
			log.Printf("wrote key=%s pattern=%s event_id=%s t_send_ms=%d", k.Key, k.Pattern, evID, nowMs)
		}
	}
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
