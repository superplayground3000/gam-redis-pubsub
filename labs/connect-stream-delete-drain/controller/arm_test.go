package main

import (
	"testing"

	"github.com/stretchr/testify/require"
)

func TestArmedDeterministic(t *testing.T) {
	in := ArmInput{Profile: "deterministic", N: 100, ArmFraction: 0.3}
	in.AppliedDistinct = 29
	require.False(t, Armed(in))
	in.AppliedDistinct = 30
	require.True(t, Armed(in))
}

func TestArmedThroughput(t *testing.T) {
	in := ArmInput{Profile: "throughput", ArmInflight: 200}
	in.NumAckPending = 199
	require.False(t, Armed(in))
	in.NumAckPending = 200
	require.True(t, Armed(in))
}
