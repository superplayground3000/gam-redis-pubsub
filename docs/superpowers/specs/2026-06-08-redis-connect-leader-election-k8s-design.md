# redis-connect-leader-election-k8s — Design

**Date:** 2026-06-08
**Status:** Approved (brainstorming)
**Upstream research:** `active-stanby-mechanism/research.md` (Method A — streams mode + fail-closed
client-go leader-election controller).
**Forked from:** `labs/redis-connect-lww-k8s/`.

---

## Property demonstrated (one sentence)

> A self-written **client-go leader-election controller** makes **exactly one** of N Redpanda
> Connect pods consume the Redis stream under steady state, transfers consumption to a standby on
> failover — and we **measure both best-effort failure windows**: a dual-active *overlap* (SIGSTOP)
> and a zero-active *gap* (force-kill) — proving this is **active-gating, not fencing**.

This lab deliberately demonstrates the research doc's **#1 thesis**: leader election provides
*best-effort active-gating*, **not** correctness-guaranteed single-active. Order and uniqueness must
never depend on the Lease; the correctness boundary lives in lower defenses (Redis consumer group +
JetStream dedup + sink CAS) which this lab intentionally **excludes** from the data path so the
gating behavior — and its honest failure windows — is observed in isolation.

---

## Scope decisions (locked in brainstorming)

| Decision | Choice | Rationale |
|---|---|---|
| Core property | Active-gating **+ best-effort honesty** | Most faithful to the doc's central correction; happy-path-only would misrepresent the mechanism as a guarantee. |
| Data path | **Source-leg only** (drop NATS/JetStream/sink-CAS/region) | Active-gating lives entirely on the `redis_streams` input; lower defenses are irrelevant to proving gating and would blur the single concern. |
| Dual-active induction | **Both** SIGSTOP (overlap) **and** force-kill (gap) | Shows best-effort failure in both directions: over-count and under-count. |
| Language | **Go** | The controller *is* `k8s.io/client-go/tools/leaderelection` (Go-only); matches existing writer/verifier and team production default. |
| Replicas | **N=3** | One leader + two standbys; exercises election among multiple candidates. |
| Dashboard | **Keep** | Live per-pod consumption view makes the overlap/gap windows visible in a browser. |
| Lease timing | Default **6s / 4s / 1s** (LeaseDuration / RenewDeadline / RetryPeriod) | Same algorithm as research's 15/10/2, shortened for fast demo failover. Tunable via values. |

---

## Topology (4 service types, on `kind`)

```
writer ──XADD app.events──▶ redis-central  (stream + consumer group "electors")
                                  ▲
              N=3 × pod           │ XREADGROUP via redis_streams input
        ┌─────────────────────────┴───────────────────────────┐
        │  connect      : rpk connect streams, EMPTY boot      │  :4195 REST + metrics
        │  elector-ctrl : client-go leaderelection (sidecar)   │  :8080 healthz + metrics
        │                 POST/DELETE /streams/{id} on :4195    │
        └───────────────────────────────────────────────────────┘
                                  │ output stamps ${POD_NAME}
                                  ▼
                       INCR consumed:<pod>  (in redis-central)   ← per-pod attribution
                                  │
        observer/verifier (Job)   │ reads: GET :4195/streams per pod,
                                  ▼         consumed:<pod> deltas, XINFO CONSUMERS
                            verdict (exit 0/1)
        dashboard (Deployment)  ── live per-pod consumed:<pod> + active-stream view
```

Connect runs in **streams mode** (`rpk connect streams`, empty boot) — the key structural change
from the fork, which ran a static `-r` config. The pipeline that gets POSTed at leadership is a
single `redis_streams` input → `redis` output (`INCR consumed:<pod>`).

---

## The new component — `elector-controller`

A Go sidecar, one per connect pod. Fail-closed state machine straight from research §3.1–3.3.

### State machine

| Trigger | Action |
|---|---|
| **Boot** | `DELETE /streams/{id}` first — re-sync to "not consuming until confirmed leading" (research §3.2 row 1). |
| `OnStartedLeading` | Template config with `POD_NAME` (handles §3.5 trap: streams REST does **not** interpolate env vars), then `POST /streams/{id}` with retry. If POST keeps failing → `cancelLeadership()` and stay fail-closed (a leader that can't start the stream releases the lease). |
| `OnStoppedLeading` | `DELETE /streams/{id}` with retry; on persistent failure → `os.Exit(1)` so kubelet restarts the pod and the stream dies with the process. |
| Cannot reach apiserver / can't confirm leading | `DELETE` local stream (fail-closed). |

### Config

`LeaderElectionConfig`: `ReleaseOnCancel: true`, `LeaseDuration/RenewDeadline/RetryPeriod` from env
(defaults 6s/4s/1s). Lock = `coordination.k8s.io/v1` Lease in the release namespace, `Identity =
POD_NAME`.

### Observability (research §8)

- `/healthz` (HTTP 200 when controller loop alive).
- Prometheus counters: `elector_post_total{result}`, `elector_delete_total{result}`,
  `elector_leading` (gauge 0/1).

### Rejected alternative

Elector sidecar + shell `watch` script driving the REST API. Research §3 explicitly warns this adds
a third state-sync failure surface. We use the **single-process controller** that drives the streams
API directly from the leader-election callbacks.

---

## Proofs (observer Job orchestrates, prints verdict, exits 0/1)

### Proof A — steady-state single-active
After settle window, assert simultaneously:
- `sum(active_streams) == 1` across the N pods (`GET :4195/streams`, leader has exactly 1 stream,
  standbys 0).
- Exactly one `consumed:<pod>` counter is advancing.
- `XINFO CONSUMERS app.events electors` shows one consumer doing work.

### Proof B1 — dual-active **overlap** (SIGSTOP)
1. Identify the leader (the pod whose `consumed:<pod>` is advancing / has the stream).
2. SIGSTOP the controller process (`kubectl exec <leader> -c elector -- kill -STOP <pid>`). Frozen
   controller can neither renew the lease **nor** run its fail-closed DELETE → its connect stream
   keeps consuming.
   - **PID-1 caveat:** in a PID namespace, SIG_DFL signals are not delivered to PID 1, and SIGSTOP to
     PID 1 from within its own namespace is unreliable. The controller must therefore **not** be the
     container's PID 1 — run it under a minimal init/shim (e.g. `tini`) so the controller is a normal
     child PID that SIGSTOP/SIGCONT act on. The proof targets that child PID (resolved at run time),
     not a hardcoded `1`.
3. Lease expires → a standby wins election → `POST`s its stream.
4. **Measure** the window where **≥2** `consumed:<pod>` counters advance simultaneously → record
   overlap duration.
5. SIGCONT the controller (`kill -CONT <pid>`) → old leader detects lost leadership → `DELETE`s →
   back to exactly one active.

Pass: overlap window observed (`overlap_ms > 0`) **and** system reconverges to single-active.

### Proof B2 — zero-active **gap** (force-kill)
1. `kubectl delete pod <leader> --force --grace-period=0` → stream dies with the pod, **no graceful
   DELETE**; the Lease lingers (held by the dead identity) until expiry.
2. **Measure** the window where **zero** `consumed:<pod>` counters advance → record gap duration.
3. Lease expires → standby wins → `POST`s → consumption resumes.

Pass: gap window observed (`gap_ms > 0`) **and** consumption resumes on a surviving pod.

### Verdict
Single line asserting **gating works** (Proof A) **and** is **best-effort** (B1 overlap > 0 OR B2
gap > 0 observed), echoing the doc's correctness-boundary disclaimer:
> Leader election only reduces concurrent-consumption probability; order and uniqueness must not
> depend on the Lease.

---

## Reused vs dropped (from `labs/redis-connect-lww-k8s`)

**Reused / trimmed**
- `writer/` (Go XADD rate driver) — strip LWW per-key versioning down to a plain event with
  `event_id`; keep the `/rate`, `/reset`, `/metrics` control plane.
- Helm chart skeleton, `redis-central`, `scripts/build-images.sh`, `scripts/render.sh`,
  `scripts/dashboard-forward.sh`, the kind workflow.
- `dashboard/` — repoint from LWW key/version stream to per-pod `consumed:<pod>` + active-stream view.

**Dropped**
- All NATS/JetStream: `nats.yaml`, `nats-config-cm.yaml`, `nats-init-job.yaml`,
  `nats-auth-secrets.yaml`, `chart/files/nats-auth/**`, `gen-nats-auth.sh`.
- `connect-sink.yaml`, the sink CAS Lua (`lww_set.lua`), `redis-region.yaml`.
- The LWW verifier (`verifier/lww.go` etc.) — replaced by an election observer.
- Static `-r` connect config (`lww-forward.yaml` / `lww-reverse.yaml`) — replaced by streams-mode
  empty boot + POSTed pipeline.

**New**
- `elector/` — the client-go leader-election controller (Go).
- `chart/templates/connect-deploy.yaml` — Deployment (replicas: 3) with `connect` + `elector`
  containers, ServiceAccount, Lease RBAC.
- `chart/templates/rbac.yaml` — Role/RoleBinding for `coordination.k8s.io/v1` leases
  (`get,list,watch,create,update,patch`) + ServiceAccount (research §4).
- `observer/` (or `verifier/` rewrite) — Go Job that runs Proof A/B1/B2 and emits the verdict.
- `chart/files/connect/pipeline.yaml` — the streams pipeline POSTed at leadership.
- `scripts/verify-election.sh` — the validation gate.

---

## Mechanics & validation

- **RBAC:** new Role for `coordination.k8s.io/v1` leases per research §4; ServiceAccount bound to the
  connect Deployment. Lease object created in the release namespace.
- **Isolation:** built in git worktree `worktree-leader-election-lab` at
  `.claude/worktrees/leader-election-lab`.
- **Validation:** Kubernetes lab — the research-lab skill's `validate_lab.sh` (docker-compose only)
  does **not** apply (same as the fork). `scripts/verify-election.sh` is the gate: deploys via Helm
  on `kind`, runs Proof A + B1 + B2, exits 0 only when all pass.

---

## Deliberately excluded

- The lower correctness defenses (JetStream dedup, sink CAS) — that is the fork's concern / research
  option 3; including them would make this two concerns.
- Native sidecar lifecycle (research §3.3 opt 2, requires K8s 1.28+) — noted as a hardening option,
  not required; we rely on the boot-time DELETE (§3.2 row 1) for residual-consumption cleanup.
- Strict global ordering knobs (`threads:1`, `max_in_flight:1`, partition-by-key) — research §6.
- Multi-stream-key subject namespacing (research §3.6 prefix guidance).
- Throughput SLOs / the tier × mode × QoS matrix (carried by the parent stress lab).
- Method C (`StatefulSet replicas: 1`) — a different route; this lab is Method A only.

---

## Further reading

- `active-stanby-mechanism/research.md` — Method A, fail-closed table (§3.2), streams-mode traps
  (§3.5), monitoring signals (§8).
- `labs/redis-connect-lww-k8s/` — the fork this lab strips down.
