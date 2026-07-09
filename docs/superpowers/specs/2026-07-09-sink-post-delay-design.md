# Sink elector post-election settle delay — design

Date: 2026-07-09
Status: approved in brainstorming session (scope, guarantee level, approach, and all four
design sections confirmed by the owner).

## Problem

On sink-leg leader failover, the old leader's Connect has pulled messages from the durable
pull consumer (`cdc_sink*`, up to `maxAckPending: 1024` outstanding) that are delivered but
un-acked. When a new elector wins the Lease it POSTs the pipeline immediately; the new
Connect binds to the same durable and JetStream hands it *newer* messages while the old
leader's un-acked deliveries stay invisible until their `ackWait` (30s default) expires.
Result: a redelivered older message can be applied to region Redis *after* a newer message
for the same key — a same-key ordering violation (stale overwrite) in this fence-free,
no-LWW pipeline.

The forward (source) leg does not have this problem: the stable Redis consumer name
(`cdc_propagator_active`) makes the incoming leader replay the dead leader's PEL backlog
from "0" before reading new entries.

## Decision summary

| Decision | Choice |
|---|---|
| Scope | Sink leg electors only (all sink groups); source leg untouched |
| Guarantee level | Best-effort mitigation, not a hard ordering guarantee — residual edge cases documented (see §Residual non-guarantees) |
| Approach | **A: fixed post-election delay** (chosen over B: drain-aware wait polling `num_ack_pending` — more moving parts, partial in external-NATS mode; and C: shrinking `maxAckPending`/`ackWait` — changes steady-state semantics, never fully closes the window) |
| Delay value | Derived per group from its effective consumer `ackWait`, overridable; not hardcoded 30s |
| Ordering A/B proof | Deferred follow-up (see §Follow-ups); this change is verified by the standard ladder |

## Design

### 1. Elector (`internal/elector/main.go`)

- New env `POST_DELAY`, parsed with the existing `envDur`, default `0s` (= exactly today's
  behavior; the source leg never sets it).
- In `OnStartedLeading`, before the POST retry loop, when the delay is > 0:
  - log: won lease; delaying POST of the stream by `POST_DELAY` so the previous leader's
    un-acked deliveries pass their ackWait;
  - wait via `select { case <-c.Done(): return; case <-time.After(delay): }`.
- If leadership is lost mid-wait, return **without POSTing** (fail-closed). Cleanup is safe:
  `streamsClient.delete` already treats 404 as success (`internal/elector/streams.go`), so
  the `OnStoppedLeading` DELETE of a never-POSTed stream is a no-op.
- Lease renewal continues in the background during the wait (client-go renews independently
  of the callback), so holding leadership for the delay without consuming is safe.
- `elector_leading` still flips to 1 only after a successful POST (unchanged).

### 2. Chart wiring (sink legs only)

- The `rrcs.connect.sinkGroups` helper (`chart/templates/_helpers.tpl`) computes a new
  per-group field `postDelay` with inheritance:
  `group.postDelay` → `connect.sinkDefaults.postDelay` → **default: the group's effective
  consumer `ackWait`** (which itself inherits group → sinkDefaults → `nats.stream.consumer`).
- `chart/templates/connect-sink.yaml` elector env gains `POST_DELAY: {{ $g.postDelay }}`.
- Explicit `"0s"` disables the delay (needed for a future failover-baseline A/B and for fast
  dev installs).
- The source-leg template is untouched; its elector gets no `POST_DELAY` env → 0 → no change.
- `chart/values.yaml` comments document the coupling: raising `ackWait` raises the delay
  automatically unless `postDelay` is set explicitly.
- No new component ⇒ no new `enabled:` toggle needed (INV-3 unaffected).

### 3. Observability & docs

- No new metric. The extra leaderless window is already visible on the existing
  `elector_leading` dashboard panel; the elector log line carries the reason. No pipeline
  failure branch is added, so INV-2 requires no dashboard change.
- `rules/05-invariants.md` gains a note next to the existing "known accepted non-guarantee"
  (cross-key reordering): same-key reordering across sink failover is *mitigated* (not
  eliminated) by the post-election delay. Edit follows `rules/40-maintenance-protocol.md`
  (backup first).

### 4. Error handling

- Delay aborted by lost leadership → no POST, fail-closed (above).
- POST failures after the delay → unchanged existing retry/release path.
- Unparseable `POST_DELAY` → `envDur` logs a WARN and uses the default (0s) — existing
  behavior for all duration envs.

## Residual non-guarantees (documented, accepted)

- An old leader that is alive-but-partitioned (lost the Lease but its Connect still holds
  delivered messages) can ack/apply late — after the new leader has applied newer values.
- A crash of the *new* leader mid-apply still reorders via redelivery.
- Cross-key reordering remains by design (existing INV-1 note).

The elector remains best-effort active-gating, not fencing; order must not *depend* on it.

## Verification (per rules/05-invariants.md ladder — elector change ⇒ L4 required)

| Level | What |
|---|---|
| L0 | Unit tests for the wait/abort logic: cancel mid-wait → no POST; `0s` → immediate POST |
| L1 | Renders: default sink elector env has `POST_DELAY: 30s`; per-group and `0s` overrides render; source-leg elector has no `POST_DELAY`; existing toggle loop still passes |
| L3 | `scripts/build-images.sh --kind --kind-name=cdc` + `RRCS_NS=cdc-k8s RRCS_RELEASE=cdc scripts/verify-cdc.sh` — full pass (install now pays one ~30s sink start delay) |
| L4 | `scripts/verify-failover.sh` — full pass. **Check first** that its settle/quiesce windows outlast recovery now extended by ~30s (2026-07-07 lesson: settle windows must outlast the slowest recovery mechanism; that horizon is now ackWait + postDelay). Same check applies to `scripts/verify-failover-prefix.sh` if run |

## Follow-ups (explicitly out of scope)

1. **Ordering A/B proof in the failover harness**: kill the sink leader with a deterministic
   un-acked backlog; assert a stale overwrite occurs with `postDelay: "0s"` and never with
   the default. Requires per-key monotonic-value tracking in writer/verifier — a substantial
   harness addition, in the spirit of the existing baseline-vs-fixed loss A/B.
2. **Drain-aware wait (approach B)**: poll the NATS monitor endpoint for the durable's
   `num_ack_pending` and POST as soon as it reaches 0, capped at ackWait — removes the fixed
   cost on clean elections if the fixed delay proves annoying in practice.
