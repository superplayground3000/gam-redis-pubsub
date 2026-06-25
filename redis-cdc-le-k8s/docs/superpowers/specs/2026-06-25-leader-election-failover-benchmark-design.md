# Leader-Election Failover Benchmark on kind — Design

Date: 2026-06-25
Status: Approved (pending Codex cross-review + user spec review)

## Goal

Empirically measure active→standby **failover latency** for the CDC relay's two
elector legs (source `forward_leg`, sink `reverse_leg`) across three leader-election
timing configs, prove CDC correctness survives repeated failovers, and use the data
plus client-go leader-election theory to justify why the **default `6s/4s/1s`**
(`LeaseDuration` / `RenewDeadline` / `RetryPeriod`) is the right operating point.

## Background — what governs failover here

`internal/elector/main.go` runs `client-go`'s `leaderelection.RunOrDie` against a
`coordination.k8s.io` Lease, one Lease per leg. Defaults (also the chart values in
`chart/values.yaml`):

| Param          | Default | client-go stock |
|----------------|---------|-----------------|
| `LeaseDuration`| 6s      | 15s             |
| `RenewDeadline`| 4s      | 10s             |
| `RetryPeriod`  | 1s      | 2s              |

Key implementation fact (verified by reading the source): the elector installs **no
SIGTERM handler**. A killed leader's Go process terminates immediately without running
`OnStoppedLeading` or `ReleaseOnCancel`, so the Lease is **never proactively released**
— a standby must wait for it to **expire**. This is the realistic crash path and is
exactly the path `LeaseDuration` governs, so failover latency scales with the timing
config in every kill scenario. (`ReleaseOnCancel` only fires on in-process context
cancellation, which a kill does not trigger.)

Predicted failover (client-go contract): a surviving candidate observes lease expiry
then acquires on its next retry, so

```
failover ≈ LeaseDuration + [0, RetryPeriod]
```

→ tight `~3–4s`, default `~6–7s`, stock `~15–17s`.

## Methodology

### Cluster & deploy
- Fresh kind cluster named `cdc` (leaves the existing `lel` cluster untouched). All
  `kubectl`/`helm` actions pin `--context kind-cdc` to avoid acting on the wrong cluster.
- `scripts/build-images.sh --kind --kind-name=cdc` loads writer/verifier/elector/
  dashboard images; the connect image is the external `hpdevelop/connect` tag.
- Deploy the chart at `profile=cdc`, wait healthy, run `scripts/verify-cdc.sh` once as
  a baseline gate (must be green before any measurement).
- A steady writer load runs throughout (realistic CDC traffic + gives the correctness
  check live data to validate).

### Measured metric — Lease acquisition latency
Per trial, for a given leg:
1. Read current holder `H_old` from the leg's Lease (`.spec.holderIdentity`).
2. `t_kill = date +%s.%N` (host clock), then
   `kubectl delete pod H_old --grace-period=0 --force` — ungraceful, forces the
   expiry path.
3. Poll the Lease (~250 ms) until `.spec.holderIdentity != H_old`; capture the
   server-side `.spec.acquireTime` (a `metav1.MicroTime`, microsecond precision).
4. **`failover = acquireTime(new) − t_kill`.** Both timestamps live in the *same host
   clock* (kind is single-node on this host; apiserver clock = host kernel clock), so
   skew is sub-100 ms — well below the second-scale signal.
5. Gate the next trial on all 3 replicas `Running` again (HA restored: active + 2
   standby) and the Lease `renewTime` advancing, so every trial starts from full state.

`acquireTime` updates only on a leadership **transfer** (new holder identity), not on
renewals, so `acquireTime(new) − t_kill` is exactly the failover acquisition time.

Volume: 10 trials × 2 legs × 3 configs = **60 kills**. Raw rows → CSV
(`config,leg,trial,t_kill,acquire_time,failover_s`). Per-config summary:
min / median / p95 / max, per leg and combined.

### Correctness dimension
After each config's trial batch, run `scripts/verify-cdc.sh` (dedup +
per-op-under-quiescence + idempotent replay — all order-insensitive). PASS proves the
active/standby gating dropped or duplicated nothing across repeated failovers. The
no-LWW intra-batch reorder caveat (README) is acceptable because the verifier is
order-insensitive.

### Switching configs
`helm upgrade --set` the four lease values on both legs (`connect.source.lease.*` and
`connect.sink.lease.*`), wait for the connect rollout to complete and a fresh election
to settle (Lease has a holder + advancing `renewTime`), then run that config's trials.
Order: default → tight → stock (default first so the baseline is established early).

## Deliverables

1. `scripts/le-bench.sh` — per-config trial driver: takes leg + trial count, runs the
   kill→acquire loop, appends CSV rows, restores HA between trials. Idempotent and
   re-runnable; never deletes a pod unless 3 replicas are Ready.
2. A sweep runner (top-level, e.g. `scripts/le-bench-sweep.sh`) that applies each
   config via `helm upgrade`, waits for settle, invokes the driver for both legs, runs
   the correctness gate, and aggregates stats. Stats via `awk` (no extra deps).
3. `docs/superpowers/specs/.../leader-election-performance-report.md` — the report:
   methodology, raw + summarized failover numbers per config, theory, and the
   reasonableness argument.

## The reasonableness argument (report thesis)

client-go invariants the config must satisfy (all hold for `6s/4s/1s`):
- `RenewDeadline < LeaseDuration` (4 < 6) — leader must finish renewing before the
  lease it published can expire.
- `RetryPeriod < RenewDeadline` (1 < 4) — multiple renew attempts fit inside the
  deadline window; with `4s/1s` ≈ **4 renew attempts** before a leader self-demotes,
  tolerating transient apiserver latency/packet loss before giving up (it stops doing
  work *before* the lease can be taken — the anti-split-brain guarantee).
- Jitter factor 1.2: `RetryPeriod·1.2 = 1.2s < RenewDeadline` — renews don't starve.

Tradeoff axes:
- **Smaller `LeaseDuration`** → faster failover, but more GET/UPDATE traffic to the
  apiserver (renew every `RetryPeriod`) and less tolerance for clock skew / GC pauses /
  API latency → risk of spurious failovers (flapping) on a loaded control plane.
- **Larger** → slower failover, more idle standby time after a real crash.

Why `6s/4s/1s` over stock `15s/10s/2s`: ~2.5× faster failover (~6–7 s vs ~15–17 s
worst case) while keeping the 4-retry renew budget and a **2 s safety margin**
(`LeaseDuration − RenewDeadline`) for clock skew / pause tolerance. For a CDC relay the
standby is **warm** (connect already running; failover is just a Lease acquire + a
single pipeline POST), so single-digit-second failover is appropriate. The tight
`3s/2s/1s` config buys only ~3 s and shrinks the safety margin to 1 s with fewer
effective renew retries → higher flap risk on a busy cluster for little gain. The sweep
data backs this: if measured failover lands near `LeaseDuration + [0, RetryPeriod]` for
all three, the default is the knee of the curve.

## Cross-review gates (Codex)

Per the subagent provider-routing rule, code-quality / final-analysis review goes to a
different model than the author:
1. **Methodology review** — Codex reviews this spec before we run, focusing on
   measurement validity (clock domains, `acquireTime` semantics, the no-release/expiry
   claim, HA-restore gating).
2. **Report review** — Codex reviews the final report's leader-election reasoning and
   whether conclusions follow from the data.

## Risks & mitigations

- **Wrong-cluster actions** → every command pins `--context kind-cdc`.
- **Image build/load time** → build once up front; `helm upgrade` between configs only
  flips env, no rebuild.
- **Eroding HA by killing into a degraded set** → trial gate requires 3/3 Ready before
  each kill.
- **Config switch not settled** → wait for rollout complete + Lease holder present with
  advancing `renewTime` before trials.
- **`acquireTime` clock-domain doubt** → single-node kind on this host makes apiserver
  clock = host clock; document the sub-100 ms bound; cross-check a couple of trials
  against the killed pod's replacement timeline as a sanity check.

## Out of scope
- Sub-second "consuming actually resumed" recovery latency (needs metric-polling
  plumbing the elector doesn't expose; acquisition latency carries the timing argument,
  and the correctness gate proves consumption resumes).
- Multi-node kind / real node failure (single-node is sufficient for Lease-expiry timing).
- Tuning connect `pipeline.threads` or NATS consumer params.
