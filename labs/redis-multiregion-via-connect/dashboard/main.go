package main

import (
	"context"
	_ "embed"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/gorilla/websocket"
	"github.com/redis/go-redis/v9"
)

//go:embed static/index.html
var indexHTML []byte

type event struct {
	Type    string `json:"type"`
	Side    string `json:"side"`
	Key     string `json:"key"`
	Value   string `json:"value"`
	TSendMs int64  `json:"t_send_ms"`
	NowMs   int64  `json:"now_ms"`
	DeltaMs int64  `json:"delta_ms"`
}

type hub struct {
	mu      sync.Mutex
	clients map[*websocket.Conn]struct{}
}

func newHub() *hub { return &hub{clients: map[*websocket.Conn]struct{}{}} }

func (h *hub) add(c *websocket.Conn) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.clients[c] = struct{}{}
}

func (h *hub) remove(c *websocket.Conn) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if _, ok := h.clients[c]; ok {
		delete(h.clients, c)
		_ = c.Close()
	}
}

func (h *hub) broadcast(msg []byte) {
	h.mu.Lock()
	conns := make([]*websocket.Conn, 0, len(h.clients))
	for c := range h.clients {
		conns = append(conns, c)
	}
	h.mu.Unlock()
	for _, c := range conns {
		_ = c.SetWriteDeadline(time.Now().Add(2 * time.Second))
		if err := c.WriteMessage(websocket.TextMessage, msg); err != nil {
			h.remove(c)
		}
	}
}

func main() {
	centralAddr := getenv("CENTRAL_ADDR", "redis-central:6379")
	regionAddr := getenv("REGION_ADDR", "redis-region:6379")
	listen := getenv("LISTEN_ADDR", ":8080")

	central := redis.NewClient(&redis.Options{Addr: centralAddr})
	region := redis.NewClient(&redis.Options{Addr: regionAddr})

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	for _, c := range []*redis.Client{central, region} {
		for i := 0; i < 30; i++ {
			if err := c.Ping(ctx).Err(); err == nil {
				break
			}
			time.Sleep(time.Second)
		}
		if err := c.ConfigSet(ctx, "notify-keyspace-events", "KEA").Err(); err != nil {
			log.Printf("config set notify-keyspace-events failed (continuing): %v", err)
		}
	}

	h := newHub()
	go subscribeKeyspace(ctx, central, "central", h)
	go subscribeKeyspace(ctx, region, "region", h)

	upgrader := websocket.Upgrader{CheckOrigin: func(r *http.Request) bool { return true }}

	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write(indexHTML)
	})
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(200)
		_, _ = w.Write([]byte("ok"))
	})
	mux.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) {
		c, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		h.add(c)
		go func() {
			defer h.remove(c)
			for {
				if _, _, err := c.ReadMessage(); err != nil {
					return
				}
			}
		}()
	})

	srv := &http.Server{Addr: listen, Handler: mux}
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigs
		shutdownCtx, cancelShutdown := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancelShutdown()
		_ = srv.Shutdown(shutdownCtx)
		cancel()
	}()

	log.Printf("dashboard listening on %s", listen)
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
}

func subscribeKeyspace(ctx context.Context, c *redis.Client, side string, h *hub) {
	const prefix = "__keyspace@0__:"
	sub := c.PSubscribe(ctx, prefix+"lb:*")
	defer func() { _ = sub.Close() }()
	ch := sub.Channel()
	log.Printf("subscribed keyspace events side=%s", side)
	for {
		select {
		case <-ctx.Done():
			return
		case msg, ok := <-ch:
			if !ok {
				return
			}
			if msg.Payload != "set" {
				continue
			}
			if !strings.HasPrefix(msg.Channel, prefix) {
				continue
			}
			key := msg.Channel[len(prefix):]
			val, err := c.Get(ctx, key).Result()
			if err != nil {
				continue
			}
			var p struct {
				V       int    `json:"v"`
				TSendMs int64  `json:"t_send_ms"`
				EventID string `json:"event_id"`
			}
			_ = json.Unmarshal([]byte(val), &p)
			now := time.Now().UnixMilli()
			delta := now - p.TSendMs
			if delta < 0 {
				delta = 0
			}
			e := event{
				Type: "event", Side: side, Key: key, Value: val,
				TSendMs: p.TSendMs, NowMs: now, DeltaMs: delta,
			}
			b, _ := json.Marshal(e)
			h.broadcast(b)
		}
	}
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
