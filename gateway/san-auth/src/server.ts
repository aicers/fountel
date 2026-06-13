import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { Allowlist } from "./allowlist.js";
import { decide } from "./authz.js";

/** Header carrying the URL-encoded client-certificate PEM from nginx. */
export const CLIENT_CERT_HEADER = "x-client-cert";

/** Path of the authorization endpoint called by nginx `auth_request`. */
export const AUTHZ_PATH = "/authz";

/** Path of the liveness endpoint (handy for container healthchecks). */
export const HEALTHZ_PATH = "/healthz";

/**
 * Build the HTTP request handler for the authorization service.
 *
 * Kept separate from {@link createAuthServer} so tests can exercise it
 * without binding a socket.
 */
export function createRequestHandler(allowlist: Allowlist) {
  return function handle(req: IncomingMessage, res: ServerResponse): void {
    const url = req.url ?? "";
    const path = url.split("?", 1)[0];

    if (path === HEALTHZ_PATH) {
      sendJson(res, 200, { status: "ok", allowlistSize: allowlist.size });
      return;
    }

    if (path !== AUTHZ_PATH) {
      sendJson(res, 404, { error: "not_found" });
      return;
    }

    if (req.method !== "GET" && req.method !== "HEAD") {
      res.setHeader("Allow", "GET, HEAD");
      sendJson(res, 405, { error: "method_not_allowed" });
      return;
    }

    // `headersDistinct` always yields an array, so a repeated header is
    // visible (plain `req.headers` would join duplicates with ", ").
    // Identity must be unambiguous: anything but exactly one value denies.
    const values = req.headersDistinct[CLIENT_CERT_HEADER];
    const headerValue = values?.length === 1 ? values[0] : undefined;

    const decision = decide(headerValue, allowlist);
    sendJson(res, decision.status, {
      reason: decision.reason,
      ...(decision.matchedSan ? { matchedSan: decision.matchedSan } : {}),
    });
  };
}

/** Create (but do not start) the authorization HTTP server. */
export function createAuthServer(allowlist: Allowlist): Server {
  return createServer(createRequestHandler(allowlist));
}

function sendJson(
  res: ServerResponse,
  status: number,
  body: Record<string, unknown>,
): void {
  const payload = JSON.stringify(body);
  res.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(payload),
  });
  // auth_request ignores the body, but it aids manual debugging and logs.
  res.end(res.req.method === "HEAD" ? undefined : payload);
}
