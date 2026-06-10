// $LAB/verifier/redis.go
package main

import (
	"context"
	"strconv"
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

// GroupLag returns unread entries for a consumer group on a stream (0 if the
// stream or group does not exist yet).
func (c *RedisClient) GroupLag(ctx context.Context, stream, group string) (int64, error) {
	groups, err := c.rdb.XInfoGroups(ctx, stream).Result()
	if err != nil {
		return 0, nil // stream absent → nothing pending
	}
	for _, g := range groups {
		if g.Name == group {
			return g.Lag, nil
		}
	}
	return 0, nil
}
