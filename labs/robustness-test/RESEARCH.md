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
