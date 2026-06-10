// $LAB/verifier/redis_test.go
package main

import "testing"

func TestEventValuesOrder(t *testing.T) {
	vals := eventValues(map[string]string{"op": "create", "kv_key": "k", "event_id": "e", "body": "{}"})
	// must be an even-length key/value slice and include op/event_id
	if len(vals)%2 != 0 {
		t.Fatalf("odd-length values: %d", len(vals))
	}
	found := map[string]bool{}
	for i := 0; i < len(vals); i += 2 {
		found[vals[i].(string)] = true
	}
	for _, k := range []string{"event_id", "op", "kv_key", "old_key", "new_key", "ts", "body"} {
		if !found[k] {
			t.Fatalf("missing field %q in %v", k, vals)
		}
	}
}
