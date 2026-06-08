package main

import (
	"context"
	"log"
	"strconv"
	"sync/atomic"

	"github.com/redis/go-redis/v9"
)

// Sweeper reaps tombstones (deleted=1) older than HorizonMs. Physical DEL only
// after the horizon so a very-late stale write cannot resurrect a key the fence
// already tombstoned (design-doc §7 GC).
//
// Reaped/Tombstones/OldestAgeMs are read concurrently by the /metrics HTTP
// handler while SweepOnce writes them, so they are atomic.
type Sweeper struct {
	RDB         *redis.Client
	HorizonMs   int64
	ScanCount   int64
	Reaped      atomic.Int64
	Tombstones  atomic.Int64
	OldestAgeMs atomic.Int64
}

// SweepOnce scans the keyspace once and DELs eligible tombstones, using `now` (ms)
// as the clock. Returns the number reaped.
func (s *Sweeper) SweepOnce(ctx context.Context, now int64) (int64, error) {
	var cursor uint64
	var reaped, tombstones, oldest int64
	for {
		keys, next, err := s.RDB.Scan(ctx, cursor, "*", s.ScanCount).Result()
		if err != nil {
			return reaped, err
		}
		for _, k := range keys {
			vals, err := s.RDB.HMGet(ctx, k, "deleted", "deleted_at").Result()
			if err != nil || len(vals) != 2 || vals[0] != "1" {
				continue
			}
			tombstones++
			raw, ok := vals[1].(string)
			if !ok {
				// deleted_at field absent — HMGet yields nil for a missing field.
				log.Printf("gc: tombstone %s has missing deleted_at; skipping reap", k)
				continue
			}
			da, perr := strconv.ParseInt(raw, 10, 64)
			if perr != nil {
				// Partial-write tombstone: deleted=1 but deleted_at non-numeric.
				// Never reap — we cannot prove it is past the horizon, and a bogus
				// da=0 would otherwise resurrect a fenced key.
				log.Printf("gc: tombstone %s has corrupt deleted_at (%v); skipping reap", k, vals[1])
				continue
			}
			if age := now - da; age > oldest {
				oldest = age
			}
			if now-da > s.HorizonMs {
				if err := s.RDB.Del(ctx, k).Err(); err == nil {
					reaped++
				}
			}
		}
		cursor = next
		if cursor == 0 {
			break
		}
	}
	s.Reaped.Add(reaped)
	s.Tombstones.Store(tombstones)
	s.OldestAgeMs.Store(oldest)
	return reaped, nil
}
