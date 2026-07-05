// $LAB/writer/payload.go
package writer

import (
	"encoding/json"
	"strings"
	"time"

	"github.com/google/uuid"
)

// Event is the CDC envelope. Per research-design §3, every field except body
// becomes Redpanda Connect metadata; body_key=body points at the JSON snapshot.
type Event struct {
	EventID string
	Op      string // create|update|delete|rename
	Type    string // string|hash (hash applies HSET; default string)
	KvKey   string // create/update/delete
	OldKey  string // rename
	NewKey  string // rename
	TsMs    int64
	Body    string            // JSON snapshot (string) or JSON field-map (hash); "" for delete/rename
	Fields  map[string]string // hash field map (nil for strings); source of Body + central HSET
}

func nowMs() int64 { return time.Now().UnixMilli() }

// snapshot builds an opaque JSON body of roughly padBytes size. The body is
// INDEPENDENT of the Redis key it lives under: production values never embed their
// own key, so neither does this synthetic payload. It carries its own random value
// id (vid), not the key. This independence is exactly what makes a value-preserving
// rename correct — moving the opaque value to a new key changes nothing inside it.
func snapshot(padBytes int) string {
	b, _ := json.Marshal(map[string]any{
		"vid": uuid.NewString(),
		"ts":  nowMs(),
		"pad": strings.Repeat("x", padBytes),
	})
	return string(b)
}

func NewCreateEvent(kvKey string, padBytes int) Event {
	return Event{EventID: uuid.NewString(), Op: "create", Type: "string", KvKey: kvKey, TsMs: nowMs(), Body: snapshot(padBytes)}
}

func NewUpdateEvent(kvKey string, padBytes int) Event {
	return Event{EventID: uuid.NewString(), Op: "update", Type: "string", KvKey: kvKey, TsMs: nowMs(), Body: snapshot(padBytes)}
}

func NewDeleteEvent(kvKey string) Event {
	return Event{EventID: uuid.NewString(), Op: "delete", Type: "string", KvKey: kvKey, TsMs: nowMs(), Body: ""}
}

// NewRenameEvent carries NO body: rename is value-preserving end-to-end (both the
// central apply and the sink use RENAME, so new_key inherits old_key's existing
// value). The empty Body is intentional — there is nothing to snapshot.
func NewRenameEvent(oldKey, newKey string) Event {
	return Event{EventID: uuid.NewString(), Op: "rename", Type: "string", OldKey: oldKey, NewKey: newKey, TsMs: nowMs()}
}

// NewCreateHashEvent / NewUpdateHashEvent carry a hash field map. Body is the
// canonical JSON of the same map (encoding/json sorts map keys), so the stream
// payload the sink reads and the central HSET the writer applies derive from one
// source. create/update differ only in Op; both merge fields (no field clearing).
func NewCreateHashEvent(kvKey string, fields map[string]string) Event {
	return newHashEvent("create", kvKey, fields)
}

func NewUpdateHashEvent(kvKey string, fields map[string]string) Event {
	return newHashEvent("update", kvKey, fields)
}

func newHashEvent(op, kvKey string, fields map[string]string) Event {
	b, _ := json.Marshal(fields)
	return Event{
		EventID: uuid.NewString(), Op: op, Type: "hash",
		KvKey: kvKey, TsMs: nowMs(), Body: string(b), Fields: fields,
	}
}

// StreamValues returns the XADD field list as an ordered slice (NOT a map —
// go-redis loses field order with a map; the source pipeline reads these as
// metadata). body_key=body, so "body" carries the JSON snapshot.
func (e Event) StreamValues() []any {
	return []any{
		"event_id", e.EventID,
		"op", e.Op,
		"type", e.Type,
		"kv_key", e.KvKey,
		"old_key", e.OldKey,
		"new_key", e.NewKey,
		"ts", e.TsMs,
		"body", e.Body,
	}
}
