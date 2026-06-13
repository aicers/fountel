#!/usr/bin/env bash
#
# Regenerate the test fixture certificates.
#
# These are self-signed throwaway certs used only to exercise SAN
# parsing and allowlist matching — the service never validates the
# certificate chain (nginx does that against the bootroot). The
# generated PEMs are committed so the test suite needs no openssl and
# no network. Run this only when the fixture set must change.
#
# Usage: ./generate.sh
set -euo pipefail

cd "$(dirname "$0")"

gen() {
  local name="$1" subj="$2" san="$3"
  if [[ -n "$san" ]]; then
    openssl req -x509 -newkey rsa:2048 -nodes -keyout /dev/null \
      -days 3650 -subj "$subj" -addext "subjectAltName=$san" \
      -out "${name}.pem" 2>/dev/null
  else
    openssl req -x509 -newkey rsa:2048 -nodes -keyout /dev/null \
      -days 3650 -subj "$subj" \
      -out "${name}.pem" 2>/dev/null
  fi
  echo "wrote ${name}.pem"
}

# Allowed: DNS SAN present in allowlist.dev.yaml.
gen allowed-dns "/CN=aimer-web-dev-1" \
  "DNS:aimer-web-dev-1.fountel.internal"

# Allowed: URI SAN present in allowlist.dev.yaml.
gen allowed-uri "/CN=aimer-ingest-dev" \
  "URI:spiffe://fountel.dev/aimer/ingest"

# Allowed: multiple SANs where only the second (URI) is allowlisted.
gen allowed-multi "/CN=aimer-ingest-dev" \
  "DNS:not-listed.fountel.internal,URI:spiffe://fountel.dev/aimer/ingest"

# Denied: DNS SAN not in any allowlist.
gen denied-dns "/CN=rogue" \
  "DNS:rogue.example.com"

# Denied: a SAN type we ignore (IP) plus a non-allowlisted DNS.
gen denied-ip "/CN=rogue-ip" \
  "IP:10.0.0.9,DNS:rogue-ip.example.com"

# Denied: certificate with no SAN extension at all.
gen no-san "/CN=aimer-web-dev-1.fountel.internal" ""

# Denied (injection attempt): a SINGLE URI SAN whose value embeds a comma and a
# fake `DNS:<allowlisted>` payload. A naive comma-splitting parser would spoof an
# allowlisted DNS entry; correct quote-aware parsing keeps it as one URI value,
# which is not allowlisted. `-addext` cannot express a literal comma inside a
# value (comma separates entries), so this one is built from a config file.
gen_cnf() {
  local name="$1" cn="$2" uri="$3"
  local cnf
  cnf="$(mktemp)"
  printf '%s\n' '[req]' 'distinguished_name=dn' 'x509_extensions=v3' 'prompt=no' \
    '[dn]' "CN=$cn" '[v3]' 'subjectAltName=@alt' '[alt]' "URI.1=$uri" >"$cnf"
  openssl req -x509 -newkey rsa:2048 -nodes -keyout /dev/null \
    -days 3650 -config "$cnf" -out "${name}.pem" 2>/dev/null
  rm -f "$cnf"
  echo "wrote ${name}.pem"
}
gen_cnf injection-uri "injection" \
  "spiffe://fountel.dev/x,DNS:aimer-web-dev-1.fountel.internal"

echo "done"
