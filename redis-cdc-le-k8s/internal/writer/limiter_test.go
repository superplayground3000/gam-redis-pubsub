package writer

import (
	"context"
	"testing"
	"time"
)

func TestLimiterInitialZero(t *testing.T) {
	l := NewLimiter()
	if got := l.Current(); got != 0 {
		t.Errorf("Current=%d, want 0", got)
	}
}

func TestLimiterSetThenCurrent(t *testing.T) {
	l := NewLimiter()
	l.Set(500)
	if got := l.Current(); got != 500 {
		t.Errorf("Current=%d, want 500", got)
	}
	l.Set(0)
	if got := l.Current(); got != 0 {
		t.Errorf("Current=%d, want 0", got)
	}
}

func TestLimiterBurstScalesWithRate(t *testing.T) {
	l := NewLimiter()
	l.Set(50)
	if l.Burst() != 100 {
		t.Errorf("Burst=%d, want 100 (min floor)", l.Burst())
	}
	l.Set(10000)
	if l.Burst() != 1000 {
		t.Errorf("Burst=%d, want 1000 (rate/10)", l.Burst())
	}
}

func TestLimiterWaitNAllowsPipelineDepth(t *testing.T) {
	l := NewLimiter()
	l.Set(10000) // 10k rps, burst = 1000
	// Initial burst should let several pipeline-depth=50 batches through without blocking.
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	for i := 0; i < 5; i++ {
		if err := l.WaitN(ctx, 50); err != nil {
			t.Fatalf("iter %d: WaitN(50) failed: %v", i, err)
		}
	}
}
