import {
  assertContractType,
  decodeFixtureEnvelope,
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
