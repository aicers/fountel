#!/usr/bin/env bash
#
# Bring up the dev MISP stack: ensure local secrets exist, then start compose.
# Idempotent — re-running reconciles to the desired state, it does not
# duplicate anything.
#
# Usage:
#   ./bin/up.sh            # generate secrets if missing + docker compose up -d
#   ./bin/up.sh --wait     # also block until misp-core is healthy

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

require_cmd docker "https://docs.docker.com/get-docker/"
docker compose version >/dev/null 2>&1 || die "docker compose v2 plugin is required"

# Seed a local .env from the template on first run (compose interpolation).
if [ ! -f "$DEV_DIR/.env" ]; then
  cp "$DEV_DIR/.env.example" "$DEV_DIR/.env"
  log "Created $DEV_DIR/.env from .env.example."
fi

# Generate local secrets on first run, the same way .env is seeded above.
# secrets-init.sh is a no-op if secrets/misp.secrets.env already exists, so this
# never clobbers a running instance's credentials.
if [ ! -f "$PLAINTEXT_FILE" ]; then
  log "No local secrets found — generating them with secrets-init.sh."
  "$BIN_DIR/secrets-init.sh"
fi

# Mint throwaway dev mTLS certs for the gateway on first run, the same way
# secrets are seeded above. In prod these PEMs are externally provisioned; in
# dev gen-dev-certs.sh stands in for that (no-op if certs already exist).
if [ ! -f "$DEV_DIR/gateway/certs/server.crt" ]; then
  log "No gateway certs found — minting throwaway dev certs with gen-dev-certs.sh."
  "$BIN_DIR/gen-dev-certs.sh"
fi

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
