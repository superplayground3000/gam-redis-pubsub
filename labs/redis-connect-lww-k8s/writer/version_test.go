package main

import (
	"strconv"
	"sync"
	"testing"
)

func TestVersionsMonotonicPerKeyWithinEpoch(t *testing.T) {
	v := NewVersions(2) // 2 shards (workers)
	v.SetEpoch("e1")
	// worker 0 owns shard 0; bump key "k" five times
	var last int64
	for i := 0; i < 5; i++ {
		got := v.Next(0, "lww:e1:0")
		if got != last+1 {
			t.Fatalf("Next #%d = %d, want %d", i, got, last+1)
		}
		last = got
	}
}

func TestVersionsResetOnNewEpoch(t *testing.T) {
	v := NewVersions(1)
	v.SetEpoch("e1")
	v.Next(0, "lww:e1:0")
	v.Next(0, "lww:e1:0") // ver=2
	v.SetEpoch("e2")      // new namespace
	if got := v.Next(0, "lww:e2:0"); got != 1 {
		t.Fatalf("after new epoch Next = %d, want 1", got)
	}
}

func TestVersionsBootIDStableNonEmpty(t *testing.T) {
	v := NewVersions(1)
	if v.BootID() == "" {
		t.Fatal("BootID empty")
	}
	if v.BootID() != v.BootID() {
		t.Fatal("BootID changed between calls")
	}
}

func TestVersionsStateMergesAcrossShards(t *testing.T) {
	v := NewVersions(2)
	v.SetEpoch("e1")
	v.Next(0, "lww:e1:0")
	v.Next(1, "lww:e1:1")
	v.Next(1, "lww:e1:1") // ver=2
	st := v.State()
	if st.Epoch != "e1" {
		t.Fatalf("epoch=%s", st.Epoch)
	}
	if st.Keys["lww:e1:0"] != 1 || st.Keys["lww:e1:1"] != 2 {
		t.Fatalf("keys=%v", st.Keys)
	}
	if st.DistinctKeys != 2 || st.TotalVersions != 3 {
		t.Fatalf("distinct=%d total=%d", st.DistinctKeys, st.TotalVersions)
	}
}

func TestVersionsConcurrentNextNoRace(t *testing.T) {
	v := NewVersions(4)
	v.SetEpoch("e1")
	var wg sync.WaitGroup
	for w := 0; w < 4; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			for i := 0; i < 1000; i++ {
				v.Next(w, "lww:e1:"+strconv.Itoa(w))
			}
		}(w)
	}
	wg.Wait()
	st := v.State()
	if st.TotalVersions != 4000 {
		t.Fatalf("total=%d, want 4000", st.TotalVersions)
	}
}
