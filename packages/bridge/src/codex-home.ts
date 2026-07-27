import { createHash } from "node:crypto";
import { homedir } from "node:os";
import { isAbsolute, join, resolve } from "node:path";

export interface ResolveCodexHomeOptions {
  env?: NodeJS.ProcessEnv;
  homeDir?: string;
  cwd?: string;
}

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
