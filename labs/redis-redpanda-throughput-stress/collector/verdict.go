package main

type SLO struct {
	RateMinPct      float64  `json:"rate_min_pct"`
	LatencyP99MsMax *float64 `json:"latency_p99_ms_max"` // nil = calibration mode (gate skipped)
}

type VerdictInput struct {
	RateTarget      int
	RateAchievedAvg float64
	Missing         int64
	LatencyP99Ms    float64
	SLO             SLO
}

type VerdictDetail struct {
	RateFloorOk  bool  `json:"rate_floor_ok"`
	MissingOk    bool  `json:"missing_ok"`
	P99LatencyOk *bool `json:"p99_latency_ok"` // nil when SLO.LatencyP99MsMax is nil
}

type Verdict struct {
	Pass   bool          `json:"pass"`
	Detail VerdictDetail `json:"detail"`
}

func ComputeVerdict(in VerdictInput) Verdict {
	d := VerdictDetail{}
	d.RateFloorOk = in.RateTarget == 0 ||
		in.RateAchievedAvg/float64(in.RateTarget) >= in.SLO.RateMinPct
	d.MissingOk = in.Missing == 0

	pass := d.RateFloorOk && d.MissingOk
	if in.SLO.LatencyP99MsMax != nil {
		ok := in.LatencyP99Ms <= *in.SLO.LatencyP99MsMax
		d.P99LatencyOk = &ok
		pass = pass && ok
	}
	return Verdict{Pass: pass, Detail: d}
}
