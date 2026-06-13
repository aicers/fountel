#!/usr/bin/env bash
#
# Generate the dev stack's secrets LOCALLY. Nothing secret is committed.
#
# Writes strong random values for every secret directly into the git-ignored
# `secrets/misp.secrets.env` (mode 0600), which compose reads via `env_file:`.
# No encryption, no age key, no GnuPG keypair: MISP autogenerates its own
# instance GnuPG key on first boot, locked with the generated GPG_PASSPHRASE.
#
# Idempotent: if `secrets/misp.secrets.env` already exists this is a NO-OP
# unless you pass --rotate. Re-running before `up.sh` is therefore safe and
# does not invalidate a running instance.
#
# Usage:
#   ./bin/secrets-init.sh            # create on first run; no-op afterwards
#   ./bin/secrets-init.sh --rotate   # force-regenerate all secret values
#
# --rotate caveat: the regenerated values (DB password, SALT, ADMIN_KEY, ...)
# will NOT match the credentials already baked into the existing Docker named
# volumes. To apply rotated secrets you must reset the volumes:
#   docker compose down -v && ./bin/up.sh

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

ROTATE=0
[ "${1:-}" = "--rotate" ] && ROTATE=1

require_cmd openssl "openssl"

if [ -f "$PLAINTEXT_FILE" ] && [ "$ROTATE" -eq 0 ]; then
  log "$PLAINTEXT_FILE already exists — nothing to do (use --rotate to regenerate)."
  exit 0
fi

# Hex values are safe in DB DSNs, redis AUTH, and shell. The admin password
# additionally satisfies MISP's default complexity policy (length >= 12, with
# upper + lower + digit + special).
gen_hex()      { openssl rand -hex 24; }
gen_password() { printf '%sAa1!' "$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)"; }

mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

# Write atomically with restrictive permissions; never leave a partial file.
TMP="$(mktemp "$SECRETS_DIR/.misp.secrets.env.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
( umask 077; cat > "$TMP" <<EOF
MYSQL_PASSWORD=$(gen_hex)
MYSQL_ROOT_PASSWORD=$(gen_hex)
REDIS_PASSWORD=$(gen_hex)
ADMIN_PASSWORD=$(gen_password)
SALT=$(gen_hex)
GPG_PASSPHRASE=$(gen_hex)
ADMIN_KEY=$(openssl rand -hex 20)
SMARTHOST_PASSWORD=
EOF
)
chmod 600 "$TMP"
mv -f "$TMP" "$PLAINTEXT_FILE"
trap - EXIT

if [ "$ROTATE" -eq 1 ]; then
  warn "Rotated all secret values in $PLAINTEXT_FILE."
  warn "These do NOT match the credentials in the existing Docker volumes."
  warn "Reset and re-bring-up to apply them: docker compose down -v && ./bin/up.sh"
else
  log "Wrote generated secrets to $PLAINTEXT_FILE (git-ignored, mode 0600)."
  log "Next: ./bin/up.sh to start the stack."
fi
