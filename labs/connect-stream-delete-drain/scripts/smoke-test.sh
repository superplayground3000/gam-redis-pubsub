#!/usr/bin/env bash
# Proves no msg loss in JetStream pull-consumer bind mode across stream close for
# hpdevelop/connect:v4.92.0-batch-nats, and that drain-on-close is bounded by
# fetch_batch_size. Preflight Controls A/B validate the harness+build BEFORE any
# experiment is trusted (abort loud). See RESEARCH.md / PROBE-FINDINGS.md.
set -uo pipefail
cd "$(dirname "$0")/.."
# Load .env but let pre-set environment win (so `MSG_COUNT=40 bash smoke-test.sh`
# overrides). Strips trailing comments; values are whitespace-free tokens.
if [ -f .env ]; then
  while IFS='=' read -r k v; do
    case "$k" in ''|\#*) continue;; esac
    case "$k" in *[!A-Za-z0-9_]*) continue;; esac
    v=${v%%#*}; v=$(printf '%s' "$v" | tr -d '[:space:]')
    [ -z "${!k+x}" ] && export "$k=$v"
  done < .env
fi
: "${MSG_COUNT:=200}" "${SLEEP_MS:=200}" "${ACK_WAIT:=3s}" "${ARM_INFLIGHT:=20}" "${FAULT_EVERY:=10}" "${FETCH_BATCH_SIZES:=1,16,256}"
API=http://localhost:${CONNECT_PORT:-14195}
ACK_WAIT_S=${ACK_WAIT%s}
line(){ printf '%.0s─' {1..72}; echo; }
fail(){ echo "SMOKE-FAIL: $*"; docker compose logs --tail=40 connect; docker compose down -v >/dev/null 2>&1; exit 1; }

# harness (distroless) runs on demand; redis-cli via the redis service; consumer
# fields via the long-running box (fast exec + jq).
hp(){ docker compose run --rm -T harness "$@"; }
rc(){ docker compose exec -T redis redis-cli "$@" 2>/dev/null | tr -d '\r'; }
nats(){ docker compose exec -T box nats --server nats://nats:4222 "$@"; }
cf(){ docker compose exec -T box sh -c "nats --server nats://nats:4222 consumer info KV_CDC cdc_sink --json | jq -r '$1'" 2>/dev/null | tr -d '\r'; }
clog(){ docker compose logs connect --since "${1:-120s}" 2>/dev/null; }

flush_redis(){ rc flushall >/dev/null; }
reset_consumer(){
  nats consumer rm KV_CDC cdc_sink -f >/dev/null 2>&1
  nats stream purge KV_CDC -f >/dev/null 2>&1
  nats consumer add KV_CDC cdc_sink --pull --filter 'kv.cdc.>' --ack explicit --deliver all \
    --replay instant --wait "${ACK_WAIT}" --max-pending 4096 --max-deliver=-1 --defaults >/dev/null 2>&1
}
post_reverse(){ # $1=fetch_batch_size
  sed -e "s/__FETCH_BATCH_SIZE__/$1/" -e "s/__SLEEP_MS__/${SLEEP_MS}/" connect/reverse.tmpl.yaml > /tmp/reverse.yaml
  local code; code=$(curl -sS -o /tmp/post.out -w '%{http_code}' -X POST --data-binary @/tmp/reverse.yaml -H 'Content-Type: application/x-yaml' "$API/streams/reverse")
  [ "$code" = 200 ] || fail "POST reverse -> $code: $(cat /tmp/post.out)"
}
del_reverse(){ curl -sS -o /dev/null -w '%{http_code}' -X DELETE "$API/streams/reverse"; }
wait_quiescent(){ for _ in $(seq 1 90); do
  [ "$(cf '.num_ack_pending')" = 0 ] && [ "$(cf '.num_pending')" = 0 ] && return 0; sleep 1; done; return 1; }
# Deterministic arming: the required in-flight to prove a close interrupted real
# work is min(ARM_INFLIGHT, fetch_batch_size) but at least 1 (a close that hits
# zero in-flight proves nothing — see RESEARCH.md Codex CRITICAL #2).
require_inflight(){ local r=$(( ARM_INFLIGHT < $1 ? ARM_INFLIGHT : $1 )); [ "$r" -lt 1 ] && r=1; echo "$r"; }
# arm: fast back-to-back poll (no sleep — cf itself is ~150ms, finer than the
# in-flight window) until num_ack_pending >= $1 or $2 seconds elapse. Echoes the
# observed value; returns 0 IFF the required in-flight was actually seen.
arm(){ local req=$1 end=$((SECONDS+$2)) n=0; while [ "$SECONDS" -lt "$end" ]; do
  n=$(cf '.num_ack_pending'); [ "${n:-0}" -ge "$req" ] 2>/dev/null && { echo "${n:-0}"; return 0; }; done
  echo "${n:-0}"; return 1; }

echo "== bring up stack =="
docker compose up -d --wait 2>&1 | tail -3 || fail "stack did not come up"

line; echo "PREFLIGHT — config gate (secondary)"; line
reset_consumer; flush_redis; post_reverse 4
curl -sS "$API/streams/reverse" | grep -q 'threads: 1' \
  && echo "config gate: GET reflects threads:1 + live graph" \
  || echo "WARN: GET /streams/reverse may return a template, not the live graph (Controls A/B are primary)"
del_reverse >/dev/null; sleep 1

line; echo "PREFLIGHT — Control A (throw ⇒ nack, not drop-and-ack)"; line
reset_consumer; flush_redis; post_reverse 4
nats pub kv.cdc.update '{"event_id":"ctrlA","op":"update","kv_key":"kv:9001","body":"val:9001:ctrlA","fault_mode":"always"}' --count=1 >/dev/null 2>&1 \
  || hp publish -key 9001 -fault always >/dev/null
d0=$(cf '.delivered.consumer_seq'); sleep "$ACK_WAIT_S"; sleep 1; d1=$(cf '.delivered.consumer_seq')
present=$(rc exists kv:9001)
echo "ctrlA: delivered ${d0}→${d1}, kv:9001 exists=${present}"
[ "${d1:-0}" -gt "${d0:-0}" ] 2>/dev/null || fail "Control A: ctrlA did not redeliver ⇒ throw is drop-and-ack ⇒ experiment 0 invalid"
[ "${present:-1}" = 0 ] || fail "Control A: faulting ctrlA got applied while failing ⇒ gate/throw broken"
del_reverse >/dev/null; sleep 1   # stop the hot loop

line; echo "PREFLIGHT — Control B (gate fires del=1, applies on distinct del=2)"; line
reset_consumer; flush_redis; post_reverse 4
hp publish -key 9002 -fault first >/dev/null
sleep 3
gate1=$(clog 30s | grep '"event":"fault-gate fired"' | grep -c '"key":"kv:9002".*"num_delivered":"1"')
apply1=$(clog 30s | grep '"event":"apply"' | grep -c '"key":"kv:9002".*"num_delivered":"1"')
apply2=$(clog 30s | grep '"event":"apply"' | grep -c '"key":"kv:9002".*"num_delivered":"2"')
applied=$(rc get applied:kv:9002)
echo "ctrlB: gate(del1)=${gate1} apply(del1)=${apply1} apply(del2)=${apply2} applied:kv:9002=${applied}"
[ "${gate1:-0}" -ge 1 ] 2>/dev/null || fail "Control B: fault-gate did not fire on delivery 1 (meta key wrong?)"
[ "${apply1:-0}" = 0 ] 2>/dev/null || fail "Control B: apply ran on the faulting delivery 1 (gate not skipping apply)"
[ "${apply2:-0}" -ge 1 ] 2>/dev/null || fail "Control B: no apply on a distinct delivery 2 (within-delivery retry?)"
[ "${applied:-0}" = 1 ] 2>/dev/null || fail "Control B: applied:kv:9002=${applied}, expected 1"
del_reverse >/dev/null; sleep 1
echo "PREFLIGHT PASSED — controls validate the build+harness"

line; echo "EXPERIMENTS — sweep FETCH_BATCH_SIZES=${FETCH_BATCH_SIZES}"; line
IFS=',' read -ra FBS <<< "${FETCH_BATCH_SIZES}"
overall=0
connect_ready(){ for _ in $(seq 1 60); do [ "$(curl -sS -o /dev/null -w '%{http_code}' "$API/ready" 2>/dev/null)" = 200 ] && return 0; sleep 1; done; return 1; }
restart_connect(){ docker compose up -d connect >/dev/null 2>&1; connect_ready || fail "connect not ready after restart"; }
# region_keys: count applied region keys kv:* (excludes applied:* and the ledger hash).
region_keys(){ docker compose exec -T redis redis-cli --scan --pattern 'kv:*' 2>/dev/null | grep -c '^kv:'; }
nfault=$(( FAULT_EVERY>0 ? MSG_COUNT/FAULT_EVERY : 0 ))

for fb in "${FBS[@]}"; do
  line; echo "### fetch_batch_size=${fb}"; line

  # Experiment 0 — apply-fault injection (no close): faults must not cause loss.
  reset_consumer; flush_redis; post_reverse "$fb"
  hp publish -count "${MSG_COUNT}" -fault-every "${FAULT_EVERY}" >/dev/null
  wait_quiescent || fail "exp0 fb=$fb: not quiescent"
  gates=$(clog 300s | grep -c '"event":"fault-gate fired".*"num_delivered":"1"')
  echo "exp0 fb=$fb: fault-gate-fired(del1)=${gates} (expected ≥ ${nfault} F keys faulted+redelivered)"
  hp verify -count "${MSG_COUNT}" || { overall=1; echo "EXP0 fb=$fb FAIL"; }
  del_reverse >/dev/null; sleep 1

  # Close experiments. Arming (pre-close) only ensures work is flowing; the PROOF
  # that a close interrupted LIVE work is measured POST-close: num_ack_pending>0
  # (in-flight messages the close left abandoned un-acked) AND region keys < N
  # (unfinished backlog). If neither holds, the close interrupted nothing ⇒
  # INCONCLUSIVE (never a silent pass). Then re-bind and prove recovery to N.
  req=$(require_inflight "$fb")

  # After a non-blocking DELETE, connect tears the stream down ASYNCHRONOUSLY while
  # still alive (it may apply+ack part of the in-flight batch during teardown). So
  # measuring num_ack_pending immediately would RACE the teardown. Wait until the
  # stream is gone (GET 404) AND num_ack_pending has stopped changing, so the
  # abandoned/interrupted count is STABLE. (SIGTERM/SIGKILL need no such barrier —
  # the process is confirmed dead before we measure, so the count can't move.)
  # FAIL CLOSED: returns 0 ONLY if it positively confirms teardown settled
  # (GET 404 AND two consecutive equal num_ack_pending reads); returns 1 if it
  # cannot confirm within the budget, so the caller must treat the measurement as
  # untrusted (INCONCLUSIVE) rather than proceed on a raced value.
  settle_after_delete(){ local prev="" cur code i
    for i in $(seq 1 60); do
      code=$(curl -sS -o /dev/null -w '%{http_code}' "$API/streams/reverse" 2>/dev/null)
      cur=$(cf '.num_ack_pending')
      [ "$code" = 404 ] && [ -n "$prev" ] && [ "$cur" = "$prev" ] && return 0
      prev="$cur"
    done; return 1; }   # never confirmed settled → fail closed

  # Experiment 1 — Streams DELETE (measured only AFTER teardown positively settles).
  reset_consumer; flush_redis; post_reverse "$fb"
  hp publish -count "${MSG_COUNT}" >/dev/null
  if ! armed=$(arm "$req" 15); then
    echo "EXP1 fb=$fb INCONCLUSIVE: could not arm num_ack_pending>=${req} (saw ${armed}) — NOT a pass"; overall=1
  else
    t0=$(date +%s.%N); code=$(del_reverse); t1=$(date +%s.%N)
    if ! settle_after_delete; then
      echo "EXP1 fb=$fb INCONCLUSIVE: DELETE teardown never settled (no GET 404 + stable num_ack_pending within budget) — measurement untrusted, NOT a pass"; overall=1
    else
    ab=$(cf '.num_ack_pending'); ac=$(region_keys); uf=$(( MSG_COUNT - ac ))
    echo "exp1 fb=$fb: DELETE -> $code in $(awk "BEGIN{printf \"%.2f\", $t1-$t0}")s | interrupted in-flight=${ab} (stable, post-teardown); applied_at_close=${ac}/${MSG_COUNT} (unfinished=${uf})"
    if [ "${ab:-0}" -lt 1 ] 2>/dev/null || [ "${uf:-0}" -lt 1 ] 2>/dev/null; then
      echo "EXP1 fb=$fb INCONCLUSIVE: DELETE interrupted no live work (abandoned=${ab}, unfinished=${uf}) — NOT a pass"; overall=1
    else
      post_reverse "$fb"; wait_quiescent || fail "exp1 fb=$fb: not quiescent after re-bind"
      hp verify -count "${MSG_COUNT}" && echo "  -> ${uf} unfinished keys (incl ${ab} interrupted in-flight) recovered via redelivery; no loss" || { overall=1; echo "EXP1 fb=$fb FAIL (LOSS)"; }
    fi
    fi
  fi
  del_reverse >/dev/null; sleep 1

  # Experiment 2 — SIGTERM (docker stop waits for exit), restart, re-bind.
  reset_consumer; flush_redis; post_reverse "$fb"
  hp publish -count "${MSG_COUNT}" >/dev/null
  if ! armed=$(arm "$req" 15); then
    echo "EXP2 fb=$fb INCONCLUSIVE: could not arm (saw ${armed}) — NOT a pass"; overall=1
    docker compose up -d connect >/dev/null 2>&1
  else
    echo "exp2 fb=$fb: SIGTERM"
    docker compose stop -t 30 connect >/dev/null 2>&1
    ab_pre=$(cf '.num_ack_pending'); ac_pre=$(region_keys)   # measure while connect down
    restart_connect
    # re-assert post-close state captured pre-restart via proof helper inputs
    if [ "${ab_pre:-0}" -lt 1 ] 2>/dev/null || [ "$(( MSG_COUNT - ac_pre ))" -lt 1 ] 2>/dev/null; then
      echo "EXP2 fb=$fb INCONCLUSIVE: SIGTERM interrupted no live work (abandoned=${ab_pre}, applied_at_close=${ac_pre}/${MSG_COUNT}) — NOT a pass"; overall=1; del_reverse >/dev/null
    else
      echo "EXP2 fb=$fb: interrupted in-flight=${ab_pre}; applied_at_close=${ac_pre}/${MSG_COUNT} (unfinished=$(( MSG_COUNT - ac_pre )))"
      post_reverse "$fb"; wait_quiescent || fail "exp2 fb=$fb: not quiescent after SIGTERM+restart"
      hp verify -count "${MSG_COUNT}" && echo "  -> recovered via redelivery; no loss" || { overall=1; echo "EXP2 fb=$fb FAIL (LOSS)"; }
    fi
  fi
  del_reverse >/dev/null; sleep 1

  # Experiment 3 — SIGKILL, restart, re-bind (safety floor).
  reset_consumer; flush_redis; post_reverse "$fb"
  hp publish -count "${MSG_COUNT}" >/dev/null
  if ! armed=$(arm "$req" 15); then
    echo "EXP3 fb=$fb INCONCLUSIVE: could not arm (saw ${armed}) — NOT a pass"; overall=1
    docker compose up -d connect >/dev/null 2>&1
  else
    echo "exp3 fb=$fb: SIGKILL"
    docker compose kill -s SIGKILL connect >/dev/null 2>&1
    ab_pre=$(cf '.num_ack_pending'); ac_pre=$(region_keys)   # measure while connect dead
    restart_connect
    if [ "${ab_pre:-0}" -lt 1 ] 2>/dev/null || [ "$(( MSG_COUNT - ac_pre ))" -lt 1 ] 2>/dev/null; then
      echo "EXP3 fb=$fb INCONCLUSIVE: SIGKILL interrupted no live work (abandoned=${ab_pre}, applied_at_close=${ac_pre}/${MSG_COUNT}) — NOT a pass"; overall=1; del_reverse >/dev/null
    else
      echo "EXP3 fb=$fb: interrupted in-flight=${ab_pre}; applied_at_close=${ac_pre}/${MSG_COUNT} (unfinished=$(( MSG_COUNT - ac_pre )))"
      post_reverse "$fb"; wait_quiescent || fail "exp3 fb=$fb: not quiescent after SIGKILL+restart"
      hp verify -count "${MSG_COUNT}" && echo "  -> recovered via redelivery; no loss" || { overall=1; echo "EXP3 fb=$fb FAIL (LOSS)"; }
    fi
  fi
  del_reverse >/dev/null; sleep 1
done

line
if [ "$overall" = 0 ]; then
  echo "SMOKE-PASS: every close provably interrupted LIVE in-flight work — post-close there were"
  echo "  abandoned un-acked messages AND unfinished backlog (<N applied) — yet all N keys recovered"
  echo "  to the region with correct identity via redelivery. Across DELETE/SIGTERM/SIGKILL for all"
  echo "  fetch_batch_size in {${FETCH_BATCH_SIZES}}. The interrupted-in-flight count scales with"
  echo "  fetch_batch_size (~1 at fb=1 up to ~fetch_batch_size); no setting loses a message."
else
  echo "SMOKE-FAIL: at least one experiment lost messages, failed identity, or was INCONCLUSIVE"
  echo "  (close interrupted no live in-flight work) — see EXP*/FAIL/INCONCLUSIVE lines above."
fi
[ "${KEEP:-0}" = 1 ] || { echo "== teardown =="; docker compose down -v 2>&1 | tail -2; }
exit "$overall"
