# Contract B1 cloud review context

This document maps the code relationships needed to review Contract B1 without
depending on local worktrees, historical agent transcripts, or unpublished
implementation ledgers. It is review context, not a second authority source.
When it conflicts with the frozen authority amendment or executable contract,
the authority amendment and validated Registry/Vectors win.

## Review identity

- Accepted base: `d1cb9b4aada56ce835ef78be72496c2e9fe3d255`
- Frozen code baseline: `a0c9f3785717af3ac03f3a8ae90080c11952ead4`
- Frozen code tree: `8ebbc1b4bc8280c5efacbae9c3f30b69fd1498f0`
- Authority amendment:
  `docs/design/codex-kernel-v4/PVMC-1-COMPACT-AUTHORITY-AMENDMENT-20260830.md`
- Authority amendment frozen-byte SHA-256:
  `317dfd46692e628c70a7a8a989debf9f8fd9384b19a257c7c2655bf7d4c7f6ab`
- B1 owns amendment sections 1--4. Sections 5--6 belong to B2.

The commit that adds this document changes review metadata only. The code and
authority blobs at the frozen code baseline remain the implementation review
target. Any later fixes must be additive commits after the context commit.

## End-to-end code path

```text
contract-registry.json + phone-core-vectors.json
  -> cli.mjs: readJson/loadModel/run
  -> strict-json.mjs: parseStrictJson
  -> validate.mjs: validateInputs
       -> names.mjs: validateGeneratedNames
       -> b1-digest-authority.mjs: validateDigestAuthority
       -> digest-preimages.mjs: discoverDigestPreimages
       -> semantic-oracle.mjs: evaluateSemanticRule
            -> semantic-primitives.mjs: closed fixture and digest builders
  -> generate.mjs: generateArtifacts
       -> generate-schema.mjs
       -> generate-typescript.mjs
       -> generate-dart.mjs
  -> cli.mjs: validate, generate, or check
       -> standalone writeArtifacts, or
       -> mapped writeArtifactTargets transaction
```

No generator path is allowed to bypass `validateInputs`. A type name, suffix,
fixture, or generator-local heuristic is not authority. Digest helper emission
must be derived from the validated Registry derivation rows.

## File responsibilities and relationships

| File | Primary responsibility | Direct review relationships |
|---|---|---|
| `docs/design/codex-kernel-v4/contracts/contract-registry.json` | Closed active profile, type graph, owners/consumers/tests, hard rules, digest ownership/equality/dependency/guard rows | Consumed by `validateInputs`; interpreted by `b1-digest-authority.mjs`; supplies generator model |
| `docs/design/codex-kernel-v4/contracts/vectors/phone-core-vectors.json` | Positive/negative semantic mutations and exact zero-effect expectations | Bound to active hard rules in `validateInputs`; executed through `semantic-oracle.mjs` |
| `src/cli.mjs` | Only command entry for `validate`, `generate`, and `check`; strict input loading; Dart 3.13 formatting; target-map dispatch | Calls `parseStrictJson`, `validateInputs`, `generateArtifacts`, and secure writers |
| `src/strict-json.mjs` | Duplicate-key, Unicode, numeric, depth/node, and strict JSON admission | Every Registry, vector, and target-map read passes through it |
| `src/validate.mjs` | Builds the only validated active model and closes the DSL/type/profile/rule/vector relations | Calls name, digest-authority, preimage-discovery, and semantic-oracle validators |
| `src/b1-digest-authority.mjs` | Exact owner/reference partition, four derivation modes, dependency DAG, predecessor template, and post-derivation guard | Registry rows enter here; normalized authority is later embedded by `generate.mjs` |
| `src/digest-preimages.mjs` | Discovers only validated reachable typed preimages and their authorized derivation modes | Used by TS/Dart generators and manifest construction; never grants authority by suffix alone |
| `src/canonical.mjs` | RFC 8785/I-JSON-safe canonical bytes, SHA-256 helpers, and deterministic JSON | Used by semantic validation, generated-runtime builders, manifests, and golden tests |
| `src/semantic-primitives.mjs` | Independently assembled closed B1 fixtures and exact boundary/digest constructors | Used by semantic oracle/tests; it is not a product runtime authority |
| `src/semantic-oracle.mjs` | Evaluates every active hard rule and the independent mutation axes | Called from `validateInputs`; must not accept a vector merely because a fixture helper produced it |
| `src/names.mjs` | Collision-free deterministic TS/Dart/generated member names | Validated before generation; shared by both language generators |
| `src/generate-schema.mjs` | Closed JSON Schema artifact | Receives only the validated model |
| `src/generate-typescript.mjs` | Closed TypeScript types, decoders, canonical-byte and digest helpers | Helper dispatch comes from validated digest derivations |
| `src/generate-dart.mjs` | Closed Dart types, decoders, canonical-byte and digest helpers | Must remain byte/digest-equal to generated TypeScript |
| `src/generate.mjs` | Artifact assembly, manifest binding, standalone output fencing, and atomic mapped multi-target transaction | Consumes normalized digest authority and all three generators; owns write/rollback evidence |
| `project-targets.json` | Exact four formal artifact destinations | Read only by `cli.mjs`; formal mapped generation is outside this PR |

## Authority data dependencies

The following relations must change together. A one-file fix is invalid when it
leaves its related authority stale.

1. A reachable `Sha256Hex64` field must appear exactly once as either an owning
   digest field or a `REFERENCE_EQUALITY` field.
2. Each owning digest row must have one supported derivation mode and an exact
   byte subject: domain-separated typed JCS, frozen RFC 8785 JCS, or exact raw
   bytes.
3. Every reference equality must target the unique owner for that field path.
4. The ordinary dependency graph must be the exact graph derivable from owning
   preimages and references. It must be acyclic except for explicitly
   stratified page/read-generation relations.
5. The predecessor relation is a separate cross-instance template with exact
   source/stable-scope equality, distinct materialization identity, and
   `currentHead = baseHead + 1`.
6. Current-manifest equality is a post-derivation validation guard and must not
   enter a proof preimage or digest dependency cycle.
7. Every active hard rule must bind an owner, consumer, executable test,
   semantic oracle, positive vector, negative vector, and exact zero-effect
   semantics.

## Generation and write boundaries

`cli.mjs#run` admits exactly one of standalone `--out` or mapped
`--target-map`. Both paths generate the same four artifact bytes.

`generate.mjs#generateArtifacts` binds:

- the validated active model;
- normalized digest authority;
- canonicalization profile and formatter identity;
- Schema, TypeScript, Dart, and profile manifest digests.

`writeArtifacts` is the standalone test/fixture path. `writeArtifactTargets` is
the formal mapped multi-target transaction. Its security and recovery behavior
is part of Contract B1 tooling correctness: project-root containment, bound
parent/stage identities, symlink rejection, serialized writers, full-set
rollback, and retained evidence on ambiguous cleanup.

Formal mapped generation is forbidden in this PR. These targets must remain
absent:

- `docs/design/codex-kernel-v4/contracts/generated/schema.json`
- `docs/design/codex-kernel-v4/contracts/generated/profile-manifest.json`
- `packages/bridge/src/conversation-core/protocol/generated/contract.ts`
- `apps/mobile/lib/conversation_core/protocol/generated/contract.dart`

## Test-to-code map

| Test | What it closes |
|---|---|
| `test/b1-digest-authority.test.mjs` | Owner/reference completeness, derivation modes, dependency edges, ordinary cycles, predecessor instances, and current-manifest post guard |
| `test/semantic-contract.test.mjs` | All active hard rules/vectors, read evidence, page chain, order/coverage, typed Gap/empty proof, predecessor, capacity boundaries, operations/interactions, and exact zero effects |
| `test/contract-tool.test.mjs` | Strict input, deterministic artifacts, namespace closure, helper authorization, standalone/mapped path security, transaction faults, rollback, and drift check |
| `test/generated-typescript-runtime.test.mjs` | Generated TS strict decoding, canonical bytes/digests, oneOf/nullable constraints, and node budget |
| `test/generated-dart-runtime-test.dart` | Generated Dart decoding and the same canonical-byte/digest goldens |
| `test/runtime-import-boundary.test.mjs` | Product runtime cannot import or call generic tooling-only digest primitives |
| `test/fixtures/jcs-goldens.json` | Cross-language fixed RFC 8785 bytes and SHA-256 values |

## Cross-file review triggers

- A Registry definition change requires rechecking reachability, names,
  owner/reference rows, dependency edges, vectors, Schema, both languages, and
  manifest bindings.
- A canonicalization change requires rerunning both language runtime goldens
  and malformed-input tests.
- A digest-mode change requires updating the authority inventory and proving
  that generated helper dispatch neither widens nor disappears.
- A semantic-oracle change requires proving independence from fixture builders
  and rerunning every active vector.
- A write-transaction change requires exact failure-point, symlink, external
  replacement, rollback, residue, and drift tests.
- A generated-name change affects both TS and Dart namespaces and all committed
  fixture artifacts.

## Out-of-scope seams

- Contract B2 state-machine/governance rows are not implemented here.
- Formal four-target generation is not authorized here.
- Adapter, Store, Mobile generated integration, Bridge composition, K04/K05,
  runtime activation, E2E, deployment, and release remain hard-gated.
- Test fixtures and `semantic-primitives.mjs` are evidence builders, never
  production authority.

## Recommended review order

1. Read the authority amendment sections 1--4.
2. Review Registry reachability and digest inventories.
3. Review vectors and semantic-oracle independence.
4. Review strict parsing and canonicalization.
5. Review generator helper authorization and TS/Dart parity.
6. Review mapped transaction fencing and recovery.
7. Use the test-to-code map to verify each repaired invariant has a negative
   regression, then run the complete package suite.
