#!/usr/bin/env bash
# Brings up the stack, runs the controller once, asserts the verdict is PASS.
# Asserts the PROPERTY (zero acked-without-apply loss across a mid-flight DELETE),
# not mere liveness.
set -euo pipefail
cd "$(dirname "$0")/.."

cp -n .env.example .env 2>/dev/null || true

cleanup() { docker compose down -v --remove-orphans >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "[smoke] building + starting stack..."
docker compose up -d --build nats redis connect

echo "[smoke] running controller..."
# controller exits non-zero on VERDICT FAIL; capture its logs
set +e
docker compose run --rm controller >controller.out 2>&1
rc=$?
set -e
cat controller.out

if [ $rc -ne 0 ]; then
  echo "[smoke] FAIL: controller exited $rc"
  exit 1
fi

if ! grep -q '"verdict":{"pass":true}' controller.out; then
  echo "[smoke] FAIL: verdict not pass"
  exit 1
fi

echo "[smoke] PASS: no acked-without-apply loss across mid-flight DELETE"
rm -f controller.out
