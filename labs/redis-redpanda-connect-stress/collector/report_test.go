package main

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestReportJSONShape(t *testing.T) {
	r := Report{
		Tier: 1000, Mode: "latency", Profile: "alo",
		StartedAt:       time.Date(2026, 5, 24, 19, 12, 3, 0, time.UTC),
		DurationS:       30,
		RateTarget:      1000,
		RateAchievedAvg: 998.2,
		RateAchievedMin: 942.0,
		Sent:            30021,
		Errors:          0,
		Received:        30019,
		Missing:         2,
		MissingPct:      0.0067,
		Latency:         LatencySummary{P50Ms: 18.4, P95Ms: 47.2, P99Ms: 89.1, MaxMs: 211.3, Samples: 6044},
		Redis:           RedisStats{CentralXLenMax: 1247, RegionXLenFinal: 30019},
		NATS:            NATSStats{PendingMax: 980, Bytes: 7_320_000},
		Connect:         ConnectStats{SourceIn: 30021, SourceOut: 30021, SinkIn: 30021, SinkOut: 30019},
		Chaos:           nil,
		SLO:             SLO{RateMinPct: 0.95, LatencyP99Ms: 1000},
		Verdict:         Verdict{Pass: true, Checks: map[string]bool{"rate_ok": true, "missing_ok": true, "latency_p99_ok": true}},
		ReceivedErrors:    7,
		Trimmed:           225000,
		QuiescenceTimeout: false,
	}
	b, err := json.MarshalIndent(r, "", "  ")
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	s := string(b)
	for _, want := range []string{
		`"tier": 1000`,
		`"mode": "latency"`,
		`"rate_achieved_avg": 998.2`,
		`"latency_ms": {`,
		`"chaos": null`,
		`"pass": true`,
		`"received_errors": 7`,
		`"trimmed": 225000`,
		`"quiescence_timeout": false`,
	} {
		if !strings.Contains(s, want) {
			t.Errorf("missing %q in:\n%s", want, s)
		}
	}
}
