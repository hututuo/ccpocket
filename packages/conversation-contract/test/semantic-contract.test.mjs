import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import {fileURLToPath} from 'node:url';

import {parseStrictJson} from '../src/cli.mjs';
import {canonicalUtf8, jcsDigest} from '../src/canonical.mjs';
import {
  evaluateCanonicalPredecessorObservation,
  evaluateMaterializationAuthority,
  evaluatePredecessorReferenceGraph,
  evaluateProviderTurnBoundary,
  evaluateReadEvidenceObservation,
  evaluateRawWireBoundary,
  evaluateSemanticRule,
} from '../src/semantic-oracle.mjs';
import {
  MAX_CONTROL_FRAME_BYTES,
  MAX_CONTROL_PAYLOAD_BYTES,
  MAX_IMAGE_BYTES,
  MAX_INLINE_TEXT_BYTES,
  MAX_PUBLICATION_PAGE_BYTES,
  MAX_PROVIDER_TURN_BYTES,
  MAX_TURN_IMAGE_COUNT,
  SOURCE,
  boundary,
  cacheObservation,
  canonicalPageBodyBytes,
  capabilitySnapshot,
  codexAdapterCertification,
  codexAdapterCertificationPreimage,
  codexAdapterProbeFacts,
  coveragePreimage,
  coverageOrderedIsland,
  epoch,
  gapBetween,
  imageIngress,
  interactionFixture,
  livePromotion,
  materialization,
  operationDispatchObservation,
  operationFingerprint,
  operationRecoveryObservation,
  operationRef,
  operationRequest,
  payloadCommitment,
  readEvidence,
  readSpec,
  repairIntent,
  sourceAdmissionObservation,
  subject,
  textItem,
  threadRef,
  turnRef,
  unavailablePayload,
} from '../src/semantic-primitives.mjs';
import {validateInputs, validateValue} from '../src/validate.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const repositoryRoot = path.resolve(here, '../../..');
const registryPath = path.join(repositoryRoot, 'docs/design/codex-kernel-v4/contracts/contract-registry.json');
const vectorsPath = path.join(repositoryRoot, 'docs/design/codex-kernel-v4/contracts/vectors/phone-core-vectors.json');

// Deliberately duplicated from the sealed oracle, rather than read from the
// Registry, so a registry/vector mutation cannot self-certify its zero shape.
const ZERO_BY_ORACLE = Object.freeze({
  'machine.authority': {artifacts: 0, durableRows: 0},
  'machine.sql-exact-bytes': {artifacts: 0, durableRows: 0},
  'operation.admission-lookup': {attemptsCreated: 0, eventRows: 0, newOperationIds: 0, operationsCreated: 0, outboxRows: 0, providerCalls: 0, resends: 0},
  'transaction.authority': {artifacts: 0, durableRows: 0},
  'wire.closed-normalized-shape': {durableRows: 0, wireWrites: 0},
  'identity.source-fence': {admissionRows: 0, interactionRows: 0, providerCalls: 0, publicationRows: 0, queueRows: 0, visibleResults: 0},
  'timeline.typed-empty': {canonicalCommits: 0, lastGoodDeletes: 0},
  'timeline.read-evidence': {canonicalCommits: 0, providerReads: 0, wireWrites: 0},
  'timeline.provider-turn-boundary': {mobileCommits: 0, mobileAcks: 0, visibleResults: 0},
  'timeline.materialization': {mobileCommits: 0, mobileAcks: 0, visibleResults: 0},
  'timeline.page-size': {mobileCommits: 0, mobileAcks: 0, visibleResults: 0},
  'image.ingress': {contentRefs: 0, operationAdmissions: 0},
  'timeline.cache-reuse': {canonicalRewrites: 0, repeatProviderReads: 0},
  'timeline.order-gap': {canonicalCommits: 0, gapClosures: 0, itemReorders: 0},
  'timeline.last-good': {canonicalCommits: 0, lastGoodDeletes: 0, lastGoodDowngrades: 0},
  'timeline.live-promotion': {canonicalDuplicates: 0, livePromotions: 0, liveReorders: 0},
  'operation.typed-union': {admissionRows: 0, providerCalls: 0},
  'operation.fingerprint': {newAdmissionRows: 0, providerCalls: 0, queueRows: 0},
  'operation.admission-barrier': {providerCalls: 0},
  'operation.outcome-unknown': {reconcileMutationCalls: 0, redispatches: 0, terminalSuccessWrites: 0},
  'queue.revision': {providerCalls: 0, queueRowsUpdated: 0},
  'interaction.source': {interactionRows: 0, operationRows: 0, providerCalls: 0, queueRows: 0, visibleResults: 0},
  'interaction.actor': {interactionRows: 0, operationRows: 0, providerCalls: 0, queueRows: 0, visibleResults: 0},
  'interaction.expiry': {interactionRows: 0, operationRows: 0, providerCalls: 0, queueRows: 0, visibleResults: 0},
  'interaction.duplicate': {additionalOperationRows: 0, additionalProviderCalls: 0, additionalVisibleResults: 0},
  'interaction.variant': {interactionRows: 0, operationRows: 0, providerCalls: 0, queueRows: 0, visibleResults: 0},
  'capability.claude': {admissionRows: 0, providerCalls: 0},
  'capability.codex-runtime': {providerReads: 0, publications: 0},
});

const ORACLE_ANCHORS = Object.freeze(Object.keys(ZERO_BY_ORACLE));

async function load(filename, label) {
  const bytes = await readFile(filename);
  const text = new TextDecoder('utf-8', {fatal: true}).decode(bytes);
  return parseStrictJson(text, label);
}

async function model() {
  return validateInputs(await load(registryPath, 'registry'), await load(vectorsPath, 'vectors'));
}

function expectRejected(value, oracleRef, reason) {
  const result = evaluateSemanticRule(value, oracleRef);
  assert.equal(result.valid, false, `${oracleRef}: expected rejection`);
  assert.equal(result.reason, reason, oracleRef);
  assert.equal(result.postState, 'UNCHANGED', oracleRef);
  assert.deepEqual({...result.sideEffects}, {...ZERO_BY_ORACLE[oracleRef]}, oracleRef);
}

function expectApplied(value, oracleRef) {
  assert.deepEqual(evaluateSemanticRule(value, oracleRef), {
    valid: true,
    reason: 'NONE',
    postState: 'APPLIED',
    sideEffects: {},
  }, oracleRef);
}

test('executes every active hard rule with typed positive and negative vectors', async () => {
  const value = await model();
  for (const rule of value.hardRules.values()) {
    const cases = value.activeVectors.filter((vector) => vector.ruleRef === rule.id);
    assert.ok(cases.some((vector) => vector.valid), `${rule.id} needs a positive vector`);
    assert.ok(cases.some((vector) => !vector.valid), `${rule.id} needs a negative vector`);
    for (const vector of cases) {
      const typeErrors = validateValue(vector.typeRef, vector.value, value);
      if (vector.expectedTypeError === 'NO_ONE_OF_VARIANT') {
        assert.equal(vector.valid, false, vector.id);
        assert.equal(typeErrors.length, 1, vector.id);
        assert.match(typeErrors[0], /NO_ONE_OF_VARIANT/, vector.id);
        continue;
      }
      assert.deepEqual(typeErrors, [], vector.id);
      const outcome = evaluateSemanticRule(vector.value, rule.oracleRef);
      assert.equal(outcome.valid, vector.valid, vector.id);
      assert.equal(outcome.reason, vector.expectedReason, vector.id);
      if (vector.valid) {
        assert.equal(outcome.postState, 'APPLIED', vector.id);
        assert.deepEqual(outcome.sideEffects, {}, vector.id);
      } else {
        assert.equal(vector.expectedPostState, 'UNCHANGED', vector.id);
        assert.equal(outcome.postState, 'UNCHANGED', vector.id);
        assert.deepEqual({...outcome.sideEffects}, {...ZERO_BY_ORACLE[rule.oracleRef]}, vector.id);
        assert.deepEqual({...outcome.sideEffects}, {...vector.expectedZeroSideEffects}, vector.id);
      }
    }
  }
});

test('exposes machine-checkable semantic oracle anchors', async (t) => {
  const value = await model();
  const activeOracleRefs = new Set([...value.hardRules.values()].map((rule) => rule.oracleRef));
  assert.deepEqual([...activeOracleRefs].sort(), [...ORACLE_ANCHORS].sort());
  for (const oracleRef of ORACLE_ANCHORS) {
    await t.test(oracleRef, () => assert.ok(activeOracleRefs.has(oracleRef), oracleRef));
  }
});

test('rejects null and duplicate-key negatives before semantic evaluation', async () => {
  const registry = await load(registryPath, 'registry');
  const vectors = await load(vectorsPath, 'vectors');
  const tampered = structuredClone(vectors);
  tampered.vectors.find((vector) => !vector.valid).value = null;
  assert.throws(() => validateInputs(registry, tampered), /vector is not executable/);
  assert.throws(() => parseStrictJson('{"a":1,"a":2}', 'duplicate'), /duplicate object (?:member|key)/);
});

test('requires independent exact zero-side-effect axes in registry and vectors', async () => {
  const registry = await load(registryPath, 'registry');
  const vectors = await load(vectorsPath, 'vectors');
  const ruleId = 'rule.timeline.page-chain-atomic-publication';
  const negativeId = 'timeline.materialization.page-count-mismatch.negative';
  for (const [name, mutate] of [
    ['missing registry axis', (copy) => delete copy.zeroSemantics.mobileAcks],
    ['extra registry axis', (copy) => { copy.zeroSemantics.extraAxis = 0; }],
    ['renamed registry axis', (copy) => { copy.zeroSemantics.mobileCommitsRenamed = copy.zeroSemantics.mobileCommits; delete copy.zeroSemantics.mobileCommits; }],
  ]) {
    const changed = structuredClone(registry);
    mutate(changed.hardRules.find((candidate) => candidate.id === ruleId));
    assert.throws(() => validateInputs(changed, vectors), /semantic oracle mismatch|must exactly match/, name);
  }
  for (const [name, mutate] of [
    ['missing vector axis', (copy) => delete copy.expectedZeroSideEffects.mobileAcks],
    ['extra vector axis', (copy) => { copy.expectedZeroSideEffects.extraAxis = 0; }],
    ['renamed vector axis', (copy) => { copy.expectedZeroSideEffects.mobileCommitsRenamed = copy.expectedZeroSideEffects.mobileCommits; delete copy.expectedZeroSideEffects.mobileCommits; }],
  ]) {
    const changed = structuredClone(vectors);
    mutate(changed.vectors.find((candidate) => candidate.id === negativeId));
    assert.throws(() => validateInputs(registry, changed), /must exactly match|semantic oracle mismatch/, name);
  }
});

test('source authority is relational across arbitrary partitions and epochs', () => {
  const sources = [
    {bridgeIdentityId: 'bridge-x', bridgeInstanceId: 'instance-x', codexSourceId: 'codex-x'},
    {bridgeIdentityId: 'bridge-y', bridgeInstanceId: 'instance-y', codexSourceId: 'codex-y'},
  ];
  for (const [index, source] of sources.entries()) {
    const observation = sourceAdmissionObservation({
      source,
      authenticatedConnectionEpoch: 2 + index,
      authenticatedSourceEpoch: 4 + index,
      currentConnectionEpoch: 3 + index,
      currentSourceEpoch: 5 + index,
      providerInstanceEpoch: 6 + index,
      runtimeAuthorityGeneration: 7 + index,
    });
    expectApplied(observation, 'identity.source-fence');
    for (const mutate of [
      (copy) => { copy.current.sourceEpoch = copy.authenticated.sourceEpoch - 1; },
      (copy) => { copy.current.providerInstanceEpoch = copy.authenticated.providerInstanceEpoch - 1; },
      (copy) => { copy.current.runtimeAuthorityGeneration = copy.authenticated.runtimeAuthorityGeneration - 1; },
      (copy) => { copy.attemptedSourcePartition = {...source, codexSourceId: 'other-codex'}; },
      (copy) => { copy.current.sourcePartition = {...source, bridgeInstanceId: 'other-instance'}; },
    ]) {
      const changed = structuredClone(observation);
      mutate(changed);
      expectRejected(changed, 'identity.source-fence', 'SOURCE_FENCE_MISMATCH');
    }

    const thread = threadRef(`thread-${index + 9}`, source);
    const snapshot = materialization({
      thread,
      materializationId: `materialization-${index + 9}`,
      sourceEpoch: epoch({sourcePartition: source, sourceEpoch: 9 + index, providerInstanceEpoch: 10 + index}),
      baseHeadVersion: index + 7,
      timelineOrdinalOverride: Number.MIN_SAFE_INTEGER,
      turnOrdinalOverride: Number.MIN_SAFE_INTEGER,
    });
    expectApplied(snapshot, 'timeline.materialization');
    const item = snapshot.pages[0].body.items.find((row) => row.rowKind === 'TIMELINE_ITEM').timelineItem;
    assert.equal(item.timelineOrdinal, Number.MIN_SAFE_INTEGER);
    assert.equal(item.turnOrdinal, Number.MIN_SAFE_INTEGER);
    assert.equal(item.itemOrdinal, 0);
    expectApplied(gapBetween({
      thread,
      left: boundary(turnRef('older-turn', thread), Number.MIN_SAFE_INTEGER, 'older-item', Number.MIN_SAFE_INTEGER),
      right: boundary(turnRef('newer-turn', thread), -1, 'newer-item', -1),
    }), 'timeline.order-gap');
  }
});

test('read evidence is verified against a separately resolved normalized result', () => {
  const makeObservation = ({source, resultKind}) => {
    const thread = threadRef(`read-thread-${source.codexSourceId}`, source);
    const subjectScope = subject(thread);
    const isIndex = resultKind === 'TURN_INDEX';
    const turns = [0, 1].map((offset) => {
      const turn = turnRef(`read-turn-${offset + 1}`, thread);
      return {
        turnRef: turn,
        turnOrdinal: -4 + offset,
        predecessorTurnRef: null,
      };
    });
    // Build the predecessor links after the array is allocated so this
    // fixture remains relational and does not depend on a sample turn name.
    for (let index = 1; index < turns.length; index += 1) turns[index].predecessorTurnRef = turns[index - 1].turnRef;
    const orderedTurnIndexes = turns;
    const orderedTurns = turns.slice(0, 1).map((turnIndex) => {
      const item = textItem({
        thread,
        turn: turnIndex.turnRef,
        id: 'read-item-1',
        turnOrdinal: turnIndex.turnOrdinal,
        timelineOrdinal: -4,
        itemOrdinal: 0,
        text: 'resolved',
      });
      const turnSpine = {
        ...turnIndex,
        firstTimelineOrdinal: item.timelineOrdinal,
        lastTimelineOrdinal: item.timelineOrdinal,
        itemCount: 1,
      };
      return {
        turnSpine,
        providerReportedItemCount: 1,
        observedTurnByteCount: String(canonicalUtf8({turnRef: turnIndex.turnRef, orderedItems: [item]}).byteLength),
        maximumTurnByteCount: MAX_PROVIDER_TURN_BYTES,
        orderedItems: [item],
      };
    });
    const spec = readSpec({
      sourcePartition: source,
      subjectScope,
      thread,
      itemsView: isIndex ? 'notLoaded' : 'full',
      limit: isIndex ? 2 : 1,
      cursor: null,
    });
    const evidence = readEvidence({
      sourceEpoch: epoch({sourcePartition: source, sourceEpoch: 2, providerInstanceEpoch: 3}),
      spec,
      resultKind,
      orderedTurnIndexes: isIndex ? orderedTurnIndexes : [],
      orderedTurns: isIndex ? [] : orderedTurns,
      resultCount: isIndex ? orderedTurnIndexes.length : orderedTurns.length,
    });
    const normalizedResult = {
      digestDomain: 'ccpocket.timeline-provider-read-result.v1',
      resultKind,
      sourcePartition: source,
      subjectScope,
      readPlanDigest: spec.readPlanDigest,
      readSpecDigest: spec.readSpecDigest,
      returnedCursor: null,
      resultCount: isIndex ? orderedTurnIndexes.length : orderedTurns.length,
      ...(isIndex ? {orderedTurnIndexes} : {orderedTurns}),
    };
    return {evidence, normalizedResult};
  };

  for (const [index, resultKind] of ['TURN_INDEX', 'FULL_TURNS'].entries()) {
    const source = {
      bridgeIdentityId: `read-bridge-${index}`,
      bridgeInstanceId: `read-instance-${index}`,
      codexSourceId: `read-codex-${index}`,
    };
    const observation = makeObservation({source, resultKind});
    expectApplied(observation, 'timeline.read-evidence');
    for (const mutate of [
      (copy) => { copy.normalizedResult.resultCount += 1; },
      (copy) => { copy.normalizedResult.sourcePartition = {...source, codexSourceId: 'different'}; },
      (copy) => { copy.evidence.readBody.resultDigest = '0'.repeat(64); },
      (copy) => { copy.normalizedResult.readPlanDigest = '0'.repeat(64); },
      (copy) => {
        if (copy.normalizedResult.resultKind === 'FULL_TURNS') copy.normalizedResult.orderedTurns[0].turnSpine.turnOrdinal += 1;
        else copy.normalizedResult.orderedTurnIndexes[0].turnOrdinal += 1;
      },
      (copy) => { copy.untrusted = true; },
    ]) {
      const changed = structuredClone(observation);
      mutate(changed);
      expectRejected(changed, 'timeline.read-evidence', 'PROVIDER_METHOD_NOT_SUPPORTED');
    }
  }

  const source = {bridgeIdentityId: 'oversized-bridge', bridgeInstanceId: 'oversized-instance', codexSourceId: 'oversized-codex'};
  const thread = threadRef('oversized-read-thread', source);
  const subjectScope = subject(thread);
  const turnIndexes = [0, 1].map((offset) => ({
    turnRef: turnRef(`oversized-turn-${offset + 1}`, thread),
    turnOrdinal: offset - 2,
    predecessorTurnRef: offset === 0 ? null : null,
  }));
  turnIndexes[1].predecessorTurnRef = turnIndexes[0].turnRef;
  const priorSpec = readSpec({sourcePartition: source, subjectScope, thread, itemsView: 'notLoaded', limit: 2, cursor: 'index-cursor'});
  const priorEvidence = readEvidence({
    readEvidenceId: 'oversized-index-evidence',
    sourceEpoch: epoch({sourcePartition: source, sourceEpoch: 3, providerInstanceEpoch: 4}),
    spec: priorSpec,
    resultKind: 'TURN_INDEX',
    orderedTurnIndexes: turnIndexes,
    resultCount: turnIndexes.length,
  });
  const priorResult = {
    digestDomain: 'ccpocket.timeline-provider-read-result.v1',
    resultKind: 'TURN_INDEX',
    sourcePartition: source,
    subjectScope,
    readPlanDigest: priorSpec.readPlanDigest,
    readSpecDigest: priorSpec.readSpecDigest,
    returnedCursor: null,
    resultCount: turnIndexes.length,
    orderedTurnIndexes: turnIndexes,
  };
  const oversizedTurn = {
    turnIndex: turnIndexes[1],
    providerReportedItemCount: 12,
    observedTurnByteCount: String(MAX_PROVIDER_TURN_BYTES + 1),
    maximumTurnByteCount: MAX_PROVIDER_TURN_BYTES,
    indexReadEvidenceId: priorEvidence.readEvidenceId,
    indexReadEvidenceDigest: priorEvidence.readEvidenceDigest,
  };
  const currentSpec = readSpec({sourcePartition: source, subjectScope, thread, itemsView: 'full', limit: 1, cursor: 'full-cursor'});
  const currentEvidence = readEvidence({
    readEvidenceId: 'oversized-full-evidence',
    sourceEpoch: epoch({sourcePartition: source, sourceEpoch: 3, providerInstanceEpoch: 4}),
    spec: currentSpec,
    resultKind: 'OVERSIZED_TURN',
    oversizedTurn,
    readGeneration: 2,
    resultCount: 1,
  });
  const currentResult = {
    digestDomain: 'ccpocket.timeline-provider-read-result.v1',
    resultKind: 'OVERSIZED_TURN',
    sourcePartition: source,
    subjectScope,
    readPlanDigest: currentSpec.readPlanDigest,
    readSpecDigest: currentSpec.readSpecDigest,
    returnedCursor: null,
    resultCount: 1,
    oversizedTurn,
  };
  const oversizedObservation = {
    evidence: currentEvidence,
    normalizedResult: currentResult,
    priorIndexEvidence: {evidence: priorEvidence, normalizedResult: priorResult},
  };
  expectApplied(oversizedObservation, 'timeline.read-evidence');
  for (const mutate of [
    (copy) => { copy.priorIndexEvidence.normalizedResult.orderedTurnIndexes.pop(); },
    (copy) => { copy.evidence.readBody.readGeneration = copy.priorIndexEvidence.evidence.readBody.readGeneration; },
    (copy) => { copy.normalizedResult.oversizedTurn.observedTurnByteCount = String(MAX_PROVIDER_TURN_BYTES + 2); },
    (copy) => { copy.priorIndexEvidence.evidence.readBody.itemsView = 'full'; },
    (copy) => { copy.normalizedResult.oversizedTurn.indexReadEvidenceId = 'different-index-evidence'; },
    (copy) => { copy.normalizedResult.oversizedTurn.indexReadEvidenceDigest = '0'.repeat(64); },
    (copy) => { copy.priorIndexEvidence.extra = true; },
  ]) {
    const changed = structuredClone(oversizedObservation);
    mutate(changed);
    expectRejected(changed, 'timeline.read-evidence', 'PROVIDER_METHOD_NOT_SUPPORTED');
  }
});

test('materialization is a closed relational page-chain with independent field mutations', () => {
  expectApplied(materialization({pageCountOverride: 1}), 'timeline.materialization');
  expectApplied(materialization({pageCountOverride: 2, indexOnly: true}), 'timeline.materialization');
  expectApplied(materialization({empty: true}), 'timeline.materialization');
  const mutations = [
    ['page count upper bound', material => { material.commit.pageCount = 129; }],
    ['begin page count fence', material => { material.beginFrame.pageCount = 1; }],
    ['item count', material => { material.commit.itemCount += 1; }],
    ['page digest', material => { material.pages[0].pageDigest = '0'.repeat(64); }],
    ['previous page digest', material => { material.pages[1].previousPageDigest = '0'.repeat(64); }],
    ['order digest', material => { material.commit.orderDigest = '0'.repeat(64); }],
    ['coverage digest', material => { material.commit.coverageDigest = '0'.repeat(64); }],
    ['manifest digest', material => { material.beginFrame.block = {...material.beginFrame.block, manifestDigest: '0'.repeat(64)}; }],
    ['begin header digest', material => { material.beginFrame.begin.beginHeaderDigest = '0'.repeat(64); }],
    ['receipt digest', material => { material.commit.receiptDigest = '0'.repeat(64); }],
    ['page stream sequence', material => { material.pages[0].message.streamSeq += 1; }],
    ['page message role', material => { material.pages[0].message.blockRole = 'COMMIT'; }],
    ['page stream identity', material => { material.pages[0].message.streamId = ''; }],
    ['page source partition', material => { material.pages[0].sourcePartition = {...material.pages[0].sourcePartition, codexSourceId: 'other-codex'}; }],
    ['read result count', material => { material.beginFrame.begin.payload.readBody.resultCount += 1; }],
    ['read evidence digest', material => { material.beginFrame.begin.preimage.payload.readEvidenceDigest = '0'.repeat(64); }],
    ['bound proof digest', material => { const proofRow = material.pages.flatMap((page) => page.body.items).find((row) => row.rowKind === 'BOUND_ORDER_PROOF'); if (proofRow) proofRow.boundOrderProof.proofDigest = '0'.repeat(64); else material.pages[0].body.items[0].coverageIsland.islandOrdinal = 9; }],
    ['last-good disposition', material => { material.commit.lastGoodDisposition = {disposition: 'PREVIOUS_HEAD_RETAINED', previousSubject: material.commit.subject, previousHeadVersion: 1}; }],
    ['page body extra authority', material => { material.pages[0].body.turns = []; }],
  ];
  for (const [name, mutate, reason = 'TIMELINE_ORDER_GAP_INVALID'] of mutations) {
    const changed = structuredClone(materialization({pageCountOverride: 2, indexOnly: true}));
    mutate(changed);
    expectRejected(changed, 'timeline.materialization', reason);
  }
  const sparsePayload = structuredClone(materialization());
  const sparseItem = sparsePayload.pages[0].body.items.find((row) => row.rowKind === 'TIMELINE_ITEM').timelineItem;
  sparseItem.payloads.length = 2;
  delete sparseItem.payloads[1];
  expectRejected(sparsePayload, 'timeline.materialization', 'TIMELINE_ORDER_GAP_INVALID');

  const gapMutationCases = [
    ['gap ordinal', material => { material.pages[0].body.gaps[0].gapOrdinal = 1; }],
    ['gap identity', material => { material.pages[0].body.gaps[0].gapId = 'random-gap'; }],
    ['gap target', material => { material.pages[0].body.gaps[0].target = {...material.pages[0].body.gaps[0].target, rightBoundary: material.pages[0].body.gaps[0].target.leftBoundary}; }],
    ['repair materialization identity', material => { material.pages[0].body.gaps[0].repairIntent.materializationId = 'forbidden'; }],
    ['repair digest', material => { material.pages[0].body.gaps[0].repairIntent.repairIntentDigest = '0'.repeat(64); }],
  ];
  for (const [name, mutate] of gapMutationCases) {
    const changed = structuredClone(materialization({withBetweenGap: true}));
    mutate(changed);
    expectRejected(changed, 'timeline.materialization', 'TIMELINE_ORDER_GAP_INVALID');
  }
});

test('coverage preimage uses one byte-exact island pair representation', () => {
  const snapshot = materialization({itemsPerTurn: 2});
  const island = snapshot.pages[0].body.items.find((row) => row.rowKind === 'COVERAGE_ISLAND').coverageIsland;
  const pair = coverageOrderedIsland(0, island);
  assert.deepEqual(coveragePreimage({islandOrdinal: 0, island}), pair);
  const clone = coverageOrderedIsland(0, structuredClone(island));
  assert.deepEqual([...canonicalUtf8(pair)], [...canonicalUtf8(clone)]);
  assert.throws(() => coveragePreimage({islandOrdinal: 0, island, extra: true}), /exactly/);
  assert.throws(() => coverageOrderedIsland(1, island), /exactly match/);
  assert.throws(() => coverageOrderedIsland(0, {...island, islandOrdinal: 1}), /exactly match/);
  expectApplied(snapshot, 'timeline.materialization');
});

test('materialization resolves independent authority and exhaustively consumes result positions', () => {
  const snapshot = materialization({itemsPerTurn: 2});
  expectApplied(snapshot, 'timeline.materialization');
  assert.deepEqual(evaluateMaterializationAuthority({
    authority: snapshot.authority,
    sourcePartition: snapshot.beginFrame.sourcePartition,
    subjectScope: snapshot.beginFrame.subject,
  }), {valid: true, reason: 'NONE', postState: 'APPLIED', sideEffects: {}});

  const missingAuthority = structuredClone(snapshot);
  delete missingAuthority.authority;
  assert.equal(evaluateMaterializationAuthority({
    authority: missingAuthority.authority,
    sourcePartition: snapshot.beginFrame.sourcePartition,
    subjectScope: snapshot.beginFrame.subject,
  }).valid, false);

  const pageForged = structuredClone(snapshot);
  const forgedItem = pageForged.pages[0].body.items.find((row) => row.rowKind === 'TIMELINE_ITEM').timelineItem;
  forgedItem.payloads[0].text = 'candidate-page-only';
  expectRejected(pageForged, 'timeline.materialization', 'TIMELINE_ORDER_GAP_INVALID');

  for (const mutate of [
    (copy) => { copy.authority.readPlan.readPlanDigest = '0'.repeat(64); },
    (copy) => { copy.authority.readSpec.cursor = 'candidate-only'; },
    (copy) => { copy.authority.normalizedResult.orderedTurns[0].orderedItems[1].timelineOrdinal += 2; },
    (copy) => { copy.authority.certification.schemaDigest = '0'.repeat(64); },
    (copy) => { copy.authority.probeEvidence.runtime['thread/items/list'] = 'AVAILABLE'; },
  ]) {
    const changed = structuredClone(snapshot);
    mutate(changed);
    expectRejected(changed, 'timeline.materialization', 'TIMELINE_ORDER_GAP_INVALID');
  }
  const certification = codexAdapterCertification({sourcePartition: snapshot.beginFrame.sourcePartition});
  assert.equal(certification.codexCertificationDigest, jcsDigest(codexAdapterCertificationPreimage()));
  assert.equal(codexAdapterCertification({sourcePartition: {...snapshot.beginFrame.sourcePartition, codexSourceId: 'other'}}).codexCertificationDigest, certification.codexCertificationDigest);
  assert.equal(codexAdapterProbeFacts().runtime['thread/items/list'], 'RUNTIME_UNAVAILABLE');
});

test('item incoming proofs use orderedItems[-2] to orderedItems[-1] only', () => {
  const snapshot = materialization({itemsPerTurn: 2});
  expectApplied(snapshot, 'timeline.materialization');
  const proofRow = snapshot.pages[0].body.items.find((row) => row.rowKind === 'BOUND_ORDER_PROOF');
  assert.equal(proofRow.boundOrderProof.sealedProof.fromPosition.itemIndex, 0);
  assert.equal(proofRow.boundOrderProof.sealedProof.toPosition.itemIndex, 1);
  assert.equal(proofRow.boundOrderProof.from.itemRef.itemId, 'item-1-1');
  assert.equal(proofRow.boundOrderProof.to.itemRef.itemId, 'item-1-2');

  const reverse = structuredClone(snapshot);
  const reverseProof = reverse.pages[0].body.items.find((row) => row.rowKind === 'BOUND_ORDER_PROOF').boundOrderProof;
  const reverseItems = reverse.pages[0].body.items.filter((row) => row.rowKind === 'TIMELINE_ITEM').map((row) => row.timelineItem);
  reverseProof.from = reverseProof.to;
  reverseProof.to = {
    endpointKind: 'ITEM',
    itemRef: reverseItems[0].itemRef,
    timelineOrdinal: reverseItems[0].timelineOrdinal,
  };
  reverseProof.proofDigest = jcsDigest(Object.fromEntries(Object.entries(reverseProof).filter(([key]) => key !== 'proofDigest')));
  expectRejected(reverse, 'timeline.materialization', 'TIMELINE_ORDER_GAP_INVALID');

  const crossTurn = structuredClone(snapshot);
  const crossProof = crossTurn.pages[0].body.items.find((row) => row.rowKind === 'BOUND_ORDER_PROOF').boundOrderProof;
  crossProof.from = {...crossProof.from, itemRef: {...crossProof.from.itemRef, turnRef: turnRef('other-turn', threadRef())}};
  crossProof.proofDigest = jcsDigest(Object.fromEntries(Object.entries(crossProof).filter(([key]) => key !== 'proofDigest')));
  expectRejected(crossTurn, 'timeline.materialization', 'TIMELINE_ORDER_GAP_INVALID');
});

test('INDEX payload gaps are a bidirectional relation and repair tuples are sealed', () => {
  const indexed = materialization({indexOnly: true, groupTurns: true, itemCountOverride: 2});
  expectApplied(indexed, 'timeline.materialization');
  const gaps = indexed.pages.flatMap((page) => page.body.gaps);
  assert.equal(gaps.length, 2);
  assert.deepEqual(gaps.map((gap) => gap.target.targetKind), ['TURN_PAYLOAD_NOT_LOADED', 'TURN_PAYLOAD_NOT_LOADED']);

  const missingGap = structuredClone(indexed);
  missingGap.pages[0].body.gaps.pop();
  expectRejected(missingGap, 'timeline.materialization', 'TIMELINE_ORDER_GAP_INVALID');

  const full = materialization();
  const invalidTurnGap = structuredClone(gaps[0]);
  invalidTurnGap.gapOrdinal = 0;
  full.pages[0].body.gaps.push(invalidTurnGap);
  expectRejected(full, 'timeline.materialization', 'TIMELINE_ORDER_GAP_INVALID');

  const between = gapBetween();
  const malformed = structuredClone(between);
  malformed.reason = 'NOT_LOADED';
  malformed.repairIntent.reason = 'NOT_LOADED';
  malformed.repairIntent.repairKind = 'NEXT_PROVIDER_PAGE';
  malformed.repairIntent.repairDisposition = 'REPAIRABLE_WITH_CURRENT_PROVIDER_API';
  const {repairIntentDigest: _digest, ...intentPreimage} = malformed.repairIntent;
  malformed.repairIntent.repairIntentDigest = jcsDigest(intentPreimage);
  expectRejected(malformed, 'timeline.order-gap', 'TIMELINE_ORDER_GAP_INVALID');
});

test('typed empty proof binds only the current read evidence and begin digest', () => {
  const empty = materialization({empty: true});
  expectApplied(empty, 'timeline.typed-empty');
  const changed = structuredClone(empty);
  changed.beginFrame.begin.preimage.payload.emptyProof.readEvidenceDigest = '0'.repeat(64);
  expectRejected(changed, 'timeline.typed-empty', 'TIMELINE_EMPTY_PROOF_INVALID');
  expectRejected(changed, 'timeline.materialization', 'TIMELINE_ORDER_GAP_INVALID');
});

function bodyAtSize(target) {
  const body = structuredClone(materialization().pages[0].body);
  const row = body.items.find((candidate) => candidate.rowKind === 'TIMELINE_ITEM');
  let low = 0;
  let high = target + 16;
  while (low <= high) {
    const mid = Math.floor((low + high) / 2);
    row.timelineItem.payloads[0].text = 'x'.repeat(mid);
    const size = canonicalPageBodyBytes(body);
    if (size === target) return body;
    if (size < target) low = mid + 1;
    else high = mid - 1;
  }
  assert.fail(`unable to construct body of ${target} bytes`);
}

test('exact provider/page/control boundaries are enforced', () => {
  const normalBody = materialization().pages[0].body;
  expectApplied(normalBody, 'timeline.page-size');
  expectApplied(bodyAtSize(MAX_PUBLICATION_PAGE_BYTES), 'timeline.page-size');
  expectRejected(bodyAtSize(MAX_PUBLICATION_PAGE_BYTES + 1), 'timeline.page-size', 'TIMELINE_PAGE_BODY_TOO_LARGE');
  const sparseBody = structuredClone(normalBody);
  delete sparseBody.items[0];
  expectRejected(sparseBody, 'timeline.page-size', 'TIMELINE_PAGE_BODY_TOO_LARGE');
  const extraBody = structuredClone(normalBody);
  extraBody.untrusted = true;
  expectRejected(extraBody, 'timeline.page-size', 'TIMELINE_PAGE_BODY_TOO_LARGE');

  assert.deepEqual(evaluateRawWireBoundary({payloadBytes: MAX_CONTROL_PAYLOAD_BYTES, frameBytes: MAX_CONTROL_FRAME_BYTES}), {valid: true, reason: 'NONE', postState: 'APPLIED', sideEffects: {}});
  assert.deepEqual(evaluateRawWireBoundary({payloadBytes: MAX_CONTROL_PAYLOAD_BYTES + 1, frameBytes: MAX_CONTROL_FRAME_BYTES}), {valid: false, reason: 'WIRE_SHAPE_INVALID', postState: 'UNCHANGED', sideEffects: ZERO_BY_ORACLE['wire.closed-normalized-shape']});
  assert.deepEqual(evaluateRawWireBoundary({payloadBytes: MAX_CONTROL_PAYLOAD_BYTES, frameBytes: MAX_CONTROL_FRAME_BYTES + 1}), {valid: false, reason: 'WIRE_SHAPE_INVALID', postState: 'UNCHANGED', sideEffects: ZERO_BY_ORACLE['wire.closed-normalized-shape']});
  assert.deepEqual(evaluateRawWireBoundary({payloadBytes: 0, rawBytes: new Uint8Array(MAX_CONTROL_FRAME_BYTES)}), {valid: true, reason: 'NONE', postState: 'APPLIED', sideEffects: {}});
  const rawOver = evaluateRawWireBoundary({payloadBytes: 0, rawBytes: new Uint8Array(MAX_CONTROL_FRAME_BYTES + 1)});
  assert.equal(rawOver.valid, false);
  assert.equal(rawOver.reason, 'WIRE_SHAPE_INVALID');
  assert.deepEqual({...rawOver.sideEffects}, ZERO_BY_ORACLE['wire.closed-normalized-shape']);
  const fakeRaw = evaluateRawWireBoundary({payloadBytes: 0, rawBytes: {byteLength: MAX_CONTROL_FRAME_BYTES}});
  assert.equal(fakeRaw.valid, false);
  assert.deepEqual({...fakeRaw.sideEffects}, ZERO_BY_ORACLE['wire.closed-normalized-shape']);

  assert.deepEqual(evaluateProviderTurnBoundary({byteLength: MAX_PROVIDER_TURN_BYTES}), {valid: true, reason: 'NONE', postState: 'APPLIED', sideEffects: {}});
  assert.deepEqual(evaluateProviderTurnBoundary({byteLength: MAX_PROVIDER_TURN_BYTES + 1}), {valid: false, reason: 'TURN_PAYLOAD_OVERSIZED', postState: 'UNCHANGED', sideEffects: ZERO_BY_ORACLE['timeline.materialization']});
  const oversizedTurn = turnRef('oversized-turn', threadRef('oversized-thread', SOURCE));
  const oversizedIdentity = {turnRef: oversizedTurn, turnOrdinal: -1};
  const oversizedGap = {
    targetKind: 'TURN_PAYLOAD_OVERSIZED',
    turnRef: oversizedTurn,
    turnOrdinal: -1,
    observedTurnByteCount: String(MAX_PROVIDER_TURN_BYTES + 1),
    maximumTurnByteCount: MAX_PROVIDER_TURN_BYTES,
  };
  assert.deepEqual(evaluateProviderTurnBoundary({byteLength: MAX_PROVIDER_TURN_BYTES + 1, turnIdentity: oversizedIdentity, oversizedGap}), {valid: true, reason: 'NONE', postState: 'APPLIED', sideEffects: {}});
  const missingRelation = evaluateProviderTurnBoundary({byteLength: MAX_PROVIDER_TURN_BYTES + 1, turnIdentity: oversizedIdentity});
  assert.deepEqual({...missingRelation.sideEffects}, ZERO_BY_ORACLE['timeline.materialization']);
  assert.equal(missingRelation.reason, 'TURN_PAYLOAD_OVERSIZED');
});

test('inline text capacity has an exact 40960/40961 seam', () => {
  const textPayload = (size) => {
    const overhead = canonicalUtf8({kind: 'text', text: ''}).byteLength;
    return {kind: 'text', text: 'x'.repeat(size - overhead)};
  };
  const escapedTextPayload = (size) => {
    const seed = 'quote=" slash=\\ newline=\n tab=\t control=\u0001';
    const seedBytes = canonicalUtf8({kind: 'text', text: seed}).byteLength;
    return {kind: 'text', text: seed + 'x'.repeat(size - seedBytes)};
  };
  const summaryPayload = (size) => {
    const overhead = canonicalUtf8({kind: 'tool_summary', toolName: '', summary: ''}).byteLength;
    return {kind: 'tool_summary', toolName: '', summary: 'x'.repeat(size - overhead)};
  };
  const escapedSummaryPayload = (size) => {
    const toolName = 'tool="\\\n\t\u0001';
    const seedBytes = canonicalUtf8({kind: 'tool_summary', toolName, summary: ''}).byteLength;
    return {kind: 'tool_summary', toolName, summary: 'x'.repeat(size - seedBytes)};
  };
  for (const payload of [textPayload(MAX_INLINE_TEXT_BYTES), escapedTextPayload(MAX_INLINE_TEXT_BYTES), summaryPayload(MAX_INLINE_TEXT_BYTES), escapedSummaryPayload(MAX_INLINE_TEXT_BYTES)]) {
    assert.equal(canonicalUtf8(payload).byteLength, MAX_INLINE_TEXT_BYTES);
    expectApplied(materialization({payloadsOverride: () => [payload]}), 'timeline.materialization');
  }
  for (const payload of [textPayload(MAX_INLINE_TEXT_BYTES + 1), escapedTextPayload(MAX_INLINE_TEXT_BYTES + 1), summaryPayload(MAX_INLINE_TEXT_BYTES + 1), escapedSummaryPayload(MAX_INLINE_TEXT_BYTES + 1)]) {
    assert.equal(canonicalUtf8(payload).byteLength, MAX_INLINE_TEXT_BYTES + 1);
    const snapshot = materialization({payloadsOverride: () => [payload]});
    expectApplied(snapshot, 'timeline.materialization');
    const item = snapshot.pages[0].body.items.find((row) => row.rowKind === 'TIMELINE_ITEM').timelineItem;
    assert.deepEqual(item.payloads[0], {kind: 'unavailable', payloadDigest: payloadCommitment(payload, 0), missingField: 'resolvedPayload'});
    const gap = snapshot.pages[0].body.gaps.find((candidate) => candidate.target.targetKind === 'PAYLOAD');
    assert.equal(gap.reason, 'CAPACITY_BOUNDARY');
    assert.equal(gap.repairIntent.repairKind, 'NONE');
  }
});

test('dominance compares stable relational facts, not materialization ids or raw Sets', () => {
  const current = materialization({materializationId: 'container-a', indexOnly: true, itemCountOverride: 1});
  const equal = materialization({materializationId: 'container-b', indexOnly: true, itemCountOverride: 1});
  expectApplied({current, candidate: equal}, 'timeline.last-good');

  const superset = materialization({materializationId: 'container-c', indexOnly: true, groupTurns: true, itemCountOverride: 2});
  expectApplied({current, candidate: superset}, 'timeline.last-good');

  const replacement = materialization({materializationId: 'container-d', thread: threadRef('other-thread', SOURCE)});
  expectRejected({current, candidate: replacement}, 'timeline.last-good', 'TIMELINE_LAST_GOOD_REGRESSION');

  const reordered = materialization({materializationId: 'container-e', turnOrdinalOverride: 10});
  expectRejected({current, candidate: reordered}, 'timeline.last-good', 'TIMELINE_LAST_GOOD_REGRESSION');

  const downgraded = materialization({materializationId: 'container-f', empty: true});
  expectRejected({current, candidate: downgraded}, 'timeline.last-good', 'TIMELINE_LAST_GOOD_REGRESSION');
});

test('only exact provider-position INDEX refinement can widen a last-good Turn', () => {
  const indexed = materialization({materializationId: 'refine-index', indexOnly: true, itemCountOverride: 1});
  const full = materialization({materializationId: 'refine-full', itemCountOverride: 1});
  expectApplied({current: indexed, candidate: full}, 'timeline.last-good');

  const reverse = materialization({materializationId: 'refine-reverse', indexOnly: true, itemCountOverride: 1});
  expectRejected({current: full, candidate: reverse}, 'timeline.last-good', 'TIMELINE_LAST_GOOD_REGRESSION');

  const missingAuthority = materialization({materializationId: 'refine-no-authority', itemCountOverride: 1});
  delete missingAuthority.authority;
  expectRejected({current: indexed, candidate: missingAuthority}, 'timeline.last-good', 'TIMELINE_LAST_GOOD_REGRESSION');

  const wrongPosition = materialization({materializationId: 'refine-wrong-position', itemCountOverride: 1});
  wrongPosition.authority.normalizedResult.orderedTurns[0].turnSpine.turnOrdinal = 1;
  expectRejected({current: indexed, candidate: wrongPosition}, 'timeline.last-good', 'TIMELINE_LAST_GOOD_REGRESSION');
});

test('INDEX to oversized refinement is exact, one-position, and non-reversible', () => {
  const indexed = materialization({materializationId: 'oversized-index', indexOnly: true, itemCountOverride: 1});
  const oversized = materialization({materializationId: 'oversized-refined', oversized: true, itemCountOverride: 1});
  expectApplied({current: indexed, candidate: oversized}, 'timeline.last-good');

  const reverse = structuredClone({current: oversized, candidate: indexed});
  expectRejected(reverse, 'timeline.last-good', 'TIMELINE_LAST_GOOD_REGRESSION');

  const wrongPosition = structuredClone(oversized);
  wrongPosition.authority.normalizedResult.oversizedTurn.turnIndex.turnOrdinal += 1;
  expectRejected({current: indexed, candidate: wrongPosition}, 'timeline.last-good', 'TIMELINE_LAST_GOOD_REGRESSION');

  const wrongEvidence = structuredClone(oversized);
  wrongEvidence.authority.normalizedResult.oversizedTurn.indexReadEvidenceId = 'wrong-index-evidence';
  expectRejected({current: indexed, candidate: wrongEvidence}, 'timeline.last-good', 'TIMELINE_LAST_GOOD_REGRESSION');
});

test('cache reuse binds the closed query and materialization identity', () => {
  expectApplied(cacheObservation({sourcePartition: SOURCE, materializationId: 'cache-a'}), 'timeline.cache-reuse');
  for (const mutate of [
    (copy) => { copy.query.untrusted = true; },
    (copy) => { copy.cacheEntryId = 'cache-b'; },
  ]) {
    const changed = structuredClone(cacheObservation({sourcePartition: SOURCE, materializationId: 'cache-a'}));
    mutate(changed);
    expectRejected(changed, 'timeline.cache-reuse', 'CACHE_REUSE_VIOLATION');
  }
});

test('payload commitments bind dense index and permit only atomic unavailable reveal', () => {
  const resolved = {kind: 'text', text: 'late payload'};
  const commitment = payloadCommitment(resolved, 1);
  const partial = materialization({
    materializationId: 'payload-old',
    payloadGap: true,
    payloadsOverride: () => [{kind: 'text', text: 'hello'}, unavailablePayload(commitment)],
  });
  const complete = materialization({
    materializationId: 'payload-new',
    payloadsOverride: () => [{kind: 'text', text: 'hello'}, resolved],
  });
  expectApplied({current: partial, candidate: complete}, 'timeline.last-good');

  const changed = structuredClone(complete);
  changed.pages[0].body.items.find((row) => row.rowKind === 'TIMELINE_ITEM').timelineItem.payloads[1].text = 'tampered';
  expectRejected({current: partial, candidate: changed}, 'timeline.last-good', 'TIMELINE_LAST_GOOD_REGRESSION');

  const wrongIndex = materialization({
    materializationId: 'payload-wrong-index',
    payloadsOverride: () => [{kind: 'text', text: 'late payload'}, {kind: 'text', text: 'hello'}],
  });
  expectRejected({current: partial, candidate: wrongIndex}, 'timeline.last-good', 'TIMELINE_LAST_GOOD_REGRESSION');
});

test('provider-page proof binds typed positions to the normalized index result', () => {
  const snapshot = materialization({materializationId: 'proof-index', indexOnly: true, groupTurns: true, itemCountOverride: 2});
  expectApplied(snapshot, 'timeline.materialization');
  const proofRow = snapshot.pages[0].body.items.find((row) => row.rowKind === 'BOUND_ORDER_PROOF');
  assert.ok(proofRow, 'fixture must contain one bound provider proof');
  for (const mutate of [
    proof => { proof.sealedProof.fromPosition.turnIndex = 1; },
    proof => { proof.sealedProof.toPosition.turnIndex = 0; },
    proof => { proof.from.turnOrdinal = 99; },
    proof => { proof.to.turnRef.turnId = 'turn-other'; },
  ]) {
    const changed = structuredClone(snapshot);
    mutate(changed.pages[0].body.items.find((row) => row.rowKind === 'BOUND_ORDER_PROOF').boundOrderProof);
    expectRejected(changed, 'timeline.materialization', 'TIMELINE_ORDER_GAP_INVALID');
  }
});

test('canonical predecessor binds a verified base head through a post-derivation edge', () => {
  const source = {
    bridgeIdentityId: 'pred-bridge',
    bridgeInstanceId: 'pred-instance',
    codexSourceId: 'pred-codex',
  };
  const thread = threadRef('pred-thread', source);
  const base = materialization({
    thread,
    materializationId: 'pred-base',
    indexOnly: true,
    groupTurns: true,
    itemCountOverride: 1,
    sourceEpoch: epoch({sourcePartition: source, sourceEpoch: 7, providerInstanceEpoch: 8}),
    turnOrdinalOverride: Number.MIN_SAFE_INTEGER,
    timelineOrdinalOverride: Number.MIN_SAFE_INTEGER,
  });
  const candidate = materialization({
    thread,
    materializationId: 'pred-candidate',
    indexOnly: true,
    groupTurns: true,
    itemCountOverride: 2,
    baseHeadVersion: 1,
    proofKind: 'CANONICAL_PREDECESSOR',
    baseSubject: base.beginFrame.block.subject,
    baseManifestDigest: base.beginFrame.block.manifestDigest,
    sourceEpoch: epoch({sourcePartition: source, sourceEpoch: 7, providerInstanceEpoch: 8}),
    turnOrdinalOverride: Number.MIN_SAFE_INTEGER,
    timelineOrdinalOverride: Number.MIN_SAFE_INTEGER,
  });
  const proof = candidate.pages.flatMap((page) => page.body.items)
    .find((row) => row.rowKind === 'BOUND_ORDER_PROOF').boundOrderProof;
  const edge = {
    edgeKind: 'PREDECESSOR_REFERENCE',
    relationMode: 'REFERENCE_EQUALITY',
    current: {
      proofDigest: proof.proofDigest,
      sourcePartition: candidate.beginFrame.sourcePartition,
      subject: candidate.beginFrame.block.subject,
      headVersion: candidate.commit.candidateHeadVersion,
      manifestDigest: candidate.beginFrame.block.manifestDigest,
    },
    base: {
      sourcePartition: base.beginFrame.sourcePartition,
      subject: base.beginFrame.block.subject,
      headVersion: base.commit.candidateHeadVersion,
      manifestDigest: base.beginFrame.block.manifestDigest,
    },
  };
  expectRejected(candidate, 'timeline.materialization', 'TIMELINE_ORDER_GAP_INVALID');
  expectApplied({base, candidate, edge, currentLastGood: base, materializationPath: {predecessorReferenceEdge: edge}}, 'timeline.last-good');
  expectRejected({base, candidate, edge, materializationPath: {predecessorReferenceEdge: edge}}, 'timeline.last-good', 'TIMELINE_LAST_GOOD_REGRESSION');
  assert.deepEqual(evaluatePredecessorReferenceGraph({edges: [edge]}), {valid: true, reason: 'NONE', postState: 'APPLIED', sideEffects: {}});

  // Each mutation changes one independently bound relation.  In particular,
  // current.manifestDigest is a POST_DERIVATION_VALIDATION_ONLY guard: it is
  // not part of proofDigest, but a false equality still rejects the edge.
  const mutations = [
    ['edge proof digest', (copy) => { copy.edge.current.proofDigest = '0'.repeat(64); }],
    ['edge current manifest', (copy) => { copy.edge.current.manifestDigest = '0'.repeat(64); }],
    ['edge current head', (copy) => { copy.edge.current.headVersion -= 1; }],
    ['edge base manifest', (copy) => { copy.edge.base.manifestDigest = '0'.repeat(64); }],
    ['edge base source', (copy) => { copy.edge.base.sourcePartition = {...source, codexSourceId: 'other-codex'}; }],
    ['edge base subject', (copy) => { copy.edge.base.subject.materializationId = 'other-base'; }],
    ['edge relation mode', (copy) => { copy.edge.relationMode = 'DIGEST_EQUALITY'; }],
    ['candidate predecessor subject', (copy) => { copy.candidate.commit.lastGoodDisposition.previousSubject.materializationId = 'wrong-base'; }],
    ['candidate proof base digest', (copy) => {
      copy.candidate.pages.flatMap((page) => page.body.items)
        .find((row) => row.rowKind === 'BOUND_ORDER_PROOF').boundOrderProof.sealedProof.baseManifestDigest = '0'.repeat(64);
    }],
    ['candidate predecessor endpoint', (copy) => {
      copy.candidate.pages.flatMap((page) => page.body.items)
        .find((row) => row.rowKind === 'BOUND_ORDER_PROOF').boundOrderProof.from.turnOrdinal += 1;
    }],
    ['edge extra field', (copy) => { copy.edge.untrusted = true; }],
  ];
  for (const [name, mutate] of mutations) {
    const changed = structuredClone({base, candidate, edge, currentLastGood: base, materializationPath: {predecessorReferenceEdge: edge}});
    mutate(changed);
    expectRejected(changed, 'timeline.last-good', 'TIMELINE_LAST_GOOD_REGRESSION');
    assert.equal(evaluateCanonicalPredecessorObservation(changed).postState, 'UNCHANGED', name);
  }
  const selfLoop = structuredClone(edge);
  selfLoop.base.subject = structuredClone(selfLoop.current.subject);
  selfLoop.base.headVersion = selfLoop.current.headVersion - 1;
  assert.equal(evaluatePredecessorReferenceGraph({edges: [selfLoop]}).valid, false);
  const reverse = structuredClone(edge);
  reverse.current.subject = structuredClone(edge.base.subject);
  reverse.current.headVersion = edge.base.headVersion;
  reverse.current.manifestDigest = edge.base.manifestDigest;
  reverse.base.subject = structuredClone(edge.current.subject);
  reverse.base.headVersion = edge.current.headVersion;
  reverse.base.manifestDigest = edge.current.manifestDigest;
  reverse.current.proofDigest = edge.current.proofDigest;
  assert.equal(evaluatePredecessorReferenceGraph({edges: [edge, reverse]}).valid, false);
  const duplicate = structuredClone(edge);
  assert.equal(evaluatePredecessorReferenceGraph({edges: [edge, duplicate]}).valid, false);
});

test('operation fingerprints are server-derived and header-independent', () => {
  for (const operationCode of ['OP-001', 'OP-002', 'OP-003', 'OP-004', 'OP-005', 'OP-006']) {
    const request = operationRequest({operationCode});
    expectApplied(request, 'operation.typed-union');
  }
  const firstRequest = operationRequest({operationCode: 'OP-001'});
  const replayRequest = structuredClone(firstRequest);
  replayRequest.header.submittedAt = '2099-01-01T00:00:00Z';
  const firstFingerprint = operationFingerprint(firstRequest);
  const replayFingerprint = operationFingerprint(replayRequest);
  assert.equal(firstFingerprint.value, replayFingerprint.value);
  expectApplied({firstRequest, replayRequest, existingOperationRef: operationRef(firstRequest), firstFingerprint, replayFingerprint}, 'operation.fingerprint');

  const changedInput = structuredClone(replayRequest);
  changedInput.input.text = 'different';
  expectRejected({firstRequest, replayRequest: changedInput, existingOperationRef: operationRef(firstRequest), firstFingerprint, replayFingerprint: operationFingerprint(changedInput)}, 'operation.fingerprint', 'OPERATION_FINGERPRINT_CONFLICT');

  const clientFingerprint = structuredClone(firstRequest);
  clientFingerprint.header.fingerprint = 'attacker-controlled';
  expectRejected(clientFingerprint, 'operation.typed-union', 'OPERATION_VARIANT_INVALID');
  const badDigest = structuredClone({firstRequest, replayRequest, existingOperationRef: operationRef(firstRequest), firstFingerprint, replayFingerprint});
  badDigest.firstFingerprint.value = badDigest.firstFingerprint.value.toUpperCase();
  expectRejected(badDigest, 'operation.fingerprint', 'OPERATION_FINGERPRINT_CONFLICT');
});

test('admission barrier and outcome-unknown form the durable recovery relation', () => {
  const reference = operationRef(operationRequest());
  expectApplied(operationDispatchObservation({reference}), 'operation.admission-barrier');
  for (const mutate of [
    (copy) => { copy.dispatchState = 'CALL_STARTED'; copy.operationState = 'ADMITTED'; },
    (copy) => { delete copy.admissionFactId; },
    (copy) => { copy.operationState = 'RECEIVED'; },
  ]) {
    const changed = operationDispatchObservation({reference});
    mutate(changed);
    expectRejected(changed, 'operation.admission-barrier', 'DURABLE_ADMISSION_REQUIRED');
  }

  const recovery = operationRecoveryObservation({reference});
  expectApplied(recovery, 'operation.outcome-unknown');
  for (const mutate of [
    (copy) => { copy.reconcileMode = 'REDISPATCH'; },
    (copy) => { copy.postCommitFactIds = [copy.attemptFactId]; },
    (copy) => { copy.postCommitFactIds = [...copy.postCommitFactIds, 'extra-fact']; },
    (copy) => { copy.deliveryEnvelopeIds = ['envelope-1']; },
    (copy) => { copy.resolutionFactId = copy.attemptFactId; },
    (copy) => { copy.operationRef.targetId = ''; },
    (copy) => { copy.extra = true; },
  ]) {
    const changed = structuredClone(recovery);
    mutate(changed);
    expectRejected(changed, 'operation.outcome-unknown', 'OUTCOME_UNKNOWN');
  }
  const sparseFacts = structuredClone(recovery);
  delete sparseFacts.postCommitFactIds[1];
  expectRejected(sparseFacts, 'operation.outcome-unknown', 'OUTCOME_UNKNOWN');
});

test('queue edit/cancel/steer/interrupt preserve lane CAS and ownership', () => {
  for (const operationCode of ['OP-002', 'OP-003', 'OP-004', 'OP-005', 'OP-006']) {
    const command = operationRequest({operationCode});
    const queueOwned = ['OP-002', 'OP-003', 'OP-005'].includes(operationCode);
    const observation = {command, currentLaneRevision: 1, currentEntryRevision: 1, ownership: queueOwned ? 'QUEUED' : 'DISPATCH_OWNED'};
    expectApplied(observation, 'queue.revision');
    const mutations = queueOwned ? [
      (copy) => { copy.currentLaneRevision = 2; },
      (copy) => { copy.currentEntryRevision = 2; },
    ] : [];
    mutations.push((copy) => { copy.ownership = queueOwned ? 'DISPATCH_OWNED' : 'QUEUED'; });
    mutations.push((copy) => { copy.command.untrusted = true; });
    for (const mutate of mutations) {
      const changed = structuredClone(observation);
      mutate(changed);
      expectRejected(changed, 'queue.revision', 'QUEUE_REVISION_CONFLICT');
    }
  }
  const sourceMismatch = {command: operationRequest({operationCode: 'OP-002'}), currentLaneRevision: 1, currentEntryRevision: 1, ownership: 'QUEUED'};
  sourceMismatch.command.header.sourcePartition = {...sourceMismatch.command.header.sourcePartition, codexSourceId: 'other-codex'};
  expectRejected(sourceMismatch, 'queue.revision', 'QUEUE_REVISION_CONFLICT');
});

function authorityFixture(kind, options = {}) {
  const fixture = interactionFixture({kind, ...options});
  return {
    authenticatedActor: fixture.snapshot.claim.actorRef,
    authenticatedEpoch: fixture.snapshot.sourceEpoch,
    snapshot: fixture.snapshot,
    command: fixture.command,
  };
}

test('all four interaction variants enforce source, actor, expiry, duplicate and response shape', () => {
  for (const kind of ['APPROVAL', 'QUESTION', 'MCP_ELICITATION', 'EXIT_PLAN']) {
    const authority = authorityFixture(kind);
    expectApplied(authority, 'interaction.source');
    expectApplied(authority, 'interaction.actor');
    expectApplied({...authority, observedAt: '2026-08-30T00:00:00Z'}, 'interaction.expiry');
    expectApplied({snapshot: authority.snapshot, firstCommand: authority.command, duplicateCommand: structuredClone(authority.command)}, 'interaction.duplicate');
    expectApplied({snapshot: authority.snapshot, command: authority.command}, 'interaction.variant');

    const sourceChanged = structuredClone(authority);
    sourceChanged.command.command.interactionRef = {...sourceChanged.command.command.interactionRef, sourcePartition: {...sourceChanged.command.command.interactionRef.sourcePartition, codexSourceId: 'other-codex'}};
    expectRejected(sourceChanged, 'interaction.source', 'INTERACTION_WRONG_SOURCE');

    const actorChanged = structuredClone(authority);
    actorChanged.authenticatedActor = {...actorChanged.authenticatedActor, actorId: 'other-actor'};
    expectRejected(actorChanged, 'interaction.actor', 'INTERACTION_WRONG_ACTOR');

    const expired = authorityFixture(kind, {expired: true});
    expectRejected({...expired, observedAt: '2026-08-30T00:00:00Z'}, 'interaction.expiry', 'INTERACTION_EXPIRED');

    const duplicateChanged = structuredClone(authority.command);
    duplicateChanged.command.header.operationId = 'second-operation';
    expectRejected({snapshot: authority.snapshot, firstCommand: authority.command, duplicateCommand: duplicateChanged}, 'interaction.duplicate', 'INTERACTION_DUPLICATE_RESPONSE');

    const extraResponseField = structuredClone(authority);
    extraResponseField.command.command.response.untrusted = true;
    expectRejected(extraResponseField, 'interaction.variant', 'WRONG_INTERACTION_VARIANT');
  }

  const question = authorityFixture('QUESTION');
  const approval = authorityFixture('APPROVAL');
  expectRejected({snapshot: question.snapshot, command: approval.command}, 'interaction.variant', 'WRONG_INTERACTION_VARIANT');
});

test('capability support and availability axes preserve UNKNOWN distinctions', () => {
  expectApplied(capabilitySnapshot(), 'capability.claude');
  expectApplied(capabilitySnapshot(), 'capability.codex-runtime');
  expectRejected(capabilitySnapshot({claude: true}), 'capability.claude', 'CLAUDE_NOT_IMPLEMENTED');
  expectRejected(capabilitySnapshot({itemsList: true}), 'capability.codex-runtime', 'PROVIDER_METHOD_NOT_SUPPORTED');
  expectRejected(capabilitySnapshot({availability: 'UNAVAILABLE'}), 'capability.codex-runtime', 'PROVIDER_METHOD_NOT_SUPPORTED');

  const unknown = capabilitySnapshot();
  const item = unknown.capabilities.find((entry) => entry.key === 'codex_thread_items_list');
  item.availability = 'AVAILABLE';
  expectRejected(unknown, 'capability.codex-runtime', 'PROVIDER_METHOD_NOT_SUPPORTED');
  const extra = capabilitySnapshot();
  extra.capabilities[0].untrusted = true;
  expectRejected(extra, 'capability.codex-runtime', 'PROVIDER_METHOD_NOT_SUPPORTED');
  const sparse = capabilitySnapshot();
  delete sparse.capabilities[0];
  expectRejected(sparse, 'capability.codex-runtime', 'PROVIDER_METHOD_NOT_SUPPORTED');
});

test('image ingress enforces exact bytes, count, ticket and commit staging', () => {
  expectApplied(imageIngress(), 'image.ingress');
  expectApplied(imageIngress({sizeBytes: MAX_IMAGE_BYTES, turnImageCount: MAX_TURN_IMAGE_COUNT}), 'image.ingress');
  for (const mutate of [
    (copy) => { copy.prepare.sizeBytes = MAX_IMAGE_BYTES + 1; },
    (copy) => { copy.turnImageRefs.push({imageId: 'over-count', contentRef: copy.turnImageRefs[0].contentRef}); },
    (copy) => { copy.replayPrepare.sha256 = 'b'.repeat(64); },
    (copy) => { copy.state.contentRef.sizeBytes += 1; },
    (copy) => { copy.turnImageRefs[1].imageId = copy.turnImageRefs[0].imageId; },
  ]) {
    const changed = structuredClone(imageIngress({turnImageCount: MAX_TURN_IMAGE_COUNT}));
    mutate(changed);
    expectRejected(changed, 'image.ingress', 'IMAGE_INGRESS_REJECTED');
  }
  expectApplied(imageIngress({stateStatus: 'PREPARED', turnImageCount: 0}), 'image.ingress');
  const prepared = imageIngress({stateStatus: 'PREPARED', turnImageCount: 0});
  prepared.state.uploadTicket.sizeBytes += 1;
  expectRejected(prepared, 'image.ingress', 'IMAGE_INGRESS_REJECTED');
  for (const mutate of [
    (copy) => { copy.prepare.unexpected = true; },
    (copy) => { copy.commit.unexpected = true; },
    (copy) => { copy.state.contentRef.objectGeneration = 0; },
    (copy) => { copy.turnImageRefs[0].imageId = ''; },
  ]) {
    const changed = structuredClone(imageIngress());
    mutate(changed);
    expectRejected(changed, 'image.ingress', 'IMAGE_INGRESS_REJECTED');
  }
  const preparedExtra = imageIngress({stateStatus: 'PREPARED', turnImageCount: 0});
  preparedExtra.state.uploadTicket.extra = true;
  expectRejected(preparedExtra, 'image.ingress', 'IMAGE_INGRESS_REJECTED');
  const sparseRefs = imageIngress();
  delete sparseRefs.turnImageRefs[0];
  expectRejected(sparseRefs, 'image.ingress', 'IMAGE_INGRESS_REJECTED');
});

test('wire source binding rejects predecode shape and source mutations without side effects', () => {
  const value = {
    type: 'timeline_read',
    header: {requestId: 'request-1', clientInstanceId: 'client-1', sourceEpoch: epoch()},
    query: {readKind: 'FIRST_READ', threadRef: threadRef(), providerReadSpec: materialization().beginFrame.begin.payload.readBody},
  };
  expectRejected(value, 'wire.closed-normalized-shape', 'WIRE_SHAPE_INVALID');
  const hello = {type: 'client_hello', hello: {protocolVersion: 1, profileId: 'pvmc1.phone-core.v1', clientInstanceId: 'client-1'}};
  expectApplied(hello, 'wire.closed-normalized-shape');
  const malformedHello = structuredClone(hello);
  malformedHello.hello.untrusted = true;
  expectRejected(malformedHello, 'wire.closed-normalized-shape', 'WIRE_SHAPE_INVALID');
});
