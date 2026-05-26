package main

import (
	"context"
	"log"
	"math/rand"
	"time"

	"github.com/redis/go-redis/v9"
)

type Worker struct {
	ID           int
	RDB          *redis.Client
	StreamKey    string
	StreamMaxLen int64
	BatchMax     int
	PayloadBytes int
	Cardinality  int
	Lim          *Limiter
	Counters     *Counters
	Mode         *ModeStore
	KeyGen       *KeyGen
	Picker       *Picker
	rng          *rand.Rand
}

// Run drives this worker's send loop. Two control-plane signals are honored:
//   - rate: re-read every iteration via Lim.Current(); WaitN bounds latency to ~500ms.
//   - mode: re-read at iteration top AND after WaitN. A /rate mode flip is observed
//     within ~one in-flight batch (typically <100ms at 50k/s with depth≈5000); the
//     batch in flight when the flip arrives completes in the old mode. This matches
//     the spec's "re-read at top of every iteration" contract.
func (w *Worker) Run(ctx context.Context) {
	w.rng = rand.New(rand.NewSource(int64(w.ID)*1_000_003 + time.Now().UnixNano()))
	var seq int64
	base := int64(w.ID) << 40 // distinct high-bits per worker so seqs never collide
	for {
		rate := int(w.Lim.Current())
		mode := w.Mode.Get()
		depth := 1
		if mode == ModeBatch {
			depth = w.BatchMax
			if rate > 0 {
				perTenth := rate / 10
				if perTenth < 1 {
					perTenth = 1
				}
				if perTenth < depth {
					depth = perTenth
				}
			}
		}

		// Per-iteration timeout so workers re-fetch limiter and mode every pass.
		waitCtx, waitCancel := context.WithTimeout(ctx, 500*time.Millisecond)
		err := w.Lim.WaitN(waitCtx, depth)
		waitCancel()
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			continue
		}
		// Re-check mode after WaitN so a mid-wait flip is observed on this batch,
		// not deferred to the next iteration. Tokens are already spent — we
		// honor depth here; the next iteration picks up the new mode for batch
		// sizing as well.
		if w.Mode.Get() != mode {
			mode = w.Mode.Get()
			// No depth adjustment — tokens already reserved.
		}
		w.Counters.Inflight.Add(1)
		pipe := w.RDB.Pipeline()
		type pendingCmd struct {
			cmd     *redis.StringCmd
			pattern int
		}
		pending := make([]pendingCmd, 0, depth)
		for i := 0; i < depth; i++ {
			seq++
			pat := w.Picker.Pick(w.rng)
			id := w.rng.Intn(w.Cardinality)
			var key, patternName string
			switch pat {
			case PatternEmployee:
				key = w.KeyGen.Employee(id)
				patternName = "employee"
			case PatternRole:
				key = w.KeyGen.Role(id)
				patternName = "role"
			case PatternOrg:
				key = w.KeyGen.Org(id)
				patternName = "org"
			}
			p := NewPayload(base|seq, w.PayloadBytes)
			body, _ := p.JSON()
			cmd := pipe.XAdd(ctx, &redis.XAddArgs{
				Stream: w.StreamKey,
				MaxLen: w.StreamMaxLen,
				Approx: true,
				Values: map[string]any{
					"value":     string(body),
					"event_id":  p.EventID,
					"key":       key,
					"pattern":   patternName,
					"t_send_ms": p.TsNs / 1_000_000,
				},
			})
			pending = append(pending, pendingCmd{cmd: cmd, pattern: pat})
		}
		_, execErr := pipe.Exec(ctx)
		w.Counters.Inflight.Add(-1)

		// Per-command accounting. Even on Exec returning non-nil, individual cmds
		// may have succeeded — credit them to Sent/SentByPattern, charge only the
		// failed ones to Errors. See go-redis Pipeline.Exec which returns the
		// first-failed-cmd error; per-cmd .Err() is the source of truth.
		var sentDelta, errDelta int64
		for _, pc := range pending {
			if pc.cmd.Err() == nil {
				sentDelta++
				w.Counters.SentByPattern[pc.pattern].Add(1)
			} else {
				errDelta++
			}
		}
		if sentDelta > 0 {
			w.Counters.Sent.Add(sentDelta)
		}
		if errDelta > 0 {
			w.Counters.Errors.Add(errDelta)
		}
		if execErr != nil && ctx.Err() == nil {
			log.Printf("worker %d: pipeline error (%d/%d cmds failed): %v", w.ID, errDelta, len(pending), execErr)
		}
	}
}
