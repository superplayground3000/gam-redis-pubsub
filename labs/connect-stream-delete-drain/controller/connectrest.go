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

type connectClient struct {
	base string
	hc   *http.Client
}

func newConnectClient(base string) *connectClient {
	return &connectClient{base: strings.TrimRight(base, "/"), hc: &http.Client{Timeout: 5 * time.Second}}
}

func (c *connectClient) PostStream(ctx context.Context, id, configYAML string) error {
	u := fmt.Sprintf("%s/streams/%s", c.base, neturl.PathEscape(id))
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u, bytes.NewBufferString(configYAML))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/x-yaml")
	return c.do(req)
}

func (c *connectClient) DeleteStream(ctx context.Context, id string) error {
	u := fmt.Sprintf("%s/streams/%s", c.base, neturl.PathEscape(id))
	req, err := http.NewRequestWithContext(ctx, http.MethodDelete, u, nil)
	if err != nil {
		return err
	}
	return c.do(req)
}

func (c *connectClient) Ready(ctx context.Context) bool {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.base+"/ready", nil)
	if err != nil {
		return false
	}
	resp, err := c.hc.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return resp.StatusCode == http.StatusOK
}

func (c *connectClient) do(req *http.Request) error {
	resp, err := c.hc.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(resp.Body)
	if req.Method == http.MethodDelete && resp.StatusCode == http.StatusNotFound {
		return nil // idempotent: already absent
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("%s %s -> %d: %s", req.Method, req.URL.Path, resp.StatusCode, string(body))
	}
	return nil
}
