import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {
  chmod,
  copyFile,
  lstat,
  mkdir,
  mkdtemp,
  readFile,
  readlink,
  readdir,
  realpath,
  rename,
  rm,
  symlink,
  unlink,
  writeFile,
} from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import { digestBytes, digestJson } from '../src/canonical.mjs';
import { run } from '../src/cli.mjs';
import { discoverDigestPreimages } from '../src/digest-preimages.mjs';
import {
  GENERATED_FILES,
  TRANSACTION_LOCK_NAME,
  TRANSACTION_STAGE_PREFIX,
  generateArtifacts,
  writeArtifactTargets,
  writeArtifacts,
} from '../src/generate.mjs';
import {
  captureGeneratorSourceFiles,
  createGeneratorSourceSnapshot,
  verifyGeneratorSourceFiles,
} from '../src/source-snapshot.mjs';
import { validateInputs, validateValue } from '../src/validate.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const fixtures = path.join(here, 'fixtures');

async function load(name) {
  return JSON.parse(await readFile(path.join(fixtures, name), 'utf8'));
}

async function model() {
  return validateInputs(await load('registry.json'), await load('vectors.json'));
}

function addActiveDefinition(registry, id, node) {
  registry.definitions.push({id, profiles: [registry.activeProfileId], node});
  registry.profiles
    .find((profile) => profile.id === registry.activeProfileId)
    .rootTypeRefs.push(id);
}

function fixtureArtifacts(label, size = 1) {
  return new Map(GENERATED_FILES.map((filename) => [
    filename,
    `${label}:${filename}:`.padEnd(size, label),
  ]));
}

test('validates the active profile and excludes planned inventory', async () => {
  const value = await model();
  assert.deepEqual([...value.activeDefinitionIds].sort(), [
    'CanonicalProfileProbePreimageV1',
    'FixtureAmbiguousOneOf',
    'FixtureCanonicalOrderSet',
    'FixtureConstrainedRecord',
    'FixtureConstraintItem',
    'FixtureEnvelope',
    'FixtureOneOf',
    'FixturePageBodyV1',
    'FixturePayload',
    'FixturePriority',
    'FixtureSourceRef',
    'FixtureUntaggedPreimageV1',
    'GapRepairIntentPreimageV1',
    'MaterializationBeginHeaderPreimageV1',
    'MaterializationCoveragePreimageV1',
    'MaterializationManifestPreimageV1',
    'MaterializationOrderPreimageV1',
    'MaterializationPagePreimageV1',
    'MaterializationReceiptPreimageV1',
    'OperationFingerprintPreimageV1',
    'ProviderReadEvidencePreimageV1',
    'Sha256Hex64',
  ]);
  assert.equal(value.activeVectors.length, 2);
  assert.equal(value.activeDefinitionIds.has('FutureOnly'), false);
  const errors = validateValue('FixtureEnvelope', value.activeVectors[0].value, value);
  assert.deepEqual(errors, []);
  assert.match(validateValue('FixtureEnvelope', value.activeVectors[1].value, value)[0], /safe integer/);

  const registry = await load('registry.json');
  registry.definitions.find((definition) => definition.id === 'FutureOnly').node = {
    kind: 'future-dsl-not-enabled',
  };
  const vectors = await load('vectors.json');
  assert.doesNotThrow(() => validateInputs(registry, vectors));
});

test('generation is byte deterministic and manifest digests bind artifacts', async () => {
  const value = await model();
  const digestPreimageTypeIds = discoverDigestPreimages(value).map(
    (preimage) => preimage.typeId,
  );
  const goldenTypeIds = (await load('jcs-goldens.json')).cases.map(
    (entry) => entry.typeId,
  );
  assert.deepEqual([...new Set(goldenTypeIds)].sort(), digestPreimageTypeIds.sort());
  const first = generateArtifacts(value);
  const second = generateArtifacts(value);
  assert.deepEqual([...first], [...second]);
  const manifest = JSON.parse(first.get('profile-manifest.json'));
  assert.equal(manifest.profileId, 'fixture.active');
  assert.equal(manifest.canonicalizationProfile, 'RFC8785-IJSON-SAFE-INTEGER-V1');
  assert.deepEqual(manifest.digestPreimageTypeIds, digestPreimageTypeIds);
  assert.equal(manifest.typeIds.includes('FutureOnly'), false);
  const schema = JSON.parse(first.get('schema.json'));
  assert.equal(
    schema.$defs.FixtureSourceRef.properties.sourceOrdinal.minimum,
    Number.MIN_SAFE_INTEGER,
  );
  assert.equal(
    schema.$defs.FixtureSourceRef.properties.sourceOrdinal.maximum,
    Number.MAX_SAFE_INTEGER,
  );
  assert.equal(schema.$defs.Sha256Hex64.pattern, '^[0-9a-f]{64}$');
  const constrained = schema.$defs.FixtureConstrainedRecord.properties;
  assert.deepEqual(constrained.nullableValue.anyOf[0], {type: 'null'});
  assert.equal(constrained.nullableValue.anyOf[1].pattern, '^value-[0-9]+$');
  assert.equal(constrained.fixed.const, 'FIXED');
  assert.equal(constrained.version.const, 1);
  assert.equal(constrained.bounded.minimum, 1);
  assert.equal(constrained.bounded.maximum, 3);
  assert.equal(constrained.disabled.const, false);
  assert.equal(constrained.items.minItems, 1);
  assert.equal(constrained.items.maxItems, 3);
  assert.deepEqual(constrained.items['x-ccpocket-uniqueBy'], ['identity.id']);
  assert.deepEqual(constrained.items['x-ccpocket-orderBy'], ['ordinal']);
  assert.equal(constrained.tags.uniqueItems, true);
  assert.equal(schema.$defs.FixtureOneOf.oneOf.length, 2);
  assert.deepEqual(schema.$defs.FixtureCanonicalOrderSet['x-ccpocket-orderBy'], ['$']);
  assert.equal(schema.$defs.FixtureUntaggedPreimageV1.oneOf.length, 2);
  const sha256Hex64 = new RegExp(schema.$defs.Sha256Hex64.pattern);
  assert.match('a'.repeat(64), sha256Hex64);
  assert.doesNotMatch('A'.repeat(64), sha256Hex64);
  assert.doesNotMatch('a'.repeat(63), sha256Hex64);
  assert.doesNotMatch('a'.repeat(65), sha256Hex64);
  for (const filename of ['schema.json', 'contract.ts', 'contract.dart']) {
    assert.equal(manifest.artifactDigests[filename], digestBytes(first.get(filename)));
    assert.doesNotMatch(first.get(filename), /FutureOnly/);
  }
  assert.deepEqual(
    manifest.artifactCatalog.map((entry) => entry.logicalName),
    GENERATED_FILES,
  );
  for (const filename of ['schema.json', 'contract.ts', 'contract.dart']) {
    const catalogEntry = manifest.artifactCatalog.find(
      (entry) => entry.logicalName === filename,
    );
    assert.deepEqual(catalogEntry, {
      logicalName: filename,
      path: filename,
      byteLength: Buffer.byteLength(first.get(filename), 'utf8'),
      sha256: digestBytes(first.get(filename)),
      integrityScope: 'SHA256',
    });
  }
  const manifestEntry = manifest.artifactCatalog.find(
    (entry) => entry.logicalName === 'profile-manifest.json',
  );
  assert.deepEqual(manifestEntry, {
    logicalName: 'profile-manifest.json',
    path: 'profile-manifest.json',
    byteLength: Buffer.byteLength(first.get('profile-manifest.json'), 'utf8'),
    integrityScope: 'SELF_PATH_AND_SIZE_ONLY',
  });
  assert.equal(
    manifest.generationProvenance.generatorSourceDigest,
    digestJson(manifest.generationProvenance.generatorSourceFiles),
  );
  assert.equal(
    manifest.generationProvenance.generatorExecutionBinding,
    'LIVE_FILESYSTEM_CATALOG_UNBOUND_V1',
  );
  assert.deepEqual(
    manifest.generationProvenance.generatorSourceFiles.map((entry) => entry.path),
    [...manifest.generationProvenance.generatorSourceFiles]
      .map((entry) => entry.path)
      .sort(),
  );
  assert.ok(
    manifest.generationProvenance.generatorSourceFiles.some(
      (entry) => entry.path.endsWith('/generate.mjs'),
    ),
  );
  assert.equal(
    manifest.generationProvenance.targetMapDigest,
    digestJson({
      formatVersion: 1,
      artifacts: Object.fromEntries(
        GENERATED_FILES.map((filename) => [filename, filename]),
      ),
    }),
  );
  assert.match(first.get('schema.json'), /draft\/2020-12/);
  assert.match(first.get('contract.ts'), /export function decodeFixtureEnvelope/);
  assert.match(first.get('contract.ts'), /readonly "nullableValue": string \| null/);
  assert.match(first.get('contract.ts'), /export type FixtureOneOf =/);
  assert.match(first.get('contract.ts'), /export function canonicalBytesOperationFingerprintPreimageV1/);
  assert.doesNotMatch(first.get('contract.ts'), /canonicalBytesFixtureEnvelope/);
  assert.match(first.get('contract.dart'), /sealed class FixturePayload/);
  assert.match(first.get('contract.dart'), /sealed class FixtureOneOf/);
  assert.match(first.get('contract.dart'), /final String\? nullableValue/);
  assert.match(first.get('contract.dart'), /cost\\\$x/);
  assert.match(first.get('contract.dart'), /String digestMaterializationReceiptPreimageV1/);

  const envelopeProperties = schema.$defs.FixtureEnvelope.properties;
  assert.equal(Object.hasOwn(envelopeProperties, '__proto__'), true);
  assert.deepEqual(envelopeProperties.__proto__, {type: 'string'});
  assert.equal(Object.hasOwn(Object.prototype, 'type'), false);
});

test('generator source snapshots reject symlinks and isolate later source changes', async () => {
  const directory = await mkdtemp(path.join(tmpdir(), 'ccpocket-source-input-'));
  const symlinkDirectory = await mkdtemp(path.join(tmpdir(), 'ccpocket-source-symlink-'));
  try {
    const first = path.join(directory, 'first.mjs');
    const second = path.join(directory, 'second.mjs');
    await writeFile(first, 'export const value = "first";\n');
    await writeFile(second, 'export const value = "second";\n');
    const snapshot = await createGeneratorSourceSnapshot(
      directory,
      'packages/conversation-contract/src',
    );
    try {
      const capturedFirst = await readFile(path.join(snapshot.directory, 'first.mjs'));
      await writeFile(first, 'export const value = "changed";\n');
      await unlink(second);
      await verifyGeneratorSourceFiles(
        snapshot.directory,
        'packages/conversation-contract/src',
        snapshot.catalog,
      );
      assert.deepEqual(
        await readFile(path.join(snapshot.directory, 'first.mjs')),
        capturedFirst,
      );
    } finally {
      await snapshot.dispose();
    }

    const victim = path.join(symlinkDirectory, 'victim.mjs');
    await writeFile(victim, 'export const value = "victim";\n');
    await copyFile(victim, path.join(symlinkDirectory, 'regular.mjs'));
    await symlink(victim, path.join(symlinkDirectory, 'linked.mjs'));
    await assert.rejects(
      captureGeneratorSourceFiles(
        symlinkDirectory,
        'packages/conversation-contract/src',
      ),
      /generator source must be a regular file/,
    );
  } finally {
    await rm(directory, {recursive: true, force: true});
    await rm(symlinkDirectory, {recursive: true, force: true});
  }
});

test('CLI generation executes from and attests one immutable source snapshot', async () => {
  const directory = await mkdtemp(path.join(tmpdir(), 'ccpocket-snapshot-cli-'));
  try {
    const result = spawnSync(
      process.execPath,
      [
        path.join(here, '../src/cli.mjs'),
        'generate',
        '--registry',
        path.join(fixtures, 'registry.json'),
        '--vectors',
        path.join(fixtures, 'vectors.json'),
        '--out',
        directory,
      ],
      {encoding: 'utf8'},
    );
    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
    assert.match(result.stdout, /generate: fixture\.active/);
    const manifest = JSON.parse(await readFile(
      path.join(directory, 'profile-manifest.json'),
      'utf8',
    ));
    assert.equal(
      manifest.generationProvenance.generatorExecutionBinding,
      'IMMUTABLE_SOURCE_SNAPSHOT_V1',
    );
    assert.ok(manifest.generationProvenance.generatorSourceFiles.some(
      (entry) => entry.path.endsWith('/source-snapshot.mjs'),
    ));
  } finally {
    await rm(directory, {recursive: true, force: true});
  }
});

test('CLI final source verification runs inside the artifact commit boundary', async () => {
  const directory = await mkdtemp(path.join(tmpdir(), 'ccpocket-snapshot-commit-'));
  const args = [
    'generate',
    '--registry', path.join(fixtures, 'registry.json'),
    '--vectors', path.join(fixtures, 'vectors.json'),
    '--out', directory,
  ];
  try {
    await run(args);
    const before = new Map();
    for (const filename of GENERATED_FILES) {
      before.set(filename, await readFile(path.join(directory, filename)));
    }
    let verified = false;
    await assert.rejects(
      run(args, {
        beforeArtifactCommit: async () => {
          verified = true;
          throw new Error('injected snapshot verification failure');
        },
      }),
      /injected snapshot verification failure/,
    );
    assert.equal(verified, true);
    for (const filename of GENERATED_FILES) {
      assert.deepEqual(
        await readFile(path.join(directory, filename)),
        before.get(filename),
      );
    }
  } finally {
    await rm(directory, {recursive: true, force: true});
  }
});

test('applies SHA-256 schema format only to the exact named scalar', async () => {
  const registry = await load('registry.json');
  const vectors = await load('vectors.json');
  registry.profiles.find((profile) => profile.id === registry.activeProfileId)
    .rootTypeRefs.push('Sha256Hex64Display');
  registry.definitions.push({
    id: 'Sha256Hex64Display',
    profiles: [registry.activeProfileId],
    node: {kind: 'string'},
  });
  const schema = JSON.parse(generateArtifacts(validateInputs(registry, vectors)).get('schema.json'));
  assert.deepEqual(schema.$defs.Sha256Hex64Display, {type: 'string'});
});

test('requires explicit closed digest derivations for generated helpers', async () => {
  const registry = await load('registry.json');
  const vectors = await load('vectors.json');

  const omitted = structuredClone(registry);
  omitted.digestDerivations = omitted.digestDerivations.filter(
    (row) => row.preimageTypeRef !== 'OperationFingerprintPreimageV1',
  );
  assert.doesNotMatch(
    generateArtifacts(validateInputs(omitted, vectors)).get('contract.ts'),
    /digestOperationFingerprintPreimageV1/,
  );

  const explicitFrozen = structuredClone(registry);
  explicitFrozen.definitions.push({
    id: 'FixtureFrozenReceiptV1',
    profiles: [explicitFrozen.activeProfileId],
    node: {
      kind: 'object',
      fields: [{name: 'receiptId', required: true, type: {kind: 'string'}}],
    },
  });
  explicitFrozen.profiles.find((profile) => profile.id === explicitFrozen.activeProfileId)
    .rootTypeRefs.push('FixtureFrozenReceiptV1');
  explicitFrozen.digestDerivations.push({
    id: 'FIXTURE-DR-Z-FROZEN-RECEIPT',
    profileId: explicitFrozen.activeProfileId,
    ownerRef: 'fixture.owner',
    derivationMode: 'FROZEN_RFC8785_JCS',
    ownedFieldPaths: [],
    preimageTypeRef: 'FixtureFrozenReceiptV1',
    formulaId: 'FIXTURE_FROZEN_RECEIPT_V1',
  });
  const explicitArtifacts = generateArtifacts(validateInputs(explicitFrozen, vectors));
  assert.match(explicitArtifacts.get('contract.ts'), /digestFixtureFrozenReceiptV1/);
  assert.match(explicitArtifacts.get('contract.dart'), /digestFixtureFrozenReceiptV1/);

  const missingDomain = structuredClone(registry);
  const missingDefinition = missingDomain.definitions.find(
    (definition) => definition.id === 'OperationFingerprintPreimageV1',
  );
  missingDefinition.node.fields = missingDefinition.node.fields.filter(
    (field) => field.name !== 'digestDomain',
  );
  assert.throws(
    () => generateArtifacts(validateInputs(missingDomain, vectors)),
    /must declare exactly one digestDomain field/,
  );

  const nonConstDomain = structuredClone(registry);
  const nonConstDefinition = nonConstDomain.definitions.find(
    (definition) => definition.id === 'OperationFingerprintPreimageV1',
  );
  nonConstDefinition.node.fields.find((field) => field.name === 'digestDomain').type = {
    kind: 'string',
  };
  assert.throws(
    () => generateArtifacts(validateInputs(nonConstDomain, vectors)),
    /digestDomain must be a string const or single-valued enum const/,
  );

  const openPreimage = structuredClone(registry);
  const openDefinition = openPreimage.definitions.find(
    (definition) => definition.id === 'OperationFingerprintPreimageV1',
  );
  openDefinition.node.fields.push({
    name: 'extensions',
    required: false,
    type: {kind: 'map', values: {kind: 'string'}},
  });
  assert.throws(
    () => generateArtifacts(validateInputs(openPreimage, vectors)),
    /reaches an open map/,
  );
});

test('rejects duplicate IDs, open refs, incomplete hard rules, and unsafe negatives', async () => {
  const registry = await load('registry.json');
  const vectors = await load('vectors.json');

  const duplicate = structuredClone(registry);
  duplicate.owners.push({id: 'FixtureEnvelope'});
  assert.throws(() => validateInputs(duplicate, vectors), /already used/);

  const openRef = structuredClone(registry);
  openRef.definitions[3].node.fields[1].type.target = 'MissingType';
  assert.throws(() => validateInputs(openRef, vectors), /unknown definition/);

  const incompleteRule = structuredClone(registry);
  delete incompleteRule.hardRules[0].consumerRef;
  assert.throws(() => validateInputs(incompleteRule, vectors), /consumerRef.*required field is missing/);

  const unsafe = structuredClone(vectors);
  delete unsafe.vectors[1].expectedZeroSideEffects;
  assert.throws(() => validateInputs(registry, unsafe), /negative vectors require zero-side-effect/);

  const noPositive = structuredClone(vectors);
  noPositive.vectors = noPositive.vectors.filter(
    (vector) => vector.id !== 'fixture.vector.valid-envelope',
  );
  assert.throws(
    () => validateInputs(registry, noPositive),
    /active hard rule fixture\.rule\.type-shape has no positive vector/,
  );
});

test('rejects active cycles and empty active authority sets before generation', async () => {
  const registry = await load('registry.json');
  const vectors = await load('vectors.json');

  const selfCycle = structuredClone(registry);
  selfCycle.definitions
    .find((definition) => definition.id === 'FixtureSourceRef')
    .node.fields[1].type = {kind: 'ref', target: 'FixtureSourceRef'};
  assert.throws(
    () => validateInputs(selfCycle, vectors),
    /active definition dependency cycle: FixtureSourceRef -> FixtureSourceRef/,
  );

  const multiCycle = structuredClone(registry);
  multiCycle.definitions
    .find((definition) => definition.id === 'FixtureSourceRef')
    .node.fields[1].type = {kind: 'ref', target: 'FixtureEnvelope'};
  assert.throws(
    () => validateInputs(multiCycle, vectors),
    /active definition dependency cycle: FixtureSourceRef -> FixtureEnvelope -> FixtureSourceRef/,
  );

  const unreachableCycle = structuredClone(registry);
  unreachableCycle.definitions.push({
    id: 'UnreachableCycle',
    profiles: [registry.activeProfileId],
    node: {kind: 'ref', target: 'UnreachableCycle'},
  });
  assert.throws(
    () => validateInputs(unreachableCycle, vectors),
    /active definition dependency cycle: UnreachableCycle -> UnreachableCycle/,
  );

  const noRoots = structuredClone(registry);
  noRoots.profiles.find((profile) => profile.status === 'active').rootTypeRefs = [];
  assert.throws(
    () => validateInputs(noRoots, vectors),
    /active profile must have at least one root type/,
  );

  const noDefinitions = structuredClone(registry);
  noDefinitions.definitions = noDefinitions.definitions.filter(
    (definition) => !definition.profiles.includes(registry.activeProfileId),
  );
  assert.throws(
    () => validateInputs(noDefinitions, vectors),
    /active profile must have at least one definition/,
  );

  const noRules = structuredClone(registry);
  noRules.hardRules = [];
  assert.throws(
    () => validateInputs(noRules, vectors),
    /active profile must have at least one hard rule/,
  );

  const noVectorSets = structuredClone(registry);
  noVectorSets.vectorSets = [];
  assert.throws(
    () => validateInputs(noVectorSets, vectors),
    /active profile must have at least one vector set/,
  );
});

test('preflights complete Dart and TypeScript generated namespaces', async () => {
  const registry = await load('registry.json');
  const vectors = await load('vectors.json');

  const publicCollision = structuredClone(registry);
  addActiveDefinition(publicCollision, 'Fixture-Envelope', {kind: 'string'});
  assert.throws(
    () => validateInputs(publicCollision, vectors),
    /generated public type name collision for FixtureEnvelope/,
  );

  const nestedCollision = structuredClone(registry);
  addActiveDefinition(nestedCollision, 'Nested', {
    kind: 'object',
    fields: [{name: 'child', required: true, type: {kind: 'object', fields: []}}],
  });
  addActiveDefinition(nestedCollision, 'NestedChild', {kind: 'string'});
  assert.throws(
    () => validateInputs(nestedCollision, vectors),
    /Dart top-level name collision for NestedChild/,
  );

  const unionVariantCollision = structuredClone(registry);
  addActiveDefinition(unionVariantCollision, 'VariantOwner', {
    kind: 'union',
    discriminator: 'kind',
    variants: [
      {tag: 'same_tag', fields: []},
      {tag: 'same-tag', fields: []},
    ],
  });
  assert.throws(
    () => validateInputs(unionVariantCollision, vectors),
    /Dart top-level name collision for VariantOwnerSameTag/,
  );

  const nullableNestedCollision = structuredClone(registry);
  addActiveDefinition(nullableNestedCollision, 'NullableOwner', {
    kind: 'object',
    fields: [{
      name: 'child',
      required: true,
      type: {kind: 'nullable', inner: {kind: 'object', fields: []}},
    }],
  });
  addActiveDefinition(nullableNestedCollision, 'NullableOwnerChildValue', {kind: 'string'});
  assert.throws(
    () => validateInputs(nullableNestedCollision, vectors),
    /Dart top-level name collision for NullableOwnerChildValue/,
  );

  const oneOfVariantCollision = structuredClone(registry);
  addActiveDefinition(oneOfVariantCollision, 'Choice', {
    kind: 'oneOf',
    variants: [{kind: 'string'}, {kind: 'integer'}],
  });
  addActiveDefinition(oneOfVariantCollision, 'ChoiceVariant1', {kind: 'string'});
  assert.throws(
    () => validateInputs(oneOfVariantCollision, vectors),
    /Dart top-level name collision for ChoiceVariant1/,
  );

  for (const id of ['String', 'ExpectString']) {
    const reserved = structuredClone(registry);
    addActiveDefinition(reserved, id, {kind: 'string'});
    assert.throws(
      () => validateInputs(reserved, vectors),
      /Dart (?:top-level|public) name collision/,
    );
  }

  for (const name of ['toJson', 'hash_code', 'runtime_type', 'no_such_method']) {
    const reservedMember = structuredClone(registry);
    reservedMember.definitions
      .find((definition) => definition.id === 'FixtureEnvelope')
      .node.fields.push({name, required: false, type: {kind: 'string'}});
    assert.throws(
      () => validateInputs(reservedMember, vectors),
      /Dart member in FixtureEnvelope name collision/,
    );
  }

  for (const enumValue of ['wire', 'from_wire', 'values']) {
    const reservedEnumMember = structuredClone(registry);
    reservedEnumMember.definitions
      .find((definition) => definition.id === 'FixturePriority')
      .node.values.push(enumValue);
    assert.throws(
      () => validateInputs(reservedEnumMember, vectors),
      /Dart enum member in FixturePriority name collision/,
    );
  }

  for (const id of [
    'ContractNode',
    'ContractField',
    'ContractVariant',
    'AssertContractType',
    'IsRecord',
    'ReadonlyArray',
    'Record',
  ]) {
    const reservedTsName = structuredClone(registry);
    addActiveDefinition(reservedTsName, id, {kind: 'string'});
    assert.throws(
      () => validateInputs(reservedTsName, vectors),
      /(?:Dart top-level|TypeScript public) name collision/,
    );
  }

  const codecCollision = structuredClone(registry);
  addActiveDefinition(codecCollision, 'DecodeFixtureEnvelope', {kind: 'string'});
  assert.throws(
    () => validateInputs(codecCollision, vectors),
    /(?:Dart|TypeScript) public name collision for DecodeFixtureEnvelope/,
  );
});

test('profile digest normalizes set-like profile arrays but preserves DSL order', async () => {
  const registry = await load('registry.json');
  const vectors = await load('vectors.json');
  const first = structuredClone(registry);
  first.profiles.find((profile) => profile.status === 'active').rootTypeRefs.push('FixturePriority');
  first.definitions
    .find((definition) => definition.id === 'FixturePriority')
    .profiles.push('fixture.future');
  const reorderedSets = structuredClone(first);
  reorderedSets.profiles.find((profile) => profile.status === 'active').rootTypeRefs.reverse();
  reorderedSets.definitions
    .find((definition) => definition.id === 'FixturePriority')
    .profiles.reverse();

  const digest = (input) => JSON.parse(
    generateArtifacts(validateInputs(input, vectors)).get('profile-manifest.json'),
  ).profileDigest;
  assert.equal(digest(first), digest(reorderedSets));

  const reorderedFields = structuredClone(first);
  reorderedFields.definitions
    .find((definition) => definition.id === 'FixtureSourceRef')
    .node.fields.reverse();
  assert.notEqual(digest(first), digest(reorderedFields));

  const reorderedVariants = structuredClone(first);
  reorderedVariants.definitions
    .find((definition) => definition.id === 'FixturePayload')
    .node.variants.reverse();
  assert.notEqual(digest(first), digest(reorderedVariants));
});

test('Dart emits valid constructors for empty objects and union variants', async () => {
  const registry = await load('registry.json');
  const vectors = await load('vectors.json');
  addActiveDefinition(registry, 'EmptyObject', {kind: 'object', fields: []});
  addActiveDefinition(registry, 'EmptyUnion', {
    kind: 'union',
    discriminator: 'kind',
    variants: [{tag: 'empty', fields: []}],
  });
  const dart = generateArtifacts(validateInputs(registry, vectors)).get('contract.dart');
  assert.match(dart, /const EmptyObject\(\);/);
  assert.match(dart, /return EmptyObject\(\);/);
  assert.match(dart, /const EmptyUnionEmpty\(\);/);
  assert.match(dart, /return EmptyUnionEmpty\(\);/);
  assert.doesNotMatch(dart, /const Empty(?:Object|UnionEmpty)\(\{\s*\}\);/);
});

test('validates nullable, scalar constraints, collection metadata, and exact oneOf branches', async () => {
  const value = await model();
  const valid = {
    nullableValue: null,
    fixed: 'FIXED',
    version: 1,
    bounded: 2,
    disabled: false,
    items: [
      {identity: {id: 'a'}, ordinal: 0, label: 'item-a'},
      {identity: {id: 'b'}, ordinal: 1, label: 'item-b'},
    ],
    tags: ['alpha', 'beta'],
  };
  assert.deepEqual(validateValue('FixtureConstrainedRecord', valid, value), []);
  assert.deepEqual(validateValue('FixtureConstrainedRecord', {...valid, nullableValue: 'value-9'}, value), []);
  assert.match(validateValue('FixtureConstrainedRecord', {...valid, fixed: 'wrong'}, value)[0], /must equal/);
  assert.match(validateValue('FixtureConstrainedRecord', {...valid, bounded: 4}, value)[0], /between 1 and 3/);
  assert.match(validateValue('FixtureConstrainedRecord', {...valid, items: []}, value)[0], /between 1 and 3 items/);
  assert.match(
    validateValue('FixtureConstrainedRecord', {
      ...valid,
      items: [valid.items[0], {...valid.items[1], identity: {id: 'a'}}],
    }, value)[0],
    /duplicates uniqueBy/,
  );
  assert.match(
    validateValue('FixtureConstrainedRecord', {...valid, items: [...valid.items].reverse()}, value)[0],
    /out of order/,
  );
  assert.match(validateValue('FixtureConstrainedRecord', {...valid, tags: ['alpha', 'alpha']}, value)[0], /duplicates/);
  assert.deepEqual(validateValue('FixtureOneOf', {left: 'ok'}, value), []);
  assert.match(validateValue('FixtureOneOf', {}, value)[0], /NO_ONE_OF_VARIANT/);
  assert.match(validateValue('FixtureAmbiguousOneOf', 'a', value)[0], /AMBIGUOUS_ONE_OF_VARIANT/);
  const canonicalOrder = [{left: 'a'}, {right: 1}];
  assert.deepEqual(validateValue('FixtureCanonicalOrderSet', canonicalOrder, value), []);
  assert.match(
    validateValue('FixtureCanonicalOrderSet', [...canonicalOrder].reverse(), value)[0],
    /out of order/,
  );
});

test('fails closed on malformed constraint and oneOf DSL metadata', async () => {
  const registry = await load('registry.json');
  const vectors = await load('vectors.json');
  const rejects = [
    [{kind: 'integer', minimum: 2, maximum: 1}, /minimum must not exceed maximum/],
    [{kind: 'string', pattern: '['}, /valid ECMAScript Unicode regular expression/],
    [{kind: 'array', items: {kind: 'string'}, minItems: -1}, /non-negative safe integer/],
    [{kind: 'array', items: {kind: 'string'}, uniqueBy: ['id']}, /selectors require object/],
    [{kind: 'array', items: {kind: 'string'}, orderBy: ['$']}, /\$ orderBy selector requires object/],
    [{kind: 'array', items: {kind: 'object', fields: []}, uniqueBy: ['$']}, /supported only by orderBy/],
    [{kind: 'oneOf', variants: [{kind: 'string'}]}, /at least two variants/],
    [{kind: 'string', minimum: 0}, /unknown field/],
  ];
  for (const [node, expected] of rejects) {
    const invalid = structuredClone(registry);
    addActiveDefinition(invalid, `Invalid${invalid.definitions.length}`, node);
    assert.throws(() => validateInputs(invalid, vectors), expected);
  }

  const optionalNullable = structuredClone(registry);
  addActiveDefinition(optionalNullable, 'OptionalNullable', {
    kind: 'object',
    fields: [{name: 'ambiguous', required: false, type: {kind: 'nullable', inner: {kind: 'string'}}}],
  });
  assert.throws(
    () => validateInputs(optionalNullable, vectors),
    /nullable fields must be required/,
  );
});

test('temporary generation and check preserve nullable, constraints, and oneOf artifacts', async () => {
  const directory = await mkdtemp(path.join(tmpdir(), 'ccpocket-contract-dsl-'));
  try {
    const args = [
      '--registry', path.join(fixtures, 'registry.json'),
      '--vectors', path.join(fixtures, 'vectors.json'),
      '--out', directory,
    ];
    await run(['generate', ...args]);
    await assert.doesNotReject(run(['check', ...args]));
    const schema = JSON.parse(await readFile(path.join(directory, 'schema.json'), 'utf8'));
    assert.equal(schema.$defs.FixtureConstrainedRecord.properties.items.minItems, 1);
    assert.equal(schema.$defs.FixtureUntaggedPreimageV1.oneOf.length, 2);
    assert.match(await readFile(path.join(directory, 'contract.ts'), 'utf8'), /NO_ONE_OF_VARIANT/);
    assert.match(await readFile(path.join(directory, 'contract.dart'), 'utf8'), /AMBIGUOUS_ONE_OF_VARIANT/);
  } finally {
    await rm(directory, {recursive: true, force: true});
  }
});

test('CLI rejects duplicate JSON object keys without echoing their values', async () => {
  const directory = await mkdtemp(path.join(tmpdir(), 'ccpocket-contract-json-'));
  try {
    const registryText = await readFile(path.join(fixtures, 'registry.json'), 'utf8');
    const vectorsText = await readFile(path.join(fixtures, 'vectors.json'), 'utf8');
    const registryFile = path.join(directory, 'registry.json');
    const vectorsFile = path.join(directory, 'vectors.json');
    await writeFile(vectorsFile, vectorsText, 'utf8');

    const escapedDuplicate = registryText.replace(
      '"formatVersion": 1,',
      '"formatVersion": 1, "\\u0066ormatVersion": 999,',
    );
    await writeFile(registryFile, escapedDuplicate, 'utf8');
    await assert.rejects(
      run(['validate', '--registry', registryFile, '--vectors', vectorsFile]),
      (error) => {
        assert.match(error.message, /duplicate object key/);
        assert.match(error.message, new RegExp(registryFile.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
        assert.match(error.message, / at \$/);
        assert.doesNotMatch(error.message, /999/);
        return true;
      },
    );

    const nestedDuplicate = registryText.replace(
      '"status": "active",',
      '"status": "active", "status": "SECRET_DUPLICATE_VALUE",',
    );
    await writeFile(registryFile, nestedDuplicate, 'utf8');
    await assert.rejects(
      run(['validate', '--registry', registryFile, '--vectors', vectorsFile]),
      (error) => {
        assert.match(error.message, /at \$\.profiles\[0\]/);
        assert.doesNotMatch(error.message, /SECRET_DUPLICATE_VALUE/);
        return true;
      },
    );

    await writeFile(registryFile, registryText, 'utf8');
    await assert.doesNotReject(
      run(['validate', '--registry', registryFile, '--vectors', vectorsFile]),
    );
  } finally {
    await rm(directory, {recursive: true, force: true});
  }
});

test('writeArtifacts rejects unsafe outputs, preserves symlink victims, and serializes writers', async () => {
  const directory = await mkdtemp(path.join(tmpdir(), 'ccpocket-contract-write-'));
  try {
    const realDirectory = path.join(directory, 'real');
    const linkedDirectory = path.join(directory, 'linked');
    const fileOutput = path.join(directory, 'file-output');
    await mkdir(realDirectory);
    await symlink(realDirectory, linkedDirectory);
    await writeFile(fileOutput, 'not a directory', 'utf8');
    await assert.rejects(
      writeArtifacts(linkedDirectory, fixtureArtifacts('linked')),
      /must not be a symbolic link/,
    );
    await assert.rejects(
      writeArtifacts(fileOutput, fixtureArtifacts('file')),
      /not a directory/,
    );

    const output = path.join(directory, 'output');
    await mkdir(output);
    const victim = path.join(directory, 'victim.txt');
    await writeFile(victim, 'victim remains unchanged', 'utf8');
    await symlink(victim, path.join(output, 'contract.ts'));
    await symlink(victim, path.join(output, 'schema.json.tmp'));
    await writeArtifacts(output, fixtureArtifacts('safe'));
    assert.equal(await readFile(victim, 'utf8'), 'victim remains unchanged');
    assert.equal((await lstat(path.join(output, 'contract.ts'))).isFile(), true);
    assert.equal((await lstat(path.join(output, 'schema.json.tmp'))).isSymbolicLink(), true);

    const concurrent = path.join(directory, 'concurrent');
    await mkdir(concurrent);
    const left = fixtureArtifacts('L', 2_000_000);
    const right = fixtureArtifacts('R', 2_000_000);
    const results = await Promise.allSettled([
      writeArtifacts(concurrent, left),
      writeArtifacts(concurrent, right),
    ]);
    assert.equal(results.filter((result) => result.status === 'fulfilled').length, 1);
    const rejected = results.find((result) => result.status === 'rejected');
    assert.match(rejected.reason.message, /(?:already locked|unfinished artifact transaction)/);
    const winner = results[0].status === 'fulfilled' ? left : right;
    for (const filename of GENERATED_FILES) {
      assert.equal(await readFile(path.join(concurrent, filename), 'utf8'), winner.get(filename));
    }
    assert.deepEqual(
      (await readdir(concurrent)).filter((name) => name.startsWith('.ccpocket-contract')),
      [],
    );
  } finally {
    await rm(directory, {recursive: true, force: true});
  }
});

test('standalone output rejects user symlink ancestors but accepts the macOS root alias', async () => {
  const directory = await mkdtemp(path.join(tmpdir(), 'ccpocket-contract-standalone-root-'));
  try {
    const lexicalRoot = path.join(directory, 'lexical');
    const outside = path.join(directory, 'outside');
    await mkdir(lexicalRoot);
    await mkdir(outside);
    await symlink(outside, path.join(lexicalRoot, 'nested-link'));
    await assert.rejects(
      writeArtifacts(
        path.join(lexicalRoot, 'nested-link/generated'),
        fixtureArtifacts('nested-link'),
      ),
      /must not be a symbolic link/,
    );
    await assert.rejects(readFile(path.join(outside, 'generated/schema.json')), /ENOENT/);

    if (process.platform === 'darwin' &&
        (await lstat('/var')).isSymbolicLink() &&
        await realpath('/var') === '/private/var') {
      const aliasRoot = await mkdtemp('/var/tmp/ccpocket-contract-system-alias-');
      try {
        const output = path.join(aliasRoot, 'generated');
        await writeArtifacts(output, fixtureArtifacts('system-alias'));
        assert.equal(
          await readFile(path.join(output, 'schema.json'), 'utf8'),
          fixtureArtifacts('system-alias').get('schema.json'),
        );
      } finally {
        await rm(aliasRoot, {recursive: true, force: true});
      }
    }
  } finally {
    await rm(directory, {recursive: true, force: true});
  }
});

test('target-map generation rejects a nested symlink escape below the real project root', async () => {
  const directory = await mkdtemp(path.join(tmpdir(), 'ccpocket-contract-escape-'));
  try {
    const project = path.join(directory, 'project');
    const outside = path.join(directory, 'outside');
    await mkdir(project);
    await mkdir(outside);
    await symlink(outside, path.join(project, 'bridge'));
    const registryFile = path.join(directory, 'registry.json');
    const vectorsFile = path.join(directory, 'vectors.json');
    const targetMapFile = path.join(directory, 'target-map.json');
    await writeFile(registryFile, await readFile(path.join(fixtures, 'registry.json'), 'utf8'));
    await writeFile(vectorsFile, await readFile(path.join(fixtures, 'vectors.json'), 'utf8'));
    await writeFile(targetMapFile, JSON.stringify({
      formatVersion: 1,
      projectRoot: 'project',
      artifacts: {
        'schema.json': 'docs/generated/schema.json',
        'profile-manifest.json': 'docs/generated/profile-manifest.json',
        'contract.ts': 'bridge/generated/contract.ts',
        'contract.dart': 'mobile/generated/contract.dart',
      },
    }), 'utf8');
    await assert.rejects(
      run([
        'generate',
        '--registry', registryFile,
        '--vectors', vectorsFile,
        '--target-map', targetMapFile,
      ]),
      /output path contains a symbolic link/,
    );
    await assert.rejects(
      readFile(path.join(outside, 'generated/contract.ts'), 'utf8'),
      /ENOENT/,
    );
  } finally {
    await rm(directory, {recursive: true, force: true});
  }
});

test('mapped target parent replacement is rejected before mutation', async () => {
  const directory = await mkdtemp(path.join(tmpdir(), 'ccpocket-contract-parent-swap-'));
  try {
    const project = path.join(directory, 'project');
    const outside = path.join(directory, 'outside');
    const targets = new Map([
      ['schema.json', path.join(project, 'docs/generated/schema.json')],
      ['profile-manifest.json', path.join(project, 'docs/generated/profile-manifest.json')],
      ['contract.ts', path.join(project, 'bridge/generated/contract.ts')],
      ['contract.dart', path.join(project, 'mobile/generated/contract.dart')],
    ]);
    const previous = fixtureArtifacts('parent-before');
    await mkdir(project);
    await mkdir(outside);
    await writeFile(path.join(outside, 'contract.ts'), 'outside victim', 'utf8');
    await writeArtifactTargets(targets, previous, {projectRoot: project});

    const contractParent = path.dirname(targets.get('contract.ts'));
    const heldParent = path.join(project, 'bridge/generated-held');
    let swapped = false;
    await assert.rejects(
      writeArtifactTargets(targets, fixtureArtifacts('parent-after'), {
        projectRoot: project,
        hooks: {
          async beforeMutation(details) {
            if (swapped ||
                details.operation !== 'backup-target' ||
                details.filename !== 'contract.ts') return;
            swapped = true;
            await rename(contractParent, heldParent);
            await symlink(outside, contractParent);
          },
        },
      }),
      /bound directory was externally replaced/,
    );
    assert.equal(await readFile(path.join(outside, 'contract.ts'), 'utf8'), 'outside victim');
    assert.equal(
      await readFile(path.join(heldParent, 'contract.ts'), 'utf8'),
      previous.get('contract.ts'),
    );
    assert.equal(await readFile(targets.get('schema.json'), 'utf8'), previous.get('schema.json'));
  } finally {
    await rm(directory, {recursive: true, force: true});
  }
});

test('mapped target parent replacement after mutation stops recovery with evidence', async () => {
  const directory = await mkdtemp(path.join(tmpdir(), 'ccpocket-contract-parent-post-swap-'));
  try {
    const project = path.join(directory, 'project');
    const outside = path.join(directory, 'outside');
    const targets = new Map([
      ['schema.json', path.join(project, 'docs/generated/schema.json')],
      ['profile-manifest.json', path.join(project, 'docs/generated/profile-manifest.json')],
      ['contract.ts', path.join(project, 'bridge/generated/contract.ts')],
      ['contract.dart', path.join(project, 'mobile/generated/contract.dart')],
    ]);
    const previous = fixtureArtifacts('post-parent-before');
    await mkdir(project);
    await mkdir(outside);
    await writeFile(path.join(outside, 'contract.ts'), 'outside victim', 'utf8');
    await writeArtifactTargets(targets, previous, {projectRoot: project});

    const contractParent = path.dirname(targets.get('contract.ts'));
    const heldParent = path.join(project, 'bridge/generated-held');
    let swapped = false;
    await assert.rejects(
      writeArtifactTargets(targets, fixtureArtifacts('post-parent-after'), {
        projectRoot: project,
        hooks: {
          async afterMutation(details) {
            if (swapped ||
                details.operation !== 'backup-target' ||
                details.filename !== 'contract.ts') return;
            swapped = true;
            await rename(contractParent, heldParent);
            await symlink(outside, contractParent);
          },
        },
      }),
      /automatic recovery stopped.*bound directory was externally replaced.*invalid backup/,
    );
    assert.equal(await readFile(path.join(outside, 'contract.ts'), 'utf8'), 'outside victim');
    assert.equal(await readFile(targets.get('schema.json'), 'utf8'), previous.get('schema.json'));
    const entries = await readdir(project);
    assert.equal(entries.includes(TRANSACTION_LOCK_NAME), true);
    const stage = entries.find((name) => name.startsWith(TRANSACTION_STAGE_PREFIX));
    assert.ok(stage);
    assert.equal(
      await readFile(path.join(project, stage, 'backup/contract.ts'), 'utf8'),
      previous.get('contract.ts'),
    );
  } finally {
    await rm(directory, {recursive: true, force: true});
  }
});

test('stage new and backup directory replacement is detected without touching victims', async (t) => {
  for (const stageChild of ['new', 'backup']) {
    await t.test(stageChild, async () => {
      const directory = await mkdtemp(
        path.join(tmpdir(), `ccpocket-contract-stage-${stageChild}-`),
      );
      try {
        const project = path.join(directory, 'project');
        const outside = path.join(directory, 'outside');
        const targets = new Map(GENERATED_FILES.map((filename) => [
          filename,
          path.join(project, filename),
        ]));
        await mkdir(project);
        await mkdir(outside);
        await writeFile(path.join(outside, 'victim.txt'), 'outside victim', 'utf8');
        if (stageChild === 'backup') {
          await writeArtifactTargets(targets, fixtureArtifacts('stage-before'), {
            projectRoot: project,
          });
        }

        let swapped = false;
        await assert.rejects(
          writeArtifactTargets(targets, fixtureArtifacts('stage-after'), {
            projectRoot: project,
            hooks: {
              async beforeMutation(details) {
                const shouldSwap = stageChild === 'new'
                  ? details.operation === 'write-staged-artifact' && details.filename === 'schema.json'
                  : details.operation === 'backup-target' && details.filename === 'schema.json';
                if (swapped || !shouldSwap) return;
                swapped = true;
                const child = stageChild === 'new'
                  ? details.newDirectory
                  : details.backupDirectory;
                await rename(child, `${child}-held`);
                await symlink(outside, child);
              },
            },
          }),
          /automatic recovery stopped.*bound directory was externally replaced/,
        );
        assert.equal(await readFile(path.join(outside, 'victim.txt'), 'utf8'), 'outside victim');
        for (const filename of GENERATED_FILES) {
          await assert.rejects(readFile(path.join(outside, filename), 'utf8'), /ENOENT/);
        }
        const entries = await readdir(project);
        assert.equal(entries.includes(TRANSACTION_LOCK_NAME), true);
        assert.equal(entries.some((name) => name.startsWith(TRANSACTION_STAGE_PREFIX)), true);
      } finally {
        await rm(directory, {recursive: true, force: true});
      }
    });
  }
});

test('stage child identity is bound to the directory created by the transaction', async (t) => {
  for (const stageChild of ['new', 'backup']) {
    await t.test(stageChild, async () => {
      const directory = await mkdtemp(
        path.join(tmpdir(), `ccpocket-contract-stage-created-${stageChild}-`),
      );
      try {
        const project = path.join(directory, 'project');
        const outside = path.join(directory, 'outside');
        const targets = new Map(GENERATED_FILES.map((filename) => [
          filename,
          path.join(project, filename),
        ]));
        await mkdir(project);
        await mkdir(outside);
        await writeFile(path.join(outside, 'victim.txt'), 'outside victim', 'utf8');

        let swapped = false;
        await assert.rejects(
          writeArtifactTargets(targets, fixtureArtifacts('created-stage-after'), {
            projectRoot: project,
            hooks: {
              async afterMutation(details) {
                const operation = stageChild === 'new'
                  ? 'create-stage-new-directory'
                  : 'create-stage-backup-directory';
                if (swapped || details.operation !== operation) return;
                swapped = true;
                const child = stageChild === 'new'
                  ? details.newDirectory
                  : details.backupDirectory;
                await rename(child, `${child}-held`);
                await symlink(outside, child);
              },
            },
          }),
          /automatic recovery stopped.*bound directory must not be a symbolic link/,
        );
        assert.equal(await readFile(path.join(outside, 'victim.txt'), 'utf8'), 'outside victim');
        for (const filename of GENERATED_FILES) {
          await assert.rejects(readFile(path.join(outside, filename), 'utf8'), /ENOENT/);
        }
        const entries = await readdir(project);
        assert.equal(entries.includes(TRANSACTION_LOCK_NAME), true);
        assert.equal(entries.some((name) => name.startsWith(TRANSACTION_STAGE_PREFIX)), true);
      } finally {
        await rm(directory, {recursive: true, force: true});
      }
    });
  }
});

test('mapped project targets generate and check one exact artifact set', async () => {
  const directory = await mkdtemp(path.join(tmpdir(), 'ccpocket-contract-map-'));
  try {
    const registryFile = path.join(directory, 'registry.json');
    const vectorsFile = path.join(directory, 'vectors.json');
    const targetMapFile = path.join(directory, 'target-map.json');
    await writeFile(registryFile, await readFile(path.join(fixtures, 'registry.json'), 'utf8'));
    await writeFile(vectorsFile, await readFile(path.join(fixtures, 'vectors.json'), 'utf8'));
    await writeFile(targetMapFile, JSON.stringify({
      formatVersion: 1,
      projectRoot: '.',
      artifacts: {
        'schema.json': 'docs/generated/schema.json',
        'profile-manifest.json': 'docs/generated/profile-manifest.json',
        'contract.ts': 'bridge/generated/contract.ts',
        'contract.dart': 'mobile/generated/contract.dart',
      },
    }), 'utf8');
    const args = [
      '--registry', registryFile,
      '--vectors', vectorsFile,
      '--target-map', targetMapFile,
    ];
    await run(['generate', ...args]);
    await assert.doesNotReject(run(['check', ...args]));
    for (const filename of GENERATED_FILES) {
      const generated = filename === 'schema.json' || filename === 'profile-manifest.json'
        ? path.join(directory, 'docs/generated', filename)
        : filename === 'contract.ts'
          ? path.join(directory, 'bridge/generated', filename)
          : path.join(directory, 'mobile/generated', filename);
      assert.equal((await lstat(generated)).isFile(), true);
    }

    const mappedManifestSource = await readFile(
      path.join(directory, 'docs/generated/profile-manifest.json'),
      'utf8',
    );
    const mappedManifest = JSON.parse(mappedManifestSource);
    assert.deepEqual(
      Object.fromEntries(
        mappedManifest.artifactCatalog.map((entry) => [entry.logicalName, entry.path]),
      ),
      {
        'schema.json': 'docs/generated/schema.json',
        'profile-manifest.json': 'docs/generated/profile-manifest.json',
        'contract.ts': 'bridge/generated/contract.ts',
        'contract.dart': 'mobile/generated/contract.dart',
      },
    );
    assert.equal(
      mappedManifest.artifactCatalog.find(
        (entry) => entry.logicalName === 'profile-manifest.json',
      ).byteLength,
      Buffer.byteLength(mappedManifestSource, 'utf8'),
    );
    assert.equal(
      mappedManifest.generationProvenance.targetMapDigest,
      digestJson({
        formatVersion: 1,
        artifacts: {
          'schema.json': 'docs/generated/schema.json',
          'profile-manifest.json': 'docs/generated/profile-manifest.json',
          'contract.ts': 'bridge/generated/contract.ts',
          'contract.dart': 'mobile/generated/contract.dart',
        },
      }),
    );

    const docsDirectory = path.join(directory, 'docs/generated');
    const displacedDocsDirectory = path.join(directory, 'docs/generated-original');
    const replacementDocsDirectory = path.join(directory, 'docs/generated-replacement');
    await mkdir(replacementDocsDirectory);
    await copyFile(
      path.join(docsDirectory, 'schema.json'),
      path.join(replacementDocsDirectory, 'schema.json'),
    );
    await copyFile(
      path.join(docsDirectory, 'profile-manifest.json'),
      path.join(replacementDocsDirectory, 'profile-manifest.json'),
    );
    await writeFile(
      path.join(replacementDocsDirectory, 'schema.json'),
      '{"wrong":true}\n',
      'utf8',
    );
    let docsDirectorySwapped = false;
    await assert.rejects(
      run(['check', ...args], {
        hooks: {
          afterArtifactInspected: async ({filename, mode}) => {
            if (!docsDirectorySwapped && filename === 'schema.json' && mode === 'mapped') {
              docsDirectorySwapped = true;
              await rename(docsDirectory, displacedDocsDirectory);
              await rename(replacementDocsDirectory, docsDirectory);
            }
          },
        },
      }),
      /bound directory was externally replaced/,
    );
    assert.equal(docsDirectorySwapped, true);
    await rm(docsDirectory, {recursive: true, force: true});
    await rename(displacedDocsDirectory, docsDirectory);
    await assert.doesNotReject(run(['check', ...args]));

    if (process.platform !== 'win32') {
      const executableTarget = path.join(directory, 'bridge/generated/contract.ts');
      await chmod(executableTarget, 0o755);
      await assert.rejects(
        run(['check', ...args]),
        /contract\.ts \(must not be executable\)/,
      );
      await chmod(executableTarget, 0o644);
      await assert.doesNotReject(run(['check', ...args]));

      const expectedContract = await readFile(executableTarget, 'utf8');
      const replacement = path.join(directory, 'executable-contract.ts');
      await writeFile(replacement, expectedContract, {mode: 0o755});
      let replaced = false;
      await assert.rejects(
        run(['check', ...args], {
          hooks: {
            afterArtifactHandleBound: async ({filename, mode, target}) => {
              if (!replaced && filename === 'contract.ts' && mode === 'mapped') {
                replaced = true;
                await rename(replacement, target);
              }
            },
          },
        }),
        /contract\.ts \(changed while checked\)/,
      );
      assert.equal(replaced, true);
      await writeFile(executableTarget, expectedContract);
      await chmod(executableTarget, 0o644);
      await assert.doesNotReject(run(['check', ...args]));
    }

    const contractTarget = path.join(directory, 'bridge/generated/contract.ts');
    const contractContent = await readFile(contractTarget, 'utf8');
    const sameContentVictim = path.join(directory, 'same-content-contract.ts');
    await writeFile(sameContentVictim, contractContent, 'utf8');
    await unlink(contractTarget);
    await symlink(sameContentVictim, contractTarget);
    await assert.rejects(run(['check', ...args]), /contract\.ts \(not a regular file\)/);
    assert.equal(await readFile(sameContentVictim, 'utf8'), contractContent);
    await unlink(contractTarget);
    await writeFile(contractTarget, contractContent, 'utf8');

    const staleLink = path.join(directory, 'docs/generated/stale-link');
    await symlink(sameContentVictim, staleLink);
    await assert.rejects(run(['check', ...args]), /stale-link \(unexpected\)/);
    await unlink(staleLink);

    const staleDirectory = path.join(directory, 'docs/generated/stale-directory');
    await mkdir(staleDirectory);
    await assert.rejects(run(['check', ...args]), /stale-directory \(unexpected\)/);
    await rm(staleDirectory, {recursive: true});

    const staleLock = path.join(await realpath(directory), TRANSACTION_LOCK_NAME);
    await mkdir(staleLock);
    await assert.rejects(run(['check', ...args]), /unfinished transaction/);
    await rm(staleLock, {recursive: true});

    const staleStage = path.join(
      await realpath(directory),
      `${TRANSACTION_STAGE_PREFIX}stale`,
    );
    await mkdir(staleStage);
    await assert.rejects(run(['check', ...args]), /unfinished transaction/);
    await rm(staleStage, {recursive: true});

    const deepStage = path.join(
      await realpath(directory),
      'docs',
      `${TRANSACTION_STAGE_PREFIX}deep-stale`,
    );
    await mkdir(deepStage);
    await assert.rejects(run(['check', ...args]), /unfinished transaction/);
    await rm(deepStage, {recursive: true});

    const stale = path.join(directory, 'docs/generated/old-schema.json');
    await writeFile(stale, '{}\n', 'utf8');
    await assert.rejects(run(['check', ...args]), /old-schema\.json \(unexpected\)/);
    await rm(stale);

    const targets = new Map([
      ['schema.json', path.join(directory, 'docs/generated/schema.json')],
      ['profile-manifest.json', path.join(directory, 'docs/generated/profile-manifest.json')],
      ['contract.ts', path.join(directory, 'bridge/generated/contract.ts')],
      ['contract.dart', path.join(directory, 'mobile/generated/contract.dart')],
    ]);
    const left = fixtureArtifacts('M', 2_000_000);
    const right = fixtureArtifacts('N', 2_000_000);
    const results = await Promise.allSettled([
      writeArtifactTargets(targets, left, {projectRoot: directory}),
      writeArtifactTargets(targets, right, {projectRoot: directory}),
    ]);
    assert.equal(results.filter((result) => result.status === 'fulfilled').length, 1);
    assert.match(
      results.find((result) => result.status === 'rejected').reason.message,
      /(?:already locked|unfinished artifact transaction)/,
    );
    const winner = results[0].status === 'fulfilled' ? left : right;
    for (const filename of GENERATED_FILES) {
      assert.equal(await readFile(targets.get(filename), 'utf8'), winner.get(filename));
    }
    assert.deepEqual(
      (await readdir(directory)).filter((name) => name.startsWith('.ccpocket-contract')),
      [],
    );
  } finally {
    await rm(directory, {recursive: true, force: true});
  }
});

test('transaction faults during backup or install restore the complete prior artifact set', async () => {
  const directory = await mkdtemp(path.join(tmpdir(), 'ccpocket-contract-rollback-'));
  try {
    const targets = new Map([
      ['schema.json', path.join(directory, 'docs/schema.json')],
      ['profile-manifest.json', path.join(directory, 'docs/profile-manifest.json')],
      ['contract.ts', path.join(directory, 'bridge/contract.ts')],
      ['contract.dart', path.join(directory, 'mobile/contract.dart')],
    ]);
    const previous = fixtureArtifacts('P');
    const replacement = fixtureArtifacts('Q');
    await writeArtifactTargets(targets, previous, {projectRoot: directory});

    let backups = 0;
    await assert.rejects(
      writeArtifactTargets(targets, replacement, {
        projectRoot: directory,
        hooks: {
          afterBackup() {
            backups += 1;
            if (backups === 2) throw new Error('injected backup fault');
          },
        },
      }),
      /injected backup fault/,
    );
    for (const filename of GENERATED_FILES) {
      assert.equal(await readFile(targets.get(filename), 'utf8'), previous.get(filename));
    }
    assert.deepEqual(
      (await readdir(await realpath(directory))).filter(
        (name) => name.startsWith('.ccpocket-contract-targets'),
      ),
      [],
    );

    let installs = 0;
    await assert.rejects(
      writeArtifactTargets(targets, replacement, {
        projectRoot: directory,
        hooks: {
          afterInstall() {
            installs += 1;
            if (installs === 2) throw new Error('injected install fault');
          },
        },
      }),
      /injected install fault/,
    );
    for (const filename of GENERATED_FILES) {
      assert.equal(await readFile(targets.get(filename), 'utf8'), previous.get(filename));
    }
    assert.deepEqual(
      (await readdir(await realpath(directory))).filter(
        (name) => name.startsWith('.ccpocket-contract-targets'),
      ),
      [],
    );
  } finally {
    await rm(directory, {recursive: true, force: true});
  }
});

test('final provenance failure rolls back before artifact transaction commit', async () => {
  const directory = await mkdtemp(path.join(tmpdir(), 'ccpocket-contract-precommit-'));
  try {
    const targets = new Map([
      ['schema.json', path.join(directory, 'docs/schema.json')],
      ['profile-manifest.json', path.join(directory, 'docs/profile-manifest.json')],
      ['contract.ts', path.join(directory, 'bridge/contract.ts')],
      ['contract.dart', path.join(directory, 'mobile/contract.dart')],
    ]);
    const previous = fixtureArtifacts('P');
    const replacement = fixtureArtifacts('Q');
    await writeArtifactTargets(targets, previous, {projectRoot: directory});
    let verified = false;

    await assert.rejects(
      writeArtifactTargets(targets, replacement, {
        projectRoot: directory,
        beforeCommit: async () => {
          verified = true;
          throw new Error('injected final provenance failure');
        },
      }),
      /injected final provenance failure/,
    );

    assert.equal(verified, true);
    for (const filename of GENERATED_FILES) {
      assert.equal(await readFile(targets.get(filename), 'utf8'), previous.get(filename));
    }
    assert.deepEqual(
      (await readdir(directory)).filter(
        (name) => name === TRANSACTION_LOCK_NAME || name.startsWith(TRANSACTION_STAGE_PREFIX),
      ),
      [],
    );
  } finally {
    await rm(directory, {recursive: true, force: true});
  }
});

test('rollback restores a prior symlink as the same symlink object', async () => {
  const directory = await mkdtemp(path.join(tmpdir(), 'ccpocket-contract-symlink-rollback-'));
  try {
    const targets = new Map(GENERATED_FILES.map((filename) => [
      filename,
      path.join(directory, 'generated', filename),
    ]));
    await mkdir(path.join(directory, 'generated'));
    const victim = path.join(directory, 'victim.txt');
    await writeFile(victim, 'symlink victim', 'utf8');
    await symlink(victim, targets.get('schema.json'));
    const symlinkIdentity = await lstat(targets.get('schema.json'), {bigint: true});
    const previous = fixtureArtifacts('symlink-before');
    for (const filename of GENERATED_FILES.filter((name) => name !== 'schema.json')) {
      await writeFile(targets.get(filename), previous.get(filename), 'utf8');
    }

    await assert.rejects(
      writeArtifactTargets(targets, fixtureArtifacts('symlink-after'), {
        projectRoot: directory,
        hooks: {
          afterInstall(record) {
            if (record.filename === 'schema.json') {
              throw new Error('injected symlink rollback failure');
            }
          },
        },
      }),
      /injected symlink rollback failure/,
    );
    const restoredSymlink = await lstat(targets.get('schema.json'), {bigint: true});
    assert.equal(restoredSymlink.isSymbolicLink(), true);
    assert.equal(restoredSymlink.dev, symlinkIdentity.dev);
    assert.equal(restoredSymlink.ino, symlinkIdentity.ino);
    assert.equal(await readlink(targets.get('schema.json')), victim);
    assert.equal(await readFile(victim, 'utf8'), 'symlink victim');
    for (const filename of GENERATED_FILES.filter((name) => name !== 'schema.json')) {
      assert.equal(await readFile(targets.get(filename), 'utf8'), previous.get(filename));
    }
    assert.deepEqual(
      (await readdir(directory)).filter((name) => name.startsWith('.ccpocket-contract')),
      [],
    );
  } finally {
    await rm(directory, {recursive: true, force: true});
  }
});

test('rollback never deletes an externally replaced target and retains recovery evidence', async () => {
  const directory = await mkdtemp(path.join(tmpdir(), 'ccpocket-contract-external-'));
  try {
    const targets = new Map([
      ['schema.json', path.join(directory, 'docs/schema.json')],
      ['profile-manifest.json', path.join(directory, 'docs/profile-manifest.json')],
      ['contract.ts', path.join(directory, 'bridge/contract.ts')],
      ['contract.dart', path.join(directory, 'mobile/contract.dart')],
    ]);
    const previous = fixtureArtifacts('R');
    const replacement = fixtureArtifacts('S');
    await writeArtifactTargets(targets, previous, {projectRoot: directory});

    await assert.rejects(
      writeArtifactTargets(targets, replacement, {
        projectRoot: directory,
        hooks: {
          async afterInstall(record) {
            if (record.filename !== 'schema.json') return;
            await unlink(record.target);
            await writeFile(record.target, 'external replacement', 'utf8');
            throw new Error('injected failure after external replacement');
          },
        },
      }),
      /automatic recovery stopped.*externally replaced/,
    );
    assert.equal(await readFile(targets.get('schema.json'), 'utf8'), 'external replacement');
    const rootEntries = await readdir(await realpath(directory));
    assert.equal(rootEntries.includes(TRANSACTION_LOCK_NAME), true);
    const stageName = rootEntries.find((name) => name.startsWith(TRANSACTION_STAGE_PREFIX));
    assert.ok(stageName);
    assert.equal(
      await readFile(path.join(await realpath(directory), stageName, 'backup/schema.json'), 'utf8'),
      previous.get('schema.json'),
    );

    await assert.rejects(
      writeArtifactTargets(targets, replacement, {projectRoot: directory}),
      /unfinished artifact transaction/,
    );

    const targetMapFile = path.join(directory, 'target-map.json');
    await writeFile(targetMapFile, JSON.stringify({
      formatVersion: 1,
      projectRoot: '.',
      artifacts: Object.fromEntries(
        [...targets].map(([filename, target]) => [
          filename,
          path.relative(directory, target),
        ]),
      ),
    }), 'utf8');
    await assert.rejects(
      run([
        'check',
        '--registry', path.join(fixtures, 'registry.json'),
        '--vectors', path.join(fixtures, 'vectors.json'),
        '--target-map', targetMapFile,
      ]),
      /unfinished transaction/,
    );
  } finally {
    await rm(directory, {recursive: true, force: true});
  }
});

test('rollback lock-cleanup failure keeps the transaction lock and stage visible', async () => {
  const directory = await mkdtemp(path.join(tmpdir(), 'ccpocket-contract-cleanup-'));
  try {
    const targets = new Map(GENERATED_FILES.map((filename) => [
      filename,
      path.join(directory, filename),
    ]));
    const previous = fixtureArtifacts('T');
    await writeArtifactTargets(targets, previous, {projectRoot: directory});
    await assert.rejects(
      writeArtifactTargets(targets, fixtureArtifacts('U'), {
        projectRoot: directory,
        hooks: {
          afterBackup() {
            throw new Error('injected transaction failure');
          },
          beforeLockCleanup() {
            throw new Error('injected cleanup failure');
          },
        },
      }),
      /automatic recovery stopped.*injected cleanup failure/,
    );
    for (const filename of GENERATED_FILES) {
      assert.equal(await readFile(targets.get(filename), 'utf8'), previous.get(filename));
    }
    const entries = await readdir(await realpath(directory));
    assert.equal(entries.includes(TRANSACTION_LOCK_NAME), true);
    assert.equal(entries.some((name) => name.startsWith(TRANSACTION_STAGE_PREFIX)), true);
  } finally {
    await rm(directory, {recursive: true, force: true});
  }
});

test('post-lock cleanup failure retains stage residue and reports the absent-lock possibility', async () => {
  const directory = await mkdtemp(path.join(tmpdir(), 'ccpocket-contract-post-lock-cleanup-'));
  try {
    const targets = new Map(GENERATED_FILES.map((filename) => [
      filename,
      path.join(directory, filename),
    ]));
    const previous = fixtureArtifacts('V');
    await writeArtifactTargets(targets, previous, {projectRoot: directory});
    await assert.rejects(
      writeArtifactTargets(targets, fixtureArtifacts('W'), {
        projectRoot: directory,
        hooks: {
          afterBackup() {
            throw new Error('injected transaction failure');
          },
          beforeMutation(details) {
            if (details.operation === 'cleanup-staged-artifact') {
              throw new Error('injected post-lock cleanup failure');
            }
          },
        },
      }),
      /inspect last-known transaction locations.*lock .*either may already be absent.*injected post-lock cleanup failure/,
    );
    for (const filename of GENERATED_FILES) {
      assert.equal(await readFile(targets.get(filename), 'utf8'), previous.get(filename));
    }
    const entries = await readdir(await realpath(directory));
    assert.equal(entries.includes(TRANSACTION_LOCK_NAME), false);
    assert.equal(entries.some((name) => name.startsWith(TRANSACTION_STAGE_PREFIX)), true);
  } finally {
    await rm(directory, {recursive: true, force: true});
  }
});

test('check detects generated drift without modifying the target', async () => {
  const directory = await mkdtemp(path.join(tmpdir(), 'ccpocket-contract-test-'));
  try {
    const value = await model();
    await writeArtifacts(directory, generateArtifacts(value));
    const args = [
      'check',
      '--registry', path.join(fixtures, 'registry.json'),
      '--vectors', path.join(fixtures, 'vectors.json'),
      '--out', directory,
    ];
    await run(args);
    const target = path.join(directory, 'contract.ts');
    const original = await readFile(target, 'utf8');
    const changed = `${original}\n// drift\n`;
    await writeFile(target, changed, 'utf8');
    await assert.rejects(run(args), /generated artifact drift: contract.ts/);
    assert.equal(await readFile(target, 'utf8'), changed);
    await writeFile(target, original, 'utf8');

    const displacedDirectory = `${directory}-bound-original`;
    const replacementDirectory = `${directory}-bound-replacement`;
    await mkdir(replacementDirectory);
    for (const filename of GENERATED_FILES) {
      await copyFile(
        path.join(directory, filename),
        path.join(replacementDirectory, filename),
      );
    }
    await writeFile(
      path.join(replacementDirectory, 'schema.json'),
      '{"wrong":true}\n',
      'utf8',
    );
    let directorySwapped = false;
    await assert.rejects(
      run(args, {
        hooks: {
          afterArtifactInspected: async ({filename, mode}) => {
            if (!directorySwapped && filename === 'schema.json' && mode === 'standalone') {
              directorySwapped = true;
              await rename(directory, displacedDirectory);
              await rename(replacementDirectory, directory);
            }
          },
        },
      }),
      /generated artifact directory changed while checked/,
    );
    assert.equal(directorySwapped, true);
    await rm(directory, {recursive: true, force: true});
    await rename(displacedDirectory, directory);
    await assert.doesNotReject(run(args));

    if (process.platform !== 'win32') {
      await chmod(target, 0o755);
      await assert.rejects(
        run(args),
        /generated artifact drift: contract\.ts \(must not be executable\)/,
      );
      await chmod(target, 0o644);
      await assert.doesNotReject(run(args));

      const victim = path.join(path.dirname(directory), `${path.basename(directory)}-victim.ts`);
      const replacement = path.join(directory, 'contract-replacement-link.ts');
      await writeFile(victim, original);
      await symlink(victim, replacement);
      let replaced = false;
      await assert.rejects(
        run(args, {
          hooks: {
            afterArtifactHandleBound: async ({filename, mode, target: boundTarget}) => {
              if (!replaced && filename === 'contract.ts' && mode === 'standalone') {
                replaced = true;
                await rename(replacement, boundTarget);
              }
            },
          },
        }),
        /contract\.ts \(changed while checked\)/,
      );
      assert.equal(replaced, true);
      await unlink(target);
      await writeFile(target, original, {mode: 0o644});
      await unlink(victim);
      await assert.doesNotReject(run(args));
    }

    const stale = path.join(directory, 'old-contract.ts');
    await writeFile(stale, '// obsolete generated artifact\n', 'utf8');
    await assert.rejects(run(args), /old-contract\.ts \(unexpected\)/);
    assert.equal(await readFile(stale, 'utf8'), '// obsolete generated artifact\n');
  } finally {
    await rm(directory, {recursive: true, force: true});
  }
});
