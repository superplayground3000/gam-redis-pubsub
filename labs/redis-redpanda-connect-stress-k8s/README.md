# Redis → Redpanda Connect Stress Lab (Kubernetes fork)

Kubernetes-native fork of `../redis-redpanda-connect-stress/`. Same pipeline
(Redis → Redpanda Connect → NATS JetStream → Redpanda Connect → Redis), same
tier × mode × QoS verdict matrix — packaged as a Helm chart and driven by a
host `kubectl` harness.

## Prerequisites

`helm`, `kubectl`, `kind` (for local), `docker`, `go`, `python3`. A reachable
cluster context (`kubectl config current-context`).

## Quick start (kind / local)

```bash
# 1. Create a local cluster
kind create cluster --name rrcs

# 2. Build the writer + collector images and side-load them into kind
scripts/build-images.sh --kind --kind-name=rrcs

# 3. Run a small matrix (boots the chart, runs, tears down on no-arg full run)
scripts/stress-run.sh --tiers=10 --modes=throughput --profile=alo
```

`stress-run.sh` installs the chart with `chart/values-dev.yaml` (writer/collector
`pullPolicy: Never`, NATS on `emptyDir`), runs each tier × mode cell as a
collector Job, extracts the verdict JSON into `reports/`, and prints a summary.

## Portable / remote cluster

```bash
# Build, retag, and push to your registry
scripts/build-images.sh --registry=corp.example.com/team --push
# Optionally redirect base images to a mirror (airgapped)
scripts/build-images.sh --base-registry=corp.example.com/mirror/ --registry=corp.example.com/team --push

# Install with your registry prefix and default (portable) values
helm install rrcs ./chart -n rrcs-k8s --create-namespace \
  --set images.registry=corp.example.com/team/

# Then run against that namespace
RRCS_VALUES=chart/values.yaml scripts/stress-run.sh --tiers=10 --modes=throughput
```

## Plain YAML (no Helm in-cluster)

```bash
scripts/render.sh --profile=alo            # writes out/manifests.yaml
kubectl create namespace rrcs-k8s
kubectl apply -n rrcs-k8s -f out/manifests.yaml
```

## Knobs (`chart/values.yaml`)

| Key | Default | Purpose |
|---|---|---|
| `profile` | `alo` | QoS profile: `alo` / `amo` / `eoe` |
| `images.registry` | `""` | Prefix for every image (custom registry) |
| `images.pullPolicy` | `IfNotPresent` | Global pull policy (public images) |
| `writer.pullPolicy` / `collector.pullPolicy` | `""` (inherit) | Per-image override; dev sets `Never` |
| `nats.persistence.mode` | `emptyDir` | `emptyDir` (portable) or `pvc` (durable) |
| `nats.persistence.storageClassName` | `""` | Only for `pvc`; blank → cluster default |
| `nats.stream.maxBytes` | `256MB` | JetStream `APP_EVENTS` byte cap |
| `scheduling.{nodeSelector,tolerations,affinity}` | empty | Applied to every pod |
| `chaos.downSeconds` | `8` | Chaos outage length |

Run-window knobs (`DURATION_S`, `WARMUP_S`, `DRAIN_S`, `CHAOS_DOWN_S`) and tier
SLOs live in `scripts/lib/tier-defs.sh` (env-overridable), identical to the
compose lab.

## How the matrix runs

For each tier × mode the harness renders a uniquely-named collector Job
(`helm template -s templates/collector-job.yaml`), applies it, waits for it to
complete, and reads the single `RESULT_JSON:` line from `kubectl logs`. A
failing verdict is an expected outcome (the collector exits 0 and the verdict
lives in the JSON); only a genuine collector error fails the Job and surfaces as
an `ERROR`/missing cell. Chaos mode scales `connect-sink` to 0 and back, gated by
its `/ready` readiness probe.

## Teardown

```bash
helm uninstall rrcs -n rrcs-k8s
kind delete cluster --name rrcs   # if using kind
```
