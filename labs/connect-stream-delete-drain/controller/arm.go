package main

// ArmInput is the per-poll snapshot used to decide when to fire the DELETE.
type ArmInput struct {
	Profile         string
	N               int
	ArmFraction     float64
	ArmInflight     int
	AppliedDistinct int // count of distinct kv:* keys applied so far
	NumAckPending   int // consumer delivered-but-not-acked
}

// Armed reports whether a meaningful in-flight cohort exists to DELETE into.
func Armed(in ArmInput) bool {
	if in.Profile == "throughput" {
		return in.NumAckPending >= in.ArmInflight
	}
	return in.NumAckPending > 0 && float64(in.AppliedDistinct) >= in.ArmFraction*float64(in.N)
}
