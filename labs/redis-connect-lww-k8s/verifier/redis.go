package main

import (
	"context"
	"strconv"
	"strings"

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

// GroupLag returns the number of entries in `stream` not yet read by consumer
// group `group`. Returns (0, nil) if the stream exists but the group doesn't —
// a stream that has never had the consumer registered is trivially caught-up
// for our quiescence purposes. Returns the underlying error for any other
// Redis failure so callers can distinguish "really drained" from "couldn't ask".
func (s *StreamClient) GroupLag(ctx context.Context, stream, group string) (int64, error) {
	groups, err := s.rdb.XInfoGroups(ctx, stream).Result()
	if err != nil {
		// "no such key" → stream doesn't exist yet. Treat as 0 lag (drained).
		// Other errors (network, perm, etc.) → propagate so quiescence can retry.
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
	return 0, nil
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

// HGetVer returns the stored version for a KV hash key, ok=false if the key/field is absent.
func (s *StreamClient) HGetVer(ctx context.Context, key string) (int64, bool, error) {
	v, err := s.rdb.HGet(ctx, key, "ver").Result()
	if err == redis.Nil {
		return 0, false, nil
	}
	if err != nil {
		return 0, false, err
	}
	n, perr := strconv.ParseInt(v, 10, 64)
	if perr != nil {
		return 0, false, perr
	}
	return n, true, nil
}
