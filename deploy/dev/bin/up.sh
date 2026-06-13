#!/usr/bin/env bash
#
# Bring up the dev MISP stack: decrypt secrets, then start compose.
# Idempotent — re-running reconciles to the desired state, it does not
# duplicate anything.
#
# Usage:
#   ./bin/up.sh            # decrypt + docker compose up -d
#   ./bin/up.sh --wait     # also block until misp-core is healthy

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

require_cmd docker "https://docs.docker.com/get-docker/"
docker compose version >/dev/null 2>&1 || die "docker compose v2 plugin is required"

# Seed a local .env from the template on first run (compose interpolation).
if [ ! -f "$DEV_DIR/.env" ]; then
  cp "$DEV_DIR/.env.example" "$DEV_DIR/.env"
  log "Created $DEV_DIR/.env from .env.example."
fi

"$BIN_DIR/secrets-decrypt.sh"

log "Starting dev MISP stack..."
( cd "$DEV_DIR" && docker compose up -d )

if [ "${1:-}" = "--wait" ]; then
  log "Waiting for misp-core to become healthy (first boot can take a few minutes)..."
  healthy=0
  for _ in $(seq 1 120); do
    status="$(cd "$DEV_DIR" && docker compose ps --format '{{.Health}}' misp-core 2>/dev/null || true)"
    [ "$status" = "healthy" ] && { log "misp-core is healthy."; healthy=1; break; }
    sleep 5
  done
  # Don't report success on a stalled boot: --wait is a bring-up verification
  # (runbook + PR test plan), so a never-healthy stack must exit non-zero.
  [ "$healthy" -eq 1 ] \
    || die "misp-core did not become healthy within ~10 min. Check: docker compose logs -f misp-core"
fi

log "Stack started. Next: ./bin/bootstrap.sh (idempotent fountel config)."
