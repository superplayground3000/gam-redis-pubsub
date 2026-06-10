// $LAB/writer/state.go
package main

import (
	"crypto/rand"
	"encoding/hex"
	"sync"
)

// RunState tracks the current run epoch, per-op counts, and the set of distinct
// keys touched — surfaced on GET /state for the verifier and dashboard. Unlike
// the parent there is NO per-key version; keys may be touched by many workers.
type RunState struct {
	bootID string
	mu     sync.Mutex
	epoch  string
	ops    map[string]int64
	keys   map[string]struct{}
}

type StateSnapshot struct {
	BootID       string           `json:"boot_id"`
	Epoch        string           `json:"epoch"`
	Ops          map[string]int64 `json:"ops"`
	DistinctKeys int              `json:"distinct_keys"`
}

func NewRunState() *RunState {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return &RunState{bootID: hex.EncodeToString(b), ops: map[string]int64{}, keys: map[string]struct{}{}}
}

func (s *RunState) BootID() string { return s.bootID }

func (s *RunState) Epoch() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.epoch
}

// SetEpoch starts a fresh run: clears op counts and the key set.
func (s *RunState) SetEpoch(name string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.epoch = name
	s.ops = map[string]int64{}
	s.keys = map[string]struct{}{}
}

// Record tallies one applied op against a key.
func (s *RunState) Record(op, key string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ops[op]++
	if key != "" {
		s.keys[key] = struct{}{}
	}
}

func (s *RunState) Snapshot() StateSnapshot {
	s.mu.Lock()
	defer s.mu.Unlock()
	ops := make(map[string]int64, len(s.ops))
	for k, v := range s.ops {
		ops[k] = v
	}
	return StateSnapshot{BootID: s.bootID, Epoch: s.epoch, Ops: ops, DistinctKeys: len(s.keys)}
}
