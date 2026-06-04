# Redis → Connect Last-Write-Wins (Kubernetes) — Design

**Date:** 2026-06-04
**Status:** Approved (pending spec review)
**Lab dir:** `labs/redis-connect-lww-k8s/`
**Forked from:** `labs/redis-redpanda-connect-stress-k8s/`
**Upstream spec:** `last-write-wins-lab/research.md` (the LWW mechanism this lab verifies)

## 1. Purpose & property demonstrated

**Property (one sentence):** A stale change (lower version) can never overwrite a
newer change (higher version) at the Redis KV sink, regardless of arrival order
across a parallel pipeline — and we measure the sustained applied-write throughput
of a single-instance sink that relies on this fence instead of strict ordering.

This is the mechanism from `last-write-wins-lab/research.md`: a **last-write-wins
compare-and-set (CAS) fence at the sink**, implemented as a Redis Lua `EVAL` that
writes only if the incoming `version` is strictly greater than the stored one.
The payoff the research calls out — *because correctness lives at the sink, the
ordering machinery can be dropped* — is the thing this lab makes observable: the
sink runs with `threads > 1` and high `max_in_flight` (which reorders same-key
messages) and correctness still holds.

**Why Kubernetes:** production is K8s-based, so the lab is a Helm chart driven by a
`kubectl`/`kind` harness — a fork of the existing `redis-redpanda-connect-stress-k8s`
lab, not the compose sibling.

### Deliberately excluded (next questions this lab does not answer)

- **Multi-instance / HA sink** — this lab is single-instance (one sink pod). The
  research's point about parallel queue-group consumers across *pods* is a
  follow-up; here the parallelism is intra-pod (`threads`/`max_in_flight`).
- **Redis Cluster** — sink Redis is `kind: simple`. The Lua touches a single key,
  so it is Cluster-safe by construction, but Cluster is not exercised here.
- **Chaos / crash-replay, the tier × mode × QoS matrix, latency SLOs** — carried by
  the parent lab; dropped here to keep one concern (LWW correctness + throughput).
- **Event-time / clock-skew LWW** — we use a per-key logical counter (single writer
  per key), the research's "best" token. Wall-clock LWW and its skew hazard is noted
  but not built.
- **Deletes / tombstones** — keys are never deleted in this lab.

## 2. Topology (single instance)

Inherited from the parent chart, all Deployments `replicas: 1`:

```
writer ──XADD app.events──▶ redis-central ──▶ connect-source ──pub──▶ NATS JetStream
                                                                          │
                                                                          ▼
dashboard ◀──keyspace/HGET── redis-region ◀──EVAL lww_set.lua── connect-sink (threads:4, max_in_flight:64)
   ▲                              ▲
   └── writer /state (source ver) │
                                  └── region-events ledger (XADD, observability)
```

Service types (each one job): `redis-central`, `redis-region`, `nats` (+`nats-init`
Job, +auth Secrets), `connect-source`, `connect-sink`, `writer`, `dashboard`, and a
run-scoped `verifier` Job. Single `lww` profile (no alo/amo/eoe pairs).

## 3. The fork diff

### 3.1 New `lww` Helm profile

- **`chart/files/connect/lww-forward.yaml`** — like `alo-forward.yaml`, but the
  re-wrap mapping carries a `version` field: `"version": meta("version").or("0").number()`
  added to the envelope, and `meta version = meta("version").or("0")` so it survives
  as a NATS-transported field. Otherwise identical (redis_streams input → JetStream output).

- **`chart/files/connect/lww-reverse.yaml`** — the core change. Replaces the parent's
  blind `cache` (`SET`) output leg with a CAS in the pipeline:
  - `pipeline.threads: 4`, and the sink output `max_in_flight: 64` — the ordering
    relaxation that *causes* same-key reordering.
  - A mapping lifts `key`, `value`, `version` into metadata.
  - A **`redis` processor** running `command: eval` of the mounted script:
    `args_mapping` → `[ file("/etc/rpconnect/lww_set.lua"), 1, meta("key"), content().string(), meta("version") ]`,
    `result_map: 'meta lww_applied = this'`.
  - A **`metric` processor** of type `counter` named `lww_apply` with a `result`
    label set from `meta("lww_applied")` mapped **three ways** —
    `1→applied`, `0→stale`, `-1→duplicate` — so connect-sink `/metrics` exposes
    `lww_apply_total{result=applied|stale|duplicate}`. The three-way split is what
    lets Proof B distinguish genuine reorder-fencing (`stale`) from routine
    at-least-once redelivery (`duplicate`); see §3.4.
  - Output: keep the `region-events` ledger XADD for observability/quiescence.

- **`chart/files/connect/lww_set.lua`** — the research CAS, **extended to a 3-way
  return** so the lab can prove reorder-fencing distinctly from dedup. (The production
  script in `last-write-wins-lab/research.md` returns only 1/0; collapsing `0` and `-1`
  back to `0` recovers it exactly — the extra state is a measurement affordance, not a
  behavior change: a duplicate and a stale write are both *not applied*.)
  ```lua
  -- KEYS[1]=key  ARGV[1]=value  ARGV[2]=version (monotonic integer)
  -- returns: 1 = applied (strictly newer)
  --          0 = stale  (strictly OLDER than stored — only possible under reordering)
  --         -1 = duplicate (version == stored — routine at-least-once redelivery)
  local cur = redis.call('HGET', KEYS[1], 'ver')
  if cur == false then
    redis.call('HSET', KEYS[1], 'val', ARGV[1], 'ver', ARGV[2])
    return 1
  end
  local v, c = tonumber(ARGV[2]), tonumber(cur)
  if v > c then
    redis.call('HSET', KEYS[1], 'val', ARGV[1], 'ver', ARGV[2])
    return 1
  elseif v < c then
    return 0
  else
    return -1
  end
  ```

> **Build-time verification (de-risk):** the exact `redis`-processor `eval` config
> shape (command name, `args_mapping` arity, `result_map`) must be verified against
> the `hpdevelop/connect:4.92.0-claudefix` image *before* wiring the rest. The
> implementation plan's first task renders + boots connect-sink with a trivial EVAL
> and confirms `meta lww_applied` is populated. Fallback if `eval` is unsupported:
> use `evalsha` after a one-time `SCRIPT LOAD`, or a `redis_script` cache resource.

### 3.2 Lua ConfigMap + mount

- New template `chart/templates/connect-lua-cm.yaml` — a ConfigMap holding
  `lww_set.lua` (via `.Files.Get "files/connect/lww_set.lua"`).
- `connect-sink.yaml` mounts it at `/etc/rpconnect/lww_set.lua` (subPath), only
  meaningful for the `lww` profile (harmless mount otherwise).

### 3.3 Writer — per-key versioning + `/state`

The writer must satisfy the **reorder-proof precondition** (§3.4.1): within a measured
run, the run's keys start with no stored version and are numbered monotonically by a
single, non-restarting writer. The design below *guarantees* that, so that a
strictly-older arrival at the sink can only be pipeline reordering.

- **Keyspace partitioning:** worker `i` owns keys whose id satisfies
  `keyID % workers == i`. Each worker advances its own keys only, so every key has a
  single writer → per-key version is provably monotonic with no clock dependence.
  (Replaces the parent's `(base|seq) % keyspace` scheme where multiple workers shared
  a key.)
- **Per-run key namespace (closes the cross-run hole).** The writer prefixes every key
  with a **run epoch** it receives from the verifier: `lww:<epoch>:<id>`. Each run gets
  a fresh `epoch` (the verifier mints it and POSTs it; see §3.4), so the run's keys are
  brand-new and provably have **no pre-existing stored version** in region — eliminating
  the case where a reset writer re-emits low versions over leftover-high stored versions.
  Keys from prior runs are simply abandoned (region MAXLEN/`region-events` trimming and
  a short KV TTL keep them from accumulating).
- **Per-key counter:** each worker keeps `map[int64]int64` of key→version (scoped to the
  current epoch), increments before `XADD`, and emits a new `version` field. On a
  pipeline error the batch is *skipped*, never re-emitted at a lower version, so the
  per-key sequence is strictly increasing with at most gaps (gaps are harmless to
  monotonicity).
- **Boot identity (closes the restart hole).** The writer generates a random `boot_id`
  at process start. `/state` returns it (and `epoch`). If the writer pod restarts
  mid-run, `boot_id` changes and its counters reset — the verifier detects the change
  and declares the run **inconclusive** rather than counting the reset-induced
  strictly-older arrivals as reordering.
- **`GET /state`**: returns
  `{"boot_id": "...", "epoch": "...", "keys": {"lww:<epoch>:<id>": <maxVersion>},
  "distinct_keys": N, "total_versions": M}`. Mutex-guarded per-worker maps, merged on
  read; consistency at quiescence (writer paused) is what matters.
- **`POST /reset {"epoch": "<id>"}`**: sets the active epoch and clears the version map.
  Because the epoch changes the key namespace, resetting the counter to 1 is *safe* —
  the keys it numbers are new, so no strictly-older-vs-stored arrivals are manufactured.
- Existing `/rate`, `/metrics`, `/healthz` unchanged.

### 3.4.1 Why `stale > 0` is an unambiguous reorder proof (the precondition)

A Lua `return 0` (strictly-older: incoming `version < stored ver`) is equivalent to
"genuine same-key reordering occurred" **iff** this precondition holds for the measured
run:

> **P:** the run's keys begin with *no* stored version, and every key is numbered by a
> strictly-increasing sequence from a *single, non-restarting* writer.

Given P, a strictly-older arrival can only mean a higher version for that key was
applied first and a lower one arrived later — i.e. the sink processed same-key messages
out of emission order. There is no other source: versions are unique per key (single
writer), monotone (counter only increments), and nothing pre-seeded a high version
(fresh namespace). The design **manufactures** P and the verifier **asserts** it, rather
than assuming it:

| Way P could break (non-reorder source of strictly-older) | Guard |
|---|---|
| Region holds high versions from a prior run; writer restarts numbering at 1 | **Fresh per-run key namespace** `lww:<epoch>:<id>` (§3.3) — run keys are new, region has no version for them |
| Writer pod restarts mid-run, counter resets to 1 | **`boot_id`** captured at baseline, re-checked at quiescence; change ⇒ **inconclusive** |
| Worker count changes ⇒ key re-owned by a fresh counter | `WORKERS` is fixed for a run; `boot_id`/epoch change on any redeploy ⇒ inconclusive |
| Stale rejections from Proof A / warmup / prior run | **Windowed counter deltas** (baseline at sustain start) |
| Equal-version redelivery (at-least-once) | Counted as **`duplicate`** (`-1`), excluded from the proof |

If any guard trips (e.g. region already has a version for a run key, or `boot_id`
changed), the verdict is **`pass:false` `reason:"precondition violated"`** — never a
silent pass.

### 3.4 Collector → LWW verifier

Reuse the collector's measurement spine — the run loop (reset → warmup → sustain →
drain → quiescence), the per-second throughput sampler (`rate_achieved_avg`), the
region Redis client, and the `RESULT_JSON:` stdout contract. **Remove** the
chaos/latency/tier-matrix verdict logic. **Add** an LWW verdict:

- **Mint a fresh epoch and reset.** At run start the verifier mints a unique `epoch`
  (passed in via a flag/env — `Date.now()` is unavailable in some contexts, so it is
  supplied by the harness, e.g. the Job's creation timestamp / a random token) and
  `POST /reset {"epoch": …}`. It records the writer's `boot_id` from `/state` as
  `boot0`.
- **Assert the empty-store precondition.** The verifier confirms region has **no**
  `ver` for a sample of the epoch's keys before traffic (it must, since the namespace
  is new); a non-empty hit means a colliding/re-used epoch → abort **inconclusive**.
- **Baseline the counters at sustain start.** Before opening the full-rate window, the
  verifier scrapes connect-sink `/metrics` and records `stale0`, `duplicate0`,
  `applied0`. All proof signals are **deltas** over the measured window
  (`stale = stale_now − stale0`, etc.), never cumulative totals. This stops
  Proof A's injected rejections, warmup traffic, or a prior run from satisfying Proof B
  (the "wrong run" hole).
- **Re-check `boot_id` at quiescence.** If `/state.boot_id != boot0`, the writer
  restarted mid-run; the per-key monotonicity precondition was violated → verdict
  **inconclusive** (do not count the window's strictly-older arrivals as reordering).
- After quiescence, `GET /state` from the writer, then for **every** key
  `HGET <key> ver` on redis-region and compare to the source max. Count `mismatches`
  (must be 0) and `regressions` = keys where `region_ver > source_ver` (must be
  impossible — flagged as a hard bug).
- Re-scrape `/metrics`; compute windowed `applied`, `stale`, `duplicate` deltas.
- Report (compact JSON, one `RESULT_JSON:` line):
  ```json
  {
    "rate_target": 5000,
    "rate_achieved_avg": 4870.2,
    "lww": { "keys_checked": 1000, "mismatches": 0, "regressions": 0,
             "applied": 148213, "stale": 20119, "duplicate": 5523,
             "writes_per_key_avg": 153.7, "epoch": "1717459200-7f3a",
             "boot_ok": true, "store_empty_at_start": true },
    "verdict": { "pass": true }
  }
  ```
  `verdict.pass = precondition_ok && mismatches == 0 && regressions == 0
  && rate_achieved_avg > 0 && stale > 0`, where
  `precondition_ok = boot_ok && store_empty_at_start` (§3.4.1).
  As in the parent, a failing verdict still exits 0 (the verdict travels in JSON);
  only a genuine collector error fails the Job.
  - **The proof signal is `stale` (strictly-older), and it is unambiguous only under
    the §3.4.1 precondition.** Given P (fresh per-run namespace ⇒ empty store, single
    non-restarting monotonic writer), a strictly-older arrival can reach the sink
    *after* a higher version was stored **only** under same-key reordering — so
    `stale > 0` is direct proof that reordering was exercised and the fence rejected the
    loser. The verifier does not *assume* P; it asserts it (`store_empty_at_start`,
    `boot_ok`) and fails closed if violated. `duplicate` (equal-version redelivery) is
    **excluded**: at-least-once delivery produces duplicates even under in-order
    transport, so counting them would let the proof pass for the wrong reason.
    Duplicates are reported for observability only.
  - **Why this has teeth.** A no-op fence (blind `SET`) yields `stale == 0` always
    (it never rejects) *and*, under reordering, `mismatches > 0` (the older write
    overwrites the newer). So a broken fence fails two independent ways. A correct
    fence under genuine reordering yields `stale > 0` **and** `mismatches == 0`.
  - If `stale == 0`, the verdict is **`pass:false` with `reason:"inconclusive — no
    strictly-older arrival observed in the measured window; reorder-fencing unproven
    end-to-end"`** (fail loud, fail closed — never a silent green). The verifier
    auto-extends the sustain window once (up to a cap) before declaring inconclusive.
  - **Run tuned to guarantee reordering.** Strictly-older arrivals are overwhelmingly
    likely when many updates to the *same* key are concurrently in flight across the
    sink's parallel threads. The default run uses a small keyspace with a high
    writes-per-key ratio (`KEY_SPACE_SIZE=1000` over a run emitting ≫1000 updates, so
    each key is rewritten ~hundreds of times) against `threads:4` + `max_in_flight:64`.
    The verifier reports `writes_per_key_avg` so the reordering pressure behind a pass
    is visible.
- The Job template (`collector-job.yaml` equivalent, renamed `verifier-job.yaml`)
  drops chaos/SLO flags; keeps `--rate` (target), `--duration`, `--warmup`, `--drain`,
  writer/redis/connect endpoints.

### 3.5 Dashboard (new)

New Go service (`dashboard/`), Deployment + Service, modeled on
`redis-multiregion-via-connect/dashboard`:

- On start, `CONFIG SET notify-keyspace-events KEA` on redis-region; `PSubscribe`
  `__keyevent@0__:hset`. On each applied write, `HMGET <key> ver val` and broadcast
  `{type:"event", key, ver, value, ts_ms}` over WebSocket.
- Background poller (1 Hz): `GET writer /state` (source max ver per key) and
  connect-sink `/metrics` (`lww_apply_total{result=applied|stale|duplicate}`,
  throughput delta). Broadcast a
  `{type:"stats", applied, stale, duplicate, applied_per_s, source_keys}` frame.
- `static/index.html`: (a) live winning-writes stream (key, ver, value snippet, ts);
  (b) **convergence table** — per key: `source ver` vs `region ver`, highlighting that
  region ≤ source always and converges; (c) stats card — applied, **stale (reorder
  fenced)**, duplicate (dedup), applied/sec. Embedded via `//go:embed`.
- Env: `REGION_ADDR`, `WRITER_URL`, `CONNECT_SINK_URL`, `LISTEN_ADDR=:8080`.
- Chart: `chart/templates/dashboard.yaml` (Deployment+Service), image
  `redis-rrcs/dashboard:dev`, added to `build-images.sh`, resources block in values.
  Readiness probe `GET /healthz`.

### 3.6 Harness scripts

- **`scripts/verify-lww.sh`** (fork of `stress-run.sh`, simplified): boot chart
  (`profile=lww`) on the current context; run **Proof A** (deterministic Job, §4);
  run **Proof B** (verifier Job at a target rate, §4); print throughput + LWW verdict
  table; teardown on no-arg full run. Exit 0 iff both proofs pass.
- **`scripts/dashboard-forward.sh`**: `kubectl -n $NS port-forward --address 0.0.0.0
  svc/${PREFIX}dashboard 8080:8080`; print all LAN URLs; trap SIGINT.
- Reuse `build-images.sh` (add dashboard image + kind-load), `gen-nats-auth.sh`,
  `render.sh` (default `profile=lww`). Reuse `lib/` only for the bits still needed
  (drop tier-defs matrix; keep a minimal run-window defaults file).

## 4. Validation (the two proofs)

`validate_lab.sh` (research-lab) is docker-compose-only and **cannot** validate a K8s
lab — an accepted divergence from the skill default, documented in the README, because
the user requires production-fidelity K8s. Validation is `scripts/verify-lww.sh` on a
`kind` cluster:

- **Proof A — deterministic mechanism test.** A one-shot Job (nats-box/redis-cli or a
  tiny `redis-cli --eval`) runs `lww_set.lua` **directly against redis-region** (it
  does *not* traverse connect-sink, so it cannot perturb the `lww_apply_total` counter
  Proof B measures) for key `lwwproof:1` with versions in arrival order **3, 1, 2**,
  payloads `v3,v1,v2`. Asserts: final `HGET lwwproof:1 ver == 3`,
  `HGET lwwproof:1 val == "v3"`, the v1/v2 EVAL calls returned `0` (strictly-older),
  and a 4th call replaying version `3` returns `-1` (duplicate) — exercising all three
  return states. This is the research's exact validation test plus the dup case — the
  loud, deterministic guarantee, independent of pipeline timing. Uses a dedicated
  `lwwproof:*` key namespace the writer never touches.
- **Proof B — end-to-end + throughput.** The verifier Job drives the writer at a
  target rate through the real parallel pipeline (reordering same-key messages across
  the 4 sink threads), waits for quiescence, and asserts every key's
  `region ver == writer source max ver` (`mismatches == 0`, `regressions == 0`).
  Reports sustained **applied writes/sec** (`rate_achieved_avg`) — the single-instance
  throughput estimate. Crucially, Proof B **asserts a windowed `stale > 0` under the
  §3.4.1 precondition** — the count of strictly-older arrivals fenced *during its own
  sustain window*, after establishing a fresh per-run key namespace (empty store) and
  confirming the writer did not restart (`boot_ok`). Under that precondition a
  strictly-older arrival is possible only under same-key reordering; the window baseline
  excludes Proof A / warmup / prior-run rejections, and `duplicate`s are excluded — so
  the signal can neither pass for the wrong reason (duplicates / leftover stored
  versions / writer reset) nor for the wrong run (foreign rejections). If `stale == 0`
  or any precondition guard trips, the verdict is a loud `pass:false` "inconclusive",
  never a silent green — fail closed. The run is tuned (small keyspace, high
  writes-per-key, 4 sink threads) so strictly-older arrivals are the common case.

Exit 0 requires Proof A pass **and** Proof B `verdict.pass == true` (which now
includes a windowed `stale > 0`, i.e. genuine same-key reordering was demonstrably
exercised *and* fenced within the measured run).

## 5. Error handling & failure-loudness

- Writer: per-key version map guarded; pipeline errors charged to `errors_total`
  (inherited). `/state` returns 503 if Redis ping fails.
- connect-sink: if the Lua/EVAL config is wrong, connect fails readiness → `verify-lww.sh`
  surfaces it (Job/pods not ready) rather than silently producing no writes.
- Verifier: a genuine error (can't reach writer/redis) fails the Job (exit ≠ 0);
  a failing *verdict* (mismatch) exits 0 with `pass:false` and is printed loudly.
- Dashboard: best-effort; never blocks the pipeline; a Redis hiccup logs and retries.
- `dashboard-forward.sh` and `verify-lww.sh`: `set -euo pipefail`, trap cleanup.

## 6. File inventory

```
labs/redis-connect-lww-k8s/
├── README.md                      # what/run(kind)/expected/teardown/dashboard
├── RESEARCH.md                    # skill-format; cites last-write-wins-lab/research.md
├── chart/
│   ├── Chart.yaml  values.yaml  values-dev.yaml
│   ├── files/connect/{lww-forward,lww-reverse}.yaml  files/connect/lww_set.lua
│   ├── files/nats-auth/…          # reused fixtures
│   └── templates/{_helpers.tpl, redis-*, nats*, connect-*, connect-lua-cm,
│                  writer, dashboard, verifier-job, NOTES.txt}
├── writer/        # forked: per-key version + /state
├── verifier/      # forked from collector/: LWW verdict, no matrix
├── dashboard/     # new: keyspace→WS, convergence table, rejection counter
└── scripts/{build-images.sh, gen-nats-auth.sh, render.sh,
             verify-lww.sh, dashboard-forward.sh, lib/}
```

## 7. Open risks

1. **Redpanda Connect `redis` `eval` shape** — verified in plan task 1 (§3.1 fallback).
2. **Keyspace event type for HSET** — confirm `hset` (not `set`) fires the notification;
   the dashboard subscribes to the correct event class (plan verifies on kind).
3. **`/state` size at large keyspace** — at `KEY_SPACE_SIZE=100000` the JSON map is
   ~MBs. The default run uses `KEY_SPACE_SIZE=1000` (§3.4) — small enough that `/state`
   and the dashboard convergence table stay tiny, and small enough to force the high
   writes-per-key, same-key concurrency that makes a windowed `stale > 0` reliable. The verifier
   still compares incrementally so a larger keyspace override degrades gracefully.
```
