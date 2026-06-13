# Dev MISP bring-up runbook

Bring the dev MISP stack up from scratch. Commands are copy-pasteable. Every
verification step prints something you can check.

## 0. Prerequisites

- Docker Engine + the `docker compose` v2 plugin.
- [`sops`](https://github.com/getsops/sops) and
  [`age`](https://github.com/FiloSottile/age) on your PATH.
- `python3` (for the taxonomy-enable step in bootstrap).
- The **sops decryption key** for the dev environment. If you are the first
  operator, the bootstrap script generates one; otherwise obtain decryption
  rights first — see [secrets.md](secrets.md), "Dev secret bootstrap".

```sh
docker compose version          # expect: Docker Compose version v2.x
sops --version && age --version  # both should print a version
```

All commands below run from the dev directory:

```sh
cd deploy/dev
```

## 1. Secrets

First operator (creates the encrypted secrets), one time:

```sh
./bin/secrets-init.sh
git add ../../.sops.yaml secrets.enc.env
git commit -m "Add dev MISP secrets (sops-encrypted)"
```

Already have `secrets.enc.env` and a key that can decrypt it? Skip straight to
step 2 — `up.sh` decrypts for you.

Verify the encrypted file is real ciphertext (no plaintext leaked):

```sh
grep -q 'sops' secrets.enc.env && echo "OK: sops-encrypted"
grep -Eq 'ENC\[' secrets.enc.env && echo "OK: values are encrypted"
```

## 2. Bring the stack up

```sh
./bin/up.sh --wait
```

This seeds `.env` from `.env.example` (first run), decrypts secrets into
`secrets/misp.secrets.env`, runs `docker compose up -d`, and waits for
`misp-core` to report healthy. First boot pulls images and initializes the DB,
so it can take a few minutes.

Verify all four services are up and healthy:

```sh
docker compose ps
```

Expect `redis`, `db`, `misp-modules`, and `misp-core` all `running`, with
`misp-core` showing `healthy`. Check the pinned images (no `:latest`):

```sh
docker compose config | grep -E 'image:'
# ghcr.io/misp/misp-docker/misp-core:v2.5.40
# ghcr.io/misp/misp-docker/misp-modules:v3.0.8
# mariadb:10.11
# valkey/valkey:7.2
```

## 3. Apply fountel config (idempotent)

```sh
./bin/bootstrap.sh
```

Loads + enables the `fountel:floor-eligible` taxonomy and applies baseline
settings. Safe to re-run; a second run is a no-op.

## 4. Verify

### Health endpoint

```sh
curl -ks https://localhost:8443/users/heartbeat && echo "  <- heartbeat OK"
```

### Admin login (local auth)

Read the generated admin credentials from the decrypted secrets, then log in:

```sh
echo "admin user: $(grep ADMIN_EMAIL .env | cut -d= -f2)"
echo "admin pass: $(grep '^ADMIN_PASSWORD=' secrets/misp.secrets.env | cut -d= -f2)"
```

Open `https://localhost:8443` in a browser (accept the self-signed dev cert)
and log in with those credentials. Or verify the admin REST key works:

```sh
ADMIN_KEY=$(grep '^ADMIN_KEY=' secrets/misp.secrets.env | cut -d= -f2)
curl -ks -H "Authorization: $ADMIN_KEY" -H "Accept: application/json" \
  https://localhost:8443/users/view/me | grep -Eo '"email": *"[^"]*"'
# -> "email": "admin@fountel.local"
```

### Taxonomy is loaded and enabled

```sh
ADMIN_KEY=$(grep '^ADMIN_KEY=' secrets/misp.secrets.env | cut -d= -f2)
curl -ks -H "Authorization: $ADMIN_KEY" -H "Accept: application/json" \
  https://localhost:8443/taxonomies/index \
  | grep -Eo '"namespace": *"fountel"' && echo "  <- fountel taxonomy present"
```

In the UI: **Event Actions → Taxonomies**, search `fountel`, confirm it is
enabled and `fountel:floor-eligible` exists.

## 5. Idempotency check

Re-running must not duplicate or clobber state:

```sh
./bin/up.sh          # compose reconciles; no new containers
./bin/bootstrap.sh   # settings unchanged, taxonomy already enabled
docker compose ps    # still exactly four services
```

## 6. Stop / reset

```sh
docker compose down                 # stop, keep data volumes
docker compose down -v              # stop and DELETE all data (full reset)
```

## Troubleshooting

- **Port already in use:** edit `CORE_HTTP_PORT` / `CORE_HTTPS_PORT` (and the
  port in `BASE_URL`) in `deploy/dev/.env`, then `./bin/up.sh` again.
- **`misp-core` never healthy:** `docker compose logs -f misp-core`. First boot
  is slow; the healthcheck allows a 60s start period plus retries.
- **Cannot decrypt:** you do not hold a recipient key for `secrets.enc.env`.
  See [secrets.md](secrets.md), "Additional operator".
- **Taxonomy enable skipped:** install `python3`, or enable `fountel` manually
  in the UI, then re-run `./bin/bootstrap.sh`.
- **Bumping versions:** change the pinned tags in `docker-compose.yml`, then
  `docker compose pull && ./bin/up.sh`.
