package main

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"sync"
	"sync/atomic"
)

// State is the JSON shape returned by GET /state.
type State struct {
	BootID        string           `json:"boot_id"`
	Epoch         string           `json:"epoch"`
	Keys          map[string]int64 `json:"keys"`
	DistinctKeys  int              `json:"distinct_keys"`
	TotalVersions int64            `json:"total_versions"`
}

// shard holds the per-key max version for the keys owned by one worker.
type shard struct {
	mu sync.Mutex
	m  map[string]int64
}

// epochState is the immutable-per-epoch set of shards. Swapping epoch swaps the
// whole pointer, so a new epoch starts every shard empty (versions restart at 1)
// — which is SAFE because the key namespace also changes (keys embed the epoch),
// so no strictly-older-vs-stored arrivals are manufactured (spec §3.4.1).
type epochState struct {
	name   string
	shards []*shard
}

type Versions struct {
	bootID  string
	nshards int
	cur     atomic.Pointer[epochState]
}

func NewVersions(workers int) *Versions {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return &Versions{bootID: hex.EncodeToString(b), nshards: workers}
}

func (v *Versions) BootID() string { return v.bootID }

func (v *Versions) SetEpoch(name string) {
	shards := make([]*shard, v.nshards)
	for i := range shards {
		shards[i] = &shard{m: map[string]int64{}}
	}
	v.cur.Store(&epochState{name: name, shards: shards})
}

// Next increments and returns the version for key, owned by worker `w`.
func (v *Versions) Next(w int, key string) int64 {
	es := v.cur.Load()
	s := es.shards[w%v.nshards]
	s.mu.Lock()
	s.m[key]++
	n := s.m[key]
	s.mu.Unlock()
	return n
}

// NextForCurrent atomically derives the per-run key for keyID and its next version
// from a SINGLE epoch snapshot. This is the hot-path API: deriving the key string
// and incrementing its counter from the same epochState makes it impossible for a
// concurrent SetEpoch to pair an old-epoch key with a new-epoch counter (or vice
// versa) — a mix that would otherwise pollute the new run's /state with an
// old-epoch key and trip a false mismatch in the verifier. Returns ok=false if no
// epoch is set yet. Worker w owns keyID; w selects the shard.
func (v *Versions) NextForCurrent(w int, keyID int64) (key string, ver int64, ok bool) {
	es := v.cur.Load()
	if es == nil {
		return "", 0, false
	}
	key = fmt.Sprintf("lww:%s:%d", es.name, keyID)
	s := es.shards[w%v.nshards]
	s.mu.Lock()
	s.m[key]++
	ver = s.m[key]
	s.mu.Unlock()
	return key, ver, true
}

// Epoch returns the active epoch name ("" before SetEpoch).
func (v *Versions) Epoch() string {
	if es := v.cur.Load(); es != nil {
		return es.name
	}
	return ""
}

func (v *Versions) State() State {
	st := State{BootID: v.bootID, Keys: map[string]int64{}}
	es := v.cur.Load()
	if es == nil {
		return st
	}
	st.Epoch = es.name
	for _, s := range es.shards {
		s.mu.Lock()
		for k, n := range s.m {
			st.Keys[k] = n
			st.TotalVersions += n
		}
		s.mu.Unlock()
	}
	st.DistinctKeys = len(st.Keys)
	return st
}
