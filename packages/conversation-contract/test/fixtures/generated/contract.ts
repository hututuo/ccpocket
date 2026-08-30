// @generated from conversation contract 1eb501a44b01fccb6727ceefb71e98de643554896d9ceb8a7d0d9446cda22851; DO NOT EDIT.
/* eslint-disable */

export interface FixtureEnvelope {
  readonly "id": string;
  readonly "source": FixtureSourceRef;
  readonly "priority": FixturePriority;
  readonly "payload": FixturePayload;
  readonly "metadata"?: Readonly<Record<string, string>>;
}

export type FixturePayload = { readonly "kind": "text"; readonly "text": string } | { readonly "kind": "progress"; readonly "complete": boolean; readonly "labels"?: ReadonlyArray<string> };

export type FixturePriority = "normal" | "high_priority";

export interface FixtureSourceRef {
  readonly "bridgeInstanceId": string;
  readonly "sourceOrdinal": number;
}

type ContractNode =
  | { readonly kind: 'string' | 'integer' | 'boolean' }
  | { readonly kind: 'enum'; readonly values: ReadonlyArray<string> }
  | { readonly kind: 'ref'; readonly target: string }
  | { readonly kind: 'array'; readonly items: ContractNode }
  | { readonly kind: 'map'; readonly values: ContractNode }
  | { readonly kind: 'object'; readonly fields: ReadonlyArray<ContractField> }
  | { readonly kind: 'union'; readonly discriminator: string; readonly variants: ReadonlyArray<ContractVariant> };
type ContractField = { readonly name: string; readonly required: boolean; readonly type: ContractNode };
type ContractVariant = { readonly tag: string; readonly fields: ReadonlyArray<ContractField> };

const contractNodes = {
  "FixtureEnvelope": {
    "kind": "object",
    "fields": [
      {
        "name": "id",
        "required": true,
        "type": {
          "kind": "string"
        }
      },
      {
        "name": "source",
        "required": true,
        "type": {
          "kind": "ref",
          "target": "FixtureSourceRef"
        }
      },
      {
        "name": "priority",
        "required": true,
        "type": {
          "kind": "ref",
          "target": "FixturePriority"
        }
      },
      {
        "name": "payload",
        "required": true,
        "type": {
          "kind": "ref",
          "target": "FixturePayload"
        }
      },
      {
        "name": "metadata",
        "required": false,
        "type": {
          "kind": "map",
          "values": {
            "kind": "string"
          }
        }
      }
    ]
  },
  "FixturePayload": {
    "kind": "union",
    "discriminator": "kind",
    "variants": [
      {
        "tag": "text",
        "fields": [
          {
            "name": "text",
            "required": true,
            "type": {
              "kind": "string"
            }
          }
        ]
      },
      {
        "tag": "progress",
        "fields": [
          {
            "name": "complete",
            "required": true,
            "type": {
              "kind": "boolean"
            }
          },
          {
            "name": "labels",
            "required": false,
            "type": {
              "kind": "array",
              "items": {
                "kind": "string"
              }
            }
          }
        ]
      }
    ]
  },
  "FixturePriority": {
    "kind": "enum",
    "values": [
      "normal",
      "high_priority"
    ]
  },
  "FixtureSourceRef": {
    "kind": "object",
    "fields": [
      {
        "name": "bridgeInstanceId",
        "required": true,
        "type": {
          "kind": "string"
        }
      },
      {
        "name": "sourceOrdinal",
        "required": true,
        "type": {
          "kind": "integer"
        }
      }
    ]
  }
} as Record<string, ContractNode>;

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function assertNode(node: ContractNode, value: unknown, path: string, depth: number): void {
  if (depth > 512) throw new TypeError(path + ': contract nesting is too deep');
  switch (node.kind) {
    case 'string': if (typeof value !== 'string') throw new TypeError(path + ': expected string'); return;
    case 'integer': if (!Number.isSafeInteger(value)) throw new TypeError(path + ': expected safe integer'); return;
    case 'boolean': if (typeof value !== 'boolean') throw new TypeError(path + ': expected boolean'); return;
    case 'enum': if (typeof value !== 'string' || !node.values.includes(value)) throw new TypeError(path + ': invalid enum'); return;
    case 'ref': {
      const target = contractNodes[node.target];
      if (!target) throw new TypeError(path + ': unknown type ' + node.target);
      assertNode(target, value, path, depth + 1); return;
    }
    case 'array':
      if (!Array.isArray(value)) throw new TypeError(path + ': expected array');
      value.forEach((entry, index) => assertNode(node.items, entry, path + '[' + index + ']', depth + 1)); return;
    case 'map':
      if (!isRecord(value)) throw new TypeError(path + ': expected string-key map');
      Object.entries(value).forEach(([key, entry]) => assertNode(node.values, entry, path + '.' + key, depth + 1)); return;
    case 'object': assertFields(node.fields, value, path, depth, undefined); return;
    case 'union': {
      if (!isRecord(value)) throw new TypeError(path + ': expected union object');
      const tag = value[node.discriminator];
      const variant = node.variants.find((candidate) => candidate.tag === tag);
      if (!variant) throw new TypeError(path + '.' + node.discriminator + ': invalid discriminator');
      assertFields(variant.fields, value, path, depth, { key: node.discriminator, value: variant.tag }); return;
    }
  }
}

function assertFields(fields: ReadonlyArray<ContractField>, value: unknown, path: string, depth: number, discriminator: { key: string; value: string } | undefined): void {
  if (!isRecord(value)) throw new TypeError(path + ': expected object');
  const allowed = new Set(fields.map((field) => field.name));
  if (discriminator) { allowed.add(discriminator.key); if (value[discriminator.key] !== discriminator.value) throw new TypeError(path + '.' + discriminator.key + ': invalid discriminator'); }
  for (const key of Object.keys(value)) if (!allowed.has(key)) throw new TypeError(path + '.' + key + ': unknown field');
  for (const field of fields) {
    if (!Object.prototype.hasOwnProperty.call(value, field.name)) { if (field.required) throw new TypeError(path + '.' + field.name + ': required'); }
    else assertNode(field.type, value[field.name], path + '.' + field.name, depth + 1);
  }
}

export function assertContractType(typeId: string, value: unknown): void {
  const node = contractNodes[typeId];
  if (!node) throw new TypeError('unknown contract type ' + typeId);
  assertNode(node, value, '$', 0);
}

export function decodeFixtureEnvelope(value: unknown): FixtureEnvelope {
  assertContractType("FixtureEnvelope", value);
  return value as FixtureEnvelope;
}

export function encodeFixtureEnvelope(value: FixtureEnvelope): unknown {
  assertContractType("FixtureEnvelope", value);
  return value;
}

export function decodeFixturePayload(value: unknown): FixturePayload {
  assertContractType("FixturePayload", value);
  return value as FixturePayload;
}

export function encodeFixturePayload(value: FixturePayload): unknown {
  assertContractType("FixturePayload", value);
  return value;
}

export function decodeFixturePriority(value: unknown): FixturePriority {
  assertContractType("FixturePriority", value);
  return value as FixturePriority;
}

export function encodeFixturePriority(value: FixturePriority): unknown {
  assertContractType("FixturePriority", value);
  return value;
}

export function decodeFixtureSourceRef(value: unknown): FixtureSourceRef {
  assertContractType("FixtureSourceRef", value);
  return value as FixtureSourceRef;
}

export function encodeFixtureSourceRef(value: FixtureSourceRef): unknown {
  assertContractType("FixtureSourceRef", value);
  return value;
}
