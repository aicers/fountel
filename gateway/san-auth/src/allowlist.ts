import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import yaml from "js-yaml";

/**
 * The set of SAN strings authorized for the active environment.
 *
 * Matching is exact on the stable SAN value, never on a certificate
 * fingerprint: the bootroot rotates certificates frequently, so a
 * fingerprint match would break on every rotation.
 */
export class Allowlist {
  private readonly entries: ReadonlySet<string>;

  constructor(sans: Iterable<string>) {
    this.entries = new Set(sans);
  }

  /** Whether the given SAN value is authorized. */
  has(san: string): boolean {
    return this.entries.has(san);
  }

  /** Whether any of the given SAN values is authorized. */
  allowsAny(sans: Iterable<string>): boolean {
    for (const san of sans) {
      if (this.entries.has(san)) {
        return true;
      }
    }
    return false;
  }

  /** Number of entries in the allowlist. */
  get size(): number {
    return this.entries.size;
  }
}

interface AllowlistDocument {
  allowed_sans?: unknown;
}

/**
 * Resolve the allowlist file path from the environment.
 *
 * Precedence:
 *   1. `ALLOWLIST_PATH` — an explicit path (absolute, or relative to cwd).
 *   2. `FOUNTEL_ENV` ∈ {dev, prod} → `allowlist.<env>.yaml` next to the
 *      service's package root. Defaults to `dev` when unset.
 */
export function resolveAllowlistPath(
  env: NodeJS.ProcessEnv = process.env,
): string {
  const explicit = env.ALLOWLIST_PATH?.trim();
  if (explicit) {
    return resolve(explicit);
  }

  const fountelEnv = (env.FOUNTEL_ENV?.trim() || "dev").toLowerCase();
  if (fountelEnv !== "dev" && fountelEnv !== "prod") {
    throw new Error(
      `FOUNTEL_ENV must be one of {dev, prod}, got "${fountelEnv}"`,
    );
  }
  return join(packageRoot(), `allowlist.${fountelEnv}.yaml`);
}

/** Load and parse an allowlist YAML file from disk. */
export function loadAllowlist(path: string): Allowlist {
  let text: string;
  try {
    text = readFileSync(path, "utf8");
  } catch (cause) {
    throw new Error(`failed to read allowlist file at ${path}`, { cause });
  }

  let doc: unknown;
  try {
    doc = yaml.load(text);
  } catch (cause) {
    throw new Error(`failed to parse allowlist YAML at ${path}`, { cause });
  }

  return new Allowlist(parseAllowedSans(doc, path));
}

function parseAllowedSans(doc: unknown, path: string): string[] {
  if (doc === null || doc === undefined) {
    // An empty file is a valid (deny-everything) allowlist.
    return [];
  }
  if (typeof doc !== "object") {
    throw new Error(`allowlist at ${path} must be a YAML mapping`);
  }

  const { allowed_sans: allowedSans } = doc as AllowlistDocument;
  if (allowedSans === undefined || allowedSans === null) {
    return [];
  }
  if (!Array.isArray(allowedSans)) {
    throw new Error(`"allowed_sans" in ${path} must be a list`);
  }

  return allowedSans.map((entry, index) => {
    if (typeof entry !== "string") {
      throw new Error(
        `"allowed_sans[${index}]" in ${path} must be a string`,
      );
    }
    return entry.trim();
  });
}

/** Absolute path to the service's package root (one level above src/). */
function packageRoot(): string {
  return resolve(dirname(fileURLToPath(import.meta.url)), "..");
}
