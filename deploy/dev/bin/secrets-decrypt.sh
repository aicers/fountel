#!/usr/bin/env bash
#
# Decrypt the committed sops file into the git-ignored plaintext secrets dir
# that docker-compose reads via `env_file:`. This is the single, obvious
# inject path (issue #3): encrypted file in -> plaintext secrets/ out.
#
# Idempotent: safe to run before every `docker compose up`.

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

require_cmd sops "https://github.com/getsops/sops"

[ -f "$ENC_FILE" ] || die "Missing $ENC_FILE. Run ./bin/secrets-init.sh first."
[ -f "$AGE_KEY_FILE" ] || die "Missing age key at $AGE_KEY_FILE. You need the dev decryption key (see docs/secrets.md)."

export SOPS_AGE_KEY_FILE="$AGE_KEY_FILE"

mkdir -p "$SECRETS_DIR"
chmod 700 "$SECRETS_DIR"

# Write atomically with restrictive permissions; never leave a partial file.
TMP="$(mktemp "$SECRETS_DIR/.misp.secrets.env.XXXXXX")"
trap 'rm -f "$TMP"' EXIT
( umask 077; sops --decrypt --input-type dotenv --output-type dotenv "$ENC_FILE" > "$TMP" )
chmod 600 "$TMP"
mv -f "$TMP" "$PLAINTEXT_FILE"
trap - EXIT

log "Decrypted secrets to $PLAINTEXT_FILE (git-ignored)."

# Decrypt the instance GnuPG private key, if committed. It is optional: when
# absent, misp-core falls back to generating its own key on first boot (see
# up.sh / docs/secrets.md). When present, it is the committed secret material
# that makes the instance signing key reproducible across a volume reset.
if [ -f "$ENC_GNUPG_FILE" ]; then
  GTMP="$(mktemp "$SECRETS_DIR/.misp.gnupg.asc.XXXXXX")"
  trap 'rm -f "$GTMP"' EXIT
  ( umask 077; sops --decrypt --input-type binary --output-type binary "$ENC_GNUPG_FILE" > "$GTMP" )
  chmod 600 "$GTMP"
  mv -f "$GTMP" "$PLAINTEXT_GNUPG_FILE"
  trap - EXIT
  log "Decrypted GnuPG private key to $PLAINTEXT_GNUPG_FILE (git-ignored)."
else
  # Stale plaintext would otherwise survive after the encrypted key is removed.
  rm -f "$PLAINTEXT_GNUPG_FILE"
  log "No committed GnuPG key ($ENC_GNUPG_FILE); misp-core will autogenerate one."
fi
