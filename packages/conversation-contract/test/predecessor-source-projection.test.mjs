import assert from 'node:assert/strict';
import test from 'node:test';

import {
  validatePredecessorReferenceInstances,
} from '../src/b1-digest-authority.mjs';

const outerSource = {
  bridgeIdentityId: 'bridge',
  bridgeInstanceId: 'instance',
  codexSourceId: 'source-a',
};

const foreignSubjectSource = {
  ...outerSource,
  codexSourceId: 'source-b',
};

function endpoint(materializationId, headVersion, manifestDigest, subjectSource = outerSource) {
  return {
    sourcePartition: outerSource,
    subject: {
      domain: 'TIMELINE',
      threadRef: {
        sourcePartition: subjectSource,
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

test('accepts predecessor endpoints whose source projection is self-consistent', () => {
  const base = endpoint('base', 1, 'manifest-1');
  const current = endpoint('current', 2, 'manifest-2');
  assert.equal(validatePredecessorReferenceInstances([predecessor(base, current)]), true);
});

test('rejects matching outer sources that disagree with both subject projections', () => {
  const base = endpoint('base', 1, 'manifest-1', foreignSubjectSource);
  const current = endpoint('current', 2, 'manifest-2', foreignSubjectSource);
  assert.throws(
    () => validatePredecessorReferenceInstances([predecessor(base, current)]),
    /source projection mismatch/,
  );
});
