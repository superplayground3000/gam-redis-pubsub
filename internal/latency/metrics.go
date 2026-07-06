// Prometheus /metrics endpoint for the latency-calculator: exposes the latest
// report's percentiles as gauges so latency is scrapeable, not just file JSON.
// Hand-rolled text format (version 0.0.4) like writer/http.go — this module
// deliberately has no prometheus/client_golang dependency.
package latency

import (
	"fmt"
	"net/http"
	"sync"
)

// MetricsServer holds the most recent report and serves it as Prometheus text.
type MetricsServer struct {
	mu    sync.Mutex
	rep   Report
	ready bool
}

// Update swaps in the latest report (called once per report interval).
func (m *MetricsServer) Update(r Report) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.rep = r
	m.ready = true
}

func (m *MetricsServer) Register(mux *http.ServeMux) {
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprintln(w, "ok")
	})
	mux.HandleFunc("/metrics", m.metrics)
}

func (m *MetricsServer) metrics(w http.ResponseWriter, r *http.Request) {
	m.mu.Lock()
	defer m.mu.Unlock()
	w.Header().Set("Content-Type", "text/plain; version=0.0.4")
	if !m.ready {
		// No report yet: expose no series rather than misleading zeros.
		return
	}
	// Percentiles are gauges in seconds (Prometheus base unit); the JSON report
	// keeps milliseconds. The quantile label mirrors summary conventions.
	fmt.Fprintf(w, "# TYPE cdc_latency_seconds gauge\n")
	writeBucket := func(op string, s Stats) {
		fmt.Fprintf(w, "cdc_latency_seconds{op=%q,quantile=\"0.50\"} %g\n", op, float64(s.P50Ms)/1000)
		fmt.Fprintf(w, "cdc_latency_seconds{op=%q,quantile=\"0.95\"} %g\n", op, float64(s.P95Ms)/1000)
		fmt.Fprintf(w, "cdc_latency_seconds{op=%q,quantile=\"0.99\"} %g\n", op, float64(s.P99Ms)/1000)
	}
	writeBucket("overall", m.rep.Overall.Stats)
	writeBucket("create", m.rep.ByOp["create"])
	writeBucket("update", m.rep.ByOp["update"])

	fmt.Fprintf(w, "# TYPE cdc_latency_samples gauge\n")
	fmt.Fprintf(w, "cdc_latency_samples{op=\"overall\"} %d\n", m.rep.Overall.Count)
	fmt.Fprintf(w, "cdc_latency_samples{op=\"create\"} %d\n", m.rep.ByOp["create"].Count)
	fmt.Fprintf(w, "cdc_latency_samples{op=\"update\"} %d\n", m.rep.ByOp["update"].Count)

	fmt.Fprintf(w, "# TYPE cdc_latency_dropped_negative_total counter\n")
	fmt.Fprintf(w, "cdc_latency_dropped_negative_total %d\n", m.rep.Overall.DroppedNegative)
}
