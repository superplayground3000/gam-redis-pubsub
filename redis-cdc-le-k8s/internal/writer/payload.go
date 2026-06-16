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
	KvKey   string // create/update/delete
	OldKey  string // rename
	NewKey  string // rename
	TsMs    int64
	Body    string // JSON snapshot; "" for delete
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
	return Event{EventID: uuid.NewString(), Op: "create", KvKey: kvKey, TsMs: nowMs(), Body: snapshot(padBytes)}
}

func NewUpdateEvent(kvKey string, padBytes int) Event {
	return Event{EventID: uuid.NewString(), Op: "update", KvKey: kvKey, TsMs: nowMs(), Body: snapshot(padBytes)}
}

func NewDeleteEvent(kvKey string) Event {
	return Event{EventID: uuid.NewString(), Op: "delete", KvKey: kvKey, TsMs: nowMs(), Body: ""}
}

// NewRenameEvent carries NO body: rename is value-preserving end-to-end (both the
// central apply and the sink use RENAME, so new_key inherits old_key's existing
// value). The empty Body is intentional — there is nothing to snapshot.
func NewRenameEvent(oldKey, newKey string) Event {
	return Event{EventID: uuid.NewString(), Op: "rename", OldKey: oldKey, NewKey: newKey, TsMs: nowMs()}
}

// StreamValues returns the XADD field list as an ordered slice (NOT a map —
// go-redis loses field order with a map; the source pipeline reads these as
// metadata). body_key=body, so "body" carries the JSON snapshot.
func (e Event) StreamValues() []any {
	return []any{
		"event_id", e.EventID,
		"op", e.Op,
		"kv_key", e.KvKey,
		"old_key", e.OldKey,
		"new_key", e.NewKey,
		"ts", e.TsMs,
		"body", e.Body,
	}
}
