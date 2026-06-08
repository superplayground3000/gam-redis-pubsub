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

func newEventID() string { return uuid.NewString() }

func makePad(n int) string { return strings.Repeat("x", n) }

// payloadJSON is the snapshot body carried in the stream value field.
func payloadJSON(eventID string, tsMs, version int64, pad string) string {
	b, _ := json.Marshal(map[string]any{
		"event_id": eventID,
		"ts_ns":    time.Now().UnixNano(),
		"version":  version,
		"pad":      pad,
	})
	return string(b)
}
