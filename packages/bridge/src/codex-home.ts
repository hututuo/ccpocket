import { createHash } from "node:crypto";
import { homedir } from "node:os";
import { isAbsolute, join, resolve } from "node:path";

export interface ResolveCodexHomeOptions {
  env?: NodeJS.ProcessEnv;
  homeDir?: string;
  cwd?: string;
}

export interface ResolveCodexSourceIdentityOptions
  extends ResolveCodexHomeOptions {
  sourceId?: string;
}

const SHARED_CODEX_SOURCE_ID_PATTERN = /^codex-source-[0-9a-f]{32}$/;
const LEGACY_CODEX_HOME_ID_PATTERN = /^codex-home-[0-9a-f]{24}$/;

/**
 * Resolve the Codex state root used by both app-server and Bridge-owned
 * compatibility readers.
 *
 * Codex itself honors CODEX_HOME. Keeping every filesystem fallback on this
 * same path prevents a Bridge from listing the default ~/.codex catalog while
 * its app-server reads and writes an isolated Cockpit/SDK home.
 */
export function resolveCodexHome(
  options: ResolveCodexHomeOptions = {},
): string {
  const env = options.env ?? process.env;
  const configured = env.CODEX_HOME?.trim();
  if (configured) {
    return isAbsolute(configured)
      ? resolve(configured)
      : resolve(options.cwd ?? process.cwd(), configured);
  }
  return join(options.homeDir ?? homedir(), ".codex");
}

export function resolveCodexSessionsDir(
  options: ResolveCodexHomeOptions = {},
): string {
  return join(resolveCodexHome(options), "sessions");
}

/**
 * Opaque cache/source partition for the selected Codex Home. The path itself
 * stays local to the Bridge, while a Home switch on the same Bridge identity
 * still invalidates Mobile catalog caches.
 */
export function codexHomeIdentity(
  options: ResolveCodexHomeOptions = {},
): string {
  return `codex-home-${createHash("sha256")
    .update(resolveCodexHome(options))
    .digest("hex")
    .slice(0, 24)}`;
}

/**
 * Validate an explicit durable Codex source identity.
 *
 * The value is an opaque public identifier, not a credential. Cockpit should
 * generate and persist a random 128-bit `codex-source-*` value for one
 * canonical session authority. An existing `codex-home-*` identity may be
 * supplied explicitly when adopting shared storage without orphaning Mobile
 * caches, archives, or downloaded mirrors keyed by that identity.
 */
export function normalizeCodexSourceId(
  value: string | undefined,
): string | undefined {
  if (value === undefined) return undefined;
  if (
    SHARED_CODEX_SOURCE_ID_PATTERN.test(value) ||
    LEGACY_CODEX_HOME_ID_PATTERN.test(value)
  ) {
    return value;
  }
  throw new Error(
    "BRIDGE_CODEX_SOURCE_ID must be codex-source- followed by 32 lowercase hex characters, or an existing codex-home- identity",
  );
}

/**
 * Durable source identity sent to Mobile.
 *
 * By default this remains the exact historical CODEX_HOME-derived identity.
 * A shared identity is only used when the operator explicitly declares that
 * multiple sequential runtimes have one canonical session/lifecycle
 * authority. Runtime connection generations remain independent.
 */
export function codexSourceIdentity(
  options: ResolveCodexSourceIdentityOptions = {},
): string {
  const configured = normalizeCodexSourceId(
    options.sourceId ??
      (options.env ?? process.env).BRIDGE_CODEX_SOURCE_ID,
  );
  return configured ?? codexHomeIdentity(options);
}

export function environmentForCodexHome(
  codexHome: string,
  baseEnv: NodeJS.ProcessEnv = process.env,
): NodeJS.ProcessEnv {
  return {
    ...baseEnv,
    CODEX_HOME: resolveCodexHome({
      env: { CODEX_HOME: codexHome },
      cwd: process.cwd(),
    }),
  };
}
