package rediscfg

import (
	"context"
	"os"
	"testing"

	"github.com/redis/go-redis/v9"
)

func TestNewSingleNode(t *testing.T) {
	c := New(Options{Addr: "127.0.0.1:6379"})
	defer c.Close()
	if _, ok := c.(*redis.Client); !ok {
		t.Fatalf("Cluster=false: want *redis.Client, got %T", c)
	}
}

func TestNewCluster(t *testing.T) {
	c := New(Options{Addr: "a:6379, b:6379", Cluster: true})
	defer c.Close()
	cc, ok := c.(*redis.ClusterClient)
	if !ok {
		t.Fatalf("Cluster=true: want *redis.ClusterClient, got %T", c)
	}
	// Seeds are comma-split and trimmed.
	opt := cc.Options()
	if len(opt.Addrs) != 2 || opt.Addrs[0] != "a:6379" || opt.Addrs[1] != "b:6379" {
		t.Fatalf("seeds not split/trimmed: %#v", opt.Addrs)
	}
}

func TestNewClusterEmptySeedsFiltered(t *testing.T) {
	// Trailing comma and whitespace-only entries (common in env vars) must not
	// inject empty addresses into the seed list.
	c := New(Options{Addr: "a:6379, ,b:6379,   ,", Cluster: true})
	defer c.Close()
	cc, ok := c.(*redis.ClusterClient)
	if !ok {
		t.Fatalf("Cluster=true: want *redis.ClusterClient, got %T", c)
	}
	opt := cc.Options()
	if len(opt.Addrs) != 2 || opt.Addrs[0] != "a:6379" || opt.Addrs[1] != "b:6379" {
		t.Fatalf("empty/whitespace seeds not filtered: %#v", opt.Addrs)
	}
}

func TestEnvBool(t *testing.T) {
	// Ensure the "unset" var is genuinely unset regardless of the ambient
	// environment, then restore it on cleanup.
	os.Unsetenv("RDSCFG_UNSET_VAR")
	if EnvBool("RDSCFG_UNSET_VAR") != false {
		t.Fatal("unset var should be false")
	}
	t.Setenv("RDSCFG_TEST_BOOL", "true")
	if EnvBool("RDSCFG_TEST_BOOL") != true {
		t.Fatal(`"true" should parse to true`)
	}
	t.Setenv("RDSCFG_TEST_BOOL", "garbage")
	if EnvBool("RDSCFG_TEST_BOOL") != false {
		t.Fatal("unparseable value should fall back to false")
	}
}

func TestForEachMasterSingleNode(t *testing.T) {
	c := New(Options{Addr: "127.0.0.1:6379"})
	defer c.Close()

	calls := 0
	var got *redis.Client
	err := ForEachMaster(context.Background(), c, func(_ context.Context, shard *redis.Client) error {
		calls++
		got = shard
		return nil
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if calls != 1 {
		t.Fatalf("single-node: want closure called once, got %d", calls)
	}
	// The closure receives the single client itself.
	if got != c.(*redis.Client) {
		t.Fatalf("single-node: closure received a different client")
	}
}
