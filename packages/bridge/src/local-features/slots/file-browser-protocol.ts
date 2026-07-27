import {
  hasOnlyLocalFeatureKeys,
  validLocalFeatureId,
  type LocalFeatureProtocolContribution,
} from "../protocol-slot.js";
import {
  validateFileMutationOperation,
  type FileMutationOperation,
} from "../../file-mutation-auth.js";

export const FILE_BROWSER_CAPABILITY = "file_browser_v1";
export const FILE_BROWSER_PROJECT_PREVIEW_CAPABILITY =
  "file_browser_project_preview_v1";

export const FILE_BROWSER_DEFAULT_PAGE_SIZE = 100;
export const FILE_BROWSER_MAX_PAGE_SIZE = 200;
export const FILE_BROWSER_MAX_STAT_ITEMS = 32;
export const FILE_BROWSER_MAX_ROOTS = 32;
export const FILE_BROWSER_MAX_RELATIVE_PATH_LENGTH = 4096;

const MAX_REQUEST_ID_LENGTH = 128;
const MAX_ROOT_ID_LENGTH = 128;
const MAX_PROJECT_PATH_LENGTH = 4096;
const MAX_CURSOR_LENGTH = 2048;
const MAX_NODE_REVISION_LENGTH = 256;
const MAX_DEVICE_ID_LENGTH = 128;
const MAX_PUBLIC_KEY_LENGTH = 256;
const MAX_PASSWORD_LENGTH = 256;

export type FileBrowserNodeKind =
  | "file"
  | "directory"
  | "symlink"
  | "other";

export interface FileBrowserRoot {
  rootId: string;
  label: string;
  displayPath: string;
}

export interface FileBrowserEntry {
  name: string;
  relativePath: string;
  kind: FileBrowserNodeKind;
  targetKind?: FileBrowserNodeKind;
  isSymlink: boolean;
  sizeBytes?: number;
  /** UTC ISO-8601 timestamp. */
  modifiedAt?: string;
  mimeType?: string;
  /** Forward-compatible preview renderer identifier. */
  previewKind?: string;
  canOpen: boolean;
  canPreview: boolean;
  canDownload: boolean;
  nodeRevision: string;
}

/** Stat results use the same node metadata as directory entries. */
export type FileBrowserNode = FileBrowserEntry;

export interface FileBrowserStatRequestItem {
  rootId: string;
  relativePath: string;
}

export interface FileBrowserStatResultItem {
  rootId: string;
  relativePath: string;
  exists: boolean;
  node?: FileBrowserEntry;
  errorCode?: string;
}

export interface FileBrowserRootsRequest {
  type: "file_browser_roots_v1";
  requestId: string;
}

export interface FileBrowserListRequest {
  type: "file_browser_list_v1";
  requestId: string;
  rootId: string;
  /** Empty string identifies the selected root. */
  relativePath: string;
  /** Omitted values are normalized to 100 by the Bridge parser. */
  pageSize?: number;
  cursor?: string;
  showHidden?: boolean;
}

export interface FileBrowserStatRequest {
  type: "file_browser_stat_v1";
  requestId: string;
  items: FileBrowserStatRequestItem[];
}

export interface FileBrowserPreviewRequest {
  type: "file_browser_preview_v1";
  requestId: string;
  rootId: string;
  relativePath: string;
  nodeRevision?: string;
}

export interface FileBrowserProjectPreviewRequest {
  type: "file_browser_project_preview_v1";
  requestId: string;
  /** Existing project/worktree root on the Bridge host. */
  projectPath: string;
  /** Canonical slash-separated path relative to projectPath. */
  filePath: string;
}

export interface FileBrowserDownloadRequest {
  type: "file_browser_download_v1";
  requestId: string;
  rootId: string;
  relativePath: string;
  nodeRevision?: string;
}

export interface FileMutationAuthStateRequest {
  type: "file_mutation_auth_state_v1";
  requestId: string;
  deviceId?: string;
}

export interface FileMutationAuthChallengeRequest {
  type: "file_mutation_auth_challenge_v1";
  requestId: string;
  deviceId: string;
  operation: FileMutationOperation;
}

export interface FileMutationAuthEnrollRequest {
  type: "file_mutation_auth_enroll_v1";
  requestId: string;
  deviceId: string;
  publicKey: string;
  password: string;
}

export type FileBrowserClientMessage =
  | FileBrowserRootsRequest
  | FileBrowserListRequest
  | FileBrowserStatRequest
  | FileBrowserPreviewRequest
  | FileBrowserProjectPreviewRequest
  | FileBrowserDownloadRequest
  | FileMutationAuthStateRequest
  | FileMutationAuthChallengeRequest
  | FileMutationAuthEnrollRequest;

type FileBrowserResultType =
  | "file_browser_roots_result_v1"
  | "file_browser_list_result_v1"
  | "file_browser_stat_result_v1"
  | "file_browser_preview_result_v1"
  | "file_browser_download_result_v1"
  | "file_mutation_auth_result_v1";

export type FileBrowserFailureResult<Type extends FileBrowserResultType> = {
  type: Type;
  requestId: string;
  success: false;
  errorCode?: string;
  error?: string;
};

export interface FileBrowserRootsSuccessResult {
  type: "file_browser_roots_result_v1";
  requestId: string;
  success: true;
  bridgeInstanceId: string;
  rootSetRevision: string;
  roots: FileBrowserRoot[];
  previewMaxBytes: number;
  downloadMaxBytes: number;
  downloadAvailable: boolean;
}

export type FileBrowserRootsResult =
  | FileBrowserRootsSuccessResult
  | FileBrowserFailureResult<"file_browser_roots_result_v1">;

export interface FileBrowserListSuccessResult {
  type: "file_browser_list_result_v1";
  requestId: string;
  success: true;
  rootId: string;
  relativePath: string;
  directoryRevision: string;
  entries: FileBrowserEntry[];
  nextCursor?: string;
}

export type FileBrowserListResult =
  | FileBrowserListSuccessResult
  | FileBrowserFailureResult<"file_browser_list_result_v1">;

export interface FileBrowserStatSuccessResult {
  type: "file_browser_stat_result_v1";
  requestId: string;
  success: true;
  items: FileBrowserStatResultItem[];
}

export type FileBrowserStatResult =
  | FileBrowserStatSuccessResult
  | FileBrowserFailureResult<"file_browser_stat_result_v1">;

export interface FileBrowserPreviewSuccessResult {
  type: "file_browser_preview_result_v1";
  requestId: string;
  success: true;
  rootId: string;
  relativePath: string;
  relativeUrl: string;
  filename: string;
  mimeType: string;
  sizeBytes: number;
  previewKind: string;
  /** UTC ISO-8601 timestamp. */
  expiresAt: string;
}

export type FileBrowserPreviewResult =
  | FileBrowserPreviewSuccessResult
  | FileBrowserFailureResult<"file_browser_preview_result_v1">;

export interface FileBrowserDownloadSuccessResult {
  type: "file_browser_download_result_v1";
  requestId: string;
  success: true;
  rootId: string;
  relativePath: string;
  transferId: string;
  status: "queued";
}

export type FileBrowserDownloadResult =
  | FileBrowserDownloadSuccessResult
  | FileBrowserFailureResult<"file_browser_download_result_v1">;

export type FileMutationAuthResult =
  | {
      type: "file_mutation_auth_result_v1";
      requestId: string;
      success: true;
      event: "state" | "enrolled";
      passwordConfigured: boolean;
      biometricEnrolled: boolean;
    }
  | {
      type: "file_mutation_auth_result_v1";
      requestId: string;
      success: true;
      event: "challenge";
      challengeId: string;
      payload: string;
      expiresAt: string;
    }
  | FileBrowserFailureResult<"file_mutation_auth_result_v1">;

export type FileBrowserServerMessage =
  | FileBrowserRootsResult
  | FileBrowserListResult
  | FileBrowserStatResult
  | FileBrowserPreviewResult
  | FileBrowserDownloadResult
  | FileMutationAuthResult;

const CLIENT_TYPES = [
  "file_browser_roots_v1",
  "file_browser_list_v1",
  "file_browser_stat_v1",
  "file_browser_preview_v1",
  "file_browser_project_preview_v1",
  "file_browser_download_v1",
  "file_mutation_auth_state_v1",
  "file_mutation_auth_challenge_v1",
  "file_mutation_auth_enroll_v1",
] as const;

const SERVER_TYPES = [
  "file_browser_roots_result_v1",
  "file_browser_list_result_v1",
  "file_browser_stat_result_v1",
  "file_browser_preview_result_v1",
  "file_browser_download_result_v1",
  "file_mutation_auth_result_v1",
] as const;

/**
 * Accept one canonical, root-relative wire representation on every platform.
 * The empty string identifies a root; every non-empty path uses `/` separators.
 */
export function validFileBrowserRelativePath(value: unknown): value is string {
  if (
    typeof value !== "string" ||
    value.length > FILE_BROWSER_MAX_RELATIVE_PATH_LENGTH ||
    value.includes("\0") ||
    value.includes("\\") ||
    value.startsWith("/") ||
    /^[A-Za-z]:/u.test(value)
  ) {
    return false;
  }
  if (value.length === 0) return true;

  return value.split("/").every(
    (segment) =>
      segment.length > 0 && segment !== "." && segment !== "..",
  );
}

export const fileBrowserProtocolContribution: LocalFeatureProtocolContribution<
  FileBrowserClientMessage,
  FileBrowserServerMessage
> = {
  clientTypes: CLIENT_TYPES,
  serverTypes: SERVER_TYPES,
  parseClient(message) {
    if (
      typeof message.type !== "string" ||
      !CLIENT_TYPES.includes(message.type as (typeof CLIENT_TYPES)[number])
    ) {
      return undefined;
    }

    if (!correlatedId(message.requestId, MAX_REQUEST_ID_LENGTH)) {
      return null;
    }
    const requestId = message.requestId;

    switch (message.type) {
      case "file_browser_roots_v1":
        return hasOnlyLocalFeatureKeys(message, ["type", "requestId"])
          ? { type: message.type, requestId }
          : null;
      case "file_browser_list_v1": {
        const pageSize =
          message.pageSize === undefined
            ? FILE_BROWSER_DEFAULT_PAGE_SIZE
            : message.pageSize;
        if (
          !hasOnlyLocalFeatureKeys(message, [
            "type",
            "requestId",
            "rootId",
            "relativePath",
            "pageSize",
            "cursor",
            "showHidden",
          ]) ||
          !correlatedId(message.rootId, MAX_ROOT_ID_LENGTH) ||
          !validFileBrowserRelativePath(message.relativePath) ||
          !Number.isInteger(pageSize) ||
          Number(pageSize) < 1 ||
          Number(pageSize) > FILE_BROWSER_MAX_PAGE_SIZE ||
          (message.cursor !== undefined &&
            !correlatedId(message.cursor, MAX_CURSOR_LENGTH)) ||
          (message.showHidden !== undefined &&
            typeof message.showHidden !== "boolean")
        ) {
          return null;
        }
        return {
          type: message.type,
          requestId,
          rootId: message.rootId,
          relativePath: message.relativePath,
          pageSize: Number(pageSize),
          ...(typeof message.cursor === "string"
            ? { cursor: message.cursor }
            : {}),
          ...(typeof message.showHidden === "boolean"
            ? { showHidden: message.showHidden }
            : {}),
        };
      }
      case "file_browser_stat_v1": {
        if (
          !hasOnlyLocalFeatureKeys(message, ["type", "requestId", "items"]) ||
          !Array.isArray(message.items) ||
          message.items.length < 1 ||
          message.items.length > FILE_BROWSER_MAX_STAT_ITEMS
        ) {
          return null;
        }
        const items: FileBrowserStatRequestItem[] = [];
        for (const value of message.items) {
          if (!value || typeof value !== "object" || Array.isArray(value)) {
            return null;
          }
          const item = value as Record<string, unknown>;
          if (
            !hasOnlyLocalFeatureKeys(item, ["rootId", "relativePath"]) ||
            !correlatedId(item.rootId, MAX_ROOT_ID_LENGTH) ||
            !validFileBrowserRelativePath(item.relativePath)
          ) {
            return null;
          }
          items.push({
            rootId: item.rootId,
            relativePath: item.relativePath,
          });
        }
        return { type: message.type, requestId, items };
      }
      case "file_browser_preview_v1":
      case "file_browser_download_v1":
        if (
          !hasOnlyLocalFeatureKeys(message, [
            "type",
            "requestId",
            "rootId",
            "relativePath",
            "nodeRevision",
          ]) ||
          !correlatedId(message.rootId, MAX_ROOT_ID_LENGTH) ||
          !validFileBrowserRelativePath(message.relativePath) ||
          (message.nodeRevision !== undefined &&
            !correlatedId(message.nodeRevision, MAX_NODE_REVISION_LENGTH))
        ) {
          return null;
        }
        return {
          type: message.type,
          requestId,
          rootId: message.rootId,
          relativePath: message.relativePath,
          ...(typeof message.nodeRevision === "string"
            ? { nodeRevision: message.nodeRevision }
            : {}),
        };
      case "file_browser_project_preview_v1":
        if (
          !hasOnlyLocalFeatureKeys(message, [
            "type",
            "requestId",
            "projectPath",
            "filePath",
          ]) ||
          typeof message.projectPath !== "string" ||
          message.projectPath.length === 0 ||
          message.projectPath.length > MAX_PROJECT_PATH_LENGTH ||
          message.projectPath.includes("\0") ||
          !validFileBrowserRelativePath(message.filePath) ||
          message.filePath.length === 0
        ) {
          return null;
        }
        return {
          type: message.type,
          requestId,
          projectPath: message.projectPath,
          filePath: message.filePath,
        };
      case "file_mutation_auth_state_v1":
        if (
          !hasOnlyLocalFeatureKeys(message, [
            "type",
            "requestId",
            "deviceId",
          ]) ||
          (message.deviceId !== undefined &&
            !correlatedId(message.deviceId, MAX_DEVICE_ID_LENGTH))
        ) {
          return null;
        }
        return {
          type: message.type,
          requestId,
          ...(typeof message.deviceId === "string"
            ? { deviceId: message.deviceId }
            : {}),
        };
      case "file_mutation_auth_challenge_v1":
        if (
          !hasOnlyLocalFeatureKeys(message, [
            "type",
            "requestId",
            "deviceId",
            "operation",
          ]) ||
          !correlatedId(message.deviceId, MAX_DEVICE_ID_LENGTH) ||
          !validateFileMutationOperation(message.operation)
        ) {
          return null;
        }
        return {
          type: message.type,
          requestId,
          deviceId: message.deviceId,
          operation: message.operation,
        };
      case "file_mutation_auth_enroll_v1":
        if (
          !hasOnlyLocalFeatureKeys(message, [
            "type",
            "requestId",
            "deviceId",
            "publicKey",
            "password",
          ]) ||
          !correlatedId(message.deviceId, MAX_DEVICE_ID_LENGTH) ||
          !correlatedId(message.publicKey, MAX_PUBLIC_KEY_LENGTH) ||
          typeof message.password !== "string" ||
          message.password.length < 8 ||
          message.password.length > MAX_PASSWORD_LENGTH
        ) {
          return null;
        }
        return {
          type: message.type,
          requestId,
          deviceId: message.deviceId,
          publicKey: message.publicKey,
          password: message.password,
        };
    }
  },
};

function correlatedId(value: unknown, maxLength: number): value is string {
  return validLocalFeatureId(value, maxLength) && value.trim().length > 0;
}
