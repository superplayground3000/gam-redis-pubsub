// $LAB/writer/worker_test.go
package main

import (
	"math/rand"
	"strings"
	"testing"
)

// TestBuildEventOpKeyMapping locks the draft→publish lifecycle: create/update
// write the standby (draft) key, delete removes active, rename promotes
// standby→active in one slot. The update→standby rule is the rollback fix —
// active is written ONLY by promotion, so a late rename cannot clobber a newer
// active value.
func TestBuildEventOpKeyMapping(t *testing.T) {
	mk := func(mix OpMix) Event {
		w := &Worker{Mix: mix, KeySpaceSize: 100, rng: rand.New(rand.NewSource(1))}
		return w.buildEvent(0)
	}
	if e := mk(OpMix{Create: 1}); !strings.Contains(e.KvKey, ":standby:") {
		t.Fatalf("create must target standby, got %q", e.KvKey)
	}
	if e := mk(OpMix{Update: 1}); !strings.Contains(e.KvKey, ":standby:") {
		t.Fatalf("update must target standby (rollback fix), got %q", e.KvKey)
	}
	if e := mk(OpMix{Delete: 1}); !strings.Contains(e.KvKey, ":active:") {
		t.Fatalf("delete must target active, got %q", e.KvKey)
	}
	e := mk(OpMix{Rename: 1})
	if !strings.Contains(e.OldKey, ":standby:") || !strings.Contains(e.NewKey, ":active:") {
		t.Fatalf("rename must be standby->active, got %q -> %q", e.OldKey, e.NewKey)
	}
	if hashTag(e.OldKey) == "" || hashTag(e.OldKey) != hashTag(e.NewKey) {
		t.Fatalf("rename keys must share a hash tag: %q vs %q", e.OldKey, e.NewKey)
	}
}

func TestPickOpCoversAll(t *testing.T) {
	mix := OpMix{Create: 40, Update: 40, Delete: 10, Rename: 10}
	seen := map[string]bool{}
	for i := 0; i < 100000; i++ {
		seen[mix.pick(uint64(i))] = true
	}
	for _, op := range []string{"create", "update", "delete", "rename"} {
		if !seen[op] {
			t.Fatalf("op %q never picked", op)
		}
	}
}

func TestPickOpZeroWeightExcluded(t *testing.T) {
	mix := OpMix{Create: 1, Update: 0, Delete: 0, Rename: 0}
	for i := 0; i < 1000; i++ {
		if got := mix.pick(uint64(i)); got != "create" {
			t.Fatalf("only create has weight, got %q", got)
		}
	}
}

func TestOpMixValid(t *testing.T) {
	cases := []struct {
		name string
		mix  OpMix
		want bool
	}{
		{"normal", OpMix{Create: 40, Update: 40, Delete: 10, Rename: 10}, true},
		{"single op", OpMix{Create: 1}, true},
		{"all zero", OpMix{}, false},
		{"negative create", OpMix{Create: -1, Update: 5}, false},
		{"negative rename", OpMix{Create: 5, Rename: -3}, false},
	}
	for _, tc := range cases {
		if got := tc.mix.Valid(); got != tc.want {
			t.Fatalf("%s: Valid() = %v, want %v", tc.name, got, tc.want)
		}
	}
}
