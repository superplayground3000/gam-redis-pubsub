package main

import (
	"strings"
	"testing"
)

func TestKeyGen_EmployeeShape(t *testing.T) {
	g := NewKeyGen(KeyGenConfig{Cardinality: 20000, Seed: 42})
	got := g.Employee(7)
	want := "lb:company:active:{employee:7}"
	if got != want {
		t.Fatalf("Employee(7) = %q, want %q", got, want)
	}
}

func TestKeyGen_OrgShape(t *testing.T) {
	g := NewKeyGen(KeyGenConfig{Cardinality: 20000, Seed: 42})
	got := g.Org(123)
	want := "lb:functions:active:{org:123}"
	if got != want {
		t.Fatalf("Org(123) = %q, want %q", got, want)
	}
}

func TestKeyGen_RoleShape(t *testing.T) {
	g := NewKeyGen(KeyGenConfig{Cardinality: 20000, Seed: 42})
	got := g.Role(0)
	if !strings.HasPrefix(got, "lb:functions:active:{role:") || !strings.HasSuffix(got, "}") {
		t.Fatalf("Role(0) = %q, want prefix lb:functions:active:{role: and suffix }", got)
	}
	hex := strings.TrimSuffix(strings.TrimPrefix(got, "lb:functions:active:{role:"), "}")
	if len(hex) != 40 {
		t.Fatalf("Role(0) hex length = %d, want 40 (SHA-1)", len(hex))
	}
}

func TestKeyGen_RoleDeterministicPerSeed(t *testing.T) {
	a := NewKeyGen(KeyGenConfig{Cardinality: 100, Seed: 42}).Role(5)
	b := NewKeyGen(KeyGenConfig{Cardinality: 100, Seed: 42}).Role(5)
	if a != b {
		t.Fatalf("Role(5) not deterministic for same seed: %q vs %q", a, b)
	}
}

func TestKeyGen_RoleDifferentSeeds(t *testing.T) {
	a := NewKeyGen(KeyGenConfig{Cardinality: 100, Seed: 1}).Role(5)
	b := NewKeyGen(KeyGenConfig{Cardinality: 100, Seed: 2}).Role(5)
	if a == b {
		t.Fatalf("Role(5) coincidentally equal across seeds: %q", a)
	}
}

func TestKeyGen_AllRolesUnique(t *testing.T) {
	const n = 20000
	g := NewKeyGen(KeyGenConfig{Cardinality: n, Seed: 42})
	seen := make(map[string]struct{}, n)
	for i := 0; i < n; i++ {
		k := g.Role(i)
		if _, dup := seen[k]; dup {
			t.Fatalf("Role(%d) duplicate: %q", i, k)
		}
		seen[k] = struct{}{}
	}
}
