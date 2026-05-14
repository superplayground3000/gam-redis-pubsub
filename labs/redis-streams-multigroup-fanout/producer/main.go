package main

import (
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/redis/go-redis/v9"
)

func main() {
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo})))

	addr := getenv("REDIS_ADDR", "redis:6379")
	stream := getenv("STREAM_NAME", "events")
	maxMessages := atoiOr("MAX_MESSAGES", 10)
	intervalMs := atoiOr("INTERVAL_MS", 1000)

	slog.Info("starting producer", "addr", addr, "stream", stream, "max", maxMessages, "interval_ms", intervalMs)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	rdb, err := connectWithRetry(ctx, addr, 10, time.Second)
	if err != nil {
		slog.Error("could not connect to redis", "err", err)
		os.Exit(1)
	}
	defer rdb.Close()

	ticker := time.NewTicker(time.Duration(intervalMs) * time.Millisecond)
	defer ticker.Stop()

	for n := 1; n <= maxMessages; n++ {
		callCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
		id, err := rdb.XAdd(callCtx, &redis.XAddArgs{
			Stream: stream,
			Values: map[string]any{
				"n":  n,
				"ts": time.Now().Unix(),
			},
		}).Result()
		cancel()
		if err != nil {
			slog.Error("XADD failed", "n", n, "err", err)
			os.Exit(1)
		}
		fmt.Printf("produced n=%d id=%s\n", n, id)

		if n == maxMessages {
			break
		}
		select {
		case <-ctx.Done():
			slog.Info("interrupted; exiting early", "produced", n)
			return
		case <-ticker.C:
		}
	}

	slog.Info("done", "produced", maxMessages)
}

func connectWithRetry(ctx context.Context, addr string, attempts int, delay time.Duration) (*redis.Client, error) {
	for i := 0; i < attempts; i++ {
		rdb := redis.NewClient(&redis.Options{Addr: addr})
		pingCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
		err := rdb.Ping(pingCtx).Err()
		cancel()
		if err == nil {
			slog.Info("connected", "attempt", i+1)
			return rdb, nil
		}
		_ = rdb.Close()
		slog.Warn("connect attempt failed", "attempt", i+1, "err", err)
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(delay):
		}
	}
	return nil, fmt.Errorf("could not connect to %s after %d attempts", addr, attempts)
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
