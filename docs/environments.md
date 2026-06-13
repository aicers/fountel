# Environment layout

fountel is a vendor-central hub with a **dev/prod split**: each aimer-web
environment syncs its paired MISP, and dev is stood up first. Environments are
isolated by directory so their stacks and secrets never share state.

```
deploy/
  dev/                     # the dev MISP stack + additive-sync exposure
    docker-compose.yml     # misp-core + MariaDB + Redis(Valkey) + misp-modules
                           #   + gateway (nginx mTLS) + san-auth + feed-exporter, pinned
    .env.example           # non-secret compose interpolation vars
    secrets.example.env    # secret schema (placeholders, non-secret)
    secrets/               # git-ignored secrets, generated locally at bring-up
    taxonomies/fountel/    # fountel:floor-eligible taxonomy definition
    gateway/               # nginx.conf (committed) + certs/ (git-ignored dev PEMs)
    feed-exporter/         # PyMISP feed-export job + pinned export-filter.yaml
    bin/                   # secrets-init, up, bootstrap, gen-dev-certs, seed, verify
  prod/                    # Phase 2 — placeholder only (see deploy/prod/README.md)

docs/                      # runbook, secrets, curation, environments, gateway
```

The #2 SAN-allowlist authorization service the gateway calls lives at the repo
root under [`gateway/san-auth/`](../gateway/san-auth/) — its own
independently-developed component, built into the stack as a container.

## dev

The fully-defined environment. See the [runbook](runbook.md) to bring it up.
The **admin** UI/API listen on **loopback** at `https://127.0.0.1:8443` (and
`http://127.0.0.1:8080`); the **mTLS feed gateway** — the only externally-bound
service — listens at `https://<host>:18443/feed/` (see [gateway.md](gateway.md)).
Change the host ports in `deploy/dev/.env` if they conflict.

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
