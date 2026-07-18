import { mkdtemp, rm, symlink, truncate, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  formatFileTransferLockInspection,
  inspectFileTransferForCli,
  resolveFileTransferStateForCli,
} from "./file-transfer-lock-command.js";
import { fileTransferStateFile } from "./file-transfer-state-store.js";

const roots: string[] = [];

afterEach(async () => {
  vi.unstubAllEnvs();
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

describe("file-transfer lock CLI", () => {
  it("resolves the same stable Bridge namespace used by runtime across ports", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-transfer-lock-cli-"));
    roots.push(root);
    const promptHistory = join(root, "prompt-history.json");
    await writeFile(promptHistory, JSON.stringify({
      version: 2,
      bridgeInstanceId: "stable-cli-bridge",
      revision: 0,
      entries: [],
    }));
    vi.stubEnv("BRIDGE_PROMPT_HISTORY_FILE", promptHistory);
    vi.stubEnv("BRIDGE_FILE_TRANSFER_STATE_FILE", "");
    await expect(resolveFileTransferStateForCli("8765")).resolves.toBe(
      fileTransferStateFile(8765, undefined, "stable-cli-bridge"),
    );
    await expect(resolveFileTransferStateForCli("9876")).resolves.toBe(
      fileTransferStateFile(9876, undefined, "stable-cli-bridge"),
    );
  });

  it("prints exact read-only lock paths and recovery eligibility", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-transfer-lock-cli-"));
    roots.push(root);
    const state = join(root, "state.json");
    vi.stubEnv("BRIDGE_FILE_TRANSFER_STATE_FILE", state);
    const inspection = await inspectFileTransferForCli("8765");
    expect(inspection).toMatchObject({ locked: false, recoverable: false });
    expect(formatFileTransferLockInspection(inspection)).toContain(`Lock: ${state}.lock`);
  });

  it("does not follow a prompt-history symlink when resolving Bridge identity", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-transfer-lock-cli-"));
    roots.push(root);
    const target = join(root, "prompt-history-target.json");
    const promptHistory = join(root, "prompt-history.json");
    await writeFile(target, JSON.stringify({
      version: 2,
      bridgeInstanceId: "must-not-be-trusted-through-a-symlink",
      revision: 0,
      entries: [],
    }));
    await symlink(target, promptHistory);
    vi.stubEnv("BRIDGE_PROMPT_HISTORY_FILE", promptHistory);
    vi.stubEnv("BRIDGE_FILE_TRANSFER_STATE_FILE", "");

    await expect(resolveFileTransferStateForCli("9876")).resolves.toBe(
      fileTransferStateFile(9876),
    );
  });

  it("bounds the prompt-history metadata read used for Bridge identity", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-transfer-lock-cli-"));
    roots.push(root);
    const promptHistory = join(root, "prompt-history.json");
    await writeFile(promptHistory, "");
    await truncate(promptHistory, 8 * 1024 * 1024 + 1);
    vi.stubEnv("BRIDGE_PROMPT_HISTORY_FILE", promptHistory);
    vi.stubEnv("BRIDGE_FILE_TRANSFER_STATE_FILE", "");

    await expect(resolveFileTransferStateForCli("9876")).resolves.toBe(
      fileTransferStateFile(9876),
    );
  });
});
