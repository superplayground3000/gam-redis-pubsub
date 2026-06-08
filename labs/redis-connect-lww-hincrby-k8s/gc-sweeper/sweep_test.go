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
