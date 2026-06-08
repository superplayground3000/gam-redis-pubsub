package main

import "testing"

// helper: build a sample with a per-pod consumed map and active-stream total.
func s(consumed map[string]int64, active int) Sample {
	return Sample{Consumed: consumed, ActiveStreams: active}
}

// After a leader is replaced (Proof B2), the dead pod's consumed:<pod> key persists
// frozen while a brand-new pod key appears and rises. SingleActive must still hold:
// exactly one pod rises per pair even though the key set grows.
func TestSingleActive_FrozenKeyPlusNewPodRising(t *testing.T) {
	series := []Sample{
		s(map[string]int64{"dead": 100, "new": 5}, 1),
		s(map[string]int64{"dead": 100, "new": 9}, 1), // only "new" rises; "dead" frozen
		s(map[string]int64{"dead": 100, "new": 13}, 1),
	}
	if !SingleActive(series) {
		t.Fatal("frozen key + one new pod rising should be single-active")
	}
}

// A pod that newly appears in b (absent in a) and rises must be counted via the
// union, so a genuine second consumer starting up is detected as overlap.
func TestOverlapPairs_NewPodCountsViaUnion(t *testing.T) {
	series := []Sample{
		s(map[string]int64{"a": 10}, 1),
		s(map[string]int64{"a": 20, "b": 4}, 2), // "b" newly appears and rises -> 2 rose
	}
	if OverlapPairs(series) != 1 {
		t.Fatalf("OverlapPairs = %d, want 1 (new pod must count via union)", OverlapPairs(series))
	}
}

func TestSingleActive_AllOnePodRising(t *testing.T) {
	series := []Sample{
		s(map[string]int64{"a": 10, "b": 0, "c": 0}, 1),
		s(map[string]int64{"a": 20, "b": 0, "c": 0}, 1),
		s(map[string]int64{"a": 30, "b": 0, "c": 0}, 1),
	}
	if !SingleActive(series) {
		t.Fatal("expected single-active for one pod rising with active==1")
	}
}

func TestSingleActive_FalseWhenTwoRise(t *testing.T) {
	series := []Sample{
		s(map[string]int64{"a": 10, "b": 5}, 2),
		s(map[string]int64{"a": 20, "b": 9}, 2),
	}
	if SingleActive(series) {
		t.Fatal("expected NOT single-active when two pods rise")
	}
}

func TestOverlapPairs_LongestRun(t *testing.T) {
	series := []Sample{
		s(map[string]int64{"a": 0, "b": 0}, 1),
		s(map[string]int64{"a": 10, "b": 0}, 1),
		s(map[string]int64{"a": 20, "b": 5}, 2),
		s(map[string]int64{"a": 30, "b": 9}, 2),
		s(map[string]int64{"a": 40, "b": 9}, 1),
	}
	got := OverlapPairs(series)
	if got != 2 {
		t.Fatalf("OverlapPairs = %d, want 2", got)
	}
}

func TestGapPairs_NoTotalIncrease(t *testing.T) {
	series := []Sample{
		s(map[string]int64{"a": 10}, 1),
		s(map[string]int64{"a": 10}, 0),
		s(map[string]int64{"a": 10}, 0),
		s(map[string]int64{"a": 25}, 1),
	}
	got := GapPairs(series)
	if got != 2 {
		t.Fatalf("GapPairs = %d, want 2", got)
	}
}
