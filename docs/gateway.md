# mTLS gateway & feed publishing

This is the **additive-sync exposure** layer (issue #4): how fountel exposes its
curated, additive feed to aimer-web over an authenticated, authorized channel,
and how it publishes the feed-format snapshot MISP generates.

fountel's responsibility ends at **correctly serving a fetchable, structurally
valid feed**. The periodic-pull / diff / expire behavior is aimer-web's job and
lives in the `aimer-web` repo.

## Shape

```
                          mTLS (bootroot)
  aimer-web client  ───────────────────────►  gateway (nginx)         only
  (bootroot cert,                              :8443 in container       non-loopback
   allowlisted SAN)                            host :FEED_HTTPS_PORT     port
                                                 │      │
                          auth_request           │      │ static serve (ro)
                  ┌────────────────────────◄─────┘      ▼
                  ▼                              feed_data volume  ◄── feed-exporter
            san-auth (#2)                        (snapshots/ + `public`     (PyMISP,
            :8080, private                        symlink, atomic swap)      scheduled)
            gateway network                                                    │
                                                                       REST API │
                                              misp-core ◄──────────────────────┘
                                              (loopback host publish, admin-only)
```

Three services are added to the dev stack and wired together:

1. **`gateway`** — nginx terminating mTLS. The **only externally-reachable
   service**, and only for the feed path.
2. **`san-auth`** — the #2 SAN-allowlist service, on the private gateway
   network, called by nginx `auth_request`.
3. **`feed-exporter`** — a scheduled PyMISP job that writes the feed-format
   snapshot to a shared volume the gateway serves.

## mTLS + authorization flow

1. nginx terminates TLS and **verifies the client cert chains to the bootroot**
   (`ssl_verify_client on`, `ssl_client_certificate` = the bootroot CA bundle).
   A cert that does not chain to the bootroot is rejected — as a TLS handshake
   alert (TLS 1.2) or, because TLS 1.3 verifies the client cert post-handshake,
   as `400 The SSL certificate error`. Either way no feed bytes are served.
2. For a verified client, nginx issues an `auth_request` subrequest to
   `http://san-auth:8080/authz`, forwarding the cert **only** as
   `X-Client-Cert: $ssl_client_escaped_cert` (the URL-encoded PEM) — exactly
   per #2's fixed contract. No other field carries identity.
3. san-auth extracts the DNS/URI SANs and returns **200** iff one matches its
   allowlist (`gateway/san-auth/allowlist.dev.yaml`), else **403**. nginx
   serves the feed on 200 and denies on 403.

Authorization is by **stable SAN**, never cert fingerprint — the bootroot
rotates certs frequently.

### Certs are externally provisioned

fountel builds **no** issuance/rotation machinery; it only **consumes**
externally-provisioned bootroot PEMs mounted read-only (see
[`../deploy/dev/gateway/README.md`](../deploy/dev/gateway/README.md) for the
mount paths). In **dev**, [`bin/gen-dev-certs.sh`](../deploy/dev/bin/gen-dev-certs.sh)
mints throwaway certs into the git-ignored `gateway/certs/` — the same
local-generation posture as `secrets-init.sh`. Nothing under `certs/` is
committed. In **prod** the same paths are populated by the external bootroot
flow (aimer/aimer-web rotation), which this repo does not touch.

## Route boundary

The gateway serves **only** `/feed/` (the published snapshot). Every other path
returns 404 — MISP's web UI/API are **not** reachable through the external mTLS
route. They stay on misp-core's host publish, which is **bound to loopback**
(`127.0.0.1:8080` / `127.0.0.1:8443`, admin-only) or reachable over the internal
compose network. The gateway's mTLS feed port is the **only** address bound to a
non-loopback interface.

## Feed publishing

The `feed-exporter` runs **MISP-native feed generation** via PyMISP — the same
path as the upstream
[`examples/feed-generator/generate.py`](https://github.com/MISP/PyMISP/blob/main/examples/feed-generator/generate.py):
it queries the MISP REST API under the pinned filter, then `MISPEvent.to_feed()`
per event. Upstream MISP is never forked and nothing reaches into the DB.

It emits the standard MISP feed format to the shared volume:

- `manifest.json` — a **UUID-keyed** object (one entry per event).
- `<uuid>.json` — one file per event.
- `hashes.csv` — `value,uuid` quick-lookup rows.

Plus fountel additions required by #4:

- **`fountel-feed-meta.json`** — a freshness **sidecar** carrying `generated_at`
  (and `event_count`, the active `filter`, `signed: false`). Freshness is
  exposed here and via nginx's native `Last-Modified` / `ETag` — **never** as a
  top-level key inside `manifest.json` (which would break strict feed-format
  consumers that iterate every key as an event). The aimer-web adapter reads
  freshness from the sidecar/header, never from the manifest.

### Pinned additive filter

The export scope is committed in
[`feed-exporter/export-filter.yaml`](../deploy/dev/feed-exporter/export-filter.yaml):

| Field | Value | Why |
| --- | --- | --- |
| `tags` | `fountel:floor-eligible` | The committed curation tag (docs/curation.md). |
| `org` | `fountel` | The vendor-central publishing org. |

So abuse.ch / Spamhaus are excluded **by construction** — they are never tagged
into this scope. Before each atomic swap the exporter **re-checks every exported
event** carries the tag and org; a snapshot containing any out-of-scope event is
rejected and **not** published.

### Atomic publish

Each run writes a fresh `snapshots/<timestamp>/` directory, then atomically
repoints the `public` symlink (relative target, `os.replace`) the gateway
serves. nginx therefore never sees a half-written snapshot (a partial
`manifest.json`, or a manifest referencing event files not yet present). Old
snapshots are pruned to `FEED_SNAPSHOT_RETENTION`.

### No signed-manifest pinning

GPG feed signing is **disabled** (`with_signatures: false`): misp-core
autogenerates a disposable instance key on first boot (#10), so there is no
stable feed signing key for a consumer to pin. Feed authenticity rides on the
**mTLS channel + `hashes.csv`**, not a signed manifest. No `.asc` detached
signature is part of the served feed or the consumer contract.

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `FEED_HTTPS_PORT` | `18443` | Host port for the gateway mTLS feed listener (the only external port). |
| `FEED_EXPORT_INTERVAL` | `300` | Seconds between scheduled exports. |
| `EXPORT_MISP_URL` | `https://misp-core` | MISP REST endpoint the exporter queries. |
| `EXPORT_MISP_VERIFY_SSL` | `false` | Verify misp-core's (self-signed dev) TLS cert. |
| `FEED_SNAPSHOT_RETENTION` | `5` | Snapshots kept on the volume. |

The exporter authenticates with `ADMIN_KEY` from `secrets/misp.secrets.env`.

## Verify

```sh
cd deploy/dev
./bin/seed-additive-event.sh    # demo: one in-scope + one out-of-scope event
./bin/verify-gateway.sh         # forces an export, then runs all the checks
```

`verify-gateway.sh` proves the acceptance criteria with `curl`:

- allowlisted bootroot client → **200**, fetches manifest + events + hashes;
- non-allowlisted bootroot client → **403** (san-auth deny);
- non-bootroot self-signed client → rejected (handshake / `400` SSL cert error);
- manifest is pure UUID-keyed, every event fetchable, `hashes.csv` consistent,
  sidecar + `Last-Modified` present, and **only** additive-scoped events present
  (the out-of-scope demo event is excluded);
- MISP UI/API are not reachable through the gateway, misp-core is loopback-only,
  and the gateway feed port is the only non-loopback bound service.
