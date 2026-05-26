package main

type SLO struct {
	RateMinPct   float64 `json:"rate_min_pct"`
	LatencyP99Ms float64 `json:"latency_p99_ms"`
	AllowMissing bool    `json:"allow_missing"`
}

type VerdictInput struct {
	Mode            string
	RateTarget      int
	RateAchievedAvg float64
	Missing         int64
	LatencyP99Ms    float64
	SLO             SLO
}

type Verdict struct {
	Pass   bool            `json:"pass"`
	Checks map[string]bool `json:"checks"`
}

func ComputeVerdict(in VerdictInput) Verdict {
	checks := map[string]bool{}
	checks["rate_ok"] = float64(in.RateTarget) == 0 ||
		in.RateAchievedAvg/float64(in.RateTarget) >= in.SLO.RateMinPct
	checks["missing_ok"] = in.SLO.AllowMissing || in.Missing == 0
	if in.Mode == "latency" || in.Mode == "chaos" {
		checks["latency_p99_ok"] = in.LatencyP99Ms <= in.SLO.LatencyP99Ms
	}
	pass := true
	for _, ok := range checks {
		if !ok {
			pass = false
			break
		}
	}
	return Verdict{Pass: pass, Checks: checks}
}
