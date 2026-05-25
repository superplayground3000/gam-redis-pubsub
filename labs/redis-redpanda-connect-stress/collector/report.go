package main

import "time"

type RedisStats struct {
	CentralXLenMax  int64 `json:"central_xlen_max"`
	RegionXLenFinal int64 `json:"region_xlen_final"`
}

type NATSStats struct {
	PendingMax int64 `json:"pending_max"`
	Bytes      int64 `json:"bytes"`
}

type ConnectStats struct {
	SourceIn  int64 `json:"source_in"`
	SourceOut int64 `json:"source_out"`
	SinkIn    int64 `json:"sink_in"`
	SinkOut   int64 `json:"sink_out"`
}

type ChaosInfo struct {
	Action         string `json:"action"`
	DownAtS        int    `json:"down_at_s"`
	DurationS      int    `json:"duration_s"`
	RecoveryLagMax int64  `json:"recovery_lag_max"`
}

type Report struct {
	Tier            int            `json:"tier"`
	Mode            string         `json:"mode"`
	Profile         string         `json:"profile"`
	StartedAt       time.Time      `json:"started_at"`
	DurationS       int            `json:"duration_s"`
	RateTarget      int            `json:"rate_target"`
	RateAchievedAvg float64        `json:"rate_achieved_avg"`
	RateAchievedMin float64        `json:"rate_achieved_min"`
	Sent            int64          `json:"sent"`
	Errors          int64          `json:"errors"`
	Received        int64          `json:"received"`
	Missing         int64          `json:"missing"`
	MissingPct      float64        `json:"missing_pct"`
	Latency         LatencySummary `json:"latency_ms"`
	Redis           RedisStats     `json:"redis"`
	NATS            NATSStats      `json:"nats"`
	Connect         ConnectStats   `json:"connect"`
	Chaos           *ChaosInfo     `json:"chaos"`
	SLO             SLO            `json:"slo"`
	Verdict         Verdict        `json:"verdict"`
	ReceivedErrors    int64 `json:"received_errors"`
	Trimmed           int64 `json:"trimmed"`
	QuiescenceTimeout bool  `json:"quiescence_timeout"`
}
