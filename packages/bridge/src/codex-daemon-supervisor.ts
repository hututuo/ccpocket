import { spawnSync } from "node:child_process";
import {
  accessSync,
  constants,
  lstatSync,
  realpathSync,
  type Stats,
} from "node:fs";
import { dirname, isAbsolute, relative, resolve } from "node:path";
import type { CodexDaemonConfig } from "./codex-app-server-config.js";

interface CodexDaemonVersionResponse {
  status?: unknown;
  backend?: unknown;
  cliVersion?: unknown;
  appServerVersion?: unknown;
  managedCodexPath?: unknown;
  managedCodexVersion?: unknown;
  socketPath?: unknown;
}

// A freshly started daemon can still be finishing its control-plane startup
// when Bridge performs the first version probe. Keep the check bounded, but do
// not inherit Desktop's much shorter UI fallback window: Bridge must report a
// truthful daemon failure instead of racing startup and silently choosing a
// different authority.
const CODEX_DAEMON_VERSION_TIMEOUT_MS = 10_000;
const CODEX_DAEMON_VERIFICATION_CACHE_TTL_MS = 2_000;
const CODEX_DAEMON_VERIFICATION_CACHE_MAX_ENTRIES = 64;

export interface CodexDaemonSocketIdentity {
  device: number;
  inode: number;
}

export interface VerifiedCodexDaemon {
  config: CodexDaemonConfig;
  cliVersion: string;
  appServerVersion: string;
  socketPath: string;
  socketIdentity: CodexDaemonSocketIdentity;
}

export interface CodexDaemonSupervisorDependencies {
  getUid?: () => number;
  now?: () => number;
  runVersion?: (
    cliPath: string,
    codexHome: string,
  ) => CodexDaemonVersionResponse;
}

interface FileIdentity {
  device: number;
  inode: number;
  size: number;
  ctimeMs: number;
  mtimeMs: number;
}

interface CachedCodexDaemonVerification {
  verified: VerifiedCodexDaemon;
  verifiedAtMs: number;
  cliIdentity: FileIdentity;
  socketIdentity: FileIdentity;
}

const daemonVerificationCache = new Map<
  string,
  CachedCodexDaemonVerification
>();

function isWithin(parentPath: string, childPath: string): boolean {
  const childRelative = relative(parentPath, childPath);
  return (
    childRelative === "" ||
    (!childRelative.startsWith("..") && !isAbsolute(childRelative))
  );
}

function assertOwnedByCurrentUser(
  stats: Stats,
  uid: number,
  description: string,
): void {
  if (stats.uid !== uid) {
    throw new Error(`${description} must be owned by the current user`);
  }
}

function assertSafeDirectory(
  directoryPath: string,
  uid: number,
  description: string,
): void {
  const stats = lstatSync(directoryPath);
  if (!stats.isDirectory()) {
    throw new Error(`${description} is not a directory`);
  }
  assertOwnedByCurrentUser(stats, uid, description);
  if ((stats.mode & 0o022) !== 0) {
    throw new Error(`${description} must not be group- or world-writable`);
  }
}

function assertSafeParents(
  canonicalHome: string,
  canonicalTarget: string,
  uid: number,
  description: string,
): void {
  let current = dirname(canonicalTarget);
  if (!isWithin(canonicalHome, current)) {
    throw new Error(`${description} must be inside CODEX_HOME`);
  }

  while (true) {
    assertSafeDirectory(current, uid, `${description} parent directory`);
    if (current === canonicalHome) break;
    const parent = dirname(current);
    if (parent === current || !isWithin(canonicalHome, parent)) {
      throw new Error(`${description} parent escaped CODEX_HOME`);
    }
    current = parent;
  }
}

function fileIdentity(stats: Stats): FileIdentity {
  return {
    device: stats.dev,
    inode: stats.ino,
    size: stats.size,
    ctimeMs: stats.ctimeMs,
    mtimeMs: stats.mtimeMs,
  };
}

function matchesFileIdentity(stats: Stats, expected: FileIdentity): boolean {
  return (
    stats.dev === expected.device &&
    stats.ino === expected.inode &&
    stats.size === expected.size &&
    stats.ctimeMs === expected.ctimeMs &&
    stats.mtimeMs === expected.mtimeMs
  );
}

function cacheVerification(
  key: string,
  verification: CachedCodexDaemonVerification,
): void {
  daemonVerificationCache.delete(key);
  daemonVerificationCache.set(key, verification);
  while (
    daemonVerificationCache.size > CODEX_DAEMON_VERIFICATION_CACHE_MAX_ENTRIES
  ) {
    const oldestKey = daemonVerificationCache.keys().next().value;
    if (oldestKey === undefined) break;
    daemonVerificationCache.delete(oldestKey);
  }
}

function defaultRunVersion(
  cliPath: string,
  codexHome: string,
): CodexDaemonVersionResponse {
  const result = spawnSync(cliPath, ["app-server", "daemon", "version"], {
    encoding: "utf8",
    env: { ...process.env, CODEX_HOME: codexHome },
    maxBuffer: 64 * 1024,
    timeout: CODEX_DAEMON_VERSION_TIMEOUT_MS,
  });

  if (result.error) {
    throw new Error(
      `Codex daemon version check failed: ${result.error.message}`,
    );
  }
  if (result.status !== 0) {
    throw new Error(`Codex daemon version check exited ${result.status}`);
  }

  try {
    return JSON.parse(result.stdout.trim()) as CodexDaemonVersionResponse;
  } catch {
    throw new Error("Codex daemon version check returned invalid JSON");
  }
}

export function verifyCodexDaemon(
  config: CodexDaemonConfig,
  dependencies: CodexDaemonSupervisorDependencies = {},
): VerifiedCodexDaemon {
  const getUid = dependencies.getUid ?? process.getuid;
  if (!getUid) {
    throw new Error("Codex daemon mode requires Unix user ownership checks");
  }
  const uid = getUid();

  if (!isAbsolute(config.codexHome)) {
    throw new Error("CODEX_HOME must be an absolute path");
  }
  const configuredHomeStats = lstatSync(config.codexHome);
  if (
    configuredHomeStats.isSymbolicLink() ||
    !configuredHomeStats.isDirectory()
  ) {
    throw new Error("CODEX_HOME must identify a real directory");
  }
  const canonicalHome = realpathSync.native(config.codexHome);
  if (canonicalHome !== resolve(config.codexHome)) {
    throw new Error("CODEX_HOME must not rely on symbolic path components");
  }
  assertSafeDirectory(canonicalHome, uid, "CODEX_HOME");

  if (!isAbsolute(config.cliPath)) {
    throw new Error("BRIDGE_CODEX_DAEMON_CLI must be an absolute path");
  }
  const configuredCliStats = lstatSync(config.cliPath);
  if (configuredCliStats.isSymbolicLink() || !configuredCliStats.isFile()) {
    throw new Error("BRIDGE_CODEX_DAEMON_CLI must identify a regular file");
  }
  accessSync(config.cliPath, constants.X_OK);
  const canonicalCli = realpathSync.native(config.cliPath);
  if (canonicalCli !== resolve(config.cliPath)) {
    throw new Error(
      "BRIDGE_CODEX_DAEMON_CLI must not rely on symbolic path components",
    );
  }
  if (!isWithin(canonicalHome, canonicalCli)) {
    throw new Error("BRIDGE_CODEX_DAEMON_CLI must be inside CODEX_HOME");
  }
  const cliStats = lstatSync(canonicalCli);
  assertOwnedByCurrentUser(cliStats, uid, "BRIDGE_CODEX_DAEMON_CLI");
  if ((cliStats.mode & 0o022) !== 0) {
    throw new Error(
      "BRIDGE_CODEX_DAEMON_CLI must not be group- or world-writable",
    );
  }
  assertSafeParents(canonicalHome, canonicalCli, uid, "Codex daemon CLI");

  if (!isAbsolute(config.socketPath)) {
    throw new Error("BRIDGE_CODEX_DAEMON_SOCKET must be an absolute path");
  }

  const canonicalSocket = realpathSync.native(config.socketPath);
  if (!isWithin(canonicalHome, canonicalSocket)) {
    throw new Error("Codex daemon socket must be inside CODEX_HOME");
  }

  assertSafeParents(canonicalHome, canonicalSocket, uid, "Codex daemon socket");

  const socketStats = lstatSync(config.socketPath);
  if (socketStats.isSymbolicLink() || !socketStats.isSocket()) {
    throw new Error("BRIDGE_CODEX_DAEMON_SOCKET must identify a Unix socket");
  }
  assertOwnedByCurrentUser(socketStats, uid, "BRIDGE_CODEX_DAEMON_SOCKET");
  if ((socketStats.mode & 0o022) !== 0) {
    throw new Error(
      "BRIDGE_CODEX_DAEMON_SOCKET must not be group- or world-writable",
    );
  }

  const cacheKey = [
    canonicalHome,
    canonicalCli,
    canonicalSocket,
    config.expectedVersion,
    config.expectedAppServerVersion ?? config.expectedVersion,
    String(uid),
  ].join("\u0000");
  const now = dependencies.now ?? Date.now;
  const cacheLookupNowMs = now();
  const cached = daemonVerificationCache.get(cacheKey);
  const cacheAgeMs = cached ? cacheLookupNowMs - cached.verifiedAtMs : -1;
  if (
    cached &&
    cacheAgeMs >= 0 &&
    cacheAgeMs <= CODEX_DAEMON_VERIFICATION_CACHE_TTL_MS &&
    matchesFileIdentity(cliStats, cached.cliIdentity) &&
    matchesFileIdentity(socketStats, cached.socketIdentity)
  ) {
    daemonVerificationCache.delete(cacheKey);
    daemonVerificationCache.set(cacheKey, cached);
    return {
      ...cached.verified,
      config: { ...cached.verified.config },
      socketIdentity: { ...cached.verified.socketIdentity },
    };
  }
  if (cached) daemonVerificationCache.delete(cacheKey);

  const runVersion = dependencies.runVersion ?? defaultRunVersion;
  const version = runVersion(canonicalCli, canonicalHome);
  if (version.status !== "running") {
    throw new Error("Codex daemon is not running");
  }
  if (version.backend !== "pid") {
    throw new Error("Codex daemon must use the audited pid backend");
  }
  const expectedAppServerVersion =
    config.expectedAppServerVersion ?? config.expectedVersion;
  if (
    version.cliVersion !== config.expectedVersion ||
    version.appServerVersion !== expectedAppServerVersion ||
    version.managedCodexVersion !== expectedAppServerVersion
  ) {
    throw new Error(
      "Codex daemon version mismatch; expected " +
        `CLI ${config.expectedVersion} and app-server ${expectedAppServerVersion}`,
    );
  }
  if (typeof version.managedCodexPath !== "string") {
    throw new Error("Codex daemon version response omitted managedCodexPath");
  }
  if (!isAbsolute(version.managedCodexPath)) {
    throw new Error("Codex daemon reported a non-absolute managed Codex path");
  }
  const reportedManagedCli = realpathSync.native(version.managedCodexPath);
  if (reportedManagedCli !== canonicalCli) {
    throw new Error("Codex daemon reported a different managed Codex CLI");
  }
  if (typeof version.socketPath !== "string") {
    throw new Error("Codex daemon version response omitted socketPath");
  }
  if (!isAbsolute(version.socketPath)) {
    throw new Error("Codex daemon reported a non-absolute control socket");
  }
  const reportedSocket = realpathSync.native(version.socketPath);
  if (reportedSocket !== canonicalSocket) {
    throw new Error("Codex daemon reported a different control socket");
  }

  const verifiedCliStats = lstatSync(canonicalCli);
  if (!matchesFileIdentity(verifiedCliStats, fileIdentity(cliStats))) {
    throw new Error("Codex daemon CLI changed during exact verification");
  }
  const verifiedSocketStats = lstatSync(canonicalSocket);
  if (
    !verifiedSocketStats.isSocket() ||
    !matchesFileIdentity(verifiedSocketStats, fileIdentity(socketStats))
  ) {
    throw new Error("Codex daemon socket changed during exact verification");
  }

  const verified: VerifiedCodexDaemon = {
    config: {
      ...config,
      codexHome: canonicalHome,
      cliPath: canonicalCli,
      socketPath: canonicalSocket,
    },
    cliVersion: version.cliVersion,
    appServerVersion: version.appServerVersion,
    socketPath: canonicalSocket,
    socketIdentity: {
      device: verifiedSocketStats.dev,
      inode: verifiedSocketStats.ino,
    },
  };
  cacheVerification(cacheKey, {
    verified,
    verifiedAtMs: now(),
    cliIdentity: fileIdentity(verifiedCliStats),
    socketIdentity: fileIdentity(verifiedSocketStats),
  });
  return {
    ...verified,
    config: { ...verified.config },
    socketIdentity: { ...verified.socketIdentity },
  };
}

export function assertCodexDaemonSocketIdentity(
  socketPath: string,
  expected: CodexDaemonSocketIdentity,
): void {
  const stats = lstatSync(socketPath);
  if (
    !stats.isSocket() ||
    stats.dev !== expected.device ||
    stats.ino !== expected.inode
  ) {
    throw new Error("Codex daemon socket was replaced after verification");
  }
}
