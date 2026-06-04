package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

var httpClient = &http.Client{Timeout: 2 * time.Second}

// scrapePromMetrics fetches a Prometheus text-format endpoint and returns
// a flat map of metric name -> first sample value seen. Histograms/summaries
// are NOT fully decoded — only the bare-name samples are kept.
func scrapePromMetrics(ctx context.Context, url string) (map[string]float64, error) {
	req, _ := http.NewRequestWithContext(ctx, "GET", url, nil)
	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("scrape %s: HTTP %d", url, resp.StatusCode)
	}
	return parseProm(resp.Body)
}

func parseProm(r io.Reader) (map[string]float64, error) {
	out := map[string]float64{}
	scn := bufio.NewScanner(r)
	for scn.Scan() {
		line := strings.TrimSpace(scn.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		name := fields[0]
		if i := strings.IndexByte(name, '{'); i >= 0 {
			name = name[:i]
		}
		v, err := strconv.ParseFloat(fields[1], 64)
		if err != nil {
			continue
		}
		// Sum across all label variants of the same bare metric name.
		// Redpanda Connect emits e.g. input_received{label="..."} per component;
		// we want the total, not the first one seen.
		out[name] += v
	}
	return out, scn.Err()
}

// PostRate calls POST /rate {rate: n} on the writer.
func PostRate(ctx context.Context, writerURL string, n int) error {
	body, _ := json.Marshal(map[string]int{"rate": n})
	req, _ := http.NewRequestWithContext(ctx, "POST", writerURL+"/rate", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	resp, err := httpClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		b, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("rate %d: %s: %s", n, resp.Status, b)
	}
	return nil
}

// decodeJSON decodes a JSON HTTP response body into v.
func decodeJSON(resp *http.Response, v any) error { return json.NewDecoder(resp.Body).Decode(v) }

// stringsReader wraps a string as an io.Reader (request body helper).
func stringsReader(s string) io.Reader { return strings.NewReader(s) }

// parseTrailingFloat returns the last whitespace-delimited token of a metric line as a float.
func parseTrailingFloat(line string) float64 {
	f := strings.Fields(line)
	if len(f) == 0 {
		return 0
	}
	v, _ := strconv.ParseFloat(f[len(f)-1], 64)
	return v
}

// ScrapeLWW fetches connect-sink /metrics and returns applied, stale, duplicate counters.
// Tolerates label order/spacing variations in the Prometheus text exposition.
func ScrapeLWW(ctx context.Context, sinkURL string) (applied, stale, duplicate int64, err error) {
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, sinkURL+"/metrics", nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0, 0, 0, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	for _, line := range strings.Split(string(body), "\n") {
		if !strings.HasPrefix(line, "lww_apply") {
			continue
		}
		val := parseTrailingFloat(line)
		switch {
		case strings.Contains(line, `result="applied"`):
			applied = int64(val)
		case strings.Contains(line, `result="stale"`):
			stale = int64(val)
		case strings.Contains(line, `result="duplicate"`):
			duplicate = int64(val)
		}
	}
	return applied, stale, duplicate, nil
}

// scrapeWriterSent reads the writer's total sent counter from /metrics.
func scrapeWriterSent(ctx context.Context, writerURL string) int64 {
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, writerURL+"/metrics", nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	for _, line := range strings.Split(string(body), "\n") {
		if strings.HasPrefix(line, "stress_writer_sent_total") {
			return int64(parseTrailingFloat(line))
		}
	}
	return 0
}

// PostReset zeros writer counters.
func PostReset(ctx context.Context, writerURL string) error {
	req, _ := http.NewRequestWithContext(ctx, "POST", writerURL+"/reset", nil)
	resp, err := httpClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("reset: %s", resp.Status)
	}
	return nil
}
