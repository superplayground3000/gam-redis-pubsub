package main

import (
	"testing"

	"github.com/stretchr/testify/require"
)

// all keys applied exactly once, consumer drained, DELETE landed mid-flight → PASS
func TestReconcileCleanDrain(t *testing.T) {
	applied := map[int]int{1: 1, 2: 1, 3: 1}
	v := Reconcile("deterministic", 3, 2, applied, ConsumerState{0, 0})
	require.True(t, v.Verdict.Pass)
	require.Empty(t, v.Lost)
	require.Equal(t, 0, v.DupCount)
	require.True(t, v.Drained)
}

// some keys applied twice (redelivery) → still PASS, dup_count counted
func TestReconcileDuplicatesPass(t *testing.T) {
	applied := map[int]int{1: 1, 2: 2, 3: 2}
	v := Reconcile("deterministic", 3, 2, applied, ConsumerState{0, 0})
	require.True(t, v.Verdict.Pass)
	require.Equal(t, 2, v.DupCount)
}

// a missing key with a drained consumer = acked-but-not-applied → FAIL, listed
func TestReconcileLossFails(t *testing.T) {
	applied := map[int]int{1: 1, 2: 0, 3: 1}
	v := Reconcile("deterministic", 3, 2, applied, ConsumerState{0, 0})
	require.False(t, v.Verdict.Pass)
	require.Equal(t, []int{2}, v.Lost)
}

// consumer not drained → FAIL (cannot conclude conservation)
func TestReconcileNotDrainedFails(t *testing.T) {
	applied := map[int]int{1: 1, 2: 1, 3: 1}
	v := Reconcile("deterministic", 3, 2, applied, ConsumerState{NumPending: 1})
	require.False(t, v.Verdict.Pass)
	require.False(t, v.Drained)
}

// DELETE never landed mid-flight → inconclusive → FAIL
func TestReconcileInconclusiveFails(t *testing.T) {
	applied := map[int]int{1: 1, 2: 1, 3: 1}
	v := Reconcile("deterministic", 3, 0, applied, ConsumerState{0, 0})
	require.False(t, v.Verdict.Pass)
}

// Lost serializes as [] not null when empty
func TestReconcileLostNeverNil(t *testing.T) {
	v := Reconcile("deterministic", 1, 1, map[int]int{1: 1}, ConsumerState{0, 0})
	require.NotNil(t, v.Lost)
}
