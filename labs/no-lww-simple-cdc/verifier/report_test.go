// $LAB/verifier/report_test.go
package main

import "testing"

func TestVerdictPassOnlyWhenAllGreen(t *testing.T) {
	all := CDCResult{DedupOK: true, OpsOK: true, ReplayOK: true}
	if v := ComputeVerdict(all); !v.Pass {
		t.Fatalf("all-green should pass: %+v", v)
	}
	bad := CDCResult{DedupOK: true, OpsOK: false, ReplayOK: true}
	if v := ComputeVerdict(bad); v.Pass {
		t.Fatal("ops failure must fail the verdict")
	}
}
