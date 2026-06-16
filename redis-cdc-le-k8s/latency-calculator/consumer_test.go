package main

import (
	"context"
	"errors"
	"testing"

	"github.com/redis/go-redis/v9"
)

// xrangeResult is one canned XRANGE page (msgs OR err).
type xrangeResult struct {
	msgs []redis.XMessage
	err  error
}

// fakeReader serves canned XRevRangeN (Seek) and a queue of XRangeN pages.
type fakeReader struct {
	revMsgs []redis.XMessage // tail entry for Seek
	revErr  error
	pages   []xrangeResult // consumed in order by successive XRangeN calls
	calls   int            // XRangeN call count
}

func (f *fakeReader) XRevRangeN(ctx context.Context, stream, start, stop string, count int64) *redis.XMessageSliceCmd {
	cmd := redis.NewXMessageSliceCmd(ctx)
	if f.revErr != nil {
		cmd.SetErr(f.revErr)
	} else {
		cmd.SetVal(f.revMsgs)
	}
	return cmd
}

func (f *fakeReader) XRangeN(ctx context.Context, stream, start, stop string, count int64) *redis.XMessageSliceCmd {
	cmd := redis.NewXMessageSliceCmd(ctx)
	if f.calls >= len(f.pages) {
		// No more canned pages: behave like an empty stream.
		cmd.SetVal(nil)
		return cmd
	}
	p := f.pages[f.calls]
	f.calls++
	if p.err != nil {
		cmd.SetErr(p.err)
	} else {
		cmd.SetVal(p.msgs)
	}
	return cmd
}

func msg(id string) redis.XMessage {
	return redis.XMessage{ID: id, Values: map[string]interface{}{
		"op": "create", "kv_key": "k", "writer_ts": "100", "sink_ts": "150",
	}}
}

// fullPage builds a pageSize-length page whose last entry has id lastID, so Poll
// keeps looping (len == pageSize).
func fullPage(lastID string) []redis.XMessage {
	out := make([]redis.XMessage, pageSize)
	for i := 0; i < pageSize-1; i++ {
		out[i] = msg("p-" + itoa(i))
	}
	out[pageSize-1] = msg(lastID)
	return out
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	return string(b[i:])
}

func TestSeekEmptyStreamStaysAtZero(t *testing.T) {
	f := &fakeReader{revMsgs: nil}
	c := NewConsumer(f, "cdc:latency")
	if err := c.Seek(context.Background()); err != nil {
		t.Fatalf("seek: %v", err)
	}
	if c.lastID != "0-0" {
		t.Errorf("lastID=%q want 0-0 on empty stream", c.lastID)
	}
}

func TestSeekTailAdvancesCursor(t *testing.T) {
	f := &fakeReader{revMsgs: []redis.XMessage{msg("42-0")}}
	c := NewConsumer(f, "cdc:latency")
	if err := c.Seek(context.Background()); err != nil {
		t.Fatalf("seek: %v", err)
	}
	if c.lastID != "42-0" {
		t.Errorf("lastID=%q want 42-0", c.lastID)
	}
}

func TestPollSinglePageDrains(t *testing.T) {
	f := &fakeReader{pages: []xrangeResult{
		{msgs: []redis.XMessage{msg("1-0"), msg("2-0"), msg("3-0")}},
	}}
	c := NewConsumer(f, "cdc:latency")
	out, err := c.Poll(context.Background())
	if err != nil {
		t.Fatalf("poll: %v", err)
	}
	if len(out) != 3 {
		t.Errorf("got %d samples want 3", len(out))
	}
	if c.lastID != "3-0" {
		t.Errorf("cursor=%q want 3-0", c.lastID)
	}
}

func TestPollMalformedSkippedCursorAdvances(t *testing.T) {
	bad := redis.XMessage{ID: "2-0", Values: map[string]interface{}{
		"op": "delete", "writer_ts": "1", "sink_ts": "2", // bad op
	}}
	f := &fakeReader{pages: []xrangeResult{
		{msgs: []redis.XMessage{msg("1-0"), bad, msg("3-0")}},
	}}
	c := NewConsumer(f, "cdc:latency")
	out, err := c.Poll(context.Background())
	if err != nil {
		t.Fatalf("poll: %v", err)
	}
	if len(out) != 2 {
		t.Errorf("got %d samples want 2 (bad entry skipped)", len(out))
	}
	if c.lastID != "3-0" {
		t.Errorf("cursor=%q want 3-0 (advanced past skipped entry)", c.lastID)
	}
}

func TestPollTwoPageDrain(t *testing.T) {
	f := &fakeReader{pages: []xrangeResult{
		{msgs: fullPage("first-last-0")},
		{msgs: []redis.XMessage{msg("x-0"), msg("y-0")}},
	}}
	c := NewConsumer(f, "cdc:latency")
	out, err := c.Poll(context.Background())
	if err != nil {
		t.Fatalf("poll: %v", err)
	}
	if len(out) != pageSize+2 {
		t.Errorf("got %d samples want %d (both pages)", len(out), pageSize+2)
	}
	if f.calls != 2 {
		t.Errorf("XRangeN calls=%d want 2", f.calls)
	}
	if c.lastID != "y-0" {
		t.Errorf("cursor=%q want y-0", c.lastID)
	}
}

func TestPollSecondPageErrorReturnsFirstPage(t *testing.T) {
	f := &fakeReader{pages: []xrangeResult{
		{msgs: fullPage("first-last-0")},
		{err: errors.New("boom")},
	}}
	c := NewConsumer(f, "cdc:latency")
	out, err := c.Poll(context.Background())
	if err == nil {
		t.Fatalf("expected error from second page")
	}
	if len(out) != pageSize {
		t.Errorf("got %d samples want %d (first page returned despite error)", len(out), pageSize)
	}
	// Cursor advanced only across delivered (first-page) entries.
	if c.lastID != "first-last-0" {
		t.Errorf("cursor=%q want first-last-0", c.lastID)
	}
}
