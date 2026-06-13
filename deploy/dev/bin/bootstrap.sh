#!/usr/bin/env bash
#
# Idempotent fountel-specific bootstrap, run AFTER the stack is up.
#
# Upstream misp-core already performs the base install idempotently from the
# environment (admin user, DB schema, salt, baseurl). This script layers the
# fountel-specific configuration on top, and is safe to re-run any number of
# times — every step reconciles to the desired state, none duplicates:
#
#   1. Loads the fountel:floor-eligible taxonomy into MISP and enables it.
#   2. Applies baseline security / hardening settings.
#
# Requires the stack to be running (./bin/up.sh) and the generated secrets
# (for ADMIN_KEY). Needs python3 on the host for the taxonomy-enable API call.

source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

require_cmd docker "https://docs.docker.com/get-docker/"
# python3 drives the taxonomy enable + verification below. It is a documented
# prerequisite (docs/runbook.md) and the taxonomy is a required deliverable, so
# its absence is a hard failure rather than a skipped step.
require_cmd python3 "https://www.python.org/downloads/"

dc() { ( cd "$DEV_DIR" && docker compose "$@" ); }
cake() { dc exec -T -u www-data misp-core /var/www/MISP/app/Console/cake "$@"; }

# --- preconditions ---------------------------------------------------------
[ -f "$PLAINTEXT_FILE" ] || die "Missing $PLAINTEXT_FILE. Run ./bin/up.sh first."
# shellcheck disable=SC1090
set -a; source "$PLAINTEXT_FILE"; set +a
[ -n "${ADMIN_KEY:-}" ] || die "ADMIN_KEY not found in secrets. Re-run ./bin/secrets-init.sh --rotate to add it."

# Read non-secret config (BASE_URL / ports) from .env if present.
[ -f "$DEV_DIR/.env" ] && { set -a; # shellcheck disable=SC1091
  source "$DEV_DIR/.env"; set +a; }
BASE_URL="${BASE_URL:-https://localhost:8443}"
HTTPS_PORT="${CORE_HTTPS_PORT:-8443}"

log "Waiting for misp-core to be healthy..."
for _ in $(seq 1 120); do
  [ "$(dc ps --format '{{.Health}}' misp-core 2>/dev/null)" = "healthy" ] && break
  sleep 5
done
[ "$(dc ps --format '{{.Health}}' misp-core 2>/dev/null)" = "healthy" ] \
  || die "misp-core did not become healthy. Check: docker compose logs misp-core"

# --- 1. taxonomy -----------------------------------------------------------
# Copy the fountel taxonomy into misp-core's files/ (a named volume) so MISP's
# loader can see it, then import the definitions into the DB. Idempotent:
# the copy overwrites; updateTaxonomies upserts.
log "Installing fountel:floor-eligible taxonomy..."
TAX_DIR=/var/www/MISP/app/files/taxonomies/fountel
dc exec -T misp-core mkdir -p "$TAX_DIR"
dc cp "$DEV_DIR/taxonomies/fountel/machinetag.json" "misp-core:$TAX_DIR/machinetag.json"
dc exec -T misp-core chown -R www-data:www-data "$TAX_DIR"
cake Admin updateTaxonomies >/dev/null || die "updateTaxonomies failed; check: docker compose logs misp-core"

# Enable the taxonomy, create its tag, and VERIFY both via the REST API (no
# cake equivalent). A working fountel:floor-eligible taxonomy is a required
# acceptance criterion, so any failure here is fatal: bootstrap must not report
# success unless 'fountel' is enabled and 'fountel:floor-eligible' exists.
ADMIN_KEY="$ADMIN_KEY" MISP_URL="https://localhost:${HTTPS_PORT}" python3 - <<'PY' \
  || die "Taxonomy enable/verify failed; check: docker compose logs misp-core"
import json, os, ssl, sys, time, urllib.error, urllib.request

base = os.environ["MISP_URL"]
key = os.environ["ADMIN_KEY"]
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

def call(method, path):
    req = urllib.request.Request(base + path, method=method,
        headers={"Authorization": key, "Accept": "application/json",
                 "Content-Type": "application/json"})
    with urllib.request.urlopen(req, context=ctx, timeout=30) as r:
        body = r.read().decode()
        return json.loads(body) if body.strip() else {}

# The misp-core healthcheck (/users/heartbeat) can pass BEFORE the entrypoint
# has applied the admin authkey, so the first authenticated calls may 403 (or
# the API may not answer yet). Poll until the admin key is accepted, then act.
for attempt in range(36):  # ~3 min at 5s
    try:
        call("GET", "/users/view/me")
        break
    except (urllib.error.HTTPError, urllib.error.URLError, OSError) as e:
        code = getattr(e, "code", None)
        if code is not None and code not in (401, 403, 500, 502, 503):
            raise
        time.sleep(5)
else:
    print("admin API never accepted the admin key (after ~3 min)", file=sys.stderr)
    sys.exit(1)

idx = call("GET", "/taxonomies/index")
rows = idx if isinstance(idx, list) else idx.get("response", idx)
tid = None
for row in rows:
    tax = row.get("Taxonomy", row)
    if tax.get("namespace") == "fountel":
        tid = tax.get("id"); break
if tid is None:
    print("fountel taxonomy not found after updateTaxonomies", file=sys.stderr); sys.exit(1)

call("POST", f"/taxonomies/enable/{tid}")   # idempotent: enabling an enabled taxonomy is a no-op
call("POST", f"/taxonomies/addTag/{tid}")   # create/enable all of its tags (fountel:floor-eligible)

# Verify the required end state rather than trusting the calls above: re-fetch
# the taxonomy and confirm it is enabled AND its fountel:floor-eligible tag now
# exists. Exit non-zero (-> bootstrap dies) if either is not true.
view = call("GET", f"/taxonomies/view/{tid}")
tax = view.get("Taxonomy", {}) if isinstance(view, dict) else {}
if str(tax.get("enabled")).lower() not in ("1", "true"):
    print("fountel taxonomy is not enabled after enable call", file=sys.stderr); sys.exit(1)
entries = view.get("entries", []) if isinstance(view, dict) else []
if not any(e.get("tag") == "fountel:floor-eligible" and e.get("existing_tag")
           for e in entries):
    print("fountel:floor-eligible tag not found after addTag", file=sys.stderr); sys.exit(1)
print(f"fountel taxonomy (id={tid}) enabled and fountel:floor-eligible tag verified.")
PY

# --- 2. baseline settings / hardening --------------------------------------
log "Applying baseline settings..."
# --force: some settings carry a guard validator that rejects an otherwise
# valid value (e.g. MISP.disable_emailing reports "E-mailing is blocked" and
# refuses the change without it). We are deliberately applying the dev baseline,
# so bypass those guards. Unknown setting names still error.
#
# Baseline hardening is part of #3's scope, so a failure here is FATAL rather
# than a warning: a typo/rename in a setting name, a permission/config-write
# failure, or a rejected value must not leave MISP.live, the password policy,
# email disabling, or enrichment wiring unapplied while the operator sees a
# successful "Bootstrap complete". The error output is surfaced, not swallowed.
set_setting() {
  local out
  if ! out=$(cake Admin setSetting --force "$1" "$2" 2>&1); then
    die "could not apply baseline setting $1: ${out:-<no output>}"
  fi
}

set_setting "MISP.baseurl"                       "$BASE_URL"
set_setting "MISP.external_baseurl"              "$BASE_URL"
set_setting "MISP.live"                          true
set_setting "MISP.disable_emailing"              true      # dev has no real SMTP relay
set_setting "MISP.terms_download"                false
set_setting "Security.require_password_confirmation" true
set_setting "Security.password_policy_length"    12
# Wire enrichment to the misp-modules service on the compose network.
set_setting "Plugin.Enrichment_services_enable"  true
set_setting "Plugin.Enrichment_services_url"     "http://misp-modules"
set_setting "Plugin.Enrichment_services_port"    6666

log "Bootstrap complete. fountel:floor-eligible is loaded; soft-by-default policy applies (docs/curation.md)."
