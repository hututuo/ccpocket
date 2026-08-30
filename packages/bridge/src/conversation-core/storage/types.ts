export interface SourcePartition {
  bridgeIdentityId: string;
  bridgeInstanceId: string;
  codexSourceId: string;
}

export interface ThreadRef {
  sourcePartition: SourcePartition;
  providerThreadId: string;
}

export type JsonObject = Record<string, unknown>;

export type TimelineHealth = "HEALTHY" | "DEGRADED";

export interface TimelineItemInput {
  itemId: string;
  providerTurnId: string;
  ordinal: number;
  kind: string;
  payload: JsonObject;
}

export interface TimelineGapInput {
  gapId: string;
  ordinal: number;
  reason: string;
  descriptor: JsonObject;
}

export interface TimelineCandidate {
  materializationId: string;
  verified: boolean;
  items: readonly TimelineItemInput[];
  gaps: readonly TimelineGapInput[];
  metadata?: JsonObject;
}

export interface TimelineItemRecord extends TimelineItemInput {}

export interface TimelineGapRecord extends TimelineGapInput {}

export interface TimelineReadback {
  thread: ThreadRef;
  revision: number;
  contentRevision: number;
  materializationId?: string;
  health: TimelineHealth;
  healthProblem?: JsonObject;
  metadata?: JsonObject;
  totalItemCount: number;
  totalGapCount: number;
  items: TimelineItemRecord[];
  gaps: TimelineGapRecord[];
}

export interface TimelineReadOptions {
  limit?: number;
  startOrdinal?: number;
}

export type OperationState =
  | "ADMITTED"
  | "QUEUED"
  | "DISPATCHING"
  | "PROVIDER_ACCEPTED"
  | "CANONICAL_OBSERVED"
  | "REJECTED"
  | "CANCELLED"
  | "OUTCOME_UNKNOWN"
  | "RECONCILE_REQUIRED";

export interface OperationAdmission {
  thread: ThreadRef;
  operationId: string;
  clientMessageId: string;
  fingerprint: string;
  payload: JsonObject;
}

export interface OperationRecord {
  thread: ThreadRef;
  operationId: string;
  clientMessageId: string;
  fingerprint: string;
  dispatchAttemptId?: string;
  providerTurnId?: string;
  state: OperationState;
  revision: number;
  canonicalObserved: boolean;
  reconcileRequired: boolean;
  dispatchStartedAt?: number;
  providerAcceptedAt?: number;
  canonicalObservedAt?: number;
  payload: JsonObject;
}

export interface OperationEventRecord {
  operationId: string;
  sequence: number;
  fromState?: OperationState;
  toState: OperationState;
  kind: string;
  dispatchAttemptId?: string;
  providerTurnId?: string;
  details?: JsonObject;
}

export interface OperationTransition {
  thread: ThreadRef;
  operationId: string;
  expectedRevision: number;
  toState: OperationState;
  eventKind: string;
  dispatchAttemptId?: string;
  providerTurnId?: string;
  providerTurnEvidence?: "TURN_START_RESPONSE" | "VERIFIED_FACT";
  details?: JsonObject;
}

export type QueueEntryState =
  | "QUEUED"
  | "EDITED"
  | "DISPATCH_OWNED"
  | "CONSUMED"
  | "CANCELLED";

export interface QueueLaneRecord {
  thread: ThreadRef;
  laneFamily: string;
  revision: number;
  nextFifoOrdinal: number;
  activeCount: number;
  capacity: number;
}

export interface QueueEntryRecord {
  thread: ThreadRef;
  laneFamily: string;
  queueEntryId: string;
  rootOperationId: string;
  fifoOrdinal: number;
  revision: number;
  state: QueueEntryState;
  payloadDigest: string;
  payload: JsonObject;
}

export interface QueueMutationRef {
  thread: ThreadRef;
  laneFamily: string;
  expectedLaneRevision: number;
}

export interface InteractionRef {
  thread: ThreadRef;
  providerTurnId: string;
  interactionId: string;
}

export type InteractionState =
  | "OPEN_UNCLAIMED"
  | "OPEN_CLAIMED"
  | "RESPONSE_PENDING"
  | "RESOLVED"
  | "WITHDRAWN"
  | "STALE"
  | "EXPIRED";

export type InteractionVariant = "APPROVAL" | "QUESTION" | "MCP" | "EXIT_PLAN";

export interface InteractionRecord {
  ref: InteractionRef;
  providerRequestId: string;
  variant: InteractionVariant;
  state: InteractionState;
  revision: number;
  descriptor: JsonObject;
  responseFingerprint?: string;
  responseOperationId?: string;
  responseActorId?: string;
  response?: JsonObject;
}

export type InteractionClaimState = "ACTIVE" | "RELEASED" | "EXPIRED";

export interface InteractionClaimRecord {
  ref: InteractionRef;
  claimId: string;
  actorId: string;
  tokenHash: string;
  expiresAt: number;
  state: InteractionClaimState;
  revision: number;
}

export type StoreFaultStage =
  | "timeline.after-head-cas"
  | "timeline.after-delete"
  | "timeline.after-items"
  | "timeline.before-commit"
  | "timeline.after-commit-before-readback"
  | "operation.after-row"
  | "operation.after-event"
  | "operation.before-commit"
  | "operation.after-commit-before-readback"
  | "queue.after-lane-cas"
  | "queue.after-entry"
  | "queue.before-commit"
  | "queue.after-commit-before-readback"
  | "interaction.after-row"
  | "interaction.after-claim"
  | "interaction.before-commit"
  | "interaction.after-commit-before-readback"
  | "recovery.after-operation";

export interface StoreOpenOptions {
  filePath: string;
  faultHook?: (stage: StoreFaultStage) => void;
  now?: () => number;
}

export type StoreErrorCode =
  | "STORE_CLOSED"
  | "WRITER_ALREADY_OPEN"
  | "IDENTITY_CONFLICT"
  | "REVISION_CONFLICT"
  | "TIMELINE_CANDIDATE_REJECTED"
  | "PAYLOAD_TOO_LARGE"
  | "OPERATION_FINGERPRINT_CONFLICT"
  | "OPERATION_ID_CONFLICT"
  | "OPERATION_NOT_FOUND"
  | "INVALID_STATE_TRANSITION"
  | "QUEUE_FULL"
  | "QUEUE_ENTRY_NOT_FOUND"
  | "QUEUE_ENTRY_NOT_EDITABLE"
  | "QUEUE_ENTRY_NOT_CANCELLABLE"
  | "QUEUE_REVISION_CONFLICT"
  | "ENTRY_REVISION_CONFLICT"
  | "INTERACTION_NOT_OPEN"
  | "INTERACTION_CONTENDED"
  | "INTERACTION_REVISION_CONFLICT"
  | "CLAIM_NOT_OWNED"
  | "CLAIM_EXPIRED";

export class ConversationStoreError extends Error {
  constructor(
    readonly code: StoreErrorCode,
    message: string,
  ) {
    super(message);
    this.name = "ConversationStoreError";
  }
}
