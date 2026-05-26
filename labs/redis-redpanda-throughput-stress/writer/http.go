package main

import (
	"encoding/json"
	"fmt"
	"net/http"
)

type Server struct {
	Lim         *Limiter
	Counters    *Counters
	Mode        *ModeStore
	MaxRate     int
	HealthCheck func() bool
}

type rateReq struct {
	Rate *int    `json:"rate,omitempty"`
	Mode *string `json:"mode,omitempty"`
}

type rateResp struct {
	Rate int    `json:"rate"`
	Mode string `json:"mode"`
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
	fmt.Fprintf(w, "# TYPE stress_writer_mode gauge\n")
	fmt.Fprintf(w, "stress_writer_mode{name=%q} 1\n", s.Mode.Name())
	for i, name := range [3]string{"employee", "role", "org"} {
		fmt.Fprintf(w, "# TYPE stress_writer_sent_by_pattern_total counter\n")
		fmt.Fprintf(w, "stress_writer_sent_by_pattern_total{pattern=%q} %d\n", name, s.Counters.SentByPattern[i].Load())
	}
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
	if rq.Rate != nil {
		if *rq.Rate < 0 || *rq.Rate > s.MaxRate {
			http.Error(w, fmt.Sprintf("rate %d out of range [0,%d]", *rq.Rate, s.MaxRate), http.StatusBadRequest)
			return
		}
		s.Lim.Set(*rq.Rate)
	}
	if rq.Mode != nil {
		if err := s.Mode.SetByName(*rq.Mode); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(rateResp{
		Rate: int(s.Lim.Current()),
		Mode: s.Mode.Name(),
	})
}

func (s *Server) reset(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST only", http.StatusMethodNotAllowed)
		return
	}
	s.Counters.Reset()
	fmt.Fprintln(w, "counters reset")
}
