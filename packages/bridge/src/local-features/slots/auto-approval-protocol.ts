import {
  hasOnlyLocalFeatureKeys,
  validLocalFeatureId,
  type LocalFeatureProtocolContribution,
} from "../protocol-slot.js";

export const AUTO_APPROVAL_STATE_CAPABILITY =
  "auto_approval_state_v1" as const;
export const AUTO_APPROVAL_SUPERVISION_CAPABILITY =
  "auto_approval_supervision_state_v1" as const;

export type AutoApprovalClientMessage =
  | {
      type: "get_auto_approval_state";
      sessionId: string;
      requestId: string;
    }
  | {
      type: "set_auto_approval";
      sessionId: string;
      requestId: string;
      enabled: boolean;
    }
  | {
      type: "disable_all_auto_approvals";
      sessionId: string;
      requestId: string;
    }
  | {
      type: "import_legacy_auto_approvals";
      sessionId: string;
      requestId: string;
      providerSessionIds: string[];
    };

export type AutoApprovalStateReason =
  | "query"
  | "updated"
  | "disabled_all"
  | "legacy_imported"
  | "auto_approved";

export interface AutoApprovalStateMessage {
  type: typeof AUTO_APPROVAL_STATE_CAPABILITY;
  requestId?: string;
  sessionId?: string;
  providerSessionId?: string;
  enabled?: boolean;
  enabledConversationCount: number;
  approvedCount?: number;
  supervisionAvailable?: boolean;
  unavailableReason?: "external_app_server" | "unsupported_session";
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

export const autoApprovalProtocolContribution:
  LocalFeatureProtocolContribution<
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
      const commonKeys = ["type", "sessionId", "requestId"] as const;
      if (
        !validLocalFeatureId(message.sessionId, 256) ||
        !validLocalFeatureId(message.requestId, 128)
      ) {
        return null;
      }

      switch (message.type) {
        case "get_auto_approval_state":
        case "disable_all_auto_approvals":
          return hasOnlyLocalFeatureKeys(message, commonKeys)
            ? {
                type: message.type,
                sessionId: message.sessionId,
                requestId: message.requestId,
              }
            : null;
        case "import_legacy_auto_approvals": {
          if (
            !hasOnlyLocalFeatureKeys(message, [
              ...commonKeys,
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
          return {
            type: message.type,
            sessionId: message.sessionId,
            requestId: message.requestId,
            providerSessionIds: [...new Set(message.providerSessionIds)],
          };
        }
        case "set_auto_approval":
          return hasOnlyLocalFeatureKeys(message, [...commonKeys, "enabled"]) &&
            typeof message.enabled === "boolean"
            ? {
                type: message.type,
                sessionId: message.sessionId,
                requestId: message.requestId,
                enabled: message.enabled,
              }
            : null;
      }
    },
  };
