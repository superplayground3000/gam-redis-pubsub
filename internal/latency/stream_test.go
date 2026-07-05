package latency

import "testing"

func TestParseSampleOK(t *testing.T) {
	got, err := ParseSample(map[string]string{
		"op": "update", "kv_key": "k", "writer_ts": "100", "sink_ts": "150",
	})
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	want := Sample{Op: "update", LatencyMs: 50, SinkTs: 150}
	if got != want {
		t.Errorf("ParseSample=%+v want %+v", got, want)
	}
}

func TestParseSampleErrors(t *testing.T) {
	cases := map[string]map[string]string{
		"bad op":      {"op": "delete", "writer_ts": "1", "sink_ts": "2"},
		"missing sts": {"op": "create", "writer_ts": "1"},
		"nonnumeric":  {"op": "create", "writer_ts": "abc", "sink_ts": "2"},
	}
	for name, f := range cases {
		if _, err := ParseSample(f); err == nil {
			t.Errorf("%s: expected error, got nil", name)
		}
	}
}
