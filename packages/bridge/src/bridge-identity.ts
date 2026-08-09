import {
  createHash,
  createPrivateKey,
  createPublicKey,
  generateKeyPairSync,
  sign,
  type KeyObject,
  verify,
} from "node:crypto";
import { execFileSync } from "node:child_process";
import { homedir, hostname } from "node:os";
import {
  chmod,
  mkdir,
  open,
  readFile,
  rename,
  rm,
  lstat,
} from "node:fs/promises";
import { dirname, join } from "node:path";

/** Identity document schema version; the capability version is separate. */
export const BRIDGE_IDENTITY_VERSION = 1 as const;
export const BRIDGE_IDENTITY_V3_CAPABILITY = "bridge_identity_v3" as const;

const DEFAULT_STATE_DIR = join(homedir(), ".ccpocket");
const DEFAULT_IDENTITY_FILE = "bridge-identity-v1.json";
const MAX_DISPLAY_NAME_LENGTH = 80;
const MAX_IDENTITY_FILE_BYTES = 64 * 1024;

export interface BridgeIdentityFile {
  version: 1;
  publicKey: string;
  privateKey: string;
}

export interface BridgeIdentityResponse {
  version: typeof BRIDGE_IDENTITY_VERSION;
  bridgeIdentityId: string;
  publicKey: string;
  bridgeInstanceId: string;
  computerName: string;
  nonce: string;
  authMode: string;
  methods: string[];
  signedPayload: string;
  signature: string;
}

export interface BridgeIdentityStoreOptions {
  stateDir?: string;
  identityFile?: string;
  displayName?: string;
  platform?: NodeJS.Platform;
  hostnameValue?: string;
  now?: () => number;
}

function base64url(value: Buffer): string {
  return value.toString("base64url");
}

function decodeBase64Url(value: string): Buffer {
  if (!/^[A-Za-z0-9_-]+$/.test(value)) {
    throw new Error("Invalid base64url value");
  }
  return Buffer.from(value, "base64url");
}

const ED25519_SPKI_PREFIX = Buffer.from("302a300506032b6570032100", "hex");

function rawEd25519PublicKey(value: Buffer): Buffer {
  if (value.length === 32) return value;
  if (
    value.length === ED25519_SPKI_PREFIX.length + 32 &&
    value.subarray(0, ED25519_SPKI_PREFIX.length).equals(ED25519_SPKI_PREFIX)
  ) {
    return value.subarray(ED25519_SPKI_PREFIX.length);
  }
  throw new Error("Bridge identity public key is not Ed25519");
}

function assertSafeRegularFile(path: string): Promise<void> {
  return lstat(path).then((stats) => {
    if (stats.isSymbolicLink() || !stats.isFile()) {
      throw new Error(`Bridge identity file is not a regular file: ${path}`);
    }
    if (stats.size > MAX_IDENTITY_FILE_BYTES) {
      throw new Error(`Bridge identity state is too large: ${path}`);
    }
  });
}

async function atomicPrivateWrite(
  path: string,
  contents: string,
): Promise<void> {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  await chmod(dirname(path), 0o700).catch(() => undefined);
  const temporary = `${path}.tmp-${process.pid}-${Math.random().toString(16).slice(2)}`;
  let handle: Awaited<ReturnType<typeof open>> | undefined;
  try {
    handle = await open(temporary, "wx", 0o600);
    await handle.writeFile(contents, "utf8");
    await handle.sync();
    await handle.close();
    handle = undefined;
    await chmod(temporary, 0o600);
    await rename(temporary, path);
    await chmod(path, 0o600);
  } finally {
    await handle?.close().catch(() => undefined);
    await rm(temporary, { force: true }).catch(() => undefined);
  }
}

async function acquireIdentityLock(path: string): Promise<() => Promise<void>> {
  const lockPath = `${path}.lock`;
  for (let attempt = 0; attempt < 200; attempt += 1) {
    try {
      await mkdir(lockPath, { mode: 0o700 });
      return async () => {
        await rm(lockPath, { recursive: true, force: true }).catch(
          () => undefined,
        );
      };
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
      await new Promise((resolve) => setTimeout(resolve, 5));
    }
  }
  throw new Error("Bridge identity state is busy");
}

/** Normalize a display-only name without using any hardware identifier. */
export function normalizeBridgeDisplayName(value: string | undefined): string {
  const normalized = (value ?? "")
    .replace(/[\u0000-\u001f\u007f]/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, MAX_DISPLAY_NAME_LENGTH)
    .trim();
  return normalized || "Bridge";
}

export function readBridgeComputerName(
  options: {
    env?: NodeJS.ProcessEnv;
    platform?: NodeJS.Platform;
    hostnameValue?: string;
    displayName?: string;
  } = {},
): string {
  const envName =
    options.displayName ??
    options.env?.BRIDGE_DISPLAY_NAME ??
    process.env.BRIDGE_DISPLAY_NAME;
  if (envName?.trim()) return normalizeBridgeDisplayName(envName);

  const platform = options.platform ?? process.platform;
  if (platform === "darwin") {
    try {
      const output = execFileSync(
        "/usr/sbin/scutil",
        ["--get", "ComputerName"],
        {
          encoding: "utf8",
          timeout: 700,
          stdio: ["ignore", "pipe", "ignore"],
        },
      );
      const name = normalizeBridgeDisplayName(output);
      if (name !== "Bridge") return name;
    } catch {
      // Fall through to the portable host name.
    }
  }
  return normalizeBridgeDisplayName(options.hostnameValue ?? hostname());
}

/** Strict field order used by the HTTP identity proof and signedPayload. */
export function canonicalBridgeIdentityPayload(input: {
  version: number;
  nonce: string;
  bridgeIdentityId: string;
  publicKey: string;
  bridgeInstanceId: string;
  computerName: string;
  authMode: string;
  methods: string[];
}): string {
  return JSON.stringify({
    version: input.version,
    bridgeIdentityId: input.bridgeIdentityId,
    publicKey: input.publicKey,
    bridgeInstanceId: input.bridgeInstanceId,
    computerName: input.computerName,
    nonce: input.nonce,
    authMode: input.authMode,
    methods: [...input.methods],
  });
}

export function isValidIdentityNonce(value: unknown): value is string {
  return (
    typeof value === "string" &&
    value.length >= 16 &&
    value.length <= 96 &&
    /^[A-Za-z0-9_-]+$/.test(value)
  );
}

export class BridgeIdentityStore {
  readonly stateDir: string;
  readonly identityFile: string;
  readonly bridgeIdentityId: string;
  readonly publicKey: string;
  readonly computerName: string;
  private readonly privateKey: KeyObject;
  private readonly now: () => number;

  private constructor(
    privateKey: KeyObject,
    publicKey: string,
    options: Required<
      Pick<BridgeIdentityStoreOptions, "stateDir" | "identityFile">
    > &
      Omit<BridgeIdentityStoreOptions, "stateDir" | "identityFile">,
  ) {
    this.privateKey = privateKey;
    this.publicKey = publicKey;
    this.bridgeIdentityId = `bridge_${createHash("sha256")
      .update(rawEd25519PublicKey(decodeBase64Url(publicKey)))
      .digest("base64url")}`;
    this.stateDir = options.stateDir;
    this.identityFile = options.identityFile;
    this.computerName = readBridgeComputerName({
      env: process.env,
      platform: options.platform,
      hostnameValue: options.hostnameValue,
      displayName: options.displayName,
    });
    this.now = options.now ?? Date.now;
  }

  static async load(
    options: BridgeIdentityStoreOptions = {},
  ): Promise<BridgeIdentityStore> {
    const stateDir =
      options.stateDir ?? process.env.CCPOCKET_STATE_DIR ?? DEFAULT_STATE_DIR;
    const identityFile =
      options.identityFile ?? join(stateDir, DEFAULT_IDENTITY_FILE);
    await mkdir(stateDir, { recursive: true, mode: 0o700 });
    const stateStats = await lstat(stateDir);
    if (stateStats.isSymbolicLink() || !stateStats.isDirectory()) {
      throw new Error(
        "Bridge identity state directory must be a real directory",
      );
    }
    await chmod(stateDir, 0o700).catch(() => undefined);
    const releaseLock = await acquireIdentityLock(identityFile);
    try {
      let parsed: BridgeIdentityFile | undefined;
      try {
        await assertSafeRegularFile(identityFile);
        let value: Partial<BridgeIdentityFile>;
        try {
          value = JSON.parse(
            await readFile(identityFile, "utf8"),
          ) as Partial<BridgeIdentityFile>;
        } catch (error) {
          throw new Error(
            `Bridge identity state is unreadable or malformed: ${identityFile}`,
            { cause: error },
          );
        }
        if (
          value.version !== 1 ||
          typeof value.publicKey !== "string" ||
          typeof value.privateKey !== "string" ||
          value.publicKey.length === 0 ||
          value.publicKey.length > 512 ||
          value.privateKey.length === 0 ||
          value.privateKey.length > 2048
        ) {
          throw new Error(`Bridge identity state is invalid: ${identityFile}`);
        }
        parsed = value as BridgeIdentityFile;
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      }
      if (parsed) await chmod(identityFile, 0o600);

      let privateKey: KeyObject;
      let publicKey: string;
      if (parsed) {
        try {
          privateKey = createPrivateKey({
            key: decodeBase64Url(parsed.privateKey),
            format: "der",
            type: "pkcs8",
          });
          const derived = createPublicKey(privateKey).export({
            format: "der",
            type: "spki",
          });
          const rawDerived = rawEd25519PublicKey(derived);
          publicKey = base64url(rawDerived);
          // Do not silently accept a mismatched public/private pair.
          const persistedPublic = rawEd25519PublicKey(
            decodeBase64Url(parsed.publicKey),
          );
          if (!rawDerived.equals(persistedPublic))
            throw new Error("Bridge identity key mismatch");
        } catch (error) {
          throw new Error(
            `Bridge identity key material is invalid: ${identityFile}`,
            { cause: error },
          );
        }
      }

      if (!parsed) {
        const generated = generateKeyPairSync("ed25519");
        privateKey = generated.privateKey;
        publicKey = base64url(
          rawEd25519PublicKey(
            generated.publicKey.export({ format: "der", type: "spki" }),
          ),
        );
        const privateDer = privateKey.export({ format: "der", type: "pkcs8" });
        await atomicPrivateWrite(
          identityFile,
          `${JSON.stringify({ version: 1, publicKey, privateKey: base64url(privateDer) } satisfies BridgeIdentityFile)}\n`,
        );
      }

      return new BridgeIdentityStore(privateKey!, publicKey!, {
        ...options,
        stateDir,
        identityFile,
      });
    } finally {
      await releaseLock();
    }
  }

  response(input: {
    nonce: string;
    bridgeInstanceId: string;
    authMode: string;
    methods: string[];
  }): BridgeIdentityResponse {
    if (!isValidIdentityNonce(input.nonce)) {
      throw new Error(
        "Identity nonce must be base64url with 16..96 characters",
      );
    }
    const signedPayload = canonicalBridgeIdentityPayload({
      version: BRIDGE_IDENTITY_VERSION,
      nonce: input.nonce,
      bridgeIdentityId: this.bridgeIdentityId,
      publicKey: this.publicKey,
      bridgeInstanceId: input.bridgeInstanceId,
      computerName: this.computerName,
      authMode: input.authMode,
      methods: input.methods,
    });
    return {
      version: BRIDGE_IDENTITY_VERSION,
      bridgeIdentityId: this.bridgeIdentityId,
      publicKey: this.publicKey,
      bridgeInstanceId: input.bridgeInstanceId,
      computerName: this.computerName,
      nonce: input.nonce,
      authMode: input.authMode,
      methods: [...input.methods],
      signedPayload,
      signature: base64url(
        sign(null, Buffer.from(signedPayload, "utf8"), this.privateKey),
      ),
    };
  }

  sign(payload: string | Buffer): string {
    return base64url(
      sign(
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
    try {
      const key = createPublicKey({
        key: (() => {
          const raw = rawEd25519PublicKey(decodeBase64Url(publicKey));
          return Buffer.concat([ED25519_SPKI_PREFIX, raw]);
        })(),
        format: "der",
        type: "spki",
      });
      return verify(
        null,
        Buffer.isBuffer(payload) ? payload : Buffer.from(payload, "utf8"),
        key,
        decodeBase64Url(signature),
      );
    } catch {
      return false;
    }
  }
}
