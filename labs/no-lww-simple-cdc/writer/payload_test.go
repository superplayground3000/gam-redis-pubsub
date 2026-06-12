// $LAB/writer/payload_test.go
package main

import (
	"encoding/json"
	"testing"
)

func TestCreateEventFields(t *testing.T) {
	e := NewCreateEvent("lb:general:active:{items:1}", 64)
	if e.Op != "create" || e.KvKey != "lb:general:active:{items:1}" {
		t.Fatalf("bad create event: %+v", e)
	}
	if e.EventID == "" || e.TsMs == 0 || e.Body == "" {
		t.Fatalf("missing event_id/ts/body: %+v", e)
	}
	var body map[string]any
	if err := json.Unmarshal([]byte(e.Body), &body); err != nil {
		t.Fatalf("body not JSON: %v", err)
	}
}

func TestDeleteEventEmptyBody(t *testing.T) {
	e := NewDeleteEvent("lb:company:active:{employees:2}")
	if e.Op != "delete" || e.Body != "" {
		t.Fatalf("delete must have empty body: %+v", e)
	}
}

func TestRenameEventKeys(t *testing.T) {
	e := NewRenameEvent("lb:company:standby:{employees:3}", "lb:company:active:{employees:3}")
	if e.Op != "rename" || e.OldKey == "" || e.NewKey == "" {
		t.Fatalf("bad rename event: %+v", e)
	}
	if e.Body != "" {
		t.Fatalf("value-preserving rename must carry empty body: %+v", e)
	}
	if e.KvKey != "" {
		t.Fatalf("rename must not set kv_key: %+v", e)
	}
}

func TestStreamValuesOrderedSlice(t *testing.T) {
	// go-redis XADD must use an ordered slice, not a map (field order matters).
	e := NewCreateEvent("k", 8)
	vals := e.StreamValues()
	if len(vals)%2 != 0 {
		t.Fatalf("StreamValues must be key/value pairs, got %d elems", len(vals))
	}
	if vals[0] != "event_id" {
		t.Fatalf("first field must be event_id, got %v", vals[0])
	}
}
