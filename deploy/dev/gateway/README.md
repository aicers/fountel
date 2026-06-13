# dev gateway — nginx mTLS edge

The nginx edge gateway terminates mTLS in front of the published feed snapshot.
It is the **only externally-reachable service** in the dev stack and serves
**only** the feed path; MISP's UI/API are not reachable through it.

See [`../../../docs/gateway.md`](../../../docs/gateway.md) for the full design,
the authorization flow, and the verification procedure.

## Files

| Path | Committed? | Purpose |
| --- | --- | --- |
| `nginx.conf` | yes | mTLS termination, `auth_request` → san-auth, static feed serving. |
| `certs/` | **no** (git-ignored) | The bootroot PEMs the gateway consumes. |

## Cert provisioning is out of scope

Per #1, fountel builds **no** certificate issuance/rotation machinery — it only
**consumes** externally-provisioned bootroot PEMs, reusing the aimer/aimer-web
rotation flow. The gateway mounts these three files **read-only**:

| Container path | nginx directive | What it is |
| --- | --- | --- |
| `/etc/nginx/certs/server.crt` | `ssl_certificate` | Gateway's bootroot **server** cert. |
| `/etc/nginx/certs/server.key` | `ssl_certificate_key` | Server private key. |
| `/etc/nginx/certs/bootroot-ca.pem` | `ssl_client_certificate` | Bootroot CA bundle used to verify client certs. |

In **dev** these are throwaway certs minted locally by
[`../bin/gen-dev-certs.sh`](../bin/gen-dev-certs.sh) into `certs/` (git-ignored,
mirroring how `secrets-init.sh` generates dev secrets). Nothing under `certs/`
is ever committed. In **prod** the same paths are populated by the external
bootroot provisioning/rotation flow — this repo does not generate or rotate
prod certs.
