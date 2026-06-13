#!/usr/bin/env bash
#
# First-time secret bootstrap for the dev stack.
#
#   1. Ensures an age key pair exists (generates one if needed).
#   2. Registers its PUBLIC key as the dev recipient in .sops.yaml.
#   3. Generates strong random values for every secret and writes the
#      sops-ENCRYPTED `secrets.enc.env` (the only secret material committed).
#
# Idempotent: if `secrets.enc.env` already exists this is a NO-OP unless you
# pass --rotate, which regenerates all values (invalidating existing logins).
#
# Usage:
#   ./bin/secrets-init.sh            # create on first run; no-op afterwards
#   ./bin/secrets-init.sh --rotate   # force-regenerate all secret values

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

ROTATE=0
[ "${1:-}" = "--rotate" ] && ROTATE=1

require_cmd sops "https://github.com/getsops/sops"
require_cmd age-keygen "https://github.com/FiloSottile/age"
require_cmd openssl "openssl"

# --- 1. age key pair -------------------------------------------------------
if [ ! -f "$AGE_KEY_FILE" ]; then
  log "No age key at $AGE_KEY_FILE — generating one."
  mkdir -p "$(dirname "$AGE_KEY_FILE")"
  ( umask 077; age-keygen -o "$AGE_KEY_FILE" )
  warn "BACK UP $AGE_KEY_FILE securely. Losing it means losing access to all secrets."
else
  log "Using existing age key at $AGE_KEY_FILE."
fi
RECIPIENT="$(age-keygen -y "$AGE_KEY_FILE")"
log "Dev age recipient (public key): $RECIPIENT"

# --- 2. register recipient in .sops.yaml -----------------------------------
if grep -q "REPLACE_WITH_DEV_AGE_PUBLIC_KEY" "$SOPS_CONFIG"; then
  sed -i.bak "s|REPLACE_WITH_DEV_AGE_PUBLIC_KEY|$RECIPIENT|" "$SOPS_CONFIG"
  rm -f "$SOPS_CONFIG.bak"
  log "Wrote dev recipient into $SOPS_CONFIG."
elif ! grep -q "$RECIPIENT" "$SOPS_CONFIG"; then
  die "Your recipient ($RECIPIENT) is not listed in $SOPS_CONFIG. Add it to the
dev rule's age: list and re-run, so the committed secrets.enc.env stays
encrypted to the recipients the policy declares (it is the source of truth)."
fi

# --- 3. generate + encrypt secrets -----------------------------------------
if [ -f "$ENC_FILE" ] && [ "$ROTATE" -eq 0 ]; then
  log "$ENC_FILE already exists — nothing to do (use --rotate to regenerate)."
  exit 0
fi

# Hex values are safe in DB DSNs, redis AUTH, and shell. The admin password
# additionally satisfies MISP's default complexity policy (length >= 12, with
# upper + lower + digit + special).
gen_hex()      { openssl rand -hex 24; }
gen_password() { printf '%sAa1!' "$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)"; }

TMP="$(mktemp)"
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

[ "$ROTATE" -eq 1 ] && warn "Rotating: existing user passwords and API keys will be invalidated."
# Encryption is two steps so the committed file always matches the .sops.yaml
# recipient policy (the single source of truth), even on --rotate:
#
#   1. Bootstrap-encrypt to the local recipient with --config /dev/null. sops
#      keys creation_rules on the committed path (deploy/dev/*.enc.*), which the
#      mktemp input path never matches, and a discovered-but-unmatched config
#      makes sops fail even when --age is given — so we skip rule matching here.
#   2. Re-key the file IN PLACE with `sops updatekeys`, which path-matches the
#      committed file against .sops.yaml and re-encrypts the data key to EVERY
#      recipient that rule lists. Without this, --rotate would silently drop any
#      other dev recipients already in the policy and ship a file only the local
#      operator could read.
#
# Write atomically: a failed encrypt must never leave a partial/empty
# secrets.enc.env behind, or the idempotency guard above would treat the
# broken file as "already created" on the next run.
export SOPS_AGE_KEY_FILE="$AGE_KEY_FILE"
ENC_TMP="$(mktemp "$DEV_DIR/.secrets.enc.env.XXXXXX")"
# On --rotate, preserve the existing committed file so a failed re-key can be
# rolled back: updatekeys must run on the committed path (it path-matches
# .sops.yaml), so we have to move the new file into place BEFORE re-keying. If
# updatekeys then fails, the working tree would otherwise hold a non-policy file
# encrypted only to the local operator — exactly the policy drift we prevent.
ENC_BACKUP=""
[ -f "$ENC_FILE" ] && ENC_BACKUP="$(mktemp "$DEV_DIR/.secrets.enc.env.bak.XXXXXX")" && cp -p "$ENC_FILE" "$ENC_BACKUP"
trap 'rm -f "$TMP" "$ENC_TMP" "$ENC_BACKUP"' EXIT
sops --config /dev/null --encrypt --age "$RECIPIENT" \
  --input-type dotenv --output-type dotenv "$TMP" > "$ENC_TMP"
mv -f "$ENC_TMP" "$ENC_FILE"
# Re-key to the full policy. Run from REPO_ROOT so sops discovers .sops.yaml.
if ! ( cd "$REPO_ROOT" && sops updatekeys --yes "$ENC_FILE" >/dev/null ); then
  if [ -n "$ENC_BACKUP" ]; then
    mv -f "$ENC_BACKUP" "$ENC_FILE"
    die "sops updatekeys failed; restored the previous $ENC_FILE so no non-policy
secret is left behind. Fix the .sops.yaml recipient policy and re-run."
  fi
  rm -f "$ENC_FILE"
  die "sops updatekeys failed; removed the partial $ENC_FILE (no prior version to
restore). Fix the .sops.yaml recipient policy and re-run."
fi

log "Wrote encrypted secrets to $ENC_FILE (keyed to the .sops.yaml recipients)."
log "Commit it. Then run ./bin/up.sh to decrypt and start the stack."
