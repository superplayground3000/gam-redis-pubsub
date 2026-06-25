# CDC leg content logging — design

**Date:** 2026-06-25
**Branch:** master
**Scope:** `redis-cdc-le-k8s/chart/files/connect/cdc-forward.yaml`, `cdc-reverse.yaml`

## Goal

Make the data flowing through both CDC legs observable end-to-end by logging
**both** the Redis-side content and the NATS-side content of every message, at
`INFO`, using Redpanda Connect `log` processors. This is a debugging aid only —
`log` is a pass-through processor and changes no pipeline behavior.

## Background

The forward and reverse legs are Redpanda Connect **streams-mode** pipelines
(Bloblang YAML), POSTed at runtime by the elector sidecar over the streams REST
API. They are stored as chart files and embedded into a ConfigMap via
`.Files.Get` / `tpl`:

- **Forward leg** (`cdc-forward.yaml`): reads the central `app.events` Redis
  stream → a `mapping` builds a self-contained JSON envelope → publishes to NATS
  JetStream on `<subjectPrefix>.<op>` with `Nats-Msg-Id=event_id`.
- **Reverse leg** (`cdc-reverse.yaml`): binds a durable pull consumer on
  JetStream → stashes envelope fields into metadata → applies to region Redis via
  a `switch` (`SET`/`HSET` for create/update, `DEL` for delete, `EVAL` rename).

The shared logger config (`observability.yaml`) is `level: INFO, format: json`,
so `INFO` log lines are visible without config changes and integrate as
structured JSON.

## Design

Four `log` processors, two per leg, each emitting **complete** content via
`fields_mapping` (structured JSON fields, not a single raw string, to match the
json logger). Each line carries `leg` + `stage` labels for filtering.

**Gated off by default.** The dumped `body` is real application data (an
exposure risk) and emits one line per message (high log volume), so the
processors are wrapped in `{{- if .Values.connect.contentLog.enabled }}` and are
not rendered at all by default. Two new values keys:

- `connect.contentLog.enabled` — `false` by default; `true` renders the four
  processors.
- `connect.contentLog.level` — `INFO` by default; the level each content dump
  logs at when enabled.

Enable with `--set connect.contentLog.enabled=true` for transient data-flow
debugging; leave off in any shared/long-running deployment.

### Forward leg (`cdc-forward.yaml`)

1. **`redis_in`** — first processor, *before* the existing `mapping`. Dumps the
   inbound stream entry: `meta = metadata()` (all XADD fields: `event_id`, `op`,
   `kv_key`, `ts`, …) and `body = content().string()`.
2. **`nats_out`** — last processor, *after* the `mapping`. Dumps the envelope
   about to be published (`envelope = content().string()`) plus `subject_op` and
   `event_id` (the meta that drive subject interpolation + the dedup header).

### Reverse leg (`cdc-reverse.yaml`)

1. **`nats_in`** — new first processor, *before* the meta-stash `mapping`. Dumps
   the full inbound JetStream envelope (`envelope = content().string()`). This is
   the only point where the original NATS payload is intact — the later `redis`
   processor replaces content with the Redis reply.
2. **`redis_apply`** — *after* the meta-stash `mapping`. Dumps exactly what is
   about to hit region Redis: `op`, `type`, `kv_key`, `old_key`, `new_key`, and
   the full `body` value payload.

## Decisions

- **Commit-first git flow:** the unrelated uncommitted `internal/latency/stream.go`
  scientific-notation fix was committed to `le-failover-benchmark` first, then
  switched to `master` for this work.
- **Gated off by default** — code review (Codex stop-time) flagged unconditional
  INFO full-payload logging as a default data-exposure + log-volume regression.
  Resolved by gating behind `connect.contentLog.enabled` (default `false`) rather
  than shipping it always-on.
- **Log level configurable, default `INFO`** — when enabled, emits at
  `connect.contentLog.level` (default `INFO`, the level originally chosen), so a
  single `--set enabled=true` restores immediate visibility.
- **Full content** — dump everything (all fields + full body), not a key-field
  subset.
- **`fields_mapping` (structured)** rather than a raw interpolated string, so the
  output stays parseable JSON.

## Verification

- `helm template chart` renders with rc=0 in both states.
- Default (`enabled=false`): 0 content-log stages in the rendered ConfigMaps.
- `--set connect.contentLog.enabled=true`: all four stages (`redis_in`,
  `nats_out`, `nats_in`, `redis_apply`) appear with correct nesting under
  `pipeline.processors`, at `connect.contentLog.level` (verified INFO and DEBUG).

## Out of scope

- Bumping the logger to DEBUG/TRACE (not needed at INFO).
- Any change to apply semantics, ordering, or the latency sidecar stream.
