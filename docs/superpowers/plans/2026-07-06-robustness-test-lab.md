# labs/robustness-test Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A bash lab under `labs/robustness-test/` that proves, in kind, that `hpdevelop/connect:v4.92.0-batch-nats` loses zero messages under force-kill of either leg's leader and of standby pods (3 replicas/leg, Lease election, Redis+NATS healthy), and that unprocessable messages increment `cdc_unprocessable{reason}`.

**Architecture:** Thin orchestrator (`verify-robustness.sh`) running 5 phases. Phases 0–1 reuse `scripts/verify-cdc.sh` and `scripts/verify-failover.sh` via a new backward-compatible `RRCS_SET` env hook. Phases 2–4 are new bash scripts sharing `lib.sh`, using the same pure-redis-cli oracles as `verify-failover.sh`. Report (json+md) per run under `labs/robustness-test/reports/` (already gitignored — root `.gitignore` has unanchored `reports/`).

**Tech Stack:** bash, kubectl, helm, kind, redis-cli (in-cluster via `kubectl exec`), nats CLI (in-cluster via `natsio/nats-box:0.14.5` pod), jq.

**Spec:** `docs/superpowers/specs/2026-07-06-robustness-test-lab-design.md` (approved 2026-07-06, incl. the poison-oracle amendment).

## Global Constraints

- Kind cluster `cdc`, namespace `cdc-k8s`, release `cdc`, resource prefix `lab-` (all overridable via `KIND_NAME`, `RRCS_NS`, `RRCS_RELEASE`, `RRCS_PREFIX`).
- Target image env `CONNECT_IMAGE`, default **exactly** `hpdevelop/connect:v4.92.0-batch-nats`; it exists only in the local docker store → must be `kind load`ed; fail fast with a clear message if absent.
- **No changes to `chart/**` or `rules/**`.** The only existing files modified are `scripts/verify-cdc.sh` and `scripts/verify-failover.sh` (additive `RRCS_SET` hook, default-empty → behavior unchanged).
- Never pass keys the verify scripts already own (`connect.source.consumerClientId`, `connect.source.maxInFlight`, `connect.source.readLimit`) through `RRCS_SET` — the lab only passes `connect.image=…`.
- All new scripts: `#!/usr/bin/env bash` + `set -euo pipefail`, executable bit set, no `sudo`, no host package installs, no writes outside the repo and the kind cluster.
- Key facts used throughout (verified 2026-07-06): stream `app.events`, group `cdc_propagator`; XADD fields `event_id op type kv_key ts body`; NATS stream `KV_CDC`, publish subject `kv.cdc.<op>`, durable `cdc_sink`, `ackWait 30s`, `maxDeliver -1`, `dupeWindow 5m`; leases `lab-connect-source-elector` / `lab-connect-sink-elector` (holder = pod name); connect metrics port 4195 (Service port `http`; standbys expose no `cdc_*` series); sink applies string create/update as `SET kv_key body` verbatim (no prefixing); `chart/values-dev.yaml` is the kind overlay (`RRCS_VALUES` default in both verify scripts).
- Reporting rule (`rules/05-invariants.md`): every "done" claim pastes command + exit status.

**Testing strategy note:** these are chaos/infra scripts; true failing-unit-test-first is not applicable. The per-task test cycle is: `bash -n` (syntax), then execution against a live kind deployment with expected output stated. Tasks 3–5 each require the deployment prepared by the Task 3 Step 0 command (run once, reused). Task 7 is the full end-to-end validation gate.

---

### Task 1: `RRCS_SET` hook in the two verify scripts

**Files:**
- Modify: `scripts/verify-cdc.sh` (helm calls at lines 14-15 and 27-30)
- Modify: `scripts/verify-failover.sh` (helm call at lines 71-75)

**Interfaces:**
- Produces: env contract `RRCS_SET="key1=val1 key2=val2"` → each pair appended as `--set key=val` to every helm invocation in both scripts, **after** the script's own `--set` flags. Default empty = zero behavior change. Later tasks rely on `RRCS_SET="connect.image=<tag>"`.

- [ ] **Step 1: Add the parser to both scripts**

In `scripts/verify-cdc.sh`, directly after the existing `VALUES_FILE=` line (line 10), insert:

```bash
# RRCS_SET: optional space-separated key=value pairs appended as extra --set
# flags to every helm invocation (e.g. RRCS_SET="connect.image=repo/img:tag").
# Empty (default) = behavior unchanged.
EXTRA_SET=()
for kv in ${RRCS_SET:-}; do EXTRA_SET+=(--set "$kv"); done
```

In `scripts/verify-failover.sh`, insert the same 5-line block directly after the `REPORT_DIR=` line (line 38).

- [ ] **Step 2: Append the expansion to every helm call**

`scripts/verify-cdc.sh` deploy call becomes:

```bash
helm upgrade --install "${RELEASE}" ./chart -n "${NS}" --create-namespace \
  --set profile=cdc -f "${VALUES_FILE}" "${EXTRA_SET[@]}" --wait --timeout 5m
```

`scripts/verify-cdc.sh` verifier-job render becomes (only the `-f`/`--set` line changes):

```bash
helm template "${RELEASE}" ./chart -n "${NS}" -s templates/verifier-job.yaml \
  -f "${VALUES_FILE}" --set profile=cdc "${EXTRA_SET[@]}" \
  --set verifier.run=true --set "verifier.jobName=${JOB}" --set "verifier.epoch=${EPOCH}" \
  | kubectl apply -n "${NS}" -f -
```

`scripts/verify-failover.sh` helm call becomes:

```bash
  helm upgrade --install "$RELEASE" ./chart -n "$NS" --create-namespace \
    --set profile=cdc -f "$VALUES_FILE" \
    --set "connect.source.consumerClientId=${client_val}" \
    --set "connect.source.maxInFlight=${MAX_IN_FLIGHT}" \
    --set "connect.source.readLimit=${READ_LIMIT}" "${EXTRA_SET[@]}" --wait --timeout 5m
```

(Note: `"${EXTRA_SET[@]}"` with an empty array is safe under `set -u` on bash ≥ 4.4; this repo's scripts already require modern bash.)

- [ ] **Step 3: Syntax check**

Run: `bash -n scripts/verify-cdc.sh && bash -n scripts/verify-failover.sh && echo SYNTAX_OK`
Expected: `SYNTAX_OK`

- [ ] **Step 4: Verify the hook renders (no cluster needed)**

Run:
```bash
RRCS_SET="connect.image=example/x:1" bash -c '
  EXTRA_SET=(); for kv in ${RRCS_SET:-}; do EXTRA_SET+=(--set "$kv"); done
  helm template cdc ./chart -n cdc-k8s --set profile=cdc -f chart/values-dev.yaml "${EXTRA_SET[@]}" \
    | grep -m1 "image: example/x:1"'
```
Expected: one line containing `image: example/x:1` (exit 0).

- [ ] **Step 5: Run the fast tiers (required by INV-4 for script changes)**

Run: `SKIP_L2=1 SKIP_L3=1 scripts/run-all-tests.sh`
Expected: exit 0, L0+L1 pass.

- [ ] **Step 6: Commit**

```bash
git add scripts/verify-cdc.sh scripts/verify-failover.sh
git commit -m "feat(scripts): optional RRCS_SET extra --set hook for verify-cdc/verify-failover

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Lab scaffold — `lib.sh`, `RESEARCH.md`, `README.md`

**Files:**
- Create: `labs/robustness-test/scripts/lib.sh`
- Create: `labs/robustness-test/RESEARCH.md`
- Create: `labs/robustness-test/README.md`

**Interfaces:**
- Produces (sourced by Tasks 3–6): env defaults `NS RELEASE PREFIX CONNECT_IMAGE STREAM`; derived names `CENTRAL REGION SRC_DEPLOY SINK_DEPLOY SRC_LEASE SINK_LEASE`; functions `rc(...)`, `rr(...)`, `holder(lease)`, `now_ms()`, `log(msg)`, `die(msg)` (exit 1), `xadd_batch(runid n keyspace)`, `region_count(runid keyspace)` (echoes int), `wait_region_full(runid keyspace n timeout_s)` (echoes final count), `wait_new_holder(lease old timeout_s)` (echoes new holder or returns 1). Key naming contract: `lb:robust:<keyspace>:{run:<runid>:k<i>}`.

- [ ] **Step 1: Write `labs/robustness-test/scripts/lib.sh`**

```bash
#!/usr/bin/env bash
# lib.sh — shared helpers for labs/robustness-test phases. SOURCED, not executed.
# Callers set -euo pipefail themselves. Oracle style mirrors scripts/verify-failover.sh
# (pure redis-cli membership over kubectl exec).

NS="${RRCS_NS:-cdc-k8s}"
RELEASE="${RRCS_RELEASE:-cdc}"
PREFIX="${RRCS_PREFIX:-lab-}"
CONNECT_IMAGE="${CONNECT_IMAGE:-hpdevelop/connect:v4.92.0-batch-nats}"
STREAM="app.events"

CENTRAL="deploy/${PREFIX}redis-central"
REGION="deploy/${PREFIX}redis-region"
SRC_DEPLOY="deploy/${PREFIX}connect-source"
SINK_DEPLOY="deploy/${PREFIX}connect-sink"
SRC_LEASE="${PREFIX}connect-source-elector"
SINK_LEASE="${PREFIX}connect-sink-elector"

rc() { kubectl -n "$NS" exec -i "$CENTRAL" -- redis-cli "$@"; }
rr() { kubectl -n "$NS" exec -i "$REGION"  -- redis-cli "$@"; }
holder() { kubectl -n "$NS" get lease "$1" -o jsonpath='{.spec.holderIdentity}' 2>/dev/null; }
now_ms() { date +%s%3N; }
log() { echo "[$(basename "$0" .sh)] $*"; }
die() { echo "[$(basename "$0" .sh)] FAIL: $*" >&2; exit 1; }

# xadd_batch <runid> <n> <keyspace> — XADD n valid create events whose region keys
# are lb:robust:<keyspace>:{run:<runid>:k<i>} (same field set verify-failover.sh uses).
xadd_batch() {
  local runid="$1" n="$2" ks="$3" i ts cmds
  ts="$(now_ms)"; cmds="$(mktemp)"
  for (( i=1; i<=n; i++ )); do
    echo "XADD $STREAM * event_id ${ks}-${runid}-${i} op create type string kv_key lb:robust:${ks}:{run:${runid}:k${i}} ts ${ts} body v${i}"
  done > "$cmds"
  kubectl -n "$NS" exec -i "$CENTRAL" -- redis-cli < "$cmds" >/dev/null
  rm -f "$cmds"
}

# region_count <runid> <keyspace> — how many of the batch's keys exist in region KV
region_count() { rr --scan --pattern "lb:robust:${2}:{run:${1}:k*}" 2>/dev/null | grep -c . || true; }

# wait_region_full <runid> <keyspace> <n> <timeout_s> — poll until count>=n or
# timeout; echoes final count. Zero-loss oracle: caller asserts final==n.
# (Deliberately NOT a stability heuristic: redelivery after a kill can stall up
# to ackWait=30s, which a short stable-reads break would misread as loss.)
wait_region_full() {
  local runid="$1" ks="$2" n="$3" timeout="$4" deadline cur=0
  deadline=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < deadline )); do
    cur="$(region_count "$runid" "$ks")"
    (( cur >= n )) && break
    sleep 5
  done
  echo "$cur"
}

# wait_new_holder <lease> <old_holder> <timeout_s> — echoes the new holder, or
# returns 1 on timeout.
wait_new_holder() {
  local lease="$1" old="$2" timeout="$3" deadline h
  deadline=$(( $(date +%s) + timeout ))
  while (( $(date +%s) < deadline )); do
    h="$(holder "$lease")"
    if [[ -n "$h" && "$h" != "$old" ]]; then echo "$h"; return 0; fi
    sleep 2
  done
  return 1
}
```

- [ ] **Step 2: Syntax + source smoke test**

Run:
```bash
bash -n labs/robustness-test/scripts/lib.sh && \
bash -c 'set -euo pipefail; source labs/robustness-test/scripts/lib.sh; \
  [[ "$SINK_LEASE" == "lab-connect-sink-elector" ]] && \
  [[ "$CONNECT_IMAGE" == "hpdevelop/connect:v4.92.0-batch-nats" ]] && echo LIB_OK'
```
Expected: `LIB_OK`

- [ ] **Step 3: Write `labs/robustness-test/RESEARCH.md`**

```markdown
# RESEARCH: robustness validation of hpdevelop/connect:v4.92.0-batch-nats

## Topic
Delivery robustness of a specific Redpanda Connect image variant ("batch-nats") in
this repo's CDC pipeline: central Redis Stream → Connect source leg → NATS
JetStream → Connect sink leg → region Redis KV, with K8s-Lease leader election
(3 replicas per leg, one active leader each).

## Property demonstrated
In a kind cluster running this repo's chart with 3 replicas per Connect leg and
K8s-Lease leader election, `hpdevelop/connect:v4.92.0-batch-nats` loses zero
messages under force-kill of the source-leg leader, the sink-leg leader, and
standby pods (Redis & NATS healthy throughout), and every unprocessable message
increments `cdc_unprocessable{reason}`.

## Essentials (primary sources: this repo)
- Wire format in: `XADD app.events * event_id E op O type T kv_key K ts TS body B`
  (`chart/files/connect/cdc-forward.yaml:64-72`). Consumer group `cdc_propagator`,
  stable client id `cdc_propagator_active` (INV-1 row 2).
- Forward publishes a JSON envelope `{event_id,op,type,kv_key,old_key,new_key,ts,enc,body}`
  to subject `kv.cdc.<op>` on stream `KV_CDC` with `Nats-Msg-Id=event_id`
  (dedup window 5m). Source XACKs only after PubAck (INV-1 row 1).
- Sink binds durable pull consumer `cdc_sink` (`bind: true`), `ackWait 30s`,
  `maxDeliver -1`: unprocessable messages REDELIVER FOREVER by design (INV-1 row 7),
  each redelivery re-incrementing `cdc_unprocessable{reason}` — hence the ≥ oracle
  and the post-assert stream purge in phase 4.
- String create/update applies as `SET kv_key body` verbatim
  (`chart/files/connect/cdc-reverse.yaml:174-179`) → region membership by key scan
  is a valid zero-loss oracle (same oracle as `scripts/verify-failover.sh`).
- `cdc_unprocessable{reason=decode_error}`: `enc=="gzip:base64"` + undecodable body
  (`cdc-reverse.yaml:85-129`). `reason=unknown_op`: op outside
  create/update/delete/rename (`cdc-reverse.yaml:212-218`). Metrics on the leader's
  `:4195/metrics`; standbys expose no `cdc_*` series.
- decode_error is NOT injectable via XADD: the forward leg re-encodes the body per
  `connect.bodyEncoding`, producing a valid encoding. It must be published directly
  to `kv.cdc.create` (nats-box pod + publisher creds Secret, mirroring the
  nats-init Job pattern in `chart/templates/nats-init-job.yaml`).

## Design decisions
- Thin bash orchestrator reusing `verify-cdc.sh` (phase 0) and `verify-failover.sh`
  (phase 1, A/B canary kept so a pass is proven non-vacuous) via the additive
  `RRCS_SET` env hook; new bash only for sink-leader kill, standby kill, poison
  metrics. Rejected: standalone rebuild (duplicates ~800 proven lines); extending
  verify-failover.sh in place (mixes image-validation into an invariant-guarded
  config-validation script).
- Zero-loss oracle: wait until region has ALL N keys (up to timeout), not
  "count stopped growing" — redelivery stalls up to ackWait would fake a plateau.
- Phase order matters: poison (phase 4) runs LAST because it ends with a KV_CDC
  purge; earlier phases' traffic has fully settled by then.

## Deliberately excluded (and why)
- Redis/NATS outage or restart tolerance — the request explicitly conditions on
  both staying healthy.
- Cross-key reordering — accepted non-guarantee (`rules/05-invariants.md` INV-1).
- Throughput/latency of the batch-nats image — delivery + metrics only.
- Grafana/alert visual verification — metric-level assertion; alert wiring is
  already covered by `labs/redis-cdc-error-alerting` (L2).
```

- [ ] **Step 4: Write `labs/robustness-test/README.md`**

```markdown
# labs/robustness-test — image robustness validation in kind

Proves `hpdevelop/connect:v4.92.0-batch-nats` (override: `CONNECT_IMAGE=...`)
against the two requirements in `docs/labs/robustness-test/request.md`:
zero message loss under pod force-kill (3 replicas/leg + Lease leader election,
Redis & NATS healthy), and unprocessable-message counting in metrics.

## Prerequisites
- kind cluster (default name `cdc`): `kind get clusters | grep -qx cdc || kind create cluster --name cdc`
- The target image present in the local docker store: `docker image inspect "$CONNECT_IMAGE"`
- `helm`, `kubectl`, `jq`, `docker` on PATH. Everything runs in containers/the
  kind cluster; no host changes.

## Run

    labs/robustness-test/scripts/verify-robustness.sh

Phases (~35 min total):
0. Load images into kind; deploy with `connect.image=$CONNECT_IMAGE`; e2e
   correctness via `scripts/verify-cdc.sh` (verifier verdict.pass).
1. A/B failover canary via `scripts/verify-failover.sh`: baseline (pod-scoped
   consumer id) MUST lose on source-leader SIGKILL — proves the harness detects
   loss — then the real config MUST NOT. Retried up to 2× on INCONCLUSIVE (rc 3).
2. Sink-leader SIGKILL mid-flight → new Lease holder + region has all N keys.
3. Standby SIGKILL (one per leg) during traffic → leadership unchanged + all N keys.
4. Poison: 5× unknown_op (XADD) + 5× decode_error (direct NATS publish) →
   `cdc_unprocessable{reason=...}` ≥ +5 per reason on the sink leader's
   `:4195/metrics`; then `nats stream purge KV_CDC` and a 100-key good-traffic
   sanity proves recovery. (≥, not ==: poison redelivers forever by design.)

Exit 0 iff all phases pass. Per-run artifacts: `labs/robustness-test/reports/<ts>/`
(`report.json`, `report.md`, per-phase logs) — gitignored.

## Env knobs
`CONNECT_IMAGE`, `KIND_NAME`, `RRCS_NS`, `RRCS_RELEASE`, `RRCS_PREFIX`,
`N_SINKKILL` (default 5000), `N_STANDBY` (2000), `N_POISON` (5),
`SINK_TIMEOUT_S` (300), `FAILOVER_TIMEOUT_S` (120).

## Interpreting failures
- Phase 1 baseline "expected loss but region has all keys" → INCONCLUSIVE
  (mistimed kill), rerun; NOT an image defect.
- Phase 2/4 assertion failures with healthy Redis/NATS → image fails the
  requirement; capture `reports/<ts>/` and the pod logs it saves.
```

- [ ] **Step 5: Commit**

```bash
git add labs/robustness-test/
git commit -m "feat(labs): robustness-test scaffold — lib.sh, RESEARCH.md, README

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Phase 2 script — `kill-sink-leader.sh`

**Files:**
- Create: `labs/robustness-test/scripts/kill-sink-leader.sh`

**Interfaces:**
- Consumes: everything from `lib.sh` (Task 2 Produces list).
- Produces: exit 0 = pass, 1 = fail, **3 = inconclusive (retryable)**; final line `[kill-sink-leader] PASS — zero loss after sink-leader SIGKILL (N=<n>)` on success. Env: `N_SINKKILL`, `SINK_TIMEOUT_S`, `FAILOVER_TIMEOUT_S`.

- [ ] **Step 0 (once, reused by Tasks 4–5): prepare a default-config deployment with the target image**

```bash
scripts/build-images.sh --kind --kind-name=cdc
docker image inspect hpdevelop/connect:v4.92.0-batch-nats >/dev/null
kind load docker-image hpdevelop/connect:v4.92.0-batch-nats --name cdc
helm upgrade --install cdc ./chart -n cdc-k8s --create-namespace \
  --set profile=cdc -f chart/values-dev.yaml \
  --set connect.image=hpdevelop/connect:v4.92.0-batch-nats --wait --timeout 5m
kubectl -n cdc-k8s rollout status deploy/lab-connect-source deploy/lab-connect-sink --timeout=180s
```
Expected: helm exits 0, both rollouts complete.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# kill-sink-leader.sh — phase 2: force-kill the SINK-leg leader while messages
# are in flight; assert a new Lease holder appears and region KV ends with ALL
# N keys (zero loss; JetStream ackWait redelivery covers the killed pod's
# un-acked batch). Exit 0 pass / 1 fail / 3 inconclusive (retry).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

N="${N_SINKKILL:-5000}"
SINK_TIMEOUT_S="${SINK_TIMEOUT_S:-300}"
FAILOVER_TIMEOUT_S="${FAILOVER_TIMEOUT_S:-120}"

runid="$(now_ms)"
h="$(holder "$SINK_LEASE")"; [[ -n "$h" ]] || die "no sink lease holder"
log "sink leader: $h; producing N=$N (runid=$runid)"
xadd_batch "$runid" "$N" sinkkill

# Arm: kill only while the sink is mid-flight (some but not all keys applied).
deadline=$(( $(date +%s) + FAILOVER_TIMEOUT_S ))
cur=0
while :; do
  cur="$(region_count "$runid" sinkkill)"
  (( cur > 0 )) && break
  (( $(date +%s) < deadline )) || die "sink applied nothing within ${FAILOVER_TIMEOUT_S}s"
  sleep 1
done
(( cur < N )) || { log "INCONCLUSIVE: sink finished all $N before the kill — raise N_SINKKILL"; exit 3; }
[[ "$(holder "$SINK_LEASE")" == "$h" ]] || { log "INCONCLUSIVE: sink leadership moved before kill"; exit 3; }

log "SIGKILL sink leader $h at region_count=${cur}/${N}"
kubectl -n "$NS" delete pod "$h" --grace-period=0 --force >/dev/null 2>&1 || true

nh="$(wait_new_holder "$SINK_LEASE" "$h" "$FAILOVER_TIMEOUT_S")" || die "no new sink lease holder within ${FAILOVER_TIMEOUT_S}s"
log "new sink leader: $nh"

final="$(wait_region_full "$runid" sinkkill "$N" "$SINK_TIMEOUT_S")"
loss=$(( N - final ))
log "region has ${final}/${N} keys (loss=${loss})"
(( loss == 0 )) || die "lost ${loss} messages after sink-leader SIGKILL"
log "PASS — zero loss after sink-leader SIGKILL (N=${N})"
```

- [ ] **Step 2: Syntax check**

Run: `bash -n labs/robustness-test/scripts/kill-sink-leader.sh && chmod +x labs/robustness-test/scripts/*.sh && echo OK`
Expected: `OK`

- [ ] **Step 3: Run against the prepared deployment**

Run: `labs/robustness-test/scripts/kill-sink-leader.sh; echo "exit=$?"`
Expected: log lines showing leader, kill at `region_count=<0<x<5000>/5000`, a NEW holder, then `PASS — zero loss after sink-leader SIGKILL (N=5000)`, `exit=0`. If `exit=3` (kill mistimed), rerun once with `N_SINKKILL=20000`.

- [ ] **Step 4: Commit**

```bash
git add labs/robustness-test/scripts/kill-sink-leader.sh
git commit -m "feat(labs): robustness-test phase 2 — sink-leader SIGKILL zero-loss proof

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Phase 3 script — `kill-standby.sh`

**Files:**
- Create: `labs/robustness-test/scripts/kill-standby.sh`

**Interfaces:**
- Consumes: `lib.sh`.
- Produces: exit 0/1 (no inconclusive path); final line `[kill-standby] PASS — zero loss, leadership stable after standby SIGKILL (N=<n>)`. Env: `N_STANDBY`, `SINK_TIMEOUT_S`.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# kill-standby.sh — phase 3 (control): force-kill one NON-leader pod on each
# Connect leg during traffic; assert both Lease holders are unchanged and the
# region ends with ALL N keys.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

N="${N_STANDBY:-2000}"
SINK_TIMEOUT_S="${SINK_TIMEOUT_S:-300}"

runid="$(now_ms)"
hs="$(holder "$SRC_LEASE")";  [[ -n "$hs" ]] || die "no source lease holder"
hk="$(holder "$SINK_LEASE")"; [[ -n "$hk" ]] || die "no sink lease holder"

# standby_of <deploy-basename> <holder> — any pod of that leg that is not the holder
standby_of() {
  kubectl -n "$NS" get pods -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' \
    | grep "^${PREFIX}$1-" | grep -vx "$2" | head -1
}
ss="$(standby_of connect-source "$hs")"; [[ -n "$ss" ]] || die "no source standby pod found"
sk="$(standby_of connect-sink "$hk")";   [[ -n "$sk" ]] || die "no sink standby pod found"

log "leaders src=$hs sink=$hk; killing standbys src=$ss sink=$sk during N=$N traffic (runid=$runid)"
xadd_batch "$runid" "$N" standby &
XPID=$!
kubectl -n "$NS" delete pod "$ss" "$sk" --grace-period=0 --force >/dev/null 2>&1 || true
wait "$XPID"

sleep 5
[[ "$(holder "$SRC_LEASE")" == "$hs" ]] || die "source leadership moved after standby kill (was $hs, now $(holder "$SRC_LEASE"))"
[[ "$(holder "$SINK_LEASE")" == "$hk" ]] || die "sink leadership moved after standby kill (was $hk, now $(holder "$SINK_LEASE"))"

final="$(wait_region_full "$runid" standby "$N" "$SINK_TIMEOUT_S")"
loss=$(( N - final ))
log "region has ${final}/${N} keys (loss=${loss})"
(( loss == 0 )) || die "lost ${loss} messages after standby SIGKILL"
log "PASS — zero loss, leadership stable after standby SIGKILL (N=${N})"
```

- [ ] **Step 2: Syntax check**

Run: `bash -n labs/robustness-test/scripts/kill-standby.sh && chmod +x labs/robustness-test/scripts/kill-standby.sh && echo OK`
Expected: `OK`

- [ ] **Step 3: Run against the prepared deployment**

Run: `labs/robustness-test/scripts/kill-standby.sh; echo "exit=$?"`
Expected: names of two killed standbys, unchanged holders, `PASS — zero loss, leadership stable after standby SIGKILL (N=2000)`, `exit=0`.

- [ ] **Step 4: Commit**

```bash
git add labs/robustness-test/scripts/kill-standby.sh
git commit -m "feat(labs): robustness-test phase 3 — standby SIGKILL control, zero loss

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Phase 4 script — `poison-metrics.sh`

**Files:**
- Create: `labs/robustness-test/scripts/poison-metrics.sh`

**Interfaces:**
- Consumes: `lib.sh`.
- Produces: exit 0/1/3 (3 = sink leadership changed mid-phase); final line `[poison-metrics] PASS — cdc_unprocessable counted both reasons (unknown_op +<u>, decode_error +<d>) and good traffic recovered`. Env: `N_POISON` (default 5), `LOCAL_METRICS_PORT` (default 15195).

- [ ] **Step 1: Write the script**

```bash
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
```

- [ ] **Step 2: Syntax check**

Run: `bash -n labs/robustness-test/scripts/poison-metrics.sh && chmod +x labs/robustness-test/scripts/poison-metrics.sh && echo OK`
Expected: `OK`

- [ ] **Step 3: Verify the Secret/Service names the script assumes**

Run: `kubectl -n cdc-k8s get secret lab-publisher-creds lab-admin-creds -o name && kubectl -n cdc-k8s get svc lab-nats -o name`
Expected: three resource names, exit 0. **If any is missing**, find the real names (`kubectl -n cdc-k8s get secret,svc | grep -E 'creds|nats'`) and fix the script's `secretName`/`NATS_SERVER` derivations — do not proceed with guesses.

- [ ] **Step 4: Run against the prepared deployment**

Run: `labs/robustness-test/scripts/poison-metrics.sh; echo "exit=$?"`
Expected: baseline line, injected line, `deltas: unknown_op +5 decode_error +5 (>= 5 each)` (or higher after a redelivery), purge, `PASS — … good traffic recovered`, `exit=0`. Also verify cleanup: `kubectl -n cdc-k8s get pod robust-poison-pub` → NotFound.

- [ ] **Step 5: Commit**

```bash
git add labs/robustness-test/scripts/poison-metrics.sh
git commit -m "feat(labs): robustness-test phase 4 — poison injection proves cdc_unprocessable

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Entrypoint — `verify-robustness.sh`

**Files:**
- Create: `labs/robustness-test/scripts/verify-robustness.sh`

**Interfaces:**
- Consumes: `lib.sh`; `scripts/verify-cdc.sh` + `scripts/verify-failover.sh` with `RRCS_SET` (Task 1); phase scripts (Tasks 3–5) incl. their exit-3 inconclusive contract.
- Produces: exit 0 iff all phases pass; `reports/<ts>/report.json` shape `{image, digest, started, phases: {p0_e2e|p1_failover_ab|p2_sink_leader_kill|p3_standby_kill|p4_poison_metrics: "PASS"|"FAIL"|"INCONCLUSIVE"}, pass: bool}` + `report.md` + per-phase logs.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# verify-robustness.sh — single entrypoint. Validates CONNECT_IMAGE (default
# hpdevelop/connect:v4.92.0-batch-nats) in kind against the two requirements in
# docs/labs/robustness-test/request.md. Phases:
#   0 e2e correctness      (scripts/verify-cdc.sh, RRCS_SET image override)
#   1 A/B failover canary  (scripts/verify-failover.sh; retried on rc=3, max 2)
#   2 sink-leader SIGKILL  (kill-sink-leader.sh; retried on rc=3, max 2)
#   3 standby SIGKILL      (kill-standby.sh)
#   4 poison metrics       (poison-metrics.sh)
# Exit 0 iff every phase PASSes. Artifacts: labs/robustness-test/reports/<ts>/.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_DIR="$(cd "${LAB_DIR}/../.." && pwd)"
source "${SCRIPT_DIR}/lib.sh"

KIND_NAME="${KIND_NAME:-cdc}"
export RRCS_NS="$NS" RRCS_RELEASE="$RELEASE" RRCS_PREFIX="$PREFIX"
export RRCS_SET="connect.image=${CONNECT_IMAGE}"
RUN_TS="$(date +%Y%m%d-%H%M%S)"
OUT="${LAB_DIR}/reports/${RUN_TS}"
mkdir -p "$OUT"
declare -A VERDICT
ORDER=(p0_e2e p1_failover_ab p2_sink_leader_kill p3_standby_kill p4_poison_metrics)

log() { echo "[robustness] $*"; }

# run_phase <name> <retries-on-rc3> <cmd...>
run_phase() {
  local name="$1" retries="$2"; shift 2
  local attempt rc
  for (( attempt=0; attempt<=retries; attempt++ )); do
    log "=== ${name} (attempt $((attempt+1))) ==="
    rc=0; "$@" 2>&1 | tee "${OUT}/${name}.attempt$((attempt+1)).log" || rc=${PIPESTATUS[0]}
    if (( rc == 0 )); then VERDICT[$name]=PASS; return 0; fi
    if (( rc == 3 && attempt < retries )); then log "${name} INCONCLUSIVE (rc=3) — retrying"; continue; fi
    VERDICT[$name]=$([[ $rc == 3 ]] && echo INCONCLUSIVE || echo FAIL)
    return 1
  done
}

finish() {
  local pass=true k
  for k in "${ORDER[@]}"; do [[ "${VERDICT[$k]:-SKIPPED}" == "PASS" ]] || pass=false; done
  local digest
  digest="$(docker image inspect -f '{{if .RepoDigests}}{{index .RepoDigests 0}}{{else}}{{.Id}}{{end}}' "$CONNECT_IMAGE" 2>/dev/null || echo unknown)"
  {
    echo "{"
    echo "  \"image\": \"${CONNECT_IMAGE}\", \"digest\": \"${digest}\", \"started\": \"${RUN_TS}\","
    echo "  \"phases\": {"
    local first=1
    for k in "${ORDER[@]}"; do
      (( first )) || echo ","; first=0
      printf '    "%s": "%s"' "$k" "${VERDICT[$k]:-SKIPPED}"
    done
    echo ""
    echo "  },"
    echo "  \"pass\": ${pass}"
    echo "}"
  } > "${OUT}/report.json"
  {
    echo "# robustness-test report ${RUN_TS}"
    echo ""
    echo "Image: \`${CONNECT_IMAGE}\` (${digest})"
    echo ""
    echo "| Phase | Verdict |"
    echo "|---|---|"
    for k in "${ORDER[@]}"; do echo "| ${k} | ${VERDICT[$k]:-SKIPPED} |"; done
    echo ""
    echo "Overall: $($pass && echo PASS || echo FAIL)"
  } > "${OUT}/report.md"
  jq . "${OUT}/report.json" >/dev/null   # self-check the JSON is valid
  log "report: ${OUT}/report.md"
  $pass && { log "OVERALL PASS"; exit 0; } || { log "OVERALL FAIL"; exit 1; }
}
trap finish EXIT

cd "$REPO_DIR"

# Preflight
docker image inspect "$CONNECT_IMAGE" >/dev/null 2>&1 || { echo "[robustness] FAIL: image ${CONNECT_IMAGE} not in local docker store" >&2; exit 1; }
kind get clusters 2>/dev/null | grep -qx "$KIND_NAME"  || { echo "[robustness] FAIL: kind cluster '${KIND_NAME}' not found (kind create cluster --name ${KIND_NAME})" >&2; exit 1; }
log "loading images into kind '${KIND_NAME}'"
scripts/build-images.sh --kind --kind-name="$KIND_NAME" >"${OUT}/build-images.log" 2>&1
kind load docker-image "$CONNECT_IMAGE" --name "$KIND_NAME" >>"${OUT}/build-images.log" 2>&1

run_phase p0_e2e 0 scripts/verify-cdc.sh || exit 1
run_phase p1_failover_ab 2 scripts/verify-failover.sh || exit 1

# verify-failover leaves source overrides (maxInFlight=1, readLimit=2000) in the
# release — restore default config (still with the target image) before phases 2-4.
log "restoring default config with connect.image=${CONNECT_IMAGE}"
helm upgrade --install "$RELEASE" ./chart -n "$NS" \
  --set profile=cdc -f chart/values-dev.yaml \
  --set "connect.image=${CONNECT_IMAGE}" --wait --timeout 5m >"${OUT}/redeploy.log" 2>&1
kubectl -n "$NS" rollout status "$SRC_DEPLOY" "$SINK_DEPLOY" --timeout=180s >>"${OUT}/redeploy.log" 2>&1

run_phase p2_sink_leader_kill 2 "${SCRIPT_DIR}/kill-sink-leader.sh" || exit 1
run_phase p3_standby_kill 0 "${SCRIPT_DIR}/kill-standby.sh" || exit 1
run_phase p4_poison_metrics 1 "${SCRIPT_DIR}/poison-metrics.sh" || exit 1
```

(Note: `finish` runs via the EXIT trap, so every path — including early `exit 1` — writes the report; final exit code comes from `finish`.)

- [ ] **Step 2: Syntax check**

Run: `bash -n labs/robustness-test/scripts/verify-robustness.sh && chmod +x labs/robustness-test/scripts/verify-robustness.sh && echo OK`
Expected: `OK`

- [ ] **Step 3: Preflight-failure behavior (cheap negative test)**

Run: `CONNECT_IMAGE=nonexistent/img:0 labs/robustness-test/scripts/verify-robustness.sh; echo "exit=$?"`
Expected: `FAIL: image nonexistent/img:0 not in local docker store`, a report.md with all phases `SKIPPED` and `Overall: FAIL`, `exit=1`.

- [ ] **Step 4: Commit**

```bash
git add labs/robustness-test/scripts/verify-robustness.sh
git commit -m "feat(labs): robustness-test entrypoint — 5-phase orchestration + report

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: Full validation run (the lab's Stage-5 gate)

**Files:**
- Modify: `labs/robustness-test/README.md` (record observed runtime)

- [ ] **Step 1: Clean slate**

Run: `helm uninstall cdc -n cdc-k8s --ignore-not-found && kubectl delete ns cdc-k8s --ignore-not-found --wait=true`
Expected: namespace gone.

- [ ] **Step 2: Full run**

Run: `time labs/robustness-test/scripts/verify-robustness.sh; echo "exit=$?"`
Expected: all five phases `PASS` in `reports/<ts>/report.md`, final `OVERALL PASS`, `exit=0`, wall time ≈ 30–40 min. On any failure: apply `superpowers:systematic-debugging` after 3 attempts on the same root cause; NEVER weaken an oracle (no `>=`→existence, no timeout inflation beyond documented redelivery math) to make it pass.

- [ ] **Step 3: Verify no leftovers**

Run: `kubectl -n cdc-k8s get pods | grep -v Running; kubectl -n cdc-k8s get pod robust-poison-pub 2>&1 | tail -1; git status --porcelain labs/ scripts/`
Expected: no crash-looping pods, poison pod NotFound, git shows only intended files (reports/ is ignored).

- [ ] **Step 4: Update README with the observed runtime and commit**

Replace the `(~35 min total)` phase-list line in `labs/robustness-test/README.md` with the measured time, then:

```bash
git add labs/robustness-test/README.md
git commit -m "docs(labs): robustness-test — record measured runtime

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

- [ ] **Step 5: Report per the invariants reporting rule**

Paste in the final summary: the exact `verify-robustness.sh` command, its exit status, the report.md table, and the `RESULT_JSON`/`[verify-cdc] PASS` + `[failover] PASS` lines from the phase logs.

---

## Self-review (done at plan-writing time)

- **Spec coverage:** phase table 0–4 → Tasks 3–6 + reuse via Task 1; RRCS_SET mechanism → Task 1; RESEARCH.md/README → Task 2; report artifacts → Task 6; "distinguish image-fails from harness-inconclusive" → exit-3 contract + README §Interpreting failures; poison-oracle amendment (≥ + purge + NATS-direct decode_error) → Task 5. Gap check: none found.
- **Placeholder scan:** all steps carry complete code/commands; the only conditional instruction (Task 5 Step 3 name verification) states exactly how to resolve it.
- **Consistency:** function names (`xadd_batch`, `region_count`, `wait_region_full`, `wait_new_holder`, `holder`, `metric_sum`) and env names (`N_SINKKILL`, `N_STANDBY`, `N_POISON`, `SINK_TIMEOUT_S`, `FAILOVER_TIMEOUT_S`, `LOCAL_METRICS_PORT`, `RRCS_SET`, `CONNECT_IMAGE`, `KIND_NAME`) match across Tasks 2–6 and the README.
