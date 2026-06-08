package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

// TestScrapeLWWSumsAcrossOpLabel proves ScrapeLWW accumulates every op-split
// series for a result (Phase 6 added an `op` label), rather than keeping only the
// last matching line, and that the OpenMetrics `_created` timestamp series is
// excluded.
func TestScrapeLWWSumsAcrossOpLabel(t *testing.T) {
	body := `# HELP lww_apply applied/stale/duplicate counter
# TYPE lww_apply counter
lww_apply{label="",op="delete",result="applied"} 149
lww_apply{label="",op="rename",result="applied"} 11151
lww_apply{label="",op="set",result="applied"} 1057
lww_apply{label="",op="set",result="stale"} 89368
lww_apply{label="",op="delete",result="stale"} 11150
lww_apply{label="",op="set",result="duplicate"} 42
lww_apply_created{label="",op="set",result="applied"} 1.717000000e+09
`
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/metrics" {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		_, _ = w.Write([]byte(body))
	}))
	defer srv.Close()

	applied, stale, duplicate, err := ScrapeLWW(context.Background(), srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	if applied != 12357 {
		t.Fatalf("applied=%d want 12357 (149+11151+1057)", applied)
	}
	if stale != 100518 {
		t.Fatalf("stale=%d want 100518 (89368+11150)", stale)
	}
	if duplicate != 42 {
		t.Fatalf("duplicate=%d want 42", duplicate)
	}
}
