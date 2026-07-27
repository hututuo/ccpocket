import { createHash, randomUUID } from "node:crypto";
import type { CodexProcess, CodexStartOptions } from "../codex-process.js";
import type { ServerMessage } from "../parser.js";
import type {
  LocalFeatureClientMessage,
  SideChatEventMessage,
  SideChatMessagePayload,
} from "./protocol.js";
import type {
  LocalFeatureHandleContext,
  LocalFeatureHandler,
  LocalFeatureRuntime,
  LocalFeatureSession,
} from "./runtime.js";

const SIDE_CHAT_CAPABILITY = "side_chat_event";
const MAX_PENDING_INPUTS = 32;
const MAX_PENDING_INPUT_CHARS = 200_000;
const MAX_SIDE_CHATS_PER_CLIENT = 4;
const MAX_SIDE_CHATS_GLOBAL = 8;
const MAX_IDEMPOTENCY_ENTRIES = 256;
const MAX_MESSAGE_CHARS = 100_000;
const MAX_STREAM_TRANSMITTED_CHARS = 2_000_000;
const STREAM_FLUSH_MS = 75;
const OPEN_TIMEOUT_MS = 10_000;

type SideChatClientMessage = Extract<
  LocalFeatureClientMessage,
  {
    type:
      | "open_side_chat"
      | "side_chat_input"
      | "side_chat_permission_response"
      | "side_chat_answer"
      | "side_chat_interrupt"
      | "close_side_chat";
  }
>;

interface SideChatParentSession extends LocalFeatureSession {
  status?: string;
  codexQueuedInput?: unknown;
  projectPath?: string;
  worktreePath?: string;
  codexSettings?: {
    profile?: string;
    approvalPolicy?: string;
    approvalsReviewer?: string;
    codexPermissionsMode?: string;
    sandboxMode?: string;
    model?: string;
    modelReasoningEffort?: string;
    serviceTier?: string;
    networkAccessEnabled?: boolean;
    webSearchMode?: string;
    additionalWritableRoots?: string[];
  };
}

interface PendingSideChatInput {
  requestId: string;
  clientMessageId: string;
  text: string;
}

interface AcceptedSideChatInput {
  requestId: string;
  textDigest: string;
  delivered: boolean;
}

interface SideChatRecord {
  owner: object;
  runtime: LocalFeatureRuntime;
  parentSessionId: string;
  sideChatId: string;
  process: CodexProcess;
  openRequestId: string;
  opened: boolean;
  openTimer?: NodeJS.Timeout;
  closed: boolean;
  inputReady: boolean;
  pendingInputs: PendingSideChatInput[];
  activeInput?: PendingSideChatInput;
  pendingPermissions: Map<string, string>;
  pendingQuestions: Set<string>;
  acceptedInputs: Map<string, AcceptedSideChatInput>;
  acceptedRequestIds: Map<string, string>;
  streamMessageId?: string;
  streamText: string;
  streamTransmittedChars: number;
  streamFlushTimer?: NodeJS.Timeout;
  listeners: {
    message: (message: ServerMessage) => void;
    inputReady: () => void;
    exit: (code: number | null) => void;
  };
}

class SideChatFeatureError extends Error {
  constructor(
    readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "SideChatFeatureError";
  }
}

/**
 * Owner-scoped side chat runtime.
 *
 * Child Codex processes deliberately live here instead of SessionManager, so
 * they never enter the normal session list, history, broadcasts, or idle
 * eviction. The only shared state with the parent is its existing cwd/worktree
 * and its no-more-permissive Codex settings.
 */
export class SideChatFeatureHandler implements LocalFeatureHandler {
  readonly messageTypes = [
    "open_side_chat",
    "side_chat_input",
    "side_chat_permission_response",
    "side_chat_answer",
    "side_chat_interrupt",
    "close_side_chat",
  ] as const;

  private readonly recordsByClient = new Map<
    object,
    Map<string, SideChatRecord>
  >();
  private shuttingDown = false;

  async handle(
    message: LocalFeatureClientMessage,
    context: LocalFeatureHandleContext,
  ): Promise<void> {
    if (!isSideChatClientMessage(message)) return;
    const isOwnerCleanup =
      message.type === "side_chat_interrupt" ||
      message.type === "close_side_chat";
    if (
      !isOwnerCleanup &&
      !context.runtime.supports(context.client, SIDE_CHAT_CAPABILITY)
    ) {
      context.runtime.send(context.client, {
        type: "error",
        errorCode: "unsupported_capability",
        message: "Side chat capability was not negotiated",
      });
      return;
    }

    switch (message.type) {
      case "open_side_chat":
        await this.open(message, context);
        return;
      case "side_chat_input":
        this.acceptInput(message, context);
        return;
      case "side_chat_permission_response":
        this.resolvePermission(message, context);
        return;
      case "side_chat_answer":
        this.answerQuestion(message, context);
        return;
      case "side_chat_interrupt":
        this.interrupt(message, context);
        return;
      case "close_side_chat":
        this.closeRequested(message, context);
        return;
    }
  }

  capabilitiesChanged(client: object): void {
    const records = this.recordsByClient.get(client);
    if (!records || records.size === 0) return;
    const first = records.values().next().value as SideChatRecord | undefined;
    if (first?.runtime.supports(client, SIDE_CHAT_CAPABILITY)) return;
    for (const record of [...records.values()]) {
      this.teardown(record, { notify: false, stopProcess: true });
    }
  }

  disconnect(client: object): void {
    const records = this.recordsByClient.get(client);
    if (records) {
      for (const record of [...records.values()]) {
        this.teardown(record, { notify: false, stopProcess: true });
      }
    }
    this.recordsByClient.delete(client);
  }

  close(): void {
    this.shuttingDown = true;
    for (const records of [...this.recordsByClient.values()]) {
      for (const record of [...records.values()]) {
        this.teardown(record, { notify: false, stopProcess: true });
      }
    }
    this.recordsByClient.clear();
  }

  private async open(
    message: Extract<SideChatClientMessage, { type: "open_side_chat" }>,
    context: LocalFeatureHandleContext,
  ): Promise<void> {
    if (this.shuttingDown || context.signal.aborted) {
      this.sendError(
        context,
        message,
        "bridge_shutting_down",
        "Bridge is shutting down",
      );
      return;
    }

    const existing = this.recordsByClient
      .get(context.client)
      ?.get(message.parentSessionId);
    if (existing && !existing.closed) {
      // Reconnect/retry requests attach to the same owner-scoped child rather
      // than creating a duplicate process. The latest request owns the reply.
      existing.openRequestId = message.requestId;
      if (existing.opened) this.sendOpened(existing);
      return;
    }

    const session = asSideChatParentSession(
      context.runtime.getSession(message.parentSessionId),
    );
    const parent = session ? asSideChatParentProcess(session) : null;
    const parentThreadId = session
      ? context.runtime.getCodexThreadId(session)
      : undefined;
    const cwd = session ? sessionCwd(session) : null;
    const createChild = context.runtime.createDedicatedCodexProcess;
    if (!session || !parent || !parentThreadId || !cwd) {
      this.sendError(
        context,
        message,
        "parent_session_not_found",
        "Active Codex parent session not found",
      );
      return;
    }
    if (session.status !== "idle" || session.codexQueuedInput != null) {
      this.sendError(
        context,
        message,
        "parent_session_busy",
        "Parent Codex session must be idle with no queued input",
      );
      return;
    }
    if (!createChild) {
      this.sendError(
        context,
        message,
        "side_chat_unavailable",
        "Side chat process factory is unavailable",
      );
      return;
    }
    const clientCount = this.recordsByClient.get(context.client)?.size ?? 0;
    if (clientCount >= MAX_SIDE_CHATS_PER_CLIENT) {
      this.sendError(
        context,
        message,
        "side_chat_client_limit",
        "This client has reached the side chat process limit",
      );
      return;
    }
    if (this.recordCount() >= MAX_SIDE_CHATS_GLOBAL) {
      this.sendError(
        context,
        message,
        "side_chat_global_limit",
        "Bridge has reached the side chat process limit",
      );
      return;
    }

    try {
      const sideChatId = randomUUID();
      const child = createChild();
      if (child === parent) {
        throw new SideChatFeatureError(
          "side_chat_factory_invalid",
          "Side chat process factory returned the parent process",
        );
      }
      const record = this.createRecord({
        owner: context.client,
        runtime: context.runtime,
        parentSessionId: message.parentSessionId,
        sideChatId,
        process: child,
        openRequestId: message.requestId,
      });
      this.storeRecord(record);
      try {
        child.start(
          cwd,
          inheritedStartOptions(session, parent, parentThreadId),
        );
      } catch (error) {
        this.teardown(record, { notify: false, stopProcess: true });
        throw new SideChatFeatureError(
          "side_chat_start_failed",
          `Failed to start side chat: ${errorMessage(error)}`,
        );
      }
      if (!record.opened && !record.closed) {
        record.openTimer = setTimeout(() => {
          if (record.opened || record.closed) return;
          this.sendRecordError(
            record,
            "side_chat_open_timeout",
            "Side chat runtime did not become ready in time",
            record.openRequestId,
          );
          this.teardown(record, { notify: false, stopProcess: true });
        }, OPEN_TIMEOUT_MS);
      }
    } catch (error) {
      if (!context.signal.aborted && !this.shuttingDown) {
        this.sendError(
          context,
          message,
          error instanceof SideChatFeatureError
            ? error.code
            : "side_chat_open_failed",
          errorMessage(error),
        );
      }
    }
  }

  private acceptInput(
    message: Extract<SideChatClientMessage, { type: "side_chat_input" }>,
    context: LocalFeatureHandleContext,
  ): void {
    const record = this.resolveOwnedRecord(message, context);
    if (!record) return;
    const textDigest = digestText(message.text);
    const accepted = record.acceptedInputs.get(message.clientMessageId);
    const requestClientId = record.acceptedRequestIds.get(message.requestId);
    if (
      (accepted &&
        (accepted.requestId !== message.requestId ||
          accepted.textDigest !== textDigest)) ||
      (requestClientId && requestClientId !== message.clientMessageId)
    ) {
      this.sendRecordError(
        record,
        "side_chat_input_conflict",
        "Side chat input identifiers were already used for different content",
        message.requestId,
        message.clientMessageId,
      );
      return;
    }
    if (accepted) {
      this.sendInputAccepted(record, message, !accepted.delivered);
      return;
    }
    if (
      record.pendingInputs.length >= MAX_PENDING_INPUTS ||
      pendingInputChars(record) + message.text.length >
        MAX_PENDING_INPUT_CHARS
    ) {
      this.sendRecordError(
        record,
        "side_chat_queue_full",
        "Side chat input queue is full",
        message.requestId,
        message.clientMessageId,
      );
      return;
    }

    const queued = !record.inputReady || record.pendingInputs.length > 0;
    record.acceptedInputs.set(message.clientMessageId, {
      requestId: message.requestId,
      textDigest,
      delivered: false,
    });
    record.acceptedRequestIds.set(message.requestId, message.clientMessageId);
    trimMap(record.acceptedInputs, MAX_IDEMPOTENCY_ENTRIES);
    trimMap(record.acceptedRequestIds, MAX_IDEMPOTENCY_ENTRIES);
    record.pendingInputs.push({
      requestId: message.requestId,
      clientMessageId: message.clientMessageId,
      text: message.text,
    });
    if (queued) this.sendInputAccepted(record, message, true);
    this.drainInput(record);
  }

  private resolvePermission(
    message: Extract<
      SideChatClientMessage,
      { type: "side_chat_permission_response" }
    >,
    context: LocalFeatureHandleContext,
  ): void {
    const record = this.resolveOwnedRecord(message, context);
    if (!record) return;
    const toolName = record.pendingPermissions.get(message.permissionRequestId);
    if (!toolName) {
      this.sendRecordError(
        record,
        "side_chat_permission_not_found",
        "Side chat permission request is no longer pending",
        message.requestId,
      );
      return;
    }
    record.pendingPermissions.delete(message.permissionRequestId);

    if (message.decision === "allow") {
      record.process.approve(message.permissionRequestId);
    } else if (message.decision === "allow_always") {
      if (toolName === "ExitPlanMode") {
        record.process.approve(message.permissionRequestId);
      } else {
        record.process.approveAlways(message.permissionRequestId);
      }
    } else {
      record.process.reject(message.permissionRequestId);
    }
    this.sendStatus(record, message.requestId);
  }

  private answerQuestion(
    message: Extract<SideChatClientMessage, { type: "side_chat_answer" }>,
    context: LocalFeatureHandleContext,
  ): void {
    const record = this.resolveOwnedRecord(message, context);
    if (!record) return;
    if (!record.pendingQuestions.delete(message.questionRequestId)) {
      this.sendRecordError(
        record,
        "side_chat_question_not_found",
        "Side chat question is no longer pending",
        message.requestId,
      );
      return;
    }
    record.process.answer(message.questionRequestId, message.answer);
    this.sendStatus(record, message.requestId);
  }

  private interrupt(
    message: Extract<SideChatClientMessage, { type: "side_chat_interrupt" }>,
    context: LocalFeatureHandleContext,
  ): void {
    const record = this.resolveOwnedRecord(message, context);
    if (!record) return;
    record.process.interrupt();
    this.sendStatus(record, message.requestId);
  }

  private closeRequested(
    message: Extract<SideChatClientMessage, { type: "close_side_chat" }>,
    context: LocalFeatureHandleContext,
  ): void {
    const record = this.resolveOwnedRecord(message, context);
    if (!record) return;
    this.teardown(record, {
      notify: true,
      stopProcess: true,
      requestId: message.requestId,
    });
  }

  private createRecord(
    params: Omit<
      SideChatRecord,
      | "opened"
      | "openTimer"
      | "closed"
      | "inputReady"
      | "pendingInputs"
      | "pendingPermissions"
      | "pendingQuestions"
      | "acceptedInputs"
      | "acceptedRequestIds"
      | "streamText"
      | "streamTransmittedChars"
      | "streamFlushTimer"
      | "listeners"
    >,
  ): SideChatRecord {
    const record = {
      ...params,
      opened: false,
      closed: false,
      inputReady: false,
      pendingInputs: [],
      pendingPermissions: new Map<string, string>(),
      pendingQuestions: new Set<string>(),
      acceptedInputs: new Map<string, AcceptedSideChatInput>(),
      acceptedRequestIds: new Map<string, string>(),
      streamText: "",
      streamTransmittedChars: 0,
      listeners: {} as SideChatRecord["listeners"],
    };

    record.listeners = {
      message: (message) => this.handleChildMessage(record, message),
      inputReady: () => {
        if (record.closed) return;
        this.flushStream(record);
        record.inputReady = true;
        record.activeInput = undefined;
        record.streamMessageId = undefined;
        record.streamText = "";
        record.streamTransmittedChars = 0;
        if (!record.opened) {
          record.opened = true;
          this.clearOpenTimer(record);
          this.sendOpened(record);
        }
        this.drainInput(record);
      },
      exit: () => {
        if (record.closed) return;
        // CodexProcess also emits `exit` for bootstrap failures while its
        // transport may still be alive, so always perform the full stop path.
        this.teardown(record, {
          notify: true,
          stopProcess: true,
          failUndeliveredInputs: true,
        });
      },
    };

    record.process.on("message", record.listeners.message);
    record.process.on("input_ready", record.listeners.inputReady);
    record.process.on("exit", record.listeners.exit);
    return record;
  }

  private handleChildMessage(
    record: SideChatRecord,
    message: ServerMessage,
  ): void {
    if (record.closed) return;
    const requestId = record.activeInput?.requestId ?? record.openRequestId;
    const clientMessageId = record.activeInput?.clientMessageId;

    switch (message.type) {
      case "stream_delta": {
        record.streamMessageId ??= `stream-${randomUUID()}`;
        record.streamText = appendBounded(
          record.streamText,
          message.text,
          MAX_MESSAGE_CHARS,
        );
        this.scheduleStreamFlush(record, requestId, clientMessageId);
        return;
      }
      case "assistant": {
        const text = message.message.content
          .filter((content) => content.type === "text")
          .map((content) => content.text)
          .join("\n");
        if (text) {
          this.clearStreamTimer(record);
          this.sendMessage(
            record,
            {
              id: record.streamMessageId ?? message.message.id,
              role: "assistant",
              text: boundedText(text, MAX_MESSAGE_CHARS),
            },
            requestId,
            clientMessageId,
          );
          record.streamMessageId = undefined;
          record.streamText = "";
        }
        for (const content of message.message.content) {
          if (content.type !== "tool_use") continue;
          this.sendMessage(
            record,
            {
              id: content.id,
              role: "tool",
              text: boundedText(
                formatToolUse(content.name, content.input),
                MAX_MESSAGE_CHARS,
              ),
            },
            requestId,
            clientMessageId,
          );
        }
        return;
      }
      case "tool_result":
        this.sendMessage(
          record,
          {
            id: message.toolUseId,
            role: "tool",
            text: boundedText(message.content, MAX_MESSAGE_CHARS),
          },
          requestId,
          clientMessageId,
        );
        return;
      case "user_input":
        this.sendMessage(
          record,
          {
            id:
              clientMessageId ??
              message.clientMessageId ??
              message.userMessageUuid ??
              randomUUID(),
            role: "user",
            text: boundedText(message.text, MAX_MESSAGE_CHARS),
          },
          requestId,
          clientMessageId,
        );
        return;
      case "status":
        this.sendStatus(record, requestId, clientMessageId, message.status);
        return;
      case "permission_request": {
        if (message.toolName === "ToolSuggestion") {
          record.process.reject(message.toolUseId);
          this.sendRecordError(
            record,
            "side_chat_tool_suggestion_unsupported",
            "Tool suggestions must be installed from the main conversation",
            requestId,
            clientMessageId,
          );
          return;
        }
        const questions = questionPayload(message);
        if (questions) {
          record.pendingQuestions.add(message.toolUseId);
          this.send(record, {
            type: "side_chat_event",
            event: "question",
            parentSessionId: record.parentSessionId,
            sideChatId: record.sideChatId,
            requestId,
            ...(clientMessageId ? { clientMessageId } : {}),
            question: {
              requestId: message.toolUseId,
              questions,
            },
          });
        } else {
          record.pendingPermissions.set(message.toolUseId, message.toolName);
          this.send(record, {
            type: "side_chat_event",
            event: "permission_request",
            parentSessionId: record.parentSessionId,
            sideChatId: record.sideChatId,
            requestId,
            ...(clientMessageId ? { clientMessageId } : {}),
            permission: {
              requestId: message.toolUseId,
              toolName: message.toolName,
              input: message.input,
            },
          });
        }
        return;
      }
      case "permission_resolved":
        record.pendingPermissions.delete(message.toolUseId);
        record.pendingQuestions.delete(message.toolUseId);
        return;
      case "error":
        this.sendRecordError(
          record,
          message.errorCode ?? "side_chat_runtime_error",
          message.message,
          requestId,
          clientMessageId,
        );
        return;
      case "result":
        if (message.subtype === "error" || message.error) {
          this.sendRecordError(
            record,
            "side_chat_turn_failed",
            message.error ?? "Side chat turn failed",
            requestId,
            clientMessageId,
          );
        }
        return;
      default:
        return;
    }
  }

  private drainInput(record: SideChatRecord): void {
    if (record.closed || !record.inputReady) return;
    const next = record.pendingInputs.shift();
    if (!next) return;
    record.inputReady = false;
    record.activeInput = next;
    if (record.process.isWaitingForInput === false) {
      // Defend against any provider-internal resolver consumption between the
      // input_ready event and this queue drain. Keep the accepted item queued.
      record.activeInput = undefined;
      record.pendingInputs.unshift(next);
      return;
    }
    this.clearStreamTimer(record);
    record.streamMessageId = undefined;
    record.streamText = "";
    record.streamTransmittedChars = 0;
    try {
      record.process.sendInput(next.text);
      if (record.closed) return;
      const accepted = record.acceptedInputs.get(next.clientMessageId);
      if (accepted?.requestId === next.requestId) accepted.delivered = true;
      this.sendInputAccepted(record, next, false);
    } catch (error) {
      record.inputReady = true;
      record.activeInput = undefined;
      record.acceptedInputs.delete(next.clientMessageId);
      record.acceptedRequestIds.delete(next.requestId);
      this.sendRecordError(
        record,
        "side_chat_input_failed",
        errorMessage(error),
        next.requestId,
        next.clientMessageId,
      );
      this.drainInput(record);
    }
  }

  private teardown(
    record: SideChatRecord,
    options: {
      notify: boolean;
      stopProcess: boolean;
      requestId?: string;
      failUndeliveredInputs?: boolean;
    },
  ): void {
    if (record.closed) return;
    const undeliveredInputs = options.failUndeliveredInputs
      ? this.undeliveredInputs(record)
      : [];
    record.closed = true;
    const records = this.recordsByClient.get(record.owner);
    if (records?.get(record.parentSessionId) === record) {
      records.delete(record.parentSessionId);
      if (records.size === 0) this.recordsByClient.delete(record.owner);
    }

    record.process.off("message", record.listeners.message);
    record.process.off("input_ready", record.listeners.inputReady);
    record.process.off("exit", record.listeners.exit);
    this.clearOpenTimer(record);
    this.clearStreamTimer(record);
    record.pendingInputs.length = 0;
    record.pendingPermissions.clear();
    record.pendingQuestions.clear();
    record.acceptedInputs.clear();
    record.acceptedRequestIds.clear();

    if (options.stopProcess) {
      try {
        record.process.interrupt();
      } catch {
        // Best-effort interruption is immediately followed by process stop.
      }
      try {
        record.process.stop();
      } catch {
        // The record is already detached; a stopped transport cannot emit out.
      }
    }

    for (const input of undeliveredInputs) {
      record.runtime.send(record.owner, {
        type: "side_chat_event",
        event: "error",
        parentSessionId: record.parentSessionId,
        sideChatId: record.sideChatId,
        requestId: input.requestId,
        clientMessageId: input.clientMessageId,
        error: {
          code: "side_chat_input_not_delivered",
          message: "Side chat closed before queued input was delivered",
        },
      });
    }

    if (options.notify) {
      this.send(record, {
        type: "side_chat_event",
        event: "closed",
        parentSessionId: record.parentSessionId,
        sideChatId: record.sideChatId,
        ...(options.requestId ? { requestId: options.requestId } : {}),
      });
    }
  }

  private resolveOwnedRecord(
    message: Exclude<SideChatClientMessage, { type: "open_side_chat" }>,
    context: LocalFeatureHandleContext,
  ): SideChatRecord | null {
    const record = this.recordsByClient
      .get(context.client)
      ?.get(message.parentSessionId);
    if (!record || record.sideChatId !== message.sideChatId || record.closed) {
      this.sendError(
        context,
        message,
        "side_chat_not_found",
        "Side chat not found for this client and parent session",
        message.sideChatId,
      );
      return null;
    }
    return record;
  }

  private storeRecord(record: SideChatRecord): void {
    const records =
      this.recordsByClient.get(record.owner) ?? new Map<string, SideChatRecord>();
    records.set(record.parentSessionId, record);
    this.recordsByClient.set(record.owner, records);
  }

  private recordCount(): number {
    let count = 0;
    for (const records of this.recordsByClient.values()) count += records.size;
    return count;
  }

  private sendOpened(record: SideChatRecord): void {
    this.send(record, {
      type: "side_chat_event",
      event: "opened",
      parentSessionId: record.parentSessionId,
      sideChatId: record.sideChatId,
      requestId: record.openRequestId,
    });
  }

  private sendInputAccepted(
    record: SideChatRecord,
    message: Pick<PendingSideChatInput, "requestId" | "clientMessageId">,
    queued: boolean,
  ): void {
    this.send(record, {
      type: "side_chat_event",
      event: "input_accepted",
      parentSessionId: record.parentSessionId,
      sideChatId: record.sideChatId,
      requestId: message.requestId,
      clientMessageId: message.clientMessageId,
      queued,
    });
  }

  private undeliveredInputs(record: SideChatRecord): PendingSideChatInput[] {
    const inputs = [...record.pendingInputs];
    const activeInput = record.activeInput;
    if (
      activeInput &&
      record.acceptedInputs.get(activeInput.clientMessageId)?.delivered !== true
    ) {
      inputs.unshift(activeInput);
    }
    return inputs;
  }

  private scheduleStreamFlush(
    record: SideChatRecord,
    requestId: string,
    clientMessageId?: string,
  ): void {
    if (
      record.streamFlushTimer ||
      record.streamTransmittedChars >= MAX_STREAM_TRANSMITTED_CHARS
    ) {
      return;
    }
    record.streamFlushTimer = setTimeout(() => {
      record.streamFlushTimer = undefined;
      this.flushStream(record, requestId, clientMessageId);
    }, STREAM_FLUSH_MS);
  }

  private flushStream(
    record: SideChatRecord,
    requestId = record.activeInput?.requestId ?? record.openRequestId,
    clientMessageId = record.activeInput?.clientMessageId,
  ): void {
    if (
      record.closed ||
      !record.streamMessageId ||
      record.streamText.length === 0
    ) {
      return;
    }
    if (
      record.streamTransmittedChars + record.streamText.length >
      MAX_STREAM_TRANSMITTED_CHARS
    ) {
      record.streamTransmittedChars = MAX_STREAM_TRANSMITTED_CHARS;
      return;
    }
    this.sendMessage(
      record,
      {
        id: record.streamMessageId,
        role: "assistant",
        text: record.streamText,
      },
      requestId,
      clientMessageId,
    );
    record.streamTransmittedChars += record.streamText.length;
  }

  private clearStreamTimer(record: SideChatRecord): void {
    if (!record.streamFlushTimer) return;
    clearTimeout(record.streamFlushTimer);
    record.streamFlushTimer = undefined;
  }

  private clearOpenTimer(record: SideChatRecord): void {
    if (!record.openTimer) return;
    clearTimeout(record.openTimer);
    record.openTimer = undefined;
  }

  private send(record: SideChatRecord, message: SideChatEventMessage): void {
    if (record.closed && message.event !== "closed") return;
    record.runtime.send(record.owner, message);
  }

  private sendMessage(
    record: SideChatRecord,
    message: SideChatMessagePayload,
    requestId?: string,
    clientMessageId?: string,
  ): void {
    this.send(record, {
      type: "side_chat_event",
      event: "message",
      parentSessionId: record.parentSessionId,
      sideChatId: record.sideChatId,
      ...(requestId ? { requestId } : {}),
      ...(clientMessageId ? { clientMessageId } : {}),
      message,
    });
  }

  private sendStatus(
    record: SideChatRecord,
    requestId?: string,
    clientMessageId?: string,
    status = record.process.status,
  ): void {
    this.send(record, {
      type: "side_chat_event",
      event: "status",
      parentSessionId: record.parentSessionId,
      sideChatId: record.sideChatId,
      ...(requestId ? { requestId } : {}),
      ...(clientMessageId ? { clientMessageId } : {}),
      status,
    });
  }

  private sendError(
    context: LocalFeatureHandleContext,
    message: SideChatClientMessage,
    code: string,
    detail: string,
    sideChatId?: string,
  ): void {
    context.runtime.send(context.client, {
      type: "side_chat_event",
      event: "error",
      parentSessionId: message.parentSessionId,
      ...(sideChatId ? { sideChatId } : {}),
      requestId: message.requestId,
      ...(message.type === "side_chat_input"
        ? { clientMessageId: message.clientMessageId }
        : {}),
      error: { code, message: detail },
    });
  }

  private sendRecordError(
    record: SideChatRecord,
    code: string,
    detail: string,
    requestId?: string,
    clientMessageId?: string,
  ): void {
    this.send(record, {
      type: "side_chat_event",
      event: "error",
      parentSessionId: record.parentSessionId,
      sideChatId: record.sideChatId,
      ...(requestId ? { requestId } : {}),
      ...(clientMessageId ? { clientMessageId } : {}),
      error: { code, message: detail },
    });
  }
}

function isSideChatClientMessage(
  message: LocalFeatureClientMessage,
): message is SideChatClientMessage {
  return (
    message.type === "open_side_chat" ||
    message.type === "side_chat_input" ||
    message.type === "side_chat_permission_response" ||
    message.type === "side_chat_answer" ||
    message.type === "side_chat_interrupt" ||
    message.type === "close_side_chat"
  );
}

function asSideChatParentProcess(
  session: SideChatParentSession,
): CodexProcess | null {
  if (session.provider !== "codex" || !session.process) return null;
  const process = session.process as Partial<CodexProcess>;
  // approvalPolicy is deliberately not part of this duck-check: it is
  // undefined while the policy is unknown (e.g. a Desktop-resumed thread),
  // and inheritedStartOptions already falls back to "on-request".
  return typeof process.model === "string" &&
    typeof process.approvalsReviewer === "string" &&
    typeof process.serviceTier === "string"
    ? (session.process as CodexProcess)
    : null;
}

function asSideChatParentSession(
  session: LocalFeatureSession | undefined,
): SideChatParentSession | null {
  return session ? (session as SideChatParentSession) : null;
}

function sessionCwd(session: SideChatParentSession): string | null {
  const cwd = session.worktreePath?.trim() || session.projectPath?.trim();
  return cwd ? cwd : null;
}

function inheritedStartOptions(
  session: SideChatParentSession,
  parent: CodexProcess,
  parentThreadId: string,
): CodexStartOptions {
  const settings = session.codexSettings ?? {};
  const approvalPolicy =
    approvalPolicyValue(settings.approvalPolicy) ??
    approvalPolicyValue(parent.approvalPolicy) ??
    "on-request";
  const approvalsReviewer =
    approvalsReviewerValue(settings.approvalsReviewer) ??
    approvalsReviewerValue(parent.approvalsReviewer) ??
    "user";
  const sandboxMode = sandboxModeValue(settings.sandboxMode) ?? "read-only";
  const codexPermissionsMode = codexPermissionsModeValue(
    settings.codexPermissionsMode ?? parent.codexPermissionsMode,
  );
  const model = nonEmpty(settings.model) ?? nonEmpty(parent.model);
  const modelReasoningEffort =
    nonEmpty(settings.modelReasoningEffort) ??
    nonEmpty(parent.modelReasoningEffort);
  const serviceTier =
    nonEmpty(settings.serviceTier) ?? nonEmpty(parent.serviceTier);
  const webSearchMode =
    webSearchModeValue(settings.webSearchMode) ?? "disabled";
  const additionalWritableRoots = Array.isArray(settings.additionalWritableRoots)
    ? settings.additionalWritableRoots.filter(
        (root): root is string =>
          typeof root === "string" && root.trim().length > 0,
      )
    : [];

  return {
    ephemeralForkFromThreadId: parentThreadId,
    ...(nonEmpty(settings.profile)
      ? { profile: settings.profile!.trim() }
      : {}),
    approvalPolicy,
    approvalsReviewer,
    ...(codexPermissionsMode ? { codexPermissionsMode } : {}),
    sandboxMode,
    ...(model ? { model } : {}),
    ...(modelReasoningEffort ? { modelReasoningEffort } : {}),
    ...(serviceTier ? { serviceTier } : {}),
    networkAccessEnabled: settings.networkAccessEnabled === true,
    webSearchMode,
    // Side chat is an ordinary chat surface. Keeping it out of Plan mode also
    // prevents CodexProcess from internally consuming the input resolver.
    collaborationMode: "default",
    ...(additionalWritableRoots.length > 0
      ? { additionalWritableRoots: [...additionalWritableRoots] }
      : {}),
  };
}

function approvalPolicyValue(
  value: unknown,
): CodexStartOptions["approvalPolicy"] | undefined {
  return value === "never" ||
    value === "on-request" ||
    value === "on-failure" ||
    value === "untrusted"
    ? value
    : undefined;
}

function approvalsReviewerValue(
  value: unknown,
): CodexStartOptions["approvalsReviewer"] | undefined {
  return value === "user" ||
    value === "auto_review" ||
    value === "guardian_subagent"
    ? value
    : undefined;
}

function codexPermissionsModeValue(
  value: unknown,
): CodexStartOptions["codexPermissionsMode"] | undefined {
  return value === "default" ||
    value === "autoReview" ||
    value === "fullAccess" ||
    value === "custom"
    ? value
    : undefined;
}

function sandboxModeValue(
  value: unknown,
): CodexStartOptions["sandboxMode"] | undefined {
  return value === "read-only" ||
    value === "workspace-write" ||
    value === "danger-full-access"
    ? value
    : undefined;
}

function webSearchModeValue(
  value: unknown,
): CodexStartOptions["webSearchMode"] | undefined {
  return value === "disabled" || value === "cached" || value === "live"
    ? value
    : undefined;
}

function nonEmpty(value: unknown): string | undefined {
  return typeof value === "string" && value.trim().length > 0
    ? value.trim()
    : undefined;
}

function questionPayload(
  message: Extract<ServerMessage, { type: "permission_request" }>,
): Array<Record<string, unknown>> | null {
  const isQuestion =
    message.toolName === "AskUserQuestion" ||
    message.toolName === "McpElicitation" ||
    Array.isArray(message.input.questions);
  if (!isQuestion) return null;
  if (!Array.isArray(message.input.questions)) return [];
  return message.input.questions
    .filter(
      (question): question is Record<string, unknown> =>
        question !== null && typeof question === "object" && !Array.isArray(question),
    )
    .slice(0, 32)
    .map((question) => ({ ...question }));
}

function formatToolUse(name: string, input: Record<string, unknown>): string {
  let detail = "";
  try {
    detail = JSON.stringify(input);
  } catch {
    detail = "";
  }
  return detail && detail !== "{}" ? `${name}\n${detail}` : name;
}

function boundedText(value: string, maxLength: number): string {
  return value.length <= maxLength ? value : value.slice(0, maxLength);
}

function appendBounded(
  current: string,
  suffix: string,
  maxLength: number,
): string {
  if (current.length >= maxLength) return current;
  return current + suffix.slice(0, maxLength - current.length);
}

function trimMap<K, V>(map: Map<K, V>, maxEntries: number): void {
  while (map.size > maxEntries) {
    const first = map.keys().next();
    if (first.done) return;
    map.delete(first.value);
  }
}

function pendingInputChars(record: SideChatRecord): number {
  return record.pendingInputs.reduce(
    (total, input) => total + input.text.length,
    0,
  );
}

function digestText(text: string): string {
  return createHash("sha256").update(text).digest("hex");
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
