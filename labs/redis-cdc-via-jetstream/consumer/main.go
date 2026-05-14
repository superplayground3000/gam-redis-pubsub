package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
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

	redisAddr := getenv("REDIS_ADDR", "redis-sink:6379")
	natsURL := getenv("NATS_URL", "nats://nats:4222")
	natsStreamName := getenv("NATS_STREAM", "EVENTS")
	subjectPrefix := getenv("NATS_SUBJECT_PREFIX", "events")
	durable := getenv("NATS_DURABLE", "bridge-consumer")

	slog.Info("starting consumer",
		"redis", redisAddr, "nats", natsURL,
		"nats_stream", natsStreamName, "durable", durable)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	rdb, err := connectRedis(ctx, redisAddr, 10, time.Second)
	if err != nil {
		slog.Error("redis connect failed", "err", err)
		os.Exit(1)
	}
	defer rdb.Close()

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

	// Stream may not exist yet — the provider creates it. Wait briefly.
	stream, err := waitForStream(ctx, js, natsStreamName, 30)
	if err != nil {
		slog.Error("stream not available", "err", err)
		os.Exit(1)
	}

	// Create or update durable consumer (idempotent).
	consCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	cons, err := stream.CreateOrUpdateConsumer(consCtx, jetstream.ConsumerConfig{
		Durable:       durable,
		AckPolicy:     jetstream.AckExplicitPolicy,
		FilterSubject: subjectPrefix + ".>",
		// Sane retry: redeliver after 5s if not acked.
		AckWait: 5 * time.Second,
	})
	cancel()
	if err != nil {
		slog.Error("create consumer failed", "err", err)
		os.Exit(1)
	}
	slog.Info("durable consumer ready", "name", durable)

	if err := os.WriteFile(readyFile, []byte("ok\n"), 0o644); err != nil {
		slog.Error("ready file write failed", "err", err)
		os.Exit(1)
	}
	slog.Info("consumer ready; pulling messages")

	iter, err := cons.Messages()
	if err != nil {
		slog.Error("messages iterator failed", "err", err)
		os.Exit(1)
	}
	// Stop the iterator when the root context is cancelled, so iter.Next() returns.
	go func() {
		<-ctx.Done()
		iter.Stop()
	}()

	for {
		msg, err := iter.Next()
		if err != nil {
			if errors.Is(err, jetstream.ErrMsgIteratorClosed) {
				slog.Info("iterator closed; exiting")
				return
			}
			slog.Warn("iter.Next failed", "err", err)
			return
		}

		var ev event
		if err := json.Unmarshal(msg.Data(), &ev); err != nil {
			slog.Warn("decode failed; terminating message", "err", err)
			_ = msg.Term()
			continue
		}

		observedAt := time.Now().UnixNano()
		key := fmt.Sprintf("event:%d", ev.ID)

		setCtx, setCancel := context.WithTimeout(ctx, 5*time.Second)
		if err := rdb.HSet(setCtx, key, map[string]any{
			"id":             ev.ID,
			"produced_at_ns": ev.ProducedAtNs,
			"observed_at_ns": observedAt,
			"payload":        ev.Payload,
		}).Err(); err != nil {
			setCancel()
			slog.Warn("HSET failed; NAKing", "key", key, "err", err)
			_ = msg.Nak()
			continue
		}
		setCancel()

		if err := msg.Ack(); err != nil {
			slog.Warn("nats ack failed", "key", key, "err", err)
		}

		fmt.Printf("synced id=%d key=%s observed_at_ns=%d\n", ev.ID, key, observedAt)
	}
}

func waitForStream(ctx context.Context, js jetstream.JetStream, name string, attempts int) (jetstream.Stream, error) {
	for i := 0; i < attempts; i++ {
		sCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
		s, err := js.Stream(sCtx, name)
		cancel()
		if err == nil {
			return s, nil
		}
		if !errors.Is(err, jetstream.ErrStreamNotFound) {
			return nil, fmt.Errorf("stream lookup: %w", err)
		}
		slog.Info("stream not yet present; waiting", "name", name, "attempt", i+1)
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(time.Second):
		}
	}
	return nil, fmt.Errorf("stream %q not present after %d attempts", name, attempts)
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
