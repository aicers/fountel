#!/usr/bin/env bash
#
# Seed demo events for feed verification (dev-only).
#
# Creates TWO events via the MISP REST API so the published snapshot can be
# checked against the pinned additive filter (issue #4):
#
#   1. IN scope  — org fountel, tagged `fountel:floor-eligible`, published.
#                  This MUST appear in the served feed.
#   2. OUT of scope — published but NOT tagged `fountel:floor-eligible`.
#                  This MUST NOT appear in the served feed, proving the filter.
#
# Idempotent: each event carries a marker in its `info` string; a matching
# event is reused rather than duplicated. Run AFTER ./bin/bootstrap.sh (the
# floor-eligible taxonomy/tag must already exist).

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

require_cmd python3 "https://www.python.org/downloads/"

[ -f "$PLAINTEXT_FILE" ] || die "Missing $PLAINTEXT_FILE. Run ./bin/up.sh first."
# shellcheck disable=SC1090
set -a; source "$PLAINTEXT_FILE"; set +a
[ -n "${ADMIN_KEY:-}" ] || die "ADMIN_KEY not found in secrets."

[ -f "$DEV_DIR/.env" ] && { set -a; # shellcheck disable=SC1091
  source "$DEV_DIR/.env"; set +a; }
HTTPS_PORT="${CORE_HTTPS_PORT:-8443}"

log "Seeding additive (in-scope) and out-of-scope demo events..."
ADMIN_KEY="$ADMIN_KEY" MISP_URL="https://127.0.0.1:${HTTPS_PORT}" python3 - <<'PY' \
  || die "Seeding failed; check: docker compose logs misp-core"
import json, os, ssl, sys, urllib.error, urllib.request

base = os.environ["MISP_URL"]
key = os.environ["ADMIN_KEY"]
ctx = ssl.create_default_context(); ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

IN_MARKER = "fountel-additive-demo (in-scope)"
OUT_MARKER = "fountel-additive-demo (out-of-scope)"
ADDITIVE_TAG = "fountel:floor-eligible"

def call(method, path, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(base + path, data=data, method=method,
        headers={"Authorization": key, "Accept": "application/json",
                 "Content-Type": "application/json"})
    with urllib.request.urlopen(req, context=ctx, timeout=30) as r:
        body = r.read().decode()
        return json.loads(body) if body.strip() else {}

def find_event(marker):
    res = call("POST", "/events/restSearch", {"eventinfo": marker})
    rows = res.get("response", res) if isinstance(res, dict) else res
    for row in (rows or []):
        ev = row.get("Event", row)
        if ev.get("info") == marker:
            return ev.get("uuid")
    return None

def create_event(marker, attr_value, tag=None):
    uuid = find_event(marker)
    if uuid:
        print(f"reusing event {uuid} ({marker!r})")
        return uuid
    payload = {"Event": {"info": marker, "distribution": "1",
        "analysis": "2", "threat_level_id": "3",
        "Attribute": [{"type": "domain", "category": "Network activity",
                       "value": attr_value, "to_ids": True}]}}
    res = call("POST", "/events/add", payload)
    ev = res.get("Event", res)
    uuid = ev.get("uuid")
    if not uuid:
        print("could not create event:", json.dumps(res)[:400], file=sys.stderr)
        sys.exit(1)
    if tag:
        call("POST", "/events/addTag", {"event": uuid, "tag": tag})
    call("POST", f"/events/publish/{uuid}")
    print(f"created+published event {uuid} ({marker!r}, tag={tag})")
    return uuid

in_uuid = create_event(IN_MARKER, "additive-demo.fountel.test", ADDITIVE_TAG)
out_uuid = create_event(OUT_MARKER, "excluded-demo.fountel.test", None)
print(json.dumps({"in_scope": in_uuid, "out_of_scope": out_uuid}))
PY

log "Seed complete. Trigger an export, then verify with ./bin/verify-gateway.sh."
