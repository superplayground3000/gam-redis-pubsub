package main

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestReport_JSONShape(t *testing.T) {
	r := Report{
		Tier: 50000, Mode: "batch",
		StartedAt:       time.Date(2026, 5, 26, 10, 0, 0, 0, time.UTC),
		DurationS:       30,
		RateTarget:      50000,
		RateAchievedAvg: 49850.2,
		Sent:            1495506,
		Received:        1492841,
		ReceivedByPattern: map[string]int64{
			"employee": 497612, "role": 497615, "org": 497614,
		},
		Trimmed:           0,
		Missing:           2665,
		SyncLatency:       LatencySummary{P50Ms: 142.3, P95Ms: 612.1, P99Ms: 1180.4, P999Ms: 1843.2, MaxMs: 2010.7, Samples: 1492841},
		ReceivedErrors:    0,
		QuiescenceTimeout: false,
		Verdict: Verdict{
			Pass:   true,
			Detail: VerdictDetail{RateFloorOk: true, MissingOk: true, P99LatencyOk: nil},
		},
	}
	buf, err := json.MarshalIndent(r, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	s := string(buf)
	for _, want := range []string{
		`"tier": 50000`,
		`"mode": "batch"`,
		`"sync_latency_ms"`,
		`"p999": 1843.2`,
		`"count": 1492841`,
		`"received_by_pattern"`,
		`"p99_latency_ok": null`,
	} {
		if !strings.Contains(s, want) {
			t.Errorf("missing %q in JSON:\n%s", want, s)
		}
	}
	for _, forbidden := range []string{
		`"profile"`,
		`"chaos"`,
		`"latency_ms"`,
		`"checks"`,
	} {
		if strings.Contains(s, forbidden) {
			t.Errorf("forbidden %q present in JSON:\n%s", forbidden, s)
		}
	}
}
