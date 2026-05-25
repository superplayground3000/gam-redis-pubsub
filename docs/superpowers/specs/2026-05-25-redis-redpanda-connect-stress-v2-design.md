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

```
1. Trim app.events                      (existing)
2. Trim region-events                   (existing)
3. PostReset                            (existing)
4. receiver := NewReceiver(...)         (NEW)
5. receiverCtx, cancelRecv := WithCancel(ctx)
6. go receiver.Run(receiverCtx)         (NEW)
7. PostRate(tier/2); sleep(warmup)      (existing)
8. PostRate(tier); sustain ticker loop  (existing)
9. PostRate(0); drain ticker loop       (existing)
10. time.Sleep(500ms)                   (NEW — last-chance tail flush)
11. cancelRecv()                        (NEW)
12. wait for receiver.Run to return     (NEW — see §6.1)
13. buildReport(...receiver...)         (modified)
```

### 6.1 Receiver goroutine join

`receiver.Run` is wrapped in a `sync.WaitGroup` so step 12 is `wg.Wait()`. This guarantees no in-flight `XREAD` is still running when `buildReport` reads `receiver.Count()` / `receiver.Latency()`, eliminating a TOCTOU race where the count could change between read and report.

### 6.2 Why 500 ms post-drain sleep

`XREAD BLOCK 250ms` means the receiver checks for new messages roughly every 250 ms. If a message lands in `region-events` at drain-end and we cancel immediately, the receiver might exit before its next XREAD cycle picks it up. Sleeping 500 ms (= 2× block window) gives the receiver one more guaranteed cycle before cancellation.

## 7. Report semantics changes

### 7.1 Field meaning changes (no schema add/remove yet)

| Field | v1 meaning | v2 meaning |
|---|---|---|
| `received` | `XLEN(region-events)` at end of run | total messages observed by streaming consumer (untainted by MAXLEN) |
| `missing` | `sent − received` (false-positive on trim) | true in-transit loss |
| `latency_ms.{p50,p95,p99,max,samples}` | poll-window-biased percentiles, ~2-20% of messages sampled | real per-message e2e percentiles over **every** delivered message |

### 7.2 New fields in `Report`

```go
type Report struct {
    ...existing fields...
    ReceivedErrors  int64 `json:"received_errors"` // transient XREAD errors from receiver
    Trimmed         int64 `json:"trimmed"`         // = max(0, received - region_xlen_final)
}
```

`trimmed` is informational. It's `received − region_xlen_final`, clamped to `[0, +∞)`. If positive (10 k tier), the report tells operators "this many messages were delivered but trimmed by MAXLEN" — the silent v1 failure mode becomes a visible diagnostic. If zero (low tiers), nothing notable.

`received_errors` lets operators see when the receiver itself had trouble (network blip, redis restart during chaos drill). The count is **not** used to compute the verdict.

### 7.3 `buildReport` changes (collector main.go)

Replace:
```go
r.Received = last.RegionXLen
r.Redis.RegionXLenFinal = last.RegionXLen
```

With:
```go
r.Received       = receiver.Count()
r.ReceivedErrors = receiver.Errors()
r.Redis.RegionXLenFinal = last.RegionXLen
r.Trimmed = r.Received - r.Redis.RegionXLenFinal
if r.Trimmed < 0 {
    r.Trimmed = 0
}
r.Latency = receiver.Latency()  // was: latency tracker from sampler
```

The rest of `buildReport` is unchanged — `Sent`, `Missing = Sent - Received` clamped, `MissingPct`, rate avg/min from sustain-window snapshot deltas, max XLen, max NATS pending, chaos block, verdict computation.

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

In `run_one`, after the `docker compose run --rm collector ...` invocation and after the `wait "${chaos_pid}"` block, add a single line:

```bash
docker exec rrcs-nats nats --server nats://nats:4222 stream purge APP_EVENTS -f >/dev/null 2>&1 \
  || echo "[purge] WARN: nats stream purge APP_EVENTS failed (continuing)" >&2
```

The purge is non-fatal. If it fails (first-run state, transient docker exec issue), the pre-flight check on the next run will catch a genuinely-broken NATS state. Quiet output on success.

### 9.1 What stays

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
│   ├── receiver.go            NEW (~70 LOC)
│   ├── receiver_test.go       NEW (~50 LOC, no Redis needed — exercises a small in-memory helper)
│   ├── snapshot.go            MODIFIED — drop latency/lastID, shrink Sampler
│   ├── main.go                MODIFIED — receiver lifecycle, buildReport fields
│   └── report.go              MODIFIED — add ReceivedErrors, Trimmed fields
├── scripts/
│   └── stress-run.sh          MODIFIED — purge between runs, +1 column in summary
├── README.md                  MODIFIED — document the new fields and what trimmed=N means
└── RESEARCH.md                MODIFIED — explain v2 measurement-vs-pipeline distinction
```

No changes to: writer (any file), connect YAMLs, docker-compose.yml, .env.example, tier-defs.sh, kill-connect-sink.sh, latency.go, verdict.go, redis.go, scrapers.go, nats.go.

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
- **NATS purge timing race**. If the purge runs while connect-source is still flushing, some in-flight messages could be lost across the boundary. Mitigation: the purge runs *after* the collector finishes (which includes drain + 500 ms tail), so by that point connect-source has no in-flight work; `app.events` is also trimmed at the start of the next run.

### Known limitations carried forward

- **Chaos timing drift** (docker compose run startup overhead). Unchanged from v1.
- **Connect Prometheus label summing**. Unchanged from v1; harmless because Connect metrics aren't part of the verdict.
- **Single-host single-replica NATS**. Unchanged.

## 14. Out of scope (deferred)

- A "soak" mode (5+ min sustained). Same v1 deferral.
- Per-tier comparative reports across multiple matrix runs.
- Variable payload sizes within a single run.
- Adjusting SLOs in `tier-defs.sh` based on the empirical v2 measurements — this is a separate follow-up that needs at least one full v2 matrix run to inform.
