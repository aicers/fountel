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

# Seed the committed instance GnuPG key into the misp_gnupg volume BEFORE
# misp-core boots. Upstream's configure_gnupg uses an existing key when
# ${GPG_DIR}/trustdb.gpg is present and only autogenerates one otherwise, so
# pre-seeding the volume is the image's own supported path — no fork. When no
# key was committed, this step is skipped and misp-core autogenerates as
# before. Idempotent: the one-shot leaves an already-seeded volume untouched,
# so it never clobbers a running instance's key (reset with `down -v` to adopt
# a freshly committed key).
if [ -f "$PLAINTEXT_GNUPG_FILE" ]; then
  log "Seeding instance GnuPG key into the misp_gnupg volume (if not already present)..."
  ( cd "$DEV_DIR" && docker compose run --rm --no-deps --user root \
      --entrypoint /bin/bash \
      -v "$PLAINTEXT_GNUPG_FILE:/tmp/fountel-gnupg.asc:ro" \
      misp-core -c '
        set -euo pipefail
        GPG_DIR=/var/www/MISP/.gnupg
        if [ -f "$GPG_DIR/trustdb.gpg" ]; then
          echo "... GnuPG key already present in volume; leaving it untouched."
          exit 0
        fi
        mkdir -p "$GPG_DIR"; chmod 700 "$GPG_DIR"
        gpg --homedir "$GPG_DIR" --batch --import /tmp/fountel-gnupg.asc
        gpg --homedir "$GPG_DIR" --batch --check-trustdb
        chown -R www-data:www-data "$GPG_DIR"
        find "$GPG_DIR" -type f -exec chmod 600 {} \;
        find "$GPG_DIR" -type d -exec chmod 700 {} \;
        echo "... imported committed GnuPG key into the misp_gnupg volume."
      ' ) \
    || die "Failed to seed the GnuPG key into the misp_gnupg volume. Check: docker compose logs"
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
