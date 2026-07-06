# robustness-test — validation evidence

Date: 2026-07-06

Image: `hpdevelop/connect:v4.92.0-batch-nats` (digest
`sha256:502ed259066153a6e412d64eb642a157a12f7d7553bddd28a04629ee4d2a4ec0`)

## Script-hook regression (L0+L1)

Command:

```
SKIP_L2=1 SKIP_L3=1 scripts/run-all-tests.sh
```

Exit status: 0

Key lines:

```
[run-all-tests] L0 PASS
[run-all-tests] L1 PASS
[run-all-tests] PASS
```

## Full clean-slate lab run

Command:

```
time labs/robustness-test/scripts/verify-robustness.sh
```

Exit status: 0. Wall time: real 5m57.076s. Run directory:
`reports/20260706-114633/`.

report.md (verbatim):

```
# robustness-test report 20260706-114633

Image: `hpdevelop/connect:v4.92.0-batch-nats` (hpdevelop/connect@sha256:502ed259066153a6e412d64eb642a157a12f7d7553bddd28a04629ee4d2a4ec0)

| Phase | Verdict |
|---|---|
| p0_e2e | PASS |
| p1_failover_ab | PASS |
| p2_sink_leader_kill | PASS |
| p3_standby_kill | PASS |
| p4_poison_metrics | PASS |

Overall: PASS
```

Key phase lines:

```
[verify-cdc] PASS — dedup + per-op + replay all green
[failover] PASS — baseline LOSES on SIGKILL failover, fixed DOES NOT
[kill-sink-leader] PASS — zero loss after sink-leader SIGKILL (N=5000)
[kill-standby] PASS — zero loss, leadership stable after standby SIGKILL (N=2000)
[poison-metrics] PASS — cdc_unprocessable counted both reasons (unknown_op +55484, decode_error +3515) and good traffic recovered
```

## Post-review fixes (this file's commit) re-verified

Applied the final-review findings (kill-proof waits in kill-sink-leader.sh and
kill-standby.sh, RRCS_SET glob safety in verify-cdc.sh/verify-failover.sh,
xadd_batch temp-file leak fix and background-wait diagnostic in
kill-standby.sh/lib.sh), then re-ran:

1. `bash -n` on all five touched scripts — exit 0 on each.
2. `SKIP_L2=1 SKIP_L3=1 scripts/run-all-tests.sh` — exit 0 (`L0 PASS`, `L1 PASS`, `PASS`).
3. Live re-run against the existing kind deployment (`RRCS_NS=cdc-k8s RRCS_RELEASE=cdc`,
   all pods confirmed `Running` beforehand):

```
$ RRCS_NS=cdc-k8s RRCS_RELEASE=cdc labs/robustness-test/scripts/kill-sink-leader.sh; echo exit=$?
[kill-sink-leader] sink leader: lab-connect-sink-55b75cb847-2r4wl; producing N=5000 (runid=1783314259605)
[kill-sink-leader] SIGKILL sink leader lab-connect-sink-55b75cb847-2r4wl at region_count=809/5000
[kill-sink-leader] new sink leader: lab-connect-sink-55b75cb847-l42ql
[kill-sink-leader] region has 5000/5000 keys (loss=0)
[kill-sink-leader] PASS — zero loss after sink-leader SIGKILL (N=5000)
exit=0
```

```
$ RRCS_NS=cdc-k8s RRCS_RELEASE=cdc labs/robustness-test/scripts/kill-standby.sh; echo exit=$?
[kill-standby] leaders src=lab-connect-source-9755bd4d9-j7vfk sink=lab-connect-sink-55b75cb847-l42ql; killing standbys src=lab-connect-source-9755bd4d9-htb9s sink=lab-connect-sink-55b75cb847-vx6wp during N=2000 traffic (runid=1783314273893)
[kill-standby] kill verified: lab-connect-source-9755bd4d9-htb9s and lab-connect-sink-55b75cb847-vx6wp are gone
[kill-standby] region has 2000/2000 keys (loss=0)
[kill-standby] PASS — zero loss, leadership stable after standby SIGKILL (N=2000)
exit=0
```

Both passed on the first attempt (no `INCONCLUSIVE` retry needed), and both
now exercise the new `kubectl wait --for=delete` kill-proof before accepting
the result. Cluster left healthy afterward (`kubectl -n cdc-k8s get pods`
showed all `Running`, no crash-looping pods).
