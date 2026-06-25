package main

// ArmInput is the per-poll snapshot used to decide when to fire the DELETE.
type ArmInput struct {
	Profile         string
	N               int
	ArmFraction     float64
	ArmInflight     int
	// MinInflight is the minimum num_ack_pending required for the arm condition to
	// fire. Default 1. Raise (e.g. 4) with PIPELINE_THREADS=8 to require a real
	// multi-message cohort simultaneously in-flight inside Connect.
	MinInflight     int
	AppliedDistinct int // count of distinct kv:* keys applied so far
	NumAckPending   int // consumer delivered-but-not-acked
	NumPending      int // messages not yet delivered to consumer (NATS backlog)
}

// Armed reports whether a meaningful in-flight cohort exists to DELETE into.
//
// For throughput: fires when the undelivered NATS backlog (NumPending) drops below
// N-ArmInflight (at least ArmInflight messages have been handed to Connect) AND
// NumAckPending >= MinInflight (a real cohort of at least MinInflight messages is
// simultaneously inside Connect's pipeline). Using >= MinInflight instead of > 0
// proves the DELETE lands over a real cohort, not a transient single message.
//
// For deterministic: fires when a fraction of messages have been applied and at
// least MinInflight messages are simultaneously in-flight (NumAckPending >=
// MinInflight). With the default MinInflight=1 this is identical to the prior
// NumAckPending > 0 behavior.
func Armed(in ArmInput) bool {
	minInFlight := in.MinInflight
	if minInFlight < 1 {
		minInFlight = 1
	}
	if in.Profile == "throughput" {
		// NumPending counts messages NATS hasn't yet delivered. When it drops to
		// N - ArmInflight, at least ArmInflight messages have been dispatched to
		// Connect — a large cohort is mid-firehose. We also require a real cohort
		// of >= MinInflight messages inside Connect's pipeline right now.
		return in.NumPending <= in.N-in.ArmInflight && in.NumAckPending >= minInFlight
	}
	return in.NumAckPending >= minInFlight && float64(in.AppliedDistinct) >= in.ArmFraction*float64(in.N)
}
