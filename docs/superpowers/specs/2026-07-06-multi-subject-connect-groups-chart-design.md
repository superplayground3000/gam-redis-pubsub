# Design (D3): Native multi-subject sink groups in `chart/`

Date: 2026-07-06
Status: design spec — no code written, no cluster touched
Author role: Fable 5 (senior design; execution is a separate session)
Deliverable ID: **D3** per `docs/labs/by-key-prefix-split-topic/DESIGN.md` §10
Precedents (style/rigor): `docs/superpowers/specs/2026-07-06-robustness-test-lab-design.md`,
`docs/superpowers/specs/2026-07-06-approach-a-order-corruption-repro-lab-design.md`

This document specifies how to make the Helm chart (`chart/`) **natively** support splitting the
Redis-CDC sink leg into N groups, each `(subject × durable pull-consumer × sink Deployment)`,
keyed by a key-prefix. The lab `labs/by-key-prefix-split-topic/` already proved the mechanism
works **without** touching the chart (lab-owned manifests + a repo `KEY_PREFIXES` writer env). D3
is the productionization: fold that mechanism into the chart with backward compatibility, the
invariant obligations (INV-1/2/3), and the auth change the lab surfaced.

> Reading contract (from DESIGN §0): every fact cited below carries a `file:line`. Files move —
> re-grep the quoted key before acting if a line has shifted. Numbers labelled "measured" come
> from this session's lab run and must be reproduced, not trusted blindly.

---

## §1 Goal & backward compatibility

**Goal.** Add a `connect.sinkGroups` list to the chart. When it has **N ≥ 1** entries, the chart
renders N sink Deployments, N durable pull-consumers (one filter-subject each), N electors/Leases,
and N sets of publish-subject routing — so messages split by key-prefix apply in parallel, lifting
aggregate sink throughput past the single-consumer in-flight ceiling the lab measured.

**Backward-compatibility contract (hard requirement, DESIGN §10 bullet "向後相容").** The default
`values.yaml` MUST render **byte-for-byte identical** Kubernetes objects to today's single-sink
chart. Concretely:

| Aspect | Today | Default after D3 | Test |
|---|---|---|---|
| Publish subject | `kv.cdc.${! meta("op") }` (`_helpers.tpl:250-253`) | identical | `helm template` diff = ∅ |
| Stream subjects | `kv.cdc.>` (`_helpers.tpl:240-243`) | identical | diff = ∅ |
| Durable | one, `cdc_sink` (`values.yaml:80`) | identical | diff = ∅ |
| Sink Deployment | one, `connect-sink` (`connect-sink.yaml`) | identical | diff = ∅ |
| Subscriber grant | scoped to `cdc_sink` (`gen-nats-auth.sh:150-158`) | identical unless regenerated (§5) | grant diff = ∅ |

The mechanism to guarantee this: `connect.sinkGroups` **defaults to a single implicit group** whose
name/filter/consumer params resolve to exactly today's values, and the group→resource templating is
written so that `len(sinkGroups)==1 && group.name=="default"` reproduces the current names verbatim.
This is a `git diff`/`helm template` obligation, enumerated in §9 as the first required test. Any
byte drift on the default render is a design failure, not an acceptable cost.

Rationale for defaulting to a **list**, not a scalar `enabled` flag on a second block: a list makes
"1 group" and "N groups" the same code path (no special-case template branch that could rot), and it
makes the per-group `enabled:` toggle (INV-3, §8) a natural per-element field.

---

## §2 `values.yaml` schema draft

New block, replacing the scalar `connect.sink.*` sub-tree's role (the old keys stay as the
**defaults source** for an unspecified group, so existing overrides keep working):

```yaml
connect:
  image: hpdevelop/connect:4.92.0-claudefix
  bodyEncoding: "none"
  source:
    enabled: true
    replicas: 3
    # ... unchanged ...

  # NEW. When omitted, the chart synthesises exactly one group equal to the legacy
  # single-sink config (name "default", filterSubject "kv.cdc.>", durable "cdc_sink"),
  # so the default render is byte-for-byte identical to today (§1).
  sinkGroups:
    - name: default            # DNS-label + NATS-token safe; used in every derived name (§7)
      enabled: true            # INV-3: per-group toggle. false => none of THIS group's objects render
      # Routing — exactly ONE of `prefixes` or `filterSubject` per group:
      #   prefixes: writer-side key-prefix tokens this group owns. The chart derives
      #             filterSubject = "kv.cdc.<prefix>.>" for each and the union is the
      #             consumer filter. Requires the forward leg to emit kv.cdc.<prefix>.<op> (§3).
      #   filterSubject: an explicit NATS filter subject (escape hatch for non-prefix routing).
      prefixes: []             # e.g. ["prefix-a"]; [] on the sole "default" group => whole stream
      # filterSubject: "kv.cdc.>"   # mutually exclusive with prefixes
      replicas: 3              # ha mode: 1 active + 2 standby (Lease-elected, §6).
                               # shared mode: all 3 bind the durable concurrently (§10.4)
      mode: ha                 # ha (default) = one active puller per group (INV-1 row 10 held).
                               # shared = replicas pull concurrently (adds concurrency, drops
                               # single-active). Concurrency knob under delay — see §10.4.
      streamID: reverse_leg    # streams-mode id the elector POSTs (per-group unique, §6)
      consumer:                # per-group overrides; unset keys inherit connect.sinkDefaults.consumer
        maxAckPending: 1024    # INV-1 rows 6-7 load-bearing (§8). NOT a throughput knob —
                               # a redelivery/memory bound only; the pull input keeps just 1
                               # fetch in flight regardless of this value (measured, §10)
        ackWait: "30s"         # INV-1 row 7; couples to alert window (§8)
        maxDeliver: -1         # INV-1 row 7: redeliver forever
      lease:
        duration: 6s
        renewDeadline: 4s
        retryPeriod: 1s
      resources: {}            # optional per-group override of resources.connect

  # Defaults every group inherits when it omits a key. Mirrors today's
  # nats.stream.consumer / connect.sink so single-group = current behaviour.
  sinkDefaults:
    consumer:
      maxAckPending: 1024
      ackWait: "30s"
      maxDeliver: -1
    replicas: 3
    lease:
      duration: 6s
      renewDeadline: 4s
      retryPeriod: 1s
```

Multi-group example (the lab's N=4, S4 scenario):

```yaml
connect:
  sinkGroups:
    - { name: a, prefixes: [prefix-a], replicas: 1 }
    - { name: b, prefixes: [prefix-b], replicas: 1 }
    - { name: c, prefixes: [prefix-c], replicas: 1 }
    - { name: d, prefixes: [prefix-d], replicas: 1, consumer: { maxAckPending: 8192 } }
```

Schema notes:
- `prefixes` XOR `filterSubject` — enforce with a `fail` in `_helpers.tpl` if both/neither set on a
  non-default group.
- The **stream subject binding** (`nats.stream.subjectPrefix`, `values.yaml:78`) is unchanged: the
  stream stays bound to `kv.cdc.>` (`_helpers.tpl:240-243`), which already covers every
  `kv.cdc.<prefix>.<op>` — so **no stream reconfiguration is needed** to add groups (this is fact F1
  in DESIGN §2). Groups only ever add *consumers*, never *streams* — matching lab decision D3
  (single stream `KV_CDC`, per-prefix durables).

---

## §3 Forward-pipeline templating (deriving the prefix segment)

Today the forward leg publishes to `kv.cdc.${! meta("op") }` via helper
`rrcs.nats.stream.publishSubject` (`_helpers.tpl:250-253`, applied at
`cdc-forward.yaml:109`). To route by prefix the subject must become
`kv.cdc.<prefix>.<op>`, where `<prefix>` is a Bloblang interpolation evaluated **at publish time**
(the streams REST API does not expand env vars — `cdc-forward.yaml:23-26`).

### 3.1 Source of the prefix — the `kv_prefix` meta

The forward mapping (`cdc-forward.yaml:61-81`) already stashes `op`/`event_id` into metadata. Add a
`kv_prefix` derivation there. Two viable sources; **choose 3.1a (key-derived) as the productive
default** because it needs no writer coordination and survives replays:

**3.1a Key-derived (recommended).** Extract the segment before the first `:` of `kv_key`, with the
rename fallback the lab already worked out (DESIGN §5.2 diff 1, and R8 in DESIGN §11 — rename/delete
events can carry an empty `kv_key`):

```
# in the forward mapping, after the existing `meta op = ...` line:
let raw_key   = meta("kv_key").or(meta("new_key")).or("")   # rename: kv_key empty -> new_key
let seg       = raw_key.split(":").index(0)
meta kv_prefix = if seg == null || seg == "" { "unknown" } else { seg }
```

`"unknown"` is deliberate: it publishes to `kv.cdc.unknown.<op>`, a subject **no group filters**, so
such a message parks in the stream instead of vanishing. INV-2 obligation: this needs a
metric+dashboard treatment — increment `cdc_forward_unrouted{reason=empty_prefix}` (a new counter,
per Hard-safety-rule 5) whenever the `"unknown"` branch fires, and a dashboard panel + alert on it,
so a routing miss is loud rather than a silent backlog (this is the productionized form of the lab's
"collector asserts `kv.cdc.unknown.>` count = 0", DESIGN §11 R8).

**3.1b Writer-stamped (alternative).** Have the writer stamp a `prefix` field into the XADD (the
`KEY_PREFIXES` repo env, DESIGN §5.1, already computes `prefixes[entityID % N]`), and read
`meta("prefix")` directly. Trade-off: fewer string ops in the hot path and no fallback ambiguity,
but couples the source pipeline to a writer contract and does not survive a re-key. Document both;
default to 3.1a.

### 3.2 The helper change (F2)

Replace the single helper with a parameterized one. Backward compat: when the caller passes no
prefix segment it must emit **exactly** `kv.cdc.${! meta("op") }` (byte-identical to today):

```gotemplate
{{/* rrcs.nats.stream.publishSubject — kv.cdc.<prefix>.<op> when prefix routing is
     on, else the legacy kv.cdc.<op>. `.prefixMode` is derived from whether ANY
     sinkGroup uses `prefixes` (i.e. the forward leg must emit a prefix segment). */}}
{{- define "rrcs.nats.stream.publishSubject" -}}
{{- $p := required "nats.stream.subjectPrefix is required" .Values.nats.stream.subjectPrefix -}}
{{- if (include "rrcs.connect.prefixRouting" .) | eq "true" -}}
{{- printf "%s.${! meta(\"kv_prefix\") }.${! meta(\"op\") }" $p -}}
{{- else -}}
{{- printf "%s.${! meta(\"op\") }" $p -}}
{{- end -}}
{{- end -}}
```

Where `rrcs.connect.prefixRouting` returns `"true"` iff any enabled group declares `prefixes`. This
keeps a pure single-`default`-group install on the legacy subject and grant, and only activates the
`kv_prefix` segment (and the §3.1 mapping addition, which must be similarly gated in
`cdc-forward.yaml`) when prefix routing is actually configured. Because this **edits
`cdc-forward.yaml`** (an INV-1 load-bearing file, rows 1-4/11), the change is L1+L3, and the guard
that keeps the default render identical is what protects INV-1 (§8, §9).

---

## §4 nats-init loop — one durable per group with drift-rebuild

The nats-init Job (`nats-init-job.yaml`) today creates/reconciles exactly **one** durable
(`cdc-forward` binds to it: `values.yaml:94`, filter = the stream subjects, drift-rebuild at
`nats-init-job.yaml:124-170`). D3 wraps the consumer block (`nats-init-job.yaml:88-171`) in a loop
over groups. The stream creation/reconcile block (`:52-86`) is **unchanged** — one stream, still
`kv.cdc.>`.

Templating approach: render the desired group set into the Job's shell as a here-doc/array, then loop
the existing reconcile logic per element. Each iteration keeps the exact drift-detection the current
Job has — this is a hard requirement: the per-group loop must **mirror**, not re-invent, the
PUSH→pull, filter-drift, ack_wait/max_pending/max_deliver drift checks at `:134-170`.

```sh
# rendered by Helm from .Values.connect.sinkGroups (name|filter|maxpending|ackwait|maxdeliver each):
GROUPS='cdc_sink_a|kv.cdc.prefix-a.>|1024|30s|-1
cdc_sink_b|kv.cdc.prefix-b.>|1024|30s|-1
...'
echo "$GROUPS" | while IFS='|' read -r CONSUMER DESIRED_SUBJECTS DESIRED_MAXPENDING DESIRED_ACKWAIT DESIRED_MAXDELIVER; do
  [ -z "$CONSUMER" ] && continue
  # ── verbatim the existing reconcile body from nats-init-job.yaml:120-170,
  #    with DESIRED_SUBJECTS now the per-GROUP filter instead of the stream subjects,
  #    and per-group consumer params. to_ns()/drift/recreate logic identical. ──
done
```

Key adaptations, each a design decision:
1. **Durable naming.** `cdc_sink_<group.name>` (`cdc_sink` for the sole `default` group — no suffix —
   to preserve byte-identity, §1). Reverse-leg `durable:` (`cdc-reverse.yaml:33`) is templated to the
   same per-group name.
2. **Filter subject.** `kv.cdc.<prefix>.>` (from `prefixes`) or the explicit `filterSubject`, instead
   of the stream-wide `kv.cdc.>`. Drift detection compares against this per-group filter
   (`nats-init-job.yaml:142` `CUR_FILTER != DESIRED_SUBJECTS`), so a prefix change on `helm upgrade`
   recreates the right consumer — same guard that protects the single-consumer case today.
3. **Orphan pruning (new).** Removing a group from `sinkGroups` must delete its now-unbound durable
   (an unbound pull consumer accrues `num_pending` forever — DESIGN §5.4 notes this). The Job should
   list `nats consumer ls KV_CDC`, and `consumer rm` any `cdc_sink_*` not in the desired set. This is
   the reconcile-completeness counterpart to the drift-rebuild; without it, scaling N down silently
   leaks consumers. Guard it so it never touches non-`cdc_sink_` consumers.
4. **Idempotency / re-run safety.** The Job name is hash-suffixed on stream/auth/image change
   (`nats-init-job.yaml:7`); adding a group changes the rendered `GROUPS` list, so the reconcile
   should also be keyed into that hash (extend the `sha256sum` input at `:7` to include
   `.Values.connect.sinkGroups`) so a group-set change actually re-runs the Job.

The nats-init consumer creation is explicitly on the INV-1 "L4 required if touched" list
(`05-invariants.md:54`) — so §9 mandates a per-group L4.

---

## §5 NATS auth — the subscriber grant change (first-class, measured blocker)

**Measured finding (this session).** The chart's baked subscriber creds
(`chart/files/nats-auth/subscriber.creds`, minted by `scripts/gen-nats-auth.sh:150-158`) grant
JS-API permissions scoped to the **exact** durable name `cdc_sink`:

```
$JS.API.CONSUMER.INFO.KV_CDC.cdc_sink
$JS.API.CONSUMER.MSG.NEXT.KV_CDC.cdc_sink
$JS.ACK.KV_CDC.cdc_sink.>
```

(literal `${STREAM_NAME}` / `${DURABLE_NAME}` in `gen-nats-auth.sh:150-158`, with
`DURABLE_NAME=cdc_sink` from the header defaults `gen-nats-auth.sh:6-8` resolved out of
`values.yaml:80`). When the lab created per-group durables `cdc_sink_<prefix>` and pointed a sink at
one, the pull request to `$JS.API.CONSUMER.MSG.NEXT.KV_CDC.cdc_sink_prefix-a` was **rejected with a
"permissions violation"** — the grant does not cover the new durable names. And the account signing
key is **gitignored** (`chart/files/nats-auth/` tracks only the public JWTs + creds; the `.nsc-store`
signing material is not committed — `gen-nats-auth.sh:27`), so a new session **cannot mint a fresh
user under the existing account** to work around it. The lab could only proceed because it re-ran
`gen-nats-auth.sh` to regenerate the whole auth set.

**Therefore multi-group support MUST regenerate the subscriber grant with per-group or wildcard
consumer permissions.** This is a requirement, not a footnote.

### 5.1 The grant change

In `gen-nats-auth.sh` (the `user subscriber` block, `:150-158`), replace the durable-scoped subjects
with consumer-wildcard subjects over the stream:

```sh
nsc add user --account "${ACCOUNT_NAME}" --name subscriber \
  --allow-pub '$JS.ACK.'"${STREAM_NAME}"'.>' \
  --allow-pub '$JS.API.STREAM.INFO.'"${STREAM_NAME}" \
  --allow-pub '$JS.API.CONSUMER.INFO.'"${STREAM_NAME}"'.*' \
  --allow-pub '$JS.API.CONSUMER.MSG.NEXT.'"${STREAM_NAME}"'.*' \
  --allow-sub '_INBOX.>' >/dev/null
```

- `$JS.ACK.KV_CDC.>` — ack any consumer's messages on the stream (was `.cdc_sink.>`).
- `$JS.API.CONSUMER.INFO.KV_CDC.*` and `.MSG.NEXT.KV_CDC.*` — info/pull any durable on the stream
  (`*` is one token = the durable name; sufficient because bind:true never *creates* consumers, so
  the `CONSUMER.*CREATE.*` grants — `gen-nats-auth.sh:151-154` — can stay or be dropped).

An alternative **per-group enumerated grant** (`…CONSUMER.MSG.NEXT.KV_CDC.cdc_sink_a`, `…_b`, …) is
tighter but requires re-minting whenever the group set changes and re-deriving the exact list in the
script — reject it as the default because the group set is a `values.yaml` concern the auth script
does not read. Use the single-token wildcard `*`.

### 5.2 Regeneration procedure

```
scripts/gen-nats-auth.sh --force        # re-mints operator/account/users into chart/files/nats-auth/
git add chart/files/nats-auth/           # commit the regenerated public JWTs + creds fixtures
```

Then `helm upgrade` re-renders the creds Secrets (`_helpers.tpl:263-269`) and the nats-init Job hash
changes (new `nats-server.conf`, `nats-init-job.yaml:7`), so the resolver reloads and the new grant
takes effect. Because the operator/account JWTs change, this is a **full auth rotation** — every
publisher/subscriber/admin creds file is regenerated together (they are signed by the same account),
so all three Secrets must be re-applied in one upgrade.

### 5.3 Security trade-off (must be documented in the values comment)

The wildcard grant is **strictly broader**: the subscriber can now `INFO`/`MSG.NEXT`/`ACK` **any**
consumer on `KV_CDC`, not just `cdc_sink`. In this single-tenant lab stream that is acceptable (all
consumers belong to the same CDC sink role). In a shared/multi-tenant stream it would let one sink
group pull another's consumer — there, prefer the enumerated per-group grant (5.1 alternative) or a
per-group *user* (one creds file per group, each scoped to its own durable). State this trade-off in
the `nats.auth` values comment and in the D3 acceptance notes; do not silently ship the broad grant
without recording why it is safe **here**.

---

## §6 Per-group Lease / elector

Today one elector sidecar per leg keys off three env vars — `LEASE_NAME`, `STREAM_ID`,
`PIPELINE_PATH` (`connect-sink.yaml:100-108`) — and the elector code reads `LEASE_NAME`/`STREAM_ID`
from env (`internal/elector/main.go:47,49`), POSTing the pipeline to `localhost:4195` only while it
holds the Lease. The elector is **group-agnostic already**: it just needs a distinct Lease + stream
id + pipeline per group. So per-group HA is a **templating** change, no elector code change.

Per group `g`, the sink Deployment template renders:

| Env / object | Value | Source |
|---|---|---|
| `LEASE_NAME` | `rrcs.name … "connect-sink-<g.name>-elector"` | was `connect-sink.yaml:100` (single `connect.sink.lease.name`) |
| `STREAM_ID` | `<g.streamID>` (unique per group, e.g. `reverse_leg_<g.name>`) | was `connect-sink.yaml:104` |
| `PIPELINE_PATH` | `/etc/elector/pipeline.yaml` (per-group ConfigMap mount) | `connect-sink.yaml:106` |
| Lease object | one `Lease` + `Role`/`RoleBinding`/`ServiceAccount` per group | RBAC template loop |
| Deployment name | `connect-sink-<g.name>` (`connect-sink` for `default`) | §1 byte-identity |

So each group is an independent active/standby set: `replicas` pods, one Lease holder binds that
group's durable `cdc_sink_<g.name>` and POSTs that group's reverse pipeline (which carries the
group's `durable:` — §4 item 1). This preserves INV-1 row 10 (exactly one active leg per group) and
row 2's stable-consumer-id guarantee **per group** — each group's durable is stable and role-scoped,
never pod-scoped, so a SIGKILL failover within a group replays that durable's PEL exactly as the
single-sink case does today. **Because lease settings + elector wiring change, this is L4 per group**
(`05-invariants.md:53-54`).

RBAC note: `rbac.enabled` (`values.yaml:212`) today gates the two per-leg ServiceAccounts. The
per-group loop must generate one SA/Role/RoleBinding **per enabled group**, all still gated by
`rbac.enabled`, and each Role scoped to `get/update` on its own Lease name only (least privilege —
don't grant a group's elector access to another group's Lease).

The above describes `mode: ha` (§2, §10.4). A group set to `mode: shared` skips the elector/Lease
entirely — its `replicas` pods each bind the group's pull durable directly and consume concurrently
(JetStream load-balances pending messages across pullers), trading the single-active guarantee for
`replicas`-way concurrency (the throughput lever under delay, §10.4). `shared` is the concurrency
escape hatch; `ha` is the default. Both keep at-least-once (idempotent apply absorbs the redelivery a
pull rebalance can cause).

---

## §7 Prefix sanitization (DESIGN D10)

A group's `prefixes` tokens become NATS subject tokens (`kv.cdc.<prefix>.>`) **and** Kubernetes
resource-name segments (`connect-sink-<name>`, `cdc_sink_<name>`). NATS subject tokens cannot contain
`.`, whitespace, or the wildcards `*`/`>`; K8s DNS-1123 labels are lowercase alphanumeric + `-`. The
safe intersection is the lab's rule (DESIGN D10):

**Allowed token: `^[a-z0-9]([a-z0-9-]*[a-z0-9])?$`** (a stricter subset of the lab's
`[A-Za-z0-9_-]+` — drop `_` and uppercase because they are illegal in DNS-1123 label names, which the
derived Deployment/Service/Lease names must satisfy; `-` allowed but not leading/trailing).

Enforcement — **fail loud at render time**, never sanitize-and-continue (a silently rewritten prefix
would route to a subject no consumer filters):

```gotemplate
{{- range .Values.connect.sinkGroups -}}
{{- range .prefixes -}}
{{- if not (regexMatch "^[a-z0-9]([a-z0-9-]*[a-z0-9])?$" .) -}}
{{- fail (printf "connect.sinkGroups prefix %q is not a valid NATS+DNS token ([a-z0-9-], no leading/trailing dash)" .) -}}
{{- end -}}
{{- end -}}
{{- end -}}
```

Also validate `name` the same way, and enforce a **length budget** (Deployment name =
`resourcePrefix` + `connect-sink-` + name must fit the 57-char name budget the chart already enforces
elsewhere — `values.yaml:12-16`). This mirrors the writer-side fatal-on-invalid-prefix the lab put in
Go (DESIGN §5.1: "非法 prefix fatal, fail-loud").

---

## §8 INV-1 / INV-2 / INV-3 clause-by-clause impact

Every group multiplies the single-sink guarantees. Enumerated so nothing is missed.

### INV-1 (at-least-once) — `05-invariants.md:27-42`

| Row | Today (single) | Per-group obligation |
|---|---|---|
| 6 — bind to pre-created durable, `bind:true` | one `cdc_sink` | **each** group binds its own pre-created `cdc_sink_<name>`, `bind:true` kept (`cdc-reverse.yaml:33,40`). Load-bearing per group. |
| 7 — `maxDeliver:-1`, `ackWait` finite | one consumer's params | **each** group's `consumer.{maxDeliver,ackWait,maxAckPending}` are load-bearing. `maxDeliver:-1` and finite `ackWait` MUST hold for every group; a group that overrides them to lose redelivery breaks INV-1 for its key-space. |
| 8 — apply-before-ack (`reject_errored`+`drop`) | reverse pipeline | unchanged pipeline body reused per group; the only per-group diff is `durable:` and (if used) filter — the load-bearing output stanza (`cdc-reverse.yaml:220-222`) stays. |
| 10 — exactly one active leg | one Lease | **one Lease per group** (§6); exactly one active pod per group. |
| 2 — stable, role-scoped consumer id | `cdc_propagator_active` (forward) | forward leg unchanged; each sink durable name `cdc_sink_<name>` is stable/role-scoped, never pod-scoped. |
| 1,3,4,5,11 (forward leg) | one publish path | forward leg edited only for the `kv_prefix` subject segment (§3), gated so default render is identical; write-then-ack, `auto_replay_nacks`, `Nats-Msg-Id`, `dupeWindow`, and the `reject` fallback child are **untouched**. |

**Consequence:** changing `cdc-forward.yaml` (§3) and the nats-init consumer creation (§4) both land
on the INV-1 table → **L1+L3, and L4 where the table says** (rows 2/6/7/10 + nats-init consumer are
all L4 triggers, `05-invariants.md:53-54`). See §9.

### INV-2 (problem-message metrics + dashboard) — `05-invariants.md:62-83`

Per-group multiplies the observability surface. Obligations, each in the **same change** (Hard rule 5,
`CLAUDE.md`):

- **Per-group metric labels.** `cdc_apply{op,type}` and `cdc_unprocessable{reason}` (`cdc-reverse.yaml:180,124-128,212-218`)
  must gain a **`group`** label (or the per-pod Deployment identity must be a label on the
  ServiceMonitor scrape) so a stuck group is attributable. Adding the label is a pipeline edit → INV-2
  grep + dashboard update required.
- **New forward counter.** `cdc_forward_unrouted{reason=empty_prefix}` for the `"unknown"` branch
  (§3.1) — new failure path ⇒ new `reason`/counter ⇒ dashboard panel + the `CDCUnprocessableMessages`-
  style alert on it (Hard rule 5; `05-invariants.md:74`).
- **Dashboard panels per group.** The shipped dashboard (`chart/files/grafana/cdc-dashboard.json`,
  `05-invariants.md:80`) must show apply-throughput and unprocessable **broken out by `group`** (a
  templated Grafana variable `$group` repeating the existing panels is the low-maintenance form) plus
  a per-group `num_pending` / `num_ack_pending` panel — `num_ack_pending` is the direct evidence of
  the measured 1-fetch-in-flight behavior (§10.1: it pins at ~1, never approaching `maxAckPending`). The
  ServiceMonitor (`servicemonitor.yaml`, `05-invariants.md:79`) must select all N sink Deployments'
  Services.
- **Alert window coupling.** The `CDCUnprocessableMessages` `increase[...]` window must stay ≥ 2×
  `ackWait` **for the largest per-group `ackWait`** (`05-invariants.md:81`, `values.yaml:86-88`).

### INV-3 (per-component enable/disable) — `05-invariants.md:100-133`

- **Per-group `enabled:` toggle (mandatory).** `sinkGroups[i].enabled=false` MUST emit **none** of
  that group's objects (Deployment, Service, pipeline ConfigMap, Lease, SA/Role/RoleBinding) and MUST
  NOT create its durable in nats-init — while leaving the other groups intact. This is INV-3 binding
  rule 1 ("any NEW component ships with an `enabled:` toggle in the same change", `05-invariants.md:118`).
- **The L1 toggle loop** (`scripts/run-all-tests.sh`, `05-invariants.md:105`) must be extended to
  cover per-group toggling (§9).
- The nats-init Job stays coupled to `nats.external.enabled` (the deliberate INV-3 exception,
  `05-invariants.md:112-115`) — it still always renders in bundled mode because it provisions the
  durables INV-1 rows 6-7 depend on.

---

## §9 Required tests

Mapped to the invariant ladder (`05-invariants.md:147-169`). Because the change touches
`cdc-forward.yaml` (INV-1), `cdc-reverse.yaml` (INV-1), nats-init consumer creation (INV-1 L4), lease
settings (INV-1 L4), metrics/dashboard (INV-2), and adds a component (INV-3), the **strictest**
matching rows apply: **L1 + L3 + L4 + INV-2 grep + INV-3 toggle loop.**

| # | Test | Proves | Level |
|---|---|---|---|
| T1 | **Byte-identity render.** `helm template chart/` on default values, diff vs pre-change render = ∅; `git status chart/files/nats-auth` clean unless grant intentionally regenerated | §1 backward compat | L1 |
| T2 | **Per-group toggle loop.** For each of ≥2 configured groups: `helm template --set connect.sinkGroups[i].enabled=false \| grep connect-sink-<name>` → no hits; enabled → hits; other groups unaffected. Fold into `run-all-tests.sh` L1 loop | INV-3 | L1 |
| T3 | **Sanitization fail-loud.** `helm template` with an illegal prefix (`Prefix.A`, `a_b`, leading `-`) exits non-zero with the §7 message | §7 | L1 |
| T4 | **Dual-group L3.** Install with N=2 groups (distinct prefixes), run a prefix-aware variant of `verify-cdc.sh`: both durables bind, each group applies only its prefix's keys, `cdc_apply{group=...}` moves for both, dedup/replay/rename-parity/hash-ops still pass, `cdc_forward_unrouted`=0 | INV-1 end-to-end, routing correctness | L3 |
| T5 | **Per-group L4 failover.** `verify-failover.sh` variant: SIGKILL the active pod of **one** group; that group's durable replays its PEL with zero loss; **other groups unaffected** (isolation is the new property). Required because durable creation + lease + consumer-id changed (`05-invariants.md:53-54`) | INV-1 crash-safety per group | L4 |
| T6 | **Auth grant.** After regenerating creds (§5.2), a sink bound to `cdc_sink_<name>` pulls successfully (no "permissions violation"); a single-`default`-group install still works on the (now broader, or unchanged if not regenerated) grant | §5 | folded into T4/T5 |
| T7 | **INV-2 grep + dashboard.** `grep` every touched metric name in `cdc-dashboard.json` + `cdc-alerts.yaml`; render with `observability.enabled=true` shows N sink Services selected; `$group` panels present | INV-2 | L1 + grep |

Reporting rule (`05-invariants.md:171-177`): paste command + exit status + the `verdict.pass=true` /
`[verify-cdc] PASS` line for T4/T5. Never claim pass without running in-session (`CLAUDE.md` Hard rule
3).

---

## §10 Capacity-planning guidance (from the measured lab numbers)

All figures below are **measured this session** on the single-node kind stack (present as measured,
reproduce before trusting — DESIGN §0-3/§0-5). **The lab refuted the ack-window model this section
originally carried; the corrected concurrency model is below.**

### 10.1 Measured mechanism: 1 fetch in flight per pod, NOT an ack window

The pre-registered hypothesis (H1, DESIGN §6) modeled a pull consumer's steady-state throughput as
`maxAckPending / T_unack` — the in-flight window ÷ round-trip. **The lab measurement REFUTED this.**
Redpanda Connect's `nats_jetstream` pull input in bind mode keeps only **one fetch outstanding per
consumer pod**, regardless of `maxAckPending` — it does not pipeline fetches to fill the window:

- **Verified**: under ~370 ms fetch RTT the consumer reported `Outstanding Acks: 1 out of maximum
  1024`. The 1024-message window sat 99.9% empty.
- **Measured**: S1 (`maxAckPending=1024`) and S2 (`maxAckPending=8192`) produced the **same**
  per-consumer rate. The window size is not the throughput lever under delay.

So `maxAckPending` bounds redelivery burst and server memory (an INV-1 concern, §8) but does **not**
set throughput. **The `N ≳ R·(2d+t_proc)/W` window formula from the earlier draft is withdrawn** — it
assumed a pipelining behavior this input does not exhibit.

### 10.2 The real model: throughput = concurrency ÷ round-trip

Because each pod serializes one message per ack cycle, per-pod throughput is set by the round-trip,
not the window:

```
  per_pod_rate ≈ 1 / (2d + t_proc)              (d = one-way delay; t_proc = per-msg apply time)
  aggregate    ≈ concurrent_pods / (2d + t_proc)
```

Throughput scales **linearly with the number of concurrent consumer pods** and **not at all** with
`maxAckPending`. Measured anchors:

| Condition | one-way d | 2d + t_proc | per-pod rate | note |
|---|---|---|---|---|
| near-zero added delay | ~0 | ~0.16 ms (t_proc dominates) | **~6.4k msg/s** | t_proc, not any window, is the floor here |
| injected 185±15 ms bidirectional | 185 ms | ~0.37 s | **~1/0.37 ≈ a few msg/s per pod** | RTT dominates; `maxAckPending` irrelevant (S1≡S2) |

At near-zero delay a single pod reaches ~6.4k msg/s because `t_proc` (~0.16 ms) is the only cost. Add
185 ms each way and the *same* pod collapses to ~1/(2d) msg/s: with exactly one message in flight it
spends the entire cycle waiting on the network. The `num_ack_pending` panel (§8) makes this visible —
it pins at ~1.

### 10.3 Concurrency-sizing (replaces the window formula)

To sustain aggregate rate **R** under one-way delay **d**, size the number of **concurrent consumer
pods**, not the window:

```
  concurrent_pods  ≳  R · (2d + t_proc)
```

Worked example — the lab target R=8000 at d=185 ms:
`concurrent_pods ≳ 8000 × 0.37 ≈ 2960 → ~3000 pods`.

**Feasibility limit (state this plainly to anyone planning a delayed sink):** 8000 msg/s under
185 ms bidirectional delay is **infeasible with this pull architecture** — it would require ~3000
concurrent consumer pods. Beyond a few hundred milliseconds of RTT the one-fetch-in-flight input
cannot be scaled to thousands of msg/s by any realistic pod count. The remedy is architectural (a
push consumer, or a batching/pipelined pull that keeps many fetches in flight), **not** a values
tweak and **not** a bigger `maxAckPending`.

### 10.4 What prefix-splitting buys, and how to size `sinkGroups`

Splitting by prefix **still helps** — it multiplies concurrency by the number of groups: N groups =
N independent durables, each with its own active puller, so `concurrent_pods ≥ N`. But it multiplies
a *small* per-pod rate, so under heavy delay it mitigates the ceiling rather than removing it.

**Crucial chart caveat (ties to §6 / INV-1 row 10).** With the default **Lease-per-group HA** model
(§6) only the **leader** pod of each group binds the durable, so `replicas` are **standbys, not
concurrency** — the concurrency knob in the default chart is **N groups**, one active puller each. To
make `replicas` contribute concurrency, a group's pods must run as **concurrent shared pullers on one
durable** (no Lease single-active), which relaxes the exactly-one-active property. That is acceptable
for at-least-once idempotent apply (JetStream delivers each pending message to exactly one puller),
but it is a per-group design choice, so D3 should let a group pick its concurrency mode:

| `mode` | Binding | Concurrency contributed | Trades |
|---|---|---|---|
| `ha` (default) | Lease-elected, one active puller | **1** per group | HA standbys; INV-1 row 10 held per group |
| `shared` | all `replicas` bind the same pull durable | **`replicas`** per group | no single-active guarantee (still at-least-once) |

So `concurrent_pods = Σ_groups (1 if mode=ha else replicas)`.

Sizing procedure for `sinkGroups`:
1. Measure the deployment's real RTT (DESIGN §7 P1 records proxy / `nats rtt`); compute
   `concurrent_pods ≳ R · (2d + t_proc)`.
2. Realize that concurrency as `Σ_groups (1 if ha else replicas)`. Under non-trivial delay this
   forces either many groups or `shared` groups with high `replicas`. If the required count is
   implausible (the 8000-at-185 ms case → ~3000), the target is **infeasible on this input** —
   escalate the architecture; do not inflate `maxAckPending`.
3. `maxAckPending` default stays **1024** (`values.yaml:90`) purely as the INV-1-audited redelivery
   bound; it is **not** a throughput setting and raising it does nothing for rate (S1≡S2). Prefer
   adding groups (isolation + concurrency) over touching it.
4. Default **N = 1** (the `default` group) — byte-identical to today (§1).

### 10.5 Single-node infra ceiling (a separate limit)

Independently of the above, the single-node kind bench is aggregate-capped at **~6.5k msg/s** apply
(one NATS + toxiproxy + shared pull path; node CPU, redis at 0.18 core, and NATS storage type each
ruled out individually). This ceiling only bites near **zero** delay, where a few concurrent pods
already saturate it; under injected delay the concurrency limit (10.3) bounds throughput far below
6.5k, so the two ceilings never apply simultaneously. Re-measure the aggregate ceiling per cluster —
do not reuse the single-node 6.5k figure for a multi-node deployment.

---

## §11 Out of scope / follow-ups

- **Per-group independent streams** (vs the single-stream-per-prefix-durable of D3): stronger
  isolation and per-key-space retention, but requires per-stream nats-init + per-stream publisher
  grants and a subject-prefix-per-group scheme. Rejected as the default (DESIGN D3) — record as a
  future option if a group needs its own retention/quota.
- **Per-group creds users** (vs the wildcard grant, §5.3): the multi-tenant-safe form; add if the
  stream is ever shared across roles.
- **Dynamic group set without Job re-run:** D3 reconciles groups via the hash-suffixed nats-init Job
  on `helm upgrade` (§4 item 4). A controller that watches `sinkGroups` for zero-downtime add/remove
  is a larger follow-up, not needed for the lab's throughput goal.
