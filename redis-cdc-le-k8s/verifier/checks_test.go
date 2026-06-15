// $LAB/verifier/checks_test.go
package main

import (
	"strings"
	"testing"
)

func TestVerifyKeysShareHashTag(t *testing.T) {
	a, b := renameKeys("e7")
	tagA := a[strings.Index(a, "{"):strings.Index(a, "}")+1]
	tagB := b[strings.Index(b, "{"):strings.Index(b, "}")+1]
	if tagA != tagB {
		t.Fatalf("rename keys must share a hash tag: %q vs %q", tagA, tagB)
	}
	if a == b {
		t.Fatal("rename keys must differ")
	}
}
