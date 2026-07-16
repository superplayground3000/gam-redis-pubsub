# E2E Matrix Test — Design (2026-07-15)

**Status:** design only (no implementation). Dated session artifact; not a standing requirement until wired in.
**Author role:** architect (team: architect → critic → implementer → codex review → run → report).
**Deliverable to build:** one permanent umbrella script `scripts/verify-e2e-matrix.sh` + one values overlay
`chart/ci/e2e-coexist-values.yaml`, gated by `RUN_E2E_MATRIX=1` in `scripts/run-all-tests.sh` at the L3 tier.

This design touches **no INV-1 load-bearing line**. It only observes; it adds no chart component and no pipeline
failure branch (respects INV-2/INV-3). All faults are reversible and use mechanisms already proven in the repo.

---

## 0. Guiding decisions (read first)

- **Traffic driver = direct `redis-cli XADD` into central Redis for every lane.** The writer Deployment
  (`writer.env` in `chart/values.yaml:367-377`) emits a *randomized* op-mix (`OP_CREATE:40/UPDATE:40/DELETE:10/
  RENAME:10`, `KEY_SPACE_SIZE:1000`, `MAX_RATE:20000`) over a single opaque key space and exposes **no** per-family
  / per-lane / `KEY_PREFIXES` knob in values (`internal/writer/prefix.go`'s `KEY_PREFIXES` is unused in any e2e).
  That makes exact per-lane counts and event-id reconciliation impossible. `redis-cli XADD` gives deterministic
  `event_id`s and exact `kv_key` control per lane — the same choice `verify-sharding.sh` and `verify-cdc*`/
  `verify-failover.sh` already make. The writer stays for soak; the matrix must not use it.
- **Zero-loss oracle = terminal-state reconciliation keyed by the emitted op log, not counts.** Because the
  script generates every `XADD`, it knows the ground-truth ordered op log and can compute the expected terminal
  region keyspace by replaying ops per key in emission order (`create/update K → expected[K]=body`;
  `delete K → drop`; `rename old→new → expected[new]=expected[old]; drop old`). After quiescence it dumps region
  (`SCAN`+`MGET`/`HGETALL`) and diffs. This is the only oracle that survives deletes (key must be **absent**) and
  renames (value **moved**). Every `XADD` still carries a unique `event_id` (`${runid}-<lane>-<seq>`) so the dedup
  sub-check can re-emit ids and assert the terminal state is unchanged (server-side `Nats-Msg-Id` dedup, INV-1 #4).
- **Quiescence primitive** (settle before every reconciliation): poll until the central group PEL is empty
  (`XPENDING app.events cdc_propagator` count 0) **and** every sink durable reports `num_pending==0` and
  `num_ack_pending==0` (`nats consumer info KV_CDC <durable>`), held stable for 2 polls. This is the stream-wide
  `MaxPending` settle idea from the verifier, generalized to the multi-durable mix.
- **One kind cluster, two installs, four phases.** Install-A (coexistence: sharded + 2-seg-prefix + catchAll)
  serves P1(render, no cluster)→P2→P3. Install-B (default single-sink whole-stream) serves P4. Phases run
  sequentially; per-phase PASS/FAIL; one machine-readable results JSON for the later HTML report.
- **"Simultaneous" traffic is interleaved at the forward leg, parallel only at the sinks.** With sharding
  enabled the forward output is globally `max_in_flight:1` + `threads:1` (INV-1 rows 11/13) — every lane's
  events serialize through one blocking publisher into NATS. The concurrency the matrix exercises is (i)
  concurrent `XADD` emission from background subshells and (ii) genuinely parallel *sink-side* consumption
  (each sink group is an independent durable/consumer). The isolation oracle is subject-routing based, so
  it does not depend on forward parallelism; the design must not claim parallel forward propagation.
- **RUN_E2E_MATRIX runs STANDALONE.** It must NOT share a `run-all-tests.sh` invocation with
  `RUN_PREFIX`/`RUN_SHARDING` (their live `cdc-mg`/`cdc-shard` releases already request ~19 of 32 node CPU;
  Install-A's connect pods on top would oversubscribe CPU limits and flake P2's quiescence polls). The
  overlay pins low replica counts (§7) and the run-all-tests header documents the standalone constraint.

---

## 1. Scenario matrix

`kv_key` families used: sharded family `lb:company` with **plural** hash tag `{employees:<id>}` (matches the
writer and `verify-sharding.sh`; see the keyPattern trap in §6); 2-seg prefix family `tg:caveat`; catchAll misc
family `misc:thing`. Subjects per `chart/templates/_helpers.tpl` + the render asserts already in
`run-all-tests.sh`: sharded → `kv.cdc.lb.company.s<K>.<op>`, prefix → `kv.cdc.tg.caveat.<op>`, catchAll →
`kv.cdc.others.<op>`.

| id | shape (routing) | overlay summary | traffic (this run) | oracle (assertion + data source) | expected |
|----|-----------------|-----------------|--------------------|----------------------------------|----------|
| M-A | (G) sharded family, 2 groups | `sharding.families.lb:company.shards=4`; `shard-a=[0,1]`, `shard-b=[2,3,x]` | creates over employees 1..40 (10/shard) | per-group & per-shard `cdc_apply{shard}` == emitted per-shard counts (`metric_sum` on each sink group, `:4195/metrics`) | PASS |
| M-B | (D) 2-seg prefix group | `caveat: prefixes=[tg:caveat]` (non-sharded) | creates/updates/deletes/renames on `tg:caveat:*` | terminal-state reconciliation of region vs op log; `cdc_apply` on group `caveat` only | PASS |
| M-C | (E) catchAll `others` | `others: catchAll=true` | creates/updates/deletes on `misc:thing:*` | terminal-state reconciliation; `cdc_apply` on group `others` only | PASS |
| M-D | (H) mixed sharded + prefixed + catchAll **coexisting** | all of M-A+M-B+M-C in ONE install | **all lanes emitted concurrently** (background subshells; interleaved at the forward leg — §0) | **duplicate-tolerant isolation** (see §1.2): (a) liveness `cdc_apply delta >= expected` per group; (b) foreign-shard-label `cdc_apply == 0` on each sharded group; (c) key-scoped terminal-state reconciliation over each lane's disjoint range == 0 missing/0 corrupt, and NO key outside the union of lane ranges present. `cdc_apply == expected` equality is **report-only**, never a gate | PASS |
| M-E | (G/O-3..O-7) strict per-key order under load | same install | ONE employee (id 5 → s1 → shard-a): NSEQ interleaved active+standby updates, emitted **concurrently** with M-D lanes | region-side monotone poller (`verify-sharding.sh` T-4 oracle): both keys' observed sequences monotone non-decreasing, finals == last emitted | PASS |
| M-F | (O-6 runtime) shard durables under load | same install | (piggybacks M-A/M-E) | every shard durable `max_ack_pending==1`, `ack_policy=explicit`, pull, exact FilterSubject, `num_ack_pending<=1` sampled under load (`nats consumer info`) | PASS |
| M-G | sx isolation lane | `shard-b` owns `x` | 3 unparseable family keys (`lb:company:...:sxprobe`) | applied (not dropped) via `shard=sx`; **delta** of `cdc_forward_unrouted{unparseable_shard}` from a pre-M-G snapshot == 3 (cumulative source counter — never assert absolute); `cdc_forward_cross_shard_rename` delta == 0 (INV-S7) | PASS |
| M-H | (A) dedup / replay | same install | re-emit M-A event_ids | terminal state unchanged (server dedup, INV-1 #4/#5) | PASS |
| G-1 | graceful SIGTERM — **source** leader | Install-A | steady mixed traffic + sharded hot-key poller running | **loss:** 0 (terminal reconciliation); **same-key monotone:** true. **REPORT (non-gating):** `elector_delete_total` did not increment; handoff_mechanism; handoff_latency; double-active window | loss PASS / **DELETE-handoff gap ABSENT (reported)** |
| G-2 | graceful SIGTERM — **sink** leader (shard-a) | Install-A | steady traffic to shard-a lane | same oracles as G-1 for the sink leg (region-apply ack path) | loss PASS / **gap reported** |
| F-1 | source-leg ack-after-apply (write-then-XACK) | Install-B (default) | burst emitted **into** a NATS partition, key range `f1:*` | during fault: `XPENDING cdc_propagator` retains ~burst, region applied == 0 (vacuity). after lift: PEL drains to 0, **scoped** reconciliation of `f1:*` loss == 0. **F-1 reconciles and completes BEFORE F-2 starts** (F-2 wipes region) | PASS |
| F-2 | sink-leg ack-after-apply (apply-then-ack) | Install-B | burst emitted **into** a region-redis outage, **disjoint** key range `f2:*` | **settle barrier first** (poll global `cdc_apply` until stable ≥N s so F-1 stragglers drain). during fault GATE: region `SCAN f2:*` == 0 (key-scoped) AND `num_ack_pending` max > 0 AND redeliveries > 0; `cdc_apply` delta is **report-only** (no key label — cannot be scoped). after recover GATE: **scoped `f2:*`-only** reconciliation loss == 0. Whole-region reconciliation **forbidden** (emptyDir wipe drops F-1) | PASS |

### 1.1 P1 expected-render objects (verified by the critic — assert verbatim)

`helm template chart/ -f chart/ci/e2e-coexist-values.yaml` renders exit-0, ~3085 lines, no stderr, and MUST
contain exactly these objects (P1 greps each from a captured render var — never pipe `helm` into `grep -q`,
per `run-all-tests.sh:41-45`):

| Kind | Names | Detail to assert |
|------|-------|------------------|
| Sink durables (nats-init `SINK_GROUPS`) | `cdc_sink_lb_company_s0`, `…_s1`, `…_s2`, `…_s3`, `cdc_sink_lb_company_sx`, `cdc_sink_caveat`, `cdc_sink_others` | each shard durable `max_ack_pending=1`; `cdc_sink_caveat` / `cdc_sink_others` `=1024` |
| Filter subjects | `kv.cdc.lb.company.s0.>` … `s3.>`, `kv.cdc.lb.company.sx.>`, `kv.cdc.tg.caveat.>`, `kv.cdc.others.>` | one per durable, exact |
| Deployments | `lab-connect-sink-shard-a`, `-shard-b`, `-caveat`, `-others` (+ each `-elector`, `-pipeline`), one `lab-connect-source` | replicas per §7 overlay |
| Negative (leak guard) | NO default whole-stream `lab-connect-sink` / `cdc_sink` durable / `kv.cdc.>` consumer | absent |
| Fail-loud guards (must exit nonzero) | whole-stream group + a `prefixes` group → `… consumed TWICE`; a family in both `sharding.families` and a `prefixes` entry → `… already owned by …` | render fails |

### 1.2 Duplicate-tolerant isolation oracle (M-D) — amended after live run 1784130697

**Why the original was unsound:** the first run gated M-D isolation on `cdc_apply` delta **== expected** per group
and read `caveat=33` vs expected `31` → false `cross_lane_leak=2` FAIL. Duplicates are **legal** under at-least-once:
forward-leg server dedup (INV-1 #4) absorbs *publish* replays, but a **sink-side** redelivery after `ackWait`
(30s) re-applies idempotently and **increments `cdc_apply` again**. So any equality on an apply counter can
false-positive forever. `cdc_apply` carries only `{shard,op,type}` labels — **no key label** — so it can never be
key-scoped. The oracle must therefore never gate on apply-count equality.

**Amended oracle — three duplicate-proof checks (all GATING except where noted):**
1. **Liveness (per group):** `cdc_apply` delta **>= expected** (dupes only push it higher; `<` means real loss on
   that lane). Report-only side value: the raw delta and the dup surplus `delta - expected`.
2. **Foreign-shard zero-check (sharded groups only, exact-0, dup-proof):** `shard-a` must show
   `cdc_apply{shard=s2|s3|sx} == 0` and `shard-b` must show `cdc_apply{shard=s0|s1} == 0`
   (`metric_sum <group> cdc_apply 'shard="s2"'` etc.). A foreign shard is exactly 0 regardless of duplicate volume;
   this is the `verify-sharding.sh` `ot_apply==0` pattern generalized. (The non-sharded `caveat`/`others` groups
   render `cdc-reverse.yaml` with no `shard` label, so they have no foreign-shard axis — their isolation is carried
   entirely by check 3, which is subject-routing-structural.)
3. **Key-scoped terminal-state reconciliation (authoritative, state-based, dup-proof):** each lane uses a
   **disjoint** key range (`lb:company:*` / `tg:caveat:*` / `misc:thing:*`). Reconcile region against the emitted
   op log per range: every lane's expected terminal keys present with correct values, deletes absent, renames moved,
   **and NO region key outside the union of the three lane ranges** (an unexpected key = mis-route/leak; a missing
   key = loss). Because this compares terminal *state* keyed by the actual `kv_key`, duplicate re-applies are
   invisible to it (idempotent SET/DEL/rename converge to the same state).

`cross_lane_leak` in the results JSON is now defined as **(foreign-shard applies) + (region keys outside any lane
range)** — both exact-zero quantities — not a difference of apply counts. The old `applied == expected` equality is
kept only as a `dup_surplus` evidence field.

| Phase | What | Install | Budget |
|-------|------|---------|--------|
| **P1 — render matrix** | `helm template` asserts the M-D coexistence overlay renders (mixed sharded+prefix+catchAll), the keyPattern-trap guard, and the known fail-loud conflicts. No cluster. | none | 3 min |
| — install A | `helm upgrade --install` coexistence overlay; roll all 4 sink groups + source; let electors POST | A | 3 min |
| **P2 — coexist traffic** | M-A..M-H: simultaneous multi-lane traffic, isolation + ordering (M-E poller) + terminal-state loss + sx lane + dedup | A | 15 min |
| **P3 — graceful leader change** | G-1 (source) then G-2 (sink), reusing Install-A; steady traffic + poller; capture lease/elector/streams evidence | A | 12 min |
| — install B | `helm uninstall` A, `helm upgrade --install` default single-sink | B | 3 min |
| **P4 — ack-after-apply faults** | F-1 (NATS partition, source PEL retention) then F-2 (region outage, sink num_ack_pending) sequentially | B | 16 min |
| — report assembly | write results JSON + human summary | — | 2 min |

Time knobs (env, defaulted): `NSEQ` (M-E updates/lane, default 200), `NROUTE` (M-A creates, default 40),
`PARTITION_S` (F-1, default 45), `REGION_OUTAGE_S` (F-2, default 45), `SETTLE_TIMEOUT_S` (default **90** for the
matrix — half of `verify-sharding.sh`'s 180: the expected settle is seconds, and four full-length 180 s waits
must not be allowed to blow the ceiling).

**Worst-case ceiling check (MINOR-6):** the expected path is seconds per settle, but the *timeout* budget is
what can overrun. There are ~5 settle/quiesce gates (P2 union, P3×2, F-1 drain, F-2 recover). At the matrix
default `SETTLE_TIMEOUT_S=90` that is ≤ 5×90 s = 7.5 min of settle ceiling, plus 2×`PARTITION_S`/`REGION_OUTAGE_S`
fault holds (~1.5 min) plus 2 installs (~6 min) plus P3 handoff waits (~2×lease-expiry + drain, ~2 min) — worst
case ≈ 40 min even if every settle runs to its cap, comfortably under 60. The script also arms a **global run
deadline** (`E2E_DEADLINE_S`, default 3000 = 50 min): on expiry it writes the partial results JSON with
`overall:"FAIL"` and `reason:"deadline"` and exits, so a wedged cluster never hangs the tier. RUN_E2E_MATRIX is
**standalone** — see §0 and §7 (do not co-run with RUN_PREFIX/RUN_SHARDING).

**Phase-abort semantics (amended after live run 1784130697 silently SKIPPED P3 when P2's bash crashed).**
The umbrella script must **not** let one phase's crash abort the run. It must NOT run under a top-level `set -e`
that kills the process on the first phase failure; instead each phase runs in its own guarded unit (a subshell
whose non-zero exit / trapped `ERR` is caught) so that:
- A phase that **fails a gating assertion** records `status:"FAIL"` with the failing check.
- A phase that **crashes** (bash error, missing pod, kubectl/helm error, timeout) records `status:"ABORT"` with the
  captured error text and the phase that was running — **distinct from `SKIP`** (SKIP is reserved for phases
  deliberately not run, e.g. a disabled sub-case). ABORT and FAIL both force `overall:"FAIL"`.
- **Every later phase still runs.** A P2 crash must not prevent P3/P4 (P3 reuses Install-A, which survives a P2
  traffic-driver crash; P4 does its own install). The only legitimate skip-forward is a phase whose **prerequisite
  install itself failed**: if Install-A never came up, P2/P3 record `status:"ABORT" reason:"install-A failed"`; if
  Install-B fails, only P4 aborts. Independent phases never inherit another phase's abort.
- The final exit code is 0 iff `overall=="PASS"` (all gating phases PASS, none ABORT); the results JSON is always
  written, even on abort, so the HTML report shows exactly which phase died and why.

---

## 3. Results-JSON schema

Written to `reports/e2e-matrix/<runid>.json` (mirrors `verify-failover.sh`'s `reports/failover/` convention).
A compact `RESULT_JSON:{...}` line is also emitted per repo convention (so a later `gen-report.sh`-style tool and
the HTML report can parse it). Every phase records `status`, `duration_s`, and evidence fields.

```jsonc
{
  "run_id": "1752...", "started": 1752..., "ended": 1752...,
  "kind_cluster": "cdc", "ns_coexist": "cdc-e2e", "ns_fault": "cdc-e2e",
  "lease_duration_s": 6,
  "overall": "PASS",                              // PASS iff all gating phases PASS and none ABORT (see §2/§4)
  // every phase object below carries "status" ∈ PASS|FAIL|ABORT|SKIP; on FAIL/ABORT it also carries
  // "error":"<failing check or captured crash text>" and "aborted_in":"<phase step>". overall=FAIL if any FAIL/ABORT.
  "phases": {
    "p1_render": { "status": "PASS", "duration_s": 0,
      "checks": [ {"name":"coexist_overlay_renders","ok":true},
                  {"name":"keypattern_trap_guard","ok":true},
                  {"name":"failloud_conflicts","ok":true} ] },
    "p2_coexist": { "status": "PASS", "duration_s": 0,           // status ∈ PASS|FAIL|ABORT|SKIP (see §2)
      "lanes": { "shard-a": {"applied":20,"expected":20,"dup_surplus":0},   // applied>=expected is the gate; dup_surplus report-only
                 "shard-b": {"applied":20,"expected":20,"dup_surplus":0},
                 "caveat":  {"applied":31,"expected":31,"dup_surplus":2},   // dupes legal — NOT a leak (DEFECT-A)
                 "others":  {"applied":0,"expected":0,"dup_surplus":0} },
      "isolation": { "cross_lane_leak": 0,                        // = foreign_shard_applies + keys_outside_lane_ranges (both exact-0)
                     "foreign_shard_applies": 0, "keys_outside_lane_ranges": 0 },
      "ordering":  { "samples":0, "distinct":0, "monotone":true, "finals":"200/200" },
      "zero_loss": { "expected_keys":0, "present_keys":0, "missing":0, "corrupt":0,
                     "deletes_verified":0, "renames_verified":0 },
      "sx_lane":   { "applied":3, "unparseable":3, "cross_shard_rename":0 },
      "durables":  { "num_ack_pending_max":1, "max_ack_pending_all":1 },
      "dedup":     { "stable":true } },
    "p3_graceful": { "status": "PASS", "duration_s": 0,
      "source_leg": { "terminated_pod":"", "loss_keys":0, "ordering_monotone":true,
                      "handoff_latency_s":0, "handoff_mechanism":"lease_expiry",   // vs "explicit_delete"
                      "elector_delete_ran":false, "double_active_window_s":0,
                      "streams_on_terminating_pod_after_sigterm":[], "lease_transitions":[] },
      "sink_leg":   { "terminated_pod":"", "loss_keys":0, "handoff_latency_s":0,
                      "handoff_mechanism":"lease_expiry", "elector_delete_ran":false,
                      "double_active_window_s":0, "lease_transitions":[] },
      "known_gap":  { "graceful_delete_handoff":"ABSENT",
                      "evidence":{ "elector_logs_grep_OnStoppedLeading":"" } } },
    "p4_ack_after_apply": { "status": "PASS", "duration_s": 0,
      "source_leg": { "fault":"nats_iptables_drop", "key_range":"f1:*", "pel_retained_during_fault":0,
                      "applied_during_fault":0, "pel_drained_after":0, "loss_keys":0,
                      "reconciled_scope":"f1:* only" },
      "sink_leg":   { "fault":"region_redis_scale_0", "key_range":"f2:*", "num_ack_pending_during_fault":0,
                      "applied_during_fault":0, "redelivered":0, "applied_after":0, "loss_keys":0,
                      "reconciled_scope":"f2:* ONLY — whole-region check forbidden (emptyDir wipe drops f1:*)" } }
  },
  "deadline_s": 3000, "reason": "",                 // reason set to "deadline" only on a global-deadline abort
  "known_gap_expectations": {
    "graceful_sigterm_delete":"EXPECTED ABSENT — report-only, does not fail the run",
    "keypattern_trap":"documented; overlay sets plural keyPattern explicitly" }
}
```

---

## 4. Gating vs reporting (what makes the run FAIL)

**Gating (a false one fails the run):** every P1 render check; P2 isolation (leak==0), M-E monotone, terminal-state
loss (missing==0, corrupt==0), sx lane counters, dedup; P3 **loss==0 and same-key monotone==true**; P4 F-1
(PEL-retained + vacuity + drain + loss==0) and F-2 (`num_ack_pending>0` during fault + applied==0 during fault +
loss==0 after recover).

**Reporting only (recorded, never fails the run):** P3 `elector_delete_ran`, `handoff_mechanism`,
`handoff_latency_s`, `double_active_window_s`, `streams_on_terminating_pod_after_sigterm`, elector-log grep. These
are the graceful-shutdown gap evidence — the user chose report-only, so the script must **observe and print**
them, not assert a product fix. (If loss or same-key order breaks *because of* double-active, that is a genuine
INV-1/ordering violation and the **gating** oracle catches it — the gap stays report-only only as long as the
guarantee actually holds.)

---

## 5. Fault-injection decisions (with justification)

**F-1 — source leg (write-then-XACK, INV-1 #1/#3):** *iptables `FORWARD -d <NATS_pod_IP> -j DROP` inside the kind
node*, reusing `verify-sharding-partition.sh:99-124` verbatim (raise before emitting, hold `PARTITION_S`, lift).
Justification: the one proven, reversible, in-repo injection that induces a **live** JetStream publish failure with
`connect-source` and its elector **still running** — exactly the write-then-XACK path (a pod-kill would test a
different thing). New coverage beyond the partition script: F-1 asserts the **central group PEL retains** the burst
(`XPENDING app.events cdc_propagator` count ≈ burst, nothing XACKed) and **0 region applies** during the outage
(vacuity guard), then **PEL drains to 0** and terminal reconciliation shows **0 loss** after lift. (The partition
script asserts *ordering* on the sharded render; F-1 asserts *PEL retention* on the default render — complementary,
not duplicated.)

**F-2 — sink leg (apply-then-ack, INV-1 #8):** *scale `deploy/lab-redis-region` to 0, emit a burst on a **disjoint
fresh key range `f2:*`** into the outage, then scale back to 1.* Options evaluated and rejected: `docker pause` the
region container (it lives inside the kind node netns, not a top-level container — impractical); `NetworkPolicy`
(kind's kindnet CNI does not enforce NetworkPolicy — would not bite); `DEBUG SLEEP` (region redis blocks the whole
server including the oracle reads, and whether Connect's redis output blocks-then-succeeds vs errors-then-nacks is
client-internal — non-deterministic proof); `WRONGTYPE` induction (a poison that redelivers forever — never recovers
cleanly). **Scale-to-0 with emit-into-outage** is deterministic (no apply race — every message is guaranteed to hit
a down region and nack), fully reversible (`scale --replicas=1`), and directly observable: `num_ack_pending>0` /
`num_delivered` climbing on `cdc_sink` via `nats consumer info`, `cdc_apply` frozen. It exercises INV-1 #8's
`reject_errored`+`drop` nack path **without editing it**. After scale-back, `cdc_apply` reaches the full `f2:*`
burst and the **scoped `f2:*`-only** reconciliation shows **0 loss**.

**During-fault gate must be key-scoped, not a global `cdc_apply` read (DEFECT-B fix, live run 1784130697).**
The first run's "`cdc_apply`==0 during outage" gate falsely tripped: 34 F-1 straggler duplicate applies landed right
after F-2's baseline snapshot (post-recovery total delta 240 = 200 real + 40 dupes), because `cdc_apply` is a
single global counter with no key label. Fix, combining both remedies: **(1) settle barrier** — after F-1 fully
drains, poll the global `cdc_apply` counter until it holds steady for `SETTLE_STABLE_S` (default 10 s) before
snapshotting F-2's baseline, so late F-1 redeliveries cannot bleed into F-2's window; **(2) key-scoped
during-fault gate** — GATE on what is actually provable and scoped: `SCAN f2:* == 0` in region (nothing applied —
key-scoped, immune to F-1 contamination), `num_ack_pending` max > 0 and `num_delivered`/redelivery count climbing
on `cdc_sink` (`nats consumer info`). The **global `cdc_apply` delta during the fault is recorded as report-only
evidence, never a gate** — it can never be key-scoped. Post-recovery, the GATE is the scoped `f2:*`-only terminal
reconciliation (loss == 0) plus `cdc_apply` reaching ≥ burst (liveness, report-only ≥).

**Region is emptyDir — F-2 is destructive to prior region state, so the oracle must be scoped (MAJOR-1 fix).**
`chart/templates/_redis.tpl:132` mounts region redis on `emptyDir: {}` (no PVC), so scaling to 0 (which replaces
the pod) **wipes the entire region keyspace**, including anything F-1 or a warm-up applied earlier. The F-2 oracle
therefore MUST: (a) emit its burst on the disjoint `f2:*` prefix that no earlier phase used; (b) reconcile **only
`f2:*`** after recovery (`SCAN --pattern 'f2:*'`), never the whole region; (c) treat F-1's `f1:*` keys as
**expected-wiped** — no post-F-2 whole-region reconciliation may run, and nothing after F-2 may depend on any
pre-F-2 region state. **Phase ordering is load-bearing: F-1 must fully emit, drain, and pass its scoped `f1:*`
reconciliation BEFORE F-2 scales region to 0.** The earlier "non-destructive" justification was wrong — no-PVC is
exactly what destroys pre-outage state; the design now relies only on F-2's own freshly-created `f2:*` burst, which
IS the only region state that exists after the wipe.

Both faults are lifted in a `trap ... EXIT` (unblock iptables / scale region back) so an aborted run never leaves
the cluster wedged — same discipline as `verify-sharding-partition.sh:81-82`.

---

## 6. Known-gap expectations

**(a) Graceful-SIGTERM leadership gap — EXPECTED, report-only.**
Confirmed by reading the code: `internal/elector/main.go` has **no** `signal.Notify`/`NotifyContext` (no `os/signal`
import); `leaderelection.RunOrDie` runs on a `context.Background()` that nothing cancels on a signal
(`main.go:121-160`), and `ReleaseOnCancel:true` only fires on that ctx cancel. `chart/templates/connect-source.yaml`
and `chart/templates/connect-sink.yaml` have **no** `lifecycle.preStop` and **no** `terminationGracePeriodSeconds`
(default 30s applies). Therefore on `kubectl delete pod <leader>` (graceful SIGTERM), the elector process is
terminated by Go's default SIGTERM disposition **before** `OnStoppedLeading`'s DELETE `/streams/{id}`
(`main.go:142-153`) can run — the explicit graceful handoff never happens; leadership instead falls back to **lease
expiry** (`lease.duration`, default 6s). P3 therefore EXPECTS and records: `elector_delete_ran=false`,
`handoff_mechanism="lease_expiry"`, `handoff_latency_s ≈ lease_duration`. **Zero-loss is HYPOTHESIZED to HOLD** on
the *assumption* that Redpanda Connect drains its in-flight messages during the default 30s termination grace
(source: publishes+XACKs; sink: applies+acks) — note there is **no** preStop hook, no grace-period override, and no
Connect `shutdown_timeout` in the chart (`grep -rniE 'shutdown_timeout|terminationGracePeriod|preStop|lifecycle'
chart/` → none), so the drain window is purely the k8s 30s default and its success is a **runtime property, not a
statically-guaranteed one**. The P3 `loss==0` gate is exactly what validates that assumption on each run — if the
drain does not complete, loss>0 fails the phase and the assumption is falsified in the results. The phase gates only
on loss==0 and same-key monotone; the DELETE-handoff absence is printed as the finding. Evidence captured: lease `holderIdentity`/`renewTime` transitions over time; `elector` container logs
grepped for `OnStoppedLeading` (expected: not present on the terminating pod, or the pod dies first); the
terminating pod's Connect `GET /streams` polled through the grace window to measure the **double-active window**
(how long the old pipeline keeps running while the new leader may already be POSTed — the double-active risk the
team asked to quantify).

**(b) keyPattern singular/plural trap — DOCUMENTED, actively avoided.**
`chart/values.yaml:315` defaults `keyPattern: '\{employee:(?P<id>[0-9]+)\}'` (**singular** `employee`), while the
writer and every existing sharding test use **plural** `{employees:<id>}` keys. A default-pattern sharded install
matches no key → every key routes to the isolation shard `sx` → the numeric shards stay empty and the sx lane
carries everything. The coexistence overlay MUST set the plural pattern explicitly
(`sharding.keyPattern='\{employees:(?P<id>[0-9]+)\}'`). P1 asserts the trap two ways: (i) the overlay renders with
the plural pattern; (ii) a guard render with the *default* singular pattern + `lb:company` traffic keys would send
everything to `sx` — documented in the script comment and the results JSON `known_gap_expectations`.

---

## 7. New files + run-all-tests.sh wiring

**New files (2):**
1. `scripts/verify-e2e-matrix.sh` — umbrella, phases P1→P4, `set -euo pipefail`, `RRCS_NS`/`RRCS_RELEASE`/
   `RRCS_VALUES`/`RRCS_PREFIX`/`RRCS_SET` knobs like the sibling scripts, `metric_sum`/`consumer_json`/`natsq`/
   `cnt`/`wait_count` helpers lifted from `verify-sharding.sh`, the terminal-state reconciliation + `quiesce`
   helpers (new, §0), and `trap` cleanup for both faults + the natsq pod. Emits `RESULT_JSON:` + writes
   `reports/e2e-matrix/<runid>.json`.
2. `chart/ci/e2e-coexist-values.yaml` — the M-D overlay (plural keyPattern; `families.lb:company.shards=4`;
   sinkGroups shard-a `[0,1]`, shard-b `[2,3,x]`, caveat `prefixes=[tg:caveat]`, others `catchAll`). No new chart
   component, so **INV-3 needs no new toggle** — this only configures existing `sinkGroups`/`sharding` values.
   (`chart/ci/` is the conventional home for render/test value files.)
   **Explicit replica pins (MAJOR-2 fix — single-node CPU pressure):** the chart default is `replicas:3` per
   connect leg; 4 sink groups + source at 3 each = 15 connect pods (~9.4 CPU requested, up to 30 CPU burst at the
   2-CPU limit) on a node that already carries the live `cdc-k8s`/`cdc-mg`/`cdc-shard` releases (~19 of 32 CPU).
   The overlay therefore pins:
   ```yaml
   connect:
     source: { replicas: 2 }              # keep ONE standby for G-1 (source graceful termination)
   # per-group replicas via sinkGroups[i].replicas:
   #   shard-a: 2   # keep a standby for G-2 (sink graceful termination)
   #   shard-b: 1   # not terminated in P3 — single active is enough
   #   caveat:  1
   #   others:  1
   ```
   ≈ 7 connect pods (~4.3 CPU requested) — schedules with comfortable headroom even alongside the other releases,
   while still giving G-1/G-2 a real standby to fail over to. (`sinkDefaults.replicas` could set the floor, but
   pin per-group so shard-a=2 while the rest stay 1.)

**Wiring** — add to `scripts/run-all-tests.sh` inside the L3 block, after the `RUN_SHARDING` branch
(around line 259), in its own namespace `cdc-e2e`:

```bash
  if [ "${RUN_E2E_MATRIX:-0}" = "1" ]; then
    RRCS_NS=cdc-e2e RRCS_RELEASE=cdce2e scripts/verify-e2e-matrix.sh || fail L3
  fi
```

and document the flag in the header comment block (lines 9-18) alongside `RUN_PREFIX`/`RUN_SHARDING`, **with an
explicit STANDALONE note (MAJOR-2):** RUN_E2E_MATRIX must not be combined with RUN_PREFIX/RUN_SHARDING in the same
invocation — their `cdc-mg`/`cdc-shard` releases plus Install-A would oversubscribe node CPU limits and flake P2's
quiescence polls. Run it alone (or after scaling those releases to 0). The separate namespace prevents *name*
collision but does nothing for *CPU* co-tenancy, which is the real risk. The new script self-contains P4's second
install (default values) via `helm uninstall`+`upgrade --install` in the same namespace (pristine-install
discipline, like `verify-sharding.sh:83-94`). CI is unaffected (it runs `SKIP_L3=1`). Results JSON lands in
`reports/e2e-matrix/` (gitignored like `reports/failover/`).

---

## 8. Deliberately NOT covered (and why)

- **SIGKILL / ungraceful failover** — already covered by `verify-failover.sh`, `verify-sharding-failover.sh`,
  `verify-sharding-replay.sh`. This test is the *graceful* complement; duplicating SIGKILL wastes budget.
- **Cross-key reordering** (e.g. delete-before-rename across different keys) — INV-1's documented accepted
  non-guarantee (`rules/05-invariants.md:57-59`); it is not loss and must not be asserted as a failure. Only
  **same-key** monotonicity is gated.
- **Sharded forward blocking-in-place ordering under live publish failure** — already the exact subject of
  `verify-sharding-partition.sh`; F-1 deliberately targets the **default** render's PEL-retention instead.
- **Alert firing / dashboard panels** — covered by the L2 lab (`verify-alert.sh`) and the INV-2 grep check; this
  test scrapes metrics as evidence but does not re-prove alerting.
- **Throughput / latency SLOs** — `measure-shard-throughput.sh` territory (tc netem), manual-only by design.
- **A product FIX for the graceful gap** (preStop hook / signal handler) — explicitly out of scope; the user chose
  report-only. The test observes and reports; it does not change the elector or the chart.
- **Shard-count cutover / replay drills** — `sharding-cutover-drill.sh` / `verify-sharding-replay.sh` own those.

---

## 9. Open questions — RESOLVED by the critic review (2026-07-15)

The four open questions were all answered in `docs/superpowers/plans/2026-07-15-e2e-matrix-critique.md`; the
resolutions are folded into the sections above and summarized here for the implementer.

1. **Mixed coexistence render (M-D) — RESOLVED: renders clean.** `helm template` of the coexistence overlay exits
   0 (~3085 lines, no stderr) with exactly the objects listed in §1.1, and both fail-loud guards fire. Shape (H)
   is genuinely supported; P2 relies on it safely. No two-install fallback needed. (§1.1 encodes the render facts.)
2. **Double-active observability — RESOLVED: runtime-only, fallback adequate.** No static handle exists (no
   preStop/grace override, Q2); the `GET /streams` window is runtime-only and the survivor lease-transition
   timestamps are the accepted coarser fallback if the container exits before it can be sampled. (§4/§6a keep
   these fields report-only.)
3. **F-2 vs region persistence — RESOLVED, and the original reasoning was BACKWARDS.** Region redis is `emptyDir`
   (`_redis.tpl:132`, no PVC), so scale-to-0 **wipes** all region state — the opposite of "no prior state to
   lose." Fixed in §5/§1/§3: F-2 emits on a disjoint `f2:*` range, reconciles only that range, and F-1 completes
   first; whole-region reconciliation after F-2 is forbidden.
4. **Budget — RESOLVED: 15 min is generous.** Sharding forces the forward leg to `max_in_flight:1 threads:1`, so
   all lanes serialize (~560 publishes total, propagating in seconds). `NSEQ=200` stays; the only budget risk was
   un-summed settle timeouts, now bounded by the lowered `SETTLE_TIMEOUT_S=90` default and the global
   `E2E_DEADLINE_S` guard (§2).

**No residual open questions for the implementer.** Build strictly from §1–§8 as revised.
