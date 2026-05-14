// relay-publish: the Streams→Vector sidecar. Vector's redis source cannot
// consume Redis Streams, so this program does XREADGROUP + POST to Vector's
// http_server source. Vector returns 200 only after the downstream NATS sink
// acks, so XACK is safe on a 200 response.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/redis/go-redis/v9"
)

const readyFile = "/tmp/ready"

type relayEvent struct {
	Pattern      string `json:"pattern"`
	ID           string `json:"id"`
	Key          string `json:"key"`
	Value        string `json:"value"`
	ProducedAtNs int64  `json:"produced_at_ns"`
	RedisID      string `json:"redis_id"`
}

func main() {
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo})))

	redisAddr := getenv("REDIS_ADDR", "central-redis:6379")
	stream := getenv("STREAM_NAME", "cdc:events")
	group := getenv("CONSUMER_GROUP", "cdc-bridge")
	consumer := getenv("CONSUMER_NAME", "relay-1")
	vectorURL := getenv("VECTOR_URL", "http://vector:9000/")
	batchCount := mustAtoi(getenv("BATCH_COUNT", "64"))
	blockMs := mustAtoi(getenv("BLOCK_MS", "5000"))

	slog.Info("relay-publish starting",
		"redis", redisAddr, "stream", stream, "group", group,
		"consumer", consumer, "vector", vectorURL,
		"batch", batchCount, "block_ms", blockMs)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	rdb, err := connectRedis(ctx, redisAddr, 30, time.Second)
	if err != nil {
		slog.Error("redis connect failed", "err", err)
		os.Exit(1)
	}
	defer rdb.Close()

	// Idempotent group bootstrap. MKSTREAM means we don't fight the producer
	// for who creates the stream first. "$" means we consume only new entries
	// arriving after this group was created — the producer's depends_on chain
	// guarantees the group exists before producer's first XADD.
	createCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	err = rdb.XGroupCreateMkStream(createCtx, stream, group, "$").Err()
	cancel()
	if err != nil && !strings.Contains(err.Error(), "BUSYGROUP") {
		slog.Error("XGROUP CREATE failed", "err", err)
		os.Exit(1)
	}
	slog.Info("consumer group ready", "stream", stream, "group", group)

	httpClient := &http.Client{Timeout: 30 * time.Second}

	// Wait for Vector to accept a probe POST before signalling ready. This
	// closes a small race where the http_server is bound but the sink ack
	// pipeline is still warming up.
	if err := waitVectorReady(ctx, httpClient, vectorURL, 30); err != nil {
		slog.Error("vector readiness probe failed", "err", err)
		os.Exit(1)
	}

	if err := os.WriteFile(readyFile, []byte("ok"), 0o644); err != nil {
		slog.Error("write ready file failed", "err", err)
		os.Exit(1)
	}
	slog.Info("ready, entering read loop")

	// Phase 1: drain any pending entries we already own (recovery on restart).
	drainPEL(ctx, rdb, httpClient, vectorURL, stream, group, consumer, batchCount)

	// Phase 2: live tail.
	delivered := 0
	for {
		if ctx.Err() != nil {
			slog.Info("shutdown")
			return
		}

		res, err := rdb.XReadGroup(ctx, &redis.XReadGroupArgs{
			Group:    group,
			Consumer: consumer,
			Streams:  []string{stream, ">"},
			Count:    int64(batchCount),
			Block:    time.Duration(blockMs) * time.Millisecond,
		}).Result()
		if err != nil {
			if errors.Is(err, redis.Nil) || errors.Is(err, context.Canceled) {
				continue
			}
			slog.Error("XREADGROUP error", "err", err)
			time.Sleep(time.Second)
			continue
		}

		for _, s := range res {
			for _, msg := range s.Messages {
				if !publishOne(ctx, httpClient, vectorURL, stream, msg) {
					// Don't XACK; the entry remains in our PEL. We'll see it
					// again on the next phase-1 drain or via a janitor.
					continue
				}
				if err := rdb.XAck(ctx, stream, group, msg.ID).Err(); err != nil {
					slog.Warn("XACK failed", "id", msg.ID, "err", err)
					continue
				}
				delivered++
			}
		}

		if delivered > 0 && delivered%50 == 0 {
			slog.Info("delivered", "count", delivered)
		}
	}
}

func drainPEL(ctx context.Context, rdb *redis.Client, http *http.Client, vectorURL, stream, group, consumer string, batch int) {
	for {
		if ctx.Err() != nil {
			return
		}
		res, err := rdb.XReadGroup(ctx, &redis.XReadGroupArgs{
			Group:    group,
			Consumer: consumer,
			Streams:  []string{stream, "0"},
			Count:    int64(batch),
		}).Result()
		if err != nil && !errors.Is(err, redis.Nil) {
			slog.Error("drain PEL failed", "err", err)
			return
		}
		if len(res) == 0 || len(res[0].Messages) == 0 {
			slog.Info("PEL drain complete")
			return
		}
		drained := 0
		for _, msg := range res[0].Messages {
			if publishOne(ctx, http, vectorURL, stream, msg) {
				rdb.XAck(ctx, stream, group, msg.ID)
				drained++
			}
		}
		slog.Info("PEL drained batch", "n", drained)
	}
}

func publishOne(ctx context.Context, c *http.Client, url, stream string, msg redis.XMessage) bool {
	ev := buildEvent(stream, msg)
	body, err := json.Marshal(ev)
	if err != nil {
		slog.Error("marshal failed", "id", msg.ID, "err", err)
		return false
	}
	body = append(body, '\n')

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		slog.Error("new request failed", "err", err)
		return false
	}
	req.Header.Set("Content-Type", "application/x-ndjson")

	resp, err := c.Do(req)
	if err != nil {
		slog.Warn("post failed", "id", msg.ID, "err", err)
		return false
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, resp.Body)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		slog.Warn("vector returned non-2xx", "id", msg.ID, "status", resp.StatusCode)
		return false
	}
	return true
}

func buildEvent(_ string, m redis.XMessage) relayEvent {
	get := func(k string) string {
		if v, ok := m.Values[k]; ok {
			if s, ok := v.(string); ok {
				return s
			}
		}
		return ""
	}
	producedAt, _ := strconv.ParseInt(get("produced_at_ns"), 10, 64)
	return relayEvent{
		Pattern:      get("pattern"),
		ID:           get("id"),
		Key:          get("key"),
		Value:        get("value"),
		ProducedAtNs: producedAt,
		RedisID:      m.ID,
	}
}

func waitVectorReady(ctx context.Context, c *http.Client, url string, attempts int) error {
	for i := 0; i < attempts; i++ {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		probe := relayEvent{Pattern: "__probe__", ID: "0", Key: "__probe__", Value: "{}", ProducedAtNs: time.Now().UnixNano(), RedisID: "0-0"}
		body, _ := json.Marshal(probe)
		body = append(body, '\n')
		req, _ := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
		req.Header.Set("Content-Type", "application/x-ndjson")
		resp, err := c.Do(req)
		if err == nil {
			io.Copy(io.Discard, resp.Body)
			resp.Body.Close()
			if resp.StatusCode == 200 {
				return nil
			}
		}
		slog.Info("waiting for vector", "attempt", i+1, "err", err)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Second):
		}
	}
	return fmt.Errorf("vector not ready after %d attempts", attempts)
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
