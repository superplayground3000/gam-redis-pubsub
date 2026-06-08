package main

import (
	"context"
	"testing"

	"github.com/alicebob/miniredis/v2"
)

func TestHGetAllSrcmaxAndTombstone(t *testing.T) {
	mr, _ := miniredis.Run()
	defer mr.Close()
	c := NewStreamClient(mr.Addr())
	defer c.Close()
	ctx := context.Background()

	mr.HSet("srcmax:run-1", "lb:company:active:{employees:run-1-1}", "9")
	mr.HSet("lb:company:active:{employees:run-1-1}", "ver", "9")
	mr.HSet("lb:company:active:{employees:run-1-1}", "deleted", "0")

	m, err := c.HGetAllInt(ctx, "srcmax:run-1")
	if err != nil {
		t.Fatal(err)
	}
	if m["lb:company:active:{employees:run-1-1}"] != 9 {
		t.Fatalf("srcmax wrong: %+v", m)
	}
	del, err := c.HGetDeleted(ctx, "lb:company:active:{employees:run-1-1}")
	if err != nil {
		t.Fatal(err)
	}
	if del != "0" {
		t.Fatalf("deleted=%q want 0", del)
	}
}

func TestRegionHasEpochKey(t *testing.T) {
	ctx := context.Background()

	// Empty region: no key contains the epoch token → false.
	mrEmpty, _ := miniredis.Run()
	defer mrEmpty.Close()
	empty := NewStreamClient(mrEmpty.Addr())
	defer empty.Close()
	dirty, err := empty.RegionHasEpochKey(ctx, "run-9")
	if err != nil {
		t.Fatal(err)
	}
	if dirty {
		t.Fatal("empty region must report no epoch key")
	}

	// Region with a key whose name embeds the epoch → true.
	mrDirty, _ := miniredis.Run()
	defer mrDirty.Close()
	region := NewStreamClient(mrDirty.Addr())
	defer region.Close()
	mrDirty.HSet("lb:company:active:{employees:run-9-3}", "ver", "5")
	dirty, err = region.RegionHasEpochKey(ctx, "run-9")
	if err != nil {
		t.Fatal(err)
	}
	if !dirty {
		t.Fatal("region with leftover epoch key must report dirty")
	}

	// A key from a DIFFERENT epoch must not trip the probe.
	dirty, err = region.RegionHasEpochKey(ctx, "run-other")
	if err != nil {
		t.Fatal(err)
	}
	if dirty {
		t.Fatal("key from a different epoch must not count as dirty")
	}
}
