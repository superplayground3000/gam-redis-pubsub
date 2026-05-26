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

// PostRate calls POST /rate {rate: n, mode?: mode} on the writer.
// Empty mode omits the mode field, leaving the writer's current mode unchanged.
func PostRate(ctx context.Context, baseURL string, rate int, mode string) error {
	body := map[string]any{"rate": rate}
	if mode != "" {
		body["mode"] = mode
	}
	buf, _ := json.Marshal(body)
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, baseURL+"/rate", bytes.NewReader(buf))
	req.Header.Set("Content-Type", "application/json")
	resp, err := httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("POST /rate: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("POST /rate: status %d", resp.StatusCode)
	}
	return nil
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
