import type { ServerMessage } from "../../parser.js";
import {
  hasOnlyLocalFeatureKeys,
  validLocalFeatureId,
  type LocalFeatureProtocolContribution,
} from "../protocol-slot.js";

export const CONVERSATION_CONTENT_EVENT_CAPABILITY =
  "conversation_content_event_v1" as const;

export type ConversationContentProvider = "claude" | "codex";

export interface ConversationContentTarget {
  provider: ConversationContentProvider;
  providerSessionId: string;
}

export interface ConversationContentCursor extends ConversationContentTarget {
  revision: string;
}

export type ConversationContentClientMessage =
  | {
      type: "conversation_content_subscribe";
      protocolVersion: 1;
      requestId: string;
      knownRevisions: ConversationContentCursor[];
      focused?: ConversationContentTarget;
    }
  | {
      type: "conversation_content_focus";
      protocolVersion: 1;
      requestId: string;
      subscriptionId: string;
      focused?: ConversationContentTarget;
    }
  | ({
      type: "conversation_content_ack";
      protocolVersion: 1;
      subscriptionId: string;
    } & ConversationContentCursor)
  | {
      type: "conversation_content_unsubscribe";
      protocolVersion: 1;
      requestId: string;
      subscriptionId: string;
    };

export interface ConversationContentEntry {
  entryId: string;
  index: number;
  contentHash: string;
  message: ServerMessage;
}

interface ConversationContentEventBase {
  type: typeof CONVERSATION_CONTENT_EVENT_CAPABILITY;
  subscriptionId: string;
  bridgeInstanceId: string;
}

export type ConversationContentServerMessage =
  | (ConversationContentEventBase & {
      event: "subscribed";
      requestId: string;
      hotConversationLimit: number;
    })
  | (ConversationContentEventBase & {
      event: "focus_applied";
      requestId: string;
      focused?: ConversationContentTarget;
    })
  | (ConversationContentEventBase & {
      event: "unsubscribed";
      requestId: string;
    })
  | (ConversationContentEventBase &
      ConversationContentTarget & {
        event: "snapshot_begin";
        revision: string;
        entryCount: number;
        pageCount: number;
        hasEarlier: boolean;
        sourceEntryCount: number;
      })
  | (ConversationContentEventBase &
      ConversationContentTarget & {
        event: "snapshot_page";
        revision: string;
        pageIndex: number;
        pageCount: number;
        entries: ConversationContentEntry[];
      })
  | (ConversationContentEventBase &
      ConversationContentTarget & {
        event: "snapshot_complete";
        revision: string;
        entryCount: number;
        hasEarlier: boolean;
        sourceEntryCount: number;
      })
  | (ConversationContentEventBase &
      ConversationContentTarget & {
        event: "patch";
        baseRevision: string;
        revision: string;
        upserts: ConversationContentEntry[];
        deletes: string[];
        hasEarlier: boolean;
        sourceEntryCount: number;
      })
  | (ConversationContentEventBase & {
      event: "error";
      requestId?: string;
      provider?: ConversationContentProvider;
      providerSessionId?: string;
      errorCode: string;
      error: string;
    });

const CLIENT_TYPES = [
  "conversation_content_subscribe",
  "conversation_content_focus",
  "conversation_content_ack",
  "conversation_content_unsubscribe",
] as const;

const MAX_KNOWN_REVISIONS = 256;

function validProvider(value: unknown): value is ConversationContentProvider {
  return value === "claude" || value === "codex";
}

function parseTarget(value: unknown): ConversationContentTarget | null {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    return null;
  }
  const target = value as Record<string, unknown>;
  if (
    !hasOnlyLocalFeatureKeys(target, ["provider", "providerSessionId"]) ||
    !validProvider(target.provider) ||
    !validLocalFeatureId(target.providerSessionId, 256)
  ) {
    return null;
  }
  return {
    provider: target.provider,
    providerSessionId: target.providerSessionId,
  };
}

function parseOptionalTarget(
  value: unknown,
): ConversationContentTarget | undefined | null {
  if (value === undefined || value === null) return undefined;
  return parseTarget(value);
}

function parseKnownRevisions(
  value: unknown,
): ConversationContentCursor[] | null {
  if (!Array.isArray(value) || value.length > MAX_KNOWN_REVISIONS) return null;
  const cursors: ConversationContentCursor[] = [];
  const keys = new Set<string>();
  for (const raw of value) {
    if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
      return null;
    }
    const record = raw as Record<string, unknown>;
    const target = parseTarget({
      provider: record.provider,
      providerSessionId: record.providerSessionId,
    });
    if (
      !target ||
      !hasOnlyLocalFeatureKeys(record, [
        "provider",
        "providerSessionId",
        "revision",
      ]) ||
      !validLocalFeatureId(record.revision, 128)
    ) {
      return null;
    }
    const key = `${target.provider}\0${target.providerSessionId}`;
    if (keys.has(key)) return null;
    keys.add(key);
    cursors.push({ ...target, revision: record.revision });
  }
  return cursors;
}

export const conversationContentProtocolContribution: LocalFeatureProtocolContribution<
  ConversationContentClientMessage,
  ConversationContentServerMessage
> = {
  clientTypes: CLIENT_TYPES,
  serverTypes: [CONVERSATION_CONTENT_EVENT_CAPABILITY],
  parseClient(message) {
    if (
      typeof message.type !== "string" ||
      !CLIENT_TYPES.includes(message.type as (typeof CLIENT_TYPES)[number])
    ) {
      return undefined;
    }
    if (message.protocolVersion !== 1) return null;

    if (message.type === "conversation_content_subscribe") {
      const focused = parseOptionalTarget(message.focused);
      const knownRevisions = parseKnownRevisions(message.knownRevisions);
      if (
        !hasOnlyLocalFeatureKeys(message, [
          "type",
          "protocolVersion",
          "requestId",
          "knownRevisions",
          "focused",
        ]) ||
        !validLocalFeatureId(message.requestId, 128) ||
        focused === null ||
        knownRevisions === null
      ) {
        return null;
      }
      return {
        type: message.type,
        protocolVersion: 1,
        requestId: message.requestId,
        knownRevisions,
        ...(focused ? { focused } : {}),
      };
    }

    if (message.type === "conversation_content_focus") {
      const focused = parseOptionalTarget(message.focused);
      if (
        !hasOnlyLocalFeatureKeys(message, [
          "type",
          "protocolVersion",
          "requestId",
          "subscriptionId",
          "focused",
        ]) ||
        !validLocalFeatureId(message.requestId, 128) ||
        !validLocalFeatureId(message.subscriptionId, 128) ||
        focused === null
      ) {
        return null;
      }
      return {
        type: message.type,
        protocolVersion: 1,
        requestId: message.requestId,
        subscriptionId: message.subscriptionId,
        ...(focused ? { focused } : {}),
      };
    }

    if (message.type === "conversation_content_ack") {
      const target = parseTarget({
        provider: message.provider,
        providerSessionId: message.providerSessionId,
      });
      if (
        !hasOnlyLocalFeatureKeys(message, [
          "type",
          "protocolVersion",
          "subscriptionId",
          "provider",
          "providerSessionId",
          "revision",
        ]) ||
        !validLocalFeatureId(message.subscriptionId, 128) ||
        !target ||
        !validLocalFeatureId(message.revision, 128)
      ) {
        return null;
      }
      return {
        type: message.type,
        protocolVersion: 1,
        subscriptionId: message.subscriptionId,
        ...target,
        revision: message.revision,
      };
    }

    if (
      !hasOnlyLocalFeatureKeys(message, [
        "type",
        "protocolVersion",
        "requestId",
        "subscriptionId",
      ]) ||
      !validLocalFeatureId(message.requestId, 128) ||
      !validLocalFeatureId(message.subscriptionId, 128)
    ) {
      return null;
    }
    return {
      type: "conversation_content_unsubscribe",
      protocolVersion: 1,
      requestId: message.requestId,
      subscriptionId: message.subscriptionId,
    };
  },
};
