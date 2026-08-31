# Mobile ConversationRepository cloud review context

This document maps the repository-local code relationships needed to review
the Mobile conversation replica. It does not activate generated authority,
Bridge composition, product database migration, UI wiring, or runtime delivery.
The implementation must remain fail-closed until the formal generated Contract
mapper exists.

## Review identity

- Accepted base: `d1cb9b4aada56ce835ef78be72496c2e9fe3d255`
- Frozen code baseline: `33a28b98d1ff0949d96002572db5467d5f556f58`
- Frozen code tree: `3d6c57d0e8394a2f76145227d6bb1f6945242c78`
- Repository-local dependency class: `INDEPENDENT`
- Generated-authority integration class: `HARD_GATE`
- Focused frozen-baseline result: 77/77 tests pass

The commit that adds this document changes review metadata only. The code blobs
at the frozen code baseline remain the implementation review target. Any later
fixes must be additive commits after the context commit.

The current additive cloud-finding repair changes the physical replica contract
to V7. It leaves every V6/V5 file untouched, rejects explicitly supplied legacy
paths, and adds a compact permanent `projection_identity` row for each admitted
projection ID. Inbox/outbox/derived rows remain GC-eligible, while the identity
row permanently binds digest, connection/source/provider fences, runtime
generation, source revision, and pending/applied/stale disposition. Three exact
`ThreadKey + source_projection_id` indexes bound ACK-derived eligibility work.

## Library shape and ownership

`conversation_repository.dart` is the sole public lifecycle/write facade. The
following private `part` files compile into the same Dart library, allowing
internal cooperation without exposing a second writer/controller:

```text
conversation_repository.dart
  part -> conversation_repository_json.dart
  part -> conversation_repository_schema.dart
  part -> conversation_repository_validation.dart
  part -> conversation_repository_materialization.dart
  part -> conversation_repository_projection.dart
  part -> conversation_repository_readback.dart
```

Two separately imported/exported files define public inputs and the contract
seam:

- `conversation_repository_models.dart`
- `conversation_repository_contract.dart`

No Bridge service, Cubit, UI widget, generated Contract output, or product
database migration is part of this PR.

## End-to-end lifecycle

```text
ConversationRepository.open
  -> choose V7 path; reject known V6/V5/V4/legacy identities
  -> sqflite open with schema version 7
  -> _createSchema or _verifySchema
  -> _acquireWriterLease
  -> initialize data_version/usage attestation
  -> start independent lease heartbeat
  -> verify every pending identity has one exact pending inbox
  -> _recoverProjectionInbox
  -> _recoverPublicationOutboxRows
  -> expose the leased database and schedule publication drain
```

Open/recovery is one shared future. Public callers cannot observe a database
before schema attestation, writer ownership, inbox recovery, and publication
recovery have completed.

Normal construction installs `UnavailableConversationContract`. Product writes
and non-empty reads therefore fail with `contractUnavailable` until a formal
generated mapper is supplied. `ConversationRepository.forTesting` admits an
explicit fixture mapper only outside product/release mode; a mapper cannot
self-declare generated authority.

## Canonical materialization path

```text
beginMaterialization
  -> _validateBegin and generated/fixture preimage verification
  -> staged_materialization

stageMaterializationPage
  -> _validatePage and exact page-body preimage verification
  -> staged_materialization_page

commitMaterialization
  -> _validateCommit
  -> serialized writer-lease assertion
  -> _prepareCapacity
  -> one SQLite transaction
       -> read/validate begin and every durable page
       -> _sealMaterialization
       -> _validateEnvelope
       -> generated/fixture envelope and order-proof verification
       -> _applyEnvelope
            -> fence/epoch/monotonic checks
            -> canonical_item + typed_gap
            -> thread_state current/last-good
            -> immutable committed_envelope proof row
            -> publication_outbox(applied,pending)
       -> delete staging
       -> full capacity verification
  -> committed transaction
  -> _publishPublicationOutbox
  -> transactional readWindow
  -> CommitReceipt
```

No notification or ACK may make uncommitted data visible. A duplicate identity
is idempotent only when all bound fields/digests match; otherwise it is an
identity conflict. Weak/error materializations preserve last-good. Strong
complete snapshots may replace the active timeline only under the exact fence,
coverage, and monotonicity rules.

## Runtime projection path

```text
commitRuntimeProjections
  -> _validateRuntimeProjection
  -> contract preimage verification
  -> one admission transaction
       -> lookup permanent projection_identity by ThreadKey + projectionId
       -> reject any digest/fence/generation/revision rebinding
       -> exact terminal replay does not recreate inbox or publication
       -> new identity inserts identity(pending) + inbox(pending) atomically
  -> _applyProjectionInbox
       -> exact identity/inbox verification
       -> reject retired/stale epochs and non-monotonic heads
       -> apply operation/queue/interaction projections
       -> projection_head snapshot markers
       -> mark inbox + identity applied, or both stale, atomically
       -> publication_outbox(applied,pending)
       -> capacity verification
  -> publication + transactional readback
```

`_recoverProjectionInbox` first rejects pending identity/inbox incompleteness,
then replays pending rows in deterministic batches of 32. An old complete
projection must not delete a newer head. Projection-only thread state is
explicit and must not impersonate a verified canonical timeline.

## Publication and ACK path

`publication_outbox` is the durable handoff between a committed transaction and
the synchronous broadcast stream.

```text
applied/pending
  -> bounded claim
  -> read committed RepositoryWindow on the leased handle
  -> listener delivery with publicationEventId
  -> consumer acknowledgePublication(eventId)
  -> notification_state=notified with delivery claim fields cleared
  -> atomically mark the projection inbox and its derived rows GC-eligible
```

The phase and notification-state matrix, delivery token, event identity, and
claim freshness are jointly validated. No listener means the event stays
pending. Duplicate publishers share one event identity. ACK before actual
delivery returns false. Open recovery uses the already leased database even
before `_database` is published to ordinary callers.

## Readback path

`readWindow` uses a SQLite read transaction and first verifies that
`thread_state.current` and `thread_state.last_good` each resolve exactly one
immutable `committed_envelope` proof row with matching digest, fence,
generation, and revision.

It then reads:

- bounded `canonical_item` rows by timeline ordinal;
- active `typed_gap` rows;
- the exact `projection_head` snapshot markers;
- active operation, queue, and interaction rows carrying those markers.

A non-empty replica cannot be decoded without the generated Contract seam.
Readback re-verifies stored digests before returning public model objects.

## File responsibilities and relationships

| File | Primary responsibility | Direct relationships |
|---|---|---|
| `conversation_repository.dart` | Public facade, lifecycle, serialization tail, contract gate, open/close, heartbeat, publication drain/ACK | Calls every private part; owns the only database handle exposed to the library |
| `conversation_repository_contract.dart` | Contract mapper interface, generated-authority profile token, fixture-only token, unavailable fail-closed mapper | Every digest/preimage request passes through it; formal generated integration must implement this seam later |
| `conversation_repository_models.dart` | Public identity, fence, evidence, materialization, projection, window, receipt, error, and hook types | Constructors guard/freeze public JSON before repository storage paths consume it |
| `conversation_repository_json.dart` | Bounded storage encoding/decoding and stored Contract preimage verification | Used by materialization, projection, and readback; malformed stored JSON fails closed |
| `conversation_repository_validation.dart` | Source/thread/fence/evidence/page/commit/projection validation and exact bounds | Runs before staging or durable mutation; complements generated preimage verification |
| `conversation_repository_schema.dart` | V7 DDL, semantic schema attestation, triggers/indexes/FKs/checks, writer lease, key predicates | Called during open and before every serialized mutation through lease assertions |
| `conversation_repository_materialization.dart` | Begin/page staging, sealing, canonical commit, current/last-good, typed gaps/items, publication outbox | Uses validation, contract preimages, schema helpers, capacity checks, and readback |
| `conversation_repository_projection.dart` | Projection inbox/head, operation/queue/interaction projections, bounded GC, capacity and independent usage attestation | Uses publication outbox and thread-state fences; invalidates cached usage on external `data_version` changes |
| `conversation_repository_readback.dart` | Transactional window reads, proof-row binding, digest revalidation, projection snapshot selection | Returns the only public `RepositoryWindow` view |

## Durable table relationships

| Table group | Role and binding |
|---|---|
| `writer_lease` | One live owner for the canonical database path, bound by token, PID, boot identity, process-instance identity, and heartbeat |
| `staged_materialization`, `staged_materialization_page` | Incomplete begin/page set; never visible as canonical data |
| `committed_envelope` | Immutable proof row for each committed materialization identity |
| `thread_state` | Current and last-good pointers plus exact source/provider/generation/revision/coverage facts |
| `canonical_item`, `typed_gap` | Active timeline facts derived only from a validated envelope |
| `projection_identity` | Compact permanent per-ThreadKey projection-ID evidence; never deleted by ordinary GC and contains no payload JSON |
| `projection_inbox`, `projection_head` | Recoverable payload admission plus current monotonic/visibility head; terminal inbox rows remain GC-eligible and the head is not the historical identity ledger |
| `operation_projection`, `queue_entry_projection`, `interaction_projection` | Active rows selected only through exact projection-head snapshot markers; ACK-derived `gc_eligible` is part of bounded GC candidate indexes |
| `publication_outbox` | Durable at-least-once publication identity and ACK state after commit |
| `retired_epoch` | Bounded immutable anti-rollback evidence |
| `replica_usage`, `replica_usage_audit` | Trigger-maintained counters plus independent mirror/recomputation attestation |

All conversation content/state rows, excluding global schema and writer-lease
metadata, are source-scoped by the composite partition
`(bridgeIdentityId, bridgeInstanceId, codexSourceId)` and, where applicable,
`providerThreadId`. Endpoint or filename alone is never conversation identity.

## Schema, lease, capacity, and GC coupling

- V7 uses `conversation_replica_v7.db` and schema identity
  `ccpocket.conversation_replica_v7`. Existing V6/V5 files remain byte-for-byte
  untouched; explicitly supplied V6/V5/V4/legacy paths and schema upgrades are
  rejected without mutation.
- Schema attestation checks columns plus PK/UNIQUE/index order/collation,
  foreign-key grouping/deferred state, trigger SQL, CHECK expressions, defaults,
  and unexpected table options.
- Same-PID isolates have distinct process-instance tokens. A stale heartbeat is
  not enough to reclaim a same-PID owner; an explicit liveness proof is needed.
- `_serialize` reasserts the writer lease before every public mutation.
- Capacity includes canonical, staging, permanent projection identity,
  recoverable projection payload, outbox, state, gap, and retired-evidence
  rows, not just visible items. Exhausting the identity budget fails closed.
- Triggered counters, guard offsets, audit mirrors, `PRAGMA data_version`, and
  independent row recomputation must agree before mutation proceeds.
- GC runs in deterministic batches of 32 and must retain exact current,
  last-good, pending publication, provenance, active snapshot, and rollback
  evidence. Performance indexes are correctness-adjacent because unbounded GC
  can block the single writer.
- Projection ACK updates `gc_eligible` in the same writer transaction as the
  outbox state. The three derived-row updates use attested
  `ThreadKey + source_projection_id` indexes. Inbox and snapshot queries filter
  on eligibility before `LIMIT`, then recheck it in delete predicates; the
  permanent identity table is not an ordinary-GC target.

## Test-to-code map

The focused test file is
`apps/mobile/test/conversation_core/repository/conversation_repository_test.dart`.

| Test group | Primary code paths |
|---|---|
| `contract authority seam` | Normal/fixture construction, generated profile fencing, preimage recomputation, typed empty evidence |
| `materialization monotonicity` | Begin/page/commit, exact retry, current/last-good, epoch changes, publication recovery/claim/ACK matrix |
| `durable runtime projection` | Inbox admission/replay, monotonic projection head, complete snapshot deletion rules, operation/queue/interaction rows |
| `schema, lease, and guards` | V7/V6/V5 identity boundary, schema attestation, same-path/same-PID isolate lease, liveness, indexed ACK eligibility, GC/row-32/protected-prefix progress, JSON guards, usage tamper, capacity, readback proof rows |

The current additive repair has 95 combined repository/safety tests. A fix must
add an exact negative regression in the group owning the violated invariant,
then rerun both focused files plus affected analysis/format checks.

## Cross-file review triggers

- A model/JSON shape change requires rechecking public JSON guards, storage
  encode/decode, generated preimage verification, DDL byte accounting, and
  readback decoding.
- A fence/identity change requires rechecking staging keys, thread state,
  committed proof rows, projection heads, outbox IDs, retired epochs, and every
  composite index/FK.
- A schema/table/index change requires updating semantic attestation, usage
  triggers/audit/recomputation, GC queries, capacity accounting, and corruption
  tests.
- A publication change requires testing transaction commit ordering, open
  recovery, listener absence, concurrent claims, duplicate identity, immediate
  ACK, stale claims, and ACK idempotence.
- A GC change requires proving bounded query order and retention of current,
  last-good, pending outbox, staging, projection markers, and provenance rows.
- A contract-seam change must remain unavailable in product until formal
  generated B1+B2 outputs exist; fixture authority may never leak into normal
  construction.

## Out-of-scope seams and hard gates

- No formal generated Contract mapper exists in this branch.
- No Bridge or Provider adapter calls this repository in this PR.
- No UI/Cubit consumes `RepositoryWindow` in this PR.
- No product database migration, runtime activation, simulator/device test,
  deployment, OTA, or release is authorized.
- If a correct repair requires Contract B1/B2, formal Schema/digest changes, or
  generated TS/Dart integration, report `BLOCKED_HARD_GATE` rather than adding
  handwritten authority.

## Recommended review order

1. Review normal versus fixture Contract construction and public JSON guards.
2. Review the V7/V6/V5 identity boundary, semantic schema attestation, and writer lease.
3. Review begin/page/seal/commit and current/last-good monotonicity.
4. Review publication outbox recovery, claim, listener, and ACK races.
5. Review projection inbox/head and complete-snapshot deletion rules.
6. Review readback proof bindings and stored digest revalidation.
7. Review capacity/usage attestation and bounded GC retention/query plans.
8. Use the test-to-code map to add exact negative regressions for each repaired
   invariant, then rerun the focused repository and safety tests.
