# redis-connect-leader-election-k8s

## What this demonstrates

Best-effort **active-gating** in front of Redpanda Connect: a self-written client-go
leader-election controller (the `elector` sidecar) makes **exactly one** of N=3 connect pods
consume a Redis stream under steady state, and transfers consumption to a standby on
failover. Crucially it also **measures the two best-effort failure windows** the upstream
research warns about — a brief *dual-active overlap* (two pods consume at once) and a
*zero-active gap* (nobody consumes) — proving this is active-gating, **not** hard fencing.

Kubernetes/Helm fork of `../redis-connect-lww-k8s/`, stripped to the **source leg only**
(no NATS/JetStream, no sink CAS, no region Redis). Mechanism: `../../active-stanby-mechanism/research.md`
(Method A). Order and uniqueness must **not** depend on the Lease — see RESEARCH.md.

## Run it (kind)

```bash
kind create cluster --name lel
scripts/build-images.sh --kind --kind-name=lel    # build writer/elector/observer/dashboard, load into kind
scripts/verify-election.sh                         # Proof A + B1 + B2; prints verdict
```

Tune the run with env vars (defaults in `scripts/lib/run-defaults.sh`):
`RATE=2000 SETTLE_S=15 OBS_WINDOW_S=6 OVERLAP_WAIT_S=12 GAP_WAIT_S=12 scripts/verify-election.sh`
(`LEL_NS`, `LEL_RELEASE`, `LEL_VALUES` override namespace/release/values.)

Watch it live in a browser:

```bash
scripts/dashboard-forward.sh        # binds --address 0.0.0.0; prints LAN URLs
# open http://<host>:8080  → per-pod consumed:<pod> bars + active-stream count + verdict banner
```

## Expected output

`verify-election.sh` exits 0 only when Proof A passes **and** a best-effort window is
observed (B1 overlap > 0 OR B2 gap > 0):

```
[proofA] {"samples":..,"single_active":true,"overlap_pairs":0,"gap_pairs":0}
[proofA] lease holder = lab-connect-xxxxx
[proofA] PASS
[proofB1] {"samples":..,"single_active":false,"overlap_pairs":NN,"gap_pairs":0}
[proofB2] {"samples":..,"single_active":false,"overlap_pairs":0,"gap_pairs":NN}
----
[verdict] single_active=true overlap_pairs=NN gap_pairs=NN
[verify-election] PASS — active-gating works AND is best-effort (measured window)
```

- **Proof A** — steady state: exactly one connect pod consumes (`single_active=true` over a
  clean post-settle window) and the Lease has a holder.
- **Proof B1** — SIGSTOP the leader's elector: it can neither renew the lease nor run its
  fail-closed DELETE, so its stream keeps consuming while a standby takes over →
  `overlap_pairs > 0` (≥2 pods consumed at once: best-effort, not fencing).
- **Proof B2** — force-delete the leader pod (`--force --grace-period=0`): the stream dies
  with no graceful DELETE and the lease lingers → `gap_pairs > 0` (nobody consumed briefly).

## Validation note

This is a Kubernetes lab, so the research-lab skill's `validate_lab.sh` (docker-compose
only) does **not** apply. `scripts/verify-election.sh` is the validation: it exits 0 only
when Proof A passes **and** at least one best-effort window (overlap or gap) is measured.

## Teardown

```bash
helm uninstall lel -n lel-k8s
kind delete cluster --name lel
```

## Further reading

- `RESEARCH.md` — the mechanism, the fail-closed lifecycle, how each proof is made unambiguous.
- `../../active-stanby-mechanism/research.md` — upstream design (Method A; why best-effort, not fencing).
- `../../docs/superpowers/specs/2026-06-08-redis-connect-leader-election-k8s-design.md` — the design spec.
- `../redis-connect-lww-k8s/` — the fork this lab strips down.
