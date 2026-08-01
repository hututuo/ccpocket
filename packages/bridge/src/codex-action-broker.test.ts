import {
  chmod,
  mkdir,
  mkdtemp,
  readFile,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";

const lstatControl = vi.hoisted(() => ({
  failPath: undefined as string | undefined,
}));

vi.mock("node:fs/promises", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:fs/promises")>();
  return {
    ...actual,
    lstat: async (
      path: Parameters<typeof actual.lstat>[0],
      options?: unknown,
    ) => {
      if (lstatControl.failPath === String(path)) {
        lstatControl.failPath = undefined;
        throw new Error("simulated post-publication lstat failure");
      }
      return actual.lstat(path, options as never);
    },
  };
});

import {
  actionBrokerFileForPort,
  actionBrokerFileForSource,
  CodexActionBroker,
  CodexActionBrokerDegradedError,
  opaqueCodexActionRequestId,
  type CodexActionRequestIdentity,
} from "./codex-action-broker.js";

const temporaryRoots: string[] = [];
const BASE_NOW = "2026-08-01T00:00:00.000Z";

afterEach(async () => {
  lstatControl.failPath = undefined;
  await Promise.all(
    temporaryRoots.splice(0).map((path) => rm(path, { recursive: true })),
  );
});

async function brokerFixture(
  options: {
    now?: () => Date;
    randomToken?: () => string;
    nested?: boolean;
  } = {},
): Promise<CodexActionBroker> {
  const root = await mkdtemp(join(tmpdir(), "ccpocket-action-broker-"));
  temporaryRoots.push(root);
  return new CodexActionBroker({
    filePath: options.nested
      ? join(root, "private", "action-broker.json")
      : join(root, "action-broker.json"),
    now: options.now ?? (() => new Date(BASE_NOW)),
    randomToken: options.randomToken,
  });
}

function identity(
  overrides: Partial<CodexActionRequestIdentity> = {},
): CodexActionRequestIdentity {
  return {
    codexSourceId: "codex-source-a",
    threadId: "thread-a",
    turnId: "turn-a",
    requestId: "request-a",
    generation: 1,
    ...overrides,
  };
}

async function observe(
  broker: CodexActionBroker,
  requestIdentity = identity(),
  expiresAt = "2026-08-02T00:00:00.000Z",
) {
  return broker.observePending({
    identity: requestIdentity,
    method: "item/commandExecution/requestApproval",
    kind: "command_approval",
    observedAt: BASE_NOW,
    expiresAt,
  });
}

describe("CodexActionBroker privacy and persistence", () => {
  it("isolates default state by Bridge port while honoring an explicit path", () => {
    expect(actionBrokerFileForPort(8765)).toContain(
      "/.ccpocket/codex-action-broker-v1.json",
    );
    expect(actionBrokerFileForPort(18765)).toContain(
      "/.ccpocket/codex-action-broker-v1-18765.json",
    );
    expect(actionBrokerFileForPort("18765")).toBe(
      actionBrokerFileForPort(18765),
    );
    expect(actionBrokerFileForPort(18765, " /tmp/custom-broker.json ")).toBe(
      "/tmp/custom-broker.json",
    );
    expect(actionBrokerFileForSource("source-a")).toBe(
      actionBrokerFileForSource("source-a"),
    );
    expect(actionBrokerFileForSource("source-a")).not.toBe(
      actionBrokerFileForSource("source-b"),
    );
  });

  it("atomically stores only private request metadata and exposes an opaque public identity", async () => {
    const broker = await brokerFixture({ nested: true });
    const created = await broker.observePending({
      identity: identity(),
      method: "item/commandExecution/requestApproval",
      kind: "command_approval",
      observedAt: BASE_NOW,
      expiresAt: "2026-08-02T00:00:00.000Z",
      // Future integration must keep these fields on the live attachment. A
      // defensive runtime caller cannot smuggle them into the durable ledger.
      payload: { command: "cat /private/top-secret.txt" },
      command: "cat /private/top-secret.txt",
      cwd: "/private/top-secret",
      questions: ["What is the secret?"],
    } as Parameters<CodexActionBroker["observePending"]>[0] &
      Record<string, unknown>);

    expect(created).toMatchObject({
      outcome: "created",
      request: {
        opaqueRequestId: opaqueCodexActionRequestId(identity()),
        kind: "command_approval",
        state: "pending",
      },
    });
    expect(created.request).not.toHaveProperty("identity");
    expect(created.request).not.toHaveProperty("method");

    const serialized = await readFile(broker.filePath, "utf8");
    expect(serialized).not.toContain("top-secret");
    expect(serialized).not.toContain("What is the secret?");
    expect(serialized).not.toContain('"payload"');
    expect(serialized).not.toContain('"command"');
    expect(serialized).not.toContain('"cwd"');
    expect(serialized).not.toContain('"questions"');

    expect((await stat(broker.filePath)).mode & 0o777).toBe(0o600);
    expect((await stat(dirname(broker.filePath))).mode & 0o777).toBe(0o700);
    expect(await broker.getByOpaqueId(created.request.opaqueRequestId)).toEqual(
      created.request,
    );
  });

  it("keeps numeric and string JSON-RPC request IDs distinct", async () => {
    const broker = await brokerFixture();
    const numeric = identity({ requestId: 7 });
    const textual = identity({ requestId: "7" });
    await observe(broker, numeric);
    await observe(broker, textual);

    expect(opaqueCodexActionRequestId(numeric)).not.toBe(
      opaqueCodexActionRequestId(textual),
    );
    expect(await broker.list()).toHaveLength(2);
  });

  it("preserves an invalid ledger and fails closed instead of overwriting it", async () => {
    const broker = await brokerFixture();
    const raw = `${JSON.stringify({
      version: 1,
      revision: 4,
      currentGenerations: [],
      requests: [],
      payload: "must-not-be-accepted",
    })}\n`;
    await writeFile(broker.filePath, raw, { mode: 0o600 });
    await chmod(broker.filePath, 0o600);

    await expect(broker.health()).resolves.toMatchObject({
      degraded: true,
      degradedReason: "unreadable_state",
    });
    await expect(observe(broker)).rejects.toBeInstanceOf(
      CodexActionBrokerDegradedError,
    );
    expect(await readFile(broker.filePath, "utf8")).toBe(raw);
  });
});

describe("CodexActionBroker exactly-once arbitration", () => {
  it("serializes competing claims and makes claim and resolution retries idempotent", async () => {
    let tokenCounter = 0;
    const broker = await brokerFixture({
      randomToken: () => `claim-token-${++tokenCounter}`,
    });
    const requestIdentity = identity();
    await observe(broker, requestIdentity);

    const claims = await Promise.all([
      broker.claim(requestIdentity, {
        claimantId: "mobile-a",
        operationId: "claim-operation-a",
      }),
      broker.claim(requestIdentity, {
        claimantId: "mobile-b",
        operationId: "claim-operation-b",
      }),
    ]);
    expect(claims.map((result) => result.outcome).sort()).toEqual([
      "claimed",
      "contended",
    ]);
    const winnerIndex = claims.findIndex(
      (result) => result.outcome === "claimed",
    );
    const winner =
      winnerIndex === 0
        ? { claimantId: "mobile-a", operationId: "claim-operation-a" }
        : { claimantId: "mobile-b", operationId: "claim-operation-b" };
    const claimed = claims[winnerIndex];
    expect(claimed.outcome).toBe("claimed");
    if (claimed.outcome !== "claimed") throw new Error("claim did not win");

    await expect(broker.claim(requestIdentity, winner)).resolves.toMatchObject({
      outcome: "idempotent",
      claimToken: claimed.claimToken,
    });
    const invalidClaimProof = ["invalid", "claim", "proof"].join("-");
    await expect(
      broker.resolve(requestIdentity, {
        authority: "claimant",
        resolutionId: "resolution-a",
        outcome: "accepted",
        claimToken: invalidClaimProof,
      }),
    ).resolves.toMatchObject({ outcome: "claim_mismatch" });

    await expect(
      broker.resolve(requestIdentity, {
        authority: "claimant",
        resolutionId: "resolution-a",
        outcome: "accepted",
        claimToken: claimed.claimToken,
      }),
    ).resolves.toMatchObject({
      outcome: "resolved",
      request: { state: "resolved" },
    });
    await expect(
      broker.resolve(requestIdentity, {
        authority: "claimant",
        resolutionId: "resolution-a",
        outcome: "accepted",
        claimToken: claimed.claimToken,
      }),
    ).resolves.toMatchObject({ outcome: "idempotent" });
    await expect(
      broker.resolve(requestIdentity, {
        authority: "app_server",
        resolutionId: "desktop-late-resolution",
        outcome: "resolved_elsewhere",
      }),
    ).resolves.toMatchObject({ outcome: "already_resolved" });
    await expect(
      broker.claim(requestIdentity, {
        claimantId: "mobile-c",
        operationId: "claim-operation-c",
      }),
    ).resolves.toMatchObject({ outcome: "resolved" });
  });

  it("lets the canonical app-server win a first-responder race and keeps a tombstone", async () => {
    const broker = await brokerFixture({
      randomToken: () => "phone-claim-token",
    });
    const requestIdentity = identity();
    await observe(broker, requestIdentity);
    const phoneClaim = await broker.claim(requestIdentity, {
      claimantId: "mobile",
      operationId: "phone-claim",
    });
    expect(phoneClaim.outcome).toBe("claimed");

    await expect(
      broker.resolve(requestIdentity, {
        authority: "app_server",
        resolutionId: "desktop-first-responder",
        outcome: "resolved_elsewhere",
      }),
    ).resolves.toMatchObject({ outcome: "resolved" });
    if (phoneClaim.outcome !== "claimed") throw new Error("missing claim");
    await expect(
      broker.resolve(requestIdentity, {
        authority: "claimant",
        resolutionId: "phone-late-response",
        outcome: "accepted",
        claimToken: phoneClaim.claimToken,
      }),
    ).resolves.toMatchObject({ outcome: "already_resolved" });

    const resolvedBeforeObserved = identity({ requestId: "resolved-first" });
    await expect(
      broker.resolve(resolvedBeforeObserved, {
        authority: "app_server",
        resolutionId: "canonical-resolution",
        outcome: "resolved_elsewhere",
      }),
    ).resolves.toMatchObject({
      outcome: "resolved",
      request: { state: "resolved", kind: "unknown" },
    });
    await expect(
      observe(broker, resolvedBeforeObserved),
    ).resolves.toMatchObject({
      outcome: "existing",
      request: { state: "resolved" },
    });
  });

  it("recovers a claimed request after restart with the same idempotency token", async () => {
    const broker = await brokerFixture({
      randomToken: () => "durable-claim-token",
    });
    const requestIdentity = identity();
    await observe(broker, requestIdentity);
    const first = await broker.claim(requestIdentity, {
      claimantId: "auto-approval-supervisor",
      operationId: "auto-claim-1",
    });
    expect(first.outcome).toBe("claimed");
    if (first.outcome !== "claimed") throw new Error("missing first claim");

    const reopened = new CodexActionBroker({
      filePath: broker.filePath,
      now: () => new Date(BASE_NOW),
    });
    await expect(reopened.ready()).resolves.toMatchObject({
      degraded: false,
      claimedCount: 1,
    });
    await expect(
      reopened.claim(requestIdentity, {
        claimantId: "auto-approval-supervisor",
        operationId: "auto-claim-1",
      }),
    ).resolves.toMatchObject({
      outcome: "idempotent",
      claimToken: first.claimToken,
    });
    await reopened.resolve(requestIdentity, {
      authority: "claimant",
      resolutionId: "auto-resolution-1",
      outcome: "accepted",
      claimToken: first.claimToken,
    });

    const reopenedAgain = new CodexActionBroker({
      filePath: broker.filePath,
      now: () => new Date(BASE_NOW),
    });
    await expect(reopenedAgain.get(requestIdentity)).resolves.toMatchObject({
      state: "resolved",
      resolution: { outcome: "accepted", authority: "claimant" },
    });
  });

  it("distinguishes a durable claim from a submitted response across restart", async () => {
    const broker = await brokerFixture({
      randomToken: () => "submission-claim-token",
    });
    const requestIdentity = identity();
    await observe(broker, requestIdentity);
    const claim = await broker.claim(requestIdentity, {
      claimantId: "mobile-a",
      operationId: "operation-a",
    });
    expect(claim.outcome).toBe("claimed");
    if (claim.outcome !== "claimed") throw new Error("missing claim");

    const beforeSubmit = await broker.get(requestIdentity);
    expect(beforeSubmit?.claim?.submittedAt).toBeUndefined();
    await broker.markSubmitting(requestIdentity, {
      operationId: "operation-a",
      claimToken: claim.claimToken,
    });
    await broker.markSubmitted(requestIdentity, {
      operationId: "operation-a",
      claimToken: claim.claimToken,
    });

    const reopened = new CodexActionBroker({
      filePath: broker.filePath,
      now: () => new Date(BASE_NOW),
    });
    expect((await reopened.get(requestIdentity))?.claim?.submittedAt).toBe(
      BASE_NOW,
    );
    await expect(
      reopened.markSubmitted(requestIdentity, {
        operationId: "operation-a",
        claimToken: claim.claimToken,
      }),
    ).resolves.toMatchObject({ outcome: "idempotent" });
  });
});

describe("CodexActionBroker generation and expiry fences", () => {
  it("allocates a monotonic source generation across Bridge restarts", async () => {
    const broker = await brokerFixture();
    await expect(
      broker.beginSourceGeneration("codex-source-a"),
    ).resolves.toEqual({ generation: 1, expiredCount: 0 });
    const firstGeneration = identity({
      requestId: "restart-pending",
      generation: 1,
    });
    await observe(broker, firstGeneration);

    const restarted = new CodexActionBroker({
      filePath: broker.filePath,
      now: () => new Date(BASE_NOW),
    });
    await expect(
      restarted.beginSourceGeneration("codex-source-a"),
    ).resolves.toEqual({ generation: 2, expiredCount: 1 });
    await expect(restarted.currentGeneration("codex-source-a")).resolves.toBe(
      2,
    );
    await expect(restarted.get(firstGeneration)).resolves.toMatchObject({
      state: "expired",
      expiration: { reason: "generation_superseded" },
    });
    await expect(observe(restarted, firstGeneration)).resolves.toEqual({
      outcome: "stale_generation",
      currentGeneration: 2,
    });

    const restartedAgain = new CodexActionBroker({
      filePath: broker.filePath,
      now: () => new Date(BASE_NOW),
    });
    await expect(
      restartedAgain.beginSourceGeneration("codex-source-a"),
    ).resolves.toEqual({ generation: 3, expiredCount: 0 });
  });

  it("expires all nonterminal requests from an older source generation", async () => {
    const broker = await brokerFixture({
      randomToken: () => "old-generation-token",
    });
    const oldPending = identity({ requestId: "old-pending", generation: 3 });
    const oldClaimed = identity({ requestId: "old-claimed", generation: 3 });
    await observe(broker, oldPending);
    await observe(broker, oldClaimed);
    await broker.claim(oldClaimed, {
      claimantId: "mobile",
      operationId: "old-claim",
    });

    await expect(
      broker.advanceGeneration("codex-source-a", 4),
    ).resolves.toEqual({
      outcome: "advanced",
      currentGeneration: 4,
      expiredCount: 2,
    });
    await expect(broker.get(oldPending)).resolves.toMatchObject({
      state: "expired",
      expiration: { reason: "generation_superseded" },
    });
    await expect(
      broker.claim(oldClaimed, {
        claimantId: "mobile",
        operationId: "late-old-claim",
      }),
    ).resolves.toEqual({
      outcome: "stale_generation",
      currentGeneration: 4,
    });
    await expect(
      broker.resolve(oldClaimed, {
        authority: "app_server",
        resolutionId: "late-old-resolution",
        outcome: "resolved_elsewhere",
      }),
    ).resolves.toEqual({
      outcome: "stale_generation",
      currentGeneration: 4,
    });

    const current = identity({ requestId: "old-pending", generation: 4 });
    await expect(observe(broker, current)).resolves.toMatchObject({
      outcome: "created",
      request: { state: "pending" },
    });
    await expect(observe(broker, oldPending)).resolves.toEqual({
      outcome: "stale_generation",
      currentGeneration: 4,
    });
    expect(opaqueCodexActionRequestId(current)).not.toBe(
      opaqueCodexActionRequestId(oldPending),
    );

    const reopened = new CodexActionBroker({
      filePath: broker.filePath,
      now: () => new Date(BASE_NOW),
    });
    await expect(observe(reopened, oldPending)).resolves.toEqual({
      outcome: "stale_generation",
      currentGeneration: 4,
    });
  });

  it("persists deadline expiry and never resurrects an expired request", async () => {
    let now = new Date(BASE_NOW);
    const broker = await brokerFixture({ now: () => new Date(now) });
    const requestIdentity = identity();
    await observe(broker, requestIdentity, "2026-08-01T00:00:05.000Z");
    now = new Date("2026-08-01T00:00:06.000Z");

    await expect(broker.expireDue()).resolves.toBe(1);
    await expect(broker.get(requestIdentity)).resolves.toMatchObject({
      state: "expired",
      expiration: { reason: "deadline" },
    });
    await expect(
      broker.claim(requestIdentity, {
        claimantId: "mobile",
        operationId: "late-claim",
      }),
    ).resolves.toMatchObject({ outcome: "expired" });
    await expect(
      broker.resolve(requestIdentity, {
        authority: "app_server",
        resolutionId: "late-resolution",
        outcome: "resolved_elsewhere",
      }),
    ).resolves.toMatchObject({ outcome: "expired" });

    const reopened = new CodexActionBroker({
      filePath: broker.filePath,
      now: () => new Date(now),
    });
    await expect(reopened.get(requestIdentity)).resolves.toMatchObject({
      state: "expired",
    });
  });

  it("does not publish an in-memory claim when atomic persistence fails", async () => {
    const broker = await brokerFixture({ nested: true });
    const requestIdentity = identity();
    await observe(broker, requestIdentity);
    const directory = dirname(broker.filePath);
    await rm(directory, { recursive: true });
    await writeFile(directory, "blocks-directory-recreation", "utf8");

    await expect(
      broker.claim(requestIdentity, {
        claimantId: "mobile",
        operationId: "claim-during-io-failure",
      }),
    ).rejects.toThrow();
    await expect(broker.get(requestIdentity)).resolves.toMatchObject({
      state: "pending",
    });

    await rm(directory, { force: true });
    await mkdir(directory, { recursive: true, mode: 0o700 });
    const retry = await broker.claim(requestIdentity, {
      claimantId: "mobile",
      operationId: "claim-during-io-failure",
    });
    expect(retry).toMatchObject({ outcome: "claimed" });

    const reopened = new CodexActionBroker({
      filePath: broker.filePath,
      now: () => new Date(BASE_NOW),
    });
    await expect(reopened.get(requestIdentity)).resolves.toMatchObject({
      state: "claimed",
    });
  });

  it("keeps a published claim in memory and fails closed when post-publication verification fails", async () => {
    const publishedClaimProof = ["published", "claim", "proof"].join("-");
    const broker = await brokerFixture({
      randomToken: () => publishedClaimProof,
    });
    const requestIdentity = identity();
    await observe(broker, requestIdentity);
    const revisionBeforeClaim = (await broker.health()).revision;

    lstatControl.failPath = broker.filePath;
    await expect(
      broker.claim(requestIdentity, {
        claimantId: "mobile",
        operationId: "post-publication-claim",
      }),
    ).rejects.toThrow("simulated post-publication lstat failure");

    await expect(broker.health()).resolves.toMatchObject({
      degraded: true,
      degradedReason: "unsafe_state",
      revision: revisionBeforeClaim + 1,
      pendingCount: 0,
      claimedCount: 1,
    });
    await expect(broker.get(requestIdentity)).resolves.toMatchObject({
      state: "claimed",
      claim: { claimToken: publishedClaimProof },
    });
    await expect(
      broker.resolve(requestIdentity, {
        authority: "claimant",
        resolutionId: "must-not-overwrite-published-claim",
        outcome: "accepted",
        claimToken: publishedClaimProof,
      }),
    ).rejects.toBeInstanceOf(CodexActionBrokerDegradedError);

    const reopened = new CodexActionBroker({
      filePath: broker.filePath,
      now: () => new Date(BASE_NOW),
    });
    await expect(reopened.get(requestIdentity)).resolves.toMatchObject({
      state: "claimed",
      claim: { claimToken: publishedClaimProof },
    });
  });
});
