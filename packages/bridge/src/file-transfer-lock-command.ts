import { parseBridgePort } from "./bridge-port.js";
import {
  fileTransferStateFile,
  inspectFileTransferLock,
  unlockFileTransferLock,
  type FileTransferLockInspection,
} from "./file-transfer-state-store.js";
import { readBoundedNoFollowMetadata } from "./file-transfer-safe-metadata.js";
import { promptHistoryStoreFileForPort } from "./prompt-history-store.js";

const FILE_TRANSFER_CLI_PROMPT_HISTORY_MAX_BYTES = 8 * 1024 * 1024;

export async function resolveFileTransferStateForCli(
  rawPort?: string,
): Promise<string> {
  const port = parseBridgePort(rawPort);
  const explicit = process.env.BRIDGE_FILE_TRANSFER_STATE_FILE?.trim();
  if (explicit) return explicit;
  let bridgeInstanceId: string | undefined;
  try {
    const promptHistoryPath = promptHistoryStoreFileForPort(
      port,
      process.env.BRIDGE_PROMPT_HISTORY_FILE,
    );
    const raw = await readBoundedNoFollowMetadata(
      promptHistoryPath,
      FILE_TRANSFER_CLI_PROMPT_HISTORY_MAX_BYTES,
      "Bridge prompt history metadata",
    );
    const parsed = JSON.parse(raw) as {
      bridgeInstanceId?: unknown;
    };
    if (
      typeof parsed.bridgeInstanceId === "string" &&
      parsed.bridgeInstanceId.trim()
    ) bridgeInstanceId = parsed.bridgeInstanceId.trim();
  } catch {
    // Read-only fallback for installations predating a durable Bridge id.
  }
  return fileTransferStateFile(port, undefined, bridgeInstanceId);
}

export async function inspectFileTransferForCli(
  rawPort?: string,
): Promise<FileTransferLockInspection> {
  return inspectFileTransferLock(await resolveFileTransferStateForCli(rawPort));
}

export async function unlockFileTransferForCli(
  rawPort?: string,
): Promise<FileTransferLockInspection> {
  return unlockFileTransferLock(await resolveFileTransferStateForCli(rawPort));
}

export function formatFileTransferLockInspection(
  inspection: FileTransferLockInspection,
): string {
  const lines = [
    `State: ${inspection.stateFilePath}`,
    `Lock: ${inspection.lockPath}`,
    `Recovery claim: ${inspection.recoveryPath}`,
    `Status: ${inspection.locked ? "locked" : "unlocked"}`,
    `Recovery in progress: ${inspection.recoveryInProgress ? "yes" : "no"}`,
    `Reason: ${inspection.reason}`,
  ];
  if (inspection.owner) {
    lines.push(`Owner PID: ${inspection.owner.pid}`);
    lines.push(`Owner alive: ${inspection.ownerAlive ? "yes" : "no"}`);
    lines.push(`Owner started: ${inspection.owner.processStartedAt}`);
    if (inspection.owner.ownerId) lines.push(`Bridge owner id: ${inspection.owner.ownerId}`);
  }
  lines.push(`Safe automatic recovery: ${inspection.recoverable ? "yes" : "no"}`);
  return lines.join("\n");
}
