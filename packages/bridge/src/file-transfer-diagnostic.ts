import { createHash } from "node:crypto";
import { constants as fsConstants } from "node:fs";
import {
  chmod,
  lstat,
  mkdir,
  open,
  rename,
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
  codexSourceId?: string;
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
}

export interface DiagnosticReportArchiverOptions extends DiagnosticRuntimeIdentity {
  reportsDirectory?: string;
  getRuntimeStates?: () => LocalFeatureRuntimeConversationState[];
  now?: () => number;
  log?: (message: string) => void;
}

export const DIAGNOSTIC_REPORT_MAX_BYTES = 32 * 1024 * 1024;
const REPORT_ID_MAX_LENGTH = 128;
const PROVIDER_MAX_LENGTH = 64;
const PROVIDER_SESSION_ID_MAX_LENGTH = 256;
const CODEX_SOURCE_ID_MAX_LENGTH = 256;
const TIMESTAMP_MAX_LENGTH = 128;
const SHA256_PATTERN = /^[a-f0-9]{64}$/u;
const SAFE_REPORT_ID_PATTERN = /^[A-Za-z0-9._:-]{1,128}$/u;
const CREDENTIAL_KEY_PATTERN = /^(?:api[_-]?key|pairing[_-]?token|token|password|authorization(?:[_-]?header)?|secret)$/iu;
const CREDENTIAL_REGION_PATTERN = /^(?:infrastructure|connection|auth)$/iu;

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
    !boundedText(candidate.providerSessionId, PROVIDER_SESSION_ID_MAX_LENGTH) ||
    (candidate.codexSourceId !== undefined &&
      !boundedText(candidate.codexSourceId, CODEX_SOURCE_ID_MAX_LENGTH)) ||
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

  async archive(
    metadata: DiagnosticReportMetadata,
    bytes: Buffer,
    declaredSizeBytes: number,
  ): Promise<DiagnosticReportArchive> {
    const startedAt = this.now();
    if (!validateDiagnosticReportMetadata(metadata)) {
      throw diagnosticError("diagnostic_metadata_invalid", "Diagnostic metadata is invalid");
    }
    if (bytes.length !== declaredSizeBytes || bytes.length > DIAGNOSTIC_REPORT_MAX_BYTES) {
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
      ...(metadata.codexSourceId ? { codexSourceId: metadata.codexSourceId } : {}),
      capturedAtStart: metadata.capturedAtStart,
      capturedAtEnd: metadata.capturedAtEnd,
      sha256: metadata.sha256,
      mobileReport: payload,
      bridge,
    };
    const serialized = Buffer.from(`${JSON.stringify(envelope, null, 2)}\n`, "utf8");
    await this.ensureDirectory();
    const filename = diagnosticReportFilename(metadata);
    const destination = join(this.reportsDirectory, filename);
    await this.publish(destination, serialized, metadata.reportId);
    const elapsedMs = Math.max(0, this.now() - startedAt);
    this.log(
      `reportId=${metadata.reportId} bytes=${serialized.length} elapsedMs=${elapsedMs} path=${destination}`,
    );
    return { filename, savedPath: destination, sizeBytes: serialized.length };
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
      await chmod(this.reportsDirectory, 0o700);
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
    reportId: string,
  ): Promise<void> {
    const temporary = `${destination}.tmp-${process.pid}-${this.now()}`;
    let handle: Awaited<ReturnType<typeof open>> | undefined;
    try {
      await this.assertDirectoryIdentity();
      try {
        const existing = await open(
          destination,
          fsConstants.O_RDONLY |
            (typeof fsConstants.O_NOFOLLOW === "number" ? fsConstants.O_NOFOLLOW : 0),
        );
        try {
          const stats = await existing.stat();
          if (!stats.isFile() || stats.size !== bytes.length) {
            throw diagnosticError("diagnostic_report_collision", "Diagnostic report destination is occupied");
          }
          const existingBytes = await existing.readFile();
          if (!existingBytes.equals(bytes)) {
            throw diagnosticError("diagnostic_report_collision", "Diagnostic report destination is occupied");
          }
          return;
        } finally {
          await existing.close().catch(() => undefined);
        }
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
      await handle.writeFile(bytes);
      await handle.sync();
      await handle.close();
      handle = undefined;
      await rename(temporary, destination);
      const published = await lstat(destination);
      if (!published.isFile() || published.isSymbolicLink()) {
        throw diagnosticError("diagnostic_publish_failed", "Diagnostic report publication failed");
      }
      await chmod(destination, 0o600);
      await fsyncDirectory(this.reportsDirectory);
    } catch (error) {
      await handle?.close().catch(() => undefined);
      await unlink(temporary).catch(() => undefined);
      if (error instanceof FileTransferError) throw error;
      throw diagnosticError(
        "diagnostic_publish_failed",
        `Unable to save diagnostic report ${reportId}`,
      );
    }
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
  const timestamp = metadata.capturedAtEnd
    .replace(/[^0-9A-Za-z]/gu, "")
    .slice(0, 32);
  const filename = `${metadata.reportId}-${timestamp || "report"}.json`;
  if (basename(filename) !== filename) {
    throw diagnosticError("diagnostic_report_id_invalid", "Diagnostic report id is unsafe");
  }
  return filename;
}

function containsProhibitedCredential(value: unknown, region = false, root = true): boolean {
  if (Array.isArray(value)) return value.some((item) => containsProhibitedCredential(item, region, false));
  if (!value || typeof value !== "object") return false;
  return Object.entries(value as Record<string, unknown>).some(
    ([key, nested]) =>
      (root || region) && CREDENTIAL_KEY_PATTERN.test(key)
        ? true
        : containsProhibitedCredential(
            nested,
            region || CREDENTIAL_REGION_PATTERN.test(key),
            false,
          ),
  );
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
