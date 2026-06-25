package main

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestArmedDeterministic(t *testing.T) {
	in := ArmInput{Profile: "deterministic", N: 100, ArmFraction: 0.3}
	in.AppliedDistinct = 29
	require.False(t, Armed(in))
	// fraction met but no in-flight cohort: must not fire (inconclusive guard)
	in.AppliedDistinct = 30
	require.False(t, Armed(in))
	// fraction met AND in-flight cohort present: fires
	in.NumAckPending = 1
	require.True(t, Armed(in))
}

func TestArmedThroughput(t *testing.T) {
	// ARM_INFLIGHT=200, N=1000: fires when NumPending <= 800 (>=200 dispatched)
	// and at least one message is in-flight (NumAckPending > 0).
	in := ArmInput{Profile: "throughput", ArmInflight: 200, N: 1000}

	// Not enough dispatched yet (only 100 delivered so pending=900>800)
	in.NumPending = 900
	in.NumAckPending = 5
	require.False(t, Armed(in))

	// Enough dispatched (pending=800 == N-ArmInflight) but nothing in-flight: don't fire
	in.NumPending = 800
	in.NumAckPending = 0
	require.False(t, Armed(in))

	// Enough dispatched and work is in-flight: fires
	in.NumPending = 800
	in.NumAckPending = 5
	require.True(t, Armed(in))

	// Far into processing, still fires as long as something is in-flight
	in.NumPending = 0
	in.NumAckPending = 3
	require.True(t, Armed(in))
}
