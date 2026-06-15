// $LAB/writer/http_test.go
package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func newTestServer() *Server {
	return &Server{Lim: NewLimiter(), Counters: &Counters{}, MaxRate: 20000, State: NewRunState(), HealthCheck: func() bool { return true }}
}

func TestResetThenState(t *testing.T) {
	s := newTestServer()
	mux := http.NewServeMux()
	s.Register(mux)

	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, httptest.NewRequest("POST", "/reset", strings.NewReader(`{"epoch":"e1"}`)))
	if rr.Code != 200 {
		t.Fatalf("reset code = %d", rr.Code)
	}
	rr = httptest.NewRecorder()
	mux.ServeHTTP(rr, httptest.NewRequest("GET", "/state", nil))
	var st StateSnapshot
	if err := json.Unmarshal(rr.Body.Bytes(), &st); err != nil {
		t.Fatalf("state json: %v", err)
	}
	if st.Epoch != "e1" {
		t.Fatalf("epoch = %q", st.Epoch)
	}
}

func TestMetricsHasPerOpSeries(t *testing.T) {
	s := newTestServer()
	s.Counters.Created.Store(5)
	mux := http.NewServeMux()
	s.Register(mux)
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, httptest.NewRequest("GET", "/metrics", nil))
	if !strings.Contains(rr.Body.String(), `cdc_writer_ops_total{op="create"} 5`) {
		t.Fatalf("metrics missing per-op series:\n%s", rr.Body.String())
	}
}
