package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func mkReport(pass bool) Report {
	return Report{
		Tier: 10, Mode: "throughput", Profile: "alo",
		Verdict: Verdict{Pass: pass, Checks: map[string]bool{"rate_ok": pass}},
	}
}

func TestWriteReportStdoutEmitsSingleSentinelLine(t *testing.T) {
	var buf bytes.Buffer
	exitFail, err := writeReport("-", &buf, mkReport(false))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if exitFail {
		t.Fatalf("stdout mode must never set exitFail (verdict travels in JSON)")
	}
	out := buf.String()
	lines := strings.Split(strings.TrimRight(out, "\n"), "\n")
	if len(lines) != 1 {
		t.Fatalf("want exactly 1 line, got %d: %q", len(lines), out)
	}
	const prefix = "RESULT_JSON:"
	if !strings.HasPrefix(lines[0], prefix) {
		t.Fatalf("line must start with %q, got %q", prefix, lines[0])
	}
	var r Report
	if err := json.Unmarshal([]byte(strings.TrimPrefix(lines[0], prefix)), &r); err != nil {
		t.Fatalf("payload after sentinel must be valid JSON: %v", err)
	}
	if r.Verdict.Pass != false || r.Tier != 10 {
		t.Fatalf("round-trip mismatch: got pass=%v tier=%d", r.Verdict.Pass, r.Tier)
	}
}

func TestWriteReportStdoutPassAlsoExitsZero(t *testing.T) {
	var buf bytes.Buffer
	exitFail, err := writeReport("-", &buf, mkReport(true))
	if err != nil || exitFail {
		t.Fatalf("pass verdict in stdout mode: err=%v exitFail=%v", err, exitFail)
	}
}

func TestWriteReportFileModeKeepsExitOnFail(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "run.json")
	exitFail, err := writeReport(path, &bytes.Buffer{}, mkReport(false))
	if err != nil {
		t.Fatalf("file write failed: %v", err)
	}
	if !exitFail {
		t.Fatalf("file mode must report exitFail=true on verdict fail (legacy behavior)")
	}
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("report file not written: %v", err)
	}
	if !bytes.Contains(b, []byte("\n")) {
		t.Fatalf("file mode should still write indented (multi-line) JSON")
	}
}
