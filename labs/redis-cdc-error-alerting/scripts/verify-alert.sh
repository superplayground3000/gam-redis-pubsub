#!/usr/bin/env bash
# Automated proof: healthy → no alert; poison → alert fires (both reasons) & webhook
# received; hash poison → dead-letters to dlq.cdc.hash_decode_error and the sink
# consumer's ack floor advances (no loop); recovery (purge) → alert clears. Resolves
# metric names from /metrics first (no _total assumption). Exits 0 on PASS, 1 on FAIL.
set -uo pipefail
cd "$(dirname "$0")/.."
PROM="http://localhost:${PROM_PORT:-19090}"
SINK="http://localhost:${ALERT_SINK_PORT:-19099}"
ALERT="CDCUnprocessableMessages"

fail() { echo "FAIL: $*"; exit 1; }
psql() { curl -s "$PROM/api/v1/query" --data-urlencode "query=$1" | jq -r '.data.result'; }
alert_state() { curl -s "$PROM/api/v1/alerts" | jq -r --arg a "$ALERT" '[.data.alerts[]|select(.labels.alertname==$a)]'; }
# The `nats` service is the plain nats:2.10-alpine SERVER image — it has no `nats`
# CLI inside it, so `docker compose exec nats nats ...` fails ("executable file
# not found"). Run the CLI from a nats-box container joined to the nats
# container's network namespace instead (same trick Phase 4's purge already uses).
natsbox() { docker run --rm --network "container:$(docker compose ps -q nats)" natsio/nats-box:0.14.5 nats --server nats://localhost:4222 "$@"; }
# Message count on ONE stream subject (empty -> nothing printed -> caller defaults 0).
subj_count() { natsbox stream subjects LAB_CDC "$1" 2>/dev/null | grep -oE "$(printf '%s' "$1" | sed 's/\./\\./g')[^0-9]+[0-9]+" | grep -oE '[0-9]+$' | head -1; }
# Always tear the lab down on exit (success OR failure) so a rerun starts clean —
# leftover containers + a file-backed stream are exactly the stale state that makes
# Phase 3 assertions pass on the wrong data. Preserve the real exit code.
trap 'ec=$?; docker compose down -v >/dev/null 2>&1 || true; exit $ec' EXIT

echo "== bring up =="
scripts/run-lab.sh >/dev/null
# Build the generator NOW so every phase uses current code. run-lab.sh only builds
# the long-running services (generator is profile "gen"); `docker compose run
# generator` reuses a stale image and would NOT pick up generator/ source changes
# (e.g. the hashpoison mode) — silently running old code and publishing nothing the
# DLQ phase expects.
docker compose build generator >/dev/null 2>&1 || fail "generator image build failed"
# wait for prometheus target up
for i in $(seq 1 30); do
  up=$(curl -s "$PROM/api/v1/targets" | jq -r '[.data.activeTargets[]|select(.labels.job=="cdc-connect-sink" and .health=="up")]|length')
  [ "$up" = "1" ] && break; sleep 2
done
[ "${up:-0}" = "1" ] || fail "connect target never came up"

echo "== resolve metric names from /metrics (no _total assumption) =="
metrics=$(docker run --rm --network "container:$(docker compose ps -q connect)" curlimages/curl -s http://localhost:4195/metrics)
echo "$metrics" | grep -qE '^cdc_apply(_total)?\{' || echo "  (cdc_apply not present yet — will appear after healthy traffic)"

echo "== PHASE 1: healthy → alert must stay inactive, cdc_apply must climb =="
GEN_MODE=healthy GEN_RATE=30 GEN_DURATION=15 docker compose run --rm generator >/dev/null
# Poll: at a 15s scrape interval, increase[2m] needs two samples of the new
# counter series before it turns nonzero — a fixed short sleep flakes.
applied=0
for i in $(seq 1 20); do
  applied=$(psql 'sum(increase({__name__=~"cdc_apply(_total)?"}[2m]))' | jq -r 'if length>0 then .[0].value[1] else "0" end')
  awk "BEGIN{exit !($applied > 0)}" && break
  sleep 3
done
echo "  cdc_apply increase(2m)=$applied"
awk "BEGIN{exit !($applied > 0)}" || fail "healthy phase produced no cdc_apply increase"
firing=$(alert_state | jq -r '[.[]|select(.state=="firing")]|length')
[ "$firing" = "0" ] || fail "alert fired during healthy phase ($firing)"
echo "  OK: cdc_apply climbing, alert inactive"

echo "== PHASE 2: poison → alert must fire (both reasons) and webhook must receive it =="
# FOREGROUND (not `-d`): the generator publishes its full poison batch and EXITS
# before we poll, so the stream is settled by the time Phase 3 baselines it. With
# the DLQ enabled each poison increments cdc_unprocessable once (then is DLQ'd +
# acked), which is enough to arm the increase[2m] alert — no need for a detached
# generator to keep re-injecting.
GEN_MODE=poison GEN_RATE=20 GEN_DURATION=20 docker compose run --rm generator >/dev/null
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

echo "== PHASE 3: hash poison -> DLQ, ack floor advances, no loop =="
# This phase must prove THIS hashpoison batch (not stale/concurrent state) was
# dead-lettered and acked. So: (1) settle the stream, (2) BASELINE the specific
# dlq.cdc.hash_decode_error subject + the consumer's ack_floor and num_redelivered
# BEFORE injecting, (3) inject a known small batch in the FOREGROUND, (4) assert the
# DELTAS. Phase 2's poison lands on dlq.cdc.{unknown_op,decode_error} — DIFFERENT
# subjects — so baselining the hash subject isolates this batch from that traffic.
sleep 5   # let the sink drain any in-flight Phase-2 poison before we baseline
BASE_DLQ=$(subj_count 'dlq.cdc.hash_decode_error'); BASE_DLQ="${BASE_DLQ:-0}"
ci=$(natsbox consumer info LAB_CDC cdc_sink --json)
BASE_FLOOR=$(echo "$ci" | jq -r '.ack_floor.consumer_seq')
BASE_REDEL=$(echo "$ci" | jq -r '.num_redelivered')
echo "  baseline: dlq.cdc.hash_decode_error=$BASE_DLQ ack_floor=$BASE_FLOOR num_redelivered=$BASE_REDEL"

# Inject a KNOWN small batch (~10 msgs at 5/s for 2s), FOREGROUND (waits for exit).
GEN_MODE=hashpoison GEN_RATE=5 GEN_DURATION=2 docker compose run --rm generator >/dev/null

# (a) the hash-DLQ subject must GROW by this batch (new hash poison dead-lettered,
# not merely "some message already there"). `stream subjects` filtered to the exact
# subject is the count. (The brief's `stream view --count` is unusable on this nats
# CLI — `--count` is not a flag and `stream view` needs an interactive TTY.)
AFTER_DLQ="$BASE_DLQ"
for i in $(seq 1 20); do   # up to ~40s for consume+DLQ-publish
  AFTER_DLQ=$(subj_count 'dlq.cdc.hash_decode_error'); AFTER_DLQ="${AFTER_DLQ:-0}"
  [ "$AFTER_DLQ" -gt "$BASE_DLQ" ] && break
  sleep 2
done
[ "$AFTER_DLQ" -gt "$BASE_DLQ" ] || fail "dlq.cdc.hash_decode_error did not grow ($BASE_DLQ -> $AFTER_DLQ): this hash-poison batch was NOT dead-lettered"

# (b) ack_floor must ADVANCE (the batch was acked after DLQ publish) and (c)
# num_redelivered must NOT climb materially (acked once, not nack-looping).
AFTER_FLOOR="$BASE_FLOOR"; AFTER_REDEL="$BASE_REDEL"
for i in $(seq 1 20); do   # up to ~40s for the ack floor to catch up
  ci=$(natsbox consumer info LAB_CDC cdc_sink --json)
  AFTER_FLOOR=$(echo "$ci" | jq -r '.ack_floor.consumer_seq')
  AFTER_REDEL=$(echo "$ci" | jq -r '.num_redelivered')
  awk "BEGIN{exit !($AFTER_FLOOR > $BASE_FLOOR)}" && break
  sleep 2
done
awk "BEGIN{exit !($AFTER_FLOOR > $BASE_FLOOR)}" || fail "ack_floor did not advance ($BASE_FLOOR -> $AFTER_FLOOR): hash poison stuck"
awk "BEGIN{exit !(($AFTER_REDEL - $BASE_REDEL) <= 1)}" || fail "num_redelivered climbed ($BASE_REDEL -> $AFTER_REDEL): hash poison is looping, not acked-after-DLQ"
echo "  dlq.cdc.hash_decode_error $BASE_DLQ -> $AFTER_DLQ; ack_floor $BASE_FLOOR -> $AFTER_FLOOR; num_redelivered $BASE_REDEL -> $AFTER_REDEL"

echo "== PHASE 4: recovery → purge poison, alert must clear (~2m window) =="
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

echo "PASS: healthy-clean, poison-fires-both-reasons+webhook, dlq-hash-poison-acked, recovery-clears"
