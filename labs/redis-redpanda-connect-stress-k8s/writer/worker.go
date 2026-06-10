package main

import (
	"context"
	"log"
	"time"

	"github.com/redis/go-redis/v9"
)

type Worker struct {
	ID            int
	RDB           *redis.Client
	StreamKey     string
	StreamMaxLen  int64
	PipelineDepth int
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
			p := NewPayload(base|seq, 0)
			kv := NewKeyValue(base|seq, w.KeySpaceSize)
			// SET the key in central Redis so connect can detect the change and
			// replicate it; the XADD entry carries the same hash as the value so
			// the sink can write exactly this hash to regional Redis.
			pipe.Set(ctx, kv.Key, kv.Hash, 0)
			pipe.XAdd(ctx, &redis.XAddArgs{
				Stream: w.StreamKey,
				MaxLen: w.StreamMaxLen,
				Approx: true,
				Values: map[string]any{
					"value":     kv.Hash,
					"event_id":  p.EventID,
					"key":       kv.Key,
					"pattern":   kv.Pattern,
					"t_send_ms": p.TsNs / 1_000_000,
				},
			})
		}
		cmds, err := pipe.Exec(ctx)
		w.Counters.Inflight.Add(-1)
		if err != nil {
			// Pipeline has 2 commands per event: SET at index 2i, XADD at 2i+1.
			// An event reaches connect only if its XADD succeeded. When SET succeeds
			// but XADD fails the key is mutated in central Redis with no stream event —
			// a permanent replication gap — so log it distinctly.
			var sent, errs int64
			for i := 0; i < depth && 2*i+1 < len(cmds); i++ {
				if xErr := cmds[2*i+1].Err(); xErr != nil {
					errs++
					if cmds[2*i].Err() == nil && ctx.Err() == nil {
						w.Counters.SetGaps.Add(1)
						log.Printf("worker %d event %d: SET ok but XADD failed (replication gap): %v", w.ID, i, xErr)
					}
				} else {
					sent++
				}
			}
			w.Counters.Sent.Add(sent)
			w.Counters.Errors.Add(errs)
			if ctx.Err() == nil {
				log.Printf("worker %d: pipeline error: %v", w.ID, err)
			}
		} else {
			w.Counters.Sent.Add(int64(depth))
		}
	}
}
