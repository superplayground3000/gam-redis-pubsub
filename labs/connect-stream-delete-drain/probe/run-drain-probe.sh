#!/usr/bin/env bash
# Deep-dive on the close/drain paths for hpdevelop/connect:v4.92.0-batch-nats:
#   D1 DELETE /streams/{id}: does it drain the batch-fetched in-flight set, or
#      abandon it un-acked? And do the abandoned msgs recover via redelivery
#      when a consumer re-binds (⇒ no loss)?
#   D2 SIGTERM (process graceful stop, shutdown_timeout=20s): does it drain
#      (apply+ack the in-flight set) before exiting?
# Uses a moderate burst so a full drain fits inside the stop grace.
set -uo pipefail
cd "$(dirname "$0")"
API=http://localhost:14195
line(){ printf '%.0s─' {1..72}; echo; }
box(){ docker compose exec -T box sh -c "$1"; }
nats(){ docker compose exec -T box nats --server nats://nats:4222 "$@"; }
cf(){ box "nats --server nats://nats:4222 consumer info PROBE probe_cons --json | jq -r '$1'"; }
post(){ curl -sS -o /dev/null -w '%{http_code}' -X POST --data-binary @connect/p3-drain.yaml -H 'Content-Type: application/x-yaml' "$API/streams/probe"; }
del(){ curl -sS -o /dev/null -w '%{http_code}' -X DELETE "$API/streams/probe"; }
reset(){ nats consumer rm PROBE probe_cons -f >/dev/null 2>&1; nats stream purge PROBE -f >/dev/null 2>&1;
  nats consumer add PROBE probe_cons --pull --filter 'probe.>' --ack explicit --deliver all \
    --replay instant --wait 3s --max-pending 1024 --max-deliver=-1 --defaults >/dev/null 2>&1; }
pub(){ box "for i in \$(seq 1 $1); do nats --server nats://nats:4222 pub probe.k\$i v\$i; done"; }
wait_inflight(){ for _ in $(seq 1 20); do n=$(cf '.num_ack_pending'); n=${n:-0}; [ "$n" -gt 3 ] 2>/dev/null && break; sleep 0.5; done; echo "$n"; }

echo "== up =="; docker compose up -d --wait 2>&1 | tail -1

line; echo "D1 — DELETE drain? + redelivery recovery (no-loss)"; line
reset; [ "$(post)" = 200 ] || echo "POST failed"
pub 30 >/dev/null
inflight=$(wait_inflight)
echo "at DELETE: num_ack_pending=$inflight delivered=$(cf '.delivered.consumer_seq') ack_floor=$(cf '.ack_floor.consumer_seq')"
t0=$(date +%s.%N); code=$(del); t1=$(date +%s.%N)
echo "DELETE -> HTTP $code in $(awk "BEGIN{printf \"%.2f\",$t1-$t0}")s"
sleep 2
echo "post-DELETE: num_ack_pending=$(cf '.num_ack_pending') ack_floor=$(cf '.ack_floor.consumer_seq') num_pending=$(cf '.num_pending')"
echo "   (ack_floor≈30 & num_ack_pending→0  ⇒ DRAINED; ack_floor small & num_ack_pending large ⇒ NOT drained, abandoned un-acked)"
echo "-- re-POST to re-bind a consumer and let abandoned msgs redeliver --"
[ "$(post)" = 200 ] || echo "re-POST failed"
for t in 2 4 6; do sleep 2; echo "  +${t}s ack_floor=$(cf '.ack_floor.consumer_seq') num_ack_pending=$(cf '.num_ack_pending') deliv_seq=$(cf '.delivered.consumer_seq')"; done
echo "   (ack_floor reaching 30 after re-bind ⇒ NO LOSS: abandoned msgs redelivered+applied)"
del >/dev/null; sleep 1

line; echo "D2 — SIGTERM graceful drain (shutdown_timeout=20s)?"; line
reset; [ "$(post)" = 200 ] || echo "POST failed"
pub 20 >/dev/null
inflight=$(wait_inflight)
echo "at SIGTERM: num_ack_pending=$inflight delivered=$(cf '.delivered.consumer_seq') ack_floor=$(cf '.ack_floor.consumer_seq')"
echo "-- docker stop -t 30 connect (SIGTERM, up to 30s grace) --"
t0=$(date +%s.%N); docker compose stop -t 30 connect >/dev/null 2>&1; t1=$(date +%s.%N)
echo "connect stopped in $(awk "BEGIN{printf \"%.1f\",$t1-$t0}")s (≈inflight×0.5s ⇒ it drained before exiting)"
echo "consumer after SIGTERM: ack_floor=$(cf '.ack_floor.consumer_seq') num_ack_pending=$(cf '.num_ack_pending') num_pending=$(cf '.num_pending')"
echo "   (ack_floor=20 & num_ack_pending=0 ⇒ DRAINED on SIGTERM; else abandoned un-acked)"
echo "applied log lines during shutdown: $(docker compose logs connect 2>/dev/null | grep -c PROBE_APPLIED)"

line
if [ "${KEEP:-0}" = 1 ]; then echo "KEEP=1 — leaving up."; else echo "== teardown =="; docker compose down -v 2>&1 | tail -1; fi
