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
	Minter        *Minter
	Ops           *OpPicker
	// Epoch is read per batch from the shared EpochHolder so a concurrent /reset is
	// observed; set directly only in tests.
	Epoch       string
	EpochHolder *EpochHolder
}

func (w *Worker) epoch() string {
	if w.EpochHolder != nil {
		return w.EpochHolder.Get()
	}
	return w.Epoch
}

// emitOne picks an op, builds the key(s), mints a version (HINCRBY), records it
// into srcmax:<epoch> (hmax via HSET-max), and queues the XADD onto pipe. Returns
// the primary kv_key and version used. Mint + srcmax happen eagerly (they must
// precede the XADD on the wire); only the XADD is pipelined.
func (w *Worker) emitOne(ctx context.Context, pipe redis.Pipeliner) (string, int64, error) {
	epoch := w.epoch()
	pat := Patterns[w.Counters.Sent.Load()%int64(len(Patterns))]
	id := w.pickID()
	op := w.Ops.Pick()
	nowMs := time.Now().UnixMilli()
	eid := newEventID()
	pad := makePad(w.PayloadBytes)

	switch op {
	case OpRename:
		oldKey := pat.Key("standby", epoch, id)
		newKey := pat.Key("active", epoch, id)
		ver, err := w.Minter.NextGlobal(ctx)
		if err != nil {
			return "", 0, err
		}
		if err := w.recordSrcmax(ctx, epoch, newKey, ver); err != nil {
			return "", 0, err
		}
		if err := w.recordSrcmax(ctx, epoch, oldKey, ver); err != nil {
			return "", 0, err
		}
		val := payloadJSON(eid, nowMs, ver, pad)
		pipe.XAdd(ctx, &redis.XAddArgs{
			Stream: w.StreamKey, MaxLen: w.StreamMaxLen, Approx: true,
			Values: map[string]any{
				"value": val, "event_id": eid, "key": newKey, "old_key": oldKey,
				"new_key": newKey, "op": string(op), "pattern": pat.Domain,
				"t_send_ms": nowMs, "version": ver,
			},
		})
		return newKey, ver, nil
	default: // set | delete
		key := pat.Key("active", epoch, id)
		ver, err := w.Minter.NextPerKey(ctx, key)
		if err != nil {
			return "", 0, err
		}
		if err := w.recordSrcmax(ctx, epoch, key, ver); err != nil {
			return "", 0, err
		}
		val := ""
		if op == OpSet {
			val = payloadJSON(eid, nowMs, ver, pad)
		}
		pipe.XAdd(ctx, &redis.XAddArgs{
			Stream: w.StreamKey, MaxLen: w.StreamMaxLen, Approx: true,
			Values: map[string]any{
				"value": val, "event_id": eid, "key": key, "op": string(op),
				"pattern": pat.Domain, "t_send_ms": nowMs, "version": ver,
			},
		})
		return key, ver, nil
	}
}

func (w *Worker) pickID() int64 {
	// Shared keyspace: every worker draws from [0, KeySpaceSize) so writers contend
	// on the same keys (the multi-writer-same-key scenario).
	return int64(w.Counters.Sent.Load()) % w.KeySpaceSize
}

func (w *Worker) recordSrcmax(ctx context.Context, epoch, key string, ver int64) error {
	return w.RDB.Eval(ctx, hmaxScript, []string{"srcmax:" + epoch}, key, ver).Err()
}

func (w *Worker) Run(ctx context.Context) {
	for {
		rate := int(w.Lim.Current())
		depth := w.PipelineDepth
		if rate > 0 {
			if perTenth := rate / 10; perTenth >= 1 && perTenth < depth {
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
		if w.epoch() == "" {
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
			if _, _, err := w.emitOne(ctx, pipe); err != nil {
				if ctx.Err() == nil {
					log.Printf("worker %d: emit error: %v", w.ID, err)
				}
				w.Counters.Errors.Add(1)
				continue
			}
			w.Counters.Sent.Add(1)
			n++
		}
		_, err = pipe.Exec(ctx)
		w.Counters.Inflight.Add(-1)
		if err != nil {
			w.Counters.Errors.Add(int64(n))
			if ctx.Err() == nil {
				log.Printf("worker %d: pipeline error: %v", w.ID, err)
			}
		}
	}
}
