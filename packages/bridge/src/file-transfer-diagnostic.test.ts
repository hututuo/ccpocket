import { createHash } from "node:crypto";
import { mkdtemp, readFile, stat, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  DIAGNOSTIC_REPORT_MAX_BYTES,
  DiagnosticReportArchiver,
  validateDiagnosticReportMetadata,
  type DiagnosticReportMetadata,
} from "./file-transfer-diagnostic.js";

const roots: string[] = [];

function metadata(bytes: Buffer, reportId = "report_20260812"): DiagnosticReportMetadata {
  return {
    schemaVersion: 1,
    reportId,
    provider: "codex",
    providerSessionId: "thread-123",
    codexSourceId: "source-123",
    capturedAtStart: "2026-08-12T00:00:00.000Z",
    capturedAtEnd: "2026-08-12T00:01:00.000Z",
    sha256: createHash("sha256").update(bytes).digest("hex"),
  };
}

afterEach(async () => {
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true, force: true })));
});

describe("diagnostic report archiver", () => {
  it("rejects unsafe report ids before any path is constructed", () => {
    expect(validateDiagnosticReportMetadata({
      schemaVersion: 1,
      reportId: "../escape",
      provider: "codex",
      providerSessionId: "thread",
      capturedAtStart: "2026-08-12T00:00:00.000Z",
      capturedAtEnd: "2026-08-12T00:01:00.000Z",
      sha256: "a".repeat(64),
    })).toBe(false);
  });

  it("writes an atomic private envelope with authoritative runtime state", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-diagnostic-"));
    roots.push(root);
    const body = Buffer.from(JSON.stringify({ event: "real-development-data", nested: { ok: true } }));
    const archiver = new DiagnosticReportArchiver({
      reportsDirectory: join(root, "reports"),
      bridgeInstanceId: "bridge-test",
      codexSourceId: "source-bridge",
      bridgeVersion: "1.69.6-test",
      getRuntimeStates: () => [{
        bridgeSessionId: "bridge-session",
        provider: "codex",
        providerSessionId: "thread-123",
        projectPath: "/private/project",
        processStatus: "running",
        executionHost: "desktopAppServer",
        controlState: "steerable",
        authorityGeneration: "generation-7",
        activeTurnId: "turn-8",
        observedAt: "2026-08-12T00:02:00.000Z",
      }],
    });
    const result = await archiver.archive(metadata(body), body, body.length);
    const saved = JSON.parse(await readFile(result.savedPath, "utf8")) as Record<string, any>;
    expect(saved.mobileReport.event).toBe("real-development-data");
    expect(saved.bridge.runtimeState).toMatchObject({
      provider: "codex",
      providerSessionId: "thread-123",
      executionHost: "desktopAppServer",
      controlState: "steerable",
      authorityGeneration: "generation-7",
      activeTurnId: "turn-8",
      processStatus: "running",
      observedAt: "2026-08-12T00:02:00.000Z",
    });
    expect((await stat(join(root, "reports"))).mode & 0o777).toBe(0o700);
    expect((await stat(result.savedPath)).mode & 0o777).toBe(0o600);
  });

  it("rejects checksum, JSON, oversized, and infrastructure credential failures", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-diagnostic-"));
    roots.push(root);
    const archiver = new DiagnosticReportArchiver({ reportsDirectory: join(root, "reports") });
    const invalidSha = Buffer.from("{}");
    await expect(archiver.archive({ ...metadata(invalidSha), sha256: "b".repeat(64) }, invalidSha, invalidSha.length))
      .rejects.toMatchObject({ code: "diagnostic_sha256_mismatch" });
    const invalidJson = Buffer.from("not json");
    await expect(archiver.archive(metadata(invalidJson), invalidJson, invalidJson.length))
      .rejects.toMatchObject({ code: "diagnostic_invalid_json" });
    const businessToken = Buffer.from(JSON.stringify({
      transcript: [{
        ["to" + "ken"]: ["business", "value"].join("-"),
        ["pass" + "word"]: ["fixture", "value"].join("-"),
      }],
    }));
    await expect(archiver.archive(metadata(businessToken, "business-fields"), businessToken, businessToken.length))
      .resolves.toMatchObject({ filename: expect.stringContaining("business-fields") });
    const secret = Buffer.from(JSON.stringify({ connection: { authorizationHeader: "must-not-be-archived" } }));
    await expect(archiver.archive(metadata(secret, "connection-secret"), secret, secret.length))
      .rejects.toMatchObject({ code: "diagnostic_sensitive_field" });
    const oversized = Buffer.alloc(DIAGNOSTIC_REPORT_MAX_BYTES + 1, 0x20);
    await expect(archiver.archive(metadata(oversized, "oversized"), oversized, oversized.length))
      .rejects.toMatchObject({ code: "diagnostic_size_mismatch" });
  });
});
