// $LAB/dashboard/divergence_test.go
package main

import "testing"

func TestDivergence(t *testing.T) {
	central := map[string]string{"a": "1", "b": "2", "c": "3"}
	region := map[string]string{"a": "1", "b": "9" /* differs */, "d": "4" /* region-only */}
	d := computeDivergence(central, region)
	if d.CentralCount != 3 || d.RegionCount != 3 {
		t.Fatalf("counts: %+v", d)
	}
	if d.OnlyCentral != 1 { // c
		t.Fatalf("OnlyCentral=%d want 1", d.OnlyCentral)
	}
	if d.OnlyRegion != 1 { // d
		t.Fatalf("OnlyRegion=%d want 1", d.OnlyRegion)
	}
	if d.Differing != 1 { // b
		t.Fatalf("Differing=%d want 1", d.Differing)
	}
	if d.Divergent != 3 {
		t.Fatalf("Divergent=%d want 3", d.Divergent)
	}
}
