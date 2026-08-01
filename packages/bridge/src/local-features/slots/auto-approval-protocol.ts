import {
  hasOnlyLocalFeatureKeys,
  validLocalFeatureId,
  type LocalFeatureProtocolContribution,
} from "../protocol-slot.js";

export const AUTO_APPROVAL_STATE_CAPABILITY = "auto_approval_state_v1" as const;
export const AUTO_APPROVAL_SUPERVISION_CAPABILITY =
  "auto_approval_supervision_state_v1" as const;

export interface AutoApprovalTargetScope {
  codexSourceId: string;
  providerSessionId: string;
}

type AutoApprovalTargetFields =
  | (AutoApprovalTargetScope & {
      /** Runtime-only correlation. Never used as authorization identity. */
      sessionId?: string;
    })
  | {
      sessionId: string;
      codexSourceId?: never;
      providerSessionId?: never;
    };

type AutoApprovalSourceFields =
  | {
      codexSourceId: string;
      /** Runtime-only correlation. Never used as authorization identity. */
      sessionId?: string;
    }
  | { sessionId: string; codexSourceId?: never };

export type AutoApprovalClientMessage =
  | ({
      type: "get_auto_approval_state";
      requestId: string;
    } & AutoApprovalTargetFields)
  | ({
      type: "set_auto_approval";
      requestId: string;
      enabled: boolean;
    } & AutoApprovalTargetFields)
  | ({
      type: "disable_all_auto_approvals";
      requestId: string;
    } & AutoApprovalSourceFields)
  | ({
      type: "import_legacy_auto_approvals";
      requestId: string;
      providerSessionIds: string[];
    } & AutoApprovalSourceFields);

export type AutoApprovalStateReason =
  "query" | "updated" | "disabled_all" | "legacy_imported" | "auto_approved";

export interface AutoApprovalStateMessage {
  type: typeof AUTO_APPROVAL_STATE_CAPABILITY;
  requestId?: string;
  sessionId?: string;
  codexSourceId?: string;
  providerSessionId?: string;
  enabled?: boolean;
  enabledConversationCount: number;
  approvedCount?: number;
  supervisionAvailable?: boolean;
  supervisionMode?: "action_broker" | "private_legacy";
  /** Legacy broad reason retained for already-shipped Mobile decoders. */
  unavailableReason?: "external_app_server" | "unsupported_session";
  /** Additive exact reason for durable supervision-aware clients. */
  supervisionUnavailableReason?:
    | "external_app_server"
    | "unsupported_session"
    | "writer_lease_unavailable"
    | "action_broker_unavailable";
  reason: AutoApprovalStateReason;
  error?: string;
  errorCode?: string;
}

const CLIENT_TYPES = [
  "get_auto_approval_state",
  "set_auto_approval",
  "disable_all_auto_approvals",
  "import_legacy_auto_approvals",
] as const;

export const autoApprovalProtocolContribution: LocalFeatureProtocolContribution<
  AutoApprovalClientMessage,
  AutoApprovalStateMessage
> = {
  clientTypes: CLIENT_TYPES,
  serverTypes: [AUTO_APPROVAL_STATE_CAPABILITY],
  parseClient(message) {
    if (
      typeof message.type !== "string" ||
      !CLIENT_TYPES.includes(message.type as (typeof CLIENT_TYPES)[number])
    ) {
      return undefined;
    }
    if (!validLocalFeatureId(message.requestId, 128)) return null;

    switch (message.type) {
      case "get_auto_approval_state": {
        const target = parseTargetFields(message);
        return target
          ? { type: message.type, requestId: message.requestId, ...target }
          : null;
      }
      case "disable_all_auto_approvals": {
        const source = parseSourceFields(message);
        return source
          ? { type: message.type, requestId: message.requestId, ...source }
          : null;
      }
      case "import_legacy_auto_approvals": {
        if (
          !hasOnlyLocalFeatureKeys(message, [
            "type",
            "sessionId",
            "requestId",
            "codexSourceId",
            "providerSessionIds",
          ]) ||
          !Array.isArray(message.providerSessionIds) ||
          message.providerSessionIds.length > 512 ||
          !message.providerSessionIds.every((value) =>
            validLocalFeatureId(value, 256),
          )
        ) {
          return null;
        }
        const source = parseSourceFields(message, true);
        if (!source) return null;
        return {
          type: message.type,
          requestId: message.requestId,
          ...source,
          providerSessionIds: [...new Set(message.providerSessionIds)],
        };
      }
      case "set_auto_approval": {
        if (typeof message.enabled !== "boolean") return null;
        const target = parseTargetFields(message, true);
        return target
          ? {
              type: message.type,
              requestId: message.requestId,
              ...target,
              enabled: message.enabled,
            }
          : null;
      }
    }
  },
};

function parseTargetFields(
  message: Record<string, unknown>,
  allowEnabled = false,
): AutoApprovalTargetFields | null {
  if (
    !hasOnlyLocalFeatureKeys(message, [
      "type",
      "sessionId",
      "requestId",
      "codexSourceId",
      "providerSessionId",
      ...(allowEnabled ? (["enabled"] as const) : []),
    ])
  ) {
    return null;
  }
  const sessionId = optionalId(message.sessionId, 256);
  if (message.sessionId !== undefined && !sessionId) return null;
  const hasSource = message.codexSourceId !== undefined;
  const hasProvider = message.providerSessionId !== undefined;
  if (hasSource !== hasProvider) return null;
  if (!hasSource) return sessionId ? { sessionId } : null;
  if (
    !validLocalFeatureId(message.codexSourceId, 128) ||
    !validLocalFeatureId(message.providerSessionId, 256)
  ) {
    return null;
  }
  return {
    ...(sessionId ? { sessionId } : {}),
    codexSourceId: message.codexSourceId,
    providerSessionId: message.providerSessionId,
  };
}

function parseSourceFields(
  message: Record<string, unknown>,
  keysAlreadyChecked = false,
): AutoApprovalSourceFields | null {
  if (
    !keysAlreadyChecked &&
    !hasOnlyLocalFeatureKeys(message, [
      "type",
      "sessionId",
      "requestId",
      "codexSourceId",
    ])
  ) {
    return null;
  }
  const sessionId = optionalId(message.sessionId, 256);
  if (message.sessionId !== undefined && !sessionId) return null;
  const codexSourceId = optionalId(message.codexSourceId, 128);
  if (message.codexSourceId !== undefined && !codexSourceId) return null;
  if (!sessionId && !codexSourceId) return null;
  if (codexSourceId) {
    return {
      codexSourceId,
      ...(sessionId ? { sessionId } : {}),
    };
  }
  return { sessionId: sessionId! };
}

function optionalId(value: unknown, maxLength: number): string | undefined {
  return validLocalFeatureId(value, maxLength) ? value : undefined;
}
