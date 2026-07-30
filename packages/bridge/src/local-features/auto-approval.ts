import { randomUUID } from "node:crypto";
import { chmod, mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import type { ServerMessage } from "../parser.js";
import { CodexProcess } from "../codex-process.js";
import type {
  AutoApprovalClientMessage,
  AutoApprovalStateMessage,
} from "./slots/auto-approval-protocol.js";
import { AUTO_APPROVAL_STATE_CAPABILITY } from "./slots/auto-approval-protocol.js";
import type {
  LocalFeatureHandleContext,
  LocalFeatureHandler,
  LocalFeatureRuntime,
  LocalFeatureSession,
} from "./runtime.js";

const AUTO_APPROVAL_STORE_VERSION = 1;
const MAX_ENABLED_THREADS = 4096;
const MAX_THREAD_ID_LENGTH = 256;

interface AutoApprovalStoreFile {
  version: typeof AUTO_APPROVAL_STORE_VERSION;
  enabledThreadIds: string[];
}

interface AutoApprovalStoreOptions {
  filePath?: string;
}

export class AutoApprovalStore {
  readonly filePath: string;

  private readonly enabledThreadIds = new Set<string>();
  private readonly settingIntents = new Map<
    string,
    { enabled: boolean; generation: number }
  >();
  private mutationTail: Promise<void> = Promise.resolve();
  private loadPromise: Promise<void> | undefined;
  private settingGeneration = 0;
  private disableAllGeneration = 0;
  private disableAllPending = false;
  private configured = false;

  constructor(options: AutoApprovalStoreOptions = {}) {
    this.filePath = options.filePath ?? defaultAutoApprovalStatePath();
  }

  async isActive(threadId: string): Promise<boolean> {
    await this.ensureLoaded();
    return (
      !this.disableAllPending &&
      this.enabledThreadIds.has(threadId) &&
      this.settingIntents.get(threadId)?.enabled !== false
    );
  }

  async visibleState(
    threadId?: string,
  ): Promise<{ enabled?: boolean; enabledConversationCount: number }> {
    await this.ensureLoaded();
    const visible = this.visibleEnabledThreadIds();
    return {
      ...(threadId ? { enabled: visible.has(threadId) } : {}),
      enabledConversationCount: visible.size,
    };
  }

  setEnabled(threadId: string, enabled: boolean): Promise<void> {
    requireThreadId(threadId);
    const generation = ++this.settingGeneration;
    this.settingIntents.set(threadId, { enabled, generation });
    const operation = this.serializeMutation(async () => {
      await this.ensureLoaded();
      const next = new Set(this.enabledThreadIds);
      if (enabled) {
        if (next.size >= MAX_ENABLED_THREADS && !next.has(threadId)) {
          throw new Error("Auto-approval conversation limit reached");
        }
        next.add(threadId);
      } else {
        next.delete(threadId);
      }
      await this.persist(next);
      this.enabledThreadIds.clear();
      for (const value of next) this.enabledThreadIds.add(value);
    });
    return operation.finally(() => {
      if (this.settingIntents.get(threadId)?.generation === generation) {
        this.settingIntents.delete(threadId);
      }
    });
  }

  disableAll(): Promise<void> {
    const generation = ++this.disableAllGeneration;
    this.disableAllPending = true;
    this.settingIntents.clear();
    const operation = this.serializeMutation(async () => {
      await this.ensureLoaded();
      await this.persist(new Set());
      this.enabledThreadIds.clear();
    });
    return operation.finally(() => {
      if (this.disableAllGeneration === generation) {
        this.disableAllPending = false;
      }
    });
  }

  importLegacy(threadIds: readonly string[]): Promise<boolean> {
    for (const threadId of threadIds) requireThreadId(threadId);
    if (threadIds.length > 512) {
      return Promise.reject(new Error("Legacy auto-approval import is too large"));
    }
    return this.serializeMutation(async () => {
      await this.ensureLoaded();
      if (this.configured) return false;
      const next = new Set(threadIds);
      await this.persist(next);
      this.enabledThreadIds.clear();
      for (const value of next) this.enabledThreadIds.add(value);
      return true;
    });
  }

  private visibleEnabledThreadIds(): Set<string> {
    const visible = this.disableAllPending
      ? new Set<string>()
      : new Set(this.enabledThreadIds);
    for (const [threadId, intent] of this.settingIntents) {
      if (intent.enabled) visible.add(threadId);
      else visible.delete(threadId);
    }
    return visible;
  }

  private ensureLoaded(): Promise<void> {
    this.loadPromise ??= this.load();
    return this.loadPromise;
  }

  private async load(): Promise<void> {
    try {
      const decoded = JSON.parse(await readFile(this.filePath, "utf8")) as {
        version?: unknown;
        enabledThreadIds?: unknown;
      };
      if (
        decoded.version !== AUTO_APPROVAL_STORE_VERSION ||
        !Array.isArray(decoded.enabledThreadIds) ||
        decoded.enabledThreadIds.length > MAX_ENABLED_THREADS
      ) {
        throw new Error("Unsupported auto-approval state file");
      }
      for (const value of decoded.enabledThreadIds) {
        requireThreadId(value);
        this.enabledThreadIds.add(value);
      }
      this.configured = true;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
        console.warn(
          `[auto-approval] Ignoring unreadable state: ${errorMessage(error)}`,
        );
        this.configured = true;
      }
      this.enabledThreadIds.clear();
    }
  }

  private serializeMutation<T>(operation: () => Promise<T>): Promise<T> {
    const current = this.mutationTail.then(operation);
    this.mutationTail = current.then(
      () => undefined,
      () => undefined,
    );
    return current;
  }

  private async persist(enabledThreadIds: Set<string>): Promise<void> {
    const data: AutoApprovalStoreFile = {
      version: AUTO_APPROVAL_STORE_VERSION,
      enabledThreadIds: [...enabledThreadIds].sort(),
    };
    const directory = dirname(this.filePath);
    const temporaryPath = `${this.filePath}.tmp-${process.pid}-${randomUUID()}`;
    await mkdir(directory, { recursive: true, mode: 0o700 });
    try {
      await writeFile(temporaryPath, `${JSON.stringify(data, null, 2)}\n`, {
        encoding: "utf8",
        mode: 0o600,
      });
      await rename(temporaryPath, this.filePath);
      await chmod(this.filePath, 0o600).catch(() => {});
      this.configured = true;
    } finally {
      await rm(temporaryPath, { force: true }).catch(() => {});
    }
  }
}

export interface AutoApprovalFeatureOptions {
  store?: AutoApprovalStore;
}

export class AutoApprovalFeatureHandler implements LocalFeatureHandler {
  readonly messageTypes = [
    "get_auto_approval_state",
    "set_auto_approval",
    "disable_all_auto_approvals",
    "import_legacy_auto_approvals",
  ] as const;

  private readonly store: AutoApprovalStore;
  private readonly capableClients = new Set<object>();
  private readonly handledRequests = new WeakMap<CodexProcess, Set<string>>();
  private readonly approvedCounts = new Map<string, number>();

  constructor(
    private readonly runtime: LocalFeatureRuntime,
    options: AutoApprovalFeatureOptions = {},
  ) {
    this.store = options.store ?? new AutoApprovalStore();
  }

  async handle(
    message: AutoApprovalClientMessage,
    context: LocalFeatureHandleContext,
  ): Promise<void> {
    if (!this.supportsClient(context.client)) {
      context.runtime.send(context.client, {
        type: "error",
        errorCode: "unsupported_capability",
        message: "Bridge-owned auto approval was not negotiated",
      });
      return;
    }

    if (message.type === "disable_all_auto_approvals") {
      try {
        await this.store.disableAll();
        const state = await this.buildState({
          requestId: message.requestId,
          sessionId: message.sessionId,
          reason: "disabled_all",
        });
        context.runtime.send(context.client, state);
        await this.broadcastState(
          { sessionId: message.sessionId, reason: "disabled_all" },
          context.client,
        );
      } catch (error) {
        await this.sendFailure(message, context, error);
      }
      return;
    }

    if (message.type === "import_legacy_auto_approvals") {
      try {
        await this.store.importLegacy(message.providerSessionIds);
        const state = await this.buildState({
          requestId: message.requestId,
          sessionId: message.sessionId,
          reason: "legacy_imported",
        });
        context.runtime.send(context.client, state);
        await this.broadcastState(
          { sessionId: message.sessionId, reason: "legacy_imported" },
          context.client,
        );
      } catch (error) {
        await this.sendFailure(message, context, error);
      }
      return;
    }

    const targetResolution = this.resolveTarget(message.sessionId);
    if (!targetResolution.target) {
      const external =
        targetResolution.unavailableReason === "external_app_server";
      await this.sendFailure(
        message,
        context,
        new Error(
          external
            ? "This conversation is owned by an independent Codex app-server; this Bridge cannot observe or answer its approval requests"
            : "Auto approval requires a Bridge-owned Codex conversation",
        ),
        external
          ? "external_app_server_approval_unsupported"
          : "unsupported_session",
        targetResolution.unavailableReason,
      );
      return;
    }
    const target = targetResolution.target;

    try {
      if (message.type === "set_auto_approval") {
        await this.store.setEnabled(target.threadId, message.enabled);
      }
      const state = await this.buildState({
        requestId: message.requestId,
        sessionId: target.session.id,
        providerSessionId: target.threadId,
        reason: message.type === "set_auto_approval" ? "updated" : "query",
      });
      context.runtime.send(context.client, state);
      if (message.type === "set_auto_approval") {
        await this.broadcastState(
          {
            sessionId: target.session.id,
            providerSessionId: target.threadId,
            reason: "updated",
          },
          context.client,
        );
      }
    } catch (error) {
      await this.sendFailure(message, context, error);
    }
  }

  sessionMessage(session: LocalFeatureSession, message: ServerMessage): void {
    if (session.provider !== "codex" || !(session.process instanceof CodexProcess)) {
      return;
    }
    if (message.type === "permission_resolved") {
      this.handledRequests.get(session.process)?.delete(message.toolUseId);
      return;
    }
    if (
      message.type !== "permission_request" ||
      !isAutoApprovablePermission(message)
    ) {
      return;
    }
    const threadId = this.runtime.getCodexThreadId(session);
    if (!threadId) return;
    const handled = this.handledRequests.get(session.process) ?? new Set();
    if (handled.has(message.toolUseId)) return;
    handled.add(message.toolUseId);
    this.handledRequests.set(session.process, handled);
    queueMicrotask(() => {
      void this.autoApprove(session, threadId, message).catch((error) => {
        handled.delete(message.toolUseId);
        console.warn(
          `[auto-approval] Failed to supervise ${message.toolUseId}: ${errorMessage(error)}`,
        );
      });
    });
  }

  capabilitiesChanged(client: object): void {
    if (this.supportsClient(client)) this.capableClients.add(client);
    else this.capableClients.delete(client);
  }

  disconnect(client: object): void {
    this.capableClients.delete(client);
  }

  private async autoApprove(
    session: LocalFeatureSession,
    threadId: string,
    message: Extract<ServerMessage, { type: "permission_request" }>,
  ): Promise<void> {
    const originalProcess = session.process as CodexProcess;
    try {
      if (!(await this.store.isActive(threadId))) return;
      const current = this.runtime.getSession(session.id);
      if (
        current !== session ||
        current.process !== originalProcess ||
        this.runtime.getCodexThreadId(current) !== threadId ||
        !(current.process instanceof CodexProcess)
      ) {
        return;
      }
      const pending = current.process.getPendingPermission(message.toolUseId);
      if (
        !pending ||
        pending.toolName !== message.toolName ||
        !isAutoApprovablePermission({
          type: "permission_request",
          toolUseId: pending.toolUseId,
          toolName: pending.toolName,
          input: pending.input,
        }) ||
        !(await this.store.isActive(threadId))
      ) {
        return;
      }

      current.process.approve(message.toolUseId);
      if (current.process.getPendingPermission(message.toolUseId)) return;
      this.approvedCounts.set(
        threadId,
        (this.approvedCounts.get(threadId) ?? 0) + 1,
      );
      await this.broadcastState({
        sessionId: session.id,
        providerSessionId: threadId,
        reason: "auto_approved",
      });
    } finally {
      this.handledRequests.get(originalProcess)?.delete(message.toolUseId);
    }
  }

  private resolveTarget(sessionId: string): {
    target: { session: LocalFeatureSession; threadId: string } | null;
    unavailableReason?: "external_app_server" | "unsupported_session";
  } {
    const session = this.runtime.getSession(sessionId);
    if (!session || session.provider !== "codex") {
      return { target: null, unavailableReason: "unsupported_session" };
    }
    if (!(session.process instanceof CodexProcess)) {
      return { target: null, unavailableReason: "external_app_server" };
    }
    const threadId = this.runtime.getCodexThreadId(session);
    return threadId
      ? { target: { session, threadId } }
      : { target: null, unavailableReason: "unsupported_session" };
  }

  private supportsClient(client: object): boolean {
    return this.runtime.supports?.(client, AUTO_APPROVAL_STATE_CAPABILITY) ?? false;
  }

  private async buildState(
    fields: Pick<AutoApprovalStateMessage, "reason"> &
      Partial<
        Pick<
          AutoApprovalStateMessage,
          "requestId" | "sessionId" | "providerSessionId"
        >
      >,
  ): Promise<AutoApprovalStateMessage> {
    const visible = await this.store.visibleState(fields.providerSessionId);
    return {
      type: AUTO_APPROVAL_STATE_CAPABILITY,
      ...fields,
      ...visible,
      supervisionAvailable: true,
      ...(fields.providerSessionId
        ? { approvedCount: this.approvedCounts.get(fields.providerSessionId) ?? 0 }
        : {}),
    };
  }

  private async broadcastState(
    fields: Pick<AutoApprovalStateMessage, "reason"> &
      Partial<
        Pick<AutoApprovalStateMessage, "sessionId" | "providerSessionId">
      >,
    excludedClient?: object,
  ): Promise<void> {
    const state = await this.buildState(fields);
    for (const client of this.capableClients) {
      if (client === excludedClient || this.runtime.isClientOpen?.(client) === false) {
        continue;
      }
      this.runtime.send(client, state);
    }
  }

  private async sendFailure(
    message: AutoApprovalClientMessage,
    context: LocalFeatureHandleContext,
    error: unknown,
    errorCode = "state_update_failed",
    unavailableReason?: "external_app_server" | "unsupported_session",
  ): Promise<void> {
    const visible = await this.store.visibleState();
    context.runtime.send(context.client, {
      type: AUTO_APPROVAL_STATE_CAPABILITY,
      requestId: message.requestId,
      sessionId: message.sessionId,
      enabledConversationCount: visible.enabledConversationCount,
      ...(unavailableReason
        ? {
            supervisionAvailable: false,
            unavailableReason,
          }
        : {}),
      reason: message.type === "disable_all_auto_approvals"
        ? "disabled_all"
        : message.type === "import_legacy_auto_approvals"
          ? "legacy_imported"
        : message.type === "set_auto_approval"
          ? "updated"
          : "query",
      errorCode,
      error: errorMessage(error),
    });
  }
}

export function isAutoApprovablePermission(
  message: Extract<ServerMessage, { type: "permission_request" }>,
): boolean {
  switch (message.toolName) {
    case "Bash": {
      const command = message.input.command;
      if (typeof command === "string" && command.trim()) {
        return !shellCommandRequiresManualApproval(command);
      }
      return (
        message.input.networkApprovalContext != null ||
        message.input.proposedNetworkPolicyAmendments != null
      );
    }
    case "FileChange":
    case "Permissions":
    case "ExitPlanMode":
      return true;
    case "McpElicitation":
      return isCanonicalMcpApproval(message.input);
    default:
      return false;
  }
}

export function shellCommandRequiresManualApproval(command: string): boolean {
  const parsed = tokenizeShellCommand(command);
  if (!parsed || parsed.ambiguous) return true;
  return parsed.segments.some((segment) => segmentRequiresManualApproval(segment));
}

interface ParsedShellCommand {
  segments: string[][];
  ambiguous: boolean;
}

function tokenizeShellCommand(command: string): ParsedShellCommand | null {
  const segments: string[][] = [];
  let segment: string[] = [];
  let word = "";
  let started = false;
  let quote: "single" | "double" | null = null;
  let ambiguous = false;

  const pushWord = (): void => {
    if (!started) return;
    segment.push(word);
    word = "";
    started = false;
  };
  const pushSegment = (): void => {
    pushWord();
    if (segment.length > 0) segments.push(segment);
    segment = [];
  };

  for (let index = 0; index < command.length; index += 1) {
    const character = command[index];
    const next = command[index + 1];
    if (quote === "single") {
      if (character === "'") quote = null;
      else word += character;
      started = true;
      continue;
    }
    if (quote === "double") {
      if (character === '"') {
        quote = null;
      } else if (character === "\\" && next !== undefined) {
        word += next;
        index += 1;
      } else {
        if (character === "`" || (character === "$" && next === "(")) {
          ambiguous = true;
        }
        word += character;
      }
      started = true;
      continue;
    }

    if (character === "'") {
      quote = "single";
      started = true;
    } else if (character === '"') {
      quote = "double";
      started = true;
    } else if (character === "\\" && next !== undefined) {
      word += next;
      started = true;
      index += 1;
    } else if (character === "`" || (character === "$" && next === "(")) {
      ambiguous = true;
      word += character;
      started = true;
    } else if (character === "\n" || character === "\r") {
      pushSegment();
    } else if (/\s/.test(character)) {
      pushWord();
    } else if (";|&(){}".includes(character)) {
      pushSegment();
      if ((character === "&" || character === "|") && next === character) {
        index += 1;
      }
    } else if (character === ">" || character === "<") {
      if (/^\d+$/.test(word)) {
        word = "";
        started = false;
      } else {
        pushWord();
      }
      segment.push("__ccpocket_redirection__");
      if (next === character) {
        if (character === "<") ambiguous = true;
        index += 1;
      }
      if (command[index + 1] === "&") {
        index += 1;
        while (/[-0-9]/.test(command[index + 1] ?? "")) index += 1;
      }
    } else {
      word += character;
      started = true;
    }
  }
  if (quote !== null) return null;
  pushSegment();
  return { segments, ambiguous };
}

function segmentRequiresManualApproval(rawWords: string[]): boolean {
  const words: string[] = [];
  for (let index = 0; index < rawWords.length; index += 1) {
    if (rawWords[index] === "__ccpocket_redirection__") {
      index += 1;
      continue;
    }
    words.push(rawWords[index]);
  }
  let index = 0;
  while (index < words.length && isShellAssignment(words[index])) index += 1;
  index = unwrapCommandPrefix(words, index);
  if (index < 0 || index >= words.length) return true;

  const executable = commandBasename(words[index]);
  if (!executable || executable.includes("$") || executable.includes("`")) {
    return true;
  }
  if (DESTRUCTIVE_EXECUTABLES.has(executable) || executable.startsWith("mkfs")) {
    return true;
  }
  const argumentsAfter = words.slice(index + 1);
  if (executable === "git") return dangerousGitArguments(argumentsAfter);
  if (executable === "find") {
    if (argumentsAfter.includes("-delete")) return true;
    const execIndex = argumentsAfter.findIndex(
      (value) => value === "-exec" || value === "-execdir",
    );
    if (execIndex >= 0) {
      const endIndex = argumentsAfter.findIndex(
        (value, candidateIndex) =>
          candidateIndex > execIndex && (value === ";" || value === "+"),
      );
      const nested = argumentsAfter.slice(
        execIndex + 1,
        endIndex < 0 ? undefined : endIndex,
      );
      return nested.length === 0 || segmentRequiresManualApproval(nested);
    }
    return false;
  }
  if (executable === "xargs") {
    const commandIndex = skipWrapperOptions(
      argumentsAfter,
      0,
      new Set([
        "-E",
        "--eof",
        "-I",
        "--replace",
        "-L",
        "--max-lines",
        "-n",
        "--max-args",
        "-P",
        "--max-procs",
        "-s",
        "--max-chars",
        "-d",
        "--delimiter",
      ]),
    );
    return commandIndex < 0
      ? false
      : segmentRequiresManualApproval(argumentsAfter.slice(commandIndex));
  }
  if (executable === "busybox" || executable === "toybox") {
    return (
      argumentsAfter.length === 0 ||
      segmentRequiresManualApproval(argumentsAfter)
    );
  }
  if (SHELL_EXECUTABLES.has(executable)) {
    const commandIndex = shellCommandArgumentIndex(argumentsAfter);
    return commandIndex < 0
      ? true
      : shellCommandRequiresManualApproval(argumentsAfter[commandIndex]);
  }
  return executable === "eval" || executable === "source" || executable === ".";
}

const DESTRUCTIVE_EXECUTABLES = new Set([
  "rm",
  "rmdir",
  "unlink",
  "shred",
  "srm",
  "dd",
  "diskutil",
]);

const SHELL_EXECUTABLES = new Set([
  "sh",
  "bash",
  "zsh",
  "dash",
  "ksh",
  "fish",
]);

function unwrapCommandPrefix(words: string[], start: number): number {
  let index = start;
  while (index < words.length) {
    const executable = commandBasename(words[index]);
    if (executable === "sudo" || executable === "doas") {
      index = skipWrapperOptions(words, index + 1, new Set([
        "-u", "--user", "-g", "--group", "-h", "--host",
        "-p", "--prompt", "-C", "--close-from", "-R", "--chroot",
        "-D", "--chdir",
      ]));
    } else if (executable === "env") {
      index = skipWrapperOptions(words, index + 1, new Set([
        "-u", "--unset", "-C", "--chdir", "-S", "--split-string",
      ]));
      while (index >= 0 && index < words.length && isShellAssignment(words[index])) {
        index += 1;
      }
    } else if (["command", "builtin", "nohup"].includes(executable)) {
      index = skipWrapperOptions(words, index + 1, new Set());
    } else if (executable === "nice") {
      index = skipWrapperOptions(words, index + 1, new Set(["-n", "--adjustment"]));
    } else if (executable === "time") {
      index = skipWrapperOptions(words, index + 1, new Set(["-f", "-o"]));
    } else {
      return index;
    }
    if (index < 0) return -1;
  }
  return index;
}

function skipWrapperOptions(
  words: string[],
  start: number,
  optionsWithValues: Set<string>,
): number {
  let index = start;
  while (index < words.length) {
    const value = words[index];
    if (value === "--") return index + 1;
    if (!value.startsWith("-") || value === "-") return index;
    const option = value.includes("=") ? value.slice(0, value.indexOf("=")) : value;
    if (optionsWithValues.has(option) && !value.includes("=")) {
      index += 2;
    } else {
      index += 1;
    }
  }
  return -1;
}

function dangerousGitArguments(args: string[]): boolean {
  let index = 0;
  while (index < args.length) {
    const value = args[index];
    if (value === "-C" || value === "-c" || value === "--git-dir" || value === "--work-tree") {
      index += 2;
      continue;
    }
    if (value.startsWith("-")) {
      index += 1;
      continue;
    }
    return ["clean", "restore", "checkout"].includes(value) ||
      (value === "reset" && args.slice(index + 1).includes("--hard"));
  }
  return false;
}

function shellCommandArgumentIndex(args: string[]): number {
  for (let index = 0; index < args.length; index += 1) {
    const value = args[index];
    if (value === "-c") return index + 1 < args.length ? index + 1 : -1;
    if (/^-[^-]*c[^-]*$/.test(value)) {
      return index + 1 < args.length ? index + 1 : -1;
    }
    if (!value.startsWith("-")) return -1;
  }
  return -1;
}

function isShellAssignment(value: string): boolean {
  return /^[A-Za-z_][A-Za-z0-9_]*=/.test(value);
}

function commandBasename(value: string): string {
  return value.replace(/\\/g, "/").split("/").pop()?.toLowerCase() ?? "";
}

function isCanonicalMcpApproval(input: Record<string, unknown>): boolean {
  const decisions = input.availableDecisions;
  return (
    input.mode === "form" &&
    Array.isArray(decisions) &&
    decisions.includes("accept") &&
    !("requestedSchema" in input) &&
    !("url" in input) &&
    !("appsNeedingAuth" in input)
  );
}

function requireThreadId(value: unknown): asserts value is string {
  if (
    typeof value !== "string" ||
    value.trim().length === 0 ||
    value.length > MAX_THREAD_ID_LENGTH
  ) {
    throw new Error("Invalid Codex thread ID in auto-approval state");
  }
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function defaultAutoApprovalStatePath(): string {
  const override = process.env.CCPOCKET_AUTO_APPROVAL_STATE_FILE?.trim();
  if (override) return override;
  if (process.env.NODE_ENV === "test") {
    return join(
      tmpdir(),
      `ccpocket-auto-approval-${process.pid}-${randomUUID()}.json`,
    );
  }
  return join(homedir(), ".ccpocket", "auto-approval-v1.json");
}
