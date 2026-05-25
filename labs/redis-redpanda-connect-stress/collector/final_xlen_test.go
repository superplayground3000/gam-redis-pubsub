package main

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestReadFinalRegionXLenSuccessOnFirstTry(t *testing.T) {
	f := newFakeStreamClient(t)
	f.setXLen("region-events", 12345)
	ctx, cancel := context.WithTimeout(context.Background(), 1*time.Second)
	defer cancel()
	got := readFinalRegionXLen(ctx, f, nil)
	if got != 12345 {
		t.Errorf("got %d, want 12345", got)
	}
}

func TestReadFinalRegionXLenFallsBackToLastSnap(t *testing.T) {
	f := newFakeStreamClient(t)
	f.setError(errors.New("redis down"))
	snaps := []Snapshot{
		{RegionXLen: 100},
		{RegionXLen: 7777}, // last snapshot — should be used as fallback
	}
	ctx, cancel := context.WithTimeout(context.Background(), 1*time.Second)
	defer cancel()
	got := readFinalRegionXLen(ctx, f, snaps)
	if got != 7777 {
		t.Errorf("got %d, want 7777 (fallback to last snap)", got)
	}
}

func TestReadFinalRegionXLenReturnsZeroWhenNoFallback(t *testing.T) {
	f := newFakeStreamClient(t)
	f.setError(errors.New("redis down"))
	ctx, cancel := context.WithTimeout(context.Background(), 1*time.Second)
	defer cancel()
	got := readFinalRegionXLen(ctx, f, nil)
	if got != 0 {
		t.Errorf("got %d, want 0 (no snaps to fall back to)", got)
	}
}
