#!/usr/bin/env bash
# verify-e2e-matrix.sh — permanent L3 umbrella e2e MATRIX test.
# Design: docs/superpowers/plans/2026-07-15-e2e-matrix-design.md (§1-§8, critic-approved).
#
# One kind cluster, two installs, four sequential phases (per-phase PASS/FAIL):
#   P1  render matrix    — helm template of the coexistence overlay (no cluster):
#                          asserts the §1.1 objects, the keyPattern plural/singular
#                          trap guard, and the two known fail-loud conflicts.
#   P2  coexist traffic  — Install-A (sharded lb:company + 2-seg tg:caveat + catchAll):
#                          M-A routing, M-D isolation, M-E strict per-key order under
#                          load, terminal-state zero-loss reconciliation, M-F shard
#                          durables under load, M-G sx isolation lane, M-H dedup.
#   P3  graceful change  — G-1 (source leader) then G-2 (sink shard-a leader): graceful
#                          `kubectl delete pod`. GATES ONLY on loss==0 + same-key
#                          monotone; RECORDS (never gates) the known graceful-SIGTERM
#                          DELETE-handoff gap evidence (design §6a).
#   P4  ack-after-apply  — Install-B (default single-sink). F-1 source ack fault (NATS
#                          iptables partition, central PEL retention) then F-2 sink ack
#                          fault (region scale-to-0, JetStream num_ack_pending). F-1
#                          fully drains + reconciles f1:* BEFORE F-2 wipes the emptyDir
#                          region and reconciles ONLY f2:*.
#
# Traffic = direct `redis-cli XADD` per lane (deterministic event_ids + kv_key control,
# the same choice verify-sharding.sh / verify-cdc*.sh make). Zero-loss oracle = terminal
# region-state reconciliation keyed by the emitted op log (survives deletes + renames),
# not counts. Both faults lift in a trap so an abort never leaves the cluster wedged.
#
# STANDALONE ONLY — do NOT co-run in the same run-all-tests.sh invocation as
# RUN_PREFIX/RUN_SHARDING (their live releases + Install-A oversubscribe node CPU and
# flake P2's quiescence polls). See design §0/§7.
#
# Results: reports/e2e-matrix/<runid>.json (§3 schema) + a compact RESULT_JSON: line.
# Phase selection: VERIFY_PHASES="p1" (default "p1 p2 p3 p4") runs P1 only, no cluster.
# Usage: RRCS_NS=cdc-e2e RRCS_RELEASE=cdce2e scripts/verify-e2e-matrix.sh
#
# NB: `set -uo pipefail` WITHOUT -e — every phase must run to a recorded PASS/FAIL and
# the results JSON must always be written (even on a global-deadline abort), so errors
# are handled explicitly, not by killing the shell.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}/.." || exit 1

# ── knobs ──────────────────────────────────────────────────────────────────────
NS="${RRCS_NS:-cdc-e2e}"
RELEASE="${RRCS_RELEASE:-cdce2e}"
VALUES_FILE="${RRCS_VALUES:-chart/values-dev.yaml}"
COEXIST_VALUES="${RRCS_COEXIST_VALUES:-chart/ci/e2e-coexist-values.yaml}"
PREFIX="${RRCS_PREFIX:-lab-}"
KIND_NAME="${KIND_NAME:-cdc}"
VERIFY_PHASES="${VERIFY_PHASES:-p1 p2 p3 p4}"

NROUTE="${NROUTE:-40}"                 # M-A creates across employees 1..NROUTE (10/shard at N=4)
NSEQ="${NSEQ:-200}"                    # M-E interleaved active+standby updates per key
NCAV="${NCAV:-30}"                     # M-B tg:caveat creates
NOTH="${NOTH:-20}"                     # M-C misc:thing (others) creates
NSEQ_G="${NSEQ_G:-150}"               # P3 hot-key monotone updates per graceful test
NKEYS_G="${NKEYS_G:-15}"              # P3 distinct-key creates per graceful test (loss check)
F1_BURST="${F1_BURST:-200}"           # F-1 burst into the NATS partition (f1:*)
F2_BURST="${F2_BURST:-200}"           # F-2 burst into the region outage (f2:*)
PARTITION_S="${PARTITION_S:-45}"       # F-1 hold
REGION_OUTAGE_S="${REGION_OUTAGE_S:-45}"  # F-2 hold
SETTLE_TIMEOUT_S="${SETTLE_TIMEOUT_S:-90}"   # per-settle cap (half of verify-sharding's 180)
SETTLE_STABLE_S="${SETTLE_STABLE_S:-10}"     # F-2 barrier: global cdc_apply must hold steady this long
                                             # after F-1 before snapshotting F-2 baseline (§5 DEFECT-B)
E2E_DEADLINE_S="${E2E_DEADLINE_S:-3000}"     # global run deadline (50 min); on expiry -> partial FAIL
ROLL_TIMEOUT="${ROLL_TIMEOUT:-180s}"
EXTRA_SET=()
set -f; for kv in ${RRCS_SET:-}; do EXTRA_SET+=(--set "$kv"); done; set +f

CENTRAL="deploy/${PREFIX}redis-central"
REGION="deploy/${PREFIX}redis-region"
REGION_DEPLOY="${PREFIX}redis-region"
STREAM="app.events"
GROUP="cdc_propagator"
DUR_BASE="cdc_sink_lb_company"

START_EPOCH="$(date +%s)"
RUNID="$START_EPOCH"
KEYRUN="$(date +%s%3N)"
DEADLINE=$(( START_EPOCH + E2E_DEADLINE_S ))
REPORT_DIR="reports/e2e-matrix"
RESULT_FILE="${REPORT_DIR}/${RUNID}.json"
mkdir -p "$REPORT_DIR"

# ── logging / redis / metric helpers (lifted from verify-sharding.sh) ───────────
log()  { echo "[e2e-matrix] $*"; }
warn() { echo "[e2e-matrix] WARN: $*" >&2; }
rc()   { kubectl -n "$NS" exec -i "$CENTRAL" -- redis-cli "$@"; }
rr()   { kubectl -n "$NS" exec -i "$REGION"  -- redis-cli "$@"; }
rr_pipe() { kubectl -n "$NS" exec -i "$REGION" -- redis-cli; }   # feed commands on stdin
holder() { kubectl -n "$NS" get lease "$1" -o jsonpath='{.spec.holderIdentity}' 2>/dev/null; }
renewtime() { kubectl -n "$NS" get lease "$1" -o jsonpath='{.spec.renewTime}' 2>/dev/null; }
now_ms() { date +%s%3N; }
cnt() { rr --scan --pattern "$1" 2>/dev/null | grep -c . || true; }
# pel_count: central consumer-group PEL depth (entries read but not XACKed)
pel_count() { rc XPENDING "$STREAM" "$GROUP" 2>/dev/null | head -1 | tr -dc '0-9'; }

metric_sum() { # $1=app-label $2=metric-base $3=optional label-filter substring
  local dep="$1" metric="$2" lf="${3:-}" pod tot=0 v
  for pod in $(kubectl -n "$NS" get pods -l "app=$dep" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    v="$(kubectl -n "$NS" exec "$pod" -c connect -- wget -qO- http://localhost:4195/metrics 2>/dev/null \
         | awk -v m="$metric" -v lf="$lf" '$1 ~ "^"m"(_total)?[{ ]" && (lf == "" || index($1, lf) > 0) {s+=$2} END{printf "%.0f", s+0}')" || v=0
    tot=$(( tot + ${v:-0} ))
  done
  echo "$tot"
}

# ── persistent nats-box helper pod for durable/consumer queries ─────────────────
NATSQ="natsq-e2e"
natsq_start() {
  kubectl -n "$NS" delete pod "$NATSQ" --grace-period=0 --force >/dev/null 2>&1 || true
  kubectl -n "$NS" run "$NATSQ" --image=natsio/nats-box:0.14.5 --restart=Never --quiet \
    --overrides='{"spec":{"containers":[{"name":"n","image":"natsio/nats-box:0.14.5","command":["sleep","3600"],"volumeMounts":[{"name":"c","mountPath":"/c"}]}],"volumes":[{"name":"c","secret":{"secretName":"'"${PREFIX}"'admin-creds","defaultMode":292}}]}}' >/dev/null 2>&1
  if kubectl -n "$NS" wait --for=condition=Ready "pod/$NATSQ" --timeout=120s >/dev/null 2>&1; then return 0; fi
  warn "natsq pod did not become Ready in 120s — consumer queries will retry lazily"
  return 1
}
natsq_ready() { [ "$(kubectl -n "$NS" get pod "$NATSQ" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)" = "true" ]; }
# ensure a WORKING natsq query pod exists — (re)start it if it is gone/evicted/not-ready.
# This is the fix for the run-2 M-F defect: under Install-A's heavier load the query pod
# could be slow/evicted, and the old silent `|| true` let every consumer_json return EMPTY
# (which also made quiesce vacuously "settle" on num_pending//0=0). Now the query path
# self-heals instead of failing closed on infra flakiness.
natsq_ensure() { natsq_ready && return 0; log "natsq query pod not ready — (re)starting it"; natsq_start; natsq_ready; }
natsq() { kubectl -n "$NS" exec "$NATSQ" -- nats --server "nats://${PREFIX}nats:4222" --creds /c/user.creds "$@"; }
# consumer_json: lazy-ensures the query pod and retries ONCE on an empty reply, so a
# transiently-down natsq never silently yields "" (which callers must treat as unknown,
# never as a valid/zeroed consumer). Empty return == genuinely unavailable after a retry.
consumer_json() {
  local out; out="$(natsq consumer info KV_CDC "$1" --json 2>/dev/null)"
  [ -n "$out" ] && { printf '%s' "$out"; return 0; }
  natsq_ensure >/dev/null 2>&1 || true
  natsq consumer info KV_CDC "$1" --json 2>/dev/null
}

# ── fault-cleanup trap (iptables + region scale) — MUST run even on abort ───────
NATS_IP=""
KIND_NODE=""
IPTABLES_RAISED=0
REGION_SCALED_DOWN=0
WROTE_RESULTS=0
cleanup() {
  # ALWAYS attempt both fault undos unconditionally — both are idempotent (iptables
  # -D under `|| true`, scale-to-1 is a no-op when already 1), matching
  # verify-sharding-partition.sh's unblock(). The flags below are for LOGGING ONLY,
  # never gate the undo: a flag left at 1 because the inline undo silently failed
  # must still be retried here, and a node-level iptables DROP to NATS (cluster-wide)
  # or a region redis stuck at 0 replicas is far worse than a redundant undo.
  if [ -n "$KIND_NODE" ] && [ -n "$NATS_IP" ]; then
    docker exec "$KIND_NODE" iptables -D FORWARD -d "$NATS_IP" -j DROP >/dev/null 2>&1 || true
    (( IPTABLES_RAISED )) && log "cleanup: removed lingering NATS iptables DROP"
  fi
  kubectl -n "$NS" scale "deploy/${REGION_DEPLOY}" --replicas=1 >/dev/null 2>&1 || true
  (( REGION_SCALED_DOWN )) && log "cleanup: restored region redis to replicas=1"
  kubectl -n "$NS" delete pod "$NATSQ" --grace-period=0 --force >/dev/null 2>&1 || true
  # Last-resort results write so an aborted/killed run still leaves a JSON artifact.
  if (( ! WROTE_RESULTS )); then
    OVERALL="FAIL"; [ -z "${REASON:-}" ] && REASON="aborted"
    write_results
  fi
}
trap cleanup EXIT

# ── deadline guard ──────────────────────────────────────────────────────────────
check_deadline() { # abort the whole run (writing partial JSON) if the global cap is hit
  if (( $(date +%s) >= DEADLINE )); then
    warn "global deadline ${E2E_DEADLINE_S}s exceeded — writing partial results and aborting"
    OVERALL="FAIL"; REASON="deadline"
    write_results
    exit 1
  fi
}
want_phase() { case " $VERIFY_PHASES " in *" $1 "*) return 0;; *) return 1;; esac; }

# ── gating bookkeeping ──────────────────────────────────────────────────────────
OVERALL="PASS"
REASON=""
gate() { # $1=name $2=ok(0/1 shell truthy: 0=pass) $3=detail — records + fails overall
  local name="$1" ok="$2" detail="${3:-}"
  if [ "$ok" = "0" ]; then
    log "GATE PASS: $name"
  else
    log "GATE FAIL: $name — $detail"
    OVERALL="FAIL"
  fi
}

# ── evidence variables (initialised so `set -u` is happy even for skipped phases) ─
# Phase status enum: SKIP (never entered) | ABORT (entered, crashed mid-phase) |
# FAIL (ran, a gate failed) | PASS. A phase that runs is NEVER "SKIP" — run_phase()
# stamps ABORT on entry (cleared to PASS/FAIL only on normal completion), so an
# abort leaves ABORT, never a stale SKIP with populated data.
P1_STATUS="SKIP"; P1_DUR=0; P1_ERR=""; P1_ABIN=""; P1_C_RENDER=false; P1_C_TRAP=false; P1_C_FAILLOUD=false
P2_STATUS="SKIP"; P2_DUR=0; P2_ERR=""; P2_ABIN=""
P2_A_APPLY=0; P2_A_EXP=0; P2_A_SURPLUS=0; P2_B_APPLY=0; P2_B_EXP=0; P2_B_SURPLUS=0
P2_CAV_APPLY=0; P2_CAV_EXP=0; P2_CAV_SURPLUS=0; P2_OTH_APPLY=0; P2_OTH_EXP=0; P2_OTH_SURPLUS=0
P2_LEAK=0; P2_FOREIGN=0; P2_KEYS_OUTSIDE=0
P2_SAMPLES=0; P2_DISTINCT=0; P2_MONOTONE=true; P2_FINALS="0/0"
P2_EXPK=0; P2_PRESK=0; P2_MISSING=0; P2_CORRUPT=0; P2_DELV=0; P2_RENV=0
P2_SX_APPLY=0; P2_SX_UNP=0; P2_SX_XSR=0; P2_NAP_MAX=0; P2_MAP_ALL=1; P2_DEDUP=true
P3_STATUS="SKIP"; P3_DUR=0; P3_ERR=""; P3_ABIN=""
P3S_POD=""; P3S_LOSS=0; P3S_MONO=true; P3S_HLAT=0; P3S_MECH="lease_expiry"; P3S_DELRAN=false; P3S_DAW=0
P3K_POD=""; P3K_LOSS=0; P3K_MONO=true; P3K_HLAT=0; P3K_MECH="lease_expiry"; P3K_DELRAN=false; P3K_DAW=0
P3_GAP="ABSENT"; P3S_GAPEV=""; P3K_GAPEV=""   # per-leg OnStoppedLeading grep evidence
P4_STATUS="SKIP"; P4_DUR=0; P4_ERR=""; P4_ABIN=""; P4_REASON=""
P4F1_PEL=0; P4F1_APPLYFAULT=0; P4F1_DRAINED=0; P4F1_LOSS=0
P4F2_STATUS="not_run"; P4F2_NAP=0; P4F2_APPLYFAULT=0; P4F2_REDELIV=0; P4F2_APPLYAFTER=0; P4F2_LOSS=0
P4F2_SCANFAULT=0; P4F2_NDCLIMB=false   # F-2 during-fault scoped gate evidence (§5 DEFECT-B)
# background region-poller PIDs, reaped between phases so a phase abort can't leak one
BG_POLLERS=()
INSTALL_A_OK=0; INSTALL_B_OK=0   # set by maybe_install_*, read via nameref (_flag) in run_phase
# aborted_in tracking: run_phase sets CUR_PHASE_N; mark() records the current sub-step into
# P<n>_ABIN so an aborted phase reports WHERE it died (cleared to "" on normal completion).
CUR_PHASE_N=""
mark() { [ -n "$CUR_PHASE_N" ] && printf -v "P${CUR_PHASE_N}_ABIN" '%s' "$1"; return 0; }

# ── results writer (§3 schema); idempotent ──────────────────────────────────────
jbool() { [ "$1" = "true" ] && echo true || echo false; }
write_results() {
  (( WROTE_RESULTS )) && return 0
  WROTE_RESULTS=1
  # Re-create the report dir here (idempotent) — it may have been deleted concurrently
  # (e.g. a parallel cleanup) after the top-of-script mkdir, which would ENOENT both the
  # jq write and the fallback echo and lose the results entirely.
  mkdir -p "$REPORT_DIR" 2>/dev/null || true
  local ended; ended="$(date +%s)"
  jq -n \
    --arg run_id "$RUNID" --argjson started "$START_EPOCH" --argjson ended "$ended" \
    --arg kind "$KIND_NAME" --arg ns "$NS" \
    --arg overall "$OVERALL" --arg reason "$REASON" --argjson deadline "$E2E_DEADLINE_S" \
    --arg p1s "$P1_STATUS" --argjson p1d "$P1_DUR" --arg p1err "$P1_ERR" --arg p1abin "$P1_ABIN" \
    --argjson p1cr "$(jbool "$P1_C_RENDER")" --argjson p1ct "$(jbool "$P1_C_TRAP")" --argjson p1cf "$(jbool "$P1_C_FAILLOUD")" \
    --arg p2s "$P2_STATUS" --argjson p2d "$P2_DUR" --arg p2err "$P2_ERR" --arg p2abin "$P2_ABIN" \
    --argjson aa "$P2_A_APPLY" --argjson ae "$P2_A_EXP" --argjson asu "$P2_A_SURPLUS" \
    --argjson ba "$P2_B_APPLY" --argjson be "$P2_B_EXP" --argjson bsu "$P2_B_SURPLUS" \
    --argjson ca "$P2_CAV_APPLY" --argjson ce "$P2_CAV_EXP" --argjson csu "$P2_CAV_SURPLUS" \
    --argjson oa "$P2_OTH_APPLY" --argjson oe "$P2_OTH_EXP" --argjson osu "$P2_OTH_SURPLUS" \
    --argjson leak "$P2_LEAK" --argjson foreign "$P2_FOREIGN" --argjson koutside "$P2_KEYS_OUTSIDE" \
    --argjson sam "$P2_SAMPLES" --argjson dis "$P2_DISTINCT" \
    --argjson mono "$(jbool "$P2_MONOTONE")" --arg finals "$P2_FINALS" \
    --argjson expk "$P2_EXPK" --argjson presk "$P2_PRESK" --argjson miss "$P2_MISSING" --argjson corr "$P2_CORRUPT" \
    --argjson delv "$P2_DELV" --argjson renv "$P2_RENV" \
    --argjson sxa "$P2_SX_APPLY" --argjson sxu "$P2_SX_UNP" --argjson sxr "$P2_SX_XSR" \
    --argjson napm "$P2_NAP_MAX" --argjson mapa "$P2_MAP_ALL" --argjson dedup "$(jbool "$P2_DEDUP")" \
    --arg p3s "$P3_STATUS" --argjson p3d "$P3_DUR" --arg p3err "$P3_ERR" --arg p3abin "$P3_ABIN" \
    --arg p3spod "$P3S_POD" --argjson p3sloss "$P3S_LOSS" --argjson p3smono "$(jbool "$P3S_MONO")" \
    --argjson p3shlat "$P3S_HLAT" --arg p3smech "$P3S_MECH" --argjson p3sdel "$(jbool "$P3S_DELRAN")" --argjson p3sdaw "$P3S_DAW" \
    --arg p3kpod "$P3K_POD" --argjson p3kloss "$P3K_LOSS" --argjson p3kmono "$(jbool "$P3K_MONO")" \
    --argjson p3khlat "$P3K_HLAT" --arg p3kmech "$P3K_MECH" --argjson p3kdel "$(jbool "$P3K_DELRAN")" --argjson p3kdaw "$P3K_DAW" \
    --arg p3gap "$P3_GAP" --arg p3sgapev "$P3S_GAPEV" --arg p3kgapev "$P3K_GAPEV" \
    --arg p4s "$P4_STATUS" --argjson p4d "$P4_DUR" --arg p4err "$P4_ERR" --arg p4abin "$P4_ABIN" --arg p4reason "$P4_REASON" --arg f2status "$P4F2_STATUS" \
    --argjson f1pel "$P4F1_PEL" --argjson f1af "$P4F1_APPLYFAULT" --argjson f1dr "$P4F1_DRAINED" --argjson f1loss "$P4F1_LOSS" \
    --argjson f2nap "$P4F2_NAP" --argjson f2af "$P4F2_APPLYFAULT" --argjson f2rd "$P4F2_REDELIV" --argjson f2aa "$P4F2_APPLYAFTER" --argjson f2loss "$P4F2_LOSS" \
    --argjson f2scan "$P4F2_SCANFAULT" --argjson f2ndclimb "$(jbool "$P4F2_NDCLIMB")" \
    '{
      run_id:$run_id, started:$started, ended:$ended,
      kind_cluster:$kind, ns_coexist:$ns, ns_fault:$ns,
      overall:$overall, reason:$reason, deadline_s:$deadline,
      phases: {
        p1_render: { status:$p1s, duration_s:$p1d, error:$p1err, aborted_in:$p1abin,
          checks: [ {name:"coexist_overlay_renders", ok:$p1cr},
                    {name:"keypattern_trap_guard", ok:$p1ct},
                    {name:"failloud_conflicts", ok:$p1cf} ] },
        p2_coexist: { status:$p2s, duration_s:$p2d, error:$p2err, aborted_in:$p2abin,
          lanes: { "shard-a":{applied:$aa,expected:$ae,dup_surplus:$asu}, "shard-b":{applied:$ba,expected:$be,dup_surplus:$bsu},
                   caveat:{applied:$ca,expected:$ce,dup_surplus:$csu}, others:{applied:$oa,expected:$oe,dup_surplus:$osu} },
          isolation: { cross_lane_leak:$leak, foreign_shard_applies:$foreign, keys_outside_lane_ranges:$koutside },
          ordering:  { samples:$sam, distinct:$dis, monotone:$mono, finals:$finals },
          zero_loss: { expected_keys:$expk, present_keys:$presk, missing:$miss, corrupt:$corr,
                       deletes_verified:$delv, renames_verified:$renv },
          sx_lane:   { applied:$sxa, unparseable:$sxu, cross_shard_rename:$sxr },
          durables:  { num_ack_pending_max:$napm, max_ack_pending_all:$mapa },
          dedup:     { stable:$dedup } },
        p3_graceful: { status:$p3s, duration_s:$p3d, error:$p3err, aborted_in:$p3abin,
          source_leg: { terminated_pod:$p3spod, loss_keys:$p3sloss, ordering_monotone:$p3smono,
                        handoff_latency_s:$p3shlat, handoff_mechanism:$p3smech,
                        elector_delete_ran:$p3sdel, double_active_window_s:$p3sdaw },
          sink_leg:   { terminated_pod:$p3kpod, loss_keys:$p3kloss, ordering_monotone:$p3kmono,
                        handoff_latency_s:$p3khlat, handoff_mechanism:$p3kmech,
                        elector_delete_ran:$p3kdel, double_active_window_s:$p3kdaw },
          known_gap:  { graceful_delete_handoff:$p3gap,
                        evidence:{ source_leader:{ elector_logs_grep_OnStoppedLeading:$p3sgapev },
                                   sink_leader:{ elector_logs_grep_OnStoppedLeading:$p3kgapev },
                          note:"per-leg OnStoppedLeading grep from each victim elector log-follow during termination; handoff_mechanism/elector_delete_ran derive from it — the elector_delete_total metric delta is unsound across pod replacement and is NOT used" } } },
        p4_ack_after_apply: { status:$p4s, duration_s:$p4d, error:$p4err, aborted_in:$p4abin, reason:$p4reason,
          source_leg: { fault:"nats_iptables_drop", key_range:"f1:*",
                        pel_retained_during_fault:$f1pel, applied_during_fault:$f1af,
                        pel_drained_after:$f1dr, loss_keys:$f1loss, reconciled_scope:"f1:* only" },
          sink_leg:   { status:$f2status, fault:"region_redis_scale_0", key_range:"f2:*",
                        region_scan_f2_during_fault:$f2scan, num_ack_pending_during_fault:$f2nap,
                        num_delivered_climbing:$f2ndclimb, applied_during_fault:$f2af,
                        applied_during_fault_note:"report-only — global cdc_apply has no key label, cannot be scoped (§5 DEFECT-B)",
                        redelivered:$f2rd, applied_after:$f2aa, loss_keys:$f2loss,
                        reconciled_scope:"f2:* ONLY — whole-region check forbidden (emptyDir wipe drops f1:*)" } }
      },
      known_gap_expectations: {
        graceful_sigterm_delete:"EXPECTED ABSENT — report-only, does not fail the run",
        keypattern_trap:"documented; overlay sets plural keyPattern explicitly" }
    }' > "$RESULT_FILE" 2>/dev/null \
    || { warn "jq results assembly failed — writing minimal fallback"
         mkdir -p "$REPORT_DIR" 2>/dev/null || true
         printf '{"overall":"%s","reason":"%s","run_id":"%s"}\n' "$OVERALL" "$REASON" "$RUNID" > "$RESULT_FILE" 2>/dev/null || true; }
  # Only claim success if the file actually exists on disk (the dir could still be gone).
  if [ -s "$RESULT_FILE" ]; then
    echo "RESULT_JSON:$(tr -d '\n' < "$RESULT_FILE")"
    log "results written to $RESULT_FILE (overall=$OVERALL${REASON:+ reason=$REASON})"
  else
    warn "RESULT FILE NOT WRITTEN ($RESULT_FILE) — report dir unavailable; emitting RESULT_JSON inline"
    echo "RESULT_JSON:{\"overall\":\"$OVERALL\",\"reason\":\"${REASON:-write_failed}\",\"run_id\":\"$RUNID\"}"
  fi
}

# ── terminal-state reconciliation (§0) ──────────────────────────────────────────
# Ground-truth op log: append_op records emitted ops (create/update/delete/rename)
# for the reconciled lanes. reconcile() replays them per key in emission order to
# compute the expected terminal region keyspace, then diffs against a single batched
# region dump. Sets RECON_* globals.
OPLOG=""
# Field separator = ASCII Unit Separator (0x1F, octal 037). MUST be a NON-whitespace
# char: with a whitespace IFS (e.g. tab) `read` collapses runs of the delimiter and
# trims, so an EMPTY middle field (delete/rename carry an empty body) would merge with
# its neighbour and shift `newkey` into `body`, leaving newkey="" → `SEEN[""]=1` is a
# FATAL bad-array-subscript that aborts the whole phase. 0x1F never appears in a redis
# key or these bodies, so empty fields are preserved exactly.
OPSEP=$'\037'
oplog_init() { OPLOG="$(mktemp)"; : > "$OPLOG"; }
append_op() { printf '%s%s%s%s%s%s%s\n' "$1" "$OPSEP" "$2" "$OPSEP" "${3:-}" "$OPSEP" "${4:-}" >> "$OPLOG"; }  # op key body newkey
RECON_EXPK=0; RECON_PRESK=0; RECON_MISS=0; RECON_CORR=0; RECON_DELV=0; RECON_RENV=0
reconcile() {
  declare -A EXP=() SEEN=()
  local op key body newkey
  local delcount=0 rencount=0
  while IFS="$OPSEP" read -r op key body newkey; do
    [ -n "$key" ] || continue                       # defensive: never index on an empty key
    SEEN["$key"]=1
    case "$op" in
      create|update) EXP["$key"]="$body";;
      delete)        unset 'EXP[$key]'; delcount=$(( delcount+1 ));;
      rename)
        [ -n "$newkey" ] || { warn "reconcile: rename with empty newkey for $key — skipped"; continue; }
        SEEN["$newkey"]=1; rencount=$(( rencount+1 ))
        if [ -n "${EXP[$key]+x}" ]; then EXP["$newkey"]="${EXP[$key]}"; unset 'EXP[$key]'; fi
        ;;
    esac
  done < "$OPLOG"

  # Batch-fetch every key we ever touched in one region round trip (order preserved).
  local allkeys=() k out
  for k in "${!SEEN[@]}"; do allkeys+=("$k"); done
  RECON_EXPK="${#EXP[@]}"; RECON_PRESK=0; RECON_MISS=0; RECON_CORR=0
  RECON_DELV=0; RECON_RENV="$rencount"
  local getf; getf="$(mktemp)"
  for k in "${allkeys[@]}"; do printf 'GET %s\n' "$k" >> "$getf"; done
  # redis-cli reads commands from stdin, prints one reply line per GET (nil -> empty).
  out="$(kubectl -n "$NS" exec -i "$REGION" -- redis-cli < "$getf" 2>/dev/null)"
  rm -f "$getf"
  local i=0
  for k in "${allkeys[@]}"; do
    i=$(( i+1 ))
    local val; val="$(sed -n "${i}p" <<<"$out" | tr -d '\r')"
    if [ -n "${EXP[$k]+x}" ]; then
      if [ -z "$val" ]; then
        RECON_MISS=$(( RECON_MISS+1 ))
      elif [ "$val" != "${EXP[$k]}" ]; then
        RECON_CORR=$(( RECON_CORR+1 ))
      else
        RECON_PRESK=$(( RECON_PRESK+1 ))
      fi
    else
      # expected ABSENT (deleted / renamed away): still present => failed apply -> corrupt
      if [ -n "$val" ]; then RECON_CORR=$(( RECON_CORR+1 )); else RECON_DELV=$(( RECON_DELV+1 )); fi
    fi
  done
}

# ── quiescence primitive (§0) ───────────────────────────────────────────────────
# Settle when the central group PEL is empty AND every listed sink durable reports
# num_pending==0 && num_ack_pending==0, held stable for 2 polls. $@ = durable names.
quiesce() {
  local durables=("$@") deadline ok=0 pel np nap d bad
  deadline=$(( $(date +%s) + SETTLE_TIMEOUT_S ))
  while (( $(date +%s) < deadline )); do
    bad=0
    pel="$(pel_count)"; pel="${pel:-0}"
    (( pel != 0 )) && bad=1
    if (( ! bad )); then
      for d in "${durables[@]}"; do
        local cj; cj="$(consumer_json "$d")"
        # An EMPTY reply means the query pod is unavailable — do NOT treat it as a
        # settled (num_pending//0=0) durable, or quiesce would vacuously "pass" while
        # the sinks are still draining (run-2 latent bug). Keep waiting; consumer_json
        # self-heals the natsq pod on the next poll.
        [ -z "$cj" ] && { bad=1; break; }
        np="$(jq -r '.num_pending // 0' <<<"$cj" 2>/dev/null)"; np="${np:-0}"
        nap="$(jq -r '.num_ack_pending // 0' <<<"$cj" 2>/dev/null)"; nap="${nap:-0}"
        (( np != 0 || nap != 0 )) && { bad=1; break; }
      done
    fi
    if (( ! bad )); then ok=$(( ok+1 )); (( ok >= 2 )) && return 0; else ok=0; fi
    sleep 3
  done
  warn "quiesce timed out after ${SETTLE_TIMEOUT_S}s (pel=$pel)"
  return 1
}

# ── emit helper: pipe a command file into central redis-cli ─────────────────────
emit_file() { kubectl -n "$NS" exec -i "$CENTRAL" -- redis-cli < "$1" >/dev/null; }

# ── install helpers ─────────────────────────────────────────────────────────────
install_coexist() {
  log "=== Install-A: coexistence overlay (sharded lb:company + tg:caveat + catchAll), ns=$NS ==="
  helm uninstall "$RELEASE" -n "$NS" >/dev/null 2>&1 || true
  kubectl -n "$NS" delete pods --all --grace-period=0 --force >/dev/null 2>&1 || true
  helm upgrade --install "$RELEASE" ./chart -n "$NS" --create-namespace \
    --set profile=cdc -f "$VALUES_FILE" -f "$COEXIST_VALUES" \
    "${EXTRA_SET[@]}" --wait --timeout 6m || return 1
  local d
  for d in connect-source connect-sink-shard-a connect-sink-shard-b connect-sink-caveat connect-sink-others; do
    kubectl -n "$NS" rollout status "deploy/${PREFIX}${d}" --timeout="$ROLL_TIMEOUT" || return 1
  done
  sleep 5   # let electors win + POST pipelines
  natsq_start
  rr FLUSHDB >/dev/null 2>&1 || true
  rc XGROUP CREATE "$STREAM" "$GROUP" 0 MKSTREAM >/dev/null 2>&1 || true
  return 0
}
install_default() {
  log "=== Install-B: default single-sink whole-stream (ns=$NS) ==="
  helm uninstall "$RELEASE" -n "$NS" >/dev/null 2>&1 || true
  kubectl -n "$NS" delete pods --all --grace-period=0 --force >/dev/null 2>&1 || true
  # Default render (no sinkGroups) but with modest replicas: F-1/F-2 are ack-path
  # faults, not failover — one active leg is enough, and low replicas keep node CPU
  # headroom (the coexist install was just torn down but pods may still be draining).
  helm upgrade --install "$RELEASE" ./chart -n "$NS" --create-namespace \
    --set profile=cdc -f "$VALUES_FILE" \
    --set connect.source.replicas=2 --set connect.sink.replicas=2 \
    "${EXTRA_SET[@]}" --wait --timeout 6m || return 1
  local d
  for d in connect-source connect-sink; do
    kubectl -n "$NS" rollout status "deploy/${PREFIX}${d}" --timeout="$ROLL_TIMEOUT" || return 1
  done
  sleep 5
  natsq_start
  rr FLUSHDB >/dev/null 2>&1 || true
  rc XGROUP CREATE "$STREAM" "$GROUP" 0 MKSTREAM >/dev/null 2>&1 || true
  return 0
}

# ════════════════════════════════════════════════════════════════════════════════
# P1 — render matrix (no cluster)
# ════════════════════════════════════════════════════════════════════════════════
phase_p1() {
  local t0; t0="$(date +%s)"
  mark "render"
  log "== P1: render matrix =="
  local RENDER rc_render
  RENDER="$(helm template chart/ -f "$COEXIST_VALUES" 2>/dev/null)"; rc_render=$?
  local sg; sg="$(grep -oE "SINK_GROUPS='[^']*'" <<<"$RENDER")"

  # (1) coexist_overlay_renders — exit 0 + all §1.1 objects, no leaked whole-stream sink.
  local ok=0 miss=""
  (( rc_render == 0 )) || { ok=1; miss="render-exit=$rc_render"; }
  local tok
  for tok in s0 s1 s2 s3 sx; do
    grep -qF "${DUR_BASE}_${tok}|kv.cdc.lb.company.${tok}.>|1|" <<<"$sg" || { ok=1; miss+=" durable_${tok}/map=1"; }
  done
  grep -qF "cdc_sink_caveat|kv.cdc.tg.caveat.>|1024|" <<<"$sg" || { ok=1; miss+=" caveat/1024"; }
  grep -qF "cdc_sink_others|kv.cdc.others.>|1024|"   <<<"$sg" || { ok=1; miss+=" others/1024"; }
  for tok in shard-a shard-b caveat others; do
    grep -q "name: ${PREFIX}connect-sink-${tok}\$" <<<"$RENDER" || { ok=1; miss+=" dep_${tok}"; }
  done
  grep -q "name: ${PREFIX}connect-source\$" <<<"$RENDER" || { ok=1; miss+=" dep_source"; }
  # leak guard: NO default whole-stream durable, NO default single sink Deployment.
  grep -qF "cdc_sink|kv.cdc.>|" <<<"$sg" && { ok=1; miss+=" LEAK_default_durable"; }
  grep -q "name: ${PREFIX}connect-sink\$" <<<"$RENDER" && { ok=1; miss+=" LEAK_default_sink"; }
  [ "$ok" = 0 ] && P1_C_RENDER=true || P1_C_RENDER=false
  gate "p1_coexist_overlay_renders" "$ok" "$miss"

  # (2) keypattern_trap_guard — overlay renders the PLURAL {employees:...} pattern;
  #     the SINGULAR default 'employee:(?P<id>' must be ABSENT (would route all to sx).
  local okt=0
  grep -qF 'employees:(?P<id>' <<<"$RENDER" || okt=1
  grep -qF 'employee:(?P<id>'  <<<"$RENDER" && okt=1   # substring test is exact: plural has 'employees:' not 'employee:'
  [ "$okt" = 0 ] && P1_C_TRAP=true || P1_C_TRAP=false
  gate "p1_keypattern_trap_guard" "$okt" "plural-employees pattern present & singular absent"

  # (3) failloud_conflicts — both known conflicts MUST fail the render (exit nonzero).
  local okf=0
  # (a) whole-stream (default) group alongside a prefixes group -> "consumed TWICE".
  if helm template chart/ --set connect.sinkGroups[0].name=default \
       --set connect.sinkGroups[1].name=a --set connect.sinkGroups[1].prefixes[0]=prefix-a \
       >/dev/null 2>&1; then okf=1; log "P1: whole-stream+prefix did NOT fail-loud"; fi
  # (b) a family in BOTH sharding.families and a prefixes entry -> "already owned by".
  if helm template chart/ -f "$COEXIST_VALUES" \
       --set 'connect.sinkGroups[4].name=dup' --set 'connect.sinkGroups[4].prefixes[0]=lb:company' \
       >/dev/null 2>&1; then okf=1; log "P1: family-in-both did NOT fail-loud"; fi
  [ "$okf" = 0 ] && P1_C_FAILLOUD=true || P1_C_FAILLOUD=false
  gate "p1_failloud_conflicts" "$okf" "both known conflicts fail-loud"

  P1_DUR=$(( $(date +%s) - t0 ))
  if $P1_C_RENDER && $P1_C_TRAP && $P1_C_FAILLOUD; then P1_STATUS="PASS"; else P1_STATUS="FAIL"; fi
  P1_ERR=""; P1_ABIN=""   # reached the end => not an abort
  log "P1 $P1_STATUS (${P1_DUR}s)"
}

# ════════════════════════════════════════════════════════════════════════════════
# P2 — coexist traffic (Install-A)
# ════════════════════════════════════════════════════════════════════════════════
phase_p2() {
  local t0; t0="$(date +%s)"
  log "== P2: coexist traffic (M-A..M-H) =="
  oplog_init
  local ts; ts="$(now_ms)"
  local SHARD_DURS=(cdc_sink_lb_company_s0 cdc_sink_lb_company_s1 cdc_sink_lb_company_s2 cdc_sink_lb_company_s3 cdc_sink_lb_company_sx)
  local ALL_DURS=("${SHARD_DURS[@]}" cdc_sink_caveat cdc_sink_others)

  # ── build per-lane command files (unique event_ids ${RUNID}-<lane>-<seq>) ──
  local f_shard f_cav f_oth f_mea f_mes
  f_shard="$(mktemp)"; f_cav="$(mktemp)"; f_oth="$(mktemp)"; f_mea="$(mktemp)"; f_mes="$(mktemp)"
  local i
  # M-A: NROUTE creates over employees 1..NROUTE (10/shard at N=4).
  for (( i=1; i<=NROUTE; i++ )); do
    local k="lb:company:active:{employees:${i}}:r${KEYRUN}"
    echo "XADD $STREAM * event_id ${RUNID}-ma-c${i} op create type string kv_key ${k} ts ${ts} body v${i}" >> "$f_shard"
    append_op create "$k" "v${i}"
  done
  # M-B: tg:caveat lane — creates then update/delete/rename (terminal reconciliation).
  for (( i=1; i<=NCAV; i++ )); do
    local k="tg:caveat:${KEYRUN}:k${i}"
    echo "XADD $STREAM * event_id ${RUNID}-mb-c${i} op create type string kv_key ${k} ts ${ts} body cv-v${i}" >> "$f_cav"
    append_op create "$k" "cv-v${i}"
  done
  { echo "XADD $STREAM * event_id ${RUNID}-mb-u1 op update type string kv_key tg:caveat:${KEYRUN}:k1 ts ${ts} body cv-v1b"
    echo "XADD $STREAM * event_id ${RUNID}-mb-d1 op delete type string kv_key tg:caveat:${KEYRUN}:k2 ts ${ts} body x"
    echo "XADD $STREAM * event_id ${RUNID}-mb-r1 op rename type string kv_key tg:caveat:${KEYRUN}:k3 old_key tg:caveat:${KEYRUN}:k3 new_key tg:caveat:${KEYRUN}:k3r ts ${ts} body x"
  } >> "$f_cav"
  append_op update "tg:caveat:${KEYRUN}:k1" "cv-v1b"
  append_op delete "tg:caveat:${KEYRUN}:k2"
  append_op rename "tg:caveat:${KEYRUN}:k3" "" "tg:caveat:${KEYRUN}:k3r"
  # M-C: misc:thing (others catchAll) lane — creates + a couple of updates.
  for (( i=1; i<=NOTH; i++ )); do
    local k="misc:thing:${KEYRUN}:k${i}"
    echo "XADD $STREAM * event_id ${RUNID}-mc-c${i} op create type string kv_key ${k} ts ${ts} body oth-v${i}" >> "$f_oth"
    append_op create "$k" "oth-v${i}"
  done
  echo "XADD $STREAM * event_id ${RUNID}-mc-u1 op update type string kv_key misc:thing:${KEYRUN}:k1 ts ${ts} body oth-v1b" >> "$f_oth"
  append_op update "misc:thing:${KEYRUN}:k1" "oth-v1b"
  # M-E: ONE employee (id 5 -> s1 -> shard-a), interleaved active+standby updates.
  local EMP=5
  local KA="lb:company:active:{employees:${EMP}}:ord${KEYRUN}"
  local KS="lb:company:standby:{employees:${EMP}}:ord${KEYRUN}"
  for (( i=1; i<=NSEQ; i++ )); do
    echo "XADD $STREAM * event_id ${RUNID}-oa-${i} op update type string kv_key ${KA} ts ${ts} body ${i}" >> "$f_mea"
    echo "XADD $STREAM * event_id ${RUNID}-os-${i} op update type string kv_key ${KS} ts ${ts} body ${i}" >> "$f_mes"
  done
  append_op update "$KA" "$NSEQ"   # terminal expected value for the union reconciliation
  append_op update "$KS" "$NSEQ"

  # ── M-E region poller (T-4 oracle): capture both keys as fast as redis-cli allows ──
  local POLL_OUT; POLL_OUT="$(mktemp)"
  kubectl -n "$NS" exec "$REGION" -- sh -c \
    "i=0; while [ \$i -lt 12000 ]; do redis-cli MGET '$KA' '$KS' | tr '\n' '|'; echo; i=\$((i+1)); done" \
    > "$POLL_OUT" 2>/dev/null &
  local POLL_PID=$!; BG_POLLERS+=("$POLL_PID")
  sleep 1

  # ── M-D: emit ALL lanes concurrently (interleaved at the serialized forward leg) ──
  # wait ONLY on the emit PIDs — a bare `wait` would also block on POLL_PID (12000 iters).
  mark "emit"
  log "M-D: emitting shard(${NROUTE}) + caveat(${NCAV}) + others(${NOTH}) + M-E(2x${NSEQ}) concurrently"
  local epids=()
  emit_file "$f_shard" & epids+=($!)
  emit_file "$f_cav"  & epids+=($!)
  emit_file "$f_oth"  & epids+=($!)
  emit_file "$f_mea"  & epids+=($!)
  emit_file "$f_mes"  & epids+=($!)
  wait "${epids[@]}" 2>/dev/null || true
  rm -f "$f_shard" "$f_cav" "$f_oth" "$f_mea" "$f_mes"

  # ── settle: quiesce on the multi-durable mix ──
  mark "quiesce"
  if ! quiesce "${ALL_DURS[@]}"; then gate "p2_quiesce" 1 "PEL/durables did not settle"; fi
  # let the poller catch the final states, then stop it
  local deadline fa fs
  deadline=$(( $(date +%s) + SETTLE_TIMEOUT_S ))
  while (( $(date +%s) < deadline )); do
    fa="$(rr GET "$KA" | tr -d '\r')"; fs="$(rr GET "$KS" | tr -d '\r')"
    [ "$fa" = "$NSEQ" ] && [ "$fs" = "$NSEQ" ] && break
    sleep 2
  done
  kill "$POLL_PID" >/dev/null 2>&1 || true; wait "$POLL_PID" 2>/dev/null || true
  P2_FINALS="${fa:-0}/${fs:-0}"

  # ── M-E: monotone + finals (region value must never go backwards per key) ──
  mark "ordering"
  local viol
  viol="$(awk -F'|' '
    { for (c=1;c<=2;c++){ v=$c; if(v=="")continue; if(v+0<last[c]){print "col"c": "last[c]" -> "v; bad=1} last[c]=v+0 } }
    END{ exit bad }' "$POLL_OUT" 2>&1)"
  if [ -n "$viol" ]; then P2_MONOTONE=false; else P2_MONOTONE=true; fi
  P2_SAMPLES="$(grep -c . "$POLL_OUT" || true)"
  P2_DISTINCT="$(awk -F'|' '{print $1}' "$POLL_OUT" | sort -un | wc -l | tr -d ' ')"
  rm -f "$POLL_OUT"
  gate "p2_ordering_monotone" "$([ "$P2_MONOTONE" = true ] && [ "$fa" = "$NSEQ" ] && [ "$fs" = "$NSEQ" ] && echo 0 || echo 1)" \
       "monotone=$P2_MONOTONE finals=$P2_FINALS want=$NSEQ/$NSEQ; $viol"

  # ── M-D isolation — DUPLICATE-TOLERANT oracle (§1.2, amended after live run 1784130697) ──
  # NEVER gate on cdc_apply equality: sink-side redeliveries after ackWait re-apply idempotently
  # and increment cdc_apply AGAIN (dupes are legal under at-least-once), so caveat=33 vs exp=31 is
  # NOT a leak. cdc_apply carries {shard,op,type} — no key label — so it can't be key-scoped.
  mark "isolation"
  # expected = MINIMUM countable applies (create/update emit cdc_apply{op,type}; delete/rename are
  # op-only, not counted). employees 1..40 mod 4: shard-a owns s0,s1 (20 creates); shard-b s2,s3 (20).
  # M-E (employee 5 -> s1 -> shard-a): 2*NSEQ update applies land on shard-a.
  P2_A_EXP=$(( 20 + 2*NSEQ )); P2_B_EXP=20; P2_CAV_EXP=$(( NCAV + 1 )); P2_OTH_EXP=$(( NOTH + 1 ))
  P2_A_APPLY="$(metric_sum connect-sink-shard-a cdc_apply)"
  P2_B_APPLY="$(metric_sum connect-sink-shard-b cdc_apply)"
  P2_CAV_APPLY="$(metric_sum connect-sink-caveat cdc_apply)"
  P2_OTH_APPLY="$(metric_sum connect-sink-others cdc_apply)"
  P2_A_SURPLUS=$(( P2_A_APPLY - P2_A_EXP )); P2_B_SURPLUS=$(( P2_B_APPLY - P2_B_EXP ))
  P2_CAV_SURPLUS=$(( P2_CAV_APPLY - P2_CAV_EXP )); P2_OTH_SURPLUS=$(( P2_OTH_APPLY - P2_OTH_EXP ))
  log "cdc_apply(>=exp): shard-a=$P2_A_APPLY/$P2_A_EXP shard-b=$P2_B_APPLY/$P2_B_EXP caveat=$P2_CAV_APPLY/$P2_CAV_EXP others=$P2_OTH_APPLY/$P2_OTH_EXP (surplus=legal dupes)"
  # (1) LIVENESS: applied >= expected per group (dupes push higher; `<` means real loss on that lane)
  local live_ok=0
  (( P2_A_APPLY   >= P2_A_EXP ))   || { live_ok=1; log "P2: shard-a applied $P2_A_APPLY < $P2_A_EXP (loss)"; }
  (( P2_B_APPLY   >= P2_B_EXP ))   || { live_ok=1; log "P2: shard-b applied $P2_B_APPLY < $P2_B_EXP (loss)"; }
  (( P2_CAV_APPLY >= P2_CAV_EXP )) || { live_ok=1; log "P2: caveat applied $P2_CAV_APPLY < $P2_CAV_EXP (loss)"; }
  (( P2_OTH_APPLY >= P2_OTH_EXP )) || { live_ok=1; log "P2: others applied $P2_OTH_APPLY < $P2_OTH_EXP (loss)"; }
  gate "p2_liveness_apply_ge_expected" "$live_ok" "each group cdc_apply >= expected (dupes legal)"
  # (2) FOREIGN-SHARD zero-check (exact-0, dup-proof): a sharded group must NEVER apply a shard it
  #     does not own. shard-a owns {s0,s1}; shard-b owns {s2,s3,sx}. (caveat/others have no shard
  #     label — cdc-reverse.yaml — so their isolation is carried entirely by check 3.)
  local foreign=0 f
  for f in s2 s3 sx; do foreign=$(( foreign + $(metric_sum connect-sink-shard-a cdc_apply "shard=\"${f}\"") )); done
  for f in s0 s1;    do foreign=$(( foreign + $(metric_sum connect-sink-shard-b cdc_apply "shard=\"${f}\"") )); done
  P2_FOREIGN=$foreign
  gate "p2_foreign_shard_zero" "$([ "$P2_FOREIGN" = 0 ] && echo 0 || echo 1)" "foreign_shard_applies=$P2_FOREIGN (must be exact 0)"

  # ── (3) key-scoped terminal-state reconciliation (authoritative, state-based, dup-proof) ──
  mark "reconcile"
  reconcile
  P2_EXPK="$RECON_EXPK"; P2_PRESK="$RECON_PRESK"; P2_MISSING="$RECON_MISS"; P2_CORRUPT="$RECON_CORR"
  P2_DELV="$RECON_DELV"; P2_RENV="$RECON_RENV"
  # NO region key may fall OUTSIDE the three disjoint lane ranges (unexpected key = mis-route/leak).
  local total inrange
  total="$(cnt '*')"
  inrange=$(( $(cnt 'lb:company:*') + $(cnt 'tg:caveat:*') + $(cnt 'misc:thing:*') ))
  P2_KEYS_OUTSIDE=$(( total - inrange )); (( P2_KEYS_OUTSIDE < 0 )) && P2_KEYS_OUTSIDE=0
  log "reconciliation: expected=$P2_EXPK present=$P2_PRESK missing=$P2_MISSING corrupt=$P2_CORRUPT del_ok=$P2_DELV ren_ok=$P2_RENV keys_outside=$P2_KEYS_OUTSIDE"
  gate "p2_zero_loss" "$([ "$P2_MISSING" = 0 ] && [ "$P2_CORRUPT" = 0 ] && echo 0 || echo 1)" \
       "missing=$P2_MISSING corrupt=$P2_CORRUPT"
  # cross_lane_leak is now (foreign-shard applies)+(region keys outside any lane range) — both exact-0,
  # NOT a difference of apply counts (which dupes make meaningless).
  P2_LEAK=$(( P2_FOREIGN + P2_KEYS_OUTSIDE ))
  gate "p2_isolation_no_leak" "$([ "$P2_LEAK" = 0 ] && echo 0 || echo 1)" \
       "cross_lane_leak=$P2_LEAK (foreign_shard=$P2_FOREIGN + keys_outside=$P2_KEYS_OUTSIDE)"

  mark "shard-durables"
  # ── M-F: shard durables under load (max_ack_pending==1, explicit, pull, num_ack_pending<=1) ──
  natsq_ensure >/dev/null 2>&1 || true   # make sure the query pod is alive before scraping
  local mf_ok=0 nap_max=0
  for tok in s0 s1 s2 s3 sx; do
    local cj map ack deliver fs2 nap
    cj="$(consumer_json "${DUR_BASE}_${tok}")"
    if [ -z "$cj" ]; then
      mf_ok=1; log "P2 M-F: ${tok} consumer_info UNAVAILABLE (natsq query pod down — infra, not a durable defect)"
      continue
    fi
    map="$(jq -r '.config.max_ack_pending' <<<"$cj" 2>/dev/null)"
    ack="$(jq -r '.config.ack_policy' <<<"$cj" 2>/dev/null)"
    deliver="$(jq -r '.config.deliver_subject // ""' <<<"$cj" 2>/dev/null)"
    fs2="$(jq -r '.config.filter_subject // (.config.filter_subjects | join(","))' <<<"$cj" 2>/dev/null)"
    nap="$(jq -r '.num_ack_pending // 0' <<<"$cj" 2>/dev/null)"; nap="${nap:-0}"
    [ "$map" = "1" ] || { mf_ok=1; log "P2 M-F: ${tok} max_ack_pending=$map"; }
    [ "$ack" = "explicit" ] || { mf_ok=1; log "P2 M-F: ${tok} ack_policy=$ack"; }
    [ -z "$deliver" ] || { mf_ok=1; log "P2 M-F: ${tok} is PUSH"; }
    [ "$fs2" = "kv.cdc.lb.company.${tok}.>" ] || { mf_ok=1; log "P2 M-F: ${tok} filter=$fs2"; }
    (( nap <= 1 )) || { mf_ok=1; log "P2 M-F: ${tok} num_ack_pending=$nap"; }
    (( nap > nap_max )) && nap_max=$nap
  done
  P2_NAP_MAX=$nap_max; P2_MAP_ALL=1
  gate "p2_shard_durables" "$mf_ok" "every shard durable pull/explicit/max_ack_pending=1, num_ack_pending<=1"

  mark "sx-lane"
  # ── M-G: sx isolation lane — 3 unparseable family keys route to sx, APPLIED not dropped ──
  local unrt0 xsr0
  unrt0="$(metric_sum connect-source cdc_forward_unrouted 'reason="unparseable_shard"')"
  xsr0="$(metric_sum connect-source cdc_forward_cross_shard_rename)"
  local f_sx; f_sx="$(mktemp)"
  for i in 1 2 3; do
    echo "XADD $STREAM * event_id ${RUNID}-sx-${i} op create type string kv_key lb:company:active:sxprobe${i}:r${KEYRUN} ts ${ts} body sx${i}" >> "$f_sx"
  done
  emit_file "$f_sx"; rm -f "$f_sx"
  local sxd=$(( $(date +%s) + SETTLE_TIMEOUT_S ))
  while (( $(date +%s) < sxd )); do
    (( $(cnt "lb:company:active:sxprobe*:r${KEYRUN}") == 3 )) && break; sleep 2
  done
  P2_SX_APPLY="$(metric_sum connect-sink-shard-b cdc_apply 'shard="sx"')"
  local unrt1 xsr1
  unrt1="$(metric_sum connect-source cdc_forward_unrouted 'reason="unparseable_shard"')"
  xsr1="$(metric_sum connect-source cdc_forward_cross_shard_rename)"
  P2_SX_UNP=$(( unrt1 - unrt0 ))          # DELTA (cumulative source counter — never absolute)
  P2_SX_XSR=$(( xsr1 - xsr0 ))
  log "sx lane: applied(shard=sx)=$P2_SX_APPLY unparseable_delta=$P2_SX_UNP cross_shard_rename_delta=$P2_SX_XSR"
  gate "p2_sx_lane" "$([ "$P2_SX_APPLY" = 3 ] && [ "$P2_SX_UNP" = 3 ] && [ "$P2_SX_XSR" = 0 ] && echo 0 || echo 1)" \
       "applied=3 unparseable_delta=3 cross_shard_rename_delta=0"

  mark "dedup"
  # ── M-H: dedup — re-emit M-A event_ids, terminal state must not change ──
  local before after
  before="$(cnt "*r${KEYRUN}*")"
  local f_dd; f_dd="$(mktemp)"
  for (( i=1; i<=NROUTE; i++ )); do
    echo "XADD $STREAM * event_id ${RUNID}-ma-c${i} op create type string kv_key lb:company:active:{employees:${i}}:r${KEYRUN} ts ${ts} body v${i}" >> "$f_dd"
  done
  emit_file "$f_dd"; rm -f "$f_dd"
  sleep 10
  after="$(cnt "*r${KEYRUN}*")"
  [ "$after" = "$before" ] && P2_DEDUP=true || P2_DEDUP=false
  gate "p2_dedup" "$([ "$P2_DEDUP" = true ] && echo 0 || echo 1)" "region ${before}->${after} after replay"

  rm -f "$OPLOG"
  P2_DUR=$(( $(date +%s) - t0 ))
  # P2 phase status: PASS iff all its gates held (recompute from evidence).
  if $P2_MONOTONE && (( live_ok==0 && mf_ok==0 )) \
     && [ "$P2_FOREIGN" = 0 ] && [ "$P2_KEYS_OUTSIDE" = 0 ] \
     && [ "$P2_MISSING" = 0 ] && [ "$P2_CORRUPT" = 0 ] \
     && [ "$P2_SX_APPLY" = 3 ] && [ "$P2_SX_UNP" = 3 ] && [ "$P2_SX_XSR" = 0 ] \
     && [ "$P2_DEDUP" = true ]; then P2_STATUS="PASS"; else P2_STATUS="FAIL"; fi
  P2_ERR=""; P2_ABIN=""   # reached the end => not an abort
  log "P2 $P2_STATUS (${P2_DUR}s)"
}

# ════════════════════════════════════════════════════════════════════════════════
# P3 — graceful leader change (Install-A). GATES ONLY on loss==0 + same-key monotone.
# ════════════════════════════════════════════════════════════════════════════════
# graceful_test <label> <lease-name> <sink-app-for-metrics> <hot-employee-id> <keytag>
#   emits a hot-key monotone lane + distinct-key creates on the lb:company family
#   (strict per-key ordering), gracefully `kubectl delete pod`s the current lease
#   holder mid-flight, then GATES on loss==0 + monotone and RECORDS the gap evidence.
# Sets (via nameref-ish OUT_* globals): OUT_POD/OUT_LOSS/OUT_MONO/OUT_HLAT/OUT_MECH/OUT_DELRAN/OUT_DAW
graceful_test() {
  # $3 (connect app label) is intentionally unused now — the old elector_delete_total
  # metric delta was sampled from post-handoff pods (victim already replaced) and is
  # unsound across pod replacement; handoff evidence comes from the victim log-follow.
  local label="$1" lease="$2" emp="$4" tag="$5"
  local ts; ts="$(now_ms)"
  OUT_POD=""; OUT_LOSS=0; OUT_MONO=true; OUT_HLAT=0; OUT_MECH="lease_expiry"; OUT_DELRAN=false; OUT_DAW=0; OUT_GAPEV=""
  local HOT="lb:company:active:{employees:${emp}}:${tag}${KEYRUN}"

  local victim
  victim="$(holder "$lease")"
  OUT_POD="$victim"
  log "$label: victim leader=$victim (lease $lease)"

  # region poller on the hot key (monotone oracle)
  local POLL_OUT; POLL_OUT="$(mktemp)"
  kubectl -n "$NS" exec "$REGION" -- sh -c \
    "i=0; while [ \$i -lt 20000 ]; do redis-cli GET '$HOT'; i=\$((i+1)); done" \
    > "$POLL_OUT" 2>/dev/null &
  local POLL_PID=$!; BG_POLLERS+=("$POLL_PID")

  oplog_init
  # emit hot-key monotone updates + distinct creates, concurrently; delete leader mid-way
  local f_hot f_keys i
  f_hot="$(mktemp)"; f_keys="$(mktemp)"
  for (( i=1; i<=NSEQ_G; i++ )); do
    echo "XADD $STREAM * event_id ${RUNID}-${tag}h-${i} op update type string kv_key ${HOT} ts ${ts} body ${i}" >> "$f_hot"
  done
  append_op update "$HOT" "$NSEQ_G"
  for (( i=1; i<=NKEYS_G; i++ )); do
    local eid=$(( 100 + i ))
    local k="lb:company:active:{employees:${eid}}:${tag}k${KEYRUN}"
    echo "XADD $STREAM * event_id ${RUNID}-${tag}k-${i} op create type string kv_key ${k} ts ${ts} body ${tag}-k${i}" >> "$f_keys"
    append_op create "$k" "${tag}-k${i}"
  done
  emit_file "$f_hot"  & local ph=$!
  emit_file "$f_keys" & local pk=$!
  # PRIMARY gap evidence: follow the victim's elector log through the whole
  # termination. `kubectl logs -f` streams until the container exits, so it captures
  # OnStoppedLeading if the callback ever runs during the grace window — reliable
  # even after the pod object is gone (unlike a post-hoc `logs --previous`, which
  # fails once the deleted pod is fully reaped). This is the sound signal for
  # elector_delete_ran / handoff_mechanism.
  local VLOG; VLOG="$(mktemp)"
  kubectl -n "$NS" logs -f "$victim" -c elector > "$VLOG" 2>/dev/null &
  local LOGPID=$!
  # graceful delete partway through emission
  sleep 2
  local t_del; t_del="$(date +%s)"
  log "$label: graceful kubectl delete pod $victim (default grace)"
  kubectl -n "$NS" delete pod "$victim" >/dev/null 2>&1 || true
  # wait ONLY on the emit PIDs — never a bare `wait` (POLL_PID runs 20000 iters).
  wait "$ph" "$pk" 2>/dev/null || true
  rm -f "$f_hot" "$f_keys"

  # handoff: poll lease holder until it changes; latency from delete to new holder
  local newh="" hd=$(( $(date +%s) + 120 ))
  until newh="$(holder "$lease")"; [ -n "$newh" ] && [ "$newh" != "$victim" ]; do
    (( $(date +%s) < hd )) || { warn "$label: no new lease holder within 120s"; break; }
    sleep 1
  done
  if [ -n "$newh" ] && [ "$newh" != "$victim" ]; then
    OUT_HLAT=$(( $(date +%s) - t_del ))
    OUT_MECH="lease_expiry"
  fi
  log "$label: handoff $victim -> ${newh:-<none>} in ${OUT_HLAT}s"

  # settle + wait for finals
  local dl fa; dl=$(( $(date +%s) + SETTLE_TIMEOUT_S ))
  while (( $(date +%s) < dl )); do
    fa="$(rr GET "$HOT" | tr -d '\r')"
    [ "$fa" = "$NSEQ_G" ] && (( $(cnt "lb:company:active:*:${tag}k${KEYRUN}") == NKEYS_G )) && break
    sleep 2
  done
  kill "$POLL_PID" >/dev/null 2>&1 || true; wait "$POLL_PID" 2>/dev/null || true

  # loss (terminal reconciliation of THIS lane) + monotone
  reconcile
  OUT_LOSS=$(( RECON_MISS + RECON_CORR ))
  local viol
  viol="$(awk '{ v=$1; if(v==""||v=="(nil)")next; if(v+0<last){print last" -> "v; bad=1} last=v+0 } END{exit bad}' "$POLL_OUT" 2>&1)"
  [ -n "$viol" ] && OUT_MONO=false || OUT_MONO=true
  rm -f "$POLL_OUT" "$OPLOG"

  # gap evidence (report-only, PRIMARY signal): did the elector's OnStoppedLeading
  # (which runs the DELETE /streams handoff) fire on the victim during termination?
  kill "$LOGPID" >/dev/null 2>&1 || true; wait "$LOGPID" 2>/dev/null || true
  local grepline
  grepline="$(grep -m1 'OnStoppedLeading' "$VLOG" 2>/dev/null || true)"
  rm -f "$VLOG"
  if [ -n "$grepline" ]; then OUT_DELRAN=true; OUT_MECH="explicit_delete"; else OUT_DELRAN=false; OUT_MECH="lease_expiry"; fi
  OUT_GAPEV="$grepline"   # per-call; phase_p3 copies into the per-leg P3S_GAPEV/P3K_GAPEV

  log "$label: loss=$OUT_LOSS monotone=$OUT_MONO handoff=${OUT_HLAT}s mechanism=$OUT_MECH elector_delete_ran=$OUT_DELRAN"
}

phase_p3() {
  local t0; t0="$(date +%s)"
  log "== P3: graceful leader change (report-only gap; gates loss==0 + monotone) =="

  # G-1: SOURCE leader (employee 7 -> s3 -> shard-b sink, strict order)
  mark "G-1 source"
  graceful_test "G-1(source)" "${PREFIX}connect-source-elector" "connect-source" 7 "g1"
  P3S_POD="$OUT_POD"; P3S_LOSS="$OUT_LOSS"; P3S_MONO="$OUT_MONO"; P3S_HLAT="$OUT_HLAT"
  P3S_MECH="$OUT_MECH"; P3S_DELRAN="$OUT_DELRAN"; P3S_DAW="$OUT_DAW"; P3S_GAPEV="$OUT_GAPEV"
  gate "p3_source_loss" "$([ "$P3S_LOSS" = 0 ] && echo 0 || echo 1)" "loss_keys=$P3S_LOSS"
  gate "p3_source_monotone" "$([ "$P3S_MONO" = true ] && echo 0 || echo 1)" "monotone=$P3S_MONO"

  check_deadline
  # G-2: SINK shard-a leader (employee 4 -> s0 -> shard-a)
  mark "G-2 sink"
  graceful_test "G-2(sink)" "${PREFIX}connect-sink-shard-a-elector" "connect-sink-shard-a" 4 "g2"
  P3K_POD="$OUT_POD"; P3K_LOSS="$OUT_LOSS"; P3K_MONO="$OUT_MONO"; P3K_HLAT="$OUT_HLAT"
  P3K_MECH="$OUT_MECH"; P3K_DELRAN="$OUT_DELRAN"; P3K_DAW="$OUT_DAW"; P3K_GAPEV="$OUT_GAPEV"
  gate "p3_sink_loss" "$([ "$P3K_LOSS" = 0 ] && echo 0 || echo 1)" "loss_keys=$P3K_LOSS"
  gate "p3_sink_monotone" "$([ "$P3K_MONO" = true ] && echo 0 || echo 1)" "monotone=$P3K_MONO"

  # known-gap report (NEVER gates): DELETE-handoff absent iff neither leg ran it.
  if [ "$P3S_DELRAN" = false ] && [ "$P3K_DELRAN" = false ]; then P3_GAP="ABSENT"; else P3_GAP="PRESENT"; fi
  log "P3 known gap graceful_delete_handoff=$P3_GAP (report-only)"

  P3_DUR=$(( $(date +%s) - t0 ))
  if [ "$P3S_LOSS" = 0 ] && [ "$P3S_MONO" = true ] && [ "$P3K_LOSS" = 0 ] && [ "$P3K_MONO" = true ]; then
    P3_STATUS="PASS"; else P3_STATUS="FAIL"; fi
  P3_ERR=""; P3_ABIN=""   # reached the end => not an abort
  log "P3 $P3_STATUS (${P3_DUR}s)"
}

# ════════════════════════════════════════════════════════════════════════════════
# P4 — ack-after-apply faults (Install-B, default single sink)
# ════════════════════════════════════════════════════════════════════════════════
phase_p4() {
  local t0; t0="$(date +%s)"
  log "== P4: ack-after-apply faults (F-1 source PEL, then F-2 sink num_ack_pending) =="
  local ts; ts="$(now_ms)"

  # resolve NATS pod IP + kind node for the F-1 iptables partition
  local NATS_POD
  NATS_POD="$(kubectl -n "$NS" get pods -l app=nats -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  NATS_IP="$(kubectl -n "$NS" get pod "$NATS_POD" -o jsonpath='{.status.podIP}' 2>/dev/null)"
  KIND_NODE="$(docker ps --format '{{.Names}}' | grep -m1 control-plane)"
  if [ -z "$NATS_IP" ] || [ -z "$KIND_NODE" ]; then
    gate "p4_prereq" 1 "cannot resolve NATS pod IP ($NATS_IP) / kind node ($KIND_NODE)"
    P4_STATUS="FAIL"; P4_DUR=$(( $(date +%s) - t0 )); return
  fi

  # ── F-1: source-leg write-then-XACK under a live NATS publish failure ──
  mark "F-1"
  log "F-1: partitioning NATS ($NATS_IP) for ${PARTITION_S}s and bursting $F1_BURST into f1:*"
  docker exec "$KIND_NODE" iptables -I FORWARD 1 -d "$NATS_IP" -j DROP; IPTABLES_RAISED=1
  sleep 2
  local f_f1 i; f_f1="$(mktemp)"
  for (( i=1; i<=F1_BURST; i++ )); do
    echo "XADD $STREAM * event_id ${RUNID}-f1-${i} op create type string kv_key f1:${KEYRUN}:k${i} ts ${ts} body f1-v${i}" >> "$f_f1"
  done
  emit_file "$f_f1"; rm -f "$f_f1"
  sleep "$PARTITION_S"
  # during fault: PEL retains the burst (nothing XACKed), region applied == 0 (vacuity)
  P4F1_PEL="$(pel_count)"; P4F1_PEL="${P4F1_PEL:-0}"
  P4F1_APPLYFAULT="$(cnt "f1:${KEYRUN}:*")"
  log "F-1 during fault: PEL=$P4F1_PEL region_f1=$P4F1_APPLYFAULT (want PEL>0, region==0)"
  docker exec "$KIND_NODE" iptables -D FORWARD -d "$NATS_IP" -j DROP >/dev/null 2>&1 || true; IPTABLES_RAISED=0
  # after lift: PEL drains to 0 and f1:* fully applies
  local dl; dl=$(( $(date +%s) + SETTLE_TIMEOUT_S ))
  while (( $(date +%s) < dl )); do
    P4F1_DRAINED="$(pel_count)"; P4F1_DRAINED="${P4F1_DRAINED:-0}"
    (( P4F1_DRAINED == 0 )) && (( $(cnt "f1:${KEYRUN}:*") == F1_BURST )) && break
    sleep 3
  done
  P4F1_DRAINED="$(pel_count)"; P4F1_DRAINED="${P4F1_DRAINED:-0}"
  local f1_present; f1_present="$(cnt "f1:${KEYRUN}:*")"
  P4F1_LOSS=$(( F1_BURST - f1_present ))
  log "F-1 after lift: PEL=$P4F1_DRAINED region_f1=$f1_present/$F1_BURST loss=$P4F1_LOSS"
  local f1_ok=0
  (( P4F1_PEL > 0 )) || { f1_ok=1; log "F-1: PEL not retained during fault"; }
  (( P4F1_APPLYFAULT == 0 )) || { f1_ok=1; log "F-1: VACUITY broken — $P4F1_APPLYFAULT applied while partitioned"; }
  (( P4F1_DRAINED == 0 )) || { f1_ok=1; log "F-1: PEL did not drain"; }
  (( P4F1_LOSS == 0 )) || { f1_ok=1; log "F-1: loss=$P4F1_LOSS"; }
  gate "p4_f1_source_ack" "$f1_ok" "PEL-retained + vacuity + drain + f1 loss==0"

  check_deadline
  # ── F-2: sink-leg apply-then-ack under a region outage (DISJOINT f2:* range) ──
  # PHASE ORDERING IS LOAD-BEARING (design §5): F-2 scales the emptyDir region to 0,
  # which WIPES all region state — including F-1's applied f1:* burst and its
  # diagnosis evidence. So F-2 MUST NOT run unless F-1 fully passed. If F-1 failed,
  # skip F-2, record it SKIPPED, and fail P4 with the precondition reason.
  local f2_ok=0
  if (( f1_ok != 0 )); then
    P4F2_STATUS="SKIPPED"
    P4_REASON="F-1 precondition failed — F-2 skipped (its region wipe would destroy F-1 evidence)"
    f2_ok=1
    log "F-2 SKIPPED: $P4_REASON"
  else
    mark "F-2"
    P4F2_STATUS="RUN"
    # SETTLE BARRIER (§5 DEFECT-B): late F-1 redelivery dupes were landing right after F-2's
    # baseline snapshot and contaminating the global cdc_apply read. Wait until the global
    # cdc_apply counter holds STEADY for SETTLE_STABLE_S before snapshotting F-2's baseline.
    log "F-2: settle barrier — waiting for global cdc_apply steady ${SETTLE_STABLE_S}s (F-1 dupes must drain)"
    local sb_prev="" sb_since sbdl cur_apply
    sb_since="$(date +%s)"; sbdl=$(( $(date +%s) + SETTLE_TIMEOUT_S ))
    while (( $(date +%s) < sbdl )); do
      cur_apply="$(metric_sum connect-sink cdc_apply)"
      if [ "$cur_apply" = "$sb_prev" ]; then
        (( $(date +%s) - sb_since >= SETTLE_STABLE_S )) && break
      else
        sb_prev="$cur_apply"; sb_since="$(date +%s)"
      fi
      sleep 2
    done
    log "F-2: scaling region to 0, bursting $F2_BURST into f2:* during the outage"
    local apply_before; apply_before="$(metric_sum connect-sink cdc_apply)"
    kubectl -n "$NS" scale "deploy/${REGION_DEPLOY}" --replicas=0 >/dev/null 2>&1; REGION_SCALED_DOWN=1
    kubectl -n "$NS" rollout status "deploy/${REGION_DEPLOY}" --timeout=60s >/dev/null 2>&1 || true
    sleep 3
    local f_f2; f_f2="$(mktemp)"
    for (( i=1; i<=F2_BURST; i++ )); do
      echo "XADD $STREAM * event_id ${RUNID}-f2-${i} op create type string kv_key f2:${KEYRUN}:k${i} ts ${ts} body f2-v${i}" >> "$f_f2"
    done
    emit_file "$f_f2"; rm -f "$f_f2"
    # during the outage POLL: keep MAX num_ack_pending, watch num_delivered CLIMB (redeliveries),
    # and confirm region SCAN f2:*==0 (nothing applied — key-scoped, immune to F-1 contamination).
    # A single end-of-outage nap sample can read 0 if redeliveries momentarily settle → poll+max.
    local nap_max=0 outage_end cj_s nap_s nd_first="" nd_last=0
    outage_end=$(( $(date +%s) + REGION_OUTAGE_S ))
    while (( $(date +%s) < outage_end )); do
      cj_s="$(consumer_json cdc_sink)"
      nap_s="$(jq -r '.num_ack_pending // 0' <<<"$cj_s" 2>/dev/null)"; nap_s="${nap_s:-0}"
      (( nap_s > nap_max )) && nap_max=$nap_s
      nd_last="$(jq -r '.delivered.consumer_seq // 0' <<<"$cj_s" 2>/dev/null)"; nd_last="${nd_last:-0}"
      [ -z "$nd_first" ] && nd_first="$nd_last"
      sleep 3
    done
    P4F2_NAP=$nap_max
    P4F2_SCANFAULT="$(cnt "f2:${KEYRUN}:*")"                 # region is down => 0 applied (key-scoped)
    [ "${nd_last:-0}" -gt "${nd_first:-0}" ] && P4F2_NDCLIMB=true || P4F2_NDCLIMB=false
    local cj_f2; cj_f2="$(consumer_json cdc_sink)"
    P4F2_REDELIV="$(jq -r '.num_redelivered // (.delivered.consumer_seq // 0)' <<<"$cj_f2" 2>/dev/null)"; P4F2_REDELIV="${P4F2_REDELIV:-0}"
    local apply_fault; apply_fault="$(metric_sum connect-sink cdc_apply)"
    P4F2_APPLYFAULT=$(( apply_fault - apply_before ))   # REPORT-ONLY (no key label, can't be scoped)
    log "F-2 during fault: scan_f2=$P4F2_SCANFAULT nap_max=$P4F2_NAP nd_climbing=$P4F2_NDCLIMB (nd ${nd_first:-0}->$nd_last) [report-only global cdc_apply_delta=$P4F2_APPLYFAULT]"
    # recover
    kubectl -n "$NS" scale "deploy/${REGION_DEPLOY}" --replicas=1 >/dev/null 2>&1; REGION_SCALED_DOWN=0
    kubectl -n "$NS" rollout status "deploy/${REGION_DEPLOY}" --timeout="$ROLL_TIMEOUT" >/dev/null 2>&1 || true
    rc XGROUP CREATE "$STREAM" "$GROUP" 0 MKSTREAM >/dev/null 2>&1 || true
    # after recover: f2:* fully applies; reconcile ONLY f2:* (whole-region is FORBIDDEN)
    dl=$(( $(date +%s) + SETTLE_TIMEOUT_S ))
    while (( $(date +%s) < dl )); do
      (( $(cnt "f2:${KEYRUN}:*") == F2_BURST )) && break; sleep 3
    done
    local f2_present; f2_present="$(cnt "f2:${KEYRUN}:*")"
    local apply_after; apply_after="$(metric_sum connect-sink cdc_apply)"
    P4F2_APPLYAFTER=$(( apply_after - apply_before ))   # REPORT-ONLY liveness (>= burst)
    P4F2_LOSS=$(( F2_BURST - f2_present ))
    log "F-2 after recover: region_f2=$f2_present/$F2_BURST cdc_apply_delta=$P4F2_APPLYAFTER loss=$P4F2_LOSS (scoped f2:* only)"
    # GATE (all key-scoped / durable-state, NOT the global cdc_apply delta):
    #   during fault: region SCAN f2:*==0 AND nap_max>0 AND num_delivered climbing;
    #   after recover: scoped f2:* reconciliation loss==0.
    (( P4F2_SCANFAULT == 0 )) || { f2_ok=1; log "F-2: $P4F2_SCANFAULT f2 keys applied DURING outage (want 0)"; }
    (( P4F2_NAP > 0 )) || { f2_ok=1; log "F-2: num_ack_pending never >0 during outage"; }
    [ "$P4F2_NDCLIMB" = true ] || { f2_ok=1; log "F-2: num_delivered did not climb (no redelivery under outage)"; }
    (( P4F2_LOSS == 0 )) || { f2_ok=1; log "F-2: f2 loss=$P4F2_LOSS"; }
    gate "p4_f2_sink_ack" "$f2_ok" "scoped: SCAN f2:*==0 + nap_max>0 + redeliveries climbing during fault + f2 loss==0 after recover"
  fi

  P4_DUR=$(( $(date +%s) - t0 ))
  if (( f1_ok==0 && f2_ok==0 )); then P4_STATUS="PASS"; else P4_STATUS="FAIL"; fi
  P4_ERR=""; P4_ABIN=""   # reached the end => not an abort
  log "P4 $P4_STATUS (${P4_DUR}s)${P4_REASON:+ — $P4_REASON}"
}

# ════════════════════════════════════════════════════════════════════════════════
# orchestration — phase-abort isolation
# ════════════════════════════════════════════════════════════════════════════════
# A FATAL in-phase error (e.g. a bad-array-subscript) is NOT catchable and, without
# -e, still unwinds every ENCLOSING compound command up to the current top-level
# command list entry, then execution continues at the NEXT top-level command. So each
# phase is invoked as its OWN top-level `run_phase …` statement (never nested inside a
# shared `if install; then p2; p3; fi`): an abort in one phase can no longer skip the
# rest. Verified against the exact nesting that skipped P3 on the first live run.

reap_pollers() { # kill any background region poller left running (e.g. by an aborted phase)
  (( ${#BG_POLLERS[@]} )) || return 0
  local p
  for p in "${BG_POLLERS[@]}"; do kill "$p" >/dev/null 2>&1 || true; done
  BG_POLLERS=()
}

# run_phase <phase-fn> <tag: p1|p2|p3|p4> [required-install-flag-var]
# Stamps ABORT on entry (a phase clears it to PASS/FAIL only on NORMAL completion), so
# an aborted phase reports ABORT with an error string — never a stale SKIP with
# populated data. SKIP is reserved strictly for "never entered" (phase not selected).
run_phase() {
  local fn="$1" tag="$2" reqflag="${3:-}" n="${2#p}"
  local -n _st="P${n}_STATUS"; local -n _er="P${n}_ERR"; local -n _ab="P${n}_ABIN"
  want_phase "$tag" || return 0                 # never entered => status stays SKIP
  reap_pollers                                  # clean up a poller leaked by a prior abort
  check_deadline
  if [ -n "$reqflag" ]; then
    local -n _flag="$reqflag"
    if [ "${_flag:-0}" != "1" ]; then
      # NOT a skip-forward for independent phases — only the phase whose OWN prerequisite
      # install failed aborts here; every other phase still runs (§2).
      _st="ABORT"; _er="prerequisite install failed — phase not run"; _ab="install"; OVERALL="FAIL"
      log "$tag: prerequisite install failed — recording ABORT (not run)"
      return 0
    fi
  fi
  # ABORT is stamped ON ENTRY and only cleared to PASS/FAIL on NORMAL completion, so a mid-phase
  # crash (fatal bad-subscript, kubectl/helm error, timeout) leaves ABORT + aborted_in — the real
  # error text is uncatchable in-process (it bypasses ERR traps) but is printed to the run log.
  _st="ABORT"; _er="phase crashed before completion — see run log for the fatal error"; _ab="entry"
  CUR_PHASE_N="$n"
  log "--- entering $tag ---"
  "$fn"        # on abort: control returns to the NEXT top-level run_phase; _st stays ABORT
  CUR_PHASE_N=""
}

# Install-A serves P2+P3; a bash-level P2 abort does NOT touch the helm release/pods,
# so P3 reuses the SAME live Install-A (no reinstall). Install-B serves P4.
maybe_install_a() {
  want_phase p2 || want_phase p3 || return 0
  reap_pollers; check_deadline
  # shellcheck disable=SC2034  # INSTALL_A_OK is read via nameref (_flag) in run_phase
  if install_coexist; then INSTALL_A_OK=1; else INSTALL_A_OK=0; gate "install_coexist" 1 "Install-A failed"; fi
}
maybe_install_b() {
  want_phase p4 || return 0
  reap_pollers; check_deadline
  # shellcheck disable=SC2034  # INSTALL_B_OK is read via nameref (_flag) in run_phase
  if install_default; then INSTALL_B_OK=1; else INSTALL_B_OK=0; gate "install_default" 1 "Install-B failed"; fi
}

log "run_id=$RUNID ns=$NS release=$RELEASE phases='$VERIFY_PHASES' deadline=${E2E_DEADLINE_S}s"

# Each line below is a distinct TOP-LEVEL command (see the abort-isolation note above).
run_phase phase_p1 p1
maybe_install_a
run_phase phase_p2 p2 INSTALL_A_OK
run_phase phase_p3 p3 INSTALL_A_OK
maybe_install_b
run_phase phase_p4 p4 INSTALL_B_OK
reap_pollers

write_results
[ "$OVERALL" = "PASS" ] && { log "PASS — e2e matrix all gating checks green"; exit 0; }
log "FAIL — one or more gating checks failed (see $RESULT_FILE)"
exit 1
