package main

import (
	"context"
	"fmt"
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
	KeySpaceSize  int64
	Lim           *Limiter
	Counters      *Counters
	Versions      *Versions
}

// ownedKeyID returns the n-th key id (0-based) this worker owns, round-robining
// over the strided subset { id : id % Workers == ID } of [0, KeySpaceSize).
func (w *Worker) ownedKeyID(n int64) int64 {
	stride := int64(w.Workers)
	count := (w.KeySpaceSize - int64(w.ID) + stride - 1) / stride // # owned ids
	if count <= 0 {
		return int64(w.ID) % w.KeySpaceSize
	}
	return int64(w.ID) + (n%count)*stride
}

func (w *Worker) Run(ctx context.Context) {
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

		epoch := w.Versions.Epoch()
		if epoch == "" {
			// No run started yet; nothing to number against. Idle briefly.
			continue
		}

		w.Counters.Inflight.Add(1)
		pipe := w.RDB.Pipeline()
		for i := 0; i < depth; i++ {
			id := w.ownedKeyID(emitted)
			emitted++
			key := fmt.Sprintf("lww:%s:%d", epoch, id)
			ver := w.Versions.Next(w.ID, key)
			p := NewPayload(ver, w.PayloadBytes)
			body, _ := p.JSON()
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
					"version":   ver,
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
