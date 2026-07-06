package latency

import (
	"io"
	"net/http/httptest"
	"strings"
	"testing"
)

func scrape(t *testing.T, m *MetricsServer) string {
	t.Helper()
	rec := httptest.NewRecorder()
	m.metrics(rec, httptest.NewRequest("GET", "/metrics", nil))
	b, err := io.ReadAll(rec.Result().Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	return string(b)
}

func TestMetricsEmptyUntilFirstReport(t *testing.T) {
	m := &MetricsServer{}
	if body := scrape(t, m); body != "" {
		t.Fatalf("expected no series before first report, got %q", body)
	}
}

func TestMetricsExposesPercentilesInSeconds(t *testing.T) {
	m := &MetricsServer{}
	m.Update(Report{
		Overall: OverallStats{
			Stats:           Stats{Count: 3, P50Ms: 250, P95Ms: 1500, P99Ms: 2000},
			DroppedNegative: 4,
		},
		ByOp: map[string]Stats{
			"create": {Count: 2, P50Ms: 100, P95Ms: 100, P99Ms: 100},
			"update": {Count: 1, P50Ms: 500, P95Ms: 500, P99Ms: 500},
		},
	})
	body := scrape(t, m)
	for _, want := range []string{
		`cdc_latency_seconds{op="overall",quantile="0.50"} 0.25`,
		`cdc_latency_seconds{op="overall",quantile="0.95"} 1.5`,
		`cdc_latency_seconds{op="create",quantile="0.50"} 0.1`,
		`cdc_latency_seconds{op="update",quantile="0.99"} 0.5`,
		`cdc_latency_samples{op="overall"} 3`,
		`cdc_latency_dropped_negative_total 4`,
		"# TYPE cdc_latency_seconds gauge",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("metrics output missing %q\n---\n%s", want, body)
		}
	}
}
