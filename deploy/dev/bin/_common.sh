#!/usr/bin/env bash
# Shared helpers for the dev bring-up scripts. Sourced, not executed.

set -euo pipefail

# Resolve key paths relative to this file so scripts work from any CWD.
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV_DIR="$(cd "$BIN_DIR/.." && pwd)"
REPO_ROOT="$(cd "$DEV_DIR/../.." && pwd)"

SOPS_CONFIG="$REPO_ROOT/.sops.yaml"
ENC_FILE="$DEV_DIR/secrets.enc.env"
# The instance GnuPG private key is committed as its own sops file (armored
# ASCII is multi-line, so it cannot live in the dotenv secret file). It is
# decrypted alongside the env secrets and seeded into the misp_gnupg volume.
ENC_GNUPG_FILE="$DEV_DIR/gnupg.secret.enc.asc"
SECRETS_DIR="$DEV_DIR/secrets"
PLAINTEXT_FILE="$SECRETS_DIR/misp.secrets.env"
PLAINTEXT_GNUPG_FILE="$SECRETS_DIR/misp.gnupg.asc"

# Where the age private key lives. Honor sops' standard env var if set.
AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"

log()  { printf '\033[1;34m[fountel]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[fountel]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fountel]\033[0m %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1 ($2)"
}
