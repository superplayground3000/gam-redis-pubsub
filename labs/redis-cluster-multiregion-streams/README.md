# redis-cluster-multiregion-streams

## What this demonstrates

In a 3-master Redis Cluster spanning regions, a stream's owning shard governs per-operation latency from every region's client; co-locating a Redis node with each region buys nothing for the 2/3 of streams whose hash tag does not land on that region's master.

## Run it

```bash
cp .env.example .env       # only if you want to override latency or thresholds
docker compose up -d --wait
docker compose logs -f client-a client-b client-c
```

To bump the "far" latency to the 5-second scenario from the original prompt:

```bash
LATENCY_FAR_MS=5000 docker compose up -d --wait
```

## Expected output

After a couple of measurement ticks, each client emits two summary lines per tick:

```
region=a tick=3 XADD: redis-a=   2.1ms redis-b= 202.5ms redis-c=1003.0ms
region=a tick=3 READ: redis-a=   1.8ms redis-b= 201.0ms redis-c=1002.4ms
region=b tick=3 XADD: redis-a= 202.0ms redis-b=   2.0ms redis-c=1002.5ms
region=b tick=3 READ: redis-a= 202.2ms redis-b=   1.7ms redis-c=1002.0ms
region=c tick=3 XADD: redis-a=1002.7ms redis-b= 202.4ms redis-c=   2.0ms
region=c tick=3 READ: redis-a=1002.4ms redis-b= 202.0ms redis-c=   1.9ms
```

Two things to notice:

1. The diagonal (`region=a → redis-a`, `region=b → redis-b`, `region=c → redis-c`) is fast because each region's own toxiproxy injects the LOCAL latency on the path to that region's own master.
2. The off-diagonal cells are slow — same stream, observed from a non-owning region, pays full WAN RTT. *Having a Redis container in your region buys you nothing* unless the stream's hash-tag happens to land on it.

The latencies shown are ROUND-TRIP (one full XADD command's RTT through toxiproxy). With default config `LATENCY_LOCAL_MS=1`, `LATENCY_MID_MS=100`, `LATENCY_FAR_MS=500`, the toxic adds the configured value in each direction, so observed RTT is roughly 2× the configured one-way.

Run the smoke test to assert the asymmetry programmatically:

```bash
bash scripts/smoke-test.sh
```

## Teardown

```bash
docker compose down -v
rm -rf shared/cluster-ready shared/proxies-ready shared/tags.json shared/measurements.jsonl
```

## Further reading

- [Redis Cluster specification](https://redis.io/docs/latest/operate/oss_and_stack/reference/cluster-spec/) — hash slots, MOVED/ASK, gossip.
- [Redis Streams](https://redis.io/docs/latest/develop/data-types/streams/) — append-only log + consumer groups.
- [Toxiproxy](https://github.com/Shopify/toxiproxy) — userspace TCP fault injection used to model WAN latency.
- `RESEARCH.md` in this directory — the design and what was deliberately left out.
