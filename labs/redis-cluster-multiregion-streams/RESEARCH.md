# Research: Redis Cluster, multi-region, streams

## Topic

Redis Cluster is Redis's built-in horizontal sharding mode. The 16384 hash slots are partitioned across master nodes; every key (including every Stream key) has exactly one owning master determined by `CRC16(key) % 16384`. This lab places three masters in three simulated regions with WAN latency on the *client → shard* path.

## Property demonstrated

In a 3-master Redis Cluster spanning regions, a stream's owning shard governs per-operation latency from every region's client; co-locating a Redis node with each region buys nothing for the 2/3 of streams whose hash tag does not land on that region's master.

## Concept summary

- A **stream key in Redis Cluster lives on exactly one master shard**, decided by `CRC16(key) % 16384`. It is *not* replicated to the other masters. A consumer reading via `XREAD` / `XREADGROUP` is always talking to the owning shard, regardless of which region the consumer is in.
- A `{hash-tag}` in the key name forces routing to use *only* the tag's CRC16. `stream:{ax9}` and `consumer-group:{ax9}` therefore both live on the same shard — useful for forcing related keys to one node, also useful here for pinning a stream to a chosen shard deterministically.
- **Consumer-group state** (last-delivered-ID, Pending Entries List) is stored alongside the stream on the owning shard. Every `XACK` and `XREADGROUP > ` from any region traverses the network to that shard.
- A cluster client (e.g., `go-redis/v9 ClusterClient`) caches the slot→node map after one `CLUSTER SHARDS` (or `CLUSTER SLOTS`) round trip, then routes each command to the owning shard directly. Per-request latency is therefore `RTT(client, owning_master) + server_processing`, with the RTT term dominating in WAN scenarios.
- Redis 7.0+ exposes `cluster-announce-hostname` and `cluster-preferred-endpoint-type hostname`. With both set, the cluster returns DNS names instead of IPs in `CLUSTER SHARDS`. This is what lets a single cluster look like three different sets of addresses to three different Docker networks, which is in turn what lets us model per-region latency without modifying the host.

## Wire / API contract

Commands and config directives used by this lab:

- `XADD <key> * <field> <value> ...` — append entry to stream. Returns `<ms>-<seq>` ID. ([XADD](https://redis.io/commands/xadd/))
- `XREVRANGE <key> + - COUNT 1` — read most-recent entry. Used as the latency probe for "replay from stream." ([XREVRANGE](https://redis.io/commands/xrevrange/))
- `CLUSTER KEYSLOT <key>` — return the slot for a given key. Used by `cluster-init` to pick hash tags that land on each shard. ([CLUSTER KEYSLOT](https://redis.io/commands/cluster-keyslot/))
- `CLUSTER SHARDS` — modern topology discovery; returns `[{slots, nodes:[{id, endpoint, ip, hostname, port, role, ...}]}]`. Clients should use hostname when `cluster-preferred-endpoint-type` is `hostname`. ([CLUSTER SHARDS](https://redis.io/commands/cluster-shards/))
- `cluster-announce-hostname <name>` (redis.conf) — the DNS name this node advertises in cluster API responses.
- `cluster-preferred-endpoint-type hostname` (redis.conf) — tell the cluster to surface hostnames as the canonical endpoint in `CLUSTER SHARDS`/`CLUSTER SLOTS`.
- `cluster-port <port>` (redis.conf, Redis 7+) — explicit cluster bus listen port, separate from client port.
- `cluster-announce-port` / `cluster-announce-bus-port` — what to advertise to peers.

Hash-tag rule (from [Redis keys with hash tags](https://redis.io/docs/latest/operate/oss_and_stack/reference/cluster-spec/#hash-tags)): if the key contains `{tag}`, only the substring inside the first balanced pair of braces is hashed. So `stream:{ax9}` hashes the same as `consumer-group:{ax9}`, both go to the shard owning `CRC16("ax9") % 16384`.

Primary references:
- [Redis Cluster specification](https://redis.io/docs/latest/operate/oss_and_stack/reference/cluster-spec/)
- [Redis Cluster tutorial](https://redis.io/docs/latest/operate/oss_and_stack/management/scaling/)
- [Redis Streams introduction](https://redis.io/docs/latest/develop/data-types/streams/)
- [Toxiproxy README](https://github.com/Shopify/toxiproxy) — `latency` toxic semantics.

## Design decisions

- **Topology: 3 masters, no replicas.** The property is about shard ownership, not failover. Adding replicas would add complexity without adding observability for the chosen property.
- **Images pinned**: `redis:7.4-alpine`, `ghcr.io/shopify/toxiproxy:2.9.0`, `golang:1.23-alpine` (build), `alpine:3.20` (runtime).
- **Per-region toxiproxy + per-network DNS aliases**: each `region-X-net` aliases all of `redis-a.local`, `redis-b.local`, `redis-c.local` to that region's toxiproxy. On `cluster-bus-net` the same names resolve to the actual redis containers, so node-to-node cluster bus traffic incurs no added latency. This is what makes per-region asymmetric latency possible while still presenting a single coherent Redis Cluster to clients.
- **Distinct Redis ports per node (6001/6002/6003) + matching `cluster-port`/announce-port settings.** A single toxiproxy listener routes by destination port to the right upstream redis, which is necessary because all three `redis-X.local` aliases inside one region collapse to one toxiproxy IP.
- **Dynamic hash-tag selection in `cluster-init`.** `redis-cli --cluster create` decides the slot split at runtime, so the lab probes `CLUSTER KEYSLOT` against candidate tags and emits `tags.json` with one tag per shard. Hard-coding CRC16 values would couple the lab to an undocumented slot-split heuristic.
- **Latency: one-way `latency` toxic on the toxiproxy upstream**, default `1 ms` local / `100 ms` mid / `500 ms` far. Tunable via `.env` (e.g., `LATENCY_FAR_MS=5000` for the original prompt's 5s scenario). Round-trip latency observed by the client is roughly 2× the configured one-way value plus negligible Redis processing time.
- **One client process per region, both writer and reader.** Each tick: write to all three streams, read most recent from all three streams, emit JSON-Lines measurements. One container per region keeps the topology obviously symmetric; splitting writer and reader containers would add files without adding clarity.
- **Smoke test reads structured JSON-Lines from a shared volume**, not container logs. JSON survives log driver / log rotation quirks and the assertion code stays readable. Each client appends one line per measurement to `/shared/measurements.jsonl`.
- **No `cap_add`, no privileged containers, no host networking, no `tc netem`.** Latency injection is fully userspace via toxiproxy. The lab works on any Docker host without granting capabilities or loading kernel modules.

### Deliberately excluded

- **Cluster-bus instability under WAN latency.** A separate lab (option B from clarification) would model `cluster-node-timeout` flapping. Adding it here would conflate "shard locality" with "false failover" — both interesting, neither cleanly observable when mixed.
- **Failover behavior.** No replicas → no failover. Killing a master in this lab makes its slot range unavailable, which is honest but isn't what we set out to demonstrate.
- **Read-from-replica.** `READONLY`/replica reads could in principle let a region read from a local replica of a stream owned elsewhere — but this only helps reads, not writes; only works with replicas under non-trivial consistency caveats; and is a different lab.
- **MOVED / ASK redirect storms.** No resharding during the demo. The slot map is created once and stable.
- **Active-active multi-region replication** (Redis Enterprise CRDTs, or app-level event forwarding). Both are valid answers to the user's underlying concern but are *alternatives* to Redis Cluster across regions, not properties of it. They warrant their own lab(s).
- **Persistence and durability.** AOF/RDB off; the lab is ephemeral.
- **Auth.** No `requirepass` or ACLs. Adds noise; not relevant to the property.

## References

- [Redis Cluster specification](https://redis.io/docs/latest/operate/oss_and_stack/reference/cluster-spec/) — slot routing, gossip, MOVED/ASK protocol.
- [Redis Cluster tutorial](https://redis.io/docs/latest/operate/oss_and_stack/management/scaling/) — `redis-cli --cluster create` walkthrough.
- [Redis Streams](https://redis.io/docs/latest/develop/data-types/streams/) — append-only log + consumer groups.
- [`cluster-announce-hostname` design](https://github.com/redis/redis/pull/9530) — Redis 7.0 PR introducing hostname-mode cluster endpoints.
- [`CLUSTER SHARDS`](https://redis.io/commands/cluster-shards/) — modern topology API.
- [Toxiproxy](https://github.com/Shopify/toxiproxy) — userspace TCP fault injection; `latency` toxic.
- [`go-redis/v9` ClusterClient](https://pkg.go.dev/github.com/redis/go-redis/v9) — cluster discovery + routing.
