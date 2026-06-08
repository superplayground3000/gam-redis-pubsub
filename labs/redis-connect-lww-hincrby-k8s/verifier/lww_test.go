package main

import (
	"context"
	"testing"

	"github.com/alicebob/miniredis/v2"
)

func TestLWWVerdictPassRequiresAllConditions(t *testing.T) {
	base := LWWResult{
		KeysChecked: 1000, Mismatches: 0, Regressions: 0,
		Applied: 50000, Stale: 1200, Duplicate: 30,
		RateAchievedAvg: 4800, RateTarget: 5000,
		BootOK: true, StoreEmptyAtStart: true, QuiescenceOK: true,
	}
	if v := ComputeLWWVerdict(base); !v.Pass {
		t.Fatalf("expected pass, got %+v", v)
	}

	// pipeline did not quiesce → comparison premature → fail
	noq := base
	noq.QuiescenceOK = false
	if v := ComputeLWWVerdict(noq); v.Pass {
		t.Fatal("quiescence_ok=false must fail (premature comparison)")
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
		BootOK: true, StoreEmptyAtStart: true, QuiescenceOK: true}
	v := ComputeLWWVerdict(r)
	if v.Pass || v.Reason == "" {
		t.Fatalf("want fail with reason, got %+v", v)
	}
}

func TestCompareSrcMax(t *testing.T) {
	mrC, _ := miniredis.Run()
	defer mrC.Close()
	mrR, _ := miniredis.Run()
	defer mrR.Close()
	central := NewStreamClient(mrC.Addr())
	defer central.Close()
	region := NewStreamClient(mrR.Addr())
	defer region.Close()
	ctx := context.Background()

	k := "lb:general:active:{items:run-2-3}"
	mrC.HSet("srcmax:run-2", k, "12")
	mrR.HSet(k, "ver", "12") // region caught up

	checked, mism, regr, err := CompareSrcMax(ctx, central, region, "run-2")
	if err != nil {
		t.Fatal(err)
	}
	if checked != 1 || mism != 0 || regr != 0 {
		t.Fatalf("checked=%d mism=%d regr=%d", checked, mism, regr)
	}

	mrR.HSet(k, "ver", "11") // region behind -> mismatch
	_, mism, _, _ = CompareSrcMax(ctx, central, region, "run-2")
	if mism != 1 {
		t.Fatalf("want 1 mismatch, got %d", mism)
	}

	mrR.HSet(k, "ver", "13") // region ahead -> regression (impossible/fence bug)
	_, _, regr, _ = CompareSrcMax(ctx, central, region, "run-2")
	if regr != 1 {
		t.Fatalf("want 1 regression, got %d", regr)
	}
}
