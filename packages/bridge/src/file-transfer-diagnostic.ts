import { createHash, randomUUID } from "node:crypto";
import { constants as fsConstants } from "node:fs";
import {
  lstat,
  link,
  mkdir,
  open,
  readdir,
  stat,
  unlink,
} from "node:fs/promises";
import { homedir } from "node:os";
import { basename, join, resolve } from "node:path";
import { FileTransferError } from "./file-transfer-errors.js";
import type { LocalFeatureRuntimeConversationState } from "./local-features/runtime.js";

export type FileTransferPurpose = "file" | "diagnostic_report";

export interface DiagnosticReportMetadata {
  schemaVersion: 1;
  reportId: string;
  provider: string;
  providerSessionId: string;
  bridgeInstanceId: string;
  codexSourceId: string;
  capturedAtStart: string;
  capturedAtEnd: string;
  sha256: string;
}

export interface DiagnosticRuntimeIdentity {
  bridgeInstanceId?: string;
  codexSourceId?: string;
  bridgeVersion?: string;
  runtimeIdentity?: string;
}

export interface DiagnosticReportArchive {
  filename: string;
  savedPath: string;
  sizeBytes: number;
  archiveSha256: string;
  mobileReportCanonicalSha256: string;
}

export interface DiagnosticReportReceiptReference {
  filename: string;
  savedPath: string;
  purpose: "diagnostic_report";
  reportId: string;
  archiveSha256: string;
  mobileReportCanonicalSha256: string;
}

export interface DiagnosticReportArchiverOptions extends DiagnosticRuntimeIdentity {
  reportsDirectory?: string;
  getRuntimeStates?: () => LocalFeatureRuntimeConversationState[];
  now?: () => number;
  log?: (message: string) => void;
}

export const DIAGNOSTIC_REPORT_MAX_BYTES = 32 * 1024 * 1024;
export const DIAGNOSTIC_REPORT_PAYLOAD_MAX_BYTES = 16 * 1024 * 1024;
const REPORT_ID_MAX_LENGTH = 128;
const PROVIDER_MAX_LENGTH = 64;
const PROVIDER_SESSION_ID_MAX_LENGTH = 256;
const CODEX_SOURCE_ID_MAX_LENGTH = 256;
const BRIDGE_INSTANCE_ID_MAX_LENGTH = 256;
const TIMESTAMP_MAX_LENGTH = 128;
const DIAGNOSTIC_REPORT_RETENTION_MS = 7 * 24 * 60 * 60 * 1000;
const DIAGNOSTIC_REPORT_MAX_FILES = 32;
const DIAGNOSTIC_REPORT_MAX_TOTAL_BYTES = 512 * 1024 * 1024;
const DIAGNOSTIC_REPORT_STALE_TEMP_MS = 60 * 60 * 1000;
const SHA256_PATTERN = /^[a-f0-9]{64}$/u;
const SUPPORTED_DIAGNOSTIC_PROVIDERS = new Set(["claude", "codex"]);
const SAFE_REPORT_ID_PATTERN = /^[A-Za-z0-9._:-]{1,128}$/u;
const SAFE_TEMP_REPORT_PATTERN = /^([A-Za-z0-9._:-]{1,128})\.json\.tmp-[0-9]+-[0-9a-f-]{36}$/iu;
const CREDENTIAL_KEYS = new Set([
  "apikey",
  "apisecret",
  "token",
  "password",
  "passwd",
  "authorization",
  "authorizationheader",
  "accesskeyid",
  "awsaccesskeyid",
  "secret",
  "privatekey",
  "sshkey",
  "credential",
  "credentials",
  "cookie",
  "setcookie",
  "passphrase",
  "signingkey",
]);
const CREDENTIAL_STRING_PATTERNS = [
  /-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----[\s\S]*?-----END (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----/iu,
  /-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----/iu,
  /-----BEGIN PGP PRIVATE KEY BLOCK-----[\s\S]*?-----END PGP PRIVATE KEY BLOCK-----/iu,
  /-----BEGIN PGP PRIVATE KEY BLOCK-----/iu,
  /\bBearer\s+[A-Za-z0-9._~+/=-]{8,}/iu,
  /\b[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/u,
  /\bsk-[A-Za-z0-9_-]{8,}\b/u,
  /\bgithub_pat_[A-Za-z0-9_]{8,}\b/u,
  /\bgh[pousr]_[A-Za-z0-9_]{8,}\b/u,
  /\bxox[baprs]-[A-Za-z0-9-]{8,}\b/u,
  /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/u,
  /\bAIza[0-9A-Za-z_-]{20,}\b/u,
  /\b(?:bridge[ _-]*api[ _-]*key|api[ _-]*key|aws[ _-]*access[ _-]*key[ _-]*id|access[ _-]*key[ _-]*id|aws[ _-]*secret[ _-]*access[ _-]*key|secret[ _-]*access[ _-]*key|secret[ _-]*key|access[ _-]*token|refresh[ _-]*token|authorization|password|passwd|client[ _-]*secret|private[ _-]*key|signing[ _-]*key|passphrase|credentials?|cookie)\s*[=:]\s*\S{6,}/iu,
] as const;
const NETWORK_URL_PATTERN = /(?:https?|wss?):\/\/[^\s<>"']+/giu;

export function validateDiagnosticReportMetadata(
  value: unknown,
): value is DiagnosticReportMetadata {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const candidate = value as Record<string, unknown>;
  const allowed = new Set([
    "schemaVersion",
    "reportId",
    "provider",
    "providerSessionId",
    "bridgeInstanceId",
    "codexSourceId",
    "capturedAtStart",
    "capturedAtEnd",
    "sha256",
  ]);
  if (Object.keys(candidate).some((key) => !allowed.has(key))) return false;
  if (
    candidate.schemaVersion !== 1 ||
    !boundedText(candidate.reportId, REPORT_ID_MAX_LENGTH) ||
    !SAFE_REPORT_ID_PATTERN.test(candidate.reportId as string) ||
    !boundedText(candidate.provider, PROVIDER_MAX_LENGTH) ||
    !SUPPORTED_DIAGNOSTIC_PROVIDERS.has(candidate.provider as string) ||
    !boundedText(candidate.providerSessionId, PROVIDER_SESSION_ID_MAX_LENGTH) ||
    !boundedText(candidate.bridgeInstanceId, BRIDGE_INSTANCE_ID_MAX_LENGTH) ||
    !boundedText(candidate.codexSourceId, CODEX_SOURCE_ID_MAX_LENGTH) ||
    !boundedText(candidate.capturedAtStart, TIMESTAMP_MAX_LENGTH) ||
    !boundedText(candidate.capturedAtEnd, TIMESTAMP_MAX_LENGTH) ||
    !SHA256_PATTERN.test(String(candidate.sha256))
  ) {
    return false;
  }
  const start = Date.parse(candidate.capturedAtStart as string);
  const end = Date.parse(candidate.capturedAtEnd as string);
  return Number.isFinite(start) && Number.isFinite(end) && start <= end;
}

export function containsDiagnosticCredential(value: unknown): boolean {
  return containsProhibitedCredential(value);
}

export function validateDiagnosticReportIdentity(value: string): boolean {
  return (
    SAFE_REPORT_ID_PATTERN.test(value) &&
    value.length <= REPORT_ID_MAX_LENGTH &&
    value !== "." &&
    value !== ".."
  );
}

export class DiagnosticReportArchiver {
  private readonly reportsDirectory: string;
  private readonly now: () => number;
  private readonly log: (message: string) => void;
  private runtimeStates?: () => LocalFeatureRuntimeConversationState[];
  private readonly identity: DiagnosticRuntimeIdentity;
  private initBarrier?: Promise<void>;
  private reportsDirectoryIdentity?: { dev: number; ino: number };

  constructor(options: DiagnosticReportArchiverOptions = {}) {
    this.reportsDirectory = resolve(
      options.reportsDirectory ?? join(homedir(), ".ccpocket", "diagnostics", "reports"),
    );
    this.now = options.now ?? Date.now;
    this.log = options.log ?? ((message) => console.info(`[diagnostic] ${message}`));
    this.runtimeStates = options.getRuntimeStates;
    this.identity = {
      ...(options.bridgeInstanceId ? { bridgeInstanceId: options.bridgeInstanceId } : {}),
      ...(options.codexSourceId ? { codexSourceId: options.codexSourceId } : {}),
      ...(options.bridgeVersion ? { bridgeVersion: options.bridgeVersion } : {}),
      ...(options.runtimeIdentity ? { runtimeIdentity: options.runtimeIdentity } : {}),
    };
  }

  setRuntimeStateProvider(
    provider: () => LocalFeatureRuntimeConversationState[],
  ): void {
    this.runtimeStates = provider;
  }

  async init(): Promise<void> {
    await this.ensureDirectory();
    await this.cleanupRetention();
  }

  async archive(
    metadata: DiagnosticReportMetadata,
    bytes: Buffer,
    declaredSizeBytes: number,
  ): Promise<DiagnosticReportArchive> {
    const startedAt = this.now();
    if (containsProhibitedCredential(metadata)) {
      throw diagnosticError("diagnostic_sensitive_field", "Diagnostic report contains a prohibited authentication field");
    }
    if (!validateDiagnosticReportMetadata(metadata)) {
      throw diagnosticError("diagnostic_metadata_invalid", "Diagnostic metadata is invalid");
    }
    if (bytes.length !== declaredSizeBytes || bytes.length > DIAGNOSTIC_REPORT_PAYLOAD_MAX_BYTES) {
      throw diagnosticError("diagnostic_size_mismatch", "Diagnostic report size does not match its declaration");
    }
    const actualSha256 = createHash("sha256").update(bytes).digest("hex");
    if (actualSha256 !== metadata.sha256) {
      throw diagnosticError("diagnostic_sha256_mismatch", "Diagnostic report checksum does not match its declaration");
    }
    let payload: unknown;
    try {
      payload = JSON.parse(bytes.toString("utf8"));
    } catch {
      throw diagnosticError("diagnostic_invalid_json", "Diagnostic report is not valid JSON");
    }
    if (containsProhibitedCredential(payload)) {
      throw diagnosticError("diagnostic_sensitive_field", "Diagnostic report contains a prohibited authentication field");
    }
    if (metadata.bridgeInstanceId !== this.identity.bridgeInstanceId) {
      throw diagnosticError("diagnostic_source_mismatch", "Diagnostic Bridge identity does not match this runtime");
    }
    if (
      !metadata.codexSourceId ||
      metadata.codexSourceId !== this.identity.codexSourceId
    ) {
      throw diagnosticError("diagnostic_source_mismatch", "Diagnostic Codex source does not match this runtime");
    }
    if (!hasMatchingMobilePayloadIdentity(payload, metadata)) {
      throw diagnosticError("diagnostic_payload_identity_mismatch", "Diagnostic payload identity does not match its metadata");
    }
    await this.ensureDirectory();
    const filename = diagnosticReportFilename(metadata);
    const destination = join(this.reportsDirectory, filename);
    const canonicalPayloadSha256 = createHash("sha256")
      .update(JSON.stringify(payload))
      .digest("hex");
    const existing = await this.readExistingArchive(
      destination,
      metadata,
      canonicalPayloadSha256,
    );
    if (existing) {
      await this.cleanupRetention(filename);
      return existing;
    }

    const matchingState = (this.runtimeStates?.() ?? []).find(
      (state) =>
        state.provider === metadata.provider &&
        state.providerSessionId === metadata.providerSessionId,
    );
    const bridge = {
      bridgeInstanceId: this.identity.bridgeInstanceId ?? null,
      codexSourceId: this.identity.codexSourceId ?? null,
      bridgeVersion: this.identity.bridgeVersion ?? null,
      runtimeIdentity: this.identity.runtimeIdentity ?? null,
      runtimeState: matchingState
        ? {
            provider: matchingState.provider,
            providerSessionId: matchingState.providerSessionId,
            executionHost: matchingState.executionHost ?? null,
            controlState: matchingState.controlState ?? null,
            authorityGeneration: matchingState.authorityGeneration ?? null,
            activeTurnId: matchingState.activeTurnId ?? null,
            pendingAttention: matchingState.pendingAttention
              ? {
                  requestId: matchingState.pendingAttention.requestId,
                  kind: matchingState.pendingAttention.kind,
                }
              : null,
            processStatus: matchingState.processStatus,
            observedAt: matchingState.observedAt,
          }
        : null,
    };
    const envelope = {
      schemaVersion: metadata.schemaVersion,
      reportId: metadata.reportId,
      provider: metadata.provider,
      providerSessionId: metadata.providerSessionId,
      bridgeInstanceId: metadata.bridgeInstanceId,
      codexSourceId: metadata.codexSourceId,
      capturedAtStart: metadata.capturedAtStart,
      capturedAtEnd: metadata.capturedAtEnd,
      sha256: metadata.sha256,
      mobileReportCanonicalSha256: canonicalPayloadSha256,
      mobileReport: payload,
      bridge,
    };
    if (containsProhibitedCredential(envelope)) {
      throw diagnosticError("diagnostic_sensitive_field", "Diagnostic report contains a prohibited authentication field");
    }
    const serialized = Buffer.from(`${JSON.stringify(envelope, null, 2)}\n`, "utf8");
    if (serialized.length > DIAGNOSTIC_REPORT_MAX_BYTES) {
      throw diagnosticError("diagnostic_envelope_too_large", "Diagnostic archive exceeds its safe size limit");
    }
    const published = await this.publish(
      destination,
      serialized,
      metadata,
      canonicalPayloadSha256,
    );
    await this.cleanupRetention(filename);
    const elapsedMs = Math.max(0, this.now() - startedAt);
    this.log(
      `reportId=${metadata.reportId} bytes=${published.sizeBytes} elapsedMs=${elapsedMs} path=${destination}`,
    );
    return published;
  }

  /** Verifies a persisted replay receipt against the immutable archive. */
  async verifyReceipt(
    metadata: DiagnosticReportMetadata,
    receipt: DiagnosticReportReceiptReference,
  ): Promise<boolean> {
    if (!validateDiagnosticReportMetadata(metadata)) {
      throw diagnosticError("diagnostic_metadata_invalid", "Diagnostic metadata is invalid");
    }
    if (
      metadata.bridgeInstanceId !== this.identity.bridgeInstanceId ||
      !metadata.codexSourceId ||
      metadata.codexSourceId !== this.identity.codexSourceId
    ) {
      throw diagnosticError("diagnostic_source_mismatch", "Diagnostic source does not match this runtime");
    }
    await this.ensureDirectory();
    await this.assertDirectoryIdentity();
    const filename = diagnosticReportFilename(metadata);
    const destination = join(this.reportsDirectory, filename);
    if (
      receipt.purpose !== "diagnostic_report" ||
      receipt.reportId !== metadata.reportId ||
      receipt.filename !== filename ||
      receipt.savedPath !== destination ||
      !SHA256_PATTERN.test(receipt.archiveSha256) ||
      !SHA256_PATTERN.test(receipt.mobileReportCanonicalSha256)
    ) {
      throw diagnosticError("diagnostic_receipt_identity_mismatch", "Diagnostic receipt does not match its archive identity");
    }
    let handle: Awaited<ReturnType<typeof open>> | undefined;
    try {
      handle = await open(
        destination,
        fsConstants.O_RDONLY |
          (typeof fsConstants.O_NOFOLLOW === "number" ? fsConstants.O_NOFOLLOW : 0),
      );
      const stats = await handle.stat();
      if (!stats.isFile() || stats.size < 1 || stats.size > DIAGNOSTIC_REPORT_MAX_BYTES) {
        throw diagnosticError("diagnostic_report_collision", "Diagnostic report archive is invalid");
      }
      const archiveBytes = await handle.readFile();
      const finalOpenedStats = await handle.stat();
      if (!sameReadIdentity(stats, finalOpenedStats)) {
        throw diagnosticError("diagnostic_report_collision", "Diagnostic report archive changed during verification");
      }
      const value = JSON.parse(archiveBytes.toString("utf8")) as unknown;
      if (
        containsProhibitedCredential(value) ||
        !isMatchingArchive(
          value,
          metadata,
          receipt.mobileReportCanonicalSha256,
        ) ||
        createHash("sha256").update(archiveBytes).digest("hex") !==
          receipt.archiveSha256
      ) {
        throw diagnosticError("diagnostic_report_collision", "Diagnostic report archive is invalid");
      }
      await this.assertDirectoryIdentity();
      const pathIdentity = await lstat(destination);
      if (
        !pathIdentity.isFile() ||
        pathIdentity.isSymbolicLink() ||
        pathIdentity.dev !== stats.dev ||
        pathIdentity.ino !== stats.ino ||
        pathIdentity.size !== stats.size
      ) {
        return false;
      }
      return true;
    } catch (error) {
      if (nodeCode(error) === "ENOENT") return false;
      if (error instanceof FileTransferError) throw error;
      throw diagnosticError("diagnostic_report_collision", "Diagnostic report archive is invalid");
    } finally {
      await handle?.close().catch(() => undefined);
    }
  }

  private async ensureDirectory(): Promise<void> {
    this.initBarrier ??= (async () => {
      await mkdir(this.reportsDirectory, { recursive: true, mode: 0o700 });
      const lexical = await lstat(this.reportsDirectory);
      const canonical = await stat(this.reportsDirectory);
      if (
        !lexical.isDirectory() ||
        lexical.isSymbolicLink() ||
        !canonical.isDirectory()
      ) {
        throw diagnosticError("diagnostic_directory_unsafe", "Diagnostic report directory is unavailable");
      }
      const directoryHandle = await open(
        this.reportsDirectory,
        fsConstants.O_RDONLY |
          (typeof fsConstants.O_NOFOLLOW === "number" ? fsConstants.O_NOFOLLOW : 0),
      );
      try {
        const opened = await directoryHandle.stat();
        if (
          !opened.isDirectory() ||
          opened.dev !== lexical.dev ||
          opened.ino !== lexical.ino
        ) {
          throw diagnosticError("diagnostic_directory_unsafe", "Diagnostic report directory is unavailable");
        }
        await directoryHandle.chmod(0o700);
      } finally {
        await directoryHandle.close();
      }
      const finalIdentity = await lstat(this.reportsDirectory);
      if (
        !finalIdentity.isDirectory() ||
        finalIdentity.isSymbolicLink() ||
        finalIdentity.dev !== lexical.dev ||
        finalIdentity.ino !== lexical.ino
      ) {
        throw diagnosticError("diagnostic_directory_unsafe", "Diagnostic report directory is unavailable");
      }
      this.reportsDirectoryIdentity = { dev: lexical.dev, ino: lexical.ino };
    })().catch((error) => {
      this.initBarrier = undefined;
      throw error;
    });
    return this.initBarrier;
  }

  private async publish(
    destination: string,
    bytes: Buffer,
    metadata: DiagnosticReportMetadata,
    canonicalPayloadSha256: string,
  ): Promise<DiagnosticReportArchive> {
    const temporary = `${destination}.tmp-${process.pid}-${randomUUID()}`;
    let handle: Awaited<ReturnType<typeof open>> | undefined;
    let publishedHandle: Awaited<ReturnType<typeof open>> | undefined;
    let temporaryIdentity: { dev: number; ino: number } | undefined;
    let reusedArchive: DiagnosticReportArchive | undefined;
    try {
      await this.assertDirectoryIdentity();
      try {
        const existing = await this.readExistingArchive(
          destination,
          metadata,
          canonicalPayloadSha256,
        );
        if (existing) return existing;
      } catch (error) {
        if (nodeCode(error) !== "ENOENT") throw error;
      }
      handle = await open(
        temporary,
        fsConstants.O_WRONLY |
          fsConstants.O_CREAT |
          fsConstants.O_EXCL |
          (typeof fsConstants.O_NOFOLLOW === "number" ? fsConstants.O_NOFOLLOW : 0),
        0o600,
      );
      const created = await handle.stat();
      temporaryIdentity = { dev: created.dev, ino: created.ino };
      await handle.writeFile(bytes);
      await handle.sync();
      await handle.close();
      handle = undefined;
      // rename(2) replaces an existing destination. Publish through a hard
      // link instead so two concurrent reports with the same identity can
      // never silently overwrite each other. The losing writer observes
      // EEXIST and validates the already-published bytes below.
      try {
        await link(temporary, destination);
        await this.assertDirectoryIdentity();
      } catch (error) {
        if (nodeCode(error) !== "EEXIST") throw error;
        const existing = await this.readExistingArchive(
          destination,
          metadata,
          canonicalPayloadSha256,
        );
        if (!existing) {
          throw diagnosticError("diagnostic_report_collision", "Diagnostic report destination is occupied");
        }
        reusedArchive = existing;
      }
      await this.assertDirectoryIdentity();
      if (reusedArchive) {
        await unlinkExactTemporary(temporary, temporaryIdentity);
        return reusedArchive;
      }
      publishedHandle = await open(
        destination,
        fsConstants.O_RDONLY |
          (typeof fsConstants.O_NOFOLLOW === "number" ? fsConstants.O_NOFOLLOW : 0),
      );
      const published = await publishedHandle.stat();
      if (
        !published.isFile() ||
        published.dev !== temporaryIdentity.dev ||
        published.ino !== temporaryIdentity.ino
      ) {
        throw diagnosticError("diagnostic_publish_failed", "Diagnostic report publication failed");
      }
      await publishedHandle.chmod(0o600);
      await publishedHandle.sync();
      await publishedHandle.close();
      publishedHandle = undefined;
      await this.assertDirectoryIdentity();
      await unlinkExactTemporary(temporary, temporaryIdentity);
      await fsyncDirectory(this.reportsDirectory);
      await this.assertDirectoryIdentity();
      const finalIdentity = await lstat(destination);
      if (
        !finalIdentity.isFile() ||
        finalIdentity.isSymbolicLink() ||
        finalIdentity.dev !== temporaryIdentity.dev ||
        finalIdentity.ino !== temporaryIdentity.ino
      ) {
        throw diagnosticError("diagnostic_publish_failed", "Diagnostic report publication failed");
      }
      return {
        filename: basename(destination),
        savedPath: destination,
        sizeBytes: bytes.length,
        archiveSha256: createHash("sha256").update(bytes).digest("hex"),
        mobileReportCanonicalSha256: canonicalPayloadSha256,
      };
    } catch (error) {
      await handle?.close().catch(() => undefined);
      await publishedHandle?.close().catch(() => undefined);
      await this.assertDirectoryIdentity()
        .then(() => unlinkExactTemporary(temporary, temporaryIdentity))
        .catch(() => undefined);
      if (error instanceof FileTransferError) throw error;
      throw diagnosticError(
        "diagnostic_publish_failed",
        `Unable to save diagnostic report ${metadata.reportId}`,
      );
    }
  }

  private async readExistingArchive(
    destination: string,
    metadata: DiagnosticReportMetadata,
    canonicalPayloadSha256: string,
  ): Promise<DiagnosticReportArchive | undefined> {
    let handle: Awaited<ReturnType<typeof open>> | undefined;
    try {
      handle = await open(
        destination,
        fsConstants.O_RDONLY |
          (typeof fsConstants.O_NOFOLLOW === "number" ? fsConstants.O_NOFOLLOW : 0),
      );
      const stats = await handle.stat();
      if (!stats.isFile() || stats.size < 1 || stats.size > DIAGNOSTIC_REPORT_MAX_BYTES) {
        throw diagnosticError("diagnostic_report_collision", "Diagnostic report destination is occupied");
      }
      const bytes = await handle.readFile();
      const finalOpenedStats = await handle.stat();
      if (!sameReadIdentity(stats, finalOpenedStats)) {
        throw diagnosticError("diagnostic_report_collision", "Diagnostic report destination changed during verification");
      }
      let value: unknown;
      try {
        value = JSON.parse(bytes.toString("utf8"));
      } catch {
        throw diagnosticError("diagnostic_report_collision", "Diagnostic report destination is occupied");
      }
      if (
        containsProhibitedCredential(value) ||
        !isMatchingArchive(value, metadata, canonicalPayloadSha256)
      ) {
        throw diagnosticError("diagnostic_report_collision", "Diagnostic report destination is occupied");
      }
      await handle.chmod(0o600);
      await this.assertDirectoryIdentity();
      const pathIdentity = await lstat(destination);
      if (
        !pathIdentity.isFile() ||
        pathIdentity.isSymbolicLink() ||
        pathIdentity.dev !== stats.dev ||
        pathIdentity.ino !== stats.ino ||
        pathIdentity.size !== stats.size
      ) {
        throw diagnosticError(
          "diagnostic_report_collision",
          "Diagnostic report destination changed during verification",
        );
      }
      return {
        filename: basename(destination),
        savedPath: destination,
        sizeBytes: bytes.length,
        archiveSha256: createHash("sha256").update(bytes).digest("hex"),
        mobileReportCanonicalSha256: canonicalPayloadSha256,
      };
    } catch (error) {
      if (nodeCode(error) === "ENOENT") return undefined;
      if (error instanceof FileTransferError) throw error;
      throw diagnosticError("diagnostic_report_collision", "Diagnostic report destination is occupied");
    } finally {
      await handle?.close().catch(() => undefined);
    }
  }

  private async cleanupRetention(protectedFilename?: string): Promise<void> {
    await this.assertDirectoryIdentity();
    const now = this.now();
    const candidates: Array<{
      filename: string;
      path: string;
      size: number;
      mtimeMs: number;
    }> = [];
    let removed = false;
    for (const entry of await readdir(this.reportsDirectory, { withFileTypes: true })) {
      if (!entry.isFile() || entry.isSymbolicLink()) continue;
      const temporaryMatch = SAFE_TEMP_REPORT_PATTERN.exec(entry.name);
      if (temporaryMatch) {
        const reportId = temporaryMatch[1];
        if (!reportId || !validateDiagnosticReportIdentity(reportId)) continue;
        const temporaryPath = join(this.reportsDirectory, entry.name);
        const temporary = await lstat(temporaryPath).catch(() => undefined);
        if (
          temporary?.isFile() &&
          !temporary.isSymbolicLink() &&
          now - temporary.mtimeMs > DIAGNOSTIC_REPORT_STALE_TEMP_MS
        ) {
          await unlink(temporaryPath).catch((error) => {
            if (nodeCode(error) !== "ENOENT") throw error;
          });
          removed = true;
        }
        continue;
      }
      if (!entry.name.endsWith(".json")) continue;
      const reportId = entry.name.slice(0, -".json".length);
      if (!validateDiagnosticReportIdentity(reportId)) continue;
      const path = join(this.reportsDirectory, entry.name);
      const details = await lstat(path).catch(() => undefined);
      if (!details?.isFile() || details.isSymbolicLink()) continue;
      candidates.push({
        filename: entry.name,
        path,
        size: details.size,
        mtimeMs: details.mtimeMs,
      });
    }
    candidates.sort((left, right) => right.mtimeMs - left.mtimeMs);
    let retainedCount = 0;
    let retainedBytes = 0;
    for (const candidate of candidates) {
      const protectedReport = candidate.filename === protectedFilename;
      const withinAge = now - candidate.mtimeMs <= DIAGNOSTIC_REPORT_RETENTION_MS;
      const withinCount = retainedCount < DIAGNOSTIC_REPORT_MAX_FILES;
      const withinBytes =
        retainedBytes + candidate.size <= DIAGNOSTIC_REPORT_MAX_TOTAL_BYTES;
      if (protectedReport || (withinAge && withinCount && withinBytes)) {
        retainedCount += 1;
        retainedBytes += candidate.size;
        continue;
      }
      await unlink(candidate.path).catch((error) => {
        if (nodeCode(error) !== "ENOENT") throw error;
      });
      removed = true;
    }
    if (removed) await fsyncDirectory(this.reportsDirectory);
    await this.assertDirectoryIdentity();
  }

  private async assertDirectoryIdentity(): Promise<void> {
    const expected = this.reportsDirectoryIdentity;
    if (!expected) {
      throw diagnosticError("diagnostic_directory_unsafe", "Diagnostic report directory is unavailable");
    }
    try {
      const lexical = await lstat(this.reportsDirectory);
      const canonical = await stat(this.reportsDirectory);
      if (
        !lexical.isDirectory() ||
        lexical.isSymbolicLink() ||
        !canonical.isDirectory() ||
        lexical.dev !== expected.dev ||
        lexical.ino !== expected.ino
      ) {
        throw diagnosticError("diagnostic_directory_changed", "Diagnostic report directory changed");
      }
    } catch (error) {
      if (error instanceof FileTransferError) throw error;
      throw diagnosticError("diagnostic_directory_changed", "Diagnostic report directory changed");
    }
  }
}

function boundedText(value: unknown, maxLength: number): value is string {
  return typeof value === "string" && value.length > 0 && value.length <= maxLength && !value.includes("\0");
}

function diagnosticReportFilename(metadata: DiagnosticReportMetadata): string {
  if (!validateDiagnosticReportIdentity(metadata.reportId)) {
    throw diagnosticError("diagnostic_report_id_invalid", "Diagnostic report id is unsafe");
  }
  const filename = `${metadata.reportId}.json`;
  if (basename(filename) !== filename) {
    throw diagnosticError("diagnostic_report_id_invalid", "Diagnostic report id is unsafe");
  }
  return filename;
}

function containsProhibitedCredential(value: unknown): boolean {
  const pending: Array<{ value: unknown; depth: number }> = [{ value, depth: 0 }];
  let visited = 0;
  while (pending.length > 0) {
    const current = pending.pop()!;
    visited += 1;
    if (visited > 100_000 || current.depth > 64) return true;
    if (typeof current.value === "string") {
      const text = current.value;
      if (CREDENTIAL_STRING_PATTERNS.some((pattern) => pattern.test(text))) return true;
      if (containsUnsafeNetworkUrl(text)) return true;
      continue;
    }
    if (Array.isArray(current.value)) {
      for (const item of current.value) pending.push({ value: item, depth: current.depth + 1 });
      continue;
    }
    if (!current.value || typeof current.value !== "object") continue;
    for (const [key, nested] of Object.entries(current.value as Record<string, unknown>)) {
      if (isProhibitedCredentialKey(key)) return true;
      pending.push({ value: nested, depth: current.depth + 1 });
    }
  }
  return false;
}

function containsUnsafeNetworkUrl(value: string): boolean {
  for (const match of value.matchAll(NETWORK_URL_PATTERN)) {
    try {
      const parsed = new URL(match[0]);
      if (parsed.username || parsed.password || parsed.hash) return true;
      if (parsed.search) {
        const entries = [...parsed.searchParams.entries()];
        const mobileRedactionMarker =
          entries.length === 1 &&
          entries[0]?.[0] === "ccpocket_redacted" &&
          entries[0]?.[1] === "1";
        if (!mobileRedactionMarker) return true;
      }
    } catch {
      return true;
    }
  }
  return false;
}

function isProhibitedCredentialKey(key: string): boolean {
  const normalized = key.toLowerCase().replace(/[^a-z0-9]/gu, "");
  return CREDENTIAL_KEYS.has(normalized) ||
    normalized.endsWith("apikey") ||
    normalized.endsWith("token") ||
    normalized.endsWith("secret") ||
    normalized.endsWith("secretkey") ||
    normalized.endsWith("accesskeyid") ||
    normalized.includes("secretaccesskey") ||
    normalized.endsWith("password") ||
    normalized.includes("authorization") ||
    normalized.includes("privatekey") ||
    normalized.includes("signingkey") ||
    normalized.endsWith("passphrase") ||
    normalized.endsWith("credential") ||
    normalized.endsWith("credentials") ||
    normalized.endsWith("cookie");
}

function isMatchingArchive(
  value: unknown,
  metadata: DiagnosticReportMetadata,
  canonicalPayloadSha256: string,
): boolean {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const candidate = value as Record<string, unknown>;
  if (
    candidate.schemaVersion !== metadata.schemaVersion ||
    candidate.reportId !== metadata.reportId ||
    candidate.provider !== metadata.provider ||
    candidate.providerSessionId !== metadata.providerSessionId ||
    candidate.bridgeInstanceId !== metadata.bridgeInstanceId ||
    candidate.codexSourceId !== metadata.codexSourceId ||
    candidate.capturedAtStart !== metadata.capturedAtStart ||
    candidate.capturedAtEnd !== metadata.capturedAtEnd ||
    candidate.sha256 !== metadata.sha256 ||
    candidate.mobileReportCanonicalSha256 !== canonicalPayloadSha256 ||
    candidate.mobileReport === undefined
  ) {
    return false;
  }
  try {
    return createHash("sha256")
      .update(JSON.stringify(candidate.mobileReport))
      .digest("hex") === canonicalPayloadSha256;
  } catch {
    return false;
  }
}

function hasMatchingMobilePayloadIdentity(
  payload: unknown,
  metadata: DiagnosticReportMetadata,
): boolean {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) return false;
  const report = payload as Record<string, unknown>;
  const target = recordValue(report.target);
  const mobile = recordValue(report.mobile);
  const infrastructure = recordValue(mobile?.infrastructure);
  if (
    report.schemaVersion !== metadata.schemaVersion ||
    report.reportId !== metadata.reportId ||
    target?.provider !== metadata.provider ||
    target.providerSessionId !== metadata.providerSessionId ||
    infrastructure?.bridgeInstanceId !== metadata.bridgeInstanceId
  ) {
    return false;
  }
  if (infrastructure.codexSourceId !== metadata.codexSourceId) {
    return false;
  }
  return true;
}

function recordValue(value: unknown): Record<string, unknown> | undefined {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : undefined;
}

function sameReadIdentity(
  before: Awaited<ReturnType<Awaited<ReturnType<typeof open>>["stat"]>>,
  after: Awaited<ReturnType<Awaited<ReturnType<typeof open>>["stat"]>>,
): boolean {
  return before.isFile() &&
    after.isFile() &&
    before.dev === after.dev &&
    before.ino === after.ino &&
    before.size === after.size &&
    before.mtimeMs === after.mtimeMs &&
    before.ctimeMs === after.ctimeMs;
}

async function unlinkExactTemporary(
  path: string,
  identity: { dev: number; ino: number } | undefined,
): Promise<void> {
  if (!identity) return;
  const current = await lstat(path).catch((error) => {
    if (nodeCode(error) === "ENOENT") return undefined;
    throw error;
  });
  if (!current) return;
  if (
    !current.isFile() ||
    current.isSymbolicLink() ||
    current.dev !== identity.dev ||
    current.ino !== identity.ino
  ) {
    throw diagnosticError("diagnostic_publish_failed", "Diagnostic temporary file changed");
  }
  await unlink(path);
}

function diagnosticError(code: string, message: string): FileTransferError {
  return new FileTransferError(422, code, message);
}

async function fsyncDirectory(path: string): Promise<void> {
  let handle: Awaited<ReturnType<typeof open>> | undefined;
  try {
    handle = await open(path, "r");
    await handle.sync();
  } finally {
    await handle?.close().catch(() => undefined);
  }
}

function nodeCode(error: unknown): string | undefined {
  return typeof error === "object" && error !== null && "code" in error
    ? String((error as { code?: unknown }).code)
    : undefined;
}
