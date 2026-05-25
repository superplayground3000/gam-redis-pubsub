# redis-redpanda-connect-stress v2 — design spec

**Date:** 2026-05-25
**Implementation skill:** `research-lab` (continues the convention established by v1; the lab remains a self-contained `labs/{slug}/` directory with `docker-compose.yml`, `README.md`, `RESEARCH.md`, and Go components).
**Previous spec:** `docs/superpowers/specs/2026-05-24-redis-redpanda-connect-stress-design.md`
**Previous plan:** `docs/superpowers/plans/2026-05-24-redis-redpanda-connect-stress.md`
**Triggering evidence:** full-matrix run on 2026-05-25 revealed three systematic measurement flaws documented below.

## 1. Goal

Fix three v1 measurement/operational flaws so the lab's PASS/FAIL verdict and reported numbers reflect **what the pipeline under test actually did**, not artifacts of the lab's own measurement methodology. The pipeline under test (Redis → Redpanda Connect → NATS JetStream → Redpanda Connect → Redis) is untouched; everything in this spec is a change to the **collector** binary and the bash **harness**.

A successful v2 lets a sceptical reviewer trust the JSON reports for all three tiers (10, 1 000, 10 000 msg/s) and all three modes (throughput, latency, chaos). Where the pipeline genuinely fails to meet an SLO, the verdict must say so; where it succeeds, the verdict must not be falsely red due to measurement bias.

## 2. v1 flaws being fixed

### Flaw A — Latency P99 unreachable at scale (polling sampler)
v1 collector calls `XRANGE region-events <lastID> + COUNT 200` once per second. At 1 k msg/s that samples ~20 % of messages; at 10 k it samples ~2 %. Worse, the reported "latency" for sampled messages is `now − msg.ts_ns` measured at the moment the collector reads them — which includes up to a full polling-window delay (~1 s). The matrix run showed latency P99 of 4–35 s at all tiers; ~95 % of that is the collector's own polling delay, not the pipeline's e2e latency. All `latency` and `chaos` mode verdicts failed `latency_p99_ok` for this reason.

### Flaw B — `received` count tainted by MAXLEN trim
v1 collector reads `received := XLEN(region-events)` at end of run. The region stream has `MAXLEN ~ 100000` (a v1 final-review fix). At 10 k tier × 30 s sustain = 300 k messages produced, but `XLEN` caps at ~100 k. The verdict computes `missing = sent − received = 200 k`, then fails `missing_ok` even though **every message was delivered** — the older 200 k were simply trimmed by the cap. The pipeline is being penalised for the lab's own storage decision.

### Flaw C — NATS stream byte accumulation aborts late-matrix runs
JetStream `APP_EVENTS` is configured with `--max-bytes 256MB`. Across a 9-run matrix the persistent `nats-data` volume accumulates more than the 200 MB pre-flight threshold, so the final 10 k chaos run aborts before it starts. The pipeline never gets exercised under chaos at the highest tier — the verdict is "ABORT", which is neither PASS nor FAIL.

## 3. Non-goals

- **Pipeline under test changes** — no edits to writer, Connect YAMLs, NATS config, Redis config, or resource limits.
- **SLO renegotiation** — the existing tier SLOs (200 ms / 1 s / 5 s for P99; 0.95/0.95/0.90 for rate floor) stay as-is. v2 measures more accurately; we discover empirically which SLOs hold and document any that need updating in a follow-up.
- **Carry-forward sample recovery** — if the streaming consumer transiently errors, those samples are lost. v2 surfaces the error count in the report but does not implement re-sampling logic.
- **Multi-host / multi-NATS-replica** — single Compose host, single NATS replica, same as v1.
- **Verdict-logic redesign** — `ComputeVerdict` is unchanged. Its **inputs** become honest in v2; the rule set itself is fine.

## 4. Architecture

```
                                       ┌────────────────────────┐
                                       │ collector binary       │
                                       │                        │
                                       │  ┌─────────────────┐   │
                                       │  │ snapshot loop   │   │  (unchanged role:
                                       │  │ 1 Hz: writer    │   │   metrics + gauges,
                                       │  │      Connect    │   │   NOT latency)
                                       │  │      NATS /jsz  │   │
                                       │  │      XLEN gauges│   │
                                       │  └─────────────────┘   │
                                       │                        │
   region-events ─XREAD BLOCK 250ms─▶│  ┌─────────────────┐   │  (NEW in v2:
   redis-region   (streaming)          │  │ receiver loop   │   │   source of truth
                                       │  │ for each msg:   │   │   for latency AND
                                       │  │   - record lat  │   │   received-count)
                                       │  │   - inc counter │   │
                                       │  └─────────────────┘   │
                                       │                        │
                                       │  buildReport reads:    │
                                       │   • receiver.Count()   │
                                       │   • receiver.Latency() │
                                       │   • snaps for          │
                                       │     XLen/NATS/Connect  │
                                       └────────────────────────┘
```

**Key changes from v1:**

| Concern | v1 | v2 |
|---|---|---|
| `received` count | `XLEN(region-events)` at end of run | streaming consumer counts every message delivered, untainted by MAXLEN |
| Latency samples | poll 200/s from `XRANGE` snapshots | `XREAD BLOCK` consumes every message, records true e2e |
| NATS state between runs | accumulates across the matrix | harness purges `APP_EVENTS` after each run |
| Snapshot loop duties | metrics + latency + received | metrics only (latency and received moved out) |

## 5. Streaming consumer (`receiver.go`)

New file `labs/redis-redpanda-connect-stress/collector/receiver.go`.

### 5.1 Type

```go
type Receiver struct {
    rdb       *redis.Client
    stream    string                 // "region-events"
    latency   *LatencyTracker
    received  atomic.Int64
    errCount  atomic.Int64
    lastID    string                 // touched only by Run() goroutine
}

func NewReceiver(addr, stream string) *Receiver
func (r *Receiver) Count() int64
func (r *Receiver) Errors() int64
func (r *Receiver) Latency() LatencySummary
func (r *Receiver) Close() error
func (r *Receiver) Run(ctx context.Context)   // blocks until ctx cancelled
```

`Run` is the single goroutine that mutates `lastID` and `latency`. Public accessors (`Count`, `Errors`, `Latency`) are race-safe (`atomic.Int64` for the two counters; `LatencyTracker.Summary` is called only after `Run` returns).

### 5.2 Run loop

```go
func (r *Receiver) Run(ctx context.Context) {
    r.lastID = "0-0"
    for {
        if ctx.Err() != nil {
            return
        }
        res, err := r.rdb.XRead(ctx, &redis.XReadArgs{
            Streams: []string{r.stream, r.lastID},
            Block:   250 * time.Millisecond,
            Count:   1000,
        }).Result()
        if err != nil {
            if errors.Is(err, redis.Nil) || errors.Is(err, context.DeadlineExceeded) {
                continue // empty window, normal — keep looping
            }
            if ctx.Err() != nil {
                return
            }
            r.errCount.Add(1)
            time.Sleep(50 * time.Millisecond)
            continue
        }
        nowNs := time.Now().UnixNano()
        for _, st := range res {
            for _, msg := range st.Messages {
                if v, ok := msg.Values["value"].(string); ok {
                    if ts, err := extractTsNs(v); err == nil {
                        r.latency.RecordAt(ts, nowNs)
                    }
                }
                r.received.Add(1)
                r.lastID = msg.ID
            }
        }
    }
}
```

### 5.3 Key properties

- **No gap between blocks.** `lastID` advances monotonically; the next `XREAD` resumes from there.
- **Survives chaos.** When `connect-sink` is stopped, the stream stops growing; `XREAD BLOCK` returns empty. When sink restarts, the backlog flows in and the receiver catches up at line rate (`COUNT 1000` per call lets the receiver consume up to 1 000 backlogged messages per iteration).
- **Bounded memory.** Each `XREAD` returns at most 1 000 messages; the receiver processes them synchronously before issuing the next call. No internal queue.
- **One Redis client** (a fresh `redis.NewClient`), separate from the snapshot loop's StreamClient. No contention.

### 5.4 Error policy

- **Transient redis errors** → `errCount++`, sleep 50 ms, retry. Not surfaced to verdict; reported as `received_errors` in the JSON.
- **`redis.Nil`** (XREAD returned empty within the block window) → normal, continue.
- **Context cancelled** → return cleanly.

## 6. Receiver lifecycle in `Run` (main.go)

The lifecycle is precisely sequenced because the `trimmed` math (§7) requires a synchronized end-of-run cut between `receiver.Count()` and final `XLEN(region-events)`, and because per-run isolation requires explicit quiescence boundaries (see §6.3).

```
 1. Trim app.events                                            (existing)
 2. Trim region-events                                         (existing)
 3. PostReset                                                  (existing)
 4. receiver := NewReceiver(...)                               (NEW)
 5. receiverCtx, cancelRecv := WithCancel(ctx)
 6. var wg sync.WaitGroup; wg.Add(1)                            (NEW)
    go func() { defer wg.Done(); receiver.Run(receiverCtx) }()
 7. PostRate(tier/2); sleep(warmup)                            (existing)
 8. PostRate(tier); sustain ticker loop (1 Hz snaps)           (existing)
 9. PostRate(0)                                                (existing)
10. drain ticker loop for DRAIN_S seconds (1 Hz snaps)         (existing)
11. quiescenceTimedOut := waitForPipelineQuiescence(            (NEW — §6.3)
                            ctx, cfg.Profile, central,
                            cfg.NATSURL, cfg.NATSStream,
                            10*time.Second)
12. time.Sleep(500ms)  // tail-flush window for receiver        (NEW — §6.2)
13. cancelRecv()                                               (NEW)
14. wg.Wait() — receiver goroutine has fully exited            (NEW — §6.1)
15. finalRegionXLen, _ := region.XLen(ctx, "region-events")    (NEW — §6.4)
16. buildReport(cfg, startedAt, snaps, receiver,
                finalRegionXLen, quiescenceTimedOut)            (modified)
```

After step 16 the collector writes JSON and exits. The harness then runs `nats stream purge APP_EVENTS` (see §9). This ordering is critical: the purge happens *after* the JSON report is final, and the next run's step 1+2 trims source/region streams *before* its receiver starts.

### 6.1 Receiver goroutine join

The receiver goroutine is launched in step 6 with `wg.Add(1)` and a deferred `wg.Done()` inside the goroutine; step 14 is `wg.Wait()`. `wg.Add(1)` MUST be called from the caller's goroutine before the receiver goroutine starts (Go memory model requirement). After `wg.Wait()` returns, no `XREAD` call is in flight and no further writes to `receiver.received` / `receiver.latency` will happen. Subsequent reads of `receiver.Count()` / `receiver.Errors()` / `receiver.Latency()` are race-safe by happens-before from the WaitGroup release.

### 6.2 Tail-flush window (step 12)

`XREAD BLOCK 250ms` means the receiver checks for new messages roughly every 250 ms. If a message lands in `region-events` at the very end of drain and we cancel immediately, the receiver might exit before its next XREAD cycle picks it up. Sleeping 500 ms (= 2× block window) before cancellation guarantees at least one more receiver cycle.

The 500 ms is sized against the **receiver's block window**, not against pipeline propagation. The two timing concerns are layered:
- §6.3 quiescence (step 11) ensures the **pipeline** is empty — no more messages will be written to `region-events`.
- §6.2 tail-flush (step 12) ensures the **receiver** has had time to see whatever §6.3 left it.

### 6.3 Pipeline quiescence (step 11)

Before declaring "drain complete," wait for the pipeline to be empty. What "empty" means depends on the QoS profile — see §6.3.1 for the profile-aware ruleset.

**Function signature:**

```go
// waitForPipelineQuiescence polls every 250 ms until either:
//   - the profile-specific quiescence condition (§6.3.1) holds for one poll, OR
//   - deadline elapses.
// Returns true if the deadline fired (the pipeline did not quiesce in time),
// false if quiescence was observed.
func waitForPipelineQuiescence(
    ctx context.Context,
    profile string,
    central *StreamClient,
    natsURL, natsStream string,
    deadline time.Duration,
) (timedOut bool)
```

The function lives in collector/main.go alongside `Run` (or a sibling file `quiescence.go` — implementation choice, not a spec constraint). It uses the existing `central.XLen` and `ScrapeJSZ` helpers; no new infrastructure.

The 10 s deadline accommodates the worst-case ALO/EOE chaos drill: ~80 k messages backlogged in NATS at 10 k tier × 8 s outage, draining at ~10 k msg/s after `connect-sink` restarts = ~8 s. Steady-state drain finishes in well under 1 s for any profile.

If the deadline fires, the function returns `timedOut=true`. The caller stores this in `quiescenceTimedOut` (lifecycle step 11), proceeds to steps 12–15 anyway (the receiver is canceled, `finalRegionXLen` is read, the report is written). The verdict itself is unaffected by `quiescence_timeout` — a genuine pipeline failure already shows up as `missing > 0` for ALO/EOE, and for AMO `missing > 0` is allowed by the SLO.

#### 6.3.1 Profile-aware quiescence conditions

| Profile | Quiescence condition | Rationale |
|---|---|---|
| `alo`, `eoe` | `XLEN("app.events") == 0` **AND** `ScrapeJSZ(...).MaxPending == 0` for the `region-writer` consumer | The reverse leg uses a durable consumer with `ack_wait: 30s` and ACK only after `region-events` write. `num_pending == 0` therefore implies every dispatched message has landed in the region stream. |
| `amo` | `XLEN("app.events") == 0` only — **NATS pending check is skipped** | The amo-reverse YAML uses an *ephemeral, deliver-new, `ack_wait: 2s`, `auto_replay_nacks: false`* consumer. By design, the AMO consumer **ignores any backlog** that accumulated while `connect-sink` was down (it consumes only from "now"). Those backlogged messages stay in `APP_EVENTS` indefinitely as the AMO loss mode — they will never be delivered and `num_pending` either reports them forever (false-hang) or the ephemeral consumer is gone entirely (no useful signal). Waiting for source quiescence is sufficient; the AMO verdict allows `missing > 0` (`slo.allow_missing=true`), so unconsumed messages are *expected and correct behavior*. |

Both code paths reuse existing collector helpers: `Central.XLen` (redis.go) and `ScrapeJSZ` (nats.go). No new infrastructure.

#### 6.3.2 Profile-aware purge safety

The §9 NATS purge happens after the collector exits, regardless of profile. For ALO/EOE this is safe because quiescence proved `num_pending == 0` (no in-flight work to lose). For AMO it is also safe — the purge discards the unconsumed backlog that AMO was going to abandon anyway. There is no message in AMO that "would have been delivered but for the purge"; AMO's loss happens at the ephemeral-consumer boundary, not at purge time.

### 6.4 Synchronized end-of-run cut (steps 14 → 15)

`finalRegionXLen` is read **after** `wg.Wait()` returns, not from the last 1-Hz snapshot tick. This ensures `receiver.Count()` and `finalRegionXLen` refer to the same moment in time — the moment the receiver stopped reading. The `trimmed = received - finalRegionXLen` formula in §7 is then well-defined.

A residual race window between `cancelRecv()` and `XLen("region-events")` is possible if `connect-sink` writes to `region-events` after we cancel the receiver but before we read `XLEN`. The size of this window varies by profile:

- **ALO/EOE**: §6.3 quiescence has confirmed `num_pending == 0` and source `XLEN == 0`. There is no in-flight JetStream message that could result in a late `XADD` to `region-events`. The race window is bounded only by Redis command-pipeline latency between cancelRecv and XLen (< 1 ms). Negligible.
- **AMO**: §6.3 confirmed only source `XLEN == 0`. The AMO ephemeral consumer can still be processing the last few messages that connect-source published just before source quiescence. Those messages may land in `region-events` after `cancelRecv()` but before the `XLEN` read, inflating `finalRegionXLen` relative to `receiver.Count()` by a small number (≤ Connect's `max_in_flight: 64`). This makes `trimmed` clamp to 0 (correct — no trim happened) and inflates `missing` by the same small number. Since AMO's verdict allows `missing > 0`, the report's PASS/FAIL outcome is unaffected; only the precise missing-count is slightly noisier. The noise floor is the AMO consumer's `max_in_flight` of 64, well below any tier's expected loss magnitude.

Both regimes converge to "trimmed math is correct or harmlessly conservative; verdict is unaffected." No further synchronization is needed.

## 7. Report semantics changes

### 7.1 Field meaning changes (additive only — no removed or renamed fields)

| Field | v1 meaning | v2 meaning |
|---|---|---|
| `received` | `XLEN(region-events)` at end of run | total messages observed by streaming consumer (untainted by MAXLEN) |
| `missing` | `sent − received` (false-positive on trim) | true in-transit loss |
| `latency_ms.{p50,p95,p99,max,samples}` | poll-window-biased percentiles, ~2-20% of messages sampled | real per-message e2e percentiles over **every** delivered message |

### 7.2 New fields in `Report`

```go
type Report struct {
    ...existing fields...
    ReceivedErrors    int64 `json:"received_errors"`     // transient XREAD errors from receiver
    Trimmed           int64 `json:"trimmed"`             // = max(0, received - finalRegionXLen)
    QuiescenceTimeout bool  `json:"quiescence_timeout"`  // true if §6.3 deadline fired before quiescence (profile-specific condition; see §7.2)
}
```

`trimmed` is informational. It's `received − finalRegionXLen`, where `finalRegionXLen` is the post-`wg.Wait` synchronized XLEN cut (§6.4), not the last polling snapshot. Clamped to `[0, +∞)`. If positive (10 k tier), the report says "this many messages were delivered but trimmed by MAXLEN" — the silent v1 failure mode becomes a visible diagnostic. If zero (low tiers), nothing notable.

`received_errors` lets operators see when the receiver itself had trouble (network blip, redis restart during chaos drill). The count is **not** used to compute the verdict — its purpose is diagnostic, so that an operator looking at a borderline `missing > 0` report can rule out receiver flakiness as the cause.

`quiescence_timeout` is `true` if the §6.3 pipeline-quiescence poll hit its 10 s deadline. The exact stall condition depends on profile: for ALO/EOE either `XLEN(app.events)` or NATS `num_pending` failed to reach 0; for AMO only `XLEN(app.events)` is checked. In a healthy run it is always `false`. In a stalled ALO/EOE pipeline it is `true` and accompanies a non-zero `missing`; in AMO `missing > 0` is expected so this flag is the operator's signal that the *source side* (not the loss-tolerated sink side) is stuck.

### 7.3 `buildReport` changes (collector main.go)

**Signature changes** from v1 to v2:

```go
// v1
func buildReport(cfg RunConfig, startedAt time.Time, snaps []Snapshot, lat LatencySummary) Report

// v2
func buildReport(
    cfg RunConfig,
    startedAt time.Time,
    snaps []Snapshot,
    receiver *Receiver,           // NEW — source of truth for received-count and latency
    finalRegionXLen int64,        // NEW — synchronized §6.4 cut
    quiescenceTimedOut bool,      // NEW — propagated to report.QuiescenceTimeout
) Report
```

The `lat LatencySummary` parameter is removed because the sampler no longer tracks latency in v2; `receiver.Latency()` replaces it.

**Body changes**: replace this block from v1
```go
last := snaps[len(snaps)-1]
r.Received = last.RegionXLen
r.Redis.RegionXLenFinal = last.RegionXLen
// ... (lat parameter used later for r.Latency)
```

with
```go
r.Received             = receiver.Count()
r.ReceivedErrors       = receiver.Errors()
r.QuiescenceTimeout    = quiescenceTimedOut
r.Redis.RegionXLenFinal = finalRegionXLen
r.Trimmed = r.Received - r.Redis.RegionXLenFinal
if r.Trimmed < 0 {
    r.Trimmed = 0
}
r.Latency = receiver.Latency()
// `last := snaps[len(snaps)-1]` is still used below for the OTHER end-of-run
// fields (Sent, Errors, Connect.*, NATS.Bytes) — those stay sourced from
// the snapshot loop.
```

All other v1 logic in `buildReport` is unchanged — `Sent` and `Errors` (from writer Prom metrics on the last snapshot), `Missing = Sent - Received` clamped to ≥0, `MissingPct`, sustain-window rate avg/min from snapshot deltas, `Redis.CentralXLenMax`, `NATS.PendingMax`, `Connect.*`, `NATS.Bytes`, `Chaos` block, `Verdict`.

### 7.4 `ComputeVerdict` — unchanged

The verdict logic in `verdict.go` is untouched. Its **inputs** become honest. The previously-failing tests pass without code changes (the v1 unit tests for verdict.go remain green; they were always correct for the rules; v1's failure was upstream).

## 8. Snapshot loop changes (`snapshot.go`)

Drop two responsibilities from the `Sampler`/`Tick` flow. `Sampler` shrinks to:

```go
type Sampler struct {
    WriterURL    string
    ConnectSrc   string
    ConnectSink  string
    NATSURL      string
    NATSStream   string
    Central      *StreamClient
    Region       *StreamClient
    // REMOVED: Latency *LatencyTracker
    // REMOVED: LastRegionID string
}
```

`Tick` no longer calls `XRangeSinceID` or `extractTsNs`. It returns a `Snapshot` populated only with: writer Prom metrics, connect-source/sink Prom metrics, central XLen, region XLen, NATS `/jsz` summary.

`Sampler.Init()` becomes a no-op and can be deleted (or kept as a forward-compatibility hook; v2 deletes it).

## 9. Harness change (`stress-run.sh`)

In `run_one`, after the `docker compose run --rm collector ...` invocation has fully exited (the collector has written its JSON report and returned) and after the `wait "${chaos_pid}"` block, add a single line:

```bash
docker exec rrcs-nats nats --server nats://nats:4222 stream purge APP_EVENTS -f >/dev/null 2>&1 \
  || echo "[purge] WARN: nats stream purge APP_EVENTS failed (continuing)" >&2
```

The purge runs **after** the collector exit; the collector's §6 lifecycle has by then completed profile-aware pipeline quiescence (§6.3.1). For ALO/EOE, `num_pending==0` proves nothing in JetStream is in flight, so purge cannot lose a "would-have-been-delivered" message. For AMO, the purge intentionally discards the unconsumed backlog — that backlog is the lab's *modeled* AMO loss; AMO's verdict allows it via `slo.allow_missing=true`. The purge is non-fatal — if it fails (first-run state, transient docker exec issue), the pre-flight check on subsequent chaos runs will catch a genuinely-broken NATS state.

### 9.1 Per-run isolation guarantee

Combined isolation from steps 1+2 of §6 (trim `app.events` and `region-events` at run start), the §6.3 pipeline quiescence at run end, and the post-collector NATS purge in §9, each run starts with empty Redis streams and an empty JetStream. The only carryover paths and how they are blocked:

- **Source-side residue (`app.events`)**: prior run's §6.3 quiescence asserts `XLEN(app.events)==0` before that run's exit (for all profiles); the new run's step 1 trim is then a no-op-safety, not load-bearing. Even if the prior run's quiescence timed out, the new run's trim destroys the residue before the receiver starts.
- **JetStream residue (`APP_EVENTS`)**: for ALO/EOE, prior run's §6.3 quiescence asserts `num_pending==0` and the harness purges the stream. For AMO, §6.3 does not gate on `num_pending` (consumer is ephemeral and ignores backlog by design), but the harness purge still discards everything in the stream. Either way, the new run's step 4 receiver starts against an empty stream.
- **Region-side residue (`region-events`)**: prior run's receiver completes (§6.1 `wg.Wait`) before the prior run's `finalRegionXLen` is read. The new run's step 2 trim then clears whatever messages were left.
- **JetStream dedup state**: `--dupe-window 5m` keeps msg-ID dedup state for 5 minutes. Because the writer generates a fresh UUID per `event_id`, the dedup window cannot collide between runs.

### 9.2 What stays from v1

- `--max-bytes 256MB` on the stream. Still a runaway ceiling.
- 200 MB pre-flight before chaos runs. Still a sanity guard.
- All other harness behaviour from v1 (arg parsing, EXIT trap teardown, tier/mode validation, robust JSZ parsing).

## 10. Summary table (stdout)

Add one column for `trimmed`. New layout:

```
tier      mode         rate_achieved   missing   trimmed   p99 ms    verdict
─────────────────────────────────────────────────────────────────────────────
10        throughput   10.0/10         0         0         18        PASS
1000      throughput   1000/1000       0         0         42        PASS
10000     throughput   9420/10000      0         225000    98        PASS
10000     chaos        9210/10000      0         225000    1140      PASS
```

(At 10 k tier, `missing=0` and `trimmed=225000` together communicate "everything delivered; 225 k older entries trimmed by MAXLEN" — the v1 false-fail becomes a clear PASS with an honest diagnostic. At 10 and 1000 tiers, `trimmed=0` because production rate × duration is well below MAXLEN.)

Renderer change: the inline Python `print(f"...")` in `stress-run.sh` gets one extra field.

## 11. File map (changes only)

```
labs/redis-redpanda-connect-stress/
├── collector/
│   ├── receiver.go            NEW (~70 LOC, see §5)
│   ├── receiver_test.go       NEW (~50 LOC, no Redis needed — exercises payload parse + counters via a small in-memory helper)
│   ├── quiescence.go          NEW (~40 LOC) — waitForPipelineQuiescence per §6.3
│   ├── snapshot.go            MODIFIED — drop Latency/LastRegionID from Sampler; Tick no longer touches latency
│   ├── main.go                MODIFIED — receiver lifecycle (§6 steps 4-15), buildReport signature (§7.3)
│   └── report.go              MODIFIED — add ReceivedErrors, Trimmed, QuiescenceTimeout fields
├── scripts/
│   └── stress-run.sh          MODIFIED — purge APP_EVENTS after each run; +1 column (`trimmed`) in summary table
├── README.md                  MODIFIED — document the new fields and what trimmed=N means
└── RESEARCH.md                MODIFIED — explain v2 measurement-vs-pipeline distinction
```

`quiescence.go` is a separate file rather than living in `main.go` so the helper can be unit-tested via a small fake `*StreamClient` and an HTTP test server for JSZ. This is implementation guidance, not a hard spec requirement — the implementer may inline it in `main.go` if preferred.

No changes to: writer (any file), connect YAMLs, docker-compose.yml, .env.example, tier-defs.sh, kill-connect-sink.sh, latency.go, verdict.go, verdict_test.go, redis.go, scrapers.go, nats.go.

## 12. Testing approach

This is a lab, not a service. Same hand-run pattern as v1.

1. **Unit tests** — `receiver_test.go` exercises payload parsing and counter logic via a small synthetic XMessage helper. `latency.go` and `verdict.go` tests untouched.
2. **Build smoke** — `go test -race ./...`, `go build ./...`, `docker compose build collector`.
3. **Sanity tier** — `bash scripts/stress-run.sh --tiers=10 --modes=throughput`. Expect PASS, `missing=0`, `trimmed=0`, P99 well under 1 s (v1 showed 4-9 s P99 due to polling delay; v2 should show <500 ms).
4. **Mid tier** — `bash scripts/stress-run.sh --tiers=1000 --modes=throughput,latency`. Expect PASS both rows, real P99 < 1 s (v1 showed 34 s).
5. **Full matrix** — `bash scripts/stress-run.sh`. Expect 10 k tier rows to show `missing=0`, `trimmed≈225000`, real latencies. Chaos run no longer aborts. Total runtime ≤ 10 min wall-clock.

## 13. Risks and known limitations

### Risks

- **Receiver back-pressure at 10 k**. If the receiver can't drain `XREAD` fast enough (≥10 k msg/s through a single goroutine + atomic operations), it falls behind. Mitigation: `COUNT 1000` per XREAD plus a single atomic-counter increment is comfortably <100 ns per message in Go; 10 k/s = 1 ms of receiver CPU per second of wall clock. Headroom is ~100×.
- **NATS purge timing race**. The purge runs after the collector exits; collector exit is gated on §6.3 pipeline quiescence (`num_pending==0` for ALO/EOE; source `XLEN==0` for AMO). For ALO/EOE this means no in-flight JetStream messages could be lost. For AMO, the purge intentionally discards the abandoned backlog — that loss is the AMO mode under test, not a measurement bug.
- **AMO end-of-run race**. As documented in §6.4, AMO can have ≤64 messages in-flight inside connect-sink at the moment §6.3 quiescence completes. These messages may land in `region-events` after `cancelRecv()` but before `XLEN`, inflating `Missing` by ≤64. AMO's verdict allows `missing > 0`, so the PASS/FAIL outcome is unaffected; only the precise missing-count is slightly noisier.

### Known limitations carried forward

- **Chaos timing drift** (docker compose run startup overhead). Unchanged from v1.
- **Connect Prometheus label summing**. Unchanged from v1; harmless because Connect metrics aren't part of the verdict.
- **Single-host single-replica NATS**. Unchanged.

## 14. Out of scope (deferred)

- A "soak" mode (5+ min sustained). Same v1 deferral.
- Per-tier comparative reports across multiple matrix runs.
- Variable payload sizes within a single run.
- Adjusting SLOs in `tier-defs.sh` based on the empirical v2 measurements — this is a separate follow-up that needs at least one full v2 matrix run to inform.
