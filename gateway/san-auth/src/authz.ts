import type { Allowlist } from "./allowlist.js";
import { decodeClientCertHeader, extractSans, parseCertificate } from "./cert.js";

/** The outcome of an authorization decision. */
export interface AuthzDecision {
  /** HTTP status to return: 200 (allow) or 403 (deny). */
  status: 200 | 403;
  /** Machine-readable reason, useful for logging and debugging. */
  reason:
    | "allowed"
    | "missing_cert_header"
    | "undecodable_cert"
    | "unparseable_cert"
    | "no_san"
    | "san_not_allowlisted";
  /** The SAN value that matched, when the decision is `allowed`. */
  matchedSan?: string;
}

/**
 * Decide whether a client certificate is authorized by the allowlist.
 *
 * The certificate is taken solely from the `X-Client-Cert` header value
 * (URL-encoded PEM, as forwarded by nginx `auth_request`). No other
 * request field is trusted for identity. The decision is allow (200) iff
 * at least one DNS/URI SAN entry is present in the allowlist; every other
 * case — absent, undecodable, unparseable, SAN-less, or unlisted — denies
 * (403).
 */
export function decide(
  clientCertHeader: string | undefined,
  allowlist: Allowlist,
): AuthzDecision {
  if (clientCertHeader === undefined || clientCertHeader.trim() === "") {
    return { status: 403, reason: "missing_cert_header" };
  }

  const pem = decodeClientCertHeader(clientCertHeader);
  if (pem === null) {
    return { status: 403, reason: "undecodable_cert" };
  }

  const cert = parseCertificate(pem);
  if (cert === null) {
    return { status: 403, reason: "unparseable_cert" };
  }

  const sans = extractSans(cert);
  if (sans.length === 0) {
    return { status: 403, reason: "no_san" };
  }

  for (const san of sans) {
    if (allowlist.has(san.value)) {
      return { status: 200, reason: "allowed", matchedSan: san.value };
    }
  }

  return { status: 403, reason: "san_not_allowlisted" };
}
