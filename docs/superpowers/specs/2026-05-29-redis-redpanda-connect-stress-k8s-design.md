# Redis → Redpanda Connect Stress Lab, Kubernetes-Native Fork — Design

**Source lab:** `labs/redis-redpanda-connect-stress/` (Docker Compose)
**Target lab:** `labs/redis-redpanda-connect-stress-k8s/` (Helm chart + host harness)
**Date:** 2026-05-29
**Status:** design — incorporates Codex early-review findings (6 HIGH, 5 MED, 2 LOW), all 13 applied below, plus 2 stop-time review fixes (collector failure semantics §6, persistence `memory`-mode cut §5.1)

---

## 1. Goal

Fork the existing Docker Compose stress lab into a Kubernetes-native lab that runs the **same** Redis → Redpanda Connect → NATS JetStream → Redpanda Connect → Redis pipeline, drives the **same** tier × mode × QoS matrix, and produces the **same** verdict JSON — but is deployed as a Helm chart and exercised by a host harness that talks to the cluster over `kubectl`.

Concretely, the fork is "done" when:

- `helm install` (or the rendered plain YAML) brings up all seven workloads plus the JetStream stream on a fresh cluster, and every workload reaches Ready.
- `bash scripts/stress-run.sh` on the host runs the full matrix against the cluster and prints the same summary table the compose lab prints, with per-tier verdict JSON extracted from the collector.
- The manifests are **portable**: they run on `kind` for local dev and on any other conformant cluster (corporate/airgapped) by changing only `values.yaml` (image registry, storage class, scheduling) — no `hostPath`, no kind-only assumptions.
- Images can be built against a **configurable base registry** and pushing to a remote registry is **optional** (build-and-test-locally is a first-class flow).

**Non-goal of the fork:** changing the pipeline's behavior, tiers, SLOs, QoS semantics, or the collector's measurement logic. This is a deployment-substrate port, not a tuning change. The compose lab stays in place, untouched.

## 2. What is being forked (source inventory)

The compose lab (`docker-compose.yml`) has seven long-lived services, one run-once init, and one one-shot tool:

| Compose service | Image | Role | Ports | Healthcheck |
|---|---|---|---|---|
| `redis-central` | `redis:7.4-alpine` | ingress stream store (`app.events`) | 6379 | `redis-cli ping` |
| `redis-region` | `redis:7.4-alpine` | egress stream store (`region-events`) | 6379 | `redis-cli ping` |
| `nats` | `nats:2.10-alpine` | JetStream broker | 4222 (client), 8222 (mon) | `wget /healthz` |
| `nats-init` | `natsio/nats-box:0.14.5` | run-once: create `APP_EVENTS` stream idempotently | — | `restart: no` |
| `connect-source` | `hpdevelop/connect:4.92.0-claudefix` | Redis→JetStream forward leg | 4195 | `wget /ready` |
| `connect-sink` | `hpdevelop/connect:4.92.0-claudefix` | JetStream→Redis reverse leg | 4195 | `wget /ready` |
| `writer` | local Go build | load generator, control API | 8081 | `wget /healthz` |
| `collector` | local Go build (`profile: tools`) | one-shot run driver + verdict | — | n/a |

Compose dependency edges to preserve:

- `nats-init` waits for `nats` healthy.
- `connect-source` waits for `redis-central` healthy **and** `nats-init` completed-successfully.
- `connect-sink` waits for `redis-region` healthy **and** `nats-init` completed-successfully.
- `writer` waits for `redis-central` healthy **and** `connect-source` healthy.
- `collector` waits for all of the above healthy.

Config inputs to preserve:

- QoS profile selects which Connect config pair is mounted: `connect/${PROFILE_QOS}-forward.yaml` on source, `${PROFILE_QOS}-reverse.yaml` on sink, for `PROFILE_QOS ∈ {alo, amo, eoe}`.
- Writer env: `REDIS_ADDR`, `STREAM_KEY=app.events`, `STREAM_MAXLEN`, `WORKERS`, `PIPELINE_DEPTH`, `INITIAL_RATE=0`, `KEY_SPACE_SIZE`, `PAYLOAD_BYTES`, `MAX_RATE`, `HEALTH_ADDR=:8081`.
- `APP_EVENTS` stream parameters (subjects `app.events.>`, file storage, `--max-age 1h`, `--max-bytes`, `--max-msg-size 1MB`, `--dupe-window 5m`, etc.).
- Tier SLOs and run-window knobs in `scripts/lib/tier-defs.sh` (copied verbatim; tier-defs is substrate-independent).

## 3. Target directory layout

```
labs/redis-redpanda-connect-stress-k8s/
├── README.md
├── RESEARCH.md                      # carried forward + a "why Kubernetes fork" section
├── chart/
│   ├── Chart.yaml
│   ├── values.yaml                  # full config surface (defaults = portable, registry-pull)
│   ├── values-dev.yaml              # kind overlay: pullPolicy Never, emptyDir NATS, no storageClass
│   ├── templates/
│   │   ├── _helpers.tpl
│   │   ├── redis-central.yaml        # Deployment + Service
│   │   ├── redis-region.yaml         # Deployment + Service
│   │   ├── nats.yaml                 # Deployment (or StatefulSet) + Service + optional PVC
│   │   ├── nats-init-job.yaml        # plain Job (NOT a hook) — fix #1
│   │   ├── connect-source.yaml       # Deployment + Service + ConfigMap mount
│   │   ├── connect-sink.yaml         # Deployment + Service + ConfigMap mount
│   │   ├── writer.yaml               # Deployment + Service
│   │   ├── connect-configmaps.yaml   # ConfigMaps built from .Files (fix #2)
│   │   └── NOTES.txt
│   └── files/
│       └── connect/                  # the 6 QoS YAMLs, COPIED here (fix #2)
│           ├── alo-forward.yaml  alo-reverse.yaml
│           ├── amo-forward.yaml  amo-reverse.yaml
│           └── eoe-forward.yaml  eoe-reverse.yaml
├── writer/                          # copied from source; Dockerfile gets ARG BASE_REGISTRY
├── collector/                       # copied from source; main.go gets --out=- sentinel support (fix #5)
└── scripts/
    ├── render.sh                    # helm template wrapper → out/manifests.yaml
    ├── build-images.sh              # build (+optional push) with configurable base/target registry
    ├── stress-run.sh                # host harness, kubectl-driven
    ├── chaos/
    │   └── scale-connect-sink.sh    # scale 0 → sleep → 1 → wait ready (fix #6 gate)
    └── lib/
        └── tier-defs.sh             # copied verbatim from source
```

The collector source must be **copied** into the new lab (the chart references its image, and `build-images.sh` builds it). The connect YAMLs must be **copied** into `chart/files/connect/` so Helm's `.Files` can read them (a chart cannot read paths outside its own directory — **fix #2**).

## 4. Compose → Kubernetes resource mapping

| Compose construct | Kubernetes equivalent | Notes |
|---|---|---|
| long-lived `service` | `Deployment` (replicas: 1) + `Service` (ClusterIP) | DNS name = service name, same as compose |
| `container_name` | not needed | addressing is via Service DNS |
| `depends_on: condition: service_healthy` | `initContainers` that poll the dependency, **plus** readiness probes on the dependency (fix #6) | see §5 |
| `depends_on: service_completed_successfully` (nats-init) | initContainer that polls `APP_EVENTS` stream existence | see §5.2 |
| `healthcheck` | `readinessProbe` + `livenessProbe` | mirror the compose `wget`/`ping` tests exactly (fix #6) |
| `nats-init` run-once | a **plain templated `Job`** (not a Helm hook) | fix #1 — see §5.2 |
| `command` / `entrypoint` | `command` / `args` | verbatim |
| `environment` | `env:` | verbatim |
| volume mount of `./connect/*.yaml` | `ConfigMap` + `volumeMounts` with `subPath` | see §5.3 |
| named volume `nats-data` | `emptyDir` (dev) or `PVC` (portable, opt-in) | fix #11 — see §5.1 |
| `deploy.resources.limits` | `resources.limits` **and** `resources.requests` (fix #10) | requests added |
| `ports` host-mapping | **not** mapped; host access via `kubectl port-forward` | harness opens PFs (§7) |
| `collector` (`profile: tools`, one-shot) | a `Job` created per run by the harness via rendered manifest | fix #7 — see §6 |
| `networks: rrcs` | namespace `rrcs-k8s` + ClusterIP DNS | fix #3 — no Namespace resource in chart |

## 5. Chart templates — design detail

### 5.1 Stateful workloads (redis-central, redis-region, nats)

Redis: `Deployment` replicas 1, `command` exactly as compose (`redis-server --notify-keyspace-events "" --appendonly no --save ""`), `ClusterIP` Service on 6379.

- `readinessProbe`: `exec: redis-cli ping` (mirrors compose), `periodSeconds: 2`, `failureThreshold: 15`.
- `livenessProbe`: same exec, looser thresholds.
- `resources`: limits `{cpu: 2, memory: 512Mi}` (from compose) **plus** requests `{cpu: 250m, memory: 128Mi}` — **fix #10**.

NATS: `command: ["-js", "-sd", "/data", "-m", "8222"]`, Service exposing 4222 + 8222.

- `readinessProbe` / `livenessProbe`: `httpGet /healthz` on 8222 (mirrors compose).
- **fix #11 — `nats.persistence.mode ∈ {emptyDir, pvc}`** (two modes only; `memory` cut — see note):
  - `emptyDir` (default, and in `values-dev.yaml`): mount an `emptyDir` at `/data`. No StorageClass needed; safe on any cluster including kind. The `APP_EVENTS` stream stays `--storage file` (matching the source lab) on that ephemeral dir — data is lost on pod restart, which is fine for a stress lab.
  - `pvc`: render a `PersistentVolumeClaim` mounted at `/data`; `storageClassName` is **only** emitted when `nats.persistence.storageClassName` is non-empty (a blank value would otherwise leave the PVC `Pending` forever on clusters with no default class). For real cross-restart durability.
  - Default in `values.yaml` (portable): `emptyDir`. Durability is not load-bearing for a stress lab; this keeps the chart runnable on a bare cluster with zero storage config. (Matches the source lab's stance — the compose `nats-data` volume exists for convenience, not correctness.)
  - **Why no `memory` mode (stop-time review fix):** an earlier draft offered a third `memory` mode (`emptyDir` `medium: Memory` + a "memory-backed" server). It was incoherent and is cut. JetStream storage type is a **per-stream** property set at stream creation (`--storage memory|file`), not a server flag or a volume choice — so a `medium: Memory` emptyDir at `/data` would be ignored by a heap-resident memory stream yet still count against the NATS container's memory limit, double-counting that risks OOM. And the nats-init command (from compose) hardcodes `--storage file`, so the "mode" changed nothing. A memory-backed stream is an orthogonal **stream-storage** concern, explicitly out of scope (§13). The persistence knob is solely about *where the file store lives*.

### 5.2 Stream init — plain Job, not a hook (fix #1)

**The bug Codex caught:** if `nats-init` is a `post-install` hook, `helm install --wait` deadlocks. `--wait` blocks until the Connect Deployments are Ready; the Connect initContainers block until `APP_EVENTS` exists; the hook that creates `APP_EVENTS` only runs *after* `--wait` returns. Circular wait → install hangs forever on first run.

**Resolution:** `nats-init` is a **plain templated `Job`** (no hook annotation), so it is created in the same apply pass as everything else and runs as soon as its own initContainer (poll `nats` healthy) passes. The Connect initContainers then observe the stream and proceed. No ordering hook is needed because the dependency gating is done by initContainers, not by Helm phases.

- Job spec: `backoffLimit: 6`, `ttlSecondsAfterFinished: 600`, `restartPolicy: OnFailure`.
- initContainer: poll NATS health: `until nats --server nats://nats:4222 server check connection ...` (full URL — **fix #4**).
- main container: the exact idempotent stream-add block from compose (`stream info || stream add ...`), every `nats` invocation carrying **`--server nats://nats:4222`** (fix #4).
- Re-runnable: idempotent on `helm upgrade`; `ttl` cleans up the old completed Job. (If a name collision is hit on upgrade, the Job uses a content-hash suffix so a changed stream config produces a new Job.)

### 5.3 Connect source / sink

`Deployment` replicas 1, image `connect.image` (registry-configurable), `command: ["run", "/connect.yaml"]`, Service on 4195.

- **ConfigMap mount (fix #2):** `connect-configmaps.yaml` renders one ConfigMap per profile pair from `.Files.Get "files/connect/<profile>-forward.yaml"` etc. The Deployment mounts the active profile's file at `/connect.yaml` via `subPath`. Active profile comes from `values.yaml` `profile: alo|amo|eoe` (the harness sets it per run with `--set profile=` on render, mirroring `PROFILE_QOS`).
- **initContainers (dependency gates):**
  - source: poll `redis-central` (`redis-cli -h redis-central ping`) **and** poll `APP_EVENTS` existence (`nats --server nats://nats:4222 stream info APP_EVENTS`).
  - sink: poll `redis-region` ping **and** `APP_EVENTS` existence.
  - Every `nats` call carries `--server nats://nats:4222` — **fix #4**.
- **readinessProbe + livenessProbe (fix #6):** `httpGet /ready` on 4195, mirroring the compose `wget /ready` healthcheck. This is what makes the chaos recovery gate meaningful — `kubectl rollout status` / readiness will not report ready until Connect's own `/ready` says so, matching the compose behavior where the harness waited for `healthy`.
- `resources`: limits `{cpu: 2, memory: 1Gi}` (compose) + requests `{cpu: 500m, memory: 256Mi}` (fix #10).

### 5.4 Writer

`Deployment` replicas 1, all env from compose verbatim (`REDIS_ADDR=redis-central:6379`, `STREAM_KEY=app.events`, …, `INITIAL_RATE=0`), Service on 8081.

- initContainers: poll `redis-central` ping **and** `connect-source` `/ready`.
- **readinessProbe + livenessProbe (fix #6):** `httpGet /healthz` on 8081 (mirrors compose).
- `resources`: limits `{cpu: 2, memory: 256Mi}` + requests `{cpu: 250m, memory: 64Mi}` (fix #10).

### 5.5 Namespace handling (fix #3)

The chart does **not** template a `Namespace` resource. Instead:

- `helm install rrcs -n rrcs-k8s --create-namespace ...`
- `render.sh` passes `--namespace rrcs-k8s`.
- **Every** `kubectl`/`helm` call in the harness, chaos script, and docs carries `-n rrcs-k8s` (the namespace is a single shell variable `NS="${RRCS_NS:-rrcs-k8s}"`). This was the inconsistency Codex flagged — several harness commands previously omitted `-n`.

### 5.6 Scheduling + image config surface

Global knobs in `values.yaml` (fix #12 — **global-only to start**, per-component overrides deferred as YAGNI):

```yaml
images:
  registry: ""          # prepended to every image ref; "" = use as-is (e.g. docker.io)
  pullPolicy: IfNotPresent
  pullSecrets: []       # list of {name:}
# per-image tags still allowed (needed for the local-built writer/collector):
writer:    { image: redis-rrcs/writer:dev }
collector: { image: redis-rrcs/collector:dev }
connect:   { image: hpdevelop/connect:4.92.0-claudefix }
redis:     { image: redis:7.4-alpine }
nats:      { image: nats:2.10-alpine }
natsBox:   { image: natsio/nats-box:0.14.5 }

scheduling:             # applied to ALL workloads (global-only, fix #12)
  nodeSelector: {}
  tolerations: []
  affinity: {}
```

`_helpers.tpl` provides:

- `rrcs.image` — joins `images.registry` + per-image ref (so `images.registry=corp.example.com/mirror/` redirects every pull). The user explicitly requires a configurable registry for other clusters; this stays (Codex #12 said "global-only" — registry is global, so it's kept; only the per-*component* scheduling overrides are dropped).
- `rrcs.imagePullSecrets` — renders `imagePullSecrets` from `images.pullSecrets`.
- `rrcs.scheduling` — emits the shared `nodeSelector`/`tolerations`/`affinity` block into every pod spec.

## 6. Collector report extraction (fix #5)

**The bug Codex caught:** the collector (`collector/main.go`) writes **indented, multi-line** JSON to a file via `json.Encoder.SetIndent` + atomic temp-rename (`writeJSON`, lines 103-126), then logs a human line `report written to …; verdict.pass=…`. In compose this is fine — the harness reads the file off a bind mount. In K8s there is no portable shared mount (hostPath is banned for portability), so the harness must read the report from `kubectl logs`. Piping multi-line indented JSON through `kubectl logs | grep '^{' | tail -1` is unsound: it catches a stray `{` line or an interleaved log line.

**Resolution — add a `--out=-` stdout mode with a sentinel, and make the exit code mean "did it run", not "did it pass":**

- Extend `collector/main.go`: when `--out=-`, marshal the report with `json.Marshal` (compact, single line) and print exactly one line `RESULT_JSON:<compact-json>` to stdout. Keep the existing `--out=<file>` behavior unchanged for the source lab's collector (the K8s lab has its own copy — copy-local change, source untouched).
- **Exit-code semantics in `--out=-` mode (stop-time review fix — collector failure handling):** the collector exits **0 whenever it produced a report**, whether the verdict passed *or* failed. Non-zero is reserved for a **genuine run failure** — couldn't reach a dependency, run aborted by signal, couldn't marshal — i.e. cases where **no** `RESULT_JSON` line was emitted. This deliberately inverts the source lab's `--out=<file>` convention (exit 1 on verdict-fail), which is correct *there* because the compose harness runs the collector with `|| true` and reads the report **file** regardless of exit code. In K8s there is no shared file and the exit code drives the Job's terminal condition — so the verdict must travel **in the JSON** (`verdict.pass`), never in the exit code. Otherwise an expected FAIL verdict (e.g. a ceiling tier) would mark the Job `failed` and, under any restarting policy, silently re-run the entire stress test.
- The collector still logs its normal human lines.
- Harness extraction: `kubectl logs job/<name> -n rrcs-k8s | sed -n 's/^RESULT_JSON://p' | tail -n 1`. Exactly one well-formed compact JSON line, immune to log interleaving (and, per the lifecycle below, immune to multi-attempt pollution).

**Collector Job lifecycle + failure handling (fix #7 + stop-time review fix):**

- **`restartPolicy: Never`, `backoffLimit: 0`.** A stress run is **never** hermetic on re-run — leftover JetStream/Redis state from the first attempt taints a second — so silent retries are wrong. One attempt → one `RESULT_JSON` line → no multi-attempt `kubectl logs` pollution. (This is *why* exit-0-on-report matters: with the old exit-1-on-fail and any restart policy, an expected FAIL verdict would have re-run the whole test.)
- **Unique name** `collector-<tier>-<mode>-<profile>-<epoch>` (avoids the "apply refuses to update an immutable completed Job" trap; deterministic per invocation, so no `generateName` "which pod won" ambiguity).
- The harness distinguishes **three** terminal outcomes, not two:
  1. Job `complete` + `RESULT_JSON` present, `verdict.pass=true` → **PASS**.
  2. Job `complete` + `RESULT_JSON` present, `verdict.pass=false` → **FAIL** (an expected research outcome, e.g. a ceiling tier — *not* a harness error).
  3. Job `failed` (non-zero exit, **no** `RESULT_JSON`) → **ERROR** — the collector genuinely couldn't run; the harness dumps the pod logs and records the matrix cell as `ERROR`, distinct from FAIL.
  Implementation: `kubectl wait --for=condition=complete --timeout=Ns job/<name>` raced against `--for=condition=failed`; on `complete`, extract and read `verdict.pass`; on `failed`, dump logs and record ERROR.
- After extraction: `kubectl delete job/<name> --wait=true` so the next run is clean; `ttlSecondsAfterFinished` is a backstop.

## 7. Host harness — `scripts/stress-run.sh` (K8s edition)

Same CLI as the compose harness: `--tiers=`, `--modes=`, `--profile=`, same env overrides (`DURATION_S`, `WARMUP_S`, `DRAIN_S`, `CHAOS_DOWN_S`). Sources the verbatim `lib/tier-defs.sh`.

Flow:

1. **Namespace var:** `NS="${RRCS_NS:-rrcs-k8s}"`; every command uses `-n "$NS"` (fix #3).
2. **Boot:** `helm upgrade --install rrcs ./chart -n "$NS" --create-namespace --set profile="$PROFILE" -f <dev-or-prod values> --wait --timeout 5m`. Because `nats-init` is a plain Job (fix #1), `--wait` does not deadlock. `--wait` blocks on Deployment readiness, which now means real `/ready` readiness (fix #6).
3. **Port-forward (chaos pre-flight only):** the collector runs *inside* the cluster and reaches every service by its in-cluster DNS name (its existing defaults `writer:8081`, `nats:8222`, `connect-source:4195`, … already match), so it needs **no** port-forward. The harness's only host-side dependency is the chaos pre-flight, which reads the NATS monitoring `/jsz`. So open exactly **one** `kubectl port-forward svc/nats 18222:8222` (only when a chaos mode is in the matrix) and track its PID. Keeping the PF surface to one port avoids the orphaned-process risk Codex flagged (fix #8).
4. **Per tier × mode:**
   - chaos pre-flight: query the NATS monitoring `/jsz` over the single port-forward (step 3) for `APP_EVENTS` bytes; abort if > 200 MB (same guard as compose).
   - chaos schedule: background `( sleep WARMUP_S; sleep chaos_at_s; bash scripts/chaos/scale-connect-sink.sh "$CHAOS_DOWN_S" )`; track its PID.
   - render + apply the collector Job (unique name, fix #7), passing the collector flags built from `tier-defs.sh` (`--tier --mode --profile --duration --warmup --drain --slo-* --out=-` and chaos args). The collector addresses in-cluster services by Service DNS (see step 3), so no per-run wiring is needed beyond the flags.
   - resolve the run to one of the three terminal outcomes (§6): on PASS/FAIL extract `RESULT_JSON` → `reports/<tier>-<mode>-<profile>.json`; on ERROR dump the pod logs and write **no** report file (the cell is left for the reducer's missing-file branch to surface). Then delete the Job (fix #7).
   - purge JetStream: `kubectl run nats-purge-<epoch> -n "$NS" --rm -i --restart=Never --image=<natsBox> -- nats --server nats://nats:4222 stream purge APP_EVENTS -f` (full `--server` URL, fix #4).
5. **Summary table:** the same Python reducer over `reports/*.json` (copied from the compose harness). Its existing missing-file branch already prints a `MISSING` row when a report is absent; an ERROR run (no report written) therefore shows up there — no reducer change needed, the cell is visibly not-PASS.
6. **Cleanup (fix #8):** a single `trap cleanup EXIT INT TERM` that kills **all** tracked PIDs (every port-forward + the chaos scaler), and — only when invoked with no args — runs `helm uninstall rrcs -n "$NS"` (the K8s analogue of `docker compose down -v`). One cleanup path, all PIDs in one array.

### 7.1 Chaos — `scripts/chaos/scale-connect-sink.sh` (fix #6 gate)

Mirrors `kill-connect-sink.sh` semantics with K8s primitives and the user's chosen scale-to-zero approach:

```
NS="${RRCS_NS:-rrcs-k8s}"; DOWN_S="${1:-8}"; DEPLOY=connect-sink
kubectl -n "$NS" scale deploy/$DEPLOY --replicas=0
# wait for the pod to actually terminate (graceful SIGTERM, like docker stop)
kubectl -n "$NS" rollout status deploy/$DEPLOY --timeout=30s   # scaled to 0
sleep "$DOWN_S"
kubectl -n "$NS" scale deploy/$DEPLOY --replicas=1
# recovery gate: rollout status returns ready only when the /ready probe passes (fix #6)
kubectl -n "$NS" rollout status deploy/$DEPLOY --timeout="${READY_TIMEOUT_S:-60}s"
```

Scale-to-zero gives the same graceful-SIGTERM-then-restart shape as `docker stop`/`docker start`, and the readiness probe added in §5.3 makes `rollout status` a true recovery gate (without the probe, `rollout status` would report ready as soon as the container process starts, under-counting recovery lag — the exact weakness Codex flagged).

## 8. Image build + registry — `scripts/build-images.sh`

Requirements from the user: configurable **base** registry for the Dockerfile `FROM`, configurable **target** registry for the built image refs, and **optional push** (build-and-test-locally must work with no remote).

**Dockerfile change (writer + collector), copied-local only:**

```dockerfile
ARG BASE_REGISTRY=""
FROM ${BASE_REGISTRY}golang:1.25-alpine AS build
...
ARG BASE_REGISTRY=""
FROM ${BASE_REGISTRY}alpine:3.20
```

`BASE_REGISTRY=""` reproduces today's behavior (pull `golang:1.25-alpine` from Docker Hub); `BASE_REGISTRY=corp.example.com/mirror/` redirects both base images to a corporate/airgapped mirror.

**`build-images.sh` flags:**

| Flag | Default | Effect |
|---|---|---|
| `--base-registry=REF` | `""` | passed as `--build-arg BASE_REGISTRY=` to both builds |
| `--registry=REF` | `""` | prefix for the built image tags (target registry) |
| `--tag=TAG` | `dev` | image tag |
| `--push` | off | **optional** — only pushes when set; default is build-only (fix #9 local flow) |
| `--kind` | off | `kind load docker-image` the built tags into the kind cluster (local flow) |
| `--kind-name=NAME` | `kind` | kind cluster name for `--kind` |

Default invocation `bash scripts/build-images.sh` builds `redis-rrcs/writer:dev` and `redis-rrcs/collector:dev` locally and stops. `--kind` loads them into kind (so `pullPolicy: Never` in `values-dev.yaml` works — **fix #9**). `--registry=corp.example.com/team --push` builds, retags, and pushes for other clusters.

**Two documented image flows (fix #9):**

- **kind/local:** `build-images.sh --kind`, then `helm install -f chart/values-dev.yaml` (which sets `images.pullPolicy: Never` for the locally-built writer/collector and `emptyDir` NATS). No registry needed.
- **portable/remote:** `build-images.sh --registry=<reg> --push`, then `helm install --set images.registry=<reg>/ ...` (default `values.yaml`, `pullPolicy: IfNotPresent`, real StorageClass if PVC mode).

## 9. `scripts/render.sh` — plain YAML generation

A thin `helm template` wrapper so the user can produce portable plain YAML without Tiller/Helm-in-cluster:

```
helm template rrcs ./chart \
  --namespace "${RRCS_NS:-rrcs-k8s}" \
  ${PROFILE:+--set profile=$PROFILE} \
  ${VALUES:+-f $VALUES} \
  "$@" > out/manifests.yaml
```

Prints the path and a reminder that the namespace must be created first (`kubectl create ns rrcs-k8s`) since the chart no longer templates a Namespace (fix #3). `kubectl apply -f out/manifests.yaml -n rrcs-k8s` then stands the lab up on any cluster.

## 10. Chaos config consolidation (fix #13)

The compose lab split chaos config: `chaos_at_s()` (derived from `DURATION_S`) and `CHAOS_DOWN_S` live in `tier-defs.sh`, while the collector takes `--chaos-at-s` / `--chaos-duration`. Codex flagged a parallel split forming in the chart between a `collector.chaosAtS` and a top-level `chaos.downSeconds`. Resolution: a **single `chaos:` block** in `values.yaml`:

```yaml
chaos:
  atSeconds: ""          # "" = derive from duration/2, mirroring chaos_at_s()
  downSeconds: 8
  readyTimeoutSeconds: 60
```

The harness reads these (env-overridable as today) and passes them both to the collector flags and the scale script — no duplicated source of truth.

## 11. `values.yaml` shape (summary)

```yaml
profile: alo                      # alo|amo|eoe — selects connect ConfigMap pair
images: { registry: "", pullPolicy: IfNotPresent, pullSecrets: [] }
writer:    { image: redis-rrcs/writer:dev,    env: {...verbatim from compose...} }
collector: { image: redis-rrcs/collector:dev }
connect:   { image: hpdevelop/connect:4.92.0-claudefix }
redis:     { image: redis:7.4-alpine }
nats:      { image: nats:2.10-alpine, persistence: { mode: emptyDir, size: 4Gi, storageClassName: "" } }
natsBox:   { image: natsio/nats-box:0.14.5 }
stream:    { name: APP_EVENTS, subjects: "app.events.>", maxAge: 1h, maxBytes: 256MB, maxMsgSize: 1MB, dupeWindow: 5m }
chaos:     { atSeconds: "", downSeconds: 8, readyTimeoutSeconds: 60 }
scheduling: { nodeSelector: {}, tolerations: [], affinity: {} }
resources:  { <per-workload limits+requests, defaults from §5> }
```

`values-dev.yaml` overlay: `images.pullPolicy: Never` (for the locally-built writer/collector), `nats.persistence.mode: emptyDir`.

## 12. Codex findings → resolution traceability

| # | Sev | Finding | Resolution | Spec § |
|---|---|---|---|---|
| 1 | HIGH | post-install hook + `--wait` deadlock | nats-init is a **plain Job**, gating done by initContainers | §5.2 |
| 2 | HIGH | `.Files.Glob "../connect"` can't escape chart | connect YAMLs **copied** to `chart/files/connect/` | §3, §5.3 |
| 3 | HIGH | namespace inconsistent / templated Namespace | no Namespace resource; `-n rrcs-k8s` everywhere via `$NS` | §5.5, §7 |
| 4 | HIGH | NATS calls missing `--server` URL | every `nats` call carries `--server nats://nats:4222` | §5.2, §5.3, §7 |
| 5 | HIGH | multi-line JSON + logs → unsound `kubectl logs` parse | collector `--out=-` emits one `RESULT_JSON:` compact line; exit 0 on report so verdict travels in JSON, not exit code (stop-time fix) | §6 |
| 6 | HIGH | chaos recovery gate weak (no readiness probes) | readiness+liveness probes on connect-src/sink/writer; `rollout status` becomes a real gate | §5.3, §5.4, §7.1 |
| 7 | MED | collector Job lifecycle race | unique per-run name; `restartPolicy: Never`/`backoffLimit: 0` (no non-hermetic re-runs); three-state PASS/FAIL/ERROR; delete --wait + ttl backstop (stop-time fix) | §6 |
| 8 | MED | orphaned background chaos PID | single `trap EXIT INT TERM`, all PIDs (PFs + chaos) tracked | §7 step 6 |
| 9 | MED | image story implicitly local | two documented flows; `values-dev.yaml` Never + `--kind` load | §8 |
| 10 | MED | limits-only resources | `requests` added to every workload | §4, §5 |
| 11 | MED | NATS PVC stalls without default StorageClass | `nats.persistence.mode emptyDir|pvc` (`memory` mode cut as incoherent, stop-time fix); storageClassName only emitted when set; default emptyDir | §5.1 |
| 12 | LOW | per-image + per-component knobs over-built | scheduling is **global-only**; per-image *tags* kept (needed) + registry kept (user-required) | §5.6 |
| 13 | LOW | chaos params split across blocks | single `chaos:` block in values | §10 |

## 13. Non-goals / YAGNI

- No change to pipeline behavior, tiers, SLOs, QoS semantics, Bloblang mappings, or collector measurement math (only the `--out=-` output mode + its exit-code semantics are added).
- No memory-backed JetStream (`--storage memory`). The stream stays `--storage file` to match the source lab; the cut `memory` persistence mode is not re-introduced as a stream-storage knob in this fork.
- No per-component scheduling overrides, no per-component resource overrides beyond the shared block (fix #12 — add on demand).
- No Ingress / LoadBalancer / NetworkPolicy — `kubectl port-forward` is the access path, matching the lab's local-host orientation.
- No HPA, no multi-replica Connect, no sink sharding — this lab keeps the single-replica identity of the source.
- No operator, no Kustomize variant — Helm chart + `render.sh` plain YAML is the whole surface.
- No CI wiring; the lab is run by hand like the compose lab.
- The compose lab is **not** modified or removed.

## 14. /research-lab compliance

The forked lab preserves the `/research-lab` output contract:

- `RESEARCH.md` — carried forward + a "Kubernetes fork rationale" section.
- `README.md` — rewritten for the kubectl/Helm workflow (boot, render, build-images flows, knobs table).
- Design spec — this document.
- Implementation plan — produced next via `superpowers:writing-plans`.
- Working stack — the Helm chart (vs. the compose file).
- Writer / collector services — carried forward (collector gains `--out=-`).
- `scripts/stress-run.sh` — kubectl edition, same CLI + tier-defs.
- `reports/*.json` — regenerated by running the matrix against the cluster.
- Verdict gating — unchanged structure.
```
