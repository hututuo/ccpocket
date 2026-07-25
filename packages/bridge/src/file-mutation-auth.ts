import {
  createHash,
  createPublicKey,
  randomBytes,
  randomUUID,
  scrypt as nodeScrypt,
  timingSafeEqual,
  verify as verifySignature,
} from "node:crypto";
import { constants as fsConstants } from "node:fs";
import { chmod, mkdir, open, rename, rm } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

const STORE_VERSION = 1;
const PASSWORD_MIN_LENGTH = 8;
const PASSWORD_MAX_LENGTH = 256;
const DEVICE_ID_MAX_LENGTH = 128;
const PUBLIC_KEY_MAX_LENGTH = 256;
const SIGNATURE_MAX_LENGTH = 256;
const MAX_ENROLLED_DEVICES = 8;
const MAX_ACTIVE_CHALLENGES = 64;
const DEFAULT_CHALLENGE_TTL_MS = 60_000;
const PASSWORD_BLOCK_MS = 30_000;
const PASSWORD_FAILURE_LIMIT = 5;
const SCRYPT_KEY_LENGTH = 64;
const SCRYPT_N = 1 << 15;
const SCRYPT_R = 8;
const SCRYPT_P = 1;
const SCRYPT_MAX_MEMORY = 64 * 1024 * 1024;
const P256_SPKI_PREFIX = Buffer.from(
  "3059301306072a8648ce3d020106082a8648ce3d030107034200",
  "hex",
);

export const FILE_MUTATION_AUTH_CAPABILITY = "file_mutation_auth_v1";
export const FILE_TRANSFER_UPLOAD_AUTH_CAPABILITY =
  "file_transfer_upload_auth_v1";

export type FileMutationOperation = {
  kind: "upload";
  transferId: string;
  filename: string;
  sizeBytes: number;
};

export type FileMutationAuthorization =
  | {
      method: "password";
      password: string;
    }
  | {
      method: "biometric";
      challengeId: string;
      deviceId: string;
      signature: string;
    };

export interface FileMutationAuthState {
  passwordConfigured: boolean;
  biometricEnrolled: boolean;
}

export interface FileMutationAuthChallenge {
  challengeId: string;
  payload: string;
  expiresAt: string;
}

interface PersistedPasswordVerifier {
  algorithm: "scrypt";
  salt: string;
  hash: string;
  n: number;
  r: number;
  p: number;
}

interface PersistedDevice {
  deviceId: string;
  publicKey: string;
  enrolledAt: string;
}

interface PersistedFileMutationAuth {
  version: typeof STORE_VERSION;
  password?: PersistedPasswordVerifier;
  devices: PersistedDevice[];
}

interface ActiveChallenge {
  client: object;
  deviceId: string;
  operationDigest: string;
  payload: string;
  expiresAt: number;
}

interface PasswordFailureState {
  failures: number;
  blockedUntil: number;
}

export interface FileMutationAuthStoreOptions {
  filePath?: string;
}

export interface FileMutationAuthorizerOptions {
  store?: FileMutationAuthStore;
  bridgeInstanceId: string;
  now?: () => number;
  challengeTtlMs?: number;
}

export class FileMutationAuthError extends Error {
  constructor(
    readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "FileMutationAuthError";
  }
}

export class FileMutationAuthStore {
  readonly filePath: string;

  private state: PersistedFileMutationAuth = {
    version: STORE_VERSION,
    devices: [],
  };
  private loadPromise: Promise<void> | undefined;
  private mutationTail: Promise<void> = Promise.resolve();

  constructor(options: FileMutationAuthStoreOptions = {}) {
    this.filePath =
      options.filePath ??
      join(homedir(), ".ccpocket", "file-mutation-auth-v1.json");
  }

  init(): Promise<void> {
    this.loadPromise ??= this.load();
    return this.loadPromise;
  }

  async status(deviceId?: string): Promise<FileMutationAuthState> {
    await this.refresh();
    return {
      passwordConfigured: this.state.password !== undefined,
      biometricEnrolled:
        deviceId !== undefined &&
        this.state.devices.some((device) => device.deviceId === deviceId),
    };
  }

  async enrolledDeviceCount(): Promise<number> {
    await this.refresh();
    return this.state.devices.length;
  }

  async setPassword(password: string): Promise<void> {
    requirePassword(password);
    await this.refresh();
    const verifier = await createPasswordVerifier(password);
    await this.serializeMutation(async () => {
      // A Bridge password change revokes every prior biometric enrollment.
      const next: PersistedFileMutationAuth = {
        version: STORE_VERSION,
        password: verifier,
        devices: [],
      };
      await this.persist(next);
      this.state = next;
    });
  }

  async verifyPassword(password: string): Promise<boolean> {
    if (
      typeof password !== "string" ||
      password.length < PASSWORD_MIN_LENGTH ||
      password.length > PASSWORD_MAX_LENGTH
    ) {
      // Keep malformed attempts on the same asynchronous path as valid ones.
      await derivePassword(
        "invalid-password-padding",
        randomBytes(16),
        SCRYPT_N,
      );
      return false;
    }
    await this.refresh();
    const verifier = this.state.password;
    if (!verifier) return false;
    const actual = await derivePassword(
      password,
      decodeBase64Url(verifier.salt, 64),
      verifier.n,
      verifier.r,
      verifier.p,
    );
    const expected = decodeBase64Url(verifier.hash, SCRYPT_KEY_LENGTH);
    return (
      actual.length === expected.length && timingSafeEqual(actual, expected)
    );
  }

  async enrollDevice(deviceId: string, publicKey: string): Promise<void> {
    requireDeviceId(deviceId);
    validatePublicKey(publicKey);
    await this.serializeMutation(async () => {
      await this.refresh();
      if (!this.state.password) {
        throw new FileMutationAuthError(
          "password_not_configured",
          "Configure the Bridge file-access password first",
        );
      }
      const devices = this.state.devices.filter(
        (device) => device.deviceId !== deviceId,
      );
      if (devices.length >= MAX_ENROLLED_DEVICES) {
        throw new FileMutationAuthError(
          "device_limit_reached",
          "Too many biometric devices are enrolled",
        );
      }
      devices.push({
        deviceId,
        publicKey,
        enrolledAt: new Date().toISOString(),
      });
      const next: PersistedFileMutationAuth = {
        ...this.state,
        devices,
      };
      await this.persist(next);
      this.state = next;
    });
  }

  async publicKeyForDevice(deviceId: string): Promise<string | undefined> {
    await this.refresh();
    return this.state.devices.find((device) => device.deviceId === deviceId)
      ?.publicKey;
  }

  private async load(): Promise<void> {
    let handle: Awaited<ReturnType<typeof open>> | undefined;
    try {
      handle = await open(
        this.filePath,
        fsConstants.O_RDONLY |
          (process.platform === "win32" ? 0 : fsConstants.O_NOFOLLOW),
      );
      const stats = await handle.stat();
      if (
        !stats.isFile() ||
        (!process.platform.startsWith("win") && (stats.mode & 0o077) !== 0)
      ) {
        throw new FileMutationAuthError(
          "unsafe_auth_store",
          "File-access authorization state must be a private regular file",
        );
      }
      const decoded = JSON.parse(await handle.readFile("utf8")) as unknown;
      this.state = validateStore(decoded);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") {
        this.state = { version: STORE_VERSION, devices: [] };
        return;
      }
      if (error instanceof FileMutationAuthError) throw error;
      throw new FileMutationAuthError(
        "invalid_auth_store",
        "File-access authorization state is unreadable",
      );
    } finally {
      await handle?.close().catch(() => undefined);
    }
  }

  /**
   * The standalone Bridge command can change this password while the service
   * is running. Authorization is a cold path, so re-read this small private
   * file here without adding work to browsing, transfer bytes, or chat sync.
   */
  private async refresh(): Promise<void> {
    if (!this.loadPromise) {
      await this.init();
      return;
    }
    await this.loadPromise;
    await this.load();
  }

  private serializeMutation(operation: () => Promise<void>): Promise<void> {
    const current = this.mutationTail.then(operation);
    this.mutationTail = current.catch(() => undefined);
    return current;
  }

  private async persist(next: PersistedFileMutationAuth): Promise<void> {
    const directory = dirname(this.filePath);
    const temporaryPath = `${this.filePath}.tmp-${process.pid}-${randomUUID()}`;
    await mkdir(directory, { recursive: true, mode: 0o700 });
    let handle: Awaited<ReturnType<typeof open>> | undefined;
    try {
      handle = await open(
        temporaryPath,
        fsConstants.O_WRONLY |
          fsConstants.O_CREAT |
          fsConstants.O_EXCL |
          (process.platform === "win32" ? 0 : fsConstants.O_NOFOLLOW),
        0o600,
      );
      await handle.writeFile(`${JSON.stringify(next, null, 2)}\n`, "utf8");
      await handle.sync();
      await handle.close();
      handle = undefined;
      await rename(temporaryPath, this.filePath);
      await chmod(this.filePath, 0o600).catch(() => undefined);
    } finally {
      await handle?.close().catch(() => undefined);
      await rm(temporaryPath, { force: true }).catch(() => undefined);
    }
  }
}

export class FileMutationAuthorizer {
  readonly store: FileMutationAuthStore;

  private readonly bridgeInstanceId: string;
  private readonly now: () => number;
  private readonly challengeTtlMs: number;
  private readonly challenges = new Map<string, ActiveChallenge>();
  private readonly passwordFailures = new WeakMap<
    object,
    PasswordFailureState
  >();

  constructor(options: FileMutationAuthorizerOptions) {
    this.store = options.store ?? new FileMutationAuthStore();
    this.bridgeInstanceId = options.bridgeInstanceId;
    this.now = options.now ?? Date.now;
    this.challengeTtlMs = options.challengeTtlMs ?? DEFAULT_CHALLENGE_TTL_MS;
  }

  init(): Promise<void> {
    return this.store.init();
  }

  status(deviceId?: string): Promise<FileMutationAuthState> {
    return this.store.status(deviceId);
  }

  async enrollDevice(
    client: object,
    input: {
      deviceId: string;
      publicKey: string;
      password: string;
    },
  ): Promise<FileMutationAuthState> {
    await this.requirePassword(client, input.password);
    await this.store.enrollDevice(input.deviceId, input.publicKey);
    return this.store.status(input.deviceId);
  }

  async issueChallenge(
    client: object,
    deviceId: string,
    operation: FileMutationOperation,
  ): Promise<FileMutationAuthChallenge> {
    requireDeviceId(deviceId);
    if (!(await this.store.publicKeyForDevice(deviceId))) {
      throw new FileMutationAuthError(
        "biometric_not_enrolled",
        "Face ID is not enrolled for this Bridge",
      );
    }
    this.pruneChallenges();
    while (this.challenges.size >= MAX_ACTIVE_CHALLENGES) {
      this.challenges.delete(this.challenges.keys().next().value as string);
    }
    const challengeId = randomBytes(24).toString("base64url");
    const expiresAt = this.now() + this.challengeTtlMs;
    const payload = JSON.stringify({
      version: 1,
      bridgeInstanceId: this.bridgeInstanceId,
      challengeId,
      nonce: randomBytes(32).toString("base64url"),
      operationDigest: digestOperation(operation),
      expiresAt,
    });
    this.challenges.set(challengeId, {
      client,
      deviceId,
      operationDigest: digestOperation(operation),
      payload,
      expiresAt,
    });
    return {
      challengeId,
      payload,
      expiresAt: new Date(expiresAt).toISOString(),
    };
  }

  async authorize(
    client: object,
    operation: FileMutationOperation,
    proof: FileMutationAuthorization | undefined,
  ): Promise<void> {
    if (!proof) {
      throw new FileMutationAuthError(
        "step_up_required",
        "Password or Face ID approval is required",
      );
    }
    if (proof.method === "password") {
      await this.requirePassword(client, proof.password);
      return;
    }
    requireDeviceId(proof.deviceId);
    if (
      typeof proof.challengeId !== "string" ||
      proof.challengeId.length < 16 ||
      proof.challengeId.length > 128 ||
      typeof proof.signature !== "string" ||
      proof.signature.length < 16 ||
      proof.signature.length > SIGNATURE_MAX_LENGTH
    ) {
      throw new FileMutationAuthError(
        "invalid_biometric_proof",
        "The Face ID approval proof is invalid",
      );
    }
    const challenge = this.challenges.get(proof.challengeId);
    // A challenge is consumed on every verification attempt, successful or not.
    this.challenges.delete(proof.challengeId);
    if (
      !challenge ||
      challenge.client !== client ||
      challenge.deviceId !== proof.deviceId ||
      challenge.expiresAt < this.now() ||
      challenge.operationDigest !== digestOperation(operation)
    ) {
      throw new FileMutationAuthError(
        "challenge_invalid_or_expired",
        "The Face ID approval expired; try again",
      );
    }
    const publicKey = await this.store.publicKeyForDevice(proof.deviceId);
    if (!publicKey) {
      throw new FileMutationAuthError(
        "biometric_not_enrolled",
        "Face ID is no longer enrolled for this Bridge",
      );
    }
    const signature = decodeBase64Url(proof.signature, 160);
    const key = publicKeyObject(publicKey);
    if (
      !verifySignature(
        "sha256",
        Buffer.from(challenge.payload, "utf8"),
        key,
        signature,
      )
    ) {
      throw new FileMutationAuthError(
        "invalid_biometric_proof",
        "The Face ID approval proof is invalid",
      );
    }
  }

  disconnect(client: object): void {
    for (const [challengeId, challenge] of this.challenges) {
      if (challenge.client === client) this.challenges.delete(challengeId);
    }
    this.passwordFailures.delete(client);
  }

  private async requirePassword(
    client: object,
    password: string,
  ): Promise<void> {
    const now = this.now();
    const failure = this.passwordFailures.get(client);
    if (failure && failure.blockedUntil > now) {
      throw new FileMutationAuthError(
        "password_rate_limited",
        "Too many password attempts; wait before trying again",
      );
    }
    const valid = await this.store.verifyPassword(password);
    if (valid) {
      this.passwordFailures.delete(client);
      return;
    }
    const failures = (failure?.failures ?? 0) + 1;
    this.passwordFailures.set(client, {
      failures,
      blockedUntil:
        failures >= PASSWORD_FAILURE_LIMIT ? now + PASSWORD_BLOCK_MS : 0,
    });
    throw new FileMutationAuthError(
      "invalid_password",
      "The Bridge file-access password is incorrect",
    );
  }

  private pruneChallenges(): void {
    const now = this.now();
    for (const [challengeId, challenge] of this.challenges) {
      if (challenge.expiresAt < now) this.challenges.delete(challengeId);
    }
  }
}

export function validateFileMutationOperation(
  value: unknown,
): value is FileMutationOperation {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const operation = value as Record<string, unknown>;
  return (
    Object.keys(operation).every((key) =>
      ["kind", "transferId", "filename", "sizeBytes"].includes(key),
    ) &&
    operation.kind === "upload" &&
    typeof operation.transferId === "string" &&
    /^[A-Za-z0-9_-]{16,128}$/u.test(operation.transferId) &&
    typeof operation.filename === "string" &&
    operation.filename.trim().length > 0 &&
    operation.filename.length <= 255 &&
    !operation.filename.includes("\0") &&
    Number.isSafeInteger(operation.sizeBytes) &&
    Number(operation.sizeBytes) >= 0
  );
}

export function validateFileMutationAuthorization(
  value: unknown,
): value is FileMutationAuthorization {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const proof = value as Record<string, unknown>;
  if (proof.method === "password") {
    return (
      Object.keys(proof).every((key) => ["method", "password"].includes(key)) &&
      typeof proof.password === "string" &&
      proof.password.length >= PASSWORD_MIN_LENGTH &&
      proof.password.length <= PASSWORD_MAX_LENGTH
    );
  }
  return (
    proof.method === "biometric" &&
    Object.keys(proof).every((key) =>
      ["method", "challengeId", "deviceId", "signature"].includes(key),
    ) &&
    typeof proof.challengeId === "string" &&
    proof.challengeId.length >= 16 &&
    proof.challengeId.length <= 128 &&
    typeof proof.deviceId === "string" &&
    proof.deviceId.length > 0 &&
    proof.deviceId.length <= DEVICE_ID_MAX_LENGTH &&
    typeof proof.signature === "string" &&
    proof.signature.length >= 16 &&
    proof.signature.length <= SIGNATURE_MAX_LENGTH
  );
}

function digestOperation(operation: FileMutationOperation): string {
  const canonical = JSON.stringify({
    kind: operation.kind,
    transferId: operation.transferId,
    filename: operation.filename,
    sizeBytes: operation.sizeBytes,
  });
  return createHash("sha256").update(canonical).digest("base64url");
}

async function createPasswordVerifier(
  password: string,
): Promise<PersistedPasswordVerifier> {
  const salt = randomBytes(16);
  const hash = await derivePassword(password, salt, SCRYPT_N);
  return {
    algorithm: "scrypt",
    salt: salt.toString("base64url"),
    hash: hash.toString("base64url"),
    n: SCRYPT_N,
    r: SCRYPT_R,
    p: SCRYPT_P,
  };
}

async function derivePassword(
  password: string,
  salt: Buffer,
  n: number,
  r = SCRYPT_R,
  p = SCRYPT_P,
): Promise<Buffer> {
  return new Promise<Buffer>((resolve, reject) => {
    nodeScrypt(
      password,
      salt,
      SCRYPT_KEY_LENGTH,
      {
        N: n,
        r,
        p,
        maxmem: Math.max(SCRYPT_MAX_MEMORY, 128 * n * r + 1024),
      },
      (error, derivedKey) => {
        if (error) reject(error);
        else resolve(Buffer.from(derivedKey));
      },
    );
  });
}

function requirePassword(password: string): void {
  if (
    typeof password !== "string" ||
    password.length < PASSWORD_MIN_LENGTH ||
    password.length > PASSWORD_MAX_LENGTH
  ) {
    throw new FileMutationAuthError(
      "invalid_password_format",
      `Password must be ${PASSWORD_MIN_LENGTH}-${PASSWORD_MAX_LENGTH} characters`,
    );
  }
}

function requireDeviceId(deviceId: string): void {
  if (
    typeof deviceId !== "string" ||
    !/^[A-Za-z0-9._:-]{8,128}$/u.test(deviceId)
  ) {
    throw new FileMutationAuthError(
      "invalid_device_id",
      "The device identity is invalid",
    );
  }
}

function validatePublicKey(publicKey: string): void {
  if (
    typeof publicKey !== "string" ||
    publicKey.length < 80 ||
    publicKey.length > PUBLIC_KEY_MAX_LENGTH
  ) {
    throw new FileMutationAuthError(
      "invalid_public_key",
      "The biometric public key is invalid",
    );
  }
  publicKeyObject(publicKey);
}

function publicKeyObject(publicKey: string) {
  try {
    const raw = decodeBase64Url(publicKey, 65);
    if (raw.length !== 65 || raw[0] !== 0x04) throw new Error("invalid");
    return createPublicKey({
      key: Buffer.concat([P256_SPKI_PREFIX, raw]),
      format: "der",
      type: "spki",
    });
  } catch {
    throw new FileMutationAuthError(
      "invalid_public_key",
      "The biometric public key is invalid",
    );
  }
}

function decodeBase64Url(value: string, maxBytes: number): Buffer {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value.length > Math.ceil((maxBytes * 4) / 3) + 4 ||
    !/^[A-Za-z0-9_-]+$/u.test(value)
  ) {
    throw new FileMutationAuthError(
      "invalid_encoding",
      "Authorization data is malformed",
    );
  }
  const decoded = Buffer.from(value, "base64url");
  if (decoded.length === 0 || decoded.length > maxBytes) {
    throw new FileMutationAuthError(
      "invalid_encoding",
      "Authorization data is malformed",
    );
  }
  return decoded;
}

function validateStore(value: unknown): PersistedFileMutationAuth {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new FileMutationAuthError(
      "invalid_auth_store",
      "File-access authorization state is invalid",
    );
  }
  const raw = value as Record<string, unknown>;
  if (
    raw.version !== STORE_VERSION ||
    !Array.isArray(raw.devices) ||
    raw.devices.length > MAX_ENROLLED_DEVICES
  ) {
    throw new FileMutationAuthError(
      "invalid_auth_store",
      "File-access authorization state is invalid",
    );
  }
  let password: PersistedPasswordVerifier | undefined;
  if (raw.password !== undefined) {
    if (
      !raw.password ||
      typeof raw.password !== "object" ||
      Array.isArray(raw.password)
    ) {
      throw new FileMutationAuthError(
        "invalid_auth_store",
        "File-access authorization state is invalid",
      );
    }
    const verifier = raw.password as Record<string, unknown>;
    if (
      verifier.algorithm !== "scrypt" ||
      typeof verifier.salt !== "string" ||
      typeof verifier.hash !== "string" ||
      verifier.n !== SCRYPT_N ||
      verifier.r !== SCRYPT_R ||
      verifier.p !== SCRYPT_P
    ) {
      throw new FileMutationAuthError(
        "invalid_auth_store",
        "File-access authorization state is invalid",
      );
    }
    decodeBase64Url(verifier.salt, 64);
    const hash = decodeBase64Url(verifier.hash, SCRYPT_KEY_LENGTH);
    if (hash.length !== SCRYPT_KEY_LENGTH) {
      throw new FileMutationAuthError(
        "invalid_auth_store",
        "File-access authorization state is invalid",
      );
    }
    password = {
      algorithm: "scrypt",
      salt: verifier.salt,
      hash: verifier.hash,
      n: verifier.n,
      r: verifier.r,
      p: verifier.p,
    };
  }
  if (raw.devices.length > 0 && password === undefined) {
    throw new FileMutationAuthError(
      "invalid_auth_store",
      "File-access authorization state is invalid",
    );
  }
  const devices = raw.devices.map((value) => {
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      throw new FileMutationAuthError(
        "invalid_auth_store",
        "File-access authorization state is invalid",
      );
    }
    const device = value as Record<string, unknown>;
    requireDeviceId(device.deviceId as string);
    validatePublicKey(device.publicKey as string);
    if (
      typeof device.enrolledAt !== "string" ||
      !device.enrolledAt.endsWith("Z") ||
      Number.isNaN(Date.parse(device.enrolledAt))
    ) {
      throw new FileMutationAuthError(
        "invalid_auth_store",
        "File-access authorization state is invalid",
      );
    }
    return {
      deviceId: device.deviceId as string,
      publicKey: device.publicKey as string,
      enrolledAt: device.enrolledAt,
    };
  });
  if (
    new Set(devices.map((device) => device.deviceId)).size !== devices.length
  ) {
    throw new FileMutationAuthError(
      "invalid_auth_store",
      "File-access authorization state is invalid",
    );
  }
  return {
    version: STORE_VERSION,
    ...(password ? { password } : {}),
    devices,
  };
}
