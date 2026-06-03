# Configurable Resource Name Prefix — Design

**Lab:** `labs/redis-redpanda-connect-stress-k8s/`
**Date:** 2026-06-03
**Status:** design

---

## 1. Goal

Every Kubernetes resource the chart renders gets a configurable name prefix, default `lab-`. A single values key — `resourcePrefix` — feeds every `metadata.name`, every cross-template reference, and the harness scripts that drive the chart, so the deployed cluster state stays internally consistent.

**Motivation.** A shared cluster may host multiple lab installs side-by-side, or a non-lab namespace may already own a `Service/nats` or `Deployment/writer`. Prefixed names make collisions obvious at install time and let a single namespace host parallel installs with different prefixes.

**Non-goals:**
- Renaming pod labels or Service selectors. The user spec is "all resource deployed must have a prefix in **name**" — labels are not names. Selectors continue to use the existing `app: <component>` labels, which keeps the Service-to-Pod binding stable without forcing a chart-wide label rewrite.
- Length/charset validation of operator-chosen prefixes. K8s + Helm already reject invalid names with clear errors; adding a custom validator duplicates that signal.
- A migration path for live clusters. Renaming a K8s resource is not in-place — uninstall + reinstall is the only supported path, which is already how this lab is operated.
- Prefixing user-supplied external-mode Secret names (`nats.external.auth.publisherSecret`, etc.). Those are operator-controlled identities; the chart references them by exact name and must not mangle them.

## 2. Configuration surface

New top-level values key:

```yaml
# chart/values.yaml
resourcePrefix: "lab-"  # prepended to every chart-rendered Kubernetes resource
                        # name (Deployments, StatefulSets, Services, ConfigMaps,
                        # Secrets, Jobs, PVCs). Empty string disables prefixing
                        # for back-compat with any existing values overrides
                        # that reference the unprefixed names.
```

Semantics:

- `resourcePrefix: "lab-"` (default) → every chart-rendered resource gets `lab-` prepended.
- `resourcePrefix: ""` → no-op; rendered names match the pre-change behavior exactly. This is the back-compat escape hatch.
- `resourcePrefix: "tenant-a-"` → `tenant-a-writer`, `tenant-a-nats`, etc.

### 2.1 Length budget (corrected)

Three classes of rendered name have different effective budgets against the K8s DNS-1123 label limit (63 chars):

| Class | Longest base seen today | Pod suffix overhead | Effective budget for `prefix + base` |
|---|---|---|---|
| ConfigMap / Secret / Service / Deployment | `connect-source-config` (20) | — | 63 |
| StatefulSet (`nats` → pod `nats-0`) | `nats` (4) | `-0` (2) | 61 |
| Static Job (`nats-init-<8hex>`) | `nats-init-<8>` (18) | `-<5>` (6) | 57 |
| **Harness-generated collector Job** | **`collector-10000-throughput-alo-1234567890` (41)** | `-<5>` (6) | **57** |

The collector Job is the binding constraint, not `connect-source-config`. The harness builds its name as `collector-${tier}-${mode}-${PROFILE}-$(date +%s)` (`scripts/stress-run.sh:167`), so the Job-name base can be 41 chars under current tiers/modes/profiles.

**Default `lab-` (4 chars):** `lab-` + 41 = 45; pod 51 — comfortable headroom.

**Custom prefix headroom for the collector Job:** 57 − 41 = 16 chars. A prefix longer than 16 chars combined with the longest harness-generated Job name will produce a pod name that exceeds the 63-char DNS-1123 limit. The K8s Job controller surfaces this as `Failed create pod: name length must be no more than 63 characters`, which is the right failure to inherit — but the chart should *also* fail-loud at `helm template` time so the operator catches it before applying.

### 2.2 Render-time fail-loud guard

`chart/templates/collector-job.yaml` rejects names that would not leave room for the Pod's 6-char random suffix:

```gotemplate
{{- $name := include "rrcs.name" (dict "root" $ "base" (default (printf "collector-%v-%s-%s" .Values.collector.tier .Values.collector.mode .Values.profile) .Values.collector.jobName)) -}}
{{- if gt (len $name) 57 -}}
{{- fail (printf "collector Job name %q (%d chars) exceeds the 57-char budget (63 DNS-1123 limit minus the 6-char Pod random suffix). Shorten resourcePrefix (currently %q) or collector.jobName." $name (len $name) .Values.resourcePrefix) -}}
{{- end -}}
```

Equivalent guards are not needed on the other Job (`nats-init`) — its name is `nats-init-<8hex>` = 18 chars, and `lab-` + 18 = 22 → pod 28, leaving 35 chars of prefix headroom; no realistic prefix exhausts that. Document the budget for `nats-init` in the spec for completeness; do not add a redundant guard.

### 2.3 README budget documentation

The README knob row for `resourcePrefix` states:

> Default `lab-`. Total rendered name + Pod suffix must stay under the K8s DNS-1123 64-char label limit. The collector Job is the binding case: a custom prefix combined with the harness-generated `collector-<tier>-<mode>-<profile>-<unix-ts>` Job base (up to 41 chars today) leaves ~16 chars for the prefix. `helm template` fails loud if you exceed this.

## 3. The `rrcs.name` helper

New helper in `chart/templates/_helpers.tpl`:

```gotemplate
{{/*
rrcs.name — prepend resourcePrefix to a base name. Single source of truth
for every chart-rendered Kubernetes resource name. Pass an empty prefix to
opt out and render today's unprefixed names.
Usage: {{ include "rrcs.name" (dict "root" $ "base" "writer") }}
*/}}
{{- define "rrcs.name" -}}
{{- printf "%s%s" .root.Values.resourcePrefix .base -}}
{{- end -}}
```

The helper is the only place the prefix concatenation lives. Templates, URL helpers, and Secret-name helpers all funnel through it.

## 4. Templates touched

**`metadata.name` substitutions** — every chart-rendered resource:

| File | Resources renamed |
|---|---|
| `chart/templates/writer.yaml` | Deployment `writer`, Service `writer` |
| `chart/templates/connect-source.yaml` | Deployment `connect-source`, Service `connect-source` |
| `chart/templates/connect-sink.yaml` | Deployment `connect-sink`, Service `connect-sink` |
| `chart/templates/redis-central.yaml` | Deployment `redis-central`, Service `redis-central` |
| `chart/templates/redis-region.yaml` | Deployment `redis-region`, Service `redis-region` |
| `chart/templates/nats.yaml` | StatefulSet `nats`, Service `nats`, optional PVC base `nats-data` |
| `chart/templates/nats-config-cm.yaml` | ConfigMap `nats-config` |
| `chart/templates/connect-configmaps.yaml` | ConfigMaps `connect-source-config`, `connect-sink-config` |
| `chart/templates/nats-auth-secrets.yaml` | Three Secrets (via `rrcs.nats.credsSecret.*` — see §5) |
| `chart/templates/nats-init-job.yaml` | Job `nats-init-<hash>` |
| `chart/templates/collector-job.yaml` | Job (default name `collector-<tier>-<mode>-<profile>`). The chart applies `rrcs.name` over `.Values.collector.jobName` too — so an operator-supplied custom `jobName` is also prefixed, and the harness does not need to compose the prefix itself when it sets `jobName`. |

**Internal references** — every place a template names a service that lives elsewhere:

- Volume sources: `configMap.name: connect-source-config` / `connect-sink-config` / `nats-config` → all routed through `rrcs.name`.
- Service-name references inside `until ... ; do sleep 1; done` init-container scripts (writer waits on `redis-central`, `connect-source`; connect-source waits on `redis-central`; connect-sink waits on `redis-region`, JetStream stream readiness; nats-init waits on `nats`).
- Writer env `REDIS_ADDR` (uses `rrcs.redis.central.hostPort` — see §5).
- Collector flags `--nats=`, `--redis-central=`, `--redis-region=` (use `rrcs.nats.monitorUrl` and the redis host:port helpers — see §5).

## 5. URL and Secret-name helpers updated

The existing helpers in `_helpers.tpl` already centralize the bundled-vs-external split. They now call `rrcs.name` for the service-DNS segment in bundled mode:

| Helper | Before | After (bundled mode only) |
|---|---|---|
| `rrcs.nats.url` | `nats://nats:4222` | `nats://<prefix>nats:<port>` |
| `rrcs.nats.monitorUrl` | `http://nats:8222` | `http://<prefix>nats:<port>` |
| `rrcs.redis.central.url` | `redis://redis-central:6379` | `redis://<prefix>redis-central:6379` |
| `rrcs.redis.region.url` | `redis://redis-region:6379` | `redis://<prefix>redis-region:6379` |
| `rrcs.redis.central.hostPort` | `redis-central:6379` | `<prefix>redis-central:6379` |
| `rrcs.redis.region.hostPort` | `redis-region:6379` | `<prefix>redis-region:6379` |
| `rrcs.nats.credsSecret.publisher` | `.Values.nats.auth.secrets.publisher` (e.g. `publisher-creds`) | `<prefix><publisher-creds>` |
| `rrcs.nats.credsSecret.subscriber` | `.Values.nats.auth.secrets.subscriber` | `<prefix><subscriber-creds>` |
| `rrcs.nats.credsSecret.admin` | `.Values.nats.auth.secrets.admin` | `<prefix><admin-creds>` |

**Empty-base guard.** `rrcs.nats.credsSecret.admin` already allows an empty value in external mode (admin Secret is optional — the harness skips purge with a warning). The helper must not apply `rrcs.name` to an empty base, which would produce just the bare prefix `lab-`. Implementation: `rrcs.name` returns the empty string when the base is empty, regardless of prefix. Equivalent guard for any future optional Secret/URL helper that may return empty.

**External-mode branches are unchanged.** When `nats.external.enabled=true`, `rrcs.nats.url` returns the operator-supplied URL verbatim; same for redis URLs and external Secret names. The prefix is a bundled-mode concept only.

The Secret-name composition is the design choice the user picked: `nats.auth.secrets.publisher` defaults stay as the base name `publisher-creds`. The helper composes `<prefix><base>` at template-consumption time. An override like `nats.auth.secrets.publisher: foo` deploys as Secret `<prefix>foo`.

## 6. Harness adaptation

The harness scripts call `kubectl` with resource names hardcoded today. After the rename, they must learn the prefix.

**`scripts/stress-run.sh`** — already parses `HELM_VALUES_JSON` for `nats.stream.name`, `nats.external.url`, etc. Extend the same path:

```bash
RESOURCE_PREFIX="$(echo "$HELM_VALUES_JSON" | jq -r '.resourcePrefix // "lab-"')"
export RESOURCE_PREFIX
```

Use `${RESOURCE_PREFIX}` to build every kubectl target:

| Today (literal) | After |
|---|---|
| `svc/nats` (in `port-forward`) | `svc/${RESOURCE_PREFIX}nats` |
| `nats://nats:4222` (default NATS_URL fallback) | `nats://${RESOURCE_PREFIX}nats:4222` |
| `admin-creds` (default admin secret) | `${RESOURCE_PREFIX}admin-creds` |
| `nats-purge-<ts>` (temporary purge pod) | `${RESOURCE_PREFIX}nats-purge-<ts>` |
| `job/${job}` | The chart already applies `rrcs.name` over `collector.jobName` (see §4). The harness still sets `--set collector.jobName=<base>` (unprefixed base) and references `job/${RESOURCE_PREFIX}<base>` when calling `kubectl wait` / `kubectl logs` / `kubectl delete`. |

**`scripts/chaos/scale-connect-sink.sh`** — single hardcoded `DEPLOY=connect-sink`. Change to:

```bash
DEPLOY="${RESOURCE_PREFIX:-lab-}connect-sink"
```

The `${RESOURCE_PREFIX:-lab-}` default mirrors the chart default, so the script still works when invoked directly (not via `stress-run.sh`).

**`scripts/render.sh`** — no change; it only runs `helm template`.

**`scripts/gen-nats-auth.sh`** — no change; it mints NATS auth identities and writes fixture files. It does not touch any K8s resources by name.

## 7. External-mode behavior

When `nats.external.enabled=true`:
- The chart skips `nats.yaml`, `nats-config-cm.yaml`, `nats-auth-secrets.yaml`, `nats-init-job.yaml` (existing behavior).
- `rrcs.nats.url` and `rrcs.nats.monitorUrl` return the operator-supplied URLs unchanged.
- `rrcs.nats.credsSecret.{publisher,subscriber,admin}` returns the operator-supplied Secret name unchanged.
- The harness uses `NATS_URL` from values (or its fallback `nats://${RESOURCE_PREFIX}nats:4222` if external is off).

When `redis.{central,region}.external.enabled=true`:
- The chart skips `redis-central.yaml` / `redis-region.yaml`.
- Redis URL/hostPort helpers return the operator-supplied URL unchanged.
- The prefix is invisible to the operator on this code path.

In short: the prefix only affects chart-rendered resources. External-supplied names always win.

## 8. Labels and selectors — unchanged

Pod labels (`app: writer`, `app: connect-source`, etc.) and the Service `spec.selector` they pair with stay as-is. Renaming labels would force a chart-wide rewrite of selectors with no functional gain. The user spec is "all resource deployed must have a prefix in **name**" — `metadata.labels` is not a name.

## 9. Validation plan

1. `helm lint chart/` — clean.
2. `helm template rrcs ./chart -n rrcs-k8s` with **default** `resourcePrefix=lab-`:
   - Every `metadata.name` is prefixed.
   - Every URL helper, every volume reference, every init-container script, every collector flag references the prefixed name.
   - Render is internally consistent: no `nats://nats:4222` survives next to a `Service/lab-nats`.
3. `helm template ... --set resourcePrefix=""`:
   - Renders byte-identical to pre-change `master` for the touched paths (back-compat).
4. `helm template ... --set resourcePrefix=tenant-a-`:
   - Same as (2) but with the alternate prefix; spot-check that the URL helpers and Secret helpers also flipped.
5. `helm template ... --set nats.external.enabled=true --set nats.external.url=nats://foo:4222 --set nats.external.auth.publisherSecret=my-creds --set nats.external.auth.subscriberSecret=my-creds`:
   - `rrcs.nats.url` returns `nats://foo:4222` (NOT `nats://lab-foo:4222`).
   - The Secret reference is `my-creds` (NOT `lab-my-creds`).
6. `bash -n scripts/stress-run.sh` and `bash -n scripts/chaos/scale-connect-sink.sh`.
7. Diff `helm template` output (default `lab-`) against pre-change `master`:
   - The only differences are the expected name and reference substitutions.

8. `helm template ... --set resourcePrefix=this-is-a-long-prefix-` (>16 chars) with a representative `collector.jobName=collector-10000-throughput-alo-1234567890`:
   - Render **must** fail with the §2.2 guard message naming the over-budget Job and the rendered length.

A full kind e2e is **not** part of this change's validation because the chart structure is unchanged — only string substitution. If the renders pass the consistency check, the cluster behavior is unchanged.

## 10. Files changed

- `chart/values.yaml` — add `resourcePrefix: "lab-"`.
- `chart/templates/_helpers.tpl` — add `rrcs.name`; update `rrcs.nats.url`, `rrcs.nats.monitorUrl`, `rrcs.redis.central.url`, `rrcs.redis.region.url`, `rrcs.redis.central.hostPort`, `rrcs.redis.region.hostPort`, `rrcs.nats.credsSecret.{publisher,subscriber,admin}`.
- `chart/templates/writer.yaml`, `connect-source.yaml`, `connect-sink.yaml`, `redis-central.yaml`, `redis-region.yaml`, `nats.yaml`, `nats-config-cm.yaml`, `connect-configmaps.yaml`, `nats-auth-secrets.yaml`, `nats-init-job.yaml`, `collector-job.yaml` — every `metadata.name`, every cross-reference (volume `configMap.name`, `secret.secretName`, init-container service-name pings).
- `scripts/stress-run.sh` — parse `resourcePrefix`, export `RESOURCE_PREFIX`, use it in port-forward, default NATS URL, default admin Secret, purge pod name, collector job name construction.
- `scripts/chaos/scale-connect-sink.sh` — read `RESOURCE_PREFIX` env with `lab-` default.
- `README.md` — knob row for `resourcePrefix` (default, semantics, length budget, opt-out via empty string).
- `chart/files/nats-auth/README.md` and `values-external.yaml.example` — short notes that the prefix only affects bundled-mode chart-rendered Secret names; user-supplied external Secret names are untouched.

## 11. Out of scope (deferred)

- Automatic truncation of over-budget names. The §2.2 render-time guard fails loudly with the rendered length and the offending Job name; the operator picks a shorter prefix. The chart never mutates operator input.
- A second knob to rename labels — no use case.
- Per-component prefix overrides (`writer.resourcePrefix: ...`) — YAGNI.
- A Helm `fullname` helper that combines `.Release.Name + resourcePrefix + base` — the user asked for a literal `lab-` default, not a release-derived name. Adding `.Release.Name` would change the rename semantics and is not what was requested.
- Renaming the Helm release itself (`helm install rrcs ...`) — out of scope; the prefix is on resource names, not the release name.
