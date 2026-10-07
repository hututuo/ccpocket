# Codex Kernel v4 static validation specification

Status: `DESIGN_VALIDATION_CONTRACT / NO_RUNTIME / NO_PRODUCT_DATABASE_WRITE`

This directory contains a read-only validator for Python 3.11+ using only the
standard library (including `sqlite3`) for the Codex Kernel v4 design. A green
report means that the checked design artifacts
are structurally self-consistent. It does **not** mean that Provider, Bridge,
Mobile, SQLite runtime behavior, native code, UI, device delivery, deployment,
IPA, OTA, installation, or stable promotion has passed.

## 1. Invocation and exit status

`--root` is the repository root containing `docs/design/codex-kernel-v4`.

```bash
python3 docs/design/codex-kernel-v4/validation/validate_design.py \
  --mode preflight \
  --root /absolute/path/to/repository \
  --report /absolute/path/to/preflight-report.json

python3 docs/design/codex-kernel-v4/validation/validate_design.py \
  --mode final \
  --root /absolute/path/to/repository \
  --report /absolute/path/to/final-report.json

python3 docs/design/codex-kernel-v4/validation/validate_design.py --self-test
```

Exit status is `0` only when every applicable required check is `PASS`. `NOT_RUN` is
permitted for the optional Git identity check when the root is not a Git
checkout and for explicitly final-only checks during preflight, but it is never
used to hide a missing or malformed required design artifact. Any required
check that is `FAIL` returns `1`; CLI/configuration errors return `2`.
Final design-source validation reports `i01_generated_targets=NOT_RUN` with
readiness `DESIGN_SOURCE_READY` only when the manifest contains the exact pair
`implementationReady=false` and `generatedTargets=[]`. Both keys are mandatory;
the old missing-key shape fails. `implementationReady=true` makes every
generated-target check mandatory. A declaration and matching on-disk hashes alone are insufficient:
until I01 adds one reviewable deterministic generator interface that the
validator can replay into a temporary root, the gate fails as
`I01_GENERATED_NOT_REPRODUCED` rather than claiming `I01_GENERATED_READY`.

The validator never starts Bridge, App, Provider, or port `8765`; it never
opens a product database. DDL is loaded into a fresh SQLite `:memory:` database
for each positive and negative test. The only persistent write is the report
path explicitly supplied by the caller. That `.json` path must resolve outside
the audited repository, may not be a symlink, and is written by an atomic
same-directory replacement. Self-tests use a temporary directory.

## 2. Deterministic report

The UTF-8 JSON report is emitted with sorted keys, stable check order, stable
error order, two-space indentation, and no timestamp. It contains:

- validator/report format version and requested mode;
- normalized absolute root and design-root paths;
- Git `HEAD` and tree when Git is available;
- overall `PASS` or `FAIL`;
- every check with `PASS`, `FAIL`, or `NOT_RUN` and stable counters/details;
- typed errors (`FAIL_MISSING_ARTIFACT` for required missing inputs);
- SHA-256 and byte size for every regular design artifact and any declared
  generated target file;
- `validation_digest`, the SHA-256 of the canonical report object before that
  field is added.

The report is deterministic for the same root bytes, Git identity, mode, and
report path. It contains no process IDs, environment variables, credentials,
network data, or runtime observations.

## 3. Preflight gate

`preflight` is intentionally satisfiable by the current cumulative design. It
checks the inventory in `expected-inventory.json` and the following invariants.

### 3.1 CSV contracts

Every registered CSV must:

- parse with Python's strict CSV parser as UTF-8 (optional BOM accepted);
- have unique, nonblank header names;
- contain every required column; extra columns are allowed;
- meet the configured preflight minimum; final mode additionally applies any
  configured exact column count and final-only required columns;
- contain no blank cell in any declared or added column;
- contain the configured fixed row count;
- have a unique ID column in the exact configured order.

The fixed identities are: baseline 30; user decisions 9; Phase 1 identity 37;
identity/receive 37 with at least 22 columns in preflight and exactly 22 in
final; operations 38 (`OP-001..OP-039`, excluding reserved `OP-007`) with at least 24
columns in preflight and exactly 27 in final; K capabilities 26 with at least
19 columns in preflight and exactly 23 in final; Phase 2 capabilities 13 + 13; source reuse 52;
audit closure 112; and implementation/delivery gates 28.

Nine final-only CSV contracts are also registered. Semantic dictionary,
decision ledger, and authority/ownership use exact 26/13/14-column headers and
derive their current row inventory from strict unique successor/set rules, so a
later adjudicated append does not require a historical-count edit. The 18-column
superseded message view likewise keeps only a nonempty unique provenance set;
its historical row count is not authority. The remaining exact shapes are: risk 27x11, experiment 63x12,
evidence 29x12, implementation waves 19x17, and design closure 112x17. Preflight does
not require or adjudicate these final-only views. Final mode applies their exact
contracts. All old-message rows must be
`SUPERSEDED_NON_AUTHORITY`; blank legacy-only fields there and type-specific
owner-extension fields in the semantic dictionary are the only registered
blank exceptions. `DESIGN-CLOSURE.csv` retains
the original 112-ID sequence and may not leave a row's machine binding pending,
missing, or unresolved.

Additional CSVs introduced by later integration are discovered automatically.
They receive the same strict parse/header/width/no-blank checks, must contain at
least one data row, and use their first column as a unique ID. They do not gain
an invented fixed count or sequence until explicitly added to the inventory.

### 3.2 Source and Markdown references

Path tokens beginning with `packages/` or `apps/`, plus `decisions.md` and
`THIRD_PARTY_NOTICES.md`, are extracted only from the inventory-declared
current-source/current-test columns. Every extracted path must be a regular
file or directory inside the repository root. Descriptive symbol text after a
path is not treated as part of the path.

Ordinary local Markdown links in design Markdown must resolve without escaping
the repository root. URL, mail, and same-document fragment links are ignored.
Inline-code spans that explicitly start with `packages/`, `apps/`, or `docs/`
(plus the two root policy files) are also checked, with optional numeric line
suffixes removed. Other prose and historical external evidence locators are not
silently reinterpreted as Markdown links.

### 3.3 Semantic guards

- Every definition of `SourcePartition` must use the complete ordered tuple
  `(bridgeIdentityId, bridgeInstanceId, codexSourceId)`.
- Every definition of `OperationKey` must be
  `(SourcePartition, operationId)`.
- Canonical names must remain `ConversationCatalogWriter`,
  `CanonicalTimelineWriter`, `ReplicaApplyCoordinator`, `ThreadState`, and
  `RelationGraph`. Historical aliases such as `CanonicalProjectionWriter`,
  `ReplicaApplyWriter`, and `EphemeralChildRegistry` are allowed only on a line
  explicitly marked as evidence, deletion, rejection, or alias convergence.
- `deviceId`, `claimantId`, `source_device_id`, `faceIdPassed`, and
  `authenticated=true` cannot appear as an authoritative identity or writer
  field. Evidence and explicit rejection/deletion statements remain legal.
- `CANDIDATE_BINDING` is forbidden in Phase 2 artifacts.
- Reachable `V2`, `Mirror`, `legacy`, or `Claude` runtime markers are forbidden.
  Historical evidence, source paths, `DELETE`/`REPLACE`/`NO_IMPORT`, explicit
  unreachable/forbidden prose, and typed `NOT_IMPLEMENTED` seams are allowed.
- File-transfer protocol generations are written `FT/2` and `FT/3`; `FT2`,
  `FT-2`, `FT_2`, or “file transfer v2” are rejected.
- Operation lanes cannot be generic/global or keyed by path/route. The draft
  operation matrix is checked in preflight. Once the final registry exists,
  every operation must carry separate `queueLaneSelector` and
  `executionConflictSelectors` fields; neither selector may use those forbidden
  scopes. Replay policy may return a prior admission/CAS state, but the same ID
  may never mean resend/redispatch. The final machine registry may not
  register a legacy upload-mutation fallback.

The registry-dependent part of the last rule is reported `NOT_RUN` during
preflight because the machine registry is a final artifact. Its absence is not
reported as a preflight pass; final mode makes it mandatory.

### 3.4 Byte budgets

The authoritative UTF-8 budgets are fixed at:

| Surface | Bytes |
|---|---:|
| control envelope | 65,536 |
| general payload | 57,344 |
| interaction answer | 49,152 |

Both numeric bytes and equivalent `64 KiB`/`56 KiB`/`48 KiB` spelling are
accepted. A detected control/envelope declaration above 65,536 bytes fails.
Content-plane limits (MiB/GiB file sizes) are separate and do not enlarge the
control envelope.

## 4. Final gate

`final` runs the preflight contracts and additionally requires the complete
source-controlled design closure. A missing file or empty required glob emits
`FAIL_MISSING_ARTIFACT`; all checks that depend on that final inventory are
`NOT_RUN`, never vacuous `PASS`.

The exact required files include:

- `drafts/FULL-DESIGN-SYNTHESIS.md`;
- `evidence/I01-UPSTREAM-HOST-INTEGRATION-MAP.md`;
- `contracts/contract-registry.json` and `contracts/CONTRACT-MANIFEST.json`;
- sealed non-authority `contracts/README.md` and
  `contracts/tools/validate_contract.py`;
- `contracts/vectors/contract-vectors.json`;
- `contracts/sql/bridge-v1.sql` and `contracts/sql/mobile-v1.sql`;
- at least one `contracts/schema/*.schema.json`;
- `matrices/RISK-REGISTER.csv`, `EXPERIMENT-REGISTRY.csv`,
  `DECISION-LEDGER.csv`, `EVIDENCE-ADJUDICATION.csv`,
  `AUTHORITY-OWNERSHIP.csv`, `IMPLEMENTATION-WAVES.csv`, and
  `DESIGN-CLOSURE.csv`.

The synthesis must be at least 4 KiB, declare
`IMPLEMENTATION_READY / SOURCE_IMPLEMENTATION_AUTHORIZED / DELIVERY_NOT_AUTHORIZED`
in its leading status block (not merely mention it as a future state), and retain the
frozen identity, writer, uncertain-operation, and `FT/2`/`FT/3` terms.

No audit/review ZIP, tar, archive, delivery carrier, 512 MiB carrier limit, or
carrier checksum is generated or required. `CONTRACT-MANIFEST.json` is a
source-controlled contract file/digest manifest, not an archive manifest. Final
identity is the report's exact Git commit/tree, the verified contract digests,
artifact hashes, and `validation_digest`. Symlinks remain forbidden in the
design tree for source identity and path-safety reasons.
The full-design entry is not required to carry a ritual anti-archive sentence;
any positive audit-package completion requirement still fails validation.

Final mode requires the design and exact generated-target roots to be clean in
Git with no report exception. Every hashed artifact is compared to its blob at
the reported HEAD, the hashes are collected a second time, and HEAD/tree/status
are rechecked before the external report is written. Thus the reported
HEAD/tree identifies the bytes whose contract and validation digests were
checked.

### 4.1 Contract source and manifest

`contract-registry.json` is the semantic machine source. Its actual top-level
shape is validated (`contract`, owners, semantics, capabilities, 24 state
machines, `errorRegistry`, limits, messages, 69 operation slots, ports, content
responsibilities/lineages, FeatureContribution contract/bindings/modules, 12
lane families, storage artifacts, settings/durable-event contracts, executable
rules, and source refs). IDs use each collection's
real key (`id`, message `kind`, or error `code`), remain unique, and references
must close.

The registry must satisfy, among other invariants:

- OP-001..OP-039 plus PX-001..PX-030 exist exactly; OP-007 is the tombstone,
  OP-023 internal, and OP-037 disabled/unreachable. Registry names must match
  each operation schema's `operationKind` const, and none of those three slots
  may enter `PublicOperation`.
- the 24 IDs extracted from `06-STATE-MACHINES-AND-SEMANTIC-AXES.md` match the
  registry exactly. Every descriptor has owner, initial/terminal states,
  nonempty valid transitions, wire projection, storage, and a resolving vector.
  `SM-MATERIALIZATION` owns the seal-once receipt/graph lifecycle; `SM-EPHEMERAL-CHILD` is memory/local-runtime only and has neither durable SQL
  table nor durable message projection. Plan does not create another machine.
  `stateMachineEdgeVectors` repeats the exact ordered edge set and each
  deliberate negative is an in-vocabulary edge absent from that set. Every DDL
  binding names an existing table/state column/trigger, and the trigger's
  extracted `OLD`/`NEW` algebra equals the registry graph exactly; a
  revision-only trigger is not a state-transition guard. In addition,
  `stateMachineSqlVectors` contains, in registry/binding/state order, every
  candidate initial state plus every distinct state pair (and registered self
  edges) for every DDL binding. Each case executes against a fresh database;
  allowed cases must commit to exact postconditions, while forbidden cases
  must return the exact extended SQLite error and leave the entire database
  snapshot unchanged.
- the exact lane inventory is THREAD_PROVIDER, THREAD_STATE, INTERACTION,
  SOURCE_POLICY, BRIDGE_TRUST, RUNTIME_SESSION, CONTENT_OFFER, TRANSFER,
  FILE_ROOT, GALLERY, GIT_WORKSPACE, and CAPTURE_SCOPE. Generic/global/path/route
  lanes fail.
- support and availability are independent closed axes; owner, capability,
  state-machine, port, schema, and error references resolve. Receive/order has
  machine bindings for materialization, TurnSpine, coverage, Gap, order proof,
  last-good, CAS, and typed begin/page/commit messages.
- the semantic view retains exact evidence names `FeatureCapabilitySnapshot`,
  `CapabilitySupport`, `CapabilityAvailability`, and
  `CodexAdapterCertification`, plus privacy-safe `ActorProjection`.
  `CanonicalFingerprint` excludes actor,
  capability evidence, request/message/client IDs, deadline, trace, epoch, and
  ticket.
- `ErrorRegistryV1` has the exact 12 error classes and seven retry directives.
  Every canonical problem code maps one-to-one to one class, one default retry
  directive, and one closed bounded redacted detail schema. `ProblemV1` carries
  only the fixed safe fields and a sealed subject. Alias codes, class/directive
  mismatch, unknown directive/detail, raw credential/exception leakage, and an
  `OUTCOME_UNKNOWN` same-operation redispatch fail. `ProblemV1` is the exact
  ordered generated `oneOf` projection of the registry problem rows; it does
  not use a self-referential executable rule. The schema mismatch negative
  vector proves that a code/class pair cannot drift.
- Every semantic schema annotation is a registered `x-ruleIds` entry. The
  registry freezes handler, schema refs, and exact positive/negative vector IDs;
  the validator independently dispatches each handler. Prose `x-crossField`,
  an unknown `x-*` annotation/rule, a rule without handler or both outcomes, or
  a vector whose negative instance is already schema-invalid fails closed.
- Durable messages use one closed `EventKeyV1`/`MessageKeyV1` envelope, exact
  kind-to-payload and kind-to-(projection route, stream) mappings, and the three
  sealed route/audience pairs. Recipient provenance remains in the route,
  never payload. Payload and message preimages are closed and non-circular;
  frame bytes/digest are storage/transport metadata outside the protocol.
  Materialization begin/page/commit share frozen subject/receipt/manifest
  identity, and both receipt branches exactly equal their closed preimage plus
  `receiptDigest`.
- `FeatureContributionDescriptorV1` exists. The 52 product capability bindings
  cover K-001..K-026 and P-001..P-026 exactly, while any number of runtime
  contributions may collaborate. Each binding has one or more planned
  contribution records, and its required roles are covered at least once, not
  exactly once. Every descriptor instance has one `hostKind` from
  BRIDGE/MOBILE/NATIVE_IOS/NATIVE_ANDROID and one `executionOwnerRef`; role is
  one of AUTHORITY/ADAPTER/REPLICA/PRESENTATION/NATIVE_HOST. Owner, port,
  dependency, lifecycle, capability-state policy, and sole-writer references
  close, and authority owners agree with K/P and `AUTHORITY-OWNERSHIP.csv`.
- actual support/availability lives only in a revisioned, evidence-bound
  `FeatureCapabilitySnapshot`; the descriptor only declares the two resolvers,
  evidence kinds, fail-closed fallback, and snapshot publication port. A
  hard-coded `SUPPORTED/AVAILABLE` descriptor claim fails. Codex adapter
  certification, native-host snapshot, and negotiated feature snapshot retain
  distinct identities and evidence scope.
- `ThreadSettingsContractV1` has exactly eight observations. `model`,
  `approvalPolicy`, `approvalsReviewer`, `sandboxPolicy`, and
  `collaborationMode` are `UNKNOWN|VALUE`; `modelReasoningEffort`, `serviceTier`,
  and `activePermissionProfile` are `UNKNOWN|EXPLICIT_NULL|VALUE`.
  `activePermissionProfile.VALUE` retains closed `id+extendsProfileId?`
  structure. The snapshot has no `knownFields` mask, and its effective sandbox
  may coexist with an active profile: outbound permissions/sandbox XOR is an
  update-parameter rule, never a readback rule.
- OP-024 is the sole model/effort mutator and the sole consumer of
  `CodexSettingsCapabilitySnapshot`; it supports explicit effort or certified
  `PROVIDER_DEFAULT`. OP-025, OP-026, OP-027, and OP-028 bind exact
  `CodexAdapterCertification` ID/digest instead. OP-028 is
  `RESTART_WITH_EXECUTION_POLICY`: it can change approval/reviewer plus one
  execution-policy intent but must preserve model, effort, service tier, and
  collaboration. Collaboration is exactly lower-case `default|plan`; flat
  mappings, `on-failure`, pair collaboration, a second effort mutator, or
  model/list capability evidence reused for another setting all fail.
- `ContentRef` exists and both `ContentAccessTicket` and
  `ContentTicketIssueRequest` are closed, exclusive two-branch unions for
  `OFFER_TARGET` versus `REF_TARGET`; mixed offer/ref fields fail.

`CONTRACT-MANIFEST.json` uses the closed
`contractSet/algorithm/members/contractSetDigest/implementationReady/generatedTargets`
shape and enumerates every
normative regular file under `contracts/` except itself and the sealed
non-authority `contracts/README.md`, including the schema, SQL, vector, and
validator-tool sources. There may be no missing, extra, duplicate, escaping,
case-colliding, symlink, or self-reference entry. Every lowercase SHA-256 and byte size is checked
against disk. The registry member digest must equal `contract-registry.json`;
`contractSetDigest` is SHA-256 of canonical `{members:[...]}` and the manifest
does not include itself.

At design-source stage the exact lifecycle fields are
`implementationReady=false` and `generatedTargets=[]`; the separate I01 target
gate is explicitly `NOT_RUN`. At I01_GENERATED they become
`implementationReady=true` and exactly two nonempty entries, one each for
language `TYPESCRIPT` and `DART`, using the final Bridge and Mobile
`conversation-core/protocol/generated/` roots. Each binds the contract source
digest and a nonempty, sorted, closed file inventory of canonical repo-relative
path, positive byte size, and SHA-256. Declared files must exist, stay within
their disjoint root, carry the deterministic generated header, and have no
unlisted peer, symlink, collision, or dirty byte drift.
Those checks intentionally do not promote handwritten matching bytes. The
current design-source state uses `generatedTargets=[]` and leaves I01 `NOT_RUN`.
When `implementationReady=true` and the two inventories are nonempty, the
validator emits `FAIL_GENERATED_TARGET_REPRODUCTION` unless the uniquely
registered source generator is actually invoked into an isolated temporary
root and its closed inventory and bytes compare exactly. A generic callback that
can copy the final target roots is not an acceptable production generator
interface; its path, argv, source-input closure, and target-read prohibition
must land with I01.

### 4.2 JSON Schema structure

Every `*.schema.json` is parsed with duplicate-key rejection and must contain a
string `$schema`, string `$id`, and a root structural keyword (`type`, an
applicator, `$ref`, or `$defs`). The stdlib checker validates the types and
basic consistency of `properties`, `required`, `additionalProperties`, items,
definitions, enum/const, numeric/string/array bounds, applicators, and `$ref`.
Local fragments and relative schema-file references must resolve; network
references are never fetched. This deliberately does not claim to implement
the complete JSON Schema evaluation specification.
Every reachable object schema must nevertheless state
`additionalProperties:false` explicitly. The only exception is the named,
capacity-bounded `ExtensionsV1` scalar map; JSON Schema's implicit open-object
default is never accepted for a preimage, envelope, payload, or domain fact.

The vector source has the real machine shape:
`schemaVectors`, `fingerprintVectors`, `serializationVectors`,
`numericVectors`, `admissionVectors`, `stateMachineVectors`,
`stateMachineEdgeVectors`, `receiveVectors`, `wireFrameVectors`,
`stateMachineSqlVectors`, `hostResolutionVectors`,
actor/JCS/FeatureContribution vectors, `sqlVectors`,
`crossFieldVectors`, `durableEnvelopeVectors`, and
`injectedFailureInventory`. Vector IDs are globally unique where the vector
kind has IDs, schema refs resolve, and every public operation has positive and
closed-union negative vectors. The validator independently evaluates schema
instances, RFC8785-subdomain bytes/digests, ticket TTL/range algebra, forbidden
state edges, current-host resolution, malformed UTF-8, and duplicate JSON keys.

Capacity acceptance is exact UTF-8 bytes, not character count: envelope
65536/65537, payload 57344/57345, and interaction answer 49152/49153. Each
over-limit, malformed-UTF8, or duplicate-key case rejects in `PRE_DECODE` with
zero admission, inbox, staging, claim, lease, product, and Provider effects.
Raw vector count or a nonempty `proofKind` is never a coverage proof.

### 4.3 Fresh SQLite and executable negative vectors

Only `bridge-v1.sql` and `mobile-v1.sql` are accepted. Each installs
independently into a fresh `sqlite3.connect(":memory:")` database with foreign
keys enabled; `foreign_key_check` must be empty and `quick_check` exactly `ok`.
`ATTACH`, `DETACH`, `VACUUM INTO`, every contract-supplied `PRAGMA`,
extension/file helpers, and virtual tables are rejected before execution and
again by the SQLite authorizer. The loader itself sets only foreign keys and
in-memory temp storage before installing that authorizer. Validator-owned
`table_info`, `index_info`, `foreign_key_list`, `foreign_key_check`, and
`quick_check` use a single-call allowlist and immediately restore the
all-PRAGMA-denied authorizer; contract SQL never receives that allowance. No
product database is opened.

Each `sqlVectors` record selects `database: bridge|mobile`, a registered
`setupFixture`, either one `statement` or ordered `steps`, an
`expectedReason`, `expectedConstraint`, exact SQLite extended error name/message,
an unchanged-state mode, and executable postconditions. Optional parameters
support deterministic repeated UTF-8 strings; optional `expectRowCount` and
`expectSuccess` model CAS rejection and protected-state preservation. Each
vector gets its own fresh in-memory database. For unchanged-state vectors it
captures the declared queries at setup or immediately before the deliberate
final fault, then compares the actual post-state to both that baseline and the
registered expected value. A DDL text search, an arbitrary SQLite error, or a
postcondition checked only after the fact cannot pass.

The validator executes every registered vector and requires the named semantic
failure inventory (additional vectors are allowed), including duplicate
ACTIVE interaction claim, cross-source
and atomic conflict claims, stale queue CAS, double dispatch, post-CALL_STARTED
redispatch, ephemeral durability, protected draft cascade, AutoApproval-policy
skip/bad-first, checkpoint-before-readback, UInt64 overflow, and UTF-8 byte
overflow. It also requires last-good partial preservation, duplicate/missing
materialization page rejection, invalid order-proof rejection, stale-head CAS,
and atomic receive rollback. It also covers unique AutoApproval policy
exact-`+1`/first revision and unknown-policy rejection, Bridge/Mobile child
re-parent rejection, seal-output and Mobile inbox-body immutability,
ContentOffer terminal/ref gates, and the receive/materialization atomicity cases.
Raw vector count is report detail, never an invariant proof.

`stateMachineSqlVectors` uses the closed shape
`{id,stateMachine,database,table,stateColumn,phase,from,to,setupSteps,
targetMutation,rowKey,valid,postconditions}`. `phase` is `INITIAL` or
`TRANSITION`; after a committed fixture the validator itself turns the closed
`insertValues`/`setValues` mutation into exactly one parameterized target
`INSERT`/`UPDATE`. The validator derives validity from the 06/registry graph,
not from the vector's `valid` claim, and compares the vector inventory to the
full generated initial/state-pair closure before executing it.
Fixture steps are single-statement DML only: they cannot create, drop, or
replace tables, indexes, or triggers. `rowKey` must equal the table's real
primary key; the validator independently proves that exact row is absent/the
declared `from` state before the case and is the declared `to` state afterward.
Every DDL binding independently registers its initial/transition guard triggers,
the exact `mutationColumns` for each phase, and exact `allowedChangedTables`.
Mutation keys must equal the binding-owned column inventory; changed tables must
contain the target and only real one-hop FK neighbours. Positive cases compare
that binding-owned inventory to the exact whole-database delta. Negative cases must raise
`SQLITE_CONSTRAINT_TRIGGER` with a literal marker extracted from the registered
guard and leave a byte-for-byte unchanged whole-database snapshot. Registered
state guards may reference only the bound OLD/NEW state column, may not use a
subquery, must expose at least one parsed edge, and use globally unique literal
markers. Every candidate target in one binding/phase/from family shares the
same setup, row key, and non-state mutation values. If a positive transition
changes an allowed FK neighbour, a canonical full-table, primary-key-ordered
postcondition must prove that neighbour's exact rows. Thus a
vector cannot self-report its changed tables/error or use an unrelated fault,
DELETE-reinsert, a no-op update, or `SELECT 1` to impersonate a transition.

## 5. Built-in self-test

`--self-test` contains a clean CSV control plus isolated injected failures. It
proves rejection of an in-repository report path, duplicate/blank CSVs,
incomplete SourcePartition, oversize
control budget, missing final artifact, forbidden lane/same-ID redispatch/legacy
upload fallback, OP/PX ID-name drift, OP-007/023/037 in the public union,
missing one of 24 state machines/12 lanes/52 capability bindings, unresolved
error and owner alias, feature authority-owner mismatch, missing required
contribution role, static SUPPORTED/AVAILABLE, ephemeral durable table/message,
mixed OFFER/REF ticket, an attempted restoration of an audit/archive completion
gate, fingerprint excluded-field
drift, ErrorRegistry alias/class/directive/detail leakage, route free products,
cross-source projection, receipt self/arbitrary/stored-trust preimages, unknown
executable rules, R62 required-field nullability, profile+sandbox readback
coexistence, a second effort mutator, and manifest digest drift. Fresh SQLite self-tests also prove the registered
rejection pattern for UTF-8 byte overflow, policy revision skip, duplicate
ACTIVE interaction claim, checkpoint-before-readback, aggregate-head/event
half transaction, and `OUTCOME_UNKNOWN` redispatch.

The self-test passes only when the clean control stays clean, each malformed
fixture is rejected for its intended code, and each SQL negative is rejected by
SQLite as registered. It does not validate the repository and writes only its
temporary directory.
