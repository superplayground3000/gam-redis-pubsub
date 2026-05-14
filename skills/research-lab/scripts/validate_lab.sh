#!/usr/bin/env bash
# validate_lab.sh - bring up a lab, run its smoke test, tear down. Always exits cleanly.
#
# Usage:
#   scripts/validate_lab.sh <lab-dir>
#
# Exit code:
#   0  - lab passed smoke test
#   1  - validation failed (any step)
#   2  - usage error

set -u
set -o pipefail

if [ $# -ne 1 ]; then
    echo "usage: $0 <lab-dir>" >&2
    exit 2
fi

LAB_DIR="$1"

if [ ! -d "$LAB_DIR" ]; then
    echo "FAIL: lab dir not found: $LAB_DIR" >&2
    exit 1
fi

if [ ! -f "$LAB_DIR/docker-compose.yml" ]; then
    echo "FAIL: no docker-compose.yml in $LAB_DIR" >&2
    exit 1
fi

if [ ! -f "$LAB_DIR/scripts/smoke-test.sh" ]; then
    echo "FAIL: no scripts/smoke-test.sh in $LAB_DIR" >&2
    exit 1
fi

cd "$LAB_DIR"

# Always tear down, even on failure or interrupt.
cleanup() {
    echo "--- teardown ---"
    docker compose down -v --remove-orphans 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "=== validate_lab.sh: $LAB_DIR ==="

# --- 1. compose schema check ---
echo "--- step 1: docker compose config ---"
if ! docker compose config -q; then
    echo "FAIL: docker compose config rejected the file" >&2
    exit 1
fi

# --- 2. host-isolation grep checklist ---
echo "--- step 2: host-isolation checks ---"

if grep -nE 'privileged:[[:space:]]*true|network_mode:[[:space:]]*("|'\'')?host|pid:[[:space:]]*("|'\'')?host|ipc:[[:space:]]*("|'\'')?host' docker-compose.yml; then
    echo "FAIL: forbidden compose flag (privileged / host networking / host pid / host ipc)" >&2
    exit 1
fi

if grep -nE '^[[:space:]]*-[[:space:]]+(/etc|/var|/usr|/home|/root|/boot|/lib|/proc|/sys)(/|:)' docker-compose.yml; then
    echo "FAIL: forbidden bind-mount source (system path)" >&2
    exit 1
fi

if grep -n 'docker\.sock' docker-compose.yml; then
    echo "FAIL: docker socket mount detected" >&2
    exit 1
fi

if grep -rn --include='*.sh' --include='*.yml' --include='*.yaml' --include='Dockerfile*' 'sudo ' . 2>/dev/null; then
    echo "FAIL: 'sudo' detected in lab files" >&2
    exit 1
fi

if grep -nE '^[[:space:]]+-[[:space:]]+"?[0-9]{1,3}:' docker-compose.yml; then
    echo "FAIL: privileged host port (<1024) detected" >&2
    exit 1
fi

echo "host-isolation checks passed."

# --- 3. bring up ---
echo "--- step 3: docker compose up -d --wait ---"
if ! docker compose up -d --wait; then
    echo "FAIL: services did not become healthy" >&2
    docker compose ps
    docker compose logs --tail=50
    exit 1
fi

# --- 4. smoke test ---
echo "--- step 4: smoke test ---"
SMOKE_EXIT=0
bash scripts/smoke-test.sh || SMOKE_EXIT=$?

if [ "$SMOKE_EXIT" -ne 0 ]; then
    echo "FAIL: smoke test exited $SMOKE_EXIT" >&2
    docker compose logs --tail=50
    exit 1
fi

echo "=== validate_lab.sh: PASS ==="
exit 0
