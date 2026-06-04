package main

import "testing"

func TestLWWVerdictPassRequiresAllConditions(t *testing.T) {
	base := LWWResult{
		KeysChecked: 1000, Mismatches: 0, Regressions: 0,
		Applied: 50000, Stale: 1200, Duplicate: 30,
		RateAchievedAvg: 4800, RateTarget: 5000,
		BootOK: true, StoreEmptyAtStart: true,
	}
	if v := ComputeLWWVerdict(base); !v.Pass {
		t.Fatalf("expected pass, got %+v", v)
	}

	// stale==0 → inconclusive (no reordering exercised)
	noReorder := base
	noReorder.Stale = 0
	if v := ComputeLWWVerdict(noReorder); v.Pass {
		t.Fatal("stale==0 must NOT pass (inconclusive)")
	}

	// mismatch → fail
	mm := base
	mm.Mismatches = 3
	if v := ComputeLWWVerdict(mm); v.Pass {
		t.Fatal("mismatches>0 must fail")
	}

	// precondition violated (boot changed) → fail even if everything else is green
	boot := base
	boot.BootOK = false
	if v := ComputeLWWVerdict(boot); v.Pass {
		t.Fatal("boot_ok=false must fail (precondition violated)")
	}

	// store not empty at start → fail
	store := base
	store.StoreEmptyAtStart = false
	if v := ComputeLWWVerdict(store); v.Pass {
		t.Fatal("store_empty_at_start=false must fail")
	}

	// no throughput → fail
	rate := base
	rate.RateAchievedAvg = 0
	if v := ComputeLWWVerdict(rate); v.Pass {
		t.Fatal("rate_achieved_avg==0 must fail")
	}
}

func TestLWWVerdictReasonIsSpecific(t *testing.T) {
	r := LWWResult{KeysChecked: 10, Mismatches: 0, Regressions: 0,
		Applied: 10, Stale: 0, Duplicate: 0, RateAchievedAvg: 100,
		BootOK: true, StoreEmptyAtStart: true}
	v := ComputeLWWVerdict(r)
	if v.Pass || v.Reason == "" {
		t.Fatalf("want fail with reason, got %+v", v)
	}
}
