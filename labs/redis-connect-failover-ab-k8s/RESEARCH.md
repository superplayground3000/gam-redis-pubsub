# Redis → Connect Leader Election (Kubernetes) — RESEARCH

## Property demonstrated

A self-written **client-go leader-election controller** makes **exactly one** of N=3
Redpanda Connect pods consume the Redis stream under steady state, transfers consumption
to a standby on failover — and we **measure both best-effort failure windows**: a
dual-active *overlap* (SIGSTOP) and a zero-active *gap* (force-kill) — proving this is
**active-gating, not fencing**.

This lab deliberately demonstrates the upstream research's **#1 thesis**: leader election
provides *best-effort active-gating*, **not** correctness-guaranteed single-active. It is a
Kubernetes/Helm fork of `../redis-connect-lww-k8s/`, stripped to the **source leg only**.
The mechanism comes from `../../active-stanby-mechanism/research.md` (Method A — streams
mode + fail-closed leader-election controller).

> Leader election only reduces concurrent-consumption probability; **order and uniqueness
> must not depend on the Lease.** The correctness boundary (Redis consumer group +
> JetStream dedup + sink CAS) is deliberately **excluded** here so the gating behavior —
> and its honest failure windows — is observed in isolation.

## Essentials (what is load-bearing)

Pipeline: `writer → redis-central stream → N×[connect (streams mode) + elector sidecar] →
INCR consumed:<pod>`. No NATS, no sink CAS, no region — those are lower defenses, not part
of active-gating.

- **Streams mode, empty boot.** Each connect pod runs `connect streams -o
  observability.yaml` with **no** pipeline. A pipeline only exists while a pod is leader.
- **The elector (`elector/`).** A client-go `leaderelection` controller, one sidecar per
  connect pod. Fail-closed (research §3.1–3.3):
  - **Boot:** `DELETE /streams/{id}` first; if it can't confirm a clean state it
    `os.Exit`s (kubelet restarts it) rather than entering election in an unknown state.
  - **OnStartedLeading:** `POST /streams/{id}` (with retry). If POST keeps failing it
    releases leadership and stays fail-closed (never consumes without confirmed leadership).
  - **OnStoppedLeading:** `DELETE /streams/{id}` (with retry); persistent failure →
    `os.Exit(1)` so the stream dies with the process.
- **`__POD__` substitution.** The streams REST API does **not** expand env vars in POSTed
  configs (research §3.5), so the elector substitutes its pod name into the pipeline
  template before POST. The pod name lands in `client_id` and in `INCR consumed:<pod>`.
- **Observability split (research §3.5 trap 3).** `http`/`logger`/`metrics` live in the
  `-o` observability config; the POSTed stream config carries only input→processor→output.
- **`/ready` is not "am I active" (research §3.5 trap 2).** A standby with zero streams
  still returns 200 — exactly what we want (healthy yet not consuming). Active-ness is read
  from `GET /streams` (leader has 1, standbys 0).
- **Lease identity = pod name.** The harness reads `lease.spec.holderIdentity` to know
  which pod to fault-inject. Lease timings default to **6s/4s/1s** (LeaseDuration /
  RenewDeadline / RetryPeriod) — the same algorithm as research's 15/10/2, shortened for
  fast demo failover.
- **Per-pod attribution.** Each consumed message does `INCR consumed:<pod>` in
  redis-central. These counters are monotonic and never deleted, so the observer can detect
  which pods consume by watching which counters rise.
- **The observer (`observer/`).** Samples every 100ms: all `consumed:*` counters + each
  connect pod's `/streams` count (pods discovered via the headless service DNS — no K8s API
  / RBAC). It serves `/timeline` and `/verdict`, computing: `SingleActive` (every pair has
  exactly one pod rising AND active==1), `OverlapPairs` (pairs with ≥2 pods rising),
  `GapPairs` (pairs with no total increase). Invalid snapshots (Redis/DNS error) are
  dropped so the math never sees corrupt data.

### Wire contract (enough to re-implement a client)

- Writer XADD fields on `app.events`: `value` (JSON body), `event_id`, `key`, `pattern`,
  `t_send_ms`, `version`. (The LWW `version`/`key` fields are inherited from the fork and
  harmless here — gating doesn't use them.)
- Streams REST (per pod, `:4195`): `POST /streams/{id}` (body = pipeline YAML,
  `Content-Type: application/x-yaml`), `DELETE /streams/{id}` (404 ⇒ already absent),
  `GET /streams` (JSON map; count = number of active streams).
- Elector metrics (`:8090/metrics`): `elector_leading`, `elector_post_total{result}`,
  `elector_delete_total{result}`.
- Observer (`:8070`): `GET /timeline?since_unix_ms=N`, `GET /verdict?since_unix_ms=N` →
  `{samples, single_active, overlap_pairs, gap_pairs}`.
- Writer control plane: `POST /reset {"epoch":"…"}`, `POST /rate {"rate":n}`,
  `GET /state` → `{…, epoch, distinct_keys}`.

## How the proof is made unambiguous

- **Proof A (single-active)** is asserted over a **clean steady-state window** (after a
  settle, the harness records a start timestamp and observes only `OBS_WINDOW_S` of
  post-settle samples) — so the messy startup before a leader is elected cannot satisfy or
  spoil it. It requires `single_active==true` (every pair: exactly one pod rising AND
  exactly one active stream) **and** a non-empty lease holder.
- **Proof B1 (overlap)** freezes the leader's elector with SIGSTOP: the frozen controller
  can neither renew the lease **nor** run its fail-closed DELETE, so its connect stream
  keeps consuming while a standby wins the lease and POSTs its own — `overlap_pairs > 0`
  means ≥2 pods' counters genuinely rose at the same time (true concurrent consumption,
  impossible under hard fencing). The elector must not be PID 1 (it runs under `tini`)
  because SIG_DFL signals are not reliably delivered to PID 1 in a namespace.
- **Proof B2 (gap)** force-deletes the leader pod (`--force --grace-period=0`): the stream
  dies with no graceful DELETE and the Lease lingers until expiry, so for a window **no**
  pod consumes — `gap_pairs > 0` (grand total flat while the writer is provably sending).
- Final verdict: gating works (Proof A) **and** is best-effort (B1 overlap>0 OR B2 gap>0).

## Validated result (kind, N=3)

`scripts/verify-election.sh` on a local `kind` cluster (N=3 connect pods, lease 6s/4s/1s,
observer sampling 100ms, writer 2000 msg/s):

- **Proof A (single-active):** over a clean 6s post-settle window (61 samples),
  `single_active=true` — every consecutive pair had exactly one pod's `consumed:<pod>`
  counter rising **and** exactly one active stream cluster-wide; the Lease had a holder.
  Active-gating holds in steady state.
- **Proof B1 (dual-active overlap):** SIGSTOP the leader's elector (pid 14, under tini) →
  `overlap_pairs=56` ≈ **5.6 s** during which ≥2 pods' counters rose simultaneously. Two
  pods genuinely consumed at once — impossible under hard fencing. Best-effort confirmed.
- **Reconvergence gate (between B1 and B2):** after B1, a fresh steady-state window
  re-asserts `single_active=true` and a non-empty Lease holder before B2 runs — so the B2
  gap is provably caused by the force-kill, not a lingering B1 outage (guards against a
  false PASS). This also demonstrates the cluster recovers to single-active after overlap.
- **Proof B2 (zero-active gap):** `kubectl delete pod <leader> --force --grace-period=0` →
  `gap_pairs=66` ≈ **6.6 s** during which no pod's counters advanced (stream died with the
  pod, Lease lingered until expiry, then a standby took over).
- **Verdict:** `single_active=true overlap_pairs=63 gap_pairs=66` → **PASS**. Gating works
  **and** is best-effort — both failure windows (~the 6s lease duration) were measured, and
  the cluster reconverged to single-active in between.

The non-zero overlap and gap are the system working as documented: leader election lowers
the probability of concurrent consumption but does not eliminate the dual-active / zero-active
windows, so correctness must never rest on the Lease.

## Design decisions

- **N=3** — one leader + two standbys; exercises election among multiple candidates.
- **Lease 6s/4s/1s** — same algorithm as research's 15/10/2, shortened so failover (and the
  measured windows) happen within a short demo run.
- **tini in the elector image** — so the controller is a child PID, not PID 1, making
  SIGSTOP/SIGCONT (Proof B1) act on it.
- **Source-leg only** — drops NATS/JetStream dedup, sink CAS and region Redis (the fork's
  concern). Keeps one concern: the gating mechanism and its honest failure windows.
- **Observer via headless-service DNS** — no K8s API or RBAC for the observer; it resolves
  all connect pod IPs and scrapes each `/streams`. (Only the elector needs lease RBAC.)
- **Dashboard is observer-backed** — it polls the observer's `/timeline` + `/verdict`
  rather than Redis keyspace events, so it has a single source of truth and no Redis
  dependency (and sidesteps the INCR→`incrby` keyspace-event naming subtlety).

## Rejected alternatives (from upstream research)

- **Elector sidecar + shell `watch` script** driving the REST API (research §3) — adds a
  third state-sync failure surface; we use a single-process controller driven directly by
  the leader-election callbacks.
- **Env-var interpolation inside the stream config** (research §3.5) — unsupported by the
  streams REST API; we template `__POD__` in the controller before POST.

## Deliberately excluded

- The lower correctness defenses (JetStream dedup, sink CAS) — the fork's concern; including
  them would make this two concerns.
- Native sidecar lifecycle (research §3.3 opt 2, requires K8s 1.28+) — noted as hardening;
  we rely on the boot-time DELETE for residual-consumption cleanup.
- Strict global ordering knobs (`threads:1` is set, but `max_in_flight:1` / partition-by-key
  are out of scope — research §6).
- Multi-stream-key subject namespacing (research §3.6).
- Method C (`StatefulSet replicas: 1`) — a different route; this lab is Method A only.

## Further reading

- `../../active-stanby-mechanism/research.md` — Method A, fail-closed table (§3.2),
  streams-mode traps (§3.5), monitoring signals (§8).
- `../../docs/superpowers/specs/2026-06-08-redis-connect-leader-election-k8s-design.md` — the design spec.
- `../redis-connect-lww-k8s/` — the fork this lab strips down.
