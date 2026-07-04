#!/usr/bin/env bash
# Automated proof: healthy → no alert; poison → alert fires (both reasons) & webhook
# received; recovery (purge) → alert clears. Resolves metric names from /metrics
# first (no _total assumption). Exits 0 on PASS, 1 on FAIL.
set -uo pipefail
cd "$(dirname "$0")/.."
PROM="http://localhost:${PROM_PORT:-19090}"
SINK="http://localhost:${ALERT_SINK_PORT:-19099}"
ALERT="CDCUnprocessableMessages"

fail() { echo "FAIL: $*"; exit 1; }
psql() { curl -s "$PROM/api/v1/query" --data-urlencode "query=$1" | jq -r '.data.result'; }
alert_state() { curl -s "$PROM/api/v1/alerts" | jq -r --arg a "$ALERT" '[.data.alerts[]|select(.labels.alertname==$a)]'; }

echo "== clean-room reset (fresh alert-sink store, TSDB, JetStream — repeatable gate) =="
docker compose down -v >/dev/null 2>&1 || true

echo "== bring up =="
scripts/run-lab.sh >/dev/null
# wait for prometheus target up
for i in $(seq 1 30); do
  up=$(curl -s "$PROM/api/v1/targets" | jq -r '[.data.activeTargets[]|select(.labels.job=="cdc-connect-sink" and .health=="up")]|length')
  [ "$up" = "1" ] && break; sleep 2
done
[ "${up:-0}" = "1" ] || fail "connect target never came up"

echo "== resolve metric names from /metrics (no _total assumption) =="
metrics=$(docker run --rm --network "container:$(docker compose ps -q connect)" curlimages/curl -s http://localhost:4195/metrics)
echo "$metrics" | grep -qE '^cdc_apply(_total)?\{' || echo "  (cdc_apply not present yet — will appear after healthy traffic)"

echo "== PHASE 1: healthy → alert must stay inactive, cdc_apply must be applied =="
GEN_MODE=healthy GEN_RATE=30 GEN_DURATION=15 docker compose run --rm generator >/dev/null
# Assert on the RAW counter (not increase()): it's true after a single scrape, so it
# needs only ~one scrape interval to settle and is immune to increase()'s ≥2-sample
# window requirement for a series that springs into existence mid-window.
sleep 20
applied=$(psql 'sum({__name__=~"cdc_apply(_total)?"})' | jq -r 'if length>0 then .[0].value[1] else "0" end')
echo "  cdc_apply total=$applied"
awk "BEGIN{exit !($applied > 0)}" || fail "healthy phase produced no cdc_apply"
firing=$(alert_state | jq -r '[.[]|select(.state=="firing")]|length')
[ "$firing" = "0" ] || fail "alert fired during healthy phase ($firing)"
echo "  OK: cdc_apply applied, alert inactive"

echo "== PHASE 2: poison → alert must fire (both reasons) and webhook must receive it =="
# Capture the detached generator so we can kill it before the Phase-3 purge — otherwise
# a still-running producer could re-publish poison right after the purge and the alert
# would never clear (false FAIL). Poison on the stream redelivers forever under
# maxDeliver=-1, so the generator only needs to run briefly to seed both reasons.
gen=$(GEN_MODE=poison GEN_RATE=20 GEN_DURATION=20 docker compose run -d --rm generator)
ok=0
for i in $(seq 1 40); do    # up to ~2min
  st=$(alert_state)
  reasons=$(echo "$st" | jq -r '[.[]|select(.state=="firing")|.labels.reason]|sort|unique|join(",")')
  if echo "$reasons" | grep -q "decode_error" && echo "$reasons" | grep -q "unknown_op"; then ok=1; echo "  alert firing for reasons: $reasons"; break; fi
  sleep 3
done
[ "$ok" = "1" ] || fail "alert did not fire for both poison reasons in time (last: ${reasons:-none})"
# webhook received it
sink_ok=$(curl -s "$SINK/alerts" | jq -r --arg a "$ALERT" '[.[]|select(.labels.alertname==$a and .status=="firing")]|length')
[ "${sink_ok:-0}" -ge 1 ] || fail "alert-sink did not receive the firing alert"
echo "  OK: alert firing (both reasons) + webhook received ($sink_ok)"

echo "== PHASE 3: recovery → stop producer, purge poison, alert must clear (~2m window) =="
docker rm -f "$gen" >/dev/null 2>&1 || true   # ensure no producer survives the purge
docker run --rm --network "container:$(docker compose ps -q nats)" natsio/nats-box:0.14.5 \
  nats --server nats://localhost:4222 stream purge LAB_CDC -f >/dev/null 2>&1 || \
  docker compose run --rm --entrypoint sh nats-init -c 'nats --server nats://nats:4222 stream purge LAB_CDC -f' >/dev/null
cleared=0
for i in $(seq 1 60); do    # up to ~3min (window 2m + margin)
  firing=$(alert_state | jq -r '[.[]|select(.state=="firing")]|length')
  if [ "$firing" = "0" ]; then cleared=1; echo "  alert cleared after ~$((i*3))s"; break; fi
  sleep 3
done
[ "$cleared" = "1" ] || fail "alert did not clear within ~3min after purge"

echo "PASS: healthy-clean, poison-fires-both-reasons+webhook, recovery-clears"
