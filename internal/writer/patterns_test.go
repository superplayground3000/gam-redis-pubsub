// $LAB/writer/patterns_test.go
package writer

import (
	"strings"
	"testing"
)

func TestActiveKeyHashTagged(t *testing.T) {
	got := Patterns[0].ActiveKey(55688)
	want := "lb:company:active:{employees:55688}"
	if got != want {
		t.Fatalf("ActiveKey = %q, want %q", got, want)
	}
}

func hashTag(s string) string {
	i, j := strings.Index(s, "{"), strings.Index(s, "}")
	if i < 0 || j < 0 || j < i {
		return ""
	}
	return s[i : j+1]
}

func TestStandbyActiveSameSlotAllPatterns(t *testing.T) {
	// Every pattern must expose a standby form whose {entity:id} hash tag matches
	// its active form, so the standby->active RENAME stays in one Redis slot.
	if Patterns[0].StandbyKey(55688) != "lb:company:standby:{employees:55688}" {
		t.Fatalf("company standby key wrong: %q", Patterns[0].StandbyKey(55688))
	}
	for _, p := range Patterns {
		if !p.HasStandby() {
			t.Fatalf("pattern %q must have a standby form for the rename flow", p.Name)
		}
		active, standby := p.ActiveKey(7), p.StandbyKey(7)
		if active == standby {
			t.Fatalf("pattern %q: active and standby must differ", p.Name)
		}
		if ta, ts := hashTag(active), hashTag(standby); ta == "" || ta != ts {
			t.Fatalf("pattern %q: active/standby must share a hash tag: %q vs %q", p.Name, ta, ts)
		}
	}
}

func TestAllThreePatternsPresent(t *testing.T) {
	if len(Patterns) != 3 {
		t.Fatalf("want 3 patterns, got %d", len(Patterns))
	}
	wants := []string{
		"lb:company:active:{employees:7}",
		"lb:funtions:active:{groups:7}",
		"lb:general:active:{items:7}",
	}
	for i, w := range wants {
		if got := Patterns[i].ActiveKey(7); got != w {
			t.Fatalf("pattern %d ActiveKey = %q, want %q", i, got, w)
		}
	}
}
