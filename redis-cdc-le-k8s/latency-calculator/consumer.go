// go-redis XRANGE cursor consumer for the cdc:latency sidecar stream.
package main

import (
	"context"
	"fmt"
	"log"

	"github.com/redis/go-redis/v9"
)

// pageSize bounds each XRANGE read; Poll loops until a short page is returned.
const pageSize = 1000

// streamReader is the narrow slice of *redis.Client the consumer needs, so Poll
// and Seek can be unit-tested against a fake (a *redis.Client satisfies it).
type streamReader interface {
	XRangeN(ctx context.Context, stream, start, stop string, count int64) *redis.XMessageSliceCmd
	XRevRangeN(ctx context.Context, stream, start, stop string, count int64) *redis.XMessageSliceCmd
}

type Consumer struct {
	rdb    streamReader
	stream string
	lastID string
}

func NewConsumer(rdb streamReader, stream string) *Consumer {
	return &Consumer{rdb: rdb, stream: stream, lastID: "0-0"}
}

// Seek moves the cursor to the current stream tail so only NEW entries are read
// (cold start). A missing stream leaves the cursor at 0-0 (reads future entries).
func (c *Consumer) Seek(ctx context.Context) error {
	msgs, err := c.rdb.XRevRangeN(ctx, c.stream, "+", "-", 1).Result()
	if err != nil {
		return fmt.Errorf("xrevrange %s: %w", c.stream, err)
	}
	if len(msgs) > 0 {
		c.lastID = msgs[0].ID
	}
	return nil
}

// Poll drains all parseable samples after the cursor, advancing it. Entries that
// fail to parse are logged and skipped (best-effort telemetry). The cursor is
// advanced per delivered entry, so any samples accumulated before an error are
// returned alongside that error (callers must consume them).
func (c *Consumer) Poll(ctx context.Context) ([]Sample, error) {
	var out []Sample
	for {
		cursor := "(" + c.lastID
		msgs, err := c.rdb.XRangeN(ctx, c.stream, cursor, "+", pageSize).Result()
		if err != nil {
			return out, fmt.Errorf("xrange %s after %s: %w", c.stream, cursor, err)
		}
		if len(msgs) == 0 {
			break
		}
		for _, m := range msgs {
			c.lastID = m.ID
			f := make(map[string]string, len(m.Values))
			for k, v := range m.Values {
				if s, ok := v.(string); ok {
					f[k] = s
				}
			}
			s, err := ParseSample(f)
			if err != nil {
				log.Printf("skip entry %s: %v", m.ID, err)
				continue
			}
			out = append(out, s)
		}
		if len(msgs) < pageSize {
			break
		}
	}
	return out, nil
}
