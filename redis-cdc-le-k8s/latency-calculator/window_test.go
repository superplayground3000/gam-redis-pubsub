package main

import "testing"

func TestAddDropsNegative(t *testing.T) {
	w := NewWindow(60_000)
	w.Add(Sample{Op: "create", LatencyMs: -5, SinkTs: 1000})
	w.Add(Sample{Op: "create", LatencyMs: 7, SinkTs: 1000})
	if w.DroppedNegative() != 1 {
		t.Errorf("droppedNegative=%d want 1", w.DroppedNegative())
	}
	if len(w.Samples()) != 1 || w.Samples()[0].LatencyMs != 7 {
		t.Errorf("samples=%+v want one positive", w.Samples())
	}
}

func TestEvictBySinkTs(t *testing.T) {
	w := NewWindow(1000) // 1s window
	w.Add(Sample{Op: "update", LatencyMs: 1, SinkTs: 9500})
	w.Add(Sample{Op: "update", LatencyMs: 2, SinkTs: 8000})
	w.Evict(10000) // cutoff = 9000
	if len(w.Samples()) != 1 || w.Samples()[0].SinkTs != 9500 {
		t.Errorf("after evict samples=%+v want only sinkTs=9500", w.Samples())
	}
}
