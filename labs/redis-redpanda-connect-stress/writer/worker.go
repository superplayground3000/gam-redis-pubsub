package main

import (
	"context"
	"log"
	"strconv"

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
		if err := w.Lim.WaitN(ctx, w.PipelineDepth); err != nil {
			return // context cancelled
		}
		w.Counters.Inflight.Add(1)
		pipe := w.RDB.Pipeline()
		for i := 0; i < w.PipelineDepth; i++ {
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
		_, err := pipe.Exec(ctx)
		w.Counters.Inflight.Add(-1)
		if err != nil {
			// Conservative semantic: any pipeline error charges the full batch to Errors,
			// even if some XADDs in the batch may have succeeded. We never inspect per-command
			// results — the overhead of iterating the response isn't worth the precision for
			// a stress lab where partial pipeline failures are extremely rare.
			w.Counters.Errors.Add(int64(w.PipelineDepth))
			if ctx.Err() == nil {
				log.Printf("worker %d: pipeline error: %v", w.ID, err)
			}
		} else {
			w.Counters.Sent.Add(int64(w.PipelineDepth))
		}
	}
}
