import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

import {
  digestAuthoritySource,
  validateDigestAuthorityRegistry,
  validatePredecessorReferenceInstances,
} from '../src/b1-digest-authority.mjs';

const registryUrl = new URL(
  '../../../docs/design/codex-kernel-v4/contracts/contract-registry.json',
  import.meta.url,
);
const pristine = JSON.parse(readFileSync(registryUrl, 'utf8'));

function registry() {
  return structuredClone(pristine);
}

function dependencyKey(edge) {
  return `${edge.relationKind}|${edge.sourceDigestId}->${edge.targetDigestId}|${
    edge.sourceFieldPath ?? ''}`;
}

function sortDependencies(value) {
  value.digestDependencyEdges.sort((left, right) => {
    const leftKey = dependencyKey(left);
    const rightKey = dependencyKey(right);
    return leftKey < rightKey ? -1 : leftKey > rightKey ? 1 : 0;
  });
}

function expectRegistryFailure(mutate, pattern) {
  const value = registry();
  mutate(value);
  assert.throws(() => validateDigestAuthorityRegistry(value), pattern);
}

test('validates and normalizes the complete active digest authority', () => {
  const model = validateDigestAuthorityRegistry(registry());
  assert.equal(model.digestDerivations.length, 19);
  assert.equal(model.digestEqualityReferences.length, 143);
  assert.equal(model.digestDependencyEdges.length, 50);
  assert.equal(model.digestPostDerivationGuards.length, 1);
  assert.equal(
    model.digestDerivationsById.get('DR-CODEX-CERTIFICATION').ownedFieldPaths[0],
    'CodexAdapterCertificationV1.codexCertificationDigest',
  );
  assert.equal(
    model.digestEqualityReferences.find((row) =>
      row.fieldPath === 'CodexAdapterCertificationPreimageV1.providerBuildDigest')
      ?.equalityTargetDigestId,
    'DR-CODEX-EXECUTABLE',
  );
  assert.equal(
    model.digestDerivationsById.get('DR-PVMC1-MACHINE-TRANSITION-SQL')
      .ownedFieldPaths[0],
    'MachineTransitionSqlV1.sqlSha256',
  );
  assert.deepEqual(
    [...new Set([
      ...model.digestDerivations.map((row) => row.derivationMode),
      ...model.digestEqualityReferences.map((row) => row.derivationMode),
    ])].sort(),
    [
      'DOMAIN_SEPARATED_JCS',
      'FROZEN_RFC8785_JCS',
      'REFERENCE_EQUALITY',
      'STANDARD_EXACT_BYTES',
    ],
  );
  assert.ok(model.digestEqualityReferences.every((row) => !row.fieldPath.includes('*')));
  assert.deepEqual(Object.keys(digestAuthoritySource(model)), [
    'digestDerivations',
    'digestEqualityReferences',
    'digestDependencyEdges',
    'digestPostDerivationGuards',
  ]);
});

test('rejects a missing reachable REFERENCE_EQUALITY field', () => {
  expectRegistryFailure((value) => {
    value.digestEqualityReferences = value.digestEqualityReferences.filter(
      (row) => row.fieldPath !== 'TimelineProviderReadBodyV1.resultDigest',
    );
  }, /must appear exactly once as owner or reference/);
});

test('rejects a duplicate reachable REFERENCE_EQUALITY field', () => {
  expectRegistryFailure((value) => {
    value.digestEqualityReferences.push(structuredClone(value.digestEqualityReferences[0]));
    value.digestEqualityReferences.sort((left, right) =>
      left.fieldPath < right.fieldPath ? -1 : left.fieldPath > right.fieldPath ? 1 : 0);
  }, /duplicate row key/);
});

test('rejects a wrong equalityTargetDigestId', () => {
  expectRegistryFailure((value) => {
    value.digestEqualityReferences.find(
      (row) => row.fieldPath === 'TimelineProviderReadBodyV1.resultDigest',
    ).equalityTargetDigestId = 'DR-READ-PLAN';
  }, /wrong target DR-READ-PLAN; expected DR-NORMALIZED-RESULT/);
});

test('rejects dangling derivation owners and preimage types independently', () => {
  expectRegistryFailure((value) => {
    value.digestDerivations[0].ownerRef = 'owner.missing';
  }, /dangling owner owner\.missing/);
  expectRegistryFailure((value) => {
    value.digestDerivations.find((row) => row.id === 'DR-MANIFEST').preimageTypeRef = 'MissingV1';
  }, /dangling or inactive preimage type MissingV1/);
});

test('rejects a derivation declared under the wrong mode', () => {
  expectRegistryFailure((value) => {
    value.digestDerivations.find((row) => row.id === 'DR-RECEIPT').derivationMode =
      'STANDARD_EXACT_BYTES';
  }, /STANDARD_EXACT_BYTES/);
});

test('rejects an invented second digest owner for one preimage', () => {
  expectRegistryFailure((value) => {
    const duplicate = structuredClone(
      value.digestDerivations.find((row) => row.id === 'DR-MANIFEST'),
    );
    duplicate.id = 'DR-MANIFEST-ALIAS';
    duplicate.ownedFieldPaths = [];
    value.digestDerivations.push(duplicate);
    value.digestDerivations.sort((left, right) =>
      left.id < right.id ? -1 : left.id > right.id ? 1 : 0);
  }, /preimage MaterializationManifestPreimageV1 has two digest owners/);
});

test('rejects a missing predecessor dependency', () => {
  expectRegistryFailure((value) => {
    value.digestDependencyEdges = value.digestDependencyEdges.filter(
      (row) => row.relationKind !== 'PREDECESSOR_REFERENCE',
    );
  }, /exactly one PREDECESSOR_REFERENCE/);
});

test('rejects a missing ordinary dependency derived from an owning preimage', () => {
  expectRegistryFailure((value) => {
    value.digestDependencyEdges = value.digestDependencyEdges.filter((row) => !(
      row.relationKind === 'ORDINARY' &&
      row.sourceDigestId === 'DR-READ-PLAN' &&
      row.targetDigestId === 'DR-REPAIR-INTENT'
    ));
  }, /missing ordinary edge DR-READ-PLAN->DR-REPAIR-INTENT/);
});

test('rejects an unstratified ordinary self dependency', () => {
  expectRegistryFailure((value) => {
    value.digestDependencyEdges.push({
      profileId: value.activeProfileId,
      sourceDigestId: 'DR-MANIFEST',
      targetDigestId: 'DR-MANIFEST',
      relationKind: 'ORDINARY',
    });
    sortDependencies(value);
  }, /ordinary digest cycle: DR-MANIFEST -> DR-MANIFEST/);
});

test('rejects an ordinary reverse edge and a larger SCC independently', () => {
  expectRegistryFailure((value) => {
    value.digestDependencyEdges.push({
      profileId: value.activeProfileId,
      sourceDigestId: 'DR-READ-SPEC',
      targetDigestId: 'DR-READ-PLAN',
      relationKind: 'ORDINARY',
    });
    sortDependencies(value);
  }, /ordinary digest cycle/);
  expectRegistryFailure((value) => {
    value.digestDependencyEdges.push({
      profileId: value.activeProfileId,
      sourceDigestId: 'DR-RECEIPT',
      targetDigestId: 'DR-READ-PLAN',
      relationKind: 'ORDINARY',
    });
    sortDependencies(value);
  }, /ordinary digest cycle/);
});

test('rejects inserting the current-manifest post guard into the digest DAG', () => {
  expectRegistryFailure((value) => {
    const edge = value.digestDependencyEdges.find(
      (row) => row.relationKind === 'PREDECESSOR_REFERENCE',
    );
    edge.sourceFieldPath = 'PredecessorReferenceEdgeV1.current.manifestDigest';
  }, /post-derivation current-manifest equality must not enter the digest DAG/);
});

test('rejects a disabled or missing current-manifest post guard', () => {
  expectRegistryFailure((value) => {
    value.digestPostDerivationGuards[0].excludedFromDigestDependencyGraph = false;
  }, /must be exactly true/);
  expectRegistryFailure((value) => {
    value.digestPostDerivationGuards = [];
  }, /requires exactly one active current-manifest guard/);
});

test('enumerates oneOf branches and providerBuildDigest as exact executable references', () => {
  const value = registry();
  value.definitions.push({
    id: 'DigestOneOfProbeV1',
    profiles: [value.activeProfileId],
    node: {
      kind: 'oneOf',
      variants: [0, 1].map(() => ({
        kind: 'object',
        fields: [{
          name: 'providerBuildDigest',
          required: true,
          type: {kind: 'ref', target: 'Sha256Hex64'},
        }],
      })),
    },
  });
  value.profiles.find((profile) => profile.id === value.activeProfileId)
    .rootTypeRefs.push('DigestOneOfProbeV1');
  for (const branch of [0, 1]) {
    value.digestEqualityReferences.push({
      profileId: value.activeProfileId,
      fieldPath: `DigestOneOfProbeV1<ONE_OF_${branch}>.providerBuildDigest`,
      derivationMode: 'REFERENCE_EQUALITY',
      equalityTargetDigestId: 'DR-CODEX-EXECUTABLE',
    });
  }
  value.digestEqualityReferences.sort((left, right) =>
    left.fieldPath < right.fieldPath ? -1 : left.fieldPath > right.fieldPath ? 1 : 0);
  assert.doesNotThrow(() => validateDigestAuthorityRegistry(value));
  value.digestEqualityReferences = value.digestEqualityReferences.filter(
    (row) => row.fieldPath !== 'DigestOneOfProbeV1<ONE_OF_1>.providerBuildDigest',
  );
  assert.throws(
    () => validateDigestAuthorityRegistry(value),
    /DigestOneOfProbeV1<ONE_OF_1>\.providerBuildDigest must appear exactly once/,
  );
});

const sourcePartition = {
  bridgeIdentityId: 'bridge',
  bridgeInstanceId: 'instance',
  codexSourceId: 'codex',
};

function endpoint(materializationId, headVersion, manifestDigest, partition = sourcePartition) {
  return {
    sourcePartition: partition,
    subject: {
      domain: 'TIMELINE',
      threadRef: {
        sourcePartition: partition,
        providerThreadId: 'thread',
      },
      materializationId,
    },
    headVersion,
    manifestDigest,
  };
}

function predecessor(base, current) {
  return {
    edgeKind: 'PREDECESSOR_REFERENCE',
    relationMode: 'REFERENCE_EQUALITY',
    current: {proofDigest: `proof-${current.manifestDigest}`, ...current},
    base,
  };
}

test('accepts a well-founded predecessor instance chain', () => {
  const first = endpoint('m1', 1, 'manifest-1');
  const second = endpoint('m2', 2, 'manifest-2');
  const third = endpoint('m3', 3, 'manifest-3');
  assert.equal(validatePredecessorReferenceInstances([
    predecessor(first, second),
    predecessor(second, third),
  ]), true);
});

test('rejects self, reverse, same-version, and cross-scope predecessor instances', () => {
  const first = endpoint('m1', 1, 'manifest-1');
  const second = endpoint('m2', 2, 'manifest-2');
  assert.throws(
    () => validatePredecessorReferenceInstances([predecessor(first, first)]),
    /self predecessor reference/,
  );
  assert.throws(
    () => validatePredecessorReferenceInstances([predecessor(second, first)]),
    /reverse predecessor reference/,
  );
  assert.throws(
    () => validatePredecessorReferenceInstances([
      predecessor(first, endpoint('m2', 1, 'manifest-2')),
    ]),
    /same-version predecessor reference/,
  );
  const otherPartition = {...sourcePartition, codexSourceId: 'other'};
  assert.throws(
    () => validatePredecessorReferenceInstances([
      predecessor(first, endpoint('m2', 2, 'manifest-2', otherPartition)),
    ]),
    /cross-scope predecessor reference/,
  );
});

test('rejects a cross-instance predecessor cycle before lexical or version ranking', () => {
  const first = endpoint('m1', 1, 'manifest-1');
  const second = endpoint('m2', 2, 'manifest-2');
  assert.throws(
    () => validatePredecessorReferenceInstances([
      predecessor(first, second),
      predecessor(second, first),
    ]),
    /cross-instance predecessor cycle/,
  );
});
