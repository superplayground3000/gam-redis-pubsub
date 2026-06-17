// Parse a cdc:latency stream entry's field map into a Sample.
package latency

import (
	"fmt"
	"math"
	"strconv"
)

// ParseSample converts XRANGE entry fields into a Sample. Only create/update
// are expected (the sink emits no latency record for delete/rename).
func ParseSample(fields map[string]string) (Sample, error) {
	op := fields["op"]
	if op != "create" && op != "update" {
		return Sample{}, fmt.Errorf("unexpected op %q", op)
	}
	wts, err := parseTSMillis(fields["writer_ts"])
	if err != nil {
		return Sample{}, fmt.Errorf("writer_ts %q: %w", fields["writer_ts"], err)
	}
	sts, err := parseTSMillis(fields["sink_ts"])
	if err != nil {
		return Sample{}, fmt.Errorf("sink_ts %q: %w", fields["sink_ts"], err)
	}
	return Sample{Op: op, LatencyMs: sts - wts, SinkTs: sts}, nil
}

// parseTSMillis parses an epoch-millis timestamp that may arrive either as an
// integer literal ("1781679315746") or as a float in scientific notation
// ("1.781679315746e+12") — the latter happens when an upstream transform (the
// sink's Lua/Connect step) formats the number as a double. ParseInt rejects the
// float form, so fall back to ParseFloat. The fallback only accepts floats that
// represent an exact integer in the int64-safe range: a fractional value is a
// malformed timestamp and is rejected rather than silently truncated.
func parseTSMillis(s string) (int64, error) {
	if n, err := strconv.ParseInt(s, 10, 64); err == nil {
		return n, nil
	}
	f, err := strconv.ParseFloat(s, 64)
	if err != nil {
		return 0, err
	}
	if f != math.Trunc(f) {
		return 0, fmt.Errorf("non-integer timestamp %q", s)
	}
	// math.MaxInt64 is not exactly float64-representable; 2^63 is the smallest
	// power of two above it, so reject anything that rounds to >= 2^63 (or the
	// negative counterpart) to avoid an out-of-range int64 conversion.
	if f >= 9.223372036854776e18 || f < -9.223372036854776e18 {
		return 0, fmt.Errorf("timestamp %q out of int64 range", s)
	}
	return int64(f), nil
}
