// $LAB/writer/prefix_test.go
package writer

import (
	"math/rand"
	"strings"
	"testing"
)

// TestParseKeyPrefixes covers the KEY_PREFIXES parsing contract: empty input is a
// no-op (nil, behavior unchanged), tokens are trimmed, and each token must be a
// single legal NATS subject token [A-Za-z0-9_-]+ (fail-loud otherwise).
func TestParseKeyPrefixes(t *testing.T) {
	t.Run("empty is nil", func(t *testing.T) {
		for _, in := range []string{"", "   ", "\t"} {
			got, err := parseKeyPrefixes(in)
			if err != nil || got != nil {
				t.Fatalf("parseKeyPrefixes(%q) = %v, %v; want nil, nil", in, got, err)
			}
		}
	})
	t.Run("trimmed and split", func(t *testing.T) {
		got, err := parseKeyPrefixes(" prefix-a , prefix_b,prefix-c ")
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		want := []string{"prefix-a", "prefix_b", "prefix-c"}
		if strings.Join(got, ",") != strings.Join(want, ",") {
			t.Fatalf("got %v, want %v", got, want)
		}
	})
	t.Run("illegal tokens rejected", func(t *testing.T) {
		for _, in := range []string{"a.b", "a b", "a,,b", "a,", "kv.cdc", "with*star", "with>gt"} {
			if _, err := parseKeyPrefixes(in); err == nil {
				t.Fatalf("parseKeyPrefixes(%q) should have errored", in)
			}
		}
	})
}

// TestApplyKeyPrefixIdentityWhenEmpty is the golden no-regression guarantee:
// with no prefixes configured the key is returned byte-for-byte unchanged.
func TestApplyKeyPrefixIdentityWhenEmpty(t *testing.T) {
	keys := []string{
		"lb:company:active:{employees:55688}",
		"lb:general:standby:{items:1}",
		"lb:hash:active:{profiles:9}",
	}
	for _, k := range keys {
		if got := applyKeyPrefix(nil, 42, k); got != k {
			t.Fatalf("applyKeyPrefix(nil,...,%q) = %q, want unchanged", k, got)
		}
		if got := applyKeyPrefix([]string{}, 42, k); got != k {
			t.Fatalf("applyKeyPrefix([],...,%q) = %q, want unchanged", k, got)
		}
	}
}

// TestApplyKeyPrefixDeterministicByEntity locks the correctness premise: the prefix
// is chosen by entity id (prefixes[id % N]) so it is identical for every key of the
// same entity, and it becomes the first colon-delimited segment of the key.
func TestApplyKeyPrefixDeterministicByEntity(t *testing.T) {
	prefixes := []string{"prefix-a", "prefix-b", "prefix-c", "prefix-d"}
	for id := int64(0); id < 40; id++ {
		want := prefixes[id%int64(len(prefixes))]
		std := applyKeyPrefix(prefixes, id, "lb:company:standby:{employees:1}")
		act := applyKeyPrefix(prefixes, id, "lb:company:active:{employees:1}")
		if first := strings.SplitN(std, ":", 2)[0]; first != want {
			t.Fatalf("id=%d first segment = %q, want %q", id, first, want)
		}
		// active and standby of the SAME entity must resolve to the SAME prefix
		if strings.SplitN(std, ":", 2)[0] != strings.SplitN(act, ":", 2)[0] {
			t.Fatalf("id=%d standby/active landed on different prefixes: %q vs %q", id, std, act)
		}
		// hash tag preserved
		if !strings.Contains(std, "{employees:1}") {
			t.Fatalf("hash tag lost: %q", std)
		}
	}
}

// TestApplyKeyPrefixSingleAndDuplicate covers the N=1 edge (id%1==0 -> always the
// one prefix) and duplicate prefixes (still deterministic, still a valid token).
func TestApplyKeyPrefixSingleAndDuplicate(t *testing.T) {
	k := "lb:company:active:{employees:3}"
	for id := int64(0); id < 10; id++ {
		if got := applyKeyPrefix([]string{"only"}, id, k); got != "only:"+k {
			t.Fatalf("N=1 id=%d got %q", id, got)
		}
	}
	// duplicates: index still deterministic by id%len; both map to "dup"
	for id := int64(0); id < 10; id++ {
		if first := strings.SplitN(applyKeyPrefix([]string{"dup", "dup"}, id, k), ":", 2)[0]; first != "dup" {
			t.Fatalf("dup id=%d first=%q", id, first)
		}
	}
}

// TestBuildEventAppliesPrefixConsistently proves the rename event's old and new
// keys share one prefix (both derived from one entity id), which is what keeps a
// standby->active promotion on a single subject/consumer.
func TestBuildEventAppliesPrefixConsistently(t *testing.T) {
	prefixes := []string{"prefix-a", "prefix-b", "prefix-c", "prefix-d"}
	w := &Worker{Mix: OpMix{Rename: 1}, KeySpaceSize: 100, Prefixes: prefixes, rng: rand.New(rand.NewSource(1))}
	for i := 0; i < 200; i++ {
		e := w.buildEvent(uint64(i))
		op, on := strings.SplitN(e.OldKey, ":", 2)[0], strings.SplitN(e.NewKey, ":", 2)[0]
		if op != on {
			t.Fatalf("rename old/new prefixes differ: %q vs %q", e.OldKey, e.NewKey)
		}
		found := false
		for _, p := range prefixes {
			if p == op {
				found = true
			}
		}
		if !found {
			t.Fatalf("prefix %q not in configured set", op)
		}
		// original lifecycle still holds under the prefix
		if !strings.Contains(e.OldKey, ":standby:") || !strings.Contains(e.NewKey, ":active:") {
			t.Fatalf("rename lifecycle broken under prefix: %q -> %q", e.OldKey, e.NewKey)
		}
	}
}

// TestBuildEventNoPrefixUnchanged confirms that with no prefixes the emitted keys
// keep the original leading "lb:" family segment (no injected prefix).
func TestBuildEventNoPrefixUnchanged(t *testing.T) {
	w := &Worker{Mix: OpMix{Create: 1}, KeySpaceSize: 100, rng: rand.New(rand.NewSource(1))}
	e := w.buildEvent(0)
	if !strings.HasPrefix(e.KvKey, "lb:") {
		t.Fatalf("without KEY_PREFIXES the key must start with lb:, got %q", e.KvKey)
	}
}
