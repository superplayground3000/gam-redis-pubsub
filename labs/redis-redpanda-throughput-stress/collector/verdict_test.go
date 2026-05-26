package main

import "testing"

func ptr(f float64) *float64 { return &f }

func TestVerdict_PassAllGates(t *testing.T) {
	v := ComputeVerdict(VerdictInput{
		RateTarget: 10000, RateAchievedAvg: 9800,
		Missing: 0, LatencyP99Ms: 120,
		SLO: SLO{RateMinPct: 0.95, LatencyP99MsMax: ptr(200.0)},
	})
	if !v.Pass {
		t.Fatalf("expected PASS, got %+v", v)
	}
	if v.Detail.P99LatencyOk == nil || !*v.Detail.P99LatencyOk {
		t.Errorf("expected P99LatencyOk=true, got %+v", v.Detail.P99LatencyOk)
	}
}

func TestVerdict_FailRateFloor(t *testing.T) {
	v := ComputeVerdict(VerdictInput{
		RateTarget: 10000, RateAchievedAvg: 8000,
		Missing: 0, LatencyP99Ms: 50,
		SLO: SLO{RateMinPct: 0.95, LatencyP99MsMax: ptr(200.0)},
	})
	if v.Pass {
		t.Fatalf("expected FAIL on rate, got PASS")
	}
	if v.Detail.RateFloorOk {
		t.Error("RateFloorOk should be false")
	}
}

func TestVerdict_FailMissing(t *testing.T) {
	v := ComputeVerdict(VerdictInput{
		RateTarget: 10000, RateAchievedAvg: 9800,
		Missing: 5, LatencyP99Ms: 50,
		SLO: SLO{RateMinPct: 0.95, LatencyP99MsMax: ptr(200.0)},
	})
	if v.Pass {
		t.Fatal("expected FAIL on missing")
	}
	if v.Detail.MissingOk {
		t.Error("MissingOk should be false")
	}
}

func TestVerdict_NullCeilingSkipsP99Gate(t *testing.T) {
	v := ComputeVerdict(VerdictInput{
		RateTarget: 10000, RateAchievedAvg: 9800,
		Missing: 0, LatencyP99Ms: 9999,
		SLO: SLO{RateMinPct: 0.95, LatencyP99MsMax: nil},
	})
	if !v.Pass {
		t.Fatalf("expected PASS when p99 ceiling is nil even with huge latency, got %+v", v)
	}
	if v.Detail.P99LatencyOk != nil {
		t.Errorf("P99LatencyOk = %v, want nil (skipped)", *v.Detail.P99LatencyOk)
	}
}

func TestVerdict_NullCeilingButOtherFailures(t *testing.T) {
	v := ComputeVerdict(VerdictInput{
		RateTarget: 10000, RateAchievedAvg: 5000,
		Missing: 10, LatencyP99Ms: 50,
		SLO: SLO{RateMinPct: 0.95, LatencyP99MsMax: nil},
	})
	if v.Pass {
		t.Fatal("expected FAIL")
	}
	if v.Detail.P99LatencyOk != nil {
		t.Error("P99LatencyOk should still be nil when ceiling is nil")
	}
}
