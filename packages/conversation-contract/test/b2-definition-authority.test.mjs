import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';

import {validateInputs} from '../src/validate.mjs';

const registryUrl = new URL(
  '../../../docs/design/codex-kernel-v4/contracts/contract-registry.json',
  import.meta.url,
);
const vectorsUrl = new URL(
  '../../../docs/design/codex-kernel-v4/contracts/vectors/phone-core-vectors.json',
  import.meta.url,
);

function inputs() {
  return {
    registry: JSON.parse(readFileSync(registryUrl, 'utf8')),
    vectors: JSON.parse(readFileSync(vectorsUrl, 'utf8')),
  };
}

function definition(registry, id) {
  return registry.definitions.find((candidate) => candidate.id === id);
}

test('all active B2 definitions exact-equal the independent closed oracle', () => {
  const {registry, vectors} = inputs();
  const model = validateInputs(registry, vectors);
  assert.ok(model.activeDefinitionIds.has('OperationAdmissionPersistedRowV1'));
  assert.ok(model.activeDefinitionIds.has('NonEmptyUniqueGuardRefSetV1'));
  assert.ok(model.activeDefinitionIds.has('VectorId'));
});

test('B2 definition oracle rejects permission and recovery weakening mutations', () => {
  const mutations = [
    (registry) => {
      definition(registry, 'OperationQueryV1').node.fields.push({
        name: 'actorBinding',
        required: false,
        type: {kind: 'ref', target: 'AuthenticatedActorBindingKeyV1'},
      });
    },
    (registry) => {
      definition(registry, 'NonEmptyUniqueGuardRefSetV1').node.minItems = 0;
    },
    (registry) => {
      definition(registry, 'TransactionManifestV1').node.fields.find((field) =>
        field.name === 'applicabilityCases').type.minItems = 0;
    },
    (registry) => {
      definition(registry, 'TransactionKillPointV1').node.fields.find((field) =>
        field.name === 'failureOracle').required = false;
    },
  ];
  for (const mutate of mutations) {
    const {registry, vectors} = inputs();
    mutate(registry);
    assert.throws(
      () => validateInputs(registry, vectors),
      /B2 definition oracle|active definition closure|does not exact-equal/,
    );
  }
});
