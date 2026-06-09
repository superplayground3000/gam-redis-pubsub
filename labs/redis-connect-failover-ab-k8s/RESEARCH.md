# Redis → Connect Failover: Method A vs Method C (Kubernetes) — RESEARCH

## Property compared

Two ways to keep **at most one** Redpanda Connect pod consuming a Redis stream, measured
under failover for **failover time** (zero-active gap) and **robustness** (at-most-1 held):

- **Method A** — Deployment + fail-closed client-go leader-election controller
  (research §3). Lease 6s/4s/1s. The Lease holder POSTs the consuming pipeline to its
  local streams API; on failover the standby takes over. **Best-effort active-gating, not
  fencing** — under clock skew / GC pause / SIGSTOP two pods can briefly consume at once.
- **Method C** — `StatefulSet replicas: 1` (research §5). Connect runs the pipeline
  directly (run mode). K8s guarantees at-most-one pod identity, so overlap is
  **structural ~0**; the cost is slower failover (terminate + reschedule + connect
  startup) and a potential **stall** on node failure (a pod stuck `Unknown` is not
  rescheduled until deleted).

LWW is removed; the writer is a plain producer. The lower correctness defenses (JetStream
dedup, sink CAS) remain out of scope — this lab isolates the gating mechanism.

## Fault matrix (what it does and does NOT expose)

The harness injects two faults on the active consumer, applied identically to A and C:

- **graceful-delete** — `kubectl delete pod` (respects `terminationGracePeriodSeconds`).
  Clean failover. A: the elector's `OnStoppedLeading` DELETEs its stream and
  `ReleaseOnCancel` frees the Lease, so a standby takes over quickly. C: the pod drains,
  then the StatefulSet creates a fresh `connect-0`.
- **force-delete** — `kubectl delete pod --force --grace-period=0` (the honest worst
  case; research §5 warns Method C against this). A: the dead pod's stream dies with it
  and the Lease lingers ~one lease-duration → a gap. C: `connect-0` is recreated → a gap
  of roughly pod scheduling + connect startup.

> **Honest scope note.** Both faults make the old consumer *stop* (deleted or
> Lease-cancelled), so neither manufactures a dual-active window. **Method A's
> best-effort overlap is therefore expected to read 0 here**, the same as Method C's
> structural 0. The fault that *would* expose A's overlap is **SIGSTOP on the elector**
> (the frozen controller keeps its stream while a standby wins the Lease) — deliberately
> **out of scope** for this comparison. `overlap_pairs` is measured on every run so the
> at-most-1 claim is backed by data, not asserted.

So the measured head-to-head signal is **failover time**, with `at_most_1_held = yes`
expected for both methods under this matrix.

## How failover time is measured

The observer samples every 100ms. A pod is "active" in a consecutive sample-pair iff its
`consumed:<pod>` counter rose. From that single signal:
- `gap_pairs` — pairs where the grand total did not increase (no pod consumed).
- `overlap_pairs` — pairs where ≥2 pods rose (dual-active).
- `single_active` — every pair had exactly one pod rising (Method A additionally requires
  the streams API to report exactly one active stream; Method C, run mode with no streams
  API, relies on the counter alone — `REQUIRE_STREAM_COUNT=false`).

**failover_time_s = gap_pairs × 0.1s**, stamped over the post-fault window.

Note: the observer skips the headless-DNS / `GET /streams` scrape entirely when stream
counts are not required (Method C). This is load-bearing — with `StatefulSet replicas:1`,
a failover empties the headless Service, so a DNS lookup there would fail and drop exactly
the zero-active samples needed to measure the gap. The `consumed:*` read alone suffices
because redis-central is a separate, always-up Deployment.

## Interpreting the result

- **Liveness — measured, and it refuted the naive hypothesis.** The naive expectation is
  "A is the fast one, C pays connect cold-start, so A ≤ C." The measurement (below) shows
  the **opposite**: Method A's recovery is gated by **lease timing** — a standby cannot
  take over until the Lease is free/expired (~the 6s LeaseDuration) — so A lands at
  ~6–7s regardless of graceful vs force. Method C's recovery is just **pod reschedule +
  warm `connect run` startup** (~1s when the image is already on the node), so it is
  several times faster here. Force-delete C even beats graceful C, because a StatefulSet
  only recreates `connect-0` once the old pod has *fully* terminated — graceful waits out
  the `terminationGracePeriodSeconds` drain, force-delete does not.
- **Safety:** both hold at-most-1 under this matrix (`overlap_pairs = 0`). The difference
  is *why*: C's zero is structural (K8s identity), A's zero is best-effort and would break
  under SIGSTOP-class faults — so correctness must never rest on Method A's Lease.
- **Takeaway:** under this fault matrix, Method C is both *safer* (structural at-most-1)
  **and** *faster to recover* (no lease to wait out) — its documented weakness is the
  uncovered case: a **node failure** strands the single pod (`Unknown`) until something
  deletes it, an unbounded stall Method A's multi-pod election avoids. Pick A only when
  you need that node-failure resilience and can tolerate lease-bounded failover; otherwise
  C is simpler, safer, and faster for planned/pod-level disruptions.

## Validated result (kind — Method A with 3 replicas, Method C with replicas:1)

`scripts/verify-failover.sh` on a local `kind` cluster (writer 2000 msg/s, observer
sampling 100ms, lease 6s/4s/1s). Steady state for both methods: `single_active=true`,
`overlap_pairs=0` over a clean 6s window (61 samples).

```
method  fault            failover_time_s    overlap_pairs   at_most_1_held
A       graceful-delete  6.1                0               yes
A       force-delete     7.1                0               yes
C       graceful-delete  1.4                0               yes
C       force-delete     0.8                0               yes
[verify-failover] PASS — both methods steady single-active AND at-most-1 held
```

(`failover_time_s = gap_pairs × 0.1s`; raw gap_pairs were A: 61/71, C: 14/8.) Both methods
kept at-most-one consumer throughout (no measured overlap) — as expected, since this
matrix stops the old consumer rather than freezing it. The headline difference is
liveness: **Method A's lease-gated failover (~6–7s) was markedly slower than Method C's
reschedule-only failover (~1s)** — the reverse of the naive expectation, for the reason
analysed above.

## Design decisions

- **Single chart, `method` toggle** — both methods see the identical writer load, Redis,
  and observer math; the only honest way to compare. `method=A` renders the
  Deployment + elector + Lease RBAC; `method=C` renders the StatefulSet (no elector, no
  RBAC).
- **Counter-based active signal** — makes the observer's overlap/gap/single-active math
  identical for both methods; the streams-API stream-count check is Method-A-only.
- **Lease 6s/4s/1s** — shortened from research's 15/10/2 for fast demo failover.
- **Method C run mode** — `connect run` expands `${POD_NAME}` at config load (the streams
  REST API does not — that trap is Method A's, §3.5).

## Deliberately excluded

- SIGSTOP and node-NotReady faults (would expose A's overlap / C's stall) — named above.
- JetStream dedup, sink CAS, region Redis — the parent fork's concern.
- Method B; strict-ordering knobs (`max_in_flight`, partition-by-key).

## Further reading

- `../../active-stanby-mechanism/research.md` — Method A (§3), Method C (§5), the
  best-effort-not-fencing thesis (§0–§2).
- `../redis-connect-leader-election-k8s/` — the Method-A-only lab this forks.
