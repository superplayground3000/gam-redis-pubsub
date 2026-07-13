# Hash-decode Guard + Dead-Letter Queue — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in dead-letter queue so permanently-unprocessable sink messages (including malformed `type=hash` bodies) are counted, published to a sibling stream subject, and acked (loop stops) instead of silently redelivering forever.

**Architecture:** All changes are gated behind a new `connect.deadLetter.enabled` toggle (default `false`, keeping the default render byte-identical). When enabled: the reverse pipeline validates hash JSON up front (`hash_decode_error`), and the three permanent-failure branches (`decode_error`, `unknown_op`, `hash_decode_error`) set DLQ metadata instead of throwing; the output becomes `reject_errored → switch → nats_jetstream(dlq.cdc.<reason>)`, giving write-then-ack (ack only after the DLQ PubAck, nack if it fails). The DLQ subject is a second binding (`dlq.cdc.>`) on the same `KV_CDC` stream, filtered by no sink consumer.

**Tech Stack:** Helm templates, Redpanda Connect (Bloblang, `nats_jetstream`/`reject_errored`/`switch` outputs), NATS JetStream + `nsc` creds, Prometheus/Grafana JSON, docker-compose L2 lab, kind L3/L4 verifiers.

## Global Constraints

- **Byte-identical default render:** `helm template chart/` (no `--set`) MUST be unchanged by this work. Every change is inside `{{- if .Values.connect.deadLetter.enabled }}`. The L1 default-render check is the gate.
- **INV-1 (at-least-once):** a message is acked only after its region-Redis write OR its DLQ PubAck succeeds. DLQ publish failure MUST nack (retry). Never `drop` a message that hasn't been durably written somewhere. Editing the reverse output topology (INV-1 rows 7–8) requires **L1 + L3 + L4**.
- **INV-2 (visibility):** every permanent-failure branch increments `cdc_unprocessable{reason=...}`; any metric added ships with a dashboard panel in the same change.
- **INV-3 (toggles):** the feature ships with the `connect.deadLetter.enabled` toggle; disabled emits none of its objects/branches.
- **INV-4 (verify):** paste command + exit status + result line for every ladder level run. Never claim a level passed without running it this session.
- **DLQ subject rule:** `connect.deadLetter.subject` MUST NOT start with `nats.stream.subjectPrefix` (`kv.cdc`) — else a whole-stream consumer re-consumes it. Enforced fail-loud at render.
- **Reasons:** exactly three — `decode_error`, `unknown_op`, `hash_decode_error`.
- **Spec:** `docs/superpowers/specs/2026-07-13-hash-decode-dlq-design.md`.

---

### Task 1: Config surface — values + helpers

**Files:**
- Modify: `chart/values.yaml` (add `connect.deadLetter` block after `connect.contentLog`)
- Modify: `chart/templates/_helpers.tpl` (`rrcs.nats.stream.subjects` line 240–243; add validation + a `rrcs.connect.deadLetter.subject` helper)
- Test: `scripts/run-all-tests.sh` (L1 loop)

**Interfaces:**
- Produces: values `connect.deadLetter.enabled` (bool), `connect.deadLetter.subject` (string, default `dlq.cdc`).
- Produces: `rrcs.nats.stream.subjects` now returns `kv.cdc.>,dlq.cdc.>` when enabled, `kv.cdc.>` when disabled.
- Produces: fail-loud when `deadLetter.enabled` and `deadLetter.subject` starts with `<subjectPrefix>.`/equals it.

- [ ] **Step 1: Add the failing L1 assertion**

In `scripts/run-all-tests.sh`, after the existing `DEFAULT_OUT=$(helm template chart/)` capture (line ~42), add:

```bash
# --- deadLetter (DLQ) render checks ---
DLQ_OUT=$(helm template chart/ --set connect.deadLetter.enabled=true) || fail L1
grep -q 'kv.cdc.>,dlq.cdc.>' <<<"$DLQ_OUT" \
  || { echo "L1: DLQ enabled must extend stream subjects to kv.cdc.>,dlq.cdc.>"; fail L1; }
if grep -q 'dlq.cdc' <<<"$DEFAULT_OUT"; then echo "L1: default render must not mention dlq"; fail L1; fi
# fail-loud: subject under kv.cdc must be rejected
if helm template chart/ --set connect.deadLetter.enabled=true --set connect.deadLetter.subject=kv.cdc.dlq >/dev/null 2>&1; then
  echo "L1: deadLetter.subject under subjectPrefix must fail-loud"; fail L1
fi
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash scripts/run-all-tests.sh 2>&1 | sed -n '1,60p'` (or isolate L1)
Expected: FAIL at the DLQ subjects check (`connect.deadLetter` not defined yet → subjects unchanged).

- [ ] **Step 3: Add the values block**

In `chart/values.yaml`, immediately after the `connect.contentLog:` block (around line 139–141), add:

```yaml
  # Dead-letter queue (opt-in). When enabled, sink messages that can NEVER be
  # applied (decode_error / unknown_op / hash_decode_error) are published to a
  # sibling subject on the SAME JetStream stream and then acked (write-then-ack),
  # instead of nacking + redelivering forever (which head-of-line-blocks the ack
  # floor). Disabled => render is byte-identical to pre-DLQ and poison redelivers
  # forever as before. Subject MUST be outside nats.stream.subjectPrefix so no
  # sink consumer re-consumes it (fail-loud otherwise).
  deadLetter:
    enabled: false
    subject: "dlq.cdc"      # published per-reason as <subject>.<reason>; stream binds <subject>.>
```

- [ ] **Step 4: Extend the stream-subjects helper + add validation**

In `chart/templates/_helpers.tpl`, replace the `rrcs.nats.stream.subjects` define (lines 240–243) with:

```gotemplate
{{- define "rrcs.nats.stream.subjects" -}}
{{- $p := required "nats.stream.subjectPrefix is required" .Values.nats.stream.subjectPrefix -}}
{{- $dl := .Values.connect.deadLetter | default dict -}}
{{- if $dl.enabled -}}
{{-   $sub := required "connect.deadLetter.subject is required when deadLetter.enabled" $dl.subject -}}
{{-   if or (eq $sub $p) (hasPrefix (printf "%s." $p) $sub) -}}
{{-     fail (printf "connect.deadLetter.subject %q must be OUTSIDE nats.stream.subjectPrefix %q — a subject under %s.> would be re-consumed by a whole-stream sink. Use e.g. dlq.cdc." $sub $p $p) -}}
{{-   end -}}
{{-   printf "%s.>,%s.>" $p $sub -}}
{{- else -}}
{{-   printf "%s.>" $p -}}
{{- end -}}
{{- end -}}
```

- [ ] **Step 5: Run the L1 checks to verify they pass**

Run: `bash scripts/run-all-tests.sh 2>&1 | grep -E 'L1|deadLetter|DLQ|PASS|FAIL' | head`
Expected: L1 passes; default render has no `dlq`, enabled render has `kv.cdc.>,dlq.cdc.>`, bad subject fails-loud.

- [ ] **Step 6: Confirm default render is byte-identical to master**

Do NOT use `git stash` (the stash stack is shared across worktrees here). Render master via a throwaway worktree and diff:

```bash
git worktree add -q /tmp/mst master
helm template /tmp/mst/chart > /tmp/mst.yaml
helm template chart/            > /tmp/now.yaml
diff /tmp/mst.yaml /tmp/now.yaml && echo "DEFAULT BYTE-IDENTICAL"
git worktree remove -f /tmp/mst
```
Expected: `DEFAULT BYTE-IDENTICAL` (no diff). Keep `/tmp/mst.yaml` for the Task 2 re-check.

- [ ] **Step 7: Commit**

```bash
git add chart/values.yaml chart/templates/_helpers.tpl scripts/run-all-tests.sh
git commit -m "feat(dlq): add connect.deadLetter toggle + sibling stream subject

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Reverse pipeline — hash guard + DLQ output (INV-1/INV-2 load-bearing)

**Files:**
- Modify: `chart/files/connect/cdc-reverse.yaml` (mapping guard ~after line 98; switch branches lines 119–218; output lines 220–223)
- Test: `scripts/run-all-tests.sh` (L1 loop)

**Interfaces:**
- Consumes: `connect.deadLetter.enabled` (Task 1).
- Produces (metadata, enabled only): `meta hash_decode_failed`, `meta dlq`, `meta dlq_reason`, `meta dlq_error`.
- Produces: metric `cdc_unprocessable{reason=hash_decode_error}`; metric `cdc_dlq_forwarded{reason}`.
- Produces: output `reject_errored → switch(dlq==yes → nats_jetstream(<subject>.<reason>) | drop)`.

> **Atomicity:** guard + output land in ONE commit. A half-state where `meta dlq` is set but the output still `drop`s would ack a message that was neither applied nor DLQ'd — data loss. Do not split.

- [ ] **Step 1: Add the failing L1 assertions**

In `scripts/run-all-tests.sh`, extend the DLQ block from Task 1 with:

```bash
grep -q 'reason: hash_decode_error' <<<"$DLQ_OUT" || { echo "L1: missing hash_decode_error counter"; fail L1; }
grep -q 'cdc_dlq_forwarded'        <<<"$DLQ_OUT" || { echo "L1: missing cdc_dlq_forwarded counter"; fail L1; }
grep -q 'hash_decode_failed'       <<<"$DLQ_OUT" || { echo "L1: missing hash guard"; fail L1; }
# enabled output must route via nats_jetstream to the dlq subject
awk '/^output:/{o=1} o' <<<"$DLQ_OUT" | grep -q 'dlq.cdc' || { echo "L1: DLQ output subject missing"; fail L1; }
# default output must stay reject_errored: drop (byte-identical guard covers full render)
grep -q 'reason: hash_decode_error' <<<"$DEFAULT_OUT" && { echo "L1: hash guard leaked into default"; fail L1; } || true
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash scripts/run-all-tests.sh 2>&1 | grep -E 'L1|hash_decode|dlq' | head`
Expected: FAIL — `hash_decode_error`/`cdc_dlq_forwarded`/`hash_decode_failed` absent.

- [ ] **Step 3: Add the hash guard to the mapping stage**

In `chart/files/connect/cdc-reverse.yaml`, immediately after the `meta decode_failed = ...` line (line 98), add:

```gotemplate
    {{- if .Values.connect.deadLetter.enabled }}
        # DLQ guard: hash bodies must be a valid JSON OBJECT for the HSET args_mapping
        # below. Validate up front so a malformed body is COUNTED
        # (cdc_unprocessable{reason=hash_decode_error}) and dead-lettered, instead of
        # throwing UN-COUNTED inside the HSET args_mapping (silent poison loop). Only
        # checked for create/update hash bodies that decoded OK.
        let hash_body_ok = if (this.op == "create" || this.op == "update") && this.type.or("string") == "hash" && meta("decode_failed") == "no" {
          $decoded.parse_json().catch(null) != null
        } else { true }
        meta hash_decode_failed = if $hash_body_ok { "no" } else { "yes" }
    {{- end }}
```

- [ ] **Step 4: Convert the poison branches to set DLQ meta (enabled) or throw (disabled)**

In the `switch` (lines 119–218), replace the `decode_failed` branch's final `mapping` (line 129) so it reads:

```gotemplate
            {{- if .Values.connect.deadLetter.enabled }}
            - mapping: |
                meta dlq        = "yes"
                meta dlq_reason = "decode_error"
                meta dlq_error  = "undecodable gzip:base64 body for kv_key %s".format(meta("kv_key").or("?"))
            {{- else }}
            - mapping: 'root = throw("decode_error: undecodable gzip:base64 body for kv_key %s".format(meta("kv_key").or("?")))'
            {{- end }}
```

Immediately AFTER the `decode_failed` branch (before the `create || update` branch at line 130), add the new hash branch:

```gotemplate
    {{- if .Values.connect.deadLetter.enabled }}
        - check: meta("hash_decode_failed") == "yes"
          processors:
            - metric:
                type: counter
                name: cdc_unprocessable
                labels:
                  reason: hash_decode_error
            - mapping: |
                meta dlq        = "yes"
                meta dlq_reason = "hash_decode_error"
                meta dlq_error  = "hash body is not valid JSON for kv_key %s".format(meta("kv_key").or("?"))
    {{- end }}
```

Replace the final `unknown_op` branch's `mapping` (line 218) so it reads:

```gotemplate
            {{- if .Values.connect.deadLetter.enabled }}
            - mapping: |
                meta dlq        = "yes"
                meta dlq_reason = "unknown_op"
                meta dlq_error  = "unknown op: %s".format(meta("op").or("missing"))
            {{- else }}
            - mapping: 'root = throw("unknown op: %s".format(meta("op").or("missing")))'
            {{- end }}
```

- [ ] **Step 5: Restructure the output**

Replace the output block (lines 220–223) with:

```gotemplate
output:
{{- if .Values.connect.deadLetter.enabled }}
  # DLQ enabled: applied messages -> drop (ack). Permanent poison (dlq==yes) ->
  # publish to <deadLetter.subject>.<reason> on the same stream, THEN ack (the
  # nats_jetstream send is the write; a send failure surfaces as an output error so
  # reject_errored nacks -> retry = write-then-ack, INV-1 preserved). Transient apply
  # failures still error -> reject_errored -> nack -> redelivery.
  reject_errored:
    switch:
      cases:
        - check: meta("dlq") == "yes"
          output:
            label: dlq_out
            nats_jetstream:
              urls:
                - "{{ include "rrcs.nats.url" . }}"
              auth:
                user_credentials_file: {{ .Values.nats.auth.creds.subscriber | quote }}
              subject: '{{ .Values.connect.deadLetter.subject }}.${! meta("dlq_reason") }'
              headers:
                Nats-Msg-Id: ${! meta("event_id") }
                dlq_reason: ${! meta("dlq_reason") }
                dlq_error: ${! meta("dlq_error") }
                dlq_orig_subject: ${! meta("nats_subject") }
          processors:
            # per-delivery count of messages routed to the DLQ (INV-2 visibility).
            - metric:
                type: counter
                name: cdc_dlq_forwarded
                labels:
                  reason: '${! meta("dlq_reason") }'
        - output:
            drop: {}
{{- else }}
  reject_errored:
    drop: {}
{{- end }}
```

> Note: the `processors` under a switch case run BEFORE the case's output send; `cdc_dlq_forwarded` therefore counts per delivery routed to DLQ (same semantic as `cdc_unprocessable`). Built-in `output_error{label=dlq_out}` covers publish failures.

- [ ] **Step 6: Run L1 to verify it passes + default byte-identical**

Run: `bash scripts/run-all-tests.sh 2>&1 | grep -E 'L1|hash_decode|dlq|PASS|FAIL' | head`
Expected: L1 passes.
Run (byte-identical, as Task 1 Step 6): `helm template chart/ | diff /tmp/mst.yaml - && echo DEFAULT-IDENTICAL`
Expected: `DEFAULT-IDENTICAL`.

- [ ] **Step 7: Sanity-check the enabled render is valid YAML/Bloblang shape**

Run: `helm template chart/ --set connect.deadLetter.enabled=true --show-only templates/connect-sink-configmap.yaml 2>/dev/null | sed -n '/output:/,/drop/p' | head -40`
Expected: shows `reject_errored: → switch: → nats_jetstream:` with `subject: dlq.cdc.${! meta("dlq_reason") }`.

- [ ] **Step 8: Commit**

```bash
git add chart/files/connect/cdc-reverse.yaml scripts/run-all-tests.sh
git commit -m "feat(dlq): hash_decode_error guard + write-then-ack DLQ output on reverse leg

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: NATS auth — subscriber pub grant for the DLQ subject

**Files:**
- Modify: `scripts/gen-nats-auth.sh` (subscriber user block, lines ~162–167)
- Regenerate: `chart/files/nats-auth/subscriber.creds` (+ any JWT artifacts the script writes)
- Test: decode the regenerated JWT

**Interfaces:**
- Consumes: `connect.deadLetter.subject` default (`dlq.cdc`).
- Produces: subscriber JWT `pub.allow` includes `dlq.cdc.>`.

> The sink publishes the DLQ with its **subscriber** creds. Without this grant the DLQ publish is permission-denied → the send errors → `reject_errored` nacks → retry (fails safe, no loss, but the message never leaves the loop). This grant is what makes the DLQ actually drain.

- [ ] **Step 1: Add the grant to the generator**

In `scripts/gen-nats-auth.sh`, in the `nsc add user ... --name subscriber` block (around line 162), add a `--allow-pub` line for the DLQ subtree. Use the DLQ base subject (default `dlq.cdc`); parameterize via an env like the existing `SUBJECT_PREFIX`:

```bash
DLQ_SUBJECT="${DLQ_SUBJECT:-dlq.cdc}"
```
and add to the subscriber user args:
```bash
  --allow-pub "${DLQ_SUBJECT}.>" \
```
Update the block comment to note the subscriber may now publish the DLQ subtree (design §4.4).

- [ ] **Step 2: Regenerate the creds (if `nsc` present)**

Run: `command -v nsc && bash scripts/gen-nats-auth.sh --force || echo "NSC-ABSENT: regenerate is an operator step"`
Expected: either regeneration runs, or `NSC-ABSENT` (then this task's creds regen is handed to the operator; the script change still lands).

- [ ] **Step 3: Verify the grant is in the JWT (if regenerated)**

Run:
```bash
python3 - <<'PY'
import base64,json,glob
f=open('chart/files/nats-auth/subscriber.creds').read()
import re
jwt=re.search(r'BEGIN NATS USER JWT-+\n(.+?)\n-+END',f,re.S).group(1).replace('\n','').strip()
b=jwt.split('.')[1]; b+='='*(-len(b)%4)
print('pub.allow:', json.loads(base64.urlsafe_b64decode(b))['nats']['pub']['allow'])
PY
```
Expected: list includes `dlq.cdc.>` (alongside `$JS.ACK.KV_CDC.>` etc.). If `NSC-ABSENT`, skip and note in the completion report.

- [ ] **Step 4: Commit**

```bash
git add scripts/gen-nats-auth.sh chart/files/nats-auth/
git commit -m "feat(dlq): grant subscriber creds pub on dlq.cdc.> for DLQ publish

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Observability — dashboard panel + alert note (INV-2)

**Files:**
- Modify: `chart/files/grafana/cdc-dashboard.json` (add a `cdc_dlq_forwarded` panel; ensure `cdc_unprocessable` panel covers the new reason)
- Modify: `chart/files/prometheus/cdc-alerts.yaml` (header note on DLQ-vs-loop increment cadence)
- Test: INV-2 grep + L1 render

**Interfaces:**
- Consumes: metrics `cdc_dlq_forwarded{reason}`, `cdc_unprocessable{reason=hash_decode_error}` (Task 2).

- [ ] **Step 1: Add the failing INV-2 grep assertion**

In `scripts/run-all-tests.sh` DLQ block, add:
```bash
grep -q 'cdc_dlq_forwarded' chart/files/grafana/cdc-dashboard.json || { echo "L1: dashboard missing cdc_dlq_forwarded panel"; fail L1; }
```

- [ ] **Step 2: Run to verify it fails**

Run: `grep -c cdc_dlq_forwarded chart/files/grafana/cdc-dashboard.json`
Expected: `0` (panel not added yet) → the L1 assertion fails.

- [ ] **Step 3: Add the dashboard panel**

In `chart/files/grafana/cdc-dashboard.json`, duplicate the existing "unprocessable-by-reason" panel object, retitle it `DLQ forwarded (by reason)`, set its target expr to `sum by (reason) (rate(cdc_dlq_forwarded[5m]))`, and give it a unique panel `id` + grid position below the unprocessable panel. Keep the same datasource/legend format as the sibling panel (copy its structure verbatim, changing only `id`, `title`, `gridPos.y`, and the `expr`).

- [ ] **Step 4: Add the alert header note**

In `chart/files/prometheus/cdc-alerts.yaml`, in the `CDCUnprocessableMessages` rule's comment header, append:

```yaml
        # NOTE: with connect.deadLetter.enabled, a poison message increments
        # cdc_unprocessable ONCE (then it is DLQ'd + acked) rather than every ackWait
        # via redelivery. The increase[...] window (>= 2x ackWait) still fires on new
        # poison; it just no longer re-arms from redelivery. cdc_dlq_forwarded{reason}
        # tracks what was parked in the DLQ.
```

- [ ] **Step 5: Run the INV-2 grep + L1**

Run: `grep -n "cdc_unprocessable\|cdc_apply\|cdc_dlq_forwarded\|cdc_latency_seconds" chart/files/grafana/cdc-dashboard.json chart/files/prometheus/cdc-alerts.yaml | grep dlq`
Expected: `cdc_dlq_forwarded` present in the dashboard.
Run: `bash scripts/run-all-tests.sh 2>&1 | grep -E 'L1|dlq|PASS|FAIL' | head`
Expected: L1 passes.

- [ ] **Step 6: Commit**

```bash
git add chart/files/grafana/cdc-dashboard.json chart/files/prometheus/cdc-alerts.yaml scripts/run-all-tests.sh
git commit -m "feat(dlq): dashboard panel for cdc_dlq_forwarded + alert cadence note (INV-2)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: L2 lab — end-to-end DLQ behavior proof

**Files:**
- Modify: `labs/redis-cdc-error-alerting/connect/config.yaml` (mirror the guard + DLQ output)
- Modify: `labs/redis-cdc-error-alerting/docker-compose.yml` (nats-init stream `--subjects "kv.cdc.>,dlq.cdc.>"`; consumer unchanged)
- Modify: `labs/redis-cdc-error-alerting/generator` (add a hash-poison emission: `type=hash` body with a trailing comma)
- Modify: `labs/redis-cdc-error-alerting/scripts/verify-alert.sh` (add a DLQ phase)
- Test: `labs/redis-cdc-error-alerting/scripts/verify-alert.sh` (L2, ~7 min)

**Interfaces:**
- Consumes: the guard/DLQ shape from Task 2 (mirrored into the lab's standalone config).
- Produces: proof that a malformed hash body lands in `dlq.cdc.hash_decode_error` and the consumer ack floor advances (no loop).

- [ ] **Step 1: Mirror the guard + DLQ output into the lab config**

In `labs/redis-cdc-error-alerting/connect/config.yaml`, after the `meta body = $decoded` line (line 29), add the hash guard, add the `hash_decode_failed` switch branch, and replace the output with the `reject_errored → switch → nats_jetstream(dlq.cdc.<reason>)` block — same shapes as Task 2 but with the lab's literal values (stream `LAB_CDC`, `nats://nats:4222`, no creds file in this lab, subject base `dlq.cdc`). Keep the lab's existing `set`-only apply for strings.

- [ ] **Step 2: Bind the DLQ subject on the lab stream**

In `labs/redis-cdc-error-alerting/docker-compose.yml` `nats-init` command (line ~29), change `--subjects "kv.cdc.>"` to `--subjects "kv.cdc.>,dlq.cdc.>"`.

- [ ] **Step 3: Add a hash-poison generator mode**

In `labs/redis-cdc-error-alerting/generator`, add a `hashpoison` case to `GEN_MODE` that XADDs to `app.events` an event with metadata `op=create`, `type=hash`, `kv_key=hp:{n}` and a body of literally `{"a":"1","b":"2",}` (trailing comma → invalid JSON).

- [ ] **Step 4: Add the DLQ phase to verify-alert.sh**

In `labs/redis-cdc-error-alerting/scripts/verify-alert.sh`, after the poison phase, add:

```bash
echo "== PHASE 3: hash poison -> DLQ, ack floor advances, no loop =="
before=$(docker compose exec -T nats nats --server nats://nats:4222 consumer info LAB_CDC cdc_sink --json | jq -r '.ack_floor.consumer_seq')
GEN_MODE=hashpoison GEN_RATE=5 GEN_DURATION=5 docker compose run --rm generator >/dev/null
# DLQ subject must receive the malformed hash body
dlq=$(docker compose exec -T nats nats --server nats://nats:4222 stream view LAB_CDC --subject 'dlq.cdc.hash_decode_error' --count 1 2>/dev/null | grep -c 'a' || echo 0)
[ "${dlq:-0}" -ge 1 ] || fail "no message parked on dlq.cdc.hash_decode_error"
# ack floor must ADVANCE (poison acked after DLQ publish, not stuck)
sleep 5
after=$(docker compose exec -T nats nats --server nats://nats:4222 consumer info LAB_CDC cdc_sink --json | jq -r '.ack_floor.consumer_seq')
awk "BEGIN{exit !($after > $before)}" || fail "ack floor did not advance ($before -> $after): poison is looping"
echo "  ack floor advanced $before -> $after; DLQ received hash poison"
```

- [ ] **Step 5: Run the L2 lab**

Run: `cd labs/redis-cdc-error-alerting && DLQ_TEST=1 scripts/verify-alert.sh; echo "exit=$?"; cd -`
Expected: `PASS` and `exit=0`, including the new `PHASE 3` (`ack floor advanced ... DLQ received hash poison`).

- [ ] **Step 6: Commit**

```bash
git add labs/redis-cdc-error-alerting/
git commit -m "test(dlq): L2 lab proves malformed hash body dead-letters + ack floor advances

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Full-ladder verification (INV-1/INV-4)

**Files:** none (verification only). Paste every command + exit status + result line.

- [ ] **Step 1: L0 — Go units (unchanged, regression sanity)**

Run: `go test ./... 2>&1 | tail -5`
Expected: `ok` across packages (no Go changed; must still pass).

- [ ] **Step 2: L1 — full render suite**

Run: `bash scripts/run-all-tests.sh SKIP_L2=1 SKIP_L3=1 2>&1 | tail -20`
Expected: L1 section passes (all toggle, multi-group, and new DLQ checks); exit 0.

- [ ] **Step 3: INV-2 metric-name grep**

Run: `grep -n "cdc_unprocessable\|cdc_apply\|cdc_dlq_forwarded\|cdc_forward_publish_failed\|cdc_latency_seconds" chart/files/grafana/cdc-dashboard.json chart/files/prometheus/cdc-alerts.yaml | grep -E 'dlq|unprocessable'`
Expected: `cdc_dlq_forwarded` (dashboard) and `cdc_unprocessable` (dashboard + alert) present.

- [ ] **Step 4: L3 — kind end-to-end (default install unaffected)**

Run:
```bash
scripts/build-images.sh --kind --kind-name=cdc && \
RRCS_NS=cdc-k8s RRCS_RELEASE=cdc scripts/verify-cdc.sh 2>&1 | tail -15
```
Expected: `[verify-cdc] PASS` (`verdict.pass=true`) — happy path unchanged.

- [ ] **Step 5: L4 — failover (required: ack-semantics change)**

Run: `scripts/verify-failover.sh 2>&1 | tail -15`
Expected: exit 0 — baseline loses messages, fixed (stable id) loses zero; at-least-once holds with the new output topology.

- [ ] **Step 6: Record results**

Paste the four command blocks + exit statuses into the completion report. If any level was skipped (e.g., `nsc`-absent creds in Task 3, or no kind cluster for L3/L4), state so explicitly and why. Update `rules/50-lessons.md` if anything surprising surfaced.

---

## Self-Review

**Spec coverage:**
- Decision 1 (write-then-ack) → Task 2 output topology + Task 6 L4. ✓
- Decision 2 (sibling subject) → Task 1 helper + validation, Task 5 lab stream. ✓
- Decision 3 (all three reasons) → Task 2 branches. ✓
- Decision 4 (opt-in default, byte-identical) → Task 1/2 gating + byte-identical checks. ✓
- Decision 5 (per-reason subject, envelope payload, dedup) → Task 2 output headers/subject. ✓
- §4.1 values → Task 1. §4.2 helpers → Task 1. §4.3 pipeline → Task 2. §4.4 auth → Task 3. §4.5 nats-init → Task 1 helper (reconcile path exercised by L3/L4) + Task 5 lab. §4.6 observability → Task 4. §Testing → Tasks 5–6. ✓

**Placeholder scan:** No TBD/TODO; every code step shows literal content. Dashboard panel (Task 4 Step 3) references copying an existing panel's verbatim structure — acceptable (the source object exists in-file).

**Type/name consistency:** `hash_decode_failed`, `dlq`, `dlq_reason`, `dlq_error`, `cdc_dlq_forwarded`, `cdc_unprocessable{reason=hash_decode_error}`, subject `dlq.cdc.<reason>` used identically across Tasks 2, 4, 5. Helper `rrcs.nats.stream.subjects` output `kv.cdc.>,dlq.cdc.>` consistent Task 1 ↔ Task 5.

**Known caveat:** Task 3 creds regen needs `nsc`; if absent it is handed to the operator (stated in-task) and Task 5/L2 uses the creds-less lab, so DLQ behavior is still proven without it.
