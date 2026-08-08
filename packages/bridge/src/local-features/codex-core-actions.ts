import {
  CodexCoreActionPreconditionError,
  CodexRpcError,
  type CodexInlineReviewStartResult,
  type CodexMcpServerStatusPage,
  type CodexProcess,
  type CodexRpcRequestOptions,
} from "../codex-process.js";
import type {
  CodexCoreActionsClientMessage,
  CodexMcpServerInfoSummary,
  CodexMcpServerStatusSummary,
  CodexMcpToolSummary,
} from "./slots/codex-core-actions-protocol.js";
import type { LocalFeatureClientMessage } from "./protocol.js";
import type {
  LocalFeatureHandler,
  LocalFeatureHandleContext,
  LocalFeatureSession,
} from "./runtime.js";

const ACTION_TIMEOUT_MS = 15_000;
const MCP_STATUS_TIMEOUT_MS = 12_000;
const MAX_ERROR_MESSAGE_LENGTH = 1024;
const MAX_MCP_SERVERS = 64;
const MAX_MCP_TOOLS_PER_SERVER = 64;
const MAX_MCP_RESPONSE_BYTES = 256 * 1024;
const MAX_NAME_LENGTH = 256;
const MAX_TITLE_LENGTH = 256;
const MAX_VERSION_LENGTH = 128;
const MAX_DESCRIPTION_LENGTH = 512;
const MAX_WEBSITE_URL_LENGTH = 2048;
const MAX_AUTH_STATUS_LENGTH = 64;

type CodexCoreActionProcess = Pick<
  CodexProcess,
  "status" | "compactThread" | "startInlineReview" | "listMcpServerStatus"
> & {
  readonly hasPendingCoreAction?: boolean;
};

export class CodexCoreActionsFeatureHandler implements LocalFeatureHandler {
  readonly messageTypes = [
    "codex_compact_request",
    "codex_review_request",
    "codex_mcp_status_request",
  ] as const;

  private readonly activeActionThreads = new Set<string>();
  private readonly activeMcpClients = new WeakSet<object>();

  async handle(
    message: LocalFeatureClientMessage,
    context: LocalFeatureHandleContext,
  ): Promise<void> {
    if (
      message.type !== "codex_compact_request" &&
      message.type !== "codex_review_request" &&
      message.type !== "codex_mcp_status_request"
    ) {
      return;
    }

    const responseType =
      message.type === "codex_mcp_status_request"
        ? "codex_mcp_status_result"
        : "codex_action_result";
    if (!context.runtime.supports(context.client, responseType)) {
      this.sendUnsupportedCapability(message, context);
      return;
    }

    const session = context.runtime.getSession(message.sessionId);
    const threadId = session
      ? context.runtime.getCodexThreadId(session)
      : undefined;
    if (
      !session ||
      session.provider !== "codex" ||
      !threadId ||
      !isCodexCoreActionProcess(session.process)
    ) {
      this.sendSessionRejected(message, context);
      return;
    }

    if (message.type === "codex_mcp_status_request") {
      await this.handleMcpStatus(message, session.process, context);
      return;
    }
    const action =
      message.type === "codex_compact_request" ? "compact" : "review";
    const mutationBlock = await context.runtime.codexThreadMutationBlock?.(
      session,
      action,
    );
    if (mutationBlock) {
      context.runtime.send(context.client, {
        type: "codex_action_result",
        sessionId: message.sessionId,
        requestId: message.requestId,
        action,
        status: "rejected",
        errorCode: mutationBlock.errorCode,
        message: mutationBlock.message,
      });
      return;
    }
    await this.handleAction(
      message,
      session,
      session.process,
      threadId,
      isSessionBusy(session),
      context,
    );
  }

  disconnect(client: object): void {
    this.activeMcpClients.delete(client);
  }

  private async handleAction(
    message: Extract<
      CodexCoreActionsClientMessage,
      { type: "codex_compact_request" | "codex_review_request" }
    >,
    session: LocalFeatureSession,
    process: CodexCoreActionProcess,
    threadId: string,
    sessionBusy: boolean,
    context: LocalFeatureHandleContext,
  ): Promise<void> {
    const action =
      message.type === "codex_compact_request" ? "compact" : "review";
    if (
      sessionBusy ||
      process.status !== "idle" ||
      process.hasPendingCoreAction === true ||
      this.activeActionThreads.has(threadId)
    ) {
      context.runtime.send(context.client, {
        type: "codex_action_result",
        sessionId: message.sessionId,
        requestId: message.requestId,
        action,
        status: "rejected",
        errorCode: "session_busy",
        message: "Codex must be idle before starting this action.",
      });
      return;
    }

    this.activeActionThreads.add(threadId);
    try {
      const options = rpcOptions(context.signal, ACTION_TIMEOUT_MS);
      let review: CodexInlineReviewStartResult | undefined;
      if (message.type === "codex_compact_request") {
        await process.compactThread(options);
      } else {
        review = await process.startInlineReview(message.target, options);
      }
      try {
        context.runtime.codexCoreActionAccepted?.(session, action);
      } catch (error) {
        // A host-side cache invalidation hook must not turn an action already
        // accepted by Codex into a failed action result.
        console.error(
          "[codex-core-actions] accepted action hook failed:",
          error,
        );
      }
      if (context.signal.aborted) return;
      context.runtime.send(context.client, {
        type: "codex_action_result",
        sessionId: message.sessionId,
        requestId: message.requestId,
        action,
        status: "accepted",
        ...(review
          ? {
              turnId: review.turnId,
              reviewThreadId: review.reviewThreadId,
            }
          : {}),
      });
    } catch (error) {
      if (!context.signal.aborted) {
        this.sendActionError(message, action, error, context);
      }
    } finally {
      this.activeActionThreads.delete(threadId);
    }
  }

  private async handleMcpStatus(
    message: Extract<
      CodexCoreActionsClientMessage,
      { type: "codex_mcp_status_request" }
    >,
    process: CodexCoreActionProcess,
    context: LocalFeatureHandleContext,
  ): Promise<void> {
    if (this.activeMcpClients.has(context.client)) {
      context.runtime.send(context.client, {
        type: "codex_mcp_status_result",
        sessionId: message.sessionId,
        requestId: message.requestId,
        status: "failed",
        servers: [],
        errorCode: "request_in_progress",
        message: "Another MCP status request is already in progress.",
      });
      return;
    }

    this.activeMcpClients.add(context.client);
    try {
      const page = await process.listMcpServerStatus(
        rpcOptions(context.signal, MCP_STATUS_TIMEOUT_MS),
      );
      if (context.signal.aborted) return;
      const sanitized = sanitizeCodexMcpServerStatusPage(page);
      context.runtime.send(context.client, {
        type: "codex_mcp_status_result",
        sessionId: message.sessionId,
        requestId: message.requestId,
        status: "completed",
        servers: sanitized.servers,
        ...(sanitized.truncated ? { serversTruncated: true } : {}),
      });
    } catch (error) {
      if (!context.signal.aborted) {
        const unsupported = isUnsupportedRpc(error);
        context.runtime.send(context.client, {
          type: "codex_mcp_status_result",
          sessionId: message.sessionId,
          requestId: message.requestId,
          status: unsupported ? "unsupported" : "failed",
          servers: [],
          errorCode: unsupported ? "unsupported_backend" : errorCode(error),
          message: boundedErrorMessage(error),
        });
      }
    } finally {
      this.activeMcpClients.delete(context.client);
    }
  }

  private sendActionError(
    message: Extract<
      CodexCoreActionsClientMessage,
      { type: "codex_compact_request" | "codex_review_request" }
    >,
    action: "compact" | "review",
    error: unknown,
    context: LocalFeatureHandleContext,
  ): void {
    const unsupported = isUnsupportedRpc(error);
    const rejected = error instanceof CodexCoreActionPreconditionError;
    context.runtime.send(context.client, {
      type: "codex_action_result",
      sessionId: message.sessionId,
      requestId: message.requestId,
      action,
      status: unsupported ? "unsupported" : rejected ? "rejected" : "failed",
      errorCode: unsupported ? "unsupported_backend" : errorCode(error),
      message: boundedErrorMessage(error),
    });
  }

  private sendSessionRejected(
    message: CodexCoreActionsClientMessage,
    context: LocalFeatureHandleContext,
  ): void {
    if (message.type === "codex_mcp_status_request") {
      context.runtime.send(context.client, {
        type: "codex_mcp_status_result",
        sessionId: message.sessionId,
        requestId: message.requestId,
        status: "failed",
        servers: [],
        errorCode: "session_not_found",
        message: "An active Codex session was not found.",
      });
      return;
    }
    context.runtime.send(context.client, {
      type: "codex_action_result",
      sessionId: message.sessionId,
      requestId: message.requestId,
      action: message.type === "codex_compact_request" ? "compact" : "review",
      status: "rejected",
      errorCode: "session_not_found",
      message: "An active Codex session was not found.",
    });
  }

  private sendUnsupportedCapability(
    message: CodexCoreActionsClientMessage,
    context: LocalFeatureHandleContext,
  ): void {
    if (message.type === "codex_mcp_status_request") {
      context.runtime.send(context.client, {
        type: "codex_mcp_status_result",
        sessionId: message.sessionId,
        requestId: message.requestId,
        status: "unsupported",
        servers: [],
        errorCode: "capability_not_negotiated",
        message: "Codex core actions capability was not negotiated.",
      });
      return;
    }
    context.runtime.send(context.client, {
      type: "codex_action_result",
      sessionId: message.sessionId,
      requestId: message.requestId,
      action: message.type === "codex_compact_request" ? "compact" : "review",
      status: "unsupported",
      errorCode: "capability_not_negotiated",
      message: "Codex core actions capability was not negotiated.",
    });
  }
}

function isCodexCoreActionProcess(
  value: unknown,
): value is CodexCoreActionProcess {
  if (!value || typeof value !== "object") return false;
  const process = value as Record<string, unknown>;
  return (
    typeof process.status === "string" &&
    typeof process.compactThread === "function" &&
    typeof process.startInlineReview === "function" &&
    typeof process.listMcpServerStatus === "function"
  );
}

function isSessionBusy(session: LocalFeatureSession): boolean {
  const runtimeSession = session as LocalFeatureSession & {
    status?: unknown;
    codexQueuedInput?: unknown;
    permissionRestartInProgress?: unknown;
  };
  return (
    (typeof runtimeSession.status === "string" &&
      runtimeSession.status !== "idle") ||
    runtimeSession.codexQueuedInput != null ||
    runtimeSession.permissionRestartInProgress === true
  );
}

function rpcOptions(
  signal: AbortSignal,
  timeoutMs: number,
): CodexRpcRequestOptions {
  return { signal, timeoutMs };
}

function isUnsupportedRpc(error: unknown): boolean {
  return (
    (error instanceof CodexRpcError && error.code === -32601) ||
    /\bmethod not found\b|\bunsupported method\b/i.test(errorMessage(error))
  );
}

function errorCode(error: unknown): string {
  if (error instanceof CodexCoreActionPreconditionError) return error.code;
  if (
    error instanceof CodexRpcError &&
    error.message.includes("invalid response")
  ) {
    return "invalid_response";
  }
  return "request_failed";
}

function boundedErrorMessage(error: unknown): string {
  return truncateText(errorMessage(error), MAX_ERROR_MESSAGE_LENGTH);
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

export function sanitizeCodexMcpServerStatusPage(
  page: CodexMcpServerStatusPage,
): { servers: CodexMcpServerStatusSummary[]; truncated: boolean } {
  const servers: CodexMcpServerStatusSummary[] = [];
  const seenNames = new Set<string>();
  let responseBytes = 0;
  let truncated = page.nextCursor !== null;

  for (const raw of page.data) {
    if (servers.length >= MAX_MCP_SERVERS) {
      truncated = true;
      break;
    }
    const server = sanitizeMcpServer(raw);
    if (!server || seenNames.has(server.name)) {
      truncated = true;
      continue;
    }
    const bytes = Buffer.byteLength(JSON.stringify(server), "utf8");
    if (responseBytes + bytes > MAX_MCP_RESPONSE_BYTES) {
      truncated = true;
      break;
    }
    seenNames.add(server.name);
    responseBytes += bytes;
    servers.push(server);
  }

  if (servers.length < page.data.length) truncated = true;
  return { servers, truncated };
}

function sanitizeMcpServer(value: unknown): CodexMcpServerStatusSummary | null {
  const raw = asRecord(value);
  const name = boundedText(raw?.name, MAX_NAME_LENGTH);
  if (!raw || !name) return null;

  const rawTools = asRecord(raw.tools);
  const toolEntries = rawTools ? Object.entries(rawTools) : [];
  const tools: CodexMcpToolSummary[] = [];
  const seenTools = new Set<string>();
  for (const [mapName, value] of toolEntries) {
    if (tools.length >= MAX_MCP_TOOLS_PER_SERVER) break;
    const tool = asRecord(value);
    const toolName =
      boundedText(tool?.name, MAX_NAME_LENGTH) ??
      boundedText(mapName, MAX_NAME_LENGTH);
    if (!toolName || seenTools.has(toolName)) continue;
    seenTools.add(toolName);
    const title = boundedText(tool?.title, MAX_TITLE_LENGTH);
    const description = boundedText(tool?.description, MAX_DESCRIPTION_LENGTH);
    tools.push({
      name: toolName,
      ...(title ? { title } : {}),
      ...(description ? { description } : {}),
    });
  }

  const serverInfo = sanitizeServerInfo(raw.serverInfo);
  const authStatus =
    boundedText(raw.authStatus, MAX_AUTH_STATUS_LENGTH) ?? "unknown";
  return {
    name,
    authStatus,
    ...(serverInfo ? { serverInfo } : {}),
    tools,
    toolCount: toolEntries.length,
    ...(tools.length < toolEntries.length ? { toolsTruncated: true } : {}),
  };
}

function sanitizeServerInfo(value: unknown): CodexMcpServerInfoSummary | null {
  const raw = asRecord(value);
  const name = boundedText(raw?.name, MAX_NAME_LENGTH);
  const version = boundedText(raw?.version, MAX_VERSION_LENGTH);
  if (!raw || !name || !version) return null;
  const title = boundedText(raw.title, MAX_TITLE_LENGTH);
  const description = boundedText(raw.description, MAX_DESCRIPTION_LENGTH);
  const websiteUrl = safeWebsiteUrl(raw.websiteUrl);
  return {
    name,
    version,
    ...(title ? { title } : {}),
    ...(description ? { description } : {}),
    ...(websiteUrl ? { websiteUrl } : {}),
  };
}

function safeWebsiteUrl(value: unknown): string | undefined {
  const text = boundedText(value, MAX_WEBSITE_URL_LENGTH);
  if (!text) return undefined;
  try {
    const url = new URL(text);
    return url.protocol === "https:" || url.protocol === "http:"
      ? text
      : undefined;
  } catch {
    return undefined;
  }
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function boundedText(value: unknown, maxLength: number): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return trimmed ? truncateText(trimmed, maxLength) : undefined;
}

function truncateText(value: string, maxLength: number): string {
  return value.length <= maxLength ? value : value.slice(0, maxLength);
}
