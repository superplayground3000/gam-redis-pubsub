# redis-connect-lww-multi-k8s

## What this demonstrates

Horizontally scaling the **relay** tier — **3 `connect-source` + 3 `connect-sink`**
replicas — preserves the last-write-wins compare-and-set fence exactly: a stale
change (lower version) can never overwrite a newer change at the Redis KV sink,
even when same-key messages are consumed and applied concurrently by *different*
pods. Correctness lives in Redis's atomic per-key `EVAL` (`lww_set.lua`), not in
the pipeline, so it is independent of pod count and arrival order.

The contrast is the point: scaling the **writer** is *not* safe. A negative proof
(Proof C) shows that two uncoordinated writers reaching the same version `K`
silently lose one of the two version-`K` values — and a version-only check reports
`mismatches=0` (a false PASS) anyway. The fence is safe under multi-**connect**
precisely because connect never violates the single-writer-per-key precondition;
multi-**writer** does.

Kubernetes/Helm fork of `../redis-connect-lww-k8s` (single-instance). The only
data-path delta is the sink input adding a `queue` deliver group so all sink pods
share one JetStream durable. Mechanism is from
`../../last-write-wins-lab/research.md`.

## Run it (kind)

```bash
# (NATS auth fixtures are committed under chart/files/nats-auth/; regenerate only
#  on a fresh checkout if missing: scripts/gen-nats-auth.sh)
kind create cluster --name lwwm
scripts/build-images.sh --kind --kind-name=lwwm        # build writer/verifier/dashboard, load into kind
RRCS_NS=lwwm-k8s RRCS_RELEASE=lwwm scripts/verify-lww.sh   # Proof A + Proof C + Proof B'
```

Tune the run with env vars: `RATE=20000 DURATION_S=30 RRCS_NS=lwwm-k8s RRCS_RELEASE=lwwm scripts/verify-lww.sh`
(defaults: RATE=5000, DURATION_S=30, WARMUP_S=5, DRAIN_S=10 — see `scripts/lib/run-defaults.sh`).

Watch it live in a browser:

```bash
scripts/dashboard-forward.sh        # binds --address 0.0.0.0; prints LAN URLs
# open http://<host>:8080  → live key/version/value stream + applied/stale-fenced/duplicate counters
```

## Expected output

`verify-lww.sh` exits 0 only when all three proofs pass:

- **Proof A** — deterministic mechanism: apply versions 3,1,2 + replay 3 to one
  key, direct to redis-region → `1 0 0 -1`, final `ver=3 val=v3`. The fence works
  in isolation.
- **Proof C** — deterministic negative: two uncoordinated writers on one key,
  interleaved versions `1..K`. Asserts the version-only check passes
  (`mismatches=0`) yet exactly one writer's version-`K` value survives — the other
  was silently dropped as a `duplicate`. This is the lost update the version-only
  proof instrument cannot see; it is why the single-writer-per-key precondition is
  load-bearing.
- **Proof B′** — end-to-end positive under inter-pod concurrency: drive the writer
  through the real 3-source + 3-sink pipeline, wait for quiescence, compare every
  key's region version to the writer's source max. Pass requires `mismatches == 0`
  **and** `stale > 0`, with `lww_apply` metrics **summed across all sink pods**
  (via the headless Service) and the precondition guards holding (fresh epoch
  namespace, writer `boot_id` unchanged, store empty at start, pipeline quiesced,
  per-pod restart guard).

The harness prints a `RESULT_JSON` line whose `.lww` object carries
`rate_achieved_avg`, `stale`, `duplicate`, `mismatches`, `writes_per_key_avg` and
a `.verdict`. The actual numbers come from your run — they are not reproduced here
until this lab has been validated end-to-end on kind (see `RESEARCH.md` →
Validated result).

## Dashboard caveat

The dashboard scrapes the round-robin ClusterIP Service, so it shows **one pod's**
counters at a time — it under-reports applied/stale totals across a 3-pod sink.
The verifier, which sums per-pod metrics across all sink pods via the headless
Service `lab-connect-sink-headless`, is the authoritative aggregator for the
proof. Use the dashboard for a live qualitative view, not for the proof numbers.

## Inconclusive runs

If a run prints `verdict.pass=false reason="inconclusive — no strictly-older
arrival observed"`, the keyspace was too large to force reordering for that
rate/duration — lower `KEY_SPACE_SIZE` or raise `RATE`/`DURATION_S` (the default
keyspace is tuned to reorder reliably; see the comment in `chart/values.yaml`).

## Validation note

This is a Kubernetes lab, so the research-lab skill's `validate_lab.sh`
(docker-compose only) does **not** apply. `scripts/verify-lww.sh` is the
validation: it exits 0 only when Proof A passes, Proof C exposes the lost update,
**and** Proof B′'s verdict is `pass:true` (which requires the precondition guards
to hold, `stale > 0`, and metrics summed across all sink pods).

## Teardown

```bash
helm uninstall lwwm -n lwwm-k8s
kind delete cluster --name lwwm
```

## Further reading

- `RESEARCH.md` — the multi-instance property, the two inter-pod reorder vectors,
  the Proof C negative finding, and the precondition guards.
- `../../docs/superpowers/specs/2026-06-05-redis-connect-lww-multi-k8s-design.md` — this lab's spec.
- `../redis-connect-lww-k8s/` — the single-instance parent lab.
- `../../last-write-wins-lab/research.md` — upstream design (why NATS/source-timestamp don't work).
