package main

import (
	"encoding/json"
	"strings"
	"time"

	"github.com/google/uuid"
)

type Payload struct {
	EventID string `json:"event_id"`
	TsNs    int64  `json:"ts_ns"`
	Seq     int64  `json:"seq"`
	Pad     string `json:"pad"`
}

func NewPayload(seq int64, padBytes int) Payload {
	return Payload{
		EventID: uuid.NewString(),
		TsNs:    time.Now().UnixNano(),
		Seq:     seq,
		Pad:     strings.Repeat("x", padBytes),
	}
}

func (p Payload) JSON() ([]byte, error) {
	return json.Marshal(p)
}
