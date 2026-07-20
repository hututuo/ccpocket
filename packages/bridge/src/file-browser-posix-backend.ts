import { spawn } from "node:child_process";
import { constants as fsConstants } from "node:fs";
import { access, open } from "node:fs/promises";
import type { FileHandle } from "node:fs/promises";
import { dirname, join, sep } from "node:path";
import { fileURLToPath } from "node:url";
import type { FileBrowserNodeKind } from "./local-features/slots/file-browser-protocol.js";

const HELPER_ROOT_FD = 3;
const FILE_BROWSER_POSIX_HELPER_NAME = "file-browser-posix-helper";
const HELPER_TIMEOUT_MS = 15_000;
const HELPER_MAX_TEXT_BYTES = 4_096;
// A full 200-entry page can contain 200 UTF-8 names of 4 KiB each. The helper
// hex-encodes those names, so the protocol ceiling must cover that valid page
// while still remaining strictly bounded.
const HELPER_MAX_OUTPUT_BYTES = 2 * 1024 * 1024;
export const FILE_BROWSER_MAX_DIRECTORY_ENTRIES = 100_000;
export const FILE_BROWSER_MAX_DIRECTORY_NAME_BYTES = 16 * 1024 * 1024;

export interface FileBrowserRootIdentity {
  dev: string;
  ino: string;
}

export interface FileBrowserNativeStats {
  kind: FileBrowserNodeKind;
  dev: string;
  ino: string;
  mode: number;
  size: number;
  mtimeMs: number;
  ctimeMs: number;
}

export interface FileBrowserNativeListResult {
  directory: FileBrowserNativeStats;
  revision: string;
  totalEntries: number;
  nextIndex?: number;
  names: string[];
}

export interface FileBrowserNativeStatSpec {
  sourceParent: string;
  /** Re-opened parents must still be the directory inode that was listed. */
  sourceParentIdentity?: FileBrowserRootIdentity;
  /** Omitted only when the source itself is the root. */
  sourceName?: string;
  /** Omitted for a broken or root-escaping terminal symlink. */
  targetCanonical?: string;
}

export type FileBrowserNativeStatResult =
  | {
      success: true;
      source: FileBrowserNativeStats;
      target?: FileBrowserNativeStats;
    }
  | { success: false; errorCode: string };

export interface FileBrowserPosixBackendOptions {
  helperPath?: string;
  platform?: NodeJS.Platform;
  maxDirectoryEntries?: number;
  maxDirectoryNameBytes?: number;
  timeoutMs?: number;
}

export class FileBrowserBackendError extends Error {
  constructor(readonly code: string, message: string) {
    super(message);
  }
}

/**
 * POSIX descriptor-bound filesystem adapter.
 *
 * Node opens and pins the configured root inode. The child receives that open
 * descriptor as fd 3; every descendant is then traversed with openat and
 * O_NOFOLLOW. Neither helper stdout nor helper errors contain an absolute path.
 */
export class FileBrowserPosixBackend {
  private readonly helperPath: string;
  private readonly platform: NodeJS.Platform;
  private readonly maxDirectoryEntries: number;
  private readonly maxDirectoryNameBytes: number;
  private readonly timeoutMs: number;
  private ready = false;

  constructor(options: FileBrowserPosixBackendOptions = {}) {
    this.helperPath = options.helperPath ?? defaultHelperPath();
    this.platform = options.platform ?? process.platform;
    this.maxDirectoryEntries = boundedPositiveInteger(
      options.maxDirectoryEntries,
      FILE_BROWSER_MAX_DIRECTORY_ENTRIES,
    );
    this.maxDirectoryNameBytes = boundedPositiveInteger(
      options.maxDirectoryNameBytes,
      FILE_BROWSER_MAX_DIRECTORY_NAME_BYTES,
    );
    this.timeoutMs = boundedPositiveInteger(options.timeoutMs, HELPER_TIMEOUT_MS);
  }

  async init(): Promise<void> {
    if (this.ready) return;
    if (this.platform !== "darwin" && this.platform !== "linux") {
      throw new FileBrowserBackendError(
        "helper_unsupported",
        "Secure file browsing is unavailable on this platform",
      );
    }
    try {
      await access(this.helperPath, fsConstants.X_OK);
    } catch {
      throw new FileBrowserBackendError(
        "helper_unavailable",
        "Secure file browser helper is unavailable",
      );
    }
    const output = await this.runUnbound(["version"]);
    if (output.trim() !== "OK\t3") {
      throw new FileBrowserBackendError(
        "helper_incompatible",
        "Secure file browser helper version is incompatible",
      );
    }
    this.ready = true;
  }

  async inspectRoot(canonicalPath: string): Promise<FileBrowserRootIdentity> {
    await this.init();
    const output = await this.runUnbound([
      "inspect-root",
      encodeText(canonicalPath),
    ]);
    const fields = output.trim().split("\t");
    if (fields[0] === "ERR") throw helperError(fields[1]);
    if (fields.length !== 3 || fields[0] !== "OK") {
      throw malformedHelperOutput();
    }
    return { dev: decimalToken(fields[1]), ino: decimalToken(fields[2]) };
  }

  async list(
    rootPath: string,
    identity: FileBrowserRootIdentity,
    canonicalRelativePath: string,
    options: {
      pageSize: number;
      startIndex: number;
      showHidden: boolean;
      signal?: AbortSignal;
    },
  ): Promise<FileBrowserNativeListResult> {
    const output = await this.runBound(
      rootPath,
      identity,
      [
        "list",
        identity.dev,
        identity.ino,
        encodeText(canonicalRelativePath),
        String(options.pageSize),
        String(options.startIndex),
        options.showHidden ? "1" : "0",
        String(this.maxDirectoryEntries),
        String(this.maxDirectoryNameBytes),
      ],
      "",
      options.signal,
    );
    const lines = output.trimEnd().split("\n");
    const header = lines.shift()?.split("\t") ?? [];
    if (header[0] === "ERR") throw helperError(header[1]);
    if (header.length !== 13 || header[0] !== "OK") {
      throw malformedHelperOutput();
    }
    const directory = parseStats(header, 1);
    if (directory.kind !== "directory") {
      throw new FileBrowserBackendError(
        "not_directory",
        "The requested path is not a directory",
      );
    }
    const revision = boundedToken(header[10], 128);
    const totalEntries = parseBoundedInteger(
      header[11],
      0,
      this.maxDirectoryEntries,
    );
    const nextIndex = header[12] === "-"
      ? undefined
      : parseBoundedInteger(header[12], 0, totalEntries);
    const names = lines.map((line) => {
      const fields = line.split("\t");
      if (fields.length !== 2 || fields[0] !== "N") {
        throw malformedHelperOutput();
      }
      return decodeText(fields[1]);
    });
    if (names.length > options.pageSize) throw malformedHelperOutput();
    return {
      directory,
      revision,
      totalEntries,
      ...(nextIndex === undefined ? {} : { nextIndex }),
      names,
    };
  }

  async stat(
    rootPath: string,
    identity: FileBrowserRootIdentity,
    specs: readonly FileBrowserNativeStatSpec[],
    signal?: AbortSignal,
  ): Promise<FileBrowserNativeStatResult[]> {
    if (specs.length < 1 || specs.length > 200) {
      throw new FileBrowserBackendError(
        "too_many_items",
        "The native stat batch is outside its bounded range",
      );
    }
    const input = specs
      .map((spec, index) =>
        [
          String(index),
          encodeText(spec.sourceParent),
          spec.sourceName === undefined ? "-" : encodeText(spec.sourceName),
          spec.targetCanonical === undefined
            ? "-"
            : encodeText(spec.targetCanonical),
          spec.sourceParentIdentity?.dev ?? "-",
          spec.sourceParentIdentity?.ino ?? "-",
        ].join("\t"),
      )
      .join("\n") + "\n";
    const output = await this.runBound(
      rootPath,
      identity,
      ["stat", identity.dev, identity.ino, String(specs.length)],
      input,
      signal,
    );
    const lines = output.trimEnd().split("\n");
    if (lines.length === 1 && lines[0].startsWith("ERR\t")) {
      const fields = lines[0].split("\t");
      throw helperError(fields[1]);
    }
    if (lines.length !== specs.length) throw malformedHelperOutput();
    const results: Array<FileBrowserNativeStatResult | undefined> =
      Array(specs.length);
    for (const line of lines) {
      const fields = line.split("\t");
      if (fields[0] !== "S" && fields[0] !== "E") {
        throw malformedHelperOutput();
      }
      const index = parseBoundedInteger(fields[1], 0, specs.length - 1);
      if (results[index] !== undefined) throw malformedHelperOutput();
      if (fields[0] === "E") {
        if (fields.length !== 3) throw malformedHelperOutput();
        results[index] = {
          success: false,
          errorCode: boundedToken(fields[2], 128),
        };
        continue;
      }
      if (fields.length !== 12 && fields.length !== 21) {
        throw malformedHelperOutput();
      }
      const source = parseStats(fields, 2);
      const markerIndex = 11;
      if (fields[markerIndex] === "-") {
        if (fields.length !== 12) throw malformedHelperOutput();
        results[index] = { success: true, source };
      } else {
        if (fields[markerIndex] !== "T" || fields.length !== 21) {
          throw malformedHelperOutput();
        }
        results[index] = {
          success: true,
          source,
          target: parseStats(fields, 12),
        };
      }
    }
    if (results.some((result) => result === undefined)) {
      throw malformedHelperOutput();
    }
    return results as FileBrowserNativeStatResult[];
  }

  private async runUnbound(args: string[]): Promise<string> {
    return this.runProcess(args, "", undefined, undefined);
  }

  private async runBound(
    rootPath: string,
    identity: FileBrowserRootIdentity,
    args: string[],
    input: string,
    signal?: AbortSignal,
  ): Promise<string> {
    await this.init();
    const handle = await this.openRoot(rootPath);
    try {
      const stats = await handle.stat({ bigint: true });
      if (
        !stats.isDirectory() ||
        stats.dev.toString() !== identity.dev ||
        stats.ino.toString() !== identity.ino
      ) {
        throw new FileBrowserBackendError(
          "root_changed",
          "The configured file browser root changed",
        );
      }
      return await this.runProcess(args, input, handle, signal);
    } finally {
      await handle.close().catch(() => undefined);
    }
  }

  private openRoot(path: string): Promise<FileHandle> {
    return open(
      path,
      fsConstants.O_RDONLY |
        fsConstants.O_DIRECTORY |
        fsConstants.O_NOFOLLOW,
    ).catch(() => {
      throw new FileBrowserBackendError(
        "root_changed",
        "The configured file browser root is unavailable",
      );
    });
  }

  private runProcess(
    args: string[],
    input: string,
    rootHandle?: FileHandle,
    signal?: AbortSignal,
  ): Promise<string> {
    if (signal?.aborted) return Promise.reject(cancelledError());
    return new Promise<string>((resolve, reject) => {
      const child = spawn(this.helperPath, args, {
        stdio: [
          "pipe",
          "pipe",
          "pipe",
          rootHandle === undefined ? "ignore" : rootHandle.fd,
        ],
      });
      const stdout: Buffer[] = [];
      let stdoutBytes = 0;
      let stderrBytes = 0;
      let settled = false;
      const finish = (error?: Error, value?: string): void => {
        if (settled) return;
        settled = true;
        clearTimeout(timeout);
        signal?.removeEventListener("abort", abort);
        if (error) reject(error);
        else resolve(value ?? "");
      };
      const abort = (): void => {
        child.kill("SIGKILL");
        finish(cancelledError());
      };
      const timeout = setTimeout(() => {
        child.kill("SIGKILL");
        finish(
          new FileBrowserBackendError(
            "helper_timeout",
            "Secure file browser helper timed out",
          ),
        );
      }, this.timeoutMs);
      timeout.unref();
      signal?.addEventListener("abort", abort, { once: true });
      child.once("error", () => {
        finish(
          new FileBrowserBackendError(
            "helper_unavailable",
            "Secure file browser helper could not be started",
          ),
        );
      });
      child.stdout!.on("data", (chunk: Buffer) => {
        stdoutBytes += chunk.length;
        if (stdoutBytes > HELPER_MAX_OUTPUT_BYTES) {
          child.kill("SIGKILL");
          finish(
            new FileBrowserBackendError(
              "helper_output_too_large",
              "Secure file browser helper output exceeded its bound",
            ),
          );
          return;
        }
        stdout.push(chunk);
      });
      child.stderr!.on("data", (chunk: Buffer) => {
        stderrBytes += chunk.length;
        if (stderrBytes > HELPER_MAX_OUTPUT_BYTES) child.kill("SIGKILL");
      });
      child.once("close", (code, terminationSignal) => {
        if (settled) return;
        const value = Buffer.concat(stdout).toString("utf8");
        if (code !== 0) {
          const first = value.trim().split("\n", 1)[0]?.split("\t") ?? [];
          finish(
            first[0] === "ERR"
              ? helperError(first[1])
              : new FileBrowserBackendError(
                  terminationSignal ? "helper_cancelled" : "helper_failed",
                  "Secure file browser helper failed",
                ),
          );
          return;
        }
        finish(undefined, value);
      });
      child.stdin!.on("error", () => undefined);
      child.stdin!.end(input);
    });
  }
}

function defaultHelperPath(): string {
  const moduleDirectory = dirname(fileURLToPath(import.meta.url));
  const outputDirectory = moduleDirectory.endsWith(`${sep}dist`)
    ? moduleDirectory
    : join(moduleDirectory, "..", "dist");
  return join(outputDirectory, FILE_BROWSER_POSIX_HELPER_NAME);
}

function parseStats(
  fields: readonly string[],
  offset: number,
): FileBrowserNativeStats {
  const kind = parseKind(fields[offset]);
  const dev = decimalToken(fields[offset + 1]);
  const ino = decimalToken(fields[offset + 2]);
  const mode = parseBoundedInteger(fields[offset + 3], 0, 0xffffffff);
  const size = parseBoundedInteger(
    fields[offset + 4],
    0,
    Number.MAX_SAFE_INTEGER,
  );
  const mtimeMs = parseTime(fields[offset + 5], fields[offset + 6]);
  const ctimeMs = parseTime(fields[offset + 7], fields[offset + 8]);
  return { kind, dev, ino, mode, size, mtimeMs, ctimeMs };
}

function parseKind(value: string | undefined): FileBrowserNodeKind {
  switch (value) {
    case "f":
      return "file";
    case "d":
      return "directory";
    case "l":
      return "symlink";
    case "o":
      return "other";
    default:
      throw malformedHelperOutput();
  }
}

function parseTime(seconds: string | undefined, nanos: string | undefined): number {
  const secondsToken = signedDecimalToken(seconds);
  const nanosValue = parseBoundedInteger(nanos, 0, 999_999_999);
  const milliseconds = Number(BigInt(secondsToken) * 1000n) + nanosValue / 1e6;
  if (!Number.isFinite(milliseconds)) throw malformedHelperOutput();
  return milliseconds;
}

function encodeText(value: string): string {
  const bytes = Buffer.from(value, "utf8");
  if (bytes.length > HELPER_MAX_TEXT_BYTES) {
    throw new FileBrowserBackendError(
      "invalid_relative_path",
      "The file browser path exceeds the native byte limit",
    );
  }
  return bytes.length === 0 ? "~" : bytes.toString("hex");
}

function decodeText(value: string | undefined): string {
  if (value === "~") return "";
  if (!value || value.length % 2 !== 0 || !/^[0-9a-f]+$/u.test(value)) {
    throw malformedHelperOutput();
  }
  const bytes = Buffer.from(value, "hex");
  if (bytes.length > HELPER_MAX_TEXT_BYTES) throw malformedHelperOutput();
  const decoded = bytes.toString("utf8");
  if (!Buffer.from(decoded, "utf8").equals(bytes)) throw malformedHelperOutput();
  return decoded;
}

function parseBoundedInteger(
  value: string | undefined,
  minimum: number,
  maximum: number,
): number {
  if (!value || !/^[0-9]+$/u.test(value)) throw malformedHelperOutput();
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < minimum || parsed > maximum) {
    throw malformedHelperOutput();
  }
  return parsed;
}

function boundedToken(value: string | undefined, maximum: number): string {
  if (!value || value.length > maximum || !/^[A-Za-z0-9_-]+$/u.test(value)) {
    throw malformedHelperOutput();
  }
  return value;
}

function decimalToken(value: string | undefined): string {
  if (!value || value.length > 32 || !/^[0-9]+$/u.test(value)) {
    throw malformedHelperOutput();
  }
  return value;
}

function signedDecimalToken(value: string | undefined): string {
  if (!value || value.length > 32 || !/^-?[0-9]+$/u.test(value)) {
    throw malformedHelperOutput();
  }
  return value;
}

function boundedPositiveInteger(
  value: number | undefined,
  maximum: number,
): number {
  const resolved = value ?? maximum;
  if (!Number.isSafeInteger(resolved) || resolved < 1 || resolved > maximum) {
    throw new Error(`Value must be between 1 and ${maximum}`);
  }
  return resolved;
}

function helperError(code: string | undefined): FileBrowserBackendError {
  const normalized = boundedToken(code, 128);
  return new FileBrowserBackendError(
    normalized,
    helperErrorMessage(normalized),
  );
}

function helperErrorMessage(code: string): string {
  switch (code) {
    case "not_found":
      return "The file no longer exists";
    case "permission_denied":
      return "The file cannot be read by the Bridge";
    case "invalid_symlink":
      return "The symbolic link changed or cannot be followed safely";
    case "directory_changed":
      return "The directory changed while it was being read";
    case "directory_too_large":
      return "The directory exceeds the secure browser limit";
    case "root_changed":
      return "The configured file browser root changed";
    default:
      return "The secure file browser operation failed";
  }
}

function malformedHelperOutput(): FileBrowserBackendError {
  return new FileBrowserBackendError(
    "helper_protocol_error",
    "Secure file browser helper returned an invalid response",
  );
}

function cancelledError(): FileBrowserBackendError {
  return new FileBrowserBackendError(
    "control_cancelled",
    "The file browser request was cancelled",
  );
}
