// relay-consume: pulls events from JetStream subject cdc.>, applies them
// to the region Redis via SET, and PUBLISHes a propagation-event record on
// channel cdc:applied so the dashboard can stream live arrivals to browsers.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
	"github.com/redis/go-redis/v9"
)

const readyFile = "/tmp/ready"

type pipelineEvent struct {
	Pattern      string `json:"pattern"`
	ID           string `json:"id"`
	Key          string `json:"key"`
	Value        string `json:"value"`
	ProducedAtNs int64  `json:"produced_at_ns"`
	RedisID      string `json:"redis_id"`
}

type appliedEvent struct {
	Pattern      string `json:"pattern"`
	ID           string `json:"id"`
	Key          string `json:"key"`
	Value        string `json:"value"`
	ProducedAtNs int64  `json:"produced_at_ns"`
	AppliedAtNs  int64  `json:"applied_at_ns"`
	DelayMs      int64  `json:"delay_ms"`
	RedisID      string `json:"redis_id"`
	Subject      string `json:"subject"`
}

func main() {
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo})))

	redisAddr := getenv("REDIS_ADDR", "region-redis:6379")
	natsURL := getenv("NATS_URL", "nats://nats:4222")
	natsStream := getenv("NATS_STREAM", "REGION_CDC")
	subjectFilter := getenv("NATS_SUBJECT_FILTER", "cdc.>")
	durable := getenv("NATS_DURABLE", "region-applier")
	appliedCh := getenv("APPLIED_CHANNEL", "cdc:applied")

	slog.Info("relay-consume starting",
		"redis", redisAddr, "nats", natsURL, "stream", natsStream,
		"filter", subjectFilter, "durable", durable, "applied", appliedCh)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	rdb, err := connectRedis(ctx, redisAddr, 30, time.Second)
	if err != nil {
		slog.Error("redis connect failed", "err", err)
		os.Exit(1)
	}
	defer rdb.Close()

	nc, err := connectNATS(ctx, natsURL, 30, time.Second)
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

	// Idempotent stream creation. Vector publishes to cdc.<pattern>.<id> and
	// expects the stream to exist (jetstream sinks fail on missing stream).
	streamCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	_, err = js.CreateOrUpdateStream(streamCtx, jetstream.StreamConfig{
		Name:      natsStream,
		Subjects:  []string{subjectFilter},
		Retention: jetstream.LimitsPolicy,
		Storage:   jetstream.FileStorage,
		MaxAge:    1 * time.Hour,
	})
	cancel()
	if err != nil {
		slog.Error("create JS stream failed", "err", err)
		os.Exit(1)
	}
	slog.Info("jetstream ready", "stream", natsStream, "subjects", subjectFilter)

	consCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	cons, err := js.CreateOrUpdateConsumer(consCtx, natsStream, jetstream.ConsumerConfig{
		Durable:       durable,
		FilterSubject: subjectFilter,
		AckPolicy:     jetstream.AckExplicitPolicy,
		AckWait:       30 * time.Second,
		MaxDeliver:    -1,
		DeliverPolicy: jetstream.DeliverAllPolicy,
	})
	cancel()
	if err != nil {
		slog.Error("create JS consumer failed", "err", err)
		os.Exit(1)
	}
	slog.Info("jetstream consumer ready", "durable", durable)

	if err := os.WriteFile(readyFile, []byte("ok"), 0o644); err != nil {
		slog.Error("write ready file failed", "err", err)
		os.Exit(1)
	}

	delivered := 0
	cc, err := cons.Consume(func(msg jetstream.Msg) {
		applyMessage(ctx, rdb, msg, appliedCh, &delivered)
	})
	if err != nil {
		slog.Error("consume failed", "err", err)
		os.Exit(1)
	}
	defer cc.Stop()

	<-ctx.Done()
	slog.Info("shutdown", "delivered", delivered)
}

func applyMessage(ctx context.Context, rdb *redis.Client, msg jetstream.Msg, appliedCh string, delivered *int) {
	subject := msg.Subject()

	// The probe POST from relay-publish gets stamped into the stream as
	// cdc.__probe__.0 once Vector forwards it. Drop those silently — they
	// pollute neither the region KV nor the dashboard.
	if strings.HasPrefix(subject, "cdc.__probe__.") {
		_ = msg.Ack()
		return
	}

	var ev pipelineEvent
	if err := json.Unmarshal(msg.Data(), &ev); err != nil {
		slog.Warn("bad event payload, terming", "subject", subject, "err", err)
		_ = msg.Term()
		return
	}
	if ev.Key == "" || ev.Value == "" {
		slog.Warn("missing key/value, terming", "subject", subject)
		_ = msg.Term()
		return
	}

	// Apply: SET key value (no TTL, no NX — overwrite by design).
	setCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
	if err := rdb.Set(setCtx, ev.Key, ev.Value, 0).Err(); err != nil {
		cancel()
		slog.Warn("region SET failed; nak for retry", "key", ev.Key, "err", err)
		_ = msg.NakWithDelay(time.Second)
		return
	}
	cancel()

	applied := appliedEvent{
		Pattern:      ev.Pattern,
		ID:           ev.ID,
		Key:          ev.Key,
		Value:        ev.Value,
		ProducedAtNs: ev.ProducedAtNs,
		AppliedAtNs:  time.Now().UnixNano(),
		RedisID:      ev.RedisID,
		Subject:      subject,
	}
	if applied.ProducedAtNs > 0 {
		applied.DelayMs = (applied.AppliedAtNs - applied.ProducedAtNs) / int64(time.Millisecond)
	}

	body, _ := json.Marshal(applied)

	pubCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	if err := rdb.Publish(pubCtx, appliedCh, string(body)).Err(); err != nil {
		slog.Warn("publish applied event failed (continuing)", "err", err)
	}
	cancel()

	if err := msg.Ack(); err != nil {
		slog.Warn("jetstream ack failed", "err", err)
		return
	}

	*delivered++
	if *delivered <= 5 || *delivered%50 == 0 {
		slog.Info("applied", "n", *delivered, "subject", subject, "delay_ms", applied.DelayMs)
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

func connectNATS(ctx context.Context, url string, attempts int, delay time.Duration) (*nats.Conn, error) {
	var lastErr error
	for i := 0; i < attempts; i++ {
		nc, err := nats.Connect(url,
			nats.Name("relay-consume"),
			nats.Timeout(5*time.Second),
			nats.ReconnectWait(2*time.Second),
			nats.MaxReconnects(-1),
		)
		if err == nil {
			return nc, nil
		}
		lastErr = err
		slog.Info("nats connect failed, retrying", "url", url, "attempt", i+1, "err", err)
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(delay):
		}
	}
	return nil, fmt.Errorf("nats connect retries exhausted: %w", lastErr)
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
