# redis-connect-failover-ab-k8s — Design

> **Date:** 2026-06-09
> **Status:** Approved (brainstorm) → ready for implementation plan
> **Topic:** A new K8s lab that removes the inherited LWW machinery and compares two
> ways of achieving "at most one active Redpanda Connect consumer" — **Method A**
> (Deployment + fail-closed leader-election controller) vs **Method C**
> (`StatefulSet replicas: 1`) — measuring **failover time** and **robustness**
> (at-most-1-active held) head-to-head.

## 1. Goal & motivation

The existing lab `labs/redis-connect-leader-election-k8s/` demonstrates **Method A**
only, and carries **LWW** (`version`/`key` fields, per-key version map, `lww:<epoch>:<id>`
key naming) inherited from its parent `redis-connect-lww-k8s/`. That LWW machinery is
**write-only / vestigial** in the leader-election context: the connect pipeline only does
`INCR consumed:<pod>` then `drop: {}`, and no consumer, observer, dashboard, or verifier
ever reads `version`/`key`/`distinct_keys`. RESEARCH.md already says so explicitly.

This lab:

1. **Removes LWW** so the writer is a plain stream producer (cleaner, more honest — the
   `lww:` keys falsely imply correctness machinery this lab deliberately excludes).
2. **Adds Method C** (`StatefulSet replicas: 1`) alongside Method A.
3. **Measures and records**, for both methods under the same fault matrix:
   - **failover time** = duration of the zero-active gap, and
   - **robustness** = whether "at most one connect is consuming at any instant" holds
     (i.e. `overlap_pairs == 0`).

The comparison surfaces the **safety-vs-liveness** trade-off:

- **Method A** optimizes **liveness** — fast failover via short lease, but the
  upstream `client-go` leader election is *best-effort* (no fencing): under
  clock skew / GC pause / SIGSTOP it can briefly run **two** active consumers.
- **Method C** optimizes **safety** — K8s StatefulSet at-most-one pod identity makes
  overlap **structurally ~0**, but failover is slower and can **stall** (long
  zero-active gap) under force-delete / node failure.

### Scope honesty note (load-bearing)

The chosen fault matrix is **graceful delete + force delete** (SIGSTOP and node-NotReady
are **out of scope** per decision). Under these two faults the *dead or cancelled* pod
stops consuming, so **Method A's best-effort overlap will most likely NOT fire** — both
methods are expected to show `overlap_pairs ≈ 0`. Therefore:

- The **headline measured result** is the **failover-time** difference, plus confirming
  `at_most_1_held = yes` for both methods under these faults.
- The **theoretical** distinction ("A is best-effort-0, C is structural-0") is **stated**
  in RESEARCH.md, with **SIGSTOP named as the out-of-scope fault** that would expose
  A's overlap. `overlap_pairs` is measured on every run so the data backs the claim
  rather than asserting it.

Methods A and C are defined in `../../active-stanby-mechanism/research.md` (§3 and §5).

## 2. Architecture

New lab `labs/redis-connect-failover-ab-k8s/`, forked from
`redis-connect-leader-election-k8s/`.

```
writer (no LWW) ──XADD──▶ redis-central stream (app.events)
                                  │
                                  ▼  consumed by the active connect pod(s)
        method=A: Deployment(N=3) + elector sidecar each (coordination Lease)
        method=C: StatefulSet replicas:1, static pipeline, NO elector
                                  │
                                  ▼
                         INCR consumed:<pod>   (redis-central)
                                  │
        observer (samples every 100ms) ── counters = universal active signal
                                  │
                         /verdict, /timeline
                                  │
                         dashboard (observer-backed)
```

A single Helm chart toggles the method via `.Values.method: A|C` (chosen approach;
alternatives — two simultaneous releases, or two values files — rejected because a
single toggled chart guarantees both methods see the **identical** writer load, redis,
and observer math, which is the only way the comparison is fair).

## 3. Components & changes

### 3.1 writer/ — remove LWW
- **Delete:** per-key version map and shard striping in `version.go`
  (`NextForCurrent` version counter, `ownedKeyID` in `worker.go`), the
  `lww:<epoch>:<id>` key naming, the `key` + `version` XADD fields, and the
  `/state` `distinct_keys` / `total_versions` reporting.
- **Keep / replace:** the `/reset` → **start gate**. The writer currently refuses to
  emit until `Versions.Epoch() != ""` (set by `POST /reset`), and
  `verify-*.sh` uses that to start traffic. Replace the epoch-version object with a
  trivial "started" flag (or a plain epoch string with no per-key map) so `/reset`
  still kicks off traffic. Payload, rate limiter, counters, HTTP control plane unchanged.
- **XADD after change:** `value` (JSON body, still carries `seq` inside it), `event_id`,
  `pattern`, `t_send_ms`. (Top-level `key` and `version` fields removed.) The worker
  passes its monotonic `emitted` count as the payload `seq`.
- **Tests:** update `version_test.go`, `worker_test.go`, `http_test.go`,
  `payload_test.go` to the stripped shape; all must stay green.

### 3.2 connect — Method A (unchanged mechanism)
- `connect streams -o observability.yaml` empty boot; one **elector** sidecar per pod
  (client-go `leaderelection`, fail-closed: boot DELETE, OnStartedLeading POST,
  OnStoppedLeading DELETE → os.Exit on persistent failure). Lease 6s/4s/1s.
- Rendered only when `.Values.method == "A"`. Reuse `elector/` as-is.

### 3.3 connect — Method C (new)
- `StatefulSet` with `replicas: 1`, running the pipeline **directly** (run mode), not
  streams mode. Env-var interpolation (`${POD_NAME}`) **is** supported when connect
  loads a config file at startup (the streams REST API's no-env-interpolation trap does
  **not** apply here), so `client_id` and `INCR consumed:<pod>` can be templated from the
  downward-API `POD_NAME`.
- **No elector, no RBAC, no Lease.** Uniqueness = StatefulSet stable identity
  (at-most-one `<name>-0`).
- `terminationGracePeriodSeconds` set so in-flight batches/XACK can flush on graceful
  delete; optional `PodDisruptionBudget`. (Per research §5 — Method C should normally
  *not* be force-deleted; the harness force-deletes it deliberately to measure the
  honest worst case.)
- Rendered only when `.Values.method == "C"`.

### 3.4 observer/ — counter-based universal active signal
- The active signal becomes **counter-based**: a pod is "active" in a consecutive
  sample-pair iff its `consumed:<pod>` counter **rose**. This already yields:
  `single_active` (exactly one pod rose), `overlap_pairs` (≥2 rose), `gap_pairs`
  (none rose) — and works **identically** for Method A and Method C.
- The `GET /streams`-count assertion (leader has 1 stream) is **Method-A-only**:
  gate it behind `REQUIRE_STREAM_COUNT` (true for A, false for C — Method C run-mode
  connect does not serve the streams API count). Invalid snapshots still dropped.
- Pod discovery via the headless `connect` service DNS (selects both Deployment and
  StatefulSet pods by the shared `app=connect` label).

### 3.5 chart/
- `templates/connect-deployment.yaml` — `{{- if eq .Values.method "A" }}` … Deployment
  + elector sidecar (current).
- `templates/connect-statefulset.yaml` — `{{- if eq .Values.method "C" }}` … StatefulSet
  replicas:1.
- One headless `connect` Service selecting `app=connect` (both pod types).
- `rbac.yaml` + elector bits gated to method A.
- Shared: `redis-central`, `writer`, `observer`, `dashboard`, services.
- `values.yaml` gains `method` (default `A`), `connectC.terminationGracePeriodSeconds`,
  observer `requireStreamCount` wired from method.

## 4. Measurement flow (per method, per fault)

1. `helm upgrade --set method=<A|C>`; wait until connect Ready; `POST /reset` to start
   the writer.
2. **Settle**, record a clean steady-state window → assert `single_active == true`
   and `overlap_pairs ≈ 0` (and, A only, a non-empty Lease holder).
3. **Inject fault** on the active pod and **stamp the inject time**:
   - `graceful-delete`: `kubectl delete pod <active>` (respects grace period).
   - `force-delete`: `kubectl delete pod <active> --force --grace-period=0` (fresh run).
4. Read observer `/verdict` over the post-fault window:
   - **failover_time_s = gap_pairs × 0.1s** (sample interval), consistent with how the
     parent lab phrases gap (`gap_pairs=66 ≈ 6.6s`).
   - record `overlap_pairs`.
5. **Reconverge** to single-active before the next scenario (guards against a false
   reading from a lingering prior outage).

"Active pod" resolution: Method A = `lease.spec.holderIdentity`; Method C = the sole
`<name>-0` pod.

## 5. Output / deliverable

`scripts/verify-failover.sh` runs the full matrix and prints a comparison table:

```
method  fault            failover_time_s   overlap_pairs   at_most_1_held
A       graceful-delete  ~X.X              0               yes
A       force-delete     ~6 (≈ lease)      0               yes
C       graceful-delete  ~Y.Y             0               yes
C       force-delete     ~Z.Z             0               yes
```

`at_most_1_held = (overlap_pairs == 0)`. The script exits 0 when every scenario produced
a measured failover_time and `at_most_1_held = yes` for the chosen fault matrix.

`RESEARCH.md` interprets the table: the safety-vs-liveness trade-off, why Method C's
overlap is **structural-0** while Method A's is **best-effort-0 under these faults**
(with SIGSTOP named as the out-of-scope fault that would expose A's overlap), and the
failover-time differences (A's short-lease fast handover vs C's
terminate+reschedule+startup).

## 6. Scripts

- `scripts/build-images.sh` — build writer / observer / dashboard; elector only needed
  for A; Method C uses the stock connect image (no new image).
- `scripts/render.sh` — `helm template` for both methods (sanity).
- `scripts/verify-failover.sh` — the comparison harness (§4–§5). Replaces the parent
  lab's `verify-election.sh`.
- `scripts/dashboard-forward.sh`, `scripts/lib/run-defaults.sh` — reuse.

## 7. Testing

- **Go unit tests** stay green: writer without LWW (`version_test.go` etc. updated),
  observer counter-based logic (`timeline_test.go` covering single/overlap/gap from
  counters; add `requireStreamCount=false` path).
- **Lab-level validation** is `scripts/verify-failover.sh`: it must produce the populated
  comparison table with `at_most_1_held = yes` for both methods under graceful + force
  delete, and non-zero measured failover times — exiting 0 only then.
- This is a Kubernetes lab, so the research-lab skill's docker-compose `validate_lab.sh`
  does **not** apply (same as the parent lab).

## 8. Deliberately excluded (YAGNI)

- **SIGSTOP** and **node-NotReady** faults (per decision) — noted in RESEARCH as the
  faults that would expose Method A's overlap / Method C's stall; an env-flagged
  extension point may be left but not built.
- Lower correctness defenses (JetStream dedup, sink CAS, region Redis) — the parent
  fork's concern; including them is a second concern.
- Method B and `max_in_flight`/partition-by-key strict-ordering knobs — out of scope.

## 9. Further reading

- `../../active-stanby-mechanism/research.md` — Method A (§3), Method C (§5),
  best-effort-not-fencing thesis (§0–§2).
- `labs/redis-connect-leader-election-k8s/` — the Method-A-only lab this forks; LWW
  removal rationale is in its earlier analysis.
