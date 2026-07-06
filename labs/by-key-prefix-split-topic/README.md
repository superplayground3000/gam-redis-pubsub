# by-key-prefix-split-topic — run guide

## What / why

This lab measures whether **splitting a CDC pipeline by the first colon-delimited key prefix**
into N `subject × durable pull-consumer × sink-pod` groups (1:1) can hold **≥8000 msg/s of
aggregate apply throughput when the sink-side Connect↔NATS path carries 170–200 ms of latency
in each direction** — a regime where a single sink is capped by its pull-consumer in-flight
window (`maxAckPending`) and cannot keep up. A Go writer produces a constant 8000–10000 msg/s;
the source leg publishes `kv.cdc.<prefix>.<op>`; per-prefix sinks bind `cdc_sink_<prefix>` and
apply to region Redis; toxiproxy injects the delay. The honest throughput signal is the
aggregate rate of `cdc_apply` (incremented only after a successful region-Redis write). All
report numbers come from CSVs written during the run — nothing is hand-entered. See
`RESEARCH.md` for the property and mechanism, and `docs/labs/by-key-prefix-split-topic/DESIGN.md`
for the full design.

## Prerequisites

- A kind cluster named **`cdc`** (override with `KIND_NAME`).
- These images present in the local docker store (preflight asserts and `kind load`s them):
  - `hpdevelop/connect:4.92.0-claudefix` (Connect, both legs)
  - `ghcr.io/shopify/toxiproxy:2.9.0` (delay injection)
  - `natsio/nats-box:0.14.5` (toolbox: `nats` CLI + `curl` + `jq`)
- The **apps image** (`redis-rrcs/cdc-apps:dev`, the writer with the `KEY_PREFIXES` change) is
  **rebuilt by preflight** via `scripts/build-images.sh --kind` — you do not build it by hand.
- `helm`, `kubectl`, `kind`, `docker` on the host.

## How to run

Single entrypoint:

```bash
bash scripts/verify-prefix-split.sh
```

It runs preflight → deploy → S0 harness check → S1–S5 scenarios → report, writing everything
under `reports/<timestamp>/`.

- `SKIP_BUILD=1` skips the apps-image rebuild (use only when `redis-rrcs/cdc-apps:dev` already
  contains the `KEY_PREFIXES` change and is loaded into kind).
- For a quick smoke run, shorten the scenario rhythm, e.g.
  `WARMUP_S=20 MEASURE_S=60 bash scripts/verify-prefix-split.sh`. (Short windows give noisier
  steady-state numbers — treat them as a plumbing check, not as the real result.)

Full run is ~60–80 min (deploy ~10 min + 6 scenarios).

## Env knobs (DESIGN §12)

| Env | Default | Purpose |
|---|---|---|
| `KIND_NAME` / `NS` / `RELEASE` | `cdc` / `cdc-k8s` / `cdc` | cluster / namespace / helm release |
| `CONNECT_IMAGE` | `hpdevelop/connect:4.92.0-claudefix` | Connect image (both legs); preflight asserts it exists |
| `PREFIXES` | `prefix-a,prefix-b,prefix-c,prefix-d` | prefix set; scenarios take the leading subset by N |
| `RATE` / `RATE_HIGH` | `8000` / `10000` | constant writer input rate (normal / high) |
| `TOXIC_LAT_MS` / `TOXIC_JITTER_MS` | `185` / `15` | per-direction latency / jitter; set `92`/`8` to mean "total RTT 170–200" |
| `MAX_ACK_PENDING` / `MAX_ACK_PENDING_TUNED` | `1024` / `8192` | consumer in-flight window: S1/S3/S4 / the S2 tuned control |
| `WARMUP_S` / `MEASURE_S` / `DRAIN_TIMEOUT_S` | `60` / `300` / `300` | per-scenario warmup / measure window / max drain |
| `SCRAPE_INTERVAL_S` | `5` | collector CSV sampling period |
| `SINK_REPLICAS` | `1` | pods per prefix group (>1 exercises pull-consumer sharing) |

All knobs are env-overridable; nothing needs editing in-file.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Harness sound **and** a split config held ≥8000 msg/s under delay **and** correctness ok (C-0 ∧ C-1 ∧ C-4). |
| `3` | Harness **INCONCLUSIVE** — S0 (through the proxy, 0 ms toxic) could not reach 8000 msg/s, so the proxy/host is the bottleneck. Fix the harness, don't trust the delay results. |
| `1` | Harness sound but **no** split config reached 8000 under delay — a valid **negative result**; the report is still produced. |

**S1 (single sink + delay) is EXPECTED to fail** and does not affect the exit code. Its
purpose is to reproduce the in-flight-window ceiling.

## Scenario matrix (DESIGN §6)

All scenarios: constant input, warmup then a 300 s measure window, drain (rate→0, wait
pending→0), purge, next. Payload 200 B, chart-default op mix.

| # | prefixes N | toxic | maxAckPending / consumer | rate | expected | purpose |
|---|---|---|---|---|---|---|
| S0 | 1 | **none** (still through proxy) | 1024 | 8000 | PASS (C-0) | prove harness + proxy bare throughput ≥8000; else rc 3 |
| S1 | 1 | 185±15 both ways | 1024 | 8000 | **FAIL** (finding) | reproduce: single sink hits the in-flight ceiling |
| S2 | 1 | same | 8192 | 8000 | recorded | control: tune the window only, no split — does it suffice? |
| S3 | 2 | same | 1024 | 8000 | marginal | split ×2 |
| S4 | 4 | same | 1024 | 8000 | PASS (C-1, main proof) | split ×4 |
| S5 | 4 (C-1 config) | same | 1024 | 10000 | recorded (C-2) | high-rate endpoint |

## Outputs

Each run writes `reports/<timestamp>/`:

- per-scenario CSVs — `S0.csv` … `S5.csv` (raw cumulative counters + pending + latency, one
  row every `SCRAPE_INTERVAL_S`)
- PNG charts — per-scenario throughput / backlog / latency plus a cross-scenario `comparison`,
  generated in-container by `report/plot.py`
- `report.md` — human report (all series traceable to CSV columns)
- `report.json` (+ `scenarios.jsonl`) — machine-readable per-scenario verdicts
- `commands.log` — every mutating command + exit status

`reports/` is **gitignored** (so are the generated `pipelines/forward.yaml`,
`pipelines/reverse.tpl.yaml`, and `pipelines/reverse-*.yaml`).

## Teardown

```bash
bash scripts/teardown.sh
```

Removes every lab-owned object (label `lab=prefix-split`), the generated ConfigMaps, and
uninstalls the helm release. **The kind cluster is kept** (it is shared). `DELETE_NS=1` also
deletes the namespace.

## Interpreting results — findings vs harness bugs

The key discipline (DESIGN §0-4): a scenario missing 8000 msg/s is a **finding**, recorded as
is; only harness faults are bugs to fix. Concretely:

- **S0 below 8000 → harness bug (rc 3).** The proxy or host is the limiter; the delay
  scenarios below it are not trustworthy. Fix throughput knobs (not the oracle) and rerun.
- **S1 fails → expected finding.** This is the single-sink in-flight ceiling under RTT, the
  whole point of the experiment. Read the backlog chart: `num_ack_pending` pinned at
  `maxAckPending` with `num_pending` climbing is the signature.
- **S2 (tuned window, no split) passing or failing → a finding either way.** If it also
  reaches 8000, the argument for splitting shifts to isolation / linear scaling rather than
  "only way"; that conclusion feeds the D3 chart-redesign doc.
- **S3/S4 → the main result.** S4 holding ≥8000 with no monotonic `num_pending` growth is C-1.
- **S5 → recorded** high-rate endpoint, pass or fail.
- **Correctness (C-4) is separate from throughput.** A non-zero `cdc_unprocessable` delta, or
  any `kv.cdc.unknown.*` subjects (a prefix-fallback bug), flags a harness/logic problem — not
  a throughput finding — and forces exit 1.
