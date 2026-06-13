# san-auth

SAN-allowlist authorization microservice for the MISP mTLS gateway.

fountel fronts an upstream (unmodifiable) MISP server with an nginx gateway.
The org mTLS policy trusts any certificate issued by the shared bootroot and
then has **each app authorize the peer by a SAN allowlist**. Because MISP is
upstream, that per-app authorization is externalized into this fountel-owned
service, which nginx calls via [`auth_request`](https://nginx.org/en/docs/http/ngx_http_auth_request_module.html).

This service has **no MISP dependency** and is developed and tested in
isolation. The nginx wiring lands separately (issue #4).

## Authorization contract

nginx terminates mTLS, validates the client certificate against the bootroot,
and on the `auth_request` subrequest forwards the certificate as:

```nginx
proxy_set_header X-Client-Cert $ssl_client_escaped_cert;
```

`$ssl_client_escaped_cert` is the **URL-encoded PEM**. This service:

1. Reads the `X-Client-Cert` request header (no other field is trusted for
   identity).
2. URL-decodes it to PEM and parses the certificate.
3. Extracts the **DNS** and **URI** Subject Alternative Names.
4. Returns **200** iff at least one SAN exactly matches an entry in the active
   allowlist; otherwise **403**.

Absent, undecodable, unparseable, SAN-less, or unlisted certificates — and any
request carrying a duplicate `X-Client-Cert` header (ambiguous identity) — all
deny with **403**.

Matching is on the **stable SAN value, never the certificate fingerprint**: the
bootroot rotates certificates frequently, so fingerprint matching would break on
every rotation.

### Endpoints

| Method | Path       | Purpose                                   |
| ------ | ---------- | ----------------------------------------- |
| `GET`  | `/authz`   | Authorization decision (200 / 403).       |
| `GET`  | `/healthz` | Liveness; returns 200 and allowlist size. |

The response body is JSON with a machine-readable `reason` for logging;
`auth_request` itself only consumes the status code.

## Allowlist (config-as-code)

The allowlist is a per-environment YAML file with a top-level `allowed_sans`
list of exact SAN strings:

```yaml
allowed_sans:
  - aimer-web-dev-1.fountel.internal        # aimer-web-dev-1
  - spiffe://fountel.dev/aimer/ingest       # aimer-ingest-dev (URI SAN)
```

The file is selected by environment variable:

| Variable         | Effect                                                                 |
| ---------------- | ---------------------------------------------------------------------- |
| `ALLOWLIST_PATH` | Explicit path. Takes precedence over `FOUNTEL_ENV`.                    |
| `FOUNTEL_ENV`    | `dev` or `prod` → `allowlist.<env>.yaml` at the package root (default `dev`). |

Changing who is authorized requires only editing the YAML — no code change.

## Configuration

| Variable | Default   | Purpose                          |
| -------- | --------- | -------------------------------- |
| `HOST`   | `0.0.0.0` | Bind address (see note below).   |
| `PORT`   | `8080`    | Listen port inside the container.|

## Binding / exposure

The service binds `0.0.0.0` **inside its container only**. It is **not**
published to the host or public interface — it is reachable only on the private
gateway Docker network, called by the nginx container. The provided Dockerfile
`EXPOSE`s the port for documentation but does not publish it; compose/run must
not map it to the host.

## Development

```sh
npm install
npm test         # unit tests (node:test + tsx), fixture certs, no network
npm run typecheck
npm run build    # emits dist/
npm run dev      # run from source with tsx
npm start        # run compiled dist/
```

Test fixture certificates live in `test/fixtures/` and are regenerated with
`test/fixtures/generate.sh` (self-signed throwaway certs; the service never
validates the chain — nginx does).

## Container

```sh
docker build -t fountel/san-auth .
# Reachable only on the private gateway network — do NOT publish the port.
docker run --rm --network gateway -e FOUNTEL_ENV=dev fountel/san-auth
```
