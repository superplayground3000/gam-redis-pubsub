// $LAB/verifier/checks.go
package verifier

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

	// Body-less rename (production shape): the sink RENAMEs region[ka]→region[kb],
	// so kb inherits ka's current region value (v2 from the update above).
	if err = c.emit(ctx, map[string]string{"event_id": "vr-" + epoch, "op": "rename", "old_key": ka, "new_key": kb}); err != nil {
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
// swallow the second). The guarded RENAME is idempotent — the second delivery
// finds old_key already gone (EXISTS=0 → no-op) → terminal state stable.
func (c *Checks) Replay(ctx context.Context, epoch string) (ok bool, err error) {
	base := fmt.Sprintf("lb:general:active:{verify-%s-rep}", epoch)
	kc, kd := base+":c", base+":d"
	body := `{"v":9}`
	if err = c.emit(ctx, map[string]string{"event_id": "vrc-" + epoch, "op": "create", "kv_key": kc, "body": body}); err != nil {
		return
	}
	if err = c.emit(ctx, map[string]string{"event_id": "vrr1-" + epoch, "op": "rename", "old_key": kc, "new_key": kd}); err != nil {
		return
	}
	if err = c.emit(ctx, map[string]string{"event_id": "vrr2-" + epoch, "op": "rename", "old_key": kc, "new_key": kd}); err != nil {
		return
	}
	// kd inherits kc's value (body) via the first RENAME; the second is a no-op.
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

// RenameParity reproduces the writer's authoritative dual write for a rename and
// asserts central and region converge to the SAME value. It guards against the
// sink's value-preserving RENAME drifting from the central apply: old_key is given
// a value that is NOT re-sent in the (body-less) rename event, so any regression to
// a body-copying apply on either side would leave central[new] != region[new].
func (c *Checks) RenameParity(ctx context.Context, epoch string) (ok bool, err error) {
	base := fmt.Sprintf("lb:general:active:{verify-%s-par}", epoch)
	ka, kb := base+":a", base+":b"
	valOld := `{"rename_parity":"old-value"}`

	// 1) create old_key. Authoritative central-apply == direct Set (mimics the
	//    writer); the emitted create event makes the sink populate region[old_key].
	if err = c.Central.Set(ctx, ka, valOld); err != nil {
		return
	}
	if err = c.emit(ctx, map[string]string{"event_id": "vpc-" + epoch, "op": "create", "kv_key": ka, "body": valOld}); err != nil {
		return
	}

	// 2) rename old→new. Authoritative central-apply == value-preserving RENAME
	//    (mimics the writer); the emitted body-less rename makes the sink RENAME region.
	if err = c.Central.RenamePreserve(ctx, ka, kb); err != nil {
		return
	}
	if err = c.emit(ctx, map[string]string{"event_id": "vpr-" + epoch, "op": "rename", "old_key": ka, "new_key": kb}); err != nil {
		return
	}

	// 3) central and region must agree on new_key (== the preserved old value), and
	//    old_key must be gone on both sides.
	cv, cok, e := c.Central.GetString(ctx, kb)
	if e != nil {
		err = e
		return
	}
	rv, rok, e := c.Region.GetString(ctx, kb)
	if e != nil {
		err = e
		return
	}
	_, kaCentralEx, e := c.Central.GetString(ctx, ka)
	if e != nil {
		err = e
		return
	}
	rAbsent, e := c.regionAbsent(ctx, ka)
	if e != nil {
		err = e
		return
	}
	ok = cok && rok && cv == rv && cv == valOld && !kaCentralEx && rAbsent
	return
}

// HashOps exercises the hash path end-to-end. Like RenameParity, it reproduces
// the writer's authoritative CENTRAL apply (the verifier's emitted events bypass
// the writer) and asserts the sink's REGION apply converges with it:
//   create -> central HSET + emit -> central==region=={fields}
//   update -> central HSET merge + emit -> central==region=={merged superset}
//   delete -> central DEL + emit -> gone on both sides
func (c *Checks) HashOps(ctx context.Context, epoch string) (ok bool, err error) {
	key := fmt.Sprintf("lb:hash:active:{verify-%s-h}", epoch)

	f1 := map[string]string{"name": "alice", "tier": "free"}
	if err = c.Central.SetHash(ctx, key, f1); err != nil {
		return
	}
	if err = c.emit(ctx, map[string]string{
		"event_id": "vhc-" + epoch, "op": "create", "type": "hash", "kv_key": key,
		"body": `{"name":"alice","tier":"free"}`,
	}); err != nil {
		return
	}
	if ok, err = c.hashParity(ctx, key, f1); err != nil || !ok {
		return
	}

	// Merge update: overwrite tier, add region; name must persist (merge).
	if err = c.Central.SetHash(ctx, key, map[string]string{"tier": "pro", "region": "apac"}); err != nil {
		return
	}
	if err = c.emit(ctx, map[string]string{
		"event_id": "vhu-" + epoch, "op": "update", "type": "hash", "kv_key": key,
		"body": `{"tier":"pro","region":"apac"}`,
	}); err != nil {
		return
	}
	want := map[string]string{"name": "alice", "tier": "pro", "region": "apac"}
	if ok, err = c.hashParity(ctx, key, want); err != nil || !ok {
		return
	}

	// Delete removes the whole hash on both sides.
	if err = c.Central.Del(ctx, key); err != nil {
		return
	}
	if err = c.emit(ctx, map[string]string{
		"event_id": "vhd-" + epoch, "op": "delete", "type": "hash", "kv_key": key,
	}); err != nil {
		return
	}
	_, cEx, e := c.Central.GetHash(ctx, key)
	if e != nil {
		err = e
		return
	}
	_, rEx, e := c.Region.GetHash(ctx, key)
	if e != nil {
		err = e
		return
	}
	ok = !cEx && !rEx
	return
}

// hashParity asserts central AND region both hold exactly want.
func (c *Checks) hashParity(ctx context.Context, key string, want map[string]string) (bool, error) {
	cv, _, err := c.Central.GetHash(ctx, key)
	if err != nil {
		return false, err
	}
	rv, _, err := c.Region.GetHash(ctx, key)
	if err != nil {
		return false, err
	}
	return mapsEqual(cv, want) && mapsEqual(rv, want), nil
}

func mapsEqual(a, b map[string]string) bool {
	if len(a) != len(b) {
		return false
	}
	for k, v := range a {
		bv, ok := b[k]
		if !ok || bv != v {
			return false
		}
	}
	return true
}
