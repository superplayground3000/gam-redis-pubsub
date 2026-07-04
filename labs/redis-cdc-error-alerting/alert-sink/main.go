// alert-sink records alerts POSTed by Alertmanager and exposes them for the test
// script. GET /alerts returns the recorded firing alerts as JSON.
package main

import (
	"encoding/json"
	"log"
	"net/http"
	"sync"
)

type amAlert struct {
	Status string            `json:"status"`
	Labels map[string]string `json:"labels"`
}
type amPayload struct {
	Alerts []amAlert `json:"alerts"`
}

type store struct {
	mu   sync.Mutex
	seen []amAlert
}

func (s *store) add(a []amAlert) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.seen = append(s.seen, a...)
}
func (s *store) snapshot() []amAlert {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]amAlert, len(s.seen))
	copy(out, s.seen)
	return out
}

func main() {
	s := &store{}
	http.HandleFunc("/webhook", func(w http.ResponseWriter, r *http.Request) {
		var p amPayload
		if err := json.NewDecoder(r.Body).Decode(&p); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		s.add(p.Alerts)
		for _, a := range p.Alerts {
			log.Printf("alert %s status=%s reason=%s ns=%s job=%s",
				a.Labels["alertname"], a.Status, a.Labels["reason"], a.Labels["namespace"], a.Labels["job"])
		}
		w.WriteHeader(http.StatusNoContent)
	})
	http.HandleFunc("/alerts", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(s.snapshot())
	})
	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(200) })
	log.Println("alert-sink listening on :9099")
	log.Fatal(http.ListenAndServe(":9099", nil))
}
