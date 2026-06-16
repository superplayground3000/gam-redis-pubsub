package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestBuildReportShape(t *testing.T) {
	w := NewWindow(60_000)
	w.Add(Sample{Op: "create", LatencyMs: 10, SinkTs: 1000})
	w.Add(Sample{Op: "create", LatencyMs: 20, SinkTs: 1000})
	w.Add(Sample{Op: "update", LatencyMs: 30, SinkTs: 1000})
	w.Add(Sample{Op: "create", LatencyMs: -1, SinkTs: 1000}) // dropped
	cfg := ConfigMeta{IntervalSec: 10, WindowSec: 60, Stream: "cdc:latency"}

	rep := BuildReport(w, 1_700_000_000_000, cfg)

	if rep.Overall.Count != 3 || rep.Overall.DroppedNegative != 1 {
		t.Errorf("overall count=%d dropped=%d want 3,1", rep.Overall.Count, rep.Overall.DroppedNegative)
	}
	if rep.ByOp["create"].Count != 2 || rep.ByOp["update"].Count != 1 {
		t.Errorf("by_op counts wrong: %+v", rep.ByOp)
	}
	if rep.Window.DurationSec != 60 || rep.Config.Stream != "cdc:latency" {
		t.Errorf("meta wrong: window=%+v config=%+v", rep.Window, rep.Config)
	}
	if rep.GeneratedAt == "" || rep.Window.Start == "" || rep.Window.End == "" {
		t.Errorf("timestamps empty: %+v", rep)
	}
}

func TestWriteReportAtomic(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "latency-report.json")
	rep := BuildReport(NewWindow(60_000), 1_700_000_000_000, ConfigMeta{WindowSec: 60})
	if err := WriteReportAtomic(path, rep); err != nil {
		t.Fatalf("write: %v", err)
	}
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	var back Report
	if err := json.Unmarshal(b, &back); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if back.Window.DurationSec != 60 {
		t.Errorf("round-trip lost data: %+v", back)
	}
	if _, err := os.Stat(path + ".tmp"); !os.IsNotExist(err) {
		t.Errorf("temp file should not remain")
	}
}
