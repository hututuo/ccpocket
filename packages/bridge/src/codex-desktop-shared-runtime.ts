#!/usr/bin/env node

import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import { lstat, open, readFile, rename, rm } from "node:fs/promises";
import { join } from "node:path";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import {
  preflightPilotIsolation,
  resolvePilotPaths,
} from "./pilot-isolation.js";

const execFileAsync = promisify(execFile);

export const DESKTOP_SHARED_RUNTIME_ENV_KEYS = [
  "CODEX_APP_SERVER_USE_LOCAL_DAEMON",
  "CODEX_HOME",
  "CODEX_SQLITE_HOME",
  "CODEX_APP_SERVER_FORCE_CLI",
  "CODEX_CLI_PATH",
  "CODEX_APP_SERVER_WS_URL",
] as const;

type DesktopSharedRuntimeEnvKey =
  (typeof DESKTOP_SHARED_RUNTIME_ENV_KEYS)[number];

export interface DesktopEnvironmentValue {
  present: boolean;
  value?: string;
}

export interface DesktopEnvironmentSnapshot {
  version: 2;
  uid: number;
  transactionId: string;
  createdAt: string;
  updatedAt: string;
  state: "captured" | "shared" | "restored";
  values: Record<DesktopSharedRuntimeEnvKey, DesktopEnvironmentValue>;
}

export interface DesktopProcessRecord {
  pid: number;
  parentPid: number;
  arguments: string;
}

export interface DesktopSharedRuntimeTopology {
  desktopPids: number[];
  descendantPids: number[];
  daemonSocketConnected: boolean;
  privateStdioAppServers: number;
}

export interface DesktopSharedRuntimeDependencies {
  uid?: number;
  now?: () => Date;
  printGuiDomain?: () => Promise<string>;
  setGuiEnvironment?: (name: string, value: string) => Promise<void>;
  unsetGuiEnvironment?: (name: string) => Promise<void>;
  listProcesses?: () => Promise<DesktopProcessRecord[]>;
  listUnixSockets?: (pid: number) => Promise<string[]>;
}

const SNAPSHOT_FILE = "desktop-environment-snapshot.json";
const MAX_SNAPSHOT_BYTES = 64 * 1024;

function currentUid(): number {
  const uid = process.getuid?.();
  if (uid === undefined) {
    throw new Error("Desktop shared-runtime pilot requires a Unix user id");
  }
  return uid;
}

function snapshotPath(root: string): string {
  return join(resolvePilotPaths(root).root, SNAPSHOT_FILE);
}

export function parseLaunchctlEnvironment(output: string): Map<string, string> {
  const values = new Map<string, string>();
  let inEnvironment = false;
  for (const line of output.split(/\r?\n/)) {
    if (!inEnvironment) {
      if (/^\s*environment\s*=\s*\{\s*$/.test(line)) {
        inEnvironment = true;
      }
      continue;
    }
    if (/^\s*}\s*$/.test(line)) break;
    const match = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=>\s*(.*)$/);
    if (match) values.set(match[1], match[2]);
  }
  return values;
}

function snapshotFromEnvironment(
  environment: ReadonlyMap<string, string>,
  uid: number,
  now: Date,
): DesktopEnvironmentSnapshot {
  const values = Object.fromEntries(
    DESKTOP_SHARED_RUNTIME_ENV_KEYS.map((key) => [
      key,
      environment.has(key)
        ? { present: true, value: environment.get(key) ?? "" }
        : { present: false },
    ]),
  ) as Record<DesktopSharedRuntimeEnvKey, DesktopEnvironmentValue>;
  const timestamp = now.toISOString();
  return {
    version: 2,
    uid,
    transactionId: randomUUID(),
    createdAt: timestamp,
    updatedAt: timestamp,
    state: "captured",
    values,
  };
}

function validateSnapshot(
  value: unknown,
  expectedUid: number,
): DesktopEnvironmentSnapshot {
  if (!value || typeof value !== "object") {
    throw new Error("Desktop environment snapshot is invalid");
  }
  const record = value as Partial<DesktopEnvironmentSnapshot>;
  if (
    record.version !== 2 ||
    record.uid !== expectedUid ||
    typeof record.transactionId !== "string" ||
    record.transactionId.length === 0 ||
    typeof record.createdAt !== "string" ||
    typeof record.updatedAt !== "string" ||
    (record.state !== "captured" &&
      record.state !== "shared" &&
      record.state !== "restored") ||
    !record.values
  ) {
    throw new Error("Desktop environment snapshot does not match this user");
  }
  for (const key of DESKTOP_SHARED_RUNTIME_ENV_KEYS) {
    const entry = record.values[key];
    if (
      !entry ||
      typeof entry.present !== "boolean" ||
      (entry.present && typeof entry.value !== "string")
    ) {
      throw new Error(`Desktop environment snapshot omitted ${key}`);
    }
  }
  return record as DesktopEnvironmentSnapshot;
}

async function defaultPrintGuiDomain(uid: number): Promise<string> {
  const { stdout } = await execFileAsync("/bin/launchctl", [
    "print",
    `gui/${uid}`,
  ]);
  return stdout;
}

async function defaultSetGuiEnvironment(
  name: string,
  value: string,
): Promise<void> {
  await execFileAsync("/bin/launchctl", ["setenv", name, value]);
}

async function defaultUnsetGuiEnvironment(name: string): Promise<void> {
  await execFileAsync("/bin/launchctl", ["unsetenv", name]);
}

async function defaultListProcesses(): Promise<DesktopProcessRecord[]> {
  const { stdout } = await execFileAsync("/bin/ps", [
    "-axo",
    "pid=,ppid=,args=",
  ]);
  return stdout.split(/\r?\n/).flatMap((line) => {
    const match = line.match(/^\s*(\d+)\s+(\d+)\s+(.*)$/);
    if (!match) return [];
    return [
      {
        pid: Number(match[1]),
        parentPid: Number(match[2]),
        arguments: match[3],
      },
    ];
  });
}

async function defaultListUnixSockets(pid: number): Promise<string[]> {
  try {
    const { stdout } = await execFileAsync("/usr/sbin/lsof", [
      "-n",
      "-U",
      "-a",
      "-p",
      String(pid),
    ]);
    return stdout.split(/\r?\n/);
  } catch {
    return [];
  }
}

function dependencies(
  overrides: DesktopSharedRuntimeDependencies = {},
): Required<DesktopSharedRuntimeDependencies> {
  const uid = overrides.uid ?? currentUid();
  return {
    uid,
    now: overrides.now ?? (() => new Date()),
    printGuiDomain:
      overrides.printGuiDomain ?? (() => defaultPrintGuiDomain(uid)),
    setGuiEnvironment: overrides.setGuiEnvironment ?? defaultSetGuiEnvironment,
    unsetGuiEnvironment:
      overrides.unsetGuiEnvironment ?? defaultUnsetGuiEnvironment,
    listProcesses: overrides.listProcesses ?? defaultListProcesses,
    listUnixSockets: overrides.listUnixSockets ?? defaultListUnixSockets,
  };
}

async function readSnapshot(
  root: string,
  deps: Required<DesktopSharedRuntimeDependencies>,
): Promise<DesktopEnvironmentSnapshot> {
  const path = snapshotPath(root);
  const metadata = await lstat(path);
  if (
    metadata.isSymbolicLink() ||
    !metadata.isFile() ||
    metadata.uid !== deps.uid ||
    (metadata.mode & 0o777) !== 0o600
  ) {
    throw new Error("Desktop environment snapshot must be a 0600 regular file");
  }
  if (metadata.size > MAX_SNAPSHOT_BYTES) {
    throw new Error("Desktop environment snapshot is unexpectedly large");
  }
  return validateSnapshot(JSON.parse(await readFile(path, "utf8")), deps.uid);
}

async function writeSnapshotAtomically(
  root: string,
  snapshot: DesktopEnvironmentSnapshot,
): Promise<void> {
  const path = snapshotPath(root);
  const temporaryPath = `${path}.tmp-${process.pid}-${randomUUID()}`;
  let handle;
  try {
    handle = await open(temporaryPath, "wx", 0o600);
    await handle.writeFile(`${JSON.stringify(snapshot, null, 2)}\n`, "utf8");
    await handle.sync();
    await handle.close();
    handle = undefined;
    await rename(temporaryPath, path);
  } finally {
    await handle?.close();
    await rm(temporaryPath, { force: true });
  }
}

async function transitionSnapshot(
  root: string,
  deps: Required<DesktopSharedRuntimeDependencies>,
  expected: DesktopEnvironmentSnapshot,
  nextState: DesktopEnvironmentSnapshot["state"],
): Promise<DesktopEnvironmentSnapshot> {
  const latest = await readSnapshot(root, deps);
  if (
    latest.transactionId !== expected.transactionId ||
    latest.state !== expected.state
  ) {
    throw new Error("Desktop environment transaction changed concurrently");
  }
  const next: DesktopEnvironmentSnapshot = {
    ...latest,
    state: nextState,
    updatedAt: deps.now().toISOString(),
  };
  await writeSnapshotAtomically(root, next);
  return next;
}

export async function snapshotDesktopEnvironment(
  root: string,
  overrides: DesktopSharedRuntimeDependencies = {},
): Promise<{
  path: string;
  snapshot: DesktopEnvironmentSnapshot;
  reused: boolean;
}> {
  await preflightPilotIsolation(root, { checkPort: false });
  const deps = dependencies(overrides);
  const path = snapshotPath(root);
  let existing: DesktopEnvironmentSnapshot | undefined;
  try {
    existing = await readSnapshot(root, deps);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
  }

  const environment = parseLaunchctlEnvironment(await deps.printGuiDomain());
  if (existing?.state === "shared") {
    throw new Error(
      "Desktop environment transaction is already in shared mode",
    );
  }
  if (existing?.state === "captured") {
    assertEnvironmentMatches(environment, existing.values);
    return { path, snapshot: existing, reused: true };
  }

  const snapshot = snapshotFromEnvironment(environment, deps.uid, deps.now());
  if (existing?.state === "restored") {
    const latest = await readSnapshot(root, deps);
    if (
      latest.transactionId !== existing.transactionId ||
      latest.state !== "restored"
    ) {
      throw new Error("Desktop environment transaction changed concurrently");
    }
  }
  await writeSnapshotAtomically(root, snapshot);
  return { path, snapshot, reused: false };
}

async function applyEnvironment(
  values: Record<DesktopSharedRuntimeEnvKey, DesktopEnvironmentValue>,
  deps: Required<DesktopSharedRuntimeDependencies>,
): Promise<void> {
  for (const key of DESKTOP_SHARED_RUNTIME_ENV_KEYS) {
    const entry = values[key];
    if (entry.present) {
      await deps.setGuiEnvironment(key, entry.value ?? "");
    } else {
      await deps.unsetGuiEnvironment(key);
    }
  }
}

function sharedEnvironmentForRoot(
  root: string,
): Record<DesktopSharedRuntimeEnvKey, DesktopEnvironmentValue> {
  const paths = resolvePilotPaths(root);
  return {
    CODEX_APP_SERVER_USE_LOCAL_DAEMON: { present: true, value: "1" },
    CODEX_HOME: { present: true, value: paths.codexHome },
    CODEX_SQLITE_HOME: { present: false },
    CODEX_APP_SERVER_FORCE_CLI: { present: false },
    CODEX_CLI_PATH: { present: false },
    CODEX_APP_SERVER_WS_URL: { present: false },
  };
}

function assertEnvironmentMatches(
  actual: ReadonlyMap<string, string>,
  expected: Record<DesktopSharedRuntimeEnvKey, DesktopEnvironmentValue>,
): void {
  for (const key of DESKTOP_SHARED_RUNTIME_ENV_KEYS) {
    const wanted = expected[key];
    if (wanted.present !== actual.has(key)) {
      throw new Error(`GUI environment presence mismatch for ${key}`);
    }
    if (wanted.present && actual.get(key) !== (wanted.value ?? "")) {
      throw new Error(`GUI environment value mismatch for ${key}`);
    }
  }
}

export async function enableDesktopSharedRuntime(
  root: string,
  overrides: DesktopSharedRuntimeDependencies = {},
): Promise<void> {
  await preflightPilotIsolation(root, { checkPort: false });
  const deps = dependencies(overrides);
  const snapshot = await readSnapshot(root, deps);
  if (snapshot.state !== "captured") {
    throw new Error(
      `Desktop environment transaction must be captured before enable (found ${snapshot.state})`,
    );
  }
  assertEnvironmentMatches(
    parseLaunchctlEnvironment(await deps.printGuiDomain()),
    snapshot.values,
  );
  const shared = sharedEnvironmentForRoot(root);
  try {
    await applyEnvironment(shared, deps);
    assertEnvironmentMatches(
      parseLaunchctlEnvironment(await deps.printGuiDomain()),
      shared,
    );
    await transitionSnapshot(root, deps, snapshot, "shared");
  } catch (error) {
    try {
      await applyEnvironment(snapshot.values, deps);
      assertEnvironmentMatches(
        parseLaunchctlEnvironment(await deps.printGuiDomain()),
        snapshot.values,
      );
    } catch (rollbackError) {
      throw new Error(
        `Failed to enable shared Desktop environment and verified rollback also failed: ${rollbackError instanceof Error ? rollbackError.message : String(rollbackError)}`,
        { cause: error },
      );
    }
    throw error;
  }
}

export async function restoreDesktopPrivateRuntime(
  root: string,
  overrides: DesktopSharedRuntimeDependencies = {},
): Promise<void> {
  await preflightPilotIsolation(root, { checkPort: false });
  const deps = dependencies(overrides);
  const snapshot = await readSnapshot(root, deps);
  if (snapshot.state !== "shared") {
    throw new Error(
      `Desktop environment transaction must be shared before restore (found ${snapshot.state})`,
    );
  }
  await applyEnvironment(snapshot.values, deps);
  assertEnvironmentMatches(
    parseLaunchctlEnvironment(await deps.printGuiDomain()),
    snapshot.values,
  );
  await transitionSnapshot(root, deps, snapshot, "restored");
}

function descendantPids(
  processes: DesktopProcessRecord[],
  roots: ReadonlySet<number>,
): Set<number> {
  const descendants = new Set(roots);
  let changed = true;
  while (changed) {
    changed = false;
    for (const processRecord of processes) {
      if (
        descendants.has(processRecord.parentPid) &&
        !descendants.has(processRecord.pid)
      ) {
        descendants.add(processRecord.pid);
        changed = true;
      }
    }
  }
  return descendants;
}

export async function verifyDesktopSharedRuntime(
  root: string,
  overrides: DesktopSharedRuntimeDependencies = {},
): Promise<DesktopSharedRuntimeTopology> {
  await preflightPilotIsolation(root, { checkPort: false });
  const deps = dependencies(overrides);
  const snapshot = await readSnapshot(root, deps);
  if (snapshot.state !== "shared") {
    throw new Error("Desktop environment transaction is not in shared mode");
  }
  const shared = sharedEnvironmentForRoot(root);
  assertEnvironmentMatches(
    parseLaunchctlEnvironment(await deps.printGuiDomain()),
    shared,
  );

  const processes = await deps.listProcesses();
  const desktopPids = processes
    .filter((entry) =>
      /\/(?:ChatGPT|Codex)\.app\/Contents\/MacOS\/(?:ChatGPT|Codex)(?:\s|$)/.test(
        entry.arguments,
      ),
    )
    .map((entry) => entry.pid);
  if (desktopPids.length === 0) {
    throw new Error("Codex Desktop is not running");
  }
  const descendants = descendantPids(processes, new Set(desktopPids));
  const descendantRecords = processes.filter((entry) =>
    descendants.has(entry.pid),
  );
  const privateStdioAppServers = descendantRecords.filter((entry) =>
    /\bcodex\b.*\bapp-server\b.*--listen\s+stdio:\/\//.test(entry.arguments),
  ).length;
  const socketPath = resolvePilotPaths(root).daemonSocket;
  let daemonSocketConnected = false;
  for (const pid of descendants) {
    const socketLines = await deps.listUnixSockets(pid);
    if (socketLines.some((line) => line.includes(socketPath))) {
      daemonSocketConnected = true;
      break;
    }
  }

  if (privateStdioAppServers > 0) {
    throw new Error("Codex Desktop silently fell back to a private app-server");
  }
  if (!daemonSocketConnected) {
    throw new Error(
      "Codex Desktop is not connected to the pilot daemon socket",
    );
  }

  return {
    desktopPids: desktopPids.sort((a, b) => a - b),
    descendantPids: [...descendants].sort((a, b) => a - b),
    daemonSocketConnected,
    privateStdioAppServers,
  };
}

interface ParsedArgs {
  command: "snapshot" | "enable-shared" | "verify-shared" | "restore-private";
  root: string;
}

function parseArgs(argv: string[]): ParsedArgs {
  const command = argv[0] as ParsedArgs["command"] | undefined;
  if (
    command !== "snapshot" &&
    command !== "enable-shared" &&
    command !== "verify-shared" &&
    command !== "restore-private"
  ) {
    throw new Error(
      "Usage: codex-desktop-shared-runtime <snapshot|enable-shared|verify-shared|restore-private> --root <pilot-root>",
    );
  }
  if (argv[1] !== "--root" || !argv[2] || argv.length !== 3) {
    throw new Error("Desktop shared-runtime command requires --root");
  }
  return { command, root: argv[2] };
}

async function main(argv: string[]): Promise<void> {
  const args = parseArgs(argv);
  if (args.command === "snapshot") {
    const result = await snapshotDesktopEnvironment(args.root);
    console.log(
      JSON.stringify({
        status: result.reused ? "snapshot_reused" : "snapshot_created",
        path: result.path,
      }),
    );
    return;
  }
  if (args.command === "enable-shared") {
    await enableDesktopSharedRuntime(args.root);
    console.log(JSON.stringify({ status: "shared_environment_enabled" }));
    return;
  }
  if (args.command === "restore-private") {
    await restoreDesktopPrivateRuntime(args.root);
    console.log(JSON.stringify({ status: "private_environment_restored" }));
    return;
  }
  const topology = await verifyDesktopSharedRuntime(args.root);
  console.log(
    JSON.stringify({ status: "shared_runtime_verified", ...topology }),
  );
}

const isDirectExecution =
  process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1];
if (isDirectExecution) {
  main(process.argv.slice(2)).catch((error) => {
    console.error(
      `[desktop-pilot] ${error instanceof Error ? error.message : String(error)}`,
    );
    process.exitCode = 1;
  });
}
