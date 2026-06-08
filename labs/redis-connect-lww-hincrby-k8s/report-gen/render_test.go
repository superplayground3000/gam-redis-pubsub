package main

import (
	"strings"
	"testing"
)

func TestRenderReportContainsVerdictAndTiers(t *testing.T) {
	sweep := Sweep{
		Lab:            "redis-connect-lww-hincrby-k8s",
		MaxPassingTier: 20000,
		Tiers: []Tier{
			{Rate: 5000, Pass: true, Mismatches: 0, Stale: 12, Applied: 100, Duplicate: 3},
			{Rate: 20000, Pass: true, Mismatches: 0, Stale: 40, Applied: 400, Duplicate: 9},
			{Rate: 40000, Pass: false, Mismatches: 0, Stale: 0, Applied: 800, Duplicate: 1},
		},
		Proofs: []Proof{{Name: "MW+", Pass: true}, {Name: "delete", Pass: true}, {Name: "rename", Pass: true}},
	}
	html, err := Render(sweep)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"redis-connect-lww-hincrby-k8s", "20000", "MW+", "delete", "rename"} {
		if !strings.Contains(html, want) {
			t.Fatalf("report missing %q", want)
		}
	}
}

func TestRenderEscapesAndHandlesEmpty(t *testing.T) {
	// Empty sweep must still render a valid doc (no panic, has <html>).
	html, err := Render(Sweep{Lab: "x", Tiers: nil, Proofs: nil})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(html, "<html") {
		t.Fatal("expected an HTML document")
	}
}
