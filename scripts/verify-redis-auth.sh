#!/usr/bin/env bash
# verify-redis-auth.sh — kind e2e proof for external Redis PASSWORD auth on the
# Connect legs (issue #39).
#
# What it proves (the two runtime risks the render checks cannot):
#   1. Connect resolves the ${REDIS_*_PASSWORD} env interpolation in the pipeline
#      URL on the STREAMS REST API path (the elector POSTs the config; nothing
#      ever loads it from a file).
#   2. The per-side Secret wiring is not crossed: central and region stand-ins
#      run with DIFFERENT passwords in DIFFERENT Secrets, so a swapped env var
#      fails auth instead of silently passing.
#
# Topology: two in-namespace `--requirepass` Redis Deployments play the
# "external" central and region Redis; two hand-created opaque Secrets (key
# redis-pass) hold their passwords; the chart installs with both sides
# external.enabled=true + authSecret set and the password-less Go workloads
# (writer/dashboard/latency-calculator) disabled — the deliberate issue #39
# deployment shape. Proof of flow: XADD a CDC-shaped event into the central
# stream with redis-cli -a, then poll the region KV for the applied value.
#
# Prereqs: a kind cluster with the app image loaded — run
#   scripts/build-images.sh --kind --kind-name=cdc
# first (same as verify-cdc.sh).
#
# On success the release/namespace are torn down; on failure they are kept for
# debugging (connect logs + kubectl describe are your friends).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.."

NS="${RRCS_NS:-cdc-auth}"
RELEASE="${RRCS_RELEASE:-cdcauth}"
VALUES_FILE="${RRCS_VALUES:-chart/values-dev.yaml}"
PW_CENTRAL="central-pass-e2e"
PW_REGION="region-pass-e2e"
EPOCH="$(date +%s)"

kubectl get ns "${NS}" >/dev/null 2>&1 || kubectl create ns "${NS}"

echo "[redis-auth] deploying passworded central/region Redis stand-ins"
for side in central region; do
  pw_var="PW_$(echo "$side" | tr '[:lower:]' '[:upper:]')"
  kubectl -n "${NS}" apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: redis-ext-${side}
  labels: { app: redis-ext-${side} }
spec:
  replicas: 1
  selector:
    matchLabels: { app: redis-ext-${side} }
  template:
    metadata:
      labels: { app: redis-ext-${side} }
    spec:
      containers:
        - name: redis
          image: redis:7.4-alpine
          args: ["redis-server", "--requirepass", "${!pw_var}", "--appendonly", "no", "--save", ""]
          ports: [{ containerPort: 6379 }]
---
apiVersion: v1
kind: Service
metadata:
  name: redis-ext-${side}
spec:
  selector: { app: redis-ext-${side} }
  ports: [{ port: 6379, targetPort: 6379 }]
EOF
done
kubectl -n "${NS}" rollout status deploy/redis-ext-central deploy/redis-ext-region --timeout=120s

echo "[redis-auth] creating the pre-created opaque Secrets (key redis-pass)"
kubectl -n "${NS}" create secret generic central-redis-auth \
  --from-literal=redis-pass="${PW_CENTRAL}" --dry-run=client -o yaml | kubectl -n "${NS}" apply -f -
kubectl -n "${NS}" create secret generic region-redis-auth \
  --from-literal=redis-pass="${PW_REGION}" --dry-run=client -o yaml | kubectl -n "${NS}" apply -f -

echo "[redis-auth] installing chart: both sides external+auth, Go workloads off"
helm upgrade --install "${RELEASE}" ./chart -n "${NS}" \
  --set profile=cdc -f "${VALUES_FILE}" \
  --set redis.central.external.enabled=true \
  --set "redis.central.external.url=redis://redis-ext-central.${NS}.svc.cluster.local:6379" \
  --set redis.central.external.authSecret=central-redis-auth \
  --set redis.region.external.enabled=true \
  --set "redis.region.external.url=redis://redis-ext-region.${NS}.svc.cluster.local:6379" \
  --set redis.region.external.authSecret=region-redis-auth \
  --set writer.enabled=false --set dashboard.enabled=false --set latencyCalculator.enabled=false \
  --wait --timeout 5m
RESOURCE_PREFIX="$(helm get values "${RELEASE}" -n "${NS}" -o json | jq -r '.resourcePrefix // "lab-"')"

# Same rollout wait as verify-cdc.sh: helm --wait can return before the
# checksum-triggered ReplicaSet is observed, and the elector only POSTs the
# pipeline after winning the Lease.
SINK_DEPLOYS="$(kubectl -n "${NS}" get deploy -o name | grep -E "/${RESOURCE_PREFIX}connect-sink" | sed 's|^deployment.apps/||')"
[ -n "$SINK_DEPLOYS" ] || { echo "[redis-auth] FAIL — no connect-sink deployments found in ${NS}" >&2; exit 1; }
for d in "${RESOURCE_PREFIX}connect-source" $SINK_DEPLOYS; do
  kubectl -n "${NS}" rollout status "deploy/${d}" --timeout=180s
done

EVENT_ID="auth-e2e-${EPOCH}"
KV_KEY="auth:e2e"
WANT="auth-proof-${EPOCH}"
echo "[redis-auth] XADD ${EVENT_ID} into central app.events (authenticated)"
kubectl -n "${NS}" exec deploy/redis-ext-central -- \
  redis-cli --no-auth-warning -a "${PW_CENTRAL}" XADD app.events '*' \
  event_id "${EVENT_ID}" op create type string kv_key "${KV_KEY}" \
  old_key '' new_key '' ts "$(date +%s%3N)" body "${WANT}" >/dev/null

echo "[redis-auth] polling region KV for ${KV_KEY}=${WANT}"
deadline=$(( $(date +%s) + 120 ))
GOT=""
while (( $(date +%s) < deadline )); do
  GOT="$(kubectl -n "${NS}" exec deploy/redis-ext-region -- \
    redis-cli --no-auth-warning -a "${PW_REGION}" GET "${KV_KEY}" 2>/dev/null || true)"
  [ "${GOT}" = "${WANT}" ] && break
  sleep 3
done
if [ "${GOT}" != "${WANT}" ]; then
  echo "[redis-auth] FAIL — region KV ${KV_KEY}=$(printf '%q' "${GOT}") (wanted ${WANT})"
  echo "[redis-auth] debugging hints (namespace kept):"
  echo "  kubectl -n ${NS} logs deploy/${RESOURCE_PREFIX}connect-source -c connect | tail"
  echo "  kubectl -n ${NS} logs deploy/${RESOURCE_PREFIX}connect-sink -c connect | tail"
  exit 1
fi

echo "[redis-auth] PASS — authenticated XADD flowed central→NATS→region KV (streams-API env interpolation proven, per-side Secrets distinct)"
helm uninstall "${RELEASE}" -n "${NS}" --wait --timeout 3m >/dev/null || true
kubectl delete ns "${NS}" --wait=false >/dev/null 2>&1 || true
exit 0
