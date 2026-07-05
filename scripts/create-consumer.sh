#!/usr/bin/env bash
# create-consumer.sh — FORMS (and optionally runs) the `nats consumer add` command
# that pre-creates the durable PULL consumer the sink binds to (bind:true).
#
# Why this exists: the nats_jetstream input does NOT create a pull consumer, it
# only ATTACHES to one. The bundled chart's nats-init Job already creates/reconciles
# it automatically; this script is the manual equivalent for an EXTERNAL NATS (or
# for re-creating the consumer by hand after `nats consumer rm`). All consumer
# params must be set here server-side — in pull(bind) mode Redpanda Connect ignores
# deliver/ack_wait/max_ack_pending in the input YAML. See
# helm-relese/connect-pull-consumer-mode.md.
#
# Defaults mirror chart/values.yaml (nats.stream.*). Override via env. The
# command is PRINTED for copy-paste; set RUN=1 to also execute it here.
#
#   # against external NATS with an admin/manage creds file:
#   NATS_CLI="nats --server nats://nats-1:4222 --creds /path/admin.creds" \
#     STREAM=KV_CDC CONSUMER=cdc_sink FILTER='kv.cdc.>' RUN=1 scripts/create-consumer.sh
#
#   # inside the bundled lab, reuse the nats-box image + admin creds (a Job/pod
#   # that mounts the admin-creds Secret), then run with NATS_CLI pointed at it.
set -euo pipefail

# `nats` invocation. Point it at your server + a creds file that may PUBLISH to
# $JS.API.CONSUMER.CREATE.<stream>.* (admin/manage). Default assumes you run this
# from a context already selected with `nats context select`.
NATS_CLI="${NATS_CLI:-nats}"

STREAM="${STREAM:-KV_CDC}"            # nats.stream.name
CONSUMER="${CONSUMER:-cdc_sink}"     # nats.stream.consumer.durable
FILTER="${FILTER:-kv.cdc.>}"          # nats.stream.subjectPrefix + ".>"
ACK_WAIT="${ACK_WAIT:-30s}"          # nats.stream.consumer.ackWait
MAX_PENDING="${MAX_PENDING:-1024}"   # nats.stream.consumer.maxAckPending
MAX_DELIVER="${MAX_DELIVER:--1}"     # nats.stream.consumer.maxDeliver (-1 = forever)

CMD="${NATS_CLI} consumer add ${STREAM} ${CONSUMER} \
--pull \
--filter '${FILTER}' \
--ack explicit \
--deliver all \
--replay instant \
--wait ${ACK_WAIT} \
--max-pending ${MAX_PENDING} \
--max-deliver=${MAX_DELIVER} \
--defaults"

cat <<EOF
# ---- pre-create the durable PULL consumer (copy & run, or set RUN=1) ----
# Verify the result with:  ${NATS_CLI} consumer info ${STREAM} ${CONSUMER}

${CMD}
EOF

if [ "${RUN:-0}" = "1" ]; then
  echo "# RUN=1 set -> executing..." >&2
  eval "${CMD}"
  eval "${NATS_CLI} consumer info ${STREAM} ${CONSUMER}"
fi
