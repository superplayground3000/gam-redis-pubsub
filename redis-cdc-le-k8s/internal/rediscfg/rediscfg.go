// Package rediscfg is the single place that builds a cluster-capable Redis
// client from an explicit toggle, plus a fan-out primitive for the node-local
// operations (SCAN / keyspace subscribe / CONFIG SET) that a cluster client does
// not transparently spread across shards.
package rediscfg

import (
	"context"
	"fmt"
	"log"
	"os"
	"strconv"
	"strings"

	"github.com/redis/go-redis/v9"
)

// Options configures New.
type Options struct {
	// Addr is host:port. Comma-separated seed nodes are accepted in cluster mode,
	// but the chart supplies a single seed (the ClusterClient discovers the rest
	// via CLUSTER SLOTS).
	Addr string
	// Cluster selects *redis.ClusterClient over *redis.Client.
	Cluster bool
	// PoolSize is optional; 0 uses the library default.
	PoolSize int
}

// New returns a cluster-capable client. Both concrete return types satisfy
// redis.UniversalClient.
func New(opt Options) redis.UniversalClient {
	if opt.Cluster {
		seeds := strings.Split(opt.Addr, ",")
		for i := range seeds {
			seeds[i] = strings.TrimSpace(seeds[i])
		}
		return redis.NewClusterClient(&redis.ClusterOptions{Addrs: seeds, PoolSize: opt.PoolSize})
	}
	return redis.NewClient(&redis.Options{Addr: opt.Addr, PoolSize: opt.PoolSize})
}

// EnvBool reads a boolean toggle from the environment. An empty or unparseable
// value is false (fail-safe to single-node behavior).
func EnvBool(key string) bool {
	v := os.Getenv(key)
	if v == "" {
		return false
	}
	b, err := strconv.ParseBool(v)
	if err != nil {
		log.Printf("WARN: %s=%q not a bool, using false", key, v)
		return false
	}
	return b
}

// ForEachMaster runs fn against every master shard (cluster) or against the one
// node (non-cluster). It is the primitive the dashboard uses for the node-local
// operations SCAN / keyspace subscribe / CONFIG SET.
func ForEachMaster(ctx context.Context, c redis.UniversalClient, fn func(context.Context, *redis.Client) error) error {
	switch cc := c.(type) {
	case *redis.ClusterClient:
		return cc.ForEachMaster(ctx, fn)
	case *redis.Client:
		return fn(ctx, cc)
	default:
		return fmt.Errorf("rediscfg: ForEachMaster unsupported client type %T", c)
	}
}
