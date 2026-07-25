import { describe, expect, it } from "vitest";
import {
  FILE_BROWSER_CAPABILITY,
  FILE_BROWSER_DEFAULT_PAGE_SIZE,
  FILE_BROWSER_MAX_PAGE_SIZE,
  FILE_BROWSER_MAX_RELATIVE_PATH_LENGTH,
  FILE_BROWSER_MAX_STAT_ITEMS,
  isLocalFeatureServerMessageType,
  parseLocalFeatureClientMessage,
  validFileBrowserRelativePath,
} from "./protocol.js";

describe("file browser protocol slot", () => {
  it("strictly parses the roots request", () => {
    expect(
      parseLocalFeatureClientMessage({
        type: "file_browser_roots_v1",
        requestId: "roots-1",
      }),
    ).toEqual({ type: "file_browser_roots_v1", requestId: "roots-1" });

    expect(
      parseLocalFeatureClientMessage({
        type: "file_browser_roots_v1",
        requestId: "roots-1",
        rootId: "forged",
      }),
    ).toBeNull();
    expect(
      parseLocalFeatureClientMessage({
        type: "file_browser_roots_v1",
        requestId: " ",
      }),
    ).toBeNull();
  });

  it("normalizes list pagination and preserves explicit options", () => {
    expect(
      parseLocalFeatureClientMessage({
        type: "file_browser_list_v1",
        requestId: "list-1",
        rootId: "home",
        relativePath: "",
      }),
    ).toEqual({
      type: "file_browser_list_v1",
      requestId: "list-1",
      rootId: "home",
      relativePath: "",
      pageSize: FILE_BROWSER_DEFAULT_PAGE_SIZE,
    });

    expect(
      parseLocalFeatureClientMessage({
        type: "file_browser_list_v1",
        requestId: "list-2",
        rootId: "home",
        relativePath: "Developer/ccpocket",
        pageSize: FILE_BROWSER_MAX_PAGE_SIZE,
        cursor: "opaque-page-2",
        showHidden: true,
      }),
    ).toEqual({
      type: "file_browser_list_v1",
      requestId: "list-2",
      rootId: "home",
      relativePath: "Developer/ccpocket",
      pageSize: FILE_BROWSER_MAX_PAGE_SIZE,
      cursor: "opaque-page-2",
      showHidden: true,
    });
  });

  it("rejects invalid list bounds, option types, and extra fields", () => {
    const request = (overrides: Record<string, unknown>) =>
      parseLocalFeatureClientMessage({
        type: "file_browser_list_v1",
        requestId: "list-1",
        rootId: "home",
        relativePath: "Documents",
        ...overrides,
      });

    expect(request({ pageSize: 0 })).toBeNull();
    expect(request({ pageSize: FILE_BROWSER_MAX_PAGE_SIZE + 1 })).toBeNull();
    expect(request({ pageSize: 1.5 })).toBeNull();
    expect(request({ pageSize: "100" })).toBeNull();
    expect(request({ showHidden: "yes" })).toBeNull();
    expect(request({ cursor: " " })).toBeNull();
    expect(request({ cursor: "x".repeat(2049) })).toBeNull();
    expect(request({ absolutePath: "/Users/test" })).toBeNull();
  });

  it("accepts only canonical root-relative slash paths", () => {
    for (const value of [
      "",
      "file.txt",
      "folder/file.txt",
      "..hidden/file",
    ]) {
      expect(validFileBrowserRelativePath(value), value).toBe(true);
    }

    for (const value of [
      "/absolute",
      "C:/absolute",
      "C:",
      "C:file.txt",
      "../escape",
      "folder/../escape",
      ".",
      "folder/./file",
      "folder\\file",
      "folder\0file",
      "folder//file",
      "folder/",
      "x".repeat(FILE_BROWSER_MAX_RELATIVE_PATH_LENGTH + 1),
    ]) {
      expect(validFileBrowserRelativePath(value), value).toBe(false);
    }
  });

  it("strictly parses a bounded stat batch", () => {
    const items = Array.from({ length: FILE_BROWSER_MAX_STAT_ITEMS }, (_, i) => ({
      rootId: "home",
      relativePath: `file-${i}.txt`,
    }));
    expect(
      parseLocalFeatureClientMessage({
        type: "file_browser_stat_v1",
        requestId: "stat-1",
        items,
      }),
    ).toEqual({
      type: "file_browser_stat_v1",
      requestId: "stat-1",
      items,
    });

    const request = (candidate: unknown) =>
      parseLocalFeatureClientMessage({
        type: "file_browser_stat_v1",
        requestId: "stat-2",
        items: candidate,
      });
    expect(request([])).toBeNull();
    expect(
      request([...items, { rootId: "home", relativePath: "overflow" }]),
    ).toBeNull();
    expect(request([{ rootId: "home", relativePath: "../escape" }])).toBeNull();
    expect(
      request([{ rootId: "home", relativePath: "file", forged: true }]),
    ).toBeNull();
    expect(request([{ rootId: " ", relativePath: "file" }])).toBeNull();
  });

  it("strictly parses preview and download requests with revision fences", () => {
    for (const type of [
      "file_browser_preview_v1",
      "file_browser_download_v1",
    ] as const) {
      expect(
        parseLocalFeatureClientMessage({
          type,
          requestId: `${type}-1`,
          rootId: "home",
          relativePath: "Downloads/report.pdf",
          nodeRevision: "node-revision-1",
        }),
      ).toEqual({
        type,
        requestId: `${type}-1`,
        rootId: "home",
        relativePath: "Downloads/report.pdf",
        nodeRevision: "node-revision-1",
      });

      expect(
        parseLocalFeatureClientMessage({
          type,
          requestId: `${type}-2`,
          rootId: "home",
          relativePath: "Downloads/report.pdf",
        }),
      ).toEqual({
        type,
        requestId: `${type}-2`,
        rootId: "home",
        relativePath: "Downloads/report.pdf",
      });

      expect(
        parseLocalFeatureClientMessage({
          type,
          requestId: `${type}-3`,
          rootId: "home",
          relativePath: "Downloads/report.pdf",
          nodeRevision: " ",
        }),
      ).toBeNull();
      expect(
        parseLocalFeatureClientMessage({
          type,
          requestId: `${type}-4`,
          rootId: "home",
          relativePath: "Downloads/report.pdf",
          nodeRevision: "node-revision-1",
          destination: "phone",
        }),
      ).toBeNull();
    }
  });

  it("strictly parses bounded mutation authorization requests", () => {
    const operation = {
      kind: "upload",
      transferId: "transfer_1234567890",
      filename: "report.json",
      sizeBytes: 42,
    };
    expect(
      parseLocalFeatureClientMessage({
        type: "file_mutation_auth_state_v1",
        requestId: "state-1",
        deviceId: "ios:test-device",
      }),
    ).toMatchObject({ type: "file_mutation_auth_state_v1" });
    expect(
      parseLocalFeatureClientMessage({
        type: "file_mutation_auth_challenge_v1",
        requestId: "challenge-1",
        deviceId: "ios:test-device",
        operation,
      }),
    ).toMatchObject({ operation });
    expect(
      parseLocalFeatureClientMessage({
        type: "file_mutation_auth_enroll_v1",
        requestId: "enroll-1",
        deviceId: "ios:test-device",
        publicKey: "a".repeat(88),
        password: ["correct", "bridge", "credential"].join("-"),
      }),
    ).toMatchObject({ type: "file_mutation_auth_enroll_v1" });

    expect(
      parseLocalFeatureClientMessage({
        type: "file_mutation_auth_challenge_v1",
        requestId: "challenge-2",
        deviceId: "ios:test-device",
        operation: { ...operation, absolutePath: "/tmp/report.json" },
      }),
    ).toBeNull();
    expect(
      parseLocalFeatureClientMessage({
        type: "file_mutation_auth_enroll_v1",
        requestId: "enroll-2",
        deviceId: "ios:test-device",
        publicKey: "a".repeat(88),
        password: "short",
      }),
    ).toBeNull();
  });

  it("registers the read-only and mutation-authorization result capabilities", () => {
    expect(FILE_BROWSER_CAPABILITY).toBe("file_browser_v1");
    for (const type of [
      "file_browser_roots_result_v1",
      "file_browser_list_result_v1",
      "file_browser_stat_result_v1",
      "file_browser_preview_result_v1",
      "file_browser_download_result_v1",
      "file_mutation_auth_result_v1",
    ]) {
      expect(isLocalFeatureServerMessageType(type), type).toBe(true);
    }
    expect(isLocalFeatureServerMessageType("file_browser_event_v1")).toBe(false);
    expect(isLocalFeatureServerMessageType(FILE_BROWSER_CAPABILITY)).toBe(false);
  });
});
