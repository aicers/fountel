# deploy/prod — placeholder (Phase 2)

The prod MISP environment is **not defined yet**. It is deferred to a
prod-hardening effort and does not block the dev MVP.

Open decisions captured for when prod is on the table:

- **Orchestrator:** docker compose vs. Kubernetes.
- **HA stance:** likely single-instance + strong backups for v1.
- **Backups:** MariaDB + MISP `files/` (attachments, **GnuPG private key**) +
  config; method, cadence, retention, encryption, restore drill, RTO/RPO.
- **Secrets:** injected from a **secret manager** (not sops, and nothing in the
  repo). Tracked in #1's deferred list.
- **Isolation:** separate hosts, separate bootroot intermediates, separate
  secret-manager scopes and SAN allowlists from dev.

Secret isolation is by design: prod secrets come from a prod-scoped secret
manager, distinct from dev's locally-generated secrets, so they never share
state.

Until this environment is defined, use [`deploy/dev/`](../dev/).
