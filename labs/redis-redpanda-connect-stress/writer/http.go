package main

import (
	"encoding/json"
	"fmt"
	"net/http"
)

type Server struct {
	Lim         *Limiter
	Counters    *Counters
	MaxRate     int
	HealthCheck func() bool
}

type rateReq struct {
	Rate int `json:"rate"`
}

func (s *Server) Register(mux *http.ServeMux) {
	mux.HandleFunc("/healthz", s.healthz)
	mux.HandleFunc("/metrics", s.metrics)
	mux.HandleFunc("/rate", s.rate)
	mux.HandleFunc("/reset", s.reset)
}

func (s *Server) healthz(w http.ResponseWriter, r *http.Request) {
	if s.HealthCheck() {
		w.WriteHeader(http.StatusOK)
		fmt.Fprintln(w, "ok")
		return
	}
	w.WriteHeader(http.StatusServiceUnavailable)
	fmt.Fprintln(w, "redis ping failed")
}

func (s *Server) metrics(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	fmt.Fprintf(w, "# TYPE stress_writer_sent_total counter\n")
	fmt.Fprintf(w, "stress_writer_sent_total %d\n", s.Counters.Sent.Load())
	fmt.Fprintf(w, "# TYPE stress_writer_errors_total counter\n")
	fmt.Fprintf(w, "stress_writer_errors_total %d\n", s.Counters.Errors.Load())
	fmt.Fprintf(w, "# TYPE stress_writer_rate_target gauge\n")
	fmt.Fprintf(w, "stress_writer_rate_target %d\n", s.Lim.Current())
	fmt.Fprintf(w, "# TYPE stress_writer_inflight_pipelines gauge\n")
	fmt.Fprintf(w, "stress_writer_inflight_pipelines %d\n", s.Counters.Inflight.Load())
}

func (s *Server) rate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	var rq rateReq
	if err := json.NewDecoder(r.Body).Decode(&rq); err != nil {
		http.Error(w, "bad json: "+err.Error(), http.StatusBadRequest)
		return
	}
	if rq.Rate < 0 || rq.Rate > s.MaxRate {
		http.Error(w, fmt.Sprintf("rate %d out of range [0,%d]", rq.Rate, s.MaxRate), http.StatusBadRequest)
		return
	}
	s.Lim.Set(rq.Rate)
	fmt.Fprintf(w, "rate set to %d\n", rq.Rate)
}

func (s *Server) reset(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	s.Counters.Reset()
	fmt.Fprintln(w, "counters reset")
}
