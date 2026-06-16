// Rolling time window of latency samples, evicted by event (sink) time.
package main

// Sample is one create/update apply observed via the cdc:latency stream.
type Sample struct {
	Op        string // "create" | "update"
	LatencyMs int64  // sink_ts - writer_ts
	SinkTs    int64  // unix millis, the eviction key
}

// Window holds the in-memory rolling set of samples plus a cumulative
// negative-latency drop counter (negatives are clock-skew artifacts).
type Window struct {
	windowMs        int64
	samples         []Sample
	droppedNegative int
}

func NewWindow(windowMs int64) *Window { return &Window{windowMs: windowMs} }

// Add stores a sample, dropping (and counting) any with negative latency.
func (w *Window) Add(s Sample) {
	if s.LatencyMs < 0 {
		w.droppedNegative++
		return
	}
	w.samples = append(w.samples, s)
}

// Evict removes samples whose SinkTs is older than nowMs - windowMs.
func (w *Window) Evict(nowMs int64) {
	cutoff := nowMs - w.windowMs
	kept := w.samples[:0]
	for _, s := range w.samples {
		if s.SinkTs >= cutoff {
			kept = append(kept, s)
		}
	}
	// Release the (possibly large) backing array once it is mostly empty, so a
	// burst of samples does not pin memory after eviction shrinks the window.
	if cap(kept) > 4*len(kept) {
		ns := make([]Sample, len(kept))
		copy(ns, kept)
		kept = ns
	}
	w.samples = kept
}

func (w *Window) Samples() []Sample    { return w.samples }
func (w *Window) DroppedNegative() int { return w.droppedNegative }
