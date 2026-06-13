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
| `GPG_PASSPHRASE` | misp-core | Passphrase protecting the instance GnuPG key. |
| `ADMIN_KEY` | misp-core, bootstrap | Fixed admin REST API key. |
| `SMARTHOST_PASSWORD` | misp-core | SMTP relay; empty in dev. |
| GnuPG private key | misp-core | Instance signing key; committed as the separate sops file `gnupg.secret.enc.asc`. |

The dotenv schema (with non-secret placeholders) is committed as
[`deploy/dev/secrets.example.env`](../deploy/dev/secrets.example.env).

> **GnuPG key.** The instance GnuPG private key is committed secret material,
> not volume-local runtime state. Armored ASCII is multi-line and cannot live
> in a dotenv file, so it is stored as its own sops file
> `deploy/dev/gnupg.secret.enc.asc`, protected with `GPG_PASSPHRASE`.
> `secrets-init.sh` generates the passphrase and the key together so they
> always match; both are committed as a coupled pair (a failed rotation rolls
> back both). At deploy the key is decrypted to `secrets/misp.gnupg.asc` and
> seeded into the `misp_gnupg` volume **before** misp-core boots. Upstream
> `configure_gnupg` uses an existing key when `${GPG_DIR}/trustdb.gpg` is
> present and only autogenerates otherwise, so pre-seeding is the image's own
> supported path — **no fork**. Result: an operator holding the sops key
> reconstructs the *same* instance signing key, even after `docker compose
> down -v`. If `gnupg.secret.enc.asc` is ever absent, deploy falls back to
> upstream autogeneration (a fresh key per volume reset).

## The inject path (single and obvious)

```
secrets.enc.env        ──sops --decrypt──▶  secrets/misp.secrets.env  ──env_file:──────▶  containers
 (committed, encrypted)                       (git-ignored, 600)                            (misp-core, db, redis)

gnupg.secret.enc.asc   ──sops --decrypt──▶  secrets/misp.gnupg.asc    ──seed misp_gnupg──▶  misp-core
 (committed, encrypted)                       (git-ignored, 600)         volume (pre-boot)    (instance signing key)
```

`./bin/secrets-decrypt.sh` performs both decrypts; `docker-compose.yml` reads
the dotenv result via `env_file:`, and `./bin/up.sh` seeds the GnuPG key into
the `misp_gnupg` volume before bring-up. Both flow from committed sops files to
the git-ignored `secrets/` dir — one inject path, two artifacts.

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

So we keep the **invariant that matters** — only encrypted files are
committed, the plaintext lives solely in the git-ignored `secrets/` dir, and
the deploy step decrypts to that dir — using the mechanism the upstream image
actually supports. (The GnuPG key adds one more committed sops file decrypted
into the same dir, then seeded into the `misp_gnupg` volume via the image's own
pre-generated-key path; see the GnuPG note above.) This is **not** the rejected
`sops exec-env` wrapper: sops only writes files; compose and the seed step read
them.

## Recipient policy (`.sops.yaml`)

[`.sops.yaml`](../.sops.yaml) at the repo root is the single source of truth
for *who may decrypt*. Each `creation_rules` entry binds a path pattern to the
age recipients (public keys) allowed to decrypt files under it:

- `deploy/dev/*.enc.*` → dev recipients
- `deploy/prod/*.enc.*` → prod recipients (Phase 2)

**Grant** access: add the operator's age public key to the rule and re-key
**every** dev file (`sops updatekeys deploy/dev/secrets.enc.env` and
`sops updatekeys deploy/dev/gnupg.secret.enc.asc`).
**Revoke** access: remove the key, `sops updatekeys` both files, then
**rotate** the secret values (`./bin/secrets-init.sh --rotate`, which also
regenerates the GnuPG key) — a former recipient may still hold old plaintext.

`secrets-init.sh` treats this policy as authoritative, so a rotation can never
silently narrow it: it bootstrap-encrypts the new values to the local key, then
runs `sops updatekeys` to re-key the committed file to *every* recipient the
dev rule lists (so other dev operators keep access across a `--rotate`). If the
local operator's key is not in `.sops.yaml`, the script fails rather than ship a
file that does not match the policy — add the key to the rule first. If the
re-key step itself fails (bad `.sops.yaml`, an added recipient with no valid
key), the script restores the previous committed `secrets.enc.env` (or removes
the partial file on a first run) before aborting, so a failed rotation can never
leave a commit-ready file encrypted only to the local operator.

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
brew install sops age gnupg
```

`gnupg` is needed only by `secrets-init.sh` (to generate the instance GnuPG
key); a normal decrypt + bring-up uses the `gpg` inside the misp-core image.

### A. The committed dev secrets

The encrypted dev secrets are **already committed**: the dotenv bundle
`deploy/dev/secrets.enc.env` and the instance GnuPG key
`deploy/dev/gnupg.secret.enc.asc`, both encrypted to the dev recipient in
`.sops.yaml`. You do not create them — you obtain a key that can decrypt them
(section B), then bring the stack up (section C). The decryption key itself
lives **outside the repo**: the bootstrap operator who generated it holds it in
the team secret store and grants other operators by adding their public key as
a recipient.

> **Re-bootstrapping from scratch (rare).** If you are standing up an entirely
> new environment, or the encrypted files and every key copy were lost,
> `./bin/secrets-init.sh` regenerates the age key, the secret values, and the
> instance GnuPG key, writing both encrypted files; commit `.sops.yaml`,
> `secrets.enc.env`, and `gnupg.secret.enc.asc`. Use `--rotate` to regenerate
> the secret *values* of an existing environment (then reset volumes — see
> Rotation above). For the committed dev environment, neither is part of normal
> bring-up.

### B. Additional operator (already has the encrypted files)

1. Generate your own key and print your public key:
   ```sh
   age-keygen -o ~/.config/sops/age/keys.txt
   age-keygen -y ~/.config/sops/age/keys.txt    # the age1... line to share
   ```
2. Send the `age1...` public key to an existing operator, who adds it to
   `.sops.yaml` and re-keys **both** committed files, then commits:
   ```sh
   sops updatekeys deploy/dev/secrets.enc.env
   sops updatekeys deploy/dev/gnupg.secret.enc.asc
   ```
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
| `secrets.enc.env` (encrypted) | `secrets/` (decrypted plaintext, incl. `misp.gnupg.asc`) |
| `gnupg.secret.enc.asc` (encrypted GnuPG key) | `.env` (local compose config) |
| `secrets.example.env` (placeholders) | `~/.config/sops/age/keys.txt` (private key, outside repo) |
| `.sops.yaml` (recipient policy) | |

The `.gitignore` enforces this: `secrets/`, `*.secrets.env`, `.env`, and age
key files are excluded; `*.enc.*` (both `secrets.enc.env` and
`gnupg.secret.enc.asc`) is explicitly kept.
