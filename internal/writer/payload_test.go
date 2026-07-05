// $LAB/writer/payload_test.go
package writer

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

func TestStringEventTypeIsString(t *testing.T) {
	if e := NewCreateEvent("k", 8); e.Type != "string" {
		t.Fatalf("string event must have type=string, got %q", e.Type)
	}
	if e := NewDeleteEvent("k"); e.Type != "string" {
		t.Fatalf("delete event must have type=string, got %q", e.Type)
	}
}

func TestCreateHashEvent(t *testing.T) {
	fields := map[string]string{"name": "a", "tier": "pro"}
	e := NewCreateHashEvent("lb:hash:active:{profiles:1}", fields)
	if e.Op != "create" || e.Type != "hash" {
		t.Fatalf("bad hash create: %+v", e)
	}
	if len(e.Fields) != 2 {
		t.Fatalf("fields not stored: %+v", e)
	}
	var body map[string]string
	if err := json.Unmarshal([]byte(e.Body), &body); err != nil {
		t.Fatalf("body not JSON: %v", err)
	}
	if body["name"] != "a" || body["tier"] != "pro" {
		t.Fatalf("body must equal field map: %v", body)
	}
}

func TestUpdateHashEventOp(t *testing.T) {
	e := NewUpdateHashEvent("k", map[string]string{"f": "v"})
	if e.Op != "update" || e.Type != "hash" {
		t.Fatalf("bad hash update: %+v", e)
	}
}

func TestStreamValuesIncludesType(t *testing.T) {
	vals := NewCreateHashEvent("k", map[string]string{"f": "v"}).StreamValues()
	found := false
	for i := 0; i+1 < len(vals); i += 2 {
		if vals[i] == "type" && vals[i+1] == "hash" {
			found = true
		}
	}
	if !found {
		t.Fatalf("StreamValues missing type=hash: %v", vals)
	}
}
