#!/usr/bin/env bash
# Stops NATS JetStream for DOWNTIME_S seconds, then restarts.
# The forward leg accumulates retries in connect-source; the reverse leg's
# durable consumer disconnects. After NATS returns, both reconnect and resume.
# Under ALO/EOE: no data loss (file storage + durable consumer + Nats-Msg-Id
# dedup if forward retries). Under AMO: messages in flight at the moment of
# the kill may be lost.
set -euo pipefail
source "$(dirname "$0")/_lib.sh"
drill nats "nats (JetStream backbone)"
