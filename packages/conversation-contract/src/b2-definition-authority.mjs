import {readFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';

import {compareUtf16, digestBytes, jsonEqual} from './canonical.mjs';

const PROFILE_ID = 'pvmc1.phone-core.v1';
const ORACLE_PATH = fileURLToPath(new URL(
  '../test/fixtures/pvmc1-b2-definition-oracle.json',
  import.meta.url,
));
const AMENDMENT_PATH = fileURLToPath(new URL(
  '../../../docs/design/codex-kernel-v4/PVMC-1-COMPACT-AUTHORITY-AMENDMENT-20260830.md',
  import.meta.url,
));
const RULING_PATH = fileURLToPath(new URL(
  '../../../docs/design/codex-kernel-v4/PVMC-1-B2-IMPLEMENTATION-RULING-20260830.md',
  import.meta.url,
));

function fail(path, message) {
  throw new TypeError(`${path}: ${message}`);
}

function loadOracle() {
  const oracle = JSON.parse(readFileSync(ORACLE_PATH, 'utf8'));
  const expectedKeys = [
    'activeDefinitionIds',
    'authorityAmendmentSha256',
    'b2Definitions',
    'formatVersion',
    'implementationRulingSha256',
    'profileId',
    'status',
  ];
  if (!jsonEqual(Object.keys(oracle).sort(compareUtf16), expectedKeys)) {
    fail('b2DefinitionOracle', 'unexpected top-level keys');
  }
  if (oracle.formatVersion !== 1 || oracle.profileId !== PROFILE_ID ||
      oracle.status !== 'INDEPENDENT_B2_DEFINITION_ORACLE_NOT_GENERATION_SOURCE') {
    fail('b2DefinitionOracle', 'unexpected oracle identity');
  }
  const amendmentSha256 = digestBytes(readFileSync(AMENDMENT_PATH));
  const rulingSha256 = digestBytes(readFileSync(RULING_PATH));
  if (oracle.authorityAmendmentSha256 !== amendmentSha256 ||
      oracle.implementationRulingSha256 !== rulingSha256) {
    fail('b2DefinitionOracle', 'authority document digest drift');
  }
  return oracle;
}

export function validateB2DefinitionAuthority(registry, activeDefinitionIds) {
  const oracle = loadOracle();
  const actualActive = [...activeDefinitionIds].sort(compareUtf16);
  if (!jsonEqual(actualActive, oracle.activeDefinitionIds)) {
    fail('registry.definitions', 'active definition closure differs from the B2 oracle');
  }
  const definitions = new Map(registry.definitions.map((definition) => [
    definition.id,
    definition,
  ]));
  const seen = new Set();
  for (const expected of oracle.b2Definitions) {
    if (seen.has(expected.id)) fail('b2DefinitionOracle.b2Definitions', `duplicate ${expected.id}`);
    seen.add(expected.id);
    const actual = definitions.get(expected.id);
    if (!actual || !jsonEqual(actual, expected)) {
      fail(`registry.definitions.${expected.id}`, 'does not exact-equal the independent B2 definition oracle');
    }
  }
  return {
    b2DefinitionIds: [...seen].sort(compareUtf16),
    activeDefinitionIds: actualActive,
  };
}
