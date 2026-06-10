// $LAB/verifier/checks.go
package main

import (
	"context"
	"fmt"
	"time"
)

// renameKeys returns two keys sharing one hash tag (same Redis slot) for the
// rename/replay checks: lb:general:active:{verify-<epoch>}:a / :b
func renameKeys(epoch string) (string, string) {
	base := fmt.Sprintf("lb:general:active:{verify-%s}", epoch)
	return base + ":a", base + ":b"
}

type Checks struct {
	Central     *RedisClient
	Region      *RedisClient
	NatsURL     string
	Stream      string
	SourceGroup string
	Quiesce     time.Duration
}

func (c *Checks) quiesce(ctx context.Context) bool {
	return WaitQuiescent(ctx, c.Central, c.SourceGroup, c.NatsURL, c.Stream, c.Quiesce)
}

// Dedup: XADD the same event_id 5x; after the source drains, JetStream Messages
// must have grown by exactly 1 (dedup within the duplicate window).
//
// Accepted assumptions for the delta==1 assertion (true for this lab's controlled
// run): the stream is otherwise idle — the writer is paused and Dedup runs first,
// so no other events inflate before/after; and JetStream `limits` retention
// (1h / 256MB) will not evict the message during the few-second check, so Messages
// only moves due to this op.
func (c *Checks) Dedup(ctx context.Context, epoch string) (delta int64, ok bool, err error) {
	before, err := ScrapeJSZ(ctx, c.NatsURL, c.Stream)
	if err != nil {
		return 0, false, err
	}
	eid := "verify-dup-" + epoch
	key := fmt.Sprintf("lb:general:active:{verify-%s-dup}", epoch)
	for i := 0; i < 5; i++ {
		if err := c.Central.XAddEvent(ctx, "app.events", map[string]string{
			"event_id": eid, "op": "update", "kv_key": key, "body": `{"dup":true}`,
		}); err != nil {
			return 0, false, err
		}
	}
	if !c.quiesce(ctx) {
		return 0, false, fmt.Errorf("dedup: pipeline did not quiesce")
	}
	after, err := ScrapeJSZ(ctx, c.NatsURL, c.Stream)
	if err != nil {
		return 0, false, err
	}
	delta = after.Messages - before.Messages
	return delta, delta == 1, nil
}

// emit one event and wait for quiescence.
func (c *Checks) emit(ctx context.Context, f map[string]string) error {
	if err := c.Central.XAddEvent(ctx, "app.events", f); err != nil {
		return err
	}
	if !c.quiesce(ctx) {
		return fmt.Errorf("op %s: pipeline did not quiesce", f["op"])
	}
	return nil
}

func (c *Checks) regionEquals(ctx context.Context, key, want string) (bool, error) {
	got, ok, err := c.Region.GetString(ctx, key)
	if err != nil {
		return false, err
	}
	return ok && got == want, nil
}

func (c *Checks) regionAbsent(ctx context.Context, key string) (bool, error) {
	_, ok, err := c.Region.GetString(ctx, key)
	if err != nil {
		return false, err
	}
	return !ok, nil
}

// PerOp: create→update→rename→delete, one op at a time, asserting region after
// each quiesced step. Order-insensitive: there is no concurrency in flight.
func (c *Checks) PerOp(ctx context.Context, epoch string) (createOK, updateOK, renameOK, deleteOK bool, err error) {
	ka, kb := renameKeys(epoch)
	v1, v2 := `{"v":1}`, `{"v":2}`

	if err = c.emit(ctx, map[string]string{"event_id": "vc-" + epoch, "op": "create", "kv_key": ka, "body": v1}); err != nil {
		return
	}
	if createOK, err = c.regionEquals(ctx, ka, v1); err != nil {
		return
	}

	if err = c.emit(ctx, map[string]string{"event_id": "vu-" + epoch, "op": "update", "kv_key": ka, "body": v2}); err != nil {
		return
	}
	if updateOK, err = c.regionEquals(ctx, ka, v2); err != nil {
		return
	}

	if err = c.emit(ctx, map[string]string{"event_id": "vr-" + epoch, "op": "rename", "old_key": ka, "new_key": kb, "body": v2}); err != nil {
		return
	}
	oldGone, e := c.regionAbsent(ctx, ka)
	if e != nil {
		err = e
		return
	}
	newThere, e := c.regionEquals(ctx, kb, v2)
	if e != nil {
		err = e
		return
	}
	renameOK = oldGone && newThere

	if err = c.emit(ctx, map[string]string{"event_id": "vd-" + epoch, "op": "delete", "kv_key": kb}); err != nil {
		return
	}
	deleteOK, err = c.regionAbsent(ctx, kb)
	return
}

// Replay: apply the same rename twice (distinct event_ids so dedup does not
// swallow the second). DEL old + SET new is idempotent → terminal state stable.
func (c *Checks) Replay(ctx context.Context, epoch string) (ok bool, err error) {
	base := fmt.Sprintf("lb:general:active:{verify-%s-rep}", epoch)
	kc, kd := base+":c", base+":d"
	body := `{"v":9}`
	if err = c.emit(ctx, map[string]string{"event_id": "vrc-" + epoch, "op": "create", "kv_key": kc, "body": body}); err != nil {
		return
	}
	if err = c.emit(ctx, map[string]string{"event_id": "vrr1-" + epoch, "op": "rename", "old_key": kc, "new_key": kd, "body": body}); err != nil {
		return
	}
	if err = c.emit(ctx, map[string]string{"event_id": "vrr2-" + epoch, "op": "rename", "old_key": kc, "new_key": kd, "body": body}); err != nil {
		return
	}
	newThere, e := c.regionEquals(ctx, kd, body)
	if e != nil {
		err = e
		return
	}
	oldGone, e := c.regionAbsent(ctx, kc)
	if e != nil {
		err = e
		return
	}
	ok = newThere && oldGone
	return
}
