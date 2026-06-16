// go-redis XRANGE cursor consumer for the cdc:latency sidecar stream.
package main

import (
	"context"
	"log"

	"github.com/redis/go-redis/v9"
)

type Consumer struct {
	rdb    *redis.Client
	stream string
	lastID string
}

func NewConsumer(rdb *redis.Client, stream string) *Consumer {
	return &Consumer{rdb: rdb, stream: stream, lastID: "0-0"}
}

// Seek moves the cursor to the current stream tail so only NEW entries are read
// (cold start). A missing stream leaves the cursor at 0-0 (reads future entries).
func (c *Consumer) Seek(ctx context.Context) error {
	msgs, err := c.rdb.XRevRangeN(ctx, c.stream, "+", "-", 1).Result()
	if err != nil {
		return err
	}
	if len(msgs) > 0 {
		c.lastID = msgs[0].ID
	}
	return nil
}

// Poll drains all parseable samples after the cursor, advancing it. Entries that
// fail to parse are logged and skipped (best-effort telemetry).
func (c *Consumer) Poll(ctx context.Context) ([]Sample, error) {
	var out []Sample
	for {
		msgs, err := c.rdb.XRangeN(ctx, c.stream, "("+c.lastID, "+", 1000).Result()
		if err != nil {
			return out, err
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
		if len(msgs) < 1000 {
			break
		}
	}
	return out, nil
}
