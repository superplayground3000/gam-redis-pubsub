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

type Report struct {
	Tier                  int              `json:"tier"`
	Mode                  string           `json:"mode"`
	StartedAt             time.Time        `json:"started_at"`
	DurationS             int              `json:"duration_s"`
	RateTarget            int              `json:"rate_target"`
	RateAchievedAvg       float64          `json:"rate_achieved"`
	RateAchievedMin       float64          `json:"rate_achieved_min"`
	Sent                  int64            `json:"sent"`
	Errors                int64            `json:"errors"`
	Received              int64            `json:"received"`
	ReceivedByPattern     map[string]int64 `json:"received_by_pattern"`
	Missing               int64            `json:"missing"`
	MissingPct            float64          `json:"missing_pct"`
	Trimmed               int64            `json:"trimmed"`
	ReceivedErrors        int64            `json:"received_errors"`
	LatencyParseErrors    int64            `json:"latency_parse_errors"`
	NegativeLatencyDeltas int64            `json:"negative_latency_deltas"`
	SyncLatency           LatencySummary   `json:"sync_latency_ms"`
	Redis                 RedisStats       `json:"redis"`
	NATS                  NATSStats        `json:"nats"`
	Connect               ConnectStats     `json:"connect"`
	SLO                   SLO              `json:"slo"`
	Verdict               Verdict          `json:"verdict"`
	QuiescenceTimeout     bool             `json:"quiescence_timeout"`
}
