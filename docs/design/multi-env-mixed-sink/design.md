# Multi-Env Mixed-Sink on One Shared PROD Stream — design

One shared external-NATS JetStream stream (binding FIXED `kv.cdc.>`, max-age 72h) and one
central forward leg, serving MULTIPLE downstream sink environments at once — some all-in-one
(AIO), some subject-sharding v2 — each its own helm release with its own region Redis. Includes
DLQ support for the sharded sink, removing today's DLQ↔sharding mutual exclusion.

Every factual claim about current behavior carries a `file:line`. Owner rulings (R1–R4) and
editor rulings (E1–E10) of 2026-07-21 are binding and embedded in §2. Where the source drafts
conflicted, the editor ruling wins and the losing option is recorded in §13.

Status: DESIGN. This document is a plan; the invariant amendments in §11 are drafts to apply at
implementation time, NOT edits to `rules/` made now.

---

## 0. One-page summary

JetStream fans one published copy of every event out to N independent **durables** on the one
stream, each with its own ack floor — so "N envs each getting a full copy" is native multi-consumer
fan-out, not N publishes. An **env is a set of durables + its own region Redis**, distinguished by
DURABLE NAME, never by subject (`draft-ops §0`). The forward publishes exactly one subject per
event via `rrcs.nats.stream.publishSubject` (`_helpers.tpl:362`).

Three release shapes share the stream (§3): exactly **one publisher release** (forward leg only),
one **AIO sink release** per AIO env, one **sharded sink release** per sharded env. They render
independently, so no render-time guard can see across releases — cross-release drift is closed by a
publisher-owned topology manifest (§7) and by making one immutable `connect.envId` (§4) the sole
identity feeding durable names, DLQ lanes, and metric labels.

Four things must change in the chart before this works, all render-proven in the drafts:

1. **Publisher-taxonomy decoupling (§3, E5)** — today the forward only emits shard/prefix tokens
   when THIS release owns an enabled sharded/prefixed sinkGroup (`prefixRouting`,
   `_helpers.tpl:776-781`), and a sink-less publisher declaring families fails INV-S4
   (`_helpers.tpl:759-766`, render EXIT 1). Publish taxonomy must become a publisher-side
   declaration. This is the prerequisite that gates everything sharded-multi-env.
2. **`connect.envId` env-scoping (§4, E1)** — two releases on default durable names collide on one
   ack floor (split delivery, not a full copy). One top-level immutable knob feeds all derived names.
3. **Sharded DLQ (§5, E2–E4)** — remove the exclusion (`_helpers.tpl:323-325`), port the
   park-then-ack switch output into the sharded pipeline, env-scope subject AND msg-id, close the
   pre-existing INV-2 hash hole.
4. **Topology manifest (§7, E6)** — a NATS KV bucket the publisher writes and each sink init reads,
   fail-closed on mismatch.

The unavoidable cost (R1): declaring ANY sharding family forces the serialized forward
(`threads:1` + `max_in_flight:1`, INV-1 row 13) whose ~1/RTT (~1000 msg/s same-zone) ceiling then
applies to EVERY env including AIO. Accepted; N is over-provisioned once (32) and never reshaped.

---

## 1. Verified facts (render-proven / file-cited)

| # | Fact | Citation |
|---|---|---|
| VF-1 | Forward publish subject computed once from `connect.sharding.families` + routeMap; one copy per event, `Nats-Msg-Id: event_id`; JetStream fans out server-side | `_helpers.tpl:362`; `cdc-forward.yaml:132-191` |
| VF-2 | A durable IS the per-consumer ack floor; two envs sharing a durable base share ONE floor → split delivery, not a copy. Bundled prune deletes sibling durables matching `${BASE_DURABLE}_*` | `draft-topology §2.1`; `nats-init-job.yaml:256-268` |
| VF-3 | Forward emits the shard/prefix token in the subject ONLY when `prefixRouting=="true"`, which is true iff some ENABLED sinkGroup in THIS release is prefixed/sharded | `_helpers.tpl:366,776-781` |
| VF-4 | `shardingEnabled` = families non-empty; gates the shard mapping + serialized output (`threads:1`, `max_in_flight:1`, no fallback) and is independent of sink groups | `_helpers.tpl:791-794`; `cdc-forward.yaml:68-75,265-298` |
| VF-5 | **Split-brain today:** shard token is COMPUTED under `shardingEnabled` but only INCLUDED in the subject under `prefixRouting` — a sink-less publisher with families set is serialized yet publishes bare `kv.cdc.aio.<op>`, matching no shard filter AND no catch-all → total black-hole for family traffic | `draft-semantics CC2`; `cdc-forward.yaml:132-189` vs `_helpers.tpl:366` |
| VF-6 | Sink-less publisher declaring a family fails render: `shard 0 is not claimed by any ENABLED sinkGroup (INV-S4)`, EXIT 1 | `draft-topology §7 Probe 1`; `_helpers.tpl:759-766` |
| VF-7 | AIO filter `kv.cdc.aio.>` is a superset of sharded subjects (`kv.cdc.aio.lp.m2g.s5.create`); pipeline reads op/kv_key from payload, indifferent to subject depth → AIO gets a full copy incl. sharded families | `draft-topology §4.2`; `cdc-reverse.yaml:66-71` |
| VF-8 | Sharded pipeline **lacks the hash guard** — a non-object hash body throws UN-COUNTED inside the HSET `args_mapping` (INV-2 hole: every unprocessable message must hit a metric) | `cdc-reverse-sharded.yaml:173-179`; `05-invariants.md:69,82` |
| VF-9 | Non-sharded DLQ parks via `reject_errored`→`switch{case dlq=="yes"→nats_jetstream(label:dlq_out), drop}`; input acked only on the DLQ PubAck (write-then-ack). Sharded output is bare `reject_errored:{drop:{}}` today | `cdc-reverse.yaml:420-447`; `cdc-reverse-sharded.yaml:273-274` |
| VF-10 | Sharded broker ack routes back along the transaction to the ORIGINATING child (F3), so one stuck shard never blocks another; park occupies the origin shard's `max_ack_pending:1` slot | `cdc-reverse-sharded.yaml:271-274`; `design.md:28` |
| VF-11 | JetStream `Nats-Msg-Id` dedup is STREAM-WIDE and subject-INDEPENDENT; the `dlq.` prefix keeps a redelivered poison deduping against its own earlier DLQ publish, not the original | `docs/dlq.md:68`; `cdc-reverse.yaml:433-441` |
| VF-12 | `rrcs.nats.dlqRoot` = `<subjectPrefix>.<segment>` in segment mode, else `<deadLetter.subject>`; single source for the DLQ subject | `_helpers.tpl:248-257` |
| VF-13 | Guard N1 fails render when `deadLetter.segment == normalSegment`; the segment tokens use grammar `^[A-Za-z0-9_-]+$` (N3) | `_helpers.tpl:283-289` |
| VF-14 | Shard durables hard-code `max_ack_pending:1` in the helper (never the values inheritance chain); a shard group setting `consumer.maxAckPending` fails render (O-6, D-8) | `_helpers.tpl:696-704` |
| VF-15 | K8s resource name budget 57 chars enforced on `resourcePrefix + connect-sink-<group>`; no durable-name length guard exists today | `_helpers.tpl:691-693` |
| VF-16 | External init job creates-if-absent / validate-only (never mutates user-owned consumers), but the create path hard-codes `--deliver all` and validates only filter/ack_policy/max_deliver/max_ack_pending — NOT `deliver_policy` or `start_sequence` | `nats-init-external-job.yaml:123-181`, `:171` |
| VF-17 | Forward identity is GLOBAL: `cdc_propagator_active` / group `cdc_propagator`; two publishers would collide on the Redis consumer group and split the `app.events` read | `values.yaml:333`; `05-invariants.md:35` (INV-1 rows 2-3) |
| VF-18 | AIO gives NO per-key order (`threads:4`, `maxAckPending:1024`, `maxDeliver:-1`); redelivery can overtake — accepted no-LWW cross-key reordering | `cdc-reverse.yaml:21-24,48`; `values.yaml:115-116`; `05-invariants.md:61-63` |
| VF-19 | `CDCDeadLetterPublishFailing` fires on `output_error{label="dlq_out"}`, `sum by (namespace,job)`, selector `job=~".*connect-sink.*"`; A1/A6 read `jetstream_consumer_*{durable=~"cdc_sink_.+_s..."}` with only a `durable` label (no namespace) | `cdc-alerts.yaml:69-73,136-141,233-235` |

---

## 2. Decision record

Status legend: ✅ binding · ⛔ rejected alternative (see §13) · ⚠ accepted risk (see §13).

| ID | Decision | Rationale | Status |
|---|---|---|---|
| **R1** | Forward serialization ceiling (~1/RTT, ALL envs incl. AIO) ACCEPTED; N sized once (over-provision e.g. 32), never reshaped; NO subject generation-versioning escape hatch | Reshard-N on a shared forward is a global downtime event; over-provision is the owner-blessed stance (`design.md` D-10). First sharded env onboarding is a global capacity event → re-baseline with `scripts/measure-shard-throughput.sh` | ✅ / ⛔ gen-versioning |
| **R2** | Per-env AIO→sharded migration is GO-FORWARD-ONLY (post-handoff events strictly ordered, no loss; keys whose last event predates the handoff keep their possibly-misordered AIO-era value). No snapshot-seed required; runbook states the limitation prominently | AIO applied ≤F0 with no per-key order (VF-18); shard durables starting at F0+1 never re-apply frozen keys. Snapshot-seed is an optional strict path (cross-ref bootstrap runbook §8.4) | ✅ |
| **R3** | New-env bootstrap: durable default deliver policy `new`; values switch (`new`\|`all`\|`by-time`); snapshot-seed + `by_start_time` runbook IN scope. **The bootstrap phase MUST extend the external init to validate the existing consumer's START SEMANTICS** (`deliver_policy`/`start_sequence`/`start_time`) against the requested mode: mismatch → fail-closed (delete/recreate, or an explicit override), never silently accept | `--deliver all` (VF-16) is a 72h partial replay of CHANGES, not a snapshot → inconsistent region; `new` is the safe go-forward default. BUT the init validates only PUSH/filter/ack_policy/max_deliver/max_ack_pending (`nats-init-external-job.yaml:123-164`), NOT start semantics — so a `new` default is unsound today: a stale `--deliver all` durable is accepted as "usable" (`:170`) and replays 72h. The validation extension is what makes the default actually safe | ✅ |
| **R4** | DLQ drain: per-env MANUAL runbook only (cadence ≤24h; poison expires with the 72h stream). NO oldest-parked-age exporter/alert in this scope | Poison is the owner-approved malformed carve-out (`05-invariants.md:25-28`); a per-subject max-age is not expressible on one stream | ✅ / ⚠ stuck-drain silent expiry |
| **E1** | ONE top-level `connect.envId` knob (NOT under `deadLetter`) | A DLQ-off sharded env still needs env-scoped durables (VF-2); a `deadLetter.envId` is undefined when DLQ is off. See §4 | ✅ |
| **E2** | DLQ env-scoping applies to BOTH subject (`kv.cdc.<dlqSeg>.<envId>.<reason>`) AND msg-id (`dlq.<envId>.<event_id>`), in BOTH pipeline variants; add `dlq_env` + `dlq_shard` headers | Msg-id dedup is stream-wide and subject-independent (VF-11); subject-only scoping leaves the cross-env dedup collapse in place | ✅ / ⛔ subject-only |
| **E3** | Sharded hash guard counter+throw (`cdc_unprocessable{reason=hash_decode_error}`) renders UNCONDITIONALLY; only the PARK action gates on `deadLetter.enabled` | Closes the pre-existing INV-2 hole (VF-8) in both renders; INV-2 is binding so it wins over "byte-identical to today's buggy render". INV-S1 (sharding-off == base) still holds | ✅ / ⛔ "DLQ-off sharded == today" |
| **E4** | Sharded DLQ park-then-ack uses ONE GLOBAL switch output over the broker fan-in (mirror `cdc-reverse.yaml:420-447`), never per-child. Park classes: `decode_error`, `hash_decode_error`, `unknown_op`. Transient region-Redis errors throw→nack. sx: no special case | Broker routes the ack back to the originating child (VF-10) so a park occupies the origin shard's MAP=1 slot → O-6 preserved. sx CROSSSLOT rename keeps nack-looping as the intended loud INV-S7 fail-stop | ✅ |
| **E5** | Publish taxonomy (families, prefixes, catch-all token emission) becomes a publisher-side declaration decoupled from locally-enabled sink groups; INV-S4 shard-coverage scoped to sink-carrying releases; NEW render assertion `shardingEnabled ⇒ (publish subject contains kv_prefix ∧ forward threads==1 ∧ MIF==1)` | Closes VF-5 split-brain permanently by binding the two predicates (VF-3 vs VF-4) so they cannot re-drift. Enabling the first family flips `prefixRouting` GLOBALLY (every non-family subject shifts) → a catch-all must be sequenced FIRST | ✅ |
| **E6** | Topology drift manifest = NATS KV bucket (NOT a retained sentinel — 72h max-age expires it), publisher-owned, `enabled:` toggle. Sink init compares `{normalSegment, families+N, prefixes}`: MISMATCH → fail-closed always; UNREADABLE → fail-closed on FIRST install of a new env, fail-open + `CDCTopologyManifestUnverified` on redeploy of an already-verified env | A drift detector must never block an emergency rollback; but a genuine mismatch (publisher N=32 / env N=16) is silent 72h loss (VF-16) and must block. KV bucket needs a user-provisioned `$KV` grant | ✅ / ⛔ retained sentinel |
| **E7** | AIO→sharded handoff: safety = `ack_floor` F0 is the contiguous-APPLIED prefix; everything >F0 redelivers (incl. timed-out unapplied in-flight) — NEVER anchor at `max_delivered_seq`. Assert filter-coverage (union of new filters ⊇ old AIO traffic incl. shard subjects, EVERY configured prefixed route, and catch-all — §3.3 / §8.3) before deleting the old durable. Operator precreates shard durables `--deliver by_start_sequence F0+1`; the external init runs a NEW **assert-only mode** for named durables (fail if the target consumer is missing or is not `by_start_sequence(F0+1)`; NEVER fall back to create `--deliver all`) | `--deliver all` create-if-absent (VF-16, `nats-init-external-job.yaml:166-180`) would silently default → 72h replay burst; the init cannot validate `start_sequence` today. Anchoring at delivered-head loses timed-out in-flight → INV-1 breach. Assert-only mode is a required new capability that no baseline phase provides — it gets its own phase (implementation-plan P-handoff) | ✅ |
| **E8** | One shared `normalSegment` across ALL envs (stated assumption) | Distinct per-env segments multiply the forward's per-event publish cost — out of scope | ✅ |
| **E9** | NEW operational invariant: exactly ONE publisher release per stream | Two collide on Redis consumer group `cdc_propagator` and split the `app.events` read (VF-17) | ✅ |
| **E10** | ONE shared ops-owned NATS exporter (`enabled:` toggle, publisher release owns it); per-env alert scoping via namespace/job for pipeline metrics, via envId-in-durable `label_replace` for A1/A6; `CDCDeadLetterPublishFailing` selector widened to sharded sink jobs PRESERVING per-namespace scoping; A1's poison-loop signal goes silent under parking (DLQ publish-failure + confirmed-parked replace it) | A1/A6 series carry only `durable` (VF-19) → env must be extractable from the durable name (couples to E1's dash-only grammar). Parking advances the floor so A1 stops firing on poison | ✅ |
| D-fwd | Publisher release carries `deadLetter.enabled:false` and parks nothing | DLQ park machinery lives in the sink pipeline templates, gated by sink-group enablement (`connect-sink.yaml:7-8`); a source-only release renders no sink pipeline (`draft-topology CC6`) | ✅ |
| D-region | Each downstream env owns a DISTINCT region Redis | AIO's unordered applies (VF-18) would race a sharded env's ordered applies if they shared one region Redis (`draft-semantics CC3`) | ✅ |

---

## 3. Topology & release shapes

**Blast-radius model** (`draft-ops §0`). Every operation is either **sink-side** (change a durable
set / region Redis — that env only) or **forward-side** (change the published subject grammar —
GLOBAL, every env sees it). The design keeps as many operations sink-side as possible.

### 3.1 The three release shapes

- **Publisher release (exactly one, E9).** `connect.source.enabled=true`,
  `connect.sink.enabled=false`, no sinkGroups, `deadLetter.enabled=false`. Owns the forward leg,
  the publish taxonomy (§3.2, E5), the topology manifest (§7), and the shared NATS exporter (E10).
  Keeps `consumerClientId: cdc_propagator_active` unchanged (VF-17, INV-1 row 2). On external PROD
  NATS its init job only validates the stream exists (`nats-init-external-job.yaml:94-98`); it
  creates no consumers (empty SINK_GROUPS loop).
- **AIO sink release (one per AIO env).** `source.enabled=false`, `sinkAllInOne.enabled=true`,
  `deadLetter.enabled=true` (mandatory under AIO), `connect.envId=<env>`. One whole-segment durable
  `cdc_sink_<envId>`, filter `kv.cdc.aio.>` (VF-7). Receives sharded traffic too, harmlessly (VF-7).
- **Sharded sink release (one per sharded env).** `source.enabled=false`, `sharding.families`
  matching the publisher's N, sharded `sinkGroups` covering `{0..N-1,x}` + a catch-all group,
  `connect.envId=<env>`. Per-shard broker durables `cdc_sink_<envId>_<fam>_s<K>`, each MAP=1
  (VF-14). `connect.source.enabled:false` is the single gate stopping any forward machinery from
  rendering here (`connect-source.yaml:1`).

### 3.2 Publish-taxonomy decoupling (E5, the primary blocker)

Today the publish subject depends on THIS release's own enabled sinkGroups (VF-3), and a sink-less
publisher declaring families fails (VF-6) — worse, if it did render it would black-hole family
traffic (VF-5). The fix makes the publish taxonomy a publisher-side declaration:

- `prefixRouting` returns true when `shardingEnabled` is true; a publisher taxonomy source (families
  + a prefixes list) feeds the routeMap independently of local sinks.
- INV-S4 shard-coverage (`_helpers.tpl:759-766`) is scoped to **sink-carrying** releases — it must
  not fire on a publisher declaring families for publishing.
- **New render assertion (binds the predicates so they cannot re-drift):**
  `shardingEnabled=="true"` ⇒ publishSubject contains `kv_prefix` ∧ forward `threads==1` ∧
  `max_in_flight==1`.

Empty taxonomy + no families ⇒ byte-identical legacy render. **Sequencing (E5):** enabling the
first family flips `prefixRouting` GLOBALLY — every non-family subject shifts
`kv.cdc.<seg>.<op>` → `kv.cdc.<seg>.<prefix|others>.<op>`; a sharded env with no enabled catch-all
group then misses all non-family traffic (`CDCForwardUnrouted`, `_helpers.tpl:887-893`). The
catch-all must be sequenced FIRST.

### 3.3 Subject layout

`normalSegment=aio`, family `lp:m2g` (N shards), optional prefixes:

| Row | Key class / role | Subject |
|---|---|---|
| Publisher publishes | Non-family, no prefix | `kv.cdc.aio.<op>` |
| | Non-family, prefix `tg:caveat` | `kv.cdc.aio.tg.caveat.<op>` |
| | Non-family, catch-all path | `kv.cdc.aio.others.<op>` |
| | Family key, shard K | `kv.cdc.aio.lp.m2g.s<K>.<op>` |
| | Family key, unparseable / cross-shard rename | `kv.cdc.aio.lp.m2g.sx.<op>` |
| AIO env filters | durable `cdc_sink_<envId>` | `kv.cdc.aio.>` (everything, full copy) |
| Sharded env filters | durables `cdc_sink_<envId>_lp_m2g_s<K>` + per-prefix + catch-all | `kv.cdc.aio.lp.m2g.s<K>.>` per shard + `kv.cdc.aio.<prefix>.>` per configured prefix + `kv.cdc.aio.others.>` |
| DLQ lanes (per env) | parked by whichever sink fails | `kv.cdc.dlq.<envId>.<reason>` |

Two envs of the same type = two durables, same filter, two independent full copies (VF-2). DLQ lanes
are disjoint from normal traffic by guard N1 (`dlqSeg != normalSegment`, VF-13) and stay under the
fixed `kv.cdc.>` binding.

**Prefixed routes are disjoint filters, NOT covered by the catch-all (load-bearing for the §8.3
handoff coverage check).** A prefixed sinkGroup renders its own filter `<prefix>.<p>.>`
(e.g. `kv.cdc.aio.tg.caveat.>`) as a distinct durable, generated separately from the catch-all
`<prefix>.others.>` (`_helpers.tpl:640-665`). So `kv.cdc.aio.others.>` does NOT absorb prefixed
traffic — a sharded env's filter set covers the old AIO segment ONLY if it carries a matching
prefixed group for every configured prefix (or a superset wildcard migration filter). This is why
the §8.3 coverage precondition must enumerate prefixed routes explicitly, not just shards + catch-all.

---

## 4. envId scheme (E1)

ONE top-level `connect.envId` is the sole per-release identity. `deadLetter` READS it; it does not
own it (E1). Empty ⇒ byte-identical legacy render in every dimension at once.

| Aspect | Rule |
|---|---|
| Key | `connect.envId` (top-level under `connect`), default `""` |
| Grammar | DNS-1123 label `^[a-z0-9]([a-z0-9-]*[a-z0-9])?$` — dashes, no underscores, no dots. Render-time guard, fail-loud |
| Length | ≤16 chars. Keeps durable `cdc_sink_<envId>_<fam>_s<K>` (= 14 + E + F chars) ≤64 and K8s name within the 57-char budget (VF-15) |
| Feeds | (a) durable base `cdc_sink_<envId>` + shard `cdc_sink_<envId>_<fam>_s<K>`; (b) DLQ subject `kv.cdc.<dlqSeg>.<envId>.<reason>` + msg-id `dlq.<envId>.<event_id>` via `rrcs.nats.dlqRoot` (VF-12) + a NEW `rrcs.nats.dlqMsgIdPrefix`; (c) `resourcePrefix` default `<envId>-` (operator-overridable); (d) Prometheus `env` label + A1/A6 `label_replace` env-extraction |
| Immutability | IMMUTABLE across redeploys. Renaming = new durable (`--deliver all` replay burst, VF-16), old durable orphaned accruing `num_pending`, AND the DLQ lane moves stranding parked poison — same hazard class as INV-1 row 2 |
| Empty | legacy: durable base `cdc_sink`, DLQ `dlq.<event_id>`, no resource-name change, no env label |

**Why grammar matters (E1/E10):** it feeds K8s names via `resourcePrefix` → `rrcs.name`
(`_helpers.tpl:927-931`), which only concatenates — an underscore/uppercase passes render and fails
`kubectl apply`. It also feeds the A1/A6 `label_replace` env-extraction from `cdc_sink_<envId>_..._s<K>`
(VF-19); an underscore or `_s<digits>` in envId would make that regex ambiguous. Dash-only, no dots,
lowercase is the intersection of the K8s-name, NATS-token, and durable-segment rules.

Two render guards, two caps (they differ on purpose — durables are NOT bound by the 57-char K8s
limit): keep the existing 57-char resource-name guard; ADD a durable-length guard (cap 64).

---

## 5. Sharded DLQ design

Removes the exclusion `_helpers.tpl:323-325` (fires today when `deadLetter.enabled` AND
`sharding.families`, `docs/dlq.md:144-159`). Ports the proven park-then-ack mechanism (VF-9) into the
sharded pipeline. Only a **sharded SINK release** may enable both (source off, families set, sharded
groups covering all shards, `draft-topology CC6`).

### 5.1 Failure-class routing (sharded)

| Class | Today | New (`deadLetter.enabled`) |
|---|---|---|
| `decode_error` | throw→nack→loop | PARK (`meta dlq=yes`, reason=decode_error) |
| `hash_decode_error` | **NO GUARD** — throws un-counted in HSET (VF-8) | counter+throw render UNCONDITIONALLY (E3); PARK gated on DLQ |
| `unknown_op` | throw→nack→loop | PARK (reason=unknown_op) |
| region-Redis transient | throw→nack→redeliver (safe under MAP=1) | UNCHANGED — still nacks (errors, never sets `dlq=yes`, hits `reject_errored`) |
| sx CROSSSLOT rename | nack-loops | UNCHANGED — intended loud INV-S7 fail-stop; NEVER parked (parking would ack-advance and hide the breach) |

`event_id` must be stashed on the sharded stash mapping (with the content-hash fallback, mirror
`cdc-reverse.yaml:130-137`); the reverse leg never needed it before but the DLQ msg-id does.

### 5.2 Output sketch (ONE global switch, E4)

```yaml
# cdc-reverse-sharded.yaml — stash mapping ADDS (hash guard renders UNCONDITIONALLY, E3):
#   let hash_body_ok = ...              # mirror cdc-reverse.yaml:117-129
#   meta hash_decode_failed = if $hash_body_ok { "no" } else { "yes" }
#   meta event_id = if this.event_id.or("") == "" { content().hash("sha256").encode("hex") } else { this.event_id }

# classifier — counter+throw ALWAYS; park action gated on deadLetter.enabled:
- switch:
    - check: meta("decode_failed") == "yes"
      processors:
        - metric: { type: counter, name: cdc_unprocessable, labels: { shard: '${! meta("shard") }', reason: decode_error } }
        {{- if .Values.connect.deadLetter.enabled }}
        - metric: { type: counter, name: cdc_dlq_forwarded, labels: { shard: '${! meta("shard") }', reason: decode_error } }
        - mapping: 'meta dlq = "yes"
                    meta dlq_reason = "decode_error"'
        {{- else }}
        - mapping: 'root = throw("decode_error: ...")'
        {{- end }}
    - check: meta("hash_decode_failed") == "yes"        # counter ALWAYS; throw or park by toggle
      processors:
        - metric: { type: counter, name: cdc_unprocessable, labels: { shard: '${! meta("shard") }', reason: hash_decode_error } }
        {{- if .Values.connect.deadLetter.enabled }}{{- /* + cdc_dlq_forwarded + meta dlq=yes */ }}{{- else }}{{- /* throw */ }}{{- end }}
    # create/update / delete / rename branches UNCHANGED; unknown_op parks-or-throws by toggle

# output — replace `reject_errored: { drop: {} }` (cdc-reverse-sharded.yaml:273-274):
output:
  reject_errored:                       # apply-before-ack, nack-on-error UNCHANGED (INV-1 row 8)
{{- if .Values.connect.deadLetter.enabled }}
    switch:                             # ONE global switch over the broker fan-in (E4)
      cases:
        - check: meta("dlq") == "yes"
          output:
            label: dlq_out              # output_sent/error{label=dlq_out} = park signals
            nats_jetstream:
              subject: '{{ include "rrcs.nats.dlqRoot" . }}.${! meta("dlq_reason") }'   # env-scoped (E2)
              headers:
                Nats-Msg-Id: '{{ include "rrcs.nats.dlqMsgIdPrefix" . }}${! meta("event_id") }'  # dlq.<envId>.
                dlq_reason: ${! meta("dlq_reason") }
                dlq_env:    {{ .Values.connect.envId | quote }}      # E2
                dlq_shard:  ${! meta("shard") }                       # E2
        - output: { drop: {} }
{{- else }}
    drop: {}
{{- end }}
```

`cdc_dlq_forwarded` is counted in-pipeline: a switch-output case takes no `processors` on this build
(`cdc-reverse.yaml:188-190`).

### 5.3 Ordering proof sketch (O-chain)

O-6 (`design.md:70`): per-shard durable MAP=1 + single active puller ⇒ the next shard message is not
delivered until the current one is acked. The ack for a parked message is emitted by the output
transaction, which completes only after the DLQ PubAck (VF-9) — exactly as a normal apply completes
only after the Redis write. So park-then-ack occupies the SAME single-in-flight slot, and the broker
routes that ack back to the ORIGINATING child (VF-10), so it lands on the origin shard's MAP=1 slot.
**O-6 unchanged.** O-7: parked messages are POISON (never applied), so occupying the slot cannot
reorder any valid change for any key. INV-1 row 14 write-then-ack is the very contract the switch
output implements. No escalation.

### 5.4 Cross-env msg-id collision (why E2 scopes BOTH)

Poison is a property of the MESSAGE — identical for every env. With a shared `dlq.<event_id>`, env B
parking within the 5m dupe window gets `PubAck{duplicate}` (a success → B acks, but its parked copy
is DISCARDED); >5m later it STORES → nondeterministic. Dedup is stream-wide and
subject-INDEPENDENT (VF-11), so scoping only the subject does NOT fix it. E2 scopes both subject and
msg-id: every env parks its own copy deterministically; an env's redelivered poison still dedupes
against its OWN earlier park; drains are physically isolated per lane.

### 5.5 Metrics

- ADD `cdc_dlq_forwarded{shard,reason}` (in-pipeline, three classifier branches).
- ADD `hash_decode_error` as a `cdc_unprocessable{shard,reason}` value (closes VF-8, E3).
- `output_sent{label=dlq_out}` = confirmed-parked; `output_error{label=dlq_out}` = publish-failing.
- Dashboard: extend panel 18 ("DLQ: routed vs confirmed parked", `docs/dlq.md:163-186`) to sharded
  sink jobs + a `shard` breakdown, in the same change (INV-2, `05-invariants.md:88`).

---

## 6. Ordering & delivery per env type

Assumption (D-region): each env owns a DISTINCT region Redis. AIO's unordered applies would race a
sharded env's ordered applies if they shared one (`draft-semantics CC3`).

- **Sharded env:** strict per-key order via O-1..O-7 (`design.md:59-77`). Parking poison advances
  only that shard's floor; each key maps to one shard; a parked message carries no valid change, so
  occupying the O-6 slot cannot reorder any valid change. O-chain unbroken.
- **AIO env:** NO per-key ordering guarantee — `threads:4` + `maxAckPending:1024`, redelivery can
  overtake (VF-18). This is the accepted no-LWW reordering. Parking preserves exactly what AIO
  already guarantees (at-least-once + head-of-line unblocking) — it never offered per-key order.
  Documented, not redesigned.

---

## 7. Drift detection (topology manifest, E6)

Each release renders independently, so no render-time guard sees across releases. The load-bearing
drift is: **publisher N=32, sharded env N=16** → env derives durables for s0..s15, forward publishes
s16..s31 → those events match no durable → park until maxAge → **silent INV-1 loss of VALID
messages** (VF-16). The external init cannot detect it (the stream binds the superset `kv.cdc.>`).

The publisher publishes a manifest — resolved `{normalSegment, families:{"lp:m2g":32}, prefixes:[...]}`
— to a **NATS KV bucket** `cdc_topology` (NOT a retained sentinel subject: a retained message on a
72h-max-age stream expires and every later deploy sees "no manifest", E6). It is a new component with
an `enabled:` toggle (INV-3), publisher-owned. On external NATS the KV bucket needs a user-provisioned
`$KV.cdc_topology.>` grant the publisher creds lack today.

Each sink init reads it and:

| Manifest state | Action |
|---|---|
| Present, MATCHES | proceed |
| Present, MISMATCH | **fail-closed ALWAYS** (definite drift = block the release) |
| Unreadable/absent, FIRST install of a new env | **fail-closed** (make the manifest a hard ordered dependency) |
| Unreadable/absent, redeploy of an already-verified env | **fail-open + `CDCTopologyManifestUnverified` alert** (never block an emergency rollback on the monitoring-adjacent KV bucket) |

This is DEPLOY-TIME only; runtime N changes remain governed by the pause-drain gate
(`design.md §10`).

---

## 8. Migration & runbooks

### 8.1 Release split (single combined release → publisher + N sink-only)

1. Convert the existing release into the PUBLISHER: `helm upgrade` with `connect.sink.enabled:false`,
   KEEP `consumerClientId:cdc_propagator_active` (VF-17 — a changed/pod-scoped id orphaned the PEL and
   lost 757 msgs historically). Forward keeps publishing; the stream is untouched.
2. Adopt the existing durable `cdc_sink` as env-0's sink-only release (`connect.envId=""` keeps the
   bare name) — the external job asserts it usable; ack floor preserved.
3. Add further sink envs as fresh sink-only releases with DISJOINT env-scoped durables (§4) + their
   own region Redis; start policy per §8.4.

**Rollback:** re-enable sink on the publisher release, delete the sink-only releases; `cdc_sink` was
preserved so the combined release resumes with its ack floor intact.

### 8.2 First-sharded-env onboarding (forward-side, GLOBAL capacity event, R1/E5)

Prerequisite: publisher-taxonomy decoupling (§3.2) has landed. Order strictly:

1. Sequence a **catch-all group FIRST** (E5) — enabling the first family flips `prefixRouting`
   GLOBALLY, shifting every non-family subject; without a catch-all in place, non-family traffic
   black-holes / fires `CDCForwardUnrouted`.
2. Declare the family in the publisher taxonomy. This forces the serialized forward on ALL envs
   (R1). Re-run `scripts/measure-shard-throughput.sh` and re-baseline every env's headroom — the
   trigger for the ceiling regime is "ANY sharded env exists", not "this env is sharded".
3. Deploy the sharded sink release covering `{0..N-1,x}`.

AIO / prefix envs keep absorbing the deeper subjects under their `.>` filters (subject-monotonic) —
zero pause for them.

### 8.3 AIO→sharded per-env handoff (sink-side, GO-FORWARD-ONLY, R2/E7)

Env A's old AIO durable `kv.cdc.aio.>` is a superset of the shard subjects, so old + new must not run
concurrently. The forward never pauses; other envs untouched.

1. **Quiesce env A's SINK only** (scale to 0 / `connect.sink.enabled:false`). Wait for full quiesce:
   sink down AND ackWait elapsed AND `num_ack_pending==0` stable. Record `ack_floor.stream_seq` = F0.
   **Safety = F0 is the contiguous-APPLIED prefix (E7).** Under `maxAckPending:1024`, scaling to 0
   drives `num_ack_pending→0` by ackWait TIMEOUT — the in-flight move back to `num_pending`
   UN-applied; they are NOT lost because step 2 re-delivers all of (F0,∞). NEVER anchor at
   `max_delivered_seq` — that loses the timed-out in-flight (INV-1 breach).
2. **Assert filter coverage (E7):** `union(new filters) ⊇` ALL traffic the old AIO durable `kv.cdc.aio.>`
   matched — enumerated as three disjoint classes: (a) every shard subject `kv.cdc.aio.<fam>.s<K>.>`;
   (b) **every configured prefixed route** `kv.cdc.aio.<prefix>.>` — these are DISJOINT durables
   (`_helpers.tpl:640-665`) and are NOT absorbed by the catch-all, so a shards+`others.>` check alone
   silently loses all prefixed traffic (e.g. `kv.cdc.aio.tg.caveat.<op>`) until the 72h expiry; and
   (c) the catch-all `kv.cdc.aio.others.>` for the remaining non-family, non-prefixed keys (prefixRouting
   must be ON so those publish under `.others.`). The env must therefore carry a matching prefixed
   sinkGroup for EVERY configured prefix, OR hold an explicit superset wildcard migration filter
   (`kv.cdc.aio.>`) across the cutover, BEFORE the old AIO durable may be deleted. Otherwise deleting it
   silently loses every uncovered class.
3. **Operator precreates** shard durables `--deliver by_start_sequence --start-sequence <F0+1>`
   (MAP=1). The external init runs in **assert-only mode** for this handoff — create-if-absent would
   silently default `--deliver all` (VF-16) → 72h replay burst. Delete env A's old AIO durable.
4. **Bring env A's sink up** sharded. No overlap ⇒ no cross-durable CONCURRENCY; boundary re-applies
   are idempotent.

**Limitation (R2), state prominently:** correct per-key order only for keys modified after F0; a key
whose latest event predates F0 keeps its possibly-misordered AIO-era value forever (VF-18). If the
owner needs a fully-correct region, snapshot-seed at F0 (§8.4) instead of relying on the AIO region.

**Rollback (before deleting the old AIO durable):** re-point env A to the AIO durable; idempotent
re-applies absorb.

### 8.4 New-env bootstrap (R3)

`connect.sink.bootstrap.deliver: new | all | by-time` (default `new`). `all` is a 72h partial replay
of CHANGES, not a snapshot (VF-16) → acceptable only for snapshot-seeded or change-tolerant envs.
**Strict path (`by-time`):** dump a consistent source snapshot → load env's region Redis → create the
durable `--deliver by_start_time` at the snapshot's stream position. **Rollback:** delete the env's
durables + release; its region Redis is disposable.

**Start-semantics validation is part of this phase (R3, closes the unsound-default gap).** The
external init today validates only PUSH/filter/ack_policy/max_deliver/max_ack_pending
(`nats-init-external-job.yaml:123-164`) and accepts any EXISTING consumer as "usable" (`:170`)
without inspecting its `deliver_policy`/`start_sequence`/`start_time`. So a durable left over from a
prior `--deliver all` create is silently blessed and replays 72h even when the values ask for `new`.
This phase MUST extend the init to compare the existing consumer's start semantics against the
requested `bootstrap.deliver` mode and **fail closed on mismatch** (require delete/recreate or an
explicit `bootstrap.allowStartMismatch` override), so `new` is actually the safe default it claims
to be. This same validation underpins the §8.3 assert-only handoff mode (E7).

### 8.5 DLQ drain (R4, per-env manual)

N per-env drainers, one per lane `kv.cdc.dlq.<envId>.>`; each persists poison externally + inspects.
Cadence ≤24h (margin under the 72h expiry). Each drain consumer is itself a durable on the shared
stream (adds to the §10 count). One source event may appear in several env lanes, possibly under
different reasons — the `dlq_env`/`dlq_shard`/`event_id` headers (E2) let a drain tool correlate.
**Accepted risk (R4, ⚠):** no oldest-parked-age alert in scope — a stuck env drain goes unnoticed
and its parked poison silently expires at 72h.

---

## 9. Observability & alerts (E10)

- **Connect-leg metrics:** shared Prometheus selects all releases' ServiceMonitors; per-env series
  fall out of `namespace`+`job`. Shipped alerts already `sum by (namespace,job,...)` (VF-19). Add an
  `env` external label; Grafana becomes a `$namespace`/`$env`-templated dashboard.
- **NATS-exporter metrics:** exactly ONE ops-owned `prometheus-nats-exporter` (E10, `enabled:`
  toggle, publisher release owns it — never per-env). A1/A6 carry only `durable` (VF-19), so env is
  extracted from the durable name via `label_replace` (requires E1's dash-only grammar) and
  Alertmanager routes by the extracted `env`.
- **DLQ / alert-semantics shift (E10):** with parking, poison no longer loops → `CDCShardStuck` (A1)
  goes SILENT on poison (floor advances, apply rate stays >0); it becomes a sharper signal that fires
  only when parking is BROKEN. The replacement is `CDCDeadLetterPublishFailing` on
  `output_error{label="dlq_out"}` (VF-19), natively per-env-routable by namespace. Its selector
  `job=~".*connect-sink.*"` MUST be verified against sharded per-group sink jobs (`sink_<group>`) and
  widened if needed, PRESERVING per-namespace scoping so it never pages across envs.

---

## 10. Capacity worksheet

- **Forward ceiling (R1):** serialized publish ⇒ throughput ≈ 1/RTT(central Connect ↔ NATS), ALL
  families and ALL envs combined; same-region ~1ms → ~1000 msg/s TOTAL. Fan-out to N envs does NOT
  multiply forward load (one publish, server-side fan-out). Constraint: total source XADD rate <
  1/RTT. Measure with `scripts/measure-shard-throughput.sh`.
- **Durable count:** `Σ_sharded(Σ_families shards + sx) + Σ_aio(1) + Σ_prefix(groups) + N_drain`.
  Example: 3 sharded × (32+1) + 5 AIO × 1 + 8 drainers = 112 consumers on one stream. No hard cap,
  but each costs delivery/ack bookkeeping + exporter cardinality; MAP=1 shard consumers are cheap. A
  `--deliver all` consumer scans the full 72h backlog on creation (creation burst).
- **72h storage:** `stream_bytes ≈ publish_rate × 72h × avg_size`. Consumers do NOT multiply storage
  (one fanned-out copy). **DLQ copies DO, ×N_envs (deterministic floor under E2):**
  `dlq_bytes ≈ poison_rate × 72h × avg_size × N_envs`. Poison is normally rare, but the ×N_envs
  multiplier is real — size retention headroom for it.

---

## 11. Invariant impact — DRAFT amendments (apply at implementation time, NOT now)

These are drafts for `rules/05-invariants.md`, to be applied under the required test evidence (§12)
when the code lands. They are NOT edits to `rules/` made by this document.

- **INV-1 statement carve-out extension (`05-invariants.md:25-28`):** extend the malformed-message
  exemption to state it applies identically to the sharded sink (`cdc-reverse-sharded.yaml`) when
  `connect.sharding.families` is configured — both park via `reject_errored`+switch-output(`dlq_out`);
  in a multi-env topology each env parks its own copy under `<dlqRoot>.<envId>.<reason>` with
  `Nats-Msg-Id: dlq.<envId>.<event_id>`.
- **Row 6 durable-name generalization (`:39`):** the durable base is env-parameterized
  (`cdc_sink_<envId>`, default `cdc_sink` when empty); bind semantics unchanged. Generalize the
  illustrative literal.
- **Row 8 amend (`:41`):** under `deadLetter.enabled` the sharded output becomes
  `reject_errored`+`switch{dlq_out, drop}` (not `reject_errored`+`drop`); the `reject_errored`
  wrapper is unchanged; non-DLQ render stays `reject_errored`+`drop`.
- **Row 13 note (`:45`):** no numeric change to `copies:1`/`threads:1`/`max_ack_pending:1`; add a note
  that park-then-ack occupies the O-6 slot and the DLQ switch output does not loosen O-6/O-7. Touching
  row 13 → L3 `RUN_SHARDING=1` + L4 sharding scripts.
- **NEW row 15 (mirrors row 14 for the sharded path):** `cdc-reverse-sharded.yaml` DLQ path stays
  publish-to-DLQ-then-ack; permanent poison publishes to `<dlqRoot>.<envId>.<reason>` with
  `Nats-Msg-Id: dlq.<envId>.<event_id>`, PubAck-confirmed, then acks; a send failure →
  `output_error{label=dlq_out}` → `reject_errored` nacks → redelivery on the same shard durable (safe
  under MAP=1). Also load-bearing: the sharded pipeline MUST carry the `hash_decode_failed` guard.
- **INV-2 additions (`:82`):** `cdc_dlq_forwarded{shard,reason}` in-pipeline; `hash_decode_error` as a
  `cdc_unprocessable{shard,reason}` value; panel 18 extended to sharded jobs + `shard` breakdown.
- **NEW operational invariants:** (a) exactly ONE publisher release per stream (E9); (b) `connect.envId`
  is immutable for a release's life (E1) — same hazard class as row 2.

---

## 12. Test plan (INV-4 ladder, `05-invariants.md:164-179`)

Strictest matching row wins. Every change class here touches sharding machinery and/or INV-1 rows
8/13/new-15, so most land at L3 `RUN_SHARDING=1` + L4.

| Change class | Required levels |
|---|---|
| Publisher-taxonomy decouple + INV-S4 sink-scoping + predicate assertion (§3.2) | L1 (render: legacy byte-identical; INV-S4 no longer fires on publisher; the new `shardingEnabled⇒kv_prefix∧threads==1∧MIF==1` assertion) + L3 |
| `connect.envId` + guards (§4) | L0 (token/length guards if unit-tested) + L1 (empty=byte-identical; bad grammar/length fail-loud) + L3 |
| Sharded DLQ pipeline + env-scoped subject/msg-id + hash guard (§5) | L1 (sharded+DLQ renders; non-DLQ sharded byte-identical INV-S1; env tokens present when envId set, absent when empty) + L2 (`test-shard-mapping.sh` + `verify-alert.sh` for the widened `CDCDeadLetterPublishFailing`) + L3 `RUN_SHARDING=1` + L4 (`verify-sharding-failover.sh`, `verify-sharding-replay.sh` — row 13 touched) |
| Topology manifest (§7) | L1 (`enabled:` toggle) + L3 (mismatch fail-closed; unreadable fail-mode by env-age) |
| Bootstrap start policy (§8.4) | L1 + L3 (new-env bootstrap e2e) |
| Observability (§9) | L1 + INV-2 grep + L2 + L3 |
| **NEW `scripts/verify-multi-env.sh` (L3)** | one publisher + 2 sink releases (AIO + sharded) in one kind cluster: both envs receive ALL messages (fan-out, disjoint durables, independent floors); env A poison PARKS/blocks its shard while env B is unaffected; no cross-steal; env-scoped metrics |
| **NEW sharded-DLQ e2e (L3)** | poison parks on `kv.cdc.dlq.<envId>.<reason>`, PubAck-confirmed, shard unblocked, next shard message applies; a multi-env cross-park proves TWO env-scoped copies, no dedup-swallow |
| **NEW `scripts/verify-env-reshard-handoff.sh` (L3+L4)** | §8.3 sink-pause + start-sequence handoff: no-loss + no-reorder for the migrating env while a second env keeps flowing; `num_ack_pending ≤ 1` throughout |

Reporting (`05-invariants.md:181-187`): paste command + exit status + the verdict line.

---

## 13. Accepted risks & rejected alternatives

**Accepted risks (⚠):**
- **R4 no oldest-parked-age alert** — a stuck per-env drain goes unnoticed; its parked poison
  silently expires at the stream's 72h max-age. Owner-accepted (poison is the malformed carve-out).
- **R1 forward ceiling on AIO envs** — the first sharded env imposes the ~1/RTT serialized-forward
  ceiling on every env, including AIO envs that never asked for sharding. Owner-accepted.

**Rejected alternatives (⛔):**
- **Subject generation-versioning escape hatch (R1)** — would make reshards per-env-rolling but adds a
  forward capability + transient double subject footprint. Rejected; over-provision N=32 once instead.
- **Subject-only DLQ env-scoping (E2)** — leaves the stream-wide, subject-independent msg-id dedup
  collapse in place (VF-11): env B's lane stays empty while it acks. Rejected; scope BOTH.
- **"DLQ-off sharded render byte-identical to today" (E3)** — today's render is the INV-2 bug (VF-8);
  the hash counter+throw must render unconditionally. Rejected; the surviving byte-identity invariant
  is INV-S1 (sharding-OFF == base).
- **Retained-sentinel-subject manifest (E6)** — expires with the 72h stream; every later deploy sees
  "no manifest". Rejected; use a NATS KV bucket.
- **Snapshot-required AIO→sharded migration (R2)** — not required; the go-forward-only handoff is the
  default, snapshot-seed is the optional strict path.

---

## 14. Out of scope

- LWW fence (v1) — retained as the upgrade path only if throughput must exceed the forward ceiling
  (`design.md §14`).
- Distinct per-env `normalSegment` (E8) — would multiply forward publish cost.
- `Fetch(1)` upstream patch / `Consumer.Messages()` migration.
- Automated DLQ replay tooling (drain is a manual per-env runbook, R4).
- Reshard-N as a routine non-global operation (R1 — over-provision instead).

---

## 15. Open questions

- **Real NATS durable-name length limit** — the §4 cap of 64 is a conservative assumption; confirm the
  actual server bound to finalize the durable-length guard. (Does not block implementation; 64 is safe.)

---

## 16. Cross-model review

A cross-model (Codex) review of this design and its implementation plan on 2026-07-21 returned
request-changes with four findings, all applied here: F1 — the §8.3 handoff coverage precondition
must enumerate prefixed routes (disjoint filters at `_helpers.tpl:640-665`), not just shards +
catch-all (§3.3 note, §8.3 step 2, E7); F2 — the drift-manifest gate must precede the
publisher-taxonomy phase so no rollout window can move traffic onto subjects no running sink matches
(implementation-plan reorder + a manifest-checked taxonomy rollout guard); F3 — `deliver:new` is only
safe once the external init validates existing-consumer start semantics, so that validation is folded
into the bootstrap phase (R3, §8.4); F4 — the assert-only handoff mode for named durables is a
required new capability with no baseline phase, so it gets its own phase (E7, implementation-plan
P-handoff). No transcript retained.

**Implementation status (2026-07-21): COMPLETE.** All eight phases (P0–P8) landed on branch
`feat/multi-env-mixed-sink` and the full e2e ladder is green — 10/10 suites, including the three
new multi-env proofs `verify-multi-env.sh` (fan-out, disjoint durables, cross-park no
dedup-swallow, manifest gate fail-closed), `verify-sharded-dlq-e2e.sh` (3 classes parked
env-scoped, +9 PubAck, O-6 held) and `verify-env-reshard-handoff.sh` (F0 anchor, no-loss 13/13,
6/6 by_start_sequence), plus `verify-sharding{,-failover,-replay}.sh`, `verify-cdc.sh`,
`verify-dlq-e2e.sh`, and `verify-alert.sh`. Operational procedures are in
`runbook-first-sharded-env.md` (first-sharded-env onboarding), `runbook-aio-to-sharded-handoff.md`
(§8.3) and `runbook-new-env-bootstrap.md` (§8.4). **Two deviations from this design were made and
are recorded here:** (1) the `CDCTopologyManifestUnverified` Prometheus alert (§9/E10) was
DEFERRED — a real alert needs the shared ops-owned NATS KV exporter this lab does not ship, so
rather than ship a permanently-non-firing rule the fail-open path is surfaced by an operational
`nats kv ls cdc_topology` check documented on the `connect.topologyManifest` values key and in the
first-sharded-env runbook. (2) A cross-release wiring bug found during multi-env e2e — Services and
Deployments without release-scoped selectors round-robined connections across two same-namespace
releases (applied+acked+counted, yet key absent) — was fixed by adding a `release` label to every
selector (commit `280034f`); it was invisible to every single-release install and is the reason the
multi-env e2e is load-bearing.
