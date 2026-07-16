# E2E Matrix Design — Adversarial Critique (2026-07-15)

**Reviewer:** critic (fresh context). **Target:** `docs/superpowers/plans/2026-07-15-e2e-matrix-design.md`.
**Verdict: REQUEST-CHANGES.** The blocking render check (Q1) passes — no redesign needed — but two
MAJOR issues must be fixed before implementation: an unsound F-2 loss oracle (region emptyDir wipe) and
unaddressed single-node resource pressure. All findings below carry design-doc line + repo evidence.

---

## Q1 — BLOCKING: does the chart render sharded family + 2-seg prefix group + catchAll in ONE install?

**ANSWER: YES, renders clean.** `helm template chart/ -f critic-q1-values.yaml` → exit 0, 3085 lines,
no stderr. Overlay written to `scratchpad/critic-q1-values.yaml` (families `lb:company` shards=4;
groups shard-a `[0,1]`, shard-b `[2,3,"x"]`, caveat `prefixes:[tg:caveat]`, others `catchAll`).

Render contains exactly the expected objects:
- Durables: `cdc_sink_lb_company_s0..s3`, `cdc_sink_lb_company_sx`, `cdc_sink_caveat`, `cdc_sink_others`
  (nats-init `SINK_GROUPS`, each shard durable `max_ack_pending=1`, prefix/catchAll `=1024`).
- Filter subjects: `kv.cdc.lb.company.s{0..3,x}.>`, `kv.cdc.tg.caveat.>`, `kv.cdc.others.>`.
- Deployments: `connect-sink-shard-a/-shard-b/-caveat/-others` (+ electors/pipelines) + one `connect-source`.
- No stray default whole-stream `connect-sink`/`cdc_sink`/`kv.cdc.>` consumer leaks in.

Both fail-louds that design **P1 `failloud_conflicts`** relies on actually fire (grounds P1):
- whole-stream group alongside a prefixes group → `Error: ... filter the WHOLE stream ... consumed TWICE`
- family listed as both `sharding.families` and a `prefixes` entry → `Error: ... already owned by ...`

**No change required to the P2 coexist phase.** Shape (H) is genuinely supported.

## Q2 — Connect SIGTERM / GET /streams observability

`grep -rniE 'shutdown_timeout|terminationGracePeriod|preStop|lifecycle' chart/` → **none**.
Statically knowable: no grace override (k8s default 30s), no preStop, no Connect `shutdown_timeout`
(built-in default applies). Connect is container PID 1 (image entrypoint + `streams` args) so it owns
SIGTERM. Elector sidecar gets the SAME SIGTERM, has no `signal.Notify` (design §6a confirmed), dies on
Go default disposition → lease released only by 6s expiry. So `handoff_mechanism="lease_expiry"` in §6a
is **correct**. The `GET /streams` double-active window is runtime-only; the design's open-Q2 fallback
(survivor lease-transition timestamps) is adequate. The "drains within 30s" claim is an *assumption* the
`loss==0` gate validates — acceptable but should be labeled as such (MINOR-3).

## Q3 — region redis PVC / scale-to-0

`chart/templates/redis-region.yaml` → `rrcs.redis.bundled ... side=region`; `_redis.tpl:132` → `emptyDir: {}`,
**no PVC**. Scale-to-0 (or pod replacement) **WIPES ALL region data.** This makes the F-2 oracle unsound as
written — see MAJOR-1. The architect's open-Q3 reasoning ("confirm no PVC so no prior state to lose") is
**backwards**: no-PVC is exactly what destroys pre-outage applied state.

## Q4 — P2 budget / traffic volume realism

**15 min is ample (generous).** Enabling sharding forces the forward output to global
`max_in_flight:1 threads:1` (INV-1 rows 11/13) — ALL lanes serialize through one blocking publisher.
Total P2 volume ≈ M-A 40 + M-E 400 + caveat/others ~80 + sx 3 + dedup ~40 ≈ **~560 serialized publishes**,
propagating in seconds, not minutes. `NSEQ=200` (verify-sharding default) is fine; no need to lower.
Only caveat: worst-case sum of four `SETTLE_TIMEOUT_S=180` settle waits + P3 + P4 holds is not summed
against the 60-min ceiling (MINOR-6).

---

## Findings

### MAJOR-1 — F-2 loss oracle is unsound: region emptyDir wipe destroys F-1's applied keys
**Design §5 lines 168-171 + open-Q3 lines 267-269. Evidence: `chart/templates/_redis.tpl:132` (`emptyDir`).**
P4 runs F-1 (NATS partition) **then** F-2 (region scale-to-0) on the **same Install-B**. F-1 applies its
burst to region *before* F-2. Because region is emptyDir, `scale --replicas=0` in F-2 **wipes every key
already in region**, including F-1's applied burst and any P4 warm-up. The §0 zero-loss oracle "replays the
emitted op log ... dumps region (SCAN+MGET) and diffs" — if that terminal reconciliation is run globally
across P4, F-1's wiped keys are reported as **missing → false FAIL** (or, if only F-2 keys are checked, the
design never says so). The architect's justification ("the burst is created during the outage so there is
no prior region state to lose") is true only for F-2's own burst and silently ignores all prior state.
**Fix:** F-2 MUST (a) emit into a **disjoint fresh key range** unused by F-1/warm-up, (b) reconcile
**only that range** after recovery, (c) the design must explicitly forbid any whole-region terminal
reconciliation after F-2 and state that F-1's keys are expected-wiped. Encode this in the results schema
(`p4.sink_leg` reconciles a scoped keyspace).

### MAJOR-2 — single-node resource pressure / co-tenancy unaddressed
**Design §7 (no replicas set → inherits default 3); §2 P2. Evidence: 1× kind node, 32 CPU allocatable;
live cdc-k8s+cdc-mg+cdc-shard already request 19.1/32 CPU (60%), 12.9 CPU headroom.**
Install-A at default `replicas:3` across 4 sink groups + source = **15 connect pods ≈ 9.4 CPU requests** —
it *schedules* (leaves ~3.5 CPU) but connect limits are 2 CPU each → up to 30 CPU burst. If RUN_E2E_MATRIX
runs in the same `run-all-tests.sh` invocation as RUN_PREFIX+RUN_SHARDING, total ≈ 27.5 CPU requests and
massive CPU-limit oversubscription under P2's simultaneous load → quiescence-poll timeouts, flakiness,
blown 15-min budget. The design's "own namespace so it never collides" answers the wrong risk (name
collision, not CPU). **Fix:** overlay sets explicit replicas — `source=2` and `shard-a=2` (keep the
standby G-1/G-2 need), `shard-b/caveat/others=1` (≈7 connect pods, ≈4.3 CPU); AND the run-all-tests header
must document that RUN_E2E_MATRIX runs standalone (not with RUN_PREFIX/RUN_SHARDING) or after scaling those
releases to 0.

### MINOR-3 — "Connect drains in-flight within the 30s grace" stated as fact, is an assumption
**Design §6a lines 189-190.** No preStop/grace/shutdown_timeout exist (Q2). Drain success is runtime-only;
statically you can confirm only that no override shortens/lengthens it. It IS self-checked by the `loss==0`
gate. Reword §6a to present it as an assumption the gate validates, not an established property.

### MINOR-4 — sx-lane counter asserted absolute, should be a delta
**Design M-G line 55.** `cdc_forward_unrouted{reason="unparseable_shard"}` is a cumulative source-leg
counter. M-A/M-E emit matching-plural `lb:company` keys (contribute 0), but asserting `==3` absolute is
fragile. Assert the **delta** (post-M-G minus a pre-M-G baseline).

### MINOR-5 — "simultaneous multi-lane traffic" overstates real parallelism
**Design M-D line 52; §2 P2.** With sharding enabled the forward output is globally `max_in_flight:1
threads:1` (INV-1 rows 11/13) — every lane serializes through one publisher. Concurrency is only in XADD
emission. Doesn't break the isolation oracle (it's subject-routing based), but the wording implies parallel
propagation that does not exist. Clarify.

### MINOR-6 — 60-min ceiling not summed against worst-case settle timeouts
**Design §2.** Four terminal-reconciliation settle waits at `SETTLE_TIMEOUT_S=180` (worst case) + P3 +
P4 fault holds could exceed 60 min on a contended cluster. Expected path is seconds/settle. Add a global
run deadline or a lower per-settle timeout for the matrix.

---

## INV / feasibility confirmations (no issue)
- INV-1 load-bearing lines: untouched (design adds a script + values overlay only). Correct.
- INV-2/INV-3: no new chart component, no new pipeline failure branch; `chart/ci/*-values.yaml` is a pure
  overlay of existing `sinkGroups`/`sharding` — no toggle owed. Correct.
- All scraped metrics exist: `cdc_apply{shard}`, `cdc_forward_unrouted`, `cdc_forward_cross_shard_rename`,
  `cdc_unprocessable`, `output_error` (cdc-forward/-reverse-sharded), `elector_delete_total` (elector).
- Reused helpers exist in verify-sharding.sh: `metric_sum`(59), `consumer_json`(78), `natsq`(77), `cnt`(48),
  `wait_count`(49), T-4 monotone oracle (147-189, NSEQ default 200). iptables inject reused from
  verify-sharding-partition.sh (~103, cited 99-124 — close). Wiring point real (run-all-tests.sh L3, after
  RUN_SHARDING branch at 257-259). Namespaces cdc-e2e/cdce2e don't collide with cdc-k8s/cdc-mg/cdc-shard.
- nats-init creates all shard + prefix + catchAll durables implied by the overlay (verified in render).
- `reports/` is gitignored (`.gitignore:6`). `chart/ci/` does not exist yet — design creates it; harmless
  (helm lint/template does not auto-consume it in this repo's flow).
