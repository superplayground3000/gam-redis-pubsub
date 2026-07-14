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
GEN_MODE=poison GEN_RATE=20 GEN_DURATION=20 docker compose run -d --rm generator >/dev/null
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
before=$(natsbox consumer info LAB_CDC cdc_sink --json | jq -r '.ack_floor.consumer_seq')
GEN_MODE=hashpoison GEN_RATE=5 GEN_DURATION=5 docker compose run --rm generator >/dev/null
# DLQ subject must receive the malformed hash body. Assert via `stream get
# --last-for <subject>`: it exits 0 iff at least one message exists on that exact
# subject, 1 otherwise — an unambiguous presence check needing no output parsing.
# (The brief's `stream view --count` does NOT work on this nats CLI: `--count`
# isn't a flag and `stream view` also demands an interactive TTY, so it always
# errored and the grep spuriously "passed" or failed on the error text.) Only the
# hash_decode_failed pipeline branch ever publishes here, so a hit is proof the
# malformed hash body was dead-lettered. Poll: the sink needs a moment to
# consume+publish after the generator exits.
dlq_ok=0
for i in $(seq 1 20); do   # up to ~40s
  if natsbox stream get LAB_CDC --last-for 'dlq.cdc.hash_decode_error' -j >/dev/null 2>&1; then dlq_ok=1; break; fi
  sleep 2
done
[ "$dlq_ok" = "1" ] || fail "no message parked on dlq.cdc.hash_decode_error"
# ack floor must ADVANCE (poison acked after DLQ publish, not stuck redelivering)
after=0
for i in $(seq 1 15); do   # up to ~30s for the ack floor to catch up
  after=$(natsbox consumer info LAB_CDC cdc_sink --json | jq -r '.ack_floor.consumer_seq')
  awk "BEGIN{exit !($after > $before)}" && break
  sleep 2
done
awk "BEGIN{exit !($after > $before)}" || fail "ack floor did not advance ($before -> $after): poison is looping"
echo "  ack floor advanced $before -> $after; DLQ received hash poison on dlq.cdc.hash_decode_error"

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
