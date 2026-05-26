package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// jszServer returns a test server that responds with the given consumer pending value.
func jszServer(t *testing.T, pending *atomic.Int64) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/jsz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{
		  "account_details": [{
		    "stream_detail": [{
		      "name": "APP_EVENTS",
		      "state": {"messages": 0, "bytes": 0},
		      "consumer_detail": [{"num_pending": ` + itoa(pending.Load()) + `}]
		    }]
		  }]
		}`))
	})
	return httptest.NewServer(mux)
}

func itoa(n int64) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	digits := ""
	for n > 0 {
		digits = string(rune('0'+(n%10))) + digits
		n /= 10
	}
	if neg {
		digits = "-" + digits
	}
	return digits
}

// fakeStreamClient is a test-only stand-in for *StreamClient.
// Implements the xlenReader interface that waitForPipelineQuiescence and
// readFinalRegionXLen (Task 8) require.
// mu guards lens, lags, and err so goroutines in tests can call setXLen/setLag
// concurrently with the polling loop calling XLen/GroupLag.
type fakeStreamClient struct {
	t    *testing.T
	mu   sync.Mutex
	lens map[string]int64
	lags map[string]int64 // keyed by "stream/group"
	err  error
}

func newFakeStreamClient(t *testing.T) *fakeStreamClient {
	return &fakeStreamClient{t: t, lens: map[string]int64{}, lags: map[string]int64{}}
}

func (f *fakeStreamClient) setXLen(stream string, n int64) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.lens[stream] = n
}
func (f *fakeStreamClient) setLag(stream, group string, n int64) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.lags[stream+"/"+group] = n
}
func (f *fakeStreamClient) setError(err error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.err = err
}

func (f *fakeStreamClient) XLen(ctx context.Context, key string) (int64, error) {
	if ctx.Err() != nil {
		return 0, ctx.Err()
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.err != nil {
		return 0, f.err
	}
	return f.lens[key], nil
}

func (f *fakeStreamClient) GroupLag(ctx context.Context, stream, group string) (int64, error) {
	if ctx.Err() != nil {
		return 0, ctx.Err()
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.err != nil {
		return 0, f.err
	}
	return f.lags[stream+"/"+group], nil
}

func TestWaitQuiescenceAloReturnsFalseWhenBothQueuesDrain(t *testing.T) {
	central := newFakeStreamClient(t)
	central.setLag("app.events", "propagator", 5)
	pending := &atomic.Int64{}
	pending.Store(3)
	srv := jszServer(t, pending)
	defer srv.Close()

	go func() {
		time.Sleep(400 * time.Millisecond)
		central.setLag("app.events", "propagator", 0)
		pending.Store(0)
	}()

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	timedOut := waitForPipelineQuiescence(ctx, central, srv.URL, "APP_EVENTS", 2*time.Second)
	if timedOut {
		t.Errorf("expected quiescence (timedOut=false), got true")
	}
}

func TestWaitQuiescenceAloReturnsTrueWhenSourceStuck(t *testing.T) {
	central := newFakeStreamClient(t)
	central.setLag("app.events", "propagator", 100)
	pending := &atomic.Int64{}
	pending.Store(0)
	srv := jszServer(t, pending)
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	timedOut := waitForPipelineQuiescence(ctx, central, srv.URL, "APP_EVENTS", 500*time.Millisecond)
	if !timedOut {
		t.Errorf("expected timeout, got quiescence")
	}
}

func TestWaitQuiescenceAloReturnsTrueWhenSinkStuck(t *testing.T) {
	central := newFakeStreamClient(t)
	central.setLag("app.events", "propagator", 0)
	pending := &atomic.Int64{}
	pending.Store(50)
	srv := jszServer(t, pending)
	defer srv.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	timedOut := waitForPipelineQuiescence(ctx, central, srv.URL, "APP_EVENTS", 500*time.Millisecond)
	if !timedOut {
		t.Errorf("expected timeout, got quiescence")
	}
}
