import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const fixturesDir = join(dirname(fileURLToPath(import.meta.url)), "fixtures");

/** Read a fixture certificate as a PEM string. */
export function readFixturePem(name: string): string {
  return readFileSync(join(fixturesDir, `${name}.pem`), "utf8");
}

/**
 * Encode a PEM the way nginx `$ssl_client_escaped_cert` would: a
 * URL-encoded (percent-encoded) string. `decodeURIComponent` is the
 * exact inverse, so this faithfully simulates the wire contract.
 */
export function urlEncodePem(pem: string): string {
  return encodeURIComponent(pem);
}

/** Read a fixture certificate and return it URL-encoded, as nginx sends it. */
export function readEncodedFixture(name: string): string {
  return urlEncodePem(readFixturePem(name));
}
