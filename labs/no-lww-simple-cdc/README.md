# no-lww-simple-cdc

## What this demonstrates

A fence-free CDC relay: a writer dual-writes each `create`/`update`/`delete`/
`rename` to **central** Redis KV and emits a CDC envelope to a Redis Stream;
**one** Redpanda Connect source publishes to NATS JetStream (with `Nats-Msg-Id`
dedup); **one** Connect sink switches on `op` and applies `SET`/`DEL`/rename-Lua
to **region** Redis KV — with **no last-write-wins fence**. Stale overwrites and
delete-resurrection are accepted and shown live as central-vs-region divergence.

Kubernetes/Helm fork of `../redis-connect-lww-multi-k8s` with the LWW fence
removed and the topology reduced to single-source/single-sink.

## Run it (kind)

```bash
kind create cluster --name cdc
scripts/build-images.sh --kind --kind-name=cdc        # build writer/verifier/dashboard, load into kind
# NATS auth fixtures are committed; regenerate only on a fresh checkout if missing:
#   scripts/gen-nats-auth.sh --force
RRCS_NS=cdc-k8s RRCS_RELEASE=cdc scripts/verify-cdc.sh
```

`verify-cdc.sh` boots the chart (`profile=cdc`), runs the verifier Job, and exits
0 only when all three checks pass (dedup, per-op-under-quiescence, idempotent
replay).

## Drive it by hand

`scripts/insert-msgs.sh` **prints** ready-to-run `redis-cli XADD` commands (one
per op + a 5× dedup test) — copy and run them yourself; the script never executes
them:

```bash
scripts/insert-msgs.sh
```

## Watch central vs region live

```bash
scripts/dashboard-forward.sh        # binds 0.0.0.0; open http://<host>:8080
```

The dashboard shows central key count, region key count, and divergence
(only-central / only-region / differing), per-op sink applies, and a live region
key-change feed.

## HTML report

```bash
RRCS_NS=cdc-k8s RRCS_RELEASE=cdc scripts/gen-report.sh   # writes reports/cdc-report.html
```

## Validation note

This is a Kubernetes lab, so the research-lab skill's `validate_lab.sh`
(docker-compose) does not apply. `scripts/verify-cdc.sh` is the validation: exit
0 requires dedup + per-op + replay all green.

## Expected output

`verify-cdc.sh` prints a `RESULT_JSON` line; its `.cdc` object carries
`dedup_delta`, `ops_ok`, `replay_ok`, and `.verdict`. Actual numbers come from
your run — see `RESEARCH.md` → Validated result once the lab has been run on kind.

## Teardown

```bash
helm uninstall cdc -n cdc-k8s
kind delete cluster --name cdc
```

## Further reading

- `RESEARCH.md` — the property, wire contract, and order-insensitive PASS bar.
- `../redis-connect-lww-multi-k8s/` — the parent (LWW) lab.
