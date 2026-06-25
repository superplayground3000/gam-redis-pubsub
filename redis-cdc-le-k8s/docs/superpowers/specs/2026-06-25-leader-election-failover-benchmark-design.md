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

Predicted failover (client-go contract, corrected after Codex methodology review): a
surviving candidate must wait out the dead leader's *remaining* lease validity, then
acquire on its next **jittered** retry (`JitterUntil(RetryPeriod, factor=1.2)`), plus an
API round-trip:

```
failover = remaining_lease_validity_at_kill + jitter(RetryPeriod, 1.2) + api_latency
         ≤ LeaseDuration + RetryPeriod·(1 + 1.2)
```

→ ceiling tight `~5.2s`, default `~8.2s`, stock `~19.4s`. (The earlier
`LeaseDuration + [0, RetryPeriod]` form undercounted: the jitter factor is 1.2, not 0,
so a standby's acquire-retry can be up to `2.2·RetryPeriod` apart. The spike confirmed
this — 7.524s on the 6s config, above the naive 7s bound.)

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

### Measured metric — two independent failover numbers per trial
Per trial, for a given leg:
1. Read current holder `H_old`, its `renewTime`, `leaseDurationSeconds`, `leaseTransitions`.
2. `t_kill = date +%s.%N` (host clock), then
   `kubectl delete pod H_old --grace-period=0 --force` — ungraceful, forces the
   expiry path.
3. Poll the Lease (~100 ms) until `.spec.holderIdentity != H_old`; record `t_detect`
   (host clock) and the new `.spec.acquireTime` (`metav1.MicroTime`) + `leaseTransitions`.
4. Compute **both**:
   - `failover_acquire = acquireTime(new) − t_kill` — the precise acquire instant.
   - `failover_observed = t_detect − t_kill` — single-host-clock upper bound (≤ one poll
     interval high), needs no cross-process assumption.

**Clock domain (corrected after Codex review).** `acquireTime` is stamped by the
*winning pod* via Go `time.Now()`, not by the apiserver. That is still valid to subtract
against the host's `date +%s.%N` because both read `CLOCK_REALTIME`, which is **not**
virtualized by time namespaces (only `MONOTONIC`/`BOOTTIME` are), and kind runs every
container on the one host kernel — so the two reads come from the *same* wall clock with
no domain offset. `failover_observed` (pure single-host-clock) is reported alongside as
empirical corroboration; sub-decisecond agreement between the two confirms there is no
hidden skew. `acquireTime` changes only on a leadership **transfer**, not on renewals
(verified by Codex against client-go `leaderelection.go`).

5. `tr_delta = leaseTransitions(new) − leaseTransitions(old)`: `>1` flags flapping during
   the window (recorded, not silently averaged) — addresses the poll-granularity concern.
6. Gate the next trial on all 3 replicas `Ready` again (HA restored: active + 2 standby)
   and the holder being a Ready pod, so every trial starts from full state.

**Kill modes.** `random` (default) kills at an arbitrary point in the renew cycle →
natural operator-observed distribution. `post-renew` kills immediately after a fresh
renew → `lease_remaining ≈ LeaseDuration`, i.e. the **worst case**, to bound the max.

Volume per config: 10 random × 2 legs + 5 post-renew (sink) = 25 kills; **75 total**.
Raw rows → CSV with the full decomposition
(`…,failover_acquire_s,failover_observed_s,lease_remaining_s,acquire_overhead_s,tr_delta`).
Per-config summary: n / min / p50 / p95 / max / mean.

### Flap-onset dimension (the cost of tight timing — added after Codex review)
Failover latency alone makes "smaller `LeaseDuration` is always better" look free. It is
not: tight timing reduces tolerance for control-plane latency, so a leader that cannot
renew within `RenewDeadline` self-demotes (a **flap**) even though nothing crashed. To
measure this directly, `scripts/le-flap.sh` injects egress `netem` delay on the **live**
source leader's renew path (via `nsenter` into that one pod's netns — targeted, guarded
against pid≤1, fully reverted), and records the delay at which `leaseTransitions`
increments. netem on `eth0` does not touch loopback, so localhost health probes are
unaffected — any holder change is a pure renew-deadline flap, not a probe kill. A fixed
delay ladder (1500/2500/4500/8000/12000 ms) across all three configs shows flap onset
tracking `RenewDeadline` (2s/4s/10s).

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

1. `scripts/le-bench.sh` — per-leg trial driver (random + post-renew kill modes); the
   kill→acquire loop with dual-clock metric + decomposition; restores HA between trials.
2. `scripts/le-flap.sh` — netem flap-onset probe on the live leader (targeted, reverted).
3. `scripts/le-bench-sweep.sh` — applies each config via `helm upgrade`, soaks, invokes
   the driver for both legs + the flap ladder + the correctness gate, restores the
   default config at the end.
4. `scripts/le-report.py` — computes percentiles and renders the markdown report.
5. `docs/superpowers/specs/2026-06-25-leader-election-performance-report.md` — the report.

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
