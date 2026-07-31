#!/usr/bin/env node

import { lstat, readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import WebSocket from "ws";
import {
  PILOT_HOST,
  PILOT_PORT,
  preflightPilotIsolation,
  resolvePilotPaths,
} from "./pilot-isolation.js";
import { getPackageVersion } from "./version.js";

const API_KEY_PATTERN = /^[A-Za-z0-9_-]{43}$/;
const MAX_INBOX_MESSAGES = 512;

interface PilotDiagnosticEvent {
  method?: string;
  threadId?: string;
  turnId?: string;
}

interface PilotDiagnostics {
  ready?: boolean;
  connectionGeneration?: number;
  daemon?: {
    expectedVersion?: string;
    cliVersion?: string;
    appServerVersion?: string;
    socketDevice?: number;
    socketInode?: number;
  };
  attachments?: number;
  events?: PilotDiagnosticEvent[];
}

class PilotBridgeClient {
  private readonly inbox: Array<Record<string, unknown>> = [];
  private readonly waiters = new Set<{
    predicate: (message: Record<string, unknown>) => boolean;
    resolve: (message: Record<string, unknown>) => void;
    reject: (error: Error) => void;
    timer: NodeJS.Timeout;
  }>();

  constructor(private readonly socket: WebSocket) {
    socket.on("message", (data) => {
      let message: Record<string, unknown>;
      try {
        message = JSON.parse(data.toString()) as Record<string, unknown>;
      } catch {
        return;
      }
      this.inbox.push(message);
      if (this.inbox.length > MAX_INBOX_MESSAGES) this.inbox.shift();
      for (const waiter of [...this.waiters]) {
        if (!waiter.predicate(message)) continue;
        this.waiters.delete(waiter);
        clearTimeout(waiter.timer);
        waiter.resolve(message);
      }
    });
    const rejectAll = (error: Error): void => {
      for (const waiter of this.waiters) {
        clearTimeout(waiter.timer);
        waiter.reject(error);
      }
      this.waiters.clear();
    };
    socket.on("error", (error) => rejectAll(error));
    socket.on("close", () => rejectAll(new Error("Pilot WebSocket closed")));
  }

  static async connect(apiKey: string): Promise<PilotBridgeClient> {
    const socket = new WebSocket(
      `ws://${PILOT_HOST}:${PILOT_PORT}?token=${encodeURIComponent(apiKey)}`,
    );
    await new Promise<void>((resolve, reject) => {
      socket.once("open", resolve);
      socket.once("error", reject);
    });
    return new PilotBridgeClient(socket);
  }

  send(message: Record<string, unknown>): void {
    if (this.socket.readyState !== WebSocket.OPEN) {
      throw new Error("Pilot WebSocket is not open");
    }
    this.socket.send(JSON.stringify(message));
  }

  checkpoint(): number {
    return this.inbox.length;
  }

  messagesSince(checkpoint: number): Array<Record<string, unknown>> {
    return this.inbox.slice(checkpoint);
  }

  waitFor(
    predicate: (message: Record<string, unknown>) => boolean,
    timeoutMs: number,
    description: string,
  ): Promise<Record<string, unknown>> {
    const existing = this.inbox.find(predicate);
    if (existing) return Promise.resolve(existing);
    return new Promise((resolve, reject) => {
      const waiter = {
        predicate,
        resolve,
        reject,
        timer: setTimeout(() => {
          this.waiters.delete(waiter);
          reject(new Error(`Timed out waiting for ${description}`));
        }, timeoutMs),
      };
      waiter.timer.unref?.();
      this.waiters.add(waiter);
    });
  }

  close(): Promise<void> {
    if (this.socket.readyState === WebSocket.CLOSED) return Promise.resolve();
    return new Promise((resolve) => {
      this.socket.once("close", () => resolve());
      this.socket.close();
    });
  }
}

async function readPilotApiKey(root: string): Promise<string> {
  const path = resolvePilotPaths(root).apiKeyFile;
  const metadata = await lstat(path);
  if (!metadata.isFile() || metadata.isSymbolicLink()) {
    throw new Error("Pilot API key is not a regular file");
  }
  if ((metadata.mode & 0o777) !== 0o600) {
    throw new Error("Pilot API key must have mode 0600");
  }
  const value = (await readFile(path, "utf8")).trim();
  if (!API_KEY_PATTERN.test(value)) {
    throw new Error("Pilot API key is invalid");
  }
  return value;
}

async function fetchJson<T>(
  path: string,
  apiKey: string,
): Promise<{ status: number; body: T }> {
  const response = await fetch(`http://${PILOT_HOST}:${PILOT_PORT}${path}`, {
    headers: { Authorization: `Bearer ${apiKey}` },
    signal: AbortSignal.timeout(10_000),
  });
  return { status: response.status, body: (await response.json()) as T };
}

async function waitForDiagnostic(
  apiKey: string,
  predicate: (diagnostics: PilotDiagnostics) => boolean,
  description: string,
  timeoutMs = 15_000,
): Promise<PilotDiagnostics> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const response = await fetchJson<PilotDiagnostics>(
      "/pilot/diagnostics",
      apiKey,
    );
    if (response.status === 200 && predicate(response.body)) {
      return response.body;
    }
    await new Promise<void>((resolve) => setTimeout(resolve, 50));
  }
  throw new Error(`Timed out waiting for ${description}`);
}

function messageType(message: Record<string, unknown>): string {
  return typeof message.type === "string" ? message.type : "";
}

export interface SharedRuntimeL0Report {
  bridgeVersion: string;
  threadId: string;
  turnId: string;
  daemonSocketDevice: number;
  daemonSocketInode: number;
  controlGeneration: number;
  threadStartedEvents: number;
  turnStartedEvents: number;
  turnCompletedEvents: number;
  secondClientObservedSession: true;
  secondClientObservedCompletion: true;
  neutralResumeConfirmed: true;
  resumedBridgeSessionId: string;
  assistantConfirmed: true;
  durationMs: number;
}

export interface SharedRuntimeRestartReport {
  bridgeVersion: string;
  threadId: string;
  bridgeSessionId: string;
  turnId: string;
  daemonSocketDevice: number;
  daemonSocketInode: number;
  controlGeneration: number;
  neutralResumeConfirmed: true;
  assistantConfirmed: true;
  durationMs: number;
}

export interface SharedRuntimeActiveAdoptionReport {
  bridgeVersion: string;
  threadId: string;
  originalBridgeSessionId: string;
  adoptedBridgeSessionId: string;
  activeTurnId: string;
  daemonSocketInode: number;
  activeStatusObserved: true;
  completionObservedAfterAdoption: true;
  durationMs: number;
}

export async function runSharedRuntimeL0(
  root: string,
): Promise<SharedRuntimeL0Report> {
  const startedAt = Date.now();
  const report = await preflightPilotIsolation(root, { checkPort: false });
  const apiKey = await readPilotApiKey(root);
  const version = await fetchJson<{ version?: string }>("/version", apiKey);
  if (version.status !== 200 || version.body.version !== getPackageVersion()) {
    throw new Error("Pilot Bridge version does not match this candidate build");
  }
  const readiness = await fetchJson<{ status?: string }>("/readyz", apiKey);
  if (readiness.status !== 200 || readiness.body.status !== "ready") {
    throw new Error("Pilot Bridge is not ready");
  }
  const initialDiagnostics = await fetchJson<PilotDiagnostics>(
    "/pilot/diagnostics",
    apiKey,
  );
  const identity = initialDiagnostics.body.daemon;
  if (
    initialDiagnostics.status !== 200 ||
    initialDiagnostics.body.ready !== true ||
    typeof identity?.socketDevice !== "number" ||
    typeof identity.socketInode !== "number" ||
    typeof initialDiagnostics.body.connectionGeneration !== "number"
  ) {
    throw new Error(
      "Pilot diagnostics did not prove one ready daemon identity",
    );
  }

  const client = await PilotBridgeClient.connect(apiKey);
  const secondClient = await PilotBridgeClient.connect(apiKey);
  try {
    await Promise.all(
      [client, secondClient].map((connectedClient) =>
        connectedClient.waitFor(
          (message) => messageType(message) === "session_list",
          10_000,
          "initial session catalog",
        ),
      ),
    );
    const startRequestId = `l0-start-${Date.now()}`;
    client.send({
      type: "start",
      provider: "codex",
      projectPath: report.paths.canaryProject,
      approvalPolicy: "never",
      sandboxMode: "on",
      autoRename: false,
      startRequestId,
    });
    const created = await client.waitFor(
      (message) =>
        (message.type === "system" &&
          message.subtype === "session_created" &&
          message.startRequestId === startRequestId) ||
        (message.type === "session_start_failed" &&
          message.startRequestId === startRequestId),
      30_000,
      "authoritative daemon thread creation",
    );
    if (created.type === "session_start_failed") {
      throw new Error("Pilot daemon rejected thread/start");
    }
    const bridgeSessionId =
      typeof created.sessionId === "string" ? created.sessionId : undefined;
    const threadId =
      typeof created.claudeSessionId === "string"
        ? created.claudeSessionId
        : undefined;
    if (!bridgeSessionId || !threadId) {
      throw new Error("Pilot session_created omitted stable identities");
    }
    await secondClient.waitFor(
      (message) =>
        message.type === "session_list" &&
        JSON.stringify(message).includes(bridgeSessionId),
      15_000,
      "second client session visibility",
    );

    await waitForDiagnostic(
      apiKey,
      (diagnostics) =>
        (diagnostics.events ?? []).some(
          (event) =>
            event.method === "thread/started" && event.threadId === threadId,
        ),
      "control observer thread/started",
    );

    const canaryName = `CC Pocket shared runtime L0 ${Date.now()}`;
    client.send({
      type: "rename_session",
      sessionId: bridgeSessionId,
      name: canaryName,
      provider: "codex",
    });
    const renamed = await client.waitFor(
      (message) =>
        message.type === "rename_result" &&
        message.sessionId === bridgeSessionId,
      15_000,
      "thread rename",
    );
    if (renamed.success !== true) {
      throw new Error("Pilot thread rename failed");
    }
    await waitForDiagnostic(
      apiKey,
      (diagnostics) =>
        (diagnostics.events ?? []).some(
          (event) =>
            event.method === "thread/name/updated" &&
            event.threadId === threadId,
        ),
      "control observer thread/name/updated",
    );

    const clientMessageId = `l0-input-${Date.now()}`;
    client.send({
      type: "input",
      sessionId: bridgeSessionId,
      clientMessageId,
      text: "Reply with exactly PILOT_OK. Do not call tools.",
    });
    const completion = await client.waitFor(
      (message) =>
        // Bridge rewrites provider lifecycle messages to its stable runtime
        // session id before broadcasting them to clients.  The provider
        // thread id remains available through session_created/diagnostics,
        // but is deliberately not used as the client routing key here.
        (message.type === "result" && message.sessionId === bridgeSessionId) ||
        (message.type === "input_rejected" &&
          message.clientMessageId === clientMessageId),
      180_000,
      "canary turn completion",
    );
    if (completion.type !== "result" || completion.subtype === "error") {
      throw new Error("Pilot canary turn did not complete successfully");
    }
    const assistantConfirmed = JSON.stringify(completion).includes("PILOT_OK");
    if (!assistantConfirmed) {
      throw new Error("Pilot canary result did not contain PILOT_OK");
    }
    await secondClient.waitFor(
      (message) =>
        message.type === "result" && message.sessionId === bridgeSessionId,
      15_000,
      "second client turn completion",
    );

    const finalDiagnostics = await waitForDiagnostic(
      apiKey,
      (diagnostics) => {
        const events = diagnostics.events ?? [];
        return events.some(
          (event) =>
            event.method === "turn/completed" && event.threadId === threadId,
        );
      },
      "control observer turn completion",
      30_000,
    );
    const events = finalDiagnostics.events ?? [];
    const threadStarted = events.filter(
      (event) =>
        event.method === "thread/started" && event.threadId === threadId,
    );
    const turnStarted = events.filter(
      (event) => event.method === "turn/started" && event.threadId === threadId,
    );
    const turnCompleted = events.filter(
      (event) =>
        event.method === "turn/completed" && event.threadId === threadId,
    );
    const turnId = turnStarted[0]?.turnId;
    if (
      threadStarted.length !== 1 ||
      turnStarted.length !== 1 ||
      turnCompleted.length !== 1 ||
      !turnId ||
      turnCompleted[0]?.turnId !== turnId
    ) {
      throw new Error("Pilot lifecycle events were duplicated or mismatched");
    }

    client.send({ type: "stop_session", sessionId: bridgeSessionId });
    await client.waitFor(
      (message) =>
        message.type === "result" &&
        message.subtype === "stopped" &&
        message.sessionId === bridgeSessionId,
      15_000,
      "Bridge attachment stop",
    );

    const resumeCheckpoint = client.checkpoint();
    const resumeRequestId = `l0-resume-${Date.now()}`;
    client.send({
      type: "resume_session",
      provider: "codex",
      sessionId: threadId,
      projectPath: report.paths.canaryProject,
      resumeRequestId,
    });
    const resumed = await client.waitFor(
      (message) =>
        (message.type === "system" &&
          message.subtype === "session_created" &&
          message.resumeRequestId === resumeRequestId) ||
        (message.type === "system" &&
          message.subtype === "session_resume_failed" &&
          message.resumeRequestId === resumeRequestId),
      30_000,
      "settings-neutral thread resume",
    );
    if (resumed.subtype === "session_resume_failed") {
      throw new Error("Pilot daemon rejected settings-neutral resume");
    }
    const resumedBridgeSessionId =
      typeof resumed.sessionId === "string" ? resumed.sessionId : undefined;
    if (
      !resumedBridgeSessionId ||
      resumed.claudeSessionId !== threadId ||
      client
        .messagesSince(resumeCheckpoint)
        .some((message) => message.type === "past_history")
    ) {
      throw new Error(
        "Pilot resume changed identity or replayed transcript history",
      );
    }
    await waitForDiagnostic(
      apiKey,
      (diagnostics) => diagnostics.attachments === 1,
      "one ready attachment after neutral resume",
    );

    return {
      bridgeVersion: version.body.version,
      threadId,
      turnId,
      daemonSocketDevice: identity.socketDevice,
      daemonSocketInode: identity.socketInode,
      controlGeneration: initialDiagnostics.body.connectionGeneration,
      threadStartedEvents: threadStarted.length,
      turnStartedEvents: turnStarted.length,
      turnCompletedEvents: turnCompleted.length,
      secondClientObservedSession: true,
      secondClientObservedCompletion: true,
      neutralResumeConfirmed: true,
      resumedBridgeSessionId,
      assistantConfirmed: true,
      durationMs: Date.now() - startedAt,
    };
  } finally {
    await secondClient.close();
    await client.close();
  }
}

export async function runSharedRuntimeRestartProbe(
  root: string,
  threadId: string,
  expectedSocketInode?: number,
): Promise<SharedRuntimeRestartReport> {
  const startedAt = Date.now();
  const normalizedThreadId = threadId.trim();
  if (!normalizedThreadId || normalizedThreadId.length > 256) {
    throw new Error("Restart probe requires one bounded Codex thread id");
  }
  const report = await preflightPilotIsolation(root, { checkPort: false });
  const apiKey = await readPilotApiKey(root);
  const version = await fetchJson<{ version?: string }>("/version", apiKey);
  if (version.status !== 200 || version.body.version !== getPackageVersion()) {
    throw new Error("Restarted Bridge version does not match this candidate");
  }
  const initialDiagnostics = await fetchJson<PilotDiagnostics>(
    "/pilot/diagnostics",
    apiKey,
  );
  const identity = initialDiagnostics.body.daemon;
  if (
    initialDiagnostics.status !== 200 ||
    initialDiagnostics.body.ready !== true ||
    typeof identity?.socketDevice !== "number" ||
    typeof identity.socketInode !== "number" ||
    typeof initialDiagnostics.body.connectionGeneration !== "number" ||
    (expectedSocketInode !== undefined &&
      identity.socketInode !== expectedSocketInode)
  ) {
    throw new Error(
      "Restarted Bridge did not retain the expected daemon identity",
    );
  }

  const client = await PilotBridgeClient.connect(apiKey);
  try {
    await client.waitFor(
      (message) => messageType(message) === "session_list",
      10_000,
      "restart probe session catalog",
    );
    const resumeCheckpoint = client.checkpoint();
    const resumeRequestId = `l0-restart-resume-${Date.now()}`;
    client.send({
      type: "resume_session",
      provider: "codex",
      sessionId: normalizedThreadId,
      projectPath: report.paths.canaryProject,
      resumeRequestId,
    });
    const resumed = await client.waitFor(
      (message) =>
        message.type === "system" &&
        (message.subtype === "session_created" ||
          message.subtype === "session_resume_failed") &&
        message.resumeRequestId === resumeRequestId,
      30_000,
      "thread resume after Bridge restart",
    );
    if (resumed.subtype !== "session_created") {
      throw new Error("Restarted Bridge could not resume the canary thread");
    }
    const bridgeSessionId =
      typeof resumed.sessionId === "string" ? resumed.sessionId : undefined;
    if (
      !bridgeSessionId ||
      resumed.claudeSessionId !== normalizedThreadId ||
      client
        .messagesSince(resumeCheckpoint)
        .some((message) => message.type === "past_history")
    ) {
      throw new Error(
        "Restarted Bridge changed identity or replayed transcript history",
      );
    }
    await waitForDiagnostic(
      apiKey,
      (diagnostics) => diagnostics.attachments === 1,
      "one ready attachment after Bridge restart",
    );

    const clientMessageId = `l0-restart-input-${Date.now()}`;
    client.send({
      type: "input",
      sessionId: bridgeSessionId,
      clientMessageId,
      text: "Reply with exactly PILOT_RESTART_OK. Do not call tools.",
    });
    const completion = await client.waitFor(
      (message) =>
        (message.type === "result" && message.sessionId === bridgeSessionId) ||
        (message.type === "input_rejected" &&
          message.clientMessageId === clientMessageId),
      180_000,
      "post-restart canary completion",
    );
    if (
      completion.type !== "result" ||
      completion.subtype === "error" ||
      !JSON.stringify(completion).includes("PILOT_RESTART_OK")
    ) {
      throw new Error("Post-restart canary turn did not complete correctly");
    }
    const finalDiagnostics = await waitForDiagnostic(
      apiKey,
      (diagnostics) =>
        (diagnostics.events ?? []).some(
          (event) =>
            event.method === "turn/completed" &&
            event.threadId === normalizedThreadId,
        ),
      "post-restart turn completion",
      30_000,
    );
    const started = (finalDiagnostics.events ?? []).filter(
      (event) =>
        event.method === "turn/started" &&
        event.threadId === normalizedThreadId,
    );
    const completed = (finalDiagnostics.events ?? []).filter(
      (event) =>
        event.method === "turn/completed" &&
        event.threadId === normalizedThreadId,
    );
    const turnId = started[0]?.turnId;
    if (
      started.length !== 1 ||
      completed.length !== 1 ||
      !turnId ||
      completed[0]?.turnId !== turnId
    ) {
      throw new Error("Post-restart lifecycle was duplicated or mismatched");
    }
    return {
      bridgeVersion: version.body.version,
      threadId: normalizedThreadId,
      bridgeSessionId,
      turnId,
      daemonSocketDevice: identity.socketDevice,
      daemonSocketInode: identity.socketInode,
      controlGeneration: initialDiagnostics.body.connectionGeneration,
      neutralResumeConfirmed: true,
      assistantConfirmed: true,
      durationMs: Date.now() - startedAt,
    };
  } finally {
    await client.close();
  }
}

export async function runSharedRuntimeActiveAdoptionProbe(
  root: string,
  threadId: string,
  expectedSocketInode?: number,
): Promise<SharedRuntimeActiveAdoptionReport> {
  const startedAt = Date.now();
  const normalizedThreadId = threadId.trim();
  if (!normalizedThreadId || normalizedThreadId.length > 256) {
    throw new Error("Active adoption requires one bounded Codex thread id");
  }
  const report = await preflightPilotIsolation(root, { checkPort: false });
  const apiKey = await readPilotApiKey(root);
  const version = await fetchJson<{ version?: string }>("/version", apiKey);
  const initialDiagnostics = await fetchJson<PilotDiagnostics>(
    "/pilot/diagnostics",
    apiKey,
  );
  const daemon = initialDiagnostics.body.daemon;
  if (
    version.status !== 200 ||
    version.body.version !== getPackageVersion() ||
    initialDiagnostics.status !== 200 ||
    initialDiagnostics.body.ready !== true ||
    typeof daemon?.socketInode !== "number" ||
    (expectedSocketInode !== undefined &&
      daemon.socketInode !== expectedSocketInode)
  ) {
    throw new Error("Active adoption did not start on the expected daemon");
  }
  const initialEventSequence = Math.max(
    0,
    ...(initialDiagnostics.body.events ?? []).map(
      (event) =>
        (event as PilotDiagnosticEvent & { sequence?: number }).sequence ?? 0,
    ),
  );

  const client = await PilotBridgeClient.connect(apiKey);
  try {
    await client.waitFor(
      (message) => messageType(message) === "session_list",
      10_000,
      "active adoption session catalog",
    );
    const firstResumeRequestId = `l0-active-resume-${Date.now()}`;
    client.send({
      type: "resume_session",
      provider: "codex",
      sessionId: normalizedThreadId,
      projectPath: report.paths.canaryProject,
      resumeRequestId: firstResumeRequestId,
    });
    const firstResume = await client.waitFor(
      (message) =>
        message.type === "system" &&
        message.subtype === "session_created" &&
        message.resumeRequestId === firstResumeRequestId,
      30_000,
      "initial active-adoption attachment",
    );
    const originalBridgeSessionId =
      typeof firstResume.sessionId === "string"
        ? firstResume.sessionId
        : undefined;
    if (!originalBridgeSessionId) {
      throw new Error("Initial active-adoption attachment omitted session id");
    }

    const clientMessageId = `l0-active-input-${Date.now()}`;
    client.send({
      type: "input",
      sessionId: originalBridgeSessionId,
      clientMessageId,
      text: "Do not call tools. Output ACTIVE_PILOT_BEGIN, then exactly 600 numbered lines in the form `N active-adoption-check`, then output ACTIVE_PILOT_END.",
    });
    const activeDiagnostics = await waitForDiagnostic(
      apiKey,
      (diagnostics) =>
        (diagnostics.events ?? []).some(
          (event) =>
            ((event as PilotDiagnosticEvent & { sequence?: number }).sequence ??
              0) > initialEventSequence &&
            event.method === "turn/started" &&
            event.threadId === normalizedThreadId,
        ),
      "active turn start",
      30_000,
    );
    const activeTurn = (activeDiagnostics.events ?? []).find(
      (event) =>
        ((event as PilotDiagnosticEvent & { sequence?: number }).sequence ??
          0) > initialEventSequence &&
        event.method === "turn/started" &&
        event.threadId === normalizedThreadId,
    );
    const activeTurnId = activeTurn?.turnId;
    if (
      !activeTurnId ||
      (activeDiagnostics.events ?? []).some(
        (event) =>
          event.method === "turn/completed" && event.turnId === activeTurnId,
      )
    ) {
      throw new Error("Canary turn completed before active adoption began");
    }

    client.send({
      type: "stop_session",
      sessionId: originalBridgeSessionId,
    });
    await client.waitFor(
      (message) =>
        message.type === "result" &&
        message.subtype === "stopped" &&
        message.sessionId === originalBridgeSessionId,
      15_000,
      "original active attachment stop",
    );

    const adoptionRequestId = `l0-active-adopt-${Date.now()}`;
    client.send({
      type: "resume_session",
      provider: "codex",
      sessionId: normalizedThreadId,
      projectPath: report.paths.canaryProject,
      resumeRequestId: adoptionRequestId,
    });
    const adopted = await client.waitFor(
      (message) =>
        message.type === "system" &&
        (message.subtype === "session_created" ||
          message.subtype === "session_resume_failed") &&
        message.resumeRequestId === adoptionRequestId,
      30_000,
      "active turn adoption",
    );
    const adoptedBridgeSessionId =
      adopted.subtype === "session_created" &&
      typeof adopted.sessionId === "string"
        ? adopted.sessionId
        : undefined;
    if (!adoptedBridgeSessionId) {
      throw new Error("Bridge failed to adopt the active canary turn");
    }
    await client.waitFor(
      (message) =>
        message.type === "status" &&
        message.sessionId === adoptedBridgeSessionId &&
        message.status === "running",
      30_000,
      "authoritative running status after active adoption",
    );
    const completion = await client.waitFor(
      (message) =>
        message.type === "result" &&
        message.sessionId === adoptedBridgeSessionId,
      180_000,
      "adopted active turn completion",
    );
    if (
      completion.subtype === "error" ||
      !JSON.stringify(completion).includes("ACTIVE_PILOT_END")
    ) {
      throw new Error("Adopted active turn did not complete correctly");
    }
    await waitForDiagnostic(
      apiKey,
      (diagnostics) =>
        (diagnostics.events ?? []).some(
          (event) =>
            event.method === "turn/completed" &&
            event.threadId === normalizedThreadId &&
            event.turnId === activeTurnId,
        ),
      "matching completion after active adoption",
      30_000,
    );
    return {
      bridgeVersion: version.body.version,
      threadId: normalizedThreadId,
      originalBridgeSessionId,
      adoptedBridgeSessionId,
      activeTurnId,
      daemonSocketInode: daemon.socketInode,
      activeStatusObserved: true,
      completionObservedAfterAdoption: true,
      durationMs: Date.now() - startedAt,
    };
  } finally {
    await client.close();
  }
}

async function main(argv: string[]): Promise<void> {
  if (argv[0] === "--root" && argv[1] && argv.length === 2) {
    console.log(JSON.stringify(await runSharedRuntimeL0(argv[1])));
    return;
  }
  if (
    argv[0] === "resume-after-restart" &&
    argv[1] === "--root" &&
    argv[2] &&
    argv[3] === "--thread-id" &&
    argv[4] &&
    (argv.length === 5 ||
      (argv.length === 7 && argv[5] === "--expected-socket-inode"))
  ) {
    const expectedInode =
      argv.length === 7 ? Number.parseInt(argv[6], 10) : undefined;
    if (
      expectedInode !== undefined &&
      (!Number.isSafeInteger(expectedInode) || expectedInode < 0)
    ) {
      throw new Error("Expected socket inode must be a non-negative integer");
    }
    console.log(
      JSON.stringify(
        await runSharedRuntimeRestartProbe(argv[2], argv[4], expectedInode),
      ),
    );
    return;
  }
  if (
    argv[0] === "active-adoption" &&
    argv[1] === "--root" &&
    argv[2] &&
    argv[3] === "--thread-id" &&
    argv[4] &&
    (argv.length === 5 ||
      (argv.length === 7 && argv[5] === "--expected-socket-inode"))
  ) {
    const expectedInode =
      argv.length === 7 ? Number.parseInt(argv[6], 10) : undefined;
    if (
      expectedInode !== undefined &&
      (!Number.isSafeInteger(expectedInode) || expectedInode < 0)
    ) {
      throw new Error("Expected socket inode must be a non-negative integer");
    }
    console.log(
      JSON.stringify(
        await runSharedRuntimeActiveAdoptionProbe(
          argv[2],
          argv[4],
          expectedInode,
        ),
      ),
    );
    return;
  }
  throw new Error(
    "Usage: codex-shared-runtime-l0 --root <pilot-root> | resume-after-restart|active-adoption --root <pilot-root> --thread-id <thread-id> [--expected-socket-inode <inode>]",
  );
}

const isDirectExecution =
  process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1];
if (isDirectExecution) {
  main(process.argv.slice(2)).catch((error) => {
    console.error(
      `[pilot-l0] ${error instanceof Error ? error.message : String(error)}`,
    );
    process.exitCode = 1;
  });
}
