package main

import (
	"strconv"
	"time"
)

type Config struct {
	Profile         string
	MsgCount        int
	PublishRate     int
	SleepMS         int
	PipelineThreads int
	AckWait         time.Duration
	ArmFraction     float64
	ArmInflight     int
	MaxAckPending   int
	// MinInflight is the minimum number of messages that must be simultaneously
	// in-flight inside Connect (num_ack_pending) for a DELETE to count as landing
	// mid-flight. Bounded by PIPELINE_THREADS. Default 1; raise to e.g. 4 with
	// PIPELINE_THREADS=8 for a stronger throughput proof.
	MinInflight int
	NATSURL     string
	RedisAddr   string
	ConnectAddr string
	StreamID    string
	HealthAddr  string
}

func LoadConfig(get func(string) string) Config {
	return Config{
		Profile:         str(get, "PROFILE", "deterministic"),
		MsgCount:        num(get, "MSG_COUNT", 60),
		PublishRate:     num(get, "PUBLISH_RATE", 0),
		SleepMS:         num(get, "SLEEP_MS", 200),
		PipelineThreads: num(get, "PIPELINE_THREADS", 1),
		AckWait:         dur(get, "ACK_WAIT", 5*time.Second),
		ArmFraction:     flt(get, "ARM_FRACTION", 0.3),
		ArmInflight:     num(get, "ARM_INFLIGHT", 200),
		MaxAckPending:   num(get, "MAX_ACK_PENDING", 1000),
		MinInflight:     num(get, "MIN_INFLIGHT", 1),
		NATSURL:         str(get, "NATS_URL", "nats://nats:4222"),
		RedisAddr:       str(get, "REDIS_ADDR", "redis:6379"),
		ConnectAddr:     str(get, "CONNECT_ADDR", "http://connect:4195"),
		StreamID:        str(get, "STREAM_ID", "source_leg"),
		HealthAddr:      str(get, "HEALTH_ADDR", ":18080"),
	}
}

func str(get func(string) string, k, def string) string {
	if v := get(k); v != "" {
		return v
	}
	return def
}
func num(get func(string) string, k string, def int) int {
	if v := get(k); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}
func flt(get func(string) string, k string, def float64) float64 {
	if v := get(k); v != "" {
		if f, err := strconv.ParseFloat(v, 64); err == nil {
			return f
		}
	}
	return def
}
func dur(get func(string) string, k string, def time.Duration) time.Duration {
	if v := get(k); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			return d
		}
	}
	return def
}
