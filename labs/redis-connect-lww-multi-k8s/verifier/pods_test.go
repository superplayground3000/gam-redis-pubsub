package main

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// sinkStub serves a connect /metrics endpoint with the given lww counters.
func sinkStub(applied, stale, duplicate int64) *httptest.Server {
	body := fmt.Sprintf(
		"# HELP lww_apply\n# TYPE lww_apply counter\n"+
			"lww_apply{result=\"applied\"} %d\n"+
			"lww_apply{result=\"stale\"} %d\n"+
			"lww_apply{result=\"duplicate\"} %d\n",
		applied, stale, duplicate)
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/metrics") {
			w.WriteHeader(404)
			return
		}
		_, _ = w.Write([]byte(body))
	}))
}

// hostPort splits an httptest URL "http://127.0.0.1:PORT" into host, port.
func hostPort(t *testing.T, srv *httptest.Server) (string, string) {
	t.Helper()
	h, p, err := net.SplitHostPort(strings.TrimPrefix(srv.URL, "http://"))
	if err != nil {
		t.Fatalf("split %s: %v", srv.URL, err)
	}
	return h, p
}

func TestScrapeAllSumsAcrossPods(t *testing.T) {
	s1 := sinkStub(100, 5, 1)
	s2 := sinkStub(200, 7, 2)
	s3 := sinkStub(50, 0, 3)
	defer s1.Close()
	defer s2.Close()
	defer s3.Close()

	// httptest servers use distinct ports, so model each as its own host:port pair.
	pairs := []string{}
	for _, s := range []*httptest.Server{s1, s2, s3} {
		h, p := hostPort(t, s)
		pairs = append(pairs, h+":"+p)
	}
	got, err := scrapeAllPairs(context.Background(), pairs)
	if err != nil {
		t.Fatalf("scrapeAllPairs: %v", err)
	}
	var a, st, d int64
	for _, c := range got {
		a += c.applied
		st += c.stale
		d += c.duplicate
	}
	if a != 350 || st != 12 || d != 6 {
		t.Fatalf("sum = (%d,%d,%d), want (350,12,6)", a, st, d)
	}
}

func TestDeltaRejectsCounterRegression(t *testing.T) {
	// Baseline higher than current simulates a pod restart (cumulative counter reset).
	base := map[string]lwwCounts{"10.0.0.1:4195": {applied: 100, stale: 5, duplicate: 1}}
	cur := map[string]lwwCounts{"10.0.0.1:4195": {applied: 40, stale: 5, duplicate: 1}}
	_, _, _, err := sumDelta([]string{"10.0.0.1:4195"}, base, cur)
	if err == nil {
		t.Fatal("expected regression error (pod restart), got nil")
	}
}

func TestDeltaSumsAcrossPods(t *testing.T) {
	pairs := []string{"a:4195", "b:4195"}
	base := map[string]lwwCounts{"a:4195": {10, 1, 0}, "b:4195": {20, 2, 0}}
	cur := map[string]lwwCounts{"a:4195": {60, 4, 0}, "b:4195": {120, 9, 0}}
	a, s, d, err := sumDelta(pairs, base, cur)
	if err != nil {
		t.Fatalf("sumDelta: %v", err)
	}
	if a != 150 || s != 10 || d != 0 {
		t.Fatalf("delta = (%d,%d,%d), want (150,10,0)", a, s, d)
	}
}

func TestDedupeSorted(t *testing.T) {
	got := dedupeSorted([]string{"a:1", "a:1", "b:1", "b:1", "c:1"})
	want := []string{"a:1", "b:1", "c:1"}
	if len(got) != len(want) {
		t.Fatalf("dedupeSorted len = %d (%v), want %d (%v)", len(got), got, len(want), want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("dedupeSorted[%d] = %q, want %q", i, got[i], want[i])
		}
	}
}

func TestSumDeltaMissingPodFails(t *testing.T) {
	pairs := []string{"a:4195", "b:4195"}
	base := map[string]lwwCounts{"a:4195": {10, 1, 0}, "b:4195": {20, 2, 0}}
	cur := map[string]lwwCounts{"a:4195": {60, 4, 0}} // b vanished mid-run
	_, _, _, err := sumDelta(pairs, base, cur)
	if err == nil {
		t.Fatal("expected error when a baseline pod is missing at end-of-window, got nil")
	}
}

func TestScrapeAllPairsFailsIfOnePodUnreachable(t *testing.T) {
	s1 := sinkStub(100, 5, 1)
	defer s1.Close()
	h, p := hostPort(t, s1)
	good := h + ":" + p
	// 127.0.0.1:1 is reserved/closed → connection refused.
	_, err := scrapeAllPairs(context.Background(), []string{good, "127.0.0.1:1"})
	if err == nil {
		t.Fatal("expected scrapeAllPairs to fail when one pod is unreachable, got nil")
	}
}

func TestSameSet(t *testing.T) {
	base := []string{"10.0.0.1:4195", "10.0.0.2:4195", "10.0.0.3:4195"}
	if !sameSet(base, []string{"10.0.0.1:4195", "10.0.0.2:4195", "10.0.0.3:4195"}) {
		t.Fatal("identical sets should compare equal")
	}
	// a new pod appeared mid-run
	if sameSet(base, []string{"10.0.0.1:4195", "10.0.0.2:4195", "10.0.0.3:4195", "10.0.0.4:4195"}) {
		t.Fatal("added pod should NOT compare equal (must fail loud)")
	}
	// a pod disappeared mid-run
	if sameSet(base, []string{"10.0.0.1:4195", "10.0.0.2:4195"}) {
		t.Fatal("removed pod should NOT compare equal")
	}
	// same size, different member
	if sameSet(base, []string{"10.0.0.1:4195", "10.0.0.2:4195", "10.0.0.9:4195"}) {
		t.Fatal("replaced pod should NOT compare equal")
	}
}
