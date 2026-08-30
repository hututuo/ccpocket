# PVMC-1 compact authority amendment

Date: `2026-08-30`

Status: `REVIEW_CANDIDATE / NORMATIVE_UPON_ACCEPTANCE` for the
`PHONE_VERIFIABLE_MESSAGE_CORE_CANDIDATE` implementation batch. These exact bytes become
normative only after independent review reports document-local `P0=0/P1=0` and the unchanged
file is recorded in an immutable implementation-branch commit.

This amendment closes the byte-shape, digest-mode, TIMELINE staging, active-machine, and
Mobile admission-lookup gaps left open by the accepted design through `8a761580`. It is
Timeline-only. It does not activate Catalog, Settings, Goal, Relation, Transfer, Native, or
any PX product profile, and it does not authorize formal generation, runtime activation, or
release.

Where an older candidate, donor, schema, DDL, or prose uses a different reachable shape, this
amendment wins for PVMC-1. `additionalProperties` is false for every object below. `Id`,
`Sha256Hex64`, safe-integer, revision, epoch, and decimal types retain their generated closed
definitions.

## 1. Subject and Provider-read identity

The stable scope and one materialization instance are different types:

```text
SourcePartitionV1 = {
  bridgeIdentityId: Id,
  bridgeInstanceId: Id,
  codexSourceId: Id
}

ThreadRefV1 = {
  sourcePartition: SourcePartitionV1,
  providerThreadId: Id
}

TimelineSubjectScopeV1 = {
  domain: "TIMELINE",
  threadRef: ThreadRefV1
}

TimelineMaterializationSubjectV1 = {
  domain: "TIMELINE",
  threadRef: ThreadRefV1,
  materializationId: Id
}
```

`TimelineSubjectScopeV1` is exactly the structural projection obtained by deleting only
`materializationId` from `TimelineMaterializationSubjectV1`. Read, repair, and dominance use
the stable scope. Materialization preimages use the materialization subject. Every outer
`sourcePartition` must exact-equal `subject.threadRef.sourcePartition`. The aliases `source`,
`threadId`, `TimelineSubjectV1`, and `{scope, materializationId}` are forbidden reachable forms.

The stable read plan and one exact Provider attempt are different authorities. The plan is the
comparison key shared by cursor continuation and `notLoaded -> full` repair; the attempt remains
fully bound to the actual view, limit, and opaque cursor:

```text
TimelineReadPlanPreimageV1 = {
  digestDomain: "ccpocket.timeline-read-plan.v1",
  sourcePartition: SourcePartitionV1,
  subjectScope: TimelineSubjectScopeV1,
  providerMethod: "thread/turns/list",
  sortDirection: "asc" | "desc",
  orderingContract: "CODEX_THREAD_TURNS_PROVIDER_ORDER_V1"
}

TimelineReadPlanV1 = TimelineReadPlanPreimageV1 + {
  readPlanDigest: Sha256Hex64
}

TimelineProviderReadSpecPreimageV1 = {
  digestDomain: "ccpocket.timeline-provider-read-spec.v1",
  sourcePartition: SourcePartitionV1,
  subjectScope: TimelineSubjectScopeV1,
  readPlanDigest: Sha256Hex64,
  providerMethod: "thread/turns/list",
  sortDirection: "asc" | "desc",
  itemsView: "notLoaded" | "full",
  limit: PositiveJsonSafeInteger,
  cursor: string | null
}

TimelineProviderReadSpecV1 = TimelineProviderReadSpecPreimageV1 + {
  readSpecDigest: Sha256Hex64
}
```

The resolved plan supplies method/direction/order. The resolved certification supplies the
upper bound for `notLoaded` `limit`; PVMC-1 requires `itemsView="full" => limit=1`. The four
cursor occurrences are all required nullable fields: `resolvedReadSpec.cursor`,
`readBody.cursor`, `readBody.returnedCursor`, and `normalizedResult.returnedCursor`. Absence and
`null` never become two byte representations. A non-null returned cursor that equals the
request cursor, or any cursor already seen by the same bounded read coordinator, is
non-advancing: it authorizes no further request, proves no adjacency, and can produce only a
partial observation with reason `READ_FAILED` while preserving last-good. With zero strong Turn
facts that observation uses the unique scope-only `COVERAGE_UNKNOWN` Gap. With one or more valid
islands, the attempt either fails without materializing or retains those exact islands and emits
the canonical `BEFORE|AFTER|BETWEEN` Gap selected by its real strong anchors and direction. A
non-advancing cursor never turns a non-empty candidate into `COVERAGE_UNKNOWN` and never
authorizes another request.

`TimelineReadAttemptRevision1` is a generated semantic alias of `PositiveRevision`. It is the
monotonic read-attempt revision within one exact `(sourcePartition, subjectScope, sourceEpoch,
providerInstanceEpoch)` tuple; it is not an aggregate/head revision and resets only when either
epoch changes.

```text
TimelineReadAttemptRevision1 = PositiveRevision

TimelineProviderReadBodyV1 = {
  providerMethod: "thread/turns/list",
  sortDirection: "asc" | "desc",
  readPlanDigest: Sha256Hex64,
  itemsView: "notLoaded" | "full",
  limit: PositiveJsonSafeInteger,
  cursor: string | null,
  returnedCursor: string | null,
  resultKind: "TURN_INDEX" | "FULL_TURNS" | "OVERSIZED_TURN",
  resultCount: Ordinal0,
  resultDigest: Sha256Hex64,
  sourceEpoch: BoundEpoch1,
  providerInstanceEpoch: BoundEpoch1,
  readGeneration: TimelineReadAttemptRevision1,
  codexExecutableDigest: Sha256Hex64
}

TimelineProviderReadEvidencePreimageV1 = {
  digestDomain: "ccpocket.timeline-provider-read-evidence.v1",
  readEvidenceId: Id,
  sourcePartition: SourcePartitionV1,
  subjectScope: TimelineSubjectScopeV1,
  readPlanDigest: Sha256Hex64,
  readSpecDigest: Sha256Hex64,
  codexCertificationId: Id,
  codexCertificationDigest: Sha256Hex64,
  readBody: TimelineProviderReadBodyV1
}

TimelineProviderReadEvidenceV1 = TimelineProviderReadEvidencePreimageV1 + {
  readEvidenceDigest: Sha256Hex64
}
```

The normalized Provider result has its own closed view-discriminated turn union. A not-loaded
index row is deliberately not a `TimelineTurnSpineV1` and cannot assert item count or item
bounds:

```text
TimelineTurnIndexV1 = {
  turnRef: TurnRefV1,
  turnOrdinal: SignedJsonSafeInteger,
  predecessorTurnRef: TurnRefV1 | null
}

TimelineProviderFullTurnV1 = {
  turnSpine: TimelineTurnSpineV1,
  providerReportedItemCount: Ordinal0,
  observedTurnByteCount: UInt64Decimal,
  maximumTurnByteCount: 4194304,
  orderedItems: [TimelineItemV1]
}

TimelineOversizedTurnObservationV1 = {
  turnIndex: TimelineTurnIndexV1,
  providerReportedItemCount: Ordinal0,
  observedTurnByteCount: UInt64Decimal,
  maximumTurnByteCount: 4194304,
  indexReadEvidenceId: Id,
  indexReadEvidenceDigest: Sha256Hex64
}

TimelineProviderReadResultPreimageV1 =
  | { digestDomain: "ccpocket.timeline-provider-read-result.v1",
      resultKind: "TURN_INDEX",
      sourcePartition: SourcePartitionV1,
      subjectScope: TimelineSubjectScopeV1,
      readPlanDigest: Sha256Hex64,
      readSpecDigest: Sha256Hex64,
      returnedCursor: string | null,
      resultCount: Ordinal0,
      orderedTurnIndexes: [TimelineTurnIndexV1] }
  | { digestDomain: "ccpocket.timeline-provider-read-result.v1",
      resultKind: "FULL_TURNS",
      sourcePartition: SourcePartitionV1,
      subjectScope: TimelineSubjectScopeV1,
      readPlanDigest: Sha256Hex64,
      readSpecDigest: Sha256Hex64,
      returnedCursor: string | null,
      resultCount: Ordinal0,
      orderedTurns: [TimelineProviderFullTurnV1] }
  | { digestDomain: "ccpocket.timeline-provider-read-result.v1",
      resultKind: "OVERSIZED_TURN",
      sourcePartition: SourcePartitionV1,
      subjectScope: TimelineSubjectScopeV1,
      readPlanDigest: Sha256Hex64,
      readSpecDigest: Sha256Hex64,
      returnedCursor: string | null,
      resultCount: 1,
      oversizedTurn: TimelineOversizedTurnObservationV1 }
```

`itemsView="notLoaded"` exact-correlates only with `TURN_INDEX`; `itemsView="full"` exact-correlates
only with `FULL_TURNS|OVERSIZED_TURN`. Every FULL turn requires
`turnSpine.itemCount=providerReportedItemCount=orderedItems.length`; its true zero-item case is therefore proved only by
full evidence, and its parsed decimal byte count is at most 4194304. An index or oversized branch never enters staging as a `TURN_SPINE` and never
proves a real zero-item Turn. TURN_INDEX/FULL_TURNS `resultCount` exact-equals their ordered
array length; OVERSIZED_TURN requires `resultCount=limit=1` and a decimal byte count strictly
greater than 4194304. Every result count is at most the resolved/read-body `limit`. Provider raw DTOs, bodies,
paths, credentials, timestamps, and latency do not enter these objects. If raw response bytes
are retained, their optional `responseDigest` is a separate `STANDARD_EXACT_BYTES` digest and
cannot replace `resultDigest`.

`observedTurnByteCount` is the canonical decimal string of
`UTF8Length(RFC8785(validatedPlainProviderTurnDto))`, measured before item normalization under
the same depth/node/plain-data gates as the adapter. The raw DTO itself is not embedded. A FULL
branch requires this count `<=4194304`; OVERSIZED requires `>4194304` and exact-equals the Gap
target and resolved evidence.

For OVERSIZED, `indexReadEvidenceId/digest` resolves one prior valid evidence object whose spec
has `itemsView="notLoaded"`, whose normalized result is `TURN_INDEX`, and whose ordered indexes
contain `oversizedTurn.turnIndex` exactly once. That index evidence and the current oversized
evidence exact-equal only sourcePartition, subjectScope, readPlanDigest, certification ID/digest,
sourceEpoch, providerInstanceEpoch, and codexExecutableDigest. Their readSpecDigest, resultDigest,
and readEvidence ID/digest are distinct and each resolves its own validated object; none is
required equal. The index `readGeneration` is strictly earlier than the current oversized
generation in that same epoch tuple, and the attempt specs differ as required by notLoaded
versus full. The current evidence resolves an `OVERSIZED_TURN` result containing this
exact observation. The staged INDEX Turn exact-equals `oversizedTurn.turnIndex`, including its
predecessorTurnRef. The Gap target exact-equals TurnRef, turnOrdinal, providerReportedItemCount,
observed/max byte counts, current oversized evidence ID/digest, problem, and disposition;
nullable neighbor boundaries are independently recomputed from the staged island.

The four cursor occurrences and every duplicated read fact are bound by exact equality:

| Fact | Required equality |
|---|---|
| stable plan | plan/source/scope/method/direction/order bytes recompute `readPlanDigest`; spec, body, evidence, result, begin, receipt, repair intent, and dominance key exact-equal it |
| request cursor | `readBody.cursor == resolvedReadSpec.cursor` |
| result cursor | `readBody.returnedCursor == normalizedResult.returnedCursor` |
| method/direction/view/limit | plan supplies method/direction; each `readBody` view/limit exact-equals resolved attempt spec |
| result kind/count/digest | body kind exact-equals the normalized-result union tag; count equals the selected array length (or exact `1` for oversized), is `<= readBody.limit == resolvedReadSpec.limit`, and digest exact-equals the normalized result |
| source partition | spec, evidence, result, proof, every materialization subject, and authenticated source all exact-equal |
| stable subject scope | plan, spec, evidence, result, empty proof, repair intent, and dominance key exact-equal; deleting only `materializationId` from every outer current proof/page/manifest/begin/receipt/commit subject and every historical subject yields those exact bytes |
| current materialization subject | only the outer `subject` fields of order proof, page, manifest, EventKey/begin, receipt, and commit exact-equal including current `materializationId`; they are never byte-compared directly with stable scope |
| historical materialization subject | `CANONICAL_PREDECESSOR.sealedProof.baseSubject` and `PREVIOUS_HEAD_RETAINED.previousSubject` exact-equal the verified current last-good head, share source/stable scope with current, and use a different older `materializationId` |
| build/certification | executable digest, provider epoch, read generation, and certification exact-equal resolved evidence |

Every outer `(sourcePartition,subjectScope)` pair exact-equals
`subjectScope.threadRef.sourcePartition`; every current or historical materialization subject
has the same source projection. `notLoaded` contributes Turn index/order knowledge only. Full
results carry exact normalized Provider-order Items or the typed oversized branch. A non-null
advancing returned cursor may authorize another bounded read but does not prove cross-result
adjacency. A terminal full-scope empty proof requires full view, initial-scope spec,
`resultCount=0`, and `returnedCursor=null`.

Resolved evidence must exact-bind the spec, source, scope, runtime fences, executable, and the
resolved certification. The global `CodexAdapterCertificationV1` must prove exact build/schema/
probe evidence and the runtime facts `thread/turns/list=AVAILABLE`,
`thread/items/list=RUNTIME_UNAVAILABLE`, and
`thread/timeline/list=RUNTIME_UNAVAILABLE`, including the certified opaque cursor, direction,
view, identity, and ordering semantics. TIMELINE preimages serialize evidence and certification
references only as the flat `id + digest` pairs shown below; no nested ref object is reachable:

```text
TimelineOrderProofPreimageV1 = {
  digestDomain: "ccpocket.order-proof.v1",
  sourcePartition: SourcePartitionV1,
  subject: TimelineMaterializationSubjectV1,
  from: TimelineOrderEndpointV1,
  to: TimelineOrderEndpointV1,
  readEvidenceId: Id,
  readEvidenceDigest: Sha256Hex64,
  codexCertificationId: Id,
  codexCertificationDigest: Sha256Hex64,
  pageIndex: PageIndex0To127,
  sealedProof: TimelineSealedOrderProofV1
}

TimelineBoundOrderProofV1 = TimelineOrderProofPreimageV1 + {
  proofDigest: Sha256Hex64
}

TimelineTypedEmptyProofV1 = {
  proofKind: "FULL_SCOPE_PROVIDER_EMPTY",
  sourcePartition: SourcePartitionV1,
  subjectScope: TimelineSubjectScopeV1,
  readPlanDigest: Sha256Hex64,
  readSpecDigest: Sha256Hex64,
  readEvidenceId: Id,
  readEvidenceDigest: Sha256Hex64,
  codexCertificationId: Id,
  codexCertificationDigest: Sha256Hex64
}
```

An order proof carries the two refs; begin carries `readPlanDigest`, `readSpecDigest`, both refs,
and one complete `readBody`; receipt carries both digests and both refs. They do not embed
drifting copies of the full plan, attempt spec, evidence, or certification. A typed empty proof
is valid only when the resolved full-view spec covers the full declared scope and resolved
evidence exact-equals `resultCount=0` and `returnedCursor=null`. It has no independent proof
digest.

The stable coordinate amendment is explicit. `TimelineTurnIndexV1.turnOrdinal` and
`TimelineItemV1.timelineOrdinal` are `SignedJsonSafeInteger`; an older prepend can therefore use
negative values without renumbering an already published window. Within one island they remain
strictly ordered and adjacent values differ by one, but they need not start at zero.
`TimelineItemV1.itemOrdinal` remains `Ordinal0`, starts at zero inside each turn, and is
contiguous. This signed-coordinate rule supersedes only the conflicting “all three ordinals
start at zero” sentence in 07; `islandOrdinal` remains zero-based and contiguous.

```text
TimelineTurnSpineV1 = {
  turnRef: TurnRefV1,
  turnOrdinal: SignedJsonSafeInteger,
  predecessorTurnRef: TurnRefV1 | null,
  firstTimelineOrdinal: SignedJsonSafeInteger | null,
  lastTimelineOrdinal: SignedJsonSafeInteger | null,
  itemCount: Ordinal0
}

TimelineTurnNodeV1 =
  | { turnNodeKind: "INDEX", turnIndex: TimelineTurnIndexV1 }
  | { turnNodeKind: "FULL", turnSpine: TimelineTurnSpineV1 }

TimelineResolvedPayloadV1 =
  | { kind: "text", text: string }
  | { kind: "image", imageRef: ImageRefV1 }
  | { kind: "structured_ref", structuredRef: CurrentStructuredAttachmentRefV1 }
  | { kind: "tool_summary", toolName: string, summary: string }

TimelinePayloadCommitmentPreimageV1 = {
  digestDomain: "ccpocket.timeline-payload-commitment.v1",
  payloadIndex: Ordinal0,
  payload: TimelineResolvedPayloadV1
}

TimelinePayloadV1 =
  | TimelineResolvedPayloadV1
  | { kind: "unavailable", payloadDigest: Sha256Hex64,
      missingField: "resolvedPayload" }

TimelineItemV1 = {
  itemRef: ItemRefV1,
  turnOrdinal: SignedJsonSafeInteger,
  itemOrdinal: Ordinal0,
  timelineOrdinal: SignedJsonSafeInteger,
  predecessorItemRef: ItemRefV1 | null,
  itemKind: "USER_MESSAGE" | "ASSISTANT_MESSAGE" | "REASONING" |
            "TOOL_CALL" | "TOOL_RESULT" | "UNKNOWN",
  payloads: array<TimelinePayloadV1, minItems=0, maxItems=64>,
  providerTypeName: string | null
}

TimelineTurnBoundaryV1 = {
  endpointKind: "TURN", turnRef: TurnRefV1,
  turnOrdinal: SignedJsonSafeInteger
}

TimelineItemBoundaryV1 = {
  endpointKind: "ITEM", itemRef: ItemRefV1,
  timelineOrdinal: SignedJsonSafeInteger
}

TimelineOrderEndpointV1 = TimelineTurnBoundaryV1 | TimelineItemBoundaryV1

TimelineStrongBoundaryV1 = TimelineOrderEndpointV1

TimelineProviderResultPositionV1 =
  | { positionKind: "TURN", turnIndex: Ordinal0 }
  | { positionKind: "ITEM", turnIndex: Ordinal0, itemIndex: Ordinal0 }

TimelineSealedOrderProofV1 =
  | { proofKind: "PROVIDER_PAGE_ORDER",
      fromPosition: TimelineProviderResultPositionV1,
      toPosition: TimelineProviderResultPositionV1 }
  | { proofKind: "CANONICAL_PREDECESSOR",
      baseSubject: TimelineMaterializationSubjectV1,
      baseHeadVersion: PositiveRevision,
      baseManifestDigest: Sha256Hex64 }

TimelineCoverageIslandV1 = {
  islandOrdinal: Ordinal0,
  startBoundary: TimelineStrongBoundaryV1,
  endBoundary: TimelineStrongBoundaryV1,
  minTurnOrdinal: SignedJsonSafeInteger,
  maxTurnOrdinal: SignedJsonSafeInteger,
  minTimelineOrdinal: SignedJsonSafeInteger | null,
  maxTimelineOrdinal: SignedJsonSafeInteger | null,
  turnCount: PositiveJsonSafeInteger,
  indexTurnCount: Ordinal0,
  fullTurnCount: Ordinal0,
  itemCount: Ordinal0
}
```

`TimelineTurnIndexV1` and `TimelineTurnSpineV1` share exactly the three index fields; a staged
Turn identity appears in exactly one node branch. For each full TurnSpine,
`firstTimelineOrdinal` and `lastTimelineOrdinal` are both null iff
`itemCount=0`; otherwise they are both required and exact-equal respectively the minimum and
maximum `timelineOrdinal` of that Turn's staged Items. No TurnSpine owns an additional
`timelineOrdinal`. A TURN endpoint carries and exact-equals its Turn node `turnOrdinal`; an ITEM
endpoint carries and exact-equals its Item `timelineOrdinal`.

For PVMC-1 every island `startBoundary/endBoundary` is a TURN endpoint exact-equal to its first
and last Turn node; ITEM island boundaries are unreachable until a future item-paging profile
adds a new reviewed branch. The two island Timeline ordinal bounds are both null exactly when
the staged `itemCount=0`; otherwise both are required. `indexTurnCount+fullTurnCount=turnCount`.
These staged counts do not turn an INDEX node into proof of a real zero-item Turn.
Start/end/min/max/counts are independently recomputed from referenced rows.
`islandId` is forbidden: `(subject.materializationId,islandOrdinal)` is the identity. The old
optional-item boundary object is replaced by the closed TURN/ITEM union. All nested refs and
coordinates exact-equal the staged TurnIndex/TurnSpine/Item rows.

`TimelineItemV1.predecessorItemRef` is null exactly for `itemOrdinal=0`; otherwise it exact-equals
the prior item in the same Turn and `itemOrdinal` increments by one. Item and parent Turn
ordinals exact-equal. `providerTypeName` is non-empty only for `itemKind="UNKNOWN"` and is null
for known kinds. Every payload branch is closed and independently capacity-checked. For every
available payload at dense array position `payloadIndex`, its commitment is exactly
`SHA256(RFC8785(TimelinePayloadCommitmentPreimageV1))`. An `unavailable.payloadDigest` commits
to the same domain, exact array position, and eventual complete `TimelineResolvedPayloadV1`;
repair must reveal bytes that recompute that digest. No other payload commitment preimage or
position-independent digest is valid.

A resolved `text` or `tool_summary` branch is reachable inline only when
`inlineTextByteCount<=40960`, where
`inlineTextByteCount=UTF8Length(RFC8785(exact complete TimelineResolvedPayloadV1 branch))`.
Raw string length, field-length summation, UTF-16 length, and unescaped text bytes are forbidden
substitutes. At `40961` or above, the adapter computes the commitment from that same complete
validated branch and emits the whole `unavailable` placeholder plus a `TimelineGapV1` whose
target/reason/repairKind/repairDisposition exact-equal the Item/PAYLOAD `CAPACITY_BOUNDARY`
branch of `TimelineGapRepairIntentPreimageV1` defined below. That closed Gap branch is the exact
capacity tuple meant here; no measured byte count or gate name becomes a durable semantic field.
The validator and boundary vectors independently reconstruct the complete branch's RFC8785 bytes
to prove the gate. The adapter never truncates, chunks, or invents a generic ContentRef lineage.
Any other resolved branch still must fit all page/payload/frame gates or uses that same committed
capacity-unavailable seam. Message images continue to use the accepted ImageRef/ContentRef
lineage. PVMC-1 intentionally chooses payload-unavailable for oversized non-image inline
payloads until a separate content lineage is reviewed.

The active proof union intentionally has only two branches. `PROVIDER_PAGE_ORDER` proves
immediate same-kind neighbors inside one exact normalized result: TURN positions require
`to.turnIndex=from.turnIndex+1`; ITEM positions require `itemsView="full"`, the same turnIndex,
and `to.itemIndex=from.itemIndex+1`. Position lookup must exact-equal the outer endpoints.
`CANONICAL_PREDECESSOR` requires the transaction's exact SEALED+VERIFIED last-good base head,
matching scope and certification, `baseHeadVersion` equal to the candidate parent, and a valid
base manifest/order reconstruction whose successor row has the outer predecessor. It is
forbidden for an initial, stale, rejected, quarantined, changed-certification, changed-edge, or
unavailable base head. The candidate version is exactly `baseHeadVersion+1`; the dependency is
valid only through the typed `PREDECESSOR_REFERENCE` edge in section 4, never through an
unstratified type-level manifest/proof edge.

`PROVIDER_PAGE_ORDER` is reachable only when the resolved certification exact-certifies
normalized canonical-display result order for the method/view/build in use. Generic build SHA or
method availability without those semantics is insufficient and rejects the proof.

`CURSOR_BOUNDARY` is unreachable for Codex 0.151.0 because opaque cursor continuation has not
been certified as mutation-safe adjacency. Bare `ADJACENCY` is also unreachable because
`{from,to}` is self-assertion, not evidence. Unsupported boundaries become typed BETWEEN Gaps.
A future cursor proof requires a new exact-build experiment and an outer one-read/two-read
evidence-binding union; a second evidence ref may not be hidden in `sealedProof`.
`CANONICAL_PREDECESSOR` is therefore an incremental publication branch: Mobile must already have
the exact base head/manifest. A fresh or mismatched replica must receive Provider-page proofs for
all edges or enter `SNAPSHOT_REQUIRED`; it never trusts the predecessor claim alone.

## 2. TIMELINE page rows and whole-block staging

For PVMC-1, the historical page-body key `items` means non-Gap TIMELINE staging rows, not only
message-body rows. This is the one explicit amendment needed to keep the required exact
`{items,gaps}` body while making every verifier input reachable by Mobile:

```text
TimelinePageStagedRowV1 =
  | { rowKind: "COVERAGE_ISLAND", coverageIsland: TimelineCoverageIslandV1 }
  | { rowKind: "TURN_INDEX", islandOrdinal: Ordinal0,
      turnIndex: TimelineTurnIndexV1 }
  | { rowKind: "TURN_SPINE", islandOrdinal: Ordinal0,
      turnSpine: TimelineTurnSpineV1 }
  | { rowKind: "TIMELINE_ITEM", islandOrdinal: Ordinal0,
      timelineItem: TimelineItemV1 }
  | { rowKind: "BOUND_ORDER_PROOF", islandOrdinal: Ordinal0,
      boundOrderProof: TimelineBoundOrderProofV1 }

TimelinePageBodyV1 = {
  items: [TimelinePageStagedRowV1],
  gaps: [TimelineGapV1]
}
```

Every union branch has exactly its listed payload. A `TimelineBoundOrderProofV1` contains the complete
sealed proof and its `proofDigest`; it is not a kind-only assertion. The typed empty proof is
not a page row: the `EMPTY_PROVEN` branch has `pageCount=0` and carries exactly one
`TimelineTypedEmptyProofV1` in begin and coverage.

The concatenation of `items` across pages is the canonical staging-row stream:

1. each `TimelineCoverageIslandV1` appears once, in increasing contiguous `islandOrdinal`, before every
   row that names that island;
2. each Turn identity appears once as exactly one `TURN_INDEX|TURN_SPINE` row in island/turn
   order; each turn predecessor is absent only for the first turn of its island and otherwise
   exact-equals the preceding Turn node;
3. each `TimelineItemV1` appears once after its parent full Turn, in contiguous nonnegative
   `itemOrdinal`; its predecessor is absent only for the first item of that turn;
4. each required `TimelineBoundOrderProofV1` appears once immediately after its `to` node row; the node
   and proof are one indivisible page-packing unit; its
   endpoints, evidence, certification, materialization subject, and containing `pageIndex`
   exact-equal the resolved rows; its `from` node must occur on the same or an earlier page and
   it cannot cross an island;
5. a page boundary may occur only between complete packing units. A row, or a `to` node and its
   incoming proof, is never split.

The independent staged reducer is hierarchical and executable, not an ordering hint. It groups
rows by `islandOrdinal`, requires exactly one island declaration, and builds one TURN chain per
island plus one separate ITEM chain per full Turn. It never performs a combined Turn+Item graph
walk and forbids every TURN-to-ITEM or ITEM-to-TURN predecessor/proof edge.

For each island, Turn nodes are ordered by signed `turnOrdinal`, adjacent ordinals differ by one,
the first predecessor is null, and each later predecessor exact-equals the prior TurnRef. The
first Turn has no incoming proof; each later Turn has exactly one TURN-to-TURN proof immediately
after its row. The island start/end are exact TURN endpoints for the first/last node.

For each full Turn, Items have `itemOrdinal=0..itemCount-1`. A zero-item full Turn has both bounds
null and no Item proof. A non-empty Turn's first Item has null predecessor/no proof; each later
Item exact-references the prior Item and has exactly one ITEM-to-ITEM proof immediately after its
row. Item `timelineOrdinal` values are contiguous across the island-to-turn-to-item traversal.
An INDEX Turn has no Item chain and makes no item-count/bounds assertion. Parent containment is
checked independently and is never represented by a cross-kind proof.

All island min/max/counts, full-Turn itemCount/bounds, Item parent/ordinal/predecessor, and
page-local row counts exact-equal recomputation. With `nonEmptyTurnCount` equal to the number of
full Turns whose itemCount is positive, the proof counts are exact:

```text
turnProofCount = turnCount - islandCount
itemProofCount = itemCount - nonEmptyTurnCount
boundOrderProofCount = turnProofCount + itemProofCount
```

Every staged proof is referenced exactly once by the order preimage; there are no extra proofs.

The complete staged node set has an exhaustive provenance partition even when a node has no
incoming proof. Retained nodes exact-reconstruct the current SEALED+VERIFIED base manifest/order;
new or refined nodes exact-reconstruct the entire current normalized result, with every result
position consumed exactly once. If the same stable ref occurs in both, the legal merge produces
one retained or INDEX-to-FULL-refined node rather than a duplicate. Initial candidates have an
empty retained set. A first Turn, each Turn's first Item, and a single-node candidate therefore
still need exact base or result provenance; absence of an incoming proof never permits a
caller-created node.

Concatenating staged TurnIndex/TurnSpine/Item rows must reconstruct all normalized-result entries,
including those used by every `PROVIDER_PAGE_ORDER` proof; resolving a
`CANONICAL_PREDECESSOR` must reconstruct the exact base manifest/order edge. Missing/extra/
duplicate result positions, base facts, nodes, or proofs, dangling parents/endpoints,
ordinal holes, cycles, endpoint-kind mixing, cross-Turn Item edges, source/thread/materialization
drift, reversed edges, unknown proof kinds, timestamp/arrival/ID/rowid sorting, or a proof
referenced zero or multiple times reject the whole block with unchanged last-good.

The concatenation of `gaps` is increasing contiguous `gapOrdinal`.
`gapContainingPageIndex(g)` is derived uniquely from the page whose `pageBody.gaps` contains
`g`; it is not another serialized authority field. Any staging column or capacity projection
named `anchorPageIndex` must exact-equal this derived value. Branch predicates are closed:

- `BEFORE.rightBoundary` exact-equals the first known island's `startBoundary`, and the Gap's
  containing page exact-equals that boundary row's page;
- `AFTER.leftBoundary` exact-equals the last known island's `endBoundary`, and the Gap's
  containing page exact-equals that boundary row's page;
- `BETWEEN.leftBoundary/rightBoundary` exact-equal respectively the `endBoundary` and
  `startBoundary` of adjacent islands `i` and `i+1`; its containing page exact-equals the right
  boundary row's page, while the left boundary is on that page or an earlier page;
- `PAYLOAD.itemRef` resolves exactly one staged Item and its containing page exact-equals that
  Item row's page;
- `TURN_PAYLOAD_NOT_LOADED` resolves exactly one staged INDEX Turn and its containing page
  exact-equals that Turn row's page;
- `TURN_PAYLOAD_OVERSIZED` resolves exactly one staged INDEX Turn, exact-equals its ordinal and
  neighboring nullable TURN boundaries, binds the resolved oversized evidence, and shares that
  Turn row's page;
- `COVERAGE_UNKNOWN.subjectScope` exact-equals the stable projection of the materialization
  subject and its containing page is page 0.

No BEFORE/AFTER/BETWEEN endpoint may resolve to any other node or island. Every pair of adjacent
islands `i,i+1` has exactly one BETWEEN Gap with those exact endpoints; missing or duplicate
separators reject. BEFORE and AFTER each occur at most once. COVERAGE_UNKNOWN requires zero
islands and is the unique structural Gap. Each ItemRef has at most one PAYLOAD Gap, whose missing
field set is already merged/canonical; each TurnRef has at most one of
TURN_PAYLOAD_NOT_LOADED/OVERSIZED. A non-empty COMPLETE structural projection therefore cannot
retain multiple unbridged islands.

The reverse cardinalities are mandatory. Every staged INDEX Turn has exactly one same-Turn
`TURN_PAYLOAD_NOT_LOADED|TURN_PAYLOAD_OVERSIZED` Gap, and every such Gap resolves exactly one
INDEX Turn. Every staged FULL Turn has zero Turn-payload Gaps. For each Item, the dense indexes
of all `unavailable` placeholders exact-equal the indexes in its one PAYLOAD Gap; at least one
unavailable exists iff that Gap exists. An Item with no PAYLOAD Gap has only resolved payloads.

For an oversized target, `leftTurnBoundary` exact-equals the previous Turn in the same island or
is null iff the target is first; `rightTurnBoundary` exact-equals the next Turn or is null iff
the target is last. Both cannot be non-null outside that island, and neither is an order proof by
itself.

BEFORE/AFTER are reachable only when the stable plan scope extends beyond the known endpoint and
resolved evidence does not terminally prove that scope boundary. COVERAGE_UNKNOWN is reachable
only when no strong Turn position can be normalized. Arbitrary padding Gaps are invalid.

`gapOrdinal` is derived, not writer-selected: BEFORE first; then island-to-turn-to-item display
order, with a Turn payload Gap immediately after its Turn node and an Item PAYLOAD Gap
immediately after its Item; then the one BETWEEN separator after each non-final island; AFTER
last. COVERAGE_UNKNOWN, when reachable, is the only Gap and has ordinal zero. The Gap and its
relevant same-page anchor are one indivisible page-packing unit. Anchor-page indexes must be
nondecreasing with this canonical ordinal.
If an anchor node also has an incoming proof, the node, that proof, and every Gap anchored to the
node form one combined indivisible packing unit; overlapping two independently placeable units
is forbidden.
A scope-only partial result may therefore use page 0 with `items=[]`; proven empty uses no page
and no Gap.

The writer may choose page boundaries, but must satisfy all of these invariants:

- `pageIndex` is contiguous `0..pageCount-1`, and `pageCount` is `0..128`;
- non-empty materializations use `1..128` pages;
- every emitted page contains at least one staged row or Gap; empty padding pages are forbidden;
- the RFC8785 UTF-8 byte length of each exact `TimelinePageBodyV1` is at most `262144`;
- the complete registered `materialization.page.v1` payload, including its metadata and body,
  is at most `57344` UTF-8 bytes and its complete envelope is at most `65536` bytes; therefore
  the active wire limit is normally stricter than the independent 256 KiB staging-body ceiling;
- an indivisible unit that cannot fit the 57344-byte payload gate must already have been
  normalized to a typed ContentRef/unavailable or Turn-oversized Gap; otherwise the whole
  candidate rejects and last-good remains unchanged;
- no logical row is duplicated or omitted across pages;
- page 0 has no previous digest; page `i>0` carries a `REFERENCE_EQUALITY` value equal to page
  `i-1`'s actual `pageDigest`;
- `orderedPageDigests[i]` names page `i`, and its length exact-equals `pageCount`.

The Registry reserves independent boundary-vector IDs and requires both sides of every gate:
`PVMC1_TURN_BYTES_4194304_ACCEPT/4194305_OVERSIZED`,
`PVMC1_INLINE_TEXT_BYTES_40960_ACCEPT/40961_UNAVAILABLE`,
`PVMC1_PAGE_BODY_262144_ACCEPT/262145_REJECT`,
`PVMC1_PAGE_PAYLOAD_57344_ACCEPT/57345_REJECT`, and
`PVMC1_PAGE_FRAME_65536_ACCEPT/65537_REJECT`. Passing one gate never implies another.
The two inline-text vectors must reconstruct and measure the exact complete RFC8785 serialized
resolved branch, not its raw fields, and include quote, backslash, newline, and control-character
escaping cases whose canonical serialized length is exactly `40960` or `40961` bytes.

The closed digest preimage is:

```text
TimelineMaterializationPagePreimageV1 = {
  digestDomain: "ccpocket.materialization-page.v1",
  sourcePartition: SourcePartitionV1,
  subject: TimelineMaterializationSubjectV1,
  pageIndex: PageIndex0To127,
  pageCount: PageCount1To128,
  pageBody: TimelinePageBodyV1
}

TimelineMaterializationPagePayloadV1 =
  | { block: TimelineMaterializationBlockRefV1,
      pageIndex: 0, pageCount: PageCount1To128,
      pageBody: TimelinePageBodyV1, pageDigest: Sha256Hex64 }
  | { block: TimelineMaterializationBlockRefV1,
      pageIndex: PageIndex1To127, pageCount: PageCount1To128,
      previousPageDigest: Sha256Hex64,
      pageBody: TimelinePageBodyV1, pageDigest: Sha256Hex64 }
```

`PageIndex0To127`, `PageIndex1To127`, `PageCount0To128`, and `PageCount1To128` are distinct
generated bounded safe-integer types. A page object cannot use the zero-page count.

`previousPageDigest` is validated as external `REFERENCE_EQUALITY`; it is not a second page
preimage field. Re-pagination can change page/proof/container digests, but it cannot create a
semantic dominance relation by itself. A non-empty commit may carry one compact
`finalPageDigest` reference exact-equal to page `pageCount-1`; the zero-page empty branch forbids
it. It is commit transport evidence, not a receipt field or a replacement for
`orderedPageDigests`.

Rejected alternatives are normative negative rules:

- adding `turns`, `proofs`, or `islands` as extra PageBody arrays violates the exact
  `{items,gaps}` publication body;
- embedding full turn/island/proof objects in every TimelineItem duplicates authority, fails
  zero-item turns, and makes capacity counts representation-dependent;
- moving these rows to begin or commit creates unbounded frames or a second list authority.

## 3. Order, coverage, dominance, and capacity

The TIMELINE order preimage is:

```text
TimelineOrderedItemV1 =
  | { orderPosition: "FIRST", item: TimelineItemV1 }
  | { orderPosition: "SUCCESSOR", item: TimelineItemV1,
      incomingProofDigest: Sha256Hex64 }

TimelineOrderedTurnV1 =
  | { orderPosition: "FIRST", turnNode: TimelineTurnNodeV1,
      orderedItems: [TimelineOrderedItemV1] }
  | { orderPosition: "SUCCESSOR", turnNode: TimelineTurnNodeV1,
      incomingProofDigest: Sha256Hex64,
      orderedItems: [TimelineOrderedItemV1] }

TimelineOrderedIslandV1 = {
  islandOrdinal: Ordinal0,
  island: TimelineCoverageIslandV1,
  orderedTurns: [TimelineOrderedTurnV1]
}

TimelineMaterializationOrderPreimageV1 = {
  digestDomain: "ccpocket.materialization-order.v1",
  sourcePartition: SourcePartitionV1,
  subject: TimelineMaterializationSubjectV1,
  domain: "TIMELINE",
  orderedIslands: [TimelineOrderedIslandV1]
}
```

For every `orderedIslands[i]`, the array index `i`, outer `islandOrdinal`, and nested
`island.islandOrdinal` are exact-equal; the sequence is contiguous from zero. The duplicate
ordinal is a checked reference, not an independent ordering input.

The first turn of each island and the first item of each full turn use the FIRST branch and have
no proof field; every other node uses SUCCESSOR and requires the digest of its exact incoming
`TimelineBoundOrderProofV1`. INDEX Turn nodes require `orderedItems=[]`. The preimage therefore contains
ordered islands, TurnIndex/TurnSpine nodes, Items, their own predecessor facts, and exact proof references. It
contains no Gap array and no repeated proof body.

Coverage is a closed two-branch union:

```text
TimelineMaterializationCoveragePreimageV1 =
  | {
      digestDomain: "ccpocket.materialization-coverage.v1",
      sourcePartition: SourcePartitionV1,
      subject: TimelineMaterializationSubjectV1,
      domain: "TIMELINE",
      structuralCoverage: "COMPLETE" | "PARTIAL",
      payloadCoverage: "COMPLETE" | "PARTIAL",
      orderedIslands: [{ islandOrdinal: Ordinal0, island: TimelineCoverageIslandV1 }],
      orderedGaps: [TimelineGapV1]
    }
  | {
      digestDomain: "ccpocket.materialization-coverage.v1",
      sourcePartition: SourcePartitionV1,
      subject: TimelineMaterializationSubjectV1,
      domain: "TIMELINE",
      structuralCoverage: "EMPTY_PROVEN",
      payloadCoverage: "COMPLETE",
      orderedIslands: [],
      orderedGaps: [],
      emptyProof: TimelineTypedEmptyProofV1
}
```

For every non-empty coverage `orderedIslands[i]`, `i`, outer `islandOrdinal`, and
`island.islandOrdinal` are exact-equal, and the nested island is byte-equal to order
`orderedIslands[i].island`. Coverage cannot create a second island sequence or ordinal authority.
Coverage `orderedGaps[i].gapOrdinal` exact-equals `i`, and the array is byte-equal to the
canonical concatenation of every actual page's `pageBody.gaps`; no Gap may be copied, omitted,
reordered, or independently rewritten.

The coverage truth table is exact:

- `structuralCoverage=PARTIAL` requires at least one structural
  `BEFORE|AFTER|BETWEEN|COVERAGE_UNKNOWN` Gap; `COMPLETE` forbids all four;
- non-empty `COMPLETE` requires at least one island and Turn; zero known entities with full-scope
  terminal evidence must use `EMPTY_PROVEN` rather than an empty COMPLETE branch;
- `payloadCoverage=PARTIAL` requires at least one
  `PAYLOAD|TURN_PAYLOAD_NOT_LOADED|TURN_PAYLOAD_OVERSIZED` Gap; `COMPLETE` forbids all three;
- by the bidirectional predicates above, `payloadCoverage=COMPLETE` therefore also requires zero
  INDEX Turns and zero `unavailable` payload elements;
- `EMPTY_PROVEN` requires page/island/turn/item/proof/Gap counts zero, empty order arrays,
  payload COMPLETE, and exactly one typed empty proof;
- the non-empty branch forbids `emptyProof`; begin and coverage empty proofs must be byte-equal.

Gap ordinals are contiguous and canonically derived below. A repair intent binds stable typed
boundaries, reason, stable read plan, exact originating read spec, certification, repair kind, and
disposition; kind-only repair intent is forbidden. The item-level missing-field set is itself a
closed generated shape:

```text
TimelinePayloadFieldPathV1 = {
  payloadIndex: Ordinal0,
  payloadKind: "unavailable",
  fieldName: "resolvedPayload"
}

NonEmptySchemaDerivedPayloadFieldSetV1 =
  array<TimelinePayloadFieldPathV1, minItems=1, maxItems=64,
        uniqueBy=(payloadIndex,payloadKind,fieldName),
        orderBy=payloadIndex>

TimelineStructuralGapTargetV1 =
  | { targetKind: "BEFORE", rightBoundary: TimelineStrongBoundaryV1 }
  | { targetKind: "AFTER", leftBoundary: TimelineStrongBoundaryV1 }
  | { targetKind: "BETWEEN", leftBoundary: TimelineStrongBoundaryV1,
      rightBoundary: TimelineStrongBoundaryV1 }
  | { targetKind: "COVERAGE_UNKNOWN", subjectScope: TimelineSubjectScopeV1 }

TimelineItemPayloadGapTargetV1 = {
  targetKind: "PAYLOAD",
  itemRef: ItemRefV1,
  missingPayloadFields: NonEmptySchemaDerivedPayloadFieldSetV1
}

TimelineNotLoadedTurnGapTargetV1 = {
  targetKind: "TURN_PAYLOAD_NOT_LOADED",
  turnRef: TurnRefV1,
  turnOrdinal: SignedJsonSafeInteger
}

TimelineOversizedTurnGapTargetV1 = {
  targetKind: "TURN_PAYLOAD_OVERSIZED",
  turnRef: TurnRefV1,
  turnOrdinal: SignedJsonSafeInteger,
  leftTurnBoundary: TimelineTurnBoundaryV1 | null,
  rightTurnBoundary: TimelineTurnBoundaryV1 | null,
  providerReportedItemCount: Ordinal0,
  observedTurnByteCount: UInt64Decimal,
  maximumTurnByteCount: 4194304,
  problemCode: "TURN_PAYLOAD_OVERSIZED",
  repairDisposition: "UNREPAIRABLE_WITH_CURRENT_PROVIDER_API",
  oversizedReadEvidenceId: Id,
  oversizedReadEvidenceDigest: Sha256Hex64
}

TimelineGapStableTargetV1 =
  TimelineStructuralGapTargetV1 |
  TimelineItemPayloadGapTargetV1 |
  TimelineNotLoadedTurnGapTargetV1 |
  TimelineOversizedTurnGapTargetV1

TimelineGapReasonV1 =
  "NOT_LOADED" | "ORDER_UNPROVEN" | "CAPACITY_BOUNDARY" |
  "READ_FAILED" | "PROVIDER_UNSUPPORTED" | "COVERAGE_UNPROVEN" |
  "PAYLOAD_UNAVAILABLE" | "TURN_PAYLOAD_OVERSIZED"

TimelineGapRepairIntentCommonV1 = {
  digestDomain: "ccpocket.gap-repair-intent.v1",
  sourcePartition: SourcePartitionV1,
  subjectScope: TimelineSubjectScopeV1,
  readPlanDigest: Sha256Hex64,
  readSpecDigest: Sha256Hex64,
  codexCertificationId: Id,
  codexCertificationDigest: Sha256Hex64
}

TimelineGapRepairIntentPreimageV1 =
  | TimelineGapRepairIntentCommonV1 + {
      target: TimelineStructuralGapTargetV1,
      reason: "ORDER_UNPROVEN" | "READ_FAILED",
      repairKind: "FULL_BOUNDED_REREAD",
      repairDisposition: "REPAIRABLE_WITH_CURRENT_PROVIDER_API" }
  | TimelineGapRepairIntentCommonV1 + {
      target: TimelineStructuralGapTargetV1,
      reason: "COVERAGE_UNPROVEN",
      repairKind: "NEXT_PROVIDER_PAGE",
      repairDisposition: "REPAIRABLE_WITH_CURRENT_PROVIDER_API" }
  | TimelineGapRepairIntentCommonV1 + {
      target: TimelineStructuralGapTargetV1,
      reason: "CAPACITY_BOUNDARY" | "PROVIDER_UNSUPPORTED",
      repairKind: "NONE",
      repairDisposition: "UNREPAIRABLE_WITH_CURRENT_PROVIDER_API" }
  | TimelineGapRepairIntentCommonV1 + {
      target: TimelineItemPayloadGapTargetV1,
      reason: "PAYLOAD_UNAVAILABLE",
      repairKind: "LOAD_PAYLOAD",
      repairDisposition: "REPAIRABLE_WITH_CURRENT_PROVIDER_API" }
  | TimelineGapRepairIntentCommonV1 + {
      target: TimelineItemPayloadGapTargetV1,
      reason: "CAPACITY_BOUNDARY",
      repairKind: "NONE",
      repairDisposition: "UNREPAIRABLE_WITH_CURRENT_PROVIDER_API" }
  | TimelineGapRepairIntentCommonV1 + {
      target: TimelineNotLoadedTurnGapTargetV1,
      reason: "NOT_LOADED",
      repairKind: "FULL_BOUNDED_REREAD",
      repairDisposition: "REPAIRABLE_WITH_CURRENT_PROVIDER_API" }
  | TimelineGapRepairIntentCommonV1 + {
      target: TimelineOversizedTurnGapTargetV1,
      reason: "TURN_PAYLOAD_OVERSIZED",
      repairKind: "NONE",
      repairDisposition: "UNREPAIRABLE_WITH_CURRENT_PROVIDER_API" }

TimelineGapRepairIntentV1 = TimelineGapRepairIntentPreimageV1 + {
  repairIntentDigest: Sha256Hex64
}

TimelineGapV1 = {
  gapOrdinal: Ordinal0,
  target: TimelineGapStableTargetV1,
  reason: TimelineGapReasonV1,
  repairIntent: TimelineGapRepairIntentV1
}
```

The observed-field ranks are exact: payload kinds
`text=0,image=1,structured_ref=2,tool_summary=3`; within tool_summary,
`toolName=0,summary=1` (all other branches have one field). PVMC-1 missing-field order is solely
`payloadIndex` because `unavailable/resolvedPayload` is its only reachable missing path. RFC8785
serializes each resulting ordinary JSON array as-is; implementations may not Set-sort,
locale-sort, or accept duplicate paths.
Every missing path's `payloadIndex` resolves to an `unavailable` placeholder at that exact dense
array position. Typed per-field missing paths are unreachable in PVMC-1: the profile never
represents a partially resolved text, image, structured ref, or tool summary. Repair replaces
one `PAYLOAD_UNAVAILABLE` placeholder with exactly one complete typed branch, removes the one
generic missing path, emits all observed fields of the revealed branch together, and must
preserve its payload commitment. A `CAPACITY_BOUNDARY` placeholder has `repairKind="NONE"` and
cannot be revealed under the active profile; changing that disposition requires a reviewed
content lineage/profile amendment.

`TimelineGapReasonV1` is exactly
`NOT_LOADED|ORDER_UNPROVEN|CAPACITY_BOUNDARY|READ_FAILED|PROVIDER_UNSUPPORTED|
COVERAGE_UNPROVEN|PAYLOAD_UNAVAILABLE|TURN_PAYLOAD_OVERSIZED`. The seven intent branches above
are the complete target/reason/repairKind/disposition matrix; no cross-product value is
reachable. In particular, an Item PAYLOAD target uses either loadable `PAYLOAD_UNAVAILABLE` or
unrepairable `CAPACITY_BOUNDARY`; a structural capacity/unsupported observation and an oversized
Turn are the other `NONE` cases. Structural targets cannot use `NOT_LOADED`, `PAYLOAD_UNAVAILABLE`,
or `TURN_PAYLOAD_OVERSIZED`, and payload targets cannot use structural reasons except the exact
Item capacity branch.
The vector Registry requires one positive vector for each of the seven intent branches and a
deliberate failure for every target-class/reason/repairKind/disposition crossover, including
`40960` inline acceptance and `40961` committed capacity-unavailable publication.
The containing Gap's target/reason and the resolved intent exact-equal. Actor, recipient, host,
source/runtime epoch, head/materialization ID, capability snapshot, token, nonce, and expiry are
forbidden. Random `gapId` and mutable lifecycle fields are also forbidden. `NONE` never admits
repair. The oversized byte count must parse above 4194304, its evidence refs must resolve to the
exact OVERSIZED_TURN result, and the writer must not fall back to full `thread/read`, split the
Turn, or claim a zero-item Turn.

Dominance uses this independently built closed semantic projection, never raw JSON/Set
inclusion. Attempt-local spec/cursor facts validate before projection but cannot make load-more
or `notLoaded -> full` incomparable:

```text
TimelineCoverageStableKeyV1 = {
  sourcePartition: SourcePartitionV1,
  subjectScope: TimelineSubjectScopeV1,
  readPlanDigest: Sha256Hex64
}

TimelineCoverageCertificationContextV1 = {
  codexCertificationId: Id,
  codexCertificationDigest: Sha256Hex64
}

TimelineTurnComparisonFactV1 =
  | { turnFactKind: "INDEX", turnRef: TurnRefV1,
      turnOrdinal: SignedJsonSafeInteger,
      semanticFieldPresence: ["turnRef","turnOrdinal"] }
  | { turnFactKind: "FULL", turnRef: TurnRefV1,
      turnOrdinal: SignedJsonSafeInteger,
      firstTimelineOrdinal: SignedJsonSafeInteger | null,
      lastTimelineOrdinal: SignedJsonSafeInteger | null,
      itemCount: Ordinal0,
      semanticFieldPresence:
        ["turnRef","turnOrdinal","firstTimelineOrdinal",
         "lastTimelineOrdinal","itemCount"] }

TimelineItemCoreComparisonFactV1 = {
  itemRef: ItemRefV1,
  turnOrdinal: SignedJsonSafeInteger,
  itemOrdinal: Ordinal0,
  timelineOrdinal: SignedJsonSafeInteger,
  predecessorItemRef: ItemRefV1 | null,
  itemKind: "USER_MESSAGE" | "ASSISTANT_MESSAGE" | "REASONING" |
            "TOOL_CALL" | "TOOL_RESULT" | "UNKNOWN",
  providerTypeName: string | null,
  semanticFieldPresence:
    ["itemRef","turnOrdinal","itemOrdinal","timelineOrdinal",
     "predecessorItemRef","itemKind","providerTypeName"]
}

TimelineObservedPayloadFieldV1 =
  | { payloadIndex: Ordinal0, payloadKind: "text",
      fieldName: "text", value: string }
  | { payloadIndex: Ordinal0, payloadKind: "image",
      fieldName: "imageRef", value: ImageRefV1 }
  | { payloadIndex: Ordinal0, payloadKind: "structured_ref",
      fieldName: "structuredRef", value: CurrentStructuredAttachmentRefV1 }
  | { payloadIndex: Ordinal0, payloadKind: "tool_summary",
      fieldName: "toolName" | "summary", value: string }

TimelinePayloadCommitmentFactV1 = {
  payloadIndex: Ordinal0,
  payloadDigest: Sha256Hex64
}

TimelineItemPayloadComparisonFactV1 = {
  itemRef: ItemRefV1,
  orderedPayloadCommitments:
    array<TimelinePayloadCommitmentFactV1, maxItems=64,
          uniqueBy=payloadIndex, orderBy=payloadIndex>,
  orderedObservedFields:
    array<TimelineObservedPayloadFieldV1, maxItems=128,
          uniqueBy=(payloadIndex,payloadKind,fieldName),
          orderBy=(payloadIndex,payloadKindRank,fieldNameRank)>,
  missingPayloadFields:
    array<TimelinePayloadFieldPathV1, maxItems=64,
          uniqueBy=(payloadIndex,payloadKind,fieldName),
          orderBy=payloadIndex>
}

TimelineAdjacencyComparisonFactV1 =
  | { edgeKind: "TURN", from: TimelineTurnBoundaryV1,
      to: TimelineTurnBoundaryV1 }
  | { edgeKind: "ITEM", from: TimelineItemBoundaryV1,
      to: TimelineItemBoundaryV1 }

TimelineDerivedIslandFactV1 = {
  startBoundary: TimelineTurnBoundaryV1,
  endBoundary: TimelineTurnBoundaryV1,
  minTurnOrdinal: SignedJsonSafeInteger,
  maxTurnOrdinal: SignedJsonSafeInteger,
  minTimelineOrdinal: SignedJsonSafeInteger | null,
  maxTimelineOrdinal: SignedJsonSafeInteger | null,
  turnCount: PositiveJsonSafeInteger,
  indexTurnCount: Ordinal0,
  fullTurnCount: Ordinal0,
  itemCount: Ordinal0
}

TimelineOversizedTurnGapSemanticTargetV1 = {
  targetKind: "TURN_PAYLOAD_OVERSIZED",
  turnRef: TurnRefV1,
  turnOrdinal: SignedJsonSafeInteger,
  leftTurnBoundary: TimelineTurnBoundaryV1 | null,
  rightTurnBoundary: TimelineTurnBoundaryV1 | null,
  providerReportedItemCount: Ordinal0,
  observedTurnByteCount: UInt64Decimal,
  maximumTurnByteCount: 4194304,
  problemCode: "TURN_PAYLOAD_OVERSIZED",
  repairDisposition: "UNREPAIRABLE_WITH_CURRENT_PROVIDER_API"
}

TimelineGapSemanticTargetV1 =
  TimelineStructuralGapTargetV1 |
  TimelineItemPayloadGapTargetV1 |
  TimelineNotLoadedTurnGapTargetV1 |
  TimelineOversizedTurnGapSemanticTargetV1

TimelineGapComparisonFactV1 =
  | { semanticTarget: TimelineStructuralGapTargetV1,
      reason: "ORDER_UNPROVEN" | "READ_FAILED",
      repairKind: "FULL_BOUNDED_REREAD",
      repairDisposition: "REPAIRABLE_WITH_CURRENT_PROVIDER_API" }
  | { semanticTarget: TimelineStructuralGapTargetV1,
      reason: "COVERAGE_UNPROVEN",
      repairKind: "NEXT_PROVIDER_PAGE",
      repairDisposition: "REPAIRABLE_WITH_CURRENT_PROVIDER_API" }
  | { semanticTarget: TimelineStructuralGapTargetV1,
      reason: "CAPACITY_BOUNDARY" | "PROVIDER_UNSUPPORTED",
      repairKind: "NONE",
      repairDisposition: "UNREPAIRABLE_WITH_CURRENT_PROVIDER_API" }
  | { semanticTarget: TimelineItemPayloadGapTargetV1,
      reason: "PAYLOAD_UNAVAILABLE",
      repairKind: "LOAD_PAYLOAD",
      repairDisposition: "REPAIRABLE_WITH_CURRENT_PROVIDER_API" }
  | { semanticTarget: TimelineItemPayloadGapTargetV1,
      reason: "CAPACITY_BOUNDARY",
      repairKind: "NONE",
      repairDisposition: "UNREPAIRABLE_WITH_CURRENT_PROVIDER_API" }
  | { semanticTarget: TimelineNotLoadedTurnGapTargetV1,
      reason: "NOT_LOADED",
      repairKind: "FULL_BOUNDED_REREAD",
      repairDisposition: "REPAIRABLE_WITH_CURRENT_PROVIDER_API" }
  | { semanticTarget: TimelineOversizedTurnGapSemanticTargetV1,
      reason: "TURN_PAYLOAD_OVERSIZED",
      repairKind: "NONE",
      repairDisposition: "UNREPAIRABLE_WITH_CURRENT_PROVIDER_API" }

TimelineCoverageComparisonProjectionV1 =
  | { projectionKind: "NON_EMPTY_OR_PARTIAL",
      stableKey: TimelineCoverageStableKeyV1,
      structuralCoverage: "COMPLETE" | "PARTIAL",
      payloadCoverage: "COMPLETE" | "PARTIAL",
      orderedTurns: [TimelineTurnComparisonFactV1],
      orderedItems: [TimelineItemCoreComparisonFactV1],
      orderedPayloadFacts: [TimelineItemPayloadComparisonFactV1],
      orderedAdjacencyFacts: [TimelineAdjacencyComparisonFactV1],
      derivedOrderedIslandFacts: [TimelineDerivedIslandFactV1],
      orderedGapFacts: [TimelineGapComparisonFactV1] }
  | { projectionKind: "EMPTY_PROVEN",
      stableKey: TimelineCoverageStableKeyV1,
      structuralCoverage: "EMPTY_PROVEN",
      payloadCoverage: "COMPLETE" }

TimelineCoverageComparisonEnvelopeV1 = {
  certification: TimelineCoverageCertificationContextV1,
  projection: TimelineCoverageComparisonProjectionV1
}
```

The fixed `semanticFieldPresence` arrays are exact literals, not caller-provided sets. A Turn's
validated `predecessorTurnRef` is deliberately excluded from its stable core and is projected
only as a verified TURN adjacency fact; this is what permits an island-first null predecessor to
be filled when its exact structural Gap closes without pretending that immutable core bytes
changed.

The payload projection is generated by decomposing validated `TimelinePayloadV1` elements in
array order. Every available element's commitment is recomputed from its typed semantic bytes;
an unavailable element supplies that exact commitment and the `resolvedPayload` missing path.
The Item's derived missing set exact-equals its unique PAYLOAD Gap target: one or more unavailable
elements exist iff that Gap exists, and no Gap iff every payload is resolved. The observed-field
maximum is 128 because each of the at most 64 payloads has one field except `tool_summary`, which
has exactly two; the independent missing-field set remains bounded by its generated 64-path
capacity gate. The full typed empty proof validates first; its attempt/evidence refs do not enter
the semantic EMPTY projection.

Every projection array is required. `orderedTurns`, `orderedItems`, and payload facts flatten
the verified island-to-turn-to-item display traversal; payload facts exact-align one-for-one
with `orderedItems`. TURN adjacency facts follow Turn traversal, then ITEM adjacency facts follow
their parent-Turn/item traversal. Derived islands retain display order without serializing
`islandOrdinal`; Gaps use the canonical order defined above. No implementation sorting is
permitted after projection construction.

Excluded provenance is materialization/block/page/receipt/event IDs, page placement,
`islandOrdinal`, `gapOrdinal`, proof/evidence IDs and digests, attempt `readSpecDigest`,
proof branch after it has validated the same stable edge, itemsView/limit/cursors, certification,
container derivation digests, timestamps, and row IDs. Exclusion never waives prior validation.
Current and candidate `stableKey` exact-equal before classification; a changed plan is
non-comparable. Each envelope's certification context resolves and validates independently.
Strict-superset additionally requires byte-equal certification contexts, while semantic-equal
and whole-scope replacement use their separate rules below.

This stable-key rule explicitly supersedes 07's attempt-`readSpecDigest` comparison key for
PVMC-1. Cursor continuation and `notLoaded -> full` intentionally use different exact attempt
specs under one stable read plan. Every read spec still exact-binds its own evidence/result and
repair intent; exclusion from dominance comparability is not permission to weaken that binding.

Classification is exact:

1. semantic-equal requires byte-equal semantic projections and does not advance the head. Its
   two independently valid certification contexts may differ because certification is evidence,
   not a visible fact;
2. every retained Turn/Item core fact occurs exactly once in candidate order. A FULL Turn fact
   remains byte-equal; an INDEX fact may refine to FULL for the same TurnRef/turnOrdinal only
   with exact full evidence. Old order is a candidate subsequence. A new Turn is allowed only
   inside an old structural Gap. A new Item is allowed only under such a newly proved FULL Turn
   or under the exact FULL refinement of an old INDEX Turn. Every new/refined fact must match
   exactly one current normalized-result position;
3. every old adjacency remains. A new edge may occur inside an old structural Gap or inside the
   new Item chain created by an exact INDEX-to-FULL refinement. An old non-null serialized
   `predecessorTurnRef` is immutable; an island-first null predecessor may become the exact newly
   proved predecessor only when its structural Gap closes. Retained Item-first predecessors do
   not change in PVMC-1; a new Item chain derives its own null-first/contiguous predecessors from
   the exact FULL result;
4. for a retained Item, every old observed payload field remains byte-equal. New observed fields
   for one of its payload indexes are allowed only when the old missing set contains that exact
   `unavailable/resolvedPayload` path and the old Gap has the exact repairable
   `PAYLOAD_UNAVAILABLE/LOAD_PAYLOAD` tuple; candidate removes the path and emits every field of
   one complete revealed branch together. A capacity-unavailable path cannot be removed under
   PVMC-1. Every old per-index commitment remains, and the revealed bytes must recompute it. A
   newly introduced Item instead contributes its complete core,
   commitments, all resolved fields, and any unavailable placeholders directly from the exact
   FULL result. Partial reveal and every other payload mutation fail;
5. a structural Gap may remain, strictly shrink, split, or close inside its old interval; it may
   not widen, overlap, move outside the old union, change a retained boundary, or reappear;
6. a retained repairable Item PAYLOAD missing set may only retain or strictly shrink; a capacity
   set must remain byte-equal. A
   TURN_PAYLOAD_NOT_LOADED Gap closes with the same Turn's valid INDEX-to-FULL refinement and may
   be replaced by zero to N child PAYLOAD Gaps, each exact-equal to the unavailable indexes of
   one newly introduced Item; or it refines to TURN_PAYLOAD_OVERSIZED only with exact full-read
   evidence and a byte count above the frozen maximum. No other new payload Gap is allowed. The
   reverse is forbidden, and an oversized Gap cannot close under the same
   plan/certification/maximum without a new reviewed content route;
7. island facts are re-derived from nodes/edges. Island merge or ordinal renumber caused by a
   proved Gap closure is not a stable-node mutation;
8. coverage axes only hold or improve. Strict-superset needs byte-equal certification contexts
   and at least one new node/proved edge, exact INDEX-to-FULL refinement, declared retained-item
   payload reveal, Gap close/shrink/split, notLoaded-to-oversized refinement, or
   structural/payload axis improvement;
9. every other comparison is non-dominating and rejects the candidate without changing
   last-good.

Whole-scope replacement is allowed only from independently verified COMPLETE terminal evidence
or EMPTY_PROVEN with the same source/scope/read plan and may not contradict retained
strong-identity bytes. It may use a new exact certification only when it rereads the whole scope,
uses no old cursor or cross-certification CANONICAL_PREDECESSOR edge, and proves every retained
edge under the new certification. Strict-superset never crosses certification. Lifecycle
replacement proof is otherwise unreachable in PVMC-1.

Capacity is a logical cross-platform verifier fact, not SQLite file size:

```text
TimelineStagedCapacityRowV1 =
  | { capacityRowKind: "PAGE",
      sourcePartition: SourcePartitionV1,
      subject: TimelineMaterializationSubjectV1,
      pageIndex: PageIndex0To127,
      pageCount: PageCount1To128,
      previousPageDigest: Sha256Hex64 | null,
      pageDigest: Sha256Hex64 }
  | { capacityRowKind: "LOGICAL_ROW",
      pageIndex: PageIndex0To127,
      item: TimelinePageStagedRowV1 }
  | { capacityRowKind: "GAP",
      pageIndex: PageIndex0To127,
      gap: TimelineGapV1 }

TimelineStagedCapacitySetV1 = each TimelineStagedCapacityRowV1 exactly once

stagedRowCount = pageCount + islandCount + turnCount + itemCount
                 + boundOrderProofCount + gapCount
stagedByteCount = decimal_string(sum(
  UTF8Length(RFC8785(row))
))
```

The Registry freezes this union and the exact inner schemas as its
`rowCapacityProjectionSchemaRef` set. PAGE excludes PageBody and maps the page-0 previous-digest
absence canonically to null; each child includes its containing page index. This counts each
byte-bearing authority row once without counting both the page blob and its children.
The capacity set is exactly the following projection and accepts no caller-supplied rows: one
PAGE row per actual page with byte-equal source, subject, pageIndex/pageCount, actual pageDigest,
and null-or-actual previousPageDigest; one LOGICAL_ROW for every `pageBody.items` element with
byte-equal item and its real containing pageIndex; and one GAP row for every `pageBody.gaps`
element with byte-equal Gap and its real containing pageIndex. Every source row appears once,
and no extra, omitted, duplicated, relocated, or digest-drifted capacity row is valid.
Header/read-spec/evidence/manifest/begin/receipt/event/
envelope objects and SQLite metadata/index bytes are excluded. `stagedByteCount` is
`UInt64Decimal`. Because the typed empty proof is carried by begin/coverage rather than staged
as a child row, `EMPTY_PROVEN` has `stagedRowCount=0` and `stagedByteCount="0"`.

## 4. Manifest, begin, receipt, and digest modes

The manifest uses flat domain counts:

```text
MaterializationManifestPreimageV1 = {
  digestDomain: "ccpocket.materialization-manifest.v1",
  algorithmVersion: 1,
  sourcePartition: SourcePartitionV1,
  subject: TimelineMaterializationSubjectV1,
  baseHeadVersion: HeadVersion0,
  candidateHeadVersion: PositiveRevision,
  pageCount: PageCount0To128,
  orderedPageDigests: [{ pageIndex: PageIndex0To127, pageDigest: Sha256Hex64 }],
  domain: "TIMELINE",
  turnCount: Ordinal0,
  itemCount: Ordinal0,
  islandCount: Ordinal0,
  gapCount: Ordinal0,
  orderDigest: Sha256Hex64,
  coverageDigest: Sha256Hex64
}
```

For every initial, provider-only, repair, non-empty, and empty candidate,
`candidateHeadVersion=baseHeadVersion+1` in safe-integer arithmetic. Therefore base zero requires
candidate one. Manifest, begin, receipt, commit, dominance input, and the eventual head CAS all
carry that exact pair; a missing, skipped, duplicated, or branch-local version rule rejects the
whole candidate. Safe-integer overflow admits no candidate and preserves last-good.

The block and EventKey are:

```text
TimelineMaterializationBlockRefV1 = {
  blockId: Id,
  subject: TimelineMaterializationSubjectV1,
  receiptId: Id,
  manifestDigest: Sha256Hex64,
  beginHeaderDigest: Sha256Hex64
}

TimelineMaterializationEventKeyV1 = {
  sourcePartition: SourcePartitionV1,
  ownerKind: "CanonicalTimelineWriter",
  aggregateRef: {
    kind: "MATERIALIZATION",
    subject: TimelineMaterializationSubjectV1
  },
  eventId: Id
}
```

Begin has one `block.manifestDigest`, one sibling `expectedCoverageDigest`, and the complete
bounded read tuple. The following schema template is codegen notation, not a reachable wire
type; it is instantiated exactly twice with the listed block types:

```text
TimelineMaterializationBeginBlockPreimageV1 = {
  blockId: Id,
  subject: TimelineMaterializationSubjectV1,
  receiptId: Id,
  manifestDigest: Sha256Hex64
}

TimelineBeginPayloadShapeV1<BlockT> =
  | {
      block: BlockT,
      baseHeadVersion: HeadVersion0,
      candidateHeadVersion: PositiveRevision,
      expectedCoverageDigest: Sha256Hex64,
      readPlanDigest: Sha256Hex64,
      readSpecDigest: Sha256Hex64,
      readEvidenceId: Id,
      readEvidenceDigest: Sha256Hex64,
      codexCertificationId: Id,
      codexCertificationDigest: Sha256Hex64,
      readBody: TimelineProviderReadBodyV1,
      pageCount: PageCount1To128,
      structuralCoverage: "COMPLETE" | "PARTIAL",
      payloadCoverage: "COMPLETE" | "PARTIAL"
    }
  | {
      block: BlockT,
      baseHeadVersion: HeadVersion0,
      candidateHeadVersion: PositiveRevision,
      expectedCoverageDigest: Sha256Hex64,
      readPlanDigest: Sha256Hex64,
      readSpecDigest: Sha256Hex64,
      readEvidenceId: Id,
      readEvidenceDigest: Sha256Hex64,
      codexCertificationId: Id,
      codexCertificationDigest: Sha256Hex64,
      readBody: TimelineProviderReadBodyV1,
      pageCount: 0,
      structuralCoverage: "EMPTY_PROVEN",
      payloadCoverage: "COMPLETE",
      emptyProof: TimelineTypedEmptyProofV1
    }

TimelineMaterializationBeginPayloadV1 =
  TimelineBeginPayloadShapeV1<TimelineMaterializationBlockRefV1>

TimelineMaterializationBeginPayloadPreimageV1 =
  TimelineBeginPayloadShapeV1<TimelineMaterializationBeginBlockPreimageV1>

MaterializationBeginHeaderPreimageV1 = {
  digestDomain: "ccpocket.materialization-begin.v1",
  eventKey: TimelineMaterializationEventKeyV1,
  payload: TimelineMaterializationBeginPayloadPreimageV1
}
```

Both instantiations are closed unions. The preimage transform replaces the actual block with
the preimage block and therefore deletes exactly `payload.block.beginHeaderDigest`; no other
field changes. `expectedCoverageDigest` exact-equals final coverage, and the empty proof is
byte-equal to the coverage proof.

The begin read tuple is not a group of independent references. `readEvidenceId/digest` resolves
one exact `TimelineProviderReadEvidenceV1`; begin `readPlanDigest`, `readSpecDigest`, certification
ID/digest, source/scope projection, and byte-equal `readBody` exact-equal that evidence and its
resolved plan/spec/certification. The evidence body kind/count/resultDigest/cursors/view/limit/
method/direction/epochs/generation/executable exact-map the one normalized result and resolved
attempt spec. Every candidate order proof and typed empty proof uses this same outer read tuple;
the only additional evidence allowed is the explicitly nested prior index evidence inside an
OVERSIZED observation.

The receipt is isomorphic to its preimage except for its own digest:

```text
TimelineMaterializationReceiptPreimageV1 = {
  algorithmVersion: 1,
  receiptId: Id,
  sourcePartition: SourcePartitionV1,
  subject: TimelineMaterializationSubjectV1,
  beginHeaderDigest: Sha256Hex64,
  baseHeadVersion: HeadVersion0,
  candidateHeadVersion: PositiveRevision,
  readPlanDigest: Sha256Hex64,
  readSpecDigest: Sha256Hex64,
  readEvidenceId: Id,
  readEvidenceDigest: Sha256Hex64,
  codexCertificationId: Id,
  codexCertificationDigest: Sha256Hex64,
  result: "VERIFIED",
  pageCount: PageCount0To128,
  domain: "TIMELINE",
  turnCount: Ordinal0,
  itemCount: Ordinal0,
  islandCount: Ordinal0,
  gapCount: Ordinal0,
  stagedRowCount: Ordinal0,
  stagedByteCount: UInt64Decimal,
  orderDigest: Sha256Hex64,
  coverageDigest: Sha256Hex64,
  manifestDigest: Sha256Hex64
}

TimelineMaterializationReceiptV1 =
  TimelineMaterializationReceiptPreimageV1 + { receiptDigest: Sha256Hex64 }
```

It has no `digestDomain`, sibling materialization ID, proof count, duplicated axes, final page
digest, block ID, or Gap array.

Receipt `readPlanDigest/readSpecDigest/readEvidenceId/readEvidenceDigest/codexCertificationId/
codexCertificationDigest` exact-equal begin and resolve the same evidence, spec, plan, and
certification described above. Although receipt does not duplicate `readBody`, its resolved
evidence body is byte-equal to begin `readBody`; any tuple that resolves to a different object or
result rejects before receipt sealing.

The active commit variant has a separate closed payload. It carries compact reconstructed facts,
not a second item/Gap/island/proof list:

```text
TimelineLastGoodDispositionV1 =
  | { disposition: "NO_PREVIOUS_HEAD" }
  | { disposition: "PREVIOUS_HEAD_RETAINED",
      previousSubject: TimelineMaterializationSubjectV1,
      previousHeadVersion: PositiveRevision }

TimelineMaterializationCommitPayloadV1 =
  | {
      block: TimelineMaterializationBlockRefV1,
      sourcePartition: SourcePartitionV1,
      subject: TimelineMaterializationSubjectV1,
      baseHeadVersion: HeadVersion0,
      candidateHeadVersion: PositiveRevision,
      pageCount: PageCount1To128,
      finalPageDigest: Sha256Hex64,
      domain: "TIMELINE",
      turnCount: Ordinal0,
      itemCount: Ordinal0,
      islandCount: Ordinal0,
      gapCount: Ordinal0,
      structuralCoverage: "COMPLETE" | "PARTIAL",
      payloadCoverage: "COMPLETE" | "PARTIAL",
      orderDigest: Sha256Hex64,
      coverageDigest: Sha256Hex64,
      receiptDigest: Sha256Hex64,
      stagedRowCount: Ordinal0,
      stagedByteCount: UInt64Decimal,
      lastGoodDisposition: TimelineLastGoodDispositionV1
    }
  | {
      block: TimelineMaterializationBlockRefV1,
      sourcePartition: SourcePartitionV1,
      subject: TimelineMaterializationSubjectV1,
      baseHeadVersion: HeadVersion0,
      candidateHeadVersion: PositiveRevision,
      pageCount: 0,
      domain: "TIMELINE",
      turnCount: 0,
      itemCount: 0,
      islandCount: 0,
      gapCount: 0,
      structuralCoverage: "EMPTY_PROVEN",
      payloadCoverage: "COMPLETE",
      orderDigest: Sha256Hex64,
      coverageDigest: Sha256Hex64,
      receiptDigest: Sha256Hex64,
      stagedRowCount: 0,
      stagedByteCount: "0",
      lastGoodDisposition: TimelineLastGoodDispositionV1
    }
```

`NO_PREVIOUS_HEAD` requires `baseHeadVersion=0`. `PREVIOUS_HEAD_RETAINED` requires its subject to
share the stable scope, differ in materialization ID, and exact-equal the transaction's current
head and `baseHeadVersion`. The commit is reachable only after VERIFIED receipt, dominance,
seal, and head CAS eligibility; semantic-equal and non-dominating candidates create no commit.
The non-empty final digest exact-equals page `pageCount-1`; the empty branch forbids it.

All block records are joined by exact equality, not field presence:

| Records | Required equality |
|---|---|
| EventKey / begin | source and aggregate subject equal begin block subject and nested ThreadRef source |
| begin / resolved evidence | read plan/spec/evidence/certification tuple exact-equals; begin `readBody` is byte-equal to evidence `readBody`; body kind/count/result digest/cursors/fences exact-map the resolved spec and normalized result |
| begin / every page | block identity, subject, pageCount, manifest digest, begin-header digest, and receipt ID equal |
| pages / manifest | actual page indexes are contiguous; `orderedPageDigests[i].pageIndex == i` and its digest exact-equals actual page `i`; counts derive from staged rows |
| begin / coverage | axes and empty branch equal; `expectedCoverageDigest` equals recomputed coverage digest; emptyProof is byte-equal |
| manifest / reducer | source, subject, heads, pageCount, four domain counts, order digest, and coverage digest equal |
| receipt / begin / evidence | all six read/certification identity-digest fields exact-equal and resolve the same objects; receipt result is VERIFIED and its evidence body is begin `readBody` |
| receipt / reducer | source, subject, heads, result, page/domain counts, capacity, order, coverage, manifest, and begin refs equal |
| commit / all above | block/source/subject/heads/pageCount/counts/axes/order/coverage/receipt/capacity equal; non-empty final page ref equals actual last page |

Any missing page, duplicate page, reordered page, wrong previous digest, row/count drift, orphan
proof/Gap, receipt mismatch, or begin/manifest/commit equality failure rejects the whole block,
does not advance checkpoint/ACK, and preserves last-good.

Digest derivation modes are closed:

- `DOMAIN_SEPARATED_JCS`: read plan, read spec, normalized result, read evidence, certification,
  payload commitment, order proof, repair intent, page, order, coverage, manifest, and begin
  header. Each preimage owns one required const domain.
- `FROZEN_RFC8785_JCS`: among the materialization preimages defined by this amendment, receipt
  only, formula
  `R59_MATERIALIZATION_RECEIPT_V1`, with no digest domain.
- `STANDARD_EXACT_BYTES`: Codex executable and optional raw response bytes.
- `REFERENCE_EQUALITY`: only the non-owning field paths in the inventory below. Each generated
  field owns exactly one `equalityTargetDigestId`; it validates the referenced object and never
  rehashes the containing object as though it owned that digest.

The `*` below means exact expansion across the closed union branches, not an open path pattern:

| equalityTargetDigestId | Exact non-owning field-path families |
|---|---|
| `DR-READ-PLAN` | `TimelineProviderReadSpecPreimageV1.readPlanDigest`; `TimelineProviderReadBodyV1.readPlanDigest`; `TimelineProviderReadEvidencePreimageV1.readPlanDigest`; `TimelineProviderReadResultPreimageV1*.readPlanDigest`; `TimelineTypedEmptyProofV1.readPlanDigest`; `TimelineGapRepairIntentCommonV1.readPlanDigest`; `TimelineBeginPayloadShapeV1*.readPlanDigest`; `TimelineMaterializationReceiptPreimageV1.readPlanDigest`; `TimelineCoverageStableKeyV1.readPlanDigest` |
| `DR-READ-SPEC` | `TimelineProviderReadEvidencePreimageV1.readSpecDigest`; `TimelineProviderReadResultPreimageV1*.readSpecDigest`; `TimelineTypedEmptyProofV1.readSpecDigest`; `TimelineGapRepairIntentCommonV1.readSpecDigest`; `TimelineBeginPayloadShapeV1*.readSpecDigest`; `TimelineMaterializationReceiptPreimageV1.readSpecDigest` |
| `DR-NORMALIZED-RESULT` | `TimelineProviderReadBodyV1.resultDigest` |
| `DR-CODEX-EXECUTABLE` | `TimelineProviderReadBodyV1.codexExecutableDigest`, targeting the certification-bound `STANDARD_EXACT_BYTES` executable digest |
| `DR-READ-EVIDENCE` | `TimelineOrderProofPreimageV1.readEvidenceDigest`; `TimelineTypedEmptyProofV1.readEvidenceDigest`; `TimelineOversizedTurnObservationV1.indexReadEvidenceDigest`; `TimelineOversizedTurnGapTargetV1.oversizedReadEvidenceDigest`; `TimelineBeginPayloadShapeV1*.readEvidenceDigest`; `TimelineMaterializationReceiptPreimageV1.readEvidenceDigest` |
| `DR-CODEX-CERTIFICATION` | `TimelineProviderReadEvidencePreimageV1.codexCertificationDigest`; `TimelineOrderProofPreimageV1.codexCertificationDigest`; `TimelineTypedEmptyProofV1.codexCertificationDigest`; `TimelineGapRepairIntentCommonV1.codexCertificationDigest`; `TimelineBeginPayloadShapeV1*.codexCertificationDigest`; `TimelineMaterializationReceiptPreimageV1.codexCertificationDigest`; `TimelineCoverageCertificationContextV1.codexCertificationDigest` |
| `DR-PAYLOAD-COMMITMENT` | `TimelinePayloadV1.unavailable.payloadDigest`; `TimelinePayloadCommitmentFactV1.payloadDigest` |
| `DR-ORDER-PROOF` | `TimelinePageStagedRowV1.BOUND_ORDER_PROOF.boundOrderProof.proofDigest`; `TimelineOrderedTurnV1.SUCCESSOR.incomingProofDigest`; `TimelineOrderedItemV1.SUCCESSOR.incomingProofDigest`; `PredecessorReferenceEdgeV1.current.proofDigest`; the same nested proof field when a `TimelinePageStagedRowV1.BOUND_ORDER_PROOF` is embedded by `TimelineStagedCapacityRowV1.LOGICAL_ROW.item` |
| `DR-REPAIR-INTENT` | `TimelineGapV1.repairIntent.repairIntentDigest` as embedded by page, coverage, comparison validation, and capacity projection |
| `DR-PAGE` | `TimelineMaterializationPagePayloadV1.previousPageDigest`; `TimelineStagedCapacityRowV1.PAGE.previousPageDigest/pageDigest`; `MaterializationManifestPreimageV1.orderedPageDigests[*].pageDigest`; non-empty `TimelineMaterializationCommitPayloadV1.finalPageDigest` |
| `DR-ORDER` | `MaterializationManifestPreimageV1.orderDigest`; `TimelineMaterializationReceiptPreimageV1.orderDigest`; `TimelineMaterializationCommitPayloadV1*.orderDigest` |
| `DR-COVERAGE` | `TimelineBeginPayloadShapeV1*.expectedCoverageDigest`; `MaterializationManifestPreimageV1.coverageDigest`; `TimelineMaterializationReceiptPreimageV1.coverageDigest`; `TimelineMaterializationCommitPayloadV1*.coverageDigest` |
| `DR-MANIFEST` | every `TimelineMaterializationBlockRefV1.manifestDigest`; `TimelineMaterializationBeginBlockPreimageV1.manifestDigest`; `TimelineMaterializationReceiptPreimageV1.manifestDigest`; `TimelineSealedOrderProofV1.CANONICAL_PREDECESSOR.baseManifestDigest`; `PredecessorReferenceEdgeV1.current/base.manifestDigest` |
| `DR-BEGIN-HEADER` | every `TimelineMaterializationBlockRefV1.beginHeaderDigest`; `TimelineMaterializationReceiptPreimageV1.beginHeaderDigest` |
| `DR-RECEIPT` | `TimelineMaterializationCommitPayloadV1*.receiptDigest` |
| `DR-OPERATION-FINGERPRINT` | `AdmissionLookupKeyV1.operationFingerprint`; `OperationQueryV1.operationFingerprint`; `OperationSnapshotResultV1*.operationFingerprint`, all targeting the accepted R34 immutable operation-header semantic fingerprint |

An owning digest output on its own validated object is not a REFERENCE_EQUALITY occurrence.
Any reachable digest-valued field missing from this inventory, resolving two target IDs, or
declared under a different derivation mode rejects Registry validation.
The operation fingerprint and global event/payload/message/frame digest derivations remain their
accepted Registry rules; this amendment only adds the listed references and does not re-own
those digests.

`CANONICAL_PREDECESSOR` uses a stratified cross-instance edge rather than an untyped
manifest-to-proof type edge:

```text
PredecessorReferenceEdgeV1 = {
  edgeKind: "PREDECESSOR_REFERENCE",
  relationMode: "REFERENCE_EQUALITY",
  current: {
    proofDigest: Sha256Hex64,
    sourcePartition: SourcePartitionV1,
    subject: TimelineMaterializationSubjectV1,
    headVersion: PositiveRevision,
    manifestDigest: Sha256Hex64
  },
  base: {
    sourcePartition: SourcePartitionV1,
    subject: TimelineMaterializationSubjectV1,
    headVersion: PositiveRevision,
    manifestDigest: Sha256Hex64
  }
}
```

The current manifest field is a guard-only equality in this Registry edge and is not inserted
into the proof preimage. Current/base source and stable scope exact-equal; materialization IDs
differ; `current.headVersion=base.headVersion+1`; current subject/version exact-equal the
candidate transaction; `current.manifestDigest` exact-equals and resolves that candidate's
actual manifest; and base subject/version/manifest exact-equal the current SEALED+VERIFIED
last-good head. The sealed proof's three base fields exact-equal this base.
Same-instance, same/future/reversed version, stale head, cross-scope, or self-manifest edges
reject.

The `current.manifestDigest` equality is `POST_DERIVATION_VALIDATION_ONLY`: it is evaluated only
after both the current proof and candidate manifest have been fully derived and sealed. It is
excluded from the proof preimage, SCC/topological digest graph, and every digest dependency edge.
Only the strictly older `base.manifestDigest` endpoint contributes the cross-instance
`PREDECESSOR_REFERENCE` dependency into the current proof.

Validation is two-level. First, each materialization instance passes SCC/topological checks on
its ordinary proof/page/order/coverage/manifest/begin/receipt DAG. Second,
PREDECESSOR_REFERENCE edges alone cross instances from a strictly lower head version to the
next version. The expanded instance graph must remain well founded; digest or materialization-ID
lexical order is never used as a rank.

The dependency registry must describe and validate this graph, including self-loop,
reverse-edge, missing-edge, unstratified predecessor, and cycle failures:

```text
executable/schema/probe facts -> certificationDigest
stable read plan -> readPlanDigest
readPlanDigest + exact attempt spec -> readSpecDigest
normalized result + readPlanDigest + readSpecDigest -> resultDigest
readPlanDigest + readSpecDigest + resultDigest + fences + certification ref -> readEvidenceDigest
common proof context + readEvidenceDigest + certification ref + exact current-result positions
  -> PROVIDER_PAGE_ORDER proofDigest
common proof context + readEvidenceDigest + certification ref + sealed base subject/version/
  manifest
  -> CANONICAL_PREDECESSOR proofDigest
base manifestDigest -[PREDECESSOR_REFERENCE]-> current CANONICAL_PREDECESSOR proofDigest
current manifestDigest == edge.current.manifestDigest
  -> POST_DERIVATION_VALIDATION_ONLY (no digest-DAG edge)
resolved payload + exact payloadIndex -> payloadCommitmentDigest
proofDigest + page rows/context -> pageDigest[*]
repair intent -> repairIntentDigest
typed coverage axes + ordered islands + ordered gaps/emptyProof + repairIntentDigest refs
  -> coverageDigest
ordered staged facts + proofDigest refs -> orderDigest
pageDigest[*] + orderDigest + coverageDigest + heads/counts -> manifestDigest
manifestDigest + coverageDigest + EventKey + read tuple -> beginHeaderDigest
beginHeaderDigest + manifest/order/coverage + read refs + counts/capacity -> receiptDigest
```

The two proof edges are mutually exclusive. `PROVIDER_PAGE_ORDER` requires and consumes the two
exact normalized-result positions and forbids base-manifest fields.
`CANONICAL_PREDECESSOR` requires the sealed base tuple and stratified edge, forbids normalized
positions, and validates its endpoints by reconstructing the base order. Shared outer proof
context/evidence/certification never turns these branch-local dependencies into optional inputs.

`payloadCommitmentDigest` feeds the validated Item, page, and order semantic bytes. None of those
objects, nor a missing-field or repair object, may feed back into its preimage; an unavailable
placeholder carries only the already computed commitment plus the closed missing-field marker.

`TimelineMaterializationCommitPayloadV1` follows the unchanged 07/R54 durable-envelope chain,
which is separate from payload-field commitments:

- `payloadCommitmentDigest = SHA256(RFC8785(TimelinePayloadCommitmentPreimageV1))` binds one
  Timeline payload array position and its eventual resolved semantic payload;
- `payloadDigest = SHA256(RFC8785(exact TimelineMaterializationCommitPayloadV1))` uses the global
  frozen typed-payload rule;
- the same exact commit payload independently enters the domain-separated
  `EventFactPreimageV1`; `eventFactDigest` excludes `payloadDigest` rather than depending on it;
- the sealed envelope contains payload, payloadDigest, and eventFactDigest; deleting only
  `messageDigest` yields the frozen message preimage and
  `messageDigest=SHA256(RFC8785(EnvelopeMessagePreimageV1))`;
- only the final encoded frame uses `frameDigest=SHA256(frameExactBytes)` as
  `STANDARD_EXACT_BYTES` storage/transport metadata.

This amendment adds no alternate commit-only digest formula and no edge from that envelope
chain back into the materialization preimage DAG above.

Page/order/coverage digest preimages do not depend on beginHeaderDigest or receiptDigest; the
page payload may still carry block identity references that exact-equal begin/receipt IDs and
digests. No manifest digest preimage depends on begin or receipt, and begin never references a
receipt digest. A `REFERENCE_EQUALITY` field carries the referenced digest bytes and verifies
them against the actual object; it does not inline that object's preimage. Global
payloadDigest/messageDigest/frameDigest rules remain the separate 07 envelope chain.

## 5. PVMC-1 active state-machine profile

The active profile is exactly `17 machines / 123 machine-local states / 151 directed edges /
64 terminals`. Initial state is the first state below. `A|B` means two explicit edges, not an
implicit wildcard. For every row, the state set is exactly the unique union of named edge
endpoints and the explicit terminal list; no unnamed state or wildcard edge is permitted.

1. `SM-SOURCE` — 12 states / 14 edges. States:
   `UNBOUND, TRANSPORT_CONNECTED, AUTHENTICATED, SOURCE_ASSERTED, SOURCE_VERIFIED,
   REPLICA_BOUND, APPLICATION_READY, AUTH_FAILED, IDENTITY_MISMATCH, SOURCE_MISMATCH,
   REVOKED, OFFLINE_LAST_GOOD`. Edges:
   `UNBOUND->TRANSPORT_CONNECTED`; `TRANSPORT_CONNECTED->AUTHENTICATED|AUTH_FAILED`;
   `AUTHENTICATED->SOURCE_ASSERTED|IDENTITY_MISMATCH`;
   `SOURCE_ASSERTED->SOURCE_VERIFIED|SOURCE_MISMATCH`;
   `SOURCE_VERIFIED->REPLICA_BOUND|REVOKED`;
   `REPLICA_BOUND->APPLICATION_READY|REVOKED|OFFLINE_LAST_GOOD`;
   `APPLICATION_READY->REVOKED|OFFLINE_LAST_GOOD`. Terminals:
   `AUTH_FAILED, IDENTITY_MISMATCH, SOURCE_MISMATCH, REVOKED, OFFLINE_LAST_GOOD`;
   `APPLICATION_READY` is nonterminal.
2. `SM-READ-ATTEMPT` — 10 / 10. `CREATED->READING|FAILED`;
   `READING->VERIFYING|FAILED`; `VERIFYING->VERIFIED|REJECTED|QUARANTINED`;
   `VERIFIED->COMMITTED|EVIDENCE_REUSED|CAS_CONFLICT`. Terminals:
   `COMMITTED, EVIDENCE_REUSED, FAILED, REJECTED, QUARANTINED, CAS_CONFLICT`.
3. `SM-MATERIALIZATION` — 4 / 3. `STAGING->SEALED|REJECTED|QUARANTINED`; terminals:
   `SEALED, REJECTED, QUARANTINED`.
4. `SM-TIMELINE-HEAD` — 3 / 3. `ABSENT->PRESENT`, `PRESENT->PRESENT`,
   `PRESENT->TOMBSTONED_PROVEN`; only `TOMBSTONED_PROVEN` is terminal.
5. `SM-GAP-REPAIR` — 5 / 4. `ACTIVE->HEAD_ADVANCED|EVIDENCE_REUSED|FAILED|STALE`; terminals:
   `HEAD_ADVANCED, EVIDENCE_REUSED, FAILED, STALE`.
6. `SM-LIVE` — 11 / 10. `OBSERVED->ANCHORED|UNANCHORED_ACTIVITY|DROPPED_STALE_FENCE|
   DROPPED_CAPACITY|EXPIRED|LOST_ON_RESTART`; `ANCHORED->DISPLAYED`;
   `DISPLAYED->PROMOTED|CONFLICT_REPAIR_REQUIRED`; `PROMOTED->RETIRED`. Terminals:
   `RETIRED, UNANCHORED_ACTIVITY, CONFLICT_REPAIR_REQUIRED, DROPPED_STALE_FENCE,
   DROPPED_CAPACITY, EXPIRED, LOST_ON_RESTART`.
7. `SM-OPERATION` — 13 / 18. `RECEIVED->REJECTED_BEFORE_ADMISSION|ADMITTED`;
   `ADMITTED->QUEUED|BLOCKED_PRECONDITION|READY|CANCELLED_PRE_DISPATCH`;
   `QUEUED->READY|CANCELLED_PRE_DISPATCH`;
   `BLOCKED_PRECONDITION->READY|CANCELLED_PRE_DISPATCH`;
   `READY->DISPATCHING|CANCELLED_PRE_DISPATCH`;
   `DISPATCHING->PROVIDER_ACCEPTED|FAILED_DEFINITIVE|OUTCOME_UNKNOWN`;
   `PROVIDER_ACCEPTED->AWAITING_EFFECT_OBSERVATION`;
   `AWAITING_EFFECT_OBSERVATION->SUCCEEDED|FAILED_DEFINITIVE`. Terminals:
   `REJECTED_BEFORE_ADMISSION, SUCCEEDED, FAILED_DEFINITIVE, OUTCOME_UNKNOWN,
   CANCELLED_PRE_DISPATCH`.
8. `SM-DISPATCH-ATTEMPT` — 6 / 5. `PREPARED->DEFINITIVE_NOT_DISPATCHED|CALL_STARTED`;
   `CALL_STARTED->PROVIDER_ACCEPTED|PROVIDER_REJECTED_NO_SIDE_EFFECT|OUTCOME_UNKNOWN`;
   terminals: `DEFINITIVE_NOT_DISPATCHED, PROVIDER_ACCEPTED,
   PROVIDER_REJECTED_NO_SIDE_EFFECT, OUTCOME_UNKNOWN`.
9. `SM-EFFECT-OBSERVATION` — 5 / 4. `NONE->PENDING`;
   `PENDING->OBSERVED_MATCH|OBSERVED_CONFLICT|OBSERVATION_UNAVAILABLE`; terminals:
   `OBSERVED_MATCH, OBSERVED_CONFLICT, OBSERVATION_UNAVAILABLE`.
10. `SM-RECONCILE` — 6 / 6. `ABSENT->REQUESTED`;
    `REQUESTED->STILL_UNKNOWN|EXECUTED_MATCHED|EXECUTED_CONFLICT|NOT_EXECUTED_PROVEN`;
    `STILL_UNKNOWN->REQUESTED`. Terminals:
    `EXECUTED_MATCHED, EXECUTED_CONFLICT, NOT_EXECUTED_PROVEN`.
11. `SM-LOCAL-INTENT` — 8 / 14. `DRAFT->HELD_OFFLINE`;
    `HELD_OFFLINE->READY_TO_SUBMIT`; `READY_TO_SUBMIT->SUBMITTING`;
    `SUBMITTING->BRIDGE_ACCEPTED|ADMISSION_UNKNOWN|LOCAL_ERROR`;
    `ADMISSION_UNKNOWN->BRIDGE_ACCEPTED|LOCAL_ERROR`;
    each of `DRAFT,HELD_OFFLINE,READY_TO_SUBMIT` may enter `LOCAL_CANCELLED` or `LOCAL_ERROR`.
    Terminals: `BRIDGE_ACCEPTED, LOCAL_CANCELLED, LOCAL_ERROR`. `ADMISSION_UNKNOWN` is query-only
    and nonterminal; it never returns to submitting.
12. `SM-QUEUE-ENTRY` — 4 / 4. `QUEUED->QUEUED|DISPATCH_OWNED|CANCELLED`;
    `DISPATCH_OWNED->CONSUMED`; terminals: `CONSUMED, CANCELLED`. `EDITED` is forbidden.
13. `SM-INTERACTION` — 7 / 15. `OPEN_UNCLAIMED<->OPEN_CLAIMED`;
    `OPEN_CLAIMED->RESPONSE_PENDING`; each open/pending state may enter
    `RESOLVED|WITHDRAWN|STALE|EXPIRED`; those four states are terminal.
14. `SM-CLAIM` — 6 / 5. `NONE->ACTIVE`;
    `ACTIVE->RELEASED|EXPIRED|CONSUMED|REVOKED`; terminals:
    `RELEASED, EXPIRED, CONSUMED, REVOKED`. Renew is value CAS, not an edge.
15. `SM-DURABLE-DELIVERY` — 7 / 7. `COMMITTED->QUEUED`;
    `QUEUED->SENT|PAUSED_BACKPRESSURE|EXPIRED_AFTER_POLICY`;
    `PAUSED_BACKPRESSURE->QUEUED`; `SENT->ACKED|SNAPSHOT_REQUIRED`. Terminals:
    `ACKED, SNAPSHOT_REQUIRED, EXPIRED_AFTER_POLICY`. Mutable state belongs to
    `durable_delivery_head.state`; immutable
    event facts and outbox envelopes stay separate.
16. `SM-REPLICA-APPLY` — 8 / 15. Main chain:
    `RECEIVED->STAGED->APPLIED->READBACK_VERIFIED->PUBLISHED->ACKED`. Each of the five
    nonterminal pre-ACK states also has an explicit edge to `REJECTED` and `SNAPSHOT_REQUIRED`.
    terminals: `ACKED, REJECTED, SNAPSHOT_REQUIRED`.
17. `SM-CONTENT-OFFER` — 8 / 14. Main chain:
    `OFFERED->TRANSFERRING->VERIFYING->FINALIZING->FINALIZED`; each of offered/transferring/
    verifying may enter `FAILED|CANCELLED|EXPIRED`; finalizing may enter `FAILED`. PVMC-1
    requires `ownerFeature="MESSAGE_IMAGE"`; general Transfer/path/destination/overwrite
    authority is forbidden. Terminals:
    `FINALIZED, FAILED, CANCELLED, EXPIRED`.

Only `PRESENT->PRESENT` and `QUEUED->QUEUED` are state self-loops. The active durable route set
contains exactly seven distinct wire identities (the TIMELINE mode suffix is part of each
materialization route identity):

```text
1. sync.gap.v1
2. materialization.begin.v1:TIMELINE
3. materialization.page.v1:TIMELINE
4. materialization.commit.v1:TIMELINE
5. operation.state.v1
6. queue.snapshot.v1
7. interaction.snapshot.v1
```

The graph-level semantic owner, authoritative transition writer, replica writer, storage, wire,
and unknown-policy bindings are separate and closed:

| Machine | Semantic owner | Authoritative transition writer | Storage and replica writer | Wire and unknown policy |
|---|---|---|---|---|
| `SM-SOURCE` | `SourceRegistry` | `SourceRegistry` | `EVIDENCE_DERIVED`; no mutable state; Mobile source evidence is consumed only inside `ReplicaApplyCoordinator` and creates no source transition | authenticated bind/capability control; mismatch fails closed, old replica read-only |
| `SM-READ-ATTEMPT` | `CanonicalTimelineWriter` | `CanonicalTimelineWriter` | Bridge `timeline_read_attempt.state` plus immutable evidence; no Mobile transition writer | no standalone durable kind; unsupported becomes typed Gap/failed attempt and never changes head |
| `SM-MATERIALIZATION` | `CanonicalTimelineWriter` | `CanonicalTimelineWriter` | Bridge `timeline_materialization.state`; Mobile `m_timeline_materialization.state` only by `ReplicaApplyCoordinator` | exact begin/page/commit TIMELINE; unknown is `SNAPSHOT_REPAIR` |
| `SM-TIMELINE-HEAD` | `CanonicalTimelineWriter` | `CanonicalTimelineWriter` | Bridge `timeline_head.state`; Mobile `m_timeline_head.state` only by `ReplicaApplyCoordinator` | only verified commit projects it; unknown preserves last-good |
| `SM-GAP-REPAIR` | `TimelineRead` | `TimelineRead` memory coordinator | `MEMORY_ONLY`; no replica writer | `gap.repair.request.v1/result.v1`; unknown intent rejected |
| `SM-LIVE` | `LiveOverlay` | `LiveOverlay` | `MEMORY_ONLY`; no replica writer | ephemeral Provider notification; weak identity becomes `UNANCHORED_ACTIVITY` |
| `SM-OPERATION` | `OperationKernel` | `OperationKernel` | Bridge `operation.lifecycle_state`; Mobile `m_operation.lifecycle_state` only by `ReplicaApplyCoordinator` | submit/state; unknown durable variant pauses feature stream |
| `SM-DISPATCH-ATTEMPT` | `OperationKernel` | `OperationKernel` | Bridge `dispatch_attempt.state`; Mobile projection only by `ReplicaApplyCoordinator` | no independent durable kind; projected by operation state |
| `SM-EFFECT-OBSERVATION` | `OperationKernel` | `OperationKernel` | Bridge `operation.effect_observation_state`; Mobile projection only by `ReplicaApplyCoordinator` | unknown observation cannot prove success |
| `SM-RECONCILE` | `OperationKernel` | `OperationKernel` | append-only Bridge attempt/resolution; Mobile projection only by `ReplicaApplyCoordinator` | reconcile request/result; durable projection remains operation state |
| `SM-LOCAL-INTENT` | Mobile `LocalIntentRepository` | Mobile `LocalIntentRepository` | Mobile `protected_local_intent.state`; `replicaWriterBindings=[]` | query/snapshot; no durable event and no resend from unknown |
| `SM-QUEUE-ENTRY` | `OperationKernel` | `OperationKernel` | Bridge `queue_entry.state`; Mobile `m_queue_entry.state` only by `ReplicaApplyCoordinator` | queue snapshot; unknown is `SNAPSHOT_REPAIR` |
| `SM-INTERACTION` | `InteractionBroker` | `InteractionBroker` | Bridge `interaction.state`; Mobile `m_interaction.state` only by `ReplicaApplyCoordinator` | interaction snapshot; unknown pauses feature stream |
| `SM-CLAIM` | `InteractionBroker` | `InteractionBroker` | Bridge `interaction_claim.state`; Mobile claim projection only by `ReplicaApplyCoordinator` | typed claim controls; no independent durable kind |
| `SM-DURABLE-DELIVERY` | `SyncProjection` | `SyncProjectionDeliveryWriter` invoked inside the originating owner transaction | Bridge `durable_delivery_head.state` plus immutable facts/envelopes; Mobile inbox/apply only by `ReplicaApplyCoordinator` | seven routes; unknown fails before QUEUED; `eventFactOwnerSelectorRef=EVENT_KEY_OWNER_V1` |
| `SM-REPLICA-APPLY` | Mobile `ReplicaApplyCoordinator` | Mobile `ReplicaApplyCoordinator` | Mobile `inbox_event.apply_state`; `replicaWriterBindings=[]` | ACK/snapshot-repair; unknown rejects, sequence/base/manifest gap requires snapshot; no event-fact owner selector |
| `SM-CONTENT-OFFER` | `ContentReferenceService` | `ContentReferenceService` | Bridge `content_offer.state`, `owner_feature_id='messageImage'`; no Mobile semantic writer | sealed image prepare/commit; unknown creates no ticket/ref |

For each concrete variant, `EventKey.ownerRef` resolves exactly one originating event-fact owner
through the durable-delivery row's required `eventFactOwnerSelectorRef`. That provenance owner is
not the delivery-machine semantic owner. `SyncProjection` owns durable delivery, and
`SyncProjectionDeliveryWriter` performs its transition atomically inside the originating owner's
transaction. Mobile `ReplicaApplyCoordinator` owns and writes only the Mobile apply machine and
listed rebuildable replica/inbox/apply state; it cannot initiate a Bridge domain transition,
write Bridge event facts/outbox, or advance a canonical Bridge head.

Adapters, transports, verifiers, byte backends, and other projectors are not alternate writers. R77
counts event fact and envelope separately: public connected `1/1`, public disconnected `1/0`,
coalesced/rejected/internal `0/0`; an eligible outbox failure rolls back the owner transaction.

Every machine must bind one exact semantic owner selector, one authoritative writer, storage
mode plus table/state column (or an
explicit `MEMORY_ONLY`, `EVIDENCE_DERIVED`, or `APPEND_ONLY_NO_MUTABLE_STATE` declaration),
wire projection, unknown policy, guards, typed problem, zero-effect/post-state, and positive/
negative/fault evidence. Catalog/Settings/Goal/Relation/Ephemeral/Transfer/Native and all
`PX-001..PX-030` must have zero reachable rows in the active view.

```text
SemanticOwnerSelectorRefV1 = {
  refKind: "SEMANTIC_OWNER_SELECTOR", registryId: Id
}

AuthoritativeWriterRefV1 = {
  refKind: "AUTHORITATIVE_WRITER", registryId: Id
}

StorageBindingRefV1 = {
  refKind: "STORAGE_BINDING", registryId: Id
}

ProjectionRouteRefV1 = {
  refKind: "PROJECTION_ROUTE", registryId: Id
}

WireProjectionRefV1 = {
  refKind: "WIRE_PROJECTION", registryId: Id
}

UnknownPolicyRefV1 = {
  refKind: "UNKNOWN_POLICY", registryId: Id
}

GuardRefV1 = {
  refKind: "EDGE_GUARD", registryId: Id
}

OracleProjectionRefV1 = {
  refKind: "ORACLE_PROJECTION", registryId: Id
}

EventFactOwnerSelectorRefV1 = {
  refKind: "EVENT_FACT_OWNER_SELECTOR", registryId: "EVENT_KEY_OWNER_V1"
}

NonEmptyStorageBindingRefSetV1 =
  array<StorageBindingRefV1, minItems=1,
        maxItems=PVMC1_ACTIVE_STORAGE_BINDING_COUNT, uniqueBy=registryId>

NonEmptyProjectionRouteRefSetV1 =
  array<ProjectionRouteRefV1, minItems=1, maxItems=7, uniqueBy=registryId>

NonEmptyUniqueGuardRefSetV1 =
  array<GuardRefV1, minItems=1,
        maxItems=PVMC1_ACTIVE_GUARD_COUNT, uniqueBy=registryId>

NonEmptyUniqueVectorIdSetV1 =
  array<VectorId, minItems=1,
        maxItems=PVMC1_ACTIVE_VECTOR_COUNT, uniqueItems=true>

MachineEdgeCoordinateV1 =
  | { machineId: "SM-SOURCE", from: SmSourceStateV1, to: SmSourceStateV1 }
  | { machineId: "SM-READ-ATTEMPT", from: SmReadAttemptStateV1, to: SmReadAttemptStateV1 }
  | { machineId: "SM-MATERIALIZATION", from: SmMaterializationStateV1, to: SmMaterializationStateV1 }
  | { machineId: "SM-TIMELINE-HEAD", from: SmTimelineHeadStateV1, to: SmTimelineHeadStateV1 }
  | { machineId: "SM-GAP-REPAIR", from: SmGapRepairStateV1, to: SmGapRepairStateV1 }
  | { machineId: "SM-LIVE", from: SmLiveStateV1, to: SmLiveStateV1 }
  | { machineId: "SM-OPERATION", from: SmOperationStateV1, to: SmOperationStateV1 }
  | { machineId: "SM-DISPATCH-ATTEMPT", from: SmDispatchAttemptStateV1, to: SmDispatchAttemptStateV1 }
  | { machineId: "SM-EFFECT-OBSERVATION", from: SmEffectObservationStateV1, to: SmEffectObservationStateV1 }
  | { machineId: "SM-RECONCILE", from: SmReconcileStateV1, to: SmReconcileStateV1 }
  | { machineId: "SM-LOCAL-INTENT", from: SmLocalIntentStateV1, to: SmLocalIntentStateV1 }
  | { machineId: "SM-QUEUE-ENTRY", from: SmQueueEntryStateV1, to: SmQueueEntryStateV1 }
  | { machineId: "SM-INTERACTION", from: SmInteractionStateV1, to: SmInteractionStateV1 }
  | { machineId: "SM-CLAIM", from: SmClaimStateV1, to: SmClaimStateV1 }
  | { machineId: "SM-DURABLE-DELIVERY", from: SmDurableDeliveryStateV1, to: SmDurableDeliveryStateV1 }
  | { machineId: "SM-REPLICA-APPLY", from: SmReplicaApplyStateV1, to: SmReplicaApplyStateV1 }
  | { machineId: "SM-CONTENT-OFFER", from: SmContentOfferStateV1, to: SmContentOfferStateV1 }

ReplicaWriterBindingV1 = {
  replicaRole: "MOBILE_REBUILDABLE_REPLICA",
  replicaWriterRef: {
    host: "MOBILE",
    writerId: "ReplicaApplyCoordinator"
  },
  storageBindings: NonEmptyStorageBindingRefSetV1,
  routeBindings: NonEmptyProjectionRouteRefSetV1,
  canWriteSemanticOwnerState: false,
  canWriteEventFacts: false,
  canWriteOutboxEnvelopes: false,
  canAdvanceCanonicalHead: false
}

UniqueReplicaWriterBindingSetV1 =
  array<ReplicaWriterBindingV1, minItems=0, maxItems=1,
        uniqueBy=(replicaRole,storageBindings)>

MachineEdgeAuthorityV1 = {
  edgeId: "<machineId>:<from>-><to>",
  coordinate: MachineEdgeCoordinateV1,
  semanticOwnerRef: SemanticOwnerSelectorRefV1,
  authoritativeWriterRef: AuthoritativeWriterRefV1,
  eventFactOwnerSelectorRef: EventFactOwnerSelectorRefV1 | null,
  replicaWriterBindings: UniqueReplicaWriterBindingSetV1,
  storageBindingRef: StorageBindingRefV1,
  wireProjectionRef: WireProjectionRefV1,
  unknownPolicyRef: UnknownPolicyRefV1,
  guardRefs: NonEmptyUniqueGuardRefSetV1,
  failureProblem: ProblemCodeV1,
  zeroEffectProjectionRef: OracleProjectionRefV1,
  successPostStateProjectionRef: OracleProjectionRefV1,
  positiveVectorId: VectorId,
  negativeVectorIds: NonEmptyUniqueVectorIdSetV1,
  faultVectorIds: NonEmptyUniqueVectorIdSetV1
}
```

Each `Sm*StateV1` in the coordinate union is the exact generated enum from the corresponding
machine list above; it is not a shared string alias. The three uppercase `PVMC1_ACTIVE_*_COUNT`
bounds are generated positive safe-integer build constants exact-equal to their active B2
Registry row counts; B2 may not substitute guessed numeric ceilings.
Every Registry ref above must resolve exactly one active PVMC-1 row of its named kind; dangling,
wrong-kind, inactive-profile, or multiply resolved IDs reject. The coordinate union enforces
`from,to in states(machineId)`. The validator additionally requires
`(from,to) in allowedEdges(machineId)`, recomputes `edgeId` from the coordinate, and requires
exactly one authority row for every allowed edge and none for a forbidden edge.

All edges of one machine exact-equal its machine owner/writer/storage/wire/unknown binding. Only
SM-DURABLE-DELIVERY has non-null `eventFactOwnerSelectorRef`, exact-equal to
`EVENT_KEY_OWNER_V1`; every other machine requires null. A replica binding is unique by
`(replicaRole,storageBindings)` and may be empty only where the table above says no replica. It
never substitutes for the semantic owner or authoritative writer.

B2 must contain exactly 151 unique rows of this type, one per edge above, with no generic
placeholder guard/problem/oracle and no missing vector. This amendment freezes the graph and
binding columns but does not claim those 151 concrete governance rows already exist. Machine B2
and formal generation remain `BLOCKED` until the immutable Registry supplies them and an
independent review finds `P0=0/P1=0`.

Registry, Schema, DDL transition relation, generated TS/Dart unions, and vectors must exact-set
equal this profile. The validator must prove unique/reachable states and edges, terminal sinks,
an outgoing and terminal path for every nonterminal, the two explicit self-loops only, exact
durable variants, exact owner/writer/storage bindings, the R77 fact/envelope cardinalities, and
the digest DAG. Each allowed edge needs a positive vector; each deliberate forbidden edge and
every cross-table kill point needs an independent failure marker and unchanged post-state.

## 6. `ADMISSION_UNKNOWN` read-only lookup

The only Mobile recovery transition from `ADMISSION_UNKNOWN` uses this schema-revision-1 pair:

```text
AdmissionLookupKeyV1 = {
  sourcePartition: SourcePartitionV1,
  operationId: Id,
  fingerprintVersion: 1,
  operationFingerprint: Sha256Hex64
}

AdmissionSerializationKeyV1 = {
  sourcePartition: SourcePartitionV1,
  operationId: Id
}

OperationQueryV1 = {
  schemaRevision: 1,
  kind: "operation.query",
  requestId: Id,
  sourcePartition: SourcePartitionV1,
  operationId: Id,
  fingerprintVersion: 1,
  operationFingerprint: Sha256Hex64
}

OperationSnapshotResultV1 =
  | {
      schemaRevision: 1, kind: "operation.snapshot", outcome: "MATCHED",
      requestId: Id, sourcePartition: SourcePartitionV1, operationId: Id,
      fingerprintVersion: 1, operationFingerprint: Sha256Hex64,
      snapshot: OperationAdmissionSnapshotV1
    }
  | {
      schemaRevision: 1, kind: "operation.snapshot", outcome: "NOT_FOUND",
      requestId: Id, sourcePartition: SourcePartitionV1, operationId: Id,
      fingerprintVersion: 1, operationFingerprint: Sha256Hex64
    }
  | {
      schemaRevision: 1, kind: "operation.snapshot", outcome: "CONFLICT",
      requestId: Id, sourcePartition: SourcePartitionV1, operationId: Id,
      fingerprintVersion: 1, operationFingerprint: Sha256Hex64,
      problem: ProblemV1
    }

OperationAdmissionSnapshotV1 = {
  operationRevision: AggregateRevision1,
  lifecycleState: SmOperationStateV1
}
```

`OperationAdmissionSnapshotV1` is derived from the existing immutable operation header plus
current aggregate revision/state; it cannot contain kind/target/body, attempt, queue token,
retry flag, or dispatch authority.
Before any outcome or actor/fingerprint condition is evaluated, the response `requestId` must
exact-equal the one outstanding `OperationQueryV1.requestId`. Its `sourcePartition`,
`operationId`, `fingerprintVersion`, and `operationFingerprint` must each exact-equal both the
corresponding query fields and the active `AdmissionLookupKeyV1`; those query fields must already
exact-equal that key. Schema revision and kind must also match the closed query/result pair. Any
mismatch is the table's `source/schema/request mismatch` branch: unchanged
`ADMISSION_UNKNOWN`, zero effect, and no snapshot is consumed.
The query never carries actor fields. After exact authenticated-source equality and while holding
the keyed barrier, Bridge derives the current `AuthenticatedActorBindingKeyV1` from execution
context. `MATCHED` is reachable only for the sealed `OperationOriginV1.AUTHENTICATED_ACTOR`
branch, whose actor binding must exact-equal that key before fingerprint comparison. The private
`AUTO_APPROVAL_POLICY` branch or an authenticated-actor mismatch returns `CONFLICT` with
`problemCode="OPERATION_ACTOR_MISMATCH"`, no snapshot, and zero effect. Only after actor equality
may version/digest mismatch return `OPERATION_FINGERPRINT_CONFLICT`; `MATCHED` requires exact
actor, ID, version, and fingerprint equality. Neither mismatch becomes not-found. The barrier is
the same one used for that `AdmissionSerializationKeyV1`; it linearizes the read with
RECEIVED/admission transitions but creates no absence fact.

For one exact AdmissionLookupKey, Mobile has at most one query in flight and sends no submit,
dispatch, retry, new attempt, or new operation ID while it is outstanding. A transport timeout
releases only the query slot, leaves `ADMISSION_UNKNOWN`, and permits one later read-only query.
Every response branch performs zero Provider calls and creates no operation/attempt/outbox/event.
The exact local projection is:

| Result | Exact condition | Local post-state |
|---|---|---|
| MATCHED | lifecycle `RECEIVED` | unchanged `ADMISSION_UNKNOWN`; release barrier only |
| MATCHED | lifecycle `REJECTED_BEFORE_ADMISSION` | `LOCAL_ERROR` |
| MATCHED | lifecycle in `ADMITTED, QUEUED, BLOCKED_PRECONDITION, READY, DISPATCHING, PROVIDER_ACCEPTED, AWAITING_EFFECT_OBSERVATION, SUCCEEDED, FAILED_DEFINITIVE, OUTCOME_UNKNOWN, CANCELLED_PRE_DISPATCH` | `BRIDGE_ACCEPTED` |
| NOT_FOUND | one authenticated linearized read found no row | unchanged `ADMISSION_UNKNOWN`; zero resend/new ID |
| CONFLICT | same ID resolves a non-public origin or authenticated actor differs from immutable public origin, checked before fingerprint | `LOCAL_ERROR` |
| CONFLICT | actor matches and fingerprint version/digest differs | `LOCAL_ERROR` |
| source/schema/request mismatch or auth failure | any | unchanged `ADMISSION_UNKNOWN`; zero effect |

`NOT_FOUND` is a single authenticated observation, never durable absence proof. It cannot close
unknown or authorize a new ID. RECEIVED also has not crossed admission and cannot project
BRIDGE_ACCEPTED. Only a definitive pre-admission rejection or conflict may enter LOCAL_ERROR;
any later new operation ID requires deliberate user intent and is never an automatic resend.
Actor/fingerprint conflicts perform zero Provider calls and create or modify no
operation/attempt/outbox/event row; the response snapshot remains absent.
No unchanged observation adds a machine self-loop, and no branch transitions
`ADMISSION_UNKNOWN` back to `SUBMITTING` or grants dispatch authority.

## 7. Implementation order and gate

1. Contract B1 implements sections 1--4 and independent P0-01..P0-17 semantic mutations.
2. Contract B2 implements sections 5--6 and exact Registry/Schema/DDL/TS/Dart/vector equality.
3. Generated helpers then dispatch by Registry derivation mode; const-domain helpers alone are
   insufficient for the frozen receipt.
4. Temporary generate/check/byte-compare must pass before exactly one formal four-target
   generation.

Until immutable B1 and B2 each receive independent `P0=0/P1=0` acceptance, formal generation,
Adapter/Store/Mobile integration against generated types, runtime activation, and candidate
claims remain blocked.
