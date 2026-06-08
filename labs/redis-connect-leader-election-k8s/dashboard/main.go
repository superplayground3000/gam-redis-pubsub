package main

import (
	"context"
	_ "embed"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/gorilla/websocket"
	"github.com/redis/go-redis/v9"
)

//go:embed static/index.html
var indexHTML []byte

type wsClient struct {
	conn   *websocket.Conn
	writeM sync.Mutex
}

func (c *wsClient) write(b []byte) error {
	c.writeM.Lock()
	defer c.writeM.Unlock()
	_ = c.conn.SetWriteDeadline(time.Now().Add(2 * time.Second))
	return c.conn.WriteMessage(websocket.TextMessage, b)
}

type hub struct {
	mu      sync.Mutex
	clients map[*wsClient]struct{}
}

func newHub() *hub { return &hub{clients: map[*wsClient]struct{}{}} }
func (h *hub) add(c *wsClient) { h.mu.Lock(); h.clients[c] = struct{}{}; h.mu.Unlock() }
func (h *hub) remove(c *wsClient) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if _, ok := h.clients[c]; ok {
		delete(h.clients, c)
		_ = c.conn.Close()
	}
}
func (h *hub) broadcast(b []byte) {
	h.mu.Lock()
	cs := make([]*wsClient, 0, len(h.clients))
	for c := range h.clients {
		cs = append(cs, c)
	}
	h.mu.Unlock()
	for _, c := range cs {
		if err := c.write(b); err != nil {
			h.remove(c)
		}
	}
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

func main() {
	regionAddr := getenv("REGION_ADDR", "redis-region:6379")
	writerURL := getenv("WRITER_URL", "http://writer:8081")
	sinkURL := getenv("CONNECT_SINK_URL", "http://connect-sink:4195")
	listen := getenv("LISTEN_ADDR", ":8080")
	event := getenv("KEYSPACE_EVENT", "__keyevent@0__:hset")

	region := redis.NewClient(&redis.Options{Addr: regionAddr})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	for i := 0; i < 30; i++ {
		if region.Ping(ctx).Err() == nil {
			break
		}
		time.Sleep(time.Second)
	}
	if err := region.ConfigSet(ctx, "notify-keyspace-events", "KEA").Err(); err != nil {
		log.Printf("config set notify-keyspace-events failed (continuing): %v", err)
	}

	h := newHub()
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); subscribeApplied(ctx, region, event, h) }()
	go func() { defer wg.Done(); pollStats(ctx, writerURL, sinkURL, h) }()

	upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write(indexHTML)
	})
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(200); _, _ = w.Write([]byte("ok")) })
	mux.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) {
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		c := &wsClient{conn: conn}
		h.add(c)
		go func() {
			defer h.remove(c)
			for {
				if _, _, err := conn.ReadMessage(); err != nil {
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
		sc, cf := context.WithTimeout(context.Background(), 3*time.Second)
		defer cf()
		_ = srv.Shutdown(sc)
		cancel()
	}()

	log.Printf("dashboard listening on %s (event=%s)", listen, event)
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
	wg.Wait()
	_ = region.Close()
}

// subscribeApplied streams every applied write (key,ver,value) to the browser.
func subscribeApplied(ctx context.Context, c *redis.Client, event string, h *hub) {
	sub := c.PSubscribe(ctx, event)
	defer func() { _ = sub.Close() }()
	ch := sub.Channel()
	log.Printf("subscribed keyspace event=%s", event)
	for {
		select {
		case <-ctx.Done():
			return
		case msg, ok := <-ch:
			if !ok {
				return
			}
			key := msg.Payload // __keyevent@…__:hset payload is the key name
			if !strings.HasPrefix(key, "lww:") {
				continue
			}
			vals, err := c.HMGet(ctx, key, "ver", "val").Result()
			if err != nil || len(vals) < 2 {
				continue
			}
			ver, _ := toInt(vals[0])
			val, _ := vals[1].(string)
			b, _ := json.Marshal(map[string]any{
				"type": "event", "key": key, "ver": ver, "value": val,
				"ts_ms": time.Now().UnixMilli(),
			})
			h.broadcast(b)
		}
	}
}

// pollStats polls writer /state and sink /metrics once a second.
func pollStats(ctx context.Context, writerURL, sinkURL string, h *hub) {
	t := time.NewTicker(time.Second)
	defer t.Stop()
	var lastApplied int64
	var lastAt = time.Now()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			applied, stale, dup := scrapeLWW(ctx, sinkURL)
			sourceKeys, sourceEpoch := scrapeState(ctx, writerURL)
			dt := time.Since(lastAt).Seconds()
			perSec := 0.0
			if dt > 0 && applied >= lastApplied {
				perSec = float64(applied-lastApplied) / dt
			}
			lastApplied, lastAt = applied, time.Now()
			b, _ := json.Marshal(map[string]any{
				"type": "stats", "applied": applied, "stale": stale, "duplicate": dup,
				"applied_per_s": perSec, "source_keys": sourceKeys, "epoch": sourceEpoch,
			})
			h.broadcast(b)
		}
	}
}

// scrapeLWW parses the connect-sink /metrics exposition for the lww_apply
// counter. It matches ONLY the counter value series (`lww_apply{...}` or
// `lww_apply_total{...}`) and explicitly skips the OpenMetrics
// `lww_apply_created{...}` series (a unix-timestamp gauge), which neither
// prefix matches — mirroring the verifier's safe scrape.
func scrapeLWW(ctx context.Context, sinkURL string) (applied, stale, dup int64) {
	body := httpGet(ctx, sinkURL+"/metrics")
	for _, ln := range strings.Split(body, "\n") {
		// Value series only; excludes `lww_apply_created{...}`.
		if !strings.HasPrefix(ln, "lww_apply{") && !strings.HasPrefix(ln, "lww_apply_total{") {
			continue
		}
		v := trailingFloat(ln)
		switch {
		case strings.Contains(ln, `result="applied"`):
			applied = int64(v)
		case strings.Contains(ln, `result="stale"`):
			stale = int64(v)
		case strings.Contains(ln, `result="duplicate"`):
			dup = int64(v)
		}
	}
	return
}

func scrapeState(ctx context.Context, writerURL string) (int, string) {
	body := httpGet(ctx, writerURL+"/state")
	var st struct {
		DistinctKeys int    `json:"distinct_keys"`
		Epoch        string `json:"epoch"`
	}
	_ = json.Unmarshal([]byte(body), &st)
	return st.DistinctKeys, st.Epoch
}

func httpGet(ctx context.Context, url string) string {
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return string(b)
}

func trailingFloat(line string) float64 {
	f := strings.Fields(line)
	if len(f) == 0 {
		return 0
	}
	v, _ := strconv.ParseFloat(f[len(f)-1], 64)
	return v
}

func toInt(v any) (int64, bool) {
	s, ok := v.(string)
	if !ok {
		return 0, false
	}
	n, err := strconv.ParseInt(s, 10, 64)
	return n, err == nil
}
