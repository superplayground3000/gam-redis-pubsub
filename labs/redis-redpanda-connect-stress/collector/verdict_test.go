package main

import "testing"

func TestVerdictAllPass(t *testing.T) {
	v := ComputeVerdict(VerdictInput{
		Mode:            "latency",
		RateTarget:      1000,
		RateAchievedAvg: 998,
		Missing:         0,
		LatencyP99Ms:    500,
		SLO:             SLO{RateMinPct: 0.95, LatencyP99Ms: 1000, AllowMissing: false},
	})
	if !v.Pass {
		t.Errorf("expected pass, got %+v", v)
	}
}

func TestVerdictRateTooLow(t *testing.T) {
	v := ComputeVerdict(VerdictInput{
		Mode: "throughput", RateTarget: 1000, RateAchievedAvg: 800,
		Missing: 0, LatencyP99Ms: 0,
		SLO: SLO{RateMinPct: 0.95},
	})
	if v.Pass {
		t.Errorf("expected fail (rate)")
	}
	if v.Checks["rate_ok"] {
		t.Errorf("rate_ok should be false")
	}
}

func TestVerdictMissingNotAllowed(t *testing.T) {
	v := ComputeVerdict(VerdictInput{
		Mode: "throughput", RateTarget: 1000, RateAchievedAvg: 1000,
		Missing: 5, LatencyP99Ms: 0,
		SLO: SLO{RateMinPct: 0.95, AllowMissing: false},
	})
	if v.Pass {
		t.Errorf("expected fail (missing)")
	}
}

func TestVerdictMissingAllowedForAMO(t *testing.T) {
	v := ComputeVerdict(VerdictInput{
		Mode: "throughput", RateTarget: 1000, RateAchievedAvg: 1000,
		Missing: 50, LatencyP99Ms: 0,
		SLO: SLO{RateMinPct: 0.95, AllowMissing: true},
	})
	if !v.Pass {
		t.Errorf("expected pass (AMO allows missing)")
	}
}

func TestVerdictLatencyOnlyCheckedInLatencyAndChaosModes(t *testing.T) {
	in := VerdictInput{
		Mode: "throughput", RateTarget: 1000, RateAchievedAvg: 1000,
		Missing: 0, LatencyP99Ms: 9999,
		SLO: SLO{RateMinPct: 0.95, LatencyP99Ms: 1000},
	}
	if !ComputeVerdict(in).Pass {
		t.Errorf("throughput mode should ignore latency p99")
	}
	in.Mode = "latency"
	if ComputeVerdict(in).Pass {
		t.Errorf("latency mode should fail when p99 > SLO")
	}
	in.Mode = "chaos"
	if ComputeVerdict(in).Pass {
		t.Errorf("chaos mode should fail when p99 > SLO")
	}
}
