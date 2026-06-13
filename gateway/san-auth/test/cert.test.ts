import assert from "node:assert/strict";
import { test } from "node:test";
import {
  decodeClientCertHeader,
  extractSans,
  parseCertificate,
} from "../src/cert.js";
import { readFixturePem, urlEncodePem } from "./helpers.js";

test("decodeClientCertHeader reverses URL-encoding into PEM", () => {
  const pem = readFixturePem("allowed-dns");
  const decoded = decodeClientCertHeader(urlEncodePem(pem));
  assert.equal(decoded, pem);
  assert.ok(decoded?.includes("-----BEGIN CERTIFICATE-----"));
});

test("decodeClientCertHeader returns null on malformed percent-encoding", () => {
  // A lone `%` is not a valid percent-escape.
  assert.equal(decodeClientCertHeader("%"), null);
  assert.equal(decodeClientCertHeader("%ZZ"), null);
});

test("parseCertificate returns null for non-certificate input", () => {
  assert.equal(parseCertificate("not a certificate"), null);
  assert.equal(parseCertificate(""), null);
  assert.equal(parseCertificate("   "), null);
});

test("parseCertificate parses a valid PEM", () => {
  const cert = parseCertificate(readFixturePem("allowed-dns"));
  assert.ok(cert);
});

test("extractSans extracts a DNS SAN", () => {
  const cert = parseCertificate(readFixturePem("allowed-dns"));
  assert.ok(cert);
  assert.deepEqual(extractSans(cert), [
    { type: "DNS", value: "aimer-web-dev-1.fountel.internal" },
  ]);
});

test("extractSans extracts a URI SAN", () => {
  const cert = parseCertificate(readFixturePem("allowed-uri"));
  assert.ok(cert);
  assert.deepEqual(extractSans(cert), [
    { type: "URI", value: "spiffe://fountel.dev/aimer/ingest" },
  ]);
});

test("extractSans extracts multiple SANs in order", () => {
  const cert = parseCertificate(readFixturePem("allowed-multi"));
  assert.ok(cert);
  assert.deepEqual(extractSans(cert), [
    { type: "DNS", value: "not-listed.fountel.internal" },
    { type: "URI", value: "spiffe://fountel.dev/aimer/ingest" },
  ]);
});

test("extractSans ignores non-DNS/URI SAN types (e.g. IP Address)", () => {
  const cert = parseCertificate(readFixturePem("denied-ip"));
  assert.ok(cert);
  assert.deepEqual(extractSans(cert), [
    { type: "DNS", value: "rogue-ip.example.com" },
  ]);
});

test("extractSans returns empty array when the cert has no SAN", () => {
  const cert = parseCertificate(readFixturePem("no-san"));
  assert.ok(cert);
  assert.deepEqual(extractSans(cert), []);
});

test("extractSans keeps a comma-bearing URI value as one entry (no injection)", () => {
  // The URI value embeds a `,DNS:<allowlisted>` payload. Node emits such a
  // value double-quoted and JSON-escaped; a naive comma split would forge a
  // second `DNS:` entry. Correct quote-aware parsing yields exactly one URI.
  const cert = parseCertificate(readFixturePem("injection-uri"));
  assert.ok(cert);
  assert.deepEqual(extractSans(cert), [
    {
      type: "URI",
      value: "spiffe://fountel.dev/x,DNS:aimer-web-dev-1.fountel.internal",
    },
  ]);
});
