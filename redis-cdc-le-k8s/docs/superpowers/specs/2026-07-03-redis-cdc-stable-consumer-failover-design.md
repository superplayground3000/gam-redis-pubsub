# Stable Redis consumer identity + SIGKILL-failover no-loss proof

**Date:** 2026-07-03
**Status:** Approved design (pre-implementation)
**Component:** `redis-cdc-le-k8s` — forward leg (Redis Stream `app.events` → NATS JetStream `KV_CDC`)

## Problem

On **ungraceful** failover (SIGKILL of the active source pod), the forward leg loses
messages — not because of unwritten-before-kill (write-then-ack ordering is sound: `XAck`
fires only after the NATS `PubAck`), but via **orphaned Redis PEL entries**.

The `redis_streams` input consumes under `client_id: __POD__`, which the elector rewrites
to the **pod name** (`internal/elector/streams.go:20`, literal `strings.ReplaceAll`). On
SIGKILL:

1. Active pod A holds the Lease and consumes as Redis consumer `A`. Its consumer PEL holds
   entries delivered-but-not-yet-`XAck`'d.
2. A is SIGKILLed. `OnStoppedLeading` never runs (process dead); the Lease expires (~6 s).
3. Pod B wins and POSTs the pipeline, consuming as a **new** consumer `B`.
4. On startup the input drains **its own** consumer's PEL (backlog read from `"0"`, then
   `">"`); it never `XCLAIM`/`XAUTOCLAIM`s another consumer. A's PEL is orphaned forever.

Redis Streams do not auto-redeliver across consumers → **effective loss on every
ungraceful failover.**

### Upstream evidence (with caveat)

The redpanda-connect source on this machine (`/media/hp/secondary/projects/connect/internal/impl/redis/input_streams.go`)
confirms the mechanism: startup initializes per-stream backlog to `"0"`, `XREADGROUP` uses
`Consumer=r.clientID`, drains pending for that `client_id`, then switches to `">"`; there is
no `XCLAIM`/`XAUTOCLAIM` (`input_streams.go:200,335,343`). The input also documents that
`client_id` is expected to be **unique** (`input_streams.go:46`).

**Caveat:** we cannot prove that on-disk tree is the exact source of the deployed image
`hpdevelop/connect:4.92.0-claudefix` (which self-reports `4.92.0-SNAPSHOT-8b54f6e1a`,
`docs/derisk-notes.md:5`). This is *why* the verification runs against the real image on a
kind cluster — the lab is the empirical arbiter of the replay behavior, not the source read.

## Fix

Make the Redis consumer identity follow the **leadership role**, not the pod. Route the
`client_id` through a Helm value so the incoming leader reuses the same consumer name, and
the input's existing startup PEL-drain replays the dead leader's un-acked entries into NATS
(deduped by `Nats-Msg-Id`). Zero Go change — `ReplaceAll` on an absent token is a no-op.

- `chart/files/connect/cdc-forward.yaml`: `client_id: {{ .Values.connect.source.consumerClientId }}`
- `chart/values.yaml` + `values-dev.yaml`: add
  `connect.source.consumerClientId: cdc_propagator_active`, documented as *"stable logical
  consumer name so an incoming leader reuses the dead leader's PEL and replays un-acked
  entries; MUST NOT be pod-scoped."*
- `output.label: __POD__` is unchanged (Benthos component label, not consumer identity).

### Honest scope of the fix (Q4)

The fix removes the **failover** loss vector. It does **not** make concurrent double-active
safe. The elector is best-effort active-gating, **not fencing** (`internal/elector/main.go:1-5`),
and the input expects `client_id` unique. If two pods ever run active with the same stable
`client_id` (overlapping leases / split-brain), they share one consumer name → shared PEL,
shared cursor, ambiguous ownership. This **reduces** loss risk versus per-pod names but is
not proven loss-free: overlap can reorder publications, and safety then rests on downstream
idempotency + `Nats-Msg-Id` dedup, not on the consumer model. We state this as a known
limitation, not a guarantee.

## Verification — by-ID delta oracle on a kind cluster

Runs the **same** test twice for a controlled A/B causal proof, driven by a new
`scripts/verify-failover.sh` (executes, modeled on `scripts/verify-cdc.sh`; note the repo
convention that `insert-msgs.sh`-style helpers only *form* commands — the orchestrator is
the one that executes).

| Run | `consumerClientId` | Expected |
|-----|--------------------|----------|
| **baseline** | `__POD__` | **loss** — lost set ≠ ∅ |
| **fixed** | `cdc_propagator_active` | **no loss** — lost set == ∅ |

### Why by-ID, not by-count (Q5)

Aggregate NATS `last_seq`/message counts are unsafe: `KV_CDC` uses limits retention
(`max_age=1h`, `max_bytes=256MB`), a **5-min dedup window**, no `max_msgs` cap
(`nats-init-job.yaml:74`, `values.yaml:82`), so counts include prior-run traffic and dedup
can mask replay. Region key counts pass on leftovers unless cleared. Therefore the oracle is
**exact `event_id` set membership within a per-run-unique namespace** — robust to leftover
traffic (we only ask "is *this* `event_id` present?") and to dedup (a present `event_id`
arrived at least once, which is all we require).

### Per-run isolation (clean state)

Before each run: `nats stream purge KV_CDC`; flush region Redis; reset/recreate the
`cdc_propagator` group so no stale PEL carries over; use a **fresh `event_id` namespace and
key prefix** per run (e.g. `lb:failover:{run:<runid>:kNNN}` with `event_id = <runid>-<NNN>`).

### Procedure (per run)

1. `helm upgrade` with the chosen `consumerClientId`; wait for the source leg ready
   (1 active + 2 standby).
2. **Produce** `P` = a burst of N=500 distinct-key SET (`op=create`) events with known,
   run-unique `event_id`s. Record `P`.
3. **Amplify the genuine vulnerable window (identical for both legs).** Write-then-ack means
   the *only* entries truly at risk on a SIGKILL are those **read into the PEL but not yet
   published** to NATS at the kill instant (published-but-unacked entries already reached
   NATS). On a fast leg that set is tiny and hard to catch, so the harness enlarges the **same
   real** set with two prod-safe, defaulted chart knobs applied identically to baseline and
   fixed:
   - `connect.source.maxInFlight = 1` — serialize the NATS publisher, so PEL entries are
     genuinely un-published (not merely awaiting `XAck`);
   - `connect.source.readLimit = 2000` — read a large batch into the PEL that the serialized
     publisher cannot drain before the kill.

   Both default to prod values (`256` / `50`); only the verifier changes them. They widen the
   exposure *magnitude/probability*; they do not invent a new failure mode.
4. **Arm on the stable current leader.** Poll the **current** Lease holder's PEL under this
   run's consumer name `CID` (baseline: the holder's own pod name; fixed: the constant
   `cdc_propagator_active`), re-reading the holder each iteration and requiring it **stable for
   two consecutive polls** (a fresh rollout hands leadership around before it settles). Arm
   when that PEL depth crosses a threshold; that holder is the kill target. Do **not** snapshot
   entry-ids here — the live pod keeps `XAck`ing between any snapshot and the kill, so the set
   alive at kill differs from the snapshot; the *residual after settle* is the correct measure.
5. **SIGKILL** the holder, fail-closed: re-confirm `holder() == armed holder` immediately
   before the kill (a leadership flip in the gap could otherwise kill a non-active pod and
   never exercise failover — a false pass on the fixed leg); then
   `kubectl delete pod <holder> --grace-period=0 --force`.
6. **Settle.** Wait for a *new* Lease holder. For **fixed**, wait until the reused consumer's
   PEL drains to 0. For **both**, then wait for the sink **adaptively** — poll region key count
   until it stops growing (stable across several polls) or timeout — robust to variable sink
   lag and any N (a fixed sleep would falsely inflate loss on the fixed leg).
7. **Measure (two agreeing oracles, pure `redis-cli`).**
   - **Forward-leg residual PEL (causal):** `residual` = entries still un-acked under `CID`
     after settle. **baseline:** `CID` is the *dead pod name* (never reused) → its PEL is
     orphaned forever, `residual > 0`. **fixed:** `CID` is the *stable name* (reused by the new
     leader, which re-read it from `"0"`, re-published and acked) → `residual == 0`.
   - **End-to-end region-KV membership:** each event SETs a distinct key under a fresh per-run
     prefix; `loss_keys = N − present_in_region`. **baseline:** `> 0`; **fixed:** `== 0`.

   Uses **only `kubectl exec … redis-cli`** — no NATS CLI/creds. Both are exact by-key / by-
   consumer measurements within a per-run-unique namespace, immune to the dedup-window /
   retention / leftover-traffic contamination that makes NATS aggregate counts unsafe (Q5).

### Assertions & causal claim (Q3)

- **baseline:** assert `residual > 0` **and** `loss_keys > 0`. If either is 0 the kill missed
  the window → **inconclusive, retry**; never pass a baseline that didn't lose.
- **fixed:** assert `residual == 0` **and** `loss_keys == 0`.

The causal proof is the **agreement of the two independent oracles**: in the baseline run the
count orphaned in the dead consumer's PEL equals the count missing from region
(observed `residual == loss_keys == 757` of 5000) — the orphaned-PEL entries are *exactly* the
data lost downstream, tying the pod-scoped consumer identity directly to the loss. The fixed
run reverses both to 0 under an equal-or-larger at-risk depth.

## Falsifiability

If the **fixed** run still shows `loss_keys > 0` (or `residual` does not drain to 0), the
stable name alone is insufficient on the deployed image — recovery would need an explicit
`XAUTOCLAIM`/startup-replay (a Go change, out of scope for this pass). The lab is designed to
surface that outcome, not paper over it.

## Deliverables

- `chart/files/connect/cdc-forward.yaml` (1-line change)
- `chart/values.yaml` + `chart/values-dev.yaml` (new `connect.source.consumerClientId`)
- `scripts/verify-failover.sh` (+ any small helper under `scripts/lib`)
- A run report under `reports/` capturing both runs' `N`, `S`/`S_keys`, PEL-drain state, `Loss_keys`
- This spec

## Non-goals

- Fencing / true single-writer guarantees (elector stays best-effort).
- Sink-leg (reverse) failover — same class of issue, separate pass.
- Changing retention/dedup/`commit_period` tuning.
