# NATS JetStream Credential Auth + External Backend Support — Design

**Lab:** `labs/redis-redpanda-connect-stress-k8s/`
**Date:** 2026-06-02
**Status:** design

---

## 1. Goal

Add NATS JetStream credential-based authentication (the production-shape: operator → account → user JWTs + `.creds` files) to the K8s lab, AND support running the lab against pre-existing external NATS and Redis instances (so the chart isn't only useful for kind-local self-contained runs).

After this change:
- Bundled mode (the kind/local quick-start) gains real creds auth using lab-fixture identities committed under `chart/files/nats-auth/`. The pipeline is otherwise unchanged.
- External mode lets you point the same chart at your org's NATS and Redis. The chart skips deploying those backends and consumes your pre-created K8s Secrets by name.
- NATS topic/stream/consumer names are configurable from `values.yaml` and propagate to the connect YAMLs, the harness, and (in bundled mode) the minted user permissions — so an external NATS owner's namespace conventions fit cleanly.

**Explicit non-goals:**
- TLS to NATS or Redis (separate concern; out of scope).
- The `$SYS` system account (lab doesn't need it; HTTP monitoring at `:8222` stays open, mirroring prod-with-network-policy practice).
- nats-account-server / full JWT resolver (the lab has one static account, so the in-process `MEMORY` resolver with a preloaded account JWT is the right call).
- Auth toggle. Auth is always-on in this lab. The no-auth original lives at `labs/redis-redpanda-connect-stress/` for anyone who needs it.
- Configurable Redis stream keys (`app.events`, `region-events`). The chart's writer owns those — the user said "topics of NATS"; Redis stream naming stays chart-internal. If a real conflict arises, fold in later.

## 2. Two modes, per backend, independently togglable

```
nats.external.enabled    redis.central.external.enabled    redis.region.external.enabled
       false                       false                            false                   →  fully bundled (today's behavior + auth)
       true                        false                            false                   →  external NATS, bundled Redis
       false                       true                             true                    →  bundled NATS, external Redis
       true                        true                             true                    →  fully external
```

Mixed combinations are valid. The chart conditionally renders per backend; no global "external" master flag.

**What renders, per mode:**

| Resource (template file) | Bundled NATS | External NATS | Bundled Redis | External Redis |
|---|---|---|---|---|
| `nats.yaml` (Deployment + Service) | ✅ | ❌ skipped | — | — |
| `nats-config-cm.yaml` (ConfigMap with `nats-server.conf`) | ✅ | ❌ | — | — |
| `nats-auth-secrets.yaml` (publisher/subscriber/admin Secrets from `chart/files/nats-auth/`) | ✅ | ❌ (user-supplied Secrets, referenced by name) | — | — |
| `nats-init-job.yaml` (idempotent stream creation) | ✅ | ❌ (stream pre-provisioned externally — never touched) | — | — |
| `redis-central.yaml` / `redis-region.yaml` (each Deployment + Service) | — | — | ✅ | ❌ skipped |

In external NATS mode the chart **never** runs `nats-init` against the external server, by explicit choice — the external owner controls the stream lifecycle. In external Redis mode the chart trusts the URLs the user provides and the optional auth Secret(s).

## 3. Identity hierarchy (bundled mode) and permissions

**Hierarchy:** `RRCS-OP` (operator) → `APP` (account, JetStream-enabled, no per-account limits beyond the stream's own caps) → three users, all signed by `APP`.

**Per-user permissions (signed into each user's JWT):**

| User (`.creds` file) | Used by | Publish allow | Subscribe allow |
|---|---|---|---|
| `publisher.creds` | connect-source | `app.events.>`, `$JS.API.STREAM.INFO.APP_EVENTS` | `_INBOX.>` |
| `subscriber.creds` | connect-sink | `$JS.ACK.APP_EVENTS.>`, `$JS.API.STREAM.INFO.APP_EVENTS`, `$JS.API.CONSUMER.>` (for the durable's own ops) | `_INBOX.>` plus the consumer's deliver subject |
| `admin.creds` | `nats-init` Job + harness purge | `$JS.API.>` (full JetStream admin) | `_INBOX.>` |

**Notes on the permission shape:**
- Publisher cannot subscribe to the stream or create/drain it; a buggy/compromised source can't re-inject downstream messages.
- Subscriber cannot publish into `app.events.>`; a buggy/compromised sink can't taint the source side.
- The narrow `$JS.API.STREAM.INFO.<stream-name>` pub allow on publisher AND subscriber lets each one's initContainer verify stream readiness with its OWN creds — admin creds never bleed into data-plane pods.
- Stream name in the permission is parameterized: `gen-nats-auth.sh` reads `chart/values.yaml`'s `nats.stream.name` and bakes that exact name into the perm. Change the stream name → re-run the gen script → re-commit.

In **external mode** the chart is agnostic to your hierarchy. You sign users in your own operator/account, give publisher/subscriber the equivalent narrow `$JS.API.STREAM.INFO.<your-stream>` permission, and reference the Secrets by name in `values-external.yaml`.

## 4. Values surface

Folded into the existing `nats:` and `redis:` blocks of `chart/values.yaml`:

```yaml
nats:
  external:
    enabled: false                # bundled (default) → chart deploys NATS + mints creds
    url: ""                       # required when enabled, e.g. "nats://nats.prod.example.com:4222"
    auth:
      publisherSecret: ""         # pre-created Secret name, key: user.creds
      subscriberSecret: ""
      adminSecret: ""             # optional; when "", harness purge is skipped (with warning)
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
      publisher: publisher-creds   # K8s Secret name (chart renders these in bundled mode)
      subscriber: subscriber-creds
      admin: admin-creds
    creds:                         # mount paths used by every client wiring (Section 6)
      publisher: /etc/nats-creds/publisher/user.creds
      subscriber: /etc/nats-creds/subscriber/user.creds
      admin: /etc/nats-creds/admin/user.creds

redis:
  image: redis:7.4-alpine          # used only in bundled mode
  central:
    external:
      enabled: false
      url: ""                      # e.g. "redis://redis.prod:6379" or "rediss://..." for TLS
      authSecret: ""               # optional; pre-created Secret with keys `password` (and optional `username`)
  region:
    external:
      enabled: false
      url: ""
      authSecret: ""
```

`values-dev.yaml` is unchanged in spirit (writer/collector `pullPolicy: Never`, NATS emptyDir). A new `values-external.yaml.example` is committed showing the external-mode shape.

## 5. Chart shape

### 5.1 New `_helpers.tpl` templates — single source of truth for addresses & creds

```
{{- define "rrcs.nats.url" -}}
{{- if .Values.nats.external.enabled -}}
{{- required "nats.external.url is required when nats.external.enabled=true" .Values.nats.external.url -}}
{{- else -}}
nats://nats:{{ .Values.nats.clientPort }}
{{- end -}}
{{- end -}}

{{- define "rrcs.redis.central.url" -}}
{{- if .Values.redis.central.external.enabled -}}
{{- required "redis.central.external.url is required" .Values.redis.central.external.url -}}
{{- else -}}
redis://redis-central:6379
{{- end -}}
{{- end -}}

{{- define "rrcs.redis.region.url" -}}  ... same shape ... {{- end -}}

{{/* NATS creds Secret name — external user-supplied OR bundled chart-rendered */}}
{{- define "rrcs.nats.credsSecret.publisher" -}}
{{- if .Values.nats.external.enabled -}}
{{- required "nats.external.auth.publisherSecret is required" .Values.nats.external.auth.publisherSecret -}}
{{- else -}}
{{- .Values.nats.auth.secrets.publisher -}}
{{- end -}}
{{- end -}}

{{- define "rrcs.nats.credsSecret.subscriber" -}}  ... same shape ... {{- end -}}

{{/* Admin Secret may be unset in external mode (purge then skipped) */}}
{{- define "rrcs.nats.credsSecret.admin" -}}
{{- if .Values.nats.external.enabled -}}
{{- .Values.nats.external.auth.adminSecret -}}      {{- /* may be empty string */ -}}
{{- else -}}
{{- .Values.nats.auth.secrets.admin -}}
{{- end -}}
{{- end -}}
```

### 5.2 Bundled-only templates (guarded by `if not .Values.nats.external.enabled`)

- **`chart/templates/nats.yaml`** — Deployment + Service (existing). Container args change from `["-js","-sd","/data","-m","8222"]` to `["-c","/etc/nats/nats-server.conf"]`. Mount the new `nats-config` ConfigMap at `/etc/nats/nats-server.conf` via `subPath`. The JetStream emptyDir/PVC at `/data` stays.
- **`chart/templates/nats-config-cm.yaml`** (NEW) — ConfigMap `nats-config` with the full `nats-server.conf`:
  ```
  server_name: rrcs-nats
  port: {{ .Values.nats.clientPort }}
  http_port: {{ .Values.nats.monitorPort }}
  jetstream {
    store_dir: /data
  }
  {{ .Files.Get "files/nats-auth/nats-server.conf" }}
  ```
  The `nats-server.conf` fragment in `chart/files/nats-auth/` contains the `operator: <jwt>` + `resolver: MEMORY` + `resolver_preload { <APP_pubkey>: <APP_jwt> }` block (produced by `gen-nats-auth.sh`).
- **`chart/templates/nats-auth-secrets.yaml`** (NEW) — three K8s Secrets, each with a `user.creds` key:
  ```yaml
  apiVersion: v1
  kind: Secret
  metadata: { name: {{ .Values.nats.auth.secrets.publisher }} }
  type: Opaque
  data:
    user.creds: {{ .Files.Get "files/nats-auth/publisher.creds" | b64enc | quote }}
  ---
  # ...subscriber, admin
  ```
- **`chart/templates/nats-init-job.yaml`** — existing template, guarded by `{{- if not .Values.nats.external.enabled }}`. Its containers now mount the admin Secret and every `nats` CLI call grows `--creds /etc/nats-creds/admin/user.creds`. The hash suffix on the Job name (Codex follow-up #I1 from the prior spec) stays.
- **`chart/templates/redis-central.yaml`** / `redis-region.yaml` — guarded by `{{- if not .Values.redis.{central,region}.external.enabled }}`. Unchanged otherwise.

### 5.3 connect-source / connect-sink (both modes — pods always exist)

The pod always exists (the chart's Connect workloads run in both modes — they're the lab's pipeline). Each pod:

- Mounts the appropriate creds Secret via the helper-resolved name (bundled chart-rendered or external user-supplied):
  ```yaml
  volumes:
    - name: nats-creds
      secret:
        secretName: {{ include "rrcs.nats.credsSecret.publisher" . }}   # or subscriber
  containers:
    - name: connect
      volumeMounts:
        - name: nats-creds
          mountPath: /etc/nats-creds/publisher                          # or subscriber
          readOnly: true
  ```
- The `wait-stream` initContainer keeps its place but now uses the role's own creds (publisher or subscriber) for the `nats stream info <stream-name>` poll — which works because of the Section 3 narrow `$JS.API.STREAM.INFO.<name>` permission.
- The `wait-redis-*` initContainer mounts the Redis auth Secret (when set via `redis.{central,region}.external.authSecret`) and pings with `redis-cli -h <host> -a "$(cat /etc/redis-auth/password)" ping`. When no auth Secret is set, the existing unauthenticated ping stays.

### 5.4 Connect ConfigMap template — `tpl`-templated YAMLs

`chart/templates/connect-configmaps.yaml` changes from:
```yaml
connect.yaml: |-
{{ .Files.Get (printf "files/connect/%s-forward.yaml" .Values.profile) | indent 4 }}
```
to:
```yaml
connect.yaml: |-
{{ tpl (.Files.Get (printf "files/connect/%s-forward.yaml" .Values.profile)) . | indent 4 }}
```

The six connect YAMLs (`{alo,amo,eoe}-{forward,reverse}.yaml`) become semi-templated. Concretely:

- `urls: [nats://nats:4222]` → `urls: ["{{ include "rrcs.nats.url" . }}"]`
- `subject: app.events.${! meta("pattern") }` (forward) → `subject: {{ .Values.nats.stream.publishSubject | quote }}`
- `subject: app.events.>` + `stream: APP_EVENTS` (reverse) → `subject: {{ .Values.nats.stream.subjects | quote }}` + `stream: {{ .Values.nats.stream.name | quote }}`
- `durable: region-writer` → `durable: {{ .Values.nats.stream.consumer.durable | quote }}`
- New `auth:` block: `auth: { user_credentials_file: {{ .Values.nats.auth.creds.publisher | quote }} }` (forward) / `subscriber` (reverse)
- Redis URL: `url: redis://redis-central:6379` → `url: {{ include "rrcs.redis.central.url" . }}` (forward) / `redis.region.url` (reverse). When an `authSecret` is set, the connect YAML gains an `auth:` block reading env vars the pod injects from the Secret.

Helm's `{{ }}` and Connect's Bloblang `${! }` don't collide; this works.

## 6. Per-client wiring (the four NATS-touching call sites)

| # | Client | Mode behavior | Auth |
|---|---|---|---|
| 1 | connect-source | always renders | `auth.user_credentials_file` in connect YAML → publisher creds Secret mounted at `/etc/nats-creds/publisher/user.creds` |
| 2 | connect-sink | always renders | same shape, subscriber creds at `/etc/nats-creds/subscriber/user.creds` |
| 3 | `nats-init` Job | bundled only (skipped in external) | mounts admin creds Secret; every `nats` CLI call grows `--creds /etc/nats-creds/admin/user.creds` |
| 4 | Harness purge (`scripts/stress-run.sh`) | bundled always; external only when `adminSecret` is set | `kubectl run` mounts admin Secret; `nats --server $URL --creds /tmp/creds/user.creds stream purge <name> -f`. If no admin Secret in external mode → skip with `[purge] WARN: admin creds not configured (skipping purge — runs are not hermetic)` |

The two initContainer poll loops are the fifth and sixth touch points (each uses its pod's own creds, see §5.3).

### Harness changes (`scripts/stress-run.sh`)

- Resolve stream name and `nats.url` once before the matrix loop:
  ```bash
  STREAM_NAME="$(helm get values rrcs -n "$NS" -o json | jq -r '.nats.stream.name // "APP_EVENTS"')"
  NATS_URL="$(helm get values rrcs -n "$NS" -o json | jq -r '.nats.external.url // empty')"
  [[ -z "$NATS_URL" ]] && NATS_URL="nats://nats:4222"
  ADMIN_SECRET="$(helm get values rrcs -n "$NS" -o json | jq -r '.nats.external.auth.adminSecret // empty')"
  # if external+adminSecret empty → ADMIN_SECRET_EXISTS=0, skip purge with warning
  ```
- The existing `PURGE_IMG` resolution (rendered from nats-init-job.yaml in the prior fix) only works in bundled mode. In external mode, fall back to `.Values.natsBox.image` resolved via `helm get values` + `.Values.images.registry` prefix.
- The per-cell `kubectl run nats-purge-...` command grows: `--overrides='{"spec":{"volumes":[{"name":"creds","secret":{"secretName":"<admin-secret>"}}],"containers":[{"name":"nats-purge-...","image":"<img>","volumeMounts":[{"name":"creds","mountPath":"/tmp/creds","readOnly":true}],"command":["nats","--server","'"$NATS_URL"'","--creds","/tmp/creds/user.creds","stream","purge","'"$STREAM_NAME"'","-f"]}]}}'` (or equivalent — the implementation plan can pick the cleanest form).
- The chaos pre-flight (`/jsz` over the port-forward) is unaffected; the HTTP monitoring port stays open in bundled mode and is presumed reachable in external mode (port-forward to the external NATS Service if it's in-cluster, or skip chaos mode against external NATS where you can't port-forward).

## 7. Bootstrap workflows

### 7.1 Bundled (kind/local quick-start)

A fresh checkout already has `chart/files/nats-auth/` populated (committed). The user flow is unchanged except they may optionally re-mint:

```bash
# one-time (only needed for fresh init, rotation, or changing nats.stream.name):
scripts/gen-nats-auth.sh        # uses local `nsc`; refuses to overwrite, --force to regen

# the existing flow, unchanged:
kind create cluster --name rrcs
scripts/build-images.sh --kind --kind-name=rrcs
scripts/stress-run.sh --tiers=10 --modes=throughput
```

### 7.2 External (real shared NATS + Redis)

```bash
# User pre-creates Secrets (not done by the chart):
kubectl create secret generic publisher-creds  --from-file=user.creds=publisher.creds  -n rrcs-k8s
kubectl create secret generic subscriber-creds --from-file=user.creds=subscriber.creds -n rrcs-k8s
kubectl create secret generic admin-creds      --from-file=user.creds=admin.creds      -n rrcs-k8s   # optional
kubectl create secret generic redis-central-auth \
  --from-literal=username=default --from-literal=password=*** -n rrcs-k8s                            # optional

# Install with the external values overlay:
helm install rrcs ./chart -n rrcs-k8s --create-namespace -f values-external.yaml
scripts/stress-run.sh --tiers=10 --modes=throughput
```

A `values-external.yaml.example` is committed showing the full shape and the prerequisites the user must satisfy (the narrow `$JS.API.STREAM.INFO.<your-stream-name>` permission on publisher and subscriber; the stream must exist; topic conventions match the values they set).

## 8. Generation tooling: `scripts/gen-nats-auth.sh`

A new committed script. Requires `nsc` installed locally (https://github.com/nats-io/nsc). Behavior:

1. Resolves the bundled stream name from `chart/values.yaml` (`nats.stream.name`, default `APP_EVENTS`).
2. Creates an isolated nsc store under `chart/files/nats-auth/.nsc-store/` (does not pollute the user's global nsc store).
3. Operator: `RRCS-OP` (idempotent; reuses an existing store on rerun unless `--force`).
4. Account: `APP` with JetStream enabled, no explicit limits.
5. Three users, with permissions exactly as Section 3 describes (publisher / subscriber / admin), with `$JS.API.STREAM.INFO.<resolved-stream-name>` baked into publisher and subscriber.
6. Exports artifacts into `chart/files/nats-auth/`:
   - `operator.jwt`, `APP.jwt` (public-key JWTs, safe).
   - `nats-server.conf` (the `operator + resolver MEMORY + resolver_preload` snippet, ready for the ConfigMap to splice in).
   - `publisher.creds`, `subscriber.creds`, `admin.creds`.
7. Refuses to overwrite an existing populated `chart/files/nats-auth/`; `--force` regenerates.
8. A `chart/files/nats-auth/README.md` (also produced by the script) documents: "these are lab fixture identities with no real privilege; do NOT reuse for any other deployment. In production, signing keys live in a secret manager (Vault / External Secrets Operator) and user creds are provisioned into K8s Secrets out-of-band — that's exactly what external mode in this chart consumes."

The script is straightforward: ~50 lines of bash wrapping nsc commands.

## 9. Lab vs production boundary (the fixture-creds caveat)

The lab commits `publisher.creds`, `subscriber.creds`, `admin.creds`, and the `.nsc-store/` (operator + account signing keys) into git. These contain nkey seeds (private key material). For a stress lab they're acceptable — they grant no privilege over anything except a throwaway lab NATS — but the README and `chart/files/nats-auth/README.md` are explicit about the lab-shortcut. The prod alternative is exactly what external mode demonstrates: signing keys in Vault, user creds materialized into K8s Secrets via External Secrets / SealedSecrets / manual `kubectl create secret`.

This dual-mode arrangement makes the lab a clean teaching artifact: bundled mode shows the FORMAT of production auth (operator/account/user JWTs + creds files + narrow JetStream perms), external mode shows the production WORKFLOW (user-supplied identities consumed by the chart).

## 10. Breaking changes vs the current chart

- NATS server now requires the `nats-server.conf` ConfigMap (in bundled mode). The previous `args: ["-js","-sd","/data","-m","8222"]` form is gone; switching is one container-args change.
- Connect YAMLs gain `auth:` blocks. Without auth, the previous YAMLs worked against a no-auth NATS; after this change the rendered YAMLs always reference a creds path. (External-mode users who don't want creds simply… don't enable external auth, but the lab assumes creds are present — there's no no-auth path post-change.)
- `nats-init` Job mounts the admin Secret and uses `--creds` on every nats CLI call.
- Harness purge changes (admin Secret mount via `kubectl run --overrides`).
- 6 connect YAMLs become `tpl`-templated and reference `{{ .Values.nats.stream.* }}` instead of literals.

All of these are scoped to the rrcs-k8s lab; the source compose lab is unaffected.

## 11. /research-lab compliance

This is an enhancement to an existing lab, not a new lab — so the `/research-lab` output-contract checklist doesn't fully apply. The lab continues to satisfy its existing contract: `README.md` is updated to document both modes; `RESEARCH.md` gains a short subsection on credential auth and the bundled-vs-external decision; the design spec is this document; an implementation plan is produced next via `superpowers:writing-plans`; the Helm chart, writer, collector, and harness all continue to work in bundled mode; external mode is additive.

## 12. Open implementation questions (for the plan, not this spec)

- Whether `kubectl run --overrides` or a tiny in-cluster `Job` template is the cleaner harness purge mechanism in external mode (both work; let the plan pick).
- Whether to grant publisher additionally a `pub _R_.>` permission for request/reply patterns (not used by current connect YAMLs; lean: don't add — YAGNI).
- Whether Redis auth env vars on the writer use `REDIS_USERNAME`/`REDIS_PASSWORD` env split or a single `REDIS_URL` form. Writer code change either way; minor.
