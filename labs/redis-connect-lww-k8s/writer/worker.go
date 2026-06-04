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
		// Unreachable: main.go guards KEY_SPACE_SIZE >= WORKERS, so every worker
		// (ID < Workers <= KeySpaceSize) owns >= 1 id. Clamp defensively to avoid a
		// divide-by-zero; the result (ID) is still in-stride and collision-free.
		count = 1
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

		if w.Versions.Epoch() == "" {
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
		var n int
		for i := 0; i < depth; i++ {
			id := w.ownedKeyID(emitted)
			// Derive key + version from ONE epoch snapshot so a concurrent /reset
			// can't pair an old-epoch key with a new-epoch counter.
			key, ver, ok := w.Versions.NextForCurrent(w.ID, id)
			if !ok {
				break // epoch cleared mid-batch (not expected); flush what we have
			}
			emitted++
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
			n++
		}
		if n == 0 {
			w.Counters.Inflight.Add(-1)
			continue
		}
		_, err = pipe.Exec(ctx)
		w.Counters.Inflight.Add(-1)
		if err != nil {
			w.Counters.Errors.Add(int64(n))
			if ctx.Err() == nil {
				log.Printf("worker %d: pipeline error: %v", w.ID, err)
			}
		} else {
			w.Counters.Sent.Add(int64(n))
		}
	}
}
