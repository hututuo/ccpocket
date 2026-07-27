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
