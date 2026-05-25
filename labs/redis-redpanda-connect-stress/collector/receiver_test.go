package main

import "testing"

func TestNewReceiverInitialState(t *testing.T) {
	r := NewReceiver("redis-region:6379", "region-events")
	defer r.Close()
	if c := r.Count(); c != 0 {
		t.Errorf("Count()=%d, want 0", c)
	}
	if e := r.Errors(); e != 0 {
		t.Errorf("Errors()=%d, want 0", e)
	}
	s := r.Latency()
	if s.Samples != 0 {
		t.Errorf("Latency().Samples=%d, want 0", s.Samples)
	}
}
