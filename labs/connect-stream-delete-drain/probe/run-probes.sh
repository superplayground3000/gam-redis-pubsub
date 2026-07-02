#!/usr/bin/env bash
# Empirically confirm three build-specific facts about
# hpdevelop/connect:v4.92.0-batch-nats before building the full lab.
#   P1 delivery-count metadata key
#   P2 throw ⇒ nack(redeliver) vs silent drop-and-ack under reject_errored.drop
#   P3 DELETE /streams/{id} ⇒ drain(apply+ack in-flight) vs hard-close; is DELETE blocking?
# Usage: ./run-probes.sh        (tears down at end)
#        KEEP=1 ./run-probes.sh (leave stack up for poking)
set -uo pipefail
cd "$(dirname "$0")"
API=http://localhost:14195
line() { printf '%.0s─' {1..72}; echo; }
box()  { docker compose exec -T box sh -c "$1"; }
nats() { docker compose exec -T box nats --server nats://nats:4222 "$@"; }
cf()   { box "nats --server nats://nats:4222 consumer info PROBE probe_cons --json | jq -r '$1'"; }
post() { curl -sS -o /tmp/probe_post.out -w '%{http_code}' -X POST --data-binary @"$1" -H 'Content-Type: application/x-yaml' "$API/streams/probe"; }
del()  { curl -sS -o /dev/null -w '%{http_code}' -X DELETE "$API/streams/probe"; }
reset_consumer() {
  nats consumer rm PROBE probe_cons -f >/dev/null 2>&1
  nats stream purge PROBE -f >/dev/null 2>&1
  nats consumer add PROBE probe_cons --pull --filter 'probe.>' --ack explicit \
    --deliver all --replay instant --wait 3s --max-pending 1024 --max-deliver=-1 --defaults >/dev/null 2>&1
}

echo "== bringing up probe stack =="
docker compose up -d --wait 2>&1 | tail -2 || { docker compose logs --tail=30; exit 1; }

line; echo "P1 — delivery-count metadata key"; line
reset_consumer
[ "$(post connect/p1-meta.yaml)" = 200 ] || { echo "POST p1 failed:"; cat /tmp/probe_post.out; }
box "for i in 1 2 3; do nats --server nats://nats:4222 pub probe.k\$i v\$i; done"
sleep 3
echo "-- metadata dumped by the pipeline (look for a delivery-count key) --"
docker compose logs connect --since 30s 2>/dev/null | grep -o '"all_meta":{[^}]*}' | head -1 \
  || docker compose logs connect --since 30s 2>/dev/null | grep PROBE_META | head -1
del >/dev/null; sleep 1

line; echo "P2 — throw ⇒ nack(redeliver) or drop-and-ack?"; line
reset_consumer
[ "$(post connect/p2-throw.yaml)" = 200 ] || { echo "POST p2 failed:"; cat /tmp/probe_post.out; }
box "nats --server nats://nats:4222 pub probe.k1 v1"
printf '%-6s %-14s %-16s %-13s %-11s\n' t deliv_seq num_redelivered num_ack_pend num_pending
for t in 0 1 2 3 4 5 7 9; do
  sleep 1
  printf '%-6s %-14s %-16s %-13s %-11s\n' "${t}s" "$(cf '.delivered.consumer_seq')" \
    "$(cf '.num_redelivered')" "$(cf '.num_ack_pending')" "$(cf '.num_pending')"
done
echo "-> if deliv_seq climbs past 1 (and num_redelivered>0): throw ⇒ NACK ⇒ redelivery (GOOD)"
echo "-> if deliv_seq stays 1, num_pending→0, nothing redelivers: throw ⇒ drop-and-ACK (BAD for the lab)"
del >/dev/null; sleep 1

line; echo "P3 — DELETE ⇒ drain(apply+ack) or hard-close? is DELETE blocking?"; line
reset_consumer
[ "$(post connect/p3-drain.yaml)" = 200 ] || { echo "POST p3 failed:"; cat /tmp/probe_post.out; }
echo "publishing burst of 60 (500ms/msg pipeline)…"
box "for i in \$(seq 1 60); do nats --server nats://nats:4222 pub probe.k\$i v\$i; done"
# wait until an in-flight set exists
inflight=0
for _ in $(seq 1 20); do
  inflight=$(cf '.num_ack_pending'); inflight=${inflight:-0}
  [ "$inflight" -gt 3 ] 2>/dev/null && break
  sleep 0.5
done
echo "in-flight (num_ack_pending) at DELETE time: $inflight"
echo "delivered so far: $(cf '.delivered.consumer_seq'), acked_floor: $(cf '.ack_floor.consumer_seq')"
echo "-- firing DELETE /streams/probe (timing it) --"
t0=$(date +%s.%N); code=$(del); t1=$(date +%s.%N)
echo "DELETE returned HTTP $code in $(awk "BEGIN{printf \"%.2f\", $t1-$t0}")s (blocking ≈ inflight×0.5s ⇒ drained-then-returned)"
printf '%-8s %-14s %-16s %-13s %-11s\n' after deliv_seq ack_floor num_ack_pend num_pending
for t in 0 1 3 5; do
  printf '%-8s %-14s %-16s %-13s %-11s\n' "+${t}s" "$(cf '.delivered.consumer_seq')" \
    "$(cf '.ack_floor.consumer_seq')" "$(cf '.num_ack_pending')" "$(cf '.num_pending')"
  sleep 1
done
echo "-> ack_floor jumped to cover the in-flight set with num_ack_pending→0 quickly ⇒ DRAINED (apply+ack on close)"
echo "-> in-flight left un-acked, reappearing only after ack_wait(3s) as redelivery ⇒ HARD-CLOSE (redelivery-rescued, not drained)"

line
if [ "${KEEP:-0}" = 1 ]; then
  echo "KEEP=1 — stack left up. Teardown: docker compose -f $(pwd)/docker-compose.yml down -v"
else
  echo "== teardown =="; docker compose down -v 2>&1 | tail -2
fi
