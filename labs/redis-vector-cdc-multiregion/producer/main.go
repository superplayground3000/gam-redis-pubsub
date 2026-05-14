// Producer: periodically updates 9 KVs (3 patterns × 3 ids) on the central
// Redis, writing each change atomically into both the KV slot AND the
// cdc:events stream so the bridge cannot see one without the other.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/redis/go-redis/v9"
)

const readyFile = "/tmp/first-tick"

// keySpec describes one of the 9 keys the producer maintains.
type keySpec struct {
	Pattern string // "employees" | "groups" | "items"
	ID      string // numeric id as string
	Key     string // full Redis key
}

// keys preserves the key shapes from lab-requirement.md verbatim, including
// the "funtions" spelling for pattern 2.
var keys = []keySpec{
	{"employees", "55688", "lb:company:employees:id:55688"},
	{"employees", "55689", "lb:company:employees:id:55689"},
	{"employees", "55690", "lb:company:employees:id:55690"},
	{"groups", "89889", "lb:funtions:groups:id:89889"},
	{"groups", "89890", "lb:funtions:groups:id:89890"},
	{"groups", "89891", "lb:funtions:groups:id:89891"},
	{"items", "9123", "lb:general:items:id:9123"},
	{"items", "9124", "lb:general:items:id:9124"},
	{"items", "9125", "lb:general:items:id:9125"},
}

type kvValue struct {
	Counter      int64  `json:"counter"`
	UpdatedAtNs  int64  `json:"updated_at_ns"`
	ProducerHost string `json:"producer_host"`
}

func main() {
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo})))

	redisAddr := getenv("REDIS_ADDR", "central-redis:6379")
	streamName := getenv("STREAM_NAME", "cdc:events")
	intervalMs := mustAtoi(getenv("EMIT_INTERVAL_MS", "1000"))
	maxTicks := mustAtoi(getenv("MAX_TICKS", "0"))

	host, _ := os.Hostname()
	slog.Info("producer starting",
		"redis", redisAddr, "stream", streamName,
		"interval_ms", intervalMs, "max_ticks", maxTicks, "keys", len(keys))

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	rdb, err := connectRedis(ctx, redisAddr, 30, time.Second)
	if err != nil {
		slog.Error("redis connect failed", "err", err)
		os.Exit(1)
	}
	defer rdb.Close()

	counters := make(map[string]int64, len(keys))

	tickInterval := time.Duration(intervalMs) * time.Millisecond
	ticker := time.NewTicker(tickInterval)
	defer ticker.Stop()

	tickCount := 0
	for {
		select {
		case <-ctx.Done():
			slog.Info("shutdown")
			return
		case <-ticker.C:
		}

		for _, k := range keys {
			counters[k.Key]++
			val := kvValue{
				Counter:      counters[k.Key],
				UpdatedAtNs:  time.Now().UnixNano(),
				ProducerHost: host,
			}
			valBytes, _ := json.Marshal(val)
			valStr := string(valBytes)

			// MULTI/EXEC: SET + XADD atomically. Either both succeed or both fail.
			pipe := rdb.TxPipeline()
			pipe.Set(ctx, k.Key, valStr, 0)
			pipe.XAdd(ctx, &redis.XAddArgs{
				Stream: streamName,
				MaxLen: 10000,
				Approx: true,
				Values: map[string]interface{}{
					"pattern":         k.Pattern,
					"id":              k.ID,
					"key":             k.Key,
					"value":           valStr,
					"produced_at_ns":  strconv.FormatInt(val.UpdatedAtNs, 10),
				},
			})
			if _, err := pipe.Exec(ctx); err != nil {
				slog.Error("set+xadd failed", "key", k.Key, "err", err)
				continue
			}
		}

		tickCount++
		if tickCount == 1 {
			// Signal compose healthcheck that the first tick has emitted.
			_ = os.WriteFile(readyFile, []byte("ok"), 0o644)
			slog.Info("first tick emitted", "keys", len(keys))
		}
		if tickCount%30 == 0 {
			slog.Info("ticks emitted", "n", tickCount)
		}

		if maxTicks > 0 && tickCount >= maxTicks {
			slog.Info("max ticks reached, exiting", "ticks", tickCount)
			return
		}
	}
}

func connectRedis(ctx context.Context, addr string, attempts int, delay time.Duration) (*redis.Client, error) {
	rdb := redis.NewClient(&redis.Options{Addr: addr})
	for i := 0; i < attempts; i++ {
		pingCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
		err := rdb.Ping(pingCtx).Err()
		cancel()
		if err == nil {
			return rdb, nil
		}
		slog.Info("redis ping failed, retrying", "addr", addr, "attempt", i+1, "err", err)
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(delay):
		}
	}
	return nil, errors.New("redis ping retries exhausted")
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func mustAtoi(s string) int {
	n, err := strconv.Atoi(s)
	if err != nil {
		panic(fmt.Errorf("not an int: %q: %w", s, err))
	}
	return n
}
