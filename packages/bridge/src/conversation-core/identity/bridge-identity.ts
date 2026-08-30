import {
  createHash,
  createPrivateKey,
  createPublicKey,
  generateKeyPairSync,
  sign as ed25519Sign,
  type KeyObject,
  verify as ed25519Verify,
} from "node:crypto";
import { homedir } from "node:os";
import { join } from "node:path";

import {
  acquireStateMutationLock,
  atomicPrivateWrite,
  preparePrivateStateDirectory,
  readBoundedPrivateFile,
  acquireStateWriterLease,
  STATE_WRITER_LEASE_SUFFIX,
  type StateMutationLockOptions,
} from "./private-state.js";

export const BRIDGE_IDENTITY_VERSION = 1 as const;
export const BRIDGE_IDENTITY_FILE = "bridge-identity-v1.json" as const;

const MAX_IDENTITY_FILE_BYTES = 64 * 1024;
const ED25519_SPKI_PREFIX = Buffer.from("302a300506032b6570032100", "hex");
const BASE64URL_PATTERN = /^[A-Za-z0-9_-]+$/;
const PROOF_VALUE_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$/;
const METHOD_PATTERN = /^[A-Za-z][A-Za-z0-9_-]{0,63}$/;

interface BridgeIdentityFileData {
  version: typeof BRIDGE_IDENTITY_VERSION;
  publicKey: string;
  privateKey: string;
}

export interface BridgeIdentityStoreOptions {
  stateDir?: string;
  lockOptions?: StateMutationLockOptions;
}

export interface BridgeNonceProofInput {
  bridgeInstanceId: string;
  nonce: string;
  authMode: string;
  methods: readonly string[];
}

export interface BridgeIdentityProof extends BridgeNonceProofInput {
  version: typeof BRIDGE_IDENTITY_VERSION;
  bridgeIdentityId: string;
  publicKey: string;
  methods: string[];
  signedPayload: string;
  signature: string;
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function hasExactKeys(
  value: Record<string, unknown>,
  keys: readonly string[],
): boolean {
  const actual = Object.keys(value).sort();
  const expected = [...keys].sort();
  return (
    actual.length === expected.length &&
    actual.every((key, index) => key === expected[index])
  );
}

function encodeBase64Url(value: Buffer): string {
  return value.toString("base64url");
}

function decodeCanonicalBase64Url(value: string, description: string): Buffer {
  if (!BASE64URL_PATTERN.test(value)) {
    throw new Error(`${description} is not canonical base64url`);
  }
  const decoded = Buffer.from(value, "base64url");
  if (decoded.length === 0 || encodeBase64Url(decoded) !== value) {
    throw new Error(`${description} is not canonical base64url`);
  }
  return decoded;
}

function rawEd25519PublicKey(publicKey: KeyObject): Buffer {
  if (publicKey.asymmetricKeyType !== "ed25519") {
    throw new Error("Bridge identity key is not Ed25519");
  }
  const exported = publicKey.export({ format: "der", type: "spki" });
  if (
    exported.length !== ED25519_SPKI_PREFIX.length + 32 ||
    !exported
      .subarray(0, ED25519_SPKI_PREFIX.length)
      .equals(ED25519_SPKI_PREFIX)
  ) {
    throw new Error("Bridge identity public key is not canonical Ed25519");
  }
  return exported.subarray(ED25519_SPKI_PREFIX.length);
}

function publicKeyFromRaw(value: string): KeyObject {
  const raw = decodeCanonicalBase64Url(value, "Bridge identity public key");
  if (raw.length !== 32) {
    throw new Error("Bridge identity public key must contain 32 bytes");
  }
  const key = createPublicKey({
    key: Buffer.concat([ED25519_SPKI_PREFIX, raw]),
    format: "der",
    type: "spki",
  });
  if (key.asymmetricKeyType !== "ed25519") {
    throw new Error("Bridge identity public key is not Ed25519");
  }
  return key;
}

function normalizeMethods(methods: readonly string[]): string[] {
  if (
    methods.length > 32 ||
    methods.some((method) => !METHOD_PATTERN.test(method))
  ) {
    throw new Error("Bridge identity methods are invalid");
  }
  return [...new Set(methods)].sort();
}

function arraysEqual(
  left: readonly string[],
  right: readonly string[],
): boolean {
  return (
    left.length === right.length &&
    left.every((value, index) => value === right[index])
  );
}

function assertProofValue(value: string, description: string): void {
  if (!PROOF_VALUE_PATTERN.test(value)) {
    throw new Error(`${description} is invalid`);
  }
}

function parseIdentityFile(
  contents: string,
  path: string,
): {
  privateKey: KeyObject;
  publicKey: string;
} {
  let parsed: unknown;
  try {
    parsed = JSON.parse(contents);
  } catch (error) {
    throw new Error(`Bridge identity state is malformed: ${path}`, {
      cause: error,
    });
  }
  if (
    !isPlainObject(parsed) ||
    !hasExactKeys(parsed, ["version", "publicKey", "privateKey"]) ||
    parsed.version !== BRIDGE_IDENTITY_VERSION ||
    typeof parsed.publicKey !== "string" ||
    typeof parsed.privateKey !== "string"
  ) {
    throw new Error(`Bridge identity state is invalid: ${path}`);
  }

  try {
    const privateDer = decodeCanonicalBase64Url(
      parsed.privateKey,
      "Bridge identity private key",
    );
    if (privateDer.length > 512) {
      throw new Error("Bridge identity private key is too large");
    }
    const privateKey = createPrivateKey({
      key: privateDer,
      format: "der",
      type: "pkcs8",
    });
    if (privateKey.asymmetricKeyType !== "ed25519") {
      throw new Error("Bridge identity private key is not Ed25519");
    }
    const derivedPublic = rawEd25519PublicKey(createPublicKey(privateKey));
    const persistedPublic = decodeCanonicalBase64Url(
      parsed.publicKey,
      "Bridge identity public key",
    );
    if (
      persistedPublic.length !== 32 ||
      !derivedPublic.equals(persistedPublic)
    ) {
      throw new Error("Bridge identity key mismatch");
    }
    return { privateKey, publicKey: encodeBase64Url(derivedPublic) };
  } catch (error) {
    throw new Error(`Bridge identity key material is invalid: ${path}`, {
      cause: error,
    });
  }
}

export function deriveBridgeIdentityId(publicKey: string): string {
  const raw = decodeCanonicalBase64Url(publicKey, "Bridge identity public key");
  if (raw.length !== 32) {
    throw new Error("Bridge identity public key must contain 32 bytes");
  }
  return `bridge_${createHash("sha256").update(raw).digest("base64url")}`;
}

export function isValidIdentityNonce(value: unknown): value is string {
  return (
    typeof value === "string" &&
    value.length >= 16 &&
    value.length <= 96 &&
    BASE64URL_PATTERN.test(value)
  );
}

export function canonicalBridgeIdentityPayload(input: {
  version: number;
  bridgeIdentityId: string;
  publicKey: string;
  bridgeInstanceId: string;
  nonce: string;
  authMode: string;
  methods: readonly string[];
}): string {
  if (input.version !== BRIDGE_IDENTITY_VERSION) {
    throw new Error("Bridge identity proof version is unsupported");
  }
  if (!isValidIdentityNonce(input.nonce)) {
    throw new Error(
      "Bridge identity nonce must be base64url with 16..96 characters",
    );
  }
  assertProofValue(input.bridgeIdentityId, "Bridge identity ID");
  assertProofValue(input.bridgeInstanceId, "Bridge instance ID");
  assertProofValue(input.authMode, "Bridge auth mode");
  publicKeyFromRaw(input.publicKey);
  const methods = normalizeMethods(input.methods);
  return JSON.stringify({
    version: BRIDGE_IDENTITY_VERSION,
    bridgeIdentityId: input.bridgeIdentityId,
    publicKey: input.publicKey,
    bridgeInstanceId: input.bridgeInstanceId,
    nonce: input.nonce,
    authMode: input.authMode,
    methods,
  });
}

export function verifyEd25519Signature(
  publicKey: string,
  payload: string | Buffer,
  signature: string,
): boolean {
  try {
    const signatureBytes = decodeCanonicalBase64Url(
      signature,
      "Bridge identity signature",
    );
    if (signatureBytes.length !== 64) return false;
    return ed25519Verify(
      null,
      Buffer.isBuffer(payload) ? payload : Buffer.from(payload, "utf8"),
      publicKeyFromRaw(publicKey),
      signatureBytes,
    );
  } catch {
    return false;
  }
}

export function verifyBridgeIdentityProof(proof: BridgeIdentityProof): boolean {
  try {
    if (proof.bridgeIdentityId !== deriveBridgeIdentityId(proof.publicKey))
      return false;
    const canonicalMethods = normalizeMethods(proof.methods);
    if (!arraysEqual(proof.methods, canonicalMethods)) return false;
    const payload = canonicalBridgeIdentityPayload(proof);
    return (
      proof.signedPayload === payload &&
      verifyEd25519Signature(proof.publicKey, payload, proof.signature)
    );
  } catch {
    return false;
  }
}

export class BridgeIdentityStore {
  readonly stateDir: string;
  readonly identityFile: string;
  readonly writerLeaseFile: string;
  readonly bridgeIdentityId: string;
  readonly publicKey: string;
  private readonly privateKey: KeyObject;
  private readonly writerLeaseRelease: () => Promise<void>;
  private closed = false;
  private closePromise: Promise<void> | undefined;

  private constructor(input: {
    stateDir: string;
    identityFile: string;
    writerLeaseFile: string;
    writerLeaseRelease: () => Promise<void>;
    privateKey: KeyObject;
    publicKey: string;
  }) {
    this.stateDir = input.stateDir;
    this.identityFile = input.identityFile;
    this.writerLeaseFile = input.writerLeaseFile;
    this.writerLeaseRelease = input.writerLeaseRelease;
    this.privateKey = input.privateKey;
    this.publicKey = input.publicKey;
    this.bridgeIdentityId = deriveBridgeIdentityId(input.publicKey);
  }

  static async load(
    options: BridgeIdentityStoreOptions = {},
  ): Promise<BridgeIdentityStore> {
    const requestedStateDir =
      options.stateDir ??
      process.env.CCPOCKET_STATE_DIR ??
      join(homedir(), ".ccpocket");
    const stateDir = await preparePrivateStateDirectory(requestedStateDir);
    const identityFile = join(stateDir, BRIDGE_IDENTITY_FILE);
    const lockOptions = { ...options.lockOptions };
    const writerLeaseStateFile = `${stateDir}.bridge-identity-writer`;
    const writerLeaseFile = `${writerLeaseStateFile}${STATE_WRITER_LEASE_SUFFIX}.lock`;
    const writerLeaseRelease = await acquireStateWriterLease(
      writerLeaseStateFile,
      "Bridge identity writer lease",
      lockOptions,
    );
    try {
      const releaseLock = await acquireStateMutationLock(
        identityFile,
        "Bridge identity state",
        lockOptions,
      );
      try {
        const contents = await readBoundedPrivateFile(
          identityFile,
          MAX_IDENTITY_FILE_BYTES,
          "Bridge identity state",
        );
        let material: { privateKey: KeyObject; publicKey: string };
        if (contents === undefined) {
          const generated = generateKeyPairSync("ed25519");
          const publicKey = encodeBase64Url(
            rawEd25519PublicKey(generated.publicKey),
          );
          const privateKey = generated.privateKey;
          const privateKeyDer = privateKey.export({
            format: "der",
            type: "pkcs8",
          });
          const data: BridgeIdentityFileData = {
            version: BRIDGE_IDENTITY_VERSION,
            publicKey,
            privateKey: encodeBase64Url(privateKeyDer),
          };
          await atomicPrivateWrite(
            identityFile,
            `${JSON.stringify(data)}\n`,
            MAX_IDENTITY_FILE_BYTES,
            "Bridge identity state",
            { syncDirectory: lockOptions.syncDirectory },
          );
          material = { privateKey, publicKey };
        } else {
          material = parseIdentityFile(contents, identityFile);
        }
        return new BridgeIdentityStore({
          stateDir,
          identityFile,
          writerLeaseFile,
          writerLeaseRelease,
          ...material,
        });
      } finally {
        await releaseLock();
      }
    } catch (error) {
      await writerLeaseRelease().catch(() => undefined);
      throw error;
    }
  }

  private assertOpen(): void {
    if (this.closed) throw new Error("Bridge identity store is closed");
  }

  sign(payload: string | Buffer): string {
    this.assertOpen();
    return encodeBase64Url(
      ed25519Sign(
        null,
        Buffer.isBuffer(payload) ? payload : Buffer.from(payload, "utf8"),
        this.privateKey,
      ),
    );
  }

  verify(
    payload: string | Buffer,
    signature: string,
    publicKey = this.publicKey,
  ): boolean {
    this.assertOpen();
    return verifyEd25519Signature(publicKey, payload, signature);
  }

  createNonceProof(input: BridgeNonceProofInput): BridgeIdentityProof {
    this.assertOpen();
    const methods = normalizeMethods(input.methods);
    const unsigned = {
      version: BRIDGE_IDENTITY_VERSION,
      bridgeIdentityId: this.bridgeIdentityId,
      publicKey: this.publicKey,
      bridgeInstanceId: input.bridgeInstanceId,
      nonce: input.nonce,
      authMode: input.authMode,
      methods,
    };
    const signedPayload = canonicalBridgeIdentityPayload(unsigned);
    return {
      ...unsigned,
      signedPayload,
      signature: this.sign(signedPayload),
    };
  }

  response(input: BridgeNonceProofInput): BridgeIdentityProof {
    return this.createNonceProof(input);
  }

  close(): Promise<void> {
    if (this.closePromise) return this.closePromise;
    this.closed = true;
    this.closePromise = this.writerLeaseRelease();
    return this.closePromise;
  }
}
