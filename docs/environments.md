# Environment layout

fountel is a vendor-central hub with a **dev/prod split**: each aimer-web
environment syncs its paired MISP, and dev is stood up first. Environments are
isolated by directory so their stacks and secrets never share state.

```
deploy/
  dev/                     # the dev MISP stack (this issue)
    docker-compose.yml     # misp-core + MariaDB + Redis(Valkey) + misp-modules, pinned
    .env.example           # non-secret compose interpolation vars
    secrets.example.env    # secret schema (placeholders, non-secret)
    secrets/               # git-ignored secrets, generated locally at bring-up
    taxonomies/fountel/    # fountel:floor-eligible taxonomy definition
    bin/                   # secrets-init, up, bootstrap
  prod/                    # Phase 2 — placeholder only (see deploy/prod/README.md)

docs/                      # runbook, secrets, curation, environments
```

## dev

The fully-defined environment. See the [runbook](runbook.md) to bring it up.
Listens on the host at `https://localhost:8443` (and `http://localhost:8080`)
by default; change the host ports in `deploy/dev/.env` if they conflict.

## prod

Intentionally a **placeholder** at this stage. prod deployment — orchestrator
choice (compose vs k8s), HA stance, backups (MariaDB + `files/` + GnuPG
private key + config), and dev/prod isolation mechanics (separate hosts,
separate SAN allowlists) — is **deferred to a prod-hardening effort** and does
not block the dev MVP. prod secrets will be injected from a **secret manager**
(not sops, and nothing in the repo); that is Phase 2, tracked in #1's deferred
list.

## Isolation invariants

- Each environment has its **own** secrets; dev generates random, disposable
  secrets locally, while prod will source its own from a secret manager
  (Phase 2). Nothing secret is committed for either.
- Image tags are **pinned per environment** in that environment's
  `docker-compose.yml` (no `:latest`), so dev and prod can move independently
  and reproducibly.
