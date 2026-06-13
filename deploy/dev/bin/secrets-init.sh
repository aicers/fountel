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
require_cmd gpg "https://gnupg.org/"

# MISP instance address. The GnuPG key UID must match MISP's MISP_EMAIL (which
# defaults to ADMIN_EMAIL) so that configure_gnupg's export-by-email and the
# GnuPG.email setting resolve to this key. Keep in sync with the ADMIN_EMAIL
# default in docker-compose.yml; if you override ADMIN_EMAIL in .env, re-run
# with --rotate so the key UID matches.
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@fountel.local}"

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

# The GnuPG key passphrase is captured in a variable (not just inlined into the
# env file) because the instance GnuPG key generated below MUST be protected
# with this exact passphrase — MISP unlocks the key at runtime with
# GnuPG.password = GPG_PASSPHRASE. Generating both here keeps them consistent.
GPG_PASSPHRASE_VAL="$(gen_hex)"

# The env secrets and the instance GnuPG key are committed as a COUPLED PAIR:
# the key is protected with the env file's GPG_PASSPHRASE, so the two must
# always move together. They are therefore committed atomically — both are
# encrypted and re-keyed, and if anything fails, BOTH are rolled back. A split
# commit (new env + old key, or vice versa) would leave a passphrase/key
# mismatch that only surfaces at bring-up, so it is never allowed to persist.
#
# Encryption is two steps so each committed file carries EVERY recipient the
# .sops.yaml policy lists (the single source of truth), even on --rotate:
#
#   1. Bootstrap-encrypt to the local recipient with --config /dev/null. sops
#      keys creation_rules on the committed path (deploy/dev/*.enc.*), which the
#      mktemp input path never matches, and a discovered-but-unmatched config
#      makes sops fail even when --age is given — so we skip rule matching here.
#   2. Re-key each file IN PLACE with `sops updatekeys`, which path-matches the
#      committed file against .sops.yaml and re-encrypts the data key to EVERY
#      recipient that rule lists. Without this, --rotate would silently drop any
#      other recipients already in the policy and ship a file only the local
#      operator could read.
#
# updatekeys must run on the committed path (it path-matches .sops.yaml), so the
# new files are moved into place BEFORE re-keying. Existing files are backed up
# first so a failed re-key restores the prior committed pair; on a first run
# there is no backup, so a failure removes the partial files instead (a partial
# file would otherwise satisfy the idempotency guard above as "already created").

enc_to_local() { # $1 plaintext  $2 iotype  -> ciphertext on stdout
  sops --config /dev/null --encrypt --age "$RECIPIENT" \
    --input-type "$2" --output-type "$2" "$1"
}

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
( umask 077; cat > "$TMP" <<EOF
MYSQL_PASSWORD=$(gen_hex)
MYSQL_ROOT_PASSWORD=$(gen_hex)
REDIS_PASSWORD=$(gen_hex)
ADMIN_PASSWORD=$(gen_password)
SALT=$(gen_hex)
GPG_PASSPHRASE=$GPG_PASSPHRASE_VAL
ADMIN_KEY=$(openssl rand -hex 20)
SMARTHOST_PASSWORD=
EOF
)

# Generate the instance GnuPG key, protected with the passphrase above and
# carrying the UID MISP expects (Name-Real/Name-Email match upstream's autogen
# so a pre-seeded key is indistinguishable from one MISP would have made). The
# armored secret key is committed as its own sops file (multi-line armor cannot
# live in the dotenv file) and seeded into the misp_gnupg volume at deploy.
GTMP="$(mktemp)"
GPG_HOME="$(mktemp -d)"; chmod 700 "$GPG_HOME"
GPG_BATCH="$(mktemp)"
trap 'rm -f "$TMP" "$GTMP" "$GPG_BATCH"; rm -rf "$GPG_HOME"' EXIT
cat > "$GPG_BATCH" <<GPGEOF
%echo Generating the fountel dev instance GnuPG key
Key-Type: RSA
Key-Length: 3072
Name-Real: MISP Admin
Name-Email: $ADMIN_EMAIL
Expire-Date: 0
Passphrase: $GPG_PASSPHRASE_VAL
%commit
%echo done
GPGEOF
gpg --homedir "$GPG_HOME" --batch --gen-key "$GPG_BATCH" >/dev/null 2>&1 \
  || die "GnuPG key generation failed."
( umask 077; gpg --homedir "$GPG_HOME" --batch --pinentry-mode loopback \
    --passphrase "$GPG_PASSPHRASE_VAL" --armor \
    --export-secret-keys "$ADMIN_EMAIL" > "$GTMP" )
[ -s "$GTMP" ] || die "Exported GnuPG secret key is empty."

[ "$ROTATE" -eq 1 ] && warn "Rotating: existing user passwords, API keys, and the instance GnuPG key will be invalidated (reset volumes with 'docker compose down -v')."

export SOPS_AGE_KEY_FILE="$AGE_KEY_FILE"

# Stage: bootstrap-encrypt both files to temp (no committed file touched yet).
ENV_ENC_TMP="$(mktemp "$ENC_FILE.XXXXXX")"
GPG_ENC_TMP="$(mktemp "$ENC_GNUPG_FILE.XXXXXX")"
# Back up any existing committed pair so a failed re-key can roll both back.
ENV_BACKUP=""; GPG_BACKUP=""
[ -f "$ENC_FILE" ]       && ENV_BACKUP="$(mktemp "$ENC_FILE.bak.XXXXXX")"       && cp -p "$ENC_FILE" "$ENV_BACKUP"
[ -f "$ENC_GNUPG_FILE" ] && GPG_BACKUP="$(mktemp "$ENC_GNUPG_FILE.bak.XXXXXX")" && cp -p "$ENC_GNUPG_FILE" "$GPG_BACKUP"
trap 'rm -f "$TMP" "$GTMP" "$GPG_BATCH" "$ENV_ENC_TMP" "$GPG_ENC_TMP" "$ENV_BACKUP" "$GPG_BACKUP"; rm -rf "$GPG_HOME"' EXIT

restore_pair() {
  # Roll the committed pair back to its prior state (or remove partial files on
  # a first run) so a failed commit never leaves a mismatched or non-policy pair.
  if [ -n "$ENV_BACKUP" ]; then mv -f "$ENV_BACKUP" "$ENC_FILE"; else rm -f "$ENC_FILE"; fi
  if [ -n "$GPG_BACKUP" ]; then mv -f "$GPG_BACKUP" "$ENC_GNUPG_FILE"; else rm -f "$ENC_GNUPG_FILE"; fi
}

enc_to_local "$TMP"  dotenv > "$ENV_ENC_TMP"
enc_to_local "$GTMP" binary > "$GPG_ENC_TMP"
mv -f "$ENV_ENC_TMP" "$ENC_FILE"
mv -f "$GPG_ENC_TMP" "$ENC_GNUPG_FILE"
if ! ( cd "$REPO_ROOT" \
        && sops updatekeys --yes "$ENC_FILE" >/dev/null \
        && sops updatekeys --yes "$ENC_GNUPG_FILE" >/dev/null ); then
  restore_pair
  die "sops updatekeys failed; restored the previous committed secrets so no
non-policy or mismatched pair is left behind. Fix the .sops.yaml recipient
policy and re-run."
fi

log "Wrote encrypted secrets to $ENC_FILE and the instance GnuPG key to"
log "$ENC_GNUPG_FILE (both keyed to the .sops.yaml recipients)."
log "Commit them. Then run ./bin/up.sh to decrypt and start the stack."
