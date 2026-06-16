// Parse a cdc:latency stream entry's field map into a Sample.
package main

import (
	"fmt"
	"strconv"
)

// ParseSample converts XRANGE entry fields into a Sample. Only create/update
// are expected (the sink emits no latency record for delete/rename).
func ParseSample(fields map[string]string) (Sample, error) {
	op := fields["op"]
	if op != "create" && op != "update" {
		return Sample{}, fmt.Errorf("unexpected op %q", op)
	}
	wts, err := strconv.ParseInt(fields["writer_ts"], 10, 64)
	if err != nil {
		return Sample{}, fmt.Errorf("writer_ts %q: %w", fields["writer_ts"], err)
	}
	sts, err := strconv.ParseInt(fields["sink_ts"], 10, 64)
	if err != nil {
		return Sample{}, fmt.Errorf("sink_ts %q: %w", fields["sink_ts"], err)
	}
	return Sample{Op: op, LatencyMs: sts - wts, SinkTs: sts}, nil
}
