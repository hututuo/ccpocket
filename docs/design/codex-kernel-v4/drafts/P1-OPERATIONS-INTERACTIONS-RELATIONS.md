# Phase 1 draft: operations, interactions, thread state, and relations

Status: `PHASE_1_DRAFT / ROOT_INTEGRATION_REQUIRED / IMPLEMENTATION_NOT_AUTHORIZED`

This draft amends the operation/scheduling, Interaction, settings, Goal, Plan,
and relation parts of the original single Codex Session Kernel. It is not a
second kernel, an implementation, a migration, or a production protocol. The
root design must reconcile its names and exact DDL with the Phase 1 identity,
receive/cache/order, and wire/storage drafts before anything becomes
authoritative.

Bound design input:

- design worktree start: `d152b118045264abeb8a1760b94113e323e46283`;
- source fact baseline named by the v4 input: `main@a706200233c55cc82d7a17e433f80f132d0f280d`, tree `ac85f620445151f45eda856f55f4b96ee442f41a`;
- original design ZIP: `d5c33a5455a1f1375efd4b68e0bb91844a5e6467c7115b3a204b4ea1faeeef76`;
- v4 input ZIP: `d0f597cc089850214ec5aece824a3eb0265e20e0ce0e0bbef27add1381f0e257`.

Evidence level in this document is `SOURCE_PRESENT / DESIGN_PROPOSED` unless a
row explicitly says `EXPERIMENT_REQUIRED`. No Provider mutation, SQLite
migration, Bridge/App run, port `8765`, deployment, IPA/OTA, installation, or
device acceptance was performed.

## 1. Baseline disposition

| Original design area | Disposition | Phase 1 ruling |
|---|---|---|
| `operation_id` plus immutable payload digest | `KEEP_STRENGTHEN` | Scope the identity by authenticated Bridge/source/thread, bind it to the authenticated actor, version canonical fingerprinting, and reject same ID with actor or digest mismatch. |
| Bridge admission before Provider I/O | `KEEP` | Admission and its first event commit atomically before scheduling. Mobile socket write is not admission. |
| one Provider-mutating lane per thread | `AMEND` | Keep one dispatch owner, add durable `lane_revision`, explicit queue entries, compare-and-swap edit/cancel/consume, and distinct priority without bypassing the lane. |
| dispatch barrier and `dispatch_attempt` | `KEEP_STRENGTHEN` | Persist exact dispatch payload digest, lane revision, Provider instance, and `CALL_STARTED` boundary. A crash after `CALL_STARTED` is ambiguous even if the actual syscall may not have run. |
| `PROVIDER_ACCEPTED` | `AMEND` | It is only a receipt/admission fact. Success waits for a command-specific authoritative read or event recorded as `CANONICAL_OBSERVED`. |
| `OUTCOME_UNKNOWN` and read-only reconcile | `KEEP_STRENGTHEN` | Reconcile never invokes the mutation. Same-operation redispatch is forbidden unless `DEFINITIVE_NO_WRITE` and a build-certified replay rule are both present. |
| generic `operation.submit.payload/preconditions` and `CodexCommand` fields typed as `unknown` | `DELETE_REPLACE` | Use a finite generated discriminated union. Every mutation in `P1-OPERATION-STATE-MATRIX.csv` has its own payload, preconditions, result, error, delivery, replay, and reconcile policy. |
| approval/question/MCP aggregate | `KEEP_STRENGTHEN` | Add ExitPlan; authenticated actor replaces client-reported claimant; claim, renew, release, respond, expire, and canonical resolution are explicit. |
| CC Pocket-owned Goal product document | `DELETE` | Goal is Provider-backed thread state. CC Pocket stores only a rebuildable snapshot plus its operation/reconcile evidence. |
| provider Plan plus CC annotations/product document | `DELETE_REPLACE` | Plan items are timeline facts, collaboration is settings, and ExitPlan is Interaction. No Plan document writer remains. |
| Side Chat as a user choice among persisted/ephemeral/Fork | `DELETE_REPLACE` | Persisted and ephemeral Side Chat both exist; ordinary Fork is a separate relation type and operation. |
| subagent custom history surface | `AMEND` | A subagent is a Provider relation to an ordinary child conversation plus source-fenced live lifecycle. Reads/watch remain bounded; no third timeline. |
| `source_device_id` accepted from business payload | `DELETE_REPLACE` | Actor is injected from authenticated connection context. Payload actor fields, if retained for diagnostics, are equality assertions only. |
| `automatic_retry_permitted` boolean | `DELETE_REPLACE` | Replay permission is derived from immutable command-specific evidence; it is never a client flag or manually toggled column. |

## 2. One Session Kernel, unique internal owners

These are internal ownership boundaries inside the original Session Kernel,
not independent product cores or independent databases.

| Semantic | Unique owner | Execution location | Durable authority | Mobile role |
|---|---|---|---|---|
| operation admission, fingerprint, state and events | `OperationKernel` | Bridge single-writer application service；scheduler 只是其内部组件 | Bridge operation ledger after acceptance; Provider remains authority for side effects | protected local intent until accepted, then replica |
| Provider-mutating lane and next-turn backlog | `OperationKernel` | Bridge | Bridge lane/queue ledger | projection and user edit/cancel requests only |
| current Provider execution/result | `CodexProviderAdapter` evidence consumed by `OperationReconciler` | Provider I/O plus Bridge read-only reconcile | Provider durable/event evidence | replica; never infers from spinner or timeout |
| interaction open/resolved fact | `InteractionBroker` | Bridge over current Provider runtime | Provider open/resolved evidence; Bridge owns claim arbitration | claim/respond surface and replica |
| authenticated actor | connection/authentication context | Bridge transport boundary | authenticated principal registry outside the Session Kernel | never self-asserts authority |
| complete thread settings snapshot and revision | `ThreadState` | Bridge writer over Provider `thread/settings/*` | Provider thread settings; Bridge caches a complete/sparse typed snapshot | selected values become authoritative only from correlated ACK/snapshot |
| Goal | `ThreadState` | Bridge writer over Provider Goal RPCs | Provider thread Goal | typed read/mutation surface; no Goal store authority |
| Plan item | `CanonicalTimeline` from Provider materialization/live | Provider/Bridge read pipeline | Provider item evidence | renders and updates by stable item identity |
| collaboration mode | `ThreadState` | Bridge/Provider settings | Provider thread setting | settings projection |
| ExitPlan | `InteractionBroker` | exact Provider runtime | Provider request/resolution | claim/respond UI |
| durable relations | `RelationGraph` | Bridge writer from Provider result/evidence | Provider relation when available; otherwise CC Pocket relation record tied to a proven child | replica/navigation |
| ephemeral Side Chat registry | `RelationGraph` | Bridge memory, runtime/source fenced | no durable conversation authority | memory projection; disappears on fence loss |
| subagent lifecycle | `RelationGraph` plus child conversation status projection | Provider read/live adapter | Provider child/source evidence | bounded list/watch/navigation |
| Mobile offline intent | `LocalIntentStore` | Mobile durable writer | user intent only, never remote queue/execution fact | owns hold/confirm/cancel until Bridge acceptance |

No Product Platform module, UI Cubit, transport router, notification handler,
or feature slot may write canonical timeline, operation state, interaction
state, settings head, Goal head, or durable relations.

`P1-OPERATION-STATE-MATRIX.csv` therefore records two owners separately:
`operation_lifecycle_owner` is always `OperationKernel` for a client mutation,
while `domain_effect_owner` owns the target aggregate and executes only after
admission. `EXPIRE_INTERACTION` is the sole listed internal transition and has
no operation lifecycle. `InteractionBroker`, `ThreadState`,
`RelationGraph` and Product services never write the operation/dispatch ledger.

## 3. Identity, actor, and fingerprint

### 3.1 Stable target identity

Every operation and durable relation uses:

```text
SourcePartition = (bridgeIdentityId, bridgeInstanceId, codexSourceId)
ThreadLocator   = (SourcePartition, providerThreadId)
OperationKey    = (SourcePartition, operationId)
```

`runtimeSessionId`, route, IP, DNS, title, text, wall clock, and array position
are not components of `ThreadLocator` or `OperationKey`. Every operation also
stores one schema-validated exact target. Session operations target a
`ThreadLocator`/Turn/Item/Interaction; Product Platform operations target their
sealed product descriptor. An operation that creates a new thread uses a
source-scoped creation target plus its proven parent locator; after the Provider
returns a child ID, the result records the child `ThreadLocator`.

### 3.2 Authenticated actor

The transport provides an immutable per-frame execution context. Actor is a
discriminated union; an API key or open connection never fabricates a device
key:

```ts
type AuthenticatedActorV1 =
  | {
      kind: "paired_device";
      principalId: string;
      deviceKeyId: string;
      trustRevision: string;
      assurance: "paired_signature";
    }
  | {
      kind: "api_key";
      principalId: string;
      credentialRevision: string;
      assurance: "connection_key";
    }
  | {
      kind: "open_connection";
      principalId: string;
      connectionEpoch: string;
      assurance: "open_local";
    };

interface AuthenticatedExecutionContextV1 {
  source: {
    bridgeIdentityId: string;
    bridgeInstanceId: string;
    codexSourceId: string;
  };
  sourceEpoch: string;
  connectionEpoch: string;
  actor: AuthenticatedActorV1;
  capabilitySnapshotId: string;
}
```

The complete actor union is injected after authentication. Operation and
Interaction request bodies containing `actor`, `actorPrincipalId`,
`actorDeviceKeyId`, `claimantId`, `deviceId`, `authenticationStrength` or
`authenticated=true` fail `ACTOR_FIELD_FORBIDDEN`; there is no reachable
compatibility equality parser. If a transition requires a paired actor or
step-up proof, `open_local` fails with `ACTOR_ASSURANCE_REQUIRED`.

### 3.3 Canonical fingerprint

Each mutation has a generated `fingerprintVersion` and a typed canonicalizer.
The digest input is:

```text
mutation kind + schema version + ThreadLocator or creation target
+ semantic payload + semantic preconditions
```

Excluded fields are transport timestamp, request trace, route, UI label, retry
counter, and connection epoch. Canonical bytes use RFC 8785 JSON Canonicalization
Scheme over the schema-validated typed value；字符串代码点不另做 NFC/NFD 改写，避免改变用户输入。Absent 和 explicit null 只有在 schema 明确区分时才能并存；binary content 只使用 immutable `ContentRef` digest，绝不 inline。普通 JSON `stringify` 或 arbitrary map 不是合同。

Admission transaction:

1. authenticate and resolve the source/thread;
2. validate the exact typed payload, capability, size, and preconditions;
3. compute the fingerprint;
4. insert operation plus revision 1 event, or return the existing row;
5. same key, actor and fingerprint returns the existing state without Provider I/O;
6. same key with another actor returns `OPERATION_ACTOR_MISMATCH`;
7. same key with another kind/payload/precondition returns `OPERATION_FINGERPRINT_CONFLICT`.

Provider acceptance is not idempotency. `clientUserMessageId` may be sent as a
correlation hint only when the pinned build accepts it; it never authorizes
replay.

## 4. Online input, Bridge queue, and Mobile offline intent

The three user-visible concepts are deliberately different.

| Concept | Owner | Durable identity | Meaning | Never means |
|---|---|---|---|---|
| online outgoing | Mobile until Bridge admission, then operation replica | `operationId` | the user initiated a submission and the socket may or may not have delivered it | Bridge queue position or Provider execution |
| Bridge queue entry | Bridge `OperationKernel` | `queueEntryId`, root `START_TURN operationId`, `laneRevision` | Bridge durably accepted a future turn but cannot dispatch it yet | ordinary socket in-flight or offline draft |
| Mobile offline intent | Mobile `LocalIntentStore` | `operationId` plus source/thread hint and fingerprint | user intent held locally while no authenticated source is writable | automatic remote dispatch permission |

Safe default while U-001 remains unresolved is `HOLD_FOR_CONFIRMATION` for a
new ordinary message created fully offline. Reconnection alone does not submit
it. A frame attempted before disconnection is different: Mobile may resubmit
the same ID and digest solely to discover/complete Bridge admission. After an
app restart, an unacknowledged intent is shown as interrupted and requires an
explicit tap.

### 4.1 Local intent state

```text
DRAFT -> HELD_OFFLINE -> READY_TO_SUBMIT -> SUBMITTING
SUBMITTING -> BRIDGE_ACCEPTED
SUBMITTING -> ADMISSION_UNKNOWN -> SUBMITTING (same ID/digest, admission query only)
DRAFT|HELD_OFFLINE|READY_TO_SUBMIT -> LOCAL_CANCELLED
any pre-accept state -> LOCAL_ERROR
```

`BRIDGE_ACCEPTED` transfers remote delivery authority to Bridge. Removing the
Mobile row never cancels a Bridge queue entry. Cancellation after acceptance
must be `CANCEL_QUEUED_INPUT` with the expected lane revision.

### 4.2 Bridge queue and lane revision

There is one Provider-mutation dispatch owner per `ThreadLocator`. The lane
row contains a monotonically increasing `laneRevision`. It increments on:

- admission into or removal from the queue;
- a successful queue edit;
- cancel/consume transition;
- dispatch owner acquisition/release;
- an outcome transition that changes whether later mutations are blocked.

Queue query returns the complete bounded snapshot: `laneRevision`, limit,
ordered entries, each entry's immutable ID, root operation ID, payload revision,
payload digest, status, and delivery evidence. Edit, cancel, and consume-for-
steer require `expectedLaneRevision` and `expectedEntryRevision`. A mismatch is
`QUEUE_REVISION_CONFLICT` and returns the latest snapshot; it never guesses by
text or silently applies to a replacement entry. Reorder is not designed.

Limit is 16 entries per thread. Text is at most 32 KiB UTF-8, structured refs
at most 64, and inline image bytes are forbidden. Attachments must already be
immutable refs before a future-turn entry is admitted.

### 4.3 Dispatch barrier and accepted versus observed

```text
ACCEPTED -> QUEUED | BLOCKED_PRECONDITION | READY
READY -> DISPATCH_PREPARED -> DISPATCHING
DISPATCHING -> DEFINITIVE_NOT_DISPATCHED | PROVIDER_ACCEPTED | REJECTED_NO_SIDE_EFFECT | OUTCOME_UNKNOWN
PROVIDER_ACCEPTED -> AWAITING_CANONICAL -> CANONICAL_OBSERVED -> SUCCEEDED | FAILED
```

`OUTCOME_UNKNOWN` is an immutable dispatch terminal, not a state with an
outgoing edge. A separate append-only reconciliation axis records
`RECONCILE_REQUESTED` followed by `RECONCILED_EXECUTED`,
`RECONCILED_NOT_EXECUTED`, or `STILL_UNKNOWN`. Those observations may derive a
current UI resolution and unblock later operations when proof is sufficient,
but they never rewrite the original terminal or authorize the original payload
to dispatch again.

Before Provider I/O, one transaction must capture the exact dispatch payload
digest and queue revisions, set the lane owner, create `dispatch_attempt`, and
record `DISPATCH_PREPARED`. A second transaction changes the attempt to
`CALL_STARTED` immediately before the adapter call. Recovery rules:

- `PREPARED` without `CALL_STARTED`: no call permission was issued; it can
  become `DEFINITIVE_NOT_DISPATCHED`;
- `CALL_STARTED` without a definitive result: `OUTCOME_UNKNOWN`;
- receipt recorded: `PROVIDER_ACCEPTED`, followed by command-specific
  read-only observation;
- no timer, socket close, or missing item proves failure or absence.

`CANONICAL_OBSERVED` is command-specific:

- start/retry: durable Provider user item/turn linked by certified identity;
- steer: durable turn/item or certified steer result on the exact turn;
- stop: the exact turn is authoritatively terminal with the observed outcome;
- settings: authoritative readback snapshot contains the intended values and
  preserves all non-target fields;
- Goal: authoritative Goal read matches the intended mutation identity;
- interaction response: Provider reports that exact request resolved;
- compact: certified compact terminal plus subsequent repair-read boundary;
- review/fork/persisted Side Chat: proven child/turn and durable relation;
- archive/rename/delete: Provider lifecycle readback.

`OUTCOME_UNKNOWN` 是不可再 dispatch 的 dispatch terminal，不是“稍后可重试”状态。
后续 reconcile 只能追加新的 observation/resolution event，并派生
`RECONCILED_EXECUTED / RECONCILED_NOT_EXECUTED / STILL_UNKNOWN` 视图；原始
`OUTCOME_UNKNOWN` event、attempt 和 payload digest 永不覆盖或删除。只有新的
operation ID 才能表达用户再次执行的意图。

### 4.4 Retry is a policy, not a generic mutation

There is no `execute("retry", map)` command.

- admission ACK loss: resubmit the same operation ID and digest; this cannot
  dispatch an already admitted operation a second time;
- `DEFINITIVE_NOT_DISPATCHED`: the same operation may return to `READY` only
  when the adapter has build-certified no-write and replay evidence for that
  exact mutation;
- definitive rejection/no side effect: an explicit user retry creates a new
  operation ID with `retryOfOperationId` for audit;
- `OUTCOME_UNKNOWN`: never reuse or automatically resend. Under U-002, an
  explicit risky resend, if allowed, is a new operation with a duplicate-side-
  effect warning and `retryOfOperationId`;
- Provider failure after canonical execution: retry is a new semantic action,
  not continuation of the completed operation.

Safe default while U-002 remains open is to block later Provider mutations on
the same thread while allowing reads/resources and explicit reconcile.

## 5. Interaction Broker

### 5.1 Aggregate and variants

The aggregate identity is:

```text
(ThreadLocator, providerTurnId, providerRequestId-with-type, runtimeFence)
```

Variants are `ApprovalInteraction`, `QuestionInteraction`,
`McpElicitationInteraction`, and `ExitPlanInteraction`. Each has its own typed
prompt and response schema. Plugin installation suggestions, authentication
forms, and unknown future requests stay visible as `UNSUPPORTED_READ_ONLY` and
cannot be forced through an approval payload.

Prompt bodies remain bound to the current live attachment unless Provider
enumeration proves a durable open-request representation. The durable ledger
may retain identity, kind, timestamps, hashes, claim and result evidence, but
must not imply it can reconstruct a missing live secret/prompt.

### 5.2 Claim/lease/respond/expire state

```text
OBSERVED_OPEN -> UNCLAIMED
UNCLAIMED -> CLAIMED (first authenticated CAS winner)
CLAIMED -> CLAIMED (same actor renews before deadline)
CLAIMED -> UNCLAIMED (release or lease expires while Provider remains open)
CLAIMED -> RESPONDING (response operation dispatch barrier committed)
RESPONDING -> RESOLVED (Provider canonical resolution)
RESPONDING -> OUTCOME_UNKNOWN (ambiguous response write)
UNCLAIMED|CLAIMED -> EXPIRED (Provider deadline)
UNCLAIMED|CLAIMED -> STALE (runtime fence lost; enumeration incomplete)
OUTCOME_UNKNOWN -> RESOLVED | OUTCOME_UNKNOWN (read-only reconcile)
```

Only one `ACTIVE` claim may exist. Claim tokens are random, single-interaction,
actor-bound, stored hashed at rest, and never accepted from another connection
principal. Default candidate lease is 30 seconds, renewable to but not beyond
the Provider expiry; the exact duration remains part of U-003 acceptance. A
socket disconnect does not immediately resolve the request; it stops renewal.

Response operations have no offline replay. Notification actions re-enter the
same authenticated claim/respond path and revalidate source, turn, request,
runtime fence, actor, and expiry. Auto approval is a Bridge policy consumer of
this interface, not a second interaction writer. It may claim/respond only on
a currently live Bridge-owned request and logs the policy revision and rule;
unknown/destructive cases fail closed.

## 6. Authoritative settings and effort

### 6.1 Snapshot

`ThreadSettingsSnapshotV1` is one typed tuple:

```ts
interface ThreadSettingsSnapshotV1 {
  target: ThreadLocator;
  settingsRevision: bigint;
  completeness: "COMPLETE" | "SPARSE";
  snapshotHash: string;
  capabilitySnapshotId: string;
  model?: string;
  modelReasoningEffort?: "none" | "minimal" | "low" | "medium" |
    "high" | "xhigh" | "max" | "ultra" | { readonly unknown: string };
  serviceTier?: "standard" | "fast" | { readonly unknown: string };
  approvalPolicy?: string;
  approvalsReviewer?: string;
  sandboxMode?: string;
  collaborationMode?: "default" | "plan" | { readonly unknown: string };
  networkAccessEnabled?: boolean;
  additionalWritableRoots?: readonly string[];
  observedAt: string;
}
```

Unknown future values remain displayable but read-only. Service tier absence
does not make model/effort unknown. A sparse catalog value may enrich an older
value but may not clear it. Only `COMPLETE` can authoritatively clear a field.
Unknown fields/enums can be retained in the snapshot `extensions` for
round-trip display, but mutations never echo them blindly. If the available
Provider API requires replacing a whole settings object and the adapter cannot
prove preservation of every unknown value, the mutation fails with
`UNKNOWN_SETTING_PRESERVATION_UNPROVEN`.

### 6.2 Typed mutations and ACK/conflict

Settings mutations are separate variants: `SET_MODEL_AND_EFFORT`,
`SET_SERVICE_TIER`, `SET_PERMISSION_SANDBOX`, and
`SET_COLLABORATION_MODE`. Each carries `expectedSettingsRevision` and
`expectedSnapshotHash`. The Provider update must preserve every non-target
field. If the Bridge only has a sparse snapshot and cannot prove a partial RPC
preserves missing fields, it first obtains a complete snapshot or rejects with
`SETTINGS_COMPLETE_SNAPSHOT_REQUIRED`.

Successful response is operation-scoped and repeatable:

```ts
interface SettingsMutationAckV1 {
  operationId: string;
  status: "APPLIED";
  effectiveAt: "NEXT_TURN" | "RESTARTED_RUNTIME";
  snapshot: ThreadSettingsSnapshotV1; // authoritative readback
}
```

A duplicate admitted operation returns the same ACK. Conflict returns
`operationId`, `SETTINGS_REVISION_CONFLICT`, and the current authoritative
snapshot. Mobile optimistic rendering remains pending until this ACK; error,
timeout, source switch, or a newer snapshot rolls it back. The effort slider
may offer only values advertised for the selected model, and the exact chosen
value must appear in ACK/readback before animation or label becomes factual.

`restart_now` is not a flag smuggled into the same update. It is the typed
`RESTART_WITH_SETTINGS` operation: capture a complete snapshot, apply the
permission tuple, interrupt only if the exact turn is still active, record
whether interruption won the race, and use a strict Goal restart lease or an
ordinary empty-input continuation, never both.

## 7. Goal and Plan owner correction

### 7.1 Provider-backed Goal

Goal reads and writes target `ThreadLocator` directly and do not resume a
thread merely to access metadata. Mutations are typed as create/replace,
objective edit, status transition, budget change, and clear, even if several
map to Provider `thread/goal/set`.

Every mutation includes:

- `expectedGoalRevision` and a semantic fingerprint of presence, objective,
  status, token budget, and creation identity;
- nondecreasing usage counters only as observations, not edit-conflict fields;
- an operation ID/fingerprint and command-specific readback reconcile;
- no chat history item and no automatic offline replay.

Pause and clear take effect at Provider step boundaries and do not pretend to
interrupt the current turn. A `budgetLimited` Goal resumes only when the same
mutation raises/removes the budget as required by Provider rules. Permission
restart may resume only a lease matching thread, objective, budget, creation
time, paused watermark, and nondecreasing usage. Cleared/replaced/edited Goals
invalidate the lease.

The Bridge snapshot is rebuildable and never becomes a `product_document`.
If Provider lacks atomic compare-and-set, per-thread serialization plus a
pre-write authoritative read detects known conflicts, and the residual race is
recorded as `EXPERIMENT_REQUIRED`, not hidden.

### 7.2 Plan split

- Plan/update-plan items are normal typed timeline items with Provider item
  identity; in-place updates use canonical item identity, never text matching.
- entering/leaving Plan collaboration is `SET_COLLABORATION_MODE` and takes
  effect according to the authoritative settings ACK.
- ExitPlan is `ExitPlanInteraction`; accept/reject/feedback use its exact
  request, lease, and response operation. Accepting may start execution only
  after Provider confirms resolution. Rejecting keeps planning.
- no Plan annotation/product-document table or second writer exists in Phase 1.
- therefore the companion matrix deliberately has no client `MUTATE_PLAN`
  operation: Provider `update_plan` is a typed receive/materialization fact,
  collaboration is `SET_COLLABORATION_MODE`, and leaving the plan is
  `RESPOND_EXIT_PLAN`.

## 8. Relations and child lifecycle

### 8.1 Durable relation record

```ts
type RelationKind =
  | "ORDINARY_FORK"
  | "PERSISTED_SIDE_CHAT"
  | "SUBAGENT"
  | "REVIEW_CHILD"
  | "EDIT_REPLACEMENT";

interface DurableRelationV1 {
  relationId: string;
  source: SourcePartition;
  parentThreadId: string;
  childThreadId: string;
  kind: RelationKind;
  relationSource: "PROVIDER" | "CC_POCKET_PROVEN";
  boundaryTurnId?: string;
  creationOperationId?: string;
  providerRelationId?: string;
  lifecycle: "DISCOVERED" | "ACTIVE" | "IDLE" | "COMPLETED" |
    "FAILED" | "CANCELLED" | "UNKNOWN";
  relationRevision: bigint;
}
```

Parent and child must belong to the same authenticated source partition.
Provider relations win; `CC_POCKET_PROVEN` requires a Provider-confirmed child
plus the exact creation operation. Relations select ordinary conversation
repositories; they do not own history.

### 8.2 Ordinary Fork, edit replacement, and review

Ordinary Fork is a persisted Provider mutation with an exact stable turn
boundary (`lastTurnId` or `beforeTurnId` as certified for the build). It yields
a distinct durable child and `ORDINARY_FORK`. A returned parent ID, ephemeral
thread, ambiguous boundary, or cross-source child is rejected. Legacy
fork-then-rollback fallback is disabled until its two-mutation crash semantics
are explicitly designed and probed.

Edit/rewind is not silent history mutation. It creates a distinct
`EDIT_REPLACEMENT` child at the exact boundary; any replacement user input is a
subsequent `START_TURN` operation on the child. Review produces Provider turn
evidence and, when a review thread exists, `REVIEW_CHILD`.

### 8.3 Persisted and ephemeral Side Chat

Persisted Side Chat creates a distinct durable Provider child with
`threadSource=ccpocket_side_chat`, excludes inherited turns from the opened
view according to the certified Provider contract, inherits a complete
settings snapshot, and records `PERSISTED_SIDE_CHAT`. Repeating the same
operation returns the same child; lost receipt uses read-only child/relation
reconcile and never creates another child blindly.

Ephemeral Side Chat uses official in-memory fork semantics and a memory-only
relation:

```text
OPENING -> ACTIVE -> CLOSING -> CLOSED
OPENING|ACTIVE -> LOST_ON_RUNTIME_FENCE
OPENING -> OUTCOME_UNKNOWN (ambiguous write; no replay)
```

The registry key includes source, parent, child, Provider instance, and runtime
fence. Bridge/Mobile restart intentionally does not restore transcript or claim
that the child still exists. Its creation operation remains auditable solely
to prevent blind duplicate dispatch.

### 8.4 Subagent

Subagent discovery uses Provider `source.subagent`/parent/ancestor evidence,
not catalog title or preview. Child conversations use normal catalog/read/live
repositories. Phase 1 freezes:

- list page at most 100, at most 20 pages/2,000 discovered descendants per
  bounded request;
- history projection at most 400 normalized messages/512 KiB per response;
- at most 8 activity watches per client;
- source/parent/ancestor validation on every list, history, watch, and jump;
- unsubscribe/cancel of watch is local and idempotent;
- canceling the subagent itself is disabled until the pinned Provider exposes
  a certified exact-child cancellation API and terminal evidence.

Unknown raw status remains visible with normalized `UNKNOWN`; it is not
silently made idle/completed. Internal subagents stay out of the primary Home
catalog and appear under their owning conversation.

## 9. Typed wire pressure

Phase 1 needs a finite typed union and these projections; exact envelope names
may be reconciled with the wire/storage draft, but their semantics are not
optional.

| Contract | Required content |
|---|---|
| `operation.submit.v1` | common identity/fingerprint fields plus one schema-generated mutation variant; no arbitrary command string/map |
| `operation.state.v1` | operation revision, typed state, lane revision, accepted/provider/canonical evidence, typed problem, retry policy derived by Bridge |
| `operation.reconcile.v1` | operation key and requested evidence refresh only; cannot contain original payload or dispatch flag |
| `queue.snapshot.v1` | full bounded queue, lane revision, entry revisions/digests, limit, dispatch owner |
| `queue.edit.v1` / `queue.cancel.v1` | exact entry/root operation and expected revisions |
| `interaction.snapshot.v1` | source/thread/turn/request/fence, variant, state, expiry, claim owner display token, live payload availability |
| `interaction.claim/renew/release/respond.v1` | exact interaction, expected revision, lease token where applicable; actor injected by Bridge |
| `settings.snapshot.v1` | complete/sparse typed tuple, revision/hash/capability evidence |
| four typed settings mutations plus `settings.ack/conflict.v1` | exact target fields and authoritative readback |
| `goal.snapshot.v1` and five typed Goal mutations | expected semantic revision/fingerprint, operation-scoped result/conflict |
| `relation.snapshot/delta.v1` | source-scoped relations with revision and gap semantics |
| `ephemeral_child.snapshot.v1` | current runtime-fenced registry only, never durable replay |

Common limits: serialized UTF-8 control envelope at most 65,536 bytes and its
payload at most 57,344 bytes; IDs at most 256 UTF-8 bytes (operation and request
IDs at most 128); ordinary text 32,768 bytes; serialized interaction answer body
49,152 bytes; structured refs 64; queue 16; no inline artifact/image/file bytes. Oversize is
`PAYLOAD_TOO_LARGE` before admission and cannot create a partial operation.

Durable server events require source partition, stream, sequence, aggregate
ID/revision, payload hash, and ACK-after-Mobile-SQLite-commit. Live/ephemeral
events are separate memory-only envelopes and never share a durable sequence.

## 10. DDL pressure and constraints

This draft does not authorize a migration. The integrated Phase 1 DDL must at
least express the following; application-only prose is insufficient where
SQLite can reject invalid state directly.

### 10.1 Bridge

- `session` and every dependent row use a composite source/thread key;跨端 Provider
  thread ID is unique only inside `(bridge_identity_id, bridge_instance_id,
  codex_source_id)`。Bridge-local DDL 可由 installation metadata 隐式固定前两项，
  但 wire、manifest、Mobile 与 export 仍必须显式完整。
- `operation` primary key is source/thread/operation; actor principal and
  fingerprint are immutable; state is a constrained enum; `OUTCOME_UNKNOWN`
  cannot carry replay permission.
- `operation_lane` has one row per thread/lane with `lane_revision` and one
  nullable dispatch owner FK. CAS owns all revision changes.
- `queue_entry` references one root `START_TURN` operation, has a unique item
  ID and FIFO ordinal within the lane, and stores current payload revision/hash.
- `dispatch_attempt` stores the exact dispatched payload hash and lane/entry
  revision; a partial unique index permits one active attempt per lane.
- `operation_event.state` is the same constrained enum as `operation.state`;
  revisions are contiguous under the writer transaction.
- `interaction` has composite session ownership and typed variant/state.
- `interaction_claim` uses `CREATE UNIQUE INDEX ... ON interaction_claim(interaction_id) WHERE state='ACTIVE'`; nullable-slot uniqueness is forbidden.
- `settings_head` is unique per source/thread and stores revision,
  completeness, hash, and typed snapshot version.
- `goal_head` is a rebuildable Provider projection unique per source/thread;
  no Goal product-document row.
- `session_relation` uses composite FKs proving both parent and child belong to
  the row's source, plus a unique `(source,parent,child,kind)` constraint.
- ephemeral Side Chat transcript/relation does not enter durable relation or
  timeline tables.

### 10.2 Mobile

- `local_operation_intent` is a protected namespace keyed by source hint,
  thread locator, and operation ID; it has no cascading FK from rebuildable
  session replica.
- operation, queue, interaction, settings, Goal, and relation replicas are
  source-scoped rebuildable projections applied only by the durable inbox
  writer.
- queue edit/cancel optimistic state never overwrites a greater lane revision.
- claim tokens are not persisted as reusable authority; at most an opaque
  actor-bound current-lease handle is kept under protected storage.
- deleting/clearing conversation replicas cannot delete drafts, offline
  intents, credentials, transfer checkpoints, or settings preferences.

### 10.3 Deliberately failing storage vectors

The integrated DDL test must reject:

1. same operation key with a different fingerprint or actor;
2. two active dispatch owners/attempts in one lane;
3. queue edit at an old lane or entry revision;
4. two active claims for one Interaction;
5. claim token reused by another actor;
6. relation whose child belongs to another source/thread partition;
7. settings/Goal head attached to another source;
8. operation event state not legal for the operation kind;
9. `OUTCOME_UNKNOWN` marked replayable;
10. session replica deletion removing a protected draft/local intent.

## 11. Cross-device and crash fault vectors

| Vector | Required result |
|---|---|
| two devices submit same operation ID/digest under different actors | original actor's state is not leaked as authority; second actor gets `OPERATION_ACTOR_MISMATCH`, no Provider call |
| same actor resubmits same ID/digest after lost ACK | existing state/ACK returned; no new dispatch |
| same ID with edited text | `OPERATION_FINGERPRINT_CONFLICT` |
| edit/cancel races queue-head dispatch | exactly one CAS wins; loser gets latest queue snapshot |
| crash after `PREPARED`, before `CALL_STARTED` | `DEFINITIVE_NOT_DISPATCHED`, subject to certified safe requeue |
| crash after `CALL_STARTED`, before receipt | `OUTCOME_UNKNOWN`; no automatic replay |
| Provider executes start, receipt is lost | reconcile durable user item/turn or remain unknown; never append a second optimistic canonical row |
| provider receipt arrives before durable user item | `PROVIDER_ACCEPTED`, not success; outgoing remains one logical pending row until canonical observation |
| stop races natural completion | record whether stop was accepted and the actual Provider terminal outcome; do not claim interrupted merely from request ACK |
| steer races turn replacement | exact `expectedTurnId` fails closed and queue item remains unless consume CAS already crossed the ambiguity barrier |
| app-server reports idle before compact terminal | queue remains blocked until compact terminal/timeout reconcile boundary, then drains one item |
| settings operation races another device | one expected revision wins; loser receives current complete snapshot |
| sparse settings snapshot omits effort | effort remains unknown/previously known and write blocks unless safe partial preservation is proven |
| Goal usage grows during an objective edit | usage-only growth is not a false conflict |
| Goal is cleared/replaced during permission restart | restart lease fails; old Goal is never resumed |
| two devices claim/respond | first valid claim wins; second is read-only; ambiguous first response is never replayed |
| claim expires during response barrier | Provider-open check and lease CAS decide; no late actor response writes |
| persisted Side Chat create receipt lost | child/relation read-only reconcile or unknown; no blind second child |
| Bridge crashes with ephemeral Side Chat | memory child projection is lost/expired; no durable transcript restoration claim |
| subagent result from another source/ancestor | quarantined, not attached to parent or Home catalog |
| Mobile replica is cleared or source changes | protected drafts/intents survive but cannot submit until current authenticated identity matches |

## 12. Current source locations and required cut points

| Current source | Observed behavior/fact | Phase 1 cut point |
|---|---|---|
| `packages/bridge/src/input-delivery-ledger.ts` (`recoveryPlan`, `admit`, `updateQueued`, `markDispatching`) | JSON ledger has source/thread/client identity and limit 16, but can replay some `provider_dispatching` start records via `clientUserMessageId`; queue edits lack expected revision | characterize, then replace replay decision and revision ownership with OperationKernel; do not inherit the file schema as target DDL |
| `packages/bridge/src/session.ts` (`restoreInputDeliveryState`, `queueCodexInputDurably`, `drainCodexQueue`, `steerCodexQueuedInput`) | memory queue plus ledger; queue is removed and user history echoed around Provider dispatch | move queue CAS/dispatch barrier to OperationKernel; canonical user item enters only through receive/materialization |
| `packages/bridge/src/websocket.ts` `case "input"`, queue cases, `forkCodexSession`, durable settings/Goal handlers | giant router coordinates admission, history append, Provider call, settings, Goal, fork | retain transport/auth validation; dispatch to typed application services |
| `packages/bridge/src/codex-process.ts` (`sendInputStructured`, `steer*`, `compactThread`, `forkThreadById`, Goal/settings RPCs) | real Provider adapter and build-specific behavior | retain behind finite typed provider adapter; it cannot decide Bridge operation success or Mobile projection |
| `packages/bridge/src/codex-action-broker*.ts` | durable identity-only claims and response ambiguity already exist | retain useful generation/claim evidence; replace client `claimantId` with authenticated context and converge states with Interaction contract |
| `packages/bridge/src/local-features/slots/codex-action-broker-protocol.ts` | `respond_codex_action` accepts payload `claimantId` | delete as authority; optional echoed ID is equality check only |
| `packages/bridge/src/codex-goal-controller.ts` | Provider-backed per-session serialization and semantic conflict checks | adapt to source-scoped GoalStatePort plus operation ledger/readback |
| `packages/bridge/src/local-features/codex-core-actions.ts` | compact/review have typed feature messages but only in-memory active set and request result | port each mutation to operation admission/barrier; keep MCP status read outside mutation lane |
| `packages/bridge/src/local-features/{persisted-side-chat,ephemeral-side-chat,subagents}.ts` | both Side Chat modes and bounded subagent reads exist | preserve product effects; publish through RelationGraph, not a second protocol/history core |
| `apps/mobile/lib/services/bridge_service.dart` (`send`, offline queue restore/flush) | transport, ephemeral RPC and persistent offline policy are mixed; input restart recovery already avoids automatic resend | split transport from LocalIntentStore/typed clients; keep authenticated identity fence |
| `apps/mobile/lib/features/chat_session/state/chat_session_cubit.dart` | pending/canonical correlation, queue/settings/Goal/Interaction state and retry live together | consume repositories; retain page view state only |
| `apps/mobile/lib/models/messages.dart` and local-feature protocol slots | large mixed wire/domain/presentation types | generated finite cross-language DTO at wire boundary; handwritten domain/presentation mapping |

## 13. Minimal interfaces to freeze in Phase 1

```ts
interface OperationPortV1 {
  submit(context: AuthenticatedExecutionContextV1, mutation: MutationV1): Promise<OperationSnapshotV1>;
  get(key: OperationKeyV1): Promise<OperationSnapshotV1>;
  reconcile(key: OperationKeyV1): Promise<OperationSnapshotV1>;
  queue(thread: ThreadLocatorV1): Promise<QueueSnapshotV1>;
}

interface InteractionPortV1 {
  listOpen(thread: ThreadLocatorV1): Promise<InteractionSnapshotV1>;
  claim(context: AuthenticatedExecutionContextV1, request: ClaimInteractionV1): Promise<InteractionSnapshotV1>;
  renew(context: AuthenticatedExecutionContextV1, request: RenewClaimV1): Promise<InteractionSnapshotV1>;
  release(context: AuthenticatedExecutionContextV1, request: ReleaseClaimV1): Promise<InteractionSnapshotV1>;
  respond(context: AuthenticatedExecutionContextV1, response: InteractionResponseV1): Promise<OperationSnapshotV1>;
}

interface ThreadSettingsPortV1 {
  read(thread: ThreadLocatorV1, requireComplete: boolean): Promise<ThreadSettingsSnapshotV1>;
  mutate(context: AuthenticatedExecutionContextV1, mutation: SettingsMutationV1): Promise<SettingsMutationAckV1>;
}

interface GoalStatePortV1 {
  read(thread: ThreadLocatorV1): Promise<GoalSnapshotV1>;
  mutate(context: AuthenticatedExecutionContextV1, mutation: GoalMutationV1): Promise<OperationSnapshotV1>;
}

interface RelationPortV1 {
  list(parent: ThreadLocatorV1, cursor?: string): Promise<RelationPageV1>;
  create(context: AuthenticatedExecutionContextV1, mutation: RelationMutationV1): Promise<OperationSnapshotV1>;
  watchEphemeral(parent: ThreadLocatorV1, runtimeFence: string): AsyncIterable<EphemeralChildSnapshotV1>;
}
```

`MutationV1`, `SettingsMutationV1`, `GoalMutationV1`,
`InteractionResponseV1`, and `RelationMutationV1` are closed generated unions
of the applicable client-command rows in the companion matrix, not
`{kind:string,payload:Map}`。`EXPIRE_INTERACTION` 是内部 state transition，不进入
client union；retry/resend 继续使用新的 `START_TURN` 加 `retryOfOperationId`，不再定义
第二个 `RETRY_START_AS_NEW` discriminant。

## 14. Open facts and Phase 2 remainder

### Experiments that still block implementation

- `OP-E01`: exact target Codex build, `clientUserMessageId` behavior, and
  command-specific Provider idempotency/correlation for start/steer/stop;
- `OP-E02`: crash injection around `PREPARED`, `CALL_STARTED`, Provider write,
  receipt and authoritative reread;
- `INT-E01`: complete open-interaction enumeration and exact response terminal
  correlation after reconnect/runtime replacement;
- `SET-E01`: authoritative complete settings read, atomic/partial update
  preservation, effort values per model, readback, and cross-client conflict;
- `GOAL-E01`: Provider Goal preflight/write/readback race and whether an atomic
  compare-and-set exists;
- `REL-E01`: fork boundary/result identities, persisted/ephemeral behavior,
  review child relation, subagent parent/ancestor persistence and exact cancel;
- `COMPACT-E01`: compact receipt/terminal order, idle-before-terminal behavior,
  and cache repair boundary.

### Product decisions preserved, not silently decided here

- U-001 new ordinary messages created fully offline: safe default remains
  hold-for-confirmation;
- U-002 risky resend/abandon while `OUTCOME_UNKNOWN`: safe default blocks later
  Provider mutation;
- U-003 multi-device claim presentation/lease duration: first authenticated
  claim is the correctness default; final UX is pending;
- Codex build/version support policy remains a release-level decision.

### Phase 2 owns

- visual queue/outbox wording, multi-device claim owner presentation, conflict
  dialogs, risky-resend expert UX, Goal manager layout, Plan cards, Side Chat
  panes/dock, subagent panel, and action sheet polish;
- effort fire/particles/RTL/reduced-motion/frame budget and GPL attribution,
  while Phase 1 owns only the value-to-authoritative-setting contract;
- auto-approval rule editor/audit presentation; Phase 1 only freezes its
  fail-closed Interaction consumer interface;
- long-list pagination UX, relation navigation, ephemeral close affordances,
  and notification actions;
- device/runtime/native acceptance and all release gates.

Phase 2 may consume these interfaces but may not add a second queue, operation
ledger, interaction claimant, settings owner, Goal store, Plan document, or
child timeline.
