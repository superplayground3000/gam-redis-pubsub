#!/usr/bin/env bash
# setup-nats-auth.sh — WORKAROUND for a gap the DESIGN missed: the chart's baked
# subscriber JWT grants JS-API perms scoped to the EXACT durable `cdc_sink`
# ($JS.API.CONSUMER.INFO.KV_CDC.cdc_sink, $JS.ACK.KV_CDC.cdc_sink.>, ...). The lab's
# per-prefix durables (cdc_sink_prefix-a ...) are therefore rejected with
# "Permissions Violation", and the account signing key is gitignored so we cannot
# mint a new user under the existing account.
#
# Fix WITHOUT touching chart files: generate a fresh, self-consistent operator/
# account/user set whose SUBSCRIBER carries WILDCARD consumer perms
# ($JS.API.CONSUMER.*.KV_CDC.*, $JS.ACK.KV_CDC.>), then inject it at the k8s-object
# level (replace the lab-nats-config ConfigMap + the three creds Secrets). chart/
# stays byte-for-byte untouched. Caller restarts NATS (emptyDir -> JS wiped) and
# recreates the stream via admin. Idempotent.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"

OUT="$LAB/nats-auth"
STORE="$OUT/.nsc-store"
STREAM_NAME="KV_CDC"
SUBJECT_PREFIX="kv.cdc"
OPERATOR_NAME="${OPERATOR_NAME:-RRCS-OP-LAB}"
ACCOUNT_NAME="APP"

command -v nsc >/dev/null || { echo "FATAL: nsc not on PATH (needed to mint lab creds)"; exit 3; }

if [ "${REGEN_AUTH:-1}" = 1 ] || [ ! -f "$OUT/subscriber.creds" ]; then
  rm -rf "$STORE"; mkdir -p "$OUT" "$STORE/data" "$STORE/config"
  # nsc refuses to overwrite an existing config/creds — clear prior artifacts
  rm -f "$OUT"/*.creds "$OUT"/nats-server.conf "$OUT"/*.jwt
  export XDG_DATA_HOME="$STORE/data" XDG_CONFIG_HOME="$STORE/config"

  nsc add operator --name "$OPERATOR_NAME" >/dev/null
  nsc add account --name SYS >/dev/null
  nsc edit operator --system-account SYS >/dev/null
  nsc add account --name "$ACCOUNT_NAME" >/dev/null
  nsc edit account --name "$ACCOUNT_NAME" --js-streams -1 --js-consumer -1 \
    --js-mem-storage -1 --js-disk-storage -1 >/dev/null

  # publisher: identical grant to the chart's (publish kv.cdc.>)
  nsc add user --account "$ACCOUNT_NAME" --name publisher \
    --allow-pub "${SUBJECT_PREFIX}.>" \
    --allow-pub '$JS.API.STREAM.INFO.'"$STREAM_NAME" \
    --allow-sub '_INBOX.>' >/dev/null

  # subscriber: WILDCARD consumer perms (the only real change vs chart) — any
  # cdc_sink_<prefix> durable on KV_CDC, plus its ack subject tree.
  nsc add user --account "$ACCOUNT_NAME" --name subscriber \
    --allow-pub '$JS.API.STREAM.INFO.'"$STREAM_NAME" \
    --allow-pub '$JS.API.CONSUMER.INFO.'"$STREAM_NAME"'.*' \
    --allow-pub '$JS.API.CONSUMER.CREATE.'"$STREAM_NAME"'.*' \
    --allow-pub '$JS.API.CONSUMER.CREATE.'"$STREAM_NAME"'.*.>' \
    --allow-pub '$JS.API.CONSUMER.DURABLE.CREATE.'"$STREAM_NAME"'.*' \
    --allow-pub '$JS.API.CONSUMER.MSG.NEXT.'"$STREAM_NAME"'.*' \
    --allow-pub '$JS.ACK.'"$STREAM_NAME"'.>' \
    --allow-sub '_INBOX.>' >/dev/null

  # admin: full JS API + ack (creates stream/consumers, purges)
  nsc add user --account "$ACCOUNT_NAME" --name admin \
    --allow-pub '$JS.API.>' \
    --allow-pub '$JS.ACK.'"$STREAM_NAME"'.>' \
    --allow-sub '_INBOX.>' >/dev/null

  nsc generate config --mem-resolver --config-file "$OUT/nats-server.conf" >/dev/null
  nsc generate creds --account "$ACCOUNT_NAME" --name publisher  > "$OUT/publisher.creds"
  nsc generate creds --account "$ACCOUNT_NAME" --name subscriber > "$OUT/subscriber.creds"
  nsc generate creds --account "$ACCOUNT_NAME" --name admin      > "$OUT/admin.creds"
  echo "[nats-auth] generated fresh auth set in $OUT (wildcard subscriber)"
fi

for f in nats-server.conf publisher.creds subscriber.creds admin.creds; do
  [ -s "$OUT/$f" ] || { echo "FATAL: $OUT/$f missing/empty"; exit 3; }
done

# Rebuild the FULL server config = chart preamble (server_name/ports/jetstream) + our
# auth block. The chart's nats-config-cm.yaml wraps the auth file with exactly this
# preamble (server_name rrcs-nats, port 4222, http_port 8222, jetstream store_dir
# /data); replacing the ConfigMap with only the nsc auth would drop JetStream and the
# server would never become ready (bit us once).
FULL="$OUT/nats-server.full.conf"
{
  echo "server_name: rrcs-nats"
  echo "port: 4222"
  echo "http_port: 8222"
  echo "jetstream {"
  echo "  store_dir: /data"
  echo "}"
  cat "$OUT/nats-server.conf"
} > "$FULL"

# inject at k8s level (chart untouched)
kc create configmap lab-nats-config --from-file=nats-server.conf="$FULL" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
kc create secret generic lab-publisher-creds  --from-file=user.creds="$OUT/publisher.creds"  --dry-run=client -o yaml | kc apply -f - >/dev/null
kc create secret generic lab-subscriber-creds --from-file=user.creds="$OUT/subscriber.creds" --dry-run=client -o yaml | kc apply -f - >/dev/null
kc create secret generic lab-admin-creds      --from-file=user.creds="$OUT/admin.creds"      --dry-run=client -o yaml | kc apply -f - >/dev/null
echo "[nats-auth] injected lab-nats-config + 3 creds Secrets (chart files untouched)"
