package elector

import (
	"context"
	"testing"
	"time"
)

func TestWaitPostDelayZeroReturnsImmediately(t *testing.T) {
	start := time.Now()
	if !waitPostDelay(context.Background(), 0) {
		t.Fatal("zero delay must return true (POST proceeds)")
	}
	if time.Since(start) > 50*time.Millisecond {
		t.Fatal("zero delay must not block")
	}
}

func TestWaitPostDelayElapsesReturnsTrue(t *testing.T) {
	if !waitPostDelay(context.Background(), 20*time.Millisecond) {
		t.Fatal("elapsed delay must return true")
	}
}

func TestWaitPostDelayCancelledReturnsFalse(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan bool, 1)
	go func() { done <- waitPostDelay(ctx, 5*time.Second) }()
	time.Sleep(20 * time.Millisecond)
	cancel()
	select {
	case ok := <-done:
		if ok {
			t.Fatal("cancel during delay must return false (no POST)")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("waitPostDelay did not return promptly after cancel")
	}
}
