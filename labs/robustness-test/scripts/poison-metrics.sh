#!/usr/bin/env bash
# poison-metrics.sh — phase 4: prove cdc_unprocessable{reason} counts every
# unprocessable message on this image.
#   unknown_op  : XADD op=frobnicate through the whole pipeline.
#   decode_error: published DIRECTLY to NATS subject kv.cdc.create with
#                 enc=gzip:base64 + garbage body (the forward leg re-encodes
#                 bodies, so XADD cannot produce a decode failure).
# Oracle: per-reason counter delta >= N_POISON on the sink leader's :4195/metrics.
# (>=, never ==: maxDeliver=-1 redelivers poison forever by design — INV-1 row 7.)
# Cleanup: purge KV_CDC (stops the error loop), then a 100-key good-traffic
# sanity proves the pipeline still applies messages.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

NP="${N_POISON:-5}"
LPORT="${LOCAL_METRICS_PORT:-15195}"
ACK_WAIT_S=30                       # nats.stream.consumer.ackWait (values.yaml)
METRIC_TIMEOUT_S=$(( ACK_WAIT_S * 3 ))
SINK_TIMEOUT_S="${SINK_TIMEOUT_S:-300}"
PUB_POD="robust-poison-pub"
NATS_SERVER="nats://${PREFIX}nats:4222"

cleanup() {
  [[ -n "${PF_PID:-}" ]] && kill "$PF_PID" 2>/dev/null || true
  kubectl -n "$NS" delete pod "$PUB_POD" --ignore-not-found --now >/dev/null 2>&1 || true
}
trap cleanup EXIT

h="$(holder "$SINK_LEASE")"; [[ -n "$h" ]] || die "no sink lease holder"
kubectl -n "$NS" port-forward "pod/$h" "${LPORT}:4195" >/dev/null 2>&1 &
PF_PID=$!
sleep 3

# metric_sum <reason> — sum of all cdc_unprocessable series with that reason label
metric_sum() {
  curl -s "http://127.0.0.1:${LPORT}/metrics" \
    | awk -v r="reason=\"$1\"" '$0 ~ /^cdc_unprocessable/ && $0 ~ r { s += $NF } END { printf "%d\n", s }'
}
u0="$(metric_sum unknown_op)"; d0="$(metric_sum decode_error)"
log "sink leader $h baseline: unknown_op=${u0} decode_error=${d0}"

runid="$(now_ms)"
# --- inject unknown_op via the full pipeline ---
{
  ts="$(now_ms)"
  for (( i=1; i<=NP; i++ )); do
    echo "XADD $STREAM * event_id pu-${runid}-${i} op frobnicate type string kv_key lb:robust:poison:{run:${runid}:u${i}} ts ${ts} body x"
  done
} | kubectl -n "$NS" exec -i "$CENTRAL" -- redis-cli >/dev/null

# --- inject decode_error directly into JetStream via a nats-box pod ---
kubectl -n "$NS" apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${PUB_POD}
spec:
  restartPolicy: Never
  containers:
    - name: pub
      image: natsio/nats-box:0.14.5
      command: ["/bin/sh", "-c", "sleep 900"]
      volumeMounts:
        - { name: pub-creds,   mountPath: /etc/nats-creds/publisher, readOnly: true }
        - { name: admin-creds, mountPath: /etc/nats-creds/admin,     readOnly: true }
  volumes:
    - name: pub-creds
      secret: { secretName: ${PREFIX}publisher-creds, defaultMode: 0444 }
    - name: admin-creds
      secret: { secretName: ${PREFIX}admin-creds, defaultMode: 0444 }
EOF
kubectl -n "$NS" wait --for=condition=Ready "pod/${PUB_POD}" --timeout=120s >/dev/null
for (( i=1; i<=NP; i++ )); do
  env_json="{\"event_id\":\"pd-${runid}-${i}\",\"op\":\"create\",\"type\":\"string\",\"kv_key\":\"lb:robust:poison:{run:${runid}:d${i}}\",\"old_key\":\"\",\"new_key\":\"\",\"ts\":\"0\",\"enc\":\"gzip:base64\",\"body\":\"!!!not-base64-gzip!!!\"}"
  kubectl -n "$NS" exec "$PUB_POD" -- nats --server "$NATS_SERVER" \
    --creds /etc/nats-creds/publisher/user.creds pub kv.cdc.create "$env_json" >/dev/null
done
log "injected ${NP}x unknown_op (XADD) + ${NP}x decode_error (NATS pub)"

# --- assert per-reason deltas >= NP within 3x ackWait ---
deadline=$(( $(date +%s) + METRIC_TIMEOUT_S )); u=0; d=0
while (( $(date +%s) < deadline )); do
  u="$(metric_sum unknown_op)"; d="$(metric_sum decode_error)"
  (( u - u0 >= NP && d - d0 >= NP )) && break
  sleep 5
done
[[ "$(holder "$SINK_LEASE")" == "$h" ]] || { log "INCONCLUSIVE: sink leadership changed mid-phase"; exit 3; }
(( u - u0 >= NP )) || die "unknown_op delta $((u-u0)) < ${NP} after ${METRIC_TIMEOUT_S}s"
(( d - d0 >= NP )) || die "decode_error delta $((d-d0)) < ${NP} after ${METRIC_TIMEOUT_S}s"
log "deltas: unknown_op +$((u-u0)) decode_error +$((d-d0)) (>= ${NP} each)"

# --- purge poison (it redelivers forever otherwise), then good-traffic sanity ---
kubectl -n "$NS" exec "$PUB_POD" -- nats --server "$NATS_SERVER" \
  --creds /etc/nats-creds/admin/user.creds stream purge KV_CDC -f >/dev/null
log "purged KV_CDC; running 100-key good-traffic sanity"
xadd_batch "$runid" 100 postpoison
final="$(wait_region_full "$runid" postpoison 100 "$SINK_TIMEOUT_S")"
(( final == 100 )) || die "post-purge good traffic incomplete: ${final}/100"
log "PASS — cdc_unprocessable counted both reasons (unknown_op +$((u-u0)), decode_error +$((d-d0))) and good traffic recovered"
