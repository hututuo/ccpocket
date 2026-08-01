import type { ServerMessage } from "./parser.js";
import { normalizePushLocale, t, type PushLocale } from "./push-i18n.js";
import type { BackgroundNotificationMessage } from "./background-delivery-protocol.js";
import type { CodexActionBrokerRuntimeRequest } from "./codex-action-broker-runtime.js";

export const BACKGROUND_PROGRESS_MIN_INTERVAL_MS = 45_000;
export const BACKGROUND_NOTIFICATION_MAX_TRACKED_SESSIONS = 256;
export const BACKGROUND_NOTIFICATION_MAX_PERMISSION_IDS_PER_SESSION = 128;
export const BACKGROUND_NOTIFICATION_MAX_CODEX_REQUEST_IDS = 2_048;

const DEFAULT_ENABLED_EVENTS = new Set([
  "approval_required",
  "ask_user_question",
  "session_completed",
  "session_failed",
]);

export interface BackgroundNotificationPolicy {
  locale: PushLocale;
  privacyMode: boolean;
  enabledEventTypes: Set<string>;
}

export interface BackgroundNotificationProjectionState {
  progressBySession: Map<string, { lastSentAt: number; lastToolKey: string }>;
  permissionToolUsesBySession: Map<string, Set<string>>;
  codexActionRequestIds: Set<string>;
}

export interface BackgroundNotificationContext {
  deliveryId: string;
  sessionId: string;
  provider: "claude" | "codex";
  providerSessionId?: string;
  bridgeInstanceId?: string;
  codexSourceId?: string;
  label: string;
  now?: number;
}

export function createBackgroundNotificationPolicy(input?: {
  locale?: string;
  privacyMode?: boolean;
  enabledEventTypes?: string[];
}): BackgroundNotificationPolicy {
  return {
    locale: normalizePushLocale(input?.locale),
    privacyMode: input?.privacyMode ?? false,
    enabledEventTypes: new Set(
      input?.enabledEventTypes ?? DEFAULT_ENABLED_EVENTS,
    ),
  };
}

export function createBackgroundNotificationProjectionState(): BackgroundNotificationProjectionState {
  return {
    progressBySession: new Map(),
    permissionToolUsesBySession: new Map(),
    codexActionRequestIds: new Set(),
  };
}

function addBoundedSetValue(
  values: Set<string>,
  value: string,
  maximum: number,
): void {
  // Refresh insertion order so frequently observed live entries survive
  // bounded eviction. These sets are notification dedupe hints, not product
  // state; eviction can at worst permit a later duplicate notification.
  values.delete(value);
  values.add(value);
  while (values.size > maximum) {
    const oldest = values.values().next().value as string | undefined;
    if (oldest === undefined) break;
    values.delete(oldest);
  }
}

function setBoundedSessionValue<T>(
  values: Map<string, T>,
  sessionId: string,
  value: T,
): void {
  values.delete(sessionId);
  values.set(sessionId, value);
  while (values.size > BACKGROUND_NOTIFICATION_MAX_TRACKED_SESSIONS) {
    const oldest = values.keys().next().value as string | undefined;
    if (oldest === undefined) break;
    values.delete(oldest);
  }
}

/**
 * Project one shared-runtime Codex request without exposing request bodies.
 *
 * The exact broker fence is data, not authority: Mobile must still fetch the
 * canonical scoped snapshot and use the CAB responder before any mutation.
 */
export function projectCodexActionBackgroundNotification(
  request: CodexActionBrokerRuntimeRequest,
  context: BackgroundNotificationContext,
  policy: BackgroundNotificationPolicy,
  state: BackgroundNotificationProjectionState,
): BackgroundNotificationMessage | null {
  const dedupeKey = `${request.authorityGeneration}\u0000${request.opaqueRequestId}`;
  if (request.state === "resolved" || request.state === "expired") {
    state.codexActionRequestIds.delete(dedupeKey);
    return null;
  }
  if (request.state !== "pending" || !request.live) return null;
  if (state.codexActionRequestIds.has(dedupeKey)) return null;

  const allowedActions = [...(request.allowedActions ?? [])].sort();
  const supportsBinaryDecision =
    allowedActions.includes("approve") || allowedActions.includes("reject");
  const asksForInput =
    request.kind === "user_input" || request.kind === "mcp_elicitation";
  const eventType =
    asksForInput && !supportsBinaryDecision
      ? "ask_user_question"
      : "approval_required";
  if (!policy.enabledEventTypes.has(eventType)) return null;

  addBoundedSetValue(
    state.codexActionRequestIds,
    dedupeKey,
    BACKGROUND_NOTIFICATION_MAX_CODEX_REQUEST_IDS,
  );
  const privacy = policy.privacyMode;
  const label = privacy ? "" : context.label;
  const toolName = privacy ? undefined : request.toolName?.trim();
  const titleBase = t(
    policy.locale,
    eventType === "ask_user_question" ? "ask_title" : "approval_title",
  );
  const title = label ? `${titleBase} - ${label}` : titleBase;
  const body =
    eventType === "ask_user_question"
      ? privacy
        ? t(policy.locale, "ask_body_private")
        : t(policy.locale, "ask_default_body")
      : privacy
        ? t(policy.locale, "approval_body_private")
        : t(policy.locale, "approval_body", {
            toolName: toolName || "Codex",
          });
  const data: Record<string, string> = {
    deliveryId: context.deliveryId,
    sessionId: context.sessionId,
    provider: "codex",
    actionPayloadVersion: "2",
    opaqueRequestId: request.opaqueRequestId,
    codexSourceId: request.codexSourceId,
    threadId: request.threadId,
    turnId: request.turnId,
    authorityGeneration: request.authorityGeneration,
    allowedActions: allowedActions.join(","),
    occurredAt: request.observedAt,
    ...notificationDataSourceFields(context),
  };
  if (context.providerSessionId) {
    data.providerSessionId = context.providerSessionId;
  }
  return {
    type: "background_notification_v1",
    deliveryId: context.deliveryId,
    eventType,
    sessionId: context.sessionId,
    provider: "codex",
    title,
    body,
    occurredAt: request.observedAt,
    data,
  };
}

export function projectBackgroundNotification(
  msg: ServerMessage,
  context: BackgroundNotificationContext,
  policy: BackgroundNotificationPolicy,
  state: BackgroundNotificationProjectionState,
): BackgroundNotificationMessage | null {
  const { sessionId, provider } = context;
  const privacy = policy.privacyMode;
  const label = privacy ? "" : context.label;
  const now = context.now ?? Date.now();
  const occurredAt = new Date(now).toISOString();

  if (msg.type === "assistant" && Array.isArray(msg.message.content)) {
    if (!policy.enabledEventTypes.has("session_progress")) return null;
    const toolUse = [...msg.message.content]
      .reverse()
      .find((content) => content.type === "tool_use");
    if (!toolUse || !toolUse.id || !toolUse.name) return null;

    const last = state.progressBySession.get(sessionId);
    const toolKey = `${toolUse.id}:${toolUse.name}`;
    if (
      last?.lastToolKey === toolKey ||
      (last != null &&
        now - last.lastSentAt < BACKGROUND_PROGRESS_MIN_INTERVAL_MS)
    ) {
      return null;
    }
    setBoundedSessionValue(state.progressBySession, sessionId, {
      lastSentAt: now,
      lastToolKey: toolKey,
    });
    const titleBase = t(policy.locale, "progress_title");
    const data: Record<string, string> = {
      deliveryId: context.deliveryId,
      sessionId,
      provider,
      ...notificationDataSourceFields(context),
    };
    if (context.providerSessionId) {
      data.providerSessionId = context.providerSessionId;
    }
    if (!privacy) {
      data.toolUseId = toolUse.id;
      data.toolName = toolUse.name;
    }
    return {
      type: "background_notification_v1",
      deliveryId: context.deliveryId,
      eventType: "session_progress",
      sessionId,
      provider,
      title: label ? `${titleBase} - ${label}` : titleBase,
      body: privacy
        ? t(policy.locale, "progress_body_private")
        : t(policy.locale, "progress_body", { toolName: toolUse.name }),
      occurredAt,
      data,
    };
  }

  if (msg.type === "permission_request") {
    const seen =
      state.permissionToolUsesBySession.get(sessionId) ?? new Set<string>();
    if (seen.has(msg.toolUseId)) return null;
    addBoundedSetValue(
      seen,
      msg.toolUseId,
      BACKGROUND_NOTIFICATION_MAX_PERMISSION_IDS_PER_SESSION,
    );
    setBoundedSessionValue(state.permissionToolUsesBySession, sessionId, seen);

    const isAskUserQuestion = msg.toolName === "AskUserQuestion";
    const isExitPlanMode = msg.toolName === "ExitPlanMode";
    const eventType = isAskUserQuestion
      ? "ask_user_question"
      : "approval_required";
    if (!policy.enabledEventTypes.has(eventType)) return null;

    let questionText: string | undefined;
    if (!privacy && isAskUserQuestion) {
      const questions = msg.input?.questions;
      const firstQuestion =
        Array.isArray(questions) && questions.length > 0
          ? (questions[0] as Record<string, unknown>)?.question
          : undefined;
      if (typeof firstQuestion === "string" && firstQuestion.length > 0) {
        questionText = firstQuestion.slice(0, 120);
      }
    }

    let title: string;
    let body: string;
    if (isExitPlanMode) {
      const titleBase = t(policy.locale, "plan_ready_title");
      title = label ? `${titleBase} - ${label}` : titleBase;
      body = t(policy.locale, "plan_ready_body");
    } else if (isAskUserQuestion) {
      const titleBase = t(policy.locale, "ask_title");
      title = label ? `${titleBase} - ${label}` : titleBase;
      body = privacy
        ? t(policy.locale, "ask_body_private")
        : (questionText ?? t(policy.locale, "ask_default_body"));
    } else {
      const titleBase = t(policy.locale, "approval_title");
      title = label ? `${titleBase} - ${label}` : titleBase;
      body = privacy
        ? t(policy.locale, "approval_body_private")
        : t(policy.locale, "approval_body", { toolName: msg.toolName });
    }
    const data: Record<string, string> = {
      deliveryId: context.deliveryId,
      sessionId,
      provider,
      permissionId: msg.toolUseId,
      ...notificationDataSourceFields(context),
    };
    if (context.providerSessionId) {
      data.providerSessionId = context.providerSessionId;
    }
    if (!privacy) {
      data.toolUseId = msg.toolUseId;
      data.toolName = msg.toolName;
    }
    return {
      type: "background_notification_v1",
      deliveryId: context.deliveryId,
      eventType,
      sessionId,
      provider,
      title,
      body,
      occurredAt,
      data,
    };
  }

  if (msg.type !== "result") {
    return null;
  }
  state.progressBySession.delete(sessionId);
  state.permissionToolUsesBySession.delete(sessionId);
  if (
    msg.subtype === "stopped" ||
    (msg.subtype !== "success" && msg.subtype !== "error")
  ) {
    return null;
  }

  const isSuccess = msg.subtype === "success";
  const eventType = isSuccess ? "session_completed" : "session_failed";
  if (!policy.enabledEventTypes.has(eventType)) return null;

  const pieces: string[] = [];
  if (isSuccess) {
    if (msg.duration != null) pieces.push(`${msg.duration.toFixed(1)}s`);
    if (msg.cost != null) pieces.push(`$${msg.cost.toFixed(4)}`);
  }
  const stats = pieces.length > 0 ? ` (${pieces.join(", ")})` : "";

  let title: string;
  if (privacy) {
    title = isSuccess
      ? t(policy.locale, "task_completed")
      : t(policy.locale, "error_occurred");
  } else if (label) {
    title = isSuccess ? `✅ ${label}` : `❌ ${label}`;
  } else {
    title = isSuccess
      ? t(policy.locale, "task_completed")
      : t(policy.locale, "error_occurred");
  }

  let body: string;
  if (privacy) {
    const privateBody = isSuccess
      ? t(policy.locale, "result_success_body_private")
      : t(policy.locale, "result_error_body_private");
    body = isSuccess ? `${privateBody}${stats}` : privateBody;
  } else if (isSuccess) {
    body = msg.result
      ? `${msg.result.slice(0, 120)}${stats}`
      : `${t(policy.locale, "session_completed")}${stats}`;
  } else {
    body = msg.error
      ? msg.error.slice(0, 120)
      : t(policy.locale, "session_failed");
  }

  const data: Record<string, string> = {
    deliveryId: context.deliveryId,
    sessionId,
    provider,
    ...notificationDataSourceFields(context),
  };
  if (context.providerSessionId) {
    data.providerSessionId = context.providerSessionId;
  }
  if (!privacy) {
    data.subtype = msg.subtype;
    if (msg.stopReason) data.stopReason = msg.stopReason;
    if (msg.sessionId) data.providerSessionId = msg.sessionId;
  }

  return {
    type: "background_notification_v1",
    deliveryId: context.deliveryId,
    eventType,
    sessionId,
    provider,
    title,
    body,
    occurredAt,
    data,
  };
}

function notificationDataSourceFields(
  context: BackgroundNotificationContext,
): Record<string, string> {
  if (!context.bridgeInstanceId) return {};
  return {
    bridgeInstanceId: context.bridgeInstanceId,
    ...(context.provider === "codex" && context.codexSourceId
      ? { codexSourceId: context.codexSourceId }
      : {}),
  };
}
