package main

import (
	"math/rand"
	"testing"
)

func TestPicker_ParseWeights(t *testing.T) {
	got, err := ParsePatternWeights("40,30,30")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := []int{40, 30, 30}
	if len(got) != 3 || got[0] != want[0] || got[1] != want[1] || got[2] != want[2] {
		t.Fatalf("ParsePatternWeights = %v, want %v", got, want)
	}
}

func TestPicker_ParseWeightsRejectsBadInput(t *testing.T) {
	if _, err := ParsePatternWeights("1,2"); err == nil {
		t.Fatal("expected error for 2-element weights")
	}
	if _, err := ParsePatternWeights("0,0,0"); err == nil {
		t.Fatal("expected error for all-zero weights")
	}
	if _, err := ParsePatternWeights("a,b,c"); err == nil {
		t.Fatal("expected error for non-numeric weights")
	}
}

func TestPicker_Distribution(t *testing.T) {
	p, err := NewPicker([]int{50, 25, 25})
	if err != nil {
		t.Fatalf("NewPicker: %v", err)
	}
	r := rand.New(rand.NewSource(1))
	counts := [3]int{}
	const n = 100_000
	for i := 0; i < n; i++ {
		counts[p.Pick(r)]++
	}
	// Allow 2% tolerance per bucket.
	check := func(name string, got, target int) {
		diff := got - target
		if diff < -2000 || diff > 2000 {
			t.Errorf("%s bucket = %d, want ~%d (±2000)", name, got, target)
		}
	}
	check("employee", counts[0], n/2)
	check("role", counts[1], n/4)
	check("org", counts[2], n/4)
}

func TestPicker_DefaultsEvenSplit(t *testing.T) {
	p, err := NewPicker([]int{33, 33, 34})
	if err != nil {
		t.Fatalf("NewPicker: %v", err)
	}
	r := rand.New(rand.NewSource(7))
	counts := [3]int{}
	const n = 99_000
	for i := 0; i < n; i++ {
		counts[p.Pick(r)]++
	}
	for i, c := range counts {
		if c < 31000 || c > 35000 {
			t.Errorf("bucket %d = %d, want ~33000", i, c)
		}
	}
}
