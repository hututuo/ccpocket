import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {readFile} from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import {fileURLToPath} from 'node:url';

import * as generated from './fixtures/generated/contract.ts';

const here = path.dirname(fileURLToPath(import.meta.url));
const goldenPath = path.join(here, 'fixtures', 'jcs-goldens.json');

async function goldens() {
  return JSON.parse(await readFile(goldenPath, 'utf8'));
}

const typedHelpers = {
  CanonicalProfileProbePreimageV1(value) {
    const typed = generated.decodeCanonicalProfileProbePreimageV1(value);
    return [
      generated.canonicalBytesCanonicalProfileProbePreimageV1(typed),
      generated.digestCanonicalProfileProbePreimageV1(typed),
    ];
  },
  ProviderReadEvidencePreimageV1(value) {
    const typed = generated.decodeProviderReadEvidencePreimageV1(value);
    return [
      generated.canonicalBytesProviderReadEvidencePreimageV1(typed),
      generated.digestProviderReadEvidencePreimageV1(typed),
    ];
  },
  OperationFingerprintPreimageV1(value) {
    const typed = generated.decodeOperationFingerprintPreimageV1(value);
    return [
      generated.canonicalBytesOperationFingerprintPreimageV1(typed),
      generated.digestOperationFingerprintPreimageV1(typed),
    ];
  },
  MaterializationPagePreimageV1(value) {
    const typed = generated.decodeMaterializationPagePreimageV1(value);
    return [
      generated.canonicalBytesMaterializationPagePreimageV1(typed),
      generated.digestMaterializationPagePreimageV1(typed),
    ];
  },
  MaterializationOrderPreimageV1(value) {
    const typed = generated.decodeMaterializationOrderPreimageV1(value);
    return [
      generated.canonicalBytesMaterializationOrderPreimageV1(typed),
      generated.digestMaterializationOrderPreimageV1(typed),
    ];
  },
  MaterializationCoveragePreimageV1(value) {
    const typed = generated.decodeMaterializationCoveragePreimageV1(value);
    return [
      generated.canonicalBytesMaterializationCoveragePreimageV1(typed),
      generated.digestMaterializationCoveragePreimageV1(typed),
    ];
  },
  MaterializationManifestPreimageV1(value) {
    const typed = generated.decodeMaterializationManifestPreimageV1(value);
    return [
      generated.canonicalBytesMaterializationManifestPreimageV1(typed),
      generated.digestMaterializationManifestPreimageV1(typed),
    ];
  },
  MaterializationBeginHeaderPreimageV1(value) {
    const typed = generated.decodeMaterializationBeginHeaderPreimageV1(value);
    return [
      generated.canonicalBytesMaterializationBeginHeaderPreimageV1(typed),
      generated.digestMaterializationBeginHeaderPreimageV1(typed),
    ];
  },
  MaterializationReceiptPreimageV1(value) {
    const typed = generated.decodeMaterializationReceiptPreimageV1(value);
    return [
      generated.canonicalBytesMaterializationReceiptPreimageV1(typed),
      generated.digestMaterializationReceiptPreimageV1(typed),
    ];
  },
  GapRepairIntentPreimageV1(value) {
    const typed = generated.decodeGapRepairIntentPreimageV1(value);
    return [
      generated.canonicalBytesGapRepairIntentPreimageV1(typed),
      generated.digestGapRepairIntentPreimageV1(typed),
    ];
  },
};

test('generated TypeScript matches independently stored canonical-byte and digest goldens', async () => {
  const fixture = await goldens();
  assert.equal(fixture.canonicalizationProfile, 'RFC8785-IJSON-SAFE-INTEGER-V1');
  for (const reference of fixture.referenceCases) {
    assert.equal(
      createHash('sha256').update(Buffer.from(reference.canonicalUtf8Hex, 'hex')).digest('hex'),
      reference.sha256,
      reference.id,
    );
  }
  assert.equal('canonicalBytesForPreimage' in generated, false);
  assert.equal('digestPreimage' in generated, false);
  for (const golden of fixture.cases) {
    const helper = typedHelpers[golden.typeId];
    assert.equal(typeof helper, 'function', golden.typeId);
    const [bytes, digest] = helper(golden.value);
    assert.equal(Buffer.from(bytes).toString('hex'), golden.canonicalUtf8Hex, golden.id);
    assert.equal(digest, golden.sha256, golden.id);
    assert.match(digest, /^[0-9a-f]{64}$/);
  }

  const probe = fixture.cases[0];
  assert.equal(Object.is(probe.value.negativeZero, -0), true);
  const canonical = Buffer.from(probe.canonicalUtf8Hex, 'hex').toString('utf8');
  const orderedKeys = ['\\r', '"1"', '"digestDomain"', '"\u0080"', '"ö"', '"€"', '"😀"', '"דּ"'];
  let previous = -1;
  for (const key of orderedKeys) {
    const current = canonical.indexOf(key);
    assert.ok(current > previous, `UTF-16 key order for ${JSON.stringify(key)}`);
    previous = current;
  }
  assert.match(canonical, /slash:\//);
  assert.doesNotMatch(canonical, /\\\//);
  assert.ok(canonical.includes('L\u2028P\u2029Z'));
  assert.match(probe.canonicalUtf8Hex, /c3a9/);
  assert.match(probe.canonicalUtf8Hex, /65cc81/);
  assert.match(canonical, /"negativeZero":0/);
});

test('generated TypeScript rejects malformed values before digest authority', async () => {
  const fixture = await goldens();
  const operationGolden = fixture.cases.find((entry) => entry.id === 'operation-fingerprint');
  const pageGolden = fixture.cases.find((entry) => entry.id === 'materialization-page');
  const valid = operationGolden.value;
  const digest = (value) => generated.digestOperationFingerprintPreimageV1(value);

  for (const jsonNumber of ['1.0', '1e0']) {
    assert.equal(
      digest({...valid, sequence: JSON.parse(jsonNumber)}),
      operationGolden.sha256,
      `${jsonNumber} integral JSON number parity`,
    );
  }

  const missing = structuredClone(valid);
  delete missing.operationCode;
  assert.throws(() => digest(missing), /required/);

  assert.throws(() => digest({...valid, extra: true}), /unknown field/);
  assert.throws(() => digest({...valid, sequence: '1'}), /safe integer/);
  assert.throws(
    () => digest({...valid, digestDomain: 'ccpocket.wrong.v1'}),
    /invalid enum|invalid digest domain/,
  );
  assert.throws(() => digest({...valid, payloadDigest: 'A'.repeat(64)}), /lowercase SHA-256 hex64/);
  assert.throws(() => digest({...valid, payloadDigest: 'a'.repeat(63)}), /lowercase SHA-256 hex64/);
  assert.throws(() => digest({...valid, sequence: Number.MAX_SAFE_INTEGER + 1}), /safe integer/);
  assert.throws(() => digest({...valid, sequence: Number.MIN_SAFE_INTEGER - 1}), /safe integer/);
  for (const value of [1.5, Number.NaN, Number.POSITIVE_INFINITY, Number.NEGATIVE_INFINITY]) {
    assert.throws(() => digest({...valid, sequence: value}), /safe integer/);
  }
  assert.throws(
    () => digest({...valid, source: {...valid.source, bridgeInstanceId: '\ud800'}}),
    /lone high surrogate/,
  );
  assert.throws(() => digest({...valid, ['\udc00']: true}), /lone low surrogate/);

  const sparse = structuredClone(pageGolden.value);
  sparse.body.items = new Array(1);
  assert.throws(
    () => generated.digestMaterializationPagePreimageV1(sparse),
    /sparse arrays/,
  );

  const extraArrayField = structuredClone(pageGolden.value);
  extraArrayField.body.items.extra = 'not-json-array-data';
  assert.throws(
    () => generated.digestMaterializationPagePreimageV1(extraArrayField),
    /unexpected array field/,
  );

  let getterReads = 0;
  const accessor = structuredClone(valid);
  Object.defineProperty(accessor, 'operationCode', {
    enumerable: true,
    get() {
      getterReads += 1;
      return 'START_TURN';
    },
  });
  assert.throws(() => digest(accessor), /own data field/);
  assert.equal(getterReads, 0);

  const hidden = structuredClone(valid);
  Object.defineProperty(hidden, 'hidden', {enumerable: false, value: true});
  assert.throws(() => digest(hidden), /own data field/);

  const symbol = structuredClone(valid);
  symbol[Symbol('extra')] = true;
  assert.throws(() => digest(symbol), /symbol fields/);

  class ExoticOperation {}
  assert.throws(
    () => digest(Object.assign(new ExoticOperation(), structuredClone(valid))),
    /plain data object/,
  );
  assert.throws(() => digest(new Proxy(structuredClone(valid), {})), /proxy objects/);

  const nullPrototype = Object.assign(Object.create(null), structuredClone(valid));
  assert.equal(digest(nullPrototype), operationGolden.sha256);

  const tampered = {...valid, payloadDigest: 'c'.repeat(64)};
  assert.notEqual(digest(tampered), operationGolden.sha256);
});

test('generated TypeScript enforces the fixed canonical node budget', async () => {
  const fixture = await goldens();
  const orderGolden = fixture.cases.find((entry) => entry.id === 'materialization-order');
  const atLimit = structuredClone(orderGolden.value);
  atLimit.orderedTimelineIds = Array.from({length: 99_993}, (_, index) => String(index));
  assert.match(generated.digestMaterializationOrderPreimageV1(atLimit), /^[0-9a-f]{64}$/);

  const overLimit = structuredClone(atLimit);
  overLimit.orderedTimelineIds.push('overflow');
  assert.throws(
    () => generated.digestMaterializationOrderPreimageV1(overLimit),
    /node limit exceeded/,
  );
});
