package main

import (
	"context"
	"testing"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"
)

func newMini(t *testing.T) (*redis.Client, func()) {
	t.Helper()
	mr, err := miniredis.Run()
	if err != nil {
		t.Fatal(err)
	}
	rdb := redis.NewClient(&redis.Options{Addr: mr.Addr()})
	return rdb, func() { rdb.Close(); mr.Close() }
}

// TestMinterPerEntityMonotonicAcrossCallers proves the single per-entity counter
// yields strictly-increasing, collision-free versions regardless of which caller
// (op type) mints — the property that makes set/delete/rename versions comparable.
func TestMinterPerEntityMonotonicAcrossCallers(t *testing.T) {
	rdb, done := newMini(t)
	defer done()
	m := NewMinter(rdb)
	ctx := context.Background()
	ent := "employees:e-1"
	seen := map[int64]bool{}
	last := int64(0)
	for i := 0; i < 10; i++ {
		for range []int{0, 1} {
			v, err := m.NextForEntity(ctx, ent)
			if err != nil {
				t.Fatal(err)
			}
			if seen[v] {
				t.Fatalf("version collision at %d", v)
			}
			if v <= last {
				t.Fatalf("non-monotonic: %d after %d", v, last)
			}
			seen[v], last = true, v
		}
	}
}

// TestMinterDistinctEntitiesAreIndependent confirms different entities keep their
// own sequences (one HINCRBY field per entity, not a single global counter).
func TestMinterDistinctEntitiesAreIndependent(t *testing.T) {
	rdb, done := newMini(t)
	defer done()
	m := NewMinter(rdb)
	ctx := context.Background()
	a1, _ := m.NextForEntity(ctx, "employees:e-1")
	b1, _ := m.NextForEntity(ctx, "groups:e-2")
	if a1 != 1 || b1 != 1 {
		t.Fatalf("each entity should start at 1: a1=%d b1=%d", a1, b1)
	}
}
