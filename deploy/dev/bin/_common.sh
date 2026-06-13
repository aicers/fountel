#!/usr/bin/env bash
# Shared helpers for the dev bring-up scripts. Sourced, not executed.

set -euo pipefail

# Resolve key paths relative to this file so scripts work from any CWD.
BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV_DIR="$(cd "$BIN_DIR/.." && pwd)"
REPO_ROOT="$(cd "$DEV_DIR/../.." && pwd)"

# Dev secrets are generated locally at bring-up and never committed. They live
# in this git-ignored directory, written in plaintext (mode 0600) and read by
# compose via `env_file:`. MISP autogenerates its own instance GnuPG key on
# first boot, so no key material is generated or seeded here.
SECRETS_DIR="$DEV_DIR/secrets"
PLAINTEXT_FILE="$SECRETS_DIR/misp.secrets.env"

log()  { printf '\033[1;34m[fountel]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[fountel]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fountel]\033[0m %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1 ($2)"
}
