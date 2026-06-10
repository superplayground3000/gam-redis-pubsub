// $LAB/writer/state_test.go
package main

import "testing"

func TestRunStateOpCountsAndKeys(t *testing.T) {
	s := NewRunState()
	s.SetEpoch("run-1")
	s.Record("create", "lb:general:active:{items:1}")
	s.Record("create", "lb:general:active:{items:2}")
	s.Record("delete", "lb:general:active:{items:1}")
	snap := s.Snapshot()
	if snap.Epoch != "run-1" {
		t.Fatalf("epoch = %q", snap.Epoch)
	}
	if snap.Ops["create"] != 2 || snap.Ops["delete"] != 1 {
		t.Fatalf("op counts wrong: %+v", snap.Ops)
	}
	if snap.DistinctKeys != 2 {
		t.Fatalf("distinct keys = %d, want 2", snap.DistinctKeys)
	}
}

func TestRunStateResetClearsCounts(t *testing.T) {
	s := NewRunState()
	s.SetEpoch("a")
	s.Record("create", "k")
	s.SetEpoch("b") // new epoch resets counts and keys
	snap := s.Snapshot()
	if snap.Ops["create"] != 0 || snap.DistinctKeys != 0 || snap.Epoch != "b" {
		t.Fatalf("epoch swap did not reset: %+v", snap)
	}
}
