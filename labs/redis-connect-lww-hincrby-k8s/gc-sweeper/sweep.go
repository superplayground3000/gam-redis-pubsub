package main

import (
	"context"
	"strconv"

	"github.com/redis/go-redis/v9"
)

// Sweeper reaps tombstones (deleted=1) older than HorizonMs. Physical DEL only
// after the horizon so a very-late stale write cannot resurrect a key the fence
// already tombstoned (design-doc §7 GC).
type Sweeper struct {
	RDB         *redis.Client
	HorizonMs   int64
	ScanCount   int64
	Reaped      int64
	Tombstones  int64
	OldestAgeMs int64
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
			da, _ := strconv.ParseInt(toS(vals[1]), 10, 64)
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
	s.Reaped += reaped
	s.Tombstones = tombstones
	s.OldestAgeMs = oldest
	return reaped, nil
}

func toS(v any) string {
	if s, ok := v.(string); ok {
		return s
	}
	return "0"
}
