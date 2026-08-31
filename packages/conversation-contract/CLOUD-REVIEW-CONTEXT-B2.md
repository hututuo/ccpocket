# Contract B2 cloud review context

This document maps the code relationships required for an independent cloud
review of Contract B2. It is review metadata, not a second authority source or
a formal generated artifact. The compact authority amendment, the B2
implementation ruling, and the validated Registry/Vectors remain authoritative.

## Review identity and stacked lineage

- Dependency class: `SOFT_STACKED`
- Base branch: `codex/review/contract-b1-20260831`
- Current base-branch tip: `1af1ed12216181de33ab1c3a81474e0089e28d5b`
- Exact B2 implementation parent: `a0c9f3785717af3ac03f3a8ae90080c11952ead4`
- Initial locally reviewed B2 HEAD: `beea9f0be053dbb03d284f7441ee5a9d9d89b4aa`
- Concentrated local-fix HEAD: `5c10fc601ae536879fba7715224fc78a1e3bcb72`
- Concentrated local-fix tree: `1d6ec81563b8defb9940f130a665aeacdac913b8`
- Local fix delta:
  `beea9f0be053dbb03d284f7441ee5a9d9d89b4aa..5c10fc601ae536879fba7715224fc78a1e3bcb72`

The base branch advanced from the implementation parent only by adding the B1
cloud-review map. It did not change any B1 implementation or authority blob.
The immutable B1 review map is available at:

https://github.com/hututuo/ccpocket/blob/1af1ed12216181de33ab1c3a81474e0089e28d5b/packages/conversation-contract/CLOUD-REVIEW-CONTEXT.md

The commit adding this B2 document changes review metadata only. The B2 code
review target remains the exact implementation chain rooted at `a0c9f378`.
Later cloud fixes must be additive commits and must not rewrite any published
SHA.

## Authority hierarchy

Read in this order:

1. `AGENTS.md`
2. `docs/design/codex-kernel-v4/PVMC-1-COMPACT-AUTHORITY-AMENDMENT-20260830.md`
   sections 5--7
3. `docs/design/codex-kernel-v4/PVMC-1-B2-IMPLEMENTATION-RULING-20260830.md`
4. This code map
5. The exact `a0c9f378..5c10fc60` implementation diff

Frozen authority identities:

- Compact amendment SHA-256:
  `317dfd46692e628c70a7a8a989debf9f8fd9384b19a257c7c2655bf7d4c7f6ab`
- B2 implementation ruling SHA-256:
  `9910bbe21a2cf71d41a3b92a84414d134455ac4877aeddba645bc324b77cb75a`
- Independent B2 definition oracle SHA-256:
  `dd710848f143b75cdbbe2d32a0c1345ea23c7f80a25d6371658c874302c23663`
- Independent B2 normative machine oracle SHA-256:
  `b8587be556ac6ff3335a81f3f18f52c93e2dfba26fc5ecf9c1b461974b59fca7`

B2 implements amendment sections 5--6. It must not change B1 sections 1--4,
run formal mapped generation, create a fifth target, or activate runtime/storage.

## End-to-end validation and generation flow

```text
contract-registry.json + phone-core-vectors.json
  -> cli.mjs / strict-json.mjs
  -> validate.mjs: validateInputs
       -> b2-definition-authority.mjs
            -> pvmc1-b2-definition-oracle.json
            -> amendment/ruling digest binding
       -> b1-digest-authority.mjs
       -> machine-semantics.mjs
            -> pvmc1-b2-normative-oracle.json
            -> 17 machine records / 151 edge rows / 872 forbidden markers
            -> generate-machine-ddl.mjs
       -> transaction-semantics.mjs
            -> production normalized manifests/steps/kill points/aliases
       -> transaction-oracle.mjs
            -> independent reconstruction and closure checks
       -> ordinary hard-rule semantic-oracle checks
       -> machine vector exact-subject checks
       -> transaction vector exact-subject checks
       -> admission-semantics.mjs exact vector set
  -> validated model
  -> generate.mjs: activeSource + profile digest + artifact metadata
       -> generate-schema.mjs
       -> generate-typescript.mjs
       -> generate-dart.mjs
       -> profile-manifest.json
```

No generator is allowed to build a different machine, transaction, route, or SQL
authority from raw Registry rows. Generation consumes only the model returned by
the complete validation chain.

## Exact closed counts

These values are derived, not configurable literals:

| Authority | Exact count |
|---|---:|
| Active machines | 17 |
| State occurrences | 123 |
| Allowed concrete directed edges | 151 |
| Terminal-state occurrences | 64 |
| Forbidden same-machine ordered pairs | 872 |
| Durable routes | 7 |
| Transaction manifests | 235 |
| Applicability cases | 387 |
| Transaction segments | 290 |
| Derived transaction steps | 1,181 |
| Derived adjacent kill points | 946 |
| Bridge route-point aliases | 28 |

Only `PRESENT->PRESENT` and `QUEUED->QUEUED` are allowed state self-loops.
Cross-machine pairs are wrong-coordinate failures and are not part of the 872
same-machine complement.

## File responsibilities and direct relationships

| File | Primary responsibility | Direct relationships |
|---|---|---|
| `PVMC-1-B2-IMPLEMENTATION-RULING-20260830.md` | Closes B2 storage, transaction, SQL, admission, and generation seams | Bound by digest into both independent oracle fixtures |
| `contracts/contract-registry.json` | Concrete B2 definitions, machine/storage/route/edge rows, transaction manifests, hard rules | Must exact-equal both independent oracles and every derived closure |
| `contracts/vectors/phone-core-vectors.json` | Machine, SQL, transaction, admission, forbidden-edge, and fault mutations | IDs must bind exact subject coordinates/sets, not just counts or case kinds |
| `test/fixtures/pvmc1-b2-definition-oracle.json` | Independent exact closure for every active B2-owned definition | Read only by `b2-definition-authority.mjs`; status explicitly forbids use as generation source |
| `test/fixtures/pvmc1-b2-normative-oracle.json` | Independent machine lists, states, edges, storage, routes, and counts | Read by `machine-semantics.mjs`; binds amendment and ruling digests |
| `src/b2-definition-authority.mjs` | Exact active-definition closure and exact B2 definition bytes | Runs before inventory/machine generation; rejects optional-field or empty-set weakening |
| `src/machine-semantics.mjs` | Builds expected normalized machine/storage/edge authority from the normative oracle and validates Registry/vectors | Calls SQL renderer; supplies machine authority to transaction validation and generators |
| `src/generate-machine-ddl.mjs` | One canonical 151-row SQL byte buffer and manifest | Consumes normalized machine/edge rows; Schema/manifest/TS/Dart reuse the same bytes |
| `src/transaction-semantics.mjs` | Production normalized transaction authority | Builds bridge/mobile manifests, steps, kill points, physical writes, and 28 aliases |
| `src/transaction-oracle.mjs` | Independent transaction reconstruction | Imports only canonical comparison helpers; independently checks writes, shapes, failure universe, aliases, coordinates, and vector subjects |
| `src/admission-semantics.mjs` | Read-only `ADMISSION_UNKNOWN` recovery oracle and exact vector inventory | Enforces correlation, persisted-row truth, actor-first fencing, fingerprint order, and zero effects |
| `src/validate.mjs` | Orchestrates the full closure in dependency order | B2 definitions -> digest -> machine -> transaction -> independent transaction oracle -> vectors |
| `src/generate.mjs` | Adds normalized machine/transaction authority to `activeSource`, profile digest, and manifest | Does not independently invent rows or SQL |
| `src/generate-schema.mjs` | Closed B2 definitions and `x-ccpocket-pvmc1-authority` metadata | Emits IDs and the exact SQL manifest from validated authority |
| `src/generate-typescript.mjs` | Typed immutable machine records/edge rows, route/transaction IDs, SQL bytes helper | Runtime edge predicate consumes only generated typed edge rows |
| `src/generate-dart.mjs` | Typed immutable Dart machine records/edge rows and identical IDs/SQL helper | Decodes fixed embedded JSON into closed generated types |

## Definition-authority closure

`validateB2DefinitionAuthority` compares:

- the complete active definition-ID closure;
- every B2-owned definition object;
- the current amendment digest;
- the current B2 ruling digest.

The oracle must reject, among other weakenings:

- an optional actor or origin view where the ruling requires a closed branch;
- empty `guardRefs`, vector sets, route sets, or applicability cases where the
  active type requires a non-empty set;
- missing failure or zero-effect oracle fields;
- open objects, missing `additionalProperties=false` behavior, wrong union
  discriminators, widened enums, or relaxed array ordering/uniqueness;
- an extra active B2 definition or a reachable definition absent from the
  independent closure.

The definition fixture is independent evidence, not the source consumed by the
generators.

## Machine and SQL flow

```text
pvmc1-b2-normative-oracle.json
  -> selector inventories
  -> authoritative and replica storage bindings
  -> 17 machine records
  -> 151 MachineEdgeAuthorityV1 rows
  -> 872 forbidden-edge markers
  -> renderMachineTransitionSql
       -> sort by machine/from/to ordinal
       -> RFC 8785 authority_json per row
       -> one fixed CREATE + one 151-tuple INSERT
       -> exact bytes/Base64/SHA-256 manifest
```

Frozen SQL facts:

- Row count: 151
- UTF-8 byte count: 220,569
- SHA-256:
  `4caa5d71547050f8f7fc32448b32cc088ed59f165ced3bdce776bf63817c237c`
- Template byte count: 657
- Template SHA-256:
  `2d84de976e3e27bb9cccc8978bac1a68e2f72cde702a5cc8b5bd43740cb7e744`
- UTF-8 without BOM, LF only, exactly one final LF

Set-valued route/storage/guard/vector arrays must already be in JCS UTF-16
order. The SQL renderer does not silently repair a non-canonical Registry row.
Schema, profile manifest, TypeScript, and Dart must all expose the same Base64
and digest, and reconstruct the same 151 typed authority rows.

## Transaction production builder versus independent oracle

`transaction-semantics.mjs` is the production authority builder. It derives:

- the five route variants for every reachable authoritative edge/route pair;
- one Mobile apply manifest per durable route;
- exact SQL/external-effect segments;
- physical writes and row cardinalities;
- flattened steps and all adjacent kill points;
- 28 Bridge route-point aliases.

`transaction-oracle.mjs` must remain independent. It does not import the
production transaction builder. It separately reconstructs and checks:

- connected, disconnected, quiet, rejected, coalesced, and internal writes;
- Mobile 8/9-segment route shapes;
- step adjacency and failure oracles;
- Bridge alias-to-kill-point resolution;
- physical coordinate consumption/closure;
- exact manifest, kill-point, alias, and Mobile subject-ID sets in vectors.

Changing both files to share one incorrect builder would destroy the independent
oracle property and is a P1/P0-level authority defect.

## Exact physical-write relationships

Owner-side exceptions must be edge-specific:

- `SM-READ-ATTEMPT VERIFYING->VERIFIED` writes
  `timeline_read_attempt.state`, then immutable `timeline_read_evidence`.
- `SM-RECONCILE ABSENT|STILL_UNKNOWN -> REQUESTED` writes immutable
  `reconcile_attempt`.
- `SM-RECONCILE REQUESTED -> terminal observation` writes immutable
  same-revision `reconcile_resolution`.

For every route case:

- `PUBLIC_CONNECTED`: exact owner coordinates, then
  `durable_delivery_head.state`, event fact, and eligible outbox envelope(s).
- `PUBLIC_DISCONNECTED`: exact owner coordinates, then event fact; no delivery
  head or outbox write.
- `COALESCED`, `REJECTED`, and `INTERNAL`: only exact owner coordinates.

`SyncProjectionDeliveryWriter` may perform the delivery-head/fact/envelope writes
inside the originating owner's transaction. It is not an alternate owner writer.
The R77 event/envelope cardinalities are connected `1/context-count`,
disconnected `1/0`, and quiet/rejected/internal `0/0`.

Mobile apply is a fixed sequence of durable SQL segments and external effects:

```text
DURABLE_INBOX_STAGING
[DURABLE_DOMAIN_STAGING]
FINAL_REPLICA_APPLY
READBACK
READBACK_STATE_CAS
PUBLICATION
PUBLICATION_STATE_CAS
ACK
ACK_STATE_CAS
```

Only `SM-REPLICA-APPLY` may write `m_inbox_event.apply_state`. Each external
effect is fenced by committed state and one fixed idempotent replay rule.

## Admission lookup ordering

The admission oracle requires this order:

1. outer request/schema/kind correlation;
2. authenticated source-partition equality;
3. result/query/lookup-key correlation;
4. one linearized persisted-row read;
5. origin/actor fencing;
6. fingerprint comparison;
7. exact persisted snapshot revision/state comparison;
8. local projection only, with zero Provider/durable side effects.

`NOT_FOUND` is accepted only when `persistedOperation == null`. A non-null row
cannot be ignored to obtain not-found. `MATCHED.snapshot` exact-equals the
persisted snapshot. Private auto-approval origin or actor mismatch wins before
fingerprint comparison. No branch authorizes submit, retry, dispatch, resend,
new operation ID, Provider call, event fact, or outbox row.

## Generated authority relationships

Generated TypeScript exports:

- 17 immutable `Pvmc1MachineRecord` values;
- 151 typed `MachineEdgeAuthorityV1` rows;
- seven durable route IDs;
- transaction manifest, kill-point, and Bridge alias ID arrays;
- SQL row count/digest/Base64 and a digest-verifying bytes helper;
- an allowed-edge helper derived only from the generated typed edge rows.

Generated Dart exposes the same authority as immutable typed values and the same
SQL bytes/digest. Schema metadata and profile manifest carry the same ID sets and
SQL manifest. Handwritten runtime edge sets or independently re-rendered SQL are
forbidden.

## Test-to-code map

| Test | Primary closure |
|---|---|
| `test/b2-definition-authority.test.mjs` | Complete active B2 definition closure and weakening mutations |
| `test/machine-contract.test.mjs` | 17/123/151/64/872 arithmetic, machine/storage/route/edge rows, UTF-16 ordering, self-loops, vectors, SQL bytes/digest |
| `test/transaction-contract.test.mjs` | 235 manifests, exact physical writes, independent oracle, Mobile shapes, 946 kill points, 28 aliases, vector subject IDs |
| `test/admission-lookup-contract.test.mjs` | Persisted-row truth, source/request/result correlation, actor-before-fingerprint, snapshot equality, timeout/auth and zero effects |
| `test/generated-b2-authority.test.mjs` | Schema/manifest/TS/Dart exact-set equality, typed machine/edge exports, and shared SQL bytes |
| `test/semantic-contract.test.mjs` | B2 hard-rule execution through the general semantic oracle |
| `test/b1-digest-authority.test.mjs` | The additive SQL exact-byte digest row does not weaken B1 ownership/dependency rules |

## Cross-file review triggers

- A B2 definition change requires updating the independent definition oracle,
  Registry closure, Schema, both generated languages, and weakening tests.
- A machine/state/edge change requires updating the normative oracle, all
  selectors/storage/routes/guards/oracles/vectors, SQL, transaction cases, and
  generated authority.
- A storage coordinate change requires rechecking production writes,
  independent coordinate closure, DDL rows, transaction oracles, and every
  applicability case.
- A route/order change requires rechecking JCS UTF-16 ordering, five variants,
  28 aliases, Mobile domains, transaction IDs, and generated ID arrays.
- A transaction segment/write change requires independently re-deriving steps,
  kill points, failure oracles, replay rules, and vector subject IDs.
- An admission change requires preserving correlation and actor/fingerprint
  ordering plus exact zero effects for every negative branch.
- A SQL change requires byte-for-byte Schema/manifest/TS/Dart equality and a new
  reviewed exact-byte digest; no formatter or platform normalization is allowed.

## Out-of-scope and hard gates

- Formal mapped generation/check remains `FORBIDDEN / NOT_RUN`.
- The four formal target files must not be created or updated in this review.
- Adapter/Store/Mobile generated integration remains blocked.
- Bridge/DB/runtime/ports, simulator, device, deployment, OTA, release, tag, and
  stable promotion are separate later gates.
- A cloud reviewer may append in-scope B2 fixes and focused tests to this Draft
  PR branch, but must not merge it or rewrite published commits.

## Recommended review order

1. Verify amendment/ruling/oracle digest identities.
2. Verify complete B2 definition closure and weakening resistance.
3. Verify machine/storage/route/edge exact-set authority and vector subjects.
4. Verify SQL canonical bytes and four-artifact equality.
5. Compare production transaction derivation with the independent oracle.
6. Audit connected/disconnected/quiet physical writes and Mobile segment shapes.
7. Audit admission ordering and persisted-row truth.
8. Audit generated typed authority and runtime helper provenance.
9. Use the test map to add an exact negative regression for every repaired P0/P1,
   then run the complete package suite and temporary standalone generation only.
