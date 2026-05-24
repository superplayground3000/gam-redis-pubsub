package main

import (
	"context"

	"github.com/redis/go-redis/v9"
)

type StreamClient struct {
	rdb *redis.Client
}

func NewStreamClient(addr string) *StreamClient {
	return &StreamClient{rdb: redis.NewClient(&redis.Options{Addr: addr})}
}

func (s *StreamClient) Close() error { return s.rdb.Close() }

func (s *StreamClient) XLen(ctx context.Context, key string) (int64, error) {
	return s.rdb.XLen(ctx, key).Result()
}

// Trim flushes the stream entirely by trimming it to MAXLEN 0.
// Used at the start of each tier run to reset the source/region streams.
func (s *StreamClient) Trim(ctx context.Context, key string) error {
	return s.rdb.XTrimMaxLen(ctx, key, 0).Err()
}

// XRangeSinceID returns stream entries strictly after `lastID` (use "0-0" for first call),
// up to count entries. Returns the new highest ID for the next call.
func (s *StreamClient) XRangeSinceID(ctx context.Context, key, lastID string, count int64) ([]redis.XMessage, string, error) {
	startExclusive := "(" + lastID
	msgs, err := s.rdb.XRangeN(ctx, key, startExclusive, "+", count).Result()
	if err != nil {
		return nil, lastID, err
	}
	newLast := lastID
	if len(msgs) > 0 {
		newLast = msgs[len(msgs)-1].ID
	}
	return msgs, newLast, nil
}
