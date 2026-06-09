package main

import (
	"crypto/rand"
	"encoding/hex"
	"sync/atomic"
)

// State is the JSON shape returned by GET /state.
type State struct {
	BootID string `json:"boot_id"`
	Epoch  string `json:"epoch"`
}

// Run holds the per-process boot id and the current run epoch. The epoch doubles as
// the writer's start gate: workers emit nothing until /reset sets a non-empty epoch.
// (The parent lab's per-key LWW version map / epoch-scoped key naming is removed —
// this lab is a plain stream producer; order/uniqueness are not the concern here.)
type Run struct {
	bootID string
	epoch  atomic.Pointer[string]
}

func NewRun() *Run {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return &Run{bootID: hex.EncodeToString(b)}
}

func (r *Run) BootID() string { return r.bootID }

// SetEpoch opens (or re-opens) the start gate to the named run.
func (r *Run) SetEpoch(name string) { r.epoch.Store(&name) }

// Epoch returns the active epoch ("" before the first /reset).
func (r *Run) Epoch() string {
	if p := r.epoch.Load(); p != nil {
		return *p
	}
	return ""
}

func (r *Run) State() State {
	return State{BootID: r.bootID, Epoch: r.Epoch()}
}
