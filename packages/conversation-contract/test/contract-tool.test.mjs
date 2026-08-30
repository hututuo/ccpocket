import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import { digestBytes } from '../src/canonical.mjs';
import { run } from '../src/cli.mjs';
import { generateArtifacts, writeArtifacts } from '../src/generate.mjs';
import { validateInputs, validateValue } from '../src/validate.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const fixtures = path.join(here, 'fixtures');

async function load(name) {
  return JSON.parse(await readFile(path.join(fixtures, name), 'utf8'));
}

async function model() {
  return validateInputs(await load('registry.json'), await load('vectors.json'));
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
    const changed = `${await readFile(target, 'utf8')}\n// drift\n`;
    await writeFile(target, changed, 'utf8');
    await assert.rejects(run(args), /generated artifact drift: contract.ts/);
    assert.equal(await readFile(target, 'utf8'), changed);
  } finally {
    await rm(directory, {recursive: true, force: true});
  }
});
