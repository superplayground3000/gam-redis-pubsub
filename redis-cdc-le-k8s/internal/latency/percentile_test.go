package latency

import "testing"

func TestPercentileNearestRank(t *testing.T) {
	s := []int64{10, 20, 30, 40, 50}
	cases := []struct {
		p    float64
		want int64
	}{{50, 30}, {95, 50}, {99, 50}, {0, 10}}
	for _, c := range cases {
		if got := Percentile(s, c.p); got != c.want {
			t.Errorf("Percentile(p=%v)=%d want %d", c.p, got, c.want)
		}
	}
}

func TestSummarizeEmpty(t *testing.T) {
	if got := Summarize(nil); got != (Stats{}) {
		t.Errorf("Summarize(nil)=%+v want zero", got)
	}
}

func TestSummarizeSingle(t *testing.T) {
	got := Summarize([]int64{42})
	want := Stats{Count: 1, MinMs: 42, MaxMs: 42, MeanMs: 42, P50Ms: 42, P95Ms: 42, P99Ms: 42}
	if got != want {
		t.Errorf("Summarize([42])=%+v want %+v", got, want)
	}
}

func TestSummarizeN2P99IsMax(t *testing.T) {
	got := Summarize([]int64{90, 10}) // unsorted input
	if got.Count != 2 || got.MinMs != 10 || got.MaxMs != 90 || got.MeanMs != 50 {
		t.Fatalf("basic stats wrong: %+v", got)
	}
	if got.P50Ms != 10 || got.P99Ms != 90 {
		t.Errorf("N=2 p50=%d (want 10) p99=%d (want 90=max)", got.P50Ms, got.P99Ms)
	}
}
