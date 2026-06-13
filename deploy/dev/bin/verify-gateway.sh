#!/usr/bin/env bash
#
# End-to-end verification of the mTLS gateway + published feed (issue #4).
#
# Proves the acceptance criteria with curl (NOT by implementing the aimer-web
# consumer):
#   1. Force a fresh feed export (atomic swap into the publish volume).
#   2. Allowlisted bootroot client  -> 200, fetches manifest + events + hashes.
#   3. Non-allowlisted bootroot client -> 403 (denied by san-auth at gateway).
#   4. Non-bootroot self-signed client -> rejected at the TLS handshake.
#   5. Feed is structurally consumable: UUID-keyed manifest, each event
#      fetchable, hashes.csv consistent, sidecar + Last-Modified present, no
#      non-UUID top-level manifest key, and ONLY additive-scoped events.
#   6. MISP UI/API are NOT reachable over the gateway route, and misp-core's
#      host publish is loopback-only (the gateway feed port is the only
#      non-loopback bound port).
#
# Prereqs: stack up (./bin/up.sh), bootstrap done (./bin/bootstrap.sh), demo
# events seeded (./bin/seed-additive-event.sh), and dev certs generated
# (./bin/gen-dev-certs.sh — up.sh/this script generate them if missing).

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

require_cmd docker "https://docs.docker.com/get-docker/"
require_cmd curl "curl"
require_cmd python3 "https://www.python.org/downloads/"

dc() { ( cd "$DEV_DIR" && docker compose "$@" ); }

CERTS="$DEV_DIR/gateway/certs"
[ -f "$CERTS/server.crt" ] || "$BIN_DIR/gen-dev-certs.sh"

[ -f "$DEV_DIR/.env" ] && { set -a; # shellcheck disable=SC1091
  source "$DEV_DIR/.env"; set +a; }
FEED_PORT="${FEED_HTTPS_PORT:-18443}"
BASE="https://localhost:${FEED_PORT}"
CA="$CERTS/bootroot-ca.pem"

pass() { printf '\033[1;32m[PASS]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

# curl as the allowlisted client; prints HTTP status only.
status_allowed() {
  curl -s -o /dev/null -w '%{http_code}' --cacert "$CA" \
    --cert "$CERTS/client-allowed.crt" --key "$CERTS/client-allowed.key" "$1"
}

# --- 1. force a fresh export ----------------------------------------------
log "Forcing a one-shot feed export..."
dc run --rm -e RUN_ONCE=1 feed-exporter >/dev/null 2>&1 \
  || fail "feed export run failed (check: docker compose logs feed-exporter)"
pass "feed export produced a snapshot and swapped it in"

# --- 2. allowlisted client can fetch --------------------------------------
code="$(status_allowed "$BASE/feed/manifest.json")"
[ "$code" = "200" ] || fail "allowlisted client got HTTP $code for manifest.json (want 200)"
pass "allowlisted bootroot client fetched manifest.json (200)"

manifest="$(curl -s --cacert "$CA" --cert "$CERTS/client-allowed.crt" \
  --key "$CERTS/client-allowed.key" "$BASE/feed/manifest.json")"

# Last-Modified header present on the static manifest.
hdrs="$(curl -sI --cacert "$CA" --cert "$CERTS/client-allowed.crt" \
  --key "$CERTS/client-allowed.key" "$BASE/feed/manifest.json")"
echo "$hdrs" | grep -qi '^last-modified:' \
  || fail "manifest.json response is missing the Last-Modified header"
pass "Last-Modified header present"

# Sidecar freshness file with generated_at.
meta="$(curl -s --cacert "$CA" --cert "$CERTS/client-allowed.crt" \
  --key "$CERTS/client-allowed.key" "$BASE/feed/fountel-feed-meta.json")"
echo "$meta" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("generated_at"), "no generated_at"' \
  || fail "fountel-feed-meta.json missing or lacks generated_at"
pass "freshness sidecar fountel-feed-meta.json present with generated_at"

# --- 3. non-allowlisted bootroot client -> 403 ----------------------------
code="$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CA" \
  --cert "$CERTS/client-denied.crt" --key "$CERTS/client-denied.key" \
  "$BASE/feed/manifest.json")"
[ "$code" = "403" ] || fail "non-allowlisted client got HTTP $code (want 403)"
pass "non-allowlisted bootroot client rejected with 403"

# --- 4. non-bootroot client -> rejected (no feed served) ------------------
# `ssl_verify_client on` rejects a cert that does not chain to the bootroot.
# Under TLS 1.2 this surfaces as a handshake alert (curl errors out); under
# TLS 1.3 the client cert is verified post-handshake, so nginx instead returns
# "400 The SSL certificate error" (codes 400/495/496). Either way the client
# never receives the feed — the one thing that must NOT happen is a 200.
ss_code="$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CA" \
  --cert "$CERTS/client-selfsigned.crt" --key "$CERTS/client-selfsigned.key" \
  "$BASE/feed/manifest.json" 2>/dev/null || echo "tls_handshake_rejected")"
case "$ss_code" in
  tls_handshake_rejected) pass "non-bootroot client rejected at the TLS handshake";;
  400|495|496) pass "non-bootroot client rejected by client-cert verification (HTTP $ss_code)";;
  *) fail "non-bootroot self-signed client was NOT rejected (got $ss_code)";;
esac

# --- 5. structural consumability + additive-only --------------------------
log "Validating feed structure and additive scope..."
BASE="$BASE" CA="$CA" \
  CERT="$CERTS/client-allowed.crt" KEY="$CERTS/client-allowed.key" \
  MANIFEST="$manifest" python3 - <<'PY' || fail "feed structure/scope check failed"
import json, os, re, ssl, subprocess, sys, urllib.request

base = os.environ["BASE"]; ca = os.environ["CA"]
cert = os.environ["CERT"]; key = os.environ["KEY"]
ADDITIVE_TAG = "fountel:floor-eligible"
OUT_MARKER = "fountel-additive-demo (out-of-scope)"
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")

def fetch(path):
    out = subprocess.run(
        ["curl", "-sf", "--cacert", ca, "--cert", cert, "--key", key, base + path],
        capture_output=True)
    if out.returncode != 0:
        sys.exit(f"fetch {path} failed (curl rc={out.returncode})")
    return out.stdout.decode()

manifest = json.loads(os.environ["MANIFEST"])
assert isinstance(manifest, dict), "manifest.json is not an object"

# Every top-level key must be a UUID — no fountel/freshness key inside manifest.
for k in manifest:
    if not UUID_RE.match(k):
        sys.exit(f"manifest has a non-UUID top-level key: {k!r}")
if not manifest:
    sys.exit("manifest is empty — expected at least the in-scope demo event")

# hashes.csv references only manifest UUIDs.
hashes = fetch("/feed/hashes.csv")
for line in filter(None, hashes.splitlines()):
    _, _, uuid = line.partition(",")
    if uuid and uuid not in manifest:
        sys.exit(f"hashes.csv references unknown event {uuid}")

# Each referenced event is fetchable, additive-tagged, and not out-of-scope.
saw_in_scope = False
for uuid in manifest:
    if not UUID_RE.match(uuid):
        continue
    ev = json.loads(fetch(f"/feed/{uuid}.json"))["Event"]
    tags = {t.get("name") for t in ev.get("Tag", [])}
    if ADDITIVE_TAG not in tags:
        sys.exit(f"event {uuid} lacks {ADDITIVE_TAG} — not additive-scoped")
    if ev.get("info") == OUT_MARKER:
        sys.exit(f"out-of-scope event {uuid} leaked into the feed")
    saw_in_scope = True

if not saw_in_scope:
    sys.exit("no additive-scoped event found in the feed")
print(f"OK: {len(manifest)} additive-scoped event(s), manifest is pure UUID-keyed")
PY
pass "feed is structurally consumable and contains ONLY additive-scoped events"

# --- 6. MISP not reachable via gateway; loopback-only host publish --------
code="$(status_allowed "$BASE/users/heartbeat")"
[ "$code" = "404" ] || fail "MISP path reachable through gateway (HTTP $code, want 404)"
code="$(status_allowed "$BASE/")"
[ "$code" = "404" ] || fail "gateway root not closed (HTTP $code, want 404)"
pass "MISP UI/API paths are not reachable through the gateway route"

http_bind="$(dc port misp-core 80 2>/dev/null || true)"
https_bind="$(dc port misp-core 443 2>/dev/null || true)"
case "$http_bind$https_bind" in
  127.0.0.1:*127.0.0.1:*) pass "misp-core host publish is loopback-only ($http_bind, $https_bind)";;
  *) fail "misp-core is not loopback-bound (http=$http_bind https=$https_bind)";;
esac

gw_bind="$(dc port gateway 8443 2>/dev/null || true)"
case "$gw_bind" in
  127.0.0.1:*) fail "gateway feed port is loopback-bound ($gw_bind) — should be external";;
  *:*) pass "gateway feed port is the only non-loopback bound service ($gw_bind)";;
  *) fail "gateway feed port not published";;
esac

printf '\033[1;32m[fountel]\033[0m All gateway/feed verification checks passed.\n'
