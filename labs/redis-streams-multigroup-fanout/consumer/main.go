package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/redis/go-redis/v9"
)

const readyFile = "/tmp/ready"

func main() {
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo})))

	addr := getenv("REDIS_ADDR", "redis:6379")
	stream := getenv("STREAM_NAME", "events")
	group := mustEnv("GROUP_NAME")
	consumer := mustEnv("CONSUMER_NAME")

	slog.Info("starting consumer", "addr", addr, "stream", stream, "group", group, "consumer", consumer)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	rdb, err := connectWithRetry(ctx, addr, 10, time.Second)
	if err != nil {
		slog.Error("could not connect to redis", "err", err)
		os.Exit(1)
	}
	defer rdb.Close()

	// Create the consumer group at end-of-stream. BUSYGROUP means it already
	// exists (e.g. on container restart) — that's fine.
	createCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	err = rdb.XGroupCreateMkStream(createCtx, stream, group, "$").Err()
	cancel()
	if err != nil && !strings.Contains(err.Error(), "BUSYGROUP") {
		slog.Error("XGROUP CREATE failed", "err", err)
		os.Exit(1)
	}
	slog.Info("group ready", "group", group)

	// Signal readiness to the compose healthcheck. The producer waits on
	// every consumer being healthy before it XADDs, ensuring no entries
	// are produced before a group exists to receive them.
	if err := os.WriteFile(readyFile, []byte("ok\n"), 0o644); err != nil {
		slog.Error("could not write ready file", "path", readyFile, "err", err)
		os.Exit(1)
	}

	for {
		if ctx.Err() != nil {
			slog.Info("shutdown signal received; exiting")
			return
		}
		readCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
		res, err := rdb.XReadGroup(readCtx, &redis.XReadGroupArgs{
			Group:    group,
			Consumer: consumer,
			Streams:  []string{stream, ">"},
			Count:    10,
			Block:    5 * time.Second,
		}).Result()
		cancel()

		if err != nil {
			if errors.Is(err, redis.Nil) || errors.Is(err, context.DeadlineExceeded) {
				// No new messages within block window; loop and try again.
				continue
			}
			if errors.Is(err, context.Canceled) {
				return
			}
			slog.Warn("XREADGROUP error", "err", err)
			time.Sleep(time.Second)
			continue
		}

		for _, s := range res {
			for _, m := range s.Messages {
				n := fmt.Sprintf("%v", m.Values["n"])
				fmt.Printf("received id=%s n=%s\n", m.ID, n)
				ackCtx, ackCancel := context.WithTimeout(ctx, 2*time.Second)
				if err := rdb.XAck(ackCtx, stream, group, m.ID).Err(); err != nil {
					slog.Warn("XACK failed", "id", m.ID, "err", err)
				}
				ackCancel()
			}
		}
	}
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

func mustEnv(k string) string {
	v := os.Getenv(k)
	if v == "" {
		fmt.Fprintf(os.Stderr, "FATAL: env var %s is required\n", k)
		os.Exit(1)
	}
	return v
}
