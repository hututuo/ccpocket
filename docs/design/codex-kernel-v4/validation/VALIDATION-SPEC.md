# Codex Kernel v4 static validation specification

Status: `DESIGN_VALIDATION_CONTRACT / NO_RUNTIME / NO_PRODUCT_DATABASE_WRITE`

This directory contains a read-only, standard-library-only validator for the
Codex Kernel v4 design. A green report means that the checked design artifacts
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

Exit status is `0` only when every applicable check is `PASS`. `NOT_RUN` is
permitted for the optional Git identity check when the root is not a Git
checkout and for explicitly final-only checks during preflight, but it is never
used to hide a missing or malformed required design artifact. Any required
check that is `FAIL` returns `1`; CLI/configuration errors return `2`.

The validator never starts Bridge, App, Provider, or port `8765`; it never
opens a product database. DDL is loaded into a fresh SQLite `:memory:` database
for each positive and negative test. The only persistent write is the report
path explicitly supplied by the caller. Self-tests use a temporary directory.

## 2. Deterministic report

The UTF-8 JSON report is emitted with sorted keys, stable check order, stable
error order, two-space indentation, and no timestamp. It contains:

- validator/report format version and requested mode;
- normalized absolute root and design-root paths;
- Git `HEAD` and tree when Git is available;
- overall `PASS` or `FAIL`;
- every check with `PASS`, `FAIL`, or `NOT_RUN` and stable counters/details;
- typed errors (`FAIL_MISSING_ARTIFACT` for required missing inputs);
- SHA-256 and byte size for every regular design artifact, excluding the
  requested report and `validation/runs/`;
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
- meet the configured **minimum** column count (there is no maximum, so final
  integration may add explicit state-reference columns);
- contain no blank cell in any declared or added column;
- contain the configured fixed row count;
- have a unique ID column in the exact configured order.

The fixed identities are: baseline 30; user decisions 9; Phase 1 identity 37;
operations 38 (`OP-001..OP-039`, excluding reserved `OP-007`) with at least 24
columns; K capabilities 26; Phase 2 capabilities 13 + 13; source reuse 52;
audit closure 112; and implementation/delivery gates 28.

### 3.2 Source and Markdown references

Path tokens beginning with `packages/` or `apps/`, plus `decisions.md` and
`THIRD_PARTY_NOTICES.md`, are extracted only from the inventory-declared
current-source/current-test columns. Every extracted path must be a regular
file or directory inside the repository root. Descriptive symbol text after a
path is not treated as part of the path.

Ordinary local Markdown links in design Markdown must resolve without escaping
the repository root. URL, mail, and same-document fragment links are ignored.
Inline-code prose and historical external evidence locators are not silently
reinterpreted as Markdown links.

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
  `executionConflictSelector` fields; neither selector may use those forbidden
  scopes. A same-ID lookup/admission query may return prior state, but the same
  ID may never mean resend/redispatch. The final machine registry may not
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

`final` runs every preflight check and additionally requires all final package
artifacts. Missing files or empty required globs produce
`FAIL_MISSING_ARTIFACT`; dependent JSON/SQLite/manifest checks become
`NOT_RUN`, never `PASS`.

Required final artifacts are defined in `expected-inventory.json` and include:

- `FULL_DESIGN.md`;
- `contracts/contract-registry.json`;
- at least one `contracts/schema/*.schema.json`;
- at least two `contracts/sql/*.sql` DDL files;
- `contracts/sql/negative-vectors.json`;
- final risk, experiment/gate, and audit-closure matrices.

The final risk register must add evidence and rollback ownership to the original
risk/likelihood/impact/mitigation contract. For compatibility with the source
evidence, `id`/`risk_id`, `owner`/`owner_stage`, `evidence`/`evidence_gate`, and
`rollback`/`rollback_gate` are accepted column-name pairs; all rows still have
unique IDs and no blank cells.

No archive, ZIP/tar carrier, package manifest, or carrier checksum file is a
design-closure requirement. The deterministic report's artifact hashes and
`validation_digest` are the final validation digest. Final mode still rejects
symlinks in the worktree design tree because path identity and source-reference
safety are part of the design check, not an archive-packaging gate.

### 4.1 Registry and JSON Schema structural checks

The contract registry is a JSON object containing every configured top-level
key. Configured registry arrays contain objects with unique, nonblank `id`
values. `sourcePartition` must list exactly the canonical three fields, and
`budgets` must contain the three exact byte values above.

`schemas` and `databases` are nonempty ID arrays whose entries also contain a
`path` to an existing file below `contracts/schema/` or `contracts/sql/`.
Present `ownerId`, `schemaId`, `requestSchemaId`, `resultSchemaId`, `errorIds`,
`portId`, and `capabilityIds` references must resolve to the corresponding
registry array. `sqlNegativeVectors` must name exactly the IDs registered in
`contracts/sql/negative-vectors.json`.

Every `*.schema.json` must be a JSON object with a string `$schema`, string
`$id`, and at least one structural applicator (`type`, `oneOf`, `anyOf`, or
`allOf`). The stdlib checker validates the types and basic consistency of
`type`, `properties`, `required`, `additionalProperties`, `items`, `$defs`,
`enum`, `const`, numeric/string/array bounds, applicator arrays, and `$ref`.
Local fragments and relative schema-file references must resolve; network
references are not fetched. This is a deterministic structural check, not a
claim to implement the complete JSON Schema specification.

### 4.2 Fresh SQLite and pre-registered negative vectors

Each `contracts/sql/*.sql` file must install independently into a new
`sqlite3.connect(":memory:")` database with `PRAGMA foreign_keys=ON`.
`PRAGMA foreign_key_check` must return no row and `PRAGMA quick_check` must
return exactly `ok`. `ATTACH`, `DETACH`, `VACUUM INTO`, extension/file helper
calls, and virtual tables are rejected before execution so a design DDL cannot
escape the in-memory database.

`contracts/sql/negative-vectors.json` has this shape:

```json
{
  "formatVersion": 1,
  "vectors": [
    {
      "id": "cross_source_foreign_key",
      "ddl": ["bridge.sql"],
      "setupSql": "INSERT ...;",
      "statement": "INSERT ...;",
      "expectedErrorContains": "FOREIGN KEY constraint failed"
    }
  ]
}
```

`id`, nonempty `ddl`, `statement`, and `expectedErrorContains` are required;
`setupSql` is optional. DDL names are basenames under `contracts/sql/` and may
not escape that directory. Each vector receives its own fresh in-memory DB.
Setup must succeed, the tested statement must raise `sqlite3.Error`, and the
configured substring must occur in the error text. The five minimum vector IDs
are fixed in the inventory: cross-source FK, duplicate ACTIVE claim, duplicate
ACTIVE dispatch, `OUTCOME_UNKNOWN` replay, and draft cascade.

## 5. Built-in negative self-test

`--self-test` runs isolated intentional failures for, at minimum:

1. duplicate CSV ID;
2. blank CSV cell;
3. incomplete/two-component `SourcePartition`;
4. control budget above 65,536 bytes;
5. missing final artifact producing `FAIL_MISSING_ARTIFACT`.

The self-test passes only when each malformed fixture is rejected for the
intended reason. It does not validate the repository and does not write the
caller-supplied report.
