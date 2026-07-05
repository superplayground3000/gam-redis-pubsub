// $LAB/dashboard/main.go
package dashboard

import (
	"context"
	_ "embed"
	"encoding/json"
	"io"
	"log"
	"net"
	"net/http"
	neturl "net/url"
	"os"
	"os/signal"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/gorilla/websocket"
	"github.com/redis/go-redis/v9"

	"redis-cdc-le-k8s/internal/rediscfg"
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

func Run(args []string) {
	centralAddr := getenv("CENTRAL_ADDR", "redis-central:6379")
	regionAddr := getenv("REGION_ADDR", "redis-region:6379")
	writerURL := getenv("WRITER_URL", "http://writer:8081")
	sinkURL := getenv("CONNECT_SINK_URL", "http://connect-sink:4195")
	listen := getenv("LISTEN_ADDR", ":8080")
	scanMatch := getenv("SCAN_MATCH", "lb:*")

	central := rediscfg.New(rediscfg.Options{Addr: centralAddr, Cluster: rediscfg.EnvBool("CENTRAL_CLUSTER")})
	region := rediscfg.New(rediscfg.Options{Addr: regionAddr, Cluster: rediscfg.EnvBool("REGION_CLUSTER")})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	for i := 0; i < 30; i++ {
		if region.Ping(ctx).Err() == nil && central.Ping(ctx).Err() == nil {
			break
		}
		time.Sleep(time.Second)
	}
	// Enable keyspace notifications on every region master — in cluster mode each
	// node must be configured (and later subscribed) independently.
	_ = rediscfg.ForEachMaster(ctx, region, func(ctx context.Context, shard *redis.Client) error {
		return shard.ConfigSet(ctx, "notify-keyspace-events", "KEA").Err()
	})

	h := newHub()
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); subscribeChanges(ctx, region, h) }()
	go func() { defer wg.Done(); pollLoop(ctx, central, region, writerURL, sinkURL, scanMatch, h) }()

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

	log.Printf("dashboard listening on %s (scan=%s)", listen, scanMatch)
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
	wg.Wait()
	_ = region.Close()
	_ = central.Close()
}

// subscribeChanges streams region key changes (set/del) to the browser. In
// cluster mode keyspace events fire only on the node owning each key, so it
// subscribes on every master; in single-node mode ForEachMaster runs the pump
// once against the one client (identical to the previous behavior).
func subscribeChanges(ctx context.Context, c redis.UniversalClient, h *hub) {
	_ = rediscfg.ForEachMaster(ctx, c, func(ctx context.Context, shard *redis.Client) error {
		// Start the pump and return immediately: a blocking read here would
		// prevent ForEachMaster from returning across the other masters.
		go pumpKeyevents(ctx, shard, h)
		return nil
	})
	// Preserve the prior contract that this call blocks until shutdown so the
	// caller's WaitGroup tracks the subscription's lifetime.
	<-ctx.Done()
}

// pumpKeyevents forwards one master's set/del keyspace events to the hub.
func pumpKeyevents(ctx context.Context, c *redis.Client, h *hub) {
	sub := c.PSubscribe(ctx, "__keyevent@0__:set", "__keyevent@0__:del")
	defer func() { _ = sub.Close() }()
	ch := sub.Channel()
	for {
		select {
		case <-ctx.Done():
			return
		case msg, ok := <-ch:
			if !ok {
				return
			}
			key := msg.Payload
			if !strings.HasPrefix(key, "lb:") {
				continue
			}
			op := "set"
			if strings.HasSuffix(msg.Channel, ":del") {
				op = "del"
			}
			val := ""
			if op == "set" {
				// In steady state the key lives on this master, so Get on the shard
				// client resolves without a redirect; during slot migration the key
				// may have moved and the Get can miss (value stays empty, tolerated).
				val, _ = c.Get(ctx, key).Result()
			}
			b, _ := json.Marshal(map[string]any{
				"type": "event", "op": op, "key": key, "value": val, "ts_ms": time.Now().UnixMilli(),
			})
			h.broadcast(b)
		}
	}
}

// serializeHash renders a hash as a canonical "k=v" string (fields sorted) so the
// central/region divergence comparison is order-independent and stable.
func serializeHash(m map[string]string) string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(m))
	for _, k := range keys {
		parts = append(parts, k+"="+m[k])
	}
	return "hash:{" + strings.Join(parts, ",") + "}"
}

// scanAll loads every key matching pattern and its string value into a map. In
// cluster mode SCAN only covers the connected node, so it scans every master and
// merges the results; in single-node mode ForEachMaster runs once. In steady
// state per-key GET on the owning shard resolves without a redirect (during slot
// migration a key may have moved and the GET can miss). Partial results are
// returned on error (graceful degradation, matching the previous behavior).
func scanAll(ctx context.Context, c redis.UniversalClient, match string) map[string]string {
	out := map[string]string{}
	var mu sync.Mutex
	_ = rediscfg.ForEachMaster(ctx, c, func(ctx context.Context, shard *redis.Client) error {
		var cursor uint64
		for {
			keys, cur, err := shard.Scan(ctx, cursor, match, 500).Result()
			if err != nil {
				return err
			}
			for _, k := range keys {
				typ, terr := shard.Type(ctx, k).Result()
				if terr != nil {
					continue // key vanished or moved mid-scan; tolerate
				}
				if typ == "hash" {
					if m, herr := shard.HGetAll(ctx, k).Result(); herr == nil && len(m) > 0 {
						mu.Lock()
						out[k] = serializeHash(m)
						mu.Unlock()
					}
					continue
				}
				if v, gerr := shard.Get(ctx, k).Result(); gerr == nil {
					mu.Lock()
					out[k] = v
					mu.Unlock()
				}
			}
			cursor = cur
			if cursor == 0 {
				break
			}
		}
		return nil
	})
	return out
}

func pollLoop(ctx context.Context, central, region redis.UniversalClient, writerURL, sinkURL, match string, h *hub) {
	t := time.NewTicker(time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			cmap := scanAll(ctx, central, match)
			rmap := scanAll(ctx, region, match)
			div := computeDivergence(cmap, rmap)
			ops := scrapeApply(ctx, sinkURL)
			epoch, writerOps := scrapeState(ctx, writerURL)
			b, _ := json.Marshal(map[string]any{
				"type": "stats", "divergence": div, "sink_apply": ops,
				"writer_ops": writerOps, "epoch": epoch,
			})
			h.broadcast(b)
		}
	}
}

// scrapeApply parses connect-sink /metrics for cdc_apply{op="..."} counters.
// With leader-election active/standby the sink runs N replicas behind a headless
// Service, but only the Lease holder runs the pipeline and increments cdc_apply;
// standbys expose no such series. We resolve every pod IP behind the Service host
// and sum across them, so the totals reflect the active leader no matter which
// pod DNS round-robin would have handed us.
func scrapeApply(ctx context.Context, sinkURL string) map[string]int64 {
	out := map[string]int64{"create": 0, "update": 0, "delete": 0, "rename": 0}
	for _, ep := range sinkEndpoints(sinkURL) {
		body := httpGet(ctx, ep+"/metrics")
		for _, ln := range strings.Split(body, "\n") {
			if !strings.HasPrefix(ln, "cdc_apply{") && !strings.HasPrefix(ln, "cdc_apply_total{") {
				continue
			}
			v := int64(trailingFloat(ln))
			for op := range out {
				if strings.Contains(ln, `op="`+op+`"`) {
					// Accumulate: Prometheus may expose the same op across multiple
					// series (e.g. differing `path` labels) and across multiple
					// pods; sum them rather than keeping only the last line.
					out[op] += v
				}
			}
		}
	}
	return out
}

// sinkEndpoints expands sinkURL into one base URL per backing pod IP. A headless
// Service resolves to all ready pod IPs; if resolution yields nothing usable
// (a single ClusterIP, an IP literal, or an external host) we fall back to the
// URL as given so non-headless / single-replica deployments work unchanged.
func sinkEndpoints(sinkURL string) []string {
	u, err := neturl.Parse(sinkURL)
	if err != nil || u.Host == "" {
		return []string{sinkURL}
	}
	host := u.Hostname()
	if net.ParseIP(host) != nil { // already an IP literal — nothing to expand
		return []string{sinkURL}
	}
	ips, err := net.LookupHost(host)
	if err != nil || len(ips) == 0 {
		return []string{sinkURL}
	}
	port := u.Port()
	out := make([]string, 0, len(ips))
	for _, ip := range ips {
		hostport := ip
		if port != "" {
			hostport = net.JoinHostPort(ip, port)
		}
		out = append(out, u.Scheme+"://"+hostport)
	}
	return out
}

func scrapeState(ctx context.Context, writerURL string) (string, map[string]int64) {
	body := httpGet(ctx, writerURL+"/state")
	var st struct {
		Epoch string           `json:"epoch"`
		Ops   map[string]int64 `json:"ops"`
	}
	_ = json.Unmarshal([]byte(body), &st)
	return st.Epoch, st.Ops
}

func httpGet(ctx context.Context, url string) string {
	// Bound each scrape: sinkEndpoints fans out to every sink pod IP, so an
	// unreachable/terminating pod must not stall the whole poll loop on the OS
	// TCP timeout. A short per-request deadline caps the worst case.
	ctx, cancel := context.WithTimeout(ctx, 4*time.Second)
	defer cancel()
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
