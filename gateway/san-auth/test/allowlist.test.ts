import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import {
  Allowlist,
  loadAllowlist,
  resolveAllowlistPath,
} from "../src/allowlist.js";

function writeTemp(name: string, content: string): string {
  const dir = mkdtempSync(join(tmpdir(), "san-auth-"));
  const path = join(dir, name);
  writeFileSync(path, content, "utf8");
  return path;
}

test("Allowlist matches exactly and reports size", () => {
  const list = new Allowlist(["a.example", "b.example"]);
  assert.equal(list.size, 2);
  assert.ok(list.has("a.example"));
  assert.ok(!list.has("c.example"));
  assert.ok(list.allowsAny(["x", "b.example"]));
  assert.ok(!list.allowsAny(["x", "y"]));
});

test("loadAllowlist parses allowed_sans and ignores comments", () => {
  const path = writeTemp(
    "allowlist.yaml",
    [
      "# header comment",
      "allowed_sans:",
      "  - host-1.example   # annotation",
      "  - spiffe://example/svc",
    ].join("\n"),
  );
  const list = loadAllowlist(path);
  assert.equal(list.size, 2);
  assert.ok(list.has("host-1.example"));
  assert.ok(list.has("spiffe://example/svc"));
});

test("loadAllowlist treats an empty/SAN-less file as deny-everything", () => {
  assert.equal(loadAllowlist(writeTemp("empty.yaml", "")).size, 0);
  assert.equal(
    loadAllowlist(writeTemp("nokey.yaml", "other: 1\n")).size,
    0,
  );
});

test("loadAllowlist rejects a non-list allowed_sans", () => {
  const path = writeTemp("bad.yaml", "allowed_sans: nope\n");
  assert.throws(() => loadAllowlist(path), /must be a list/);
});

test("loadAllowlist rejects a non-string entry", () => {
  const path = writeTemp("bad.yaml", "allowed_sans:\n  - 42\n");
  assert.throws(() => loadAllowlist(path), /must be a string/);
});

test("loadAllowlist throws when the file is missing", () => {
  assert.throws(
    () => loadAllowlist("/no/such/allowlist.yaml"),
    /failed to read allowlist file/,
  );
});

test("resolveAllowlistPath honors ALLOWLIST_PATH first", () => {
  const path = resolveAllowlistPath({ ALLOWLIST_PATH: "/tmp/custom.yaml" });
  assert.equal(path, "/tmp/custom.yaml");
});

test("resolveAllowlistPath maps FOUNTEL_ENV to a per-env file", () => {
  assert.match(resolveAllowlistPath({ FOUNTEL_ENV: "prod" }), /allowlist\.prod\.yaml$/);
  assert.match(resolveAllowlistPath({ FOUNTEL_ENV: "dev" }), /allowlist\.dev\.yaml$/);
  // Defaults to dev when unset.
  assert.match(resolveAllowlistPath({}), /allowlist\.dev\.yaml$/);
});

test("resolveAllowlistPath rejects an unknown FOUNTEL_ENV", () => {
  assert.throws(
    () => resolveAllowlistPath({ FOUNTEL_ENV: "staging" }),
    /must be one of/,
  );
});

test("the committed dev allowlist loads and contains expected SANs", () => {
  const list = loadAllowlist(resolveAllowlistPath({ FOUNTEL_ENV: "dev" }));
  assert.ok(list.has("aimer-web-dev-1.fountel.internal"));
  assert.ok(list.has("spiffe://fountel.dev/aimer/ingest"));
});
