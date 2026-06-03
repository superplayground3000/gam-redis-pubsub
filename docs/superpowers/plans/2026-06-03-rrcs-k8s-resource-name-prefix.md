# rrcs-k8s Resource Name Prefix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `resourcePrefix: "lab-"` values key that prepends to every chart-rendered Kubernetes resource name in `labs/redis-redpanda-connect-stress-k8s/`, plus the harness scripts that drive them, so the lab can be installed multiple times in one namespace without name collisions.

**Architecture:** A single new top-level values key drives a new `rrcs.name` helper. The helper is the single source of truth for prefix concatenation — invoked from every `metadata.name`, every cross-reference, and every URL/Secret-name helper. Empty string is a no-op (back-compat). A render-time `fail` guard in the collector Job catches over-budget rendered names before they hit Kubernetes Pod admission. Harness scripts read the prefix from `HELM_VALUES_JSON` (consistent with existing pattern) and propagate it to subscripts via env var.

**Tech Stack:** Helm 3 (Go templating), bash, jq, kubectl. No code-level dependencies.

**Spec:** `docs/superpowers/specs/2026-06-03-rrcs-k8s-resource-name-prefix-design.md`

**Lab root for every step:** `/media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s/`. All `helm` / `git` commands below assume the shell's CWD is that directory unless stated otherwise.

---

## Task 1: Add `resourcePrefix` values key + `rrcs.name` helper

**Files:**
- Modify: `chart/values.yaml`
- Modify: `chart/templates/_helpers.tpl`

Foundation. No consumers yet. Validation is structural (`helm lint`) plus a one-shot template render that exercises `rrcs.name` through a hand-written invocation.

- [ ] **Step 1: Capture current `helm lint` baseline**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
helm lint ./chart
```

Expected: `1 chart(s) linted, 0 chart(s) failed` (one INFO about chart icon is acceptable).

- [ ] **Step 2: Add `resourcePrefix` to `chart/values.yaml`**

Insert after line 2 (immediately after the `profile:` line, before the comment block that begins `# The chart does NOT template a Namespace`):

```yaml
# Prepended to every chart-rendered Kubernetes resource name (this chart
# renders: Deployments, Services, ConfigMaps, Secrets, Jobs, and one
# optional PVC). Empty string disables prefixing for back-compat with
# any existing values overrides that reference the unprefixed names.
#
# Length budget: see docs/superpowers/specs/2026-06-03-rrcs-k8s-resource-name-prefix-design.md §2.1.
# Binding case is the harness-generated collector Job
# (collector-<tier>-<mode>-<profile>-<unix-ts>, up to 41 chars): default
# "lab-" leaves ~16 chars of headroom for any custom prefix. The
# collector-Job template fails loud at render time if you exceed this.
resourcePrefix: "lab-"
```

- [ ] **Step 3: Add `rrcs.name` helper to `chart/templates/_helpers.tpl`**

Append to the very end of the file:

```gotemplate

{{/*
rrcs.name — prepend resourcePrefix to a base name. Single source of truth
for every chart-rendered Kubernetes resource name. Returns the empty
string when the base is empty, so optional Secret/URL helpers that may
yield "" do not collapse to the bare prefix.
Usage: {{ include "rrcs.name" (dict "root" $ "base" "writer") }}
*/}}
{{- define "rrcs.name" -}}
{{- if eq .base "" -}}
{{- else -}}
{{- printf "%s%s" .root.Values.resourcePrefix .base -}}
{{- end -}}
{{- end -}}
```

- [ ] **Step 4: Verify `helm lint` still passes**

```bash
helm lint ./chart
```

Expected: `1 chart(s) linted, 0 chart(s) failed`.

- [ ] **Step 5: Smoke-test the helper renders the prefix**

```bash
helm template rrcs ./chart -n rrcs-k8s --set 'images.registry=' \
  --set 'extraTestAnnotation=ignored' 2>&1 | head -3
```

That just confirms the chart still renders. Now exercise the helper directly via a one-off probe:

```bash
cat > /tmp/probe-rrcs-name.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "rrcs.name" (dict "root" $ "base" "probe") }}
EOF
helm template rrcs ./chart -n rrcs-k8s --show-only templates/writer.yaml >/dev/null 2>&1
echo '--- probe ---'
echo "{{- printf \"%s%s\" .Values.resourcePrefix \"probe\" -}}" | \
  helm template rrcs ./chart -n rrcs-k8s --debug 2>&1 | grep -q 'rendered manifests:' && echo "render OK"
```

Expected: `render OK` (the chart still renders end-to-end with the helper present but unused).

Simpler alternative if the above is awkward: just verify `helm template` succeeds and grep the resulting output does NOT contain the literal `<no value>` (which would indicate a missing values reference):

```bash
helm template rrcs ./chart -n rrcs-k8s 2>&1 | grep -F '<no value>' && echo "FAIL: missing value" || echo "render OK"
```

Expected: `render OK`.

- [ ] **Step 6: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-connect-stress-k8s/chart/values.yaml \
        labs/redis-redpanda-connect-stress-k8s/chart/templates/_helpers.tpl
git commit -m "$(cat <<'EOF'
rrcs-k8s: add resourcePrefix values key + rrcs.name helper (no consumers)

Foundation for the configurable-name-prefix work. Adds resourcePrefix
(default "lab-") to chart/values.yaml and a single rrcs.name helper to
_helpers.tpl. Empty-base short-circuit makes the helper safe to call
with optional Secret/URL values that may render to "".

No template or helper consumers yet — subsequent commits wire it in.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Route URL + Secret helpers through `rrcs.name`

**Files:**
- Modify: `chart/templates/_helpers.tpl`

Updates `rrcs.nats.url`, `rrcs.nats.monitorUrl`, `rrcs.redis.central.url`, `rrcs.redis.region.url`, `rrcs.redis.central.hostPort`, `rrcs.redis.region.hostPort`, and `rrcs.nats.credsSecret.{publisher,subscriber,admin}` so bundled-mode references prefix automatically. External branches stay verbatim.

- [ ] **Step 1: Capture pre-change rendered URLs as the failing assertion**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
helm template rrcs ./chart -n rrcs-k8s 2>&1 | \
  grep -E 'nats://nats:|http://nats:|redis://redis-(central|region):|secretName: (publisher|subscriber|admin)-creds' | sort -u
```

Expected (pre-change): output includes `nats://nats:4222`, `http://nats:8222` (if monitorUrl is exercised), `redis://redis-central:6379`, `redis://redis-region:6379`, and Secret references `publisher-creds`, `subscriber-creds`, `admin-creds`. This is the "before" snapshot; record it mentally — after the change none of these unprefixed forms should appear.

- [ ] **Step 2: Update bundled-mode branch of `rrcs.nats.url`**

In `chart/templates/_helpers.tpl`, replace:

```gotemplate
{{- define "rrcs.nats.url" -}}
{{- if .Values.nats.external.enabled -}}
{{- required "nats.external.url is required when nats.external.enabled=true" .Values.nats.external.url -}}
{{- else -}}
nats://nats:{{ .Values.nats.clientPort }}
{{- end -}}
{{- end -}}
```

with:

```gotemplate
{{- define "rrcs.nats.url" -}}
{{- if .Values.nats.external.enabled -}}
{{- required "nats.external.url is required when nats.external.enabled=true" .Values.nats.external.url -}}
{{- else -}}
{{- printf "nats://%s:%v" (include "rrcs.name" (dict "root" $ "base" "nats")) .Values.nats.clientPort -}}
{{- end -}}
{{- end -}}
```

- [ ] **Step 3: Update bundled-mode branch of `rrcs.nats.monitorUrl`**

Replace:

```gotemplate
{{- define "rrcs.nats.monitorUrl" -}}
{{- if .Values.nats.external.enabled -}}
{{- .Values.nats.external.monitorUrl -}}
{{- else -}}
http://nats:{{ .Values.nats.monitorPort }}
{{- end -}}
{{- end -}}
```

with:

```gotemplate
{{- define "rrcs.nats.monitorUrl" -}}
{{- if .Values.nats.external.enabled -}}
{{- .Values.nats.external.monitorUrl -}}
{{- else -}}
{{- printf "http://%s:%v" (include "rrcs.name" (dict "root" $ "base" "nats")) .Values.nats.monitorPort -}}
{{- end -}}
{{- end -}}
```

- [ ] **Step 4: Update bundled-mode branches of redis URL helpers**

Replace:

```gotemplate
{{- define "rrcs.redis.central.url" -}}
{{- if .Values.redis.central.external.enabled -}}
{{- required "redis.central.external.url is required when enabled" .Values.redis.central.external.url -}}
{{- else -}}
redis://redis-central:6379
{{- end -}}
{{- end -}}

{{- define "rrcs.redis.region.url" -}}
{{- if .Values.redis.region.external.enabled -}}
{{- required "redis.region.external.url is required when enabled" .Values.redis.region.external.url -}}
{{- else -}}
redis://redis-region:6379
{{- end -}}
{{- end -}}
```

with:

```gotemplate
{{- define "rrcs.redis.central.url" -}}
{{- if .Values.redis.central.external.enabled -}}
{{- required "redis.central.external.url is required when enabled" .Values.redis.central.external.url -}}
{{- else -}}
{{- printf "redis://%s:6379" (include "rrcs.name" (dict "root" $ "base" "redis-central")) -}}
{{- end -}}
{{- end -}}

{{- define "rrcs.redis.region.url" -}}
{{- if .Values.redis.region.external.enabled -}}
{{- required "redis.region.external.url is required when enabled" .Values.redis.region.external.url -}}
{{- else -}}
{{- printf "redis://%s:6379" (include "rrcs.name" (dict "root" $ "base" "redis-region")) -}}
{{- end -}}
{{- end -}}
```

The hostPort helpers strip the `redis://` prefix from these — no change needed in `rrcs.redis.central.hostPort` / `rrcs.redis.region.hostPort` because they already operate on the URL helper output.

- [ ] **Step 5: Update bundled-mode branches of `rrcs.nats.credsSecret.{publisher,subscriber,admin}`**

Replace the three definitions with:

```gotemplate
{{- define "rrcs.nats.credsSecret.publisher" -}}
{{- if .Values.nats.external.enabled -}}
{{- required "nats.external.auth.publisherSecret is required when external" .Values.nats.external.auth.publisherSecret -}}
{{- else -}}
{{- include "rrcs.name" (dict "root" $ "base" .Values.nats.auth.secrets.publisher) -}}
{{- end -}}
{{- end -}}

{{- define "rrcs.nats.credsSecret.subscriber" -}}
{{- if .Values.nats.external.enabled -}}
{{- required "nats.external.auth.subscriberSecret is required when external" .Values.nats.external.auth.subscriberSecret -}}
{{- else -}}
{{- include "rrcs.name" (dict "root" $ "base" .Values.nats.auth.secrets.subscriber) -}}
{{- end -}}
{{- end -}}

{{- define "rrcs.nats.credsSecret.admin" -}}
{{- if .Values.nats.external.enabled -}}
{{- .Values.nats.external.auth.adminSecret -}}
{{- else -}}
{{- include "rrcs.name" (dict "root" $ "base" .Values.nats.auth.secrets.admin) -}}
{{- end -}}
{{- end -}}
```

- [ ] **Step 6: Run the post-change assertion**

```bash
helm template rrcs ./chart -n rrcs-k8s 2>&1 | \
  grep -E 'nats://[a-z-]+:|http://[a-z-]+:|redis://[a-z-]+:|secretName: ' | sort -u
```

Expected post-change output includes `nats://lab-nats:4222`, `http://lab-nats:8222` (if exercised), `redis://lab-redis-central:6379`, `redis://lab-redis-region:6379`, `secretName: lab-publisher-creds`, `secretName: lab-subscriber-creds`, `secretName: lab-admin-creds`. NO occurrences of the unprefixed forms.

- [ ] **Step 7: Verify back-compat with empty prefix**

```bash
helm template rrcs ./chart -n rrcs-k8s --set 'resourcePrefix=' 2>&1 | \
  grep -E 'nats://nats:4222|redis://redis-central:6379|secretName: publisher-creds' | wc -l
```

Expected: a non-zero count (the old unprefixed forms come back when the prefix is empty).

- [ ] **Step 8: Verify external-mode branches are untouched**

```bash
helm template rrcs ./chart -n rrcs-k8s \
  --set 'nats.external.enabled=true' \
  --set 'nats.external.url=nats://external.example.com:4222' \
  --set 'nats.external.auth.publisherSecret=my-pub' \
  --set 'nats.external.auth.subscriberSecret=my-sub' \
  --set 'redis.central.external.enabled=true' \
  --set 'redis.central.external.url=redis://external-central.example.com:6379' \
  --set 'redis.region.external.enabled=true' \
  --set 'redis.region.external.url=redis://external-region.example.com:6379' \
  2>&1 | grep -E 'external|my-pub|my-sub' | grep -vE '#|^---|labels:' | head -10
```

Expected: external URLs and Secret names appear verbatim, NOT prefixed with `lab-`. No `lab-external.example.com` or `lab-my-pub` strings anywhere.

- [ ] **Step 9: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-connect-stress-k8s/chart/templates/_helpers.tpl
git commit -m "$(cat <<'EOF'
rrcs-k8s: route URL + credsSecret helpers through rrcs.name

Bundled-mode branches of rrcs.nats.url, rrcs.nats.monitorUrl, the redis
URL helpers, and rrcs.nats.credsSecret.{publisher,subscriber,admin} now
prefix the service-DNS / Secret-name segment via rrcs.name. The hostPort
helpers inherit the change transparently (they strip the scheme from the
URL helper output).

External-mode branches unchanged — operator-supplied URLs and Secret
names pass through verbatim.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Rename `writer.yaml` (Deployment + Service + hardcoded init-container ping)

**Files:**
- Modify: `chart/templates/writer.yaml`

The writer Deployment + Service are renamed. The `wait-connect-source` init container hardcodes `http://connect-source:4195/ready` (NOT routed through any helper), so the literal must also be updated.

- [ ] **Step 1: Failing assertion — `lab-writer` does not yet exist**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
helm template rrcs ./chart -n rrcs-k8s -s templates/writer.yaml 2>&1 | grep -E '^  name: '
```

Expected: shows `name: writer` twice (Deployment + Service), `lab-writer` nowhere.

- [ ] **Step 2: Edit `chart/templates/writer.yaml` line 4 (Deployment metadata.name)**

Replace:

```yaml
metadata:
  name: writer
  labels: { app: writer }
```

with:

```yaml
metadata:
  name: {{ include "rrcs.name" (dict "root" $ "base" "writer") }}
  labels: { app: writer }
```

- [ ] **Step 3: Edit `chart/templates/writer.yaml` (Service metadata.name, around line 62)**

In the Service section near the bottom, replace:

```yaml
metadata:
  name: writer
  labels: { app: writer }
```

with:

```yaml
metadata:
  name: {{ include "rrcs.name" (dict "root" $ "base" "writer") }}
  labels: { app: writer }
```

(Two occurrences of `name: writer` in this file — Deployment metadata at top, Service metadata at bottom. Labels `app: writer` stay unchanged.)

- [ ] **Step 4: Edit the hardcoded `connect-source` literal in the init-container ping (around line 28)**

Replace:

```yaml
        - name: wait-connect-source
          image: {{ include "rrcs.image" (dict "root" $ "ref" .Values.redis.image) }}
          imagePullPolicy: {{ .Values.images.pullPolicy }}
          command: ["/bin/sh", "-c"]
          args:
            - until wget -q --spider http://connect-source:4195/ready; do echo waiting connect-source; sleep 1; done
```

with:

```yaml
        - name: wait-connect-source
          image: {{ include "rrcs.image" (dict "root" $ "ref" .Values.redis.image) }}
          imagePullPolicy: {{ .Values.images.pullPolicy }}
          command: ["/bin/sh", "-c"]
          args:
            - until wget -q --spider http://{{ include "rrcs.name" (dict "root" $ "base" "connect-source") }}:4195/ready; do echo waiting connect-source; sleep 1; done
```

- [ ] **Step 5: Verify post-change render**

```bash
helm template rrcs ./chart -n rrcs-k8s -s templates/writer.yaml 2>&1 | grep -E '^  name: |wget'
```

Expected: shows `name: lab-writer` twice and the init-container line `until wget -q --spider http://lab-connect-source:4195/ready`. NO unprefixed `name: writer` lines, NO unprefixed `http://connect-source` literal.

- [ ] **Step 6: Verify back-compat with empty prefix**

```bash
helm template rrcs ./chart -n rrcs-k8s -s templates/writer.yaml --set 'resourcePrefix=' 2>&1 | \
  grep -cE '^  name: writer$|http://connect-source:4195'
```

Expected: 3 (two unprefixed `name: writer` lines + one unprefixed init-container literal).

- [ ] **Step 7: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-connect-stress-k8s/chart/templates/writer.yaml
git commit -m "$(cat <<'EOF'
rrcs-k8s: prefix writer Deployment + Service + init-container literal

Both metadata.name fields now route through rrcs.name. The wait-connect-source
init container hardcoded http://connect-source:4195/ready literally (not
via any helper), so the literal string is also updated to use rrcs.name.
Labels (app: writer) unchanged.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Rename `connect-source.yaml` (Deployment + Service + volume `configMap.name`)

**Files:**
- Modify: `chart/templates/connect-source.yaml`

Routes both metadata.name fields and the `configMap.name: connect-source-config` volume reference through `rrcs.name`. The `wait-redis-central` init container already uses `rrcs.redis.central.hostPort` and the `wait-stream` init container already uses `rrcs.nats.url` — both inherited prefixing from Task 2, no further changes needed there. The `secretName` is already routed through `rrcs.nats.credsSecret.publisher` (also done in Task 2).

- [ ] **Step 1: Failing assertion**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
helm template rrcs ./chart -n rrcs-k8s -s templates/connect-source.yaml 2>&1 | \
  grep -E '^  name: connect-source$|name: connect-source-config$'
```

Expected: two `name: connect-source` lines + one `name: connect-source-config` line — none of them prefixed yet.

- [ ] **Step 2: Edit Deployment metadata.name (line 4)**

Replace:

```yaml
metadata:
  name: connect-source
  labels: { app: connect-source }
```

with:

```yaml
metadata:
  name: {{ include "rrcs.name" (dict "root" $ "base" "connect-source") }}
  labels: { app: connect-source }
```

- [ ] **Step 3: Edit Service metadata.name (around line 71)**

Replace the SECOND occurrence of `name: connect-source` (inside the Service block near the bottom):

```yaml
metadata:
  name: connect-source
  labels: { app: connect-source }
```

with:

```yaml
metadata:
  name: {{ include "rrcs.name" (dict "root" $ "base" "connect-source") }}
  labels: { app: connect-source }
```

- [ ] **Step 4: Edit volume configMap.name reference (around line 62)**

Replace:

```yaml
      volumes:
        - name: config
          configMap:
            name: connect-source-config
```

with:

```yaml
      volumes:
        - name: config
          configMap:
            name: {{ include "rrcs.name" (dict "root" $ "base" "connect-source-config") }}
```

- [ ] **Step 5: Verify**

```bash
helm template rrcs ./chart -n rrcs-k8s -s templates/connect-source.yaml 2>&1 | \
  grep -E '^  name: |configMap:|secret:|nats-creds'
```

Expected: `name: lab-connect-source` twice, `name: lab-connect-source-config` once. No unprefixed forms.

- [ ] **Step 6: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-connect-stress-k8s/chart/templates/connect-source.yaml
git commit -m "$(cat <<'EOF'
rrcs-k8s: prefix connect-source Deployment + Service + configMap mount

Both metadata.name and the volumes[].configMap.name reference now route
through rrcs.name. Init-container service-name references (rrcs.redis.central.hostPort,
rrcs.nats.url) and the publisher Secret reference (rrcs.nats.credsSecret.publisher)
inherit prefixing transparently from the helper updates landed in the
prior commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Rename `connect-sink.yaml` (Deployment + Service + volume `configMap.name`)

**Files:**
- Modify: `chart/templates/connect-sink.yaml`

Identical pattern to Task 4 but for connect-sink. The `configMap.name` here is `connect-sink-config`; the Secret reference uses `rrcs.nats.credsSecret.subscriber`.

- [ ] **Step 1: Failing assertion**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
helm template rrcs ./chart -n rrcs-k8s -s templates/connect-sink.yaml 2>&1 | \
  grep -E '^  name: connect-sink$|name: connect-sink-config$'
```

Expected: two unprefixed `name: connect-sink` lines + one `name: connect-sink-config`.

- [ ] **Step 2: Edit Deployment metadata.name (line 4)**

Replace:

```yaml
metadata:
  name: connect-sink
  labels: { app: connect-sink }
```

with:

```yaml
metadata:
  name: {{ include "rrcs.name" (dict "root" $ "base" "connect-sink") }}
  labels: { app: connect-sink }
```

- [ ] **Step 3: Edit Service metadata.name (around line 71)**

Replace the second `name: connect-sink` (in the Service block) similarly to Step 2.

- [ ] **Step 4: Edit volume configMap.name reference (around line 62)**

Replace:

```yaml
      volumes:
        - name: config
          configMap:
            name: connect-sink-config
```

with:

```yaml
      volumes:
        - name: config
          configMap:
            name: {{ include "rrcs.name" (dict "root" $ "base" "connect-sink-config") }}
```

- [ ] **Step 5: Verify**

```bash
helm template rrcs ./chart -n rrcs-k8s -s templates/connect-sink.yaml 2>&1 | \
  grep -E '^  name: |configMap:'
```

Expected: `name: lab-connect-sink` twice, `name: lab-connect-sink-config` once.

- [ ] **Step 6: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-connect-stress-k8s/chart/templates/connect-sink.yaml
git commit -m "$(cat <<'EOF'
rrcs-k8s: prefix connect-sink Deployment + Service + configMap mount

Mirror of the connect-source commit. Init-container references and the
subscriber Secret inherit prefixing from the helper updates.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Rename `redis-central.yaml` + `redis-region.yaml`

**Files:**
- Modify: `chart/templates/redis-central.yaml`
- Modify: `chart/templates/redis-region.yaml`

Both are simple Deployment + Service. No volume / Secret / init-container literals — straight metadata.name substitution in both files.

- [ ] **Step 1: Failing assertion**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
helm template rrcs ./chart -n rrcs-k8s -s templates/redis-central.yaml -s templates/redis-region.yaml 2>&1 | \
  grep -E '^  name: redis-(central|region)$'
```

Expected: 4 unprefixed lines (each file has Deployment + Service).

- [ ] **Step 2: Edit `redis-central.yaml` — Deployment (line 5) and Service (around line 47)**

In both `metadata:` blocks, replace:

```yaml
metadata:
  name: redis-central
  labels: { app: redis-central }
```

with:

```yaml
metadata:
  name: {{ include "rrcs.name" (dict "root" $ "base" "redis-central") }}
  labels: { app: redis-central }
```

- [ ] **Step 3: Edit `redis-region.yaml` — Deployment (line 5) and Service (around line 47)**

Same substitution but with base `"redis-region"`.

- [ ] **Step 4: Verify**

```bash
helm template rrcs ./chart -n rrcs-k8s -s templates/redis-central.yaml -s templates/redis-region.yaml 2>&1 | \
  grep -E '^  name: '
```

Expected: `name: lab-redis-central` twice + `name: lab-redis-region` twice.

- [ ] **Step 5: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-connect-stress-k8s/chart/templates/redis-central.yaml \
        labs/redis-redpanda-connect-stress-k8s/chart/templates/redis-region.yaml
git commit -m "$(cat <<'EOF'
rrcs-k8s: prefix redis-central + redis-region Deployments + Services

Pure metadata.name substitution. Consumers (writer REDIS_ADDR,
collector --redis-* flags, init-container redis-cli pings) inherit
prefixing transparently via rrcs.redis.{central,region}.hostPort.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Rename `nats.yaml` (Deployment + Service + optional PVC + claimName)

**Files:**
- Modify: `chart/templates/nats.yaml`

Three resources: optional PVC `nats-data` (only when `nats.persistence.mode=pvc`), Deployment `nats`, Service `nats`. The Deployment's volume references the PVC by name in its `persistentVolumeClaim.claimName`, so that literal also needs updating.

- [ ] **Step 1: Failing assertion (with PVC mode enabled to exercise the conditional)**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
helm template rrcs ./chart -n rrcs-k8s -s templates/nats.yaml --set 'nats.persistence.mode=pvc' 2>&1 | \
  grep -E '^  name: (nats|nats-data)$|claimName: nats-data$'
```

Expected: three `name:` lines (PVC, Deployment, Service) + one `claimName: nats-data` line.

- [ ] **Step 2: Edit PVC metadata.name (line 6)**

Replace:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nats-data
  labels: { app: nats }
```

with:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ include "rrcs.name" (dict "root" $ "base" "nats-data") }}
  labels: { app: nats }
```

- [ ] **Step 3: Edit Deployment metadata.name (line 21)**

Replace:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nats
  labels: { app: nats }
```

with:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "rrcs.name" (dict "root" $ "base" "nats") }}
  labels: { app: nats }
```

- [ ] **Step 4: Edit volumes claimName (around line 64)**

Replace:

```yaml
      volumes:
        - name: data
        {{- if eq .Values.nats.persistence.mode "pvc" }}
          persistentVolumeClaim:
            claimName: nats-data
        {{- else }}
          emptyDir: {}
        {{- end }}
```

with:

```yaml
      volumes:
        - name: data
        {{- if eq .Values.nats.persistence.mode "pvc" }}
          persistentVolumeClaim:
            claimName: {{ include "rrcs.name" (dict "root" $ "base" "nats-data") }}
        {{- else }}
          emptyDir: {}
        {{- end }}
```

- [ ] **Step 5: Edit nats-config ConfigMap reference (around line 70)**

Replace:

```yaml
        - name: config
          configMap:
            name: nats-config
```

with:

```yaml
        - name: config
          configMap:
            name: {{ include "rrcs.name" (dict "root" $ "base" "nats-config") }}
```

- [ ] **Step 6: Edit Service metadata.name (around line 75)**

Replace:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nats
  labels: { app: nats }
```

with:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ include "rrcs.name" (dict "root" $ "base" "nats") }}
  labels: { app: nats }
```

- [ ] **Step 7: Verify (PVC mode and emptyDir mode)**

```bash
helm template rrcs ./chart -n rrcs-k8s -s templates/nats.yaml --set 'nats.persistence.mode=pvc' 2>&1 | \
  grep -E '^  name: |claimName: |configMap:'
echo '--- emptyDir mode ---'
helm template rrcs ./chart -n rrcs-k8s -s templates/nats.yaml 2>&1 | \
  grep -E '^  name: |configMap:'
```

Expected (PVC mode): `name: lab-nats-data`, `name: lab-nats` (×2 for Deployment + Service), `claimName: lab-nats-data`, `name: lab-nats-config` (configMap reference). Expected (emptyDir mode): same minus the PVC and claimName lines.

- [ ] **Step 8: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-connect-stress-k8s/chart/templates/nats.yaml
git commit -m "$(cat <<'EOF'
rrcs-k8s: prefix nats Deployment + Service + optional PVC + claimName

Three rendered resources renamed: the optional nats-data PVC, the nats
Deployment, the nats Service. The Deployment's persistentVolumeClaim.claimName
reference also needs updating so it binds to the (newly prefixed) PVC.
The nats-config ConfigMap reference in the volume mount is updated here
too — that ConfigMap itself is renamed in the next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Rename ConfigMaps (`nats-config-cm.yaml`, `connect-configmaps.yaml`)

**Files:**
- Modify: `chart/templates/nats-config-cm.yaml`
- Modify: `chart/templates/connect-configmaps.yaml`

Three ConfigMaps: `nats-config`, `connect-source-config`, `connect-sink-config`. All consumed via volume `configMap.name` references already updated in Tasks 4, 5, 7.

- [ ] **Step 1: Failing assertion**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
helm template rrcs ./chart -n rrcs-k8s -s templates/nats-config-cm.yaml -s templates/connect-configmaps.yaml 2>&1 | \
  grep -E '^  name: (nats-config|connect-(source|sink)-config)$'
```

Expected: three unprefixed lines.

- [ ] **Step 2: Edit `nats-config-cm.yaml` line 5**

Replace:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: nats-config
  labels: { app: nats }
```

with:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "rrcs.name" (dict "root" $ "base" "nats-config") }}
  labels: { app: nats }
```

- [ ] **Step 3: Edit `connect-configmaps.yaml` — both ConfigMap metadata.name fields**

Replace:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: connect-source-config
  labels: { app: connect-source }
```

with:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "rrcs.name" (dict "root" $ "base" "connect-source-config") }}
  labels: { app: connect-source }
```

And for the second ConfigMap in the same file:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: connect-sink-config
  labels: { app: connect-sink }
```

→

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "rrcs.name" (dict "root" $ "base" "connect-sink-config") }}
  labels: { app: connect-sink }
```

- [ ] **Step 4: Verify**

```bash
helm template rrcs ./chart -n rrcs-k8s -s templates/nats-config-cm.yaml -s templates/connect-configmaps.yaml 2>&1 | \
  grep -E '^  name: '
```

Expected: `name: lab-nats-config`, `name: lab-connect-source-config`, `name: lab-connect-sink-config`.

- [ ] **Step 5: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-connect-stress-k8s/chart/templates/nats-config-cm.yaml \
        labs/redis-redpanda-connect-stress-k8s/chart/templates/connect-configmaps.yaml
git commit -m "$(cat <<'EOF'
rrcs-k8s: prefix nats-config + connect-source/sink-config ConfigMaps

All three rendered ConfigMaps renamed via rrcs.name. The volume mount
references were already updated in the workload-template commits.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Rename `nats-auth-secrets.yaml` (three Secrets)

**Files:**
- Modify: `chart/templates/nats-auth-secrets.yaml`

The Secret `metadata.name` fields currently read `.Values.nats.auth.secrets.{publisher,subscriber,admin}` directly. After this task they route through `rrcs.name`. The consuming `secretName:` references in Connect Deployments and the nats-init Job already use `rrcs.nats.credsSecret.*` (updated in Task 2).

- [ ] **Step 1: Failing assertion**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
helm template rrcs ./chart -n rrcs-k8s -s templates/nats-auth-secrets.yaml 2>&1 | \
  grep -E '^  name: '
```

Expected: `name: publisher-creds`, `name: subscriber-creds`, `name: admin-creds` — all unprefixed.

- [ ] **Step 2: Edit each Secret's metadata.name**

Replace lines 5, 14, 23:

```yaml
  name: {{ .Values.nats.auth.secrets.publisher }}
```

→

```yaml
  name: {{ include "rrcs.name" (dict "root" $ "base" .Values.nats.auth.secrets.publisher) }}
```

Similarly for `.subscriber` and `.admin`.

- [ ] **Step 3: Verify**

```bash
helm template rrcs ./chart -n rrcs-k8s -s templates/nats-auth-secrets.yaml 2>&1 | \
  grep -E '^  name: '
```

Expected: `name: lab-publisher-creds`, `name: lab-subscriber-creds`, `name: lab-admin-creds`.

- [ ] **Step 4: Verify symmetry — `secretName:` consumers match the new Secret names**

```bash
helm template rrcs ./chart -n rrcs-k8s 2>&1 | grep -E 'secretName: ' | sort -u
```

Expected: `secretName: lab-publisher-creds`, `secretName: lab-subscriber-creds`, `secretName: lab-admin-creds`. (Each appears multiple times across the rendered manifests — that's fine.)

- [ ] **Step 5: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-connect-stress-k8s/chart/templates/nats-auth-secrets.yaml
git commit -m "$(cat <<'EOF'
rrcs-k8s: prefix bundled-mode nats-auth Secret names

The three Secret metadata.name fields route through rrcs.name. Consumers
already reference these through rrcs.nats.credsSecret.{publisher,subscriber,admin},
which were updated to apply the same prefix earlier, so the rendered
secretName: values match without additional changes.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Rename `nats-init-job.yaml` (Job + hardcoded service literal)

**Files:**
- Modify: `chart/templates/nats-init-job.yaml`

The Job's `metadata.name` is hash-derived (`nats-init-<8hex>`) — prefix the constant part. The init-container script body contains the hardcoded literal `nats://nats:{{ .Values.nats.clientPort }}` (NOT via `rrcs.nats.url` — it builds the URL inline because it predates the admin-mode helper plumbing); update that literal to use the helper now that the helper handles prefixing.

- [ ] **Step 1: Failing assertion**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
helm template rrcs ./chart -n rrcs-k8s -s templates/nats-init-job.yaml 2>&1 | \
  grep -E '^  name: nats-init-|SERVER="nats://|nats --server nats://'
```

Expected: `name: nats-init-<8hex>` line (unprefixed) and a `SERVER="nats://nats:4222"` line (unprefixed inline URL).

- [ ] **Step 2: Edit Job metadata.name (line 7)**

Replace:

```yaml
metadata:
  # Hash-suffixed so a changed stream config or image yields a NEW Job name
  # rather than failing `helm upgrade` on the immutable completed Job (spec §5.2).
  name: nats-init-{{ printf "%s|%s|%s|%s" (toYaml .Values.nats.stream) (toYaml .Values.nats.auth) (.Files.Get "files/nats-auth/nats-server.conf") (include "rrcs.image" (dict "root" $ "ref" .Values.natsBox.image)) | sha256sum | trunc 8 }}
  labels: { app: nats-init }
```

with:

```yaml
metadata:
  # Hash-suffixed so a changed stream config or image yields a NEW Job name
  # rather than failing `helm upgrade` on the immutable completed Job (spec §5.2).
  name: {{ include "rrcs.name" (dict "root" $ "base" (printf "nats-init-%s" (printf "%s|%s|%s|%s" (toYaml .Values.nats.stream) (toYaml .Values.nats.auth) (.Files.Get "files/nats-auth/nats-server.conf") (include "rrcs.image" (dict "root" $ "ref" .Values.natsBox.image)) | sha256sum | trunc 8))) }}
  labels: { app: nats-init }
```

- [ ] **Step 3: Edit the `wait-nats` init-container `until ... rtt` line (around line 31)**

Replace:

```yaml
              until nats --server nats://nats:{{ .Values.nats.clientPort }} --creds /etc/nats-creds/admin/user.creds rtt >/dev/null 2>&1; do
```

with:

```yaml
              until nats --server {{ include "rrcs.nats.url" . }} --creds /etc/nats-creds/admin/user.creds rtt >/dev/null 2>&1; do
```

- [ ] **Step 4: Edit the `create-stream` container's `SERVER=` line (around line 46)**

Replace:

```yaml
              SERVER="nats://nats:{{ .Values.nats.clientPort }}"
```

with:

```yaml
              SERVER={{ include "rrcs.nats.url" . | quote }}
```

- [ ] **Step 5: Verify**

```bash
helm template rrcs ./chart -n rrcs-k8s -s templates/nats-init-job.yaml 2>&1 | \
  grep -E '^  name: |SERVER=|nats --server'
```

Expected: `name: lab-nats-init-<8hex>` (prefixed), `SERVER="nats://lab-nats:4222"`, `nats --server nats://lab-nats:4222`.

- [ ] **Step 6: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-connect-stress-k8s/chart/templates/nats-init-job.yaml
git commit -m "$(cat <<'EOF'
rrcs-k8s: prefix nats-init Job + route its inline NATS URL via helper

The Job's hash-derived metadata.name is wrapped in rrcs.name. The
wait-nats and create-stream containers no longer hardcode nats://nats:<port>
inline — they call rrcs.nats.url, which now returns the prefixed
service-DNS in bundled mode.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Rename `collector-job.yaml` + add fail-loud over-budget guard

**Files:**
- Modify: `chart/templates/collector-job.yaml`

Two changes: (1) wrap `metadata.name` (which combines optional `.Values.collector.jobName` with a printf default) in `rrcs.name`; (2) add a render-time `fail` if the rendered name exceeds 57 chars (per spec §2.2).

- [ ] **Step 1: Failing assertion**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
helm template rrcs ./chart -n rrcs-k8s -s templates/collector-job.yaml \
  --set 'collector.run=true' --set 'collector.tier=10000' \
  --set 'collector.mode=throughput' 2>&1 | grep -E '^  name: '
```

Expected: `name: collector-10000-throughput-alo` (unprefixed).

- [ ] **Step 2: Edit `metadata.name` + add guard (lines 1-6)**

Replace:

```yaml
{{- if .Values.collector.run }}
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ .Values.collector.jobName | default (printf "collector-%v-%s-%s" .Values.collector.tier .Values.collector.mode .Values.profile) }}
  labels: { app: collector }
```

with:

```yaml
{{- if .Values.collector.run }}
{{- $base := .Values.collector.jobName | default (printf "collector-%v-%s-%s" .Values.collector.tier .Values.collector.mode .Values.profile) -}}
{{- $name := include "rrcs.name" (dict "root" $ "base" $base) -}}
{{- if gt (len $name) 57 -}}
{{- fail (printf "collector Job name %q (%d chars) exceeds the 57-char budget (63 DNS-1123 limit minus the 6-char Pod random suffix). Shorten resourcePrefix (currently %q) or collector.jobName." $name (len $name) .Values.resourcePrefix) -}}
{{- end -}}
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ $name }}
  labels: { app: collector }
```

- [ ] **Step 3: Verify default render**

```bash
helm template rrcs ./chart -n rrcs-k8s -s templates/collector-job.yaml \
  --set 'collector.run=true' --set 'collector.tier=10000' \
  --set 'collector.mode=throughput' 2>&1 | grep -E '^  name: '
```

Expected: `name: lab-collector-10000-throughput-alo` (prefixed).

- [ ] **Step 4: Verify guard fires on over-budget rendered name**

```bash
helm template rrcs ./chart -n rrcs-k8s -s templates/collector-job.yaml \
  --set 'collector.run=true' \
  --set 'collector.jobName=collector-10000-throughput-alo-1234567890' \
  --set 'resourcePrefix=this-is-a-too-long-prefix-' 2>&1 | tail -3
```

Expected: error message naming the over-budget Job and the rendered length, e.g. `Error: execution error at ...: collector Job name "this-is-a-too-long-prefix-collector-10000-throughput-alo-1234567890" (66 chars) exceeds the 57-char budget ...`.

- [ ] **Step 5: Verify guard does NOT fire just under budget**

```bash
helm template rrcs ./chart -n rrcs-k8s -s templates/collector-job.yaml \
  --set 'collector.run=true' \
  --set 'collector.jobName=collector-10000-throughput-alo-1234567890' \
  --set 'resourcePrefix=sixteen-charpref' 2>&1 | grep -E '^  name: '
```

Expected: `name: sixteen-charprefcollector-10000-throughput-alo-1234567890` (57 chars total), rendered cleanly with no error.

- [ ] **Step 6: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-connect-stress-k8s/chart/templates/collector-job.yaml
git commit -m "$(cat <<'EOF'
rrcs-k8s: prefix collector Job + add fail-loud over-budget render guard

metadata.name wraps both the operator-supplied collector.jobName and the
template default in rrcs.name. A render-time guard fails helm template
if the rendered name (prefix + base) would not leave 6 chars of headroom
for the Pod random suffix, naming both the rendered length and the
current resourcePrefix in the error so the operator knows what to shorten.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 12: Adapt harness scripts (`stress-run.sh` + `chaos/scale-connect-sink.sh`)

**Files:**
- Modify: `scripts/stress-run.sh`
- Modify: `scripts/chaos/scale-connect-sink.sh`

`stress-run.sh` already parses `HELM_VALUES_JSON` for several values. Extend that pattern: parse `resourcePrefix`, export `RESOURCE_PREFIX`, and use it for every hardcoded `nats`, `connect-sink`, `admin-creds`, and `nats-purge-...` reference. The chaos script reads the env var with a `lab-` fallback so it works standalone.

- [ ] **Step 1: Capture pre-change references in the scripts**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
grep -nE 'svc/nats|nats://nats:|admin-creds|nats-purge-|DEPLOY=connect' scripts/stress-run.sh scripts/chaos/scale-connect-sink.sh
```

Expected: matches in both scripts for the literals that need rewriting (`svc/nats`, fallback `nats://nats:4222`, default `admin-creds`, `nats-purge-` pod prefix; `DEPLOY=connect-sink` in the chaos script).

- [ ] **Step 2: Edit `scripts/stress-run.sh` — add resourcePrefix parse near the other `HELM_VALUES_JSON` parses (around line 74)**

Find the existing `STREAM_NAME=...` line and add immediately after it:

```bash
RESOURCE_PREFIX="$(echo "$HELM_VALUES_JSON" | jq -r '.resourcePrefix // "lab-"')"
export RESOURCE_PREFIX
```

- [ ] **Step 3: Edit `scripts/stress-run.sh` — line 78 NATS URL fallback**

Replace:

```bash
[[ -z "$NATS_URL" ]] && NATS_URL="nats://nats:4222"
```

with:

```bash
[[ -z "$NATS_URL" ]] && NATS_URL="nats://${RESOURCE_PREFIX}nats:4222"
```

- [ ] **Step 4: Edit `scripts/stress-run.sh` — line 82 default admin Secret**

Replace:

```bash
  ADMIN_SECRET="$(echo "$HELM_VALUES_JSON" | jq -r '.nats.auth.secrets.admin // "admin-creds"')"
```

with:

```bash
  ADMIN_SECRET_BASE="$(echo "$HELM_VALUES_JSON" | jq -r '.nats.auth.secrets.admin // "admin-creds"')"
  ADMIN_SECRET="${RESOURCE_PREFIX}${ADMIN_SECRET_BASE}"
```

- [ ] **Step 5: Edit `scripts/stress-run.sh` — line 99 port-forward target**

Replace:

```bash
    kubectl -n "${NS}" port-forward svc/nats 18222:8222 >/dev/null 2>&1 &
```

with:

```bash
    kubectl -n "${NS}" port-forward "svc/${RESOURCE_PREFIX}nats" 18222:8222 >/dev/null 2>&1 &
```

- [ ] **Step 6: Edit `scripts/stress-run.sh` — line 218 purge pod name**

Replace:

```bash
  purge_name="nats-purge-$(date +%s)"
```

with:

```bash
  purge_name="${RESOURCE_PREFIX}nats-purge-$(date +%s)"
```

- [ ] **Step 7: Edit `scripts/stress-run.sh` — line 167 collector job name reference**

The harness builds the job name via:

```bash
  job="collector-${tier}-${mode}-${PROFILE}-$(date +%s)"
```

The chart now applies `rrcs.name` over `collector.jobName` (Task 11), so the harness still sets `--set collector.jobName=<base>` with the unprefixed base. But every `kubectl ... job/${job}` reference downstream (lines around 139, 192, 197, 201) must reference the prefixed name. Add right after the `job=` assignment (around line 167):

```bash
  job_full="${RESOURCE_PREFIX}${job}"
```

Then replace every downstream occurrence of `job/${job}` with `job/${job_full}`. The exact lines to change (verify with grep):

```bash
grep -n 'job/${job}' scripts/stress-run.sh
```

For each line, replace `job/${job}` → `job/${job_full}`. The `--set collector.jobName=${job}` line (around 174) STAYS unprefixed — the chart prefixes it.

- [ ] **Step 8: Edit `scripts/chaos/scale-connect-sink.sh` — DEPLOY assignment**

Replace line 11:

```bash
DEPLOY=connect-sink
```

with:

```bash
DEPLOY="${RESOURCE_PREFIX:-lab-}connect-sink"
```

The `${RESOURCE_PREFIX:-lab-}` default mirrors the chart default so the script works when invoked directly (not via stress-run.sh).

- [ ] **Step 9: Syntax-check both scripts**

```bash
bash -n scripts/stress-run.sh && echo "stress-run.sh OK"
bash -n scripts/chaos/scale-connect-sink.sh && echo "chaos script OK"
```

Expected: both print `OK`.

- [ ] **Step 10: Smoke-test prefix propagation**

```bash
HELM_VALUES_JSON='{"resourcePrefix":"staging-","nats":{"auth":{"secrets":{"admin":"admin-creds"}}}}' \
  bash -c 'source scripts/stress-run.sh 2>/dev/null; echo "ADMIN_SECRET=$ADMIN_SECRET"' 2>&1 | head -5
```

That sourcing may fail since stress-run.sh is not designed to be sourced (it has top-level argument parsing). Alternative spot-check: just verify the literal `${RESOURCE_PREFIX}` appears in the right places:

```bash
grep -nE 'RESOURCE_PREFIX|resourcePrefix' scripts/stress-run.sh scripts/chaos/scale-connect-sink.sh
```

Expected: at least 7 hits across the two scripts (parse, export, NATS URL, admin secret, port-forward, purge pod, job_full, chaos DEPLOY).

- [ ] **Step 11: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-connect-stress-k8s/scripts/stress-run.sh \
        labs/redis-redpanda-connect-stress-k8s/scripts/chaos/scale-connect-sink.sh
git commit -m "$(cat <<'EOF'
rrcs-k8s: harness scripts read resourcePrefix from values + propagate

stress-run.sh extends its HELM_VALUES_JSON parser to pick up
.resourcePrefix (default "lab-") and exports RESOURCE_PREFIX. Every
literal kubectl target that names a chart-rendered resource (svc/nats
port-forward, default NATS URL fallback, default admin Secret name,
nats-purge-<ts> temporary pod, collector job/<name> for wait/logs/
delete) now uses ${RESOURCE_PREFIX}-prefixed names. The --set
collector.jobName= flag still passes the unprefixed base — the chart
applies rrcs.name on the chart side.

chaos/scale-connect-sink.sh reads ${RESOURCE_PREFIX:-lab-} so it works
both via stress-run.sh (env inherited) and standalone (default).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 13: Update docs

**Files:**
- Modify: `README.md`
- Modify: `values-external.yaml.example`
- Modify: `chart/files/nats-auth/README.md`
- Modify: `RESEARCH.md`

- [ ] **Step 1: Add `resourcePrefix` row to the README knob table**

In `README.md`, the knob table starts around line 84. Insert a new row directly after the `images.registry` row:

```markdown
| `resourcePrefix` | `lab-` | Prepended to every chart-rendered K8s resource name. Empty string opts out (back-compat with the unprefixed pre-v3 names). Pod names must fit the K8s 63-char DNS-1123 label limit; the collector Job is the binding case (~16 chars of headroom for a custom prefix). `helm template` fails loud at render time if you exceed this. |
```

- [ ] **Step 2: Add `resourcePrefix` note to `values-external.yaml.example`**

Append at the bottom of the file (after the last existing block):

```yaml

# Optional: pick a different prefix for the bundled chart-rendered resources.
# Has no effect on user-supplied external Secret/URL names — those pass
# through verbatim. Default "lab-".
# resourcePrefix: "tenant-a-"
```

- [ ] **Step 3: Update `chart/files/nats-auth/README.md`** — add a single sentence about the prefix at the end of the existing doc:

```markdown

When the chart is installed with a non-default `resourcePrefix`, the
deployed Secrets reflect that prefix (e.g. `tenant-a-publisher-creds`),
but the fixture `.creds` files themselves are operator-controlled
content and stay un-prefixed in this directory.
```

- [ ] **Step 4: Add a short paragraph to `RESEARCH.md`** — append under the "credential auth + external backend support" section near the top:

```markdown
- **Resource-name prefix.** Every chart-rendered K8s resource (Deployments,
  Services, ConfigMaps, Secrets, Jobs, the optional PVC) takes a configurable
  prefix from `resourcePrefix` (default `lab-`). Single source of truth via
  the `rrcs.name` helper means URL helpers, Secret-name helpers, and the
  harness scripts all track the same value. External-mode user-supplied
  names pass through unchanged.
```

- [ ] **Step 5: Verify**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
grep -nE 'resourcePrefix' README.md values-external.yaml.example chart/files/nats-auth/README.md RESEARCH.md | head -10
```

Expected: at least one hit per file.

- [ ] **Step 6: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-connect-stress-k8s/README.md \
        labs/redis-redpanda-connect-stress-k8s/values-external.yaml.example \
        labs/redis-redpanda-connect-stress-k8s/chart/files/nats-auth/README.md \
        labs/redis-redpanda-connect-stress-k8s/RESEARCH.md
git commit -m "$(cat <<'EOF'
rrcs-k8s: document the resourcePrefix knob

README knob table gains a resourcePrefix row noting the binding budget
(collector Job, ~16-char headroom) and the fail-loud render guard.
values-external.yaml.example adds a commented-out example for custom
prefixes. The nats-auth fixtures README clarifies that fixture .creds
files stay un-prefixed (they're operator-controlled content). RESEARCH.md
captures the design rationale.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 14: End-to-end validation

**Files:**
- Read-only: every chart template and harness script touched above.

No code changes; this task gathers the round-trip evidence that the rename is internally consistent and that the back-compat escape hatch works.

- [ ] **Step 1: `helm lint` clean**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
helm lint ./chart
```

Expected: `1 chart(s) linted, 0 chart(s) failed`.

- [ ] **Step 2: Default render — every chart-rendered resource carries the `lab-` prefix**

```bash
helm template rrcs ./chart -n rrcs-k8s --set 'nats.persistence.mode=pvc' 2>&1 | \
  awk '/^kind:/{k=$2} /^  name:/{print k"/"$2}' | sort -u
```

Expected (the full inventory, every name beginning with `lab-`):

```
ConfigMap/lab-connect-sink-config
ConfigMap/lab-connect-source-config
ConfigMap/lab-nats-config
Deployment/lab-connect-sink
Deployment/lab-connect-source
Deployment/lab-nats
Deployment/lab-redis-central
Deployment/lab-redis-region
Deployment/lab-writer
Job/lab-nats-init-<8hex>
PersistentVolumeClaim/lab-nats-data
Secret/lab-admin-creds
Secret/lab-publisher-creds
Secret/lab-subscriber-creds
Service/lab-connect-sink
Service/lab-connect-source
Service/lab-nats
Service/lab-redis-central
Service/lab-redis-region
Service/lab-writer
```

No line should be missing the prefix. The Job hash will be deterministic per `.Values.nats.stream` + auth content; the exact 8 hex chars don't matter.

- [ ] **Step 3: Default render — every cross-reference (URL, secretName, configMap.name, env, claimName, kubectl-target literal) carries the prefix**

```bash
helm template rrcs ./chart -n rrcs-k8s --set 'nats.persistence.mode=pvc' 2>&1 | \
  grep -E 'nats://|redis://|http://[a-z]|secretName:|configMap:|claimName:|REDIS_ADDR|--nats=|--redis-' | \
  sort -u
```

Expected: every URL is `lab-<service>...`, every `secretName:` is `lab-<role>-creds`, every `configMap.name:` and `claimName:` is `lab-<base>`, every Redis env is `lab-redis-...`. No leftover unprefixed forms.

- [ ] **Step 4: Back-compat — `resourcePrefix=""` renders the original pre-change names**

```bash
helm template rrcs ./chart -n rrcs-k8s --set 'resourcePrefix=' --set 'nats.persistence.mode=pvc' 2>&1 | \
  awk '/^kind:/{k=$2} /^  name:/{print k"/"$2}' | sort -u | head
```

Expected: same inventory as Step 2 but WITHOUT the `lab-` prefix on any line.

- [ ] **Step 5: Custom prefix — `resourcePrefix=staging-` produces every name with that prefix**

```bash
helm template rrcs ./chart -n rrcs-k8s --set 'resourcePrefix=staging-' --set 'nats.persistence.mode=pvc' 2>&1 | \
  awk '/^kind:/{k=$2} /^  name:/{print k"/"$2}' | sort -u | head
```

Expected: same inventory as Step 2 but with `staging-` instead of `lab-`.

- [ ] **Step 6: External-mode — operator-supplied names pass through verbatim**

```bash
helm template rrcs ./chart -n rrcs-k8s \
  --set 'nats.external.enabled=true' \
  --set 'nats.external.url=nats://prod.example.com:4222' \
  --set 'nats.external.monitorUrl=http://prod.example.com:8222' \
  --set 'nats.external.auth.publisherSecret=prod-pub' \
  --set 'nats.external.auth.subscriberSecret=prod-sub' \
  --set 'nats.external.auth.adminSecret=prod-admin' \
  --set 'redis.central.external.enabled=true' \
  --set 'redis.central.external.url=redis://prod-central.example.com:6379' \
  --set 'redis.region.external.enabled=true' \
  --set 'redis.region.external.url=redis://prod-region.example.com:6379' \
  2>&1 | grep -E 'prod-|prod\.example\.com' | sort -u
```

Expected: lines reference `prod-pub`, `prod-sub`, `prod-admin`, `nats://prod.example.com:4222`, `http://prod.example.com:8222`, `redis://prod-central.example.com:6379`, `redis://prod-region.example.com:6379` — none of them carry a `lab-` prefix.

- [ ] **Step 7: Over-budget guard fires loudly**

```bash
helm template rrcs ./chart -n rrcs-k8s \
  --set 'collector.run=true' \
  --set 'collector.jobName=collector-10000-throughput-alo-1234567890' \
  --set 'resourcePrefix=this-prefix-is-over-budget-' 2>&1 | tail -3
```

Expected: error message naming the over-budget rendered Job name (>57 chars) and the current `resourcePrefix`.

- [ ] **Step 8: Harness scripts pass shell syntax check**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
bash -n scripts/stress-run.sh && bash -n scripts/chaos/scale-connect-sink.sh && echo "all scripts OK"
```

Expected: `all scripts OK`.

- [ ] **Step 9: Render diff against pre-change `master` is just the expected substitutions**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git stash
helm template rrcs ./labs/redis-redpanda-connect-stress-k8s/chart -n rrcs-k8s > /tmp/render-before.yaml
git stash pop
helm template rrcs ./labs/redis-redpanda-connect-stress-k8s/chart -n rrcs-k8s > /tmp/render-after.yaml
diff /tmp/render-before.yaml /tmp/render-after.yaml | head -40
```

Expected: the diff contains only name and reference changes (unprefixed → `lab-` prefixed). No structural changes to fields outside of `metadata.name`, `secretName:`, `claimName:`, `configMap.name:`, URL strings, and the new `resourcePrefix` value.

If `git stash` complains about no changes to stash (e.g. if the prior tasks were already committed), fall back to comparing against the merge-base:

```bash
git checkout HEAD~14 -- labs/redis-redpanda-connect-stress-k8s/chart
helm template rrcs ./labs/redis-redpanda-connect-stress-k8s/chart -n rrcs-k8s > /tmp/render-before.yaml
git checkout HEAD -- labs/redis-redpanda-connect-stress-k8s/chart
helm template rrcs ./labs/redis-redpanda-connect-stress-k8s/chart -n rrcs-k8s > /tmp/render-after.yaml
diff /tmp/render-before.yaml /tmp/render-after.yaml | wc -l
```

Expected: a non-zero count (proves the diff exists), with the changes scoped to name/reference substitutions.

- [ ] **Step 10: Smoke commit**

This task makes no source changes, so there is nothing to commit. Note the validation outcome and proceed to handoff.

```bash
echo "validation passed" # no commit
```

---

## Self-review pass (do this before declaring the plan implemented)

After all 14 tasks land, run this checklist:

1. **Spec § coverage:**
   - §1 Goal: every `metadata.name` prefixed → Tasks 3–11.
   - §2.1 Length budget: §2.2 guard implemented in Task 11; §2.3 README budget paragraph in Task 13.
   - §3 `rrcs.name` helper: Task 1.
   - §4 Templates touched: Tasks 3–11.
   - §5 URL/Secret helpers: Task 2.
   - §6 Harness: Task 12.
   - §7 External-mode boundary: Tasks 2, 14 (Step 6).
   - §8 Labels unchanged: implicit (no task edits any `labels:` block).
   - §9 Validation plan: Task 14.
   - §10 Files changed: every file in §10 maps to at least one task above.
   - §11 Out-of-scope: respected (no truncation logic; no label rename; no release-name change).

2. **No placeholders:** every step shows complete code/commands and exact expected output.

3. **Type/string consistency:** the helper is `rrcs.name` (kebab-cased `dict "root" $ "base" "..."`) everywhere; values key is exactly `resourcePrefix`; env var is exactly `RESOURCE_PREFIX`; back-compat opt-out is `resourcePrefix=""` everywhere.
