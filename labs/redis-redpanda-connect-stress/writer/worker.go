package main

import (
	"context"
	"log"
	"strconv"
	"time"

	"github.com/redis/go-redis/v9"
)

type Worker struct {
	ID            int
	RDB           *redis.Client
	StreamKey     string
	StreamMaxLen  int64
	PipelineDepth int
	PayloadBytes  int
	KeySpaceSize  int64
	Lim           *Limiter
	Counters      *Counters
}

func (w *Worker) Run(ctx context.Context) {
	var seq int64
	base := int64(w.ID) << 40 // each worker gets a distinct high-bit seq prefix so seqs never collide
	for {
		// Dynamic batch size: at low rates, a fixed PipelineDepth=50 means batches every
		// (depth/rate) seconds, which is bursty and creates large measurement gaps. Size
		// batches so they fire roughly every 100ms at any rate, with a floor of 1 and a
		// ceiling of PipelineDepth.
		rate := int(w.Lim.Current())
		depth := w.PipelineDepth
		if rate > 0 {
			perTenth := rate / 10 // tokens that accumulate per 100ms
			if perTenth < 1 {
				perTenth = 1
			}
			if perTenth < depth {
				depth = perTenth
			}
		}

		// Per-iteration timeout so workers re-fetch the current Limiter state on every
		// pass — necessary because Limiter.Set updates limit/burst on the underlying
		// rate.Limiter, and a worker already blocked inside the old WaitN would otherwise
		// stay blocked when the rate transitions from 0 to N>0.
		waitCtx, waitCancel := context.WithTimeout(ctx, 500*time.Millisecond)
		err := w.Lim.WaitN(waitCtx, depth)
		waitCancel()
		if err != nil {
			if ctx.Err() != nil {
				return // genuine cancellation
			}
			// Timeout or rate-too-low: tokens not yet accumulated. Loop and retry.
			continue
		}
		w.Counters.Inflight.Add(1)
		pipe := w.RDB.Pipeline()
		for i := 0; i < depth; i++ {
			seq++
			p := NewPayload(base|seq, w.PayloadBytes)
			body, _ := p.JSON()
			key := "stress:" + strconv.FormatInt((base|seq)%w.KeySpaceSize, 10)
			pipe.XAdd(ctx, &redis.XAddArgs{
				Stream: w.StreamKey,
				MaxLen: w.StreamMaxLen,
				Approx: true,
				Values: map[string]any{
					"value":     string(body),
					"event_id":  p.EventID,
					"key":       key,
					"pattern":   "stress",
					"t_send_ms": p.TsNs / 1_000_000,
				},
			})
		}
		_, err = pipe.Exec(ctx)
		w.Counters.Inflight.Add(-1)
		if err != nil {
			// Conservative semantic: any pipeline error charges the full batch to Errors,
			// even if some XADDs in the batch may have succeeded. We never inspect per-command
			// results — the overhead of iterating the response isn't worth the precision for
			// a stress lab where partial pipeline failures are extremely rare.
			w.Counters.Errors.Add(int64(depth))
			if ctx.Err() == nil {
				log.Printf("worker %d: pipeline error: %v", w.ID, err)
			}
		} else {
			w.Counters.Sent.Add(int64(depth))
		}
	}
}
