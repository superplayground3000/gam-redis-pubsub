package main

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestArmedDeterministic(t *testing.T) {
	in := ArmInput{Profile: "deterministic", N: 100, ArmFraction: 0.3, MinInflight: 1}
	in.AppliedDistinct = 29
	require.False(t, Armed(in))
	// fraction met but no in-flight cohort: must not fire (inconclusive guard)
	in.AppliedDistinct = 30
	require.False(t, Armed(in))
	// fraction met AND in-flight cohort present (>= MinInflight=1): fires
	in.NumAckPending = 1
	require.True(t, Armed(in))
}

func TestArmedThroughput(t *testing.T) {
	// ARM_INFLIGHT=200, N=1000, MIN_INFLIGHT=1: fires when NumPending <= 800
	// (>=200 dispatched) and at least MinInflight=1 message is in-flight.
	in := ArmInput{Profile: "throughput", ArmInflight: 200, N: 1000, MinInflight: 1}

	// Not enough dispatched yet (only 100 delivered so pending=900>800)
	in.NumPending = 900
	in.NumAckPending = 5
	require.False(t, Armed(in))

	// Enough dispatched (pending=800 == N-ArmInflight) but nothing in-flight: don't fire
	in.NumPending = 800
	in.NumAckPending = 0
	require.False(t, Armed(in))

	// Enough dispatched and work is in-flight (>= MinInflight=1): fires
	in.NumPending = 800
	in.NumAckPending = 5
	require.True(t, Armed(in))

	// Far into processing, still fires as long as >= MinInflight messages in-flight
	in.NumPending = 0
	in.NumAckPending = 3
	require.True(t, Armed(in))
}

func TestArmedThroughputMinInflight(t *testing.T) {
	// With MIN_INFLIGHT=4, the throughput arm must NOT fire when NumAckPending < 4
	// even if the backlog condition (NumPending <= N-ArmInflight) is met.
	in := ArmInput{Profile: "throughput", ArmInflight: 200, N: 1000, MinInflight: 4}

	// Backlog condition met, but only 3 messages in-flight — below MinInflight=4.
	in.NumPending = 800
	in.NumAckPending = 3
	require.False(t, Armed(in), "must NOT arm: NumAckPending=%d < MinInflight=%d", in.NumAckPending, in.MinInflight)

	// Backlog condition met and exactly MinInflight=4 messages in-flight: fires.
	in.NumAckPending = 4
	require.True(t, Armed(in), "must arm: NumAckPending=%d >= MinInflight=%d", in.NumAckPending, in.MinInflight)

	// Backlog condition met and more than MinInflight in-flight: still fires.
	in.NumAckPending = 7
	require.True(t, Armed(in))
}
