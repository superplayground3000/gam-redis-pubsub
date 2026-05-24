package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestNewPayloadShapeAndFields(t *testing.T) {
	p := NewPayload(42, 200)
	if p.Seq != 42 {
		t.Errorf("Seq=%d, want 42", p.Seq)
	}
	if p.EventID == "" {
		t.Errorf("EventID is empty")
	}
	if p.TsNs == 0 {
		t.Errorf("TsNs is zero")
	}
	if len(p.Pad) != 200 {
		t.Errorf("Pad len=%d, want 200", len(p.Pad))
	}
}

func TestPayloadJSONRoundTrip(t *testing.T) {
	p := NewPayload(7, 50)
	b, err := p.JSON()
	if err != nil {
		t.Fatalf("JSON err: %v", err)
	}
	if !strings.Contains(string(b), `"seq":7`) {
		t.Errorf("missing seq field: %s", b)
	}
	var back Payload
	if err := json.Unmarshal(b, &back); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if back.EventID != p.EventID {
		t.Errorf("EventID mismatch")
	}
	if back.TsNs != p.TsNs {
		t.Errorf("TsNs mismatch")
	}
}

func TestNewPayloadEventIDsAreUnique(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 100; i++ {
		p := NewPayload(int64(i), 10)
		if seen[p.EventID] {
			t.Fatalf("duplicate EventID at i=%d: %s", i, p.EventID)
		}
		seen[p.EventID] = true
	}
}
