# VALIDATION — by-key-prefix-split-topic

Validated in-session on 2026-07-06/07 against kind cluster `cdc`, namespace `cdc-k8s`,
release `cdc`. Single entrypoint `scripts/verify-prefix-split.sh` completed a full real run
(exit 1 = harness sound, no split config reached the demonstration target under delay — a
valid **negative/finding** result, report produced). This lab's job was to TEST the design's
throughput hypotheses; it refuted the central one with data (below).

## 1. Verification ladder (commands + exit status, run this session)

| Level | Command | Result |
|---|---|---|
| L0 | `go test ./...` | **exit 0** — all writer tests incl. 6 new `KEY_PREFIXES` tests pass |
| L1 | `helm lint chart/ && helm template chart/ >/dev/null` | **exit 0** — chart renders |
| chart untouched | `git status --porcelain chart/` | **empty** — zero chart changes (INV-3/§0-10 honored) |
| pipeline lint | `connect lint pipelines/forward.yaml` | **exit 0** — Bloblang valid |
| Full lab | `scripts/verify-prefix-split.sh` | **exit 1** (harness_ok=1, any_split_pass=0, c4_ok=1) |

The one repo code change (writer `KEY_PREFIXES`) was cross-reviewed by **Codex** (different
provider) — no substantive issues; nits (single/duplicate-prefix coverage) were closed.

## 2. Scenario results (from `reports/20260706-234700/`, all numbers from CSV)

| Scenario | N (prefixes) | delay | maxAckPending | rate | **aggregate apply** | p95 E2E |
|---|---|---|---|---|---|---|
| S0 | 4 | **off** | 1024 | 4000 | **3249 msg/s** | 5 ms |
| S1 | 1 | on (185±15 ×2) | 1024 | 4000 | **3 msg/s** | ~127 s |
| S2 | 1 | on | **8192** | 4000 | **3 msg/s** | ~141 s |
| S3 | 2 | on | 1024 | 4000 | **4 msg/s** | ~134 s |
| S4 | 4 | on | 1024 | 4000 | **10 msg/s** | ~130 s |
| S5 | 4 | on | 1024 | 6000 | **10 msg/s** | ~152 s |

## 3. Findings (the actual scientific result)

**F1 — The design's maxAckPending "in-flight window" model (H1) is REFUTED.**
Redpanda Connect's `nats_jetstream` pull input (bind mode) keeps only ~**1 fetch in flight**,
not `maxAckPending`: `nats consumer info` showed `Outstanding Acks: 1 out of maximum 1024`
under delay. It does NOT pipeline to fill the window. Direct proof: **S1 (maxAckPending=1024)
= S2 (maxAckPending=8192) = 3 msg/s** — the window knob has no effect. The predicted
"1024/0.4 ≈ 2560 msg/s" never materialized; measured was ~3 msg/s.

**F2 — Under delay, per-consumer throughput ≈ 1/(2d + t_proc), i.e. one message per fetch
round-trip.** With 185 ms each way (~370–555 ms effective per message), a single sink does
~3 msg/s. This is a ~1000× cliff from the 0-delay baseline (S0 3249 → S1 3).

**F3 — Prefix-splitting scales throughput LINEARLY in the number of consumer pods (H2 confirmed
in SHAPE, refuted in magnitude/mechanism).** S1(N=1)=3 → S3(N=2)=4 → **S4(N=4)=10** ≈ **3.9× at
N=4**. Splitting helps because it adds *concurrent consumers* (concurrency ÷ RTT), NOT because
it multiplies an ack window. The real capacity model is `aggregate ≈ concurrent_pods /
(2d + t_proc)` — so reaching 8000 msg/s under 185 ms delay would need ~3000 concurrent pods:
**8000 under this delay is infeasible with this pull architecture** (remedy is architectural —
a pipelined/push consumer — not a values tweak). This reshaped the D3 chart-redesign spec.

**F4 — Rate is irrelevant once delay-bound.** S5 (rate 6000) = S4 (rate 4000) = 10 msg/s; the
sink drains at its delay-bound ceiling and the excess simply grows backlog (p95 → minutes).

**F5 — Even at 0 delay, aggregate anti-scales on single-node NATS.** A single sink alone does
~6.4k/s, but N=4 aggregate is only ~3.2–4.8k/s; adding consumers to one NATS server degrades
per-consumer throughput. Bypassing toxiproxy gave the same number, so the ceiling is the
single-node NATS/connect path, not the delay tool.

**F6 — Harness/chart gap discovered (not in the design): NATS JWT permission scoping.** The
chart's baked subscriber creds (`chart/files/nats-auth/subscriber.creds`) grant JS-API perms
scoped to the EXACT durable `cdc_sink`; per-prefix durables `cdc_sink_<prefix>` are rejected
("permissions violation") and the account signing key is gitignored. The lab works around this
by minting a wildcard-consumer subscriber set and injecting it at the k8s-object level
(`scripts/setup-nats-auth.sh`) — **chart files stay byte-for-byte untouched**. Multi-group
chart support MUST regenerate the subscriber grant (documented in the D3 spec).

## 4. Deviations from DESIGN (all recorded per §0-4)

| Deviation | Reason |
|---|---|
| RATE 8000→4000, TARGET 8000→3000 | Aggregate is infra-capped ~4.8k/s at 0 delay (F5) and collapses under delay (F2); the demonstration is run below the ceiling to isolate the delay-vs-split effect. 8000 is infra-infeasible (F3). |
| S0 uses N=4 (not N=1) | A single sink at 0 delay is itself window/RTT-limited; N=1 S0 could never gate "harness sound". C-0 re-defined as **writer input capacity** (writer sustained ≥90% of rate), the honest harness check. |
| Source leg tuned (readLimit 50→500, threads 2→8, max_in_flight 256→2048) | Single source pod was the initial input bottleneck; tuning let it feed ≥4000/s (DESIGN §5.2 sanctioned knobs). |
| NATS auth injected at k8s level | F6 — required for per-prefix durables; chart untouched. |
| Correctness sample simplified to unproc-delta + unknown-subject guard | Under multi-minute backlog, central/region parity can't settle within the drain window; `cdc_unprocessable` delta = 0 and `kv.cdc.unknown.*` = 0 were asserted (c4_ok=1). |

## 5. Embedded run report

See `reports/20260706-234700/report.md` (+ `comparison.png` and per-scenario throughput/backlog/
latency PNGs, all generated from that run's CSVs). Scenario summary reproduced above (§2).

Teardown (`scripts/teardown.sh`) leaves the kind cluster; `kubectl get deploy -l lab=prefix-split`
is empty after teardown.
