package main

import "testing"

func TestPatternKeyShape(t *testing.T) {
	p := Pattern{Domain: "company", Entity: "employees"}
	got := p.Key("active", "run-1", 55688)
	want := "lb:company:active:{employees:run-1-55688}"
	if got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}

func TestActiveStandbyShareHashTag(t *testing.T) {
	p := Pattern{Domain: "company", Entity: "employees"}
	a := p.Key("active", "e", 7)
	s := p.Key("standby", "e", 7)
	tag := func(k string) string { return k[len(k)-len("{employees:e-7}"):] }
	if tag(a) != tag(s) {
		t.Fatalf("hash tags differ: %q vs %q", a, s)
	}
}

func TestThreePatterns(t *testing.T) {
	if len(Patterns) != 3 {
		t.Fatalf("want 3 patterns, got %d", len(Patterns))
	}
}
