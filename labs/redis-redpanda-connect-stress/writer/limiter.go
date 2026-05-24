package main

import (
	"context"
	"sync/atomic"

	"golang.org/x/time/rate"
)

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
