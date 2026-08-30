import {
  assertContractType,
  decodeFixtureCanonicalOrderSet,
  decodeFixtureConstrainedRecord,
  decodeFixtureEnvelope,
  decodeFixtureOneOf,
  encodeFixtureEnvelope,
} from '../generated/contract.js';

const decoded = decodeFixtureEnvelope(JSON.parse(`{
  "id": "typescript-fixture",
  "source": {"bridgeInstanceId": "bridge-ts", "sourceOrdinal": 1},
  "priority": "cost$x",
  "payload": {"kind": "text", "text": "cost$x"},
  "__proto__": "safe"
}`));

const proto: string | undefined = decoded.__proto__;
const encoded: unknown = encodeFixtureEnvelope(decoded);
assertContractType('FixtureEnvelope', encoded);
void proto;

const constrained = decodeFixtureConstrainedRecord({
  nullableValue: null,
  fixed: 'FIXED',
  version: 1,
  bounded: 2,
  disabled: false,
  items: [{identity: {id: 'a'}, ordinal: 0, label: 'item-a'}],
  tags: ['alpha'],
});
const nullableValue: string | null = constrained.nullableValue;
const oneOf: {readonly left: string} | {readonly right: number} =
  decodeFixtureOneOf({left: 'typed'});
const canonicalOrder: ReadonlyArray<{readonly left: string} | {readonly right: number}> =
  decodeFixtureCanonicalOrderSet([{left: 'a'}, {right: 1}]);
void nullableValue;
void oneOf;
void canonicalOrder;
