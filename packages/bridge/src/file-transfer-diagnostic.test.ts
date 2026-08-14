import { createHash } from "node:crypto";
import { mkdtemp, readFile, readdir, stat, rm, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  DIAGNOSTIC_REPORT_PAYLOAD_MAX_BYTES,
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
    bridgeInstanceId: "bridge-test",
    codexSourceId: "source-bridge",
    capturedAtStart: "2026-08-12T00:00:00.000Z",
    capturedAtEnd: "2026-08-12T00:01:00.000Z",
    sha256: createHash("sha256").update(bytes).digest("hex"),
  };
}

function reportBody(
  reportId: string,
  fields: Record<string, unknown> = {},
): Buffer {
  return Buffer.from(JSON.stringify({
    schemaVersion: 1,
    reportId,
    target: {
      provider: "codex",
      providerSessionId: "thread-123",
    },
    mobile: {
      infrastructure: {
        bridgeInstanceId: "bridge-test",
        codexSourceId: "source-bridge",
      },
    },
    ...fields,
  }));
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
      bridgeInstanceId: "bridge-test",
      capturedAtStart: "2026-08-12T00:00:00.000Z",
      capturedAtEnd: "2026-08-12T00:01:00.000Z",
      sha256: "a".repeat(64),
    })).toBe(false);
  });

  it("writes an atomic private envelope with authoritative runtime state", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-diagnostic-"));
    roots.push(root);
    const body = reportBody("report_20260812", {
      event: "real-development-data",
      nested: { ok: true },
    });
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
    expect(result.archiveSha256).toMatch(/^[a-f0-9]{64}$/u);
    expect(result.mobileReportCanonicalSha256).toMatch(/^[a-f0-9]{64}$/u);
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
    const archiver = new DiagnosticReportArchiver({
      reportsDirectory: join(root, "reports"),
      bridgeInstanceId: "bridge-test",
      codexSourceId: "source-bridge",
    });
    const invalidSha = reportBody("report_20260812");
    await expect(archiver.archive({ ...metadata(invalidSha), sha256: "b".repeat(64) }, invalidSha, invalidSha.length))
      .rejects.toMatchObject({ code: "diagnostic_sha256_mismatch" });
    const invalidJson = Buffer.from("not json");
    await expect(archiver.archive(metadata(invalidJson), invalidJson, invalidJson.length))
      .rejects.toMatchObject({ code: "diagnostic_invalid_json" });
    const businessToken = reportBody("business-fields", {
      transcript: [{
        ["to" + "ken"]: ["business", "value"].join("-"),
        ["pass" + "word"]: ["fixture", "value"].join("-"),
      }],
    });
    await expect(archiver.archive(metadata(businessToken, "business-fields"), businessToken, businessToken.length))
      .rejects.toMatchObject({ code: "diagnostic_sensitive_field" });
    const fixtureCredential = ["must", "not", "be", "archived"].join("-");
    const secret = reportBody("connection-secret", {
      connection: { authorizationHeader: fixtureCredential },
    });
    await expect(archiver.archive(metadata(secret, "connection-secret"), secret, secret.length))
      .rejects.toMatchObject({ code: "diagnostic_sensitive_field" });
    for (const [reportId, payload] of [
      ["id-token", { connection: { id_token: fixtureCredential } }],
      ["oauth-token", { authentication: { oauth_token: fixtureCredential } }],
      ["client-secret", { infrastructure: { client_secret: fixtureCredential } }],
      ["github-token", { infrastructure: { githubToken: fixtureCredential } }],
    ] as const) {
      const credential = reportBody(reportId, payload);
      await expect(archiver.archive(metadata(credential, reportId), credential, credential.length))
        .rejects.toMatchObject({ code: "diagnostic_sensitive_field" });
    }
    for (const [reportId, payload] of [
      ["websocket-query", { connection: "wss://bridge.test:8765/socket?token=must-not-leave" }],
      ["websocket-userinfo", { connection: "ws://owner:secret@bridge.test:8765" }],
      ["inline-assignment", { log: "BRIDGE_API_KEY=must-not-leave-either" }],
      ["pem-private", { log: ["-----BEGIN ", "PRIVATE KEY-----\nprivate-material\n-----END PRIVATE KEY-----"].join("") }],
      ["pem-openssh", { log: ["-----BEGIN OPENSSH ", "PRIVATE KEY-----\nssh-material\n-----END OPENSSH PRIVATE KEY-----"].join("") }],
      ["pem-truncated", { log: ["-----BEGIN EC ", "PRIVATE KEY-----\ntruncated-material"].join("") }],
      ["aws-access-key", { log: ["AK", "IAABCDEFGHIJKLMNOP"].join("") }],
      ["aws-temporary-access-key", { log: "ASIAABCDEFGHIJKLMNOP" }],
      ["aws-access-key-id-field", { env: { AWS_ACCESS_KEY_ID: "temporary-access-id" } }],
      ["aws-access-key-id-assignment", { log: "AWS_ACCESS_KEY_ID=temporary-access-id" }],
      ["aws-secret-key-field", { env: { AWS_SECRET_ACCESS_KEY: "not-an-access-id-but-still-secret" } }],
      ["aws-secret-key-assignment", { log: "AWS_SECRET_ACCESS_KEY=another-high-confidence-secret" }],
      ["aws-secret-key-human-assignment", { log: "AWS Secret Access Key: natural-language-secret-value" }],
    ] as const) {
      const credential = reportBody(reportId, payload);
      await expect(archiver.archive(metadata(credential, reportId), credential, credential.length))
        .rejects.toMatchObject({ code: "diagnostic_sensitive_field" });
    }
    const oversized = Buffer.alloc(DIAGNOSTIC_REPORT_PAYLOAD_MAX_BYTES + 1, 0x20);
    await expect(archiver.archive(metadata(oversized, "oversized"), oversized, oversized.length))
      .rejects.toMatchObject({ code: "diagnostic_size_mismatch" });
  });

  it("archives full-fidelity development reports after basic integrity checks", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-diagnostic-"));
    roots.push(root);
    const body = reportBody("development-full-fidelity", {
      transcript: {
        authorizationHeader: "development-fixture-value",
        endpoint: "wss://bridge.test/socket?development=1",
      },
      largeProjection: Array.from({ length: 100_100 }, (_, index) => index),
    });
    const archiver = new DiagnosticReportArchiver({
      reportsDirectory: join(root, "reports"),
      bridgeInstanceId: "bridge-test",
      codexSourceId: "source-bridge",
      contentPolicy: "development_full_fidelity",
    });

    const result = await archiver.archive(
      metadata(body, "development-full-fidelity"),
      body,
      body.length,
    );
    const saved = JSON.parse(
      await readFile(result.savedPath, "utf8"),
    ) as Record<string, any>;
    expect(saved.mobileReport.transcript).toEqual({
      authorizationHeader: "development-fixture-value",
      endpoint: "wss://bridge.test/socket?development=1",
    });
    expect(saved.mobileReport.largeProjection).toHaveLength(100_100);
    const reportMetadata = metadata(body, "development-full-fidelity");
    await expect(
      archiver.archive(reportMetadata, body, body.length),
    ).resolves.toEqual(result);
    await expect(
      archiver.verifyReceipt(reportMetadata, {
        filename: result.filename,
        savedPath: result.savedPath,
        purpose: "diagnostic_report",
        reportId: reportMetadata.reportId,
        archiveSha256: result.archiveSha256,
        mobileReportCanonicalSha256: result.mobileReportCanonicalSha256,
      }),
    ).resolves.toBe(true);
  });

  it("keeps development integrity failures distinct from content policy", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-diagnostic-"));
    roots.push(root);
    const archiver = new DiagnosticReportArchiver({
      reportsDirectory: join(root, "reports"),
      bridgeInstanceId: "bridge-test",
      codexSourceId: "source-bridge",
      contentPolicy: "development_full_fidelity",
    });
    const clean = reportBody("development-integrity");
    await expect(
      archiver.archive(
        { ...metadata(clean, "development-integrity"), sha256: "b".repeat(64) },
        clean,
        clean.length,
      ),
    ).rejects.toMatchObject({ code: "diagnostic_sha256_mismatch" });
    const invalidJson = Buffer.from("not json");
    await expect(
      archiver.archive(
        metadata(invalidJson, "development-invalid-json"),
        invalidJson,
        invalidJson.length,
      ),
    ).rejects.toMatchObject({ code: "diagnostic_invalid_json" });
  });

  it("accepts only exact provider and source identities", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-diagnostic-"));
    roots.push(root);
    const archiver = new DiagnosticReportArchiver({
      reportsDirectory: join(root, "reports"),
      bridgeInstanceId: "bridge-test",
      codexSourceId: "source-bridge",
    });
    const body = reportBody("provider-identity");
    for (const override of [
      { provider: "codex ", codexSourceId: "source-bridge" },
      { provider: "CODEx", codexSourceId: "source-bridge" },
      { provider: "unknown", codexSourceId: "source-bridge" },
      { provider: "codex", codexSourceId: undefined },
    ]) {
      await expect(archiver.archive({
        ...metadata(body, "provider-identity"),
        ...override,
      }, body, body.length)).rejects.toMatchObject({
        code: expect.stringMatching(
          /diagnostic_(metadata_invalid|source_mismatch)/u,
        ),
      });
    }
  });

  it("rejects mismatched nested report identity and credentials in authoritative metadata", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-diagnostic-"));
    roots.push(root);
    const archiver = new DiagnosticReportArchiver({
      reportsDirectory: join(root, "reports"),
      bridgeInstanceId: "bridge-test",
      codexSourceId: "source-bridge",
    });
    for (const [reportId, fields] of [
      ["wrong-provider", {
        target: { provider: "claude", providerSessionId: "thread-123" },
      }],
      ["wrong-session", {
        target: { provider: "codex", providerSessionId: "other-thread" },
      }],
      ["wrong-bridge", {
        mobile: { infrastructure: { bridgeInstanceId: "other-bridge", codexSourceId: "source-bridge" } },
      }],
      ["wrong-source", {
        mobile: { infrastructure: { bridgeInstanceId: "bridge-test", codexSourceId: "other-source" } },
      }],
    ] as const) {
      const body = reportBody(reportId, fields);
      await expect(archiver.archive(metadata(body, reportId), body, body.length))
        .rejects.toMatchObject({ code: "diagnostic_payload_identity_mismatch" });
    }

    const clean = reportBody("metadata-secret");
    await expect(archiver.archive({
      ...metadata(clean, "metadata-secret"),
      provider: "api_key=metadata-secret-value",
    }, clean, clean.length)).rejects.toMatchObject({
      code: "diagnostic_sensitive_field",
    });

    const runtimeSecret = reportBody("runtime-secret");
    const unsafeRuntime = new DiagnosticReportArchiver({
      reportsDirectory: join(root, "unsafe-runtime-reports"),
      bridgeInstanceId: "bridge-test",
      codexSourceId: "source-bridge",
      runtimeIdentity: "Bearer runtime-secret-value",
    });
    await expect(unsafeRuntime.archive(
      metadata(runtimeSecret, "runtime-secret"),
      runtimeSecret,
      runtimeSecret.length,
    )).rejects.toMatchObject({ code: "diagnostic_sensitive_field" });
  });

  it("removes only stale owned temporary report files during retention cleanup", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-diagnostic-"));
    roots.push(root);
    const reportsDirectory = join(root, "reports");
    const now = Date.parse("2026-08-13T00:00:00.000Z");
    const archiver = new DiagnosticReportArchiver({
      reportsDirectory,
      bridgeInstanceId: "bridge-test",
      codexSourceId: "source-bridge",
      now: () => now,
    });
    await archiver.init();
    const stale = join(
      reportsDirectory,
      "stale-report.json.tmp-123-00000000-0000-4000-8000-000000000000",
    );
    const unrelated = join(reportsDirectory, "keep.tmp-file");
    await writeFile(stale, "stale");
    await writeFile(unrelated, "keep");
    const old = new Date(now - 2 * 60 * 60 * 1000);
    await utimes(stale, old, old);

    await archiver.init();

    expect(await readdir(reportsDirectory)).toEqual(["keep.tmp-file"]);
  });

  it("never overwrites a concurrent report with the same identity", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-diagnostic-"));
    roots.push(root);
    const archiver = new DiagnosticReportArchiver({
      reportsDirectory: join(root, "reports"),
      bridgeInstanceId: "bridge-test",
      codexSourceId: "source-bridge",
    });
    const reportId = "concurrent-report";
    const first = reportBody(reportId, { event: "first" });
    const second = reportBody(reportId, { event: "second" });
    const settled = await Promise.allSettled([
      archiver.archive(metadata(first, reportId), first, first.length),
      archiver.archive(metadata(second, reportId), second, second.length),
    ]);
    expect(settled.filter((result) => result.status === "fulfilled")).toHaveLength(1);
    expect(settled.filter((result) => result.status === "rejected")).toHaveLength(1);
    const failure = settled.find((result) => result.status === "rejected");
    expect(failure).toMatchObject({
      status: "rejected",
      reason: { code: "diagnostic_report_collision" },
    });
    const success = settled.find((result) => result.status === "fulfilled");
    if (success?.status !== "fulfilled") throw new Error("expected one archived report");
    const saved = JSON.parse(await readFile(success.value.savedPath, "utf8")) as {
      mobileReport: { event: string };
    };
    expect(["first", "second"]).toContain(saved.mobileReport.event);
  });

  it("reuses one immutable archive when Bridge runtime state changes", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-diagnostic-"));
    roots.push(root);
    let generation = "generation-1";
    const archiver = new DiagnosticReportArchiver({
      reportsDirectory: join(root, "reports"),
      bridgeInstanceId: "bridge-test",
      codexSourceId: "source-bridge",
      getRuntimeStates: () => [{
        bridgeSessionId: "bridge-session",
        provider: "codex",
        providerSessionId: "thread-123",
        projectPath: root,
        processStatus: "running",
        authorityGeneration: generation,
        observedAt: "2026-08-12T00:02:00.000Z",
      }],
    });
    const body = reportBody("stable-retry", { event: "same-mobile-state" });
    const first = await archiver.archive(
      metadata(body, "stable-retry"),
      body,
      body.length,
    );
    generation = "generation-2";
    const second = await archiver.archive(
      metadata(body, "stable-retry"),
      body,
      body.length,
    );
    expect(second).toEqual(first);
    const saved = JSON.parse(await readFile(first.savedPath, "utf8")) as Record<string, any>;
    expect(saved.bridge.runtimeState.authorityGeneration).toBe("generation-1");
  });

  it("rejects a credential injected into an existing archive before reuse", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-diagnostic-"));
    roots.push(root);
    const archiver = new DiagnosticReportArchiver({
      reportsDirectory: join(root, "reports"),
      bridgeInstanceId: "bridge-test",
      codexSourceId: "source-bridge",
    });
    const body = reportBody("existing-credential", { event: "clean" });
    const saved = await archiver.archive(
      metadata(body, "existing-credential"),
      body,
      body.length,
    );
    const envelope = JSON.parse(await readFile(saved.savedPath, "utf8")) as Record<string, any>;
    envelope.bridge.runtimeIdentity = "Bearer injected-secret-value";
    await writeFile(saved.savedPath, `${JSON.stringify(envelope, null, 2)}\n`);

    await expect(archiver.archive(
      metadata(body, "existing-credential"),
      body,
      body.length,
    )).rejects.toMatchObject({ code: "diagnostic_report_collision" });
  });

  it("bounds retained report files without deleting the report just returned", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-diagnostic-"));
    roots.push(root);
    const reportsDirectory = join(root, "reports");
    const archiver = new DiagnosticReportArchiver({
      reportsDirectory,
      bridgeInstanceId: "bridge-test",
      codexSourceId: "source-bridge",
    });
    let latestPath = "";
    for (let index = 0; index < 35; index += 1) {
      const reportId = `retention-${String(index).padStart(2, "0")}`;
      const body = reportBody(reportId, { index });
      latestPath = (await archiver.archive(
        metadata(body, reportId),
        body,
        body.length,
      )).savedPath;
    }

    expect(await readdir(reportsDirectory)).toHaveLength(32);
    await expect(readFile(latestPath, "utf8")).resolves.toContain(
      '"reportId": "retention-34"',
    );
  });
});
