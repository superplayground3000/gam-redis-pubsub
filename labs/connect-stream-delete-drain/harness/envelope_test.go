package main

import "testing"

func TestValueForKeyEmbedsEventID(t *testing.T) {
	v := valueForKey(5, "eid-abc")
	if v != "val:5:eid-abc" {
		t.Fatalf("got %q", v)
	}
}

func TestParseValueIdentity(t *testing.T) {
	ok := valueMatches("kv:5", "eid-abc", "val:5:eid-abc")
	if !ok {
		t.Fatal("expected identity match")
	}
	if valueMatches("kv:5", "eid-abc", "val:5:OTHER") {
		t.Fatal("wrong event_id must not match")
	}
	if valueMatches("kv:5", "eid-abc", "val:6:eid-abc") {
		t.Fatal("wrong key index must not match")
	}
}

func TestEnvelopeJSONRoundTrip(t *testing.T) {
	e := Envelope{EventID: "e1", Op: "update", KVKey: "kv:1", Body: "val:1:e1", FaultMode: "none"}
	b, err := e.Marshal()
	if err != nil {
		t.Fatal(err)
	}
	got, err := UnmarshalEnvelope(b)
	if err != nil {
		t.Fatal(err)
	}
	if got != e {
		t.Fatalf("round-trip mismatch: %+v", got)
	}
}
