import {
  hasOnlyLocalFeatureKeys,
  validLocalFeatureId,
  validLocalFeatureText,
} from "./local-features/protocol-slot.js";
import {
  FILE_TRANSFER_ID_PATTERN,
  FILE_TRANSFER_MAX_FILE_SIZE_BYTES,
  FILE_TRANSFER_TOKEN_PATTERN,
} from "./file-transfer-constants.js";
export { FILE_TRANSFER_CAPABILITY } from "./file-transfer-constants.js";

export type FileTransferClientMessage =
  | {
      type: "file_transfer_upload_prepare_v2";
      requestId: string;
      transferId: string;
      resumeToken: string;
      filename: string;
      sizeBytes: number;
    }
  | {
      type: "file_transfer_receive_result_v2";
      transferId: string;
      success: boolean;
      savedFilename?: string;
      receivedBytes?: number;
      error?: string;
      errorCode?: string;
    }
  | {
      type: "file_transfer_cancel_v2";
      requestId: string;
      transferId: string;
      direction: "upload" | "download";
      resumeToken?: string;
      downloadToken?: string;
    }
  | {
      type: "file_transfer_download_resume_v2";
      requestId: string;
      transferId: string;
      downloadToken: string;
    };

export type FileTransferServerMessage =
  | {
      type: "file_transfer_offer_v2";
      transferId: string;
      filename: string;
      mimeType: string;
      sizeBytes: number;
      downloadUrl: string;
      downloadToken: string;
      etag: string;
      expiresAt: string;
    }
  | {
      type: "file_transfer_upload_ready_v2";
      requestId: string;
      transferId: string;
      uploadUrl: string;
      uploadToken: string;
      resumeToken: string;
      uploadOffset: number;
      sizeBytes: number;
      expiresAt: string;
      maxChunkSizeBytes: number;
    }
  | {
      type: "file_transfer_upload_result_v2";
      requestId: string;
      transferId: string;
      success: boolean;
      filename?: string;
      sizeBytes?: number;
      error?: string;
      errorCode?: string;
    }
  | {
      type: "file_transfer_upload_result_v3";
      requestId: string;
      transferId: string;
      success: boolean;
      filename?: string;
      sizeBytes?: number;
      savedPath?: string;
      error?: string;
      errorCode?: string;
    }
  | {
      type: "file_transfer_cancel_result_v2";
      requestId: string;
      transferId: string;
      direction: "upload" | "download";
      success: boolean;
      error?: string;
      errorCode?: string;
    }
  | {
      type: "file_transfer_download_resumed_v2";
      requestId: string;
      transferId: string;
      success: boolean;
      sizeBytes?: number;
      etag?: string;
      expiresAt?: string;
      error?: string;
      errorCode?: string;
    };

const CLIENT_TYPES = [
  "file_transfer_upload_prepare_v2",
  "file_transfer_receive_result_v2",
  "file_transfer_cancel_v2",
  "file_transfer_download_resume_v2",
] as const;
const SERVER_TYPES = new Set<string>([
  "file_transfer_offer_v2",
  "file_transfer_upload_ready_v2",
  "file_transfer_upload_result_v2",
  "file_transfer_upload_result_v3",
  "file_transfer_cancel_result_v2",
  "file_transfer_download_resumed_v2",
]);
const MAX_REQUEST_ID_LENGTH = 128;
const MAX_FILENAME_LENGTH = 1024;
const MAX_ERROR_LENGTH = 2048;
const MAX_ERROR_CODE_LENGTH = 128;

/** `undefined` means unrelated; `null` means a recognized invalid payload. */
export function parseFileTransferClientMessage(
  message: Record<string, unknown>,
): FileTransferClientMessage | null | undefined {
  if (message.type === "file_transfer_cancel_v2") {
    if (
      !hasOnlyLocalFeatureKeys(message, [
        "type",
        "requestId",
        "transferId",
        "direction",
        "resumeToken",
        "downloadToken",
      ]) ||
      !correlatedId(message.requestId, MAX_REQUEST_ID_LENGTH) ||
      typeof message.transferId !== "string" ||
      !FILE_TRANSFER_ID_PATTERN.test(message.transferId) ||
      (message.direction !== "upload" && message.direction !== "download")
    ) return null;
    if (
      message.direction === "upload" &&
      (typeof message.resumeToken !== "string" ||
        !FILE_TRANSFER_TOKEN_PATTERN.test(message.resumeToken) ||
        message.downloadToken !== undefined)
    ) return null;
    if (
      message.direction === "download" &&
      (message.resumeToken !== undefined ||
        (message.downloadToken !== undefined &&
          (typeof message.downloadToken !== "string" ||
            !FILE_TRANSFER_TOKEN_PATTERN.test(message.downloadToken))))
    ) return null;
    return {
      type: message.type,
      requestId: message.requestId,
      transferId: message.transferId,
      direction: message.direction,
      ...(typeof message.resumeToken === "string"
        ? { resumeToken: message.resumeToken }
        : {}),
      ...(typeof message.downloadToken === "string"
        ? { downloadToken: message.downloadToken }
        : {}),
    };
  }

  if (message.type === "file_transfer_download_resume_v2") {
    if (
      !hasOnlyLocalFeatureKeys(message, [
        "type",
        "requestId",
        "transferId",
        "downloadToken",
      ]) ||
      !correlatedId(message.requestId, MAX_REQUEST_ID_LENGTH) ||
      typeof message.transferId !== "string" ||
      !FILE_TRANSFER_ID_PATTERN.test(message.transferId) ||
      typeof message.downloadToken !== "string" ||
      !FILE_TRANSFER_TOKEN_PATTERN.test(message.downloadToken)
    ) return null;
    return {
      type: message.type,
      requestId: message.requestId,
      transferId: message.transferId,
      downloadToken: message.downloadToken,
    };
  }

  if (
    typeof message.type !== "string" ||
    !CLIENT_TYPES.includes(message.type as (typeof CLIENT_TYPES)[number])
  ) {
    return undefined;
  }

  if (message.type === "file_transfer_upload_prepare_v2") {
    if (
      !hasOnlyLocalFeatureKeys(message, [
        "type",
        "requestId",
        "transferId",
        "resumeToken",
        "filename",
        "sizeBytes",
      ]) ||
      !correlatedId(message.requestId, MAX_REQUEST_ID_LENGTH) ||
      typeof message.transferId !== "string" ||
      !FILE_TRANSFER_ID_PATTERN.test(message.transferId) ||
      typeof message.resumeToken !== "string" ||
      !FILE_TRANSFER_TOKEN_PATTERN.test(message.resumeToken) ||
      !validLocalFeatureText(message.filename, MAX_FILENAME_LENGTH, false) ||
      !Number.isSafeInteger(message.sizeBytes) ||
      Number(message.sizeBytes) < 0 ||
      Number(message.sizeBytes) > FILE_TRANSFER_MAX_FILE_SIZE_BYTES
    ) {
      return null;
    }
    return {
      type: message.type,
      requestId: message.requestId,
      transferId: message.transferId,
      resumeToken: message.resumeToken,
      filename: message.filename,
      sizeBytes: Number(message.sizeBytes),
    };
  }

  if (
    !hasOnlyLocalFeatureKeys(message, [
      "type",
      "transferId",
      "success",
      "savedFilename",
      "receivedBytes",
      "error",
      "errorCode",
    ]) ||
    typeof message.transferId !== "string" ||
    !FILE_TRANSFER_ID_PATTERN.test(message.transferId) ||
    typeof message.success !== "boolean" ||
    !optionalText(message.savedFilename, MAX_FILENAME_LENGTH) ||
    (message.receivedBytes !== undefined &&
      (!Number.isSafeInteger(message.receivedBytes) ||
        Number(message.receivedBytes) < 0 ||
        Number(message.receivedBytes) > FILE_TRANSFER_MAX_FILE_SIZE_BYTES)) ||
    !optionalText(message.error, MAX_ERROR_LENGTH) ||
    !optionalText(message.errorCode, MAX_ERROR_CODE_LENGTH)
  ) {
    return null;
  }
  return {
    type: "file_transfer_receive_result_v2",
    transferId: message.transferId,
    success: message.success,
    ...(typeof message.savedFilename === "string"
      ? { savedFilename: message.savedFilename }
      : {}),
    ...(typeof message.receivedBytes === "number"
      ? { receivedBytes: message.receivedBytes }
      : {}),
    ...(typeof message.error === "string" ? { error: message.error } : {}),
    ...(typeof message.errorCode === "string"
      ? { errorCode: message.errorCode }
      : {}),
  };
}

export function isFileTransferServerMessageType(type: string): boolean {
  return SERVER_TYPES.has(type);
}

export function isFileTransferClientMessage(
  message: { type: string },
): message is FileTransferClientMessage {
  return CLIENT_TYPES.includes(
    message.type as (typeof CLIENT_TYPES)[number],
  );
}

function correlatedId(value: unknown, maxLength: number): value is string {
  return validLocalFeatureId(value, maxLength) && value.trim().length > 0;
}

function optionalText(value: unknown, maxLength: number): boolean {
  return (
    value === undefined || validLocalFeatureText(value, maxLength, true)
  );
}
