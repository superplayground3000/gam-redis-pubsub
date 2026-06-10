// $LAB/writer/patterns_test.go
package main

import "testing"

func TestActiveKeyHashTagged(t *testing.T) {
	got := Patterns[0].ActiveKey(55688)
	want := "lb:company:active:{employees:55688}"
	if got != want {
		t.Fatalf("ActiveKey = %q, want %q", got, want)
	}
}

func TestStandbyKeyOnlyCompany(t *testing.T) {
	// Only the company/employees pattern has a standby->active rename flow.
	if Patterns[0].StandbyKey(55688) != "lb:company:standby:{employees:55688}" {
		t.Fatalf("company standby key wrong: %q", Patterns[0].StandbyKey(55688))
	}
	if Patterns[0].ActiveKey(1) == Patterns[0].StandbyKey(1) {
		t.Fatal("active and standby must differ")
	}
}

func TestAllThreePatternsPresent(t *testing.T) {
	if len(Patterns) != 3 {
		t.Fatalf("want 3 patterns, got %d", len(Patterns))
	}
	wants := []string{
		"lb:company:active:{employees:7}",
		"lb:funtions:active:{groups:7}",
		"lb:general:active:{items:7}",
	}
	for i, w := range wants {
		if got := Patterns[i].ActiveKey(7); got != w {
			t.Fatalf("pattern %d ActiveKey = %q, want %q", i, got, w)
		}
	}
}
