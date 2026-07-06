# RESEARCH: key-prefix split-topic under sink-side latency

## Topic

Key-prefix sharding of a CDC pipeline under sink-side network latency. A central-Redis →
Connect (source leg) → NATS JetStream → Connect (sink leg) → region-Redis CDC pipeline is
split by the first colon-delimited prefix of each key into N `subject × durable-consumer × sink-pod`
groups (1:1), and its aggregate apply throughput is measured while 170–200 ms of one-way
latency is injected on the sink-side Connect↔NATS path (both directions). The question: can a
horizontal prefix split recover ≥8000 msg/s of end-to-end apply throughput where a single
sink cannot?

## Property demonstrated

When the sink-side Connect↔NATS path carries 170–200 ms of latency in each direction,
splitting messages by the first colon-delimited key prefix across N subject×consumer×pod
groups (1:1) lets aggregate apply throughput reach ≥8000 msg/s, where a single
undelayed-window sink cannot.

## Essential vs accidental complexity

**Essential** (the mechanism the lab exists to expose):

- The pull-consumer **in-flight window** (`maxAckPending`) caps single-consumer throughput
  under RTT. A pull consumer can have at most `maxAckPending` messages un-acked at once;
  steady-state throughput is bounded by `maxAckPending / T_unack`, where `T_unack` is
  dominated by the round trip (down-leg delivery + apply + up-leg ack). With ~0.4 s RTT and
  `maxAckPending=1024`, a single consumer is structurally pinned well below 8000 msg/s.
- **Horizontal split multiplies the aggregate window**. Running N independent durable pull
  consumers (one per prefix, one sink pod each) makes the aggregate in-flight window
  `N × maxAckPending`, so aggregate throughput scales roughly linearly with N until some
  other resource binds. This is why splitting recovers throughput that tuning a single
  consumer's window does not necessarily reach.

**Accidental** (swappable without changing the finding):

- The specific delay tool — toxiproxy latency toxics. Any faithful bidirectional TCP delay
  (tc/netem, chaos-mesh, a delaying proxy) would demonstrate the same thing; toxiproxy is
  chosen only because it is containerised, needs no `NET_ADMIN`, has jitter and an HTTP
  on/off API, and can run a 0 ms baseline to prove the proxy itself is not the bottleneck.
- kind as the runtime. The property is about consumer windows and RTT, not about kind.
- The exact image tags (`hpdevelop/connect:4.92.0-claudefix`, `toxiproxy:2.9.0`,
  `nats-box:0.14.5`). Pinned for reproducibility, not because the finding depends on them.

## Key facts (cite the mechanism)

- **Source leg publishes `kv.cdc.<prefix>.<op>`.** The forward pipeline extracts the prefix
  (first colon-delimited segment of the key, with a rename/delete fallback to the new key,
  else `unknown`) and publishes to the per-prefix, per-op subject. The stream `KV_CDC` binds
  the wildcard `kv.cdc.>`, so new prefix subjects are captured with zero stream/permission
  changes.
- **Sink binds a per-prefix durable pull consumer `cdc_sink_<prefix>`** with
  `FilterSubject = kv.cdc.<prefix>.>`, created out-of-band (mirroring the chart's nats-init
  flags) and bound by the sink pipeline with `bind: true`. One durable, one FilterSubject,
  one sink Deployment per prefix — the 1:1 group.
- **`cdc_apply` increments only after a successful region-Redis write.** This is the honest
  "done" signal (per repo invariant INV-2): the measured oracle is the aggregate rate of
  `cdc_apply` across all sinks (differenced from cumulative counters at plot time), plus each
  consumer's `num_pending` / `num_ack_pending`. A message that never lands in region Redis
  never counts.
- **Latency is injected by toxiproxy latency toxics in both directions.** Per prefix, a
  proxy `nats-<prefix>` fronts `lab-nats:4222`; scenarios attach a `downstream` and an
  `upstream` latency toxic (`latency=185, jitter=15` by default), so both message delivery
  and ack/fetch traverse the delay. The full fetch RTT is therefore ≈2× one-way, making the
  test stricter, not looser.

## Deliberately excluded

- **Per-prefix independent streams (vs one stream, many subjects).** This lab uses a single
  `KV_CDC` stream with per-prefix subjects and durables, because that needs zero chart/stream
  changes. Stronger per-prefix isolation via separate streams is a real design axis but is
  **deferred to the D3 chart-redesign doc** (`docs/superpowers/specs/…-multi-subject-connect-groups-chart-design.md`),
  which weighs the tradeoff with this lab's measured numbers in hand.
- **HA / elector failover.** The lab sinks run without the Lease/elector sidecar. This is an
  **effectiveness experiment, not an HA experiment** — pull consumers already allow multiple
  pods to share a durable, and mixing in leader election would only confound the throughput
  measurement.
- **Automatic prefix rebalancing / hot-prefix skew.** Prefixes are assigned round-robin by
  entity id (`prefixes[id % N]`), giving an even split by construction. Skewed/hot-prefix
  distributions and dynamic rebalancing are out of scope.
- **Native chart support for multi-subject groups.** The chart is untouched here; all
  customization goes through `helm --set` and lab-owned manifests. First-class chart values
  for sink groups are the subject of the D3 design doc, not this lab.

## Design decisions (DESIGN §3 D1–D10 + §4 topology)

Summary of the fixed decisions from the design doc; full rationale and rejected alternatives
live in `docs/labs/by-key-prefix-split-topic/DESIGN.md`.

| # | Decision |
|---|---|
| D1 | Delay tool = **toxiproxy 2.9.0**, in-cluster Deployment; sink NATS URL points at it. Rejected: tc/netem sidecar (needs NET_ADMIN), chaos-mesh (too heavy), pumba (docker-level, not pod-granular), istio fault injection (HTTP-only; NATS is raw TCP). |
| D2 | Delay semantics = **185 ms latency ± 15 ms jitter each direction** (one toxic upstream + one downstream), i.e. "pull and ack both delayed 170–200 ms". Knobs `TOXIC_LAT_MS`/`TOXIC_JITTER_MS`; set 92/8 to reinterpret as "total RTT 170–200". Measured RTT goes in the report. |
| D3 | Subject scheme = **single stream `KV_CDC`, per-prefix subject `kv.cdc.<prefix>.<op>` + per-prefix durable** filtering `kv.cdc.<prefix>.>`. Rejected (deferred to D3 doc): per-prefix independent streams. |
| D4 | **Chart is not modified.** It provides infra only — redis-central/region, NATS + nats-init, latency-calculator — via `connect.source.enabled=false`, `connect.sink.enabled=false`, `writer.enabled=false`, `latencyCalculator.enabled=true`. |
| D5 | **Writer gains a `KEY_PREFIXES` env** (the one repo code change; see below). |
| D6 | Lab pipeline files = **`helm template` render + a minimal explicit diff**, not hand-copied, so they stay comparable to the production pipelines. |
| D7 | Primary oracle = **aggregate `cdc_apply` rate + per-consumer `num_pending`**; E2E latency from the latency-calculator. `cdc_apply` counts only region-Redis-committed writes. |
| D8 | Visualization = bash collector writes CSV every 5 s → containerised `python:3.12-slim` + matplotlib produces PNGs + `report.md`. CSV is the raw evidence; charts are regenerable. |
| D9 | Between scenarios: writer rate→0 → wait pending→0 → `nats stream purge KV_CDC` → next, so a limits-retention stream can't drop old messages and pollute the next measurement. |
| D10 | Default prefix set `prefix-a,prefix-b,prefix-c,prefix-d`; subject tokens restricted to `[A-Za-z0-9_-]+` (general sanitization deferred to the D3 doc). |

**Topology (DESIGN §4).** The chart owns infrastructure only (redis-central, redis-region,
NATS + nats-init, latency-calculator). The **lab owns** the workload: `lab-writer`,
`lab-source` (single source-leg Connect pod, direct to NATS), N `lab-sink-<prefix>` pods
(sink-leg Connect, NATS URL pointed at the toxiproxy listener for that prefix),
`lab-toxiproxy` (per-prefix listeners `4223+i`, admin `8474`), and `lab-toolbox`
(nats-box; all `nats`/`curl` control runs via `kubectl exec` into it). The chart-created
`cdc_sink` consumer is deleted so its empty `num_pending` does not perturb readings.

**The one repo code change** is the writer's **`KEY_PREFIXES` env**: a comma-separated list;
when non-empty, `prefixes[id % N]` is prepended (as `<prefix>:<original-key>`) to every key
an entity produces, so all of an entity's create/update/delete/rename operations land on the
same prefix (preserving per-subject ordering). When empty/unset the writer's key layout is
**unchanged, bit-for-bit** — a golden-test invariant, developed via TDD.
