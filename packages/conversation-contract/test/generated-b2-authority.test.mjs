import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {pathToFileURL} from 'node:url';

import {generateArtifacts} from '../src/generate.mjs';
import {validateInputs} from '../src/validate.mjs';

const registryUrl = new URL(
  '../../../docs/design/codex-kernel-v4/contracts/contract-registry.json',
  import.meta.url,
);
const vectorsUrl = new URL(
  '../../../docs/design/codex-kernel-v4/contracts/vectors/phone-core-vectors.json',
  import.meta.url,
);

function generated() {
  const registry = JSON.parse(readFileSync(registryUrl, 'utf8'));
  const vectors = JSON.parse(readFileSync(vectorsUrl, 'utf8'));
  const model = validateInputs(registry, vectors);
  return {registry, model, artifacts: generateArtifacts(model)};
}

function capture(source, expression, label) {
  const match = source.match(expression);
  assert.ok(match, label);
  return match[1];
}

function tsJson(source, name) {
  return JSON.parse(capture(
    source,
    new RegExp(`export const ${name} = (\\[[\\s\\S]*?\\]) as const;`),
    name,
  ));
}

function dartJson(source, name) {
  return JSON.parse(capture(
    source,
    new RegExp(`const List<String> ${name} = (\\[[^;]*\\]);`),
    name,
  ));
}

test('Schema and profile manifest expose one exact B2 authority set', () => {
  const {model, artifacts} = generated();
  const schema = JSON.parse(artifacts.get('schema.json'));
  const manifest = JSON.parse(artifacts.get('profile-manifest.json'));
  const metadata = schema['x-ccpocket-pvmc1-authority'];
  const manifestIds = model.transactionAuthority.transactionManifests.map((row) =>
    row.manifestId);
  const killPointIds = model.transactionAuthority.transactionKillPoints.map((row) =>
    row.killPointId).sort();
  assert.deepEqual(metadata.machineIds, model.machineAuthority.machineRecords.map((row) =>
    row.machineId));
  assert.deepEqual(metadata.machineEdgeIds, model.machineAuthority.machineEdgeAuthorities.map((row) =>
    row.edgeId));
  assert.deepEqual(metadata.forbiddenEdgeMarkerIds, model.machineAuthority.forbiddenEdgeMarkers.map((row) =>
    row.markerId));
  assert.deepEqual(metadata.transactionManifestIds, manifestIds);
  assert.deepEqual(metadata.transactionKillPointIds, killPointIds);
  assert.deepEqual(manifest.transactionManifestIds, manifestIds);
  assert.deepEqual(manifest.transactionKillPointIds, killPointIds);
  assert.deepEqual(manifest.transactionCounts, {
    manifests: 235,
    applicabilityCases: 387,
    segments: 290,
    steps: 1181,
    killPoints: 946,
    bridgeRoutePoints: 28,
  });
  assert.equal(schema.$defs.TransactionManifestV1.type, 'object');
  assert.equal(schema.$defs.TransactionKillPointV1.type, 'object');
  assert.equal(schema.$defs.TransactionSegmentV1.oneOf.length, 2);
});

test('generated TypeScript exports exact immutable machine and transaction authority', () => {
  const {model, artifacts} = generated();
  const source = artifacts.get('contract.ts');
  const records = JSON.parse(capture(
    source,
    /export const pvmc1MachineRecords = (\[[\s\S]*?\]) as const satisfies readonly Pvmc1MachineRecord\[\];/,
    'pvmc1MachineRecords',
  ));
  assert.deepEqual(records, model.machineAuthority.machineRecords);
  const edges = JSON.parse(capture(
    source,
    /export const pvmc1MachineEdgeAuthorities = (\[[\s\S]*?\]) as const satisfies readonly MachineEdgeAuthorityV1\[\];/,
    'pvmc1MachineEdgeAuthorities',
  ));
  assert.deepEqual(edges, model.machineAuthority.machineEdgeAuthorities);
  assert.deepEqual(
    tsJson(source, 'pvmc1DurableRouteIds'),
    model.machineAuthority.projectionRoutes.map((row) => row.registryId),
  );
  assert.deepEqual(
    tsJson(source, 'pvmc1TransactionManifestIds'),
    model.transactionAuthority.transactionManifests.map((row) => row.manifestId),
  );
  assert.deepEqual(
    tsJson(source, 'pvmc1TransactionKillPointIds'),
    model.transactionAuthority.transactionKillPoints.map((row) => row.killPointId).sort(),
  );
  assert.match(source, /function isAllowedPvmc1MachineEdge/);
  assert.match(source, /function pvmc1MachineTransitionSqlBytes/);
  assert.match(source, /as const satisfies readonly Pvmc1MachineRecord\[\]/);
  assert.match(source, /function pvmc1DeepFreezeAuthority/);
  assert.match(source, /pvmc1DeepFreezeAuthority\(pvmc1MachineRecords\)/);
  assert.match(source, /pvmc1DeepFreezeAuthority\(pvmc1MachineEdgeAuthorities\)/);
});

test('generated TypeScript authority is recursively immutable before helper indexing', async () => {
  const {artifacts} = generated();
  const directory = mkdtempSync(path.join(tmpdir(), 'ccpocket-b2-ts-runtime-'));
  const target = path.join(directory, 'contract.ts');
  try {
    writeFileSync(target, artifacts.get('contract.ts'));
    const authority = await import(`${pathToFileURL(target).href}?runtime=${Date.now()}`);
    const firstRecord = authority.pvmc1MachineRecords[0];
    const firstEdge = authority.pvmc1MachineEdgeAuthorities[0];
    const coordinate = firstEdge.coordinate;
    assert.equal(
      authority.isAllowedPvmc1MachineEdge(
        coordinate.machineId,
        coordinate.from,
        coordinate.to,
      ),
      true,
    );
    assert.throws(() => authority.pvmc1MachineRecords.push(firstRecord), TypeError);
    assert.throws(() => { firstRecord.states[0] = 'MUTATED'; }, TypeError);
    assert.throws(() => { firstEdge.coordinate.from = 'MUTATED'; }, TypeError);
    assert.throws(() => firstEdge.guardRefs.push(firstEdge.guardRefs[0]), TypeError);
    const replica = authority.pvmc1MachineRecords.find((row) =>
      row.replicaWriterBindings.length > 0).replicaWriterBindings[0];
    assert.throws(() => replica.storageBindings.push(replica.storageBindings[0]), TypeError);
    assert.throws(
      () => authority.pvmc1TransactionManifestIds.push('tx.mutated'),
      TypeError,
    );
    assert.equal(
      authority.isAllowedPvmc1MachineEdge(
        coordinate.machineId,
        coordinate.from,
        coordinate.to,
      ),
      true,
    );
  } finally {
    rmSync(directory, {recursive: true, force: true});
  }
});

test('generated Dart exports the same machine JSON, routes, and transaction IDs', () => {
  const {model, artifacts} = generated();
  const source = artifacts.get('contract.dart');
  const encodedMachineJson = JSON.parse(capture(
    source,
    /const String _pvmc1MachineRecordsJson = ("(?:[^"\\]|\\.)*");/,
    '_pvmc1MachineRecordsJson',
  ));
  assert.deepEqual(JSON.parse(encodedMachineJson), model.machineAuthority.machineRecords);
  const encodedEdgesJson = JSON.parse(capture(
    source,
    /const String _pvmc1MachineEdgeAuthoritiesJson = ("(?:[^"\\]|\\.)*");/,
    '_pvmc1MachineEdgeAuthoritiesJson',
  ));
  assert.deepEqual(
    JSON.parse(encodedEdgesJson),
    model.machineAuthority.machineEdgeAuthorities,
  );
  assert.deepEqual(
    dartJson(source, 'pvmc1DurableRouteIds'),
    model.machineAuthority.projectionRoutes.map((row) => row.registryId),
  );
  assert.deepEqual(
    dartJson(source, 'pvmc1TransactionManifestIds'),
    model.transactionAuthority.transactionManifests.map((row) => row.manifestId),
  );
  assert.deepEqual(
    dartJson(source, 'pvmc1TransactionKillPointIds'),
    model.transactionAuthority.transactionKillPoints.map((row) => row.killPointId).sort(),
  );
  assert.match(source, /bool isAllowedPvmc1MachineEdge/);
  assert.match(source, /Uint8List pvmc1MachineTransitionSqlBytes/);
  assert.match(source, /final List<Pvmc1MachineRecord> pvmc1MachineRecords/);
  assert.match(source, /final List<MachineEdgeAuthorityV1> pvmc1MachineEdgeAuthorities/);
  assert.match(source, /_pvmc1ImmutableReplicaWriterBinding/);
  assert.match(source, /_pvmc1ImmutableMachineEdgeAuthority/);
});

test('Schema, manifest, TypeScript, and Dart carry the exact same SQL bytes and digest', () => {
  const {model, artifacts} = generated();
  const schema = JSON.parse(artifacts.get('schema.json'));
  const manifest = JSON.parse(artifacts.get('profile-manifest.json'));
  const typescript = artifacts.get('contract.ts');
  const dart = artifacts.get('contract.dart');
  const expected = model.machineAuthority.machineTransitionSql.manifest;
  const tsBase64 = JSON.parse(capture(
    typescript,
    /pvmc1MachineTransitionSqlUtf8Base64 = ("[A-Za-z0-9+/=]+") as const;/,
    'TypeScript SQL Base64',
  ));
  const dartBase64 = JSON.parse(capture(
    dart,
    /pvmc1MachineTransitionSqlUtf8Base64 = ("[A-Za-z0-9+/=]+");/,
    'Dart SQL Base64',
  ));
  assert.deepEqual(schema['x-ccpocket-pvmc1-authority'].machineTransitionSql, expected);
  assert.deepEqual(manifest.machineTransitionSql, expected);
  assert.equal(tsBase64, expected.sqlUtf8Base64);
  assert.equal(dartBase64, expected.sqlUtf8Base64);
  const bytes = Buffer.from(tsBase64, 'base64');
  assert.equal(bytes.length, model.machineAuthority.machineTransitionSql.bytes.length);
  assert.equal(createHash('sha256').update(bytes).digest('hex'), expected.sqlSha256);
  assert.equal(bytes.toString('utf8'), model.machineAuthority.machineTransitionSql.sql);
});
