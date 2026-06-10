// $LAB/writer/worker_test.go
package main

import "testing"

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
