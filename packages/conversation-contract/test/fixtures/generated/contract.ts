// @generated from conversation contract cdd9b5622b7af2917865f30af72cb96a976289ab0569f5464b5dba1b9ba15d6d; DO NOT EDIT.
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

export type FixtureAmbiguousOneOf = string | string;

export type FixtureCanonicalOrderSet = ReadonlyArray<FixtureOneOf>;

export interface FixtureConstrainedRecord {
  readonly "nullableValue": string | null;
  readonly "fixed": "FIXED";
  readonly "version": 1;
  readonly "bounded": number;
  readonly "disabled": false;
  readonly "items": ReadonlyArray<FixtureConstraintItem>;
  readonly "tags": ReadonlyArray<string>;
}

export interface FixtureConstraintItem {
  readonly "identity": { readonly "id": string };
  readonly "ordinal": number;
  readonly "label": string;
}

export interface FixtureEnvelope {
  readonly "id": string;
  readonly "source": FixtureSourceRef;
  readonly "priority": FixturePriority;
  readonly "payload": FixturePayload;
  readonly "metadata"?: Readonly<Record<string, string>>;
  readonly "__proto__"?: string;
}

export type FixtureOneOf = { readonly "left": string } | { readonly "right": number };

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

export type FixtureUntaggedPreimageV1 = { readonly "digestDomain": "ccpocket.fixture-untagged.v1"; readonly "left": string | null } | { readonly "digestDomain": "ccpocket.fixture-untagged.v1"; readonly "right": number };

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
  | { readonly kind: 'string'; readonly const?: string; readonly pattern?: string }
  | { readonly kind: 'integer'; readonly const?: number; readonly minimum?: number; readonly maximum?: number }
  | { readonly kind: 'boolean'; readonly const?: boolean }
  | { readonly kind: 'enum'; readonly values: ReadonlyArray<string>; readonly const?: string }
  | { readonly kind: 'ref'; readonly target: string }
  | { readonly kind: 'nullable'; readonly inner: ContractNode }
  | { readonly kind: 'array'; readonly items: ContractNode; readonly minItems?: number; readonly maxItems?: number; readonly uniqueItems?: boolean; readonly uniqueBy?: ReadonlyArray<string>; readonly orderBy?: ReadonlyArray<string> }
  | { readonly kind: 'map'; readonly values: ContractNode }
  | { readonly kind: 'object'; readonly fields: ReadonlyArray<ContractField> }
  | { readonly kind: 'oneOf'; readonly variants: ReadonlyArray<ContractNode> }
  | { readonly kind: 'union'; readonly discriminator: string; readonly variants: ReadonlyArray<ContractVariant> };
type ContractField = { readonly name: string; readonly required: boolean; readonly type: ContractNode };
type ContractVariant = { readonly tag: string; readonly fields: ReadonlyArray<ContractField> };
type JsonSnapshot = null | string | number | boolean | JsonSnapshot[] | JsonSnapshotObject;
type JsonSnapshotObject = { readonly [key: string]: JsonSnapshot };
type SnapshotState = { readonly active: Set<object>; nodes: number };
type DigestDomainRule =
  | null
  | { readonly kind: 'object'; readonly value: string }
  | { readonly kind: 'oneOf'; readonly values: ReadonlyArray<string> }
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
  "FixtureAmbiguousOneOf": {
    "kind": "oneOf",
    "variants": [
      {
        "kind": "string",
        "pattern": "^a"
      },
      {
        "kind": "string",
        "pattern": "a$"
      }
    ]
  },
  "FixtureCanonicalOrderSet": {
    "kind": "array",
    "items": {
      "kind": "ref",
      "target": "FixtureOneOf"
    },
    "minItems": 1,
    "maxItems": 3,
    "orderBy": [
      "$"
    ]
  },
  "FixtureConstrainedRecord": {
    "kind": "object",
    "fields": [
      {
        "name": "nullableValue",
        "required": true,
        "type": {
          "kind": "nullable",
          "inner": {
            "kind": "string",
            "pattern": "^value-[0-9]+$"
          }
        }
      },
      {
        "name": "fixed",
        "required": true,
        "type": {
          "kind": "string",
          "const": "FIXED"
        }
      },
      {
        "name": "version",
        "required": true,
        "type": {
          "kind": "integer",
          "const": 1
        }
      },
      {
        "name": "bounded",
        "required": true,
        "type": {
          "kind": "integer",
          "minimum": 1,
          "maximum": 3
        }
      },
      {
        "name": "disabled",
        "required": true,
        "type": {
          "kind": "boolean",
          "const": false
        }
      },
      {
        "name": "items",
        "required": true,
        "type": {
          "kind": "array",
          "items": {
            "kind": "ref",
            "target": "FixtureConstraintItem"
          },
          "minItems": 1,
          "maxItems": 3,
          "uniqueBy": [
            "identity.id"
          ],
          "orderBy": [
            "ordinal"
          ]
        }
      },
      {
        "name": "tags",
        "required": true,
        "type": {
          "kind": "array",
          "items": {
            "kind": "string",
            "pattern": "^[a-z]+$"
          },
          "minItems": 1,
          "maxItems": 3,
          "uniqueItems": true
        }
      }
    ]
  },
  "FixtureConstraintItem": {
    "kind": "object",
    "fields": [
      {
        "name": "identity",
        "required": true,
        "type": {
          "kind": "object",
          "fields": [
            {
              "name": "id",
              "required": true,
              "type": {
                "kind": "string",
                "pattern": "^[a-z]+$"
              }
            }
          ]
        }
      },
      {
        "name": "ordinal",
        "required": true,
        "type": {
          "kind": "integer",
          "minimum": 0,
          "maximum": 3
        }
      },
      {
        "name": "label",
        "required": true,
        "type": {
          "kind": "string",
          "pattern": "^item-[a-z]+$"
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
  "FixtureOneOf": {
    "kind": "oneOf",
    "variants": [
      {
        "kind": "object",
        "fields": [
          {
            "name": "left",
            "required": true,
            "type": {
              "kind": "string"
            }
          }
        ]
      },
      {
        "kind": "object",
        "fields": [
          {
            "name": "right",
            "required": true,
            "type": {
              "kind": "integer"
            }
          }
        ]
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
  "FixtureUntaggedPreimageV1": {
    "kind": "oneOf",
    "variants": [
      {
        "kind": "object",
        "fields": [
          {
            "name": "digestDomain",
            "required": true,
            "type": {
              "kind": "string",
              "const": "ccpocket.fixture-untagged.v1"
            }
          },
          {
            "name": "left",
            "required": true,
            "type": {
              "kind": "nullable",
              "inner": {
                "kind": "string"
              }
            }
          }
        ]
      },
      {
        "kind": "object",
        "fields": [
          {
            "name": "digestDomain",
            "required": true,
            "type": {
              "kind": "string",
              "const": "ccpocket.fixture-untagged.v1"
            }
          },
          {
            "name": "right",
            "required": true,
            "type": {
              "kind": "integer",
              "minimum": 0,
              "maximum": 9
            }
          }
        ]
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
  "FixtureUntaggedPreimageV1": {
    "kind": "object",
    "value": "ccpocket.fixture-untagged.v1"
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

function dereferenceContractNode(node: ContractNode, path: string): ContractNode {
  const seen = new Set<string>();
  let current = node;
  while (current.kind === 'ref') {
    if (seen.has(current.target) || !Object.hasOwn(contractNodes, current.target)) throw new TypeError(path + ': invalid selector type reference');
    seen.add(current.target);
    current = contractNodes[current.target];
  }
  return current;
}

function selectedContractNodes(itemNode: ContractNode, selector: string, path: string): ReadonlyArray<ContractNode> {
  if (selector === '$') return [dereferenceContractNode(itemNode, path)];
  let nodes: ReadonlyArray<ContractNode> = [itemNode];
  for (const segment of selector.split('.')) {
    const next: ContractNode[] = [];
    for (const rawNode of nodes) {
      const node = dereferenceContractNode(rawNode, path);
      if (node.kind === 'object') {
        const field = node.fields.find((candidate) => candidate.name === segment);
        if (!field) throw new TypeError(path + ': unknown collection selector ' + selector);
        next.push(field.type);
      } else if (node.kind === 'union') {
        if (segment === node.discriminator) {
          next.push({ kind: 'enum', values: node.variants.map((variant) => variant.tag) });
        } else {
          for (const variant of node.variants) {
            const field = variant.fields.find((candidate) => candidate.name === segment);
            if (!field) throw new TypeError(path + ': selector ' + selector + ' is absent from ' + variant.tag);
            next.push(field.type);
          }
        }
      } else if (node.kind === 'oneOf') {
        for (const variant of node.variants) next.push(...selectedContractNodes(variant, segment, path));
      } else {
        throw new TypeError(path + ': collection selectors require object, union, or oneOf items');
      }
    }
    nodes = next;
  }
  return nodes;
}

function selectorEnumOrder(itemNode: ContractNode, selector: string, path: string): ReadonlyArray<string> | undefined {
  const result: string[] = [];
  const seen = new Set<string>();
  for (const selected of selectedContractNodes(itemNode, selector, path)) {
    let node = dereferenceContractNode(selected, path);
    if (node.kind === 'nullable') node = dereferenceContractNode(node.inner, path);
    if (node.kind !== 'enum') continue;
    for (const value of node.values) if (!seen.has(value)) { seen.add(value); result.push(value); }
  }
  return result.length === 0 ? undefined : result;
}

function snapshotSelectorValue(value: JsonSnapshot, selector: string, path: string): JsonSnapshot {
  let current = value;
  for (const segment of selector.split('.')) {
    if (current === null || typeof current !== 'object' || Array.isArray(current) || !Object.hasOwn(current, segment)) {
      throw new TypeError(path + '.' + selector + ': required collection selector');
    }
    current = current[segment];
  }
  return current;
}

function compareUtf16(left: string, right: string): number {
  const length = Math.min(left.length, right.length);
  for (let index = 0; index < length; index += 1) {
    const difference = left.charCodeAt(index) - right.charCodeAt(index);
    if (difference !== 0) return difference;
  }
  return left.length - right.length;
}

function compareConstraintScalar(left: JsonSnapshot, right: JsonSnapshot, enumOrder: ReadonlyArray<string> | undefined): number {
  if (left === right) return 0;
  if (left === null) return -1;
  if (right === null) return 1;
  if (enumOrder && typeof left === 'string' && typeof right === 'string') {
    const leftRank = enumOrder.indexOf(left);
    const rightRank = enumOrder.indexOf(right);
    if (leftRank !== -1 && rightRank !== -1) return leftRank - rightRank;
  }
  if (typeof left === 'number' && typeof right === 'number') return left - right;
  if (typeof left === 'boolean' && typeof right === 'boolean') return left ? 1 : -1;
  if (typeof left === 'string' && typeof right === 'string') return compareUtf16(left, right);
  throw new TypeError('orderBy values have incompatible scalar types');
}

function compareCanonicalBytes(left: JsonSnapshot, right: JsonSnapshot): number {
  const leftBytes = utf8Encoder.encode(canonicalJson(left));
  const rightBytes = utf8Encoder.encode(canonicalJson(right));
  const length = Math.min(leftBytes.length, rightBytes.length);
  for (let index = 0; index < length; index += 1) {
    const difference = leftBytes[index] - rightBytes[index];
    if (difference !== 0) return difference;
  }
  return leftBytes.length - rightBytes.length;
}

function compareArrayEntries(left: JsonSnapshot, right: JsonSnapshot, selectors: ReadonlyArray<string>, itemNode: ContractNode, path: string): number {
  for (const selector of selectors) {
    const comparison = selector === '$'
      ? compareCanonicalBytes(left, right)
      : compareConstraintScalar(
          snapshotSelectorValue(left, selector, path),
          snapshotSelectorValue(right, selector, path),
          selectorEnumOrder(itemNode, selector, path + '.' + selector),
        );
    if (comparison !== 0) return comparison;
  }
  return 0;
}

function assertArrayConstraints(node: ContractNode & { readonly kind: 'array' }, values: ReadonlyArray<JsonSnapshot>, path: string): void {
  const minimum = node.minItems ?? 0;
  const maximum = node.maxItems ?? Number.MAX_SAFE_INTEGER;
  if (values.length < minimum || values.length > maximum) throw new TypeError(path + ': expected between ' + minimum + ' and ' + maximum + ' items');
  if (node.uniqueItems) {
    const seen = new Set<string>();
    for (let index = 0; index < values.length; index += 1) {
      const key = canonicalJson(values[index]);
      if (seen.has(key)) throw new TypeError(path + '[' + index + ']: duplicate array item');
      seen.add(key);
    }
  }
  if (node.uniqueBy) {
    const seen = new Set<string>();
    for (let index = 0; index < values.length; index += 1) {
      const key = canonicalJson(node.uniqueBy.map((selector) => snapshotSelectorValue(values[index], selector, path + '[' + index + ']')));
      if (seen.has(key)) throw new TypeError(path + '[' + index + ']: duplicate uniqueBy fields ' + node.uniqueBy.join(', '));
      seen.add(key);
    }
  }
  if (node.orderBy) {
    for (let index = 1; index < values.length; index += 1) {
      if (compareArrayEntries(values[index - 1], values[index], node.orderBy, node.items, path + '[' + index + ']') > 0) {
        throw new TypeError(path + '[' + index + ']: out of order by ' + node.orderBy.join(', '));
      }
    }
  }
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
      assertUnicodeScalarString(value, path);
      if (Object.hasOwn(node, 'const') && value !== node.const) throw new TypeError(path + ': invalid const');
      if (node.pattern !== undefined && !new RegExp(node.pattern, 'u').test(value)) throw new TypeError(path + ': pattern mismatch');
      return value;
    case 'integer': {
      if (!Number.isSafeInteger(value)) throw new TypeError(path + ': expected safe integer');
      const integer = value as number;
      if (integer < (node.minimum ?? Number.MIN_SAFE_INTEGER) || integer > (node.maximum ?? Number.MAX_SAFE_INTEGER)) throw new TypeError(path + ': integer outside bounds');
      if (Object.hasOwn(node, 'const') && integer !== node.const) throw new TypeError(path + ': invalid const');
      return integer;
    }
    case 'boolean':
      if (typeof value !== 'boolean') throw new TypeError(path + ': expected boolean');
      if (Object.hasOwn(node, 'const') && value !== node.const) throw new TypeError(path + ': invalid const');
      return value;
    case 'enum':
      if (typeof value !== 'string' || !node.values.includes(value)) throw new TypeError(path + ': invalid enum');
      if (Object.hasOwn(node, 'const') && value !== node.const) throw new TypeError(path + ': invalid const');
      assertUnicodeScalarString(value, path); return value;
    case 'nullable':
      return value === null ? null : snapshotNode(node.inner, value, path, depth + 1, state);
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
        const result = Array.from({ length: value.length }, (_, index) =>
          snapshotNode(node.items, descriptors.get(index)?.value, path + '[' + index + ']', depth + 1, state));
        assertArrayConstraints(node, result, path);
        return result;
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
    case 'oneOf': {
      const matches: Array<{ readonly snapshot: JsonSnapshot; readonly nodes: number }> = [];
      for (const variant of node.variants) {
        const branchState: SnapshotState = { active: new Set(state.active), nodes: state.nodes };
        try {
          matches.push({ snapshot: snapshotNode(variant, value, path, depth + 1, branchState), nodes: branchState.nodes });
        } catch (error) {
          if (!(error instanceof TypeError)) throw error;
        }
      }
      if (matches.length === 0) throw new TypeError(path + ': NO_ONE_OF_VARIANT');
      if (matches.length > 1) throw new TypeError(path + ': AMBIGUOUS_ONE_OF_VARIANT');
      state.nodes = matches[0].nodes;
      return matches[0].snapshot;
    }
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
  const snapshot = snapshotNode(node, value, '$', 0, { active: new Set<object>(), nodes: 0 });
  assertSemanticType(typeId, snapshot, '$');
  return snapshot;
}

function assertDigestDomain(typeId: string, value: JsonSnapshot): void {
  const rule = digestDomainRules[typeId];
  if (!Object.hasOwn(digestDomainRules, typeId) || typeof value !== 'object' || value === null || Array.isArray(value)) throw new TypeError(typeId + ': invalid digest preimage authority');
  if (rule === null) return;
  if (rule.kind === 'object') {
    if (value.digestDomain !== rule.value) throw new TypeError(typeId + '.digestDomain: invalid digest domain');
    return;
  }
  if (rule.kind === 'oneOf') {
    if (typeof value.digestDomain !== 'string' || !rule.values.includes(value.digestDomain)) throw new TypeError(typeId + '.digestDomain: invalid digest domain');
    return;
  }
  const tag = value[rule.discriminator];
  const variant = rule.variants.find((candidate) => candidate.tag === tag);
  if (!variant || value.digestDomain !== variant.value) throw new TypeError(typeId + '.digestDomain: invalid digest domain');
}

function canonicalJson(value: JsonSnapshot): string {
  if (value === null) return 'null';
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

export function decodeFixtureAmbiguousOneOf(value: unknown): FixtureAmbiguousOneOf {
  return snapshotContractType("FixtureAmbiguousOneOf", value) as unknown as FixtureAmbiguousOneOf;
}

export function encodeFixtureAmbiguousOneOf(value: FixtureAmbiguousOneOf): unknown {
  return snapshotContractType("FixtureAmbiguousOneOf", value);
}

export function decodeFixtureCanonicalOrderSet(value: unknown): FixtureCanonicalOrderSet {
  return snapshotContractType("FixtureCanonicalOrderSet", value) as unknown as FixtureCanonicalOrderSet;
}

export function encodeFixtureCanonicalOrderSet(value: FixtureCanonicalOrderSet): unknown {
  return snapshotContractType("FixtureCanonicalOrderSet", value);
}

export function decodeFixtureConstrainedRecord(value: unknown): FixtureConstrainedRecord {
  return snapshotContractType("FixtureConstrainedRecord", value) as unknown as FixtureConstrainedRecord;
}

export function encodeFixtureConstrainedRecord(value: FixtureConstrainedRecord): unknown {
  return snapshotContractType("FixtureConstrainedRecord", value);
}

export function decodeFixtureConstraintItem(value: unknown): FixtureConstraintItem {
  return snapshotContractType("FixtureConstraintItem", value) as unknown as FixtureConstraintItem;
}

export function encodeFixtureConstraintItem(value: FixtureConstraintItem): unknown {
  return snapshotContractType("FixtureConstraintItem", value);
}

export function decodeFixtureEnvelope(value: unknown): FixtureEnvelope {
  return snapshotContractType("FixtureEnvelope", value) as unknown as FixtureEnvelope;
}

export function encodeFixtureEnvelope(value: FixtureEnvelope): unknown {
  return snapshotContractType("FixtureEnvelope", value);
}

export function decodeFixtureOneOf(value: unknown): FixtureOneOf {
  return snapshotContractType("FixtureOneOf", value) as unknown as FixtureOneOf;
}

export function encodeFixtureOneOf(value: FixtureOneOf): unknown {
  return snapshotContractType("FixtureOneOf", value);
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

export function decodeFixtureUntaggedPreimageV1(value: unknown): FixtureUntaggedPreimageV1 {
  return snapshotContractType("FixtureUntaggedPreimageV1", value) as unknown as FixtureUntaggedPreimageV1;
}

export function encodeFixtureUntaggedPreimageV1(value: FixtureUntaggedPreimageV1): unknown {
  return snapshotContractType("FixtureUntaggedPreimageV1", value);
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

export function canonicalBytesFixtureUntaggedPreimageV1(value: FixtureUntaggedPreimageV1): Uint8Array {
  return canonicalBytesForPreimage("FixtureUntaggedPreimageV1", value);
}

export function digestFixtureUntaggedPreimageV1(value: FixtureUntaggedPreimageV1): string {
  return createHash('sha256').update(canonicalBytesFixtureUntaggedPreimageV1(value)).digest('hex');
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
