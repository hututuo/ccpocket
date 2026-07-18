import type { ServerMessage } from "../../parser.js";
import {
  hasOnlyLocalFeatureKeys,
  validLocalFeatureId,
  validLocalFeatureText,
  type LocalFeatureProtocolContribution,
} from "../protocol-slot.js";

export type ConversationMirrorProvider = "codex" | "claude";

interface ConversationMirrorRequestBase {
  /** Breaking wire changes must use version 2 request/event type names. */
  protocolVersion: 1;
  requestId: string;
  provider: ConversationMirrorProvider;
  providerSessionId: string;
}

type ConversationMirrorSnapshotRequest<
  Type extends
    | "conversation_mirror_probe"
    | "conversation_mirror_sync"
    | "conversation_mirror_watch",
> = ConversationMirrorRequestBase & {
  type: Type;
  projectPath: string;
  knownRevision?: string;
};

export type ConversationMirrorClientMessage =
  | ConversationMirrorSnapshotRequest<"conversation_mirror_probe">
  | ConversationMirrorSnapshotRequest<"conversation_mirror_sync">
  | ConversationMirrorSnapshotRequest<"conversation_mirror_watch">
  | (ConversationMirrorRequestBase & {
      type: "conversation_mirror_unwatch";
    });

export interface ConversationMirrorEntry {
  entryId: string;
  index: number;
  contentHash: string;
  /** A normal ccPocket ServerMessage; no mirror-specific rendering model. */
  message: ServerMessage;
}

export type ConversationMirrorThreadStatus = string | null;

interface ConversationMirrorEventBase {
  type: "conversation_mirror_event_v1";
  requestId: string;
  bridgeInstanceId: string;
  provider: ConversationMirrorProvider;
  providerSessionId: string;
}

export type ConversationMirrorEventMessage =
  | (ConversationMirrorEventBase & {
      /**
       * Additive v1 acknowledgement before the provider read that can produce
       * this request's next snapshot, patch, or not-modified event. A Bridge
       * may repeat it when a long-lived watch starts a later reconciliation.
       */
      event: "accepted";
    })
  | (ConversationMirrorEventBase & {
      event: "probe";
      revision: string;
      entryCount: number;
      totalBytes: number;
      threadStatus: ConversationMirrorThreadStatus;
      notModified: boolean;
    })
  | (ConversationMirrorEventBase & {
      event: "snapshot_begin";
      revision: string;
      entryCount: number;
      pageCount: number;
      totalBytes: number;
      threadStatus: ConversationMirrorThreadStatus;
    })
  | (ConversationMirrorEventBase & {
      event: "snapshot_page";
      revision: string;
      pageIndex: number;
      pageCount: number;
      entries: ConversationMirrorEntry[];
    })
  | (ConversationMirrorEventBase & {
      event: "snapshot_complete";
      revision: string;
      entryCount: number;
      threadStatus: ConversationMirrorThreadStatus;
    })
  | (ConversationMirrorEventBase & {
      event: "watching" | "not_modified";
      revision: string;
      threadStatus: ConversationMirrorThreadStatus;
    })
  | (ConversationMirrorEventBase & {
      event: "patch";
      baseRevision: string;
      revision: string;
      upserts: ConversationMirrorEntry[];
      deletes: string[];
      threadStatus: ConversationMirrorThreadStatus;
    })
  | (ConversationMirrorEventBase & {
      event: "unwatched";
    })
  | (ConversationMirrorEventBase & {
      event: "error";
      errorCode: string;
      error: string;
    });

const SNAPSHOT_TYPES = [
  "conversation_mirror_probe",
  "conversation_mirror_sync",
  "conversation_mirror_watch",
] as const;
const CLIENT_TYPES = [
  ...SNAPSHOT_TYPES,
  "conversation_mirror_unwatch",
] as const;

function validProvider(value: unknown): value is ConversationMirrorProvider {
  return value === "codex" || value === "claude";
}

export const conversationMirrorProtocolContribution:
  LocalFeatureProtocolContribution<
    ConversationMirrorClientMessage,
    ConversationMirrorEventMessage
  > = {
    clientTypes: CLIENT_TYPES,
    serverTypes: ["conversation_mirror_event_v1"],
    parseClient(message) {
      if (
        typeof message.type !== "string" ||
        !CLIENT_TYPES.includes(message.type as (typeof CLIENT_TYPES)[number])
      ) {
        return undefined;
      }

      if (
        message.protocolVersion !== 1 ||
        !validLocalFeatureId(message.requestId, 128) ||
        !validProvider(message.provider) ||
        !validLocalFeatureId(message.providerSessionId, 256)
      ) {
        return null;
      }
      const requestId = message.requestId;
      const provider = message.provider;
      const providerSessionId = message.providerSessionId;

      if (message.type === "conversation_mirror_unwatch") {
        return hasOnlyLocalFeatureKeys(message, [
          "type",
          "protocolVersion",
          "requestId",
          "provider",
          "providerSessionId",
        ])
          ? {
              type: message.type,
              protocolVersion: 1,
              requestId,
              provider,
              providerSessionId,
            }
          : null;
      }

      if (
        !SNAPSHOT_TYPES.includes(
          message.type as (typeof SNAPSHOT_TYPES)[number],
        ) ||
        !hasOnlyLocalFeatureKeys(message, [
          "type",
          "protocolVersion",
          "requestId",
          "provider",
          "providerSessionId",
          "projectPath",
          "knownRevision",
        ]) ||
        !validLocalFeatureText(message.projectPath, 4096, false) ||
        (message.knownRevision !== undefined &&
          !validLocalFeatureId(message.knownRevision, 128))
      ) {
        return null;
      }

      return {
        type: message.type,
        protocolVersion: 1,
        requestId,
        provider,
        providerSessionId,
        projectPath: message.projectPath,
        ...(message.knownRevision !== undefined
          ? { knownRevision: message.knownRevision }
          : {}),
      } as ConversationMirrorClientMessage;
    },
  };
