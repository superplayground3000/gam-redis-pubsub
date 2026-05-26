package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func newTestServer() (*Server, *ModeStore) {
	mode := NewModeStore("batch")
	return &Server{
		Lim:         NewLimiter(),
		Counters:    &Counters{},
		Mode:        mode,
		MaxRate:     60000,
		HealthCheck: func() bool { return true },
	}, mode
}

func doRate(t *testing.T, s *Server, body string) (int, map[string]any) {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/rate", bytes.NewBufferString(body))
	rr := httptest.NewRecorder()
	mux := http.NewServeMux()
	s.Register(mux)
	mux.ServeHTTP(rr, req)
	var out map[string]any
	_ = json.Unmarshal(rr.Body.Bytes(), &out)
	return rr.Code, out
}

func TestRate_SetsBoth(t *testing.T) {
	s, mode := newTestServer()
	code, out := doRate(t, s, `{"rate": 10000, "mode": "single"}`)
	if code != http.StatusOK {
		t.Fatalf("status = %d, body=%v", code, out)
	}
	if mode.Get() != ModeSingle {
		t.Fatalf("mode = %v, want ModeSingle", mode.Get())
	}
	if s.Lim.Current() != 10000 {
		t.Fatalf("rate = %d, want 10000", s.Lim.Current())
	}
	if out["mode"] != "single" || int(out["rate"].(float64)) != 10000 {
		t.Fatalf("echo body = %v", out)
	}
}

func TestRate_OmittedFieldsKeepCurrent(t *testing.T) {
	s, mode := newTestServer()
	s.Lim.Set(5000)
	_ = mode.SetByName("batch")

	// Only rate, no mode.
	code, _ := doRate(t, s, `{"rate": 7000}`)
	if code != http.StatusOK {
		t.Fatalf("status = %d", code)
	}
	if mode.Get() != ModeBatch {
		t.Fatal("mode mutated when omitted")
	}
	if s.Lim.Current() != 7000 {
		t.Fatalf("rate = %d, want 7000", s.Lim.Current())
	}

	// Only mode, no rate.
	code, _ = doRate(t, s, `{"mode": "single"}`)
	if code != http.StatusOK {
		t.Fatalf("status = %d", code)
	}
	if mode.Get() != ModeSingle {
		t.Fatal("mode unchanged when set")
	}
	if s.Lim.Current() != 7000 {
		t.Fatalf("rate mutated to %d when omitted", s.Lim.Current())
	}
}

func TestRate_RejectsInvalidMode(t *testing.T) {
	s, _ := newTestServer()
	code, _ := doRate(t, s, `{"mode": "yolo"}`)
	if code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", code)
	}
}

func TestRate_RejectsOutOfRangeRate(t *testing.T) {
	s, _ := newTestServer()
	code, _ := doRate(t, s, `{"rate": 999999}`)
	if code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", code)
	}
}

func TestRate_InvalidModeDoesNotMutateRate(t *testing.T) {
	s, _ := newTestServer()
	s.Lim.Set(5000) // baseline
	code, _ := doRate(t, s, `{"rate": 9999, "mode": "yolo"}`)
	if code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", code)
	}
	if s.Lim.Current() != 5000 {
		t.Fatalf("rate mutated to %d despite mode validation failure, want 5000", s.Lim.Current())
	}
}
