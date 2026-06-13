import assert from "node:assert/strict";
import { connect, type AddressInfo } from "node:net";
import { after, before, test } from "node:test";
import { Allowlist } from "../src/allowlist.js";
import { AUTHZ_PATH, CLIENT_CERT_HEADER, createAuthServer, HEALTHZ_PATH } from "../src/server.js";
import { readEncodedFixture } from "./helpers.js";

const allowlist = new Allowlist([
  "aimer-web-dev-1.fountel.internal",
  "spiffe://fountel.dev/aimer/ingest",
]);
const server = createAuthServer(allowlist);
let baseUrl = "";
let serverPort = 0;

before(async () => {
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  serverPort = (server.address() as AddressInfo).port;
  baseUrl = `http://127.0.0.1:${serverPort}`;
});

after(() => {
  server.close();
});

async function authz(headerValue?: string): Promise<Response> {
  const headers: Record<string, string> = {};
  if (headerValue !== undefined) {
    headers[CLIENT_CERT_HEADER] = headerValue;
  }
  return fetch(`${baseUrl}${AUTHZ_PATH}`, { headers });
}

/** Send a raw HTTP/1.1 GET with explicit header lines; resolve the status code. */
function rawAuthzStatus(headerLines: string[]): Promise<number> {
  const request = [
    `GET ${AUTHZ_PATH} HTTP/1.1`,
    "Host: 127.0.0.1",
    "Connection: close",
    ...headerLines,
    "",
    "",
  ].join("\r\n");

  return new Promise<number>((resolve, reject) => {
    const socket = connect(serverPort, "127.0.0.1", () => socket.write(request));
    let buf = "";
    socket.setEncoding("utf8");
    socket.on("data", (chunk) => {
      buf += chunk;
    });
    socket.on("end", () => {
      const match = buf.match(/^HTTP\/1\.1 (\d{3})/);
      if (match) {
        resolve(Number(match[1]));
      } else {
        reject(new Error(`no status line in response: ${buf.slice(0, 80)}`));
      }
    });
    socket.on("error", reject);
  });
}

test("GET /authz returns 200 for an allowlisted DNS SAN", async () => {
  const res = await authz(readEncodedFixture("allowed-dns"));
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.reason, "allowed");
  assert.equal(body.matchedSan, "aimer-web-dev-1.fountel.internal");
});

test("GET /authz returns 200 for an allowlisted URI SAN", async () => {
  const res = await authz(readEncodedFixture("allowed-uri"));
  assert.equal(res.status, 200);
});

test("GET /authz returns 403 for a non-allowlisted SAN", async () => {
  const res = await authz(readEncodedFixture("denied-dns"));
  assert.equal(res.status, 403);
  assert.equal((await res.json()).reason, "san_not_allowlisted");
});

test("GET /authz returns 403 when the header is absent", async () => {
  const res = await authz(undefined);
  assert.equal(res.status, 403);
  assert.equal((await res.json()).reason, "missing_cert_header");
});

test("GET /authz returns 403 for an undecodable header", async () => {
  const res = await authz("%");
  assert.equal(res.status, 403);
  assert.equal((await res.json()).reason, "undecodable_cert");
});

test("GET /authz returns 403 for a malformed certificate", async () => {
  const res = await authz(encodeURIComponent("-----BEGIN CERTIFICATE-----\nnope\n"));
  assert.equal(res.status, 403);
  assert.equal((await res.json()).reason, "unparseable_cert");
});

test("a repeated X-Client-Cert header is rejected as ambiguous", async () => {
  // fetch() merges array headers before sending, so send raw bytes with
  // two header lines. Even though the first value is allowlisted, an
  // ambiguous identity must deny (the handler reads `headersDistinct`).
  const status = await rawAuthzStatus([
    `${CLIENT_CERT_HEADER}: ${readEncodedFixture("allowed-dns")}`,
    `${CLIENT_CERT_HEADER}: ${readEncodedFixture("denied-dns")}`,
  ]);
  assert.equal(status, 403);
});

test("non-GET methods are rejected with 405", async () => {
  const res = await fetch(`${baseUrl}${AUTHZ_PATH}`, { method: "POST" });
  assert.equal(res.status, 405);
});

test("unknown paths return 404", async () => {
  const res = await fetch(`${baseUrl}/nope`);
  assert.equal(res.status, 404);
});

test("GET /healthz returns 200", async () => {
  const res = await fetch(`${baseUrl}${HEALTHZ_PATH}`);
  assert.equal(res.status, 200);
  assert.equal((await res.json()).status, "ok");
});
