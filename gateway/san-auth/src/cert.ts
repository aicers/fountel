import { X509Certificate } from "node:crypto";

/**
 * A Subject Alternative Name entry extracted from a client certificate.
 *
 * Only the SAN types relevant to peer identity in our mTLS policy are
 * surfaced here. The `value` is the stable identity string used for
 * allowlist matching — never a certificate fingerprint, which rotates.
 */
export interface SanEntry {
  type: "DNS" | "URI";
  value: string;
}

/**
 * URL-decode the `X-Client-Cert` header value into a PEM string.
 *
 * nginx forwards the client certificate as `$ssl_client_escaped_cert`,
 * which is the URL-encoded PEM. We reverse that encoding here.
 *
 * @returns the decoded PEM, or `null` if the value cannot be decoded.
 */
export function decodeClientCertHeader(headerValue: string): string | null {
  try {
    return decodeURIComponent(headerValue);
  } catch {
    // Malformed percent-encoding (e.g. a stray `%`) throws URIError.
    return null;
  }
}

/**
 * Parse a PEM-encoded certificate.
 *
 * @returns the parsed certificate, or `null` if the input is not a
 *   valid certificate.
 */
export function parseCertificate(pem: string): X509Certificate | null {
  const trimmed = pem.trim();
  if (trimmed.length === 0) {
    return null;
  }
  try {
    return new X509Certificate(trimmed);
  } catch {
    return null;
  }
}

/**
 * Extract the DNS and URI SAN entries from a parsed certificate.
 *
 * Node's `subjectAltName` exposes the SAN extension as a single string
 * of comma-separated `TYPE:value` pairs (e.g.
 * `DNS:host.example, URI:spiffe://example/foo`). Values that contain
 * characters needing escaping are emitted as double-quoted, JSON-style
 * escaped strings. This parser respects that quoting so a value
 * containing a comma is not split.
 *
 * SAN types other than DNS and URI (IP Address, email, etc.) are ignored.
 */
export function extractSans(cert: X509Certificate): SanEntry[] {
  const raw = cert.subjectAltName;
  if (!raw) {
    return [];
  }

  const entries: SanEntry[] = [];
  for (const segment of splitSanSegments(raw)) {
    const sep = segment.indexOf(":");
    if (sep === -1) {
      continue;
    }
    const label = segment.slice(0, sep).trim();
    if (label !== "DNS" && label !== "URI") {
      continue;
    }
    const value = unquote(segment.slice(sep + 1).trim());
    if (value.length > 0) {
      entries.push({ type: label, value });
    }
  }
  return entries;
}

/**
 * Split a `subjectAltName` string into its top-level `TYPE:value`
 * segments, treating commas inside double-quoted values as literal.
 */
function splitSanSegments(raw: string): string[] {
  const segments: string[] = [];
  let current = "";
  let inQuotes = false;

  for (let i = 0; i < raw.length; i++) {
    const ch = raw[i];
    if (inQuotes) {
      current += ch;
      if (ch === "\\" && i + 1 < raw.length) {
        // Preserve the escaped character verbatim; it is unescaped later.
        current += raw[++i];
      } else if (ch === '"') {
        inQuotes = false;
      }
      continue;
    }
    if (ch === '"') {
      inQuotes = true;
      current += ch;
    } else if (ch === ",") {
      segments.push(current.trim());
      current = "";
    } else {
      current += ch;
    }
  }
  if (current.trim().length > 0) {
    segments.push(current.trim());
  }
  return segments;
}

/**
 * Remove surrounding double quotes and undo JSON-style escaping that
 * Node applies to SAN values containing special characters.
 */
function unquote(value: string): string {
  if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
    try {
      return JSON.parse(value) as string;
    } catch {
      // Fall through to the raw value if it is not valid JSON.
    }
  }
  return value;
}
