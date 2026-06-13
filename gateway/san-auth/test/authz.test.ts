import assert from "node:assert/strict";
import { test } from "node:test";
import { Allowlist } from "../src/allowlist.js";
import { decide } from "../src/authz.js";
import { readEncodedFixture } from "./helpers.js";

const allowlist = new Allowlist([
  "aimer-web-dev-1.fountel.internal",
  "spiffe://fountel.dev/aimer/ingest",
]);

test("allows a cert whose DNS SAN is allowlisted", () => {
  const decision = decide(readEncodedFixture("allowed-dns"), allowlist);
  assert.equal(decision.status, 200);
  assert.equal(decision.reason, "allowed");
  assert.equal(decision.matchedSan, "aimer-web-dev-1.fountel.internal");
});

test("allows a cert whose URI SAN is allowlisted", () => {
  const decision = decide(readEncodedFixture("allowed-uri"), allowlist);
  assert.equal(decision.status, 200);
  assert.equal(decision.matchedSan, "spiffe://fountel.dev/aimer/ingest");
});

test("allows when only one of several SANs is allowlisted", () => {
  const decision = decide(readEncodedFixture("allowed-multi"), allowlist);
  assert.equal(decision.status, 200);
  assert.equal(decision.matchedSan, "spiffe://fountel.dev/aimer/ingest");
});

test("denies a cert whose SAN is not allowlisted", () => {
  const decision = decide(readEncodedFixture("denied-dns"), allowlist);
  assert.equal(decision.status, 403);
  assert.equal(decision.reason, "san_not_allowlisted");
});

test("denies a cert whose only matchable SAN type is ignored", () => {
  // denied-ip has an IP Address SAN (ignored) and a non-allowlisted DNS SAN.
  const decision = decide(readEncodedFixture("denied-ip"), allowlist);
  assert.equal(decision.status, 403);
  assert.equal(decision.reason, "san_not_allowlisted");
});

test("denies a cert with no SAN", () => {
  const decision = decide(readEncodedFixture("no-san"), allowlist);
  assert.equal(decision.status, 403);
  assert.equal(decision.reason, "no_san");
});

test("denies when the header is absent", () => {
  const decision = decide(undefined, allowlist);
  assert.equal(decision.status, 403);
  assert.equal(decision.reason, "missing_cert_header");
});

test("denies when the header is empty or whitespace", () => {
  assert.equal(decide("", allowlist).reason, "missing_cert_header");
  assert.equal(decide("   ", allowlist).reason, "missing_cert_header");
});

test("denies when the header is undecodable", () => {
  const decision = decide("%", allowlist);
  assert.equal(decision.status, 403);
  assert.equal(decision.reason, "undecodable_cert");
});

test("denies when the decoded value is not a certificate", () => {
  const decision = decide(encodeURIComponent("garbage, not a PEM"), allowlist);
  assert.equal(decision.status, 403);
  assert.equal(decision.reason, "unparseable_cert");
});

test("denies a SAN-injection cert: comma payload does not forge a DNS match", () => {
  // The cert's single URI SAN embeds ",DNS:aimer-web-dev-1.fountel.internal".
  // That DNS name IS allowlisted, so a comma-splitting parser would wrongly
  // allow this peer. Quote-aware parsing keeps it one URI value -> denied.
  const decision = decide(readEncodedFixture("injection-uri"), allowlist);
  assert.equal(decision.status, 403);
  assert.equal(decision.reason, "san_not_allowlisted");
});

test("matching is exact: a superstring SAN is not allowlisted", () => {
  const narrow = new Allowlist(["aimer-web-dev-1.fountel.interna"]);
  const decision = decide(readEncodedFixture("allowed-dns"), narrow);
  assert.equal(decision.status, 403);
});
