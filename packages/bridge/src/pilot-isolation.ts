#!/usr/bin/env node

import { createHash, randomBytes } from "node:crypto";
import { spawn } from "node:child_process";
import {
  access,
  chmod,
  copyFile,
  lstat,
  mkdir,
  open,
  readFile,
  realpath,
  rename,
  rm,
} from "node:fs/promises";
import { constants as fsConstants, createReadStream } from "node:fs";
import { createServer } from "node:net";
import { homedir } from "node:os";
import {
  basename,
  dirname,
  isAbsolute,
  join,
  relative,
  resolve,
} from "node:path";
import { fileURLToPath } from "node:url";

export const PILOT_HOST = "127.0.0.1";
export const PILOT_PORT = 18_765;
export const PRODUCTION_BRIDGE_PORT = 8_765;
const PILOT_ROOT_PREFIX = "ccp-sr-";
const MAX_UNIX_SOCKET_PATH_BYTES = 100;
const API_KEY_PATTERN = /^[A-Za-z0-9_-]{43}$/;

export interface PilotIsolationPaths {
  root: string;
  home: string;
  codexHome: string;
  canaryProject: string;
  temporaryDirectory: string;
  bridgeStateDirectory: string;
  apiKeyFile: string;
  daemonSocket: string;
  managedCodexDirectory: string;
  managedCodexCli: string;
  daemonManifest: string;
  identityFile: string;
  identityManifest: string;
}

export interface PilotPreflightReport {
  paths: PilotIsolationPaths;
  host: typeof PILOT_HOST;
  port: typeof PILOT_PORT;
  apiKeyFileMode: "0600";
  rootMode: "0700";
  isolation: {
    independentHome: true;
    independentCodexHome: true;
    pushDisabled: true;
    mdnsDisabled: true;
    autoArtifactsDisabled: true;
  };
}

export interface PilotDaemonLaunchOptions {
  cliPath: string;
  expectedVersion: string;
  allowThreadStart?: boolean;
  allowTurnStart?: boolean;
  phoneLink?: boolean;
}

export interface PilotLaunchOptions extends PilotDaemonLaunchOptions {
  root: string;
  bridgeEntry: string;
  baseEnv?: NodeJS.ProcessEnv;
  spawnImpl?: typeof spawn;
}

export interface PilotDaemonManifest {
  schemaVersion: 1;
  sourceCliPath: string;
  sourceSha256: string;
  managedCliPath: string;
  managedSha256: string;
  expectedVersion: string;
}

export interface PilotDaemonVerification {
  root: string;
  sourceCliPath: string;
  managedCliPath: string;
  sha256: string;
  expectedVersion: string;
  socketPath: string;
  socketDevice: number;
  socketInode: number;
}

export interface PilotIdentityManifest {
  schemaVersion: 1;
  sourceCodexHome: string;
  authSha256: string;
}

interface PilotCommandResult {
  exitCode: number;
  stdout: string;
  stderr: string;
}

export interface PilotDaemonDependencies {
  runCommand?: (
    cliPath: string,
    args: string[],
    env: NodeJS.ProcessEnv,
  ) => Promise<PilotCommandResult>;
  wait?: (milliseconds: number) => Promise<void>;
}

const DAEMON_MANIFEST_SCHEMA_VERSION = 1;
const IDENTITY_MANIFEST_SCHEMA_VERSION = 1;
const DAEMON_COMMAND_TIMEOUT_MS = 15_000;
const DAEMON_VERIFY_RETRY_MS = 100;
const DAEMON_VERIFY_TIMEOUT_MS = 10_000;
const SHA256_PATTERN = /^[a-f0-9]{64}$/;
const EXPECTED_VERSION_PATTERN = /^[0-9A-Za-z.+_-]{1,96}$/;

function currentUid(): number {
  const getuid = process.getuid;
  if (!getuid) {
    throw new Error("The shared-runtime pilot requires Unix ownership checks");
  }
  return getuid();
}

function pilotTemporaryRoot(
  platform: NodeJS.Platform = process.platform,
): string {
  return platform === "darwin" ? "/private/tmp" : "/tmp";
}

export function defaultPilotRoot(
  uid: number = currentUid(),
  platform: NodeJS.Platform = process.platform,
): string {
  return join(pilotTemporaryRoot(platform), `${PILOT_ROOT_PREFIX}${uid}`);
}

function isWithin(parent: string, child: string): boolean {
  const rel = relative(parent, child);
  return rel === "" || (!rel.startsWith("..") && !isAbsolute(rel));
}

export function resolvePilotPaths(
  rootInput: string,
  platform: NodeJS.Platform = process.platform,
): PilotIsolationPaths {
  if (!isAbsolute(rootInput)) {
    throw new Error("Pilot root must be an absolute path");
  }
  const root = resolve(rootInput);
  const allowedParent = resolve(pilotTemporaryRoot(platform));
  if (dirname(root) !== allowedParent) {
    throw new Error(`Pilot root must be a direct child of ${allowedParent}`);
  }
  if (!basename(root).startsWith(PILOT_ROOT_PREFIX)) {
    throw new Error(`Pilot root name must start with ${PILOT_ROOT_PREFIX}`);
  }

  const home = join(root, "home");
  const codexHome = join(root, "codex");
  const daemonSocket = join(
    codexHome,
    "app-server-control",
    "app-server-control.sock",
  );
  const managedCodexDirectory = join(
    codexHome,
    "packages",
    "standalone",
    "current",
  );
  if (Buffer.byteLength(daemonSocket) > MAX_UNIX_SOCKET_PATH_BYTES) {
    throw new Error(
      `Pilot root is too long for a safe Unix socket path (${Buffer.byteLength(daemonSocket)} bytes)`,
    );
  }

  return {
    root,
    home,
    codexHome,
    canaryProject: join(root, "canary"),
    temporaryDirectory: join(root, "tmp"),
    bridgeStateDirectory: join(home, ".ccpocket"),
    apiKeyFile: join(root, "bridge-api-key"),
    daemonSocket,
    managedCodexDirectory,
    managedCodexCli: join(managedCodexDirectory, "codex"),
    daemonManifest: join(root, "codex-daemon-manifest.json"),
    identityFile: join(codexHome, "auth.json"),
    identityManifest: join(root, "codex-identity-manifest.json"),
  };
}

async function assertPrivateDirectory(
  path: string,
  uid: number,
): Promise<void> {
  const stats = await lstat(path);
  if (stats.isSymbolicLink() || !stats.isDirectory()) {
    throw new Error(`${path} must be a real directory`);
  }
  if (stats.uid !== uid) {
    throw new Error(`${path} must be owned by the current user`);
  }
  if ((stats.mode & 0o777) !== 0o700) {
    throw new Error(`${path} must have mode 0700`);
  }
}

async function ensurePrivateDirectory(
  path: string,
  uid: number,
): Promise<void> {
  try {
    await mkdir(path, { mode: 0o700 });
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
  }
  await assertPrivateDirectory(path, uid);
}

async function readApiKey(path: string, uid: number): Promise<string> {
  const stats = await lstat(path);
  if (stats.isSymbolicLink() || !stats.isFile()) {
    throw new Error("Pilot API key must be a real regular file");
  }
  if (stats.uid !== uid) {
    throw new Error("Pilot API key file must be owned by the current user");
  }
  if ((stats.mode & 0o777) !== 0o600) {
    throw new Error("Pilot API key file must have mode 0600");
  }
  if (stats.size > 256) {
    throw new Error("Pilot API key file is unexpectedly large");
  }
  const value = (await readFile(path, "utf8")).trim();
  if (!API_KEY_PATTERN.test(value)) {
    throw new Error("Pilot API key must be a 32-byte base64url secret");
  }
  return value;
}

async function ensureApiKey(path: string, uid: number): Promise<void> {
  let handle;
  try {
    handle = await open(path, "wx", 0o600);
    await handle.writeFile(randomBytes(32).toString("base64url"), "utf8");
    await handle.sync();
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
  } finally {
    await handle?.close();
  }
  await readApiKey(path, uid);
}

export async function preparePilotIsolation(
  rootInput = defaultPilotRoot(),
): Promise<PilotPreflightReport> {
  const paths = resolvePilotPaths(rootInput);
  const uid = currentUid();
  const realParent = await realpath(dirname(paths.root));
  if (realParent !== dirname(paths.root)) {
    throw new Error("Pilot root parent must not rely on a symbolic link");
  }

  await ensurePrivateDirectory(paths.root, uid);
  for (const directory of [
    paths.home,
    paths.codexHome,
    paths.canaryProject,
    paths.temporaryDirectory,
    paths.bridgeStateDirectory,
    join(paths.home, "downloads"),
    join(paths.home, "partials"),
  ]) {
    await ensurePrivateDirectory(directory, uid);
  }
  await ensureApiKey(paths.apiKeyFile, uid);
  return preflightPilotIsolation(paths.root, { checkPort: false });
}

async function assertPortAvailable(): Promise<void> {
  await new Promise<void>((resolvePromise, reject) => {
    const server = createServer();
    server.once("error", reject);
    server.listen(
      { host: PILOT_HOST, port: PILOT_PORT, exclusive: true },
      () => {
        server.close((error) => (error ? reject(error) : resolvePromise()));
      },
    );
  }).catch((error) => {
    throw new Error(
      `Pilot endpoint ${PILOT_HOST}:${PILOT_PORT} is unavailable: ${error instanceof Error ? error.message : String(error)}`,
    );
  });
}

export function assertPilotPort(port: number): void {
  if (port === PRODUCTION_BRIDGE_PORT) {
    throw new Error("The pilot must never use production Bridge port 8765");
  }
  if (port !== PILOT_PORT) {
    throw new Error(`The pilot is restricted to port ${PILOT_PORT}`);
  }
}

export async function preflightPilotIsolation(
  rootInput = defaultPilotRoot(),
  options: { checkPort?: boolean } = {},
): Promise<PilotPreflightReport> {
  assertPilotPort(PILOT_PORT);
  const paths = resolvePilotPaths(rootInput);
  const uid = currentUid();
  const canonicalRoot = await realpath(paths.root);
  if (canonicalRoot !== paths.root) {
    throw new Error("Pilot root must not be a symbolic link");
  }
  await assertPrivateDirectory(paths.root, uid);
  for (const directory of [
    paths.home,
    paths.codexHome,
    paths.canaryProject,
    paths.temporaryDirectory,
    paths.bridgeStateDirectory,
    join(paths.home, "downloads"),
    join(paths.home, "partials"),
  ]) {
    const canonical = await realpath(directory);
    if (canonical !== directory || !isWithin(paths.root, canonical)) {
      throw new Error(`${directory} escaped the pilot root`);
    }
    await assertPrivateDirectory(directory, uid);
  }
  await readApiKey(paths.apiKeyFile, uid);
  if (options.checkPort !== false) await assertPortAvailable();

  return {
    paths,
    host: PILOT_HOST,
    port: PILOT_PORT,
    apiKeyFileMode: "0600",
    rootMode: "0700",
    isolation: {
      independentHome: true,
      independentCodexHome: true,
      pushDisabled: true,
      mdnsDisabled: true,
      autoArtifactsDisabled: true,
    },
  };
}

const SAFE_INHERITED_ENV = [
  "LANG",
  "LC_ALL",
  "LC_CTYPE",
  "LOGNAME",
  "PATH",
  "SHELL",
  "USER",
] as const;

export async function buildPilotEnvironment(
  report: PilotPreflightReport,
  daemon: PilotDaemonLaunchOptions,
  baseEnv: NodeJS.ProcessEnv = process.env,
): Promise<NodeJS.ProcessEnv> {
  assertExpectedVersion(daemon.expectedVersion);
  const preparedDaemon = await validatePreparedPilotDaemonFiles(
    report,
    daemon.cliPath,
    daemon.expectedVersion,
  );

  const env: NodeJS.ProcessEnv = {};
  for (const name of SAFE_INHERITED_ENV) {
    if (baseEnv[name] !== undefined) env[name] = baseEnv[name];
  }

  const { paths } = report;
  const apiKey = await readApiKey(paths.apiKeyFile, currentUid());
  env.HOME = paths.home;
  env.CODEX_HOME = paths.codexHome;
  env.CODEX_SQLITE_HOME = paths.codexHome;
  env.TMPDIR = paths.temporaryDirectory;
  env.PWD = paths.canaryProject;
  env.XDG_CACHE_HOME = join(paths.home, ".cache");
  env.XDG_CONFIG_HOME = join(paths.home, ".config");
  env.XDG_DATA_HOME = join(paths.home, ".local", "share");
  env.BRIDGE_HOST = PILOT_HOST;
  env.BRIDGE_PORT = String(PILOT_PORT);
  env.BRIDGE_API_KEY = apiKey;
  env.BRIDGE_ALLOWED_DIRS = paths.canaryProject;
  env.BRIDGE_DISABLE_PUSH = "1";
  env.BRIDGE_DISABLE_MDNS = "1";
  env.BRIDGE_AUTO_ARTIFACTS = "0";
  if (!daemon.phoneLink) env.BRIDGE_DEMO_MODE = "1";
  env.BRIDGE_PROMPT_HISTORY_FILE = join(
    paths.bridgeStateDirectory,
    "prompt-history-pilot.json",
  );
  env.BRIDGE_ARTIFACT_REGISTRY_FILE = join(
    paths.bridgeStateDirectory,
    "artifact-registry-pilot.json",
  );
  env.BRIDGE_FILE_TRANSFER_STATE_FILE = join(
    paths.bridgeStateDirectory,
    "file-transfer-pilot.json",
  );
  env.BRIDGE_FILE_TRANSFER_DOWNLOAD_DIR = join(paths.home, "downloads");
  env.BRIDGE_FILE_TRANSFER_PARTIAL_DIR = join(paths.home, "partials");
  env.BRIDGE_CODEX_APP_SERVER_MODE = "daemon";
  env.BRIDGE_CODEX_SHARED_PILOT = "1";
  env.BRIDGE_CODEX_SHARED_PILOT_ALLOW_THREAD_START = daemon.allowThreadStart
    ? "1"
    : "0";
  env.BRIDGE_CODEX_SHARED_PILOT_ALLOW_TURN_START = daemon.allowTurnStart
    ? "1"
    : "0";
  // Bridge must execute the exact private copy whose hash is pinned by the
  // pilot manifest. The Desktop/source CLI is used only to prepare and verify
  // that copy; it is never the daemon authority exposed to Bridge.
  env.BRIDGE_CODEX_DAEMON_CLI = preparedDaemon.manifest.managedCliPath;
  env.BRIDGE_CODEX_DAEMON_SOCKET = paths.daemonSocket;
  env.BRIDGE_CODEX_DAEMON_EXPECTED_VERSION = daemon.expectedVersion;
  env.BRIDGE_CODEX_SOURCE_ID = `codex-source-${createHash("sha256")
    .update(paths.root)
    .digest("hex")
    .slice(0, 32)}`;
  return env;
}

function buildPilotDaemonEnvironment(
  paths: PilotIsolationPaths,
  baseEnv: NodeJS.ProcessEnv = process.env,
): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = {};
  for (const name of SAFE_INHERITED_ENV) {
    if (baseEnv[name] !== undefined) env[name] = baseEnv[name];
  }
  env.HOME = paths.home;
  env.CODEX_HOME = paths.codexHome;
  env.CODEX_SQLITE_HOME = paths.codexHome;
  env.TMPDIR = paths.temporaryDirectory;
  env.PWD = paths.canaryProject;
  env.XDG_CACHE_HOME = join(paths.home, ".cache");
  env.XDG_CONFIG_HOME = join(paths.home, ".config");
  env.XDG_DATA_HOME = join(paths.home, ".local", "share");
  return env;
}

async function defaultRunPilotCommand(
  cliPath: string,
  args: string[],
  env: NodeJS.ProcessEnv,
): Promise<PilotCommandResult> {
  return new Promise<PilotCommandResult>((resolvePromise, reject) => {
    const child = spawn(cliPath, args, {
      cwd: env.PWD,
      env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    let settled = false;
    const finish = (callback: () => void): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      callback();
    };
    const appendBounded = (current: string, chunk: Buffer): string => {
      const next = current + chunk.toString("utf8");
      if (Buffer.byteLength(next) > 64 * 1024) {
        child.kill("SIGKILL");
        finish(() =>
          reject(new Error("Pilot Codex command output exceeded 64 KiB")),
        );
      }
      return next;
    };
    child.stdout?.on("data", (chunk: Buffer) => {
      stdout = appendBounded(stdout, chunk);
    });
    child.stderr?.on("data", (chunk: Buffer) => {
      stderr = appendBounded(stderr, chunk);
    });
    child.once("error", (error) => finish(() => reject(error)));
    child.once("exit", (code, signal) => {
      finish(() => {
        if (signal) {
          reject(new Error(`Pilot Codex command exited from signal ${signal}`));
          return;
        }
        resolvePromise({ exitCode: code ?? 1, stdout, stderr });
      });
    });
    const timeout = setTimeout(() => {
      child.kill("SIGKILL");
      finish(() => reject(new Error("Pilot Codex command timed out")));
    }, DAEMON_COMMAND_TIMEOUT_MS);
    timeout.unref();
  });
}

async function hashFile(path: string): Promise<string> {
  const hash = createHash("sha256");
  await new Promise<void>((resolvePromise, reject) => {
    const stream = createReadStream(path);
    stream.on("data", (chunk) => hash.update(chunk));
    stream.once("error", reject);
    stream.once("end", resolvePromise);
  });
  return hash.digest("hex");
}

async function fsyncFile(path: string): Promise<void> {
  const handle = await open(path, "r");
  try {
    await handle.sync();
  } finally {
    await handle.close();
  }
}

async function assertMissingOrPrivateRegularFile(
  path: string,
  uid: number,
  description: string,
): Promise<void> {
  try {
    const stats = await lstat(path);
    if (stats.isSymbolicLink() || !stats.isFile() || stats.uid !== uid) {
      throw new Error(`${description} must be a current-user regular file`);
    }
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
  }
}

async function atomicCopyPrivateFile(
  source: string,
  destination: string,
  uid: number,
  mode: 0o600 | 0o700,
  description: string,
): Promise<void> {
  await assertMissingOrPrivateRegularFile(destination, uid, description);
  const temporary = `${destination}.tmp-${randomBytes(8).toString("hex")}`;
  try {
    await copyFile(source, temporary, fsConstants.COPYFILE_EXCL);
    await chmod(temporary, mode);
    await fsyncFile(temporary);
    await rename(temporary, destination);
  } finally {
    await rm(temporary, { force: true });
  }
}

async function atomicWritePrivateJson(
  destination: string,
  value: unknown,
  uid: number,
): Promise<void> {
  await assertMissingOrPrivateRegularFile(destination, uid, "Daemon manifest");
  const temporary = `${destination}.tmp-${randomBytes(8).toString("hex")}`;
  let handle;
  try {
    handle = await open(temporary, "wx", 0o600);
    await handle.writeFile(`${JSON.stringify(value, null, 2)}\n`, "utf8");
    await handle.sync();
    await handle.close();
    handle = undefined;
    await rename(temporary, destination);
  } finally {
    await handle?.close();
    await rm(temporary, { force: true });
  }
}

async function validateSourceCli(pathInput: string): Promise<string> {
  if (!isAbsolute(pathInput)) {
    throw new Error("Pilot Codex source CLI path must be absolute");
  }
  const configuredStats = await lstat(pathInput);
  if (configuredStats.isSymbolicLink() || !configuredStats.isFile()) {
    throw new Error("Pilot Codex source CLI must be a real regular file");
  }
  await access(pathInput, fsConstants.X_OK);
  return realpath(pathInput);
}

function assertExpectedVersion(expectedVersion: string): void {
  if (!EXPECTED_VERSION_PATTERN.test(expectedVersion)) {
    throw new Error("Pilot Codex daemon expected version is invalid");
  }
}

function assertSuccessfulCommand(
  result: PilotCommandResult,
  description: string,
): void {
  if (result.exitCode !== 0) {
    const suffix = result.stderr.trim();
    throw new Error(
      `${description} exited ${result.exitCode}${suffix ? `: ${suffix}` : ""}`,
    );
  }
}

async function assertSourceCliVersion(
  sourceCli: string,
  expectedVersion: string,
  env: NodeJS.ProcessEnv,
  runCommand: NonNullable<PilotDaemonDependencies["runCommand"]>,
): Promise<void> {
  const result = await runCommand(sourceCli, ["--version"], env);
  assertSuccessfulCommand(result, "Pilot Codex source version check");
  const versionOutput = result.stdout.trim();
  if (
    versionOutput !== expectedVersion &&
    versionOutput !== `codex-cli ${expectedVersion}`
  ) {
    throw new Error(
      `Pilot Codex source version mismatch; expected ${expectedVersion}`,
    );
  }
}

async function readDaemonManifest(
  paths: PilotIsolationPaths,
  uid: number,
): Promise<PilotDaemonManifest> {
  const stats = await lstat(paths.daemonManifest);
  if (stats.isSymbolicLink() || !stats.isFile() || stats.uid !== uid) {
    throw new Error(
      "Pilot daemon manifest must be a current-user regular file",
    );
  }
  if ((stats.mode & 0o777) !== 0o600) {
    throw new Error("Pilot daemon manifest must have mode 0600");
  }
  if (stats.size > 16 * 1024) {
    throw new Error("Pilot daemon manifest is unexpectedly large");
  }

  let candidate: Partial<PilotDaemonManifest>;
  try {
    candidate = JSON.parse(
      await readFile(paths.daemonManifest, "utf8"),
    ) as Partial<PilotDaemonManifest>;
  } catch {
    throw new Error("Pilot daemon manifest is invalid JSON");
  }
  if (
    candidate.schemaVersion !== DAEMON_MANIFEST_SCHEMA_VERSION ||
    typeof candidate.sourceCliPath !== "string" ||
    typeof candidate.managedCliPath !== "string" ||
    typeof candidate.sourceSha256 !== "string" ||
    !SHA256_PATTERN.test(candidate.sourceSha256) ||
    typeof candidate.managedSha256 !== "string" ||
    !SHA256_PATTERN.test(candidate.managedSha256) ||
    typeof candidate.expectedVersion !== "string" ||
    !EXPECTED_VERSION_PATTERN.test(candidate.expectedVersion)
  ) {
    throw new Error("Pilot daemon manifest has an invalid schema");
  }
  return candidate as PilotDaemonManifest;
}

async function assertDaemonSocketAbsent(
  paths: PilotIsolationPaths,
): Promise<void> {
  try {
    await lstat(paths.daemonSocket);
    throw new Error(
      "Pilot identity must be prepared before the isolated daemon is running",
    );
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
  }
}

export async function preparePilotIdentity(
  rootInput: string,
  sourceCodexHomeInput: string,
): Promise<PilotIdentityManifest> {
  if (!isAbsolute(sourceCodexHomeInput)) {
    throw new Error("Source CODEX_HOME must be an absolute path");
  }
  const report = await preparePilotIsolation(rootInput);
  const { paths } = report;
  await assertDaemonSocketAbsent(paths);

  const sourceCodexHome = await realpath(sourceCodexHomeInput);
  const sourceHomeStats = await lstat(sourceCodexHome);
  if (!sourceHomeStats.isDirectory()) {
    throw new Error("Source CODEX_HOME must be a directory");
  }
  if (isWithin(paths.root, sourceCodexHome)) {
    throw new Error("Source CODEX_HOME must be outside the pilot root");
  }
  const sourceAuth = join(sourceCodexHome, "auth.json");
  const authStats = await lstat(sourceAuth);
  if (authStats.isSymbolicLink() || !authStats.isFile()) {
    throw new Error("Source CODEX_HOME auth.json must be a real regular file");
  }
  if (authStats.size > 4 * 1024 * 1024) {
    throw new Error("Source CODEX_HOME auth.json is unexpectedly large");
  }
  const uid = currentUid();
  await atomicCopyPrivateFile(
    sourceAuth,
    paths.identityFile,
    uid,
    0o600,
    "Pilot auth.json",
  );
  const sourceSha256 = await hashFile(sourceAuth);
  const targetSha256 = await hashFile(paths.identityFile);
  if (sourceSha256 !== targetSha256) {
    throw new Error("Pilot auth.json copy does not match its source");
  }
  const manifest: PilotIdentityManifest = {
    schemaVersion: IDENTITY_MANIFEST_SCHEMA_VERSION,
    sourceCodexHome,
    authSha256: targetSha256,
  };
  await atomicWritePrivateJson(paths.identityManifest, manifest, uid);
  return manifest;
}

export async function verifyPilotIdentity(
  rootInput: string,
): Promise<PilotIdentityManifest> {
  const report = await preflightPilotIsolation(rootInput, { checkPort: false });
  const { paths } = report;
  const uid = currentUid();
  let manifestStats;
  try {
    manifestStats = await lstat(paths.identityManifest);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") {
      throw new Error(
        "Pilot identity is not prepared; run prepare-identity first",
      );
    }
    throw error;
  }
  if (
    manifestStats.isSymbolicLink() ||
    !manifestStats.isFile() ||
    manifestStats.uid !== uid ||
    (manifestStats.mode & 0o777) !== 0o600 ||
    manifestStats.size > 16 * 1024
  ) {
    throw new Error("Pilot identity manifest failed ownership or mode checks");
  }
  const authStats = await lstat(paths.identityFile);
  if (
    authStats.isSymbolicLink() ||
    !authStats.isFile() ||
    authStats.uid !== uid ||
    (authStats.mode & 0o777) !== 0o600
  ) {
    throw new Error("Pilot auth.json must be a 0600 current-user regular file");
  }

  let candidate: Partial<PilotIdentityManifest>;
  try {
    candidate = JSON.parse(
      await readFile(paths.identityManifest, "utf8"),
    ) as Partial<PilotIdentityManifest>;
  } catch {
    throw new Error("Pilot identity manifest is invalid JSON");
  }
  if (
    candidate.schemaVersion !== IDENTITY_MANIFEST_SCHEMA_VERSION ||
    typeof candidate.sourceCodexHome !== "string" ||
    !isAbsolute(candidate.sourceCodexHome) ||
    typeof candidate.authSha256 !== "string" ||
    !SHA256_PATTERN.test(candidate.authSha256)
  ) {
    throw new Error("Pilot identity manifest has an invalid schema");
  }
  const actualSha256 = await hashFile(paths.identityFile);
  if (actualSha256 !== candidate.authSha256) {
    throw new Error("Pilot auth.json hash no longer matches its manifest");
  }
  return candidate as PilotIdentityManifest;
}

interface ValidatedPilotDaemonAssets {
  report: PilotPreflightReport;
  manifest: PilotDaemonManifest;
  sourceCli: string;
  env: NodeJS.ProcessEnv;
}

interface ValidatedPreparedPilotDaemonFiles {
  manifest: PilotDaemonManifest;
  sourceCli: string;
}

async function validatePreparedPilotDaemonFiles(
  report: PilotPreflightReport,
  sourceCliInput: string,
  expectedVersion: string,
): Promise<ValidatedPreparedPilotDaemonFiles> {
  assertExpectedVersion(expectedVersion);
  const { paths } = report;
  const uid = currentUid();
  for (const directory of [
    join(paths.codexHome, "packages"),
    join(paths.codexHome, "packages", "standalone"),
    paths.managedCodexDirectory,
  ]) {
    const canonical = await realpath(directory);
    if (canonical !== directory || !isWithin(paths.codexHome, canonical)) {
      throw new Error("Managed Codex directory escaped the pilot CODEX_HOME");
    }
    await assertPrivateDirectory(directory, uid);
  }

  const sourceCli = await validateSourceCli(sourceCliInput);
  const manifest = await readDaemonManifest(paths, uid);
  if (
    manifest.sourceCliPath !== sourceCli ||
    manifest.managedCliPath !== paths.managedCodexCli ||
    manifest.expectedVersion !== expectedVersion
  ) {
    throw new Error(
      "Pilot daemon manifest does not match the requested assets",
    );
  }

  const managedStats = await lstat(paths.managedCodexCli);
  if (
    managedStats.isSymbolicLink() ||
    !managedStats.isFile() ||
    managedStats.uid !== uid ||
    (managedStats.mode & 0o777) !== 0o700
  ) {
    throw new Error(
      "Managed Codex CLI must be a 0700 current-user regular file",
    );
  }
  const sourceSha256 = await hashFile(sourceCli);
  const managedSha256 = await hashFile(paths.managedCodexCli);
  if (
    sourceSha256 !== manifest.sourceSha256 ||
    managedSha256 !== manifest.managedSha256 ||
    sourceSha256 !== managedSha256
  ) {
    throw new Error("Pilot Codex CLI hash no longer matches its manifest");
  }

  return { manifest, sourceCli };
}

async function validatePilotDaemonAssets(
  rootInput: string,
  sourceCliInput: string,
  expectedVersion: string,
  dependencies: PilotDaemonDependencies,
): Promise<ValidatedPilotDaemonAssets> {
  assertExpectedVersion(expectedVersion);
  const report = await preflightPilotIsolation(rootInput, { checkPort: false });
  const { manifest, sourceCli } = await validatePreparedPilotDaemonFiles(
    report,
    sourceCliInput,
    expectedVersion,
  );

  const env = buildPilotDaemonEnvironment(report.paths);
  const runCommand = dependencies.runCommand ?? defaultRunPilotCommand;
  await assertSourceCliVersion(sourceCli, expectedVersion, env, runCommand);
  return { report, manifest, sourceCli, env };
}

export async function preparePilotDaemon(
  rootInput: string,
  sourceCliInput: string,
  expectedVersion: string,
  dependencies: PilotDaemonDependencies = {},
): Promise<PilotDaemonManifest> {
  assertExpectedVersion(expectedVersion);
  const report = await preparePilotIsolation(rootInput);
  const { paths } = report;
  await assertDaemonSocketAbsent(paths);
  const uid = currentUid();
  const sourceCli = await validateSourceCli(sourceCliInput);
  const env = buildPilotDaemonEnvironment(paths);
  const runCommand = dependencies.runCommand ?? defaultRunPilotCommand;
  await assertSourceCliVersion(sourceCli, expectedVersion, env, runCommand);

  for (const directory of [
    join(paths.codexHome, "packages"),
    join(paths.codexHome, "packages", "standalone"),
    paths.managedCodexDirectory,
  ]) {
    await ensurePrivateDirectory(directory, uid);
  }
  await atomicCopyPrivateFile(
    sourceCli,
    paths.managedCodexCli,
    uid,
    0o700,
    "Managed Codex CLI",
  );
  const sourceSha256 = await hashFile(sourceCli);
  const managedSha256 = await hashFile(paths.managedCodexCli);
  if (sourceSha256 !== managedSha256) {
    throw new Error("Managed Codex CLI copy does not match its source");
  }

  const manifest: PilotDaemonManifest = {
    schemaVersion: DAEMON_MANIFEST_SCHEMA_VERSION,
    sourceCliPath: sourceCli,
    sourceSha256,
    managedCliPath: paths.managedCodexCli,
    managedSha256,
    expectedVersion,
  };
  await atomicWritePrivateJson(paths.daemonManifest, manifest, uid);
  return manifest;
}

interface DaemonVersionResponse {
  status?: unknown;
  backend?: unknown;
  cliVersion?: unknown;
  appServerVersion?: unknown;
  managedCodexPath?: unknown;
  managedCodexVersion?: unknown;
  socketPath?: unknown;
}

async function verifyRunningPilotDaemon(
  assets: ValidatedPilotDaemonAssets,
  dependencies: PilotDaemonDependencies,
): Promise<PilotDaemonVerification> {
  const runCommand = dependencies.runCommand ?? defaultRunPilotCommand;
  const result = await runCommand(
    assets.sourceCli,
    ["app-server", "daemon", "version"],
    assets.env,
  );
  assertSuccessfulCommand(result, "Pilot Codex daemon version check");

  let version: DaemonVersionResponse;
  try {
    version = JSON.parse(result.stdout.trim()) as DaemonVersionResponse;
  } catch {
    throw new Error("Pilot Codex daemon version check returned invalid JSON");
  }
  const { paths } = assets.report;
  const expectedVersion = assets.manifest.expectedVersion;
  if (version.status !== "running") {
    throw new Error("Pilot Codex daemon is not running");
  }
  if (version.backend !== "pid") {
    throw new Error("Pilot Codex daemon must use the audited pid backend");
  }
  if (
    version.cliVersion !== expectedVersion ||
    version.appServerVersion !== expectedVersion ||
    version.managedCodexVersion !== expectedVersion
  ) {
    throw new Error(
      `Pilot Codex daemon version mismatch; expected ${expectedVersion}`,
    );
  }
  if (
    version.managedCodexPath !== paths.managedCodexCli ||
    version.socketPath !== paths.daemonSocket
  ) {
    throw new Error("Pilot Codex daemon reported different managed paths");
  }

  const socketStats = await lstat(paths.daemonSocket);
  if (
    socketStats.isSymbolicLink() ||
    !socketStats.isSocket() ||
    socketStats.uid !== currentUid() ||
    (socketStats.mode & 0o022) !== 0
  ) {
    throw new Error(
      "Pilot Codex daemon socket failed ownership or mode checks",
    );
  }
  const canonicalSocket = await realpath(paths.daemonSocket);
  if (canonicalSocket !== paths.daemonSocket) {
    throw new Error("Pilot Codex daemon socket must not use symbolic paths");
  }

  return {
    root: paths.root,
    sourceCliPath: assets.sourceCli,
    managedCliPath: paths.managedCodexCli,
    sha256: assets.manifest.managedSha256,
    expectedVersion,
    socketPath: paths.daemonSocket,
    socketDevice: socketStats.dev,
    socketInode: socketStats.ino,
  };
}

export async function verifyPilotDaemon(
  rootInput: string,
  sourceCliInput: string,
  expectedVersion: string,
  dependencies: PilotDaemonDependencies = {},
): Promise<PilotDaemonVerification> {
  const assets = await validatePilotDaemonAssets(
    rootInput,
    sourceCliInput,
    expectedVersion,
    dependencies,
  );
  return verifyRunningPilotDaemon(assets, dependencies);
}

export async function startPilotDaemon(
  rootInput: string,
  sourceCliInput: string,
  expectedVersion: string,
  dependencies: PilotDaemonDependencies = {},
): Promise<PilotDaemonVerification> {
  await verifyPilotIdentity(rootInput);
  const assets = await validatePilotDaemonAssets(
    rootInput,
    sourceCliInput,
    expectedVersion,
    dependencies,
  );
  const runCommand = dependencies.runCommand ?? defaultRunPilotCommand;
  const start = await runCommand(
    assets.sourceCli,
    ["app-server", "daemon", "start"],
    assets.env,
  );
  assertSuccessfulCommand(start, "Pilot Codex daemon start");

  const wait =
    dependencies.wait ??
    ((milliseconds) =>
      new Promise<void>((resolvePromise) =>
        setTimeout(resolvePromise, milliseconds),
      ));
  const deadline = Date.now() + DAEMON_VERIFY_TIMEOUT_MS;
  let lastError: unknown;
  do {
    try {
      return await verifyRunningPilotDaemon(assets, dependencies);
    } catch (error) {
      lastError = error;
      if (Date.now() >= deadline) break;
      await wait(DAEMON_VERIFY_RETRY_MS);
    }
  } while (Date.now() < deadline);
  throw new Error(
    `Pilot Codex daemon did not become ready: ${lastError instanceof Error ? lastError.message : String(lastError)}`,
  );
}

export async function stopPilotDaemon(
  rootInput: string,
  sourceCliInput: string,
  expectedVersion: string,
  dependencies: PilotDaemonDependencies = {},
): Promise<void> {
  const assets = await validatePilotDaemonAssets(
    rootInput,
    sourceCliInput,
    expectedVersion,
    dependencies,
  );
  await verifyRunningPilotDaemon(assets, dependencies);
  const runCommand = dependencies.runCommand ?? defaultRunPilotCommand;
  const stop = await runCommand(
    assets.sourceCli,
    ["app-server", "daemon", "stop"],
    assets.env,
  );
  assertSuccessfulCommand(stop, "Pilot Codex daemon stop");

  const wait =
    dependencies.wait ??
    ((milliseconds) =>
      new Promise<void>((resolvePromise) =>
        setTimeout(resolvePromise, milliseconds),
      ));
  const deadline = Date.now() + DAEMON_VERIFY_TIMEOUT_MS;
  while (Date.now() < deadline) {
    try {
      await lstat(assets.report.paths.daemonSocket);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return;
      throw error;
    }
    await wait(DAEMON_VERIFY_RETRY_MS);
  }
  throw new Error("Pilot Codex daemon socket remained after stop");
}

async function validateBridgeEntry(pathInput: string): Promise<string> {
  if (!isAbsolute(pathInput)) {
    throw new Error("Pilot Bridge entry must be an absolute path");
  }
  const path = await realpath(pathInput);
  const stats = await lstat(path);
  if (!stats.isFile()) {
    throw new Error("Pilot Bridge entry must be a regular file");
  }
  const productionRuntimeRoot = join(
    homedir(),
    "Library",
    "Application Support",
    "ccPocket Bridge",
    "runtime",
  );
  if (isWithin(productionRuntimeRoot, path)) {
    throw new Error("Pilot Bridge entry must not use a production runtime");
  }
  return path;
}

export async function launchIsolatedPilot(
  options: PilotLaunchOptions,
): Promise<number> {
  const report = await preflightPilotIsolation(options.root);
  await verifyPilotIdentity(options.root);
  await verifyPilotDaemon(
    options.root,
    options.cliPath,
    options.expectedVersion,
  );
  const bridgeEntry = await validateBridgeEntry(options.bridgeEntry);
  const env = await buildPilotEnvironment(
    report,
    {
      cliPath: options.cliPath,
      expectedVersion: options.expectedVersion,
      allowThreadStart: options.allowThreadStart,
      allowTurnStart: options.allowTurnStart,
      phoneLink: options.phoneLink,
    },
    options.baseEnv,
  );
  const spawnImpl = options.spawnImpl ?? spawn;

  // The API key is present only in the child environment. It is never placed
  // in argv, emitted in this launcher message, or written outside its 0600
  // secret file.
  console.log(
    `[pilot] Isolation preflight passed; launching candidate on ${PILOT_HOST}:${PILOT_PORT}`,
  );
  const child = spawnImpl(process.execPath, [bridgeEntry], {
    cwd: report.paths.canaryProject,
    env,
    stdio: "inherit",
  });
  return new Promise<number>((resolvePromise, reject) => {
    child.once("error", reject);
    child.once("exit", (code, signal) => {
      if (signal) {
        reject(new Error(`Pilot Bridge exited from signal ${signal}`));
        return;
      }
      resolvePromise(code ?? 1);
    });
  });
}

interface ParsedArgs {
  command:
    | "prepare"
    | "prepare-identity"
    | "prepare-daemon"
    | "start-daemon"
    | "verify-daemon"
    | "stop-daemon"
    | "preflight"
    | "launch";
  root: string;
  bridgeEntry?: string;
  cliPath?: string;
  expectedVersion?: string;
  allowThreadStart?: boolean;
  allowTurnStart?: boolean;
  phoneLink?: boolean;
  sourceCodexHome?: string;
}

function parseOptionalBinaryFlag(
  values: ReadonlyMap<string, string>,
  name: string,
): boolean | undefined {
  const value = values.get(name);
  if (value === undefined) return undefined;
  if (value === "0") return false;
  if (value === "1") return true;
  throw new Error(`--${name} must be exactly 0 or 1`);
}

function parseArgs(argv: string[]): ParsedArgs {
  const command = argv[0];
  if (
    command !== "prepare" &&
    command !== "prepare-identity" &&
    command !== "prepare-daemon" &&
    command !== "start-daemon" &&
    command !== "verify-daemon" &&
    command !== "stop-daemon" &&
    command !== "preflight" &&
    command !== "launch"
  ) {
    throw new Error(
      "Usage: pilot-isolation <prepare|prepare-identity|prepare-daemon|start-daemon|verify-daemon|stop-daemon|preflight|launch> [options]",
    );
  }
  const values = new Map<string, string>();
  for (let index = 1; index < argv.length; index += 2) {
    const name = argv[index];
    const value = argv[index + 1];
    if (!name?.startsWith("--") || value === undefined) {
      throw new Error(
        `Invalid pilot option near ${name ?? "end of arguments"}`,
      );
    }
    values.set(name.slice(2), value);
  }
  const sourceCli = values.get("source-cli");
  const legacyDaemonCli = values.get("daemon-cli");
  if (
    sourceCli !== undefined &&
    legacyDaemonCli !== undefined &&
    resolve(sourceCli) !== resolve(legacyDaemonCli)
  ) {
    throw new Error(
      "--source-cli and --daemon-cli must identify the same file",
    );
  }
  return {
    command,
    root: values.get("root") ?? defaultPilotRoot(),
    bridgeEntry: values.get("bridge-entry"),
    cliPath: sourceCli ?? legacyDaemonCli,
    expectedVersion: values.get("expected-version"),
    allowThreadStart: parseOptionalBinaryFlag(values, "allow-thread-start"),
    allowTurnStart: parseOptionalBinaryFlag(values, "allow-turn-start"),
    phoneLink: parseOptionalBinaryFlag(values, "phone-link"),
    sourceCodexHome: values.get("source-codex-home"),
  };
}

async function main(argv: string[]): Promise<void> {
  const args = parseArgs(argv);
  if (args.command === "prepare") {
    const report = await preparePilotIsolation(args.root);
    console.log(
      JSON.stringify({
        status: "prepared",
        root: report.paths.root,
        apiKeyFile: report.paths.apiKeyFile,
      }),
    );
    return;
  }
  if (args.command === "preflight") {
    const report = await preflightPilotIsolation(args.root);
    console.log(JSON.stringify({ status: "ready", ...report }));
    return;
  }
  if (args.command === "prepare-identity") {
    if (!args.sourceCodexHome) {
      throw new Error("prepare-identity requires --source-codex-home");
    }
    await preparePilotIdentity(args.root, args.sourceCodexHome);
    console.log(
      JSON.stringify({ status: "identity-prepared", root: args.root }),
    );
    return;
  }
  if (
    args.command === "prepare-daemon" ||
    args.command === "start-daemon" ||
    args.command === "verify-daemon" ||
    args.command === "stop-daemon"
  ) {
    if (!args.cliPath || !args.expectedVersion) {
      throw new Error(
        `${args.command} requires --source-cli and --expected-version`,
      );
    }
    if (args.command === "prepare-daemon") {
      const manifest = await preparePilotDaemon(
        args.root,
        args.cliPath,
        args.expectedVersion,
      );
      console.log(
        JSON.stringify({
          status: "daemon-prepared",
          managedCliPath: manifest.managedCliPath,
          sha256: manifest.managedSha256,
          expectedVersion: manifest.expectedVersion,
        }),
      );
      return;
    }
    if (args.command === "start-daemon") {
      const verified = await startPilotDaemon(
        args.root,
        args.cliPath,
        args.expectedVersion,
      );
      console.log(JSON.stringify({ status: "daemon-running", ...verified }));
      return;
    }
    if (args.command === "verify-daemon") {
      const verified = await verifyPilotDaemon(
        args.root,
        args.cliPath,
        args.expectedVersion,
      );
      console.log(JSON.stringify({ status: "daemon-verified", ...verified }));
      return;
    }
    await stopPilotDaemon(args.root, args.cliPath, args.expectedVersion);
    console.log(JSON.stringify({ status: "daemon-stopped", root: args.root }));
    return;
  }
  if (!args.bridgeEntry || !args.cliPath || !args.expectedVersion) {
    throw new Error(
      "launch requires --bridge-entry, --source-cli, and --expected-version",
    );
  }
  const exitCode = await launchIsolatedPilot({
    root: args.root,
    bridgeEntry: args.bridgeEntry,
    cliPath: args.cliPath,
    expectedVersion: args.expectedVersion,
    allowThreadStart: args.allowThreadStart,
    allowTurnStart: args.allowTurnStart,
    phoneLink: args.phoneLink,
  });
  process.exitCode = exitCode;
}

const isDirectExecution =
  process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1];
if (isDirectExecution) {
  main(process.argv.slice(2)).catch((error) => {
    console.error(
      `[pilot] ${error instanceof Error ? error.message : String(error)}`,
    );
    process.exitCode = 1;
  });
}
