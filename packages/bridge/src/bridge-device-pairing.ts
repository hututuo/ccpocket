import {
  createHash,
  createPublicKey,
  randomBytes,
  randomUUID,
  verify,
} from "node:crypto";
import { homedir } from "node:os";
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
import type { BridgeIdentityStore } from "./bridge-identity.js";

export type BridgeAuthMode = "key" | "paired_or_key" | "open";

export const DEVICE_PAIRING_VERSION = 1 as const;
export const DEVICE_AUTH_TIMEOUT_MS = 10_000;
export const PAIRING_TOKEN_TTL_MS = 5 * 60_000;
export const MAX_PAIRING_TOKENS = 8;
export const MAX_TRUSTED_DEVICES = 16;
export const MAX_PENDING_PAIRINGS = 16;

const DEFAULT_STATE_DIR = join(homedir(), ".ccpocket");
const TRUSTED_FILE = "trusted-mobile-devices-v1.json";
const PAIRING_FILE = "pairing-state-v1.json";
const MAX_ID_LENGTH = 128;
const MAX_PUBLIC_KEY_LENGTH = 512;
const RAW_ED25519_PUBLIC_KEY_BYTES = 32;
const SPKI_ED25519_PREFIX = Buffer.from("302a300506032b6570032100", "hex");

export interface TrustedMobileDevice {
  deviceId: string;
  publicKey: string;
  label?: string;
  createdAt: string;
  lastSeenAt: string;
  revokedAt?: string;
  scopes: string[];
}

interface TrustedState {
  version: typeof DEVICE_PAIRING_VERSION;
  revision: number;
  devices: TrustedMobileDevice[];
}

interface PairingTokenRecord {
  tokenHash: string;
  createdAt: string;
  expiresAt: string;
  usedAt?: string;
}

export interface PendingPairing {
  requestId: string;
  confirmationCode: string;
  deviceId: string;
  publicKey: string;
  label?: string;
  scopes: string[];
  createdAt: string;
  expiresAt: string;
  approvedAt?: string;
  rejectedAt?: string;
}

interface PairingState {
  version: typeof DEVICE_PAIRING_VERSION;
  revision: number;
  tokens: PairingTokenRecord[];
  pending: PendingPairing[];
}

export interface PairingChallenge {
  challengeId: string;
  nonce: string;
  expiresAt: string;
  bridgeIdentityId: string;
  bridgeInstanceId: string;
}

interface ChallengeRecord extends PairingChallenge {
  used: boolean;
}

export interface DevicePairingOptions {
  stateDir?: string;
  trustedFile?: string;
  pairingFile?: string;
  bridgeIdentity: BridgeIdentityStore;
  bridgeInstanceId: string;
  now?: () => number;
  maxDevices?: number;
}

export interface DevicePairingRequest {
  deviceId: string;
  publicKey: string;
  label?: string;
  scopes?: string[];
  token?: string;
}

export interface DeviceAuthRequest {
  challengeId: string;
  nonce: string;
  expiresAt: string;
  bridgeIdentityId: string;
  bridgeInstanceId: string;
  deviceId: string;
  publicKey: string;
  signature: string;
}

export interface PairingQrInfo {
  token: string;
  expiresAt: string;
  deepLink: string;
}

export interface PairingSnapshot {
  trustedRevision: number;
  pairingRevision: number;
  devices: TrustedMobileDevice[];
  pending: PendingPairing[];
}

function isoNow(now: () => number): string {
  return new Date(now()).toISOString();
}

function tokenHash(token: string): string {
  return createHash("sha256").update(token, "utf8").digest("hex");
}

function randomToken(): string {
  return randomBytes(32).toString("base64url");
}

function validateId(value: unknown, name: string): string {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value.length > MAX_ID_LENGTH ||
    !/^[\x21-\x7e]+$/.test(value)
  ) {
    throw new Error(`${name} is invalid`);
  }
  return value;
}

function validatePublicKey(value: unknown): string {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value.length > MAX_PUBLIC_KEY_LENGTH ||
    !/^[A-Za-z0-9_-]+$/.test(value)
  ) {
    throw new Error("publicKey is invalid");
  }
  // Parse once at the boundary so malformed keys never enter the trust file.
  publicKeyObject(value);
  return value;
}

function publicKeyObject(value: string) {
  const raw = Buffer.from(value, "base64url");
  const der = raw.length === RAW_ED25519_PUBLIC_KEY_BYTES
    ? Buffer.concat([SPKI_ED25519_PREFIX, raw])
    : raw;
  return createPublicKey({ key: der, format: "der", type: "spki" });
}

function normalizeScopes(scopes: string[] | undefined): string[] {
  const values = scopes ?? ["owner"];
  return [...new Set(values.filter((value) => typeof value === "string" && /^[\x21-\x7e]{1,64}$/.test(value)))].slice(0, 16);
}

function cloneDevice(device: TrustedMobileDevice): TrustedMobileDevice {
  return { ...device, scopes: [...device.scopes] };
}

function clonePending(value: PendingPairing): PendingPairing {
  return { ...value, scopes: [...value.scopes] };
}

async function ensurePrivatePath(path: string, directoryMode: 0o700 | 0o600): Promise<void> {
  const parent = dirname(path);
  await mkdir(parent, { recursive: true, mode: 0o700 });
  await chmod(parent, 0o700).catch(() => undefined);
  await chmod(path, directoryMode).catch(() => undefined);
}

async function atomicJsonWrite(path: string, value: unknown): Promise<void> {
  await ensurePrivatePath(path, 0o600);
  const temporary = `${path}.tmp-${process.pid}-${randomBytes(8).toString("hex")}`;
  let handle: Awaited<ReturnType<typeof open>> | undefined;
  try {
    handle = await open(temporary, "wx", 0o600);
    await handle.writeFile(`${JSON.stringify(value, null, 2)}\n`, "utf8");
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

async function readJson<T>(path: string, fallback: T): Promise<T> {
  try {
    const stats = await lstat(path);
    if (stats.isSymbolicLink() || !stats.isFile()) throw new Error("not regular");
    return JSON.parse(await readFile(path, "utf8")) as T;
  } catch {
    return fallback;
  }
}

async function withLock<T>(path: string, fn: () => Promise<T>): Promise<T> {
  const lockPath = `${path}.lock`;
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  let acquired = false;
  for (let attempt = 0; attempt < 200; attempt += 1) {
    try {
      await mkdir(lockPath, { mode: 0o700 });
      acquired = true;
      break;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
      await new Promise((resolve) => setTimeout(resolve, 5));
    }
  }
  if (!acquired) throw new Error("Bridge pairing state is busy");
  try {
    return await fn();
  } finally {
    await rm(lockPath, { recursive: true, force: true }).catch(() => undefined);
  }
}

function validState(value: unknown): value is TrustedState {
  const state = value as Partial<TrustedState>;
  return state?.version === DEVICE_PAIRING_VERSION && Number.isInteger(state.revision) && Array.isArray(state.devices);
}

function validPairingState(value: unknown): value is PairingState {
  const state = value as Partial<PairingState>;
  return state?.version === DEVICE_PAIRING_VERSION && Number.isInteger(state.revision) && Array.isArray(state.tokens) && Array.isArray(state.pending);
}

function canonicalDeviceChallengePayload(input: {
  challengeId: string;
  nonce: string;
  expiresAt: string;
  bridgeIdentityId: string;
  bridgeInstanceId: string;
  deviceId: string;
}): string {
  return JSON.stringify({
    challengeId: input.challengeId,
    nonce: input.nonce,
    expiresAt: input.expiresAt,
    bridgeIdentityId: input.bridgeIdentityId,
    bridgeInstanceId: input.bridgeInstanceId,
    deviceId: input.deviceId,
  });
}

export { canonicalDeviceChallengePayload };

export class BridgeDevicePairing {
  readonly stateDir: string;
  readonly trustedFile: string;
  readonly pairingFile: string;
  readonly bridgeInstanceId: string;
  private readonly bridgeIdentity: BridgeIdentityStore;
  private readonly now: () => number;
  private readonly maxDevices: number;
  private readonly challenges = new Map<string, ChallengeRecord>();

  constructor(options: DevicePairingOptions) {
    this.stateDir = options.stateDir ?? process.env.CCPOCKET_STATE_DIR ?? DEFAULT_STATE_DIR;
    this.trustedFile = options.trustedFile ?? join(this.stateDir, TRUSTED_FILE);
    this.pairingFile = options.pairingFile ?? join(this.stateDir, PAIRING_FILE);
    this.bridgeInstanceId = validateId(options.bridgeInstanceId, "bridgeInstanceId");
    this.bridgeIdentity = options.bridgeIdentity;
    this.now = options.now ?? Date.now;
    this.maxDevices = Math.min(Math.max(options.maxDevices ?? MAX_TRUSTED_DEVICES, 1), MAX_TRUSTED_DEVICES);
  }

  async init(): Promise<void> {
    await mkdir(this.stateDir, { recursive: true, mode: 0o700 });
    const stateStats = await lstat(this.stateDir);
    if (stateStats.isSymbolicLink() || !stateStats.isDirectory()) {
      throw new Error("Bridge pairing state directory must be a real directory");
    }
    await chmod(this.stateDir, 0o700).catch(() => undefined);
    const trusted = await readJson<unknown>(this.trustedFile, undefined);
    if (!validState(trusted)) {
      await atomicJsonWrite(this.trustedFile, { version: DEVICE_PAIRING_VERSION, revision: 0, devices: [] } satisfies TrustedState);
    } else await chmod(this.trustedFile, 0o600).catch(() => undefined);
    const pairing = await readJson<unknown>(this.pairingFile, undefined);
    if (!validPairingState(pairing)) {
      await atomicJsonWrite(this.pairingFile, { version: DEVICE_PAIRING_VERSION, revision: 0, tokens: [], pending: [] } satisfies PairingState);
    } else await chmod(this.pairingFile, 0o600).catch(() => undefined);
  }

  get pairingAvailable(): boolean {
    return true;
  }

  async snapshot(): Promise<PairingSnapshot> {
    const [trustedRaw, pairingRaw] = await Promise.all([
      readJson<unknown>(this.trustedFile, undefined),
      readJson<unknown>(this.pairingFile, undefined),
    ]);
    const trusted = validState(trustedRaw) ? trustedRaw : { version: DEVICE_PAIRING_VERSION, revision: 0, devices: [] } satisfies TrustedState;
    const pairing = validPairingState(pairingRaw) ? pairingRaw : { version: DEVICE_PAIRING_VERSION, revision: 0, tokens: [], pending: [] } satisfies PairingState;
    const now = this.now();
    return {
      trustedRevision: trusted.revision,
      pairingRevision: pairing.revision,
      devices: trusted.devices.map(cloneDevice),
      pending: pairing.pending.filter((request) => Date.parse(request.expiresAt) > now).map(clonePending),
    };
  }

  async trustedDevice(deviceId: string): Promise<TrustedMobileDevice | undefined> {
    const state = await readJson<unknown>(this.trustedFile, undefined);
    if (!validState(state)) return undefined;
    const found = state.devices.find((device) => device.deviceId === deviceId && !device.revokedAt);
    return found ? cloneDevice(found) : undefined;
  }

  async createPairingToken(input: { baseUrl?: string; bridgeUrl?: string } = {}): Promise<PairingQrInfo> {
    return withLock(this.pairingFile, async () => {
      const raw = await readJson<unknown>(this.pairingFile, undefined);
      const state: PairingState = validPairingState(raw)
        ? raw
        : { version: DEVICE_PAIRING_VERSION, revision: 0, tokens: [], pending: [] };
      const now = this.now();
      state.tokens = state.tokens.filter((entry) => !entry.usedAt && Date.parse(entry.expiresAt) > now);
      if (state.tokens.length >= MAX_PAIRING_TOKENS) throw new Error("Pairing token limit reached");
      const token = randomToken();
      const expiresAt = new Date(now + PAIRING_TOKEN_TTL_MS).toISOString();
      state.tokens.push({ tokenHash: tokenHash(token), createdAt: new Date(now).toISOString(), expiresAt });
      state.revision += 1;
      await atomicJsonWrite(this.pairingFile, state);
      const params = new URLSearchParams({
        token,
        bridgeIdentityId: this.bridgeIdentity.bridgeIdentityId,
        bridgeInstanceId: this.bridgeInstanceId,
      });
      const bridgeUrl = input.bridgeUrl?.trim() || input.baseUrl?.trim();
      if (bridgeUrl) params.set("url", bridgeUrl);
      return { token, expiresAt, deepLink: `ccpocket://pair?${params.toString()}` };
    });
  }

  async requestPairing(input: DevicePairingRequest): Promise<
    | { status: "paired"; device: TrustedMobileDevice }
    | { status: "pending"; request: PendingPairing }
  > {
    const deviceId = validateId(input.deviceId, "deviceId");
    const publicKey = validatePublicKey(input.publicKey);
    const label = input.label?.replace(/[\u0000-\u001f\u007f]/g, " ").trim().slice(0, 80) || undefined;
    const scopes = normalizeScopes(input.scopes);
    if (input.token) {
      const paired = await this.consumeToken(input.token);
      if (!paired) throw new Error("Pairing token is invalid or expired");
      const device = await this.enroll({ deviceId, publicKey, label, scopes });
      return { status: "paired", device };
    }

    return withLock(this.pairingFile, async () => {
      const state = await this.readPairingState();
      const now = this.now();
      state.pending = state.pending.filter((request) => Date.parse(request.expiresAt) > now && !request.rejectedAt);
      const existing = state.pending.find((request) => request.deviceId === deviceId && request.publicKey === publicKey);
      if (existing) return { status: "pending", request: clonePending(existing) };
      if (state.pending.filter((request) => !request.approvedAt).length >= MAX_PENDING_PAIRINGS) throw new Error("Pending pairing limit reached");
      const usedCodes = new Set(state.pending.map((request) => request.confirmationCode));
      let confirmationCode = "";
      for (let attempt = 0; attempt < 32; attempt += 1) {
        const candidate = String(100000 + randomBytes(4).readUInt32BE(0) % 900000);
        if (!usedCodes.has(candidate)) { confirmationCode = candidate; break; }
      }
      if (!confirmationCode) throw new Error("Could not allocate a pairing confirmation code");
      const request: PendingPairing = {
        requestId: randomUUID(),
        confirmationCode,
        deviceId,
        publicKey,
        ...(label ? { label } : {}),
        scopes,
        createdAt: new Date(now).toISOString(),
        expiresAt: new Date(now + PAIRING_TOKEN_TTL_MS).toISOString(),
      };
      state.pending.push(request);
      state.revision += 1;
      await this.writePairingState(state);
      return { status: "pending", request: clonePending(request) };
    });
  }

  async approve(code: string): Promise<TrustedMobileDevice> {
    return withLock(this.pairingFile, async () => {
      const state = await this.readPairingState();
      const now = this.now();
      const request = state.pending.find((entry) => entry.confirmationCode === code && !entry.rejectedAt && !entry.approvedAt && Date.parse(entry.expiresAt) > now);
      if (!request) throw new Error("Pairing confirmation code is invalid or expired");
      request.approvedAt = new Date(now).toISOString();
      state.revision += 1;
      await this.writePairingState(state);
      return this.enroll({ deviceId: request.deviceId, publicKey: request.publicKey, label: request.label, scopes: request.scopes });
    });
  }

  async reject(code: string): Promise<boolean> {
    return withLock(this.pairingFile, async () => {
      const state = await this.readPairingState();
      const request = state.pending.find((entry) => entry.confirmationCode === code && !entry.approvedAt && !entry.rejectedAt);
      if (!request || Date.parse(request.expiresAt) <= this.now()) return false;
      request.rejectedAt = isoNow(this.now);
      state.revision += 1;
      await this.writePairingState(state);
      return true;
    });
  }

  async revoke(deviceId: string): Promise<boolean> {
    validateId(deviceId, "deviceId");
    return withLock(this.trustedFile, async () => {
      const state = await this.readTrustedState();
      const device = state.devices.find((entry) => entry.deviceId === deviceId && !entry.revokedAt);
      if (!device) return false;
      device.revokedAt = isoNow(this.now);
      state.revision += 1;
      await this.writeTrustedState(state);
      return true;
    });
  }

  async enroll(input: { deviceId: string; publicKey: string; label?: string; scopes?: string[] }): Promise<TrustedMobileDevice> {
    const deviceId = validateId(input.deviceId, "deviceId");
    const publicKey = validatePublicKey(input.publicKey);
    const label = input.label?.replace(/[\u0000-\u001f\u007f]/g, " ").trim().slice(0, 80) || undefined;
    const scopes = normalizeScopes(input.scopes);
    return withLock(this.trustedFile, async () => {
      const state = await this.readTrustedState();
      const now = isoNow(this.now);
      const existing = state.devices.find((entry) => entry.deviceId === deviceId);
      if (existing) {
        if (existing.publicKey !== publicKey && !existing.revokedAt) throw new Error("Device identity is already trusted with a different key");
        existing.publicKey = publicKey;
        existing.label = label;
        existing.scopes = scopes;
        existing.revokedAt = undefined;
        existing.lastSeenAt = now;
        state.revision += 1;
        await this.writeTrustedState(state);
        return cloneDevice(existing);
      }
      const activeCount = state.devices.filter((entry) => !entry.revokedAt).length;
      if (activeCount >= this.maxDevices) throw new Error("Trusted device limit reached");
      const device: TrustedMobileDevice = {
        deviceId,
        publicKey,
        ...(label ? { label } : {}),
        createdAt: now,
        lastSeenAt: now,
        scopes,
      };
      state.devices.push(device);
      state.revision += 1;
      await this.writeTrustedState(state);
      return cloneDevice(device);
    });
  }

  createChallenge(): PairingChallenge {
    const now = this.now();
    const challenge: ChallengeRecord = {
      challengeId: randomUUID(),
      nonce: randomBytes(32).toString("base64url"),
      expiresAt: new Date(now + DEVICE_AUTH_TIMEOUT_MS).toISOString(),
      bridgeIdentityId: this.bridgeIdentity.bridgeIdentityId,
      bridgeInstanceId: this.bridgeInstanceId,
      used: false,
    };
    this.challenges.set(challenge.challengeId, challenge);
    while (this.challenges.size > 256) this.challenges.delete(this.challenges.keys().next().value!);
    return { ...challenge };
  }

  async authenticate(input: DeviceAuthRequest): Promise<TrustedMobileDevice> {
    const challenge = this.challenges.get(input.challengeId);
    if (!challenge || challenge.used || Date.parse(challenge.expiresAt) <= this.now()) throw new Error("Device challenge is invalid or expired");
    const deviceId = validateId(input.deviceId, "deviceId");
    const publicKey = validatePublicKey(input.publicKey);
    if (input.nonce !== challenge.nonce || input.expiresAt !== challenge.expiresAt || input.bridgeIdentityId !== challenge.bridgeIdentityId || input.bridgeInstanceId !== challenge.bridgeInstanceId) throw new Error("Device challenge binding is invalid");
    const trusted = await this.trustedDevice(deviceId);
    if (!trusted || trusted.publicKey !== publicKey || trusted.revokedAt) throw new Error("Device is not trusted");
    const payload = canonicalDeviceChallengePayload({
      challengeId: challenge.challengeId,
      nonce: challenge.nonce,
      expiresAt: challenge.expiresAt,
      bridgeIdentityId: challenge.bridgeIdentityId,
      bridgeInstanceId: challenge.bridgeInstanceId,
      deviceId,
    });
    let valid = false;
    try {
      valid = verify(null, Buffer.from(payload, "utf8"), publicKeyObject(publicKey), Buffer.from(input.signature, "base64url"));
    } catch {
      valid = false;
    }
    if (!valid) throw new Error("Device signature is invalid");
    challenge.used = true;
    this.challenges.delete(challenge.challengeId);
    await withLock(this.trustedFile, async () => {
      const state = await this.readTrustedState();
      const current = state.devices.find((entry) => entry.deviceId === deviceId && !entry.revokedAt);
      if (!current || current.publicKey !== publicKey) throw new Error("Device is no longer trusted");
      current.lastSeenAt = isoNow(this.now);
      state.revision += 1;
      await this.writeTrustedState(state);
    });
    return { ...trusted, lastSeenAt: isoNow(this.now) };
  }

  private async consumeToken(token: string): Promise<boolean> {
    if (typeof token !== "string" || token.length < 40 || !/^[A-Za-z0-9_-]+$/.test(token)) return false;
    return withLock(this.pairingFile, async () => {
      const state = await this.readPairingState();
      const entry = state.tokens.find((candidate) => candidate.tokenHash === tokenHash(token) && !candidate.usedAt);
      if (!entry || Date.parse(entry.expiresAt) <= this.now()) return false;
      entry.usedAt = isoNow(this.now);
      state.revision += 1;
      await this.writePairingState(state);
      return true;
    });
  }

  private async readTrustedState(): Promise<TrustedState> {
    const raw = await readJson<unknown>(this.trustedFile, undefined);
    return validState(raw) ? raw : { version: DEVICE_PAIRING_VERSION, revision: 0, devices: [] };
  }

  private async writeTrustedState(state: TrustedState): Promise<void> {
    await atomicJsonWrite(this.trustedFile, state);
  }

  private async readPairingState(): Promise<PairingState> {
    const raw = await readJson<unknown>(this.pairingFile, undefined);
    return validPairingState(raw) ? raw : { version: DEVICE_PAIRING_VERSION, revision: 0, tokens: [], pending: [] };
  }

  private async writePairingState(state: PairingState): Promise<void> {
    await atomicJsonWrite(this.pairingFile, state);
  }
}
