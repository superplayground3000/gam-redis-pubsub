package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func newTestServer() *Server {
	return &Server{
		Lim: NewLimiter(), Counters: &Counters{}, MaxRate: 100000,
		Versions:    NewVersions(2),
		HealthCheck: func() bool { return true },
	}
}

func TestResetSetsEpochAndStateReportsIt(t *testing.T) {
	s := newTestServer()
	mux := http.NewServeMux()
	s.Register(mux)

	body := strings.NewReader(`{"epoch":"run-123"}`)
	req := httptest.NewRequest(http.MethodPost, "/reset", body)
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)
	if rr.Code != 200 {
		t.Fatalf("reset code=%d body=%s", rr.Code, rr.Body.String())
	}

	// Simulate a write so /state has content.
	s.Versions.Next(0, "lww:run-123:0")

	req = httptest.NewRequest(http.MethodGet, "/state", nil)
	rr = httptest.NewRecorder()
	mux.ServeHTTP(rr, req)
	if rr.Code != 200 {
		t.Fatalf("state code=%d", rr.Code)
	}
	var st State
	if err := json.Unmarshal(rr.Body.Bytes(), &st); err != nil {
		t.Fatalf("unmarshal: %v body=%s", err, rr.Body.String())
	}
	if st.Epoch != "run-123" {
		t.Errorf("epoch=%q", st.Epoch)
	}
	if st.BootID == "" {
		t.Error("boot_id empty")
	}
	if st.Keys["lww:run-123:0"] != 1 {
		t.Errorf("keys=%v", st.Keys)
	}
}

func TestResetRequiresEpoch(t *testing.T) {
	s := newTestServer()
	mux := http.NewServeMux()
	s.Register(mux)
	req := httptest.NewRequest(http.MethodPost, "/reset", strings.NewReader(`{}`))
	rr := httptest.NewRecorder()
	mux.ServeHTTP(rr, req)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("want 400 for missing epoch, got %d", rr.Code)
	}
}
