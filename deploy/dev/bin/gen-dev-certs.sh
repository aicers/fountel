#!/usr/bin/env bash
#
# Generate THROWAWAY dev mTLS certs for the gateway and its verification.
#
# IMPORTANT: this is a dev-only convenience that stands in for the external
# bootroot provisioning/rotation flow. fountel builds NO issuance/rotation
# machinery (issue #1) — in prod the gateway consumes externally-provisioned
# bootroot PEMs. Here we mint disposable certs locally, the same posture as
# secrets-init.sh: nothing under gateway/certs/ is ever committed (git-ignored).
#
# It produces, under deploy/dev/gateway/certs/ :
#   bootroot-ca.pem            a throwaway "bootroot" CA (cert)        [mounted]
#   server.crt / server.key    gateway server cert (CA-signed)        [mounted]
#   bootroot-ca.key            the CA key (used only to sign below)
#   client-allowed.{crt,key}   CA-signed, SAN aimer-web-dev-1.fountel.internal
#   client-denied.{crt,key}    CA-signed, SAN not in the allowlist
#   client-selfsigned.{crt,key}  NOT chained to the bootroot (handshake reject)
#
# The allowed client's SAN is taken from gateway/san-auth/allowlist.dev.yaml.
#
# Usage:
#   ./bin/gen-dev-certs.sh           # create if missing
#   ./bin/gen-dev-certs.sh --force   # regenerate from scratch

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

require_cmd openssl "openssl"

CERTS_DIR="$DEV_DIR/gateway/certs"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

if [ -f "$CERTS_DIR/server.crt" ] && [ "$FORCE" -eq 0 ]; then
  log "$CERTS_DIR already populated — nothing to do (use --force to regenerate)."
  exit 0
fi

mkdir -p "$CERTS_DIR"
cd "$CERTS_DIR"

# A bootroot client whose SAN is allowlisted (acceptance: can fetch the feed).
ALLOWED_SAN="aimer-web-dev-1.fountel.internal"
# A bootroot client whose SAN is NOT allowlisted (acceptance: 403 at gateway).
DENIED_SAN="not-allowlisted.fountel.internal"

log "Minting throwaway bootroot CA..."
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout bootroot-ca.key -out bootroot-ca.pem \
  -subj "/CN=fountel-dev-bootroot" 2>/dev/null

# Sign a leaf cert with the bootroot CA. $1 name, $2 subject CN, $3 SAN.
sign_leaf() {
  local name="$1" cn="$2" san="$3"
  openssl req -newkey rsa:2048 -nodes \
    -keyout "${name}.key" -out "${name}.csr" \
    -subj "/CN=${cn}" 2>/dev/null
  openssl x509 -req -in "${name}.csr" \
    -CA bootroot-ca.pem -CAkey bootroot-ca.key -CAcreateserial \
    -days 3650 -extfile <(printf 'subjectAltName=%s\n' "$san") \
    -out "${name}.crt" 2>/dev/null
  rm -f "${name}.csr"
}

log "Minting gateway server cert (CA-signed)..."
# SANs the verification curl connects through (host loopback + container name).
sign_leaf server "fountel-gateway-dev" \
  "DNS:localhost,DNS:fountel-gateway.dev,IP:127.0.0.1"

log "Minting allowlisted client cert (SAN=$ALLOWED_SAN)..."
sign_leaf client-allowed "aimer-web-dev-1" "DNS:${ALLOWED_SAN}"

log "Minting non-allowlisted bootroot client cert (SAN=$DENIED_SAN)..."
sign_leaf client-denied "rogue-but-bootroot" "DNS:${DENIED_SAN}"

log "Minting non-bootroot self-signed client cert (handshake should reject)..."
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout client-selfsigned.key -out client-selfsigned.crt \
  -subj "/CN=self-signed-intruder" \
  -addext "subjectAltName=DNS:${ALLOWED_SAN}" 2>/dev/null

chmod 600 ./*.key
rm -f bootroot-ca.srl

log "Wrote throwaway dev certs to $CERTS_DIR (git-ignored)."
log "The gateway mounts server.crt, server.key, bootroot-ca.pem read-only."
