import assert from 'node:assert/strict';
import {
  lstat,
  mkdir,
  mkdtemp,
  readFile,
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

import { digestBytes } from '../src/canonical.mjs';
import { run } from '../src/cli.mjs';
import {
  GENERATED_FILES,
  TRANSACTION_LOCK_NAME,
  TRANSACTION_STAGE_PREFIX,
  generateArtifacts,
  writeArtifactTargets,
  writeArtifacts,
} from '../src/generate.mjs';
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
    'FixtureEnvelope', 'FixturePayload', 'FixturePriority', 'FixtureSourceRef',
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
  const first = generateArtifacts(value);
  const second = generateArtifacts(value);
  assert.deepEqual([...first], [...second]);
  const manifest = JSON.parse(first.get('profile-manifest.json'));
  assert.equal(manifest.profileId, 'fixture.active');
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
  for (const filename of ['schema.json', 'contract.ts', 'contract.dart']) {
    assert.equal(manifest.artifactDigests[filename], digestBytes(first.get(filename)));
    assert.doesNotMatch(first.get(filename), /FutureOnly/);
  }
  assert.match(first.get('schema.json'), /draft\/2020-12/);
  assert.match(first.get('contract.ts'), /export function decodeFixtureEnvelope/);
  assert.match(first.get('contract.dart'), /sealed class FixturePayload/);
  assert.match(first.get('contract.dart'), /cost\\\$x/);

  const envelopeProperties = schema.$defs.FixtureEnvelope.properties;
  assert.equal(Object.hasOwn(envelopeProperties, '__proto__'), true);
  assert.deepEqual(envelopeProperties.__proto__, {type: 'string'});
  assert.equal(Object.hasOwn(Object.prototype, 'type'), false);
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

test('rollback cleanup failure keeps the transaction lock and stage visible', async () => {
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
          beforeStageCleanup() {
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

    const stale = path.join(directory, 'old-contract.ts');
    await writeFile(stale, '// obsolete generated artifact\n', 'utf8');
    await assert.rejects(run(args), /old-contract\.ts \(unexpected\)/);
    assert.equal(await readFile(stale, 'utf8'), '// obsolete generated artifact\n');
  } finally {
    await rm(directory, {recursive: true, force: true});
  }
});
