import type { FileTransferManager } from "./file-transfer-manager.js";
import { FileTransferDownloadStore } from "./file-transfer-download-store.js";
import { FileTransferHttpHandler } from "./file-transfer-http.js";
import { FileTransferManager as Manager } from "./file-transfer-manager.js";
import {
  FileTransferStateStore,
  fileTransferStateFile,
} from "./file-transfer-state-store.js";
import { FileTransferUploadStore } from "./file-transfer-upload-store.js";
import type { FileMutationAuthorizer } from "./file-mutation-auth.js";
import type { DiagnosticReportArchiver } from "./file-transfer-diagnostic.js";

export interface FileTransferRuntime {
  manager: FileTransferManager;
  http: FileTransferHttpHandler;
  stateFilePath: string;
}

export interface FileTransferRuntimeOptions {
  port: number;
  bridgeInstanceId?: string;
  allowedDirs: string[];
  baseUrl?: string;
  stateFilePath?: string;
  downloadDirectory?: string;
  partialDirectory?: string;
  fileMutationAuthorizer?: FileMutationAuthorizer;
  warn?: (message: string) => void;
  diagnosticReportArchiver?: DiagnosticReportArchiver;
}

/**
 * Initializes the optional transfer module without ever making Bridge chat
 * startup depend on its lock, state, or directory health.
 */
export async function initializeFileTransferRuntime(
  options: FileTransferRuntimeOptions,
): Promise<FileTransferRuntime | undefined> {
  const stateFilePath = fileTransferStateFile(
    options.port,
    options.stateFilePath,
    options.bridgeInstanceId,
  );
  let manager: FileTransferManager | undefined;
  try {
    const stateStore = new FileTransferStateStore({
      filePath: stateFilePath,
      lockOwnerId: options.bridgeInstanceId,
      warn: options.warn,
    });
    const downloadStore = new FileTransferDownloadStore({
      stateStore,
      // This is the existing Bridge path authority, including an explicit
      // empty list when the Bridge itself is intentionally unrestricted.
      allowedDirs: options.allowedDirs,
    });
    const uploadStore = new FileTransferUploadStore({
      stateStore,
      ...(options.downloadDirectory
        ? { directory: options.downloadDirectory }
        : {}),
      ...(options.partialDirectory
        ? { partialDirectory: options.partialDirectory }
        : {}),
    });
    manager = new Manager({
      downloadStore,
      uploadStore,
      baseUrl: options.baseUrl,
      fileMutationAuthorizer: options.fileMutationAuthorizer,
      diagnosticReportArchiver: options.diagnosticReportArchiver,
    });
    await manager.init();
    return {
      manager,
      http: new FileTransferHttpHandler(manager),
      stateFilePath,
    };
  } catch (error) {
    await manager?.close().catch(() => undefined);
    const detail = error instanceof Error ? error.message : String(error);
    options.warn?.(
      `Phone file transfer disabled; chat remains available: ${detail}`,
    );
    if (/lock|owner|Bridge process/i.test(detail)) {
      options.warn?.(
        `File transfer lock for diagnosis: ${stateFilePath}.lock`,
      );
      options.warn?.(
        `Recovery: run "ccpocket-bridge file-transfer status --port ${options.port}"; only when it reports a dead verified owner, run "ccpocket-bridge file-transfer unlock --port ${options.port}". Missing owner metadata requires manual review and is never auto-removed.`,
      );
    }
    return undefined;
  }
}
