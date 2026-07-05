package elector

import "testing"

func TestRenderPipeline(t *testing.T) {
	tmpl := "processors:\n  - redis:\n      args_mapping: 'root = [\"consumed:__POD__\"]'\n"
	got := renderPipeline(tmpl, "connect-xyz-0")
	want := "processors:\n  - redis:\n      args_mapping: 'root = [\"consumed:connect-xyz-0\"]'\n"
	if got != want {
		t.Fatalf("renderPipeline:\n got=%q\nwant=%q", got, want)
	}
}

func TestRenderPipelineReplacesAll(t *testing.T) {
	got := renderPipeline("__POD__ and __POD__", "p1")
	if got != "p1 and p1" {
		t.Fatalf("want all replaced, got %q", got)
	}
}
