package main

import (
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestLoadConfigDefaults(t *testing.T) {
	cfg := LoadConfig(func(string) string { return "" })
	require.Equal(t, "deterministic", cfg.Profile)
	require.Equal(t, 60, cfg.MsgCount)
	require.Equal(t, 200, cfg.SleepMS)
	require.Equal(t, 1, cfg.PipelineThreads)
	require.Equal(t, 5*time.Second, cfg.AckWait)
	require.InDelta(t, 0.3, cfg.ArmFraction, 1e-9)
	require.Equal(t, "source_leg", cfg.StreamID)
	require.Equal(t, 1, cfg.MinInflight) // default: require at least 1 in-flight
}

func TestLoadConfigOverrides(t *testing.T) {
	env := map[string]string{
		"PROFILE": "throughput", "MSG_COUNT": "20000", "SLEEP_MS": "25",
		"PIPELINE_THREADS": "8", "ACK_WAIT": "7s", "ARM_INFLIGHT": "250",
		"PUBLISH_RATE": "5000", "MAX_ACK_PENDING": "2000", "MIN_INFLIGHT": "4",
	}
	cfg := LoadConfig(func(k string) string { return env[k] })
	require.Equal(t, "throughput", cfg.Profile)
	require.Equal(t, 20000, cfg.MsgCount)
	require.Equal(t, 25, cfg.SleepMS)
	require.Equal(t, 8, cfg.PipelineThreads)
	require.Equal(t, 7*time.Second, cfg.AckWait)
	require.Equal(t, 250, cfg.ArmInflight)
	require.Equal(t, 5000, cfg.PublishRate)
	require.Equal(t, 2000, cfg.MaxAckPending)
	require.Equal(t, 4, cfg.MinInflight)
}
