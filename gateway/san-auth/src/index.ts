import { loadAllowlist, resolveAllowlistPath } from "./allowlist.js";
import { createAuthServer } from "./server.js";

/** TCP port the service listens on inside its container. */
const PORT = Number(process.env.PORT ?? "8080");

/**
 * Bind address. Defaults to `0.0.0.0` because the service runs inside a
 * container that is *not* published on the host/public interface — it is
 * reachable only on the private gateway Docker network, called by the
 * nginx container.
 */
const HOST = process.env.HOST ?? "0.0.0.0";

function main(): void {
  const allowlistPath = resolveAllowlistPath();
  const allowlist = loadAllowlist(allowlistPath);
  // eslint-disable-next-line no-console
  console.log(
    `[san-auth] loaded ${allowlist.size} allowlisted SAN(s) from ${allowlistPath}`,
  );

  const server = createAuthServer(allowlist);
  server.listen(PORT, HOST, () => {
    // eslint-disable-next-line no-console
    console.log(`[san-auth] listening on http://${HOST}:${PORT}`);
  });

  const shutdown = (signal: string) => {
    // eslint-disable-next-line no-console
    console.log(`[san-auth] received ${signal}, shutting down`);
    server.close(() => process.exit(0));
  };
  process.on("SIGTERM", () => shutdown("SIGTERM"));
  process.on("SIGINT", () => shutdown("SIGINT"));
}

main();
