// Streams REST client for Redpanda Connect streams mode.
// Content-Type confirmed working against hpdevelop/connect:4.92.0-claudefix in Task 0: application/x-yaml
package main

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	neturl "net/url"
	"strings"
	"time"
)

// renderPipeline substitutes the literal pod name for the __POD__ placeholder.
// We substitute in the controller (not via env interpolation) because the streams
// REST API does NOT expand environment variables in POSTed configs (research §3.5).
func renderPipeline(tmpl, podName string) string {
	return strings.ReplaceAll(tmpl, "__POD__", podName)
}

type streamsClient struct {
	base string // e.g. http://localhost:4195
	hc   *http.Client
}

func newStreamsClient(base string) *streamsClient {
	return &streamsClient{base: strings.TrimRight(base, "/"), hc: &http.Client{Timeout: 5 * time.Second}}
}

func (c *streamsClient) post(ctx context.Context, id, configYAML string) error {
	url := fmt.Sprintf("%s/streams/%s", c.base, neturl.PathEscape(id))
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewBufferString(configYAML))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/x-yaml")
	return c.do(req)
}

func (c *streamsClient) delete(ctx context.Context, id string) error {
	url := fmt.Sprintf("%s/streams/%s", c.base, neturl.PathEscape(id))
	req, err := http.NewRequestWithContext(ctx, http.MethodDelete, url, nil)
	if err != nil {
		return err
	}
	return c.do(req)
}

func (c *streamsClient) do(req *http.Request) error {
	resp, err := c.hc.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	// DELETE of a non-existent stream returns 404 — treat as already-absent (idempotent).
	if req.Method == http.MethodDelete && resp.StatusCode == http.StatusNotFound {
		return nil
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("%s %s -> %d: %s", req.Method, req.URL.Path, resp.StatusCode, string(body))
	}
	return nil
}

// retry runs fn up to n times with a fixed delay, returning the last error.
func retry(ctx context.Context, n int, delay time.Duration, fn func() error) error {
	var err error
	for i := 0; i < n; i++ {
		if err = fn(); err == nil {
			return nil
		}
		if i == n-1 {
			break
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(delay):
		}
	}
	return err
}
