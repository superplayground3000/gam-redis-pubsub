package main

import "testing"

// TestOwnedKeyIDSingleOwner asserts the core LWW precondition: for any valid
// config (keyspace >= workers, enforced by the startup guard in main.go), every
// key id is owned by exactly one worker. A collision here would let two workers
// write the same key with independent counters, silently breaking per-key version
// monotonicity — the whole reorder proof depends on this not happening.
func TestOwnedKeyIDSingleOwner(t *testing.T) {
	configs := []struct{ workers int; keyspace int64 }{
		{1, 1}, {8, 8}, {8, 1000}, {4, 5}, {3, 100}, {16, 16}, {2, 1000},
	}
	for _, cfg := range configs {
		owner := map[int64]int{} // keyID -> first worker that claimed it
		for id := 0; id < cfg.workers; id++ {
			w := &Worker{ID: id, Workers: cfg.workers, KeySpaceSize: cfg.keyspace}
			// Probe more iterations than there are keys to exercise round-robin wrap.
			for n := int64(0); n < cfg.keyspace*2+5; n++ {
				k := w.ownedKeyID(n)
				if k < 0 || k >= cfg.keyspace {
					t.Fatalf("cfg %+v worker %d: ownedKeyID(%d)=%d out of [0,%d)", cfg, id, n, k, cfg.keyspace)
				}
				if prev, ok := owner[k]; ok && prev != id {
					t.Fatalf("cfg %+v: key %d owned by BOTH worker %d and worker %d (single-owner violated)", cfg, k, prev, id)
				}
				owner[k] = id
				// Stride invariant: a worker only owns ids congruent to its ID mod workers.
				if int(k)%cfg.workers != id%cfg.workers {
					t.Fatalf("cfg %+v worker %d: key %d not in stride (%d %% %d != %d)", cfg, id, k, k, cfg.workers, id%cfg.workers)
				}
			}
		}
	}
}
