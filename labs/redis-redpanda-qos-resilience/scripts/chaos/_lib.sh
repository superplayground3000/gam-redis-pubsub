# Shared helpers for chaos drills. Source-only — don't run directly.
# All scripts cd to the lab root so `docker compose` finds the project.
LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$LAB_ROOT"

DOWNTIME_S="${DOWNTIME_S:-${1:-10}}"

drill() {
  local svc="$1"
  local label="${2:-$svc}"
  echo "[chaos] stopping ${label} for ${DOWNTIME_S}s..."
  docker compose stop "$svc" >/dev/null
  sleep "$DOWNTIME_S"
  echo "[chaos] restarting ${label}..."
  docker compose start "$svc" >/dev/null
  # Wait for healthcheck (best-effort; not all services use one we trust here).
  for i in $(seq 1 30); do
    state=$(docker inspect -f '{{.State.Health.Status}}' "rrqr-${svc}" 2>/dev/null || echo "")
    if [ "$state" = "healthy" ] || [ -z "$state" ]; then
      break
    fi
    sleep 1
  done
  echo "[chaos] ${label} back: state=${state:-unknown}"
}
