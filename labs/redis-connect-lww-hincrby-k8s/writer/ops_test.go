package main

import (
	"math/rand"
	"testing"
)

func TestOpPickerRespectsWeights(t *testing.T) {
	p := NewOpPicker(OpWeights{Set: 8, Delete: 1, Rename: 1}, rand.New(rand.NewSource(1)))
	counts := map[Op]int{}
	for i := 0; i < 100000; i++ {
		counts[p.Pick()]++
	}
	if counts[OpSet] < counts[OpDelete] || counts[OpSet] < counts[OpRename] {
		t.Fatalf("set should dominate: %+v", counts)
	}
	if counts[OpDelete] == 0 || counts[OpRename] == 0 {
		t.Fatalf("delete/rename never picked: %+v", counts)
	}
}

func TestOpPickerZeroWeightsDefaultsToSet(t *testing.T) {
	p := NewOpPicker(OpWeights{}, rand.New(rand.NewSource(1)))
	if p.Pick() != OpSet {
		t.Fatal("empty weights should default to set")
	}
}
