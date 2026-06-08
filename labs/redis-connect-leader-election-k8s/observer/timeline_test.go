package main

import "testing"

// helper: build a sample with a per-pod consumed map and active-stream total.
func s(consumed map[string]int64, active int) Sample {
	return Sample{Consumed: consumed, ActiveStreams: active}
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
