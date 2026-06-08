// dashboard: a thin live view over the observer. It polls the observer's /timeline
// (latest per-pod consumed:<pod> snapshot + active-stream count) and /verdict (rolling
// single-active / overlap / gap status), plus the writer's /state for the run epoch,
// and pushes a combined "stats" message to the browser over a websocket. It is purely
// cosmetic — the proof is owned by the observer + scripts/verify-election.sh.
package main

import (
	"context"
	_ "embed"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"

	"github.com/gorilla/websocket"
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

func newHub() *hub             { return &hub{clients: map[*wsClient]struct{}{}} }
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
	observerURL := getenv("OBSERVER_URL", "http://lab-observer:8070")
	writerURL := getenv("WRITER_URL", "http://lab-writer:8081")
	listen := getenv("LISTEN_ADDR", ":8080")

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	h := newHub()
	var wg sync.WaitGroup
	wg.Add(1)
	go func() { defer wg.Done(); pollStats(ctx, observerURL, writerURL, h) }()

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

	log.Printf("dashboard listening on %s (observer=%s)", listen, observerURL)
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
	wg.Wait()
}

// pollStats pushes a combined live snapshot to the browser once a second.
func pollStats(ctx context.Context, observerURL, writerURL string, h *hub) {
	t := time.NewTicker(time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			perPod, active := latestSample(ctx, observerURL)
			sa, overlap, gap := scrapeVerdict(ctx, observerURL)
			b, _ := json.Marshal(map[string]any{
				"type":           "stats",
				"consumed":       perPod,
				"active_streams": active,
				"single_active":  sa,
				"overlap_pairs":  overlap,
				"gap_pairs":      gap,
				"epoch":          scrapeEpoch(ctx, writerURL),
				"ts_ms":          time.Now().UnixMilli(),
			})
			h.broadcast(b)
		}
	}
}

// latestSample returns the most recent observer sample's per-pod counters and the
// active-stream total. It asks only for the last ~3s of timeline to keep the payload small.
func latestSample(ctx context.Context, observerURL string) (map[string]int64, int) {
	since := time.Now().Add(-3 * time.Second).UnixMilli()
	body := httpGet(ctx, fmt.Sprintf("%s/timeline?since_unix_ms=%d", observerURL, since))
	var samples []struct {
		Consumed      map[string]int64 `json:"consumed"`
		ActiveStreams int              `json:"active_streams"`
	}
	if json.Unmarshal([]byte(body), &samples) != nil || len(samples) == 0 {
		return map[string]int64{}, 0
	}
	last := samples[len(samples)-1]
	if last.Consumed == nil {
		last.Consumed = map[string]int64{}
	}
	return last.Consumed, last.ActiveStreams
}

// scrapeVerdict reads the observer's rolling verdict over the last ~3s.
func scrapeVerdict(ctx context.Context, observerURL string) (singleActive bool, overlap, gap int) {
	since := time.Now().Add(-3 * time.Second).UnixMilli()
	body := httpGet(ctx, fmt.Sprintf("%s/verdict?since_unix_ms=%d", observerURL, since))
	var v struct {
		SingleActive bool `json:"single_active"`
		OverlapPairs int  `json:"overlap_pairs"`
		GapPairs     int  `json:"gap_pairs"`
	}
	_ = json.Unmarshal([]byte(body), &v)
	return v.SingleActive, v.OverlapPairs, v.GapPairs
}

func scrapeEpoch(ctx context.Context, writerURL string) string {
	body := httpGet(ctx, writerURL+"/state")
	var st struct {
		Epoch string `json:"epoch"`
	}
	_ = json.Unmarshal([]byte(body), &st)
	return st.Epoch
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
