export interface SourcePartition {
  bridgeIdentityId: string;
  bridgeInstanceId: string;
  codexSourceId: string;
}

export interface SourceEpoch {
  source: SourcePartition;
  connectionGeneration: number;
  providerGeneration: number;
}

export interface AuthenticatedOrigin {
  kind: "MOBILE_CLIENT" | "BRIDGE_INTERNAL" | "PROVIDER_READER";
  id: string;
}

/** Constructed by the authenticated server boundary, never decoded from a client body. */
export interface AuthenticatedExecutionContext {
  actorId: string;
  sourceEpoch: SourceEpoch;
  origin: AuthenticatedOrigin;
}

export interface ThreadRef {
  sourcePartition: SourcePartition;
  providerThreadId: string;
}

export type JsonObject = Record<string, unknown>;

export type TimelineReadKind = "FIRST_READ" | "OLDER_PAGE" | "TIMELINE_REPAIR" | "CACHE_REUSE";
export type TimelineReadScope = "WHOLE_SCOPE" | "BOUNDED_RANGE";

export interface ProviderReadEvidence {
  requestId: string;
  readKind: TimelineReadKind;
  readScope: TimelineReadScope;
  providerInstanceEpoch: string;
  providerRevision: string;
  observedAt: number;
  firstTimelineOrdinal: number;
  lastTimelineOrdinal: number;
}

export interface TimelineItemInput {
  itemId: string;
  providerTurnId: string;
  turnOrdinal: number;
  itemOrdinal: number;
  timelineOrdinal: number;
  kind: string;
  payload: JsonObject;
}

export type TimelineGapKind = "STRUCTURAL" | "PAYLOAD";
export type TimelineGapReason =
  | "PROVIDER_PAGE_MISSING"
  | "OVERSIZED_TURN"
  | "ITEM_PAYLOAD_UNAVAILABLE"
  | "UNKNOWN_PROVIDER_ITEM";

export interface TimelineGapInput {
  gapId: string;
  gapOrdinal: number;
  gapKind: TimelineGapKind;
  firstMissingTimelineOrdinal: number;
  lastMissingTimelineOrdinal: number;
  reason: TimelineGapReason;
  descriptor: JsonObject;
}

export interface TimelineCoverageIslandInput {
  islandId: string;
  islandOrdinal: number;
  firstTimelineOrdinal: number;
  lastTimelineOrdinal: number;
  structuralCoverage: "COMPLETE" | "PARTIAL";
  payloadCoverage: "COMPLETE" | "PARTIAL";
}

export interface TimelineMaterializationBeginInput {
  context: AuthenticatedExecutionContext;
  thread: ThreadRef;
  materializationId: string;
  evidence: ProviderReadEvidence;
}

export interface TimelineMaterializationRecord {
  thread: ThreadRef;
  materializationId: string;
  sourceEpoch: SourceEpoch;
  evidence: ProviderReadEvidence;
  readEvidenceDigest: string;
  state: "STAGING" | "SEALED" | "ABORTED";
  pageCount: number;
  itemCount: number;
  gapCount: number;
  totalBytes: number;
}

export interface TimelinePageInput {
  context: AuthenticatedExecutionContext;
  thread: ThreadRef;
  materializationId: string;
  pageIndex: number;
  previousPageDigest?: string;
  items: readonly TimelineItemInput[];
  gaps: readonly TimelineGapInput[];
  coverageIslands: readonly TimelineCoverageIslandInput[];
}

export interface TimelinePageRecord {
  materializationId: string;
  pageIndex: number;
  previousPageDigest?: string;
  pageDigest: string;
  itemCount: number;
  gapCount: number;
  bodyBytes: number;
}

export interface TimelineEmptyProof {
  proofKind: "PROVIDER_CONFIRMED_EMPTY";
  providerRevision: string;
  observationDigest: string;
}

export interface TimelineSealInput {
  context: AuthenticatedExecutionContext;
  thread: ThreadRef;
  materializationId: string;
  expectedHeadRevision: number;
  expectedPageCount: number;
  expectedItemCount: number;
  expectedGapCount: number;
  expectedLastPageDigest?: string;
  emptyProof?: TimelineEmptyProof;
}

export interface TimelineVerificationReceipt {
  materializationDigest: string;
  orderDigest: string;
  coverageDigest: string;
  readEvidenceDigest: string;
  verifiedAt: number;
}

export interface TimelineItemRecord extends TimelineItemInput {}
export interface TimelineGapRecord extends TimelineGapInput {}
export interface TimelineCoverageIslandRecord extends TimelineCoverageIslandInput {}

export interface TimelineReadback {
  thread: ThreadRef;
  headRevision: number;
  materializationId: string;
  sourceEpoch: SourceEpoch;
  evidence: ProviderReadEvidence;
  receipt: TimelineVerificationReceipt;
  totalItemCount: number;
  totalGapCount: number;
  items: TimelineItemRecord[];
  gaps: TimelineGapRecord[];
  coverageIslands: TimelineCoverageIslandRecord[];
}

export interface TimelineReadOptions {
  limit?: number;
  startTimelineOrdinal?: number;
}

export type TimelineReadAttemptOutcome = "FAILED" | "PARTIAL" | "TIMEOUT" | "READ_ERROR";

export interface TimelineReadAttemptInput {
  context: AuthenticatedExecutionContext;
  thread: ThreadRef;
  attemptId: string;
  evidence?: ProviderReadEvidence;
  outcome: TimelineReadAttemptOutcome;
  problem: JsonObject;
}

export interface TimelineReadAttemptRecord {
  attemptId: string;
  thread: ThreadRef;
  sourceEpoch: SourceEpoch;
  outcome: TimelineReadAttemptOutcome;
  evidenceDigest?: string;
  problem: JsonObject;
  observedAt: number;
}

export type OperationCode =
  | "OP-001"
  | "OP-002"
  | "OP-003"
  | "OP-004"
  | "OP-005"
  | "OP-006"
  | "OP-016"
  | "OP-017"
  | "OP-018"
  | "OP-019"
  | "OP-020"
  | "OP-021"
  | "OP-022";

export type OperationState =
  | "RECEIVED"
  | "DURABLY_ADMITTED"
  | "QUEUED"
  | "CALL_STARTED"
  | "PROVIDER_ACCEPTED"
  | "CANONICAL_OBSERVED"
  | "SUCCEEDED"
  | "REJECTED"
  | "CANCELLED"
  | "OUTCOME_UNKNOWN";

export type OperationConflictFamily =
  | "THREAD_MUTATION"
  | "QUEUE_CONTROL"
  | "INTERACTION_RESPONSE";

export type OperationTarget =
  | { targetKind: "THREAD"; providerThreadId: string }
  | { targetKind: "TURN"; providerThreadId: string; providerTurnId: string }
  | {
      targetKind: "QUEUE_ENTRY";
      providerThreadId: string;
      queueEntryId: string;
      rootOperationId: string;
    }
  | {
      targetKind: "INTERACTION";
      providerThreadId: string;
      providerTurnId: string;
      interactionId: string;
      variant: InteractionVariant;
    };

export type OperationPayload =
  | { payloadKind: "START_TURN"; body: JsonObject }
  | { payloadKind: "EDIT_QUEUED_INPUT"; body: JsonObject }
  | { payloadKind: "CANCEL_QUEUED_INPUT"; body: JsonObject }
  | { payloadKind: "STEER_ACTIVE_TURN"; body: JsonObject }
  | { payloadKind: "STEER_QUEUED_INPUT"; body: JsonObject }
  | { payloadKind: "INTERRUPT_TURN"; body: JsonObject }
  | { payloadKind: "CLAIM_INTERACTION"; body: JsonObject }
  | { payloadKind: "RENEW_INTERACTION"; body: JsonObject }
  | { payloadKind: "RELEASE_INTERACTION"; body: JsonObject }
  | { payloadKind: "RESPOND_APPROVAL"; body: JsonObject }
  | { payloadKind: "RESPOND_QUESTION"; body: JsonObject }
  | { payloadKind: "RESPOND_MCP_ELICITATION"; body: JsonObject }
  | { payloadKind: "RESPOND_EXIT_PLAN"; body: JsonObject };

export interface OperationPreconditions {
  expectedHeadVersion?: number;
  expectedLaneRevision?: number;
  expectedEntryRevision?: number;
  expectedInteractionRevision?: number;
  expectedClaimRevision?: number;
}

export interface OperationAdmission {
  context: AuthenticatedExecutionContext;
  thread: ThreadRef;
  operationId: string;
  clientInstanceId: string;
  clientMessageId: string;
  operationCode: OperationCode;
  conflictFamily: OperationConflictFamily;
  target: OperationTarget;
  payload: OperationPayload;
  preconditions: OperationPreconditions;
  claimedFingerprint?: string;
}

export interface OperationRecord {
  thread: ThreadRef;
  sourceEpoch: SourceEpoch;
  actorId: string;
  origin: AuthenticatedOrigin;
  operationId: string;
  clientInstanceId: string;
  clientMessageId: string;
  operationCode: OperationCode;
  conflictFamily: OperationConflictFamily;
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
  target: OperationTarget;
  payload: OperationPayload;
  preconditions: OperationPreconditions;
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
  context: AuthenticatedExecutionContext;
  thread: ThreadRef;
  operationId: string;
  expectedRevision: number;
  toState: "PROVIDER_ACCEPTED" | "CANONICAL_OBSERVED" | "SUCCEEDED" | "REJECTED";
  eventKind: string;
  dispatchAttemptId: string;
  providerTurnId?: string;
  providerEvidence?: "SERVER_RESPONSE" | "VERIFIED_CANONICAL_FACT";
  details?: JsonObject;
}

export interface DispatchStartInput {
  context: AuthenticatedExecutionContext;
  thread: ThreadRef;
  operationId: string;
  expectedOperationRevision: number;
  dispatchAttemptId: string;
}

export type ReconcileFactKind =
  | "PROVIDER_ACCEPTED"
  | "CANONICAL_OBSERVED"
  | "PROVIDER_REJECTED"
  | "PROVIDER_CANCELLED";

export interface VerifiedProviderFact {
  verificationKind: "EXACT_PROVIDER_FACT";
  providerEvent:
    | "turn/started"
    | "turn/completed"
    | "turn/rejected"
    | "turn/cancelled"
    | "serverRequest/resolved";
  providerFactId: string;
  providerThreadId: string;
  providerTurnId?: string;
  providerRequestId?: string;
  observedAt: number;
}

export interface ReconcileFactInput {
  context: AuthenticatedExecutionContext;
  thread: ThreadRef;
  operationId: string;
  reconcileRoundId: string;
  factId: string;
  factKind: ReconcileFactKind;
  evidence: VerifiedProviderFact;
  providerTurnId?: string;
}

export interface ReconcileResolutionRecord {
  operationId: string;
  reconcileRoundId: string;
  factId: string;
  projectedOutcome: "PROVIDER_ACCEPTED" | "SUCCEEDED" | "REJECTED" | "CANCELLED";
  evidenceDigest: string;
  resolvedAt: number;
}

export type QueueEntryState = "QUEUED" | "DISPATCH_RESERVED" | "CONSUMED" | "CANCELLED";

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

export interface QueueAdmissionInput {
  admission: OperationAdmission;
  laneFamily: string;
  expectedLaneRevision: number;
  queueEntryId: string;
  capacity?: number;
}

export interface QueueControlInput {
  admission: OperationAdmission;
  laneFamily: string;
  queueEntryId: string;
  expectedLaneRevision: number;
  expectedEntryRevision: number;
  replacementPayload?: JsonObject;
}

export interface BeginQueuedDispatchInput {
  context: AuthenticatedExecutionContext;
  thread: ThreadRef;
  laneFamily: string;
  expectedLaneRevision: number;
  dispatchAttemptId: string;
}

export interface QueueDispatchBarrier {
  lane: QueueLaneRecord;
  entry: QueueEntryRecord;
  operation: OperationRecord;
}

export interface InteractionRef {
  thread: ThreadRef;
  providerTurnId: string;
  interactionId: string;
}

export type InteractionState =
  | "OPEN_UNCLAIMED"
  | "CLAIMED"
  | "RESPONDING"
  | "RESOLVED"
  | "EXPIRED"
  | "WITHDRAWN";

export type InteractionVariant = "APPROVAL" | "QUESTION" | "MCP_ELICITATION" | "EXIT_PLAN";

export interface InteractionRecord {
  ref: InteractionRef;
  sourceEpoch: SourceEpoch;
  providerRequestId: string;
  variant: InteractionVariant;
  state: InteractionState;
  revision: number;
  expiresAt: number;
  descriptor: JsonObject;
  responseFingerprint?: string;
  responseOperationId?: string;
  responseActorId?: string;
  response?: JsonObject;
  resolutionEvidenceDigest?: string;
}

export type InteractionClaimState = "ACTIVE" | "CONSUMED" | "RELEASED" | "EXPIRED" | "REVOKED";

export interface InteractionClaimRecord {
  ref: InteractionRef;
  claimId: string;
  actorId: string;
  tokenHash: string;
  expiresAt: number;
  state: InteractionClaimState;
  revision: number;
}

export interface OpenInteractionInput {
  context: AuthenticatedExecutionContext;
  ref: InteractionRef;
  providerRequestId: string;
  variant: InteractionVariant;
  expiresAt: number;
  descriptor: JsonObject;
}

export interface ClaimInteractionInput {
  context: AuthenticatedExecutionContext;
  ref: InteractionRef;
  expectedInteractionRevision: number;
  claimId: string;
  claimToken: string;
  expiresAt: number;
}

export interface InteractionClaimMutationInput {
  context: AuthenticatedExecutionContext;
  ref: InteractionRef;
  expectedInteractionRevision: number;
  claimId: string;
  expectedClaimRevision: number;
  claimToken: string;
}

export interface RenewInteractionClaimInput extends InteractionClaimMutationInput {
  expiresAt: number;
}

export interface RespondInteractionInput {
  context: AuthenticatedExecutionContext;
  ref: InteractionRef;
  variant: InteractionVariant;
  expectedInteractionRevision: number;
  claimId: string;
  expectedClaimRevision: number;
  claimToken: string;
  responseOperationId: string;
  responseClientInstanceId: string;
  responseClientMessageId: string;
  operationCode: "OP-019" | "OP-020" | "OP-021" | "OP-022";
  claimedFingerprint?: string;
  operationTarget: Extract<OperationTarget, { targetKind: "INTERACTION" }>;
  operationPreconditions: OperationPreconditions;
  response: JsonObject;
}

export interface ResolveInteractionInput {
  context: AuthenticatedExecutionContext;
  ref: InteractionRef;
  expectedInteractionRevision: number;
  responseOperationId: string;
  providerRequestId: string;
  providerEvent: "SERVER_REQUEST_RESOLVED";
  evidence: VerifiedProviderFact;
}

export type StoreFaultStage =
  | "timeline.after-page"
  | "timeline.after-materialization-seal"
  | "timeline.after-head-cas"
  | "timeline.before-commit"
  | "operation.after-row"
  | "operation.after-event"
  | "operation.before-transaction"
  | "operation.before-commit"
  | "operation.after-commit-before-readback"
  | "queue.after-lane-cas"
  | "queue.after-entry"
  | "queue.after-operation"
  | "queue.before-commit"
  | "interaction.after-row"
  | "interaction.after-claim"
  | "interaction.after-operation"
  | "interaction.before-commit"
  | "recovery.after-operation";

export interface StoreOpenOptions {
  filePath: string;
  writerLeaseTtlMs?: number;
  /** Internal tests only. Business code uses ConversationCoreStoreClient. */
  faultHook?: (stage: StoreFaultStage) => void;
  /** Internal tests only. */
  now?: () => number;
}

export type StoreErrorCode =
  | "STORE_CLOSED"
  | "STORE_WORKER_CRASHED"
  | "WORKER_REQUIRED"
  | "WRITER_ALREADY_OPEN"
  | "WRITER_LEASE_LOST"
  | "INVALID_DATABASE_PATH"
  | "IDENTITY_CONFLICT"
  | "SOURCE_FENCE_MISMATCH"
  | "REVISION_CONFLICT"
  | "TIMELINE_CANDIDATE_REJECTED"
  | "TIMELINE_PAGE_CHAIN_INVALID"
  | "PAYLOAD_TOO_LARGE"
  | "INVALID_JSON"
  | "OPERATION_FINGERPRINT_CONFLICT"
  | "OPERATION_ID_CONFLICT"
  | "OPERATION_NOT_FOUND"
  | "INVALID_STATE_TRANSITION"
  | "BLOCKED_BY_UNKNOWN_OUTCOME"
  | "QUEUE_FULL"
  | "QUEUE_ENTRY_NOT_FOUND"
  | "QUEUE_ENTRY_NOT_EDITABLE"
  | "QUEUE_ENTRY_NOT_CANCELLABLE"
  | "QUEUE_REVISION_CONFLICT"
  | "ENTRY_REVISION_CONFLICT"
  | "INTERACTION_NOT_OPEN"
  | "INTERACTION_CONTENDED"
  | "INTERACTION_REVISION_CONFLICT"
  | "WRONG_INTERACTION_VARIANT"
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
