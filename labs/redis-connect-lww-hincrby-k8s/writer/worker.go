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

// emitOne picks an op, builds the key(s), mints a version (HINCRBY), and QUEUES
// both the srcmax record (hmax EVAL) and the XADD onto pipe. Returns the primary
// kv_key and version used.
//
// Atomicity: the HINCRBY mint is eager (a minted-but-unpublished version just
// leaves a harmless gap in kv:ver — the verifier's fence compares with > only, so
// gaps are fine). The srcmax record and the XADD are BOTH queued onto the same
// pipeliner; when Run Exec's it as a MULTI/EXEC, they commit together. A failed
// Exec applies NEITHER, so srcmax never claims a version that wasn't published —
// which would otherwise be a permanent false mismatch in CompareSrcMax.
//
// /reset race: epoch is read ONCE here so this event is internally consistent —
// its key and its srcmax entry use the same epoch. A late old-epoch event that is
// published after a /reset lands in srcmax:<old-epoch> under an old-epoch key,
// which the verifier (reading srcmax:<new-epoch>) never inspects. Epoch-in-key
// isolation thus makes the reset race benign with no extra synchronization.
func (w *Worker) emitOne(ctx context.Context, pipe redis.Pipeliner) (string, int64, error) {
	epoch := w.epoch()
	pat := Patterns[w.Counters.Sent.Load()%int64(len(Patterns))]
	id := w.pickID()
	op := w.Ops.Pick()
	nowMs := time.Now().UnixMilli()
	eid := newEventID()
	pad := makePad(w.PayloadBytes)

	// Single per-entity counter: every op (set, delete, rename) on this entity mints
	// from kv:ver <ent>, so all versions for the entity are one comparable monotonic
	// sequence. This is what makes set-after-rename win the sink CAS instead of being
	// rejected as stale across two incomparable number spaces (the version flaw).
	ent := pat.EntityID(epoch, id)
	ver, err := w.Minter.NextForEntity(ctx, ent)
	if err != nil {
		return "", 0, err
	}

	switch op {
	case OpRename:
		oldKey := pat.Key("standby", epoch, id)
		newKey := pat.Key("active", epoch, id)
		// Record srcmax for the ACTIVE (new) key ONLY. The standby is intentionally
		// not tracked: a rename's win is decided by lww_rename.lua's CAS gate on the
		// ACTIVE key, so whether the standby tombstone actually applied depends on an
		// outcome the producer cannot predict at mint time. If a later set (higher
		// version) beats this rename on the active key, the rename is correctly
		// rejected and the standby is never tombstoned — but srcmax[standby]=<renameVer>
		// would then exceed region[standby].ver, a FALSE mismatch. In the sweep
		// workload the standby is only ever a tombstone target (set/delete target
		// active), so it has no producer-knowable authoritative max to verify; its
		// tombstone semantics are covered deterministically by scripts/proof-rename.sh.
		w.queueSrcmax(ctx, pipe, epoch, newKey, ver)
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
		w.queueSrcmax(ctx, pipe, epoch, key, ver)
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

// queueSrcmax queues the hmax (HSET-to-max) EVAL onto pipe so it commits in the
// same MULTI/EXEC as the XADD — see emitOne's atomicity note.
func (w *Worker) queueSrcmax(ctx context.Context, pipe redis.Pipeliner, epoch, key string, ver int64) {
	pipe.Eval(ctx, hmaxScript, []string{"srcmax:" + epoch}, key, ver)
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
		// TxPipeline => MULTI/EXEC: every event's XADD + srcmax EVAL in this batch
		// commit atomically, so a failed Exec applies none of them (srcmax never
		// outruns the published stream).
		pipe := w.RDB.TxPipeline()
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
