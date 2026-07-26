import { randomUUID } from "node:crypto";
import { EventEmitter } from "node:events";
import { join } from "node:path";
import { homedir } from "node:os";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ProcessStatus, ServerMessage } from "./parser.js";
import { pathToSlug } from "./sessions-index.js";

const { codexInstances, sdkInstances, fakeDirs, fakeFiles } = vi.hoisted(
  () => ({
    codexInstances: [] as Array<{
      isWaitingForInput: boolean;
      supportsNextTurnPermissionUpdates: boolean;
      supportsNativePlanMode: boolean;
      nativePlanModeCapabilityKnown: boolean;
      start: ReturnType<typeof vi.fn>;
      stop: ReturnType<typeof vi.fn>;
      sendInputStructured: ReturnType<typeof vi.fn>;
      steerInputStructured: ReturnType<typeof vi.fn>;
      steerTurnStructured: ReturnType<typeof vi.fn>;
      emit: (event: string, ...args: unknown[]) => boolean;
    }>,
    sdkInstances: [] as Array<{
      permissionMode: string;
      start: ReturnType<typeof vi.fn>;
      stop: ReturnType<typeof vi.fn>;
      rewindFiles: ReturnType<typeof vi.fn>;
      emit: (event: string, ...args: unknown[]) => boolean;
    }>,
    fakeDirs: new Set<string>(),
    fakeFiles: new Map<string, string>(),
  }),
);
const { extractArtifactCandidatesMock } = vi.hoisted(() => ({
  extractArtifactCandidatesMock: vi.fn(),
}));

vi.mock("./artifact-candidates.js", async () => {
  const actual = await vi.importActual<
    typeof import("./artifact-candidates.js")
  >("./artifact-candidates.js");
  return {
    ...actual,
    extractArtifactCandidates: (
      ...args: Parameters<typeof actual.extractArtifactCandidates>
    ) => {
      extractArtifactCandidatesMock(...args);
      return actual.extractArtifactCandidates(...args);
    },
  };
});

vi.mock("node:fs", () => {
  const normalize = (value: unknown): string =>
    String(value).replaceAll("\\", "/");
  return {
    existsSync: vi.fn((path: unknown) => {
      const key = normalize(path);
      return fakeDirs.has(key) || fakeFiles.has(key);
    }),
    readFileSync: vi.fn((path: unknown) => {
      const key = normalize(path);
      const content = fakeFiles.get(key);
      if (content == null) {
        const err = new Error(
          `ENOENT: no such file or directory, open '${key}'`,
        );
        (err as NodeJS.ErrnoException).code = "ENOENT";
        throw err;
      }
      return content;
    }),
    readdirSync: vi.fn(
      (path: unknown, options?: { withFileTypes?: boolean }) => {
        const base = normalize(path);
        const prefix = base.endsWith("/") ? base : `${base}/`;
        const childNames = new Set<string>();

        for (const dir of fakeDirs) {
          if (!dir.startsWith(prefix)) continue;
          const rest = dir.slice(prefix.length);
          if (!rest || rest.includes("/")) continue;
          childNames.add(rest);
        }

        if (options?.withFileTypes) {
          return [...childNames].map((name) => ({
            name,
            isDirectory: () => true,
          }));
        }
        return [...childNames];
      },
    ),
  };
});

vi.mock("./codex-process.js", () => ({
  CodexProcess: class MockCodexProcess extends EventEmitter {
    public isWaitingForInput = false;
    public supportsNextTurnPermissionUpdates = false;
    public supportsNativePlanMode = false;
    public nativePlanModeCapabilityKnown = false;
    public start = vi.fn((_: string, __?: unknown) => {});
    public stop = vi.fn(() => {});
    public sendInputStructured = vi.fn();
    public steerInputStructured = vi.fn(async () => {});
    public steerTurnStructured = vi.fn(async () => {});

    constructor() {
      super();
      codexInstances.push(this);
    }
  },
}));

vi.mock("./sdk-process.js", () => ({
  SdkProcess: class MockSdkProcess extends EventEmitter {
    public permissionMode = "default";
    public start = vi.fn((_: string, __?: unknown) => {});
    public stop = vi.fn(() => {});
    public rewindFiles = vi.fn(async () => ({ canRewind: false }));

    constructor() {
      super();
      sdkInstances.push(this);
    }
  },
}));

import { SessionManager } from "./session.js";

describe("SessionManager codex path", () => {
  beforeEach(() => {
    codexInstances.length = 0;
    sdkInstances.length = 0;
    extractArtifactCandidatesMock.mockClear();
  });

  it("creates a codex session and forwards codex start options", () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create(
      "/tmp/project-codex",
      undefined,
      undefined,
      undefined,
      "codex",
      {
        threadId: "thread-1",
        sandboxMode: "workspace-write",
        approvalPolicy: "on-request",
        model: "gpt-5.3-codex",
        modelReasoningEffort: "high",
        networkAccessEnabled: true,
        webSearchMode: "live",
      },
    );

    expect(codexInstances).toHaveLength(1);
    expect(sdkInstances).toHaveLength(0);
    expect(codexInstances[0].start).toHaveBeenCalledTimes(1);
    expect(codexInstances[0].start).toHaveBeenCalledWith(
      "/tmp/project-codex",
      expect.objectContaining({
        threadId: "thread-1",
        sandboxMode: "workspace-write",
        approvalPolicy: "on-request",
        model: "gpt-5.3-codex",
        modelReasoningEffort: "high",
        networkAccessEnabled: true,
        webSearchMode: "live",
      }),
    );

    const session = manager.get(sessionId);
    expect(session?.provider).toBe("codex");
    expect(manager.list()[0].codexSettings?.codexPermissionsMode).toBe(
      "default",
    );
  });

  it("keeps processing messages after a poisoned pipeline step (P0-6)", async () => {
    let resolveRegister: (images: unknown[]) => void = () => {};
    const imageStore = {
      extractImagePaths: vi.fn((content: unknown) =>
        typeof content === "string" && content.includes("/tmp/a.png")
          ? ["/tmp/a.png"]
          : [],
      ),
      registerImages: vi.fn(
        () =>
          new Promise<unknown[]>((res) => {
            resolveRegister = res;
          }),
      ),
    };
    const received: string[] = [];
    const manager = new SessionManager((_id, msg) => {
      received.push((msg as { type: string }).type);
    }, imageStore as never);
    const sessionId = manager.create(
      "/tmp/project-codex",
      undefined,
      undefined,
      undefined,
      "codex",
      { threadId: "thread-poison" },
    );
    const proc = codexInstances[0];

    // Pin the async pipeline on a pending image registration.
    proc.emit("message", {
      type: "tool_result",
      toolUseId: "tu-1",
      content: "generated /tmp/a.png",
    });
    expect(imageStore.registerImages).toHaveBeenCalledTimes(1);

    // Chain a drain step behind the pinned pipeline and poison it.
    proc.isWaitingForInput = true;
    expect(
      manager.queueCodexInput(sessionId, {
        itemId: "queued-1",
        text: "queued input",
        queuedAt: new Date().toISOString(),
      } as never),
    ).toBe(true);
    proc.sendInputStructured.mockImplementation(() => {
      throw new Error("drain blew up");
    });
    proc.emit("input_ready");

    // Release the pipeline, then immediately chain another message onto the
    // (about to be poisoned) tail before it settles.
    resolveRegister([]);
    proc.emit("message", {
      type: "assistant",
      message: {
        model: "codex",
        content: [{ type: "text", text: "after poison" }],
      },
    });

    await new Promise((res) => setTimeout(res, 0));
    expect(received).toContain("assistant");
  });

  it("surfaces a pending runtime interaction before status catches up", () => {
    const manager = new SessionManager(() => {});
    manager.create(
      "/tmp/project-codex",
      undefined,
      undefined,
      undefined,
      "codex",
    );
    const pendingPermission = {
      toolUseId: "plan-approval-1",
      toolName: "ExitPlanMode",
      input: { plan: "Implement the change" },
    };
    (
      codexInstances[0] as unknown as {
        getPendingPermission: () => typeof pendingPermission;
      }
    ).getPendingPermission = vi.fn(() => pendingPermission);

    expect(manager.list()[0]).toMatchObject({
      status: "starting",
      pendingPermission,
    });
  });

  it("keeps unknown Codex permissions non-authoritative until runtime init", async () => {
    const onSessionUpdated = vi.fn();
    const manager = new SessionManager(
      () => {},
      undefined,
      undefined,
      undefined,
      undefined,
      onSessionUpdated,
    );
    manager.create(
      "/tmp/project-codex",
      undefined,
      undefined,
      undefined,
      "codex",
      { threadId: "thread-bootstrap" },
    );

    expect(manager.list()[0]).toMatchObject({
      provider: "codex",
      claudeSessionId: "thread-bootstrap",
    });
    expect(manager.list()[0].permissionMode).toBeUndefined();
    expect(manager.list()[0].executionMode).toBeUndefined();
    expect(manager.list()[0].codexSettings?.approvalPolicy).toBeUndefined();

    codexInstances[0].emit("message", {
      type: "system",
      subtype: "init",
      sessionId: "thread-bootstrap",
      approvalPolicy: "never",
      approvalsReviewer: "user",
      sandboxMode: "danger-full-access",
    });
    await Promise.resolve();

    expect(manager.list()[0]).toMatchObject({
      permissionMode: "bypassPermissions",
      executionMode: "fullAccess",
      codexSettings: {
        approvalPolicy: "never",
        approvalsReviewer: "user",
        sandboxMode: "danger-full-access",
        codexPermissionsMode: "fullAccess",
      },
    });
    expect(onSessionUpdated).toHaveBeenCalledWith(manager.list()[0].id);
  });

  it("keeps ephemeral side chats out of the durable catalog and destroys them with the parent", () => {
    const manager = new SessionManager(() => {});
    const parentSessionId = manager.create(
      "/tmp/project-side-chat",
      undefined,
      undefined,
      undefined,
      "codex",
    );
    const childSessionId = manager.create(
      "/tmp/project-side-chat",
      undefined,
      [],
      undefined,
      "codex",
      {
        ephemeralForkFromThreadId: "parent-thread",
        excludeTurnsOnOpen: true,
        threadSource: "ccpocket_side_chat",
      },
      {
        auxiliary: {
          kind: "ephemeral_side_chat",
          parentSessionId,
        },
      },
    );

    expect(manager.list().map((session) => session.id)).toEqual([
      parentSessionId,
    ]);
    expect(
      manager.listEphemeralSideChats().map((session) => session.id),
    ).toEqual([childSessionId]);

    expect(manager.destroy(parentSessionId)).toBe(true);
    expect(manager.get(parentSessionId)).toBeUndefined();
    expect(manager.get(childSessionId)).toBeUndefined();
    expect(codexInstances[0].stop).toHaveBeenCalledOnce();
    expect(codexInstances[1].stop).toHaveBeenCalledOnce();
  });

  it("replaces a Codex runtime under a stable session id only after input_ready", async () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create(
      "/tmp/project-codex",
      undefined,
      undefined,
      undefined,
      "codex",
      { threadId: "thread-stable" },
    );
    const originalSession = manager.get(sessionId)!;
    originalSession.name = "Stable session";
    expect(
      manager.queueCodexInput(sessionId, {
        itemId: "queued-stable",
        text: "before edit",
        createdAt: "2026-07-19T00:00:00.000Z",
      }),
    ).toBe(true);

    const replacementPromise = manager.replaceCodexSession(
      sessionId,
      "/tmp/project-codex",
      [{ role: "assistant", content: [{ type: "text", text: "desktop" }] }],
      undefined,
      { threadId: "thread-stable" },
      1_000,
    );
    expect(manager.get(sessionId)).toBe(originalSession);
    expect(
      manager.updateCodexQueuedInput(
        sessionId,
        "queued-stable",
        "edited during bootstrap",
      ),
    ).toBe(true);

    codexInstances[1].emit("input_ready");
    await expect(replacementPromise).resolves.toBe(sessionId);

    const replacement = manager.get(sessionId)!;
    expect(replacement).not.toBe(originalSession);
    expect(replacement.id).toBe(sessionId);
    expect(replacement.name).toBe("Stable session");
    expect(replacement.status).toBe("idle");
    expect(replacement.codexQueuedInput?.text).toBe(
      "edited during bootstrap",
    );
    expect(codexInstances[0].stop).toHaveBeenCalledOnce();
  });

  it("carries the user-echo dedup state across a Codex replacement", async () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create(
      "/tmp/project-codex",
      undefined,
      undefined,
      undefined,
      "codex",
      { threadId: "thread-dedup" },
    );
    const originalSession = manager.get(sessionId)!;
    // Live dedup state accumulated while the old runtime owned the slot.
    originalSession.codexLatestUserInput = {
      type: "user_input",
      text: "latest input",
      sessionId,
    } as (typeof originalSession)["codexLatestUserInput"];
    originalSession.pendingCodexUserEchoUuids = new Set([
      "ccpocket-codex-user-turn-00000001",
    ]);
    originalSession.codexUserTurnUuidByRawId = new Map([
      ["raw-live-1", "ccpocket-codex-user-turn-00000001"],
    ]);

    const replacementPromise = manager.replaceCodexSession(
      sessionId,
      "/tmp/project-codex",
      [{ role: "assistant", content: [{ type: "text", text: "desktop" }] }],
      undefined,
      { threadId: "thread-dedup" },
      1_000,
    );
    codexInstances[1].emit("input_ready");
    await expect(replacementPromise).resolves.toBe(sessionId);

    const replacement = manager.get(sessionId)!;
    expect(replacement).not.toBe(originalSession);
    // Without these, the app-server echo of an already-published user turn
    // is treated as a brand-new message — the "duplicated twice" symptom.
    expect(replacement.codexLatestUserInput?.text).toBe("latest input");
    expect(
      replacement.pendingCodexUserEchoUuids?.has(
        "ccpocket-codex-user-turn-00000001",
      ),
    ).toBe(true);
    expect(replacement.codexUserTurnUuidByRawId?.get("raw-live-1")).toBe(
      "ccpocket-codex-user-turn-00000001",
    );
  });

  it("keeps the old Codex runtime when a staged replacement exits", async () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create(
      "/tmp/project-codex",
      undefined,
      undefined,
      undefined,
      "codex",
      { threadId: "thread-stable" },
    );
    const originalSession = manager.get(sessionId)!;

    const replacementPromise = manager.replaceCodexSession(
      sessionId,
      "/tmp/project-codex",
      [],
      undefined,
      { threadId: "thread-stable" },
      1_000,
    );
    codexInstances[1].emit("exit", 1);

    await expect(replacementPromise).rejects.toThrow(
      "exited before it became ready",
    );
    expect(manager.get(sessionId)).toBe(originalSession);
    expect(codexInstances[0].stop).not.toHaveBeenCalled();
    expect(codexInstances[1].stop).toHaveBeenCalledOnce();
  });

  it("keeps the old runtime when continuity epoch changes before input_ready", async () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create(
      "/tmp/project-codex",
      undefined,
      undefined,
      undefined,
      "codex",
      { threadId: "thread-stable" },
    );
    const originalSession = manager.get(sessionId)!;
    let stillValid = true;

    const replacementPromise = manager.replaceCodexSession(
      sessionId,
      "/tmp/project-codex",
      [],
      undefined,
      { threadId: "thread-stable" },
      1_000,
      () => stillValid,
    );
    stillValid = false;
    codexInstances[1].emit("input_ready");

    await expect(replacementPromise).rejects.toThrow(
      "invalidated before it became ready",
    );
    expect(manager.get(sessionId)).toBe(originalSession);
    expect(codexInstances[0].stop).not.toHaveBeenCalled();
    expect(codexInstances[1].stop).toHaveBeenCalledOnce();
  });

  it("never drains a continuity queue at replacement input_ready", async () => {
    const onBlocked = vi.fn();
    const manager = new SessionManager(
      () => {},
      undefined,
      undefined,
      undefined,
      undefined,
      undefined,
      undefined,
      { canDrain: () => false, onBlocked },
    );
    const sessionId = manager.create(
      "/tmp/project-codex",
      undefined,
      undefined,
      undefined,
      "codex",
      { threadId: "thread-stable" },
    );
    manager.queueCodexInput(sessionId, {
      itemId: "queued-race",
      text: "must stay queued",
      createdAt: "2026-07-20T00:00:00.000Z",
    });
    let guardCalls = 0;
    const replacementPromise = manager.replaceCodexSession(
      sessionId,
      "/tmp/project-codex",
      [],
      undefined,
      { threadId: "thread-stable" },
      1_000,
      () => ++guardCalls === 1,
    );
    codexInstances[1].isWaitingForInput = true;
    codexInstances[1].emit("input_ready");

    await expect(replacementPromise).resolves.toBe(sessionId);
    expect(manager.get(sessionId)?.codexQueuedInput?.itemId).toBe(
      "queued-race",
    );
    expect(codexInstances[1].sendInputStructured).not.toHaveBeenCalled();
    expect(onBlocked).toHaveBeenCalledOnce();
  });

  it("re-derives permissions after incremental runtime settings", () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create(
      "/tmp/project-codex-permissions",
      undefined,
      undefined,
      undefined,
      "codex",
      {
        codexPermissionsMode: "default",
        approvalPolicy: "on-request",
        sandboxMode: "workspace-write",
      },
    );

    codexInstances[0].emit("message", {
      type: "system",
      subtype: "init",
      approvalPolicy: "on-request",
      sandboxMode: "read-only",
    });

    expect(
      manager.get(sessionId)?.codexSettings?.codexPermissionsMode,
    ).toBeUndefined();
    expect(manager.list()[0].codexSettings?.codexPermissionsMode).toBe(
      "custom",
    );
  });

  it("caches codex plugin completion metadata", () => {
    const manager = new SessionManager(() => {});
    manager.create(
      "/tmp/project-codex",
      undefined,
      undefined,
      undefined,
      "codex",
    );

    codexInstances[0].emit("message", {
      type: "system",
      subtype: "supported_commands",
      plugins: ["sample"],
      pluginMetadata: [
        {
          id: "sample@test",
          name: "sample",
          path: "plugin://sample@test",
          marketplaceName: "test",
          installed: true,
          enabled: true,
        },
      ],
    } satisfies ServerMessage);

    expect(
      manager.getCachedCommands("codex", "/tmp/project-codex"),
    ).toMatchObject({
      plugins: ["sample"],
      pluginMetadata: [
        expect.objectContaining({
          id: "sample@test",
          path: "plugin://sample@test",
        }),
      ],
    });
  });

  it("separates completion caches by provider", () => {
    const manager = new SessionManager(() => {});
    manager.create(
      "/tmp/shared-project",
      undefined,
      undefined,
      undefined,
      "codex",
    );
    manager.create(
      "/tmp/shared-project",
      undefined,
      undefined,
      undefined,
      "claude",
    );

    codexInstances[0].emit("message", {
      type: "system",
      subtype: "supported_commands",
      skills: ["codex-skill"],
    } satisfies ServerMessage);
    sdkInstances[0].emit("message", {
      type: "system",
      subtype: "supported_commands",
      slashCommands: ["claude-command"],
    } satisfies ServerMessage);

    expect(
      manager.getCachedCommands("codex", "/tmp/shared-project")?.skills,
    ).toEqual(["codex-skill"]);
    expect(
      manager.getCachedCommands("claude", "/tmp/shared-project")
        ?.slashCommands,
    ).toEqual(["claude-command"]);
  });

  it("keys completion caches by the effective worktree cwd", () => {
    const manager = new SessionManager(() => {});
    manager.create(
      "/tmp/base-project",
      undefined,
      undefined,
      { existingWorktreePath: "/tmp/project-worktree" },
      "codex",
    );

    codexInstances[0].emit("message", {
      type: "system",
      subtype: "supported_commands",
      skills: ["worktree-skill"],
    } satisfies ServerMessage);

    expect(
      manager.getCachedCommands("codex", "/tmp/project-worktree")?.skills,
    ).toEqual(["worktree-skill"]);
    expect(
      manager.getCachedCommands("codex", "/tmp/base-project"),
    ).toBeUndefined();
  });

  it("replaces cached completion entities with an empty snapshot", () => {
    const manager = new SessionManager(() => {});
    manager.create(
      "/tmp/project-empty",
      undefined,
      undefined,
      undefined,
      "codex",
    );

    codexInstances[0].emit("message", {
      type: "system",
      subtype: "supported_commands",
      skills: ["removed-skill"],
    } satisfies ServerMessage);
    codexInstances[0].emit("message", {
      type: "system",
      subtype: "supported_commands",
      slashCommands: [],
      skills: [],
      skillMetadata: [],
      apps: [],
      appMetadata: [],
      plugins: [],
      pluginMetadata: [],
    } satisfies ServerMessage);

    expect(manager.getCachedCommands("codex", "/tmp/project-empty")).toEqual({
      slashCommands: [],
      skills: [],
      skillMetadata: [],
      apps: [],
      appMetadata: [],
      plugins: [],
      pluginMetadata: [],
    });
  });

  it("stores codex additional writable roots for resume metadata", () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create(
      "/tmp/project-codex",
      undefined,
      undefined,
      undefined,
      "codex",
      {
        additionalWritableRoots: ["/tmp/shared"],
      },
    );

    expect(codexInstances[0].start).toHaveBeenCalledWith(
      "/tmp/project-codex",
      expect.objectContaining({
        additionalWritableRoots: ["/tmp/shared"],
      }),
    );
    expect(manager.get(sessionId)?.codexSettings).toMatchObject({
      additionalWritableRoots: ["/tmp/shared"],
    });
  });

  it("returns only newer retained history entries for a history delta", () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create("/tmp/project-history-delta");

    const first = manager.appendHistory(sessionId, {
      type: "status",
      status: "running",
    } as ServerMessage);
    const second = manager.appendHistory(sessionId, {
      type: "assistant",
      message: {
        id: "msg-1",
        role: "assistant",
        content: [{ type: "text", text: "hello" }],
        model: "test",
      },
    } as ServerMessage);

    const result = manager.getHistorySince(sessionId, first?.seq ?? 0);

    expect(result).toMatchObject({
      kind: "delta",
      fromSeq: second?.seq,
      toSeq: second?.seq,
    });
    expect(result?.entries).toHaveLength(1);
    expect(result?.entries[0]).toMatchObject({
      seq: second?.seq,
      message: { type: "assistant" },
    });
    const receivedAt = result?.entries[0]?.message.receivedAt;
    expect(receivedAt).toBe(second?.message.receivedAt);
    expect(receivedAt).toEqual(expect.any(String));
    expect(Number.isNaN(Date.parse(receivedAt ?? ""))).toBe(false);
  });

  it("returns a history snapshot when the requested sequence was compacted", () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create("/tmp/project-history-snapshot");

    for (let i = 0; i < 105; i++) {
      manager.appendHistory(sessionId, {
        type: "status",
        status: i % 2 === 0 ? "running" : "idle",
      } as ServerMessage);
    }

    const session = manager.get(sessionId);
    const result = manager.getHistorySince(sessionId, 0);

    expect(session?.history).toHaveLength(100);
    expect(result).toMatchObject({
      kind: "snapshot",
      fromSeq: 6,
      toSeq: 105,
      reason: "compacted",
    });
    expect(result?.entries).toHaveLength(100);
    expect(result?.entries[0].seq).toBe(6);
  });

  it("trims history as a chronological tail instead of preserving only user inputs", () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create("/tmp/project-history-tail");

    for (let i = 0; i < 60; i++) {
      manager.appendHistory(sessionId, {
        type: "user_input",
        text: `question ${i}`,
      } as ServerMessage);
      manager.appendHistory(sessionId, {
        type: "assistant",
        message: {
          id: `answer-${i}`,
          role: "assistant",
          content: [{ type: "text", text: `answer ${i}` }],
          model: "test",
        },
      } as ServerMessage);
    }

    const session = manager.get(sessionId);
    const result = manager.getHistorySince(sessionId, 0);

    expect(session?.history).toHaveLength(100);
    expect(result).toMatchObject({
      kind: "snapshot",
      fromSeq: 21,
      toSeq: 120,
    });
    expect(result?.entries.map((entry) => entry.seq)).toEqual(
      Array.from({ length: 100 }, (_, i) => i + 21),
    );
    expect(
      result?.entries.slice(0, 6).map((entry) => entry.message.type),
    ).toEqual([
      "user_input",
      "assistant",
      "user_input",
      "assistant",
      "user_input",
      "assistant",
    ]);
  });

  it("retains the latest Codex user anchor after history compaction", () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create(
      "/tmp/project-codex-history-anchor",
      undefined,
      undefined,
      undefined,
      "codex",
    );
    manager.appendHistory(sessionId, {
      type: "user_input",
      text: "delegate this task",
      userMessageUuid: "codex:user-turn:1",
    });
    for (let index = 0; index < 100; index++) {
      manager.appendHistory(sessionId, {
        type: "status",
        status: index % 2 === 0 ? "running" : "idle",
      });
    }

    const session = manager.get(sessionId);
    expect(session?.history).toHaveLength(100);
    expect(session?.history.some((message) => message.type === "user_input"))
      .toBe(false);
    expect(session?.codexLatestUserInput).toMatchObject({
      type: "user_input",
      text: "delegate this task",
      userMessageUuid: "codex:user-turn:1",
    });
  });

  it("keeps history delta sequences isolated per running session", () => {
    const manager = new SessionManager(() => {});
    const sessionA = manager.create("/tmp/project-history-a");
    const sessionB = manager.create("/tmp/project-history-b");

    manager.appendHistory(sessionA, {
      type: "status",
      status: "running",
    } as ServerMessage);
    manager.appendHistory(sessionB, {
      type: "status",
      status: "running",
    } as ServerMessage);
    manager.appendHistory(sessionA, {
      type: "status",
      status: "idle",
    } as ServerMessage);

    expect(manager.getHistorySince(sessionA, 0)?.toSeq).toBe(2);
    expect(manager.getHistorySince(sessionB, 0)?.toSeq).toBe(1);
  });

  it("updates codex session settings and broadcasts the resolved thread id", () => {
    const onSessionUpdated = vi.fn();
    const manager = new SessionManager(
      () => {},
      undefined,
      undefined,
      undefined,
      undefined,
      onSessionUpdated,
    );
    const sessionId = manager.create(
      "/tmp/project-codex",
      undefined,
      undefined,
      undefined,
      "codex",
      {
        sandboxMode: "workspace-write",
      },
    );

    codexInstances[0].emit("message", {
      type: "system",
      subtype: "init",
      provider: "codex",
      sessionId: "thread-runtime",
      model: "gpt-5.4",
      approvalPolicy: "never",
      sandboxMode: "workspace-write",
      networkAccessEnabled: false,
    });
    codexInstances[0].emit("message", {
      type: "assistant",
      message: {
        id: "msg_1",
        role: "assistant",
        model: "gpt-5.4",
        content: [],
      },
    });

    const session = manager.get(sessionId);
    expect(session?.claudeSessionId).toBe("thread-runtime");
    expect(onSessionUpdated).toHaveBeenCalledOnce();
    expect(onSessionUpdated).toHaveBeenCalledWith(sessionId);
    expect(session?.codexSettings).toMatchObject({
      model: "gpt-5.4",
      approvalPolicy: "never",
      sandboxMode: "workspace-write",
      networkAccessEnabled: false,
    });
  });

  it("rebroadcasts per-runtime permission capability after its probe", () => {
    const onSessionUpdated = vi.fn();
    const manager = new SessionManager(
      () => {},
      undefined,
      undefined,
      undefined,
      undefined,
      onSessionUpdated,
    );
    const sessionId = manager.create(
      "/tmp/project-codex-capability",
      undefined,
      undefined,
      undefined,
      "codex",
    );
    const proc = codexInstances[0];

    expect(
      manager.list().find((entry) => entry.id === sessionId)
        ?.codexPermissionApplyStrategySupported,
    ).toBe(false);
    proc.supportsNextTurnPermissionUpdates = true;
    proc.emit("message", {
      type: "system",
      subtype: "runtime_capabilities",
      provider: "codex",
    });

    expect(onSessionUpdated).toHaveBeenCalledOnce();
    expect(onSessionUpdated).toHaveBeenCalledWith(sessionId);
    expect(
      manager.list().find((entry) => entry.id === sessionId)
        ?.codexPermissionApplyStrategySupported,
    ).toBe(true);
  });

  it("rebroadcasts exact native Plan capability for the owning runtime", () => {
    const onSessionUpdated = vi.fn();
    const manager = new SessionManager(
      () => {},
      undefined,
      undefined,
      undefined,
      undefined,
      onSessionUpdated,
    );
    const sessionId = manager.create(
      "/tmp/project-codex-plan-capability",
      undefined,
      undefined,
      undefined,
      "codex",
    );
    const proc = codexInstances[0];

    expect(
      manager.list().find((entry) => entry.id === sessionId)
        ?.codexNativePlanModeSupported,
    ).toBeUndefined();
    proc.nativePlanModeCapabilityKnown = true;
    proc.supportsNativePlanMode = true;
    proc.emit("message", {
      type: "system",
      subtype: "runtime_capabilities",
      provider: "codex",
      codexNativePlanModeSupported: true,
    });

    expect(onSessionUpdated).toHaveBeenCalledOnce();
    expect(onSessionUpdated).toHaveBeenCalledWith(sessionId);
    expect(
      manager.list().find((entry) => entry.id === sessionId)
        ?.codexNativePlanModeSupported,
    ).toBe(true);
  });

  it("keeps Goal notifications monotonic and out of chat history", async () => {
    const forwarded: ServerMessage[] = [];
    const manager = new SessionManager((_sessionId, msg) => {
      forwarded.push(msg);
    });
    const sessionId = manager.create(
      "/tmp/project-codex-goal-notification",
      undefined,
      undefined,
      undefined,
      "codex",
    );
    const proc = codexInstances[0];
    const baseGoal = {
      threadId: "thread-goal",
      objective: "Newest objective",
      status: "active" as const,
      tokenBudget: null,
      tokensUsed: 0,
      timeUsedSeconds: 0,
      createdAt: 1,
      updatedAt: 10,
    };

    proc.emit("message", { type: "goal_state", goal: baseGoal });
    proc.emit("message", {
      type: "goal_state",
      goal: { ...baseGoal, objective: "Stale objective", updatedAt: 9 },
    });
    await Promise.resolve();

    expect(manager.get(sessionId)?.codexGoal).toEqual(baseGoal);
    expect(forwarded.filter((msg) => msg.type === "goal_state")).toEqual([
      { type: "goal_state", goal: baseGoal },
    ]);
    expect(manager.get(sessionId)?.history).toEqual([]);
  });

  it("orders same-second Goal clear and recreate events by Bridge sequence", async () => {
    const forwarded: ServerMessage[] = [];
    const manager = new SessionManager((_sessionId, msg) => {
      forwarded.push(msg);
    });
    const sessionId = manager.create(
      "/tmp/project-codex-goal-sequence",
      undefined,
      undefined,
      undefined,
      "codex",
    );
    const proc = codexInstances[0];
    const first = {
      threadId: "thread-goal",
      objective: "First Goal",
      status: "active" as const,
      tokenBudget: null,
      tokensUsed: 0,
      timeUsedSeconds: 0,
      createdAt: 1,
      updatedAt: 10,
    };
    const recreated = { ...first, objective: "Recreated in same second" };

    proc.emit("message", {
      type: "goal_state",
      goal: first,
      goalOperationSequence: 1,
    });
    proc.emit("message", {
      type: "goal_state",
      goal: null,
      goalOperationSequence: 2,
    });
    proc.emit("message", {
      type: "goal_state",
      goal: recreated,
      goalOperationSequence: 3,
    });
    proc.emit("message", {
      type: "goal_state",
      goal: null,
      goalOperationSequence: 2,
    });
    proc.emit("message", {
      type: "goal_state",
      goal: first,
      goalOperationSequence: 1,
    });
    await Promise.resolve();

    expect(manager.get(sessionId)?.codexGoal).toEqual(recreated);
    expect(manager.get(sessionId)?.codexGoalOperationSequence).toBe(3);
    expect(forwarded.filter((msg) => msg.type === "goal_state")).toEqual([
      { type: "goal_state", goal: first, goalOperationSequence: 1 },
      { type: "goal_state", goal: null, goalOperationSequence: 2 },
      { type: "goal_state", goal: recreated, goalOperationSequence: 3 },
    ]);
  });

  it("omits unknown Goal capability and exposes a probed value", () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create(
      "/tmp/project-codex-goal-capability",
      undefined,
      undefined,
      undefined,
      "codex",
    );
    const unknown = manager.list().find((entry) => entry.id === sessionId);
    expect(unknown).not.toHaveProperty("codexGoalControlSupported");

    const session = manager.get(sessionId)!;
    session.codexGoalControlSupported = false;
    expect(
      manager.list().find((entry) => entry.id === sessionId)
        ?.codexGoalControlSupported,
    ).toBe(false);
  });

  it("ignores placeholder codex model names from runtime messages", () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create(
      "/tmp/project-codex",
      undefined,
      undefined,
      undefined,
      "codex",
    );

    codexInstances[0].emit("message", {
      type: "system",
      subtype: "init",
      provider: "codex",
      sessionId: "thread-runtime",
      model: "codex",
      sandboxMode: "workspace-write",
    });
    codexInstances[0].emit("message", {
      type: "assistant",
      message: {
        id: "msg_1",
        role: "assistant",
        model: "codex",
        content: [],
      },
    });

    const session = manager.get(sessionId);
    expect(session?.codexSettings?.model).toBeUndefined();
  });

  it("uses existing worktree path as cwd for codex resume sessions", () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create(
      "/tmp/project-main",
      undefined,
      [
        {
          role: "user",
          content: [{ type: "text", text: "resume from worktree" }],
        },
      ],
      {
        existingWorktreePath: "/tmp/project-main-worktrees/feature-x",
        worktreeBranch: "feature/x",
      },
      "codex",
      {
        threadId: "thread-worktree",
        sandboxMode: "workspace-write",
      },
    );

    expect(codexInstances).toHaveLength(1);
    expect(codexInstances[0].start).toHaveBeenCalledTimes(1);
    expect(codexInstances[0].start).toHaveBeenCalledWith(
      "/tmp/project-main-worktrees/feature-x",
      expect.objectContaining({
        threadId: "thread-worktree",
        sandboxMode: "workspace-write",
      }),
    );

    const session = manager.get(sessionId);
    expect(session?.projectPath).toBe("/tmp/project-main");
    expect(session?.worktreePath).toBe("/tmp/project-main-worktrees/feature-x");
    expect(session?.worktreeBranch).toBe("feature/x");
  });

  it("stores codex worktree mapping when threadId is known at start", () => {
    const setMapping = vi.fn();
    const manager = new SessionManager(
      () => {},
      undefined,
      undefined,
      undefined,
      { get: vi.fn(), set: setMapping } as any,
    );

    manager.create(
      "/tmp/project-main",
      undefined,
      undefined,
      {
        existingWorktreePath: "/tmp/project-main-worktrees/feature-y",
        worktreeBranch: "feature/y",
      },
      "codex",
      {
        threadId: "thread-with-worktree",
        sandboxMode: "workspace-write",
      },
    );

    expect(setMapping).toHaveBeenCalledWith("thread-with-worktree", {
      worktreePath: "/tmp/project-main-worktrees/feature-y",
      worktreeBranch: "feature/y",
      projectPath: "/tmp/project-main",
    });
  });

  it("updates status from process events and sets idle on exit", () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create(
      "/tmp/project-codex",
      undefined,
      undefined,
      undefined,
      "codex",
    );
    const proc = codexInstances[0];
    const session = manager.get(sessionId);
    expect(session?.status).toBe("starting");

    proc.emit("status", "running" satisfies ProcessStatus);
    expect(manager.get(sessionId)?.status).toBe("running");

    proc.emit("exit", 0);
    const afterExit = manager.get(sessionId);
    expect(afterExit?.status).toBe("idle");
    expect(afterExit?.history.at(-1)).toMatchObject({
      type: "status",
      status: "idle",
      historySeq: 1,
    });
  });

  it("evicts the least recently active idle session above the retention limit", () => {
    const onSessionUpdated = vi.fn();
    const manager = new SessionManager(
      () => {},
      undefined,
      undefined,
      undefined,
      undefined,
      onSessionUpdated,
    );
    const sessionIds = Array.from({ length: 31 }, (_, index) => {
      const id = manager.create(
        `/tmp/project-idle-${index}`,
        undefined,
        undefined,
        undefined,
        "codex",
      );
      manager.get(id)!.lastActivityAt = new Date(index * 1000);
      return id;
    });

    for (const process of codexInstances) {
      process.emit("status", "idle" satisfies ProcessStatus);
    }

    expect(manager.get(sessionIds[0])).toBeUndefined();
    expect(codexInstances[0].stop).toHaveBeenCalledOnce();
    expect(manager.get(sessionIds[1])).toBeDefined();
    expect(manager.list()).toHaveLength(30);
    expect(onSessionUpdated).toHaveBeenCalledOnce();
    manager.destroyAll();
  });

  it("includes codex agent metadata in session summaries", () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create(
      "/tmp/project-codex",
      undefined,
      undefined,
      undefined,
      "codex",
    );
    const proc = codexInstances[0] as (typeof codexInstances)[number] & {
      agentNickname?: string;
      agentRole?: string;
    };
    proc.agentNickname = "Atlas";
    proc.agentRole = "explorer";

    const summary = manager.list().find((entry) => entry.id == sessionId);
    expect(summary?.agentNickname).toBe("Atlas");
    expect(summary?.agentRole).toBe("explorer");
  });

  it("counts past messages and excludes streaming deltas from history", () => {
    const forwarded: Array<{ sessionId: string; msg: ServerMessage }> = [];
    const manager = new SessionManager((sessionId, msg) => {
      forwarded.push({ sessionId, msg });
    });

    const sessionId = manager.create(
      "/tmp/project-codex",
      undefined,
      [
        { role: "user", content: [{ type: "text", text: "old question" }] },
        { role: "assistant", content: [{ type: "text", text: "old answer" }] },
      ],
      undefined,
      "codex",
    );

    const proc = codexInstances[0];
    proc.emit("message", {
      type: "stream_delta",
      text: "partial",
    } satisfies ServerMessage);
    proc.emit("message", {
      type: "assistant",
      message: {
        id: "a1",
        role: "assistant",
        content: [{ type: "text", text: "new answer" }],
        model: "codex",
      },
    } satisfies ServerMessage);

    const session = manager.get(sessionId);
    expect(session?.history).toHaveLength(1);
    expect(session?.history[0].type).toBe("assistant");
    expect(forwarded).toHaveLength(2);

    const summary = manager.list().find((s) => s.id === sessionId);
    expect(summary).toBeDefined();
  });

  it("drains queued codex input when the process becomes ready", () => {
    const forwarded: Array<{ sessionId: string; msg: ServerMessage }> = [];
    const manager = new SessionManager((sessionId, msg) => {
      forwarded.push({ sessionId, msg });
    });

    const sessionId = manager.create(
      "/tmp/project-codex",
      undefined,
      undefined,
      undefined,
      "codex",
    );
    const queued = manager.queueCodexInput(sessionId, {
      itemId: "queued-1",
      text: "Follow up",
      createdAt: "2026-04-25T00:00:00.000Z",
      clientMessageId: "mobile-queued-1",
      imageCount: 1,
      images: [{ base64: "aGVsbG8=", mimeType: "image/png" }],
      imageRefs: [{ id: "img-1", url: "/images/img-1", mimeType: "image/png" }],
      skills: [{ name: "skill", path: "/skills/skill" }],
      mentions: [{ name: "note", path: "/tmp/note.md" }],
    });
    expect(queued).toBe(true);

    const proc = codexInstances[0];
    proc.isWaitingForInput = true;
    proc.emit("input_ready");

    expect(manager.get(sessionId)?.codexQueuedInput).toBeUndefined();
    expect(
      manager.list().find((s) => s.id === sessionId)?.queuedInput,
    ).toBeUndefined();
    expect(proc.sendInputStructured).toHaveBeenCalledWith("Follow up", {
      images: [{ base64: "aGVsbG8=", mimeType: "image/png" }],
      skills: [{ name: "skill", path: "/skills/skill" }],
      mentions: [{ name: "note", path: "/tmp/note.md" }],
      clientMessageId: "mobile-queued-1",
    });

    const queueMessages = forwarded
      .filter((entry) => entry.msg.type === "conversation_queue")
      .map(
        (entry) =>
          entry.msg as Extract<ServerMessage, { type: "conversation_queue" }>,
      );
    expect(queueMessages).toHaveLength(2);
    expect(queueMessages[0].items).toHaveLength(1);
    expect(queueMessages[1].items).toEqual([]);

    expect(
      forwarded.some(
        (entry) =>
          entry.sessionId === sessionId &&
          entry.msg.type === "user_input" &&
          entry.msg.text === "Follow up" &&
          entry.msg.clientMessageId === "mobile-queued-1" &&
          "imageCount" in entry.msg &&
          entry.msg.imageCount === 1,
      ),
    ).toBe(true);
  });

  it("guards both input_ready and explicit Codex queue drains", () => {
    let allowDrain = false;
    const onBlocked = vi.fn();
    const manager = new SessionManager(
      () => {},
      undefined,
      undefined,
      undefined,
      undefined,
      undefined,
      undefined,
      {
        canDrain: () => allowDrain,
        onBlocked,
      },
    );
    const sessionId = manager.create(
      "/tmp/project-codex",
      undefined,
      undefined,
      undefined,
      "codex",
    );
    manager.queueCodexInput(sessionId, {
      itemId: "queued-guarded",
      text: "wait for continuity",
      createdAt: "2026-07-20T00:00:00.000Z",
    });
    const proc = codexInstances[0];
    proc.isWaitingForInput = true;

    proc.emit("input_ready");
    expect(manager.get(sessionId)?.codexQueuedInput?.itemId).toBe(
      "queued-guarded",
    );
    expect(manager.drainCodexQueuedInputIfReady(sessionId)).toBe(false);
    expect(onBlocked).toHaveBeenCalledTimes(2);
    expect(proc.sendInputStructured).not.toHaveBeenCalled();

    allowDrain = true;
    expect(manager.drainCodexQueuedInputIfReady(sessionId)).toBe(true);
    expect(proc.sendInputStructured).toHaveBeenCalledOnce();
    expect(manager.get(sessionId)?.codexQueuedInput).toBeUndefined();
  });

  it("drains a handoff queued just after input_ready", () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create(
      "/tmp/project-codex",
      undefined,
      undefined,
      undefined,
      "codex",
    );
    const proc = codexInstances[0];
    proc.isWaitingForInput = true;
    expect(
      manager.queueCodexInput(sessionId, {
        itemId: "queued-after-ready",
        text: "run after refresh",
        createdAt: "2026-07-19T00:00:00.000Z",
      }),
    ).toBe(true);

    expect(manager.drainCodexQueuedInputIfReady(sessionId)).toBe(true);
    expect(manager.get(sessionId)?.codexQueuedInput).toBeUndefined();
    expect(proc.sendInputStructured).toHaveBeenCalledWith(
      "run after refresh",
      expect.any(Object),
    );
  });

  it("keeps delayed artifact enrichment ahead of result and queued input drain", async () => {
    let markRegistrationStarted!: (input: any) => void;
    const registrationStarted = new Promise<any>((resolve) => {
      markRegistrationStarted = resolve;
    });
    let releaseRegistration!: () => void;
    const registrationGate = new Promise<void>((resolve) => {
      releaseRegistration = resolve;
    });
    const artifactManager = {
      registerCandidates: vi.fn(async (input: any) => {
        markRegistrationStarted(input);
        await registrationGate;
        return [
          {
            id: "artifact-delayed",
            filename: "report.md",
            mimeType: "text/markdown",
            sizeBytes: 12,
            kind: "source",
            source: "assistant_markdown",
            originalHref: "/tmp/project-codex/report.md",
            textContentIndex: 0,
          },
        ];
      }),
    };
    const forwarded: Array<{ sessionId: string; msg: ServerMessage }> = [];
    let markQueuedInputPromoted!: () => void;
    const queuedInputPromoted = new Promise<void>((resolve) => {
      markQueuedInputPromoted = resolve;
    });
    const manager = new SessionManager(
      (sessionId, msg) => {
        forwarded.push({ sessionId, msg });
        if (msg.type === "user_input" && msg.text === "queued follow-up") {
          markQueuedInputPromoted();
        }
      },
      undefined,
      undefined,
      undefined,
      undefined,
      undefined,
      artifactManager as any,
    );
    const sessionId = manager.create(
      "/tmp/project-codex",
      undefined,
      undefined,
      undefined,
      "codex",
    );
    const proc = codexInstances[0];
    proc.emit("message", {
      type: "system",
      subtype: "init",
      sessionId: "thread-stable-owner",
    } satisfies ServerMessage);
    expect(
      manager.queueCodexInput(sessionId, {
        itemId: "queued-after-result",
        text: "queued follow-up",
        createdAt: "2026-07-16T05:00:00.000Z",
      }),
    ).toBe(true);
    forwarded.length = 0;

    proc.emit("message", {
      type: "assistant",
      message: {
        id: "assistant-delayed",
        role: "assistant",
        content: [
          {
            type: "text",
            text: "Open [report](/tmp/project-codex/report.md)",
          },
        ],
        model: "codex",
      },
    } satisfies ServerMessage);
    const registrationInput = await registrationStarted;
    proc.emit("message", {
      type: "result",
      subtype: "success",
      result: "done",
      sessionId: "thread-stable-owner",
    } satisfies ServerMessage);
    proc.isWaitingForInput = true;
    proc.emit("input_ready");

    expect(registrationInput).toMatchObject({
      ownerId: "thread-stable-owner",
      messageId: "assistant-delayed",
      cwd: "/tmp/project-codex",
    });
    expect(forwarded).toEqual([]);
    expect(proc.sendInputStructured).not.toHaveBeenCalled();

    releaseRegistration();
    await queuedInputPromoted;

    expect(forwarded.map(({ msg }) => msg.type)).toEqual([
      "assistant",
      "result",
      "conversation_queue",
      "user_input",
    ]);
    expect(forwarded[0].msg).toMatchObject({
      type: "assistant",
      artifacts: [{ id: "artifact-delayed" }],
    });
    expect(proc.sendInputStructured).toHaveBeenCalledWith(
      "queued follow-up",
      expect.objectContaining({
        images: undefined,
        skills: undefined,
        mentions: undefined,
      }),
    );
    const historyTail = manager.get(sessionId)?.history.slice(-3) ?? [];
    expect(historyTail.map((message) => message.type)).toEqual([
      "assistant",
      "result",
      "user_input",
    ]);
    expect(JSON.stringify(historyTail)).not.toContain("artifactCandidates");
    expect(JSON.stringify(forwarded)).not.toContain("artifactCandidates");
  });

  it("strips structured artifact candidates before enabled history and broadcast", async () => {
    const artifactManager = {
      registerCandidates: vi.fn(async () => [
        {
          id: "artifact-image",
          filename: "generated image.png",
          mimeType: "image/png",
          sizeBytes: 24,
          kind: "preview",
          source: "image_generation",
        },
      ]),
    };
    let markForwarded!: (message: ServerMessage) => void;
    const forwardedMessage = new Promise<ServerMessage>((resolve) => {
      markForwarded = resolve;
    });
    const manager = new SessionManager(
      (_sessionId, msg) => {
        if (msg.type === "tool_result") markForwarded(msg);
      },
      undefined,
      undefined,
      undefined,
      undefined,
      undefined,
      artifactManager as any,
    );
    const sessionId = manager.create(
      "/tmp/project-codex",
      undefined,
      undefined,
      undefined,
      "codex",
    );
    const proc = codexInstances[0];
    proc.emit("message", {
      type: "system",
      subtype: "init",
      sessionId: "thread-stable-owner",
    } satisfies ServerMessage);
    proc.emit("message", {
      type: "tool_result",
      toolUseId: "image-generation-1",
      toolName: "ImageGeneration",
      content: "status: completed",
      artifactCandidates: [
        {
          source: "image_generation",
          linkKind: "generated",
          localPath: "/tmp/project-codex/generated image.png",
        },
      ],
    } satisfies ServerMessage);

    const forwarded = await forwardedMessage;
    const historyMessage = manager.get(sessionId)?.history.at(-1);
    expect(artifactManager.registerCandidates).toHaveBeenCalledWith(
      expect.objectContaining({
        ownerId: "thread-stable-owner",
        messageId: "image-generation-1",
        candidates: [
          expect.objectContaining({
            localPath: "/tmp/project-codex/generated image.png",
          }),
        ],
      }),
    );
    expect(forwarded).toMatchObject({
      type: "tool_result",
      artifacts: [{ id: "artifact-image" }],
    });
    expect(historyMessage).toMatchObject({
      type: "tool_result",
      artifacts: [{ id: "artifact-image" }],
    });
    expect(JSON.stringify(forwarded)).not.toContain("artifactCandidates");
    expect(JSON.stringify(historyMessage)).not.toContain("artifactCandidates");
  });

  it("skips Markdown scanning and strips candidates when artifact manager is absent", () => {
    const forwarded: ServerMessage[] = [];
    const manager = new SessionManager((_sessionId, msg) => {
      forwarded.push(msg);
    });
    const sessionId = manager.create(
      "/tmp/project-codex",
      undefined,
      undefined,
      undefined,
      "codex",
    );
    const proc = codexInstances[0];

    proc.emit("message", {
      type: "assistant",
      message: {
        id: "assistant-disabled",
        role: "assistant",
        content: [
          {
            type: "text",
            text: "Open [report](/tmp/project-codex/report.md)",
          },
        ],
        model: "codex",
      },
    } satisfies ServerMessage);
    proc.emit("message", {
      type: "tool_result",
      toolUseId: "image-generation-disabled",
      toolName: "ImageGeneration",
      content: "status: completed",
      artifactCandidates: [
        {
          source: "image_generation",
          linkKind: "generated",
          localPath: "/tmp/project-codex/generated image.png",
        },
      ],
    } satisfies ServerMessage);

    expect(extractArtifactCandidatesMock).not.toHaveBeenCalled();
    expect(forwarded.map((message) => message.type)).toEqual([
      "assistant",
      "tool_result",
    ]);
    expect(manager.get(sessionId)?.history).toHaveLength(2);
    expect(JSON.stringify(forwarded)).not.toContain("artifactCandidates");
    expect(JSON.stringify(manager.get(sessionId)?.history)).not.toContain(
      "artifactCandidates",
    );
    expect(JSON.stringify(forwarded)).not.toContain('"artifacts"');
  });

  it("steers queued codex input and broadcasts the promoted user message", async () => {
    const forwarded: Array<{ sessionId: string; msg: ServerMessage }> = [];
    const manager = new SessionManager((sessionId, msg) => {
      forwarded.push({ sessionId, msg });
    });

    const sessionId = manager.create(
      "/tmp/project-codex",
      undefined,
      undefined,
      undefined,
      "codex",
    );
    expect(
      manager.queueCodexInput(sessionId, {
        itemId: "queued-1",
        text: "Steer this",
        createdAt: "2026-04-25T00:00:00.000Z",
        clientMessageId: "mobile-steer-1",
        skills: [{ name: "skill", path: "/skills/skill" }],
        mentions: [{ name: "note", path: "/tmp/note.md" }],
      }),
    ).toBe(true);

    const result = await manager.steerCodexQueuedInput(
      sessionId,
      "queued-1",
      "local-turn-1",
    );

    expect(result).toEqual({ ok: true });
    expect(manager.get(sessionId)?.codexQueuedInput).toBeUndefined();
    expect(codexInstances[0].steerTurnStructured).toHaveBeenCalledWith(
      "local-turn-1",
      "Steer this",
      {
        images: undefined,
        skills: [{ name: "skill", path: "/skills/skill" }],
        mentions: [{ name: "note", path: "/tmp/note.md" }],
        clientMessageId: "mobile-steer-1",
      },
    );
    expect(
      forwarded.some(
        (entry) =>
          entry.sessionId === sessionId &&
          entry.msg.type === "conversation_queue" &&
          entry.msg.items.length === 0,
      ),
    ).toBe(true);
    expect(
      forwarded.some(
        (entry) =>
          entry.sessionId === sessionId &&
          entry.msg.type === "user_input" &&
          entry.msg.text === "Steer this" &&
          entry.msg.clientMessageId === "mobile-steer-1",
      ),
    ).toBe(true);
  });

  it("keeps queued codex input when steer fails", async () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create(
      "/tmp/project-codex",
      undefined,
      undefined,
      undefined,
      "codex",
    );
    expect(
      manager.queueCodexInput(sessionId, {
        itemId: "queued-1",
        text: "Steer this",
        createdAt: "2026-04-25T00:00:00.000Z",
      }),
    ).toBe(true);
    codexInstances[0].steerTurnStructured.mockRejectedValueOnce(
      new Error("No active Codex turn to steer"),
    );

    const result = await manager.steerCodexQueuedInput(
      sessionId,
      "queued-1",
      "local-turn-1",
    );

    expect(result).toEqual({
      ok: false,
      error: "No active Codex turn to steer",
    });
    expect(manager.get(sessionId)?.codexQueuedInput?.text).toBe("Steer this");
  });

  it("does not steer when the locked turn changes before the RPC", async () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create(
      "/tmp/project-codex",
      undefined,
      undefined,
      undefined,
      "codex",
    );
    manager.queueCodexInput(sessionId, {
      itemId: "queued-stale-lock",
      text: "must not move to another turn",
      createdAt: "2026-07-20T00:00:00.000Z",
    });

    await expect(
      manager.steerCodexQueuedInput(
        sessionId,
        "queued-stale-lock",
        "local-turn-a",
        () => false,
      ),
    ).resolves.toEqual({
      ok: false,
      error: "The target turn changed before guidance was applied.",
    });
    expect(codexInstances[0].steerTurnStructured).not.toHaveBeenCalled();
    expect(manager.get(sessionId)?.codexQueuedInput?.itemId).toBe(
      "queued-stale-lock",
    );
  });

  it("does not clear an edited queue snapshot while steer RPC is in flight", async () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create(
      "/tmp/project-codex",
      undefined,
      undefined,
      undefined,
      "codex",
    );
    manager.queueCodexInput(sessionId, {
      itemId: "queued-racing-edit",
      text: "send this snapshot",
      createdAt: "2026-07-19T00:00:00.000Z",
    });
    let resolveSteer!: () => void;
    codexInstances[0].steerTurnStructured.mockImplementationOnce(
      () => new Promise<void>((resolve) => (resolveSteer = resolve)),
    );

    const steering = manager.steerCodexQueuedInput(
      sessionId,
      "queued-racing-edit",
      "local-turn-1",
    );
    expect(
      manager.updateCodexQueuedInput(
        sessionId,
        "queued-racing-edit",
        "keep this edited follow-up",
      ),
    ).toBe(true);
    resolveSteer();

    await expect(steering).resolves.toEqual({ ok: true });
    expect(manager.get(sessionId)?.codexQueuedInput?.text).toBe(
      "keep this edited follow-up",
    );
    expect(manager.get(sessionId)?.history).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          type: "user_input",
          text: "send this snapshot",
        }),
      ]),
    );
  });

  it("does not erase a replacement queue item after an in-flight steer", async () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create(
      "/tmp/project-codex",
      undefined,
      undefined,
      undefined,
      "codex",
    );
    manager.queueCodexInput(sessionId, {
      itemId: "queued-racing-cancel",
      text: "steer first",
      createdAt: "2026-07-19T00:00:00.000Z",
    });
    let resolveSteer!: () => void;
    codexInstances[0].steerTurnStructured.mockImplementationOnce(
      () => new Promise<void>((resolve) => (resolveSteer = resolve)),
    );

    const steering = manager.steerCodexQueuedInput(
      sessionId,
      "queued-racing-cancel",
      "local-turn-1",
    );
    expect(
      manager.cancelCodexQueuedInput(sessionId, "queued-racing-cancel"),
    ).toBe(true);
    expect(
      manager.queueCodexInput(sessionId, {
        itemId: "queued-replacement",
        text: "next item",
        createdAt: "2026-07-19T00:00:01.000Z",
      }),
    ).toBe(true);
    resolveSteer();

    await expect(steering).resolves.toEqual({ ok: true });
    expect(manager.get(sessionId)?.codexQueuedInput?.itemId).toBe(
      "queued-replacement",
    );
  });

  it("best-effort steers a Desktop-owned turn by authoritative turn id", async () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create(
      "/tmp/project-codex",
      undefined,
      undefined,
      undefined,
      "codex",
    );
    expect(
      manager.queueCodexInput(sessionId, {
        itemId: "queued-external",
        text: "Guide the Desktop turn",
        createdAt: "2026-07-19T00:00:00.000Z",
        clientMessageId: "mobile-guide-1",
      }),
    ).toBe(true);

    const result = await manager.steerCodexQueuedInput(
      sessionId,
      "queued-external",
      "desktop-turn-1",
    );

    expect(result).toEqual({ ok: true });
    expect(codexInstances[0].steerTurnStructured).toHaveBeenCalledWith(
      "desktop-turn-1",
      "Guide the Desktop turn",
      expect.objectContaining({ clientMessageId: "mobile-guide-1" }),
    );
    expect(manager.get(sessionId)?.codexQueuedInput).toBeUndefined();
  });

  it("extracts Codex MCP base64 images into images for history and forwarding", async () => {
    const forwarded: Array<{ sessionId: string; msg: ServerMessage }> = [];
    const imageStore = {
      extractImagePaths: vi.fn(() => []),
      registerImages: vi.fn(async () => []),
      registerFromBase64: vi.fn(() => ({
        id: "img-codex-1",
        url: "/images/img-codex-1",
        mimeType: "image/png",
      })),
    };
    const manager = new SessionManager((sessionId, msg) => {
      forwarded.push({ sessionId, msg });
    }, imageStore as any);

    const sessionId = manager.create(
      "/tmp/project-codex-images",
      undefined,
      undefined,
      undefined,
      "codex",
    );

    codexInstances[0].emit("message", {
      type: "tool_result",
      toolUseId: "mcp-img-1",
      toolName: "mcp:marionette/take_screenshots",
      content: "Generated 1 image",
      rawContentBlocks: [
        {
          type: "image",
          source: {
            type: "base64",
            data: "aGVsbG8=",
            media_type: "image/png",
          },
        },
      ],
    } as ServerMessage);

    await new Promise((resolve) => setTimeout(resolve, 0));

    const forwardedMsg = forwarded.at(-1)?.msg as
      Record<string, unknown> | undefined;
    expect(forwardedMsg).toBeDefined();
    expect(forwardedMsg?.type).toBe("tool_result");
    expect(forwardedMsg?.images).toEqual([
      {
        id: "img-codex-1",
        url: "/images/img-codex-1",
        mimeType: "image/png",
      },
    ]);
    expect(forwardedMsg).not.toHaveProperty("rawContentBlocks");

    const historyMsg = manager.get(sessionId)?.history.at(-1) as
      Record<string, unknown> | undefined;
    expect(historyMsg).toBeDefined();
    expect(historyMsg?.images).toEqual([
      {
        id: "img-codex-1",
        url: "/images/img-codex-1",
        mimeType: "image/png",
      },
    ]);
    expect(historyMsg).not.toHaveProperty("rawContentBlocks");
  });

  it("uses structured ImageGeneration paths with spaces and Unicode for images and gallery", async () => {
    const generatedPath =
      "/tmp/codex/generated_images/生成 的 image result.png";
    const stagedPath =
      "/tmp/managed-artifacts/hash/生成 的 image result.png";
    const imageRef = {
      id: "img-generated-1",
      url: "/images/img-generated-1",
      mimeType: "image/png",
    };
    const imageStore = {
      // Even if legacy text extraction returns the raw provider path, the
      // structured path must be replaced by its validated staged copy.
      extractImagePaths: vi.fn(() => ["/b.png", generatedPath]),
      registerImages: vi.fn(async () => [imageRef]),
      registerFromBase64: vi.fn(),
    };
    const galleryStore = {
      addImage: vi.fn(async () => null),
      addImageFromBase64: vi.fn(async () => null),
    };
    const artifactManager = {
      materializeGeneratedCandidates: vi.fn(async () => [stagedPath]),
      registerCandidates: vi.fn(async () => []),
    };
    let resolveForwarded!: (message: ServerMessage) => void;
    const forwarded = new Promise<ServerMessage>((resolve) => {
      resolveForwarded = resolve;
    });
    const manager = new SessionManager(
      (_sessionId, msg) => {
        if (msg.type === "tool_result") resolveForwarded(msg);
      },
      imageStore as any,
      galleryStore as any,
      undefined,
      undefined,
      undefined,
      artifactManager as any,
    );
    const sessionId = manager.create(
      "/tmp/project-codex-images",
      undefined,
      undefined,
      { existingWorktreePath: "/tmp/project-codex-images-worktree" },
      "codex",
    );

    codexInstances[0].emit("message", {
      type: "system",
      subtype: "init",
      sessionId: "thread-image-generation",
    } satisfies ServerMessage);

    codexInstances[0].emit("message", {
      type: "tool_result",
      toolUseId: "image-generation-unicode",
      toolName: "ImageGeneration",
      content: "status: completed",
      artifactCandidates: [
        {
          source: "image_generation",
          linkKind: "generated",
          localPath: generatedPath,
        },
      ],
    } satisfies ServerMessage);

    await expect(forwarded).resolves.toMatchObject({
      type: "tool_result",
      images: [imageRef],
    });
    expect(imageStore.registerImages).toHaveBeenCalledWith(
      [stagedPath],
      "/tmp/project-codex-images-worktree",
    );
    expect(galleryStore.addImage).toHaveBeenCalledWith(
      stagedPath,
      "/tmp/project-codex-images-worktree",
      sessionId,
      "thread-image-generation",
    );
    expect(artifactManager.materializeGeneratedCandidates).toHaveBeenCalledWith(
      expect.objectContaining({
        ownerId: "thread-image-generation",
        messageId: "image-generation-unicode",
        candidates: [expect.objectContaining({ localPath: generatedPath })],
      }),
    );
    expect(JSON.stringify(manager.get(sessionId)?.history)).not.toContain(
      "artifactCandidates",
    );
  });

  it("keeps legacy raw image extraction when automatic artifacts are disabled", async () => {
    const generatedPath =
      "/tmp/codex/generated_images/legacy-generated.png";
    const imageRef = {
      id: "img-legacy-1",
      url: "/images/img-legacy-1",
      mimeType: "image/png",
    };
    const imageStore = {
      extractImagePaths: vi.fn(() => [generatedPath]),
      registerImages: vi.fn(async () => [imageRef]),
      registerFromBase64: vi.fn(),
    };
    let resolveForwarded!: (message: ServerMessage) => void;
    const forwarded = new Promise<ServerMessage>((resolve) => {
      resolveForwarded = resolve;
    });
    const manager = new SessionManager(
      (_sessionId, msg) => {
        if (msg.type === "tool_result") resolveForwarded(msg);
      },
      imageStore as any,
    );
    manager.create(
      "/tmp/project-codex-images",
      undefined,
      undefined,
      undefined,
      "codex",
    );

    codexInstances[0].emit("message", {
      type: "tool_result",
      toolUseId: "image-generation-legacy",
      toolName: "ImageGeneration",
      content: `savedPath: ${generatedPath}`,
      artifactCandidates: [
        {
          source: "image_generation",
          linkKind: "generated",
          localPath: generatedPath,
        },
      ],
    } satisfies ServerMessage);

    await expect(forwarded).resolves.toMatchObject({
      type: "tool_result",
      images: [imageRef],
    });
    expect(imageStore.registerImages).toHaveBeenCalledWith(
      [generatedPath],
      "/tmp/project-codex-images",
    );
  });

  it("keeps canonical history messages when Markdown extraction throws", async () => {
    const artifactManager = {
      registerCandidates: vi.fn(async () => []),
    };
    const manager = new SessionManager(
      () => {},
      undefined,
      undefined,
      undefined,
      undefined,
      undefined,
      artifactManager as any,
    );
    const sessionId = manager.create(
      "/tmp/project-history-artifact-failure",
      undefined,
      undefined,
      undefined,
      "codex",
    );
    const session = manager.get(sessionId)!;
    session.claudeSessionId = "thread-history-artifact-failure";
    const message = {
      type: "assistant",
      message: {
        id: "assistant-history-artifact-failure",
        role: "assistant",
        content: [{ type: "text", text: "[source](src/main.ts)" }],
        model: "codex",
      },
    } satisfies ServerMessage;
    extractArtifactCandidatesMock.mockImplementationOnce(() => {
      throw new Error("lexer failed");
    });

    await expect(
      Promise.resolve(manager.enrichArtifactsForSession(session, message)),
    ).resolves.toEqual(message);
    expect(artifactManager.registerCandidates).not.toHaveBeenCalled();
  });
});

describe("SessionManager claude UUID backfill", () => {
  const registerHistoryJsonl = (
    projectLikePath: string,
    threadId: string,
    lines: string[],
  ): void => {
    const projectsDir = join(homedir(), ".claude", "projects");
    const dir = join(projectsDir, pathToSlug(projectLikePath));
    fakeDirs.add(projectsDir);
    fakeDirs.add(dir);
    fakeFiles.set(join(dir, `${threadId}.jsonl`), `${lines.join("\n")}\n`);
  };

  beforeEach(() => {
    codexInstances.length = 0;
    sdkInstances.length = 0;
    fakeDirs.clear();
    fakeFiles.clear();
  });

  it("backfills user UUIDs from worktree history jsonl", () => {
    const testId = randomUUID();
    const projectPath = `/tmp/ccpocket-main-${testId}`;
    const worktreePath = `/tmp/ccpocket-main-${testId}-worktrees/feat`;
    const threadId = `thread-${testId}`;

    registerHistoryJsonl(worktreePath, threadId, [
      JSON.stringify({
        type: "user",
        uuid: "user-uuid-1",
        message: {
          content: [{ type: "text", text: "hello from worktree" }],
        },
      }),
    ]);

    const forwarded: ServerMessage[] = [];
    const manager = new SessionManager((_, msg) => {
      forwarded.push(msg);
    });
    const sessionId = manager.create(
      projectPath,
      undefined,
      undefined,
      { existingWorktreePath: worktreePath, worktreeBranch: "feat" },
      "claude",
    );

    const session = manager.get(sessionId);
    expect(session).toBeDefined();
    if (!session) return;

    session.claudeSessionId = threadId;
    manager.appendHistory(sessionId, {
      type: "user_input",
      text: "hello from worktree",
    } as ServerMessage);

    sdkInstances[0].emit("message", {
      type: "result",
      subtype: "success",
      sessionId: threadId,
    } satisfies ServerMessage);

    const userInput = session.history.find((msg) => msg.type === "user_input");
    expect(userInput).toBeDefined();
    expect(
      userInput && "userMessageUuid" in userInput
        ? userInput.userMessageUuid
        : undefined,
    ).toBe("user-uuid-1");
    expect(
      forwarded.some(
        (msg) =>
          msg.type === "user_input" &&
          "userMessageUuid" in msg &&
          msg.userMessageUuid === "user-uuid-1",
      ),
    ).toBe(true);
  });

  it("SDK echo merge preserves imageCount from original user_input", () => {
    const forwarded: ServerMessage[] = [];
    const manager = new SessionManager((_, msg) => {
      forwarded.push(msg);
    });
    const sessionId = manager.create("/tmp/project-merge");

    const session = manager.get(sessionId);
    expect(session).toBeDefined();
    if (!session) return;

    // Simulate websocket.ts pushing user_input with imageCount
    manager.appendHistory(sessionId, {
      type: "user_input",
      text: "check this screenshot",
      imageCount: 2,
    } as ServerMessage);

    // Simulate SDK echoing back user_input with UUID (no imageCount)
    sdkInstances[0].emit("message", {
      type: "user_input",
      text: "check this screenshot",
      userMessageUuid: "uuid-img",
    } as ServerMessage);

    // The merged entry should have BOTH userMessageUuid AND imageCount
    const merged = session.history.find(
      (msg) => msg.type === "user_input" && "userMessageUuid" in msg,
    ) as Record<string, unknown> | undefined;
    expect(merged).toBeDefined();
    expect(merged?.userMessageUuid).toBe("uuid-img");
    expect(merged?.imageCount).toBe(2);
    expect(merged?.text).toBe("check this screenshot");
  });

  it("SDK echo merge works for text-only user_input even when echo text changes", () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create("/tmp/project-merge-text");

    const session = manager.get(sessionId);
    expect(session).toBeDefined();
    if (!session) return;

    // Text-only user_input (no imageCount)
    manager.appendHistory(sessionId, {
      type: "user_input",
      text: "hello world",
    } as ServerMessage);

    // SDK echo with UUID
    sdkInstances[0].emit("message", {
      type: "user_input",
      text: "hello world normalized",
      userMessageUuid: "uuid-text",
    } as ServerMessage);

    const userInputs = session.history.filter(
      (msg) => msg.type === "user_input",
    );
    expect(userInputs).toHaveLength(1);
    const merged = userInputs[0] as Record<string, unknown> | undefined;
    expect(merged).toBeDefined();
    expect(merged?.userMessageUuid).toBe("uuid-text");
    expect(merged?.text).toBe("hello world");
  });

  it("merges Codex user echo when mobile placeholder has a synthetic UUID", () => {
    const broadcasts: Array<{ id: string; msg: ServerMessage }> = [];
    const manager = new SessionManager((id, msg) => {
      broadcasts.push({ id, msg });
    });
    const sessionId = manager.create(
      "/tmp/project-merge-codex",
      undefined,
      undefined,
      undefined,
      "codex",
    );

    const session = manager.get(sessionId);
    expect(session).toBeDefined();
    if (!session) return;

    manager.appendHistory(sessionId, {
      type: "user_input",
      text: "sync this turn",
      userMessageUuid: "codex:user-turn:1",
      clientMessageId: "cm-codex-merge",
    } as ServerMessage);

    codexInstances[0].emit("message", {
      type: "user_input",
      text: "sync this turn",
      userMessageUuid: "item-real-1",
    } as ServerMessage);

    let userInputs = session.history.filter((msg) => msg.type === "user_input");
    expect(userInputs).toHaveLength(1);
    expect(userInputs[0]).toMatchObject({
      type: "user_input",
      text: "sync this turn",
      userMessageUuid: "codex:user-turn:1",
      clientMessageId: "cm-codex-merge",
    });
    expect(broadcasts.at(-1)).toMatchObject({
      id: sessionId,
      msg: {
        type: "user_input",
        text: "sync this turn",
        userMessageUuid: "codex:user-turn:1",
        clientMessageId: "cm-codex-merge",
      },
    });

    codexInstances[0].emit("message", {
      type: "user_input",
      text: "sync this turn",
      userMessageUuid: "item-real-2",
    } as ServerMessage);

    userInputs = session.history.filter((msg) => msg.type === "user_input");
    expect(userInputs).toHaveLength(2);
    expect(userInputs[1]).toMatchObject({
      type: "user_input",
      text: "sync this turn",
      userMessageUuid: "codex:user-turn:2",
    });
  });

  it("does not merge distinct real Codex user item IDs with identical text", () => {
    const broadcasts: Array<{ id: string; msg: ServerMessage }> = [];
    const manager = new SessionManager((id, msg) => {
      broadcasts.push({ id, msg });
    });
    const sessionId = manager.create(
      "/tmp/project-distinct-codex",
      undefined,
      undefined,
      undefined,
      "codex",
    );

    const session = manager.get(sessionId);
    expect(session).toBeDefined();
    if (!session) return;

    manager.appendHistory(sessionId, {
      type: "user_input",
      text: "repeat",
      userMessageUuid: "item-real-1",
    } as ServerMessage);

    codexInstances[0].emit("message", {
      type: "user_input",
      text: "repeat",
      userMessageUuid: "item-real-2",
    } as ServerMessage);

    expect(
      session.history.filter((msg) => msg.type === "user_input"),
    ).toHaveLength(2);
    expect(
      session.history.filter((msg) => msg.type === "user_input")[1],
    ).toMatchObject({
      type: "user_input",
      text: "repeat",
      userMessageUuid: "codex:user-turn:2",
    });
    expect(broadcasts.at(-1)).toMatchObject({
      id: sessionId,
      msg: {
        type: "user_input",
        text: "repeat",
      },
    });
    expect("userMessageUuid" in (broadcasts.at(-1)?.msg ?? {})).toBe(false);
  });

  it("counts resumed Codex past messages when assigning remote user turn UUIDs", () => {
    const broadcasts: Array<{ id: string; msg: ServerMessage }> = [];
    const manager = new SessionManager((id, msg) => {
      broadcasts.push({ id, msg });
    });
    const sessionId = manager.create(
      "/tmp/project-resumed-codex",
      undefined,
      [
        {
          role: "user",
          uuid: "codex:user-turn:1",
          content: [{ type: "text", text: "old turn" }],
        },
      ],
      undefined,
      "codex",
    );

    const session = manager.get(sessionId);
    expect(session).toBeDefined();
    if (!session) return;

    codexInstances[0].emit("message", {
      type: "user_input",
      text: "remote after resume",
      userMessageUuid: "item-real-after-resume",
    } as ServerMessage);

    expect(session.history).toContainEqual(
      expect.objectContaining({
        type: "user_input",
        text: "remote after resume",
        userMessageUuid: "codex:user-turn:2",
      }),
    );
    expect(broadcasts.at(-1)).toMatchObject({
      id: sessionId,
      msg: {
        type: "user_input",
        text: "remote after resume",
      },
    });
    expect("userMessageUuid" in (broadcasts.at(-1)?.msg ?? {})).toBe(false);
  });

  it("suppresses Codex raw user echo already restored from canonical history", () => {
    const broadcasts: Array<{ id: string; msg: ServerMessage }> = [];
    const manager = new SessionManager((id, msg) => {
      broadcasts.push({ id, msg });
    });
    const sessionId = manager.create(
      "/tmp/project-canonical-codex",
      undefined,
      [
        {
          role: "user",
          uuid: "codex:user-turn:1",
          rawItemId: "raw-user-1",
          content: [{ type: "text", text: "canonical turn" }],
        },
      ],
      undefined,
      "codex",
    );

    const session = manager.get(sessionId);
    expect(session).toBeDefined();
    if (!session) return;
    expect(session.codexUserTurnUuidByRawId?.get("raw-user-1")).toBe(
      "codex:user-turn:1",
    );

    codexInstances[0].emit("message", {
      type: "user_input",
      text: "canonical turn",
      userMessageUuid: "raw-user-1",
    } as ServerMessage);

    expect(
      session.history.filter((msg) => msg.type === "user_input"),
    ).toHaveLength(0);
    expect(broadcasts).toHaveLength(0);

    codexInstances[0].emit("message", {
      type: "user_input",
      text: "next remote",
      userMessageUuid: "raw-user-2",
    } as ServerMessage);

    expect(session.history).toContainEqual(
      expect.objectContaining({
        type: "user_input",
        text: "next remote",
        userMessageUuid: "codex:user-turn:2",
      }),
    );
  });

  it("counts queued Codex input when assigning remote user turn UUIDs", () => {
    const manager = new SessionManager(() => {});
    const sessionId = manager.create(
      "/tmp/project-queued-codex",
      undefined,
      undefined,
      undefined,
      "codex",
    );

    const session = manager.get(sessionId);
    expect(session).toBeDefined();
    if (!session) return;

    manager.appendHistory(sessionId, {
      type: "user_input",
      text: "first local",
      userMessageUuid: "codex:user-turn:1",
    } as ServerMessage);
    expect(
      manager.queueCodexInput(sessionId, {
        itemId: "queued-1",
        text: "queued local",
        createdAt: "2026-05-12T10:00:00.000Z",
        userMessageUuid: "codex:user-turn:2",
      }),
    ).toBe(true);

    codexInstances[0].emit("message", {
      type: "user_input",
      text: "remote while queued",
      userMessageUuid: "item-real-queued-race",
    } as ServerMessage);

    expect(session.history).toContainEqual(
      expect.objectContaining({
        type: "user_input",
        text: "remote while queued",
        userMessageUuid: "codex:user-turn:3",
      }),
    );
  });

  it("falls back to scanning all project dirs when primary slug lookup misses", () => {
    const testId = randomUUID();
    const projectPath = `/tmp/ccpocket-main-${testId}`;
    const unrelatedPath = `/tmp/ccpocket-other-${testId}`;
    const threadId = `thread-${testId}`;

    registerHistoryJsonl(unrelatedPath, threadId, [
      JSON.stringify({
        type: "user",
        uuid: "user-uuid-fallback",
        message: {
          content: [{ type: "text", text: "fallback match" }],
        },
      }),
    ]);

    const manager = new SessionManager(() => {});
    const sessionId = manager.create(projectPath);
    const session = manager.get(sessionId);
    expect(session).toBeDefined();
    if (!session) return;

    session.claudeSessionId = threadId;
    manager.appendHistory(sessionId, {
      type: "user_input",
      text: "fallback match",
    } as ServerMessage);

    sdkInstances[0].emit("message", {
      type: "result",
      subtype: "success",
      sessionId: threadId,
    } satisfies ServerMessage);

    const userInput = session.history.find((msg) => msg.type === "user_input");
    expect(userInput).toBeDefined();
    expect(
      userInput && "userMessageUuid" in userInput
        ? userInput.userMessageUuid
        : undefined,
    ).toBe("user-uuid-fallback");
  });
});
