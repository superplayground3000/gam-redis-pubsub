package main

import (
	"context"
	"testing"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"
)

func TestSweepDeletesOldTombstonesOnly(t *testing.T) {
	mr, _ := miniredis.Run()
	defer mr.Close()
	rdb := redis.NewClient(&redis.Options{Addr: mr.Addr()})
	defer rdb.Close()
	ctx := context.Background()

	now := int64(100000) // ms
	rdb.HSet(ctx, "k:old", "ver", 5, "deleted", "1", "deleted_at", now-60000)  // eligible
	rdb.HSet(ctx, "k:fresh", "ver", 5, "deleted", "1", "deleted_at", now-1000) // within horizon, keep
	rdb.HSet(ctx, "k:live", "ver", 7, "deleted", "0")                           // live, never touch

	s := &Sweeper{RDB: rdb, HorizonMs: 30000, ScanCount: 100}
	n, err := s.SweepOnce(ctx, now)
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("want 1 reaped, got %d", n)
	}
	if mr.Exists("k:old") {
		t.Fatal("old tombstone should be deleted")
	}
	if !mr.Exists("k:fresh") || !mr.Exists("k:live") {
		t.Fatal("fresh tombstone and live key must survive")
	}
}

// A partial-write tombstone (deleted=1) with a missing or non-numeric deleted_at
// must NOT be reaped — otherwise da=0 would make age huge and resurrect a key the
// fence intended to keep for the full horizon. It must still survive the sweep.
func TestSweepSkipsTombstoneWithBadDeletedAt(t *testing.T) {
	mr, _ := miniredis.Run()
	defer mr.Close()
	rdb := redis.NewClient(&redis.Options{Addr: mr.Addr()})
	defer rdb.Close()
	ctx := context.Background()

	now := int64(100000) // ms
	// deleted=1 but deleted_at entirely absent.
	rdb.HSet(ctx, "k:nodate", "ver", 5, "deleted", "1")
	// deleted=1 but deleted_at non-numeric.
	rdb.HSet(ctx, "k:baddate", "ver", 5, "deleted", "1", "deleted_at", "not-a-number")
	// a genuinely old, well-formed tombstone — should be reaped.
	rdb.HSet(ctx, "k:old", "ver", 5, "deleted", "1", "deleted_at", now-60000)

	s := &Sweeper{RDB: rdb, HorizonMs: 30000, ScanCount: 100}
	n, err := s.SweepOnce(ctx, now)
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("want 1 reaped (only the well-formed old one), got %d", n)
	}
	if !mr.Exists("k:nodate") {
		t.Fatal("tombstone with missing deleted_at must survive")
	}
	if !mr.Exists("k:baddate") {
		t.Fatal("tombstone with non-numeric deleted_at must survive")
	}
	if mr.Exists("k:old") {
		t.Fatal("well-formed old tombstone should be deleted")
	}
	// All three are tombstones, even the skipped ones.
	if got := s.Tombstones.Load(); got != 3 {
		t.Fatalf("want 3 tombstones counted, got %d", got)
	}
}
