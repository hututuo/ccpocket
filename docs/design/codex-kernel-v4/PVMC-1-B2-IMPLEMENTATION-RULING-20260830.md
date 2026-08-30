# PVMC-1 B2 implementation ruling

Date: `2026-08-30`

Status: `REVIEW_CANDIDATE / NORMATIVE_UPON_ACCEPTANCE` for Contract B2 only. These
exact bytes become normative after independent review reports document-local
`P0=0/P1=0` and an unchanged implementation-branch commit freezes them.

This ruling is subordinate to the accepted
`PVMC-1-COMPACT-AUTHORITY-AMENDMENT-20260830.md` at commit
`a0c9f3785717af3ac03f3a8ae90080c11952ead4`, file SHA-256
`317dfd46692e628c70a7a8a989debf9f8fd9384b19a257c7c2655bf7d4c7f6ab`.
It closes only the implementation seams in amendment sections 5--6. It does not
change B1 types or semantics, create B2 rows, accept a Registry, authorize formal
generation, add a fifth generated target, or activate runtime/storage.

## 1. Exact count meanings

The four profile counts mean exactly:

- `17` active machine Registry records;
- `123` machine-local state occurrences across those 17 records;
- `151` allowed concrete directed edge coordinates;
- `64` terminal-state occurrences across those 17 records.

They do not mean 17 physical SQL tables or 64 durable variants. The durable route
inventory contains exactly the seven identities already listed in the amendment.
The sum of the 17 machine-local Cartesian products is `1023`; therefore the exact
forbidden same-machine ordered-pair complement is `1023-151=872`. Cross-machine
pairs are wrong-coordinate failures, not members of that 872-pair complement.

B2 must derive all five counts (`17/123/151/64/872`) from the normalized active
model and reject a literal override. The two allowed self-loops remain part of the
151 allowed edges. There are 123 same-state coordinates, one for each machine-local
state occurrence; the other `123-2=121` same-state coordinates are individually
present in the 872-marker forbidden complement.

### 1.1 Additive actor-origin admission view

The compact amendment's admission oracle names `AuthenticatedActorBindingKeyV1`
and the sealed persisted `OperationOriginV1`, but Contract B1 intentionally did
not place either full internal authority type in its active generated closure.
Contract B2 adds the exact actor key plus the following read-only admission view.
The view is derived under the keyed barrier from the persisted origin; it is not a
second origin authority and cannot be written back. This additive B2 closure does
not amend or rewrite the published B1 commit, and it adds no actor field to
`OperationQueryV1` or `OperationSnapshotResultV1`.

```text
AuthenticatedActorBindingKeyV1 =
  | {
      kind: "PAIRED_DEVICE",
      principalId: Id,
      trustRevision: AggregateRevision1
    }
  | {
      kind: "API_KEY",
      principalId: Id,
      credentialRevision: AggregateRevision1
    }
  | {
      kind: "OPEN_CONNECTION",
      principalId: Id,
      connectionEpoch: BoundEpochV1
    }

OperationOriginAdmissionViewV1 =
  | {
      kind: "AUTHENTICATED_ACTOR",
      actorBinding: AuthenticatedActorBindingKeyV1
    }
  | {
      kind: "AUTO_APPROVAL_POLICY"
    }
```

The admission lookup reads only this projection under the
`AdmissionSerializationKeyV1` barrier. The full private origin evidence remains
owned by the existing operation ledger and is outside B2 generation. Any
`AUTO_APPROVAL_POLICY` view deterministically takes the actor-mismatch conflict
branch before fingerprint comparison. The public wire query never selects an
origin or actor. B2 does not widen the B1 public operation-submit shape and does
not make the private branch wire-reachable.

## 2. Closed storage and replica projections

`storageBindingRef` always names the authoritative machine storage from the
amendment table. A `replicaWriterBindings` entry is a separate rebuildable Mobile
projection and never changes the semantic owner or authoritative writer. B2 uses
the following closed rows; `SqlIdentifier` is a non-empty ASCII identifier matching
`[A-Za-z_][A-Za-z0-9_]*` and is not a quoted or qualified SQL fragment.

```text
StorageModeV1 =
  "SQL_STATE_COLUMN" | "SQL_AUXILIARY" | "MEMORY_ONLY" |
  "EVIDENCE_DERIVED" | "APPEND_ONLY_NO_MUTABLE_STATE"

PhysicalStorageCoordinateV1 = {
  coordinateId: Id,
  host: "BRIDGE" | "MOBILE",
  databaseId: Id,
  tableName: SqlIdentifier,
  stateColumnName: SqlIdentifier | null,
  storageRole: "MUTABLE_STATE" | "AUXILIARY_MUTABLE_STATE" |
               "IMMUTABLE_FACT" | "IMMUTABLE_ENVELOPE" |
               "STAGING" | "CHECKPOINT" | "PUBLICATION_OUTBOX"
}

StorageWriterBindingV1 =
  | { writerKind: "AUTHORITATIVE",
      authoritativeWriterRef: AuthoritativeWriterRefV1 }
  | { writerKind: "REPLICA",
      replicaWriterRef: {
        host: "MOBILE",
        writerId: "ReplicaApplyCoordinator"
      } }

StorageBindingV1 = {
  registryId: Id,
  machineId: Id,
  bindingRole: "AUTHORITATIVE" | "REBUILDABLE_REPLICA" |
               "TRANSACTION_AUXILIARY",
  semanticOwnerRef: SemanticOwnerSelectorRefV1,
  writerBinding: StorageWriterBindingV1,
  storageMode: StorageModeV1,
  physicalCoordinates:
    array<PhysicalStorageCoordinateV1, minItems=0,
          maxItems=PVMC1_ACTIVE_PHYSICAL_STORAGE_COORDINATE_COUNT,
          uniqueBy=coordinateId>
}

PhysicalStorageCoordinateRefV1 = {
  storageBindingRef: StorageBindingRefV1,
  coordinateId: Id
}
```

`SQL_STATE_COLUMN` has exactly one `MUTABLE_STATE` coordinate and that coordinate
has the exact table/state column frozen for its machine; it may not hide another
mutable state coordinate. `SQL_AUXILIARY` has one or more physical coordinates.
`APPEND_ONLY_NO_MUTABLE_STATE` has one or more immutable coordinates and no mutable
state column. `MEMORY_ONLY` and `EVIDENCE_DERIVED` have no physical coordinate. Every
physical coordinate ID is globally unique and
every `PhysicalStorageCoordinateRefV1` exact-resolves its named binding and nested
coordinate.

An authoritative binding exact-equals the machine's semantic owner and
authoritative writer. A rebuildable-replica binding preserves that semantic owner,
uses only the closed Mobile replica writer, and is reachable only through the
machine's one `ReplicaWriterBindingV1`. A transaction-auxiliary binding is never a
machine-state substitute; its semantic owner and authoritative writer exact-equal
the transaction shape that writes it. References are intentionally one-way from a
manifest phase to a binding/coordinate. Storage bindings, edges, and routes store no
manifest backlink; the validator derives the complete reverse index, so one binding
may be consumed by multiple route/edge-specific manifests without a reference cycle.

The previously abbreviated Mobile projection bindings are frozen as follows:

| Machine | Authoritative storage | Mobile replica storage | Mobile replica route bindings |
|---|---|---|---|
| `SM-MATERIALIZATION` | Bridge `timeline_materialization.state` | `m_timeline_materialization.state` | `materialization.begin.v1:TIMELINE`, `materialization.page.v1:TIMELINE`, `materialization.commit.v1:TIMELINE` |
| `SM-TIMELINE-HEAD` | Bridge `timeline_head.state` | `m_timeline_head.state` | `materialization.commit.v1:TIMELINE` |
| `SM-OPERATION` | Bridge `operation.lifecycle_state` | `m_operation.lifecycle_state` | `operation.state.v1` |
| `SM-DISPATCH-ATTEMPT` | Bridge `dispatch_attempt.state` | `m_operation.dispatch_attempt_state` | `operation.state.v1` |
| `SM-EFFECT-OBSERVATION` | Bridge `operation.effect_observation_state` | `m_operation.effect_observation_state` | `operation.state.v1` |
| `SM-RECONCILE` | Bridge `APPEND_ONLY_NO_MUTABLE_STATE` over immutable `reconcile_attempt` plus optional same-revision `reconcile_resolution` | `m_operation.reconcile_state` | `operation.state.v1` |
| `SM-QUEUE-ENTRY` | Bridge `queue_entry.state` | `m_queue_entry.state` | `queue.snapshot.v1` |
| `SM-INTERACTION` | Bridge `interaction.state` | `m_interaction.state` | `interaction.snapshot.v1` |
| `SM-CLAIM` | Bridge `interaction_claim.state` | `m_interaction.claim_state` | `interaction.snapshot.v1` |
| `SM-DURABLE-DELIVERY` | Bridge `durable_delivery_head.state` plus immutable fact/envelope rows | none; the immutable envelope is input to the separate apply machine, not a replica of `SmDurableDeliveryStateV1` | none |

Each row above that names Mobile replica storage has exactly one
`ReplicaWriterBindingV1`, with
`replicaRole="MOBILE_REBUILDABLE_REPLICA"`, writer host/id
`MOBILE/ReplicaApplyCoordinator`, and all four authority flags false. Its
`storageBindings` and `routeBindings` exact-set equal that table row.

The following machines have `replicaWriterBindings=[]`:

- `SM-SOURCE`, `SM-READ-ATTEMPT`, `SM-GAP-REPAIR`, `SM-LIVE`;
- `SM-LOCAL-INTENT`, because Mobile `LocalIntentRepository` is its semantic owner
  and authoritative writer rather than a replica writer;
- `SM-DURABLE-DELIVERY`; its seven envelopes are authenticated inputs to
  `SM-REPLICA-APPLY`, not Mobile state replicas of the Bridge delivery machine;
- `SM-REPLICA-APPLY`, because Mobile `ReplicaApplyCoordinator` owns/writes that
  machine directly at `m_inbox_event.apply_state`;
- `SM-CONTENT-OFFER`.

Only `SM-REPLICA-APPLY` may bind `m_inbox_event.apply_state`. Registry validation
must reject a delivery-machine replica binding, another machine-local enum on that
column, an alternate writer, storage alias, route subset, or extra replica binding.
No Bridge delivery edge is writable from Mobile.

## 3. DDL representation inside the four formal targets

The formal target set remains exactly the existing four paths:

1. `docs/design/codex-kernel-v4/contracts/generated/schema.json`
2. `docs/design/codex-kernel-v4/contracts/generated/profile-manifest.json`
3. `packages/bridge/src/conversation-core/protocol/generated/contract.ts`
4. `apps/mobile/lib/conversation_core/protocol/generated/contract.dart`

B2 does not add a fifth SQL file. The generator derives one canonical transition
relation from the normalized 17-machine/151-edge model. Rows are sorted by
`(machineOrdinal,fromStateOrdinal,toStateOrdinal)`, where machine and state
ordinals are their positions in the accepted normative lists. The exact SQL bytes
are frozen as `PVMC1_MACHINE_TRANSITION_SQL_V1`:

- UTF-8 without BOM, LF line endings, and exactly one final LF;
- one fixed `CREATE TABLE pvmc1_machine_transition` statement followed by one
  fixed `INSERT` statement containing 151 literal tuples and no comments;
- fixed columns, in order:
  `machine_ordinal,from_state_ordinal,to_state_ordinal,machine_id,from_state,
  to_state,edge_id,authority_json`;
- `authority_json` is RFC8785 of the exact `MachineEdgeAuthorityV1` row;
- every SQL text literal uses single quotes and replaces each embedded single
  quote with two single quotes; integers use unsigned base-10 with no leading
  zero; no locale-dependent formatting is permitted;
- tuple lines are comma-separated in the stated sort order, with no blank lines
  or trailing spaces; the final tuple is followed by `;` and the single final LF.

Before RFC8785, every set-valued array in an authority row must already be in
canonical order and validator input with another order rejects. `storageBindings`,
`routeBindings`, and `guardRefs` sort ascending by `registryId` under the frozen
JCS UTF-16 code-unit comparator; `negativeVectorIds` and `faultVectorIds` sort by
the same comparator on `VectorId`. `replicaWriterBindings` has at most one item.
No generator silently sorts a non-canonical Registry row.

The following fenced block is the complete UTF-8 template content, excluding the
fences. It has exactly one LF after the final semicolon and no other trailing byte.
The ASCII `{{ROW_TUPLES}}` token occurs exactly once and is replaced by the 151
comma-LF-joined tuple lines. The template before substitution is 657 UTF-8 bytes
with SHA-256
`2d84de976e3e27bb9cccc8978bac1a68e2f72cde702a5cc8b5bd43740cb7e744`.

```sql
CREATE TABLE pvmc1_machine_transition (
  machine_ordinal INTEGER NOT NULL CHECK(machine_ordinal >= 0),
  from_state_ordinal INTEGER NOT NULL CHECK(from_state_ordinal >= 0),
  to_state_ordinal INTEGER NOT NULL CHECK(to_state_ordinal >= 0),
  machine_id TEXT NOT NULL,
  from_state TEXT NOT NULL,
  to_state TEXT NOT NULL,
  edge_id TEXT NOT NULL,
  authority_json TEXT NOT NULL CHECK(json_valid(authority_json)),
  UNIQUE(edge_id),
  PRIMARY KEY(machine_id, from_state, to_state)
) STRICT;
INSERT INTO pvmc1_machine_transition(machine_ordinal,from_state_ordinal,to_state_ordinal,machine_id,from_state,to_state,edge_id,authority_json) VALUES
{{ROW_TUPLES}};
```

One tuple is exactly
`(<machineOrdinal>,<fromStateOrdinal>,<toStateOrdinal>,<machineIdSql>,
<fromStateSql>,<toStateSql>,<edgeIdSql>,<authorityJsonSql>)` with no spaces or
angle brackets in output. Each `*Sql` token is the corresponding UTF-8 string
wrapped in ASCII single quotes after replacing every single quote with two single
quotes. Ordinals use canonical unsigned decimal. Schema/TS/Dart generators consume
the one substituted byte buffer and may not re-render SQL independently.

The generator emits:

- the closed machine/edge representation in Schema;
- a manifest object named `machineTransitionSql` with exact fields
  `derivationId="PVMC1_MACHINE_TRANSITION_SQL_V1"`, `encoding="UTF-8"`,
  `lineEnding="LF"`, `hasBom=false`, `trailingLfCount=1`, `rowCount=151`,
  `sqlUtf8Base64`, and `sqlSha256`;
- `sqlUtf8Base64` is RFC 4648 standard Base64 with required `=` padding of the
  exact SQL bytes, and `sqlSha256` is lowercase SHA-256 of those decoded bytes;
- byte-identical SQL and immutable typed machine/edge constants in generated
  TypeScript and Dart.

B2 extends the accepted B1 digest authority inventory with exactly one active
digest-contract row, using the accepted B1 row schema unchanged:

```text
digestId = "DR-PVMC1-MACHINE-TRANSITION-SQL"
derivationMode = "STANDARD_EXACT_BYTES"
byteSubjectRef = "PVMC1_MACHINE_TRANSITION_SQL_V1"
outputFieldPath = "profileManifest.machineTransitionSql.sqlSha256"
outputRepresentation = "LOWERCASE_SHA256_HEX_64"
producerRef = "GEN-PVMC1-MACHINE-TRANSITION-SQL"
verifierRefs = [
  "CHECK-PVMC1-MACHINE-TRANSITION-SQL",
  "TS-PVMC1-MACHINE-TRANSITION-SQL",
  "DART-PVMC1-MACHINE-TRANSITION-SQL"
]
positiveVectorIds = ["V-PVMC1-MACHINE-TRANSITION-SQL-EXACT"]
negativeVectorIds = [
  "V-PVMC1-MACHINE-TRANSITION-SQL-BYTE-DRIFT",
  "V-PVMC1-MACHINE-TRANSITION-SQL-DIGEST-DRIFT"
]
```

The block above names the semantic contract fields. In the accepted B1 inventory
schema the same row is encoded without adding new row keys as:

```text
id = "DR-PVMC1-MACHINE-TRANSITION-SQL"
profileId = "pvmc1.phone-core.v1"
ownerRef = "owner.contract-authority"
derivationMode = "STANDARD_EXACT_BYTES"
ownedFieldPaths = ["MachineTransitionSqlV1.sqlSha256"]
byteSubjectRef = "PVMC1_MACHINE_TRANSITION_SQL_V1"
```

`MachineTransitionSqlV1` is an active B2 definition and the generated profile
manifest's `machineTransitionSql` value exact-equals that typed value. The
producer, verifier, and vector bindings are represented by the existing B1
owner/consumer/executable-test/hard-rule/vector inventories; they are not added as
unrecognized keys on `DigestContractV1`. This mapping preserves the accepted B1
row schema and still gives the SQL digest exactly one owning derivation.

The three ref arrays above use the accepted B1 ref types and JCS UTF-16 set order;
each named row/vector must exist exactly once in the active B2 Registry. No second
SQL-byte digest row, domain-separated wrapper, or digest of manifest-ID arrays is
active.

The complete governance row is inside `authority_json`; the duplicated coordinate
and `edge_id` columns exact-equal that JSON and are independently checked. For every
row, `machine_id` exact-equals the machine at `machine_ordinal`, and `from_state` and
`to_state` exact-equal the states at their respective ordinals in that machine's
accepted normative state list. An out-of-range ordinal or an ID/ordinal mismatch
rejects even if the three textual coordinates otherwise name an allowed edge. The
SQL relation has no forbidden-edge row and no wildcard state/edge syntax. Check
decodes manifest Base64, verifies byte shape and the registered exact-byte digest,
then compares the same bytes with the generated TS/Dart runtime constants and
reconstructs all 151 JSON rows for Registry exact-set equality. Bridge Store and
Mobile may later consume the generated relation; handwritten runtime copies are
forbidden.

## 4. Exhaustive negative and derived kill-point universe

Every one of the 872 forbidden same-machine ordered pairs has a stable independent
`ForbiddenEdgeMarkerIdV1` derived from `(machineId,from,to)`. Each mutation starts
from the same pristine accepted active model, adds exactly that one coordinate, and
must produce no accepted artifact/profile bytes. Cross-machine, unknown-state,
wrong-enum, missing-edge, duplicate-edge, and edge-ID mismatch mutations are
separate wrong-shape/set failures and do not replace the 872 complement.

Transaction manifests are required for every reachable case that spans two or more
physical writes, two or more durable SQL transactions, or any readback,
publication, or ACK visibility boundary. They are normalized one-way rows: a
manifest references coordinates/routes/guards/oracles, while an edge, route,
storage binding, oracle, or vector never references a manifest. Kill points and
reverse indices are derived and are not hand-authored Registry rows.

### 4.1 Closed transaction case and segment types

```text
ActiveMachineIdV1 = MachineEdgeCoordinateV1["machineId"]

TransactionManifestRefV1 = {
  refKind: "TRANSACTION_MANIFEST",
  registryId: Id
}

TransactionBindingKeyV1 =
  | {
      bindingKind: "AUTHORITATIVE_MACHINE",
      machineId: ActiveMachineIdV1
    }
  | {
      bindingKind: "MOBILE_REPLICA",
      machineId: ActiveMachineIdV1,
      replicaRole: "MOBILE_REBUILDABLE_REPLICA"
    }

CanonicalTransactionGuardRefSetV1 =
  array<GuardRefV1, minItems=1,
        maxItems=PVMC1_ACTIVE_GUARD_COUNT,
        uniqueBy=registryId>

TransactionRouteVariantV1 =
  "NONE" | "PUBLIC_CONNECTED" | "PUBLIC_DISCONNECTED" |
  "COALESCED" | "REJECTED" | "INTERNAL"

TransactionApplicabilityCaseV1 = {
  bindingKey: TransactionBindingKeyV1,
  coordinate: MachineEdgeCoordinateV1,
  routeRef: ProjectionRouteRefV1 | null,
  routeVariant: TransactionRouteVariantV1,
  guardRefs: CanonicalTransactionGuardRefSetV1
}

TransactionWriteRoleV1 =
  "OWNER_STATE" | "EVENT_FACT" | "OUTBOX_ENVELOPE" |
  "DURABLE_STAGING" | "DOMAIN_REPLICA" | "APPLY_STATE" |
  "CHECKPOINT" | "PROGRESS_METADATA" | "PUBLICATION_OUTBOX"

TransactionRowCardinalityV1 =
  | { cardinalityKind: "EXACT", rows: PositiveJsonSafeInteger }
  | {
      cardinalityKind: "CONTEXT_COUNT",
      countKind:
        "EVENT_FACT_COUNT" | "ELIGIBLE_ENVELOPE_COUNT" |
        "MATERIALIZATION_PAGE_COUNT" | "STAGED_ENVELOPE_COUNT" |
        "STAGED_TYPED_ROW_COUNT" | "APPLICABLE_DOMAIN_ROW_COUNT"
    }

TransactionPhysicalWriteV1 = {
  writeOrdinal: Ordinal0,
  writeId: Id,
  writeRole: TransactionWriteRoleV1,
  bindingKey: TransactionBindingKeyV1,
  physicalStorageCoordinateRef: PhysicalStorageCoordinateRefV1,
  rowCardinality: TransactionRowCardinalityV1
}

SqlTransactionRoleV1 =
  "AUTHORITATIVE_OWNER" | "MACHINE_ATOMIC" |
  "DURABLE_INBOX_STAGING" | "DURABLE_DOMAIN_STAGING" |
  "FINAL_REPLICA_APPLY" | "READBACK_STATE_CAS" |
  "PUBLICATION_STATE_CAS" | "ACK_STATE_CAS"

SqlTransactionSegmentV1 = {
  segmentOrdinal: Ordinal0,
  segmentId: Id,
  segmentKind: "SQL_TRANSACTION",
  transactionRole: SqlTransactionRoleV1,
  coordinatorBindingKey: TransactionBindingKeyV1,
  entryDurablePostStateProjectionRef: OracleProjectionRefV1,
  writes: array<TransactionPhysicalWriteV1, minItems=1,
                maxItems=PVMC1_ACTIVE_TRANSACTION_WRITE_COUNT>,
  commitPostStateProjectionRef: OracleProjectionRefV1
}

ExternalEffectSegmentV1 =
  | {
      segmentOrdinal: Ordinal0,
      segmentId: Id,
      segmentKind: "READBACK",
      durablePostStateProjectionRef: OracleProjectionRefV1,
      effectPostStateProjectionRef: OracleProjectionRefV1,
      replayRule: "READ_ONLY_REPEATABLE"
    }
  | {
      segmentOrdinal: Ordinal0,
      segmentId: Id,
      segmentKind: "PUBLICATION",
      durablePostStateProjectionRef: OracleProjectionRefV1,
      effectPostStateProjectionRef: OracleProjectionRefV1,
      replayRule: "IDEMPOTENT_BY_REPOSITORY_PUBLICATION_ID"
    }
  | {
      segmentOrdinal: Ordinal0,
      segmentId: Id,
      segmentKind: "ACK",
      durablePostStateProjectionRef: OracleProjectionRefV1,
      effectPostStateProjectionRef: OracleProjectionRefV1,
      replayRule: "IDEMPOTENT_BY_MESSAGE_KEY_AND_COMMITTED_CHECKPOINT"
    }

TransactionSegmentV1 =
  SqlTransactionSegmentV1 | ExternalEffectSegmentV1

TransactionManifestV1 = {
  manifestId: Id,
  initialDurablePostStateProjectionRef: OracleProjectionRefV1,
  applicabilityCases:
    array<TransactionApplicabilityCaseV1, minItems=1,
          maxItems=PVMC1_ACTIVE_TRANSACTION_CASE_COUNT>,
  segments:
    array<TransactionSegmentV1, minItems=1,
          maxItems=PVMC1_ACTIVE_TRANSACTION_SEGMENT_COUNT>
}
```

For a `NONE` case, `routeRef=null`; every other route variant requires a non-null
route ref. The case binding machine exact-equals `coordinate.machineId`; its
coordinate resolves one active edge and its route, when present, is an exact
reachable projection of that edge. A case never denotes a free Cartesian product.
Its guard set is the exact conjunction selecting one mutually exclusive guard
partition. `applicabilityCases` sort by binding-kind ordinal, machine ordinal,
from/to state ordinals, route-null before route-present, route normative ordinal,
route-variant ordinal, then the guard-ref sequence. Guard-ref sequences sort by
`registryId` under the JCS UTF-16 comparator. Duplicate or non-canonical input
rejects.

`segments[i].segmentOrdinal=i` and
`segments[i].segmentId=manifestId+":S"+CanonicalUnsignedDecimal(i)`. Segment arrays
are execution order, not lexical sets. Every SQL segment contains at least one
write and expands to the exact generated step sequence `TX_BEGIN`, `WRITE[0] ...
WRITE[n-1]`, `TX_COMMIT`; there are no optional hidden read/write/effect phases.
For its writes,
`writes[j].writeOrdinal=j` and
`writeId=segmentId+":W"+CanonicalUnsignedDecimal(j)`. Every write selects exactly
one physical coordinate, that coordinate belongs to its binding key, and its host
equals the transaction coordinator's host. A `CONTEXT_COUNT` must be positive in
its case; a zero-count branch uses a separate no-write applicability case and may
not fabricate a physical write.

Every external-effect segment is surrounded by SQL segments, has no physical
write, preserves the preceding durable post-state, and uses exactly the stated
idempotent replay rule. Two external-effect segments cannot be adjacent. The next
SQL segment's `entryDurablePostStateProjectionRef` exact-equals the preceding SQL
commit post-state; intervening effects do not silently change durable state.

### 4.2 Exact owner, writer, storage, and applicability cover

`AUTHORITATIVE_MACHINE` uniquely derives semantic owner, authoritative writer, and
authoritative storage from the exact machine edge rows; a manifest does not copy
those values. `MOBILE_REPLICA` uniquely resolves the machine's sole
`ReplicaWriterBindingV1`, whose writer is exactly `MOBILE/ReplicaApplyCoordinator`
and whose four authority flags are false. Each write coordinate must belong to a
storage binding reachable from that binding key. The sole cross-writer allowance
is `SyncProjectionDeliveryWriter` writing the delivery fact/envelope inside the
exact originating-owner transaction; it is not a second coordinator and cannot
write owner state.

The validator derives, rather than stores:

- each manifest's binding-key set as the unique union of all physical writes;
- each manifest's storage-binding/coordinate sets as the corresponding unions;
- the reverse index from every binding/coordinate to all consuming manifests.

For each manifest, all applicability cases must expand to byte-identical physical
steps, coordinator/writer resolution, row-cardinality expressions, external-effect
sequence, and state oracles. The normalized expected universe is:

```text
ExpectedTransactionCases =
  expandReachableTransactionCases(
    active machine coordinates,
    active durable route identities,
    active mutually-exclusive guard partitions,
    authoritative and replica bindings
  )
```

For B2 this expansion is closed, not heuristic. The authoritative side contains
the Cartesian product of every allowed edge of every machine whose
`authoritativeRouteRefs` contains the route with the five route variants
`PUBLIC_CONNECTED`, `PUBLIC_DISCONNECTED`, `COALESCED`, `REJECTED`, and
`INTERNAL`. The Mobile side contains one case per durable route, keyed by
`AUTHORITATIVE_MACHINE/SM-REPLICA-APPLY` at
`RECEIVED->STAGED`; its route-specific domain bindings are the exact set below:

| durable route | authoritative edge families | Mobile domain replica bindings |
|---|---|---|
| `sync.gap.v1` | every `SM-READ-ATTEMPT` edge | none |
| `materialization.begin.v1:TIMELINE` | every `SM-MATERIALIZATION` edge | `SM-MATERIALIZATION` |
| `materialization.page.v1:TIMELINE` | every `SM-MATERIALIZATION` edge | `SM-MATERIALIZATION` |
| `materialization.commit.v1:TIMELINE` | every `SM-TIMELINE-HEAD` edge | `SM-MATERIALIZATION`, `SM-TIMELINE-HEAD` |
| `operation.state.v1` | every edge of `SM-OPERATION`, `SM-DISPATCH-ATTEMPT`, `SM-EFFECT-OBSERVATION`, and `SM-RECONCILE` | the same four machine IDs |
| `queue.snapshot.v1` | every `SM-QUEUE-ENTRY` edge | `SM-QUEUE-ENTRY` |
| `interaction.snapshot.v1` | every `SM-INTERACTION` and `SM-CLAIM` edge | `SM-INTERACTION`, `SM-CLAIM` |

The durable `sync.gap.v1` publication therefore belongs to the persisted
`SM-READ-ATTEMPT` owner transaction. `SM-GAP-REPAIR` remains `MEMORY_ONLY` and
continues to own only the repair request/result workflow; it has no durable-route
ref and no invented SQL state. This disambiguates the amendment's “typed Gap or
failed attempt” rule without changing either state graph.

For one authoritative edge/route pair, `PUBLIC_CONNECTED` has owner-state,
event-fact, and eligible-envelope writes; `PUBLIC_DISCONNECTED` has owner-state
and event-fact writes; the other three variants share one owner-state-only
manifest and remain three disjoint applicability cases. The whole five-way guard
partition is included because it closes one route transaction family; the
zero-event branches may not be omitted merely because their selected physical
write count is one. This produces an exact, enumerable universe rather than an
implementation-selected subset.

It includes every and only reachable case meeting the manifest threshold in the
first paragraph of section 4. The disjoint union of all active
`manifest.applicabilityCases` must exact-equal `ExpectedTransactionCases`: each
expected case belongs to exactly one manifest and every unreachable case belongs
to zero. Guard partitions are mutually exclusive and collectively exhaustive and
have executable truth-table vectors. Missing, overlapping, or extra cases reject.

R77 cardinality is applied per case. Public connected is `event fact 1` plus the
context-derived eligible envelope count; public disconnected is `1/0`; coalesced,
rejected, and internal are `0/0`. A source-broadcast eligible envelope count may be
greater than one; only the originating receipt is `0..1`. A zero-event/outbox case
contains neither physical write.

### 4.3 Derived steps, kill points, and failure oracles

The generator flattens every segment into steps. SQL segments contribute
`TX_BEGIN`, each physical write, and `TX_COMMIT`; an external-effect segment
contributes one step of the same name. For the flattened array:

```text
steps[i].stepOrdinal = i
steps[i].stepId = manifestId + ":P" + CanonicalUnsignedDecimal(i)

killPoint(after=i).killPointId =
  manifestId + ":K" + CanonicalUnsignedDecimal(i)
```

Every adjacent pair `steps[i],steps[i+1]` produces exactly one
`TransactionKillPointV1`; no non-adjacent or literal extra marker is active:

```text
TransactionFailureOracleV1 =
  | {
      oracleKind: "ROLLBACK_OPEN_TRANSACTION",
      durablePostStateProjectionRef: OracleProjectionRefV1,
      resumeSegmentOrdinal: Ordinal0
    }
  | {
      oracleKind: "DURABLE_COMMIT_IDEMPOTENT_REPLAY",
      durablePostStateProjectionRef: OracleProjectionRefV1,
      resumeSegmentOrdinal: Ordinal0
    }
  | {
      oracleKind: "EXTERNAL_EFFECT_MAY_HAVE_OCCURRED",
      effectKind: "READBACK" | "PUBLICATION" | "ACK",
      replayRule:
        "READ_ONLY_REPEATABLE" |
        "IDEMPOTENT_BY_REPOSITORY_PUBLICATION_ID" |
        "IDEMPOTENT_BY_MESSAGE_KEY_AND_COMMITTED_CHECKPOINT",
      durablePostStateProjectionRef: OracleProjectionRefV1,
      resumeSegmentOrdinal: Ordinal0
    }

TransactionKillPointV1 = {
  killPointId: Id,
  manifestRef: TransactionManifestRefV1,
  afterStepOrdinal: Ordinal0,
  afterStepId: Id,
  beforeStepOrdinal: PositiveJsonSafeInteger,
  beforeStepId: Id,
  failureOracle: TransactionFailureOracleV1
}
```

`TX_BEGIN`/`WRITE` to the next step rolls back only the currently open SQL
transaction to that segment's entry durable post-state; it never erases staging
committed by an earlier segment. `TX_COMMIT` to the next step uses that segment's
commit post-state and resumes the next segment idempotently. After an external
effect, durable state remains the preceding commit state but the effect may have
occurred, so recovery uses only its fixed replay rule. An external effect has
before/after adjacent markers because it is neither first nor last. The exact
oracle refs and resume ordinal are derived from the segment sequence and reject a
literal override.

### 4.4 Exact 28-row Bridge mapping

For each of the seven durable routes, the canonical alias-bearing
`PUBLIC_CONNECTED` applicability case is the first reachable case ordered by
machine ordinal and then edge ordinal. It has a route-specific authoritative
manifest. Other eligible `PUBLIC_CONNECTED` cases remain in the complete manifest
inventory and have their own derived kill points, but do not create additional
Bridge alias rows.
Its `AUTHORITATIVE_OWNER` SQL segment contains, contiguously and in order, one or
more `OWNER_STATE` writes, one `EVENT_FACT` write, one or more
`OUTBOX_ENVELOPE` writes, then `TX_COMMIT`; `TX_BEGIN` immediately precedes the
first owner-state write. The four point kinds are:

```text
BridgeRoutePointKindV1 =
  "BEFORE_OWNER_STATE_WRITE" |
  "AFTER_OWNER_STATE_BEFORE_EVENT_FACT" |
  "AFTER_EVENT_FACT_BEFORE_OUTBOX" |
  "AFTER_OUTBOX_BEFORE_COMMIT"

BridgeRoutePointBindingV1 = {
  bridgeMarkerId: Id,
  routeRef: ProjectionRouteRefV1,
  pointKind: BridgeRoutePointKindV1,
  manifestRef: TransactionManifestRefV1,
  applicabilityCaseOrdinal: Ordinal0,
  transactionKillPointId: Id
}
```

The 28 rows sort by normative route ordinal and then the point-kind order above.
`bridgeMarkerId=routeRef.registryId+":"+pointKind`. The four rows for one route
resolve, respectively, the unique adjacent derived marker at:

1. `TX_BEGIN -> first OWNER_STATE`;
2. `last OWNER_STATE -> EVENT_FACT`;
3. `EVENT_FACT -> first OUTBOX_ENVELOPE`;
4. `last OUTBOX_ENVELOPE -> TX_COMMIT`.

All 28 `transactionKillPointId` values are distinct and belong to the referenced
manifest; a Bridge alias is not a second kill-point ID. Public-disconnected,
coalesced, rejected, and internal cases use separate exact-cover cases/manifests
with no outbox adjacency. Their negative vectors prove the eligible guard false and
the outbox point unreachable rather than simulating a write.

### 4.5 Mobile multi-transaction apply shape

Every applicable Mobile manifest uses this exact order, with
`DURABLE_DOMAIN_STAGING` present exactly once only when its applicability case has
typed domain rows and otherwise absent:

```text
DURABLE_INBOX_STAGING SQL commit
[DURABLE_DOMAIN_STAGING SQL commit]
FINAL_REPLICA_APPLY SQL commit
READBACK external effect
READBACK_STATE_CAS SQL commit
PUBLICATION external effect
PUBLICATION_STATE_CAS SQL commit
ACK external effect
ACK_STATE_CAS SQL commit
```

Inbox/apply-batch staging commits `STAGED` and may remain durable while last-good
and current visibility remain unchanged. Optional typed-domain staging is a second
durable, discardable segment. The final apply transaction atomically performs
old-current supersession, candidate-current promotion, domain apply, `APPLIED`, and
checkpoint advance. The next three state-CAS transactions uniquely persist
`READBACK_VERIFIED`, `PUBLISHED`, and `ACKED` after their preceding idempotent
effect. Only `SM-REPLICA-APPLY` may write `m_inbox_event.apply_state` in these
segments. A failure in any SQL segment rolls back only that segment; a crash after
one commit preserves that exact committed post-state and resumes the next segment.

### 4.6 Artifact, vector, and digest closure

Registry stores the closed manifest inventory but not derived steps, kill points,
reverse indices, or Bridge aliases. Schema emits the closed types. The profile
manifest fields `transactionManifestIds` and `transactionKillPointIds` are unique
arrays sorted ascending under the JCS UTF-16 comparator, accompanied by their
derived counts; generated TypeScript and Dart export the same arrays. Non-canonical
or duplicate arrays reject.

There is deliberately no separate digest over those arrays. The existing profile
digest covers them because `activeSource()` includes manifests, derived steps and
kill points, the 28 derived Bridge mappings, storage bindings, and the registered
SQL exact-byte digest contract. `sqlSha256` does not depend on the profile digest,
and the profile digest is never inserted into SQL authority rows. Registry, Schema,
profile manifest, TS, Dart, and vectors must exact-set equal; generated count bounds
replace guessed ceilings.

Kill-point/fault references may use only derived `TransactionKillPointV1` IDs. The
872 forbidden-edge vectors use only `ForbiddenEdgeMarkerIdV1`; they are not
transaction kill points. A manifest never references a vector, while a vector may
reference a deterministically derived kill-point ID. Applicability stores a typed
coordinate value rather than a full edge-authority row. These directions prevent
`edge -> vector -> kill point -> manifest -> edge` and digest dependency cycles.

Every allowed edge still requires a positive vector and non-empty edge-local
negative/fault references. Generic catch-all markers are forbidden.

## 5. Closed admission wire correlation

The existing outer wire tags are frozen as:

- client `operation_query` with fields
  `header: AuthenticatedClientHeaderV1` and `query: OperationQueryV1`;
- server `operation_snapshot` with field
  `result: OperationSnapshotResultV1`.

`ServerMessageV1.operation_snapshot` is required; an operation-state event or a
generic problem envelope cannot substitute for the read-only snapshot result.

Before Bridge reads an outcome or actor/fingerprint condition:

- `header.requestId == query.requestId`;
- the authenticated connection/source-epoch binding must resolve exactly the
  `query.sourcePartition`; raw `sourceEpoch` and `SourcePartitionV1` are not
  compared as interchangeable strings;
- result `requestId` exact-equals the one outstanding query's `requestId`;
- result `sourcePartition`, `operationId`, `fingerprintVersion`, and
  `operationFingerprint` each exact-equal both the corresponding outstanding
  query field and active `AdmissionLookupKeyV1` field.

Any outer/inner mismatch uses the unchanged `ADMISSION_UNKNOWN`, zero-effect path.
There is at most one in-flight query for one exact lookup key. The query contains no
actor field. Actor-origin equality remains before fingerprint comparison. No outer
header, server envelope, or problem branch may add submit, retry, dispatch, new ID,
Provider call, event fact, or outbox authority.

## 6. Gate and sequencing

Contract B1 must first freeze an immutable clean commit/tree and pass independent
`P0=0/P1=0`. B2 then starts from that exact commit, not from a dirty snapshot.

B2 acceptance requires at minimum:

- exact `17/123/151/64/872` derived counts and exactly seven routes;
- all concrete owner/writer/storage/replica/wire/unknown bindings above;
- 151 non-placeholder authority rows, the exhaustive forbidden complement, the
  required 28-marker Bridge subset, and the complete manifest-derived kill-point
  union including Mobile pre/post-commit oracles;
- closed admission inner/outer correlation and zero-effect oracle;
- Schema/manifest/TS/Dart/DDL exact-set and byte/digest equality;
- temporary-directory validate/generate/check and independent immutable
  `P0=0/P1=0` review.

Formal generation remains `FORBIDDEN / NOT_RUN` until both B1 and B2 satisfy their
independent gates. Runtime composition, Bridge/DB/ports, Mobile/simulator/candidate,
release, and device installation remain separate later gates.
