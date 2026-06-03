# NATS JetStream Credential Auth + External Backend Support — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the design at `docs/superpowers/specs/2026-06-02-rrcs-k8s-nats-creds-auth-design.md` — add production-shape NATS credential auth (operator → account → publisher/subscriber/admin users with narrow JetStream perms) to the K8s lab, plus independent bundled/external toggles for NATS and each Redis, plus values-driven NATS topic/stream/consumer names that propagate to the connect YAMLs via Helm `tpl`.

**Architecture:** A new `scripts/gen-nats-auth.sh` script uses the `nsc` CLI to mint a self-contained operator + account + three user JWTs into `chart/files/nats-auth/` (committed lab fixtures). The chart renders three K8s Secrets from those creds, mounts them on the matching client pods, and switches the NATS server to a config-file form that loads the operator/account JWTs into a `MEMORY` resolver. In external mode the chart skips its own NATS/Redis Deployments and consumes user-supplied URLs + pre-created Secrets by name. Six connect YAMLs become `tpl`-rendered so they can pick up the configurable URL, subject, stream name, durable consumer name, and creds path. Auth is always-on (no toggle); the no-auth original lab remains at `labs/redis-redpanda-connect-stress/`.

**Tech Stack:** Helm 3, kubectl, kind, Docker, Go 1.24 (collector — one defensive change in `scrapers.go`), bash, `nsc` (NATS Security Configurator CLI), `shellcheck`, `python3`/`jq`. The design spec is the contract; this plan executes it.

**Testing strategy (per task type):**
- **Go (collector defensive change):** strict TDD (failing test → impl → pass).
- **Helm templates:** `helm lint` + `helm template … | grep`/`yq` render-asserts. Where a kind cluster is up, `kubectl apply --dry-run=client` schema-validates.
- **Bash scripts:** `bash -n` + `shellcheck` + `--help`/dry-run where applicable.
- **Integration:** Task 18 spins kind, mints creds, installs the chart, runs throughput + chaos cells with auth — the live gate that catches any wrong NATS permission.

**Prerequisites the executor must have installed (verify before Task 1):** `helm`, `kubectl`, `kind`, `docker`, `go`, `shellcheck`, `jq`, `nsc`. `nsc` is the only addition vs. the previous plan; Task 1 installs it if missing. Confirm with `helm version && kubectl version --client && kind version && docker version && go version && shellcheck --version && jq --version && nsc --version`.

**Conventions:**
- Run all commands from the repo root `/media/hp/secondary/projects/gam-redis-pubsub` unless stated.
- The lab dir is `labs/redis-redpanda-connect-stress-k8s/` (abbreviated `$LAB` in examples; substitute literally when writing commands).
- Namespace is `rrcs-k8s`, release name is `rrcs`.
- Stream name is `APP_EVENTS`, durable consumer is `region-writer` (these MUST match what the gen script bakes into user JWT perms — see Task 1).
- Commit after each task with the message shown.

---

### Task 1: Install `nsc` (if missing), write `gen-nats-auth.sh`, mint and commit the lab fixtures

The script uses `nsc` to mint operator + account + three users (with the narrow JetStream perms from spec §3), generates the `MEMORY` resolver config via `nsc generate config --mem-resolver`, and writes all artifacts into `chart/files/nats-auth/`. Re-runnable; refuses to overwrite without `--force`.

**Files:**
- Create: `labs/redis-redpanda-connect-stress-k8s/scripts/gen-nats-auth.sh`
- Create (output of the script, committed): `labs/redis-redpanda-connect-stress-k8s/chart/files/nats-auth/{operator.jwt, APP.jwt, nats-server.conf, publisher.creds, subscriber.creds, admin.creds, README.md, .nsc-store/}`

- [ ] **Step 1: Install nsc if missing**

```bash
command -v nsc || curl -L https://raw.githubusercontent.com/nats-io/nsc/main/install.py | python3 -
nsc --version
```
Expected: a version line like `nsc version 2.x.x`. If install completes but `nsc` isn't on `PATH`, the installer prints the install location — add it to `~/.local/bin` or export `PATH` to include it.

- [ ] **Step 2: Create `labs/redis-redpanda-connect-stress-k8s/scripts/gen-nats-auth.sh`** with EXACTLY this content:

```bash
#!/usr/bin/env bash
# Mints the lab's operator/account/user JWTs + creds files via nsc.
# Output lands in chart/files/nats-auth/ (committed lab fixtures).
# Re-runnable; refuses to overwrite without --force.
#
# Env overrides (defaults match chart/values.yaml):
#   STREAM_NAME=APP_EVENTS        DURABLE_NAME=region-writer
#   OPERATOR_NAME=RRCS-OP         ACCOUNT_NAME=APP
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${LAB_DIR}"

FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0;;
    *) echo "unknown arg: $arg" >&2; exit 2;;
  esac
done

OUT="chart/files/nats-auth"
NSC_HOME_DIR="${OUT}/.nsc-store"
STREAM_NAME="${STREAM_NAME:-APP_EVENTS}"
DURABLE_NAME="${DURABLE_NAME:-region-writer}"
OPERATOR_NAME="${OPERATOR_NAME:-RRCS-OP}"
ACCOUNT_NAME="${ACCOUNT_NAME:-APP}"

if [[ -f "${OUT}/operator.jwt" && "${FORCE}" -ne 1 ]]; then
  echo "error: ${OUT}/ already populated. Pass --force to regenerate." >&2
  exit 1
fi

# Isolate nsc state under the lab dir; do NOT touch the user's global nsc store.
export NSC_HOME="${PWD}/${NSC_HOME_DIR}"
mkdir -p "${OUT}" "${NSC_HOME}"

if (( FORCE )); then
  rm -rf "${NSC_HOME}"
  mkdir -p "${NSC_HOME}"
fi

echo "[gen] operator ${OPERATOR_NAME}"
nsc add operator --name "${OPERATOR_NAME}" >/dev/null

echo "[gen] account ${ACCOUNT_NAME} (JetStream enabled, unlimited)"
nsc add account --name "${ACCOUNT_NAME}" >/dev/null
nsc edit account --name "${ACCOUNT_NAME}" \
  --js-streams -1 --js-consumer -1 \
  --js-mem-storage -1 --js-disk-storage -1 >/dev/null

echo "[gen] user publisher"
nsc add user --account "${ACCOUNT_NAME}" --name publisher \
  --allow-pub 'app.events.>' \
  --allow-pub '$JS.API.STREAM.INFO.'"${STREAM_NAME}" \
  --allow-sub '_INBOX.>' >/dev/null

echo "[gen] user subscriber"
nsc add user --account "${ACCOUNT_NAME}" --name subscriber \
  --allow-pub '$JS.ACK.'"${STREAM_NAME}"'.'"${DURABLE_NAME}"'.>' \
  --allow-pub '$JS.API.STREAM.INFO.'"${STREAM_NAME}" \
  --allow-pub '$JS.API.CONSUMER.DURABLE.CREATE.'"${STREAM_NAME}"'.'"${DURABLE_NAME}" \
  --allow-pub '$JS.API.CONSUMER.CREATE.'"${STREAM_NAME}"'.'"${DURABLE_NAME}" \
  --allow-pub '$JS.API.CONSUMER.CREATE.'"${STREAM_NAME}"'.'"${DURABLE_NAME}"'.>' \
  --allow-pub '$JS.API.CONSUMER.INFO.'"${STREAM_NAME}"'.'"${DURABLE_NAME}" \
  --allow-sub '_INBOX.>' >/dev/null

echo "[gen] user admin"
nsc add user --account "${ACCOUNT_NAME}" --name admin \
  --allow-pub '$JS.API.>' \
  --allow-sub '_INBOX.>' >/dev/null

echo "[gen] resolver config (MEMORY)"
nsc generate config --mem-resolver --config-file "${OUT}/nats-server.conf"

echo "[gen] export public JWTs"
nsc describe operator --field jwt --raw > "${OUT}/operator.jwt"
nsc describe account --name "${ACCOUNT_NAME}" --field jwt --raw > "${OUT}/${ACCOUNT_NAME}.jwt"

echo "[gen] creds files"
nsc generate creds --account "${ACCOUNT_NAME}" --name publisher  > "${OUT}/publisher.creds"
nsc generate creds --account "${ACCOUNT_NAME}" --name subscriber > "${OUT}/subscriber.creds"
nsc generate creds --account "${ACCOUNT_NAME}" --name admin      > "${OUT}/admin.creds"
chmod 600 "${OUT}"/*.creds

cat > "${OUT}/README.md" <<EOF
# rrcs-k8s NATS lab fixtures

Generated by \`scripts/gen-nats-auth.sh\`. **These are lab-only fixture
identities with NO real privilege; do NOT reuse for any other deployment.**

Hierarchy:
- Operator: ${OPERATOR_NAME}
- Account:  ${ACCOUNT_NAME} (JetStream enabled, unlimited)
- Users:    publisher, subscriber, admin

Stream/durable bound into the user JWT permissions:
- Stream:  ${STREAM_NAME}
- Durable: ${DURABLE_NAME}

To rotate or change stream/durable names: rerun with --force.

In production, signing keys live in a secret manager (Vault / External
Secrets / SealedSecrets) and user creds are provisioned into K8s Secrets
out-of-band — that's exactly what the chart's external-mode consumes.
EOF

echo "[done] artifacts in ${OUT}/"
ls "${OUT}"
```

- [ ] **Step 3: Make the script executable and run it once**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
chmod +x scripts/gen-nats-auth.sh
bash -n scripts/gen-nats-auth.sh && echo "syntax OK"
shellcheck scripts/gen-nats-auth.sh && echo "shellcheck clean"
scripts/gen-nats-auth.sh
```
Expected: `syntax OK`, `shellcheck clean`, then `[gen]` lines for operator/account/users, the resolver config, exports, creds, and a final `ls` showing `APP.jwt operator.jwt nats-server.conf publisher.creds subscriber.creds admin.creds README.md`.

- [ ] **Step 4: Verify the artifacts are usable**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
# Resolver config has the three required pieces
grep -q "^operator:" chart/files/nats-auth/nats-server.conf && echo "operator OK"
grep -q "^resolver: MEMORY" chart/files/nats-auth/nats-server.conf && echo "MEMORY resolver OK"
grep -q "resolver_preload" chart/files/nats-auth/nats-server.conf && echo "preload OK"
# Each .creds file has the expected JWT+nkey structure
for f in publisher subscriber admin; do
  grep -q "BEGIN NATS USER JWT" "chart/files/nats-auth/${f}.creds" && \
  grep -q "BEGIN USER NKEY SEED" "chart/files/nats-auth/${f}.creds" && \
    echo "${f}.creds OK"
done
# Subscriber's narrow CONSUMER perms are baked into its JWT
nsc describe user --account APP --name subscriber --field 'nats.pub.allow' 2>/dev/null | grep -q "CONSUMER.INFO.APP_EVENTS.region-writer" && echo "subscriber CONSUMER.INFO perm OK"
```
Expected: `operator OK`, `MEMORY resolver OK`, `preload OK`, three `.creds OK` lines, and `subscriber CONSUMER.INFO perm OK`.

- [ ] **Step 5: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-connect-stress-k8s/scripts/gen-nats-auth.sh \
        labs/redis-redpanda-connect-stress-k8s/chart/files/nats-auth/
git commit -m "rrcs-k8s: gen-nats-auth.sh + lab-fixture creds (operator/account/3 users)"
```

---

### Task 2: Expand `chart/values.yaml` with the new auth + external + topic surface

Adds the values keys §4 of the spec specifies, with safe defaults (`external.enabled: false`, bundled-mode creds Secret names matching what Task 5 will render). Keeps `helm lint` clean.

**Files:**
- Modify: `labs/redis-redpanda-connect-stress-k8s/chart/values.yaml`

- [ ] **Step 1: Replace the `nats:` and `redis:` blocks in `chart/values.yaml`**

Read the file first, then use Edit to replace the relevant blocks. The full new `nats:` block:

```yaml
nats:
  external:
    enabled: false                # bundled (default) → chart deploys NATS + mints creds
    url: ""                       # required when enabled, e.g. "nats://nats.prod.example.com:4222"
    monitorUrl: ""                # optional; "" → collector skips /jsz queries, harness skips chaos pre-flight
    auth:
      publisherSecret: ""         # pre-created Secret name, key: user.creds
      subscriberSecret: ""
      adminSecret: ""             # optional; "" → harness purge is skipped with warning
  # ── bundled-mode config below; ignored when external.enabled=true ──
  image: nats:2.10-alpine
  clientPort: 4222
  monitorPort: 8222
  stream:
    name: APP_EVENTS                                       # JetStream stream name
    subjects: "app.events.>"                               # subjects the stream binds to
    publishSubject: "app.events.${! meta(\"pattern\") }"   # what connect-source publishes to
    consumer:
      durable: "region-writer"                             # durable consumer name connect-sink uses
    maxAge: "1h"
    maxBytes: "256MB"
    maxMsgSize: "1MB"
    dupeWindow: "5m"
  persistence:
    mode: emptyDir
    size: 4Gi
    storageClassName: ""
  auth:                            # bundled-mode rendered creds Secrets + in-pod mount paths
    secrets:
      publisher: publisher-creds
      subscriber: subscriber-creds
      admin: admin-creds
    creds:
      publisher: /etc/nats-creds/publisher/user.creds
      subscriber: /etc/nats-creds/subscriber/user.creds
      admin: /etc/nats-creds/admin/user.creds
```

The full new `redis:` block:

```yaml
redis:
  image: redis:7.4-alpine          # used only in bundled mode
  central:
    external:
      enabled: false
      url: ""                      # required when enabled, e.g. "redis://redis.prod:6379"
      authSecret: ""               # RESERVED — v1 does NOT consume it (see spec §2 non-goals)
  region:
    external:
      enabled: false
      url: ""
      authSecret: ""               # RESERVED — v1 does NOT consume it
```

The existing `natsBox`, `connect`, `writer`, `collector`, `scheduling`, and `resources` blocks stay unchanged.

- [ ] **Step 2: Lint and render**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
helm lint chart/ 2>&1 | tail -1
helm template rrcs chart/ -n rrcs-k8s >/dev/null && echo "render OK"
```
Expected: `1 chart(s) linted, 0 chart(s) failed` and `render OK`. (Existing templates don't reference the new keys yet, so render is unchanged.)

- [ ] **Step 3: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-connect-stress-k8s/chart/values.yaml
git commit -m "rrcs-k8s: values.yaml expanded for creds-auth + external-mode + topic config"
```

---

### Task 3: Add the new `_helpers.tpl` templates (URL + creds-Secret + hostPort resolvers)

Adds the helpers §5.1 / §13.1 of the spec specify: `rrcs.nats.url`, `rrcs.nats.monitorUrl`, `rrcs.redis.{central,region}.url`, `rrcs.redis.{central,region}.hostPort`, `rrcs.nats.credsSecret.{publisher,subscriber,admin}`.

**Files:**
- Modify: `labs/redis-redpanda-connect-stress-k8s/chart/templates/_helpers.tpl`

- [ ] **Step 1: Append the new defines to `_helpers.tpl`** (preserve all four existing helpers `rrcs.image`, `rrcs.pullPolicy`, `rrcs.imagePullSecrets`, `rrcs.scheduling`):

```yaml
{{/*
rrcs.nats.url — client URL. Bundled: in-cluster Service. External: user-supplied.
Usage: {{ include "rrcs.nats.url" . }}
*/}}
{{- define "rrcs.nats.url" -}}
{{- if .Values.nats.external.enabled -}}
{{- required "nats.external.url is required when nats.external.enabled=true" .Values.nats.external.url -}}
{{- else -}}
nats://nats:{{ .Values.nats.clientPort }}
{{- end -}}
{{- end -}}

{{/*
rrcs.nats.monitorUrl — HTTP /jsz endpoint. Bundled: in-cluster Service.
External: user-supplied; returns "" if unset (callers gate).
*/}}
{{- define "rrcs.nats.monitorUrl" -}}
{{- if .Values.nats.external.enabled -}}
{{- .Values.nats.external.monitorUrl -}}
{{- else -}}
http://nats:{{ .Values.nats.monitorPort }}
{{- end -}}
{{- end -}}

{{/*
rrcs.redis.central.url / rrcs.redis.region.url — connection URL form.
*/}}
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

{{/*
rrcs.redis.{central,region}.hostPort — host:port form (URL scheme stripped),
for the writer's REDIS_ADDR env, the collector's --redis-* flags, and the
init-container redis-cli ping.
*/}}
{{- define "rrcs.redis.central.hostPort" -}}
{{- $u := include "rrcs.redis.central.url" . -}}
{{- regexReplaceAll "^rediss?://" $u "" -}}
{{- end -}}

{{- define "rrcs.redis.region.hostPort" -}}
{{- $u := include "rrcs.redis.region.url" . -}}
{{- regexReplaceAll "^rediss?://" $u "" -}}
{{- end -}}

{{/*
rrcs.nats.credsSecret.{publisher,subscriber,admin} — Secret name to mount.
Bundled: the chart-rendered Secret name from values. External: user-supplied
Secret name (may be empty for admin, in which case purge is skipped).
*/}}
{{- define "rrcs.nats.credsSecret.publisher" -}}
{{- if .Values.nats.external.enabled -}}
{{- required "nats.external.auth.publisherSecret is required when external" .Values.nats.external.auth.publisherSecret -}}
{{- else -}}
{{- .Values.nats.auth.secrets.publisher -}}
{{- end -}}
{{- end -}}

{{- define "rrcs.nats.credsSecret.subscriber" -}}
{{- if .Values.nats.external.enabled -}}
{{- required "nats.external.auth.subscriberSecret is required when external" .Values.nats.external.auth.subscriberSecret -}}
{{- else -}}
{{- .Values.nats.auth.secrets.subscriber -}}
{{- end -}}
{{- end -}}

{{- define "rrcs.nats.credsSecret.admin" -}}
{{- if .Values.nats.external.enabled -}}
{{- .Values.nats.external.auth.adminSecret -}}
{{- else -}}
{{- .Values.nats.auth.secrets.admin -}}
{{- end -}}
{{- end -}}
```

- [ ] **Step 2: Lint and exercise the helpers via a tiny inline test template**

The helpers are only invoked by other templates (Tasks 4-13), so direct exercise needs a temp probe. Use `helm template` with `--show-only` plus a one-shot ad-hoc template — simpler: add a temporary `chart/templates/_probe.yaml` that ConfigMap-renders helper outputs, run asserts, then delete it.

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
cat > chart/templates/_probe.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata: { name: helper-probe }
data:
  nats_url:           "{{ include "rrcs.nats.url" . }}"
  nats_monitor:       "{{ include "rrcs.nats.monitorUrl" . }}"
  redis_central_url:  "{{ include "rrcs.redis.central.url" . }}"
  redis_central_hp:   "{{ include "rrcs.redis.central.hostPort" . }}"
  redis_region_hp:    "{{ include "rrcs.redis.region.hostPort" . }}"
  publisher_secret:   "{{ include "rrcs.nats.credsSecret.publisher" . }}"
  subscriber_secret:  "{{ include "rrcs.nats.credsSecret.subscriber" . }}"
  admin_secret:       "{{ include "rrcs.nats.credsSecret.admin" . }}"
EOF

echo "=== bundled (default) ===" 
helm template rrcs chart/ -n rrcs-k8s -s templates/_probe.yaml
echo "=== external NATS ===" 
helm template rrcs chart/ -n rrcs-k8s -s templates/_probe.yaml \
  --set nats.external.enabled=true \
  --set nats.external.url=nats://corp:4222 \
  --set nats.external.auth.publisherSecret=my-pub \
  --set nats.external.auth.subscriberSecret=my-sub
echo "=== external Redis ===" 
helm template rrcs chart/ -n rrcs-k8s -s templates/_probe.yaml \
  --set redis.central.external.enabled=true \
  --set redis.central.external.url=redis://corp-cache:6379 \
  --set redis.region.external.enabled=true \
  --set redis.region.external.url=rediss://corp-cache2:6380

rm chart/templates/_probe.yaml
helm lint chart/ 2>&1 | tail -1
```
Expected (key lines):
- Bundled: `nats_url: "nats://nats:4222"`, `redis_central_hp: "redis-central:6379"`, `publisher_secret: "publisher-creds"`.
- External NATS: `nats_url: "nats://corp:4222"`, `publisher_secret: "my-pub"`, `admin_secret: ""` (when unset).
- External Redis: `redis_central_hp: "corp-cache:6379"`, `redis_region_hp: "corp-cache2:6380"` (TLS scheme stripped).
- After cleanup: `1 chart(s) linted, 0 chart(s) failed`.

- [ ] **Step 3: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-connect-stress-k8s/chart/templates/_helpers.tpl
git commit -m "rrcs-k8s: _helpers.tpl adds URL + creds-Secret + hostPort resolvers"
```

---

### Task 4: New ConfigMap template `nats-config-cm.yaml` (bundled-only)

Renders `nats-server.conf` from `chart/files/nats-auth/nats-server.conf` (produced in Task 1) combined with the lab's port/JetStream knobs. Guarded by `{{- if not .Values.nats.external.enabled }}`.

**Files:**
- Create: `labs/redis-redpanda-connect-stress-k8s/chart/templates/nats-config-cm.yaml`

- [ ] **Step 1: Create the file with EXACTLY:**

```yaml
{{- if not .Values.nats.external.enabled }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: nats-config
  labels: { app: nats }
data:
  nats-server.conf: |-
    server_name: rrcs-nats
    port: {{ .Values.nats.clientPort }}
    http_port: {{ .Values.nats.monitorPort }}
    jetstream {
      store_dir: /data
    }
{{ .Files.Get "files/nats-auth/nats-server.conf" | indent 4 }}
{{- end }}
```

- [ ] **Step 2: Render-assert (bundled renders, external skips)**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
echo "=== bundled: ConfigMap present + has resolver ==="
helm template rrcs chart/ -n rrcs-k8s -s templates/nats-config-cm.yaml | grep -E "kind: ConfigMap|resolver: MEMORY|^    operator:" | head -5
echo "=== external: skipped ==="
helm template rrcs chart/ -n rrcs-k8s -s templates/nats-config-cm.yaml \
  --set nats.external.enabled=true \
  --set nats.external.url=nats://x:4222 \
  --set nats.external.auth.publisherSecret=p \
  --set nats.external.auth.subscriberSecret=s \
  | wc -l
```
Expected: bundled shows the three matched lines (kind, resolver, operator). External output is 0 lines (`if not external.enabled` evaluates false → empty).

- [ ] **Step 3: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-connect-stress-k8s/chart/templates/nats-config-cm.yaml
git commit -m "rrcs-k8s: nats-config-cm.yaml (bundled-only) embeds resolver from files"
```

---

### Task 5: New Secrets template `nats-auth-secrets.yaml` (bundled-only)

Renders three K8s Secrets (publisher/subscriber/admin) from the committed `.creds` files. Guarded by `{{- if not .Values.nats.external.enabled }}`.

**Files:**
- Create: `labs/redis-redpanda-connect-stress-k8s/chart/templates/nats-auth-secrets.yaml`

- [ ] **Step 1: Create the file with EXACTLY:**

```yaml
{{- if not .Values.nats.external.enabled }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ .Values.nats.auth.secrets.publisher }}
  labels: { app: nats-auth, role: publisher }
type: Opaque
data:
  user.creds: {{ .Files.Get "files/nats-auth/publisher.creds" | b64enc | quote }}
---
apiVersion: v1
kind: Secret
metadata:
  name: {{ .Values.nats.auth.secrets.subscriber }}
  labels: { app: nats-auth, role: subscriber }
type: Opaque
data:
  user.creds: {{ .Files.Get "files/nats-auth/subscriber.creds" | b64enc | quote }}
---
apiVersion: v1
kind: Secret
metadata:
  name: {{ .Values.nats.auth.secrets.admin }}
  labels: { app: nats-auth, role: admin }
type: Opaque
data:
  user.creds: {{ .Files.Get "files/nats-auth/admin.creds" | b64enc | quote }}
{{- end }}
```

- [ ] **Step 2: Render-assert (three Secrets bundled; skipped external)**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
echo "=== bundled: three Secrets, each with user.creds key ==="
helm template rrcs chart/ -n rrcs-k8s -s templates/nats-auth-secrets.yaml | grep -E "kind: Secret|^  name:|user\.creds:" | head -12
echo "=== external: skipped ==="
helm template rrcs chart/ -n rrcs-k8s -s templates/nats-auth-secrets.yaml \
  --set nats.external.enabled=true \
  --set nats.external.url=nats://x:4222 \
  --set nats.external.auth.publisherSecret=p \
  --set nats.external.auth.subscriberSecret=s | wc -l
```
Expected: three `kind: Secret`, three `name:` lines for `publisher-creds`/`subscriber-creds`/`admin-creds`, three `user.creds:` keys. External: 0 lines.

- [ ] **Step 3: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-connect-stress-k8s/chart/templates/nats-auth-secrets.yaml
git commit -m "rrcs-k8s: nats-auth-secrets.yaml (bundled-only) renders 3 creds Secrets"
```

---

### Task 6: Update `nats.yaml` — config-file mode + ConfigMap mount + external guard

NATS server switches from CLI args to a config file. The Deployment + Service are wrapped in `{{- if not .Values.nats.external.enabled }}`.

**Files:**
- Modify: `labs/redis-redpanda-connect-stress-k8s/chart/templates/nats.yaml`

- [ ] **Step 1: Edit `chart/templates/nats.yaml`**

Wrap the entire file body (including the existing `{{- if eq .Values.nats.persistence.mode "pvc" }}` PVC block, the `Deployment`, and the `Service`) in `{{- if not .Values.nats.external.enabled }} ... {{- end }}`. Inside the Deployment's container spec, replace:

```yaml
          args: ["-js", "-sd", "/data", "-m", "{{ .Values.nats.monitorPort }}"]
```
with:
```yaml
          args: ["-c", "/etc/nats/nats-server.conf"]
```

And add a new `volumeMount` for the config file (alongside the existing `data` mount):
```yaml
          volumeMounts:
            - name: data
              mountPath: /data
            - name: config
              mountPath: /etc/nats/nats-server.conf
              subPath: nats-server.conf
              readOnly: true
```

And add the matching pod-level volume (alongside the existing `data` volume):
```yaml
      volumes:
        - name: data
        {{- if eq .Values.nats.persistence.mode "pvc" }}
          persistentVolumeClaim:
            claimName: nats-data
        {{- else }}
          emptyDir: {}
        {{- end }}
        - name: config
          configMap:
            name: nats-config
```

The probes (readinessProbe/livenessProbe on `/healthz`), `imagePullSecrets`, `scheduling`, `resources`, and the Service definition stay unchanged.

- [ ] **Step 2: Render-assert**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
echo "=== bundled: nats Deployment uses config file + mounts ConfigMap ==="
helm template rrcs chart/ -n rrcs-k8s -s templates/nats.yaml | grep -E '"-c"|/etc/nats/nats-server.conf|configMap:|name: nats-config' | head -8
echo "=== external: Deployment + Service skipped ==="
helm template rrcs chart/ -n rrcs-k8s -s templates/nats.yaml \
  --set nats.external.enabled=true \
  --set nats.external.url=nats://x:4222 \
  --set nats.external.auth.publisherSecret=p \
  --set nats.external.auth.subscriberSecret=s | wc -l
```
Expected: bundled shows `args: ["-c", "/etc/nats/nats-server.conf"]`, the mountPath, the configMap volume, and `name: nats-config`. External: 0 lines.

- [ ] **Step 3: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-connect-stress-k8s/chart/templates/nats.yaml
git commit -m "rrcs-k8s: nats.yaml uses config file + ConfigMap mount; guarded by external flag"
```

---

### Task 7: Update `nats-init-job.yaml` — admin creds mount + `--creds` on every nats call + external guard

The init Job mounts the admin Secret and adds `--creds` to every `nats` invocation. Guarded by `{{- if not .Values.nats.external.enabled }}` (in external mode the user pre-provisions the stream).

**Files:**
- Modify: `labs/redis-redpanda-connect-stress-k8s/chart/templates/nats-init-job.yaml`

- [ ] **Step 1: Edit the file**

Wrap the entire `Job` resource in `{{- if not .Values.nats.external.enabled }} ... {{- end }}`. In the spec.template.spec, add a `volumes:` block referencing the admin Secret, and add `volumeMounts:` to both the initContainer (`wait-nats`) and the main container (`create-stream`). Modify every `nats` CLI invocation to include `--creds`.

Pod spec gains:
```yaml
      volumes:
        - name: admin-creds
          secret:
            secretName: {{ include "rrcs.nats.credsSecret.admin" . }}
            defaultMode: 0400
```

Both containers add:
```yaml
          volumeMounts:
            - name: admin-creds
              mountPath: /etc/nats-creds/admin
              readOnly: true
```

The initContainer's `args` become:
```yaml
          args:
            - |
              until nats --server nats://nats:{{ .Values.nats.clientPort }} --creds /etc/nats-creds/admin/user.creds rtt >/dev/null 2>&1; do
                echo "waiting for nats..."; sleep 1;
              done
```

The main container's `args` become (note `--creds` added to every nats call):
```yaml
          args:
            - |
              set -e
              SERVER="nats://nats:{{ .Values.nats.clientPort }}"
              CREDS="/etc/nats-creds/admin/user.creds"
              if nats --server "$SERVER" --creds "$CREDS" stream info {{ .Values.nats.stream.name }} >/dev/null 2>&1; then
                echo "{{ .Values.nats.stream.name }} already exists"
              else
                nats --server "$SERVER" --creds "$CREDS" stream add {{ .Values.nats.stream.name }} \
                  --subjects '{{ .Values.nats.stream.subjects }}' \
                  --storage file \
                  --replicas 1 \
                  --retention limits \
                  --discard old \
                  --max-age {{ .Values.nats.stream.maxAge }} \
                  --max-bytes {{ .Values.nats.stream.maxBytes }} \
                  --max-msgs=-1 \
                  --max-msg-size={{ .Values.nats.stream.maxMsgSize }} \
                  --dupe-window {{ .Values.nats.stream.dupeWindow }} \
                  --defaults
              fi
              nats --server "$SERVER" --creds "$CREDS" stream info {{ .Values.nats.stream.name }}
```

The hash-suffixed Job name (from the prior fix), `backoffLimit`, `restartPolicy: OnFailure`, `imagePullSecrets`, `scheduling`, `resources` all stay unchanged.

- [ ] **Step 2: Render-assert**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
echo "=== bundled: admin Secret mounted + every nats call has --creds ==="
helm template rrcs chart/ -n rrcs-k8s -s templates/nats-init-job.yaml | grep -E "secretName: admin-creds|--creds /etc/nats-creds/admin/user.creds|nats --server.*--creds" | head -8
echo "=== bundled: count of nats CLI invocations (rtt + info + add + final info = 4) ==="
helm template rrcs chart/ -n rrcs-k8s -s templates/nats-init-job.yaml | grep -c '^[[:space:]]*nats --server\|^[[:space:]]*until nats'
echo "=== external: Job skipped ==="
helm template rrcs chart/ -n rrcs-k8s -s templates/nats-init-job.yaml \
  --set nats.external.enabled=true \
  --set nats.external.url=nats://x:4222 \
  --set nats.external.auth.publisherSecret=p \
  --set nats.external.auth.subscriberSecret=s | wc -l
```
Expected: bundled shows the `secretName: admin-creds` line, the mount path, and at least 4 lines containing `nats --server` (one in initContainer `until`, three in main container). Count: 4. External: 0 lines.

- [ ] **Step 3: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-connect-stress-k8s/chart/templates/nats-init-job.yaml
git commit -m "rrcs-k8s: nats-init-job mounts admin creds, all CLI calls --creds-aware; external guard"
```

---

### Task 8: Guard `redis-central.yaml` and `redis-region.yaml` with their respective external flags

Wrap each redis Deployment+Service in `{{- if not .Values.redis.{central,region}.external.enabled }} ... {{- end }}`.

**Files:**
- Modify: `labs/redis-redpanda-connect-stress-k8s/chart/templates/redis-central.yaml`
- Modify: `labs/redis-redpanda-connect-stress-k8s/chart/templates/redis-region.yaml`

- [ ] **Step 1: Wrap `redis-central.yaml`**

Add `{{- if not .Values.redis.central.external.enabled }}` at the very top (line 1) and `{{- end }}` at the very bottom. No other content changes.

- [ ] **Step 2: Wrap `redis-region.yaml` identically with `.region.external.enabled`**

Same treatment, but for `region`.

- [ ] **Step 3: Render-assert**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
echo "=== bundled: both redis Deployments + Services present ==="
helm template rrcs chart/ -n rrcs-k8s | grep -E "name: redis-(central|region)$" | sort -u
echo "=== external central only: central skipped, region present ==="
helm template rrcs chart/ -n rrcs-k8s --set redis.central.external.enabled=true --set redis.central.external.url=redis://x:6379 \
  | grep -E "name: redis-(central|region)$" | sort -u
echo "=== external both: neither rendered ==="
helm template rrcs chart/ -n rrcs-k8s \
  --set redis.central.external.enabled=true --set redis.central.external.url=redis://x:6379 \
  --set redis.region.external.enabled=true --set redis.region.external.url=redis://y:6379 \
  | grep -E "name: redis-(central|region)$" | wc -l
```
Expected: bundled shows both `name: redis-central` and `name: redis-region`. External central: only `name: redis-region`. External both: 0.

- [ ] **Step 4: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-connect-stress-k8s/chart/templates/redis-central.yaml \
        labs/redis-redpanda-connect-stress-k8s/chart/templates/redis-region.yaml
git commit -m "rrcs-k8s: guard redis Deployments with .external.enabled"
```

---

### Task 9: Switch `connect-configmaps.yaml` to `tpl`-render the connect YAMLs

Changes the ConfigMap template so each connect YAML is processed as a Helm template after being read. The connect YAMLs themselves don't have any `{{ }}` yet (verified in spec §14), so the change is a no-op until Task 10 adds template directives.

**Files:**
- Modify: `labs/redis-redpanda-connect-stress-k8s/chart/templates/connect-configmaps.yaml`

- [ ] **Step 1: Edit `chart/templates/connect-configmaps.yaml`**

Replace the existing two `{{ .Files.Get ... | indent 4 }}` lines so they become `{{ tpl (.Files.Get ...) . | indent 4 }}`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: connect-source-config
  labels: { app: connect-source }
data:
  connect.yaml: |-
{{ tpl (.Files.Get (printf "files/connect/%s-forward.yaml" .Values.profile)) . | indent 4 }}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: connect-sink-config
  labels: { app: connect-sink }
data:
  connect.yaml: |-
{{ tpl (.Files.Get (printf "files/connect/%s-reverse.yaml" .Values.profile)) . | indent 4 }}
```

- [ ] **Step 2: Render-assert (still renders identically since YAMLs have no `{{`)**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
helm template rrcs chart/ -n rrcs-k8s --set profile=alo | grep -q "redis://redis-central:6379" && echo "alo unchanged OK"
helm template rrcs chart/ -n rrcs-k8s --set profile=eoe -s templates/connect-configmaps.yaml | grep -c "connect.yaml"
```
Expected: `alo unchanged OK`, and the eoe count is `2`.

- [ ] **Step 3: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-connect-stress-k8s/chart/templates/connect-configmaps.yaml
git commit -m "rrcs-k8s: connect-configmaps uses tpl so YAMLs become Helm-template-aware"
```

---

### Task 10: Template the 6 connect YAMLs (urls, subjects, stream/durable, auth, redis URLs)

Each of the six `chart/files/connect/{alo,amo,eoe}-{forward,reverse}.yaml` gets Helm directives for: NATS URL, NATS subject (forward) / subjects (reverse), stream name (reverse only), durable (reverse only), `auth: user_credentials_file` block, and the Redis URL. Bloblang `${! }` is untouched.

**Files:**
- Modify: `labs/redis-redpanda-connect-stress-k8s/chart/files/connect/alo-forward.yaml`
- Modify: `labs/redis-redpanda-connect-stress-k8s/chart/files/connect/alo-reverse.yaml`
- Modify: `labs/redis-redpanda-connect-stress-k8s/chart/files/connect/amo-forward.yaml`
- Modify: `labs/redis-redpanda-connect-stress-k8s/chart/files/connect/amo-reverse.yaml`
- Modify: `labs/redis-redpanda-connect-stress-k8s/chart/files/connect/eoe-forward.yaml`
- Modify: `labs/redis-redpanda-connect-stress-k8s/chart/files/connect/eoe-reverse.yaml`

- [ ] **Step 1: Patch all three FORWARD YAMLs** (`alo-forward.yaml`, `amo-forward.yaml`, `eoe-forward.yaml`)

In each forward file:
- The `redis_streams.url` line `url: redis://redis-central:6379` → `url: {{ include "rrcs.redis.central.url" . }}`
- The `nats_jetstream.urls` line `urls: [nats://nats:4222]` → `urls: ["{{ include "rrcs.nats.url" . }}"]`
- The `nats_jetstream.subject` line `subject: app.events.${! meta("pattern") }` → `subject: {{ .Values.nats.stream.publishSubject | quote }}`
- Add an `auth:` block under `nats_jetstream:` (after `urls:`):
  ```yaml
      auth:
        user_credentials_file: {{ .Values.nats.auth.creds.publisher | quote }}
  ```

Concrete: after editing, `alo-forward.yaml`'s output block becomes:
```yaml
output:
  label: jetstream_sink
  nats_jetstream:
    urls: ["{{ include "rrcs.nats.url" . }}"]
    auth:
      user_credentials_file: {{ .Values.nats.auth.creds.publisher | quote }}
    subject: {{ .Values.nats.stream.publishSubject | quote }}
    headers:
      Nats-Msg-Id: ${! meta("event_id") }
      Content-Type: application/json
    max_in_flight: 256
```
(`amo-forward.yaml` keeps its no-`Nats-Msg-Id` AMO variant; same shape change otherwise. `eoe-forward.yaml` is identical to `alo-forward.yaml`'s output block.)

The input/`redis_streams.url` change applies to all three.

- [ ] **Step 2: Patch all three REVERSE YAMLs** (`alo-reverse.yaml`, `amo-reverse.yaml`, `eoe-reverse.yaml`)

In each reverse file:
- The `nats_jetstream.urls` line → `urls: ["{{ include "rrcs.nats.url" . }}"]`
- The `nats_jetstream.subject` line `subject: app.events.>` → `subject: {{ .Values.nats.stream.subjects | quote }}`
- For ALO and EOE (which have a `durable:` field): add `stream: {{ .Values.nats.stream.name | quote }}` ABOVE the `durable:` line, and replace `durable: region-writer` → `durable: {{ .Values.nats.stream.consumer.durable | quote }}`.
- For AMO (no `durable:` field — ephemeral consumer): add `stream: {{ .Values.nats.stream.name | quote }}` as a sibling to `subject:`. No `durable:` change (it doesn't exist).
- Add `auth:` block under `nats_jetstream:`:
  ```yaml
      auth:
        user_credentials_file: {{ .Values.nats.auth.creds.subscriber | quote }}
  ```
- Both `redis://redis-region:6379` references (in the `redis_streams` output AND the `cache_resources` block — and in `eoe-reverse.yaml` the additional `dedup_cache` resource) → `{{ include "rrcs.redis.region.url" . }}`.

Concrete: `alo-reverse.yaml`'s input block becomes:
```yaml
input:
  label: jetstream_source
  nats_jetstream:
    urls: ["{{ include "rrcs.nats.url" . }}"]
    auth:
      user_credentials_file: {{ .Values.nats.auth.creds.subscriber | quote }}
    subject: {{ .Values.nats.stream.subjects | quote }}
    stream: {{ .Values.nats.stream.name | quote }}
    durable: {{ .Values.nats.stream.consumer.durable | quote }}
    deliver: all
    ack_wait: 30s
```

`amo-reverse.yaml`'s input block (ephemeral consumer, no `durable:`):
```yaml
input:
  label: jetstream_source
  nats_jetstream:
    urls: ["{{ include "rrcs.nats.url" . }}"]
    auth:
      user_credentials_file: {{ .Values.nats.auth.creds.subscriber | quote }}
    subject: {{ .Values.nats.stream.subjects | quote }}
    stream: {{ .Values.nats.stream.name | quote }}
    deliver: new
    ack_wait: 2s
```

`eoe-reverse.yaml`'s input block: identical to `alo-reverse.yaml` (it has the same `durable: region-writer`, `deliver: all`, `ack_wait: 30s`).

The output `redis_streams` blocks for all three reverse files:
```yaml
      - redis_streams:
          url: {{ include "rrcs.redis.region.url" . }}
          stream: region-events
          ...
```

The `cache_resources` blocks (and `eoe-reverse.yaml`'s extra `dedup_cache`):
```yaml
cache_resources:
  - label: region_kv
    redis:
      url: {{ include "rrcs.redis.region.url" . }}
      kind: simple
```

- [ ] **Step 3: Render-assert (default profile=alo and one external override)**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
echo "=== alo bundled — auth + URLs templated ==="
helm template rrcs chart/ -n rrcs-k8s --set profile=alo -s templates/connect-configmaps.yaml \
  | grep -E "user_credentials_file:|urls:|subject:|durable:|stream:|url: redis://" | head -20

echo "=== amo bundled (ephemeral consumer, no durable) ==="
helm template rrcs chart/ -n rrcs-k8s --set profile=amo -s templates/connect-configmaps.yaml \
  | grep -E "durable:" | wc -l

echo "=== eoe bundled (durable + dedup_cache region URL) ==="
helm template rrcs chart/ -n rrcs-k8s --set profile=eoe -s templates/connect-configmaps.yaml \
  | grep -E "durable:|dedup_cache|url: redis://redis-region:6379" | head -5

echo "=== external NATS URL flows in ==="
helm template rrcs chart/ -n rrcs-k8s --set profile=alo -s templates/connect-configmaps.yaml \
  --set nats.external.enabled=true --set nats.external.url=nats://corp:4222 \
  --set nats.external.auth.publisherSecret=p --set nats.external.auth.subscriberSecret=s \
  | grep -E "urls:" | head -2

echo "=== custom stream name flows in ==="
helm template rrcs chart/ -n rrcs-k8s --set profile=alo --set nats.stream.name=MY_STREAM \
  -s templates/connect-configmaps.yaml | grep "stream: " | head -2
```
Expected:
- alo: shows `user_credentials_file:`, the templated URL `nats://nats:4222`, the published subject Bloblang expression, `durable: "region-writer"`, `stream: "APP_EVENTS"`, and `url: redis://redis-central:6379` / `redis://redis-region:6379`.
- amo: 0 `durable:` lines (AMO is ephemeral).
- eoe: `durable: "region-writer"`, `dedup_cache` present, region URL in BOTH cache_resources entries.
- External: `urls: ["nats://corp:4222"]`.
- Custom stream: `stream: "MY_STREAM"`.

- [ ] **Step 4: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-connect-stress-k8s/chart/files/connect/
git commit -m "rrcs-k8s: connect YAMLs templated for url/subjects/stream/durable/auth/redis URL"
```

---

### Task 11: Update `connect-source.yaml` and `connect-sink.yaml` — mount creds, init `wait-stream` uses --creds

Each connect pod mounts its role-specific creds Secret (resolved via helper, so external mode picks up the user-supplied Secret name). The `wait-stream` initContainer uses that pod's own creds to call `nats stream info` — which works because of the narrow `$JS.API.STREAM.INFO.<stream>` perm in publisher/subscriber JWTs.

**Files:**
- Modify: `labs/redis-redpanda-connect-stress-k8s/chart/templates/connect-source.yaml`
- Modify: `labs/redis-redpanda-connect-stress-k8s/chart/templates/connect-sink.yaml`

- [ ] **Step 1: Edit `connect-source.yaml`**

Add a `volumes:` block (alongside the existing `config` ConfigMap volume) for the publisher creds Secret. Add a `volumeMounts:` for it on the main container. Update the `wait-stream` initContainer to also mount the publisher creds and pass `--creds`.

Pod-level `volumes:` becomes:
```yaml
      volumes:
        - name: config
          configMap:
            name: connect-source-config
        - name: nats-creds
          secret:
            secretName: {{ include "rrcs.nats.credsSecret.publisher" . }}
            defaultMode: 0400
```

Main container `volumeMounts:` becomes:
```yaml
          volumeMounts:
            - name: config
              mountPath: /connect.yaml
              subPath: connect.yaml
            - name: nats-creds
              mountPath: /etc/nats-creds/publisher
              readOnly: true
```

The `wait-stream` initContainer changes from:
```yaml
        - name: wait-stream
          image: {{ include "rrcs.image" (dict "root" $ "ref" .Values.natsBox.image) }}
          imagePullPolicy: {{ .Values.images.pullPolicy }}
          command: ["/bin/sh", "-c"]
          args:
            - until nats --server nats://nats:{{ .Values.nats.clientPort }} stream info {{ .Values.nats.stream.name }} >/dev/null 2>&1; do echo waiting stream; sleep 1; done
```
to:
```yaml
        - name: wait-stream
          image: {{ include "rrcs.image" (dict "root" $ "ref" .Values.natsBox.image) }}
          imagePullPolicy: {{ .Values.images.pullPolicy }}
          command: ["/bin/sh", "-c"]
          args:
            - until nats --server {{ include "rrcs.nats.url" . | quote }} --creds /etc/nats-creds/publisher/user.creds stream info {{ .Values.nats.stream.name }} >/dev/null 2>&1; do echo waiting stream; sleep 1; done
          volumeMounts:
            - name: nats-creds
              mountPath: /etc/nats-creds/publisher
              readOnly: true
```

The `wait-redis-central` initContainer stays unchanged for v1 (external Redis no-auth per spec §2; just keep the unauthenticated ping). The probes, ports, command, resources, image are unchanged.

- [ ] **Step 2: Edit `connect-sink.yaml`** with the same shape but using subscriber creds:

- Volumes use `{{ include "rrcs.nats.credsSecret.subscriber" . }}`.
- Main container `volumeMounts` mounts at `/etc/nats-creds/subscriber`.
- `wait-stream` initContainer uses `--creds /etc/nats-creds/subscriber/user.creds`.
- `wait-redis-region` initContainer unchanged for v1.

- [ ] **Step 3: Render-assert**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
echo "=== source: publisher creds mount + wait-stream uses --creds ==="
helm template rrcs chart/ -n rrcs-k8s -s templates/connect-source.yaml \
  | grep -E "secretName: publisher-creds|mountPath: /etc/nats-creds/publisher|--creds /etc/nats-creds/publisher/user.creds" | head -6

echo "=== sink: subscriber creds mount + wait-stream uses --creds ==="
helm template rrcs chart/ -n rrcs-k8s -s templates/connect-sink.yaml \
  | grep -E "secretName: subscriber-creds|mountPath: /etc/nats-creds/subscriber|--creds /etc/nats-creds/subscriber/user.creds" | head -6

echo "=== external mode: Secret names come from user values ==="
helm template rrcs chart/ -n rrcs-k8s -s templates/connect-source.yaml \
  --set nats.external.enabled=true --set nats.external.url=nats://x:4222 \
  --set nats.external.auth.publisherSecret=my-pub --set nats.external.auth.subscriberSecret=my-sub \
  | grep -E "secretName: my-pub|--creds /etc/nats-creds/publisher/user.creds" | head -2
```
Expected: source shows publisher mount + `--creds` in wait-stream; sink shows subscriber; external shows `secretName: my-pub` flowing through.

- [ ] **Step 4: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-connect-stress-k8s/chart/templates/connect-source.yaml \
        labs/redis-redpanda-connect-stress-k8s/chart/templates/connect-sink.yaml
git commit -m "rrcs-k8s: connect source/sink mount role creds, wait-stream uses --creds"
```

---

### Task 12: Update `writer.yaml` — template `REDIS_ADDR` + `wait-redis-central` host

The writer's `REDIS_ADDR` env and the `wait-redis-central` initContainer's `redis-cli -h` host both become helper-driven so external Redis URLs land.

**Files:**
- Modify: `labs/redis-redpanda-connect-stress-k8s/chart/templates/writer.yaml`

- [ ] **Step 1: Edit `writer.yaml`**

Replace:
```yaml
            - { name: REDIS_ADDR,    value: "redis-central:6379" }
```
with:
```yaml
            - { name: REDIS_ADDR,    value: {{ include "rrcs.redis.central.hostPort" . | quote }} }
```

Replace the `wait-redis-central` initContainer's `args:` from:
```yaml
            - until redis-cli -h redis-central ping | grep -q PONG; do echo waiting redis-central; sleep 1; done
```
to:
```yaml
            - HP="{{ include "rrcs.redis.central.hostPort" . }}"; HOST="${HP%%:*}"; PORT="${HP##*:}"; until redis-cli -h "$HOST" -p "$PORT" ping | grep -q PONG; do echo waiting redis-central; sleep 1; done
```

(Splitting host:port lets `redis-cli` accept a non-default port like `redis-prod:6380`.)

- [ ] **Step 2: Render-assert**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
echo "=== bundled: hostPort default ==="
helm template rrcs chart/ -n rrcs-k8s -s templates/writer.yaml | grep -E 'REDIS_ADDR|redis-cli -h' | head -3

echo "=== external Redis URL flows in ==="
helm template rrcs chart/ -n rrcs-k8s -s templates/writer.yaml \
  --set redis.central.external.enabled=true --set redis.central.external.url=redis://corp-cache:6380 \
  | grep -E 'REDIS_ADDR|redis-cli' | head -3
```
Expected: bundled shows `value: "redis-central:6379"` and the redis-cli inline with `redis-central:6379`. External: `value: "corp-cache:6380"` and the redis-cli host/port pair extracted from `corp-cache:6380`.

- [ ] **Step 3: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-connect-stress-k8s/chart/templates/writer.yaml
git commit -m "rrcs-k8s: writer.yaml templates REDIS_ADDR + wait-redis-central host"
```

---

### Task 13: Update `collector-job.yaml` — add `--nats-stream` / `--nats` / `--redis-*` args

The collector Job template gains four flag overrides so a renamed stream and external Redis/NATS endpoints land correctly (spec §13.2).

**Files:**
- Modify: `labs/redis-redpanda-connect-stress-k8s/chart/templates/collector-job.yaml`

- [ ] **Step 1: Append four args to the existing `args:` list**

After the existing `--slo-allow-missing=...` line and BEFORE the `{{- if eq .Values.collector.mode "chaos" }}` chaos block, insert:

```yaml
            - --nats-stream={{ .Values.nats.stream.name }}
            - --nats={{ include "rrcs.nats.monitorUrl" . | quote }}
            - --redis-central={{ include "rrcs.redis.central.hostPort" . | quote }}
            - --redis-region={{ include "rrcs.redis.region.hostPort" . | quote }}
```

- [ ] **Step 2: Render-assert**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
helm template rrcs chart/ -n rrcs-k8s -s templates/collector-job.yaml \
  --set collector.run=true --set collector.tier=10 \
  | grep -E '\-\-nats-stream|\-\-nats=|\-\-redis-central|\-\-redis-region' | head -6

echo "=== custom stream + external NATS monitorUrl flow in ==="
helm template rrcs chart/ -n rrcs-k8s -s templates/collector-job.yaml \
  --set collector.run=true --set collector.tier=10 \
  --set nats.stream.name=MY_STREAM \
  --set nats.external.enabled=true --set nats.external.url=nats://x:4222 \
  --set nats.external.monitorUrl=http://x:8222 \
  --set nats.external.auth.publisherSecret=p --set nats.external.auth.subscriberSecret=s \
  | grep -E '\-\-nats-stream|\-\-nats=' | head -2
```
Expected: bundled shows the four flags with default values. Custom: `--nats-stream=MY_STREAM`, `--nats="http://x:8222"`.

- [ ] **Step 3: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-connect-stress-k8s/chart/templates/collector-job.yaml
git commit -m "rrcs-k8s: collector-job wires --nats-stream + --nats + --redis-* via helpers"
```

---

### Task 14: Collector defensive change — treat empty `--nats` as "skip JS HTTP queries" (TDD)

Spec §13.2: when the collector is invoked in external mode with `nats.external.monitorUrl=""`, the `--nats` flag arrives as empty string. The collector's JS HTTP scrapers must tolerate this (return zero values) instead of crashing on a malformed URL fetch.

**Files:**
- Modify: `labs/redis-redpanda-connect-stress-k8s/collector/scrapers.go`
- Create: `labs/redis-redpanda-connect-stress-k8s/collector/scrapers_nats_empty_test.go`

- [ ] **Step 1: Read the current scrapers to find the NATS-side function names**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s/collector
grep -nE "^func .*NATS|natsURL|nats\.go" scrapers.go nats.go | head -10
```
You should see (names may vary slightly — adapt the test to match what's actually there):
- A function in `nats.go` like `func getNATSStreamStats(ctx context.Context, monitorURL, streamName string) (NATSStats, error)` that issues an HTTP GET against `<monitorURL>/jsz`.

Adjust the test below to use the actual function names. The pattern (return zeroes when URL is empty) is the same.

- [ ] **Step 2: Write the failing test**

Create `labs/redis-redpanda-connect-stress-k8s/collector/scrapers_nats_empty_test.go`:

```go
package main

import (
	"context"
	"testing"
	"time"
)

// When the operator runs the collector against external NATS with no
// monitoring URL configured (--nats=""), the collector must return zero
// values without attempting an HTTP fetch — otherwise the run aborts
// at the first sampler tick.
func TestGetNATSStreamStatsEmptyURLIsNoOp(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	stats, err := getNATSStreamStats(ctx, "", "APP_EVENTS")
	if err != nil {
		t.Fatalf("expected nil err for empty URL, got %v", err)
	}
	if stats.PendingMax != 0 || stats.Bytes != 0 {
		t.Fatalf("expected zero stats, got %+v", stats)
	}
}
```

If the function name in `nats.go` is different, rename in this test accordingly (e.g. `scrapeNATS`, `fetchJsz`). Read `nats.go` to pin the right symbol.

- [ ] **Step 3: Run to verify it fails**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s/collector
go test ./... -run TestGetNATSStreamStatsEmptyURL -v
```
Expected: FAIL — either with a panic / non-nil error from attempting to fetch an empty-URL HTTP request, or non-zero stats.

- [ ] **Step 4: Implement the guard**

In `collector/scrapers.go` (or `nats.go`, wherever the JS HTTP function lives), at the very top of the function, add:

```go
	if monitorURL == "" {
		return NATSStats{}, nil
	}
```

(`NATSStats` is the struct returned by that function; substitute the actual type if different.)

- [ ] **Step 5: Run to verify it passes**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s/collector
go test ./... -v 2>&1 | tail -15
```
Expected: all tests pass, including the new one. Pre-existing tests stay green.

- [ ] **Step 6: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-connect-stress-k8s/collector/
git commit -m "rrcs-k8s: collector treats empty --nats as skip JS HTTP queries (TDD)"
```

---

### Task 15: Update `scripts/stress-run.sh` — gated chaos pre-flight, admin-creds purge, stream name from values

Three changes (spec §6 harness section + §13.4): resolve stream name and admin-Secret name from `helm get values`, gate chaos pre-flight on `nats.external.enabled` + `monitorUrl`, mount admin Secret into the purge `kubectl run`.

**Files:**
- Modify: `labs/redis-redpanda-connect-stress-k8s/scripts/stress-run.sh`

- [ ] **Step 1: Add early-resolution block after `helm upgrade --install`**

After the existing helm install block, before the chaos port-forward, insert:

```bash
# Resolve runtime config from the installed release (rather than baking
# defaults into the harness). External mode users only see their values.
HELM_VALUES_JSON="$(helm get values "${RELEASE}" -n "${NS}" -o json)"
STREAM_NAME="$(echo "$HELM_VALUES_JSON" | jq -r '.nats.stream.name // "APP_EVENTS"')"
NATS_EXTERNAL="$(echo "$HELM_VALUES_JSON" | jq -r '.nats.external.enabled // false')"
NATS_MONITOR_URL="$(echo "$HELM_VALUES_JSON" | jq -r '.nats.external.monitorUrl // empty')"
NATS_URL="$(echo "$HELM_VALUES_JSON" | jq -r '.nats.external.url // empty')"
[[ -z "$NATS_URL" ]] && NATS_URL="nats://nats:4222"
ADMIN_SECRET="$(echo "$HELM_VALUES_JSON" | jq -r '.nats.auth.secrets.admin // "admin-creds"')"
if [[ "$NATS_EXTERNAL" == "true" ]]; then
  ADMIN_SECRET="$(echo "$HELM_VALUES_JSON" | jq -r '.nats.external.auth.adminSecret // empty')"
fi
echo "[config] stream=${STREAM_NAME} ext=${NATS_EXTERNAL} url=${NATS_URL} mon=${NATS_MONITOR_URL:-<unset>} admin=${ADMIN_SECRET:-<unset>}"
```

- [ ] **Step 2: Gate the chaos pre-flight port-forward on bundled mode + monitor URL availability**

Replace the existing block:
```bash
if (( needs_pf )); then
  kubectl -n "${NS}" port-forward svc/nats 18222:8222 >/dev/null 2>&1 &
  PF_PID=$!
  # ... existing readiness poll ...
fi
```
with:
```bash
if (( needs_pf )); then
  if [[ "$NATS_EXTERNAL" == "true" ]]; then
    if [[ -z "$NATS_MONITOR_URL" ]]; then
      echo "[chaos-preflight] WARN: nats.external.monitorUrl unset; skipping JetStream bytes pre-flight" >&2
      JSZ_URL=""
    else
      JSZ_URL="${NATS_MONITOR_URL%/}/jsz"
    fi
  else
    kubectl -n "${NS}" port-forward svc/nats 18222:8222 >/dev/null 2>&1 &
    PF_PID=$!
    pf_ok=0
    for _ in $(seq 1 15); do
      if curl -fs "http://127.0.0.1:18222/jsz" >/dev/null 2>&1; then pf_ok=1; break; fi
      sleep 1
    done
    (( pf_ok )) || { echo "[error] NATS port-forward not ready on :18222" >&2; exit 1; }
    JSZ_URL="http://127.0.0.1:18222/jsz"
  fi
fi
```

And update `jetstream_bytes()` to use `JSZ_URL`:
```bash
jetstream_bytes() {
  [[ -z "${JSZ_URL:-}" ]] && { echo 0; return; }
  curl -fs "${JSZ_URL}?streams=true&consumers=true&accounts=true" \
    | python3 -c 'import json,sys
d=json.load(sys.stdin); b=0
for a in d.get("account_details",[]):
 for s in a.get("stream_detail",[]):
  if s.get("name")=="'"${STREAM_NAME}"'": b=s.get("state",{}).get("bytes",0)
print(b)'
}
```
(Note: the Python embeds `${STREAM_NAME}` via shell expansion since the heredoc isn't single-quoted in this version — verify the shellcheck still passes and that the value is properly interpolated by writing the function with care.)

- [ ] **Step 3: Update the purge `kubectl run` to mount the admin Secret**

Replace the existing purge block:
```bash
  local purge_img
  purge_img="$(...)"
  kubectl -n "${NS}" run "nats-purge-$(date +%s)" --rm -i --restart=Never \
    --image="${PURGE_IMG}" -- \
    nats --server nats://nats:4222 stream purge APP_EVENTS -f >/dev/null 2>&1 \
    || echo "[purge] WARN: stream purge failed (continuing)" >&2
}
```
with:
```bash
  if [[ -z "${ADMIN_SECRET}" ]]; then
    echo "[purge] WARN: admin creds not configured (skipping purge — runs are not hermetic)" >&2
    return 0
  fi
  local purge_name="nats-purge-$(date +%s)"
  kubectl -n "${NS}" run "${purge_name}" --rm -i --restart=Never --image="${PURGE_IMG}" \
    --overrides='{
      "spec": {
        "volumes": [{"name": "creds", "secret": {"secretName": "'"${ADMIN_SECRET}"'", "defaultMode": 256}}],
        "containers": [{
          "name": "'"${purge_name}"'",
          "image": "'"${PURGE_IMG}"'",
          "volumeMounts": [{"name": "creds", "mountPath": "/tmp/creds", "readOnly": true}],
          "command": ["nats", "--server", "'"${NATS_URL}"'", "--creds", "/tmp/creds/user.creds", "stream", "purge", "'"${STREAM_NAME}"'", "-f"]
        }]
      }
    }' >/dev/null 2>&1 \
    || echo "[purge] WARN: stream purge failed (continuing)" >&2
}
```

- [ ] **Step 4: shellcheck + bash -n + --help still works**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
bash -n scripts/stress-run.sh && echo "syntax OK"
shellcheck scripts/stress-run.sh && echo "shellcheck clean"
scripts/stress-run.sh --help | head -5
```
Expected: `syntax OK`, `shellcheck clean`, usage block printed. (If shellcheck flags genuine issues in the `--overrides` JSON heredoc or quoting, fix them carefully — do not blanket-disable.)

- [ ] **Step 5: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-connect-stress-k8s/scripts/stress-run.sh
git commit -m "rrcs-k8s: harness resolves stream/admin from values, gates chaos pre-flight, mounts purge creds"
```

---

### Task 16: Create `values-external.yaml.example` and update `README.md` + `RESEARCH.md`

Documents the external-mode shape and prerequisites.

**Files:**
- Create: `labs/redis-redpanda-connect-stress-k8s/values-external.yaml.example`
- Modify: `labs/redis-redpanda-connect-stress-k8s/README.md`
- Modify: `labs/redis-redpanda-connect-stress-k8s/RESEARCH.md`

- [ ] **Step 1: Create `values-external.yaml.example`** with EXACTLY:

```yaml
# Example overlay for running the rrcs-k8s lab against pre-existing external
# NATS JetStream and Redis. Copy to a real values file (NOT committed), fill
# in your URLs, and pre-create the K8s Secrets referenced below.
#
# Prerequisites you must satisfy in your external NATS account:
#   - The stream named by nats.stream.name (default APP_EVENTS) must exist
#     with subjects nats.stream.subjects (default app.events.>).
#   - The publisher user JWT must allow: pub app.events.> and
#     pub $JS.API.STREAM.INFO.<stream-name>; sub _INBOX.>
#   - The subscriber user JWT must allow: pub $JS.ACK.<stream>.<durable>.>,
#     pub $JS.API.STREAM.INFO.<stream>, and the four narrow consumer subjects
#     (DURABLE.CREATE, CREATE, CREATE.>, INFO) for stream.durable;
#     sub _INBOX.>.
#   - (Optional) admin user JWT with pub $JS.API.> for the harness purge.
#
# Pre-create the Secrets (keys: user.creds):
#   kubectl create secret generic prod-publisher-creds  --from-file=user.creds=publisher.creds  -n rrcs-k8s
#   kubectl create secret generic prod-subscriber-creds --from-file=user.creds=subscriber.creds -n rrcs-k8s
#   kubectl create secret generic prod-admin-creds      --from-file=user.creds=admin.creds      -n rrcs-k8s   # optional

nats:
  external:
    enabled: true
    url: "nats://nats.prod.example.com:4222"
    monitorUrl: "http://nats-monitor.prod.example.com:8222"   # optional
    auth:
      publisherSecret: prod-publisher-creds
      subscriberSecret: prod-subscriber-creds
      adminSecret: prod-admin-creds                          # optional; "" skips harness purge

redis:
  central:
    external:
      enabled: true
      url: "redis://redis-central.prod.example.com:6379"
  region:
    external:
      enabled: true
      url: "redis://redis-region.prod.example.com:6379"

# Writer/collector still locally built; load into your cluster's registry or kind:
#   scripts/build-images.sh --registry=corp.example.com/team --push
images:
  registry: corp.example.com/team/   # if you pushed; or "" if loaded into kind
```

- [ ] **Step 2: Update `README.md`**

Add (or replace, depending on existing structure) a new section "Authentication & external backends" near the top of the README, just after the existing "Quick start (kind / local)" section. Use the Edit tool — insert this content at an appropriate location:

```markdown
## Authentication

The chart runs in two modes (independently per backend):

- **Bundled mode (default).** The chart deploys NATS + Redis and mints
  credential auth at install time from lab-fixture JWTs under
  `chart/files/nats-auth/`. Run `scripts/gen-nats-auth.sh` once on a fresh
  checkout if those fixtures are missing.
- **External mode.** Point the chart at your own NATS/Redis. Pre-create
  K8s Secrets containing user .creds files; reference them in
  `values-external.yaml`. The chart never mints, never touches your
  stream. See `values-external.yaml.example` for the full shape and the
  exact NATS permissions you must grant.

## Quick start (kind / local) — with auth

```bash
scripts/gen-nats-auth.sh                    # once, for fresh checkouts
kind create cluster --name rrcs
scripts/build-images.sh --kind --kind-name=rrcs
scripts/stress-run.sh --tiers=10 --modes=throughput --profile=alo
```

## Running against external NATS + Redis

```bash
# user pre-creates Secrets in their cluster (NOT done by the chart)
kubectl create secret generic prod-publisher-creds  --from-file=user.creds=publisher.creds  -n rrcs-k8s
kubectl create secret generic prod-subscriber-creds --from-file=user.creds=subscriber.creds -n rrcs-k8s
kubectl create secret generic prod-admin-creds      --from-file=user.creds=admin.creds      -n rrcs-k8s   # optional

cp values-external.yaml.example values-prod.yaml     # edit URLs + secret names
helm install rrcs ./chart -n rrcs-k8s --create-namespace -f values-prod.yaml
RRCS_VALUES=values-prod.yaml scripts/stress-run.sh --tiers=10 --modes=throughput
```
```

- [ ] **Step 3: Update `RESEARCH.md`**

Prepend a brief section "Why credential auth + bundled-vs-external" near the top, before the existing Kubernetes-fork rationale section:

```markdown
# RESEARCH — credential auth + external backend support

This iteration adds production-shape NATS credential auth (operator → account
→ user JWTs + .creds files) and independent bundled-vs-external toggles for
NATS and each Redis. Two design decisions worth remembering:

- **Permission narrowness.** Publisher and subscriber don't share admin
  creds; each gets exactly the JetStream API subjects it needs (publisher:
  `app.events.>` + read on `$JS.API.STREAM.INFO.<stream>`; subscriber:
  ack on `$JS.ACK.<stream>.<durable>.>` + the four narrow CONSUMER subjects
  scoped to its own durable + the same stream-info read). A compromised
  source can't drain the stream; a compromised sink can't inspect other
  consumers. This is the production pattern; lab demonstrates the format.
- **Two modes, one chart.** Bundled mode mints fixture creds at install
  for kind/local use. External mode skips deploying NATS/Redis and consumes
  user-supplied Secrets by name (production workflow: signing keys in Vault,
  creds materialized into K8s Secrets via External Secrets / SealedSecrets).
  Lab is a teaching artifact: bundled shows the FORMAT, external shows the
  WORKFLOW.

---
```

- [ ] **Step 4: Render-assert + grep**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
test -s values-external.yaml.example && echo "example exists"
grep -q "Pre-create the Secrets" values-external.yaml.example && echo "example has prereqs"
grep -q "Authentication" README.md && grep -q "scripts/gen-nats-auth.sh" README.md && echo "README updated"
grep -q "Permission narrowness" RESEARCH.md && echo "RESEARCH updated"
```
Expected: all four lines.

- [ ] **Step 5: Commit**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git add labs/redis-redpanda-connect-stress-k8s/values-external.yaml.example \
        labs/redis-redpanda-connect-stress-k8s/README.md \
        labs/redis-redpanda-connect-stress-k8s/RESEARCH.md
git commit -m "rrcs-k8s: values-external.yaml.example + README/RESEARCH for auth + external"
```

---

### Task 17: Full-chart render + dry-run integration check (no cluster needed)

A quick offline gate before the live e2e: the full chart must render in both bundled and external modes, with kubectl client-side validation.

**Files:** none (verification only).

- [ ] **Step 1: Full chart render — bundled (default)**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
helm template rrcs chart/ -n rrcs-k8s -f chart/values-dev.yaml | grep -c "^kind:"
```
Expected: at least 17 (5 Deployments + 6 Services + 1 Job + 2 ConfigMaps + 3 Secrets + 1 ConfigMap for nats-config = 18; collector Job gated off).

- [ ] **Step 2: Full chart render — external NATS + external Redis**

```bash
helm template rrcs chart/ -n rrcs-k8s \
  --set nats.external.enabled=true \
  --set nats.external.url=nats://corp:4222 \
  --set nats.external.auth.publisherSecret=p \
  --set nats.external.auth.subscriberSecret=s \
  --set redis.central.external.enabled=true --set redis.central.external.url=redis://corp1:6379 \
  --set redis.region.external.enabled=true --set redis.region.external.url=redis://corp2:6379 \
  | grep -c "^kind:"
```
Expected: fewer kinds — no NATS Deployment/Service/Job/ConfigMap/Secrets and no Redis Deployments/Services, but connect-source/sink/writer Deployments + Services + ConfigMaps stay. ~6 (connect-source, connect-sink, writer Deployments + their Services + the two connect ConfigMaps).

- [ ] **Step 3: Spin a kind cluster solely for `kubectl apply --dry-run=client` schema validation**

```bash
kind get clusters | grep -qx rrcs || kind create cluster --name rrcs --wait 60s
helm template rrcs chart/ -n rrcs-k8s -f chart/values-dev.yaml | kubectl apply --dry-run=client -f - 2>&1 | grep -E "created|invalid" | tail -20
```
Expected: every resource line shows `created (dry run)`; no `invalid` lines.

- [ ] **Step 4: No commit needed (verification only)**

Move on. The kind cluster is kept up for Task 18.

---

### Task 18: Kind end-to-end smoke test (live integration gate)

The functional gate for the whole change: live NATS auth, real durable consumer creation by the subscriber, real publish by the publisher, real purge by the admin. If the narrow CONSUMER perms are wrong, this is where it shows.

**Files:** none (verification only).

- [ ] **Step 1: Build and side-load images (if not done)**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub/labs/redis-redpanda-connect-stress-k8s
scripts/build-images.sh --kind --kind-name=rrcs
```
Expected: both `redis-rrcs/writer:dev` and `redis-rrcs/collector:dev` loaded into the kind cluster `rrcs`.

- [ ] **Step 2: Install the chart with bundled mode + auth**

```bash
helm upgrade --install rrcs ./chart -n rrcs-k8s --create-namespace \
  --set profile=alo -f chart/values-dev.yaml --wait --timeout 5m
kubectl -n rrcs-k8s get pods
kubectl -n rrcs-k8s get secret publisher-creds subscriber-creds admin-creds
```
Expected: all 6 deployments Ready 1/1, the `nats-init-<hash>` Job Complete, the three Secrets present with `user.creds` key. (`helm --wait` succeeds means `nats-init` Job completed → admin creds work for stream creation; connect-source + sink pods Ready means their `wait-stream` initContainers passed → publisher and subscriber creds work for `$JS.API.STREAM.INFO`.)

- [ ] **Step 3: Run a throughput cell — full pipeline w/ auth**

```bash
RRCS_VALUES=chart/values-dev.yaml DURATION_S=15 scripts/stress-run.sh --tiers=10 --modes=throughput --profile=alo
python3 -c "import json; d=json.load(open('reports/10-throughput-alo.json')); print('pass=', d['verdict']['pass'], 'missing=', d['missing'])"
```
Expected: harness logs `[ok] report saved`; the python line prints `pass= True missing= 0` (the subscriber successfully created the durable consumer, received messages, and ack'd — proving the narrow CONSUMER perms work end-to-end).

- [ ] **Step 4: Run a chaos cell — exercise the purge admin path too**

```bash
RRCS_VALUES=chart/values-dev.yaml DURATION_S=20 scripts/stress-run.sh --tiers=10 --modes=chaos --profile=alo
python3 -c "import json; d=json.load(open('reports/10-chaos-alo.json')); print('chaos=', d['chaos']['action'], 'missing=', d['missing'])"
```
Expected: harness logs the chaos scale 0→1 + recovered (ready) lines; the python line prints `chaos= kill-connect-sink missing= 0`. The `[purge] WARN: stream purge failed` should NOT appear — purge with admin creds should succeed.

- [ ] **Step 5: Verify subscriber's narrow CONSUMER perms actually got exercised**

```bash
kubectl -n rrcs-k8s logs -l app=connect-sink --tail=50 | grep -iE "consumer|api error|permission" | head -5
```
Expected: no `api error` or `permission` lines. If there's a "no responders available for $JS.API.CONSUMER.CREATE..." error, the perm set is missing the right form — revisit Task 1 / spec §3.

- [ ] **Step 6: Tear down**

```bash
helm uninstall rrcs -n rrcs-k8s || true
kind delete cluster --name rrcs
```

- [ ] **Step 7: Final commit (any e2e-driven fixes)**

```bash
cd /media/hp/secondary/projects/gam-redis-pubsub
git status --short labs/redis-redpanda-connect-stress-k8s/
```
If only `reports/*.json` are unstaged, those are gitignored and there's nothing to commit. If the e2e surfaced any chart/script fixes, commit them with a message like `rrcs-k8s: fixes from auth-mode kind e2e`.

---

## Self-Review (completed by plan author)

**1. Spec coverage** — every spec section has a task:

- §1 Goal / §2 modes (independent toggles) → Tasks 2 (values), 6/7/8 (template guards), 17 (render both modes).
- §3 Identity hierarchy + permissions (incl. §14 narrow CONSUMER subjects) → Task 1 (gen script bakes the four narrow subjects + `$JS.API.STREAM.INFO.<stream>` per user).
- §4 Values surface → Task 2.
- §5.1 New helpers → Task 3.
- §5.2 Bundled-only templates (`nats.yaml`, `nats-config-cm.yaml`, `nats-auth-secrets.yaml`, `nats-init-job.yaml`, redis) → Tasks 4, 5, 6, 7, 8.
- §5.3 connect-source/sink creds mount + wait-stream → Task 11.
- §5.4 `tpl`-templated connect YAMLs → Tasks 9 + 10.
- §6 Per-client wiring (4 NATS-touching call sites) → Tasks 7 (init Job), 11 (source + sink + their initContainer wait-stream), 15 (harness purge).
- §7 Bootstrap workflows → Task 16 (README documents both flows).
- §8 `gen-nats-auth.sh` (incl. §14's `nsc generate config --mem-resolver`) → Task 1.
- §10 Breaking changes → covered in README update (Task 16).
- §13.1 New helpers (monitorUrl, hostPort) → Task 3.
- §13.2 Collector four new flags → Task 13.
- §13.3 Writer REDIS_ADDR template → Task 12.
- §13.4 Harness chaos pre-flight gating → Task 15.
- §13.5 Defensive collector empty-NATS skip → Task 14 (TDD).
- §14 Codex review fixes → folded into Task 1 (narrow perms + `nsc generate config --mem-resolver`).
- Final integration → Tasks 17 + 18.

**2. Placeholder scan** — no TBD/TODO/"add error handling"/"similar to Task N". Every code step has complete content. Every command shows expected output. The only "look up the actual function name in nats.go" is in Task 14 Step 1 — that's a deliberate one-line lookup (the function name in the existing collector code is what it is; the test/impl pattern is fully shown). Not a placeholder.

**3. Type consistency** — Service DNS names (`redis-central`, `redis-region`, `nats`, `connect-source`, `connect-sink`, `writer`) unchanged. Helper names referenced consistently across Tasks 3 / 6 / 7 / 10 / 11 / 12 / 13 (`rrcs.nats.url`, `rrcs.nats.monitorUrl`, `rrcs.redis.{central,region}.{url,hostPort}`, `rrcs.nats.credsSecret.{publisher,subscriber,admin}`). Values keys (`nats.external.enabled`, `nats.auth.secrets.*`, `nats.auth.creds.*`, `nats.stream.{name,publishSubject,consumer.durable}`, `redis.{central,region}.external.{enabled,url}`) match between values.yaml (Task 2), the templates (Tasks 4-13), the helpers (Task 3), and the harness `helm get values` reads (Task 15). Mount paths uniform: `/etc/nats-creds/{publisher,subscriber,admin}/user.creds`.
