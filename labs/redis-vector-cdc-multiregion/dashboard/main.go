// dashboard: serves /index.html (embedded), /api/state (snapshot of both
// Redis stores for the 9 tracked keys), and /api/events (Server-Sent Events
// stream from the region Redis Pub/Sub channel cdc:applied — emitted by
// relay-consume on every successful region apply).
package main

import (
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/redis/go-redis/v9"
)

//go:embed index.html
var indexHTML []byte

// keyDef mirrors the producer's key list; kept in sync manually.
type keyDef struct {
	Pattern string
	ID      string
	Key     string
}

var keys = []keyDef{
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

type keyState struct {
	Pattern     string `json:"pattern"`
	ID          string `json:"id"`
	Key         string `json:"key"`
	Central     string `json:"central"`
	Region      string `json:"region"`
	CentralOK   bool   `json:"central_present"`
	RegionOK    bool   `json:"region_present"`
	Match       bool   `json:"match"`
}

type stateResp struct {
	GeneratedAtNs int64      `json:"generated_at_ns"`
	Keys          []keyState `json:"keys"`
}

func main() {
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo})))

	centralAddr := getenv("CENTRAL_REDIS_ADDR", "central-redis:6379")
	regionAddr := getenv("REGION_REDIS_ADDR", "region-redis:6379")
	channel := getenv("APPLIED_CHANNEL", "cdc:applied")
	listenAddr := getenv("LISTEN_ADDR", ":8080")

	slog.Info("dashboard starting",
		"central", centralAddr, "region", regionAddr, "channel", channel, "listen", listenAddr)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	centralCli, err := connectRedis(ctx, centralAddr, 30, time.Second)
	if err != nil {
		slog.Error("central connect failed", "err", err)
		os.Exit(1)
	}
	defer centralCli.Close()

	regionCli, err := connectRedis(ctx, regionAddr, 30, time.Second)
	if err != nil {
		slog.Error("region connect failed", "err", err)
		os.Exit(1)
	}
	defer regionCli.Close()

	// Fan-out hub for SSE clients. We subscribe to region Redis Pub/Sub once
	// and broadcast every message to every connected browser. Each subscriber
	// has its own buffered channel; slow clients are dropped rather than
	// allowed to block the hub.
	hub := newHub()
	go hub.run(ctx, regionCli, channel)

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Write(indexHTML)
	})
	mux.HandleFunc("/api/state", func(w http.ResponseWriter, r *http.Request) {
		handleState(r.Context(), w, centralCli, regionCli)
	})
	mux.HandleFunc("/api/events", func(w http.ResponseWriter, r *http.Request) {
		handleEvents(r.Context(), w, hub)
	})

	srv := &http.Server{Addr: listenAddr, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	go func() {
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			slog.Error("listen failed", "err", err)
			os.Exit(1)
		}
	}()
	slog.Info("listening", "addr", listenAddr)

	<-ctx.Done()
	slog.Info("shutdown")
	shutCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutCtx)
}

func handleState(ctx context.Context, w http.ResponseWriter, central, region *redis.Client) {
	out := stateResp{GeneratedAtNs: time.Now().UnixNano(), Keys: make([]keyState, 0, len(keys))}

	for _, k := range keys {
		cCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
		cVal, cErr := central.Get(cCtx, k.Key).Result()
		cancel()
		rCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
		rVal, rErr := region.Get(rCtx, k.Key).Result()
		cancel()

		st := keyState{Pattern: k.Pattern, ID: k.ID, Key: k.Key}
		if cErr == nil {
			st.CentralOK = true
			st.Central = cVal
		}
		if rErr == nil {
			st.RegionOK = true
			st.Region = rVal
		}
		st.Match = st.CentralOK && st.RegionOK && st.Central == st.Region
		out.Keys = append(out.Keys, st)
	}

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	_ = json.NewEncoder(w).Encode(out)
}

func handleEvents(ctx context.Context, w http.ResponseWriter, hub *eventHub) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Connection", "keep-alive")
	flusher.Flush()

	sub := hub.subscribe()
	defer hub.unsubscribe(sub)

	// Heartbeat so reverse proxies don't kill an idle connection.
	hb := time.NewTicker(15 * time.Second)
	defer hb.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-hb.C:
			_, _ = fmt.Fprintf(w, ": heartbeat %d\n\n", time.Now().Unix())
			flusher.Flush()
		case msg, ok := <-sub:
			if !ok {
				return
			}
			_, _ = fmt.Fprintf(w, "data: %s\n\n", msg)
			flusher.Flush()
		}
	}
}

// eventHub fans pub/sub messages out to many SSE subscribers.
type eventHub struct {
	subscribe   func() chan string
	unsubscribe func(chan string)
	run         func(ctx context.Context, rdb *redis.Client, channel string)
}

func newHub() *eventHub {
	subs := map[chan string]struct{}{}
	addCh := make(chan chan string)
	delCh := make(chan chan string)
	bcast := make(chan string, 128)

	h := &eventHub{}
	h.subscribe = func() chan string {
		c := make(chan string, 64)
		addCh <- c
		return c
	}
	h.unsubscribe = func(c chan string) {
		delCh <- c
	}
	h.run = func(ctx context.Context, rdb *redis.Client, channel string) {
		// Start a Redis Pub/Sub subscriber; reconnect on error.
		go func() {
			for {
				if ctx.Err() != nil {
					return
				}
				ps := rdb.Subscribe(ctx, channel)
				ch := ps.Channel()
				slog.Info("subscribed to pub/sub", "channel", channel)
				for m := range ch {
					select {
					case bcast <- m.Payload:
					default:
						// hub backlog full — drop oldest
					}
				}
				_ = ps.Close()
				slog.Warn("pub/sub channel closed; reconnecting")
				time.Sleep(time.Second)
			}
		}()

		for {
			select {
			case <-ctx.Done():
				return
			case c := <-addCh:
				subs[c] = struct{}{}
				slog.Info("sse subscriber added", "n", len(subs))
			case c := <-delCh:
				if _, ok := subs[c]; ok {
					delete(subs, c)
					close(c)
				}
				slog.Info("sse subscriber removed", "n", len(subs))
			case msg := <-bcast:
				for c := range subs {
					select {
					case c <- msg:
					default:
						// slow subscriber — drop this message for it
					}
				}
			}
		}
	}
	return h
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
