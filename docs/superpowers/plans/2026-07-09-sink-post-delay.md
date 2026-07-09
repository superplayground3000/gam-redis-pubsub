# Sink Elector Post-Election Settle Delay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sink-leg electors wait out the previous leader's ackWait window (default: the group's effective `ackWait`, 30s) after winning the Lease before POSTing the pipeline, so delivered-but-unacked messages redeliver *before* the new leg consumes newer ones — mitigating same-key stale overwrites on failover.

**Architecture:** One new env (`POST_DELAY`) in the Go elector with a context-aware wait in `OnStartedLeading` (abort fail-closed if leadership is lost mid-wait); the Helm chart derives a per-sink-group `postDelay` from the group's effective consumer `ackWait` (overridable, `"0s"` disables) and injects it only into sink electors. The source leg never sets the env, so its behavior is bit-identical.

**Tech Stack:** Go 1.x (`internal/elector`), Helm chart templates (`chart/`), bash verify scripts, kind/docker test tiers.

**Spec:** `docs/superpowers/specs/2026-07-09-sink-post-delay-design.md` (approved 2026-07-09).

## Global Constraints

- `POST_DELAY` env: Go duration string, default `0s` (unset = today's behavior). Parsed by the existing `envDur` (bad value → WARN + default, existing convention).
- Chart `postDelay` resolution precedence (exact): `group.postDelay` → `connect.sinkDefaults.postDelay` → the group's **effective** consumer `ackWait` (which resolves `group.consumer.ackWait` → `sinkDefaults.consumer.ackWait` → `nats.stream.consumer.ackWait`, today `"30s"`).
- Sink legs only. `chart/templates/connect-source.yaml` must NOT gain a `POST_DELAY` env.
- Default chart render for everything EXCEPT the new sink elector env must stay byte-identical (the D3 "byte-identical default render" property must not regress).
- Repo hard rules (CLAUDE.md): back up any `rules/*` file before editing (`cp <f> <f>.bak-$(date +%Y%m%d-%H%M%S)`); never claim a test passed without running it in-session (paste command + exit status); elector code change ⇒ **L4 required** (`rules/05-invariants.md` INV-1).
- `verify-failover-prefix.sh` settle stability window must outlast the new recovery horizon (leader election ≤~10s + postDelay 30s before the first post-kill apply): use **25×3s = 75s**.
- Commit after every task. Commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Elector `POST_DELAY` (Go, TDD)

**Files:**
- Modify: `internal/elector/main.go` (var block ~lines 44-55; `OnStartedLeading` ~lines 131-141; new helper at end of file)
- Test (create): `internal/elector/main_test.go`

**Interfaces:**
- Consumes: existing `envDur(k string, def time.Duration) time.Duration` (main.go), `retry`, `streamsClient` (streams.go).
- Produces: `waitPostDelay(ctx context.Context, d time.Duration) bool` — true = proceed to POST (delay elapsed or zero); false = leadership context cancelled mid-wait, caller returns without POSTing. Env `POST_DELAY` read in `Run`.

- [ ] **Step 1: Write the failing test**

Create `internal/elector/main_test.go`:

```go
package elector

import (
	"context"
	"testing"
	"time"
)

func TestWaitPostDelayZeroReturnsImmediately(t *testing.T) {
	start := time.Now()
	if !waitPostDelay(context.Background(), 0) {
		t.Fatal("zero delay must return true (POST proceeds)")
	}
	if time.Since(start) > 50*time.Millisecond {
		t.Fatal("zero delay must not block")
	}
}

func TestWaitPostDelayElapsesReturnsTrue(t *testing.T) {
	if !waitPostDelay(context.Background(), 20*time.Millisecond) {
		t.Fatal("elapsed delay must return true")
	}
}

func TestWaitPostDelayCancelledReturnsFalse(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan bool, 1)
	go func() { done <- waitPostDelay(ctx, 5*time.Second) }()
	time.Sleep(20 * time.Millisecond)
	cancel()
	select {
	case ok := <-done:
		if ok {
			t.Fatal("cancel during delay must return false (no POST)")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("waitPostDelay did not return promptly after cancel")
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/elector/ -run TestWaitPostDelay -v`
Expected: FAIL to build with `undefined: waitPostDelay`

- [ ] **Step 3: Implement**

In `internal/elector/main.go`, add to the `var (...)` block in `Run` (after `retryPd`):

```go
		postDelay = envDur("POST_DELAY", 0)
```

Replace the `OnStartedLeading` callback body (currently the `log.Printf("OnStartedLeading: POST stream %q", ...)` line through `leading.Store(1)`) with:

```go
			OnStartedLeading: func(c context.Context) {
				if postDelay > 0 {
					log.Printf("OnStartedLeading: won lease; delaying POST of %q by %s so the previous leader's un-acked deliveries pass their ackWait", streamID, postDelay)
					if !waitPostDelay(c, postDelay) {
						log.Printf("leadership lost during POST delay -> staying fail-closed (no POST)")
						return
					}
				}
				log.Printf("OnStartedLeading: POST stream %q", streamID)
				if err := retry(c, 10, retryPd, func() error { return sc.post(c, streamID, pipelineYAML) }); err != nil {
					postE.Add(1)
					log.Printf("POST kept failing (%v) -> releasing leadership, staying fail-closed", err)
					cancel()
					return
				}
				postOK.Add(1)
				leading.Store(1)
			},
```

(Do NOT call `cancel()` on the abort path: leadership is already gone; `OnStoppedLeading`'s DELETE of the never-POSTed stream is a no-op — `streamsClient.do` treats DELETE 404 as success, `internal/elector/streams.go:59`.)

Add at the end of `internal/elector/main.go`:

```go
// waitPostDelay blocks for d (the post-election settle delay) unless the
// leadership context is cancelled first. false = lost leadership mid-wait:
// the caller must return without POSTing (fail-closed).
func waitPostDelay(ctx context.Context, d time.Duration) bool {
	if d <= 0 {
		return true
	}
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-t.C:
		return true
	}
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `go test ./internal/elector/ -v`
Expected: PASS (all, including the pre-existing `TestRenderPipeline*` and streams tests)

Run: `go test ./...`
Expected: PASS, exit 0 (L0 green)

- [ ] **Step 5: Commit**

```bash
git add internal/elector/main.go internal/elector/main_test.go
git commit -m "elector: POST_DELAY settle wait before posting pipeline

New leader waits out the previous leader's ackWait horizon before
consuming, so un-acked deliveries redeliver ahead of newer messages
(same-key ordering mitigation, spec 2026-07-09-sink-post-delay).
Aborts fail-closed (no POST) if leadership is lost mid-wait.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Chart wiring — per-group `postDelay` (sink only)

**Files:**
- Modify: `chart/templates/_helpers.tpl` (`rrcs.connect.sinkGroups` define, ~lines 263-425: docstring field list ~273-274; `$elem` dict ~383-403)
- Modify: `chart/templates/connect-sink.yaml` (elector env block, after `RETRY_PERIOD`, ~line 126)
- Modify: `chart/values.yaml` (ackWait comment ~86-89; sinkGroups per-group-override comment ~235-237; `sinkDefaults` commented example ~266-275)
- Test: L1 render commands below (no script changes)

**Interfaces:**
- Consumes: env name `POST_DELAY` from Task 1.
- Produces: sinkGroups helper element field `postDelay` (string duration, e.g. `"30s"`); every enabled sink group's elector container gets `POST_DELAY: <postDelay>`.

- [ ] **Step 1: Capture the before-render (byte-identical check baseline)**

```bash
helm template chart/ > /tmp/claude-1000/-media-hp-secondary-projects-connect-project-gam-redis-pubsub/6725c455-28c6-492a-a5d0-eb1db4e5023c/scratchpad/render-before.yaml
```

- [ ] **Step 2: Edit `chart/templates/_helpers.tpl`**

In the `rrcs.connect.sinkGroups` docstring, extend the field list (currently `... replicas ackWait maxAckPending maxDeliver leaseDuration / renewDeadline retryPeriod deployBase ...`) to include `postDelay` after `ackWait` (matching the dict emission order), and append to the precedence note:

```
  group value  ->  connect.sinkDefaults  ->  legacy connect.sink.* / consumer.*
postDelay (elector post-election settle wait) resolves group.postDelay ->
sinkDefaults.postDelay -> the group's EFFECTIVE consumer ackWait; "0s" disables.
```

In the group loop, immediately before `{{- $elem := dict`, add:

```
{{-   $ackWait := $gcons.ackWait | default $defCons.ackWait | default $legCons.ackWait -}}
```

In the `$elem` dict, replace the `"ackWait"` line:

```
             "ackWait" ($gcons.ackWait | default $defCons.ackWait | default $legCons.ackWait)
```

with:

```
             "ackWait" $ackWait
             "postDelay" ($g.postDelay | default $defs.postDelay | default $ackWait)
```

- [ ] **Step 3: Edit `chart/templates/connect-sink.yaml`**

In the elector container env block, after the `RETRY_PERIOD` entry (`value: {{ $g.retryPeriod | quote }}`), add:

```yaml
            # Post-election settle wait: let the previous leader's un-acked
            # deliveries pass their ackWait before this leg consumes, so they
            # redeliver AHEAD of newer messages (same-key ordering mitigation).
            - name: POST_DELAY
              value: {{ $g.postDelay | quote }}
```

- [ ] **Step 4: Edit `chart/values.yaml` comments**

Extend the `ackWait:` comment (nats.stream.consumer) with one more line at the end of its existing COUPLING note:

```yaml
                            # Also the default for the sink electors' postDelay
                            # (post-election settle wait, see connect.sinkGroups).
```

In the sinkGroups doc comment, after the `streamID:` bullet, add:

```yaml
  #   postDelay: how long a group's elector waits after WINNING the Lease before
  #              POSTing the pipeline, so the previous leader's delivered-but-
  #              unacked messages pass their ackWait and redeliver ahead of newer
  #              ones (same-key stale-overwrite mitigation on failover; best-effort,
  #              not fencing). Inherits group -> sinkDefaults -> the group's
  #              effective consumer.ackWait. "0s" disables (dev / A-B baselines).
```

In the `sinkDefaults:` commented example block, add one line alongside `# replicas: 3`:

```yaml
    # postDelay: "30s"
```

- [ ] **Step 5: L1 render checks**

```bash
helm lint chart/
```
Expected: `1 chart(s) linted, 0 chart(s) failed`, exit 0.

```bash
helm template chart/ | grep -A1 'name: POST_DELAY'
```
Expected: exactly ONE hit pair (the default sink group's elector): `value: "30s"`.

```bash
helm template chart/ -s templates/connect-source.yaml | grep -c POST_DELAY
```
Expected: `0` (exit 1 from grep is fine — source leg untouched).

```bash
helm template chart/ \
  --set connect.sinkGroups[0].name=a --set connect.sinkGroups[0].prefixes[0]=prefix-a \
  --set connect.sinkGroups[1].name=b --set connect.sinkGroups[1].prefixes[0]=prefix-b \
  --set connect.sinkGroups[1].consumer.ackWait=45s \
  | grep -A1 'name: POST_DELAY'
```
Expected: TWO hit pairs — group a `value: "30s"` (inherited), group b `value: "45s"` (follows its own ackWait).

```bash
helm template chart/ --set connect.sinkDefaults.postDelay=0s | grep -A1 'name: POST_DELAY'
```
Expected: `value: "0s"` (explicit disable renders).

```bash
helm template chart/ > /tmp/claude-1000/-media-hp-secondary-projects-connect-project-gam-redis-pubsub/6725c455-28c6-492a-a5d0-eb1db4e5023c/scratchpad/render-after.yaml
diff /tmp/claude-1000/-media-hp-secondary-projects-connect-project-gam-redis-pubsub/6725c455-28c6-492a-a5d0-eb1db4e5023c/scratchpad/render-before.yaml /tmp/claude-1000/-media-hp-secondary-projects-connect-project-gam-redis-pubsub/6725c455-28c6-492a-a5d0-eb1db4e5023c/scratchpad/render-after.yaml
```
Expected: the ONLY diff is the added `POST_DELAY` env (+ its comment lines) in the connect-sink elector container. Anything else = regression of the byte-identical-default property; fix before proceeding.

- [ ] **Step 6: Run the fast tiers (includes the INV-3 toggle loop)**

Run: `SKIP_L2=1 SKIP_L3=1 scripts/run-all-tests.sh`
Expected: L0 + L1 PASS, exit 0.

- [ ] **Step 7: Commit**

```bash
git add chart/templates/_helpers.tpl chart/templates/connect-sink.yaml chart/values.yaml
git commit -m "chart: sink electors get POST_DELAY derived from group ackWait

Per-group postDelay (group -> sinkDefaults -> effective ackWait, \"0s\"
disables); sink legs only, source leg env unchanged.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Widen the prefix-failover settle window for the new horizon

**Files:**
- Modify: `scripts/verify-failover-prefix.sh` (settle comment ~lines 108-115 and `stable>=15` ~line 121)

**Interfaces:**
- Consumes: nothing from other tasks (script-only), but exists BECAUSE the chart default now delays the killed group's recovery by `postDelay` (30s).
- Produces: settle loop stability threshold `stable>=25` (25×3s = 75s).

- [ ] **Step 1: Update the settle comment and threshold**

Replace the comment block above the settle loop (the lines explaining `15x3s=45s > ackWait 30s`) with:

```bash
# settle: a complete region (NA+NB) ends the wait immediately; otherwise only
# conclude "stopped growing" after the count has been stable LONGER than the
# slowest recovery mechanism (rules/50-lessons.md 2026-07-07). Since the sink
# electors' post-election settle delay (postDelay = ackWait, 30s default), the
# killed group's count legitimately freezes for leader election (<=~10s) +
# postDelay (30s) before the first redelivered apply — ackWait itself expires
# DURING that wait. 25x3s=75s outlasts that ~40s horizon with margin.
```

In the settle loop change `(( stable>=15 ))` to `(( stable>=25 ))`.

- [ ] **Step 2: Syntax-check**

Run: `bash -n scripts/verify-failover-prefix.sh`
Expected: no output, exit 0.

- [ ] **Step 3: Commit**

```bash
git add scripts/verify-failover-prefix.sh
git commit -m "tests: L4 prefix settle window outlasts election + postDelay horizon

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Document the mitigation + residual non-guarantees in the invariants file

**Files:**
- Modify: `rules/05-invariants.md` (the "Known accepted non-guarantee" paragraph under INV-1, ~lines 56-58)

**Interfaces:** none (docs). The INV-1 load-bearing TABLE is not touched — this appends a note below it.

- [ ] **Step 1: Back up first (repo hard rule 2)**

Run: `cp rules/05-invariants.md rules/05-invariants.md.bak-$(date +%Y%m%d-%H%M%S)`
Expected: backup file exists (`ls rules/05-invariants.md.bak-*`).

- [ ] **Step 2: Append the note**

Directly after the existing paragraph

> **Known accepted non-guarantee:** cross-key reordering (e.g. delete-before-rename) ... it is not covered by INV-1.

add:

```markdown
**Known accepted non-guarantee (same-key, sink failover):** same-key reordering across a
sink leader failover — the old leader's delivered-but-unacked messages redeliver only
after `ackWait`, behind newer messages — is *mitigated*, not eliminated: sink electors
delay their pipeline POST by the group's effective `ackWait` (chart `postDelay`, elector
`POST_DELAY`; spec `docs/superpowers/specs/2026-07-09-sink-post-delay-design.md`).
Residual and accepted: an alive-but-partitioned old leader acking/applying late, and a
new leader crashing mid-apply, can still reorder. The elector remains best-effort
active-gating, not fencing — ordering must not *depend* on it.
```

- [ ] **Step 3: Read back the edited section**

Run: `sed -n '50,75p' rules/05-invariants.md`
Expected: both non-guarantee paragraphs present, table above untouched.

- [ ] **Step 4: Commit**

```bash
git add rules/05-invariants.md
git commit -m "rules: record sink-failover same-key reorder mitigation + residuals

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Full verification — L3 + L4 (elector change makes L4 mandatory)

**Files:** none modified (verification only; `rules/50-lessons.md` if a process lesson emerges).

**Interfaces:** consumes the complete implementation (Tasks 1-4 committed).

- [ ] **Step 1: Build images into kind**

Run: `scripts/build-images.sh --kind --kind-name=cdc`
Expected: exit 0, images loaded into the `cdc` kind cluster.

- [ ] **Step 2: L3 end-to-end**

Run: `RRCS_NS=cdc-k8s RRCS_RELEASE=cdc scripts/verify-cdc.sh`
Expected: final `[verify-cdc] PASS` line and `verdict.pass=true` in RESULT_JSON, exit 0. (Install now pays one ~30s sink start delay; the script's 240s region-wait absorbs it.)

- [ ] **Step 3: L4 source-leg failover chaos (~12 min)**

Run: `scripts/verify-failover.sh`
Expected: exit 0 — baseline (pod-scoped id) loses messages AND fixed (stable id) loses zero. (This script kills the SOURCE leader; sink leadership never changes mid-run, so `postDelay` only delays the initial install by ~30s, absorbed by its adaptive drain/settle loops.)

- [ ] **Step 4: L4 sink-group failover chaos**

Run: `scripts/verify-failover-prefix.sh`
Expected: exit 0 — `[failover-prefix] PASS — group-a durable replayed with ZERO loss after SIGKILL; group-b unaffected (isolation held)`. This is the run that actually exercises the new delay on a killed sink leader: watch the group-a elector log for the new `delaying POST ... 30s` line (`kubectl logs <new group-a leader pod> -c elector`).

- [ ] **Step 5: Report**

Paste, per repo reporting rule: each command, exit status, and the final PASS/RESULT_JSON lines. If any level was skipped, say so and why. Record any process lesson in `rules/50-lessons.md` (format per that file) and commit it if one emerged.

---

## Follow-ups (out of scope, recorded in the spec)

1. Ordering A/B proof in the failover harness (stale-overwrite detector; assert reorder with `postDelay: "0s"`, none with default).
2. Drain-aware wait (approach B: poll `num_ack_pending`, POST early when 0).
