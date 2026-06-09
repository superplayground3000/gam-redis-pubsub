package main

import "testing"

func TestRunBootIDStableNonEmpty(t *testing.T) {
	r := NewRun()
	if r.BootID() == "" {
		t.Fatal("BootID empty")
	}
	if r.BootID() != r.BootID() {
		t.Fatal("BootID changed between calls")
	}
}

func TestRunEpochStartsEmpty(t *testing.T) {
	r := NewRun()
	if r.Epoch() != "" {
		t.Fatalf("epoch=%q, want empty before reset (start gate closed)", r.Epoch())
	}
}

func TestRunSetEpochOpensGateAndStateReportsIt(t *testing.T) {
	r := NewRun()
	r.SetEpoch("run-1")
	if r.Epoch() != "run-1" {
		t.Fatalf("epoch=%q, want run-1", r.Epoch())
	}
	st := r.State()
	if st.Epoch != "run-1" {
		t.Fatalf("state epoch=%q", st.Epoch)
	}
	if st.BootID == "" {
		t.Fatal("state boot_id empty")
	}
}
