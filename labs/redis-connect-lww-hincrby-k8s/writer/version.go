package main

import (
	"context"

	"github.com/redis/go-redis/v9"
)

// Minter mints monotonic versions on the SOURCE Redis via HINCRBY — the shared
// atomic counter that makes multi-writer-same-key safe (design-doc §6). There is
// NO in-process counter: every version is minted by Redis, so concurrent writers
// on one entity always get strictly-increasing, collision-free versions.
type Minter struct{ RDB *redis.Client }

func NewMinter(rdb *redis.Client) *Minter { return &Minter{RDB: rdb} }

// NextForEntity mints the next version for an entity: HINCRBY kv:ver <entityID> 1.
// ALL ops (set, delete, rename) on a given entity mint from this SINGLE counter,
// so their versions form one comparable, monotonic sequence — a rename outranks
// every prior write to the entity, and a later set outranks the rename, so the
// sink's numeric CAS resolves set-after-rename correctly (design-decision-tree §9).
func (m *Minter) NextForEntity(ctx context.Context, entityID string) (int64, error) {
	return m.RDB.HIncrBy(ctx, "kv:ver", entityID, 1).Result()
}
