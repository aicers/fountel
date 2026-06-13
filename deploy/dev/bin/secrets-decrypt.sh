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
