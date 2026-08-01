import { isAbsolute, join, resolve } from "node:path";

const DEFAULT_CODEX_APP_SERVER_PORT = "8767";
const FALLBACK_CODEX_APP_SERVER_PORT = "8768";

export type CodexAppServerMode = "private" | "managed" | "external" | "daemon";

export interface CodexDaemonConfig {
  codexHome: string;
  cliPath: string;
  socketPath: string;
  expectedVersion: string;
  expectedAppServerVersion?: string;
}

export function defaultCodexAppServerPort(bridgePort?: string): string {
  return bridgePort?.trim() === DEFAULT_CODEX_APP_SERVER_PORT
    ? FALLBACK_CODEX_APP_SERVER_PORT
    : DEFAULT_CODEX_APP_SERVER_PORT;
}

export function defaultCodexSharedAppServerUrl(bridgePort?: string): string {
  return `ws://127.0.0.1:${defaultCodexAppServerPort(bridgePort)}`;
}

export function readCodexSharedAppServerUrl(
  env: NodeJS.ProcessEnv = process.env,
): string | undefined {
  return (
    env.BRIDGE_CODEX_SHARED_APP_SERVER_URL?.trim() ||
    env.BRIDGE_CODEX_APP_SERVER_URL?.trim() ||
    undefined
  );
}

export function readCodexAppServerMode(
  env: NodeJS.ProcessEnv = process.env,
): CodexAppServerMode {
  const raw = env.BRIDGE_CODEX_APP_SERVER_MODE?.trim();
  if (!raw) return "private";
  if (
    raw === "private" ||
    raw === "managed" ||
    raw === "external" ||
    raw === "daemon"
  ) {
    return raw;
  }
  throw new Error(
    `Invalid BRIDGE_CODEX_APP_SERVER_MODE "${raw}"; expected private, managed, external, or daemon`,
  );
}

function requiredDaemonValue(
  env: NodeJS.ProcessEnv,
  name: keyof NodeJS.ProcessEnv,
): string {
  const raw = env[name];
  const value = raw?.trim();
  if (!value) {
    throw new Error(`${String(name)} is required in daemon mode`);
  }
  return value;
}

function requireAbsolutePath(value: string, name: string): string {
  if (!isAbsolute(value)) {
    throw new Error(`${name} must be an absolute path`);
  }
  return resolve(value);
}

export function readCodexDaemonConfig(
  env: NodeJS.ProcessEnv = process.env,
  platform: NodeJS.Platform = process.platform,
): CodexDaemonConfig {
  if (platform === "win32") {
    throw new Error("Codex daemon mode requires a Unix domain socket");
  }

  const codexHome = requireAbsolutePath(
    requiredDaemonValue(env, "CODEX_HOME"),
    "CODEX_HOME",
  );
  const cliPath = requireAbsolutePath(
    requiredDaemonValue(env, "BRIDGE_CODEX_DAEMON_CLI"),
    "BRIDGE_CODEX_DAEMON_CLI",
  );
  const expectedVersion = requiredDaemonValue(
    env,
    "BRIDGE_CODEX_DAEMON_EXPECTED_VERSION",
  );
  const expectedAppServerVersion =
    env.BRIDGE_CODEX_DAEMON_EXPECTED_APP_SERVER_VERSION?.trim();
  const configuredSocket = env.BRIDGE_CODEX_DAEMON_SOCKET;
  if (configuredSocket !== undefined && configuredSocket.trim().length === 0) {
    throw new Error(
      "BRIDGE_CODEX_DAEMON_SOCKET must not be empty when configured",
    );
  }
  const socketPath = requireAbsolutePath(
    configuredSocket?.trim() ||
      join(codexHome, "app-server-control", "app-server-control.sock"),
    "BRIDGE_CODEX_DAEMON_SOCKET",
  );

  return {
    codexHome,
    cliPath,
    socketPath,
    expectedVersion,
    ...(expectedAppServerVersion ? { expectedAppServerVersion } : {}),
  };
}

export function resolveCodexSharedAppServerUrl(
  mode: CodexAppServerMode,
  env: NodeJS.ProcessEnv = process.env,
): string | undefined {
  const explicit = readCodexSharedAppServerUrl(env);
  if (explicit) return explicit;
  if (mode !== "managed") return undefined;

  const legacyPort = env.BRIDGE_CODEX_APP_SERVER_PORT?.trim();
  if (legacyPort) return `ws://127.0.0.1:${legacyPort}`;

  return defaultCodexSharedAppServerUrl(env.BRIDGE_PORT);
}

export function codexCliJoinTarget(
  threadId: string,
  env: NodeJS.ProcessEnv = process.env,
): { url: string; command: string } | undefined {
  const mode = readCodexAppServerMode(env);
  if (mode === "private" || mode === "daemon") return undefined;

  const url = resolveCodexSharedAppServerUrl(mode, env);
  if (!url) return undefined;

  return {
    url,
    command: `codex resume ${threadId} --remote ${url}`,
  };
}
