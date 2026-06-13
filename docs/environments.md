# Environment layout

fountel is a vendor-central hub with a **dev/prod split**: each aimer-web
environment syncs its paired MISP, and dev is stood up first. Environments are
isolated by directory so their stacks, secrets, and recipient policies never
share state.

```
deploy/
  dev/                     # the dev MISP stack (this issue)
    docker-compose.yml     # misp-core + MariaDB + Redis(Valkey) + misp-modules, pinned
    .env.example           # non-secret compose interpolation vars
    secrets.example.env    # secret schema (placeholders, non-secret)
    secrets.enc.env        # sops-encrypted secrets (created by bin/secrets-init.sh)
    secrets/               # git-ignored decrypted plaintext (created at deploy)
    taxonomies/fountel/    # fountel:floor-eligible taxonomy definition
    bin/                   # secrets-init, secrets-decrypt, up, bootstrap
  prod/                    # Phase 2 — placeholder only (see deploy/prod/README.md)

docs/                      # runbook, secrets, curation, environments
.sops.yaml                 # recipient policy: which key(s) may decrypt per env
```

## dev

The fully-defined environment. See the [runbook](runbook.md) to bring it up.
Listens on the host at `https://localhost:8443` (and `http://localhost:8080`)
by default; change the host ports in `deploy/dev/.env` if they conflict.

## prod

Intentionally a **placeholder** at this stage. prod deployment — orchestrator
choice (compose vs k8s), HA stance, backups (MariaDB + `files/` + GnuPG
private key + config), and dev/prod isolation mechanics (separate hosts,
separate sops recipients/allowlists) — is **deferred to a prod-hardening
effort** and does not block the dev MVP. The `.sops.yaml` already reserves a
`deploy/prod/*.enc.*` recipient rule so prod secrets stay isolated from dev
when that work begins.

## Isolation invariants

- Each environment has its **own** secrets and **own** sops recipients; a dev
  key never decrypts prod material.
- Image tags are **pinned per environment** in that environment's
  `docker-compose.yml` (no `:latest`), so dev and prod can move independently
  and reproducibly.
