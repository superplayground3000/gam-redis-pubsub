package main

import (
	"context"
	"log"
	"time"

	"github.com/redis/go-redis/v9"
)

type Worker struct {
	ID            int
	Workers       int
	RDB           *redis.Client
	StreamKey     string
	StreamMaxLen  int64
	PipelineDepth int
	PayloadBytes  int
	Lim           *Limiter
	Counters      *Counters
	Run           *Run
}

// Loop emits payloads to the stream at the limiter's current rate. It is gated on the
// run epoch: nothing is sent until /reset opens the gate (Run.Epoch() != "").
func (w *Worker) Loop(ctx context.Context) {
	var emitted int64
	for {
		rate := int(w.Lim.Current())
		depth := w.PipelineDepth
		if rate > 0 {
			perTenth := rate / 10
			if perTenth < 1 {
				perTenth = 1
			}
			if perTenth < depth {
				depth = perTenth
			}
		}

		waitCtx, waitCancel := context.WithTimeout(ctx, 500*time.Millisecond)
		err := w.Lim.WaitN(waitCtx, depth)
		waitCancel()
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			continue
		}

		if w.Run.Epoch() == "" {
			// No run started yet (no /reset received). Sleep before retrying so we
			// don't hot-spin discarding granted tokens if a rate was set pre-reset.
			select {
			case <-ctx.Done():
				return
			case <-time.After(100 * time.Millisecond):
			}
			continue
		}

		w.Counters.Inflight.Add(1)
		pipe := w.RDB.Pipeline()
		for i := 0; i < depth; i++ {
			emitted++
			p := NewPayload(emitted, w.PayloadBytes)
			body, _ := p.JSON()
			pipe.XAdd(ctx, &redis.XAddArgs{
				Stream: w.StreamKey,
				MaxLen: w.StreamMaxLen,
				Approx: true,
				Values: map[string]any{
					"value":     string(body),
					"event_id":  p.EventID,
					"pattern":   "stress",
					"t_send_ms": p.TsNs / 1_000_000,
				},
			})
		}
		_, err = pipe.Exec(ctx)
		w.Counters.Inflight.Add(-1)
		if err != nil {
			w.Counters.Errors.Add(int64(depth))
			if ctx.Err() == nil {
				log.Printf("worker %d: pipeline error: %v", w.ID, err)
			}
		} else {
			w.Counters.Sent.Add(int64(depth))
		}
	}
}
