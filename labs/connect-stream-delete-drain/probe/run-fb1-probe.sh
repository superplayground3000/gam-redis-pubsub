#!/usr/bin/env bash
# Hypothesis: fetch_batch_size governs the un-acked-on-close window. With
# fetch_batch_size=1 the input holds ≤1 prefetched msg, so DELETE should leave
# at most ~1 un-acked (effectively drain-clean), vs 27/29 abandoned at 256.
set -uo pipefail
cd "$(dirname "$0")"
API=http://localhost:14195
box(){ docker compose exec -T box sh -c "$1"; }
nats(){ docker compose exec -T box nats --server nats://nats:4222 "$@"; }
cf(){ box "nats --server nats://nats:4222 consumer info PROBE probe_cons --json | jq -r '$1'"; }
post(){ curl -sS -o /dev/null -w '%{http_code}' -X POST --data-binary @"$1" -H 'Content-Type: application/x-yaml' "$API/streams/probe"; }
del(){ curl -sS -o /dev/null -w '%{http_code}' -X DELETE "$API/streams/probe"; }
reset(){ nats consumer rm PROBE probe_cons -f >/dev/null 2>&1; nats stream purge PROBE -f >/dev/null 2>&1;
  nats consumer add PROBE probe_cons --pull --filter 'probe.>' --ack explicit --deliver all \
    --replay instant --wait 3s --max-pending 1024 --max-deliver=-1 --defaults >/dev/null 2>&1; }
pub(){ box "for i in \$(seq 1 $1); do nats --server nats://nats:4222 pub probe.k\$i v\$i; done"; }

echo "== up =="; docker compose up -d --wait 2>&1 | tail -1
for cfg in connect/p3-fb1.yaml connect/p3-drain.yaml; do
  fb=$(grep -o 'fetch_batch_size: [0-9]*' "$cfg" | awk '{print $2}')
  printf '\n── fetch_batch_size=%s ──\n' "$fb"
  reset; [ "$(post "$cfg")" = 200 ] || echo "POST failed"
  pub 30 >/dev/null
  # let it run a couple seconds so a steady in-flight forms
  sleep 3
  ip=$(cf '.num_ack_pending'); af=$(cf '.ack_floor.consumer_seq')
  echo "before DELETE: num_ack_pending=$ip ack_floor=$af"
  del >/dev/null; sleep 2
  echo "after  DELETE: num_ack_pending=$(cf '.num_ack_pending') ack_floor=$(cf '.ack_floor.consumer_seq')  <- un-acked abandoned = the redelivery window"
  del >/dev/null 2>&1; sleep 1
done
echo; echo "== teardown =="; docker compose down -v 2>&1 | tail -1
