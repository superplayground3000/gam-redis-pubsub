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
		w.Counters.Inflight.Add(1)
		pipe := w.RDB.Pipeline()
		patternsThisBatch := make([]int, 0, depth)
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
			pipe.XAdd(ctx, &redis.XAddArgs{
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
			patternsThisBatch = append(patternsThisBatch, pat)
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
			for _, pat := range patternsThisBatch {
				w.Counters.SentByPattern[pat].Add(1)
			}
		}
	}
}
