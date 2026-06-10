I'll verify a few version-specific and behavioral facts before answering, since this is a production-correctness question.Short answer: **no — NATS JetStream cannot compare a timestamp against a previously stored message and discard the older one. No such mechanism exists, in any version.** And injecting the timestamp at the *source* Redpanda Connect is also unsafe. The robust way to get "only the latest change per key wins" is a **last-write-wins (LWW) compare-and-set fence at the sink** (the final Redis KV write). This is actually a much better fit for your stated requirement than your current strict-ordering design, and it lets you *drop* most of the expensive ordering constraints.

Let me walk through why, then give you a production-grade design with versions, config, and monitoring.

## Why NATS can't do timestamp-conditional discard

JetStream is an append-only log. Its discard policies are **limit-triggered only** — they fire when `max_msgs`/`max_bytes`/`max_age` are exceeded, not on any comparison of message content. DiscardOld removes the oldest messages to make space; DiscardNew refuses any new messages. Neither inspects a timestamp.

The one subject-scoped variant is the trap people fall into here. `DiscardNewPerSubject` with `MaxMsgsPerSubject=1` does the **opposite** of what you want: if the stream's max-messages-per-subject limit is 1 and a message already exists for that subject, the publish call fails. That keeps the **oldest** message per subject and rejects everything newer — first-write-wins, not last-write-wins.

There's also the `Nats-Rollup` header, which lets a single new message replace all contents of a subject in a stream. But rollup replaces by *arrival order at the server*, never by event timestamp — so a stale, redelivered event arriving late would still roll up and clobber a newer value. It doesn't solve reordering either.

Bottom line: there is no server-side "apply only if newer" in NATS. The comparison has to happen somewhere that holds the current state of the key — and that's the sink.

## Why a source-side timestamp is also unsafe

Adding `now()` at the first Redpanda Connect stamps **processing time, not event time**, and your pipeline has a redelivery path. Concretely: a process crashes mid-batch, the Redis PEL entry is reclaimed (XAUTOCLAIM) and re-read later — it now gets a *fresh, later* timestamp than an event that was genuinely newer. The stale change would then win. Processing-time stamping silently corrupts LWW under exactly the failure modes you're building HA to survive.

Worse, you can't fall back to the Redis Stream entry ID (`<ms>-<seq>`), which *would* be a perfect monotonic source token, because Redpanda Connect's `redis_streams` input still doesn't expose it. The docs only state that the body key is extracted and all other key/value pairs are saved as metadata fields — there is no metadata key for the server-generated entry ID. I verified this against the current component reference.

So the version token must come from **the source of truth — the application doing the XADD** — as an event-time value or a logical version embedded in the payload.

## The better mechanism: an LWW fence at the Redis KV sink

Have the producer write a monotonic `version` field into the XADD payload. Carry it through the pipeline as metadata/header (same plumbing you already use for `event_id`). At the sink, apply the value with an **atomic Lua compare-and-set** that writes only if the incoming version is strictly greater than the stored one.

```lua
-- lww_set.lua  -- KEYS[1]=key  ARGV[1]=value  ARGV[2]=version (monotonic integer)
local cur = redis.call('HGET', KEYS[1], 'ver')
if cur == false or tonumber(ARGV[2]) > tonumber(cur) then
  redis.call('HSET', KEYS[1], 'val', ARGV[1], 'ver', ARGV[2])
  return 1   -- applied
end
return 0     -- stale write rejected
```

Why this is the correct layer:

- **Order-independent.** Messages can arrive in any order across instances, partitions, and retries. The stored `ver` only ever moves forward, so no older change can ever land after a newer one — which is exactly your requirement, and nothing weaker.
- **Redelivery-safe and idempotent.** A duplicate has `version == ver`, so `>` rejects it. You no longer depend on JetStream's `duplicate_window` for correctness (keep a small one only to cut redundant sink work).
- **Atomic by construction.** Redis executes the script to completion single-threaded; in Cluster the key maps to one slot whose owner serializes concurrent writers. The script touches a single key, so it's Cluster-safe with no hash-tag gymnastics.
- **It lets you delete the expensive ordering machinery.** This is the big payoff. Because correctness now lives at the sink, you can drop `pipeline.threads: 1`, `max_in_flight: 1`, `MaxAckPending: 1`, the per-partition `FilterSubject` durable consumers, and the partition-by-key routing token. You can run parallel queue-group consumers and high `max_in_flight` everywhere. The CAS is the only synchronization point, and Redis already serializes per key for free.

### Choosing the version token (this is the one thing to get right)

- **Best:** a per-key logical version the app owns (e.g. `HINCRBY versions <key> 1` before XADD, or a per-key counter from the writer that owns that key). Clean integer comparison, no clock dependence.
- **Acceptable:** event-time in epoch nanoseconds **plus a tiebreaker**. Bare millisecond timestamps collide for rapid updates — encode `(ms, seq)` and compare lexicographically, or use ns resolution.
- **Watch out for clock skew.** If *multiple hosts* can write the same key with wall-clock timestamps, skew can invert order — the classic LWW hazard. Since your design already partitions by key, route each key through a single writer and use a per-key counter; then monotonicity is guaranteed without trusting clocks.
- **Deletes:** if keys can be deleted and recreated, store a tombstone carrying the version too, so a late stale write can't resurrect an old value.

### Sink config (second Redpanda Connect)

The producer's `version` field arrives as `meta("version")`. Use the `redis` processor with `eval` (use `evalsha` + a one-time `SCRIPT LOAD` in production):

```yaml
pipeline:
  processors:
    - redis:
        url: redis://kv.internal:6379
        kind: cluster
        command: eval
        args_mapping: |
          root = [
            file("/etc/rpconnect/lww_set.lua"),   # or the script inline; prefer evalsha
            1,
            meta("kv_key"),
            content().string(),
            meta("version")
          ]
        result_map: 'meta lww_applied = this'      # 1 = applied, 0 = stale-dropped
```

## Minimum versions

| Capability | Component | Minimum |
|---|---|---|
| Lua `EVAL`/`EVALSHA` (the CAS) | Redis | 2.6.0 (trivially met) |
| `FUNCTION`/`FCALL` (optional, nicer deploy) | Redis | 7.0 |
| Streams source | Redis | 5.0 |
| `redis` processor (`command`+`args_mapping`) | Redpanda Connect | present in your 4.x baseline; keep ≥ 4.38.0 |
| Header interpolation to carry `version` as a NATS header | Redpanda Connect | 4.1.0 |
| `nats_jetstream` input/output | Redpanda Connect | 3.46.0 |
| (Only if you also want a per-subject "latest cache" in NATS for storage bounding — *not* for correctness) | NATS Server | 2.9.0 |

Note that NATS needs **no special version** for this design, because the fence isn't in NATS — it's pure transport now. You can keep `RetentionPolicy=limits` with `MaxMsgsPerSubject` and `DiscardOld` purely to bound storage; that's storage hygiene and is fully compatible with sink-side LWW.

## Production readiness — what to monitor

The valuable new signal is the **stale-write rejection rate**, which the script hands you directly via its return value (`meta lww_applied`). Feed it into a counter.

| Signal | Source | What it tells you / threshold |
|---|---|---|
| Stale-write rejection rate (`lww_applied == 0`) | Redpanda Connect metric off the script result | Expected to be non-zero under reordering — that's the system working. Alert on a sudden spike (could indicate a stuck/slow partition replaying old data) or on it being *always* zero (version field may be missing). |
| Version-regression assertion | optional guard in the Lua (log if a write with lower version is ever seen as winner) | Must be impossible by construction; any hit is a real bug or a non-monotonic producer. |
| End-to-end propagation latency | event-time in payload vs apply-time at sink (compute in Bloblang, export histogram) | p99 staleness of the KV value; your real freshness SLA. |
| `output_error`, `output_latency_ns` p99, `output_connection_*` | Prometheus `:4195/metrics` | Sink/transport health; non-zero error rate, p99 > ~100 ms. |
| Redis Stream PEL depth / max idle | `XPENDING` via `oliver006/redis_exporter` | Backlog and stranded entries; sustained growth. |
| JetStream `num_pending`, `num_ack_pending` | `prometheus-nats-exporter` / `nats consumer info` | Transport lag (trend, not absolute). |
| Sink Redis health (cmd rate, memory, slowlog) | `redis_exporter` | Lua scripts show in slowlog if they ever block. |

Validation test (mirror of your existing dedup test): publish three changes to one key with versions 3, 1, 2 in that arrival order; assert the stored value corresponds to version 3 and the two later writes were rejected (`lww_applied=0`).

## Operational effort comparison

Sink-side LWW is *less* operational burden than your current strict-ordering path, not more. You're trading away: per-partition durable consumer management, `MaxAckPending: 1` (a throughput killer), `threads: 1`/`max_in_flight: 1` everywhere, the routing-token plumbing, and the per-partition lag heatmaps needed to babysit it. You're adding: one Lua script (version-controlled, loaded via `SCRIPT LOAD`/`FUNCTION`), one metric, and a hard contract that the producer always emits a monotonic `version`. The producer contract is the main thing to enforce in review/CI — same discipline you already apply to `event_id`.

## Optional throughput optimization: conflation

Since only the latest change per key matters, you can *collapse* multiple updates to the same key within a short batch window before publishing (a windowed `group_by` keeping max-version per key, or a dedupe cache keyed by `kv_key`). This cuts downstream volume and sink writes substantially for hot keys. It's strictly an optimization — the sink CAS still does the correctness work, because conflation can't see across windows or instances.

---

If it's useful, I can write this up as a design-doc section (the LWW fence, version-token contract, Lua function deployment, and the monitoring panel definitions) to slot into your existing research doc — say the word and I'll generate the file.
