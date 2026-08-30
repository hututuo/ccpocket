export type JsonPrimitive = string | number | boolean | null;

export type JsonValue =
  | JsonPrimitive
  | readonly JsonValue[]
  | { readonly [key: string]: JsonValue };

export interface SourcePartition {
  readonly bridgeIdentityId: string;
  readonly bridgeInstanceId: string;
  readonly codexSourceId: string;
}

export interface ThreadRef {
  readonly source: SourcePartition;
  readonly providerThreadId: string;
}

export interface ProviderItemSnapshot {
  readonly providerItemId: string;
  readonly kind: string;
  readonly payload: JsonValue;
}

export interface ProviderTurnSnapshot {
  readonly providerTurnId: string;
  readonly items: readonly ProviderItemSnapshot[];
}

export type ProviderReadStatus = "complete" | "partial" | "empty";

/**
 * One isolated provider read. Array order is the only ordering fact accepted by
 * K01; timestamps and inferred cursors are deliberately absent.
 */
export interface ProviderThreadSnapshot {
  readonly source: SourcePartition;
  readonly providerThreadId: string;
  readonly readGeneration: number;
  readonly readStatus: ProviderReadStatus;
  readonly turns: readonly ProviderTurnSnapshot[];
}

export interface CanonicalTurnRef {
  readonly thread: ThreadRef;
  readonly providerTurnId: string;
  readonly turnOrdinal: number;
  readonly orderKey: string;
}

export interface CanonicalItemRef {
  readonly turn: CanonicalTurnRef;
  readonly providerItemId: string;
  readonly itemOrdinal: number;
  readonly ordinal: number;
  readonly orderKey: string;
}

export type CanonicalItemKind =
  | "user"
  | "assistant"
  | "thinking"
  | "tool_use"
  | "tool_result"
  | "system"
  | "unknown";

export interface CanonicalTimelineItem {
  readonly ref: CanonicalItemRef;
  readonly kind: CanonicalItemKind;
  /** The exact provider discriminator is retained even when kind is unknown. */
  readonly providerKind: string;
  readonly payload: JsonValue;
}

export interface CoverageBoundary {
  readonly providerTurnId: string;
  readonly providerItemId: string;
  readonly ordinal: number;
}

export type GapKind = "provider_history_unknown" | "window_not_loaded";

export interface TimelineGap {
  readonly gapId: string;
  readonly kind: GapKind;
  readonly after?: CoverageBoundary;
  readonly before?: CoverageBoundary;
}

export interface CoverageIsland {
  readonly start: CoverageBoundary;
  readonly end: CoverageBoundary;
  readonly itemCount: number;
}

export interface TimelineCoverage {
  readonly providerReadStatus: ProviderReadStatus;
  readonly knownItemCount: number;
  readonly windowStartOrdinal?: number;
  readonly windowEndOrdinal?: number;
  readonly hasEarlierWindowItems: boolean;
  readonly hasLaterWindowItems: boolean;
  readonly islands: readonly CoverageIsland[];
  readonly gaps: readonly TimelineGap[];
}

export type ReadHealthState =
  | "healthy"
  | "partial"
  | "empty"
  | "error"
  | "timeout"
  | "rejected";

export interface ReadHealth {
  readonly state: ReadHealthState;
  readonly servedReadGeneration: number;
  readonly observedReadGeneration?: number;
  readonly code?: string;
}

/** Immutable, bounded projection over a process-local canonical cache. */
export interface CanonicalTimelineSnapshot {
  readonly thread: ThreadRef;
  readonly readGeneration: number;
  readonly knownTurns: readonly CanonicalTurnRef[];
  readonly items: readonly CanonicalTimelineItem[];
  readonly coverage: TimelineCoverage;
  readonly readHealth: ReadHealth;
}

export interface ProviderLiveItem {
  readonly source: SourcePartition;
  readonly providerThreadId: string;
  readonly liveGeneration: number;
  readonly providerTurnId: string;
  readonly item: ProviderItemSnapshot;
}

export interface LiveOverlayItem {
  readonly providerTurnId: string;
  readonly item: ProviderItemSnapshot;
  readonly arrivalOrdinal: number;
  readonly orderKey: string;
}

export interface LiveOverlay {
  readonly thread: ThreadRef;
  readonly liveGeneration: number;
  readonly items: readonly LiveOverlayItem[];
}

export type LiveApplyRejection =
  | "source_mismatch"
  | "stale_live_generation"
  | "duplicate_provider_identity"
  | "invalid_provider_fact";

export interface LiveApplyResult {
  readonly accepted: boolean;
  readonly rejection?: LiveApplyRejection;
  readonly overlay: LiveOverlay;
}
