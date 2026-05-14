# Research: Redis Streams multi-group fanout

## Topic

Redis Streams is an append-only log data type in Redis with built-in consumer-group semantics.

## Property demonstrated

Multiple consumer groups each independently read every message from one stream — one `XADD` produces a message that is observed once by every group.

## Concept summary

- A **stream** is an append-only log of entries. Each entry has a monotonically increasing ID (`<ms>-<seq>`) and a flat field/value map.
- A **consumer group** is a named bookmark over a stream. The group remembers the highest delivered ID and a Pending Entries List (PEL) of entries delivered but not yet acked.
- **Groups are fully independent.** Creating group A and group B against the same stream gives each its own cursor and PEL. The same `XADD` entry is readable by *both* groups.
- **Within one group**, an entry is delivered to exactly one consumer (load-balanced via consumer name). Two consumers in the same group split the work; two consumers in *different* groups each see the entry.
- An entry stays in a consumer's PEL until `XACK`'d. Unacked entries can be reclaimed by other consumers via `XCLAIM` / `XAUTOCLAIM`. This lab does not demonstrate reclaim — see "Deliberately excluded".

## Wire / API contract

Commands used by this lab:

- `XADD <stream> * <field> <value> [<field> <value> ...]` — append an entry. `*` lets Redis generate the ID. Returns the new ID.
- `XGROUP CREATE <stream> <group> $ MKSTREAM` — create a consumer group starting at the current end (only entries added *after* this command will be delivered). `MKSTREAM` creates the stream if it doesn't exist yet.
- `XREADGROUP GROUP <group> <consumer> COUNT <n> BLOCK <ms> STREAMS <stream> >` — read up to `n` entries not yet delivered to anyone in the group. `>` is the special ID meaning "new arrivals". `BLOCK <ms>` waits up to `ms` milliseconds.
- `XACK <stream> <group> <id>` — acknowledge entry, removing it from the consumer's PEL.

Primary references:
- [Redis Streams introduction](https://redis.io/docs/latest/develop/data-types/streams/)
- [XADD](https://redis.io/commands/xadd/), [XGROUP](https://redis.io/commands/xgroup/), [XREADGROUP](https://redis.io/commands/xreadgroup/), [XACK](https://redis.io/commands/xack/)

## Design decisions

- **Image:** `redis:7.4-alpine`. Redis 7.x is current stable; Streams API is unchanged since 5.0 but later versions get security fixes.
- **Topology:** 1 redis + 1 producer + 3 consumers (one per group). Three groups named `group-a`, `group-b`, `group-c`. Each group has exactly one consumer to keep the fanout demonstration unambiguous.
- **Three identical consumer services rather than one image with `replicas: 3`:** each consumer needs a distinct `GROUP_NAME` env var. Compose `replicas` would give identical env to all replicas. Three services with explicit env is clearer than templating.
- **Producer cadence:** one entry every 2 seconds, payload `{"n": <counter>, "ts": <unix>}`. Bounded by `MAX_MESSAGES` env (default 30) so the lab terminates naturally for the smoke test.
- **Group start position is `$`:** consumers see entries produced after they joined, not the entire history. The lab is about live fanout, not catch-up.
- **Language:** Go (user choice, matches production stack). Library: `github.com/redis/go-redis/v9` pinned to a current minor.
- **Smoke test asserts the property directly:** after the producer finishes (or after a bounded wait), each consumer's log must contain the same set of message IDs the producer wrote. The test reads `docker compose logs` and compares.

### Deliberately excluded

- **Reclaim / `XCLAIM` / `XAUTOCLAIM`** — entries stuck in PEL after a consumer crashes. Adding this would conflate fanout with failure-recovery. Separate lab.
- **Multiple consumers per group (load balancing)** — different property (partitioned consumption, not fanout).
- **`MAXLEN`/`MINID` trimming and persistence tuning** — operational concerns, not part of the fanout property.
- **Cluster mode** — Streams work the same conceptually in cluster; clustering would add complexity without changing the demonstrated property.
- **Replay from `0-0`** — different property (historical catch-up). A natural sibling lab.

## References

- [Redis Streams introduction](https://redis.io/docs/latest/develop/data-types/streams/) — primary.
- [Streams tutorial in Redis docs](https://redis.io/docs/latest/develop/data-types/streams-tutorial/) — primary, longer-form.
- [Command pages: XADD](https://redis.io/commands/xadd/), [XGROUP](https://redis.io/commands/xgroup/), [XREADGROUP](https://redis.io/commands/xreadgroup/), [XACK](https://redis.io/commands/xack/) — primary.
- [`go-redis/v9` package docs](https://pkg.go.dev/github.com/redis/go-redis/v9) — Go client API surface used by this lab.
