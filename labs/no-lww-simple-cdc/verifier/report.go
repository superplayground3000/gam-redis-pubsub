// $LAB/verifier/report.go
package main

import "fmt"

type CDCResult struct {
	Epoch      string `json:"epoch"`
	DedupDelta int64  `json:"dedup_delta"`
	DedupOK    bool   `json:"dedup_ok"`
	CreateOK   bool   `json:"create_ok"`
	UpdateOK   bool   `json:"update_ok"`
	RenameOK   bool   `json:"rename_ok"`
	DeleteOK   bool   `json:"delete_ok"`
	OpsOK      bool   `json:"ops_ok"`
	ReplayOK   bool   `json:"replay_ok"`
	// RenameParityOK: after a value-preserving rename, central and region hold the
	// same new_key value (dual-write convergence).
	RenameParityOK bool `json:"rename_parity_ok"`
}

type Verdict struct {
	Pass   bool   `json:"pass"`
	Reason string `json:"reason,omitempty"`
}

type Report struct {
	CDC     CDCResult `json:"cdc"`
	Verdict Verdict   `json:"verdict"`
}

func ComputeVerdict(r CDCResult) Verdict {
	switch {
	case !r.DedupOK:
		return Verdict{false, fmt.Sprintf("dedup failed: stream grew by %d (want 1)", r.DedupDelta)}
	case !r.OpsOK:
		return Verdict{false, fmt.Sprintf("per-op failed: create=%v update=%v rename=%v delete=%v", r.CreateOK, r.UpdateOK, r.RenameOK, r.DeleteOK)}
	case !r.ReplayOK:
		return Verdict{false, "replay not idempotent: rename re-delivery changed terminal state"}
	case !r.RenameParityOK:
		return Verdict{false, "rename parity failed: central and region diverged after a value-preserving rename"}
	default:
		return Verdict{true, ""}
	}
}
