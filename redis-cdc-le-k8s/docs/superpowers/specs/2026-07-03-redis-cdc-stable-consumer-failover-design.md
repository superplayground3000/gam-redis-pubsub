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
3. **Arm the kill in the vulnerable window.** Poll `XPENDING app.events cdc_propagator`
   until pending is non-trivial, then **snapshot the at-risk PEL by ID under the run's
   consumer name.** The Redis **consumer name** is this run's configured `consumerClientId`
   (`CID`) — it is *not* always the pod name:
   - **baseline** (`client_id=__POD__`): `CID` == the active pod name == the current Lease
     holder;
   - **fixed** (`client_id=cdc_propagator_active`): `CID` == the constant
     `cdc_propagator_active`, independent of the pod.

   The Lease holder
   (`kubectl get lease <release>-<source-lease> -o jsonpath='{.spec.holderIdentity}'`) is
   used **only** to pick which pod to SIGKILL; the PEL snapshot filters by `CID`:
   `XPENDING app.events cdc_propagator - + <big> <CID>` → pending **stream entry IDs**;
   `XRANGE` each → their `event_id` fields = set `S` (at-risk ids). This is the correction
   that makes `S` non-empty and the oracle meaningful in **both** runs: in the fixed run the
   surviving stable consumer name is exactly what the new leader re-attaches to and drains,
   so `S` captured under `CID=cdc_propagator_active` is precisely the set that must be
   replayed. Note `S` mixes truly-unpublished ids with published-but-not-yet-`XAck`'d ids
   (the `commit_period=200ms` window, Q1) — accounted for below.
4. **SIGKILL** the holder: `kubectl delete pod <holder> --grace-period=0 --force`.
5. **Settle.** Wait until a *new* Lease holder is active. For the **fixed** run, also wait
   until group PEL drains toward ~0 (success signal) or timeout. For the **baseline** run,
   do **not** wait for PEL to drain (that would contradict the loss hypothesis, Q3) — wait a
   bounded settle period after the new holder is active, then measure.
6. **Measure — forward-leg PEL delta (pure Redis, causal proof).** Re-query the group PEL
   under the run's consumer name: `XPENDING app.events cdc_propagator - + <big> <CID>`.
   - **fixed:** `S` must have **drained** — the new leader re-attached to the same `CID`,
     re-read those entries from `"0"`, re-published, and `XAck`'d them (⇒ PubAck'd to NATS,
     by write-then-ack); total group pending → ~0.
   - **baseline:** `S` must remain **stuck** under the dead consumer `CID` (orphaned; the new
     leader consumes under a *different* name and never re-reads it).
7. **Measure — end-to-end loss oracle (region-KV key membership).** At kill, map each `S`
   entry to its `kv_key` via `XRANGE`. Each run's events SET distinct keys under a fresh
   prefix `P_keys`. After the sink settles, `Loss_keys = P_keys \ present_in_region`.
   - **fixed:** `Loss_keys == ∅` (all N applied).
   - **baseline:** `Loss_keys ≠ ∅`, and `Loss_keys ⊆ S_keys` (the missing keys are exactly
     the orphaned ones).

   This uses **only `kubectl exec … redis-cli`** — no in-cluster NATS CLI/creds, no envelope
   parsing. Both measurements are exact by-ID / by-key membership within a per-run-unique
   namespace, so they are immune to the dedup-window / retention / leftover-traffic
   contamination that makes NATS aggregate counts unsafe (Q5). The PEL delta is the direct
   forward-leg (Redis→NATS) proof; region-KV membership is the end-to-end no-loss confirmation.

### Assertions & causal claim (Q3)

- **baseline** (`CID` = dead pod name): the new leader consumes under a **different**
  consumer name (its own pod name), so `S` — captured under the dead pod's `CID` — is never
  re-read. Assert (a) PEL: `S` **still pending** under the dead `CID`; (b) region:
  `Loss_keys ≠ ∅` and `Loss_keys ⊆ S_keys` (missing region keys are exactly the orphaned
  ones; undelivered `>` entries are still picked up by the new consumer, so they are *not*
  lost). If `Loss_keys == ∅`, the kill missed the vulnerable window → **inconclusive,
  retry**; never pass a baseline that didn't lose.
- **fixed** (`CID` = `cdc_propagator_active`): the new leader re-attaches to the **same**
  consumer name and drains its PEL from `"0"`. Assert (a) PEL: `S` **drained** under `CID`
  (group pending → ~0); (b) region: `Loss_keys == ∅` (all N applied). Because `S` is captured
  under the surviving stable `CID` (per the step-3 correction), it is non-empty and is
  precisely the recovery claim — not a vacuous check.

Tying loss/recovery to the **same kill-time set `S`**, captured under each run's real
consumer name, is the causal proof: the fix *replays those specific entries* (PEL drains,
region gains those keys) rather than the system merely passing in aggregate.

## Falsifiability

If the **fixed** run still shows `Loss_keys ≠ ∅` (or `S` does not drain from the PEL), the stable name alone
is insufficient on the deployed image — recovery would need an explicit
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
