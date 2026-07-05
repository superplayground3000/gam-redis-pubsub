# Redis-CDC forward leg: SIGKILL-failover message-loss fix & proof

**Date:** 2026-07-03 · **Cluster:** kind `cdc`, ns `cdc-k8s` · **Image:** `hpdevelop/connect:4.92.0-claudefix`
**Fix commit:** `1453bd7` · **Spec:** [`../superpowers/specs/2026-07-03-redis-cdc-stable-consumer-failover-design.md`](../superpowers/specs/2026-07-03-redis-cdc-stable-consumer-failover-design.md)

## TL;DR

The CDC forward leg (Redis Stream `app.events` → NATS JetStream `KV_CDC`) **loses messages
on an ungraceful (SIGKILL) leader failover** because the Redis consumer name is pod-scoped
(`client_id: __POD__`). A new leader is a *new* consumer, so the dead leader's un-acked
Pending-Entries-List (PEL) is orphaned forever — Redis Streams never auto-redeliver across
consumers.

**Fix (one line, zero Go change):** make the consumer name follow the *leadership role*, not
the pod — `client_id: cdc_propagator_active`. The incoming leader reuses the name, the
`redis_streams` input replays the dead leader's PEL from offset `"0"`, and NATS `Nats-Msg-Id`
dedup absorbs any duplicates.

**Proof (A/B on a real cluster):**

| leg | `consumerClientId` | orphaned PEL (residual) | region keys lost | verdict |
|-----|--------------------|-------------------------|------------------|---------|
| baseline | `__POD__` | **757** | **757 / 5000** | LOSS |
| fixed | `cdc_propagator_active` | **0** | **0 / 5000** | NO LOSS |

In the baseline the two independent oracles agreed exactly — `residual == loss == 757` — so
the messages orphaned in the dead consumer's PEL are *precisely* the ones missing downstream.

---

## 1. Background — the system

A fence-free CDC relay with Kubernetes-Lease leader election on both legs. This report
concerns the **forward leg** only.

*Diagram: [`01-architecture.drawio`](01-architecture.drawio)*

- A **writer** `XADD`s CDC events to a central Redis stream `app.events` (consumer group
  `cdc_propagator`).
- **connect-source** runs 3 replicas; only the **K8s-Lease holder** POSTs the consuming
  pipeline. It reads with `XREADGROUP` under a consumer name = `client_id`, publishes each
  event to NATS JetStream `KV_CDC` (header `Nats-Msg-Id = event_id` for dedup).
- **connect-sink** binds a durable pull consumer and applies `op → SET/DEL` to **region
  Redis**.
- **Write-then-ack:** the source `XAck`s an entry **only after** the NATS `PubAck`. So an
  entry that never reached NATS is never acked in Redis — there is no "unwritten-before-kill"
  loss. The *only* loss vector is un-acked PEL entries stranded by an ungraceful kill.

## 2. The bug — orphaned PEL on ungraceful failover

The elector replaces the literal token `__POD__` with the pod name before POSTing the
pipeline (`internal/elector/streams.go:20`), so each leader consumes under **its own pod
name**. On SIGKILL, `OnStoppedLeading` never runs; the Lease expires (~6 s) and a new pod
wins.

*Diagram: [`02-loss-vs-fix.drawio`](02-loss-vs-fix.drawio)*

- **Baseline (`__POD__`):** the new leader `pod-B` consumes as a **new** name and only reads
  new entries (`>`). It never `XCLAIM`/`XAUTOCLAIM`s `pod-A`'s PEL, so those un-acked entries
  are **orphaned forever → lost**.
- **Fixed (`cdc_propagator_active`):** the new leader reuses the **same** consumer name, so
  the input's startup backlog read from `"0"` returns `pod-A`'s PEL, republishes it, and acks
  it → **recovered**. (Upstream `redis_streams` initializes per-stream backlog to `"0"` then
  switches to `">"`; confirmed in `internal/impl/redis/input_streams.go:200,335,343`.)

### Why the loss is *bounded* (and why it still matters)

Because of write-then-ack, the only genuinely lost entries are those **read into the PEL but
not yet published** to NATS at the instant of the kill. Entries already `PubAck`'d (awaiting
the batched `XAck`) already reached NATS. So on a fast leg the loss is small — but it is
**permanent** (orphaned, never redelivered), and the fix recovers it. The lab deliberately
*enlarges this genuine window* (see §4) to make the effect measurable and unambiguous.

## 3. The fix

`chart/files/connect/cdc-forward.yaml`:

```yaml
    consumer_group: cdc_propagator
    client_id: {{ .Values.connect.source.consumerClientId }}   # was: __POD__
```

`chart/values.yaml` — `connect.source.consumerClientId: cdc_propagator_active` (prod default).
No Go change: the elector's `strings.ReplaceAll(tmpl, "__POD__", pod)` is a no-op when the
token is absent.

**Safety when single-active is violated (split-brain):** the elector is best-effort
active-gating, **not fencing**. If two pods ever run active with the same stable `client_id`,
they share one consumer/PEL; `Nats-Msg-Id` dedup absorbs the resulting **duplicates**, so it
degrades to duplication (and possible reordering), not loss. The fix removes the *failover*
loss vector; it does not make concurrent double-active safe.

## 4. Lab method — `scripts/verify-failover.sh`

The same test runs twice (baseline, fixed) via `--set connect.source.consumerClientId`.

*Diagram: [`03-lab-method.drawio`](03-lab-method.drawio)*

### Making the vulnerable window deterministic

A fast leg drains a burst before any sizable un-acked PEL forms, and only the read-but-
unpublished slice is truly at risk. Two **prod-safe, defaulted** chart knobs — applied
*identically to both legs* — enlarge that same genuine window:

- `connect.source.maxInFlight = 1` (prod default 256) — serialize the NATS publisher so PEL
  entries are genuinely **un-published**, not merely awaiting `XAck`.
- `connect.source.readLimit = 2000` (prod default 50) — read a large batch into the PEL that
  the serialized publisher cannot drain before the kill.

These change *magnitude/probability*, not the failure mode. Applying them equally to baseline
and fixed keeps the A/B fair (confirmed by the final cross-model review).

### The oracle (pure `kubectl exec … redis-cli`, no NATS CLI)

Two independent measurements that must agree:

1. **Forward-leg PEL residual (causal):** after failover + settle, count entries still
   un-acked under the run's consumer name `CID`.
   *baseline* `CID` = dead pod name (never reused) → orphaned, `residual > 0`.
   *fixed* `CID` = stable name (reused, replayed from `"0"`) → `residual == 0`.
2. **End-to-end region membership:** each event `SET`s a distinct key under a fresh per-run
   prefix; `loss = N − region_present`.

Robustness details baked in after empirical iteration and two Codex reviews:

- **Arm** on the *current* Lease holder's PEL depth (rollout churn moves leadership); require
  the holder **stable across 2 polls** and **re-confirm `holder == armed` immediately before
  the kill** — otherwise fail closed to `INCONCLUSIVE` (prevents a false pass where a
  non-active pod is killed).
- **Adaptive sink-settle:** poll region key count until it *stops growing* (not a fixed
  sleep) — robust to variable sink lag and any `N`; a fixed sleep would falsely inflate loss
  on the fixed leg.
- **Per-run isolation:** `FLUSHDB` region + unique key/`event_id` namespace; `DELCONSUMER` the
  dead baseline consumer afterwards.
- Measurements are exact by-key / by-consumer within a per-run-unique namespace, so they are
  immune to the NATS dedup-window / retention / leftover-traffic contamination that makes NATS
  aggregate counts unsafe.

## 5. Results

```
baseline: {"consumerClientId":"__POD__","n":5000,"arm_depth":591,
           "pel_residual":767,"region_present":4233,"loss_keys":767}   → LOSS
fixed:    {"consumerClientId":"cdc_propagator_active","n":5000,"arm_depth":1241,
           "pel_residual":0,"region_present":5000,"loss_keys":0}        → NO LOSS
```

- **Baseline loses**, and the orphaned-PEL count equals the region-loss count
  (`residual == loss`), across two independent runs (757 and 767) — the pod-scoped consumer
  identity *is* the loss.
- **Fixed loses nothing** under an equal-or-larger at-risk depth (armed at 1241–2126): the
  new leader replayed the dead leader's PEL and every key reached region.
- The hardened verifier also **caught a real Lease-holder flip** on one combined run and
  returned `INCONCLUSIVE` rather than certifying it — the fail-closed guard working.

Raw evidence: [`../../reports/failover/summary.md`](../../reports/failover/summary.md) and the
`*-baseline.json` / `*-fixed.json` result files.

## 6. Honest caveats

- **Magnitude ≠ production loss rate.** The knobs prove the bug *exists* and the fix *works*
  under stressed settings; they do not measure how many messages a given production incident
  would drop (that depends on real in-flight depth at the kill instant).
- **Image-vs-source.** The upstream `input_streams.go` replay path was read from a local tree
  that may not be byte-identical to the deployed image — which is exactly why the proof is
  **empirical on the real image** rather than a source argument.
- **Not fencing.** See §3 split-brain note.

## 7. Reproduce

```bash
# from redis-cdc-le-k8s/ against a running kind cluster (ns cdc-k8s, release cdc)
RRCS_NS=cdc-k8s RRCS_RELEASE=cdc scripts/verify-failover.sh    # both legs, gated
MODE=baseline scripts/verify-failover.sh                       # single leg
MODE=fixed    scripts/verify-failover.sh
```

Exit 0 only when baseline reproduces loss **and** fixed shows none. Prod defaults
(`maxInFlight=256`, `readLimit=50`, `consumerClientId=cdc_propagator_active`) are restored by
a plain `helm upgrade`.

## 8. Diagrams

Open the `.drawio` files at [app.diagrams.net](https://app.diagrams.net) or with the VS Code
"Draw.io Integration" extension:

- [`01-architecture.drawio`](01-architecture.drawio) — forward-leg data flow & the fix site.
- [`02-loss-vs-fix.drawio`](02-loss-vs-fix.drawio) — orphaned-PEL loss vs stable-name replay.
- [`03-lab-method.drawio`](03-lab-method.drawio) — the verifier's arm→kill→measure→assert flow.
