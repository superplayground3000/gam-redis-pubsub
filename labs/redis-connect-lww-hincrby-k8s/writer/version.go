package main

import (
	"context"

	"github.com/redis/go-redis/v9"
)

// Minter mints monotonic versions on the SOURCE Redis via HINCRBY — the shared
// atomic counter that makes multi-writer-same-key safe (design-doc §6). There is
// NO in-process counter: every version is minted by Redis, so concurrent writers
// on one key always get strictly-increasing, collision-free versions.
type Minter struct{ RDB *redis.Client }

func NewMinter(rdb *redis.Client) *Minter { return &Minter{RDB: rdb} }

// NextPerKey mints the next version for kv_key: HINCRBY kv:ver <kv_key> 1.
func (m *Minter) NextPerKey(ctx context.Context, kvKey string) (int64, error) {
	return m.RDB.HIncrBy(ctx, "kv:ver", kvKey, 1).Result()
}

// NextGlobal mints the next global version (rename must dominate two key
// sequences): HINCRBY kv:gver global 1.
func (m *Minter) NextGlobal(ctx context.Context) (int64, error) {
	return m.RDB.HIncrBy(ctx, "kv:gver", "global", 1).Result()
}
