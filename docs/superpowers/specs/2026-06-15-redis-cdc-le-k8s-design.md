# redis-cdc-le-k8s — design

Date: 2026-06-15
Status: approved (design questions answered; recommended defaults adopted)

## Goal

Create a new top-level repo folder, `redis-cdc-le-k8s/`, that maintains a Redpanda
Connect CDC chart combining:

- the CDC pipeline of `labs/no-lww-simple-cdc` (Redis central → NATS JetStream →
  Redis region, via a pull consumer), as the base, and
- the Kubernetes-Lease leader-election (active/standby) mechanism of
  `labs/redis-connect-leader-election-k8s`.

## Requirements (from `helm-relese/requirements.md`)

1. New folder in repo root dedicated to maintaining the Redpanda Connect chart.
2. Base = `no-lww-simple-cdc`; add the k8s Lease leader-election mechanism from
   `redis-connect-leader-election-k8s`.
3. Redis templates default to `--protected-mode "no"`.
4. Redpanda Connect defaults to **pull consumer** mode.
5. RBAC: grant the leader elector permission to run elections (leases).
6. Pull consumer must be pre-created; provide a command script to create it.
7. Author YAML in block/indented style — no flow-style braces `{ }`.

## Decisions (answered)

- **Deliverable:** full lab copy (writer/verifier/dashboard Go services + chart),
  standalone and runnable — not chart-only.
- **Leader-election scope:** BOTH connect legs (source and sink).
- **Consumer script:** standalone `scripts/create-consumer.sh` AND keep the
  automatic `nats-init` Job.
- **Folder name:** `redis-cdc-le-k8s` at repo root.
- Recommended defaults adopted: both legs `replicas: 2`; lease timings 6s/4s/1s;
  keep base `verifier`/`dashboard`; drop LE's `observer`.

## Architecture

Unchanged dataflow from the base:

```
writer → redis-central (app.events stream)
       → connect-source  (redis_streams → nats_jetstream publish)
       → NATS JetStream  (stream + durable PULL consumer, pre-created)
       → connect-sink    (nats_jetstream bind:true PULL → redis-region apply)
       → redis-region
verifier / dashboard observe convergence
```

What changes: each connect leg becomes an **active/standby set**.

### Streams-mode + elector sidecar (per leg)

- Connect container boots in **streams mode** with an empty pipeline:
  `args: ["streams", "-o", "/etc/connect/observability.yaml"]`.
- An **elector sidecar** (client-go `LeaderElection`) runs in every connect pod.
  Only the Lease holder POSTs the leg's pipeline to its local connect via the
  streams REST API (`POST /streams/<id>`); on losing the lease it DELETEs the
  stream. Standbys hold zero streams (`/ready` still returns 200 → healthy but
  idle). Result: exactly one active consumer per leg → strict ordering preserved.
- Per leg: its own Lease, stream ID, and pipeline ConfigMap.
  - source leg: Lease `connect-source-elector`, stream id `forward_leg`.
  - sink leg:   Lease `connect-sink-elector`,   stream id `reverse_leg`.

### Pipeline files → streams-config shape

The base `files/connect/cdc-forward.yaml` / `cdc-reverse.yaml` are full
`run`-mode configs (top-level `http`/`logger`/`metrics`). For streams mode:

- Strip top-level `http:`, `logger:`, `metrics:` — these move to
  `files/connect/observability.yaml` (the `-o` bootstrap config). Each pipeline
  file keeps only `input` / `pipeline` / `output`.
- `cdc-forward` `client_id: ${HOSTNAME:…}` → `__POD__`: the streams REST API does
  NOT expand environment variables; the elector substitutes the literal pod name
  for the `__POD__` token before POSTing (see elector `renderPipeline`).
- Runtime Bloblang interpolations (`${! meta("op") }`, publish subject) are
  unaffected — connect evaluates those at run time.

### RBAC (req #5)

`chart/templates/rbac.yaml`: per leg a ServiceAccount + Role
(`coordination.k8s.io/leases`: get,list,watch,create,update,patch) + RoleBinding.
Each connect Deployment sets `serviceAccountName` to its leg's SA.

### Redis protected-mode (req #3)

`redis-central` and `redis-region` Deployments add `--protected-mode` `"no"` to
the `redis-server` args, in block style.

### Pull consumer (reqs #2, #4)

Already the default: `bind: true` inputs + the `nats-init` Job that creates and
reconciles the durable pull consumer server-side. Kept as-is. Added:
`scripts/create-consumer.sh` — a documented manual
`nats consumer add <stream> <consumer> --pull --filter … --ack explicit
--max-pending … --wait … --deliver all --max-deliver=-1` wrapper (admin creds or
a saved context), usable against bundled or external NATS, per
`helm-relese/connect-pull-consumer-mode.md`.

### YAML style (req #7)

All chart YAML authored/edited in this lab (templates, `values.yaml`,
`files/connect/*`) uses block/indented style; flow-style `{ }` maps are expanded.

## Components

- `chart/` — Helm chart (templates, files, NATS nsc auth material).
  - new: `templates/rbac.yaml`, `files/connect/observability.yaml`.
  - changed: `connect-source.yaml`, `connect-sink.yaml` (streams mode + elector
    sidecar + SA), `connect-configmaps.yaml` (pipeline + observability CMs),
    `redis-central.yaml`, `redis-region.yaml` (protected-mode), `values.yaml`
    (connect.{source,sink}.replicas, lease.*, streamID, elector image+resources),
    `_helpers.tpl` (unchanged helpers reused).
- `elector/` — client-go leader-election controller (copied from LE lab).
- `writer/`, `verifier/`, `dashboard/` — copied from base, unchanged.
- `scripts/` — base scripts + new `create-consumer.sh`; `build-images.sh` also
  builds the elector image.

## Verifier integration risk

The verifier sums the sink's `cdc_apply` Prometheus counter. With active/standby
and a round-robin Service, a scrape can hit an idle standby (zero series). Resolve
by scraping the **leader** only: a headless Service + per-pod scrape (mirroring
LE's headless approach), or filter to the pod reporting `elector_leading=1`.
Decided during implementation; verified by a green `helm template` + a scrape that
returns the active leg's counter.

## Testing

- `helm template` of the chart renders cleanly (default values, and
  external-NATS/external-Redis toggles).
- `helm lint`.
- Go unit tests still pass in `elector/`, `writer/`, `verifier/`, `dashboard/`.
- Block-style check: no flow-map `{ }` left in authored chart YAML.

## Non-goals

- No change to the CDC semantics (still no-LWW; last writer overwrites).
- No new observability service (LE's `observer` is dropped).
- External Redis TLS / writer-verifier auth remain out of scope (inherited).
