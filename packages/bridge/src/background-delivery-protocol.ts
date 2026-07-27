export const BACKGROUND_NOTIFICATION_DELIVERY_CAPABILITY =
  "background_notification_delivery_v1";
export const BACKGROUND_NOTIFICATION_ACK_CAPABILITY =
  "background_notification_delivery_ack_v1";

export const CLIENT_DELIVERY_MODE_STATE_MESSAGE =
  "client_delivery_mode_state_v1";
export const BACKGROUND_NOTIFICATION_MESSAGE = "background_notification_v1";
export const BACKGROUND_NOTIFICATION_ACK_MESSAGE =
  "background_notification_ack_v1";
export const BACKGROUND_ACTIVITY_STATE_MESSAGE =
  "background_activity_state_v1";

export type ClientDeliveryMode = "interactive" | "notifications_only";

export interface SetClientDeliveryModeMessage {
  type: "set_client_delivery_mode";
  mode: ClientDeliveryMode;
  requestId: string;
  locale?: string;
  privacyMode?: boolean;
  enabledEventTypes?: string[];
}

export interface BackgroundNotificationAckMessage {
  type: typeof BACKGROUND_NOTIFICATION_ACK_MESSAGE;
  deliveryId: string;
}

export interface ClientDeliveryModeStateMessage {
  type: typeof CLIENT_DELIVERY_MODE_STATE_MESSAGE;
  mode: ClientDeliveryMode;
  requestId: string;
  activeWorkCount: number;
}

export interface BackgroundNotificationMessage {
  type: typeof BACKGROUND_NOTIFICATION_MESSAGE;
  deliveryId: string;
  eventType:
    | "approval_required"
    | "ask_user_question"
    | "session_completed"
    | "session_failed"
    | "session_progress";
  sessionId: string;
  provider: "claude" | "codex";
  title: string;
  body: string;
  occurredAt: string;
  data: Record<string, string>;
}

export interface BackgroundActivityStateMessage {
  type: typeof BACKGROUND_ACTIVITY_STATE_MESSAGE;
  activeWorkCount: number;
  occurredAt: string;
}

export type BackgroundDeliveryClientMessage =
  | SetClientDeliveryModeMessage
  | BackgroundNotificationAckMessage;
export type BackgroundDeliveryServerMessage =
  | ClientDeliveryModeStateMessage
  | BackgroundNotificationMessage
  | BackgroundActivityStateMessage;

const MAX_REQUEST_ID_LENGTH = 96;
const MAX_DELIVERY_ID_LENGTH = 96;
const MAX_EVENT_TYPES = 16;
const MAX_EVENT_TYPE_LENGTH = 64;

/**
 * Parse only this feature's client message.
 *
 * `undefined` means that another protocol owns the message, while `null`
 * means this feature owns the type but the payload is malformed.
 */
export function parseBackgroundDeliveryClientMessage(
  value: Record<string, unknown>,
): BackgroundDeliveryClientMessage | null | undefined {
  if (value.type === BACKGROUND_NOTIFICATION_ACK_MESSAGE) {
    if (
      Object.keys(value).some(
        (key) => key !== "type" && key !== "deliveryId",
      ) ||
      typeof value.deliveryId !== "string" ||
      value.deliveryId.length < 1 ||
      value.deliveryId.length > MAX_DELIVERY_ID_LENGTH
    ) {
      return null;
    }
    return value as unknown as BackgroundNotificationAckMessage;
  }
  if (value.type !== "set_client_delivery_mode") return undefined;
  const allowedKeys = new Set([
    "type",
    "mode",
    "requestId",
    "locale",
    "privacyMode",
    "enabledEventTypes",
  ]);
  if (Object.keys(value).some((key) => !allowedKeys.has(key))) return null;
  if (
    value.mode !== "interactive" &&
    value.mode !== "notifications_only"
  ) {
    return null;
  }
  if (
    typeof value.requestId !== "string" ||
    value.requestId.length < 1 ||
    value.requestId.length > MAX_REQUEST_ID_LENGTH
  ) {
    return null;
  }
  if (
    value.locale !== undefined &&
    (typeof value.locale !== "string" ||
      value.locale.length < 1 ||
      value.locale.length > 32)
  ) {
    return null;
  }
  if (
    value.privacyMode !== undefined &&
    typeof value.privacyMode !== "boolean"
  ) {
    return null;
  }
  if (value.enabledEventTypes !== undefined) {
    if (
      !Array.isArray(value.enabledEventTypes) ||
      value.enabledEventTypes.length > MAX_EVENT_TYPES ||
      value.enabledEventTypes.some(
        (eventType) =>
          typeof eventType !== "string" ||
          eventType.length < 1 ||
          eventType.length > MAX_EVENT_TYPE_LENGTH,
      )
    ) {
      return null;
    }
  }
  return value as unknown as SetClientDeliveryModeMessage;
}
