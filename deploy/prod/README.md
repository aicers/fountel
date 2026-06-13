# deploy/prod — placeholder (Phase 2)

The prod MISP environment is **not defined yet**. It is deferred to a
prod-hardening effort and does not block the dev MVP.

Open decisions captured for when prod is on the table:

- **Orchestrator:** docker compose vs. Kubernetes.
- **HA stance:** likely single-instance + strong backups for v1.
- **Backups:** MariaDB + MISP `files/` (attachments, **GnuPG private key**) +
  config; method, cadence, retention, encryption, restore drill, RTO/RPO.
- **Isolation:** separate hosts, separate bootroot intermediates, separate
  sops recipients and SAN allowlists from dev.

Secret isolation is already reserved: `.sops.yaml` has a
`deploy/prod/*.enc.*` recipient rule distinct from dev, so prod secrets will
never be decryptable with a dev key.

Until this environment is defined, use [`deploy/dev/`](../dev/).
