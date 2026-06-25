package main

// ArmInput is the per-poll snapshot used to decide when to fire the DELETE.
type ArmInput struct {
	Profile         string
	N               int
	ArmFraction     float64
	ArmInflight     int
	AppliedDistinct int // count of distinct kv:* keys applied so far
	NumAckPending   int // consumer delivered-but-not-acked
	NumPending      int // messages not yet delivered to consumer (NATS backlog)
}

// Armed reports whether a meaningful in-flight cohort exists to DELETE into.
//
// For throughput: fires when the undelivered NATS backlog (NumPending) drops below
// N-ArmInflight, meaning at least ArmInflight messages have been handed to Connect
// (delivered or in-progress). This ensures DELETE lands mid-firehose with a large
// cohort in various stages of processing — achievable regardless of pipeline thread
// count, unlike NumAckPending which is bounded by the number of pipeline threads.
//
// For deterministic: fires when a fraction of messages have been applied and at
// least one is in-flight (NumAckPending > 0).
func Armed(in ArmInput) bool {
	if in.Profile == "throughput" {
		// NumPending counts messages NATS hasn't yet delivered. When it drops to
		// N - ArmInflight, at least ArmInflight messages have been dispatched to
		// Connect — a large cohort is mid-firehose.
		return in.NumPending <= in.N-in.ArmInflight && in.NumAckPending > 0
	}
	return in.NumAckPending > 0 && float64(in.AppliedDistinct) >= in.ArmFraction*float64(in.N)
}
