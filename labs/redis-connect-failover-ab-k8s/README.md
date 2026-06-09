# redis-connect-failover-ab-k8s

## What this demonstrates

A head-to-head comparison of two ways to keep **at most one** Redpanda Connect pod
consuming a Redis stream, under failover:

- **Method A** — Deployment of N pods (streams mode) + a fail-closed client-go
  **leader-election** controller (one elector sidecar per pod). The Lease holder
  consumes. At-most-one is *best-effort* (no fencing), and failover is **lease-gated**:
  a standby waits out the lease before taking over.
- **Method C** — `StatefulSet replicas: 1` running connect in run mode. K8s
  at-most-one pod identity is the only gate, so overlap is **structural ~0**; failover is
  just pod-reschedule + connect startup, but a **node failure can stall** it.

> Measured result (see RESEARCH.md): under pod-delete faults, Method C recovered *faster*
> (~1s) than Method A (~6–7s, lease-gated) — the reverse of the naive guess — while both
> held at-most-1 (`overlap_pairs = 0`).

For each method the harness injects **graceful delete** and **force delete** on the
active consumer and records **failover time** (zero-active gap duration) and
**robustness** (whether at-most-1 held, i.e. `overlap_pairs == 0`).

LWW (the parent lab's per-key version machinery) is **removed** — the writer is a plain
stream producer; this lab is about the gating mechanism, not data correctness.
Mechanism definitions: `../../active-stanby-mechanism/research.md` (Method A §3, Method C §5).

## Run it (kind)

```bash
kind create cluster --name lel
scripts/build-images.sh --kind --kind-name=lel    # writer/elector/observer/dashboard
scripts/verify-failover.sh                         # compares A and C; prints the table
```

Tune via env (defaults in `scripts/lib/run-defaults.sh`):
`RATE=2000 SETTLE_S=20 FAULT_WAIT_S=20 METHODS="A C" scripts/verify-failover.sh`
(`LEL_NS`, `LEL_RELEASE`, `LEL_VALUES` override namespace/release/values.)

Watch live in a browser:

```bash
scripts/dashboard-forward.sh        # binds --address 0.0.0.0; prints LAN URLs
```

## Expected output

```
==================== COMPARISON ====================
method  fault            failover_time_s    overlap_pairs   at_most_1_held
A       graceful-delete  ~X.X               0               yes
A       force-delete     ~6 (≈ lease)       0               yes
C       graceful-delete  ~Y.Y               0               yes
C       force-delete     ~Z.Z               0               yes
====================================================
[verify-failover] PASS — both methods steady single-active AND at-most-1 held ...
```

`verify-failover.sh` exits 0 iff both methods reach steady single-active AND every
scenario holds at-most-1 (`overlap_pairs == 0`) with a readable verdict.

## Validation note

This is a Kubernetes lab, so the research-lab skill's `validate_lab.sh` (docker-compose)
does **not** apply. `scripts/verify-failover.sh` is the validation.

## Teardown

```bash
helm uninstall lel -n lel-k8s
kind delete cluster --name lel
```

## Further reading

- `RESEARCH.md` — the two mechanisms, what the fault matrix does and does not expose.
- `../../active-stanby-mechanism/research.md` — Method A (§3), Method C (§5).
- `../redis-connect-leader-election-k8s/` — the Method-A-only lab this forks.
