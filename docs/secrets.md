# Secrets: sops, recipient policy, and the dev bootstrap procedure

fountel keeps **no plaintext secret material in the repository**. The only
secret artifact committed is a [sops](https://github.com/getsops/sops)-encrypted
file; it is decrypted into a git-ignored directory at deploy time.

## What is a secret here

| Secret | Used by | Notes |
| --- | --- | --- |
| `MYSQL_PASSWORD` | misp-core, db | App DB user. |
| `MYSQL_ROOT_PASSWORD` | db | DB root. |
| `REDIS_PASSWORD` | misp-core, redis | Valkey/Redis AUTH. |
| `ADMIN_PASSWORD` | misp-core | MISP site-admin login. |
| `SALT` | misp-core | `security.salt`; set once, kept stable. |
| `GPG_PASSPHRASE` | misp-core | Instance GnuPG key passphrase. |
| `ADMIN_KEY` | misp-core, bootstrap | Fixed admin REST API key. |
| `SMARTHOST_PASSWORD` | misp-core | SMTP relay; empty in dev. |

The schema (with non-secret placeholders) is committed as
[`deploy/dev/secrets.example.env`](../deploy/dev/secrets.example.env).

> **GnuPG key.** MISP generates the instance GnuPG key from `GPG_PASSPHRASE`
> on first boot and stores it in the `misp_gnupg` Docker named volume. Only
> the passphrase is managed as a secret here; backing up the generated private
> key is a Phase-2 (prod) concern.

## The inject path (single and obvious)

```
secrets.enc.env   ──sops --decrypt──▶   secrets/misp.secrets.env   ──env_file:──▶   containers
 (committed,                              (git-ignored plaintext,                     (misp-core,
  encrypted)                               mode 600)                                   db, redis)
```

`./bin/secrets-decrypt.sh` performs the decrypt; `docker-compose.yml` reads the
result via `env_file:`. There is exactly one inject path.

### Why `env_file:` and not Docker `secrets:`

Issue #3 names compose `secrets: { file: ./secrets/... }` as the example
mechanism. We use `env_file:` pointing at the same git-ignored `secrets/`
directory instead, for a concrete reason:

- Upstream `misp-core` reads its credentials **from environment variables**
  and has **no `_FILE` / `/run/secrets` convention**. Docker `secrets:`
  mounts files at `/run/secrets/<name>`, which the unmodified image never
  reads.
- Making the image consume `secrets:` would require **patching its
  entrypoint** — a fork-like change ruled out by the project invariant
  *"upstream MISP, no fork/build"* (issue #1).

So we keep the **invariant that matters** — only the encrypted file is
committed, the plaintext lives solely in the git-ignored `secrets/` dir, and
the deploy step is a single decrypt-to-dir — using the mechanism the upstream
image actually supports. This is **not** the rejected `sops exec-env`
wrapper: sops only writes files; compose reads them.

## Recipient policy (`.sops.yaml`)

[`.sops.yaml`](../.sops.yaml) at the repo root is the single source of truth
for *who may decrypt*. Each `creation_rules` entry binds a path pattern to the
age recipients (public keys) allowed to decrypt files under it:

- `deploy/dev/*.enc.*` → dev recipients
- `deploy/prod/*.enc.*` → prod recipients (Phase 2)

**Grant** access: add the operator's age public key to the rule and re-key the
files (`sops updatekeys deploy/dev/secrets.enc.env`).
**Revoke** access: remove the key, `sops updatekeys`, then **rotate** the
secret values (`./bin/secrets-init.sh --rotate`) — a former recipient may
still hold old plaintext.

> **Rotation takes effect only after a volume reset.** MariaDB and MISP bake
> the DB password into their persistent volumes (`mysql_data`, `misp_configs`)
> on first init and do not re-read it on a plain restart. After rotating,
> `docker compose down -v` then `./bin/up.sh` so the DB user and `database.php`
> are regenerated together from the new secrets. (This is also why all MISP
> state is kept in named volumes rather than host bind mounts — `down -v`
> resets DB and config atomically, so they can never desync.)

## Dev secret bootstrap procedure

### Prerequisites

Install the tooling (macOS shown; use your package manager):

```sh
brew install sops age
```

### A. The committed dev secrets

The encrypted dev secrets are **already committed** as
`deploy/dev/secrets.enc.env`, encrypted to the dev recipient in `.sops.yaml`.
You do not create them — you obtain a key that can decrypt them (section B),
then bring the stack up (section C). The decryption key itself lives **outside
the repo**: the bootstrap operator who generated it holds it in the team
secret store and grants other operators by adding their public key as a
recipient.

> **Re-bootstrapping from scratch (rare).** If you are standing up an entirely
> new environment, or the encrypted file and every key copy were lost,
> `./bin/secrets-init.sh` regenerates the age key + encrypted file; commit
> `.sops.yaml` and `secrets.enc.env`. Use `--rotate` to regenerate the secret
> *values* of an existing environment (then reset volumes — see Rotation
> above). For the committed dev environment, neither is part of normal
> bring-up.

### B. Additional operator (already has the encrypted file)

1. Generate your own key and print your public key:
   ```sh
   age-keygen -o ~/.config/sops/age/keys.txt
   age-keygen -y ~/.config/sops/age/keys.txt    # the age1... line to share
   ```
2. Send the `age1...` public key to an existing operator, who adds it to
   `.sops.yaml` and runs `sops updatekeys deploy/dev/secrets.enc.env`, then
   commits.
3. Pull, and you can now decrypt.

### C. Bring the stack up

With a key that can decrypt:

```sh
cd deploy/dev
./bin/up.sh          # decrypts secrets, starts the stack
./bin/bootstrap.sh   # idempotent fountel config (taxonomy, settings)
```

`secrets/misp.secrets.env` (the decrypted plaintext) is created here and is
git-ignored. Never commit it.

## What is committed vs. ignored

| Committed | Git-ignored |
| --- | --- |
| `secrets.enc.env` (encrypted) | `secrets/` (decrypted plaintext) |
| `secrets.example.env` (placeholders) | `.env` (local compose config) |
| `.sops.yaml` (recipient policy) | `~/.config/sops/age/keys.txt` (private key, outside repo) |

The `.gitignore` enforces this: `secrets/`, `*.secrets.env`, `.env`, and age
key files are excluded; `*.enc.*` is explicitly kept.
