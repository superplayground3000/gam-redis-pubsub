# Multi-env worked example — one source, two sink shapes

The three values files in this directory build the canonical mixed-sink
topology from `docs/design/multi-env-mixed-sink/design.md`:

```
 source Redis ──▶ publisher (forward, serialized) ──▶ ONE JetStream stream
                                                      │  kv.cdc.aio.<kv_prefix>.<op>
                                       server-side fan-out (per-durable cursors)
                        ┌─────────────────────────────┴────────────────────┐
                        ▼                                                  ▼
          AIO env  (values-sink-aio.yaml)             sharded env (values-sink-sharded.yaml)
          1 durable: cdc_sink_aioenv                  6 durables: ..._lb_company_s0..s3, _sx,
          filter kv.cdc.aio.>  (superset)                         ..._others (precise filters)
          → its own region Redis                      → its own region Redis, per-key order
```

| file | role | consumers |
|---|---|---|
| `values-publisher.yaml` | the ONE source-side release: forward leg + taxonomy (family `lb:company` N=4, segment `aio`) + topology manifest | 0 (sink disabled) |
| `values-sink-aio.yaml` | env `aioenv`: all-in-one + DLQ | 1 |
| `values-sink-sharded.yaml` | env `shardenv`: sharding v2 + DLQ | 6 (s0–s3 + sx + others) |

## Render them

```bash
helm template pub   chart/ -f chart/examples/multi-env/values-publisher.yaml
helm template aio   chart/ -f chart/examples/multi-env/values-sink-aio.yaml
helm template shard chart/ -f chart/examples/multi-env/values-sink-sharded.yaml
```

## Why one forward serves both shapes

The forward publishes each event ONCE, always in the finest-grained subject
form — the shard token is folded into the subject at publish time
(`kv.cdc.aio.lb.company.s2.create`; non-family → `kv.cdc.aio.others.create`).
Consumers pick their view purely by filter: the AIO durable's `kv.cdc.aio.>`
is a superset that absorbs the shard tokens as extra wildcard tokens; the six
sharded durables each bind one precise filter whose union covers the same
space. JetStream keeps an independent cursor (ack floor) per durable, so each
env gets a full copy without the publisher knowing either of them exists.

Costs and guards to be aware of (all render-enforced or manifest-enforced):

- Declaring ANY family serializes the forward (`threads: 1`,
  `max_in_flight: 1`) — a global ~1/RTT throughput ceiling shared by BOTH
  envs, AIO included (ordering links O-3/O-4, INV-1 row 13).
- Each env's durable names carry its `connect.envId`; DLQ lanes and park
  msg-ids are env-scoped too, so two envs parking the SAME poison event never
  dedup-collide.
- The topology manifest (`nats.topologyManifest.enabled`) makes a sink whose
  family N drifts from the publisher FAIL CLOSED at init — without it, a
  drifted sink silently strands traffic on unconsumed shard subjects until
  stream max-age.
- Exactly ONE publisher release per stream.

## Runtime proof

`RRCS_NS=cdc-menv scripts/verify-multi-env.sh` deploys this exact topology
(publisher+sharded combined + an external AIO sink release) in kind and
asserts fan-out, disjoint durables, cross-env poison parking with no dedup
swallow, isolation, and the manifest fail-closed gate.
