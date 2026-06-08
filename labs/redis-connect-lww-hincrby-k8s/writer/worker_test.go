package main

import (
	"context"
	"math/rand"
	"testing"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"
)

func TestEmitOnceWritesStreamAndSrcmax(t *testing.T) {
	mr, err := miniredis.Run()
	if err != nil {
		t.Fatal(err)
	}
	defer mr.Close()
	rdb := redis.NewClient(&redis.Options{Addr: mr.Addr()})
	defer rdb.Close()
	ctx := context.Background()

	w := &Worker{
		ID: 0, Workers: 2, RDB: rdb, StreamKey: "app.events",
		StreamMaxLen: 1000, PayloadBytes: 8, KeySpaceSize: 4,
		Minter:   NewMinter(rdb),
		Counters: &Counters{},
		Ops:      NewOpPicker(OpWeights{Set: 1}, rand.New(rand.NewSource(1))),
		Epoch:    "run-test",
	}
	key, ver, err := w.emitOne(ctx, rdb.Pipeline())
	if err != nil {
		t.Fatal(err)
	}
	if ver < 1 {
		t.Fatalf("version not minted: %d", ver)
	}
	got, err := rdb.HGet(ctx, "srcmax:run-test", key).Int64()
	if err != nil {
		t.Fatalf("srcmax missing for %s: %v", key, err)
	}
	if got != ver {
		t.Fatalf("srcmax=%d want %d", got, ver)
	}
}
