import type { ConversationContentEntry } from "./conversation-content-protocol.js";
import type { ServerMessage } from "../../parser.js";
import {
  hasOnlyLocalFeatureKeys,
  validLocalFeatureId,
  type LocalFeatureProtocolContribution,
} from "../protocol-slot.js";

export const CONVERSATION_SYNC_V2_CAPABILITY = "conversation_sync_v2" as const;
export const CONVERSATION_WINDOW_COVERAGE_CAPABILITY =
  "conversation_sync_window_coverage_v1" as const;
export const CONVERSATION_SYNC_FOCUS_REFRESH_CAPABILITY =
  "conversation_sync_focus_refresh_v1" as const;
export const CONVERSATION_ITEMS_BY_ID_CAPABILITY =
  "conversation_items_by_id_v1" as const;
export const CONVERSATION_USER_INDEX_CAPABILITY =
  "conversation_user_index_v1" as const;
export const APP_SERVER_STATUS_CAPABILITY = "app_server_status_v1" as const;
export const BRIDGE_IDENTITY_V2_CAPABILITY = "bridge_identity_v2" as const;
export const CONVERSATION_RUNTIME_OVERLAY_CAPABILITY =
  "conversation_runtime_overlay_v1" as const;

export type ConversationRuntimeOverlayMessage = Extract<
  ServerMessage,
  {
    type:
      | "assistant"
      | "result"
      | "error"
      | "guardian_approval"
      | "tool_use_summary";
  }
>;

export type ConversationSyncProvider = "claude" | "codex";

export interface ConversationSyncTarget {
  provider: ConversationSyncProvider;
  providerSessionId: string;
}

export interface ConversationSyncThreadState extends ConversationSyncTarget {
  revision: string;
  /** Client retained this base, but its additive window needs a full replace. */
  forceReplacement?: boolean;
}

export interface ConversationSyncReadWatermark extends ConversationSyncTarget {
  readAt: string;
}

export type ConversationSyncClientMessage =
  | {
      type: "conversation_sync_subscribe";
      protocolVersion: 2;
      requestId: string;
      catalogState?: string;
      statusState?: string;
      threadContentStates: ConversationSyncThreadState[];
      readWatermarks: ConversationSyncReadWatermark[];
      focused?: ConversationSyncTarget;
    }
  | {
      type: "conversation_sync_ack";
      protocolVersion: 2;
      subscriptionId: string;
      sequence: number;
    }
  | (ConversationSyncReadWatermark & {
      type: "conversation_sync_read";
      protocolVersion: 2;
      subscriptionId: string;
    })
  | {
      type: "conversation_sync_focus";
      protocolVersion: 2;
      requestId: string;
      subscriptionId: string;
      focused?: ConversationSyncTarget;
      refresh?: boolean;
    }
  | {
      type: "conversation_sync_unsubscribe";
      protocolVersion: 2;
      requestId: string;
      subscriptionId: string;
    }
  | ({
      type: "conversation_turns_page";
      protocolVersion: 2;
      requestId: string;
      subscriptionId: string;
      cursor?: string;
      limit?: number;
      sortDirection?: "asc" | "desc";
      itemsView?: "summary" | "full";
      projection?: "user_index";
    } & ConversationSyncTarget)
  | ({
      type: "conversation_items_page";
      protocolVersion: 2;
      requestId: string;
      subscriptionId: string;
      turnId?: string;
      toolUseIds?: string[];
      cursor?: string;
      limit?: number;
      sortDirection?: "asc" | "desc";
    } & ConversationSyncTarget);

export interface ConversationSyncCatalogEntry extends ConversationSyncTarget {
  revision: string;
  projectPath: string;
  projectGroupKind?: "desktopProject" | "projectless";
  projectGroupId?: string;
  projectGroupName?: string;
  projectGroupPath?: string;
  projectGroupingSnapshotComplete?: boolean;
  name?: string;
  summary?: string;
  firstPrompt?: string;
  /** Exact provider settings observed from the durable Codex rollout. */
  model?: string;
  modelReasoningEffort?: string;
  serviceTier?: string;
  approvalPolicy?: string;
  approvalsReviewer?: string;
  sandboxMode?: string;
  collaborationMode?: "plan" | "default";
  networkAccessEnabled?: boolean;
  webSearchMode?: string;
  /**
   * True only when omitted Codex settings are authoritative absences rather
   * than fields unavailable from a fast catalog/index read. Older producers
   * omit this marker, which must be treated as an incremental snapshot.
   */
  codexSettingsSnapshotComplete?: boolean;
  createdAt: string;
  modifiedAt: string;
  recencyAt: string;
  availability: "durable" | "ephemeral" | "expired";
  forkedFromThreadId?: string;
  parentThreadId?: string;
}

export type ConversationSyncExecutionHost =
  "bridge" | "desktopAppServer" | "unknown";

export type ConversationSyncControlState =
  | "readOnly"
  | "steerable"
  | "writable"
  | "reconciling"
  | "blocked"
  | "unavailable";

export interface ConversationSyncStatus extends ConversationSyncTarget {
  activity: "idle" | "working" | "compacting" | "systemError" | "unknown";
  attention: "none" | "approval" | "question" | "permission" | "form";
  result: "none" | "completed" | "failed";
  runtimeAttachment: "notLoaded" | "loaded" | "ownedElsewhere";
  source: "appServer" | "bridgeRuntime" | "legacyRollout";
  confidence: "authoritative" | "observed" | "inferred" | "unknown";
  observedAt: string;
  attentionRequestId?: string;
  /** Turn initiator projection; source remains the evidence transport. */
  executionHost?: ConversationSyncExecutionHost;
  /** Exact active provider turn when the current authority can prove it. */
  activeTurnId?: string;
  /** Whether this client may mutate the current authority binding. */
  controlState?: ConversationSyncControlState;
  /** Opaque generation fencing control-plane actions and late observations. */
  authorityGeneration?: string;
}

export interface ConversationSyncNextState {
  catalogState: string;
  statusState: string;
  threadContentStates: ConversationSyncThreadState[];
}

export interface ConversationSyncLatestTurnGap {
  turnId?: string;
  missingEntryCount: number;
  payloadOmitted: boolean;
  firstMissingSourceIndex?: number;
  repair: "items_page" | "turns_page";
}

interface ConversationSyncEventBase {
  type: typeof CONVERSATION_SYNC_V2_CAPABILITY;
  subscriptionId: string;
  bridgeInstanceId: string;
  codexSourceId: string;
  batchId: string;
  sequence: number;
  requestId?: string;
}

export type ConversationSyncServerMessage =
  | {
      /** Capability-advertisement marker; never emitted as a runtime event. */
      type: typeof CONVERSATION_WINDOW_COVERAGE_CAPABILITY;
      supported: true;
    }
  | (ConversationSyncEventBase & {
      event: "sync_begin";
      requestId: string;
      catalogState: string;
      statusState: string;
    })
  | (ConversationSyncEventBase & {
      event: "catalog_changes";
      catalogState: string;
      pageIndex: number;
      pageCount: number;
      created: ConversationSyncCatalogEntry[];
      updated: ConversationSyncCatalogEntry[];
      destroyed: ConversationSyncTarget[];
    })
  | (ConversationSyncEventBase & {
      event: "status_changes";
      statusState: string;
      pageIndex: number;
      pageCount: number;
      changes: ConversationSyncStatus[];
    })
  | (ConversationSyncEventBase &
      ConversationSyncTarget & {
        event: "timeline_page";
        revision: string;
        baseRevision?: string;
        mode: "snapshot" | "patch";
        phase?: "priority" | "recent" | "cold";
        timelineIndex?: number;
        timelineCount?: number;
        pageIndex: number;
        pageCount: number;
        entries: ConversationContentEntry[];
        deletes: string[];
        hasEarlier: boolean;
        turnsNextCursor?: string | null;
        /**
         * True only when this page transaction covers the complete bounded hot
         * window and may replace a previously committed window. Older clients
         * safely ignore this additive field.
         */
        windowComplete?: boolean;
        latestTurnComplete?: boolean;
        latestTurnGap?: ConversationSyncLatestTurnGap;
        sourceEntryCount: number;
      })
  | (ConversationSyncEventBase &
      ConversationSyncTarget & {
        event: "runtime_overlay";
        overlayId: string;
        observedAt: string;
        /** Producer lifecycle fence; changes when observer/runtime is replaced. */
        originGeneration: string;
        /**
         * Exact producer attachment. SessionManager uses its runtime session
         * ID; the shared observer uses its opaque observer generation.
         */
        runtimeSessionId: string;
        /** Authority fence shared with the current status projection. */
        authorityGeneration: string;
        /** Exact provider turn that owns this transient overlay. */
        turnId: string;
        message: ConversationRuntimeOverlayMessage;
      })
  | (ConversationSyncEventBase & {
      event: "sync_checkpoint";
      phase: "priority" | "recent" | "cold";
      hasMore: boolean;
    })
  | (ConversationSyncEventBase & {
      event: "sync_complete";
      nextState: ConversationSyncNextState;
    })
  | (ConversationSyncEventBase & {
      event: "sync_reset";
      scope: "catalog" | "status" | "thread";
      reason: string;
      target?: ConversationSyncTarget;
    })
  | (ConversationSyncEventBase &
      ConversationSyncTarget & {
        event: "turns_page_response";
        requestId: string;
        data: unknown[];
        nextCursor: string | null;
      })
  | (ConversationSyncEventBase &
      ConversationSyncTarget & {
      event: "items_page_response";
      requestId: string;
      turnId?: string;
      data: unknown[];
      nextCursor: string | null;
      /**
       * Compatibility marker for a non-terminal projected page. Current
       * Bridges fail an oversized source item and keep its cursor unchanged
       * instead of presenting a projection as complete.
       */
      pageComplete?: boolean;
      latestTurnGap?: ConversationSyncLatestTurnGap;
      })
  | (ConversationSyncEventBase & {
      event: "focus_applied";
      requestId: string;
      focused?: ConversationSyncTarget;
    })
  | (ConversationSyncEventBase & {
      event: "unsubscribed";
      requestId: string;
    })
  | (ConversationSyncEventBase & {
      event: "error";
      requestId?: string;
      errorCode: string;
      error: string;
      target?: ConversationSyncTarget;
    });

const CLIENT_TYPES = [
  "conversation_sync_subscribe",
  "conversation_sync_ack",
  "conversation_sync_read",
  "conversation_sync_focus",
  "conversation_sync_unsubscribe",
  "conversation_turns_page",
  "conversation_items_page",
] as const;

const MAX_THREAD_STATES = 512;
const MAX_READ_WATERMARKS = 512;
const MAX_PAGE_LIMIT = 200;
const MAX_TOOL_USE_IDS = 8;

function validProvider(value: unknown): value is ConversationSyncProvider {
  return value === "claude" || value === "codex";
}

function parseTarget(value: unknown): ConversationSyncTarget | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const record = value as Record<string, unknown>;
  if (
    !hasOnlyLocalFeatureKeys(record, ["provider", "providerSessionId"]) ||
    !validProvider(record.provider) ||
    !validLocalFeatureId(record.providerSessionId, 256)
  ) {
    return null;
  }
  return {
    provider: record.provider,
    providerSessionId: record.providerSessionId,
  };
}

function parseOptionalTarget(
  value: unknown,
): ConversationSyncTarget | null | undefined {
  if (value === undefined || value === null) return undefined;
  return parseTarget(value);
}

function parseThreadStates(
  value: unknown,
): ConversationSyncThreadState[] | null {
  if (!Array.isArray(value) || value.length > MAX_THREAD_STATES) return null;
  const seen = new Set<string>();
  const states: ConversationSyncThreadState[] = [];
  for (const raw of value) {
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
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
        "forceReplacement",
      ]) ||
      !validLocalFeatureId(record.revision, 128) ||
      (record.forceReplacement !== undefined &&
        typeof record.forceReplacement !== "boolean")
    ) {
      return null;
    }
    const key = targetKey(target);
    if (seen.has(key)) return null;
    seen.add(key);
    states.push({
      ...target,
      revision: record.revision,
      ...(record.forceReplacement === true ? { forceReplacement: true } : {}),
    });
  }
  return states;
}

function parseReadWatermarks(
  value: unknown,
): ConversationSyncReadWatermark[] | null {
  if (!Array.isArray(value) || value.length > MAX_READ_WATERMARKS) return null;
  const seen = new Set<string>();
  const watermarks: ConversationSyncReadWatermark[] = [];
  for (const raw of value) {
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
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
        "readAt",
      ]) ||
      !validIsoDate(record.readAt)
    ) {
      return null;
    }
    const key = targetKey(target);
    if (seen.has(key)) return null;
    seen.add(key);
    watermarks.push({ ...target, readAt: record.readAt });
  }
  return watermarks;
}

function validOptionalState(value: unknown): value is string | undefined {
  return value === undefined || validLocalFeatureId(value, 256);
}

function validOptionalCursor(value: unknown): value is string | undefined {
  return value === undefined || validLocalFeatureId(value, 512);
}

function validOptionalLimit(value: unknown): value is number | undefined {
  return (
    value === undefined ||
    (Number.isSafeInteger(value) &&
      (value as number) > 0 &&
      (value as number) <= MAX_PAGE_LIMIT)
  );
}

function validIsoDate(value: unknown): value is string {
  return (
    typeof value === "string" &&
    value.length <= 64 &&
    Number.isFinite(Date.parse(value))
  );
}

function targetKey(target: ConversationSyncTarget): string {
  return `${target.provider}\0${target.providerSessionId}`;
}

export const conversationSyncV2ProtocolContribution: LocalFeatureProtocolContribution<
  ConversationSyncClientMessage,
  ConversationSyncServerMessage
> = {
  clientTypes: CLIENT_TYPES,
  serverTypes: [
    CONVERSATION_SYNC_V2_CAPABILITY,
    CONVERSATION_WINDOW_COVERAGE_CAPABILITY,
  ],
  parseClient(message) {
    if (
      typeof message.type !== "string" ||
      !CLIENT_TYPES.includes(message.type as (typeof CLIENT_TYPES)[number])
    ) {
      return undefined;
    }
    if (message.protocolVersion !== 2) return null;

    if (message.type === "conversation_sync_subscribe") {
      const focused = parseOptionalTarget(message.focused);
      const threadContentStates = parseThreadStates(
        message.threadContentStates,
      );
      const readWatermarks = parseReadWatermarks(message.readWatermarks);
      if (
        !hasOnlyLocalFeatureKeys(message, [
          "type",
          "protocolVersion",
          "requestId",
          "catalogState",
          "statusState",
          "threadContentStates",
          "readWatermarks",
          "focused",
        ]) ||
        !validLocalFeatureId(message.requestId, 128) ||
        !validOptionalState(message.catalogState) ||
        !validOptionalState(message.statusState) ||
        focused === null ||
        threadContentStates === null ||
        readWatermarks === null
      ) {
        return null;
      }
      return {
        type: "conversation_sync_subscribe",
        protocolVersion: 2,
        requestId: message.requestId,
        ...(message.catalogState ? { catalogState: message.catalogState } : {}),
        ...(message.statusState ? { statusState: message.statusState } : {}),
        threadContentStates,
        readWatermarks,
        ...(focused ? { focused } : {}),
      };
    }

    if (message.type === "conversation_sync_ack") {
      if (
        !hasOnlyLocalFeatureKeys(message, [
          "type",
          "protocolVersion",
          "subscriptionId",
          "sequence",
        ]) ||
        !validLocalFeatureId(message.subscriptionId, 128) ||
        !Number.isSafeInteger(message.sequence) ||
        (message.sequence as number) < 0
      ) {
        return null;
      }
      return {
        type: "conversation_sync_ack",
        protocolVersion: 2,
        subscriptionId: message.subscriptionId,
        sequence: message.sequence as number,
      };
    }

    if (message.type === "conversation_sync_read") {
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
          "readAt",
        ]) ||
        !validLocalFeatureId(message.subscriptionId, 128) ||
        !target ||
        !validIsoDate(message.readAt)
      ) {
        return null;
      }
      return {
        type: "conversation_sync_read",
        protocolVersion: 2,
        subscriptionId: message.subscriptionId,
        ...target,
        readAt: message.readAt,
      };
    }

    if (
      message.type === "conversation_sync_focus" ||
      message.type === "conversation_sync_unsubscribe"
    ) {
      const focused =
        message.type === "conversation_sync_focus"
          ? parseOptionalTarget(message.focused)
          : undefined;
      if (
        !hasOnlyLocalFeatureKeys(
          message,
          message.type === "conversation_sync_focus"
            ? [
                "type",
                "protocolVersion",
                "requestId",
                "subscriptionId",
                "focused",
                "refresh",
              ]
            : ["type", "protocolVersion", "requestId", "subscriptionId"],
        ) ||
        !validLocalFeatureId(message.requestId, 128) ||
        !validLocalFeatureId(message.subscriptionId, 128) ||
        (message.type === "conversation_sync_focus" &&
          message.refresh !== undefined &&
          typeof message.refresh !== "boolean") ||
        (message.type === "conversation_sync_focus" &&
          message.refresh === true &&
          !focused) ||
        focused === null
      ) {
        return null;
      }
      if (message.type === "conversation_sync_unsubscribe") {
        return {
          type: message.type,
          protocolVersion: 2,
          requestId: message.requestId,
          subscriptionId: message.subscriptionId,
        };
      }
      return {
        type: message.type,
        protocolVersion: 2,
        requestId: message.requestId,
        subscriptionId: message.subscriptionId,
        ...(focused ? { focused } : {}),
        ...(message.refresh === true ? { refresh: true } : {}),
      };
    }

    const target = parseTarget({
      provider: message.provider,
      providerSessionId: message.providerSessionId,
    });
    const commonKeys = [
      "type",
      "protocolVersion",
      "requestId",
      "subscriptionId",
      "provider",
      "providerSessionId",
      "cursor",
      "limit",
      "sortDirection",
    ];
    const allowedKeys =
      message.type === "conversation_turns_page"
        ? [...commonKeys, "itemsView", "projection"]
        : [...commonKeys, "turnId", "toolUseIds"];
    if (
      !hasOnlyLocalFeatureKeys(message, allowedKeys) ||
      !validLocalFeatureId(message.requestId, 128) ||
      !validLocalFeatureId(message.subscriptionId, 128) ||
      !target ||
      !validOptionalCursor(message.cursor) ||
      !validOptionalLimit(message.limit) ||
      (message.sortDirection !== undefined &&
        message.sortDirection !== "asc" &&
        message.sortDirection !== "desc")
    ) {
      return null;
    }
    if (message.type === "conversation_turns_page") {
      if (
        message.itemsView !== undefined &&
        message.itemsView !== "summary" &&
        message.itemsView !== "full"
      ) {
        return null;
      }
      if (
        message.projection !== undefined &&
        message.projection !== "user_index"
      ) {
        return null;
      }
      return {
        type: message.type,
        protocolVersion: 2,
        requestId: message.requestId,
        subscriptionId: message.subscriptionId,
        ...target,
        ...(message.cursor ? { cursor: message.cursor } : {}),
        ...(message.limit ? { limit: message.limit as number } : {}),
        ...(message.sortDirection
          ? { sortDirection: message.sortDirection }
          : {}),
        ...(message.itemsView ? { itemsView: message.itemsView } : {}),
        ...(message.projection ? { projection: message.projection } : {}),
      };
    }
    if (
      message.turnId !== undefined &&
      !validLocalFeatureId(message.turnId, 256)
    ) {
      return null;
    }
    const toolUseIds =
      message.toolUseIds === undefined
        ? undefined
        : parseToolUseIds(message.toolUseIds);
    if (
      (message.toolUseIds !== undefined && toolUseIds === null) ||
      (toolUseIds && message.turnId === undefined)
    ) {
      return null;
    }
    return {
      type: "conversation_items_page",
      protocolVersion: 2,
      requestId: message.requestId,
      subscriptionId: message.subscriptionId,
      ...target,
      ...(message.turnId ? { turnId: message.turnId } : {}),
      ...(toolUseIds ? { toolUseIds } : {}),
      ...(message.cursor ? { cursor: message.cursor } : {}),
      ...(message.limit ? { limit: message.limit as number } : {}),
      ...(message.sortDirection
        ? { sortDirection: message.sortDirection }
        : {}),
    };
  },
};

function parseToolUseIds(value: unknown): string[] | null {
  if (
    !Array.isArray(value) ||
    value.length === 0 ||
    value.length > MAX_TOOL_USE_IDS
  ) {
    return null;
  }
  const seen = new Set<string>();
  const ids: string[] = [];
  for (const raw of value) {
    if (!validLocalFeatureId(raw, 256)) return null;
    const id = raw.trim();
    if (!id || seen.has(id)) return null;
    seen.add(id);
    ids.push(id);
  }
  return ids;
}
