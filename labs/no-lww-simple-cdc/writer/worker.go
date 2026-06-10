// $LAB/writer/worker.go
package main

import (
	"context"
	"log"
	"math/rand"
	"time"

	"github.com/redis/go-redis/v9"
)

// OpMix is the weighted op distribution (weights need not sum to 100).
type OpMix struct{ Create, Update, Delete, Rename int }

func (m OpMix) total() int { return m.Create + m.Update + m.Delete + m.Rename }

// Valid reports whether the mix is usable: no negative weight and at least one
// op has positive weight (otherwise pick would have nothing to choose).
func (m OpMix) Valid() bool {
	if m.Create < 0 || m.Update < 0 || m.Delete < 0 || m.Rename < 0 {
		return false
	}
	return m.total() > 0
}

// pick maps an arbitrary counter n into an op deterministically by weight.
func (m OpMix) pick(n uint64) string {
	t := m.total()
	if t <= 0 {
		return "update"
	}
	r := int(n % uint64(t))
	if r < m.Create {
		return "create"
	}
	r -= m.Create
	if r < m.Update {
		return "update"
	}
	r -= m.Update
	if r < m.Delete {
		return "delete"
	}
	return "rename"
}

type Worker struct {
	ID            int
	RDB           *redis.Client // central Redis (KV + app.events stream)
	StreamKey     string
	StreamMaxLen  int64
	PipelineDepth int
	PayloadBytes  int
	KeySpaceSize  int64
	Mix           OpMix
	Lim           *Limiter
	Counters      *Counters
	State         *RunState
	rng           *rand.Rand
}

// buildEvent picks an op and a key (any key in [0,KeySpaceSize) across a random
// pattern — multiple workers may collide on the same key, which is allowed).
func (w *Worker) buildEvent(seq uint64) Event {
	p := Patterns[w.rng.Intn(len(Patterns))]
	id := w.rng.Int63n(w.KeySpaceSize)
	switch w.Mix.pick(seq) {
	case "create":
		return NewCreateEvent(p.ActiveKey(id), w.PayloadBytes)
	case "update":
		return NewUpdateEvent(p.ActiveKey(id), w.PayloadBytes)
	case "delete":
		return NewDeleteEvent(p.ActiveKey(id))
	default: // rename: company uses standby->active; others active(id)->active(id+offset)
		if p.HasStandby() {
			return NewRenameEvent(p.StandbyKey(id), p.ActiveKey(id), w.PayloadBytes)
		}
		other := (id + 1) % w.KeySpaceSize
		return NewRenameEvent(p.ActiveKey(id), p.ActiveKey(other), w.PayloadBytes)
	}
}

// applyCentral applies the op to the central KV (the authoritative intent of
// record) within the same pipeline as the XADD (dual write; not atomic — that
// looseness is part of the no-LWW story).
func applyCentral(pipe redis.Pipeliner, ctx context.Context, e Event) {
	switch e.Op {
	case "create", "update":
		pipe.Set(ctx, e.KvKey, e.Body, 0)
	case "delete":
		pipe.Del(ctx, e.KvKey)
	case "rename":
		pipe.Del(ctx, e.OldKey)
		pipe.Set(ctx, e.NewKey, e.Body, 0)
	}
}

func (w *Worker) Run(ctx context.Context) {
	if w.rng == nil {
		w.rng = rand.New(rand.NewSource(int64(w.ID)*7919 + time.Now().UnixNano()))
	}
	var seq uint64
	for {
		depth := w.PipelineDepth
		if rate := int(w.Lim.Current()); rate > 0 && rate/10 < depth {
			if d := rate / 10; d >= 1 {
				depth = d
			}
		}
		waitCtx, cancel := context.WithTimeout(ctx, 500*time.Millisecond)
		err := w.Lim.WaitN(waitCtx, depth)
		cancel()
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			continue
		}
		if w.State.Epoch() == "" {
			select {
			case <-ctx.Done():
				return
			case <-time.After(100 * time.Millisecond):
			}
			continue
		}

		w.Counters.Inflight.Add(1)
		pipe := w.RDB.Pipeline()
		batch := make([]Event, 0, depth)
		for i := 0; i < depth; i++ {
			e := w.buildEvent(seq)
			seq++
			applyCentral(pipe, ctx, e)
			pipe.XAdd(ctx, &redis.XAddArgs{
				Stream: w.StreamKey,
				MaxLen: w.StreamMaxLen,
				Approx: true,
				Values: e.StreamValues(),
			})
			batch = append(batch, e)
		}
		_, err = pipe.Exec(ctx)
		w.Counters.Inflight.Add(-1)
		if err != nil {
			w.Counters.Errors.Add(int64(len(batch)))
			if ctx.Err() == nil {
				log.Printf("worker %d: pipeline error: %v", w.ID, err)
			}
			continue
		}
		w.Counters.Sent.Add(int64(len(batch)))
		for _, e := range batch {
			w.Counters.bump(e.Op)
			if e.Op == "rename" {
				w.State.RecordKeys(e.Op, e.OldKey, e.NewKey)
			} else {
				w.State.RecordKeys(e.Op, e.KvKey)
			}
		}
	}
}
