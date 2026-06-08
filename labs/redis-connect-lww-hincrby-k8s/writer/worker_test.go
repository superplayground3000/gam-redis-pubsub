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

	// emitOne only QUEUES the XADD + hmax onto the pipeline; the Exec below commits
	// them atomically (one MULTI/EXEC), proving srcmax and the stream entry land
	// together — a failed Exec applies NEITHER.
	pipe := rdb.TxPipeline()
	key, ver, err := w.emitOne(ctx, pipe)
	if err != nil {
		t.Fatal(err)
	}
	if ver < 1 {
		t.Fatalf("version not minted: %d", ver)
	}

	// Before Exec, the srcmax side effect must NOT be visible (it's queued, not run).
	if _, err := rdb.HGet(ctx, "srcmax:run-test", key).Result(); err != redis.Nil {
		t.Fatalf("srcmax recorded before Exec: err=%v", err)
	}

	if _, err := pipe.Exec(ctx); err != nil {
		t.Fatalf("pipe exec: %v", err)
	}

	// (a) srcmax now holds the minted version.
	got, err := rdb.HGet(ctx, "srcmax:run-test", key).Int64()
	if err != nil {
		t.Fatalf("srcmax missing for %s: %v", key, err)
	}
	if got != ver {
		t.Fatalf("srcmax=%d want %d", got, ver)
	}

	// (b) exactly one stream entry, whose version field == ver.
	n, err := rdb.XLen(ctx, "app.events").Result()
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Fatalf("XLEN=%d want 1", n)
	}
	msgs, err := rdb.XRange(ctx, "app.events", "-", "+").Result()
	if err != nil {
		t.Fatal(err)
	}
	if gotVer := msgs[0].Values["version"]; gotVer != "1" {
		t.Fatalf("stream version=%v want %d", gotVer, ver)
	}
}
