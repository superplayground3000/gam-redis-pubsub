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

func TestMinterPerKeyMonotonicAcrossCallers(t *testing.T) {
	rdb, done := newMini(t)
	defer done()
	m := NewMinter(rdb)
	ctx := context.Background()
	seen := map[int64]bool{}
	last := int64(0)
	for i := 0; i < 10; i++ {
		for range []int{0, 1} {
			v, err := m.NextPerKey(ctx, "lb:company:active:{employees:e-1}")
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

func TestMinterGlobalMonotonic(t *testing.T) {
	rdb, done := newMini(t)
	defer done()
	m := NewMinter(rdb)
	ctx := context.Background()
	a, _ := m.NextGlobal(ctx)
	b, _ := m.NextGlobal(ctx)
	if b <= a {
		t.Fatalf("global not monotonic: %d then %d", a, b)
	}
}
