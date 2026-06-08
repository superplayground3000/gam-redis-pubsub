package main

import (
	"context"
	"testing"

	"github.com/alicebob/miniredis/v2"
)

func TestHGetAllSrcmaxAndTombstone(t *testing.T) {
	mr, _ := miniredis.Run()
	defer mr.Close()
	c := NewStreamClient(mr.Addr())
	defer c.Close()
	ctx := context.Background()

	mr.HSet("srcmax:run-1", "lb:company:active:{employees:run-1-1}", "9")
	mr.HSet("lb:company:active:{employees:run-1-1}", "ver", "9")
	mr.HSet("lb:company:active:{employees:run-1-1}", "deleted", "0")

	m, err := c.HGetAllInt(ctx, "srcmax:run-1")
	if err != nil {
		t.Fatal(err)
	}
	if m["lb:company:active:{employees:run-1-1}"] != 9 {
		t.Fatalf("srcmax wrong: %+v", m)
	}
	del, err := c.HGetDeleted(ctx, "lb:company:active:{employees:run-1-1}")
	if err != nil {
		t.Fatal(err)
	}
	if del != "0" {
		t.Fatalf("deleted=%q want 0", del)
	}
}
