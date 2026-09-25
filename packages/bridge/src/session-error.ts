import { randomUUID } from "node:crypto";

export type SessionErrorDeliveryDefaults = {
  sessionId: string;
  errorSource?: "provider" | "bridge" | "control" | "transport";
  errorPhase?: string;
};

export type SessionErrorMessage = {
  type: "error";
  message: string;
  sessionId?: string;
  errorCode?: string;
  errorEventId?: string;
  operationId?: string;
  errorSource?: "provider" | "bridge" | "control" | "transport";
  errorPhase?: string;
  [key: string]: unknown;
};

/**
 * Gives every session-owned error one stable delivery identity and an
 * explicit source/phase before it reaches a WebSocket client.  Request-scoped
 * errors without a sessionId are deliberately left untouched.
 */
export function normalizeSessionError<T extends SessionErrorMessage>(
  message: T,
  defaults: SessionErrorDeliveryDefaults,
): T {
  if (message.sessionId && message.sessionId !== defaults.sessionId) {
    return message;
  }
  return {
    ...message,
    sessionId: message.sessionId ?? defaults.sessionId,
    errorCode: message.errorCode ?? "bridge_error",
    errorEventId: message.errorEventId ?? randomUUID(),
    errorSource: message.errorSource ?? defaults.errorSource ?? "bridge",
    errorPhase: message.errorPhase ?? defaults.errorPhase ?? "request",
  } as T;
}
