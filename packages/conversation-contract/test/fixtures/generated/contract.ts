// @generated from conversation contract 07db48c0fa1b872cc1ad12deb7a1454dccf61ff8414727f2e02d985ecf3cf1b2; DO NOT EDIT.
/* eslint-disable */

import { createHash } from 'node:crypto';
import { isProxy } from 'node:util/types';

export interface CanonicalProfileProbePreimageV1 {
  readonly "digestDomain": "ccpocket.canonical-profile-probe.v1";
  readonly "\r": string;
  readonly "1": string;
  readonly "": string;
  readonly "ö": string;
  readonly "€": string;
  readonly "😀": string;
  readonly "דּ": string;
  readonly "escaped": string;
  readonly "lineSeparators": string;
  readonly "nfc": string;
  readonly "nfd": string;
  readonly "minSafe": number;
  readonly "maxSafe": number;
  readonly "negativeZero": number;
}

export interface FixtureEnvelope {
  readonly "id": string;
  readonly "source": FixtureSourceRef;
  readonly "priority": FixturePriority;
  readonly "payload": FixturePayload;
  readonly "metadata"?: Readonly<Record<string, string>>;
  readonly "__proto__"?: string;
}

export interface FixturePageBodyV1 {
  readonly "items": ReadonlyArray<string>;
  readonly "gaps": ReadonlyArray<string>;
}

export type FixturePayload = { readonly "kind": "text"; readonly "text": string } | { readonly "kind": "progress"; readonly "complete": boolean; readonly "labels"?: ReadonlyArray<string> };

export type FixturePriority = "normal" | "high_priority" | "cost$x" | "quote\"slash\\cost$x";

export interface FixtureSourceRef {
  readonly "bridgeInstanceId": string;
  readonly "sourceOrdinal": number;
}

export interface GapRepairIntentPreimageV1 {
  readonly "digestDomain": "ccpocket.gap-repair-intent.v1";
  readonly "source": FixtureSourceRef;
  readonly "readSpecDigest": Sha256Hex64;
  readonly "boundaryKind": "BEFORE" | "AFTER" | "BETWEEN";
  readonly "repairKind": "NEXT_PROVIDER_PAGE" | "FULL_BOUNDED_REREAD" | "NONE";
}

export interface MaterializationBeginHeaderPreimageV1 {
  readonly "digestDomain": "ccpocket.materialization-begin.v1";
  readonly "source": FixtureSourceRef;
  readonly "manifestDigest": Sha256Hex64;
  readonly "coverageDigest": Sha256Hex64;
  readonly "pageCount": number;
}

export interface MaterializationCoveragePreimageV1 {
  readonly "digestDomain": "ccpocket.materialization-coverage.v1";
  readonly "structuralCoverage": "COMPLETE" | "PARTIAL" | "EMPTY_PROVEN";
  readonly "payloadCoverage": "COMPLETE" | "PARTIAL";
  readonly "gapOrdinals": ReadonlyArray<number>;
}

export interface MaterializationManifestPreimageV1 {
  readonly "digestDomain": "ccpocket.materialization-manifest.v1";
  readonly "algorithmVersion": number;
  readonly "pageCount": number;
  readonly "orderedPageDigests": ReadonlyArray<Sha256Hex64>;
  readonly "orderDigest": Sha256Hex64;
  readonly "coverageDigest": Sha256Hex64;
}

export type MaterializationOrderPreimageV1 = { readonly "domain": "CATALOG"; readonly "digestDomain": "ccpocket.materialization-order.v1"; readonly "source": FixtureSourceRef; readonly "orderedSessionIds": ReadonlyArray<string> } | { readonly "domain": "TIMELINE"; readonly "digestDomain": "ccpocket.materialization-order.v1"; readonly "source": FixtureSourceRef; readonly "orderedTimelineIds": ReadonlyArray<string> };

export interface MaterializationPagePreimageV1 {
  readonly "digestDomain": "ccpocket.materialization-page.v1";
  readonly "source": FixtureSourceRef;
  readonly "pageIndex": number;
  readonly "pageCount": number;
  readonly "previousPageDigest"?: Sha256Hex64;
  readonly "body": FixturePageBodyV1;
}

export interface MaterializationReceiptPreimageV1 {
  readonly "digestDomain": "ccpocket.materialization-receipt.v1";
  readonly "receiptId": string;
  readonly "beginHeaderDigest": Sha256Hex64;
  readonly "manifestDigest": Sha256Hex64;
  readonly "status": "VERIFIED";
  readonly "stagedBytes": number;
}

export interface OperationFingerprintPreimageV1 {
  readonly "digestDomain": "ccpocket.operation-fingerprint.v1";
  readonly "operationCode": "START_TURN" | "EDIT_QUEUE";
  readonly "source": FixtureSourceRef;
  readonly "payloadDigest": Sha256Hex64;
  readonly "preconditionDigest": Sha256Hex64;
  readonly "sequence": number;
}

export interface ProviderReadEvidencePreimageV1 {
  readonly "digestDomain": "ccpocket.provider-read-evidence.v1";
  readonly "providerMethod": "THREAD_TURNS_LIST";
  readonly "codexBuildDigest": Sha256Hex64;
  readonly "readGeneration": number;
  readonly "resultDigest": Sha256Hex64;
  readonly "resultCount": number;
}

export type Sha256Hex64 = string;

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
type JsonSnapshot = string | number | boolean | JsonSnapshot[] | JsonSnapshotObject;
type JsonSnapshotObject = { readonly [key: string]: JsonSnapshot };
type SnapshotState = { readonly active: WeakSet<object>; nodes: number };
type DigestDomainRule =
  | { readonly kind: 'object'; readonly value: string }
  | { readonly kind: 'union'; readonly discriminator: string; readonly variants: ReadonlyArray<{ readonly tag: string; readonly value: string }> };

const contractNodes = {
  "CanonicalProfileProbePreimageV1": {
    "kind": "object",
    "fields": [
      {
        "name": "digestDomain",
        "required": true,
        "type": {
          "kind": "enum",
          "values": [
            "ccpocket.canonical-profile-probe.v1"
          ]
        }
      },
      {
        "name": "\r",
        "required": true,
        "type": {
          "kind": "string"
        }
      },
      {
        "name": "1",
        "required": true,
        "type": {
          "kind": "string"
        }
      },
      {
        "name": "",
        "required": true,
        "type": {
          "kind": "string"
        }
      },
      {
        "name": "ö",
        "required": true,
        "type": {
          "kind": "string"
        }
      },
      {
        "name": "€",
        "required": true,
        "type": {
          "kind": "string"
        }
      },
      {
        "name": "😀",
        "required": true,
        "type": {
          "kind": "string"
        }
      },
      {
        "name": "דּ",
        "required": true,
        "type": {
          "kind": "string"
        }
      },
      {
        "name": "escaped",
        "required": true,
        "type": {
          "kind": "string"
        }
      },
      {
        "name": "lineSeparators",
        "required": true,
        "type": {
          "kind": "string"
        }
      },
      {
        "name": "nfc",
        "required": true,
        "type": {
          "kind": "string"
        }
      },
      {
        "name": "nfd",
        "required": true,
        "type": {
          "kind": "string"
        }
      },
      {
        "name": "minSafe",
        "required": true,
        "type": {
          "kind": "integer"
        }
      },
      {
        "name": "maxSafe",
        "required": true,
        "type": {
          "kind": "integer"
        }
      },
      {
        "name": "negativeZero",
        "required": true,
        "type": {
          "kind": "integer"
        }
      }
    ]
  },
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
      },
      {
        "name": "__proto__",
        "required": false,
        "type": {
          "kind": "string"
        }
      }
    ]
  },
  "FixturePageBodyV1": {
    "kind": "object",
    "fields": [
      {
        "name": "items",
        "required": true,
        "type": {
          "kind": "array",
          "items": {
            "kind": "string"
          }
        }
      },
      {
        "name": "gaps",
        "required": true,
        "type": {
          "kind": "array",
          "items": {
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
      "high_priority",
      "cost$x",
      "quote\"slash\\cost$x"
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
  },
  "GapRepairIntentPreimageV1": {
    "kind": "object",
    "fields": [
      {
        "name": "digestDomain",
        "required": true,
        "type": {
          "kind": "enum",
          "values": [
            "ccpocket.gap-repair-intent.v1"
          ]
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
        "name": "readSpecDigest",
        "required": true,
        "type": {
          "kind": "ref",
          "target": "Sha256Hex64"
        }
      },
      {
        "name": "boundaryKind",
        "required": true,
        "type": {
          "kind": "enum",
          "values": [
            "BEFORE",
            "AFTER",
            "BETWEEN"
          ]
        }
      },
      {
        "name": "repairKind",
        "required": true,
        "type": {
          "kind": "enum",
          "values": [
            "NEXT_PROVIDER_PAGE",
            "FULL_BOUNDED_REREAD",
            "NONE"
          ]
        }
      }
    ]
  },
  "MaterializationBeginHeaderPreimageV1": {
    "kind": "object",
    "fields": [
      {
        "name": "digestDomain",
        "required": true,
        "type": {
          "kind": "enum",
          "values": [
            "ccpocket.materialization-begin.v1"
          ]
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
        "name": "manifestDigest",
        "required": true,
        "type": {
          "kind": "ref",
          "target": "Sha256Hex64"
        }
      },
      {
        "name": "coverageDigest",
        "required": true,
        "type": {
          "kind": "ref",
          "target": "Sha256Hex64"
        }
      },
      {
        "name": "pageCount",
        "required": true,
        "type": {
          "kind": "integer"
        }
      }
    ]
  },
  "MaterializationCoveragePreimageV1": {
    "kind": "object",
    "fields": [
      {
        "name": "digestDomain",
        "required": true,
        "type": {
          "kind": "enum",
          "values": [
            "ccpocket.materialization-coverage.v1"
          ]
        }
      },
      {
        "name": "structuralCoverage",
        "required": true,
        "type": {
          "kind": "enum",
          "values": [
            "COMPLETE",
            "PARTIAL",
            "EMPTY_PROVEN"
          ]
        }
      },
      {
        "name": "payloadCoverage",
        "required": true,
        "type": {
          "kind": "enum",
          "values": [
            "COMPLETE",
            "PARTIAL"
          ]
        }
      },
      {
        "name": "gapOrdinals",
        "required": true,
        "type": {
          "kind": "array",
          "items": {
            "kind": "integer"
          }
        }
      }
    ]
  },
  "MaterializationManifestPreimageV1": {
    "kind": "object",
    "fields": [
      {
        "name": "digestDomain",
        "required": true,
        "type": {
          "kind": "enum",
          "values": [
            "ccpocket.materialization-manifest.v1"
          ]
        }
      },
      {
        "name": "algorithmVersion",
        "required": true,
        "type": {
          "kind": "integer"
        }
      },
      {
        "name": "pageCount",
        "required": true,
        "type": {
          "kind": "integer"
        }
      },
      {
        "name": "orderedPageDigests",
        "required": true,
        "type": {
          "kind": "array",
          "items": {
            "kind": "ref",
            "target": "Sha256Hex64"
          }
        }
      },
      {
        "name": "orderDigest",
        "required": true,
        "type": {
          "kind": "ref",
          "target": "Sha256Hex64"
        }
      },
      {
        "name": "coverageDigest",
        "required": true,
        "type": {
          "kind": "ref",
          "target": "Sha256Hex64"
        }
      }
    ]
  },
  "MaterializationOrderPreimageV1": {
    "kind": "union",
    "discriminator": "domain",
    "variants": [
      {
        "tag": "CATALOG",
        "fields": [
          {
            "name": "digestDomain",
            "required": true,
            "type": {
              "kind": "enum",
              "values": [
                "ccpocket.materialization-order.v1"
              ]
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
            "name": "orderedSessionIds",
            "required": true,
            "type": {
              "kind": "array",
              "items": {
                "kind": "string"
              }
            }
          }
        ]
      },
      {
        "tag": "TIMELINE",
        "fields": [
          {
            "name": "digestDomain",
            "required": true,
            "type": {
              "kind": "enum",
              "values": [
                "ccpocket.materialization-order.v1"
              ]
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
            "name": "orderedTimelineIds",
            "required": true,
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
  "MaterializationPagePreimageV1": {
    "kind": "object",
    "fields": [
      {
        "name": "digestDomain",
        "required": true,
        "type": {
          "kind": "enum",
          "values": [
            "ccpocket.materialization-page.v1"
          ]
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
        "name": "pageIndex",
        "required": true,
        "type": {
          "kind": "integer"
        }
      },
      {
        "name": "pageCount",
        "required": true,
        "type": {
          "kind": "integer"
        }
      },
      {
        "name": "previousPageDigest",
        "required": false,
        "type": {
          "kind": "ref",
          "target": "Sha256Hex64"
        }
      },
      {
        "name": "body",
        "required": true,
        "type": {
          "kind": "ref",
          "target": "FixturePageBodyV1"
        }
      }
    ]
  },
  "MaterializationReceiptPreimageV1": {
    "kind": "object",
    "fields": [
      {
        "name": "digestDomain",
        "required": true,
        "type": {
          "kind": "enum",
          "values": [
            "ccpocket.materialization-receipt.v1"
          ]
        }
      },
      {
        "name": "receiptId",
        "required": true,
        "type": {
          "kind": "string"
        }
      },
      {
        "name": "beginHeaderDigest",
        "required": true,
        "type": {
          "kind": "ref",
          "target": "Sha256Hex64"
        }
      },
      {
        "name": "manifestDigest",
        "required": true,
        "type": {
          "kind": "ref",
          "target": "Sha256Hex64"
        }
      },
      {
        "name": "status",
        "required": true,
        "type": {
          "kind": "enum",
          "values": [
            "VERIFIED"
          ]
        }
      },
      {
        "name": "stagedBytes",
        "required": true,
        "type": {
          "kind": "integer"
        }
      }
    ]
  },
  "OperationFingerprintPreimageV1": {
    "kind": "object",
    "fields": [
      {
        "name": "digestDomain",
        "required": true,
        "type": {
          "kind": "enum",
          "values": [
            "ccpocket.operation-fingerprint.v1"
          ]
        }
      },
      {
        "name": "operationCode",
        "required": true,
        "type": {
          "kind": "enum",
          "values": [
            "START_TURN",
            "EDIT_QUEUE"
          ]
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
        "name": "payloadDigest",
        "required": true,
        "type": {
          "kind": "ref",
          "target": "Sha256Hex64"
        }
      },
      {
        "name": "preconditionDigest",
        "required": true,
        "type": {
          "kind": "ref",
          "target": "Sha256Hex64"
        }
      },
      {
        "name": "sequence",
        "required": true,
        "type": {
          "kind": "integer"
        }
      }
    ]
  },
  "ProviderReadEvidencePreimageV1": {
    "kind": "object",
    "fields": [
      {
        "name": "digestDomain",
        "required": true,
        "type": {
          "kind": "enum",
          "values": [
            "ccpocket.provider-read-evidence.v1"
          ]
        }
      },
      {
        "name": "providerMethod",
        "required": true,
        "type": {
          "kind": "enum",
          "values": [
            "THREAD_TURNS_LIST"
          ]
        }
      },
      {
        "name": "codexBuildDigest",
        "required": true,
        "type": {
          "kind": "ref",
          "target": "Sha256Hex64"
        }
      },
      {
        "name": "readGeneration",
        "required": true,
        "type": {
          "kind": "integer"
        }
      },
      {
        "name": "resultDigest",
        "required": true,
        "type": {
          "kind": "ref",
          "target": "Sha256Hex64"
        }
      },
      {
        "name": "resultCount",
        "required": true,
        "type": {
          "kind": "integer"
        }
      }
    ]
  },
  "Sha256Hex64": {
    "kind": "string"
  }
} as Record<string, ContractNode>;
const digestDomainRules = {
  "CanonicalProfileProbePreimageV1": {
    "kind": "object",
    "value": "ccpocket.canonical-profile-probe.v1"
  },
  "GapRepairIntentPreimageV1": {
    "kind": "object",
    "value": "ccpocket.gap-repair-intent.v1"
  },
  "MaterializationBeginHeaderPreimageV1": {
    "kind": "object",
    "value": "ccpocket.materialization-begin.v1"
  },
  "MaterializationCoveragePreimageV1": {
    "kind": "object",
    "value": "ccpocket.materialization-coverage.v1"
  },
  "MaterializationManifestPreimageV1": {
    "kind": "object",
    "value": "ccpocket.materialization-manifest.v1"
  },
  "MaterializationOrderPreimageV1": {
    "kind": "union",
    "discriminator": "domain",
    "variants": [
      {
        "tag": "CATALOG",
        "value": "ccpocket.materialization-order.v1"
      },
      {
        "tag": "TIMELINE",
        "value": "ccpocket.materialization-order.v1"
      }
    ]
  },
  "MaterializationPagePreimageV1": {
    "kind": "object",
    "value": "ccpocket.materialization-page.v1"
  },
  "MaterializationReceiptPreimageV1": {
    "kind": "object",
    "value": "ccpocket.materialization-receipt.v1"
  },
  "OperationFingerprintPreimageV1": {
    "kind": "object",
    "value": "ccpocket.operation-fingerprint.v1"
  },
  "ProviderReadEvidencePreimageV1": {
    "kind": "object",
    "value": "ccpocket.provider-read-evidence.v1"
  }
} as Record<string, DigestDomainRule>;
const sha256Hex64 = /^[0-9a-f]{64}$/;
const utf8Encoder = new TextEncoder();

function assertUnicodeScalarString(value: string, path: string): void {
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code >= 0xd800 && code <= 0xdbff) {
      if (index + 1 >= value.length) throw new TypeError(path + ': lone high surrogate');
      const low = value.charCodeAt(index + 1);
      if (low < 0xdc00 || low > 0xdfff) throw new TypeError(path + ': lone high surrogate');
      index += 1;
    } else if (code >= 0xdc00 && code <= 0xdfff) {
      throw new TypeError(path + ': lone low surrogate');
    }
  }
}

function assertSemanticType(typeId: string, value: JsonSnapshot, path: string): void {
  if (typeId === "Sha256Hex64" && (typeof value !== 'string' || !sha256Hex64.test(value))) {
    throw new TypeError(path + ': expected lowercase SHA-256 hex64');
  }
}

function recordDescriptors(value: unknown, path: string): Map<string, PropertyDescriptor> {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) throw new TypeError(path + ': expected object');
  if (isProxy(value)) throw new TypeError(path + ': proxy objects are not contract data');
  const prototype = Object.getPrototypeOf(value);
  if (prototype !== Object.prototype && prototype !== null) throw new TypeError(path + ': expected plain data object');
  const descriptors = Object.getOwnPropertyDescriptors(value);
  const result = new Map<string, PropertyDescriptor>();
  for (const key of Reflect.ownKeys(value)) {
    if (typeof key !== 'string') throw new TypeError(path + ': symbol fields are not allowed');
    assertUnicodeScalarString(key, path + '.<key>');
    const descriptor = descriptors[key];
    if (!descriptor || !descriptor.enumerable || !Object.prototype.hasOwnProperty.call(descriptor, 'value')) {
      throw new TypeError(path + '.' + key + ': expected enumerable own data field');
    }
    result.set(key, descriptor);
  }
  return result;
}

function arrayDescriptors(value: ReadonlyArray<unknown>, path: string): Map<number, PropertyDescriptor> {
  if (isProxy(value)) throw new TypeError(path + ': proxy arrays are not contract data');
  if (Object.getPrototypeOf(value) !== Array.prototype) throw new TypeError(path + ': expected plain array');
  const descriptors = Object.getOwnPropertyDescriptors(value);
  const result = new Map<number, PropertyDescriptor>();
  for (const key of Reflect.ownKeys(value)) {
    if (key === 'length') continue;
    if (typeof key !== 'string') throw new TypeError(path + ': symbol array fields are not allowed');
    const index = Number(key);
    if (!Number.isInteger(index) || index < 0 || index >= value.length || String(index) !== key) {
      throw new TypeError(path + '.' + key + ': unexpected array field');
    }
    const descriptor = descriptors[key];
    if (!descriptor || !descriptor.enumerable || !Object.prototype.hasOwnProperty.call(descriptor, 'value')) {
      throw new TypeError(path + '[' + index + ']: expected enumerable own data entry');
    }
    result.set(index, descriptor);
  }
  if (result.size !== value.length) throw new TypeError(path + ': sparse arrays are not allowed');
  return result;
}

function snapshotFields(
  fields: ReadonlyArray<ContractField>,
  value: unknown,
  path: string,
  depth: number,
  state: SnapshotState,
  discriminator: { readonly key: string; readonly value: string } | undefined,
  capturedDescriptors?: Map<string, PropertyDescriptor>,
): JsonSnapshotObject {
  const descriptors = capturedDescriptors ?? recordDescriptors(value, path);
  const allowed = new Set(fields.map((field) => field.name));
  if (discriminator) allowed.add(discriminator.key);
  for (const key of descriptors.keys()) if (!allowed.has(key)) throw new TypeError(path + '.' + key + ': unknown field');
  if (discriminator) {
    const descriptor = descriptors.get(discriminator.key);
    if (!descriptor || descriptor.value !== discriminator.value) throw new TypeError(path + '.' + discriminator.key + ': invalid discriminator');
    assertUnicodeScalarString(discriminator.value, path + '.' + discriminator.key);
    if (++state.nodes > 100000) throw new TypeError(path + '.' + discriminator.key + ': contract node limit exceeded');
  }
  const result: Record<string, JsonSnapshot> = Object.create(null);
  if (discriminator) result[discriminator.key] = discriminator.value;
  for (const field of fields) {
    const descriptor = descriptors.get(field.name);
    if (!descriptor) {
      if (field.required) throw new TypeError(path + '.' + field.name + ': required');
      continue;
    }
    result[field.name] = snapshotNode(field.type, descriptor.value, path + '.' + field.name, depth + 1, state);
  }
  return result;
}

function snapshotNode(node: ContractNode, value: unknown, path: string, depth: number, state: SnapshotState): JsonSnapshot {
  if (depth > 512) throw new TypeError(path + ': contract nesting is too deep');
  if (node.kind !== 'ref' && ++state.nodes > 100000) throw new TypeError(path + ': contract node limit exceeded');
  switch (node.kind) {
    case 'string':
      if (typeof value !== 'string') throw new TypeError(path + ': expected string');
      assertUnicodeScalarString(value, path); return value;
    case 'integer': if (!Number.isSafeInteger(value)) throw new TypeError(path + ': expected safe integer'); return value as number;
    case 'boolean': if (typeof value !== 'boolean') throw new TypeError(path + ': expected boolean'); return value;
    case 'enum':
      if (typeof value !== 'string' || !node.values.includes(value)) throw new TypeError(path + ': invalid enum');
      assertUnicodeScalarString(value, path); return value;
    case 'ref': {
      if (!Object.hasOwn(contractNodes, node.target)) throw new TypeError(path + ': unknown type ' + node.target);
      const target = contractNodes[node.target];
      const snapshot = snapshotNode(target, value, path, depth, state);
      assertSemanticType(node.target, snapshot, path); return snapshot;
    }
    case 'array': {
      if (!Array.isArray(value)) throw new TypeError(path + ': expected array');
      if (state.active.has(value)) throw new TypeError(path + ': cyclic value');
      state.active.add(value);
      try {
        const descriptors = arrayDescriptors(value, path);
        return Array.from({ length: value.length }, (_, index) =>
          snapshotNode(node.items, descriptors.get(index)?.value, path + '[' + index + ']', depth + 1, state));
      } finally { state.active.delete(value); }
    }
    case 'map': {
      if (value === null || typeof value !== 'object') throw new TypeError(path + ': expected string-key map');
      if (state.active.has(value)) throw new TypeError(path + ': cyclic value');
      state.active.add(value);
      try {
        const descriptors = recordDescriptors(value, path);
        const result: Record<string, JsonSnapshot> = Object.create(null);
        for (const [key, descriptor] of descriptors) {
          assertUnicodeScalarString(key, path + '.<key>');
          result[key] = snapshotNode(node.values, descriptor.value, path + '.' + key, depth + 1, state);
        }
        return result;
      } finally { state.active.delete(value); }
    }
    case 'object':
      if (value === null || typeof value !== 'object') throw new TypeError(path + ': expected object');
      if (state.active.has(value)) throw new TypeError(path + ': cyclic value');
      state.active.add(value);
      try { return snapshotFields(node.fields, value, path, depth, state, undefined); } finally { state.active.delete(value); }
    case 'union': {
      if (value === null || typeof value !== 'object') throw new TypeError(path + ': expected union object');
      if (state.active.has(value)) throw new TypeError(path + ': cyclic value');
      state.active.add(value);
      try {
        const descriptors = recordDescriptors(value, path);
        const tag = descriptors.get(node.discriminator)?.value;
        const variant = node.variants.find((candidate) => candidate.tag === tag);
        if (!variant) throw new TypeError(path + '.' + node.discriminator + ': invalid discriminator');
        return snapshotFields(variant.fields, value, path, depth, state, { key: node.discriminator, value: variant.tag }, descriptors);
      } finally { state.active.delete(value); }
    }
  }
}

function snapshotContractType(typeId: string, value: unknown): JsonSnapshot {
  if (!Object.hasOwn(contractNodes, typeId)) throw new TypeError('unknown contract type ' + typeId);
  const node = contractNodes[typeId];
  const snapshot = snapshotNode(node, value, '$', 0, { active: new WeakSet<object>(), nodes: 0 });
  assertSemanticType(typeId, snapshot, '$');
  return snapshot;
}

function assertDigestDomain(typeId: string, value: JsonSnapshot): void {
  const rule = digestDomainRules[typeId];
  if (!rule || typeof value !== 'object' || value === null || Array.isArray(value)) throw new TypeError(typeId + ': invalid digest preimage authority');
  if (rule.kind === 'object') {
    if (value.digestDomain !== rule.value) throw new TypeError(typeId + '.digestDomain: invalid digest domain');
    return;
  }
  const tag = value[rule.discriminator];
  const variant = rule.variants.find((candidate) => candidate.tag === tag);
  if (!variant || value.digestDomain !== variant.value) throw new TypeError(typeId + '.digestDomain: invalid digest domain');
}

function canonicalJson(value: JsonSnapshot): string {
  if (typeof value === 'string') return JSON.stringify(value);
  if (typeof value === 'number') return Object.is(value, -0) ? '0' : String(value);
  if (typeof value === 'boolean') return value ? 'true' : 'false';
  if (Array.isArray(value)) return '[' + value.map(canonicalJson).join(',') + ']';
  return '{' + Object.keys(value).sort().map((key) => JSON.stringify(key) + ':' + canonicalJson(value[key])).join(',') + '}';
}

function canonicalBytesForPreimage(typeId: string, value: unknown): Uint8Array {
  const snapshot = snapshotContractType(typeId, value);
  assertDigestDomain(typeId, snapshot);
  return utf8Encoder.encode(canonicalJson(snapshot));
}

export function assertContractType(typeId: string, value: unknown): void {
  snapshotContractType(typeId, value);
}

export function decodeCanonicalProfileProbePreimageV1(value: unknown): CanonicalProfileProbePreimageV1 {
  return snapshotContractType("CanonicalProfileProbePreimageV1", value) as unknown as CanonicalProfileProbePreimageV1;
}

export function encodeCanonicalProfileProbePreimageV1(value: CanonicalProfileProbePreimageV1): unknown {
  return snapshotContractType("CanonicalProfileProbePreimageV1", value);
}

export function decodeFixtureEnvelope(value: unknown): FixtureEnvelope {
  return snapshotContractType("FixtureEnvelope", value) as unknown as FixtureEnvelope;
}

export function encodeFixtureEnvelope(value: FixtureEnvelope): unknown {
  return snapshotContractType("FixtureEnvelope", value);
}

export function decodeFixturePageBodyV1(value: unknown): FixturePageBodyV1 {
  return snapshotContractType("FixturePageBodyV1", value) as unknown as FixturePageBodyV1;
}

export function encodeFixturePageBodyV1(value: FixturePageBodyV1): unknown {
  return snapshotContractType("FixturePageBodyV1", value);
}

export function decodeFixturePayload(value: unknown): FixturePayload {
  return snapshotContractType("FixturePayload", value) as unknown as FixturePayload;
}

export function encodeFixturePayload(value: FixturePayload): unknown {
  return snapshotContractType("FixturePayload", value);
}

export function decodeFixturePriority(value: unknown): FixturePriority {
  return snapshotContractType("FixturePriority", value) as unknown as FixturePriority;
}

export function encodeFixturePriority(value: FixturePriority): unknown {
  return snapshotContractType("FixturePriority", value);
}

export function decodeFixtureSourceRef(value: unknown): FixtureSourceRef {
  return snapshotContractType("FixtureSourceRef", value) as unknown as FixtureSourceRef;
}

export function encodeFixtureSourceRef(value: FixtureSourceRef): unknown {
  return snapshotContractType("FixtureSourceRef", value);
}

export function decodeGapRepairIntentPreimageV1(value: unknown): GapRepairIntentPreimageV1 {
  return snapshotContractType("GapRepairIntentPreimageV1", value) as unknown as GapRepairIntentPreimageV1;
}

export function encodeGapRepairIntentPreimageV1(value: GapRepairIntentPreimageV1): unknown {
  return snapshotContractType("GapRepairIntentPreimageV1", value);
}

export function decodeMaterializationBeginHeaderPreimageV1(value: unknown): MaterializationBeginHeaderPreimageV1 {
  return snapshotContractType("MaterializationBeginHeaderPreimageV1", value) as unknown as MaterializationBeginHeaderPreimageV1;
}

export function encodeMaterializationBeginHeaderPreimageV1(value: MaterializationBeginHeaderPreimageV1): unknown {
  return snapshotContractType("MaterializationBeginHeaderPreimageV1", value);
}

export function decodeMaterializationCoveragePreimageV1(value: unknown): MaterializationCoveragePreimageV1 {
  return snapshotContractType("MaterializationCoveragePreimageV1", value) as unknown as MaterializationCoveragePreimageV1;
}

export function encodeMaterializationCoveragePreimageV1(value: MaterializationCoveragePreimageV1): unknown {
  return snapshotContractType("MaterializationCoveragePreimageV1", value);
}

export function decodeMaterializationManifestPreimageV1(value: unknown): MaterializationManifestPreimageV1 {
  return snapshotContractType("MaterializationManifestPreimageV1", value) as unknown as MaterializationManifestPreimageV1;
}

export function encodeMaterializationManifestPreimageV1(value: MaterializationManifestPreimageV1): unknown {
  return snapshotContractType("MaterializationManifestPreimageV1", value);
}

export function decodeMaterializationOrderPreimageV1(value: unknown): MaterializationOrderPreimageV1 {
  return snapshotContractType("MaterializationOrderPreimageV1", value) as unknown as MaterializationOrderPreimageV1;
}

export function encodeMaterializationOrderPreimageV1(value: MaterializationOrderPreimageV1): unknown {
  return snapshotContractType("MaterializationOrderPreimageV1", value);
}

export function decodeMaterializationPagePreimageV1(value: unknown): MaterializationPagePreimageV1 {
  return snapshotContractType("MaterializationPagePreimageV1", value) as unknown as MaterializationPagePreimageV1;
}

export function encodeMaterializationPagePreimageV1(value: MaterializationPagePreimageV1): unknown {
  return snapshotContractType("MaterializationPagePreimageV1", value);
}

export function decodeMaterializationReceiptPreimageV1(value: unknown): MaterializationReceiptPreimageV1 {
  return snapshotContractType("MaterializationReceiptPreimageV1", value) as unknown as MaterializationReceiptPreimageV1;
}

export function encodeMaterializationReceiptPreimageV1(value: MaterializationReceiptPreimageV1): unknown {
  return snapshotContractType("MaterializationReceiptPreimageV1", value);
}

export function decodeOperationFingerprintPreimageV1(value: unknown): OperationFingerprintPreimageV1 {
  return snapshotContractType("OperationFingerprintPreimageV1", value) as unknown as OperationFingerprintPreimageV1;
}

export function encodeOperationFingerprintPreimageV1(value: OperationFingerprintPreimageV1): unknown {
  return snapshotContractType("OperationFingerprintPreimageV1", value);
}

export function decodeProviderReadEvidencePreimageV1(value: unknown): ProviderReadEvidencePreimageV1 {
  return snapshotContractType("ProviderReadEvidencePreimageV1", value) as unknown as ProviderReadEvidencePreimageV1;
}

export function encodeProviderReadEvidencePreimageV1(value: ProviderReadEvidencePreimageV1): unknown {
  return snapshotContractType("ProviderReadEvidencePreimageV1", value);
}

export function decodeSha256Hex64(value: unknown): Sha256Hex64 {
  return snapshotContractType("Sha256Hex64", value) as unknown as Sha256Hex64;
}

export function encodeSha256Hex64(value: Sha256Hex64): unknown {
  return snapshotContractType("Sha256Hex64", value);
}

export function canonicalBytesCanonicalProfileProbePreimageV1(value: CanonicalProfileProbePreimageV1): Uint8Array {
  return canonicalBytesForPreimage("CanonicalProfileProbePreimageV1", value);
}

export function digestCanonicalProfileProbePreimageV1(value: CanonicalProfileProbePreimageV1): string {
  return createHash('sha256').update(canonicalBytesCanonicalProfileProbePreimageV1(value)).digest('hex');
}

export function canonicalBytesGapRepairIntentPreimageV1(value: GapRepairIntentPreimageV1): Uint8Array {
  return canonicalBytesForPreimage("GapRepairIntentPreimageV1", value);
}

export function digestGapRepairIntentPreimageV1(value: GapRepairIntentPreimageV1): string {
  return createHash('sha256').update(canonicalBytesGapRepairIntentPreimageV1(value)).digest('hex');
}

export function canonicalBytesMaterializationBeginHeaderPreimageV1(value: MaterializationBeginHeaderPreimageV1): Uint8Array {
  return canonicalBytesForPreimage("MaterializationBeginHeaderPreimageV1", value);
}

export function digestMaterializationBeginHeaderPreimageV1(value: MaterializationBeginHeaderPreimageV1): string {
  return createHash('sha256').update(canonicalBytesMaterializationBeginHeaderPreimageV1(value)).digest('hex');
}

export function canonicalBytesMaterializationCoveragePreimageV1(value: MaterializationCoveragePreimageV1): Uint8Array {
  return canonicalBytesForPreimage("MaterializationCoveragePreimageV1", value);
}

export function digestMaterializationCoveragePreimageV1(value: MaterializationCoveragePreimageV1): string {
  return createHash('sha256').update(canonicalBytesMaterializationCoveragePreimageV1(value)).digest('hex');
}

export function canonicalBytesMaterializationManifestPreimageV1(value: MaterializationManifestPreimageV1): Uint8Array {
  return canonicalBytesForPreimage("MaterializationManifestPreimageV1", value);
}

export function digestMaterializationManifestPreimageV1(value: MaterializationManifestPreimageV1): string {
  return createHash('sha256').update(canonicalBytesMaterializationManifestPreimageV1(value)).digest('hex');
}

export function canonicalBytesMaterializationOrderPreimageV1(value: MaterializationOrderPreimageV1): Uint8Array {
  return canonicalBytesForPreimage("MaterializationOrderPreimageV1", value);
}

export function digestMaterializationOrderPreimageV1(value: MaterializationOrderPreimageV1): string {
  return createHash('sha256').update(canonicalBytesMaterializationOrderPreimageV1(value)).digest('hex');
}

export function canonicalBytesMaterializationPagePreimageV1(value: MaterializationPagePreimageV1): Uint8Array {
  return canonicalBytesForPreimage("MaterializationPagePreimageV1", value);
}

export function digestMaterializationPagePreimageV1(value: MaterializationPagePreimageV1): string {
  return createHash('sha256').update(canonicalBytesMaterializationPagePreimageV1(value)).digest('hex');
}

export function canonicalBytesMaterializationReceiptPreimageV1(value: MaterializationReceiptPreimageV1): Uint8Array {
  return canonicalBytesForPreimage("MaterializationReceiptPreimageV1", value);
}

export function digestMaterializationReceiptPreimageV1(value: MaterializationReceiptPreimageV1): string {
  return createHash('sha256').update(canonicalBytesMaterializationReceiptPreimageV1(value)).digest('hex');
}

export function canonicalBytesOperationFingerprintPreimageV1(value: OperationFingerprintPreimageV1): Uint8Array {
  return canonicalBytesForPreimage("OperationFingerprintPreimageV1", value);
}

export function digestOperationFingerprintPreimageV1(value: OperationFingerprintPreimageV1): string {
  return createHash('sha256').update(canonicalBytesOperationFingerprintPreimageV1(value)).digest('hex');
}

export function canonicalBytesProviderReadEvidencePreimageV1(value: ProviderReadEvidencePreimageV1): Uint8Array {
  return canonicalBytesForPreimage("ProviderReadEvidencePreimageV1", value);
}

export function digestProviderReadEvidencePreimageV1(value: ProviderReadEvidencePreimageV1): string {
  return createHash('sha256').update(canonicalBytesProviderReadEvidencePreimageV1(value)).digest('hex');
}
