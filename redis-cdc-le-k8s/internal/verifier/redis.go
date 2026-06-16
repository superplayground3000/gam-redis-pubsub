// $LAB/verifier/redis.go
package verifier

import (
	"context"
	"strconv"
	"strings"
	"time"

	"github.com/redis/go-redis/v9"
)

type RedisClient struct{ rdb *redis.Client }

func NewRedisClient(addr string) *RedisClient {
	return &RedisClient{rdb: redis.NewClient(&redis.Options{Addr: addr})}
}
func (c *RedisClient) Close() error { return c.rdb.Close() }

// eventValues builds the ordered XADD field slice for a CDC event from a map.
// Always emits the full field set so the source pipeline metadata is consistent.
func eventValues(f map[string]string) []any {
	get := func(k string) string { return f[k] }
	return []any{
		"event_id", get("event_id"),
		"op", get("op"),
		"kv_key", get("kv_key"),
		"old_key", get("old_key"),
		"new_key", get("new_key"),
		"ts", get("ts"),
		"body", get("body"),
	}
}

// XAddEvent appends one CDC event to the central app.events stream.
func (c *RedisClient) XAddEvent(ctx context.Context, stream string, f map[string]string) error {
	if f["ts"] == "" {
		f["ts"] = strconv.FormatInt(time.Now().UnixMilli(), 10)
	}
	return c.rdb.XAdd(ctx, &redis.XAddArgs{Stream: stream, Values: eventValues(f)}).Err()
}

// GetString returns (value, exists).
func (c *RedisClient) GetString(ctx context.Context, key string) (string, bool, error) {
	v, err := c.rdb.Get(ctx, key).Result()
	if err == redis.Nil {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	return v, true, nil
}

// Set writes a string value (no expiry). Used by RenameParity to reproduce the
// writer's authoritative central-apply for create/update without running the writer.
func (c *RedisClient) Set(ctx context.Context, key, val string) error {
	return c.rdb.Set(ctx, key, val, 0).Err()
}

// renamePreserveScript MUST stay identical to chart/files/connect/cdc_rename.lua
// (the sink) and writer.renamePreserveScript: value-preserving, EXISTS-guarded so
// a missing old_key is a no-op rather than a "no such key" error.
const renamePreserveScript = `if redis.call('EXISTS', KEYS[1]) == 1 then
  redis.call('RENAME', KEYS[1], KEYS[2])
end
return 1`

// RenamePreserve applies the writer's authoritative value-preserving rename to KV,
// so the verifier can reproduce the central side of the dual write and assert it
// converges with the region (which the sink renames the same way).
func (c *RedisClient) RenamePreserve(ctx context.Context, oldKey, newKey string) error {
	return c.rdb.Eval(ctx, renamePreserveScript, []string{oldKey, newKey}).Err()
}

// GroupLag returns unread entries for a consumer group on a stream (0 if the
// stream or group does not exist yet).
func (c *RedisClient) GroupLag(ctx context.Context, stream, group string) (int64, error) {
	groups, err := c.rdb.XInfoGroups(ctx, stream).Result()
	if err != nil {
		// Only a missing stream means "nothing pending yet"; any other error must
		// propagate so WaitQuiescent fails closed (keeps waiting / times out) rather
		// than falsely reporting quiescence.
		if strings.Contains(strings.ToLower(err.Error()), "no such key") {
			return 0, nil
		}
		return 0, err
	}
	for _, g := range groups {
		if g.Name == group {
			return g.Lag, nil
		}
	}
	return 0, nil // stream exists but group not created yet
}

// GroupBacklog returns the consumer group's lag (entries added but not yet
// delivered) AND pending (entries delivered but not yet ACKed — the PEL depth).
// True source quiescence requires BOTH to be 0: `lag` alone drops to 0 the moment
// an entry is delivered to the consumer's PEL, well before the source connect pod
// has processed/published/ACKed it — so checking only lag reports quiescence while
// the source is still in flight. Fails closed (propagates errors) except a missing
// stream.
func (c *RedisClient) GroupBacklog(ctx context.Context, stream, group string) (lag, pending int64, err error) {
	groups, err := c.rdb.XInfoGroups(ctx, stream).Result()
	if err != nil {
		if strings.Contains(strings.ToLower(err.Error()), "no such key") {
			return 0, 0, nil
		}
		return 0, 0, err
	}
	for _, g := range groups {
		if g.Name == group {
			return g.Lag, g.Pending, nil
		}
	}
	return 0, 0, nil // stream exists but group not created yet
}
