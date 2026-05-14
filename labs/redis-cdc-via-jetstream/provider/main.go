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
	"strings"
	"syscall"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
	"github.com/redis/go-redis/v9"
)

const readyFile = "/tmp/ready"

type event struct {
	ID           int64  `json:"id"`
	ProducedAtNs int64  `json:"produced_at_ns"`
	Payload      string `json:"payload"`
}

func main() {
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo})))

	redisAddr := getenv("REDIS_ADDR", "redis-source:6379")
	natsURL := getenv("NATS_URL", "nats://nats:4222")
	stream := getenv("STREAM_NAME", "events")
	group := getenv("SOURCE_GROUP", "bridge")
	subjectPrefix := getenv("NATS_SUBJECT_PREFIX", "events")
	natsStreamName := getenv("NATS_STREAM", "EVENTS")
	consumerName := getenv("PROVIDER_CONSUMER", "provider-1")

	slog.Info("starting provider",
		"redis", redisAddr, "nats", natsURL, "stream", stream, "group", group,
		"nats_stream", natsStreamName, "subject_prefix", subjectPrefix)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	rdb, err := connectRedis(ctx, redisAddr, 10, time.Second)
	if err != nil {
		slog.Error("redis connect failed", "err", err)
		os.Exit(1)
	}
	defer rdb.Close()

	// Source-side: create consumer group at end-of-stream (idempotent).
	createCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	err = rdb.XGroupCreateMkStream(createCtx, stream, group, "$").Err()
	cancel()
	if err != nil && !strings.Contains(err.Error(), "BUSYGROUP") {
		slog.Error("XGROUP CREATE failed", "err", err)
		os.Exit(1)
	}
	slog.Info("source group ready", "stream", stream, "group", group)

	// NATS connect.
	nc, err := connectNATS(ctx, natsURL, 10, time.Second)
	if err != nil {
		slog.Error("nats connect failed", "err", err)
		os.Exit(1)
	}
	defer nc.Close()

	js, err := jetstream.New(nc)
	if err != nil {
		slog.Error("jetstream context failed", "err", err)
		os.Exit(1)
	}

	// Create JetStream stream (idempotent — tolerate "already in use").
	streamCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	_, err = js.CreateStream(streamCtx, jetstream.StreamConfig{
		Name:     natsStreamName,
		Subjects: []string{subjectPrefix + ".>"},
		Storage:  jetstream.FileStorage,
	})
	cancel()
	if err != nil && !errors.Is(err, jetstream.ErrStreamNameAlreadyInUse) {
		slog.Error("create JS stream failed", "err", err)
		os.Exit(1)
	}
	slog.Info("nats stream ready", "name", natsStreamName)

	// Signal readiness — bridge is wired.
	if err := os.WriteFile(readyFile, []byte("ok\n"), 0o644); err != nil {
		slog.Error("ready file write failed", "err", err)
		os.Exit(1)
	}
	slog.Info("bridge ready; forwarding from redis stream to nats")

	for {
		if ctx.Err() != nil {
			slog.Info("shutdown signal received; exiting")
			return
		}
		readCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
		res, err := rdb.XReadGroup(readCtx, &redis.XReadGroupArgs{
			Group:    group,
			Consumer: consumerName,
			Streams:  []string{stream, ">"},
			Count:    10,
			Block:    5 * time.Second,
		}).Result()
		cancel()

		if err != nil {
			if errors.Is(err, redis.Nil) || errors.Is(err, context.DeadlineExceeded) {
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
				ev, err := parseEvent(m)
				if err != nil {
					slog.Warn("parse event failed; skipping", "stream_id", m.ID, "err", err)
					// Still ack so we don't loop forever on a poison message.
					_ = rdb.XAck(ctx, stream, group, m.ID).Err()
					continue
				}

				subject := fmt.Sprintf("%s.%d", subjectPrefix, ev.ID)
				body, _ := json.Marshal(ev)

				pubCtx, pubCancel := context.WithTimeout(ctx, 5*time.Second)
				_, err = js.Publish(pubCtx, subject, body)
				pubCancel()
				if err != nil {
					slog.Warn("nats publish failed; will retry via redis", "id", ev.ID, "err", err)
					// Do not XACK: redis will redeliver on next XREADGROUP cycle.
					continue
				}

				ackCtx, ackCancel := context.WithTimeout(ctx, 2*time.Second)
				if err := rdb.XAck(ackCtx, stream, group, m.ID).Err(); err != nil {
					slog.Warn("XACK failed", "stream_id", m.ID, "err", err)
				}
				ackCancel()

				fmt.Printf("forwarded stream_id=%s event_id=%d subject=%s\n", m.ID, ev.ID, subject)
			}
		}
	}
}

func parseEvent(m redis.XMessage) (event, error) {
	idStr, ok := m.Values["id"].(string)
	if !ok {
		return event{}, fmt.Errorf("missing id field")
	}
	id, err := strconv.ParseInt(idStr, 10, 64)
	if err != nil {
		return event{}, fmt.Errorf("id parse: %w", err)
	}
	tsStr, ok := m.Values["produced_at_ns"].(string)
	if !ok {
		return event{}, fmt.Errorf("missing produced_at_ns field")
	}
	ts, err := strconv.ParseInt(tsStr, 10, 64)
	if err != nil {
		return event{}, fmt.Errorf("produced_at_ns parse: %w", err)
	}
	payload, _ := m.Values["payload"].(string)
	return event{ID: id, ProducedAtNs: ts, Payload: payload}, nil
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

func connectNATS(ctx context.Context, url string, attempts int, delay time.Duration) (*nats.Conn, error) {
	for i := 0; i < attempts; i++ {
		nc, err := nats.Connect(url,
			nats.Timeout(2*time.Second),
			nats.MaxReconnects(-1),
			nats.ReconnectWait(time.Second),
		)
		if err == nil {
			slog.Info("nats connected", "url", url, "attempt", i+1)
			return nc, nil
		}
		slog.Warn("nats connect attempt failed", "url", url, "attempt", i+1, "err", err)
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(delay):
		}
	}
	return nil, fmt.Errorf("could not connect to nats %s after %d attempts", url, attempts)
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
