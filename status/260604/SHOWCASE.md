# Showcase — Redis ⇄ Redpanda Connect Lab on Kubernetes + CVE Hardening

**Date:** 2026-06-04
**Scope:** Local `kind` deployment of the `redis-redpanda-connect-stress-k8s` (rrcs-k8s) lab + a hardened `redpandadata/connect` image used inside it.
**Diagram bundle:** [`SHOWCASE.drawio`](./SHOWCASE.drawio) — two pages (`Kind Lab — Components & Data Flow`, `CVE Fix — Redpanda Connect`).

---

## 1. Lab deployment — `kind` end-to-end

### Stack

| Layer | Component | Image / Version |
|---|---|---|
| Cluster | kind (single-node, control-plane) | `kindest/node:v1.35.0` |
| Helm release | `rrcs` in namespace `rrcs-k8s` | chart `./labs/redis-redpanda-connect-stress-k8s/chart`, revision 2 |
| Profile | QoS profile | `alo` (at-least-once) |
| Resource prefix | every chart-rendered K8s name | `lab-` (configurable via `resourcePrefix`) |
| Persistence | NATS JetStream | `emptyDir` (kind / dev) |
| Load generator | `lab-writer` (Go, `:8081`) | locally built `redis-rrcs/writer:dev`, side-loaded into kind |
| Pipeline | `lab-connect-source` + `lab-connect-sink` | **`hpdevelop/connect:4.92.0-claudefix`** (see §3) |
| Broker | `lab-nats` JetStream | `nats:2.10.x` (upstream image) |
| Stores | `lab-redis-central`, `lab-redis-region` | `redis:7.x` |
| Bootstrap | `lab-nats-init` Job | `natsio/nats-box:0.14.5` |
| Verdict harness | `lab-collector` Job (per cell) | locally built `redis-rrcs/collector:dev` |

### Live deployment state

```
NAME                                      READY   STATUS      RESTARTS   AGE
pod/lab-connect-sink-847fdbc654-kkjmx     1/1     Running     0          2m38s
pod/lab-connect-source-5db88bf57f-x2g4p   1/1     Running     0          2m38s
pod/lab-nats-7f6dc5c94c-fwgbz             1/1     Running     0          2m38s
pod/lab-nats-init-ad0d4b26-vr8jq          0/1     Completed   0          2m38s
pod/lab-redis-central-75bd46bc74-9c5fw    1/1     Running     0          2m38s
pod/lab-redis-region-5b7665cc75-7rh4d     1/1     Running     0          2m38s
pod/lab-writer-75d6c865dc-z7vsh           1/1     Running     0          2m38s

job.batch/lab-nats-init-ad0d4b26           Complete   1/1   25s   2m38s
```

All 6 long-running pods `Running`; bootstrap Job `Complete`. See diagram page **Kind Lab — Components & Data Flow**.

### Verdict — tier=10 / throughput / alo

| Tier | Mode | Rate achieved | Missing | Trimmed | p99 (ms) | SLO p99 | Verdict |
|---|---|---|---|---|---|---|---|
| 10 | throughput | **9.9 / 10** | 0 | 0 | **129.3** | 200 | **PASS** |

Verdict JSON (excerpt, `reports/10-throughput-alo.json`):

```json
{
  "tier": 10, "mode": "throughput", "profile": "alo",
  "duration_s": 30, "rate_target": 10, "rate_achieved_avg": 9.862,
  "sent": 327, "received": 327, "missing": 0,
  "latency_ms": {"p50": 1.092, "p95": 1.62, "p99": 129.279, "max": 729.599},
  "redis": {"central_xlen_max": 327, "region_xlen_final": 327},
  "nats": {"pending_max": 0, "bytes": 193692},
  "slo": {"rate_min_pct": 0.95, "latency_p99_ms": 200, "allow_missing": false},
  "verdict": {"pass": true, "checks": {"missing_ok": true, "rate_ok": true}}
}
```

### Bring-up bug caught & fixed during this run

The collector Job template (`chart/templates/collector-job.yaml`) did **not** pass a `--writer` flag, so the collector fell back to its compiled-in default `http://writer:8081` instead of `http://lab-writer:8081`. With `resourcePrefix=lab-` the DNS lookup failed (`writer:8081` is unresolvable inside `rrcs-k8s`), so every cell reported `MISSING/ERROR`.

**Fix:**

```diff
   args:
     - --tier={{ .Values.collector.tier }}
     ...
+    - --writer=http://{{ include "rrcs.name" (dict "root" $ "base" "writer") }}:8081
     - --nats-stream={{ .Values.nats.stream.name }}
     - --nats={{ include "rrcs.nats.monitorUrl" . }}
```

After the fix → tier=10/throughput → PASS, confirming the chart is `resourcePrefix`-clean end-to-end.

---

## 2. Data flow (what each cell actually exercises)

```
lab-writer ──XADD app.events──▶ lab-redis-central
                                      │ XREAD
                                      ▼
                              lab-connect-source ──publish app.events.*──▶ lab-nats (JetStream APP_EVENTS)
                                                                                  │ deliver (durable: region-writer)
                                                                                  ▼
                                                                          lab-connect-sink ──XADD──▶ lab-redis-region
```

The `lab-collector` Job (one per `tier × mode × profile` cell) probes the live system from outside the data path:

- **writer** — `POST /reset` (zero counters), `GET /metrics` (rate achieved)
- **redis-central / redis-region** — `XLEN`, `XRANGE` for sample diffing
- **NATS** — `GET /jsz` monitor port for stream depth & ack state

Verdict is emitted as a single `RESULT_JSON: { ... }` stdout line; `scripts/stress-run.sh` extracts it via `kubectl logs`.

---

## 3. CVE fix — Redpanda Connect base image

See diagram page **CVE Fix — Redpanda Connect**.

### Before / after (trivy 0.52.2, severity `CRITICAL,HIGH`)

| Image | Tag preserved as | CRITICAL | HIGH |
|---|---|---:|---:|
| `redpandadata/connect:4.45.1` (stock) | `hpdevelop/connect:4.45.1-orig` | **4** | **26** |
| Hardened rebuild (this work) | **`hpdevelop/connect:4.92.0-claudefix`** | **0** | **3** |

**Approach:** rebase the stock 4.45.1 stable image onto the upstream 4.92.0 edge build (`public.ecr.aws/l9j0i2e0/connect:edge-amd64`). The edge tag carries a refreshed Go stdlib, updated `grpc-go`/`pgx`, and drops the bundled `ollama` runtime — together closing all 4 criticals in a single base-image bump.

### Critical CVEs closed

| CVE | Component | Installed → Fixed | Description |
|---|---|---|---|
| **CVE-2026-33816** | `github.com/jackc/pgx/v5` | v5.6.0 → v5.9.0 | Memory-safety vulnerability in PostgreSQL driver |
| **CVE-2025-63389** | `github.com/ollama/ollama` | v0.5.4 (runtime removed) | Missing authentication on model-management endpoints |
| **CVE-2026-33186** | `google.golang.org/grpc` | v1.68.0 → v1.79.3 | Authorization bypass via improper HTTP/2 path validation |
| **CVE-2025-68121** | Go `crypto/tls` (stdlib) | go1.23.5 → ≥go1.24.13 | Incorrect certificate validation during TLS session resumption |

### Residual HIGH (3 — upstream Connect not yet rebased)

| CVE | Component | Installed → Fixed |
|---|---|---|
| CVE-2026-41602 | `github.com/apache/thrift` | v0.22.0 → 0.23.0 |
| CVE-2026-44973 | `github.com/go-git/go-billy/v5` | v5.8.0 → 5.9.0 |
| CVE-2026-45022 | `github.com/go-git/go-git/v5` | v5.18.0 → 5.19.0 |

These three are vendored Go libraries inside the upstream Redpanda Connect binary; we cannot patch them without forking the upstream go module set. Tracked for a follow-up rebuild once upstream cuts a release on top of the patched libs.

### Runtime verification

The hardened tag is **the one actually deployed** in the kind lab above:

```
$ kubectl get pods -n rrcs-k8s -o jsonpath='{.items[?(@.metadata.labels.app=="connect-source")].spec.containers[*].image}'
hpdevelop/connect:4.92.0-claudefix

$ kubectl get pods -n rrcs-k8s -o jsonpath='{.items[?(@.metadata.labels.app=="connect-sink")].spec.containers[*].image}'
hpdevelop/connect:4.92.0-claudefix
```

The PASS verdict in §1 — sent=327, received=327, missing=0 over a 30 s window — is the integration test that proves the rebased image still drives the Redis ⇄ Connect ⇄ NATS pipeline correctly. Per the `image-fixer` skill's acceptance criteria:

- ✅ image is runnable
- ✅ no remaining CRITICAL CVEs
- ✅ tagged `hpdevelop/REPO_NAME:VERSION-claudefix`

---

## 4. Reproduce

```bash
cd labs/redis-redpanda-connect-stress-k8s

# Fresh cluster
kind create cluster --name rrcs

# Build + side-load writer/collector images
scripts/build-images.sh --kind --kind-name=rrcs

# Boot chart + run one cell (tier=10 throughput); harness keeps release up
scripts/stress-run.sh --tiers=10 --modes=throughput --profile=alo

# Inspect
kubectl get pods,jobs -n rrcs-k8s
cat reports/10-throughput-alo.json | jq

# Tear down
helm uninstall rrcs -n rrcs-k8s
kind delete cluster --name rrcs
```

---

## 5. Status snapshot

| Track | State |
|---|---|
| `rrcs-k8s` chart on kind | ✅ deployed, all pods Running, tier=10 throughput PASS |
| `resourcePrefix` end-to-end | ✅ verified (collector Job fix landed during this session) |
| Redpanda Connect CVE hardening | ✅ 4 CRITICAL → 0; image runnable and shipping in the lab |
| Outstanding | 3 HIGH in vendored Go libs (upstream Connect rebase pending); larger tiers (1000 / 10000) and chaos/latency modes not yet replayed on the hardened image |
