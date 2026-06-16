// Report structs, builder, and atomic JSON file writer.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"time"
)

type WindowMeta struct {
	Start       string `json:"start"`
	End         string `json:"end"`
	DurationSec int    `json:"duration_sec"`
}

type ConfigMeta struct {
	IntervalSec int    `json:"interval_sec"`
	WindowSec   int    `json:"window_sec"`
	Stream      string `json:"stream"`
}

// OverallStats embeds the per-bucket Stats and adds the cumulative drop counter.
type OverallStats struct {
	Stats
	DroppedNegative int `json:"dropped_negative"`
}

type Report struct {
	GeneratedAt string           `json:"generated_at"`
	Window      WindowMeta       `json:"window"`
	Config      ConfigMeta       `json:"config"`
	Overall     OverallStats     `json:"overall"`
	ByOp        map[string]Stats `json:"by_op"`
}

func msToRFC3339(ms int64) string {
	return time.UnixMilli(ms).UTC().Format(time.RFC3339)
}

// BuildReport summarizes the window's current samples as of nowMs.
func BuildReport(w *Window, nowMs int64, cfg ConfigMeta) Report {
	all := w.Samples()
	overall := make([]int64, 0, len(all))
	byOp := map[string][]int64{"create": nil, "update": nil}
	for _, s := range all {
		overall = append(overall, s.LatencyMs)
		byOp[s.Op] = append(byOp[s.Op], s.LatencyMs)
	}
	return Report{
		GeneratedAt: msToRFC3339(nowMs),
		Window: WindowMeta{
			Start:       msToRFC3339(nowMs - int64(cfg.WindowSec)*1000),
			End:         msToRFC3339(nowMs),
			DurationSec: cfg.WindowSec,
		},
		Config:  cfg,
		Overall: OverallStats{Stats: Summarize(overall), DroppedNegative: w.DroppedNegative()},
		ByOp: map[string]Stats{
			"create": Summarize(byOp["create"]),
			"update": Summarize(byOp["update"]),
		},
	}
}

// WriteReportAtomic writes r as pretty JSON via a same-directory temp file +
// rename, so readers never observe a partial file.
func WriteReportAtomic(path string, r Report) error {
	b, err := json.MarshalIndent(r, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal report: %w", err)
	}
	b = append(b, '\n')
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return fmt.Errorf("write %s: %w", tmp, err)
	}
	if err := os.Rename(tmp, path); err != nil {
		return fmt.Errorf("rename %s -> %s: %w", tmp, path, err)
	}
	return nil
}
