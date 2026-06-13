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
hardening, secrets, curation taxonomy, and (later) the mTLS gateway and feed
publishing.

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
- **Secrets** are stored as [sops](https://github.com/getsops/sops)-encrypted
  files in this repo and decrypted into a git-ignored `secrets/` directory at
  deploy time. No plaintext secret material is ever committed.
- **Operator auth** is MISP's built-in local auth (roles / ACL / API keys).
  No external SSO in v1.
- **Curation is soft-by-default**: everything published is treated as soft
  (LLM-enrichment) intel unless a source has been explicitly vetted and tagged
  `fountel:floor-eligible`.

## What is NOT in this repo / this stage

- The aimer-web pull adapter (separate repo, see above).
- The mTLS gateway, the SAN-allowlist authorization service, and feed
  publishing (tracked separately; not part of the initial dev-stack scaffold).
- prod deployment, backups, HA, and dedicated secret/SSO infrastructure
  (Phase 2 / prod-hardening, deferred).

## Quickstart

The dev stack lives under [`deploy/dev/`](deploy/dev/). To bring it up you
need the sops decryption key for this environment.

The encrypted dev secrets are already committed; you just need a key that can
decrypt them (see [docs/secrets.md](docs/secrets.md), "Additional operator").

```sh
cd deploy/dev

# Every bring-up: decrypt the committed secrets and start the stack.
./bin/up.sh

# Apply fountel-specific config (taxonomy, baseline settings). Idempotent.
./bin/bootstrap.sh
```

See the **[bring-up runbook](docs/runbook.md)** for the full, copy-pasteable
procedure and verification commands, and **[docs/](docs/)** for the secret
bootstrap, curation policy, and environment layout.

## Documentation

| Document | What it covers |
| --- | --- |
| [docs/runbook.md](docs/runbook.md) | Bring the dev stack up from scratch, with verification commands. |
| [docs/secrets.md](docs/secrets.md) | sops, `.sops.yaml` recipient policy, and the dev secret bootstrap procedure. |
| [docs/curation.md](docs/curation.md) | The `fountel:floor-eligible` taxonomy and the soft-by-default curation policy. |
| [docs/environments.md](docs/environments.md) | dev/prod environment layout and what is deferred to prod. |

## License

MISP itself is AGPL and is used unmodified. This repository's own
configuration and tooling are licensed under [Apache-2.0](LICENSE).
