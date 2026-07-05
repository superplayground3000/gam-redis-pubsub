# redis-cdc-le-k8s

Redpanda Connect CDC chart = the fence-free CDC relay of `../labs/no-lww-simple-cdc`
**plus** Kubernetes-Lease leader election (active/standby) on both connect legs,
from `../labs/redis-connect-leader-election-k8s`.

## What this demonstrates

A fence-free CDC relay: a writer emits each `create`/`update`/`delete`/`rename`
as a CDC envelope on a central Redis Stream; a Redpanda Connect **source** leg
publishes to NATS JetStream (with `Nats-Msg-Id` dedup); a Connect **sink** leg
binds a durable **pull consumer**, switches on `op`, and applies
`SET`/`DEL`/rename-Lua to **region** Redis KV — with **no last-write-wins fence**.

What this fork adds:

- **Leader election on both legs.** Each connect leg runs `replicas: 3`
  (1 active + 2 standbys — HA quorum) in *streams mode* (empty boot) with an
  **elector sidecar**. Only the holder of the leg's coordination.k8s.io **Lease**
  POSTs the consuming pipeline to its local connect over the streams REST API;
  standbys hold no stream (`/ready` is 200 — healthy but idle). Exactly one active
  pod consumes per leg ⇒ clean active/standby failover and no cross-pod
  double-processing. (Within the active sink pod, `pipeline.threads` still
  processes a batch concurrently, so same-key ops in one batch may reorder — fine
  for this no-LWW lab; set sink `threads: 1` for strict per-key ordering.)
- **RBAC** granting each elector get/list/watch/create/update/patch on `leases`.
- **Pull-consumer by default** (`bind: true`): the durable consumer is
  pre-created server-side (the `nats-init` Job, or `scripts/create-consumer.sh`),
  because the `nats_jetstream` input only *attaches*, never creates.
- Redis defaults to `--protected-mode no` (`redis.protectedMode`).

See `docs/superpowers/specs/2026-06-15-redis-cdc-le-k8s-design.md` for the design.

## Run it (kind)

```bash
kind create cluster --name cdc
scripts/build-images.sh --kind --kind-name=cdc   # writer/verifier/dashboard/elector → kind
# NATS auth fixtures are committed; regenerate only on a fresh checkout if missing:
#   scripts/gen-nats-auth.sh --force
RRCS_NS=cdc-k8s RRCS_RELEASE=cdc scripts/verify-cdc.sh
```

`verify-cdc.sh` boots the chart (`profile=cdc`), runs the verifier Job, and exits
0 only when all three checks pass (dedup, per-op-under-quiescence, idempotent
replay).

## Body encoding & backward-safe upgrade

The CDC body inside the NATS envelope can be carried as a plain string
(`connect.bodyEncoding: "none"`, the default) or **gzip-then-base64**
(`"gzip:base64"`). Plain `content().string()` both bloats and *silently corrupts*
non-UTF-8/binary values (Go's JSON encoder rewrites invalid bytes to U+FFFD);
`gzip:base64` carries the raw bytes losslessly and smaller. The **sink leg
auto-detects** the format per message via the envelope's `enc` field, so it always
consumes both — only the **source leg** honors the flag.

`values-dev.yaml` enables `gzip:base64` (kind installs are fresh, so both legs start
new together — safe). Because this is a wire-format change, **upgrading an existing
deployment is reader-first** — the sink must understand the new format before the
source produces it:

```bash
# 1. Deploy this chart with encoding still OFF; roll BOTH legs.
#    Sink becomes decode-capable while the source still emits plain bodies (safe in any order).
helm upgrade cdc ./chart -n cdc-k8s --set profile=cdc --set connect.bodyEncoding=none
kubectl -n cdc-k8s rollout restart deploy/lab-connect-sink deploy/lab-connect-source

# 2. Flip encoding ON; roll ONLY the source. Every sink already decodes.
helm upgrade cdc ./chart -n cdc-k8s --set profile=cdc --set connect.bodyEncoding=gzip:base64
kubectl -n cdc-k8s rollout restart deploy/lab-connect-source
```

(The chart has no configmap-checksum annotation, so pods must be rolled to re-POST a
changed pipeline — the elector POSTs only on lease acquisition.)

## Inspect leader election

```bash
kubectl -n cdc-k8s get lease                       # holderIdentity = active pod per leg
kubectl -n cdc-k8s get pods -l app=connect-sink    # 3 replicas; 1 active, 2 standby
```

## Pre-create the pull consumer by hand

The bundled `nats-init` Job creates/reconciles the durable pull consumer
automatically. For an **external** NATS (or after `nats consumer rm`), form the
command manually — it never auto-runs unless you set `RUN=1`:

```bash
scripts/create-consumer.sh                         # prints `nats consumer add … --pull …`
NATS_CLI="nats --server nats://nats-1:4222 --creds /path/admin.creds" RUN=1 \
  scripts/create-consumer.sh                       # actually create it
```

## Drive it by hand

`scripts/insert-msgs.sh` **prints** ready-to-run `redis-cli XADD` commands (one
per op + a 5× dedup test) — copy and run them yourself; the script never executes
them.

## Watch central vs region live

```bash
scripts/dashboard-forward.sh        # binds 0.0.0.0; open http://<host>:8080
```

The dashboard shows central/region key counts, divergence, per-op sink applies
(summed across all sink pods, so the active leader's counts are always reflected),
and a live region key-change feed.

## HTML report

```bash
RRCS_NS=cdc-k8s RRCS_RELEASE=cdc scripts/gen-report.sh   # writes reports/cdc-report.html
```

## Latency calculator (optional)

The sink leg emits a best-effort `cdc:latency` record (`op,kv_key,writer_ts,sink_ts`)
to **region** Redis after each create/update. Enable the region-side calculator to
turn that into a rolling p50/p95/p99 report:

```bash
helm upgrade ... --set latencyCalculator.enabled=true
kubectl -n <ns> exec deploy/<prefix>latency-calculator -- cat /reports/latency-report.json
```

`latency_ms = sink_ts - writer_ts`. Only create/update are measured (delete/rename
carry no body/ts). A persistently rising `dropped_negative` indicates central/region
clock drift (NTP), not a CDC bug.

### One module, one binary, one image

All workloads live in a single Go module (`redis-cdc-le-k8s`): a `main.go`
dispatcher plus `internal/{writer,verifier,elector,latency,dashboard}` subpackages.
One `go build` produces a single binary `app` (no `go.work`) that selects its
behavior by subcommand: `app writer`, `app verifier`, `app elector`,
`app latency-calculator`, `app dashboard`. That binary ships in a single image
(`redis-rrcs/cdc-apps`) whose entrypoint idles on `sleep infinity`; every k8s
workload overrides `command:` to `["/usr/local/bin/app","<mode>"]` to pick its
mode. Build with `scripts/build-images.sh [--kind --kind-name=...]`.

## Validation note

This is a Kubernetes lab, so the research-lab skill's `validate_lab.sh`
(docker-compose) does not apply. `scripts/verify-cdc.sh` is the validation: exit
0 requires dedup + per-op + replay all green.

## Teardown

```bash
helm uninstall cdc -n cdc-k8s
kind delete cluster --name cdc
```

## Further reading

- `docs/superpowers/specs/2026-06-15-redis-cdc-le-k8s-design.md` — this fork's design.
- `RESEARCH.md` — the property, wire contract, and order-insensitive PASS bar (base).
- `../labs/no-lww-simple-cdc/` — the CDC base lab.
- `../labs/redis-connect-leader-election-k8s/` — the leader-election base lab.
