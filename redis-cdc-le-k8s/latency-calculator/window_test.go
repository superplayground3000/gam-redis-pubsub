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

func TestEvictShrinksCapacity(t *testing.T) {
	w := NewWindow(1000) // 1s window
	for i := 0; i < 1000; i++ {
		w.Add(Sample{Op: "create", LatencyMs: 1, SinkTs: 1000}) // old, will evict
	}
	for i := 0; i < 3; i++ {
		w.Add(Sample{Op: "create", LatencyMs: 1, SinkTs: 9500}) // recent, kept
	}
	w.Evict(10000) // cutoff = 9000: only the 3 recent survive
	if len(w.Samples()) != 3 {
		t.Fatalf("after evict len=%d want 3", len(w.Samples()))
	}
	if cap(w.Samples()) > 4*len(w.Samples()) {
		t.Errorf("capacity not shrunk: cap=%d len=%d", cap(w.Samples()), len(w.Samples()))
	}
}
