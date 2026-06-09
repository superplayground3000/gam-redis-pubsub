// observer: samples per-pod consumed:* counters (from redis-central) and each connect
// pod's /streams count (via the headless service) every interval, keeps a ring buffer,
// and serves /timeline + /verdict + /healthz. No K8s API/RBAC needed (uses DNS).
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strconv"
	"sync"
	"time"

	"github.com/redis/go-redis/v9"
)

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

type ring struct {
	mu      sync.RWMutex
	samples []Sample
	max     int
}

func (r *ring) add(s Sample) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.samples = append(r.samples, s)
	if len(r.samples) > r.max {
		r.samples = r.samples[len(r.samples)-r.max:]
	}
}

// since returns samples at/after t (copy).
func (r *ring) since(t time.Time) []Sample {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := []Sample{}
	for _, s := range r.samples {
		if !s.T.Before(t) {
			out = append(out, s)
		}
	}
	return out
}

func main() {
	var (
		redisAddr          = env("REDIS_ADDR", "lab-redis-central:6379")
		connectHost        = env("CONNECT_HEADLESS", "lab-connect-headless")
		connectPort        = env("CONNECT_PORT", "4195")
		listen             = env("LISTEN_ADDR", ":8070")
		intervalMs, _      = strconv.Atoi(env("SAMPLE_INTERVAL_MS", "100"))
		requireStreamCount = env("REQUIRE_STREAM_COUNT", "true") == "true"
	)
	if intervalMs <= 0 {
		intervalMs = 100
	}
	rdb := redis.NewClient(&redis.Options{Addr: redisAddr})
	hc := &http.Client{Timeout: 1 * time.Second}
	rb := &ring{max: 36000} // ~1h at 100ms

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	go func() {
		tick := time.NewTicker(time.Duration(intervalMs) * time.Millisecond)
		defer tick.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-tick.C:
				// Drop invalid samples (Redis/DNS error) rather than feed corrupt
				// data — a counter mis-read as 0 would fabricate false overlap/gap
				// verdicts. The verdict math only ever sees complete snapshots.
				if s, ok := sampleOnce(ctx, rdb, hc, connectHost, connectPort); ok {
					rb.add(s)
				}
			}
		}
	}()

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(200) })
	mux.HandleFunc("/timeline", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, rb.since(parseSince(r)))
	})
	mux.HandleFunc("/verdict", func(w http.ResponseWriter, r *http.Request) {
		series := rb.since(parseSince(r))
		writeJSON(w, map[string]any{
			"samples":       len(series),
			"single_active": SingleActive(series, requireStreamCount),
			"overlap_pairs": OverlapPairs(series),
			"gap_pairs":     GapPairs(series),
		})
	})
	fmt.Printf("observer sampling every %dms; serving %s\n", intervalMs, listen)
	if err := http.ListenAndServe(listen, mux); err != nil {
		fmt.Printf("server: %v\n", err)
		os.Exit(1)
	}
}

// sampleOnce reads all consumed:* counters and sums active streams across pods.
// It returns ok=false if the snapshot is incomplete (Redis SCAN/GET error, or the
// headless DNS lookup failed) so the caller can discard it: feeding a partial map or
// a transiently-zero counter into the verdict math would manufacture false
// overlap/gap windows. A per-pod /streams failure is NOT a sample error — a pod that
// is down genuinely has zero active streams.
func sampleOnce(ctx context.Context, rdb *redis.Client, hc *http.Client, host, port string) (Sample, bool) {
	c, cancel := context.WithTimeout(ctx, 800*time.Millisecond)
	defer cancel()
	consumed := map[string]int64{}
	var cursor uint64
	for {
		keys, cur, err := rdb.Scan(c, cursor, "consumed:*", 200).Result()
		if err != nil {
			return Sample{}, false
		}
		for _, k := range keys {
			v, err := rdb.Get(c, k).Int64()
			if err != nil {
				return Sample{}, false
			}
			consumed[k[len("consumed:"):]] = v
		}
		cursor = cur
		if cursor == 0 {
			break
		}
	}
	ips, err := net.LookupHost(host)
	if err != nil {
		return Sample{}, false
	}
	active := 0
	for _, ip := range ips {
		active += streamCount(hc, ip, port)
	}
	return Sample{T: time.Now(), Consumed: consumed, ActiveStreams: active}, true
}

// streamCount GETs /streams on one pod and returns the number of streams (0 or 1 here).
func streamCount(hc *http.Client, ip, port string) int {
	resp, err := hc.Get(fmt.Sprintf("http://%s:%s/streams", ip, port))
	if err != nil {
		return 0
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return 0 // non-200 (error body) must not have its JSON keys counted as streams
	}
	body, _ := io.ReadAll(resp.Body)
	var m map[string]any
	if json.Unmarshal(body, &m) != nil {
		return 0
	}
	return len(m)
}

func parseSince(r *http.Request) time.Time {
	if v := r.URL.Query().Get("since_unix_ms"); v != "" {
		if ms, err := strconv.ParseInt(v, 10, 64); err == nil {
			return time.UnixMilli(ms)
		}
	}
	return time.Time{} // zero -> everything
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(v)
}
