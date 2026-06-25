package main

import (
	"context"
	"strconv"

	"github.com/redis/go-redis/v9"
)

type sinkReader struct{ rdb *redis.Client }

func newSinkReader(addr string) *sinkReader {
	return &sinkReader{rdb: redis.NewClient(&redis.Options{Addr: addr})}
}

// flush clears the destination so re-runs start from a clean ledger.
func (s *sinkReader) flush(ctx context.Context) error { return s.rdb.FlushDB(ctx).Err() }

// readLedger returns applied[i] = value of applied:<i> (0 if absent) for i in 1..n.
func (s *sinkReader) readLedger(ctx context.Context, n int) (map[int]int, error) {
	pipe := s.rdb.Pipeline()
	cmds := make([]*redis.StringCmd, n+1)
	for i := 1; i <= n; i++ {
		cmds[i] = pipe.Get(ctx, "applied:"+strconv.Itoa(i))
	}
	if _, err := pipe.Exec(ctx); err != nil && err != redis.Nil {
		return nil, err
	}
	out := make(map[int]int, n)
	for i := 1; i <= n; i++ {
		v, err := cmds[i].Int()
		if err == redis.Nil {
			out[i] = 0
			continue
		}
		if err != nil {
			return nil, err
		}
		out[i] = v
	}
	return out, nil
}

// distinctApplied counts keys kv:* currently present (cheap arm-progress proxy).
func (s *sinkReader) distinctApplied(ctx context.Context) (int, error) {
	var n int
	iter := s.rdb.Scan(ctx, 0, "kv:*", 1000).Iterator()
	for iter.Next(ctx) {
		n++
	}
	return n, iter.Err()
}

func (s *sinkReader) close() error { return s.rdb.Close() }
