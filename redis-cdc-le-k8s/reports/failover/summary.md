# SIGKILL-failover no-loss proof — evidence

**Date:** 2026-07-03
**Cluster:** kind `cdc`, namespace `cdc-k8s`
**Image:** `hpdevelop/connect:4.92.0-claudefix` (self-reports `4.92.0-SNAPSHOT-8b54f6e1a`)
**Harness:** `scripts/verify-failover.sh`
**Spec:** `docs/superpowers/specs/2026-07-03-redis-cdc-stable-consumer-failover-design.md`

## Verdict

The forward leg (Redis `app.events` → NATS `KV_CDC`) **loses messages on ungraceful
(SIGKILL) failover when the Redis consumer name is pod-scoped (`__POD__`)**, and **loses
nothing when the consumer name is stable (`cdc_propagator_active`)** — confirming the fix on
the deployed image.

## Runs (`RESULT_JSON`)

| mode | consumerClientId | arm_depth | pel_residual | region_present / N | loss_keys | verdict |
|------|------------------|-----------|--------------|--------------------|-----------|---------|
| baseline | `__POD__` (→ pod name) | 1168 | **757** | 4243 / 5000 | **757** | LOSS |
| fixed | `cdc_propagator_active` | 2126 | **0** | 5000 / 5000 | **0** | NO LOSS |

```
baseline: {"mode":"baseline","cid":"lab-connect-source-5bbcbf59bb-x5dnt","n":5000,
           "arm_depth":1168,"pel_residual":757,"region_present":4243,"loss_keys":757}
fixed:    {"mode":"fixed","cid":"cdc_propagator_active","n":5000,
           "arm_depth":2126,"pel_residual":0,"region_present":5000,"loss_keys":0}
```

## Why this is a causal proof

Two independent oracles agree in each run:

- **Forward-leg PEL delta** — after failover, the entries still un-acked under the run's
  consumer name. Baseline: **757** stranded under the *dead pod's* consumer (a name the new
  leader never reuses → orphaned forever). Fixed: **0** — the new leader reused the stable
  name, re-read that PEL from `"0"`, and republished + acked it.
- **End-to-end region-KV membership** — keys the sink actually applied. Baseline: **757**
  missing. Fixed: **all 5000** present.

In the baseline run `pel_residual == loss_keys == 757` exactly: the messages orphaned in the
dead consumer's PEL are precisely the ones missing downstream. That equality is the causal
link between the pod-scoped consumer identity and the data loss.

## How the vulnerable window was made deterministic

A write-then-ack pipeline (XAck only after the NATS PubAck) loses only the messages that are
**read-but-not-yet-published at the instant of the kill**. On a fast leg that set is tiny and
hard to catch. The harness enlarges the *genuine* in-flight set (it does not manufacture a
fake one) with two prod-safe, defaulted knobs applied identically to both runs:

- `connect.source.maxInFlight = 1` — serialize the NATS publisher so PEL entries are truly
  un-published, not merely published-and-awaiting-ack.
- `connect.source.readLimit = 2000` — read a large batch into the PEL that the serialized
  publisher cannot drain before the SIGKILL.

Both default to prod values (`256` / `50`); only the verifier lowers/raises them. They widen
the exposure window; they do not change the loss mechanism.

## Reproduce

```bash
RRCS_NS=cdc-k8s RRCS_RELEASE=cdc scripts/verify-failover.sh            # both legs, gated
MODE=baseline scripts/verify-failover.sh                              # single leg
MODE=fixed    scripts/verify-failover.sh
```
