package main

import (
	"context"
	"sync/atomic"

	"golang.org/x/time/rate"
)

// Limiter wraps golang.org/x/time/rate with cheap observability reads.
// r is the authoritative rate source (mutex-protected by the rate package).
// current and burst are atomic shadows for the HTTP /metrics read-path; they
// may transiently lag r for microseconds during a Set call — this is acceptable.
type Limiter struct {
	r       *rate.Limiter
	current atomic.Int64
	burst   atomic.Int64
}

func NewLimiter() *Limiter {
	l := &Limiter{r: rate.NewLimiter(0, 100)}
	l.burst.Store(100)
	return l
}

// Set updates the rate to rps events/sec via SetLimit/SetBurst on the underlying
// limiter. rps=0 pauses the writer: any workers already mid-WaitN see an "exceed
// deadline" error (returned because the wait would be infinite with limit=0).
// Worker.Run uses a 500ms per-call timeout so those errors are retried rather than
// fatal; that same timeout also forces workers to refresh their view of the limiter
// state quickly when Set transitions from 0 → N>0. Burst is floored at 100 to
// prevent warmup ramps from starving workers.
func (l *Limiter) Set(rps int) {
	b := 100
	if rps/10 > b {
		b = rps / 10
	}
	l.r.SetLimit(rate.Limit(rps))
	l.r.SetBurst(b)
	l.current.Store(int64(rps))
	l.burst.Store(int64(b))
}

func (l *Limiter) Current() int64 { return l.current.Load() }
func (l *Limiter) Burst() int64   { return l.burst.Load() }

func (l *Limiter) WaitN(ctx context.Context, n int) error {
	return l.r.WaitN(ctx, n)
}
