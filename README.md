# fountel

fountel deploys and operates a **vendor-central MISP server** as an
**additive** threat-intelligence source for aimer-web.

## Mission

fountel stands up and runs a single, vendor-central
[MISP](https://www.misp-project.org/) hub (the CIRCL open-source Threat
Intelligence Platform) and publishes a **curated, additive** subset of its
intel to aimer-web. "Additive" means fountel only ever *adds* context: it
never carries the feeds aimer-web already ingests directly (abuse.ch,
Spamhaus), and customer-observed indicators never flow into MISP — only
*feed data* flows out.

fountel **is MISP-based**: it deploys upstream MISP as-is and never forks or
rebuilds it. "MISP" is the proper name of the upstream project; fountel does
not brand itself with it.

## Repo boundary

This repository **operates MISP** — the server stack, its configuration and
hardening, secrets, curation taxonomy, and the mTLS gateway and feed publishing.

The **aimer-web pull adapter** — the code that pulls fountel's published
feed and imports it into aimer-web — is a **separate, cross-repo effort** and
lives in the `aimer-web` repository, **not here**. fountel defines and
publishes the feed contract; aimer-web consumes it.

This split is deliberate: fountel never reaches into aimer-web, and the only
coupling between them is the published feed format and the mTLS transport.

## Posture (v1, dev)

- **Vendor-central single hub**, with a **dev/prod split**; dev is stood up
  first. This repo currently contains the **dev** stack.
- **Upstream MISP, no fork/build** — images are pulled, version-pinned, and
  used as-is.
- **Connection is periodic pull/sync, not query-time.** aimer-web pulls
  published feeds into its own store and matches locally; observed indicators
  never egress to MISP.
- **Secrets** are random and disposable in dev: they are generated locally at
  bring-up into a git-ignored `secrets/` directory. No secret material is ever
  committed. (prod will inject secrets from a secret manager — Phase 2.)
- **Operator auth** is MISP's built-in local auth (roles / ACL / API keys).
  No external SSO in v1.
- **Curation is soft-by-default**: everything published is treated as soft
  (LLM-enrichment) intel unless a source has been explicitly vetted and tagged
  `fountel:floor-eligible`.

- **Additive-sync exposure** is wired in: an **nginx mTLS gateway** (the only
  externally-reachable service) fronts a **scheduled, MISP-native feed export**
  of the additive-scoped snapshot, authorizing clients via the SAN-allowlist
  service. See [docs/gateway.md](docs/gateway.md).

## What is NOT part of this dev-MISP stack

- The aimer-web pull adapter — a **separate repo** (see above), not here. fountel
  serves a fetchable, structurally valid feed; consuming/diffing/expiring it is
  aimer-web's job.
- prod deployment, backups, HA, and dedicated secret/SSO infrastructure
  (Phase 2 / prod-hardening, deferred).
- Certificate **issuance/rotation** — the gateway only **consumes**
  externally-provisioned bootroot mTLS PEMs; fountel builds no issuance machinery.

The **SAN-allowlist authorization service** lives in this repo under
[`gateway/san-auth/`](gateway/san-auth/) as its own independently-developed
component; the dev stack now builds it as a container and the mTLS gateway calls
it via `auth_request`.

## Quickstart

The dev stack lives under [`deploy/dev/`](deploy/dev/). Dev generates its own
secrets locally at bring-up — nothing secret is committed and there is no
sops/age key to obtain. You only need Docker, `openssl`, and `python3` (see the
[runbook](docs/runbook.md)).

```sh
cd deploy/dev

# Generate local dev secrets (or let up.sh do it automatically on first run).
./bin/secrets-init.sh

# Every bring-up: start the stack.
./bin/up.sh

# Apply fountel-specific config (taxonomy, baseline settings). Idempotent.
./bin/bootstrap.sh

# Verify the mTLS gateway + published feed (seeds demo events, runs curl checks).
./bin/seed-additive-event.sh
./bin/verify-gateway.sh
```

`up.sh` starts the MISP stack plus the mTLS `gateway`, `san-auth`, and
`feed-exporter`. The gateway is the only externally-reachable service; MISP's
UI/API stay loopback-bound and admin-only.

See the **[bring-up runbook](docs/runbook.md)** for the full, copy-pasteable
procedure and verification commands, the **[gateway & feed guide](docs/gateway.md)**
for the exposure design, and **[docs/](docs/)** for the secret bootstrap,
curation policy, and environment layout.

## Documentation

| Document | What it covers |
| --- | --- |
| [docs/runbook.md](docs/runbook.md) | Bring the dev stack up from scratch, with verification commands. |
| [docs/secrets.md](docs/secrets.md) | Local dev secret generation (nothing committed) and the bootstrap procedure. |
| [docs/curation.md](docs/curation.md) | The `fountel:floor-eligible` taxonomy and the soft-by-default curation policy. |
| [docs/gateway.md](docs/gateway.md) | The mTLS gateway, SAN authorization, and additive feed publishing. |
| [docs/environments.md](docs/environments.md) | dev/prod environment layout and what is deferred to prod. |

## License

MISP itself is AGPL and is used unmodified. This repository's own
configuration and tooling are licensed under [Apache-2.0](LICENSE).
