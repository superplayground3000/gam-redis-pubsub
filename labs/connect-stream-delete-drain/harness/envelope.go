package main

import (
	"encoding/json"
	"fmt"
)

// Envelope is the self-contained CDC message published to JetStream.
// One message per key; Body embeds the event_id for per-message-instance identity.
type Envelope struct {
	EventID   string `json:"event_id"`
	Op        string `json:"op"`
	KVKey     string `json:"kv_key"`
	Body      string `json:"body"`
	FaultMode string `json:"fault_mode"` // "none" | "first" | "always"
}

func (e Envelope) Marshal() ([]byte, error) { return json.Marshal(e) }

func UnmarshalEnvelope(b []byte) (Envelope, error) {
	var e Envelope
	err := json.Unmarshal(b, &e)
	return e, err
}

// valueForKey is the applied value for key index i: "val:<i>:<event_id>".
func valueForKey(i int, eventID string) string {
	return fmt.Sprintf("val:%d:%s", i, eventID)
}

// valueMatches verifies a region value carries THIS key's own event_id
// (per-message-instance identity). key is like "kv:5".
func valueMatches(key, eventID, got string) bool {
	var idx int
	if _, err := fmt.Sscanf(key, "kv:%d", &idx); err != nil {
		return false
	}
	return got == valueForKey(idx, eventID)
}
