import {Buffer} from 'node:buffer';

import {canonicalize, digestBytes} from './canonical.mjs';

export const MACHINE_TRANSITION_SQL_DERIVATION_ID =
  'PVMC1_MACHINE_TRANSITION_SQL_V1';

export const MACHINE_TRANSITION_SQL_TEMPLATE_SHA256 =
  '2d84de976e3e27bb9cccc8978bac1a68e2f72cde702a5cc8b5bd43740cb7e744';

export const MACHINE_TRANSITION_SQL_TEMPLATE = `CREATE TABLE pvmc1_machine_transition (
  machine_ordinal INTEGER NOT NULL CHECK(machine_ordinal >= 0),
  from_state_ordinal INTEGER NOT NULL CHECK(from_state_ordinal >= 0),
  to_state_ordinal INTEGER NOT NULL CHECK(to_state_ordinal >= 0),
  machine_id TEXT NOT NULL,
  from_state TEXT NOT NULL,
  to_state TEXT NOT NULL,
  edge_id TEXT NOT NULL,
  authority_json TEXT NOT NULL CHECK(json_valid(authority_json)),
  UNIQUE(edge_id),
  PRIMARY KEY(machine_id, from_state, to_state)
) STRICT;
INSERT INTO pvmc1_machine_transition(machine_ordinal,from_state_ordinal,to_state_ordinal,machine_id,from_state,to_state,edge_id,authority_json) VALUES
{{ROW_TUPLES}};
`;

function fail(path, message) {
  throw new TypeError(`${path}: ${message}`);
}

function requireArray(value, path) {
  if (!Array.isArray(value)) fail(path, 'expected an array');
  return value;
}

function requireString(value, path) {
  if (typeof value !== 'string' || value.length === 0) {
    fail(path, 'expected a non-empty string');
  }
  return value;
}

function sqlText(value, path) {
  return `'${requireString(value, path).replaceAll("'", "''")}'`;
}

function canonicalUnsigned(value, path) {
  if (!Number.isSafeInteger(value) || value < 0) {
    fail(path, 'expected a non-negative safe integer');
  }
  return String(value);
}

function templatePreflight() {
  const bytes = Buffer.from(MACHINE_TRANSITION_SQL_TEMPLATE, 'utf8');
  if (bytes.length !== 657) {
    fail('machineTransitionSql.template', `expected 657 bytes, got ${bytes.length}`);
  }
  const digest = digestBytes(bytes);
  if (digest !== MACHINE_TRANSITION_SQL_TEMPLATE_SHA256) {
    fail('machineTransitionSql.template', `unexpected template digest ${digest}`);
  }
  if (MACHINE_TRANSITION_SQL_TEMPLATE.split('{{ROW_TUPLES}}').length !== 2) {
    fail('machineTransitionSql.template', 'ROW_TUPLES token must occur exactly once');
  }
}

function normalizedRows(machineRecords, edgeAuthorities) {
  const machines = new Map();
  for (const [index, machine] of requireArray(
    machineRecords,
    'machineRecords',
  ).entries()) {
    const path = `machineRecords[${index}]`;
    const machineId = requireString(machine?.machineId, `${path}.machineId`);
    if (machines.has(machineId)) fail(`${path}.machineId`, 'duplicate machine');
    if (machine.machineOrdinal !== index) {
      fail(`${path}.machineOrdinal`, `expected ${index}`);
    }
    const states = requireArray(machine.states, `${path}.states`);
    if (new Set(states).size !== states.length) {
      fail(`${path}.states`, 'states must be unique');
    }
    machines.set(machineId, {machine, states});
  }

  const rows = [];
  const seenCoordinates = new Set();
  const seenEdgeIds = new Set();
  for (const [index, authority] of requireArray(
    edgeAuthorities,
    'machineEdgeAuthorities',
  ).entries()) {
    const path = `machineEdgeAuthorities[${index}]`;
    const coordinate = authority?.coordinate;
    const machineId = requireString(coordinate?.machineId, `${path}.coordinate.machineId`);
    const machineEntry = machines.get(machineId);
    if (!machineEntry) fail(`${path}.coordinate.machineId`, 'unknown machine');
    const from = requireString(coordinate?.from, `${path}.coordinate.from`);
    const to = requireString(coordinate?.to, `${path}.coordinate.to`);
    const fromStateOrdinal = machineEntry.states.indexOf(from);
    const toStateOrdinal = machineEntry.states.indexOf(to);
    if (fromStateOrdinal < 0 || toStateOrdinal < 0) {
      fail(`${path}.coordinate`, 'state is not in the named machine');
    }
    const edgeId = requireString(authority.edgeId, `${path}.edgeId`);
    const expectedEdgeId = `${machineId}:${from}->${to}`;
    if (edgeId !== expectedEdgeId) {
      fail(`${path}.edgeId`, `expected ${JSON.stringify(expectedEdgeId)}`);
    }
    const coordinateKey = `${machineId}\u0000${from}\u0000${to}`;
    if (seenCoordinates.has(coordinateKey)) {
      fail(`${path}.coordinate`, 'duplicate coordinate');
    }
    if (seenEdgeIds.has(edgeId)) fail(`${path}.edgeId`, 'duplicate edge ID');
    seenCoordinates.add(coordinateKey);
    seenEdgeIds.add(edgeId);
    rows.push({
      machineOrdinal: machineEntry.machine.machineOrdinal,
      fromStateOrdinal,
      toStateOrdinal,
      machineId,
      from,
      to,
      edgeId,
      authority,
    });
  }
  rows.sort((left, right) =>
    left.machineOrdinal - right.machineOrdinal ||
    left.fromStateOrdinal - right.fromStateOrdinal ||
    left.toStateOrdinal - right.toStateOrdinal);
  return rows;
}

export function renderMachineTransitionSql(machineRecords, edgeAuthorities) {
  templatePreflight();
  const rows = normalizedRows(machineRecords, edgeAuthorities);
  const tuples = rows.map((row, index) => {
    const authorityJson = canonicalize(row.authority);
    return `(${canonicalUnsigned(row.machineOrdinal, `rows[${index}].machineOrdinal`)},` +
      `${canonicalUnsigned(row.fromStateOrdinal, `rows[${index}].fromStateOrdinal`)},` +
      `${canonicalUnsigned(row.toStateOrdinal, `rows[${index}].toStateOrdinal`)},` +
      `${sqlText(row.machineId, `rows[${index}].machineId`)},` +
      `${sqlText(row.from, `rows[${index}].from`)},` +
      `${sqlText(row.to, `rows[${index}].to`)},` +
      `${sqlText(row.edgeId, `rows[${index}].edgeId`)},` +
      `${sqlText(authorityJson, `rows[${index}].authorityJson`)})`;
  });
  const sql = MACHINE_TRANSITION_SQL_TEMPLATE.replace(
    '{{ROW_TUPLES}}',
    tuples.join(',\n'),
  );
  const bytes = Buffer.from(sql, 'utf8');
  if (bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) {
    fail('machineTransitionSql', 'UTF-8 BOM is forbidden');
  }
  if (!sql.endsWith('\n') || sql.endsWith('\n\n') || sql.includes('\r')) {
    fail('machineTransitionSql', 'expected LF-only text with exactly one final LF');
  }
  return {
    bytes,
    sql,
    rows,
    manifest: {
      derivationId: MACHINE_TRANSITION_SQL_DERIVATION_ID,
      encoding: 'UTF-8',
      lineEnding: 'LF',
      hasBom: false,
      trailingLfCount: 1,
      rowCount: rows.length,
      sqlUtf8Base64: bytes.toString('base64'),
      sqlSha256: digestBytes(bytes),
    },
  };
}

export function decodeMachineTransitionSqlManifest(manifest) {
  if (manifest?.derivationId !== MACHINE_TRANSITION_SQL_DERIVATION_ID ||
      manifest.encoding !== 'UTF-8' || manifest.lineEnding !== 'LF' ||
      manifest.hasBom !== false || manifest.trailingLfCount !== 1 ||
      !Number.isSafeInteger(manifest.rowCount) || manifest.rowCount < 0 ||
      typeof manifest.sqlUtf8Base64 !== 'string' ||
      typeof manifest.sqlSha256 !== 'string') {
    fail('machineTransitionSql.manifest', 'invalid manifest shape');
  }
  const bytes = Buffer.from(manifest.sqlUtf8Base64, 'base64');
  if (bytes.toString('base64') !== manifest.sqlUtf8Base64) {
    fail('machineTransitionSql.manifest.sqlUtf8Base64', 'non-canonical standard Base64');
  }
  if (digestBytes(bytes) !== manifest.sqlSha256) {
    fail('machineTransitionSql.manifest.sqlSha256', 'digest mismatch');
  }
  const sql = bytes.toString('utf8');
  if (!Buffer.from(sql, 'utf8').equals(bytes)) {
    fail('machineTransitionSql.manifest.sqlUtf8Base64', 'invalid UTF-8');
  }
  if (!sql.endsWith('\n') || sql.endsWith('\n\n') || sql.includes('\r')) {
    fail('machineTransitionSql.manifest', 'invalid line ending shape');
  }
  return {bytes, sql};
}
