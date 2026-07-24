import { EventEmitter } from "node:events";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const { spawnMock, fakeChildren } = vi.hoisted(() => ({
  spawnMock: vi.fn(),
  fakeChildren: [] as FakeChildProcess[],
}));

class FakeWritable extends EventEmitter {
  public writes: string[] = [];
  write(chunk: string): boolean {
    this.writes.push(chunk);
    this.emit("write", chunk);
    return true;
  }
}

class FakeReadable extends EventEmitter {
  setEncoding(_encoding: string): void {}
}

class FakeChildProcess extends EventEmitter {
  public stdout = new FakeReadable();
  public stderr = new FakeReadable();
  public stdin = new FakeWritable();
  public killed = false;

  kill(_signal?: NodeJS.Signals): boolean {
    this.killed = true;
    this.emit("exit", 0);
    return true;
  }
}

vi.mock("node:child_process", () => ({
  spawn: spawnMock,
}));

import {
  buildCodexSpawnSpec,
  codexErrorMessage,
  CodexCoreActionPreconditionError,
  CodexProcess,
  CodexRpcError,
  createCodexGoalResumeLease,
  parseCodexGoal,
} from "./codex-process.js";
import { stopManagedCodexAppServers } from "./codex-transport.js";

const originalCodexAppServerEnv = {
  bridgePort: process.env.BRIDGE_PORT,
  mode: process.env.BRIDGE_CODEX_APP_SERVER_MODE,
  sharedUrl: process.env.BRIDGE_CODEX_SHARED_APP_SERVER_URL,
  port: process.env.BRIDGE_CODEX_APP_SERVER_PORT,
  url: process.env.BRIDGE_CODEX_APP_SERVER_URL,
};

function restoreCodexAppServerEnv(): void {
  restoreEnvVar("BRIDGE_PORT", originalCodexAppServerEnv.bridgePort);
  restoreEnvVar("BRIDGE_CODEX_APP_SERVER_MODE", originalCodexAppServerEnv.mode);
  restoreEnvVar(
    "BRIDGE_CODEX_SHARED_APP_SERVER_URL",
    originalCodexAppServerEnv.sharedUrl,
  );
  restoreEnvVar("BRIDGE_CODEX_APP_SERVER_PORT", originalCodexAppServerEnv.port);
  restoreEnvVar("BRIDGE_CODEX_APP_SERVER_URL", originalCodexAppServerEnv.url);
}

function restoreEnvVar(key: string, value: string | undefined): void {
  if (value === undefined) {
    delete process.env[key];
    return;
  }
  process.env[key] = value;
}

describe("CodexProcess (app-server)", () => {
  beforeEach(() => {
    spawnMock.mockReset();
    fakeChildren.length = 0;
    spawnMock.mockImplementation(() => {
      const child = new FakeChildProcess();
      fakeChildren.push(child);
      return child;
    });
  });

  afterEach(() => {
    stopManagedCodexAppServers();
    restoreCodexAppServerEnv();
    for (const child of fakeChildren) {
      if (!child.killed) {
        child.kill();
      }
    }
  });

  it("persists client message identity on start and steer RPCs", async () => {
    const proc = new CodexProcess("linux");
    const request = vi
      .spyOn(proc as any, "request")
      .mockResolvedValue({ turn: { id: "turn-1" } });

    await (proc as any).requestWithClientUserMessageIdFallback(
      "turn/start",
      { threadId: "thread-1", input: [{ type: "text", text: "hello" }] },
      "mobile-message-1",
    );
    expect(request).toHaveBeenNthCalledWith(1, "turn/start", {
      threadId: "thread-1",
      input: [{ type: "text", text: "hello" }],
      clientUserMessageId: "mobile-message-1",
    });

    (proc as any)._threadId = "thread-1";
    (proc as any).pendingTurnId = "turn-1";
    expect(proc.activeTurnId).toBe("turn-1");
    await proc.steerInputStructured("follow up", {
      clientMessageId: "mobile-message-2",
    });
    expect(request).toHaveBeenNthCalledWith(2, "turn/steer", {
      threadId: "thread-1",
      input: [{ type: "text", text: "follow up" }],
      expectedTurnId: "turn-1",
      clientUserMessageId: "mobile-message-2",
    });

    (proc as any).pendingTurnId = null;
    expect(proc.activeTurnId).toBeUndefined();
    await proc.steerTurnStructured("desktop-turn-1", "guide desktop", {
      clientMessageId: "mobile-message-3",
    });
    expect(request).toHaveBeenNthCalledWith(3, "turn/steer", {
      threadId: "thread-1",
      input: [{ type: "text", text: "guide desktop" }],
      expectedTurnId: "desktop-turn-1",
      clientUserMessageId: "mobile-message-3",
    });
  });

  it("sticky-downgrades client message identity for an older app-server", async () => {
    const proc = new CodexProcess("linux");
    const warning = vi.spyOn(console, "warn").mockImplementation(() => {});
    const request = vi
      .spyOn(proc as any, "request")
      .mockRejectedValueOnce(
        new CodexRpcError(
          "turn/start",
          "invalid params: unknown field clientUserMessageId",
          -32602,
        ),
      )
      .mockResolvedValue({ turn: { id: "turn-1" } });
    const params = {
      threadId: "thread-1",
      input: [{ type: "text", text: "hello" }],
    };

    await (proc as any).requestWithClientUserMessageIdFallback(
      "turn/start",
      params,
      "mobile-message-1",
    );
    await (proc as any).requestWithClientUserMessageIdFallback(
      "turn/start",
      params,
      "mobile-message-2",
    );

    expect(request.mock.calls).toEqual([
      ["turn/start", { ...params, clientUserMessageId: "mobile-message-1" }],
      ["turn/start", params],
      ["turn/start", params],
    ]);
    expect(warning).toHaveBeenCalledTimes(1);
    warning.mockRestore();
  });

  it("maps goal get, set, and clear to app-server RPCs", async () => {
    const proc = new CodexProcess("linux");
    (proc as any)._threadId = "thread-1";
    const goal = {
      threadId: "thread-1",
      objective: "Ship Goal support",
      status: "active",
      tokenBudget: null,
      tokensUsed: 12,
      timeUsedSeconds: 3,
      createdAt: 100,
      updatedAt: 101,
    };
    const request = vi
      .spyOn(proc as any, "request")
      .mockResolvedValueOnce({ goal })
      .mockResolvedValueOnce({ goal: { ...goal, status: "paused" } })
      .mockResolvedValueOnce({ cleared: true });

    await expect(proc.getGoal()).resolves.toEqual(goal);
    await expect(
      proc.setGoal({
        objective: "  Ship Goal support  ",
        status: "paused",
        tokenBudget: 12_000,
      }),
    ).resolves.toMatchObject({ status: "paused" });
    await expect(proc.clearGoal()).resolves.toBe(true);

    expect(request).toHaveBeenNthCalledWith(1, "thread/goal/get", {
      threadId: "thread-1",
    });
    expect(request).toHaveBeenNthCalledWith(2, "thread/goal/set", {
      threadId: "thread-1",
      objective: "Ship Goal support",
      status: "paused",
      tokenBudget: 12_000,
    });
    expect(request).toHaveBeenNthCalledWith(3, "thread/goal/clear", {
      threadId: "thread-1",
    });
  });

  it("persists next-turn permissions before resuming an active goal", async () => {
    const proc = new CodexProcess("linux");
    (proc as any)._threadId = "thread-next-turn";
    (proc as any)._projectPath = "/tmp/project-next-turn";
    let resolveSettings!: (value: unknown) => void;
    const settingsResponse = new Promise((resolve) => {
      resolveSettings = resolve;
    });
    const goal = {
      threadId: "thread-next-turn",
      objective: "Continue safely",
      status: "active",
      tokenBudget: null,
      tokensUsed: 0,
      timeUsedSeconds: 0,
      createdAt: 1,
      updatedAt: 2,
    };
    const request = vi
      .spyOn(proc as any, "request")
      .mockImplementationOnce(() => settingsResponse)
      .mockResolvedValueOnce({ goal });

    const settings = proc.updatePermissionSettingsForNextTurn({
      approvalPolicy: "never",
      approvalsReviewer: "user",
      codexPermissionsMode: "fullAccess",
      sandboxMode: "danger-full-access",
    });
    const resumeGoal = proc.setGoal({ status: "active" });
    await tick();

    expect(request).toHaveBeenCalledTimes(1);
    expect(request).toHaveBeenNthCalledWith(1, "thread/settings/update", {
      threadId: "thread-next-turn",
      approvalPolicy: "never",
      approvalsReviewer: "user",
      sandboxPolicy: { type: "dangerFullAccess" },
    });

    resolveSettings({});
    await settings;
    await expect(resumeGoal).resolves.toEqual(goal);
    expect(request).toHaveBeenNthCalledWith(2, "thread/goal/set", {
      threadId: "thread-next-turn",
      status: "active",
    });
  });

  it("waits for permission updates appended while a goal update is waiting", async () => {
    const proc = new CodexProcess("linux");
    (proc as any)._threadId = "thread-serial-settings";
    let resolveFirst!: (value: unknown) => void;
    let resolveSecond!: (value: unknown) => void;
    const first = new Promise((resolve) => {
      resolveFirst = resolve;
    });
    const second = new Promise((resolve) => {
      resolveSecond = resolve;
    });
    const goal = {
      threadId: "thread-serial-settings",
      objective: "Continue safely",
      status: "active",
      tokenBudget: null,
      tokensUsed: 0,
      timeUsedSeconds: 0,
      createdAt: 1,
      updatedAt: 2,
    };
    const request = vi
      .spyOn(proc as any, "request")
      .mockImplementationOnce(() => first)
      .mockImplementationOnce(() => second)
      .mockResolvedValueOnce({ goal });

    const firstUpdate = proc.updatePermissionSettingsForNextTurn({
      approvalPolicy: "on-request",
    });
    const goalUpdate = proc.setGoal({ status: "active" });
    const secondUpdate = proc.updatePermissionSettingsForNextTurn({
      approvalsReviewer: "auto_review",
    });
    resolveFirst({});
    await firstUpdate;
    await tick();

    expect(request).toHaveBeenCalledTimes(2);
    resolveSecond({});
    await secondUpdate;
    await expect(goalUpdate).resolves.toEqual(goal);
    expect(request).toHaveBeenNthCalledWith(3, "thread/goal/set", {
      threadId: "thread-serial-settings",
      status: "active",
    });
  });

  it("waits for permission updates appended while ordinary input is waiting", async () => {
    const proc = new CodexProcess("linux");
    (proc as any)._threadId = "thread-serial-input-settings";
    (proc as any)._projectPath = "/tmp/project-serial-input-settings";
    let resolveRuntime!: (value: unknown) => void;
    let resolvePermission!: (value: unknown) => void;
    const runtime = new Promise((resolve) => {
      resolveRuntime = resolve;
    });
    const permission = new Promise((resolve) => {
      resolvePermission = resolve;
    });
    const request = vi
      .spyOn(proc as any, "request")
      .mockImplementationOnce(() => runtime)
      .mockImplementationOnce(() => permission)
      .mockResolvedValueOnce({ turn: { id: "turn-serial-input" } });

    void (proc as any).runInputLoop();
    proc.setServiceTier("fast");
    const runtimeUpdate = proc.persistRuntimeServiceTierForNextTurn();
    proc.sendInput("continue after every setting is stable");
    const permissionUpdate = proc.updatePermissionSettingsForNextTurn({
      approvalPolicy: "never",
    });
    await tick();

    expect(request).toHaveBeenCalledTimes(1);
    expect(request).toHaveBeenNthCalledWith(1, "thread/settings/update", {
      threadId: "thread-serial-input-settings",
      serviceTier: "fast",
    });

    resolveRuntime({});
    await runtimeUpdate;
    await tick();
    expect(request).toHaveBeenCalledTimes(2);
    expect(request).toHaveBeenNthCalledWith(2, "thread/settings/update", {
      threadId: "thread-serial-input-settings",
      approvalPolicy: "never",
    });

    resolvePermission({});
    await permissionUpdate;
    await tick();
    expect(request).toHaveBeenCalledTimes(3);
    expect(request).toHaveBeenNthCalledWith(
      3,
      "turn/start",
      expect.objectContaining({
        threadId: "thread-serial-input-settings",
        approvalPolicy: "never",
        serviceTier: "fast",
      }),
    );

    proc.stop();
  });

  it("does not resume a goal when its pending permission update fails", async () => {
    const proc = new CodexProcess("linux");
    (proc as any)._threadId = "thread-failed-settings";
    let rejectSettings!: (error: Error) => void;
    const settings = new Promise((_, reject) => {
      rejectSettings = reject;
    });
    const request = vi
      .spyOn(proc as any, "request")
      .mockImplementationOnce(() => settings);

    const update = proc.updatePermissionSettingsForNextTurn({
      approvalPolicy: "on-request",
    });
    const goalUpdate = proc.setGoal({ status: "active" });
    rejectSettings(new Error("settings rejected"));

    await expect(update).rejects.toThrow("settings rejected");
    await expect(goalUpdate).rejects.toThrow("settings rejected");
    expect(request).toHaveBeenCalledOnce();
  });

  it("serializes next-turn permission updates and propagates unsupported RPCs", async () => {
    const proc = new CodexProcess("linux");
    (proc as any)._threadId = "thread-unsupported";
    const request = vi
      .spyOn(proc as any, "request")
      .mockRejectedValue(
        new CodexRpcError("thread/settings/update", "Method not found", -32601),
      );

    await expect(
      proc.updatePermissionSettingsForNextTurn({
        approvalPolicy: "on-request",
        approvalsReviewer: "auto_review",
        codexPermissionsMode: "autoReview",
        sandboxMode: "danger-full-access",
      }),
    ).rejects.toMatchObject({ code: -32601 });
    expect(proc.approvalPolicy).toBe("on-request");
    expect(proc.approvalsReviewer).toBe("user");
    expect(request).toHaveBeenCalledOnce();
  });

  it("sends a complete workspace sandbox policy for next-turn permissions", async () => {
    const proc = new CodexProcess("linux");
    (proc as any)._threadId = "thread-workspace";
    (proc as any)._projectPath = "/tmp/project-workspace";
    (proc as any)._additionalWritableRoots = ["/tmp/extra-root"];
    (proc as any)._networkAccessEnabled = true;
    const request = vi
      .spyOn(proc as any, "request")
      .mockResolvedValueOnce({
        config: {
          sandbox_workspace_write: {
            writable_roots: ["/tmp/config-root"],
          },
        },
      })
      .mockResolvedValueOnce({});

    await proc.updatePermissionSettingsForNextTurn({
      approvalPolicy: "on-request",
      approvalsReviewer: "auto_review",
      codexPermissionsMode: "autoReview",
      sandboxMode: "workspace-write",
    });

    expect(request).toHaveBeenNthCalledWith(2, "thread/settings/update", {
      threadId: "thread-workspace",
      approvalPolicy: "on-request",
      approvalsReviewer: "guardian_subagent",
      sandboxPolicy: {
        type: "workspaceWrite",
        writableRoots: [
          "/tmp/project-workspace",
          "/tmp/config-root",
          "/tmp/extra-root",
        ],
        networkAccess: true,
        excludeTmpdirEnvVar: false,
        excludeSlashTmp: false,
      },
    });
  });

  it("persists ultra and Fast before activating a Goal continuation", async () => {
    const proc = new CodexProcess("linux");
    (proc as any)._threadId = "thread-runtime-goal";
    let resolveModel!: (value: unknown) => void;
    let resolveSpeed!: (value: unknown) => void;
    let resolvePermission!: (value: unknown) => void;
    const modelUpdate = new Promise((resolve) => {
      resolveModel = resolve;
    });
    const speedUpdate = new Promise((resolve) => {
      resolveSpeed = resolve;
    });
    const permissionUpdate = new Promise((resolve) => {
      resolvePermission = resolve;
    });
    const goal = {
      threadId: "thread-runtime-goal",
      objective: "Continue with the selected runtime settings",
      status: "active",
      tokenBudget: null,
      tokensUsed: 0,
      timeUsedSeconds: 0,
      createdAt: 1,
      updatedAt: 2,
    };
    const request = vi
      .spyOn(proc as any, "request")
      .mockImplementationOnce(() => modelUpdate)
      .mockImplementationOnce(() => speedUpdate)
      .mockImplementationOnce(() => permissionUpdate)
      .mockResolvedValueOnce({ goal });

    proc.setModel("gpt-5.6-sol", "ultra");
    const persistedModel = proc.persistRuntimeModelForNextTurn();
    proc.setServiceTier("fast");
    const persistedSpeed = proc.persistRuntimeServiceTierForNextTurn();
    const resumedGoal = proc.setGoal({ status: "active" });
    await tick();

    expect(request).toHaveBeenCalledTimes(1);
    expect(request).toHaveBeenNthCalledWith(1, "thread/settings/update", {
      threadId: "thread-runtime-goal",
      model: "gpt-5.6-sol",
      effort: "ultra",
    });

    resolveModel({});
    await expect(persistedModel).resolves.toBe(true);
    await tick();
    expect(request).toHaveBeenNthCalledWith(2, "thread/settings/update", {
      threadId: "thread-runtime-goal",
      serviceTier: "fast",
    });
    expect(request).toHaveBeenCalledTimes(2);

    const persistedPermission = proc.updatePermissionSettingsForNextTurn({
      approvalPolicy: "never",
    });
    resolveSpeed({});
    await expect(persistedSpeed).resolves.toBe(true);
    await tick();
    expect(request).toHaveBeenNthCalledWith(3, "thread/settings/update", {
      threadId: "thread-runtime-goal",
      approvalPolicy: "never",
    });
    expect(request).toHaveBeenCalledTimes(3);

    resolvePermission({});
    await persistedPermission;
    await expect(resumedGoal).resolves.toEqual(goal);
    expect(request).toHaveBeenNthCalledWith(4, "thread/goal/set", {
      threadId: "thread-runtime-goal",
      status: "active",
    });
  });

  it("keeps turn/start fallback state when runtime fields are unsupported", async () => {
    const proc = new CodexProcess("linux");
    (proc as any)._threadId = "thread-old-runtime";
    const warning = vi.spyOn(console, "warn").mockImplementation(() => {});
    const request = vi
      .spyOn(proc as any, "request")
      .mockRejectedValue(
        new CodexRpcError(
          "thread/settings/update",
          "Invalid params: unknown field effort",
          -32602,
        ),
      );

    try {
      proc.setModel("gpt-5.6-sol", "ultra");
      proc.setServiceTier("fast");

      await expect(proc.persistRuntimeModelForNextTurn()).resolves.toBe(false);
      await expect(proc.persistRuntimeServiceTierForNextTurn()).resolves.toBe(
        false,
      );

      expect(request).toHaveBeenCalledTimes(2);
      expect(proc.model).toBe("gpt-5.6-sol");
      expect(proc.modelReasoningEffort).toBe("ultra");
      expect(proc.serviceTier).toBe("fast");
    } finally {
      warning.mockRestore();
    }
  });

  it("distinguishes confirmed settings from new-session fallbacks", () => {
    const proc = new CodexProcess("linux");

    expect(proc.model).toBe("gpt-5.5");
    expect(proc.knownModel).toBeUndefined();
    expect(proc.serviceTier).toBe("standard");
    expect(proc.knownServiceTier).toBeUndefined();

    proc.setModel("gpt-5.6-sol", "ultra");
    proc.setServiceTier("fast");

    expect(proc.knownModel).toBe("gpt-5.6-sol");
    expect(proc.knownServiceTier).toBe("fast");
  });

  it("probes next-turn permission support on the exact runtime", async () => {
    const proc = new CodexProcess("linux");
    (proc as any)._threadId = "thread-probe";
    const messages: unknown[] = [];
    proc.on("message", (message) => messages.push(message));
    const request = vi.spyOn(proc as any, "request").mockResolvedValueOnce({});

    await (proc as any).probeNextTurnPermissionUpdates();

    expect(request).toHaveBeenCalledWith("thread/settings/update", {
      threadId: "thread-probe",
    });
    expect(proc.supportsNextTurnPermissionUpdates).toBe(true);
    expect(messages).toContainEqual({
      type: "system",
      subtype: "runtime_capabilities",
      provider: "codex",
    });
  });

  it("enables native Plan mode only after collaborationMode/list advertises plan", async () => {
    const proc = new CodexProcess("linux");
    (proc as any)._threadId = "thread-plan-probe";
    const messages: unknown[] = [];
    proc.on("message", (message) => messages.push(message));
    const request = vi.spyOn(proc as any, "request").mockResolvedValue({
      data: [
        {
          name: "Plan",
          mode: "plan",
          model: null,
          reasoning_effort: null,
        },
      ],
    });

    await expect((proc as any).probeNativePlanModeSupport()).resolves.toBe(
      true,
    );

    expect(request).toHaveBeenCalledWith(
      "collaborationMode/list",
      {},
      { timeoutMs: 1500 },
    );
    expect(proc.supportsNativePlanMode).toBe(true);
    expect(messages).toContainEqual({
      type: "system",
      subtype: "runtime_capabilities",
      provider: "codex",
      sessionId: "thread-plan-probe",
      codexNativePlanModeSupported: true,
    });
    expect(() => proc.setCollaborationMode("plan")).not.toThrow();
  });

  it("fails closed when collaborationMode/list lacks a native Plan preset", async () => {
    const proc = new CodexProcess("linux");
    const messages: unknown[] = [];
    proc.on("message", (message) => messages.push(message));
    const request = vi.spyOn(proc as any, "request").mockResolvedValue({
      data: [{ name: "Default", mode: "default" }],
    });

    await expect(proc.probeNativePlanModeSupport()).resolves.toBe(false);
    await expect(proc.probeNativePlanModeSupport()).resolves.toBe(false);

    expect(request).toHaveBeenCalledOnce();
    expect(proc.nativePlanModeCapabilityKnown).toBe(true);
    expect(proc.supportsNativePlanMode).toBe(false);
    expect(messages).toContainEqual({
      type: "system",
      subtype: "runtime_capabilities",
      provider: "codex",
      codexNativePlanModeSupported: false,
    });
    expect(() => proc.setCollaborationMode("plan")).toThrow(
      "Native Codex Plan mode is unavailable",
    );
    expect(proc.collaborationMode).toBe("default");
  });

  it("shares one collaborationMode/list RPC across concurrent probes", async () => {
    const proc = new CodexProcess("linux");
    let resolveResponse!: (value: unknown) => void;
    const response = new Promise<unknown>((resolve) => {
      resolveResponse = resolve;
    });
    const request = vi
      .spyOn(proc as any, "request")
      .mockImplementation(() => response);

    const firstProbe = proc.probeNativePlanModeSupport();
    const secondProbe = proc.probeNativePlanModeSupport();

    expect(secondProbe).toBe(firstProbe);
    expect(request).toHaveBeenCalledOnce();

    resolveResponse({ data: [{ name: "Plan", mode: "plan" }] });
    await expect(Promise.all([firstProbe, secondProbe])).resolves.toEqual([
      true,
      true,
    ]);
    expect(request).toHaveBeenCalledOnce();
  });

  it("ignores a stale runtime probe without clearing the current probe", async () => {
    const proc = new CodexProcess("linux");
    const messages: unknown[] = [];
    proc.on("message", (message) => messages.push(message));
    let resolveStaleResponse!: (value: unknown) => void;
    let resolveCurrentResponse!: (value: unknown) => void;
    const staleResponse = new Promise<unknown>((resolve) => {
      resolveStaleResponse = resolve;
    });
    const currentResponse = new Promise<unknown>((resolve) => {
      resolveCurrentResponse = resolve;
    });
    const request = vi
      .spyOn(proc as any, "request")
      .mockImplementationOnce(() => staleResponse)
      .mockImplementationOnce(() => currentResponse);

    const staleProbe = proc.probeNativePlanModeSupport();
    (proc as any).prepareLaunch("/tmp/current-plan-runtime");
    const currentProbe = proc.probeNativePlanModeSupport();

    resolveStaleResponse({ data: [{ name: "Plan", mode: "plan" }] });
    await expect(staleProbe).resolves.toBe(false);

    expect(proc.nativePlanModeCapabilityKnown).toBe(false);
    expect((proc as any)._nativePlanModeProbe).toBe(currentProbe);
    expect(messages).not.toContainEqual(
      expect.objectContaining({ codexNativePlanModeSupported: true }),
    );

    resolveCurrentResponse({ data: [{ name: "Plan", mode: "plan" }] });
    await expect(currentProbe).resolves.toBe(true);

    expect(request).toHaveBeenCalledTimes(2);
    expect(proc.nativePlanModeCapabilityKnown).toBe(true);
    expect(proc.supportsNativePlanMode).toBe(true);
    expect((proc as any)._nativePlanModeProbe).toBeNull();
    expect(messages).toContainEqual(
      expect.objectContaining({ codexNativePlanModeSupported: true }),
    );
  });

  it("keeps a timed-out native Plan probe retryable and accepts a later success", async () => {
    const proc = new CodexProcess("linux");
    (proc as any)._threadId = "thread-plan-retry";
    const messages: unknown[] = [];
    proc.on("message", (message) => messages.push(message));
    const request = vi
      .spyOn(proc as any, "request")
      .mockRejectedValueOnce(
        new CodexRpcError(
          "collaborationMode/list",
          "collaborationMode/list timed out after 1500ms",
        ),
      )
      .mockResolvedValueOnce({ data: [{ name: "Plan", mode: "plan" }] });

    await expect(proc.probeNativePlanModeSupport()).resolves.toBe(false);

    expect(proc.nativePlanModeCapabilityKnown).toBe(false);
    expect(proc.supportsNativePlanMode).toBe(false);
    expect(messages).not.toContainEqual(
      expect.objectContaining({ codexNativePlanModeSupported: false }),
    );
    expect(() => proc.setCollaborationMode("plan")).toThrow(
      "could not be confirmed",
    );

    await expect(proc.probeNativePlanModeSupport()).resolves.toBe(true);

    expect(request).toHaveBeenCalledTimes(2);
    expect(proc.nativePlanModeCapabilityKnown).toBe(true);
    expect(proc.supportsNativePlanMode).toBe(true);
    expect(messages).toContainEqual({
      type: "system",
      subtype: "runtime_capabilities",
      provider: "codex",
      sessionId: "thread-plan-retry",
      codexNativePlanModeSupported: true,
    });
  });

  it("uses the longer probe window for an explicit native Plan action", async () => {
    const proc = new CodexProcess("linux");
    const request = vi.spyOn(proc as any, "request").mockResolvedValue({
      data: [{ name: "Plan", mode: "plan" }],
    });

    await expect(
      proc.confirmNativePlanModeSupportForUserAction(),
    ).resolves.toBe(true);

    expect(request).toHaveBeenCalledWith(
      "collaborationMode/list",
      {},
      { timeoutMs: 5000 },
    );
  });

  it("caches only method-not-found as permanently unsupported", async () => {
    const proc = new CodexProcess("linux");
    const messages: unknown[] = [];
    proc.on("message", (message) => messages.push(message));
    const request = vi
      .spyOn(proc as any, "request")
      .mockRejectedValue(
        new CodexRpcError("collaborationMode/list", "Method not found", -32601),
      );

    await expect(proc.probeNativePlanModeSupport()).resolves.toBe(false);
    await expect(proc.probeNativePlanModeSupport()).resolves.toBe(false);

    expect(request).toHaveBeenCalledOnce();
    expect(proc.nativePlanModeCapabilityKnown).toBe(true);
    expect(proc.supportsNativePlanMode).toBe(false);
    expect(messages).toContainEqual({
      type: "system",
      subtype: "runtime_capabilities",
      provider: "codex",
      codexNativePlanModeSupported: false,
    });
    expect(() => proc.setCollaborationMode("plan")).toThrow(
      "Native Codex Plan mode is unavailable",
    );
  });

  it.each([
    [
      "RPC internal error",
      () =>
        new CodexRpcError("collaborationMode/list", "Internal error", -32603),
    ],
    ["transport failure", () => new Error("transport closed")],
    [
      "abort",
      () =>
        new CodexRpcError(
          "collaborationMode/list",
          "collaborationMode/list aborted: client closed",
        ),
    ],
  ])("keeps %s native Plan probes retryable", async (_label, makeError) => {
    const proc = new CodexProcess("linux");
    const messages: unknown[] = [];
    proc.on("message", (message) => messages.push(message));
    const request = vi
      .spyOn(proc as any, "request")
      .mockImplementation(() => Promise.reject(makeError()));

    await expect(proc.probeNativePlanModeSupport()).resolves.toBe(false);
    await expect(proc.probeNativePlanModeSupport()).resolves.toBe(false);

    expect(request).toHaveBeenCalledTimes(2);
    expect(proc.nativePlanModeCapabilityKnown).toBe(false);
    expect(messages).not.toContainEqual(
      expect.objectContaining({ codexNativePlanModeSupported: false }),
    );
  });

  it("keeps malformed collaboration mode responses unknown", async () => {
    const proc = new CodexProcess("linux");
    const messages: unknown[] = [];
    proc.on("message", (message) => messages.push(message));
    vi.spyOn(proc as any, "request").mockResolvedValue({
      data: [{ name: "Plan" }],
    });

    await expect(proc.probeNativePlanModeSupport()).resolves.toBe(false);

    expect(proc.nativePlanModeCapabilityKnown).toBe(false);
    expect(proc.supportsNativePlanMode).toBe(false);
    expect(messages).not.toContainEqual(
      expect.objectContaining({ codexNativePlanModeSupported: false }),
    );
    expect(() => proc.setCollaborationMode("plan")).toThrow(
      "could not be confirmed",
    );
  });

  it("waits for the interrupted turn terminal notification", async () => {
    const proc = new CodexProcess("linux");
    (proc as any)._threadId = "thread-interrupt";
    (proc as any).pendingTurnId = "turn-interrupt";
    (proc as any)._status = "running";
    const request = vi.spyOn(proc as any, "request").mockResolvedValueOnce({});
    let settled = false;

    const interrupt = proc.interruptCurrentTurnAndWait(500).then((result) => {
      settled = true;
      return result;
    });
    await tick();
    expect(request).toHaveBeenCalledWith("turn/interrupt", {
      threadId: "thread-interrupt",
      turnId: "turn-interrupt",
    });
    expect(settled).toBe(false);

    (proc as any).handleNotification("turn/completed", {
      threadId: "thread-interrupt",
      turn: { id: "turn-interrupt", status: "interrupted" },
    });
    await expect(interrupt).resolves.toBe(true);
    expect(settled).toBe(true);
  });

  it("does not continue when the turn completed before interrupt won", async () => {
    const proc = new CodexProcess("linux");
    (proc as any)._threadId = "thread-interrupt-race";
    (proc as any).pendingTurnId = "turn-interrupt-race";
    (proc as any)._status = "running";
    let rejectInterrupt!: (error: Error) => void;
    vi.spyOn(proc as any, "request").mockImplementation(
      () =>
        new Promise((_, reject) => {
          rejectInterrupt = reject;
        }),
    );

    const interrupt = proc.interruptCurrentTurnAndWait(500);
    await tick();
    (proc as any).handleNotification("turn/completed", {
      threadId: "thread-interrupt-race",
      turn: { id: "turn-interrupt-race", status: "completed" },
    });
    rejectInterrupt(new Error("turn already completed"));

    await expect(interrupt).resolves.toBe(false);
  });

  it("continues a restarted ordinary turn with empty app-server input", async () => {
    const proc = new CodexProcess("linux");
    (proc as any)._threadId = "thread-empty-continuation";
    const request = vi
      .spyOn(proc as any, "request")
      .mockImplementation(async (method: string, params: any) => {
        expect(method).toBe("turn/start");
        expect(params).toEqual({
          threadId: "thread-empty-continuation",
          input: [],
        });
        setTimeout(() => {
          (proc as any).handleNotification("turn/started", {
            threadId: "thread-empty-continuation",
            turn: { id: "turn-empty" },
          });
          (proc as any).handleNotification("turn/completed", {
            threadId: "thread-empty-continuation",
            turn: { id: "turn-empty", status: "completed" },
          });
        }, 0);
        return { turn: { id: "turn-empty" } };
      });

    await (proc as any).continueInterruptedTurnAfterBootstrap({
      continueInterruptedTurnAfterStart: true,
    });

    expect(request).toHaveBeenCalledOnce();
    expect(proc.status).toBe("idle");
  });

  it("falls back to a visible continue prompt when empty input is rejected", async () => {
    const proc = new CodexProcess("linux");
    (proc as any)._threadId = "thread-text-continuation";
    const request = vi
      .spyOn(proc as any, "request")
      .mockRejectedValueOnce(new Error("input must not be empty"))
      .mockImplementationOnce(async (_method: string, params: any) => {
        expect(params).toEqual({
          threadId: "thread-text-continuation",
          input: [{ type: "text", text: "继续" }],
        });
        setTimeout(() => {
          (proc as any).handleNotification("turn/started", {
            threadId: "thread-text-continuation",
            turn: { id: "turn-fallback" },
          });
          (proc as any).handleNotification("turn/completed", {
            threadId: "thread-text-continuation",
            turn: { id: "turn-fallback", status: "completed" },
          });
        }, 0);
        return { turn: { id: "turn-fallback" } };
      });

    await (proc as any).continueInterruptedTurnAfterBootstrap({
      continueInterruptedTurnAfterStart: true,
      continuationFallbackText: "继续",
    });

    expect(request).toHaveBeenCalledTimes(2);
    expect(proc.status).toBe("idle");
  });

  it("does not resurrect a continuation completed before turn/start replies", async () => {
    const proc = new CodexProcess("linux");
    (proc as any)._threadId = "thread-fast-continuation";
    vi.spyOn(proc as any, "request").mockImplementation(async () => {
      (proc as any).handleNotification("turn/started", {
        threadId: "thread-fast-continuation",
        turn: { id: "turn-fast" },
      });
      (proc as any).handleNotification("turn/completed", {
        threadId: "thread-fast-continuation",
        turn: { id: "turn-fast", status: "completed" },
      });
      return { turn: { id: "turn-fast" } };
    });

    await (proc as any).continueInterruptedTurnAfterBootstrap({
      continueInterruptedTurnAfterStart: true,
    });

    expect((proc as any).pendingTurnId).toBeNull();
    expect(proc.status).toBe("idle");
  });

  it("validates goal payloads received from app-server", () => {
    expect(() => parseCodexGoal({ status: "active" })).toThrow("invalid shape");
    expect(
      parseCodexGoal({
        threadId: "thread-1",
        objective: "Goal",
        status: "waitingForFutureResource",
        tokensUsed: 0,
        timeUsedSeconds: 0,
        createdAt: 1,
        updatedAt: 1,
      }),
    ).toEqual({
      threadId: "thread-1",
      objective: "Goal",
      status: "waitingForFutureResource",
      tokenBudget: null,
      tokensUsed: 0,
      timeUsedSeconds: 0,
      createdAt: 1,
      updatedAt: 1,
    });
  });

  it("preserves structured JSON-RPC error details", () => {
    const proc = new CodexProcess("linux");
    let rejected: Error | undefined;
    (proc as any).pendingRpc.set(42, {
      resolve: vi.fn(),
      reject: (error: Error) => {
        rejected = error;
      },
      method: "thread/resume",
    });

    (proc as any).handleRpcResponse({
      id: 42,
      error: {
        code: -32600,
        message: "thread thread-1 already has an active writer",
        data: { threadId: "thread-1" },
      },
    });

    expect(rejected).toBeInstanceOf(CodexRpcError);
    expect(rejected).toMatchObject({
      method: "thread/resume",
      code: -32600,
      message: "thread thread-1 already has an active writer",
      data: { threadId: "thread-1" },
    });
    expect(codexErrorMessage(rejected)).toBe(
      "This Codex thread is already open in another client. Close it there and try again.",
    );
  });

  it("keeps non-writer JSON-RPC error messages unchanged", () => {
    expect(
      codexErrorMessage(
        new CodexRpcError("thread/resume", "invalid thread id", -32600),
      ),
    ).toBe("invalid thread id");
  });

  it("finalizes streamed agent text before turn completion", () => {
    const proc = new CodexProcess("linux");
    const messages: Array<Record<string, unknown>> = [];
    proc.on("message", (message) =>
      messages.push(message as Record<string, unknown>),
    );

    (proc as any).handleNotification("turn/started", {
      turn: { id: "turn-stream-only" },
    });
    (proc as any).handleNotification("item/agentMessage/delta", {
      itemId: "agent-message-1",
      delta: "Streamed ",
    });
    (proc as any).handleNotification("item/agentMessage/delta", {
      itemId: "agent-message-1",
      delta: "response",
    });
    (proc as any).handleNotification("turn/completed", {
      turn: { id: "turn-stream-only", status: "completed" },
    });

    const assistantIndex = messages.findIndex(
      (message) => message.type === "assistant",
    );
    const resultIndex = messages.findIndex(
      (message) => message.type === "result",
    );
    expect(assistantIndex).toBeGreaterThanOrEqual(0);
    expect(resultIndex).toBeGreaterThan(assistantIndex);
    expect(messages[assistantIndex]).toMatchObject({
      type: "assistant",
      message: {
        id: "agent-message-1",
        role: "assistant",
        content: [{ type: "text", text: "Streamed response" }],
      },
    });
    expect(messages[resultIndex]).toMatchObject({
      type: "result",
      subtype: "success",
      result: "Streamed response",
    });
  });

  it("binds an id-less delta to the only started agent message", () => {
    const proc = new CodexProcess("linux");
    const messages: Array<Record<string, unknown>> = [];
    proc.on("message", (message) =>
      messages.push(message as Record<string, unknown>),
    );

    (proc as any).handleNotification("turn/started", {
      turn: { id: "turn-started-agent" },
    });
    (proc as any).handleNotification("item/started", {
      turnId: "turn-started-agent",
      item: { id: "agent-started", type: "agentMessage" },
    });
    (proc as any).handleNotification("item/agentMessage/delta", {
      turnId: "turn-started-agent",
      delta: "Bound response",
    });
    (proc as any).handleNotification("item/completed", {
      turnId: "turn-started-agent",
      item: { id: "agent-started", type: "agentMessage" },
    });
    (proc as any).handleNotification("turn/completed", {
      turn: { id: "turn-started-agent", status: "completed" },
    });

    expect(messages.filter((message) => message.type === "assistant")).toEqual([
      expect.objectContaining({
        message: expect.objectContaining({
          id: "agent-started",
          content: [{ type: "text", text: "Bound response" }],
        }),
      }),
    ]);
    expect(messages.find((message) => message.type === "result")).toMatchObject(
      { result: "Bound response" },
    );
  });

  it("suppresses a turn-scoped late completion without polluting the next result", () => {
    const proc = new CodexProcess("linux");
    const messages: Array<Record<string, unknown>> = [];
    proc.on("message", (message) =>
      messages.push(message as Record<string, unknown>),
    );

    (proc as any).handleNotification("turn/started", {
      turn: { id: "turn-first" },
    });
    (proc as any).handleNotification("item/agentMessage/delta", {
      turnId: "turn-first",
      itemId: "agent-first",
      delta: "First result",
    });
    (proc as any).handleNotification("turn/completed", {
      turn: { id: "turn-first", status: "completed" },
    });

    (proc as any).handleNotification("turn/started", {
      turn: { id: "turn-second" },
    });
    (proc as any).handleNotification("item/agentMessage/delta", {
      turnId: "turn-second",
      itemId: "agent-second",
      delta: "Second result",
    });
    (proc as any).handleNotification("item/completed", {
      turnId: "turn-first",
      item: {
        id: "agent-first",
        type: "agentMessage",
        text: "First result",
      },
    });
    (proc as any).handleNotification("turn/completed", {
      turn: { id: "turn-second", status: "completed" },
    });

    const assistantTexts = messages
      .filter((message) => message.type === "assistant")
      .map(
        (message) =>
          ((message.message as any).content[0] as Record<string, unknown>).text,
      );
    expect(assistantTexts).toEqual(["First result", "Second result"]);
    expect(
      messages
        .filter((message) => message.type === "result")
        .map((message) => message.result),
    ).toEqual(["First result", "Second result"]);
  });

  it("resets agent turn tombstones when preparing a new launch", () => {
    const proc = new CodexProcess("linux");
    const messages: Array<Record<string, unknown>> = [];
    proc.on("message", (message) =>
      messages.push(message as Record<string, unknown>),
    );

    (proc as any).handleNotification("turn/started", {
      turn: { id: "turn-old-runtime" },
    });
    (proc as any).handleNotification("item/agentMessage/delta", {
      turnId: "turn-old-runtime",
      itemId: "agent-reused",
      delta: "Old runtime response",
    });
    (proc as any).handleNotification("turn/completed", {
      turn: { id: "turn-old-runtime", status: "completed" },
    });

    (proc as any).prepareLaunch("/tmp/new-runtime");
    messages.length = 0;
    (proc as any).handleNotification("item/completed", {
      turnId: "turn-old-runtime",
      item: {
        id: "agent-reused",
        type: "agentMessage",
        text: "New runtime response",
      },
    });

    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "assistant",
        message: expect.objectContaining({
          id: "agent-reused",
          content: [{ type: "text", text: "New runtime response" }],
        }),
      }),
    );
  });

  it("repairs truncated streamed text from the turn completion summary", () => {
    const proc = new CodexProcess("linux");
    const messages: Array<Record<string, unknown>> = [];
    proc.on("message", (message) =>
      messages.push(message as Record<string, unknown>),
    );

    (proc as any).handleNotification("turn/started", {
      turn: { id: "turn-summary-repair" },
    });
    (proc as any).handleNotification("item/agentMessage/delta", {
      itemId: "agent-message-summary",
      delta: "Partial response",
    });
    (proc as any).handleNotification("turn/completed", {
      turn: {
        id: "turn-summary-repair",
        status: "completed",
        itemsView: "summary",
        items: [
          {
            id: "agent-message-summary",
            type: "agentMessage",
            text: "Complete response from summary",
          },
        ],
      },
    });

    const assistants = messages.filter(
      (message) => message.type === "assistant",
    );
    expect(assistants).toHaveLength(1);
    expect(assistants[0]).toMatchObject({
      message: {
        id: "agent-message-summary",
        content: [{ type: "text", text: "Complete response from summary" }],
      },
    });
    expect(messages.find((message) => message.type === "result")).toMatchObject(
      { result: "Complete response from summary" },
    );
  });

  it("does not duplicate an agent message confirmed before the turn summary", () => {
    const proc = new CodexProcess("linux");
    const messages: Array<Record<string, unknown>> = [];
    proc.on("message", (message) =>
      messages.push(message as Record<string, unknown>),
    );

    (proc as any).handleNotification("turn/started", {
      turn: { id: "turn-summary-dedupe" },
    });
    (proc as any).handleNotification("item/completed", {
      item: {
        id: "agent-message-confirmed",
        type: "agentMessage",
        text: "Confirmed response",
      },
    });
    (proc as any).handleNotification("turn/completed", {
      turn: {
        id: "turn-summary-dedupe",
        status: "completed",
        itemsView: "summary",
        items: [
          {
            id: "agent-message-confirmed",
            type: "agentMessage",
            text: "Confirmed response",
          },
        ],
      },
    });

    expect(
      messages.filter((message) => message.type === "assistant"),
    ).toHaveLength(1);
    expect(messages.find((message) => message.type === "result")).toMatchObject(
      { result: "Confirmed response" },
    );
  });

  it("keeps canonical item text when the completion summary differs", () => {
    const proc = new CodexProcess("linux");
    const messages: Array<Record<string, unknown>> = [];
    proc.on("message", (message) =>
      messages.push(message as Record<string, unknown>),
    );

    (proc as any).handleNotification("turn/started", {
      turn: { id: "turn-summary-canonical" },
    });
    (proc as any).handleNotification("item/completed", {
      item: {
        id: "agent-message-canonical",
        type: "agentMessage",
        text: "Canonical response",
      },
    });
    (proc as any).handleNotification("turn/completed", {
      turn: {
        id: "turn-summary-canonical",
        status: "completed",
        itemsView: "summary",
        items: [
          {
            id: "agent-message-canonical",
            type: "agentMessage",
            text: "Different fallback summary",
          },
        ],
      },
    });

    expect(
      messages.filter((message) => message.type === "assistant"),
    ).toHaveLength(1);
    expect(messages.find((message) => message.type === "result")).toMatchObject(
      { result: "Canonical response" },
    );
  });

  it("correlates an unknown-id delta with a matching completion summary", () => {
    const proc = new CodexProcess("linux");
    const messages: Array<Record<string, unknown>> = [];
    proc.on("message", (message) =>
      messages.push(message as Record<string, unknown>),
    );

    (proc as any).handleNotification("turn/started", {
      turn: { id: "turn-summary-unknown-id" },
    });
    (proc as any).handleNotification("item/agentMessage/delta", {
      delta: "Response prefix",
    });
    (proc as any).handleNotification("turn/completed", {
      turn: {
        id: "turn-summary-unknown-id",
        status: "completed",
        itemsView: "summary",
        items: [
          {
            id: "agent-message-known",
            type: "agentMessage",
            text: "Response prefix and completed suffix",
          },
        ],
      },
    });

    const assistants = messages.filter(
      (message) => message.type === "assistant",
    );
    expect(assistants).toHaveLength(1);
    expect(assistants[0]).toMatchObject({
      message: {
        id: "agent-message-known",
        content: [
          { type: "text", text: "Response prefix and completed suffix" },
        ],
      },
    });
  });

  it("does not duplicate an unknown-id delta confirmed by item/completed", () => {
    const proc = new CodexProcess("linux");
    const messages: Array<Record<string, unknown>> = [];
    proc.on("message", (message) =>
      messages.push(message as Record<string, unknown>),
    );

    (proc as any).handleNotification("turn/started", {
      turn: { id: "turn-unknown-id-completed" },
    });
    (proc as any).handleNotification("item/agentMessage/delta", {
      delta: "Complete response",
    });
    (proc as any).handleNotification("item/completed", {
      item: {
        id: "agent-message-known",
        type: "agentMessage",
        text: "Complete response",
      },
    });
    (proc as any).handleNotification("turn/completed", {
      turn: {
        id: "turn-unknown-id-completed",
        status: "completed",
        itemsView: "summary",
        items: [
          {
            id: "agent-message-known",
            type: "agentMessage",
            text: "Complete response",
          },
        ],
      },
    });

    expect(
      messages.filter((message) => message.type === "assistant"),
    ).toHaveLength(1);
    expect(messages.find((message) => message.type === "result")).toMatchObject(
      { result: "Complete response" },
    );
  });

  it("ignores completion summaries for interrupted turns", () => {
    const proc = new CodexProcess("linux");
    const messages: Array<Record<string, unknown>> = [];
    proc.on("message", (message) =>
      messages.push(message as Record<string, unknown>),
    );

    (proc as any).handleNotification("turn/started", {
      turn: { id: "turn-summary-interrupted" },
    });
    (proc as any).handleNotification("item/agentMessage/delta", {
      itemId: "agent-message-interrupted",
      delta: "Interrupted partial",
    });
    (proc as any).handleNotification("turn/completed", {
      turn: {
        id: "turn-summary-interrupted",
        status: "interrupted",
        itemsView: "summary",
        items: [
          {
            id: "agent-message-interrupted",
            type: "agentMessage",
            text: "Unexpected completed summary",
          },
        ],
      },
    });

    expect(
      messages.find((message) => message.type === "assistant"),
    ).toMatchObject({
      message: {
        content: [{ type: "text", text: "Interrupted partial" }],
      },
    });
    expect(messages.find((message) => message.type === "result")).toMatchObject(
      {
        subtype: "interrupted",
      },
    );
  });

  it("finalizes multiple streamed agent items independently", () => {
    const proc = new CodexProcess("linux");
    const messages: Array<Record<string, unknown>> = [];
    proc.on("message", (message) =>
      messages.push(message as Record<string, unknown>),
    );

    (proc as any).handleNotification("turn/started", {
      turn: { id: "turn-multiple-agents" },
    });
    (proc as any).handleNotification("item/agentMessage/delta", {
      itemId: "agent-message-1",
      delta: "First response",
    });
    (proc as any).handleNotification("item/agentMessage/delta", {
      itemId: "agent-message-2",
      delta: "Second response",
    });
    (proc as any).handleNotification("turn/completed", {
      turn: { id: "turn-multiple-agents", status: "completed" },
    });

    const assistants = messages.filter(
      (message) => message.type === "assistant",
    );
    expect(assistants).toMatchObject([
      {
        message: {
          id: "agent-message-1",
          content: [{ type: "text", text: "First response" }],
        },
      },
      {
        message: {
          id: "agent-message-2",
          content: [{ type: "text", text: "Second response" }],
        },
      },
    ]);
    expect(messages.find((message) => message.type === "result")).toMatchObject(
      { result: "Second response" },
    );
  });

  it("keeps an unknown-id delta when another agent item completes", () => {
    const proc = new CodexProcess("linux");
    const messages: Array<Record<string, unknown>> = [];
    proc.on("message", (message) =>
      messages.push(message as Record<string, unknown>),
    );

    (proc as any).handleNotification("turn/started", {
      turn: { id: "turn-unknown-agent" },
    });
    (proc as any).handleNotification("item/agentMessage/delta", {
      delta: "Unknown item response",
    });
    (proc as any).handleNotification("item/completed", {
      item: {
        id: "known-agent-message",
        type: "agentMessage",
        text: "Known item response",
      },
    });
    (proc as any).handleNotification("turn/completed", {
      turn: { id: "turn-unknown-agent", status: "completed" },
    });

    const assistantTexts = messages
      .filter((message) => message.type === "assistant")
      .map(
        (message) =>
          ((message.message as any).content[0] as Record<string, unknown>).text,
      );
    expect(assistantTexts).toEqual([
      "Known item response",
      "Unknown item response",
    ]);
  });

  it("emits goal state for app-server goal notifications", () => {
    const proc = new CodexProcess("linux");
    (proc as any)._threadId = "thread-1";
    const messages: unknown[] = [];
    proc.on("message", (message) => messages.push(message));
    const goal = {
      threadId: "thread-1",
      objective: "Ship Goal support",
      status: "waitingForFutureResource",
      tokensUsed: 0,
      timeUsedSeconds: 0,
      createdAt: 1,
      updatedAt: 2,
    };

    (proc as any).handleNotification("thread/goal/updated", {
      threadId: "thread-1",
      turnId: null,
      goal,
    });
    (proc as any).handleNotification("thread/goal/cleared", {
      threadId: "thread-1",
    });

    expect(messages).toEqual([
      {
        type: "goal_state",
        goal: { ...goal, tokenBudget: null },
        goalOperationSequence: 1,
      },
      { type: "goal_state", goal: null, goalOperationSequence: 2 },
    ]);
  });

  it("does not let a delayed clear echo erase a Goal recreated after the response", async () => {
    const proc = new CodexProcess("linux");
    (proc as any)._threadId = "thread-1";
    const messages: unknown[] = [];
    proc.on("message", (message) => messages.push(message));
    const firstGoal = {
      threadId: "thread-1",
      objective: "First goal",
      status: "active",
      tokenBudget: null,
      tokensUsed: 0,
      timeUsedSeconds: 0,
      createdAt: 1,
      updatedAt: 10,
    };
    const secondGoal = {
      ...firstGoal,
      objective: "Newer external goal",
      updatedAt: 11,
    };
    const resolve = vi.fn();
    const reject = vi.fn();

    (proc as any).pendingRpc.set(1, {
      resolve,
      reject,
      method: "thread/goal/set",
    });
    (proc as any).handleRpcResponse({ id: 1, result: { goal: firstGoal } });
    (proc as any).handleNotification("thread/goal/updated", {
      threadId: "thread-1",
      goal: firstGoal,
    });

    (proc as any).pendingRpc.set(2, {
      resolve,
      reject,
      method: "thread/goal/clear",
    });
    (proc as any).handleRpcResponse({ id: 2, result: { cleared: true } });
    (proc as any).handleNotification("thread/goal/updated", {
      threadId: "thread-1",
      goal: secondGoal,
    });
    vi.spyOn(proc as any, "request").mockResolvedValueOnce({
      goal: secondGoal,
    });
    (proc as any).handleNotification("thread/goal/cleared", {
      threadId: "thread-1",
    });
    await tick();

    expect(reject).not.toHaveBeenCalled();
    expect(resolve).toHaveBeenCalledTimes(2);
    expect(messages).toEqual([
      {
        type: "goal_state",
        goal: firstGoal,
        goalOperationSequence: 1,
      },
      { type: "goal_state", goal: null, goalOperationSequence: 2 },
      {
        type: "goal_state",
        goal: secondGoal,
        goalOperationSequence: 3,
      },
      {
        type: "goal_state",
        goal: secondGoal,
        goalOperationSequence: 4,
      },
    ]);
  });

  it("suppresses only the immediate ordered echo of a clear response", () => {
    const proc = new CodexProcess("linux");
    (proc as any)._threadId = "thread-1";
    const messages: unknown[] = [];
    proc.on("message", (message) => messages.push(message));

    (proc as any).pendingRpc.set(1, {
      resolve: vi.fn(),
      reject: vi.fn(),
      method: "thread/goal/clear",
    });
    (proc as any).handleRpcResponse({ id: 1, result: { cleared: true } });
    (proc as any).handleNotification("thread/goal/cleared", {
      threadId: "thread-1",
    });

    expect(messages).toEqual([
      { type: "goal_state", goal: null, goalOperationSequence: 1 },
    ]);
  });

  it("does not create a clear echo fence when its notification arrived first", () => {
    const proc = new CodexProcess("linux");
    (proc as any)._threadId = "thread-1";
    const messages: unknown[] = [];
    proc.on("message", (message) => messages.push(message));

    (proc as any).pendingRpc.set(1, {
      resolve: vi.fn(),
      reject: vi.fn(),
      method: "thread/goal/clear",
      goalOrderingGeneration: 0,
    });
    (proc as any).handleNotification("thread/goal/cleared", {
      threadId: "thread-1",
    });
    (proc as any).handleRpcResponse({ id: 1, result: { cleared: true } });
    (proc as any).handleNotification("thread/goal/cleared", {
      threadId: "thread-1",
    });

    expect(messages).toEqual([
      { type: "goal_state", goal: null, goalOperationSequence: 1 },
      { type: "goal_state", goal: null, goalOperationSequence: 2 },
      { type: "goal_state", goal: null, goalOperationSequence: 3 },
    ]);
  });

  it("authoritatively verifies a delayed clear after a later Goal RPC", async () => {
    const proc = new CodexProcess("linux");
    (proc as any)._threadId = "thread-1";
    const messages: unknown[] = [];
    proc.on("message", (message) => messages.push(message));

    (proc as any).pendingRpc.set(1, {
      resolve: vi.fn(),
      reject: vi.fn(),
      method: "thread/goal/clear",
    });
    (proc as any).handleRpcResponse({ id: 1, result: { cleared: true } });
    const recreatedGoal = {
      threadId: "thread-1",
      objective: "Recreated Goal",
      status: "active",
      tokenBudget: null,
      tokensUsed: 0,
      timeUsedSeconds: 0,
      createdAt: 2,
      updatedAt: 2,
    };
    vi.spyOn(proc as any, "request")
      .mockRejectedValueOnce(new Error("later Goal lookup failed"))
      .mockResolvedValueOnce({ goal: recreatedGoal });

    await expect(proc.getGoal()).rejects.toThrow("later Goal lookup failed");
    (proc as any).handleNotification("thread/goal/cleared", {
      threadId: "thread-1",
    });
    await tick();

    expect(messages).toEqual([
      { type: "goal_state", goal: null, goalOperationSequence: 1 },
      {
        type: "goal_state",
        goal: recreatedGoal,
        goalOperationSequence: 2,
      },
    ]);
  });

  it("does not resume a replacement Goal from a strict restart lease", async () => {
    const proc = new CodexProcess("linux");
    (proc as any)._threadId = "thread-lease";
    const pausedGoal = {
      threadId: "thread-lease",
      objective: "Original Goal",
      status: "paused" as const,
      tokenBudget: 12_000,
      tokensUsed: 10,
      timeUsedSeconds: 2,
      createdAt: 1,
      updatedAt: 5,
    };
    const replacementGoal = {
      ...pausedGoal,
      tokensUsed: 0,
      timeUsedSeconds: 0,
      updatedAt: 6,
    };
    const messages: unknown[] = [];
    proc.on("message", (message) => messages.push(message));
    const request = vi
      .spyOn(proc as any, "request")
      .mockResolvedValueOnce({ goal: replacementGoal });

    await (proc as any).resumeGoalAfterBootstrap({
      resumeGoalAfterStart: true,
      resumeGoalLease: createCodexGoalResumeLease(pausedGoal),
    });

    expect(request).toHaveBeenCalledOnce();
    expect(request).toHaveBeenCalledWith("thread/goal/get", {
      threadId: "thread-lease",
    });
    expect(messages).toEqual([{ type: "goal_state", goal: replacementGoal }]);
  });

  it("resumes the same paused Goal from a strict restart lease", async () => {
    const proc = new CodexProcess("linux");
    (proc as any)._threadId = "thread-matching-lease";
    const pausedGoal = {
      threadId: "thread-matching-lease",
      objective: "Original Goal",
      status: "paused" as const,
      tokenBudget: null,
      tokensUsed: 12,
      timeUsedSeconds: 4,
      createdAt: 1,
      updatedAt: 6,
    };
    const request = vi
      .spyOn(proc as any, "request")
      .mockResolvedValueOnce({ goal: pausedGoal })
      .mockResolvedValueOnce({
        goal: { ...pausedGoal, status: "active", updatedAt: 7 },
      });

    await (proc as any).resumeGoalAfterBootstrap({
      resumeGoalAfterStart: true,
      resumeGoalLease: createCodexGoalResumeLease({
        ...pausedGoal,
        updatedAt: 5,
      }),
    });

    expect(request).toHaveBeenNthCalledWith(1, "thread/goal/get", {
      threadId: "thread-matching-lease",
    });
    expect(request).toHaveBeenNthCalledWith(2, "thread/goal/set", {
      threadId: "thread-matching-lease",
      status: "active",
    });
  });

  it("keeps legacy restart Goal resume behavior when no lease is supplied", async () => {
    const proc = new CodexProcess("linux");
    (proc as any)._threadId = "thread-legacy-resume";
    const resumedGoal = {
      threadId: "thread-legacy-resume",
      objective: "Legacy Goal",
      status: "active",
      tokenBudget: null,
      tokensUsed: 0,
      timeUsedSeconds: 0,
      createdAt: 1,
      updatedAt: 2,
    };
    const request = vi
      .spyOn(proc as any, "request")
      .mockResolvedValueOnce({ goal: resumedGoal });

    await (proc as any).resumeGoalAfterBootstrap({
      resumeGoalAfterStart: true,
    });

    expect(request).toHaveBeenCalledOnce();
    expect(request).toHaveBeenCalledWith("thread/goal/set", {
      threadId: "thread-legacy-resume",
      status: "active",
    });
  });

  it("orders an observed Goal RPC response after an earlier external update", () => {
    const proc = new CodexProcess("linux");
    (proc as any)._threadId = "thread-1";
    const messages: unknown[] = [];
    proc.on("message", (message) => messages.push(message));
    const externalGoal = {
      threadId: "thread-1",
      objective: "Desktop update",
      status: "paused",
      tokenBudget: null,
      tokensUsed: 1,
      timeUsedSeconds: 1,
      createdAt: 1,
      updatedAt: 20,
    };
    const responseGoal = {
      ...externalGoal,
      objective: "Mobile response",
      status: "active",
      updatedAt: 21,
    };

    (proc as any).handleNotification("thread/goal/updated", {
      threadId: "thread-1",
      goal: externalGoal,
    });
    (proc as any).pendingRpc.set(1, {
      resolve: vi.fn(),
      reject: vi.fn(),
      method: "thread/goal/set",
    });
    (proc as any).handleRpcResponse({ id: 1, result: { goal: responseGoal } });

    expect(messages).toEqual([
      {
        type: "goal_state",
        goal: externalGoal,
        goalOperationSequence: 1,
      },
      {
        type: "goal_state",
        goal: responseGoal,
        goalOperationSequence: 2,
      },
    ]);
  });

  it("does not suppress a clear notification after its echo fence expires", () => {
    const proc = new CodexProcess("linux");
    (proc as any)._threadId = "thread-1";
    const messages: unknown[] = [];
    proc.on("message", (message) => messages.push(message));
    (proc as any).goalOperationSequence = 1;
    (proc as any).expectedGoalNotifications = [
      {
        sequence: 1,
        kind: "cleared",
        expiresAt: Date.now() - 1,
      },
    ];

    (proc as any).handleNotification("thread/goal/cleared", {
      threadId: "thread-1",
    });

    expect(messages).toEqual([
      { type: "goal_state", goal: null, goalOperationSequence: 2 },
    ]);
  });

  it("moves the default managed app-server port when Bridge uses 8767", () => {
    process.env.BRIDGE_PORT = "8767";
    process.env.BRIDGE_CODEX_APP_SERVER_MODE = "managed";
    delete process.env.BRIDGE_CODEX_SHARED_APP_SERVER_URL;
    delete process.env.BRIDGE_CODEX_APP_SERVER_PORT;
    delete process.env.BRIDGE_CODEX_APP_SERVER_URL;

    const proc = new CodexProcess("linux");
    proc.start("/tmp/project-managed-port");

    expect(spawnMock).toHaveBeenCalledWith(
      "codex",
      ["app-server", "--listen", "ws://127.0.0.1:8768"],
      expect.objectContaining({ cwd: "/tmp/project-managed-port" }),
    );

    proc.stop();
  });

  it("returns a clear error when Codex CLI is not installed", () => {
    const proc = new CodexProcess("linux");
    const messages: unknown[] = [];
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    proc.on("message", (msg) => messages.push(msg));

    try {
      proc.start("/tmp/project-missing-codex");

      const err = new Error("spawn codex ENOENT") as NodeJS.ErrnoException;
      err.code = "ENOENT";
      fakeChildren[0].emit("error", err);

      expect(messages).toContainEqual({
        type: "error",
        message:
          "Codex CLI is not installed or not available on PATH on the Bridge machine. Install it with `curl -fsSL https://chatgpt.com/codex/install.sh | sh`, then restart Bridge.",
        errorCode: "codex_cli_not_found",
      });
    } finally {
      errorSpy.mockRestore();
    }

    proc.stop();
  });

  it("starts codex app-server and sends initialize + thread/start", async () => {
    const proc = new CodexProcess("linux");
    const messages: unknown[] = [];
    proc.on("message", (msg) => messages.push(msg));

    proc.start("/tmp/project-a", {
      sandboxMode: "workspace-write",
      approvalPolicy: "on-request",
      approvalsReviewer: "auto_review",
      model: "gpt-5.3-codex",
    });

    expect(spawnMock).toHaveBeenCalledTimes(1);
    expect(spawnMock).toHaveBeenCalledWith(
      "codex",
      ["app-server", "--listen", "stdio://"],
      expect.objectContaining({ cwd: "/tmp/project-a" }),
    );

    const child = fakeChildren[0];
    await tick();

    const initReq = nextOutgoingRequest(child);
    expect(initReq.method).toBe("initialize");
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: initReq.id, result: {} })}\n`,
    );

    await tick();
    const initialized = nextOutgoingNotification(child);
    expect(initialized.method).toBe("initialized");

    const startReq = nextOutgoingRequest(child);
    expect(startReq.method).toBe("thread/start");
    expect(startReq.params).toMatchObject({
      cwd: "/tmp/project-a",
      approvalPolicy: "on-request",
      approvalsReviewer: "guardian_subagent",
      sandbox: "workspace-write",
      model: "gpt-5.3-codex",
    });

    child.stdout.emit(
      "data",
      `${JSON.stringify({
        id: startReq.id,
        result: {
          thread: { id: "thr_1" },
          model: "gpt-5.3-codex",
          serviceTier: "priority",
          approvalPolicy: "on-request",
          approvalsReviewer: "guardian_subagent",
          sandbox: {
            type: "workspaceWrite",
            networkAccess: false,
          },
        },
      })}\n`,
    );
    await tick();

    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "system",
        subtype: "init",
        provider: "codex",
        sessionId: "thr_1",
        model: "gpt-5.3-codex",
        approvalPolicy: "on-request",
        approvalsReviewer: "auto_review",
        sandboxMode: "workspace-write",
        serviceTier: "fast",
        networkAccessEnabled: false,
      }),
    );

    proc.stop();
  });

  it("creates a dedicated runtime with an in-memory fork instead of resuming or archiving", async () => {
    const proc = new CodexProcess("linux");
    const messages: unknown[] = [];
    proc.on("message", (message) => messages.push(message));

    proc.start("/tmp/project-dedicated", {
      ephemeralForkFromThreadId: "parent-thread",
      sandboxMode: "read-only",
      approvalPolicy: "on-request",
      collaborationMode: "default",
    });

    const child = fakeChildren[0];
    await tick();
    const initReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: initReq.id, result: {} })}\n`,
    );
    await tick();
    nextOutgoingNotification(child);

    const forkReq = nextOutgoingRequest(child);
    expect(forkReq.method).toBe("thread/fork");
    expect(forkReq.params).toMatchObject({
      threadId: "parent-thread",
      ephemeral: true,
      cwd: "/tmp/project-dedicated",
      sandbox: "read-only",
      approvalPolicy: "on-request",
    });
    expect(forkReq.method).not.toBe("thread/resume");

    child.stdout.emit(
      "data",
      `${JSON.stringify({
        id: forkReq.id,
        result: {
          thread: {
            id: "ephemeral-dedicated-thread",
            ephemeral: true,
            path: null,
          },
        },
      })}\n`,
    );
    await tick();

    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "system",
        subtype: "init",
        sessionId: "ephemeral-dedicated-thread",
        provider: "codex",
      }),
    );
    expect(
      child.stdin.writes.some((line) => line.includes("thread/archive")),
    ).toBe(false);
    expect(
      child.stdin.writes.some((line) => line.includes("thread/resume")),
    ).toBe(false);

    proc.stop();
  });

  it("creates a distinct persisted fork for a durable side runtime", async () => {
    const proc = new CodexProcess("linux");
    const messages: unknown[] = [];
    proc.on("message", (message) => messages.push(message));

    proc.start("/tmp/project-durable", {
      forkFromThreadId: "parent-thread",
      excludeTurnsOnOpen: true,
      threadSource: "ccpocket_side_chat",
      sandboxMode: "read-only",
    });

    const child = fakeChildren[0];
    await tick();
    const initReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: initReq.id, result: {} })}\n`,
    );
    await tick();
    nextOutgoingNotification(child);

    const forkReq = nextOutgoingRequest(child);
    expect(forkReq.method).toBe("thread/fork");
    expect(forkReq.params).toMatchObject({
      threadId: "parent-thread",
      ephemeral: false,
      excludeTurns: true,
      threadSource: "ccpocket_side_chat",
      cwd: "/tmp/project-durable",
    });

    child.stdout.emit(
      "data",
      `${JSON.stringify({
        id: forkReq.id,
        result: {
          thread: {
            id: "durable-side-thread",
            ephemeral: false,
            path: "/tmp/durable-side-thread.jsonl",
          },
        },
      })}\n`,
    );
    await tick();

    expect(proc.sessionId).toBe("durable-side-thread");
    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "system",
        subtype: "init",
        sessionId: "durable-side-thread",
      }),
    );
    proc.stop();
  });

  it("rejects a persisted fork without deleting the untrusted returned id", async () => {
    const warning = vi.spyOn(console, "warn").mockImplementation(() => {});
    const proc = new CodexProcess("linux");
    const messages: unknown[] = [];
    proc.on("message", (message) => messages.push(message));
    proc.start("/tmp/project-dedicated", {
      ephemeralForkFromThreadId: "parent-thread",
    });

    const child = fakeChildren[0];
    await tick();
    const initReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: initReq.id, result: {} })}\n`,
    );
    await tick();
    nextOutgoingNotification(child);
    const forkReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({
        id: forkReq.id,
        result: {
          thread: {
            id: "persisted-by-old-server",
            ephemeral: false,
            path: "/tmp/persisted-rollout.jsonl",
          },
        },
      })}\n`,
    );

    await tick();
    warning.mockRestore();

    expect(
      child.stdin.writes.some((line) => line.includes("thread/delete")),
    ).toBe(false);
    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "error",
        message: expect.stringContaining(
          "thread/fork did not return an in-memory ephemeral thread",
        ),
      }),
    );
    proc.stop();
  });

  it("does not delete a different id when an incompatible response has a path", async () => {
    const warning = vi.spyOn(console, "warn").mockImplementation(() => {});
    try {
      const proc = new CodexProcess("linux");
      const messages: unknown[] = [];
      proc.on("message", (message) => messages.push(message));
      proc.start("/tmp/project-dedicated", {
        ephemeralForkFromThreadId: "parent-thread",
      });

      const child = fakeChildren[0];
      await tick();
      const initReq = nextOutgoingRequest(child);
      child.stdout.emit(
        "data",
        `${JSON.stringify({ id: initReq.id, result: {} })}\n`,
      );
      await tick();
      nextOutgoingNotification(child);
      const forkReq = nextOutgoingRequest(child);
      child.stdout.emit(
        "data",
        `${JSON.stringify({
          id: forkReq.id,
          result: {
            thread: {
              id: "persisted-without-delete",
              ephemeral: true,
              path: "/tmp/persisted-rollout.jsonl",
            },
          },
        })}\n`,
      );

      await tick();

      expect(
        child.stdin.writes.some((line) => line.includes("thread/delete")),
      ).toBe(false);
      expect(warning).toHaveBeenCalledWith(
        expect.stringContaining(
          "Rejected incompatible ephemeral fork persisted-without-delete",
        ),
      );
      expect(messages).toContainEqual(
        expect.objectContaining({
          type: "error",
          message: expect.stringContaining(
            "automatic cleanup skipped for safety",
          ),
        }),
      );
      proc.stop();
    } finally {
      warning.mockRestore();
    }
  });

  it("never deletes the parent when an incompatible server echoes its id", async () => {
    const warning = vi.spyOn(console, "warn").mockImplementation(() => {});
    try {
      const proc = new CodexProcess("linux");
      const messages: unknown[] = [];
      proc.on("message", (message) => messages.push(message));
      proc.start("/tmp/project-dedicated", {
        ephemeralForkFromThreadId: "parent-thread",
      });

      const child = fakeChildren[0];
      await tick();
      const initReq = nextOutgoingRequest(child);
      child.stdout.emit(
        "data",
        `${JSON.stringify({ id: initReq.id, result: {} })}\n`,
      );
      await tick();
      nextOutgoingNotification(child);
      const forkReq = nextOutgoingRequest(child);
      child.stdout.emit(
        "data",
        `${JSON.stringify({
          id: forkReq.id,
          result: {
            thread: {
              id: "parent-thread",
              ephemeral: true,
              path: null,
            },
          },
        })}\n`,
      );
      await tick();

      expect(
        child.stdin.writes.some((line) => line.includes("thread/delete")),
      ).toBe(false);
      expect(warning).toHaveBeenCalledWith(
        expect.stringContaining(
          "Rejected incompatible ephemeral fork parent-thread",
        ),
      );
      expect(messages).toContainEqual(
        expect.objectContaining({
          type: "error",
          message: expect.stringContaining(
            "automatic cleanup skipped for safety",
          ),
        }),
      );
      proc.stop();
    } finally {
      warning.mockRestore();
    }
  });

  it("leaves approval, reviewer, and sandbox unset for custom permissions", async () => {
    const proc = new CodexProcess("linux");
    const messages: unknown[] = [];
    proc.on("message", (msg) => messages.push(msg));

    proc.start("/tmp/project-custom-permissions", {
      codexPermissionsMode: "custom",
    });

    const child = fakeChildren[0];
    await tick();

    const initReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: initReq.id, result: {} })}\n`,
    );

    await tick();
    nextOutgoingNotification(child);

    const startReq = nextOutgoingRequest(child);
    expect(startReq.method).toBe("thread/start");
    expect(startReq.params).toMatchObject({
      cwd: "/tmp/project-custom-permissions",
    });
    expect(startReq.params).not.toHaveProperty("approvalPolicy");
    expect(startReq.params).not.toHaveProperty("approvalsReviewer");
    expect(startReq.params).not.toHaveProperty("sandbox");

    child.stdout.emit(
      "data",
      `${JSON.stringify({
        id: startReq.id,
        result: { thread: { id: "thr_custom" } },
      })}\n`,
    );
    await tick();

    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "system",
        subtype: "init",
        provider: "codex",
        sessionId: "thr_custom",
        codexPermissionsMode: "custom",
      }),
    );
    const initMessage = messages.find(
      (msg) =>
        typeof msg === "object" &&
        msg !== null &&
        (msg as { type?: string; subtype?: string }).type === "system" &&
        (msg as { type?: string; subtype?: string }).subtype === "init",
    ) as Record<string, unknown>;
    expect(initMessage).not.toHaveProperty("approvalPolicy");
    expect(initMessage).not.toHaveProperty("approvalsReviewer");
    expect(initMessage).not.toHaveProperty("sandboxMode");

    proc.stop();
  });

  it("handles managed app-server spawn errors without crashing", () => {
    process.env.BRIDGE_CODEX_APP_SERVER_MODE = "managed";
    process.env.BRIDGE_CODEX_SHARED_APP_SERVER_URL = "ws://127.0.0.1:18767";
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});

    try {
      const proc = new CodexProcess("linux");
      proc.start("/tmp/project-managed-error");

      expect(spawnMock).toHaveBeenCalledWith(
        "codex",
        ["app-server", "--listen", "ws://127.0.0.1:18767"],
        expect.objectContaining({ cwd: "/tmp/project-managed-error" }),
      );

      expect(() => {
        fakeChildren[0].emit("error", new Error("spawn failed"));
      }).not.toThrow();

      expect(errorSpy).toHaveBeenCalledWith(
        "[codex-app-server] Failed to start: spawn failed",
      );

      const nextProc = new CodexProcess("linux");
      nextProc.start("/tmp/project-managed-error-next");
      expect(spawnMock).toHaveBeenCalledTimes(2);

      proc.stop();
      nextProc.stop();
    } finally {
      errorSpy.mockRestore();
    }
  });

  it("falls back to requested approval reviewer in init when thread response omits it", async () => {
    const proc = new CodexProcess("linux");
    const messages: unknown[] = [];
    proc.on("message", (msg) => messages.push(msg));

    proc.start("/tmp/project-auto-review", {
      sandboxMode: "workspace-write",
      approvalPolicy: "on-request",
      approvalsReviewer: "auto_review",
    });

    const child = fakeChildren[0];
    await tick();

    const initReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: initReq.id, result: {} })}\n`,
    );

    await tick();
    nextOutgoingNotification(child);

    const startReq = nextOutgoingRequest(child);
    expect(startReq.params).toMatchObject({
      approvalPolicy: "on-request",
      approvalsReviewer: "guardian_subagent",
      sandbox: "workspace-write",
    });
    child.stdout.emit(
      "data",
      `${JSON.stringify({
        id: startReq.id,
        result: {
          thread: { id: "thr_auto_review" },
          model: "gpt-5.5",
        },
      })}\n`,
    );
    await tick();

    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "system",
        subtype: "init",
        provider: "codex",
        sessionId: "thr_auto_review",
        approvalPolicy: "on-request",
        approvalsReviewer: "auto_review",
        sandboxMode: "workspace-write",
      }),
    );

    proc.stop();
  });

  it("sends reasoning effort via config override on thread/start", async () => {
    const proc = new CodexProcess("linux");

    proc.start("/tmp/project-effort", {
      sandboxMode: "workspace-write",
      approvalPolicy: "on-request",
      modelReasoningEffort: "xhigh",
    });

    const child = fakeChildren[0];
    await tick();

    const initReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: initReq.id, result: {} })}\n`,
    );

    await tick();
    nextOutgoingNotification(child); // initialized

    const startReq = nextOutgoingRequest(child);
    expect(startReq.method).toBe("thread/start");
    expect(startReq.params).toMatchObject({
      config: {
        model_reasoning_effort: "xhigh",
      },
    });

    proc.stop();
  });

  it("sends selected profile via config override on thread/start", async () => {
    const proc = new CodexProcess("linux");

    proc.start("/tmp/project-profile", {
      profile: "ccpocket",
      sandboxMode: "workspace-write",
      approvalPolicy: "on-request",
    });

    const child = fakeChildren[0];
    await tick();

    const initReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: initReq.id, result: {} })}\n`,
    );

    await tick();
    nextOutgoingNotification(child); // initialized

    const startReq = nextOutgoingRequest(child);
    expect(startReq.method).toBe("thread/start");
    expect(startReq.params).toMatchObject({
      cwd: "/tmp/project-profile",
      approvalPolicy: "on-request",
      sandbox: "workspace-write",
      config: {
        profile: "ccpocket",
      },
    });

    proc.stop();
  });

  it("merges additional writable roots with config/read roots on thread/start", async () => {
    const proc = new CodexProcess("linux");

    proc.start("/tmp/project-roots", {
      sandboxMode: "workspace-write",
      approvalPolicy: "on-request",
      additionalWritableRoots: [
        "/tmp/extra",
        "/tmp/project-roots/../extra",
        "/tmp/other",
      ],
    });

    const child = fakeChildren[0];
    await tick();

    const initReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: initReq.id, result: {} })}\n`,
    );

    await tick();
    nextOutgoingNotification(child); // initialized

    const configReq = nextOutgoingRequest(child);
    expect(configReq.method).toBe("config/read");
    expect(configReq.params).toEqual({
      includeLayers: false,
      cwd: "/tmp/project-roots",
    });
    child.stdout.emit(
      "data",
      `${JSON.stringify({
        id: configReq.id,
        result: {
          config: {
            sandbox_workspace_write: {
              writable_roots: ["/tmp/project-roots", "/tmp/extra"],
            },
          },
        },
      })}\n`,
    );

    await tick();
    const startReq = nextOutgoingRequest(child);
    expect(startReq.method).toBe("thread/start");
    expect(startReq.params).toMatchObject({
      cwd: "/tmp/project-roots",
      config: {
        sandbox_workspace_write: {
          writable_roots: ["/tmp/project-roots", "/tmp/extra", "/tmp/other"],
        },
      },
    });

    proc.stop();
  });

  it("uses cmd.exe to launch codex app-server on Windows", () => {
    const proc = new CodexProcess("win32");

    proc.start("D:\\Users\\alice\\repo");

    expect(spawnMock).toHaveBeenCalledTimes(1);
    expect(spawnMock).toHaveBeenCalledWith(
      "cmd.exe",
      ["/d", "/s", "/c", "codex app-server --listen stdio://"],
      expect.objectContaining({
        cwd: "D:\\Users\\alice\\repo",
        windowsVerbatimArguments: true,
      }),
    );

    proc.stop();
  });

  it("builds a normalized Windows spawn spec", () => {
    expect(
      buildCodexSpawnSpec("\\\\?\\D:\\Users\\alice\\repo", "win32"),
    ).toEqual({
      command: "cmd.exe",
      args: ["/d", "/s", "/c", "codex app-server --listen stdio://"],
      options: expect.objectContaining({
        cwd: "D:\\Users\\alice\\repo",
        stdio: "pipe",
        windowsVerbatimArguments: true,
      }),
    });
  });

  it("sends thread/rollback for the active thread", async () => {
    const proc = new CodexProcess("linux");
    proc.start("/tmp/project-a");

    const child = fakeChildren[0];
    await tick();

    const initReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: initReq.id, result: {} })}\n`,
    );

    await tick();
    nextOutgoingNotification(child);
    const startReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: startReq.id, result: { thread: { id: "thr_rollback" } } })}\n`,
    );
    await tick();
    drainSkillsList(child);

    const rollbackPromise = proc.rollbackThread(2);
    const rollbackReq = nextOutgoingRequest(child);
    expect(rollbackReq.method).toBe("thread/rollback");
    expect(rollbackReq.params).toEqual({
      threadId: "thr_rollback",
      numTurns: 2,
    });

    child.stdout.emit(
      "data",
      `${JSON.stringify({
        id: rollbackReq.id,
        result: { thread: { id: "thr_rollback", turns: [] } },
      })}\n`,
    );
    await expect(rollbackPromise).resolves.toEqual({
      id: "thr_rollback",
      turns: [],
    });
  });

  it("sends thread/read with includeTurns", async () => {
    const proc = new CodexProcess("linux");
    const initializePromise = proc.initializeOnly("/tmp/project-a");

    const child = fakeChildren[0];
    await tick();

    const initReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: initReq.id, result: {} })}\n`,
    );
    await tick();
    await initializePromise;

    const readPromise = proc.readThread("thr_read", true);
    const readReq = nextOutgoingRequest(child);
    expect(readReq.method).toBe("thread/read");
    expect(readReq.params).toEqual({
      threadId: "thr_read",
      includeTurns: true,
    });

    child.stdout.emit(
      "data",
      `${JSON.stringify({
        id: readReq.id,
        result: { thread: { id: "thr_read", turns: [] } },
      })}\n`,
    );
    await expect(readPromise).resolves.toEqual({
      id: "thr_read",
      turns: [],
    });
  });

  it("keeps Codex fork lineage from thread/list", async () => {
    const proc = new CodexProcess("linux");
    vi.spyOn(proc as any, "request").mockResolvedValue({
      data: [
        {
          id: "thr_child",
          forkedFromId: "thr_parent",
          preview: "Inherited prefix",
          createdAt: 1,
          updatedAt: 2,
          cwd: "/tmp/project-a",
        },
      ],
      nextCursor: null,
    });

    await expect(proc.listThreads()).resolves.toMatchObject({
      data: [
        {
          id: "thr_child",
          forkedFromThreadId: "thr_parent",
        },
      ],
    });
    proc.stop();
  });

  it("exposes one generic, read-only RPC seam for optional modules", async () => {
    const proc = new CodexProcess("linux");
    const response = { rateLimits: { limitId: "codex" } };
    const request = vi
      .spyOn(proc as any, "request")
      .mockResolvedValue(response);
    await expect(
      proc.requestReadOnlyRpc(
        "account/rateLimits/read",
        {},
        {
          timeoutMs: 10_000,
        },
      ),
    ).resolves.toBe(response);
    expect(request).toHaveBeenCalledWith(
      "account/rateLimits/read",
      {},
      {
        timeoutMs: 10_000,
      },
    );
    await expect(
      proc.requestReadOnlyRpc("thread/archive", { threadId: "unsafe" }),
    ).rejects.toThrow("Refusing non-read-only RPC method");
  });

  it("maps historical lifecycle mutations to stable app-server RPCs", async () => {
    const proc = new CodexProcess("linux");
    const request = vi.spyOn(proc as any, "request").mockResolvedValue({});

    await proc.archiveThread("thread-archive");
    await proc.unarchiveThread("thread-unarchive");
    await proc.deleteThread("thread-delete");

    expect(request).toHaveBeenNthCalledWith(1, "thread/archive", {
      threadId: "thread-archive",
    });
    expect(request).toHaveBeenNthCalledWith(2, "thread/unarchive", {
      threadId: "thread-unarchive",
    });
    expect(request).toHaveBeenNthCalledWith(3, "thread/delete", {
      threadId: "thread-delete",
    });
  });

  it("maps compact and inline review to stable app-server RPCs", async () => {
    const proc = new CodexProcess("linux");
    (proc as any)._threadId = "thread-core-actions";
    (proc as any)._status = "idle";
    const request = vi
      .spyOn(proc as any, "request")
      .mockResolvedValueOnce({})
      .mockResolvedValueOnce({
        turn: { id: "turn-review" },
        reviewThreadId: "thread-core-actions",
      });
    const options = { timeoutMs: 12_000 };

    await expect(proc.compactThread(options)).resolves.toBeUndefined();
    (proc as any).handleNotification("turn/started", {
      threadId: "thread-core-actions",
      turn: { id: "turn-compact" },
    });
    (proc as any).handleNotification("turn/completed", {
      threadId: "thread-core-actions",
      turn: { id: "turn-compact", status: "completed" },
    });
    await expect(
      proc.startInlineReview(
        { type: "commit", sha: "abc123", title: null },
        options,
      ),
    ).resolves.toEqual({
      turnId: "turn-review",
      reviewThreadId: "thread-core-actions",
    });
    (proc as any).handleNotification("turn/started", {
      threadId: "thread-core-actions",
      turn: { id: "turn-review" },
    });
    (proc as any).handleNotification("turn/completed", {
      threadId: "thread-core-actions",
      turn: { id: "turn-review", status: "completed" },
    });

    expect(request).toHaveBeenNthCalledWith(
      1,
      "thread/compact/start",
      { threadId: "thread-core-actions" },
      options,
    );
    expect(request).toHaveBeenNthCalledWith(
      2,
      "review/start",
      {
        threadId: "thread-core-actions",
        target: { type: "commit", sha: "abc123", title: null },
        delivery: "inline",
      },
      options,
    );
  });

  it("fails core actions closed unless the active thread is idle", async () => {
    const proc = new CodexProcess("linux");
    const request = vi.spyOn(proc as any, "request");

    await expect(proc.compactThread()).rejects.toEqual(
      expect.objectContaining<CodexCoreActionPreconditionError>({
        code: "thread_unavailable",
      }),
    );

    (proc as any)._threadId = "thread-busy";
    (proc as any)._status = "running";
    await expect(
      proc.startInlineReview({ type: "uncommittedChanges" }),
    ).rejects.toEqual(
      expect.objectContaining<CodexCoreActionPreconditionError>({
        code: "session_busy",
      }),
    );
    expect(request).not.toHaveBeenCalled();
  });

  it("owns the core-action ack window until turn/started takes over", async () => {
    const proc = new CodexProcess("linux");
    const inputResolve = vi.fn();
    const inputError = vi.spyOn(console, "error").mockImplementation(() => {});
    (proc as any)._threadId = "thread-core-action-lock";
    (proc as any)._status = "idle";
    (proc as any).inputResolve = inputResolve;
    const request = vi
      .spyOn(proc as any, "request")
      .mockResolvedValueOnce({})
      .mockResolvedValueOnce({ data: [], nextCursor: null });

    await expect(proc.compactThread()).resolves.toBeUndefined();
    expect(proc.hasPendingCoreAction).toBe(true);
    expect(proc.status).toBe("running");
    expect(proc.isWaitingForInput).toBe(false);

    await expect(
      proc.startInlineReview({ type: "uncommittedChanges" }),
    ).rejects.toMatchObject({ code: "session_busy" });
    proc.sendInput("must not overtake compact", "message-during-compact");
    expect(inputResolve).not.toHaveBeenCalled();
    expect((proc as any).inputResolve).toBe(inputResolve);
    expect(request).toHaveBeenCalledTimes(1);

    await expect(proc.listMcpServerStatus()).resolves.toEqual({
      data: [],
      nextCursor: null,
    });
    expect(request).toHaveBeenNthCalledWith(
      2,
      "mcpServerStatus/list",
      {
        cursor: null,
        limit: 64,
        detail: "toolsAndAuthOnly",
        threadId: "thread-core-action-lock",
      },
      {},
    );

    (proc as any).handleNotification("turn/started", {
      threadId: "thread-core-action-lock",
      turn: { id: "turn-compact" },
    });
    expect(proc.hasPendingCoreAction).toBe(false);
    expect(proc.status).toBe("running");
    expect(proc.isWaitingForInput).toBe(false);

    (proc as any).handleNotification("turn/completed", {
      threadId: "thread-core-action-lock",
      turn: { id: "turn-compact", status: "completed" },
    });
    expect(proc.status).toBe("idle");
    expect(proc.isWaitingForInput).toBe(true);
    inputError.mockRestore();
  });

  it("matches review admission to its returned turn id", async () => {
    const proc = new CodexProcess("linux");
    (proc as any)._threadId = "thread-review-lock";
    (proc as any)._status = "idle";
    vi.spyOn(proc as any, "request").mockResolvedValue({
      turn: { id: "turn-review" },
      reviewThreadId: "thread-review-lock",
    });

    await expect(
      proc.startInlineReview({ type: "uncommittedChanges" }),
    ).resolves.toMatchObject({ turnId: "turn-review" });
    expect(proc.hasPendingCoreAction).toBe(true);

    (proc as any).handleNotification("turn/started", {
      threadId: "thread-review-lock",
      turn: { id: "turn-unrelated" },
    });
    expect(proc.hasPendingCoreAction).toBe(true);

    (proc as any).handleNotification("turn/started", {
      threadId: "thread-review-lock",
      turn: { id: "turn-review" },
    });
    expect(proc.hasPendingCoreAction).toBe(false);
    expect(proc.status).toBe("running");

    (proc as any).handleNotification("turn/completed", {
      threadId: "thread-review-lock",
      turn: { id: "turn-review", status: "completed" },
    });
  });

  it("releases admission on RPC failure without fabricating a busy turn", async () => {
    const proc = new CodexProcess("linux");
    const inputResolve = vi.fn();
    (proc as any)._threadId = "thread-core-action-failure";
    (proc as any)._status = "idle";
    (proc as any).inputResolve = inputResolve;
    vi.spyOn(proc as any, "request").mockRejectedValue(
      new CodexRpcError("thread/compact/start", "rejected", -32000),
    );

    await expect(proc.compactThread()).rejects.toThrow("rejected");
    expect(proc.hasPendingCoreAction).toBe(false);
    expect(proc.status).toBe("idle");
    expect(proc.isWaitingForInput).toBe(true);

    proc.sendInput("safe after failure", "message-after-failure");
    expect(inputResolve).toHaveBeenCalledWith({
      text: "safe after failure",
      clientMessageId: "message-after-failure",
    });
  });

  it("keeps normal busy state when an observed action turn wins an RPC failure", async () => {
    const proc = new CodexProcess("linux");
    (proc as any)._threadId = "thread-core-action-started-failure";
    (proc as any)._status = "idle";
    let rejectRequest!: (error: Error) => void;
    vi.spyOn(proc as any, "request").mockReturnValue(
      new Promise((_resolve, reject) => {
        rejectRequest = reject;
      }),
    );

    const compact = proc.compactThread();
    expect(proc.hasPendingCoreAction).toBe(true);
    (proc as any).handleNotification("turn/started", {
      threadId: "thread-core-action-started-failure",
      turn: { id: "turn-compact" },
    });
    rejectRequest(new Error("late RPC failure"));

    await expect(compact).rejects.toThrow("late RPC failure");
    expect(proc.hasPendingCoreAction).toBe(false);
    expect(proc.status).toBe("running");
    expect((proc as any).pendingTurnId).toBe("turn-compact");

    (proc as any).handleNotification("turn/completed", {
      threadId: "thread-core-action-started-failure",
      turn: { id: "turn-compact", status: "failed" },
    });
  });

  it("clears an acked admission on terminal events, start timeout, and stop", async () => {
    vi.useFakeTimers();
    const clearTimeoutSpy = vi.spyOn(globalThis, "clearTimeout");
    const warning = vi.spyOn(console, "warn").mockImplementation(() => {});
    const proc = new CodexProcess("linux");
    (proc as any)._threadId = "thread-core-action-cleanup";
    (proc as any)._status = "idle";
    vi.spyOn(proc as any, "request").mockResolvedValue({});
    try {
      await proc.compactThread({ timeoutMs: 1 });
      expect(proc.hasPendingCoreAction).toBe(true);
      const completedTimer = (proc as any).pendingCoreAction.startTimeout;
      expect(completedTimer).toBeDefined();
      (proc as any).handleNotification("turn/completed", {
        threadId: "thread-core-action-cleanup",
        turn: { id: "turn-completed-early", status: "failed" },
      });
      expect(proc.hasPendingCoreAction).toBe(false);
      expect(clearTimeoutSpy).toHaveBeenCalledWith(completedTimer);

      await proc.compactThread({ timeoutMs: 1 });
      const expiredTimer = (proc as any).pendingCoreAction.startTimeout;
      expect(expiredTimer).toBeDefined();
      await vi.advanceTimersByTimeAsync(14_999);
      expect(proc.hasPendingCoreAction).toBe(true);
      await vi.advanceTimersByTimeAsync(1);
      expect(proc.hasPendingCoreAction).toBe(false);
      expect(proc.status).toBe("idle");
      expect(warning).toHaveBeenCalledWith(
        expect.stringContaining("within 15000ms"),
      );
      expect(clearTimeoutSpy).toHaveBeenCalledWith(expiredTimer);

      await proc.compactThread();
      expect(proc.hasPendingCoreAction).toBe(true);
      const stoppedTimer = (proc as any).pendingCoreAction.startTimeout;
      expect(stoppedTimer).toBeDefined();
      proc.stop();
      expect(proc.hasPendingCoreAction).toBe(false);
      expect(clearTimeoutSpy).toHaveBeenCalledWith(stoppedTimer);
    } finally {
      proc.stop();
      warning.mockRestore();
      clearTimeoutSpy.mockRestore();
      vi.useRealTimers();
    }
  });

  it("requests one bounded low-detail MCP status page", async () => {
    const proc = new CodexProcess("linux");
    (proc as any)._threadId = "thread-mcp-status";
    const response = {
      data: [{ name: "filesystem", authStatus: "unsupported" }],
      nextCursor: "next-page",
    };
    const request = vi
      .spyOn(proc as any, "request")
      .mockResolvedValue(response);
    const options = { timeoutMs: 10_000 };

    await expect(proc.listMcpServerStatus(options)).resolves.toEqual(response);
    expect(request).toHaveBeenCalledWith(
      "mcpServerStatus/list",
      {
        cursor: null,
        limit: 64,
        detail: "toolsAndAuthOnly",
        threadId: "thread-mcp-status",
      },
      options,
    );
  });

  it("rejects malformed review and MCP status responses", async () => {
    const proc = new CodexProcess("linux");
    (proc as any)._threadId = "thread-invalid-response";
    (proc as any)._status = "idle";
    const request = vi
      .spyOn(proc as any, "request")
      .mockResolvedValueOnce({ turn: {}, reviewThreadId: "thread" })
      .mockResolvedValueOnce({ data: null });

    await expect(
      proc.startInlineReview({ type: "uncommittedChanges" }),
    ).rejects.toMatchObject({
      method: "review/start",
    });
    await expect(proc.listMcpServerStatus()).rejects.toMatchObject({
      method: "mcpServerStatus/list",
    });
  });

  it("reads Browser Use auto-review policy without RPC params", async () => {
    const proc = new CodexProcess("linux");
    const child = new FakeChildProcess();
    attachFakeTransport(proc as any, child);

    const requirementsPromise = proc.readConfigRequirements();
    const request = nextOutgoingRequest(child);
    expect(request).toMatchObject({
      method: "configRequirements/read",
    });
    expect(request).not.toHaveProperty("params");

    (proc as any).handleRpcResponse({
      id: request.id,
      result: {
        requirements: {
          browserUse: { disableAutoReview: true },
        },
      },
    });
    await expect(requirementsPromise).resolves.toEqual({
      autoReviewDisabled: true,
    });
    proc.stop();
  });

  it("treats missing configRequirements/read as an old Codex fallback", async () => {
    const proc = new CodexProcess("linux");
    const child = new FakeChildProcess();
    attachFakeTransport(proc as any, child);

    const requirementsPromise = proc.readConfigRequirements();
    const request = nextOutgoingRequest(child);
    (proc as any).handleRpcResponse({
      id: request.id,
      error: { code: -32601, message: "Method not found" },
    });

    await expect(requirementsPromise).resolves.toEqual({
      autoReviewDisabled: false,
    });
    proc.stop();
  });

  it("ignores placeholder codex model names from resume state", async () => {
    const proc = new CodexProcess("linux");
    const messages: unknown[] = [];
    proc.on("message", (msg) => messages.push(msg));

    proc.start("/tmp/project-placeholder", {
      sandboxMode: "workspace-write",
      approvalPolicy: "on-request",
      model: "codex",
    });

    const child = fakeChildren[0];
    await tick();

    const initReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: initReq.id, result: {} })}\n`,
    );

    await tick();
    nextOutgoingNotification(child); // initialized

    const startReq = nextOutgoingRequest(child);
    expect(startReq.method).toBe("thread/start");
    expect(startReq.params).not.toHaveProperty("model");

    child.stdout.emit(
      "data",
      `${JSON.stringify({
        id: startReq.id,
        result: { thread: { id: "thr_placeholder" } },
      })}\n`,
    );

    await tick();
    drainSkillsList(child);

    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "system",
        subtype: "init",
        provider: "codex",
        sessionId: "thr_placeholder",
      }),
    );
    expect(messages).not.toContainEqual(
      expect.objectContaining({
        type: "system",
        subtype: "init",
        model: "codex",
      }),
    );

    (proc as any)._nativePlanModeSupport = "unsupported";
    proc.sendInput("continue", "mobile-message-loop");
    await tick();
    const turnReq = nextOutgoingRequest(child);
    expect(turnReq.method).toBe("turn/start");
    expect(turnReq.params).not.toHaveProperty("model");
    expect(turnReq.params).toHaveProperty(
      "clientUserMessageId",
      "mobile-message-loop",
    );
    expect(turnReq.params).not.toHaveProperty("collaborationMode");

    proc.stop();
  });

  it("can initialize app-server without starting a thread", async () => {
    const proc = new CodexProcess("linux");

    const initializePromise = proc.initializeOnly("/tmp/project-init-only");

    expect(spawnMock).toHaveBeenCalledTimes(1);
    expect(spawnMock).toHaveBeenCalledWith(
      "codex",
      ["app-server", "--listen", "stdio://"],
      expect.objectContaining({ cwd: "/tmp/project-init-only" }),
    );

    const child = fakeChildren[0];
    await tick();

    const initReq = nextOutgoingRequest(child);
    expect(initReq.method).toBe("initialize");
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: initReq.id, result: {} })}\n`,
    );

    await initializePromise;

    const initialized = nextOutgoingNotification(child);
    expect(initialized.method).toBe("initialized");
    expect(() => nextOutgoingRequest(child)).toThrow();

    proc.stop();
  });

  it("removes timed-out RPCs so late replies cannot poison later requests", async () => {
    vi.useFakeTimers();
    const clearTimeoutSpy = vi.spyOn(globalThis, "clearTimeout");
    const proc = new CodexProcess("linux");
    try {
      const child = new FakeChildProcess();
      fakeChildren.push(child);
      const internal = proc as any;
      attachFakeTransport(internal, child);

      const firstPromise = internal.request(
        "account/rateLimits/read",
        {},
        { timeoutMs: 25 },
      ) as Promise<unknown>;
      const firstRequest = nextOutgoingRequest(child);
      const firstTimer = internal.pendingRpc.get(firstRequest.id)?.timeout;
      expect(firstTimer).toBeDefined();
      const firstRejection = expect(firstPromise).rejects.toThrow(
        "account/rateLimits/read timed out after 25ms",
      );
      await vi.advanceTimersByTimeAsync(25);
      await firstRejection;
      expect(internal.pendingRpc.size).toBe(0);
      expect(clearTimeoutSpy).toHaveBeenCalledWith(firstTimer);

      internal.handleRpcResponse({
        id: firstRequest.id,
        result: { late: true },
      });
      expect(internal.pendingRpc.size).toBe(0);

      const secondPromise = internal.request(
        "model/list",
        {},
        { timeoutMs: 25 },
      ) as Promise<unknown>;
      const secondRequest = nextOutgoingRequest(child);
      const secondTimer = internal.pendingRpc.get(secondRequest.id)?.timeout;
      expect(secondTimer).toBeDefined();
      internal.handleRpcResponse({
        id: secondRequest.id,
        result: { data: [] },
      });
      await expect(secondPromise).resolves.toEqual({ data: [] });
      expect(internal.pendingRpc.size).toBe(0);
      expect(clearTimeoutSpy).toHaveBeenCalledWith(secondTimer);
    } finally {
      proc.stop();
      clearTimeoutSpy.mockRestore();
      vi.useRealTimers();
    }
  });

  it("preserves RPC method/code and removes an aborted pending read", async () => {
    const proc = new CodexProcess("linux");
    const child = new FakeChildProcess();
    fakeChildren.push(child);
    const internal = proc as any;
    attachFakeTransport(internal, child);

    const failed = proc.requestReadOnlyRpc("thread/list", {});
    const failedRequest = nextOutgoingRequest(child);
    internal.handleRpcResponse({
      id: failedRequest.id,
      error: { code: -32601, message: "Method not found" },
    });
    const rpcError = await failed.catch((error) => error);
    expect(rpcError).toBeInstanceOf(CodexRpcError);
    expect(rpcError).toMatchObject({
      method: "thread/list",
      code: -32601,
    });

    const abort = new AbortController();
    const pending = proc.requestReadOnlyRpc(
      "thread/read",
      {},
      {
        signal: abort.signal,
      },
    );
    nextOutgoingRequest(child);
    abort.abort(new Error("client closed"));
    await expect(pending).rejects.toThrow("client closed");
    expect(internal.pendingRpc.size).toBe(0);
    proc.stop();
  });

  it("stops initialize-only runtimes and clears pending RPCs on timeout", async () => {
    vi.useFakeTimers();
    const clearTimeoutSpy = vi.spyOn(globalThis, "clearTimeout");
    const proc = new CodexProcess("linux");
    try {
      const initializePromise = proc.initializeOnly(
        "/tmp/project-init-timeout",
        25,
      );
      const child = fakeChildren[0];
      await tick();
      const initializeRequest = nextOutgoingRequest(child);
      expect(initializeRequest.method).toBe("initialize");
      const initializeTimer = (proc as any).pendingRpc.get(
        initializeRequest.id,
      )?.timeout;
      expect(initializeTimer).toBeDefined();

      const rejection = expect(initializePromise).rejects.toThrow(
        "initialize timed out after 25ms",
      );
      await vi.advanceTimersByTimeAsync(25);
      await rejection;

      expect(child.killed).toBe(true);
      expect((proc as any).pendingRpc.size).toBe(0);
      expect(clearTimeoutSpy).toHaveBeenCalledWith(initializeTimer);
    } finally {
      proc.stop();
      clearTimeoutSpy.mockRestore();
      vi.useRealTimers();
    }
  });

  it("emits user_input for app-server user items from another client", async () => {
    const proc = new CodexProcess("linux");
    const messages: unknown[] = [];
    proc.on("message", (msg) => messages.push(msg));

    proc.start("/tmp/project-copresence");
    const child = fakeChildren[0];
    await tick();

    const initReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: initReq.id, result: {} })}\n`,
    );
    await tick();
    nextOutgoingNotification(child);
    const startReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({
        id: startReq.id,
        result: { thread: { id: "thr_copresence" } },
      })}\n`,
    );
    await tick();

    child.stdout.emit(
      "data",
      `${JSON.stringify({
        method: "item/completed",
        params: {
          threadId: "thr_copresence",
          item: {
            id: "user_1",
            type: "user_message",
            content: [{ type: "text", text: "sent from terminal" }],
            timestamp: "2026-05-12T10:00:00.000Z",
          },
        },
      })}\n`,
    );
    await tick();

    expect(messages).toContainEqual({
      type: "user_input",
      text: "sent from terminal",
      userMessageUuid: "user_1",
      timestamp: "2026-05-12T10:00:00.000Z",
    });

    proc.stop();
  });

  it("ignores app-server notifications for other threads", async () => {
    const proc = new CodexProcess("linux");
    const messages: unknown[] = [];
    proc.on("message", (msg) => messages.push(msg));

    proc.start("/tmp/project-thread-filter");
    const child = fakeChildren[0];
    await tick();

    const initReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: initReq.id, result: {} })}\n`,
    );
    await tick();
    nextOutgoingNotification(child);
    const startReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({
        id: startReq.id,
        result: {
          thread: {
            id: "thr_self",
            agentNickname: "self-agent",
            agentRole: "primary",
          },
        },
      })}\n`,
    );
    await tick();

    expect(proc.sessionId).toBe("thr_self");
    expect(proc.agentNickname).toBe("self-agent");
    expect(proc.agentRole).toBe("primary");

    child.stdout.emit(
      "data",
      `${JSON.stringify({
        method: "thread/started",
        params: {
          threadId: "thr_other",
          thread: {
            id: "thr_other",
            agentNickname: "other-agent",
            agentRole: "secondary",
          },
        },
      })}\n`,
    );
    child.stdout.emit(
      "data",
      `${JSON.stringify({
        method: "turn/started",
        params: { threadId: "thr_other", turn: { id: "turn_other" } },
      })}\n`,
    );
    child.stdout.emit(
      "data",
      `${JSON.stringify({
        method: "item/completed",
        params: {
          threadId: "thr_other",
          item: {
            id: "user_other",
            type: "userMessage",
            content: [{ type: "text", text: "foreign input" }],
          },
        },
      })}\n`,
    );
    await tick();

    expect(proc.sessionId).toBe("thr_self");
    expect(proc.agentNickname).toBe("self-agent");
    expect(proc.agentRole).toBe("primary");
    expect(messages).not.toContainEqual(
      expect.objectContaining({ text: "foreign input" }),
    );

    child.stdout.emit(
      "data",
      `${JSON.stringify({
        method: "item/completed",
        params: {
          threadId: "thr_self",
          item: {
            id: "user_self",
            type: "userMessage",
            content: [{ type: "text", text: "own input" }],
          },
        },
      })}\n`,
    );
    await tick();

    expect(messages).toContainEqual({
      type: "user_input",
      text: "own input",
      userMessageUuid: "user_self",
    });

    proc.stop();
  });

  it("lists available models via model/list pagination", async () => {
    const proc = new CodexProcess("linux");
    const initializePromise = proc.initializeOnly("/tmp/project-model-list");

    const child = fakeChildren[0];
    await tick();

    const initReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: initReq.id, result: {} })}\n`,
    );
    await initializePromise;
    nextOutgoingNotification(child);

    const modelsPromise = proc.listAvailableModelMetadata();
    await tick();

    const firstReq = nextOutgoingRequest(child);
    expect(firstReq.method).toBe("model/list");
    expect(firstReq.params).toEqual({
      limit: 100,
      cursor: null,
      includeHidden: false,
    });
    child.stdout.emit(
      "data",
      `${JSON.stringify({
        id: firstReq.id,
        result: {
          data: [
            {
              model: "gpt-5.5",
              id: "ignored",
              hidden: false,
              supportedReasoningEfforts: [
                {
                  reasoningEffort: "low",
                  description: "Fast responses with lighter reasoning",
                },
                {
                  reasoningEffort: "medium",
                  description: "Balances speed and reasoning depth",
                },
                {
                  reasoningEffort: "max",
                  description: "Maximum reasoning depth",
                },
                {
                  reasoningEffort: "ultra",
                  description: "Maximum reasoning with automatic delegation",
                },
              ],
              defaultReasoningEffort: "medium",
              additionalSpeedTiers: ["fast"],
              serviceTiers: [
                { id: "priority", name: "Fast", description: "1.5x speed" },
              ],
              defaultServiceTier: "fast",
            },
            { model: "gpt-hidden", hidden: true },
            { model: "gpt-5.5", hidden: false },
          ],
          nextCursor: "1",
        },
      })}\n`,
    );

    await tick();
    const secondReq = nextOutgoingRequest(child);
    expect(secondReq.method).toBe("model/list");
    expect(secondReq.params).toEqual({
      limit: 100,
      cursor: "1",
      includeHidden: false,
    });
    child.stdout.emit(
      "data",
      `${JSON.stringify({
        id: secondReq.id,
        result: {
          data: [
            {
              id: "gpt-5.4-mini",
              hidden: false,
              supported_reasoning_levels: ["low", "medium"],
              default_reasoning_effort: "low",
            },
          ],
          nextCursor: null,
        },
      })}\n`,
    );

    await expect(modelsPromise).resolves.toEqual([
      {
        model: "gpt-5.5",
        supportedReasoningEfforts: ["low", "medium", "max", "ultra"],
        defaultReasoningEffort: "medium",
        supportedServiceTiers: ["fast"],
        defaultServiceTier: "fast",
      },
      {
        model: "gpt-5.4-mini",
        supportedReasoningEfforts: ["low", "medium"],
        defaultReasoningEffort: "low",
        supportedServiceTiers: [],
      },
    ]);
    proc.stop();
  });

  it("sends reasoning effort on turn/start in default mode", async () => {
    const proc = new CodexProcess("linux");

    proc.start("/tmp/project-default-effort", {
      sandboxMode: "workspace-write",
      approvalPolicy: "on-request",
      modelReasoningEffort: "high",
    });

    const child = fakeChildren[0];
    await tick();

    const initReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: initReq.id, result: {} })}\n`,
    );
    await tick();
    nextOutgoingNotification(child); // initialized

    const startReq = nextOutgoingRequest(child);
    expect(startReq.params).toMatchObject({
      config: {
        model_reasoning_effort: "high",
      },
    });
    child.stdout.emit(
      "data",
      `${JSON.stringify({
        id: startReq.id,
        result: {
          thread: { id: "thr_default_effort" },
          reasoningEffort: "high",
        },
      })}\n`,
    );

    await tick();
    drainSkillsList(child);

    (proc as any)._nativePlanModeSupport = "unsupported";
    proc.sendInput("continue");
    await tick();
    const turnReq = nextOutgoingRequest(child);
    expect(turnReq.method).toBe("turn/start");
    expect(turnReq.params).toMatchObject({ effort: "high" });
    expect(turnReq.params).not.toHaveProperty("collaborationMode");

    proc.stop();
  });

  it("uses runtime model settings on the next turn/start", async () => {
    const proc = new CodexProcess("linux");

    proc.start("/tmp/project-runtime-model", {
      sandboxMode: "workspace-write",
      approvalPolicy: "on-request",
      model: "gpt-5.5",
      modelReasoningEffort: "high",
    });

    const child = fakeChildren[0];
    await tick();

    const initReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: initReq.id, result: {} })}\n`,
    );
    await tick();
    nextOutgoingNotification(child); // initialized

    const startReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({
        id: startReq.id,
        result: {
          thread: { id: "thr_runtime_model", model: "gpt-5.5" },
          reasoningEffort: "high",
        },
      })}\n`,
    );

    await tick();
    drainSkillsList(child);

    (proc as any)._nativePlanModeSupport = "supported";
    proc.setModel("gpt-5.6-sol", "ultra");
    proc.setServiceTier("fast");
    proc.sendInput("continue with ultra reasoning at fast speed");
    await tick();

    const turnReq = nextOutgoingRequest(child);
    expect(turnReq.method).toBe("turn/start");
    expect(turnReq.params).toMatchObject({
      model: "gpt-5.6-sol",
      effort: "ultra",
      serviceTier: "fast",
      collaborationMode: {
        mode: "default",
        settings: {
          model: "gpt-5.6-sol",
          reasoning_effort: "ultra",
        },
      },
    });

    proc.stop();
  });

  it("encodes Standard as null on the next turn/start", async () => {
    const proc = new CodexProcess("linux");

    proc.start("/tmp/project-standard-tier", {
      sandboxMode: "workspace-write",
      approvalPolicy: "on-request",
      model: "gpt-5.6-sol",
      modelReasoningEffort: "ultra",
      serviceTier: "fast",
    });

    const child = fakeChildren[0];
    await tick();
    const initReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: initReq.id, result: {} })}\n`,
    );
    await tick();
    nextOutgoingNotification(child);
    const startReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({
        id: startReq.id,
        result: {
          thread: { id: "thr_standard_tier", model: "gpt-5.6-sol" },
          reasoningEffort: "ultra",
          serviceTier: "fast",
        },
      })}\n`,
    );

    await tick();
    drainSkillsList(child);
    (proc as any)._nativePlanModeSupport = "unsupported";
    proc.setServiceTier("standard");
    proc.sendInput("continue at standard speed");
    await tick();

    const turnReq = nextOutgoingRequest(child);
    expect(turnReq.method).toBe("turn/start");
    expect(turnReq.params).toMatchObject({
      model: "gpt-5.6-sol",
      effort: "ultra",
      serviceTier: null,
    });
    expect(turnReq.params).not.toHaveProperty("collaborationMode");

    proc.stop();
  });

  it("does not downgrade reasoning effort to medium in plan mode", async () => {
    const proc = new CodexProcess("linux");

    proc.start("/tmp/project-plan-effort", {
      sandboxMode: "workspace-write",
      approvalPolicy: "on-request",
      modelReasoningEffort: "xhigh",
      collaborationMode: "plan",
    });

    const child = fakeChildren[0];
    await tick();

    const initReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: initReq.id, result: {} })}\n`,
    );
    await tick();
    nextOutgoingNotification(child); // initialized

    const planProbeReq = nextOutgoingRequest(child);
    expect(planProbeReq.method).toBe("collaborationMode/list");
    expect(planProbeReq.params).toEqual({});
    child.stdout.emit(
      "data",
      `${JSON.stringify({
        id: planProbeReq.id,
        result: { data: [{ name: "Plan", mode: "plan" }] },
      })}\n`,
    );
    const startReq = await waitForOutgoingRequest(child, "thread/start");
    expect(startReq.params).toMatchObject({
      config: {
        model_reasoning_effort: "xhigh",
      },
    });
    child.stdout.emit(
      "data",
      `${JSON.stringify({
        id: startReq.id,
        result: {
          thread: { id: "thr_plan_effort" },
          reasoningEffort: "xhigh",
        },
      })}\n`,
    );

    await tick();
    drainSkillsList(child);

    proc.sendInput("plan this");
    await tick();
    const turnReq = nextOutgoingRequest(child);
    expect(turnReq.method).toBe("turn/start");
    expect(turnReq.params).toMatchObject({
      effort: "xhigh",
      collaborationMode: {
        mode: "plan",
        settings: {
          model: "gpt-5.5",
          reasoning_effort: "xhigh",
        },
      },
    });

    proc.stop();
  });

  it("does not start a requested Plan conversation on an older app-server", async () => {
    const proc = new CodexProcess("linux");
    const messages: unknown[] = [];
    const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    proc.on("message", (message) => messages.push(message));

    try {
      proc.start("/tmp/project-plan-unsupported", {
        collaborationMode: "plan",
      });
      const child = fakeChildren[0];
      await tick();
      const initReq = nextOutgoingRequest(child);
      child.stdout.emit(
        "data",
        `${JSON.stringify({ id: initReq.id, result: {} })}\n`,
      );
      await tick();
      nextOutgoingNotification(child);
      const probeReq = nextOutgoingRequest(child);
      expect(probeReq.method).toBe("collaborationMode/list");
      child.stdout.emit(
        "data",
        `${JSON.stringify({
          id: probeReq.id,
          error: { code: -32601, message: "Method not found" },
        })}\n`,
      );
      for (
        let attempt = 0;
        attempt < 10 &&
        !messages.some(
          (message) =>
            typeof message === "object" &&
            message !== null &&
            (message as { errorCode?: unknown }).errorCode ===
              "codex_native_plan_mode_unsupported",
        );
        attempt++
      ) {
        await tick();
      }

      expect(messages).toContainEqual(
        expect.objectContaining({
          type: "error",
          errorCode: "codex_native_plan_mode_unsupported",
          message: expect.stringContaining(
            "Native Codex Plan mode is unavailable",
          ),
        }),
      );
      expect(proc.supportsNativePlanMode).toBe(false);
      expect(proc.collaborationMode).toBe("default");
      expect(() => nextOutgoingRequest(child)).toThrow();
    } finally {
      errorSpy.mockRestore();
      proc.stop();
    }
  });

  it("emits permission_request and responds on approve", async () => {
    const proc = new CodexProcess("linux");
    const messages: unknown[] = [];
    proc.on("message", (msg) => messages.push(msg));

    proc.start("/tmp/project-b");
    const child = fakeChildren[0];

    await tick();
    const initReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: initReq.id, result: {} })}\n`,
    );
    await tick();
    nextOutgoingNotification(child); // initialized
    const threadReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: threadReq.id, result: { thread: { id: "thr_2" } } })}\n`,
    );

    await tick();
    drainSkillsList(child);
    proc.sendInput("run ls");
    await tick();
    const turnReq = nextOutgoingRequest(child);
    expect(turnReq.method).toBe("turn/start");

    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: turnReq.id, result: { turn: { id: "turn_1" } } })}\n`,
    );
    child.stdout.emit(
      "data",
      `${JSON.stringify({ method: "turn/started", params: { turn: { id: "turn_1" } } })}\n`,
    );
    child.stdout.emit(
      "data",
      `${JSON.stringify({
        id: "req-approval-1",
        method: "item/commandExecution/requestApproval",
        params: {
          itemId: "item_cmd_1",
          command: "ls -la",
          cwd: "/tmp/project-b",
        },
      })}\n`,
    );

    await tick();

    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "permission_request",
        toolUseId: "item_cmd_1",
        toolName: "Bash",
      }),
    );

    proc.approve("item_cmd_1");
    await tick();
    const approvalResponse = nextOutgoingResponse(child);
    expect(approvalResponse).toMatchObject({
      id: "req-approval-1",
      result: { decision: "accept" },
    });

    child.stdout.emit(
      "data",
      `${JSON.stringify({
        method: "turn/completed",
        params: { turn: { id: "turn_1", status: "completed" } },
      })}\n`,
    );

    await tick();

    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "result",
        subtype: "success",
        sessionId: "thr_2",
      }),
    );

    proc.stop();
  });

  it("keeps waiting while another interactive request remains", async () => {
    const proc = new CodexProcess("linux");
    const child = new FakeChildProcess();
    attachFakeTransport(proc as any, child);

    (proc as any).handleServerRequest(
      "req-command-concurrent",
      "item/commandExecution/requestApproval",
      {
        itemId: "item-command-concurrent",
        command: "pwd",
      },
    );
    (proc as any).handleServerRequest(
      "req-question-concurrent",
      "item/tool/requestUserInput",
      {
        itemId: "item-question-concurrent",
        questions: [
          {
            id: "q1",
            header: "Choice",
            question: "Pick one option",
            options: [{ label: "A", description: "Option A" }],
          },
        ],
      },
    );

    expect(proc.status).toBe("waiting_approval");
    proc.approve("item-command-concurrent");

    expect(nextOutgoingResponse(child)).toMatchObject({
      id: "req-command-concurrent",
      result: { decision: "accept" },
    });
    expect(proc.status).toBe("waiting_approval");
    expect(proc.getPendingPermission()).toMatchObject({
      toolUseId: "item-question-concurrent",
      toolName: "AskUserQuestion",
    });

    proc.answer("item-question-concurrent", "A");

    expect(nextOutgoingResponse(child)).toMatchObject({
      id: "req-question-concurrent",
      result: { answers: { q1: { answers: ["A"] } } },
    });
    expect(proc.status).toBe("running");
  });

  it("defers approved plan execution until every interaction is resolved", () => {
    const proc = new CodexProcess("linux");
    const child = new FakeChildProcess();
    attachFakeTransport(proc as any, child);
    const resumedInputs: Array<{ text: string }> = [];
    (proc as any).inputResolve = (input: { text: string }) => {
      resumedInputs.push(input);
    };
    (proc as any).pendingPlanCompletion = {
      toolUseId: "plan-concurrent",
      planText: "Run the verified plan",
    };
    (proc as any).handleServerRequest(
      "req-command-plan-concurrent",
      "item/commandExecution/requestApproval",
      { itemId: "command-plan-concurrent", command: "pwd" },
    );
    (proc as any).handleServerRequest(
      "req-question-plan-concurrent",
      "item/tool/requestUserInput",
      {
        itemId: "question-plan-concurrent",
        questions: [
          {
            id: "q1",
            header: "Choice",
            question: "Pick one option",
            options: [{ label: "A", description: "Option A" }],
          },
        ],
      },
    );

    proc.approve("plan-concurrent");
    expect(resumedInputs).toEqual([]);
    expect(proc.status).toBe("waiting_approval");

    proc.approve("command-plan-concurrent");
    expect(resumedInputs).toEqual([]);
    expect(proc.status).toBe("waiting_approval");

    proc.answer("question-plan-concurrent", "A");
    expect(resumedInputs).toEqual([
      { text: "Execute the following plan:\n\nRun the verified plan" },
    ]);
  });

  it("emits AskUserQuestion and responds on answer", async () => {
    const proc = new CodexProcess("linux");
    const messages: unknown[] = [];
    proc.on("message", (msg) => messages.push(msg));

    proc.start("/tmp/project-c");
    const child = fakeChildren[0];

    await tick();
    const initReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: initReq.id, result: {} })}\n`,
    );
    await tick();
    nextOutgoingNotification(child); // initialized
    const threadReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: threadReq.id, result: { thread: { id: "thr_3" } } })}\n`,
    );

    await tick();
    drainSkillsList(child);
    proc.sendInput("ask me a question");
    await tick();
    const turnReq = nextOutgoingRequest(child);
    expect(turnReq.method).toBe("turn/start");
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: turnReq.id, result: { turn: { id: "turn_2" } } })}\n`,
    );
    child.stdout.emit(
      "data",
      `${JSON.stringify({ method: "turn/started", params: { turn: { id: "turn_2" } } })}\n`,
    );

    child.stdout.emit(
      "data",
      `${JSON.stringify({
        id: "req-user-input-1",
        method: "item/tool/requestUserInput",
        params: {
          itemId: "item_user_input_1",
          questions: [
            {
              id: "q1",
              header: "Runtime",
              question: "Pick one option",
              options: [
                { label: "A", description: "Option A" },
                { label: "B", description: "Option B" },
              ],
            },
          ],
          threadId: "thr_3",
          turnId: "turn_2",
        },
      })}\n`,
    );

    await tick();

    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "permission_request",
        toolUseId: "item_user_input_1",
        toolName: "AskUserQuestion",
      }),
    );

    proc.answer("item_user_input_1", "A");
    await tick();
    const answerResponse = nextOutgoingResponse(child);
    expect(answerResponse).toMatchObject({
      id: "req-user-input-1",
      result: {
        answers: {
          q1: { answers: ["A"] },
        },
      },
    });

    child.stdout.emit(
      "data",
      `${JSON.stringify({
        method: "turn/completed",
        params: { turn: { id: "turn_2", status: "completed" } },
      })}\n`,
    );
    await tick();

    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "result",
        subtype: "success",
        sessionId: "thr_3",
      }),
    );

    proc.stop();
  });

  it("responds to permission grants with granted scope and requested permissions", async () => {
    const proc = new CodexProcess("linux");
    const messages: unknown[] = [];
    proc.on("message", (msg) => messages.push(msg));

    proc.start("/tmp/project-perms");
    const child = fakeChildren[0];

    await tick();
    const initReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: initReq.id, result: {} })}\n`,
    );
    await tick();
    nextOutgoingNotification(child);
    const threadReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: threadReq.id, result: { thread: { id: "thr_perms" } } })}\n`,
    );

    await tick();
    child.stdout.emit(
      "data",
      `${JSON.stringify({
        id: "req-perms-1",
        method: "item/permissions/requestApproval",
        params: {
          itemId: "perm_item_1",
          threadId: "thr_perms",
          turnId: "turn_perms",
          reason: "Need write access",
          permissions: {
            fileSystem: {
              write: ["/tmp/project-perms"],
            },
          },
        },
      })}\n`,
    );

    await tick();

    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "permission_request",
        toolUseId: "perm_item_1",
        toolName: "Permissions",
      }),
    );

    proc.approveAlways("perm_item_1");
    await tick();

    const response = nextOutgoingResponse(child);
    expect(response).toMatchObject({
      id: "req-perms-1",
      result: {
        scope: "session",
        permissions: {
          fileSystem: {
            write: ["/tmp/project-perms"],
          },
        },
      },
    });

    proc.stop();
  });

  it("maps MCP elicitation form requests to answer flow", async () => {
    const proc = new CodexProcess("linux");
    const messages: unknown[] = [];
    proc.on("message", (msg) => messages.push(msg));

    proc.start("/tmp/project-elicitation");
    const child = fakeChildren[0];

    await tick();
    const initReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: initReq.id, result: {} })}\n`,
    );
    await tick();
    nextOutgoingNotification(child);
    const threadReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: threadReq.id, result: { thread: { id: "thr_elicit" } } })}\n`,
    );

    await tick();
    child.stdout.emit(
      "data",
      `${JSON.stringify({
        id: "req-elicit-1",
        method: "mcpServer/elicitation/request",
        params: {
          threadId: "thr_elicit",
          turnId: "turn_elicit",
          serverName: "codex_apps",
          mode: "form",
          message: "Confirm this operation",
          requestedSchema: {
            type: "object",
            properties: {
              confirmed: {
                type: "boolean",
                title: "Confirmed",
                description: "Whether to continue",
              },
              count: { type: "number", title: "Count" },
              location: { type: "string", title: "Location" },
              retries: { type: "integer", title: "Retries" },
              note: { type: "string", title: "Note" },
              scope: {
                type: "string",
                title: "Scope",
                oneOf: [
                  { const: "repo", title: "Repository" },
                  { const: "org", title: "Organization" },
                ],
              },
              channels: {
                type: "array",
                title: "Channels",
                items: {
                  anyOf: [
                    { const: "issues", title: "Issues" },
                    { const: "pulls", title: "Pull requests" },
                  ],
                },
              },
            },
            required: ["confirmed", "count", "location"],
          },
        },
      })}\n`,
    );

    await tick();

    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "permission_request",
        toolUseId: "req-elicit-1",
        toolName: "McpElicitation",
      }),
    );
    expect(proc.getPendingPermission("req-elicit-1")).toMatchObject({
      toolUseId: "req-elicit-1",
      toolName: "McpElicitation",
      input: {
        questions: expect.arrayContaining([
          expect.objectContaining({
            id: "scope",
            required: false,
            options: expect.arrayContaining([
              expect.objectContaining({ label: "Repository", value: "repo" }),
            ]),
          }),
          expect.objectContaining({
            id: "channels",
            multiSelect: true,
          }),
        ]),
      },
    });

    proc.answer(
      "req-elicit-1",
      JSON.stringify({
        answers: {
          confirmed: "true",
          count: "3.5",
          location: "Tokyo, Japan",
          retries: "2.5",
          note: "",
          scope: "repo",
          channels: ["issues", "pulls"],
        },
      }),
    );
    await tick();

    const response = nextOutgoingResponse(child);
    expect(response).toMatchObject({
      id: "req-elicit-1",
      result: {
        action: "accept",
        content: {
          confirmed: true,
          count: 3.5,
          location: "Tokyo, Japan",
          scope: "repo",
          channels: ["issues", "pulls"],
        },
      },
    });
    expect((response.result as any).content).not.toHaveProperty("retries");
    expect((response.result as any).content).not.toHaveProperty("note");

    proc.stop();
  });

  it("responds to current time requests with Unix seconds", () => {
    const proc = new CodexProcess("linux");
    const child = new FakeChildProcess();
    attachFakeTransport(proc as any, child);

    (proc as any).handleServerRequest("time-1", "currentTime/read", {
      threadId: "thr_time",
    });

    expect(nextOutgoingResponse(child)).toEqual({
      id: "time-1",
      result: { currentTimeAt: expect.any(Number) },
    });
    proc.stop();
  });

  it("rejects unsupported server requests instead of returning empty success", () => {
    const proc = new CodexProcess("linux");
    const child = new FakeChildProcess();
    attachFakeTransport(proc as any, child);

    (proc as any).handleServerRequest("unknown-1", "future/request", {});

    expect(nextOutgoingError(child)).toEqual({
      id: "unknown-1",
      error: {
        code: -32601,
        message: "Unsupported server request: future/request",
      },
    });
    proc.stop();
  });

  it("surfaces Codex warnings and completed review output", () => {
    const proc = new CodexProcess("linux");
    const messages: unknown[] = [];
    proc.on("message", (message) => messages.push(message));

    (proc as any).handleNotification("configWarning", {
      summary: "Invalid rule",
      details: "Check .codex/rules/default.rules",
    });
    (proc as any).processItemCompleted({
      type: "exitedReviewMode",
      id: "review-1",
      review: "Review complete: no findings.",
    });

    expect(messages).toContainEqual({
      type: "error",
      errorCode: "codex_warning",
      message: "Invalid rule\nCheck .codex/rules/default.rules",
    });
    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "assistant",
        message: expect.objectContaining({
          id: "review-1",
          content: [{ type: "text", text: "Review complete: no findings." }],
        }),
      }),
    );
    proc.stop();
  });

  it("suppresses low-risk guardian allow decisions", async () => {
    vi.useFakeTimers();
    const proc = new CodexProcess("linux");
    const messages: unknown[] = [];
    proc.on("message", (message) => messages.push(message));
    try {
      (proc as any).handleNotification("guardianWarning", {
        message:
          "Automatic approval review approved (risk: low, authorization: unknown):\nAuto-review returned a\n  low-risk   allow decision.",
      });
      await vi.runAllTimersAsync();
      expect(messages).toEqual([]);
    } finally {
      proc.stop();
      vi.useRealTimers();
    }
  });

  it.each([
    [
      "medium",
      "medium",
      "Launching the Flutter app writes build files outside the workspace.",
    ],
    [
      "high",
      "high",
      "Running this command can change files outside the workspace.",
    ],
  ] as const)(
    "surfaces %s-risk guardian approvals as dedicated notices",
    async (risk, authorization, reason) => {
      vi.useFakeTimers();
      const proc = new CodexProcess("linux");
      const messages: unknown[] = [];
      proc.on("message", (message) => messages.push(message));
      try {
        (proc as any).handleNotification("guardianWarning", {
          message: `Automatic approval review approved (risk: ${risk}, authorization: ${authorization}):\n${reason}`,
        });
        await vi.runAllTimersAsync();

        expect(messages).toEqual([
          {
            type: "guardian_approval",
            risk,
            authorization,
            reason,
            status: "approved",
          },
        ]);
      } finally {
        proc.stop();
        vi.useRealTimers();
      }
    },
  );

  it("keeps a custom low-risk review compact while preserving legacy fallback", async () => {
    vi.useFakeTimers();
    const proc = new CodexProcess("linux");
    const messages: unknown[] = [];
    proc.on("message", (message) => messages.push(message));
    const message =
      "Automatic approval review approved (risk: low, authorization: high):\n" +
      "The command only lists local simulator database metadata.";
    try {
      (proc as any).handleNotification("guardianWarning", { message });
      await vi.runAllTimersAsync();

      expect(messages).toEqual([
        {
          type: "error",
          errorCode: "codex_warning",
          message,
          guardianReview: {
            status: "approved",
            risk: "low",
            authorization: "high",
            reason: "The command only lists local simulator database metadata.",
          },
        },
      ]);
    } finally {
      proc.stop();
      vi.useRealTimers();
    }
  });

  it("merges the legacy warning with structured action details", async () => {
    vi.useFakeTimers();
    const proc = new CodexProcess("linux");
    const messages: unknown[] = [];
    proc.on("message", (message) => messages.push(message));
    const reason =
      "The command reads simulator metadata without modifying the database.";
    const action = {
      type: "command",
      command: "ls -la /tmp/simulator.db*",
      cwd: "/tmp",
      source: "shell",
    };
    try {
      (proc as any).handleNotification("guardianWarning", {
        message:
          "Automatic approval review approved (risk: medium, authorization: high): " +
          reason,
      });
      (proc as any).handleNotification("item/autoApprovalReview/completed", {
        reviewId: "guardian-1",
        targetItemId: "command-1",
        review: {
          status: "approved",
          riskLevel: null,
          userAuthorization: null,
          rationale: null,
        },
        action,
      });
      await vi.runAllTimersAsync();

      expect(messages).toEqual([
        {
          type: "guardian_approval",
          status: "approved",
          risk: "medium",
          authorization: "high",
          reason,
          reviewId: "guardian-1",
          targetItemId: "command-1",
          action,
        },
      ]);
    } finally {
      proc.stop();
      vi.useRealTimers();
    }
  });

  it("ignores guardian review events for other threads", async () => {
    vi.useFakeTimers();
    const proc = new CodexProcess("linux");
    const messages: unknown[] = [];
    proc.on("message", (message) => messages.push(message));
    (proc as any)._threadId = "thread-self";
    const reason = "The command reads metadata.";
    try {
      (proc as any).handleNotification("guardianWarning", {
        threadId: "thread-other",
        message:
          "Automatic approval review approved (risk: medium, authorization: high): " +
          reason,
      });
      (proc as any).handleNotification("item/autoApprovalReview/completed", {
        threadId: "thread-other",
        reviewId: "guardian-other",
        review: {
          status: "approved",
          riskLevel: "medium",
          userAuthorization: "high",
          rationale: reason,
        },
        action: {
          type: "command",
          command: "ls -la",
          cwd: "/tmp",
          source: "shell",
        },
      });
      await vi.runAllTimersAsync();

      expect(messages).toEqual([]);
    } finally {
      proc.stop();
      vi.useRealTimers();
    }
  });

  it("preserves denied reviews as localized-card metadata for new clients", async () => {
    vi.useFakeTimers();
    const proc = new CodexProcess("linux");
    const messages: unknown[] = [];
    proc.on("message", (message) => messages.push(message));
    const reason = "The command would upload source code.";
    const message =
      "Automatic approval review denied (risk: high, authorization: low): " +
      reason;
    try {
      (proc as any).handleNotification("guardianWarning", { message });
      (proc as any).handleNotification("item/autoApprovalReview/completed", {
        reviewId: "guardian-denied",
        review: {
          status: "denied",
          riskLevel: "high",
          userAuthorization: "low",
          rationale: reason,
        },
        action: {
          type: "networkAccess",
          protocol: "https",
          host: "example.com",
          port: 443,
          target: "https://example.com/upload",
        },
      });
      await vi.runAllTimersAsync();

      expect(messages).toEqual([
        {
          type: "error",
          errorCode: "codex_warning",
          message,
          guardianReview: {
            status: "denied",
            risk: "high",
            authorization: "low",
            reason,
            reviewId: "guardian-denied",
            action: {
              type: "networkAccess",
              protocol: "https",
              host: "example.com",
              port: 443,
              target: "https://example.com/upload",
            },
          },
        },
      ]);
    } finally {
      proc.stop();
      vi.useRealTimers();
    }
  });

  it("surfaces malformed approved guardian notifications as warnings", () => {
    const proc = new CodexProcess("linux");
    const messages: unknown[] = [];
    proc.on("message", (message) => messages.push(message));
    const message = "Automatic approval review approved without metadata.";

    (proc as any).handleNotification("guardianWarning", { message });

    expect(messages).toEqual([
      { type: "error", errorCode: "codex_warning", message },
    ]);
    proc.stop();
  });

  it("continues to surface actionable guardian and standard warnings", () => {
    const proc = new CodexProcess("linux");
    const messages: unknown[] = [];
    proc.on("message", (message) => messages.push(message));

    (proc as any).handleNotification("guardianWarning", {
      message: "Automatic approval review could not verify this command.",
    });
    (proc as any).handleNotification("warning", {
      message: "Model fallback is active.",
    });

    expect(messages).toContainEqual({
      type: "error",
      errorCode: "codex_warning",
      message: "Automatic approval review could not verify this command.",
    });
    expect(messages).toContainEqual({
      type: "error",
      errorCode: "codex_warning",
      message: "Model fallback is active.",
    });
    proc.stop();
  });

  it("installs a suggested remote plugin before accepting the elicitation", async () => {
    const proc = new CodexProcess("linux");
    const child = new FakeChildProcess();
    attachFakeTransport(proc as any, child);
    const messages: unknown[] = [];
    proc.on("message", (msg) => messages.push(msg));

    (proc as any).handleServerRequest(
      "req-tool-suggestion-1",
      "mcpServer/elicitation/request",
      {
        serverName: "codex_apps",
        mode: "form",
        message: "GitHub makes it easier to inspect forks.",
        requestedSchema: { type: "object", properties: {} },
        _meta: {
          codex_approval_kind: "tool_suggestion",
          persist: "always",
          tool_type: "plugin",
          suggest_type: "install",
          suggest_reason: "GitHub makes it easier to inspect forks.",
          tool_id: "github@openai-curated-remote",
          tool_name: "GitHub",
          remote_plugin_id: "plugins~github-remote-id",
          app_connector_ids: ["connector-github"],
        },
      },
    );

    expect(messages).toContainEqual({
      type: "permission_request",
      toolUseId: "req-tool-suggestion-1",
      toolName: "ToolSuggestion",
      input: expect.objectContaining({
        toolName: "GitHub",
        toolType: "plugin",
        suggestType: "install",
        installState: "idle",
      }),
    });

    const installation = proc.installToolSuggestion("req-tool-suggestion-1");
    const installRequest = nextOutgoingRequest(child);
    expect(installRequest).toMatchObject({
      method: "plugin/install",
      params: {
        remoteMarketplaceName: "openai-curated-remote",
        pluginName: "plugins~github-remote-id",
      },
    });
    (proc as any).handleRpcEnvelope({
      id: installRequest.id,
      result: { authPolicy: "ON_USE", appsNeedingAuth: [] },
    });
    await installation;

    expect(nextOutgoingResponse(child)).toEqual({
      id: "req-tool-suggestion-1",
      result: { action: "accept", content: null, _meta: null },
    });
    expect(messages).toContainEqual({
      type: "permission_resolved",
      toolUseId: "req-tool-suggestion-1",
    });
    expect(proc.getPendingPermission("req-tool-suggestion-1")).toBeUndefined();

    proc.stop();
  });

  it("does not install tool suggestions claimed by an external MCP server", async () => {
    const proc = new CodexProcess("linux");
    const child = new FakeChildProcess();
    attachFakeTransport(proc as any, child);
    const messages: unknown[] = [];
    proc.on("message", (msg) => messages.push(msg));

    (proc as any).handleServerRequest(
      "req-untrusted-tool-suggestion",
      "mcpServer/elicitation/request",
      {
        serverName: "untrusted_mcp",
        mode: "form",
        message: "Install this plugin.",
        requestedSchema: { type: "object", properties: {} },
        _meta: {
          codex_approval_kind: "tool_suggestion",
          tool_type: "plugin",
          suggest_type: "install",
          tool_id: "github@openai-curated-remote",
          tool_name: "GitHub",
          remote_plugin_id: "plugins~untrusted-id",
        },
      },
    );

    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "permission_request",
        toolUseId: "req-untrusted-tool-suggestion",
        toolName: "McpElicitation",
      }),
    );
    await expect(
      proc.installToolSuggestion("req-untrusted-tool-suggestion"),
    ).rejects.toThrow("No pending tool suggestion found");

    proc.stop();
  });

  it("keeps a tool suggestion pending until required app authentication completes", async () => {
    const proc = new CodexProcess("linux");
    const child = new FakeChildProcess();
    attachFakeTransport(proc as any, child);
    const messages: unknown[] = [];
    proc.on("message", (msg) => messages.push(msg));

    (proc as any).handleServerRequest(
      "req-tool-suggestion-auth",
      "mcpServer/elicitation/request",
      {
        serverName: "codex_apps",
        mode: "form",
        message: "Install GitHub",
        requestedSchema: { type: "object", properties: {} },
        _meta: {
          codex_approval_kind: "tool_suggestion",
          tool_type: "plugin",
          suggest_type: "install",
          tool_id: "github@openai-curated-remote",
          tool_name: "GitHub",
          remote_plugin_id: "plugins~github-remote-id",
        },
      },
    );

    const installation = proc.installToolSuggestion("req-tool-suggestion-auth");
    const installRequest = nextOutgoingRequest(child);
    (proc as any).handleRpcEnvelope({
      id: installRequest.id,
      result: {
        authPolicy: "ON_INSTALL",
        appsNeedingAuth: [
          {
            id: "connector-github",
            name: "GitHub",
            description: "Connect GitHub",
            installUrl: "https://chatgpt.com/connect/github",
            category: "Developer",
          },
        ],
      },
    });
    await installation;

    expect(proc.getPendingPermission("req-tool-suggestion-auth")).toMatchObject(
      {
        toolName: "ToolSuggestion",
        input: {
          installState: "needs_auth",
          appsNeedingAuth: [
            {
              id: "connector-github",
              name: "GitHub",
              installUrl: "https://chatgpt.com/connect/github",
            },
          ],
        },
      },
    );
    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "permission_request",
        toolUseId: "req-tool-suggestion-auth",
        input: expect.objectContaining({ installState: "needs_auth" }),
      }),
    );

    proc.approve("req-tool-suggestion-auth");
    expect(nextOutgoingResponse(child)).toEqual({
      id: "req-tool-suggestion-auth",
      result: { action: "accept", content: null, _meta: null },
    });

    proc.stop();
  });

  it("maps MCP tool approval elicitation to dynamic options and always allow response", async () => {
    const proc = new CodexProcess("linux");
    const messages: unknown[] = [];
    proc.on("message", (msg) => messages.push(msg));

    proc.start("/tmp/project-mcp-approval");
    const child = fakeChildren[0];

    await tick();
    const initReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: initReq.id, result: {} })}\n`,
    );
    await tick();
    nextOutgoingNotification(child);
    const threadReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: threadReq.id, result: { thread: { id: "thr_mcp_approval" } } })}\n`,
    );

    await tick();
    child.stdout.emit(
      "data",
      `${JSON.stringify({
        id: "req-mcp-approval-1",
        method: "mcpServer/elicitation/request",
        params: {
          threadId: "thr_mcp_approval",
          turnId: "turn_mcp_approval",
          serverName: "revenuecat",
          mode: "form",
          _meta: {
            codex_approval_kind: "mcp_tool_call",
            persist: ["session", "always"],
          },
          message:
            'Allow the revenuecat MCP server to run tool "delete-package-from-offering"?',
          requestedSchema: {
            type: "object",
            properties: {},
          },
        },
      })}\n`,
    );

    await tick();

    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "permission_request",
        toolUseId: "req-mcp-approval-1",
        toolName: "McpElicitation",
        input: expect.objectContaining({
          questions: [
            expect.objectContaining({
              header: "Approve app tool call?",
              options: [
                expect.objectContaining({ label: "Allow" }),
                expect.objectContaining({ label: "Allow for this session" }),
                expect.objectContaining({ label: "Always allow" }),
                expect.objectContaining({ label: "Cancel" }),
              ],
            }),
          ],
        }),
      }),
    );

    proc.answer("req-mcp-approval-1", "Always allow");
    await tick();

    const response = nextOutgoingResponse(child);
    expect(response).toMatchObject({
      id: "req-mcp-approval-1",
      result: {
        action: "accept",
        content: null,
        _meta: {
          persist: "always",
        },
      },
    });

    proc.stop();
  });

  it("omits session remember choices when MCP approval persist modes are absent", async () => {
    const proc = new CodexProcess("linux");
    const messages: unknown[] = [];
    proc.on("message", (msg) => messages.push(msg));

    proc.start("/tmp/project-mcp-approval-basic");
    const child = fakeChildren[0];

    await tick();
    const initReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: initReq.id, result: {} })}\n`,
    );
    await tick();
    nextOutgoingNotification(child);
    const threadReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: threadReq.id, result: { thread: { id: "thr_mcp_basic" } } })}\n`,
    );

    await tick();
    child.stdout.emit(
      "data",
      `${JSON.stringify({
        id: "req-mcp-approval-2",
        method: "mcpServer/elicitation/request",
        params: {
          threadId: "thr_mcp_basic",
          turnId: "turn_mcp_basic",
          serverName: "revenuecat",
          mode: "form",
          _meta: {
            codex_approval_kind: "mcp_tool_call",
          },
          message:
            'Allow the revenuecat MCP server to run tool "delete-package-from-offering"?',
          requestedSchema: {
            type: "object",
            properties: {},
          },
        },
      })}\n`,
    );

    await tick();

    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "permission_request",
        toolUseId: "req-mcp-approval-2",
        toolName: "McpElicitation",
        input: expect.objectContaining({
          questions: [
            expect.objectContaining({
              options: [
                expect.objectContaining({ label: "Allow" }),
                expect.objectContaining({ label: "Cancel" }),
              ],
            }),
          ],
        }),
      }),
    );

    expect(proc.getPendingPermission("req-mcp-approval-2")).toMatchObject({
      toolUseId: "req-mcp-approval-2",
      toolName: "McpElicitation",
    });

    proc.reject("req-mcp-approval-2");
    await tick();

    const response = nextOutgoingResponse(child);
    expect(response).toMatchObject({
      id: "req-mcp-approval-2",
      result: {
        action: "cancel",
        content: null,
        _meta: null,
      },
    });

    proc.stop();
  });

  it("maps message-only MCP elicitations to approval actions", async () => {
    const proc = new CodexProcess("linux");
    const messages: unknown[] = [];
    proc.on("message", (msg) => messages.push(msg));

    proc.start("/tmp/project-computer-use");
    const child = fakeChildren[0];

    await tick();
    const initReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: initReq.id, result: {} })}\n`,
    );
    await tick();
    nextOutgoingNotification(child);
    const threadReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: threadReq.id, result: { thread: { id: "thr_computer_use" } } })}\n`,
    );

    await tick();
    child.stdout.emit(
      "data",
      `${JSON.stringify({
        id: "req-computer-use-1",
        method: "mcpServer/elicitation/request",
        params: {
          threadId: "thr_computer_use",
          turnId: "turn_computer_use",
          serverName: "computer-use",
          mode: "form",
          _meta: null,
          message: "Allow Codex to use Safari?",
          requestedSchema: {
            type: "object",
            properties: {},
          },
        },
      })}\n`,
    );

    await tick();

    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "permission_request",
        toolUseId: "req-computer-use-1",
        toolName: "McpElicitation",
        input: expect.objectContaining({
          availableDecisions: ["accept", "decline"],
          questions: [
            expect.objectContaining({
              header: "Approve app tool call?",
              question: "Allow Codex to use Safari?",
              options: [
                expect.objectContaining({ label: "Allow" }),
                expect.objectContaining({ label: "Deny" }),
                expect.objectContaining({ label: "Cancel" }),
              ],
            }),
          ],
        }),
      }),
    );

    proc.approve("req-computer-use-1");
    await tick();

    const response = nextOutgoingResponse(child);
    expect(response).toMatchObject({
      id: "req-computer-use-1",
      result: {
        action: "accept",
        content: null,
        _meta: null,
      },
    });

    proc.stop();
  });

  it("clears pending requests when serverRequest/resolved arrives", async () => {
    const proc = new CodexProcess("linux");
    const messages: unknown[] = [];
    proc.on("message", (msg) => messages.push(msg));

    proc.start("/tmp/project-resolved");
    const child = fakeChildren[0];

    await tick();
    const initReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: initReq.id, result: {} })}\n`,
    );
    await tick();
    nextOutgoingNotification(child);
    const threadReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: threadReq.id, result: { thread: { id: "thr_resolved" } } })}\n`,
    );

    await tick();
    child.stdout.emit(
      "data",
      `${JSON.stringify({
        id: "req-resolved-1",
        method: "item/commandExecution/requestApproval",
        params: {
          itemId: "item_resolved_1",
          command: "pwd",
          cwd: "/tmp/project-resolved",
        },
      })}\n`,
    );

    await tick();
    child.stdout.emit(
      "data",
      `${JSON.stringify({
        method: "serverRequest/resolved",
        params: {
          threadId: "thr_resolved",
          requestId: "req-resolved-1",
        },
      })}\n`,
    );
    await tick();

    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "permission_resolved",
        toolUseId: "item_resolved_1",
      }),
    );

    proc.stop();
  });

  it("uses acceptForSession for command approvals", async () => {
    const proc = new CodexProcess("linux");

    proc.start("/tmp/project-approve-always");
    const child = fakeChildren[0];

    await tick();
    const initReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: initReq.id, result: {} })}\n`,
    );
    await tick();
    nextOutgoingNotification(child);
    const threadReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: threadReq.id, result: { thread: { id: "thr_always" } } })}\n`,
    );

    await tick();
    child.stdout.emit(
      "data",
      `${JSON.stringify({
        id: "req-always-1",
        method: "item/commandExecution/requestApproval",
        params: {
          itemId: "item_always_1",
          command: "git status",
          cwd: "/tmp/project-approve-always",
        },
      })}\n`,
    );

    await tick();
    proc.approveAlways("item_always_1");
    await tick();

    const response = nextOutgoingResponse(child);
    expect(response).toMatchObject({
      id: "req-always-1",
      result: { decision: "acceptForSession" },
    });

    proc.stop();
  });

  it("maps dynamic tool calls into tool_use and tool_result messages", async () => {
    const proc = new CodexProcess("linux");
    const messages: unknown[] = [];
    proc.on("message", (msg) => messages.push(msg));

    proc.start("/tmp/project-dynamic-tool");
    const child = fakeChildren[0];

    await tick();
    const initReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: initReq.id, result: {} })}\n`,
    );
    await tick();
    nextOutgoingNotification(child);
    const threadReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: threadReq.id, result: { thread: { id: "thr_dynamic" } } })}\n`,
    );

    await tick();
    child.stdout.emit(
      "data",
      `${JSON.stringify({
        method: "item/started",
        params: {
          item: {
            type: "dynamicToolCall",
            id: "dyn_tool_1",
            tool: "open_pr",
            arguments: {
              repo: "openai/codex",
              title: "Add protocol support",
            },
            status: "inProgress",
          },
        },
      })}\n`,
    );
    child.stdout.emit(
      "data",
      `${JSON.stringify({
        method: "item/completed",
        params: {
          item: {
            type: "dynamicToolCall",
            id: "dyn_tool_1",
            tool: "open_pr",
            arguments: {
              repo: "openai/codex",
              title: "Add protocol support",
            },
            status: "completed",
            success: true,
            contentItems: [
              {
                type: "inputText",
                text: "Created PR #42",
              },
            ],
          },
        },
      })}\n`,
    );

    await tick();

    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "assistant",
        message: expect.objectContaining({
          content: expect.arrayContaining([
            expect.objectContaining({
              type: "tool_use",
              id: "dyn_tool_1",
              name: "open_pr",
              input: {
                repo: "openai/codex",
                title: "Add protocol support",
              },
            }),
          ]),
        }),
      }),
    );
    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "tool_result",
        toolUseId: "dyn_tool_1",
        toolName: "open_pr",
        content: expect.stringContaining("Created PR #42"),
      }),
    );
    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "tool_result",
        toolUseId: "dyn_tool_1",
        content: expect.stringContaining("success: true"),
      }),
    );

    proc.stop();
  });

  it("maps image generation saved paths into tool_use and tool_result messages", async () => {
    const proc = new CodexProcess("linux");
    const messages: unknown[] = [];
    proc.on("message", (msg) => messages.push(msg));

    proc.start("/tmp/project-image-generation-path");
    const child = fakeChildren[0];

    await tick();
    const initReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: initReq.id, result: {} })}\n`,
    );
    await tick();
    nextOutgoingNotification(child);
    const threadReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: threadReq.id, result: { thread: { id: "thr_image_path" } } })}\n`,
    );

    await tick();
    child.stdout.emit(
      "data",
      `${JSON.stringify({
        method: "item/started",
        params: {
          item: {
            type: "imageGeneration",
            id: "ig_saved_1",
            status: "inProgress",
            revisedPrompt: "a small blue square",
          },
        },
      })}\n`,
    );
    child.stdout.emit(
      "data",
      `${JSON.stringify({
        method: "item/completed",
        params: {
          item: {
            type: "imageGeneration",
            id: "ig_saved_1",
            status: "completed",
            revisedPrompt: "a small blue square",
            result: "base64-omitted-from-content",
            savedPath: "/tmp/codex/generated_images/ig_saved_1.png",
          },
        },
      })}\n`,
    );

    await tick();

    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "assistant",
        message: expect.objectContaining({
          content: expect.arrayContaining([
            expect.objectContaining({
              type: "tool_use",
              id: "ig_saved_1",
              name: "ImageGeneration",
              input: {
                status: "inProgress",
                revisedPrompt: "a small blue square",
              },
            }),
          ]),
        }),
      }),
    );
    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "tool_result",
        toolUseId: "ig_saved_1",
        toolName: "ImageGeneration",
        content: expect.stringContaining(
          "savedPath: /tmp/codex/generated_images/ig_saved_1.png",
        ),
        artifactCandidates: [
          {
            source: "image_generation",
            linkKind: "generated",
            localPath: "/tmp/codex/generated_images/ig_saved_1.png",
          },
        ],
      }),
    );
    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "tool_result",
        toolUseId: "ig_saved_1",
        content: expect.not.stringContaining("base64-omitted-from-content"),
      }),
    );

    proc.stop();
  });

  it("preserves image generation base64 results as raw content blocks", async () => {
    const proc = new CodexProcess("linux");
    const messages: unknown[] = [];
    proc.on("message", (msg) => messages.push(msg));

    proc.start("/tmp/project-image-generation-base64");
    const child = fakeChildren[0];

    await tick();
    const initReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: initReq.id, result: {} })}\n`,
    );
    await tick();
    nextOutgoingNotification(child);
    const threadReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: threadReq.id, result: { thread: { id: "thr_image_base64" } } })}\n`,
    );

    await tick();
    child.stdout.emit(
      "data",
      `${JSON.stringify({
        method: "item/completed",
        params: {
          item: {
            type: "imageGeneration",
            id: "ig_base64_1",
            status: "completed",
            revised_prompt: "a small red square",
            result: "data:image/png;base64,aGVsbG8=",
          },
        },
      })}\n`,
    );

    await tick();

    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "tool_result",
        toolUseId: "ig_base64_1",
        toolName: "ImageGeneration",
        content: expect.stringContaining("Generated 1 image"),
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
      }),
    );
    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "tool_result",
        toolUseId: "ig_base64_1",
        content: expect.not.stringContaining("aGVsbG8="),
      }),
    );

    proc.stop();
  });

  it("preserves MCP image outputs as raw content blocks for downstream rendering", async () => {
    const proc = new CodexProcess("linux");
    const messages: unknown[] = [];
    proc.on("message", (msg) => messages.push(msg));

    proc.start("/tmp/project-mcp-images");
    const child = fakeChildren[0];

    await tick();
    const initReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: initReq.id, result: {} })}\n`,
    );
    await tick();
    nextOutgoingNotification(child);
    const threadReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: threadReq.id, result: { thread: { id: "thr_mcp" } } })}\n`,
    );

    await tick();
    child.stdout.emit(
      "data",
      `${JSON.stringify({
        method: "item/completed",
        params: {
          item: {
            type: "mcpToolCall",
            id: "mcp_tool_1",
            server: "marionette",
            tool: "take_screenshots",
            arguments: {},
            result: {
              content: [
                {
                  type: "image",
                  data: "aGVsbG8=",
                  mimeType: "image/png",
                },
              ],
            },
          },
        },
      })}\n`,
    );

    await tick();

    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "assistant",
        message: expect.objectContaining({
          content: expect.arrayContaining([
            expect.objectContaining({
              type: "tool_use",
              id: "mcp_tool_1",
              name: "mcp:marionette/take_screenshots",
              input: {},
            }),
          ]),
        }),
      }),
    );
    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "tool_result",
        toolUseId: "mcp_tool_1",
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
      }),
    );

    proc.stop();
  });

  it("maps official Codex item types to stable semantic tool activities", () => {
    const proc = new CodexProcess("darwin");
    const messages: Array<Record<string, any>> = [];
    proc.on("message", (message) => messages.push(message as any));

    const emitLifecycle = (item: Record<string, unknown>) => {
      (proc as any).handleNotification("item/started", { item });
      (proc as any).handleNotification("item/completed", { item });
    };

    emitLifecycle({
      type: "commandExecution",
      id: "read-skill-1",
      command: "sed -n '1,200p' /tmp/demo/SKILL.md",
      cwd: "/tmp/demo",
      commandActions: [
        {
          type: "read",
          command: "sed -n '1,200p' /tmp/demo/SKILL.md",
          name: "sed",
          path: "/tmp/demo/SKILL.md",
        },
      ],
      aggregatedOutput: "skill instructions",
      exitCode: 0,
    });
    emitLifecycle({
      type: "commandExecution",
      id: "multi-command-1",
      command: "git status && rg TODO",
      cwd: "/tmp/demo",
      commandActions: [
        { type: "unknown", command: "git status" },
        { type: "search", command: "rg TODO", query: "TODO", path: null },
      ],
      aggregatedOutput: "clean",
      exitCode: 0,
    });
    emitLifecycle({
      type: "collabAgentToolCall",
      id: "spawn-agent-1",
      tool: "spawnAgent",
      status: "completed",
      senderThreadId: "root",
      receiverThreadIds: ["child"],
      prompt: "Review the change",
    });
    emitLifecycle({
      type: "contextCompaction",
      id: "compact-1",
    });
    emitLifecycle({
      type: "mcpToolCall",
      id: "mcp-live-1",
      server: "workspace",
      tool: "lookup",
      status: "completed",
      arguments: { query: "history" },
      result: { content: [{ type: "text", text: "found" }] },
    });

    const toolUses = messages
      .filter((message) => message.type === "assistant")
      .map((message) => message.message.content[0]);
    expect(toolUses).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          id: "read-skill-1",
          name: "ReadSkill",
          input: expect.objectContaining({
            file_path: "/tmp/demo/SKILL.md",
            skill: "demo",
          }),
        }),
        expect.objectContaining({
          id: "multi-command-1",
          name: "MultiCommand",
          input: expect.objectContaining({
            commands: ["git status", "rg TODO"],
          }),
        }),
        expect.objectContaining({ id: "spawn-agent-1", name: "SpawnAgent" }),
        expect.objectContaining({
          id: "compact-1",
          name: "ContextCompaction",
        }),
        expect.objectContaining({
          id: "mcp-live-1",
          name: "mcp:workspace/lookup",
        }),
      ]),
    );
    for (const id of [
      "read-skill-1",
      "multi-command-1",
      "spawn-agent-1",
      "compact-1",
      "mcp-live-1",
    ]) {
      expect(toolUses.filter((tool) => tool.id === id)).toHaveLength(1);
    }
    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "tool_result",
        toolUseId: "compact-1",
        toolName: "ContextCompaction",
      }),
    );
  });

  it("upgrades a generic started command when completion adds a semantic action", () => {
    const proc = new CodexProcess("darwin");
    const messages: Array<Record<string, any>> = [];
    proc.on("message", (message) => messages.push(message as any));

    (proc as any).handleNotification("item/started", {
      item: {
        type: "commandExecution",
        id: "late-read-1",
        command: "sed -n '1,40p' /tmp/demo/README.md",
        status: "inProgress",
        commandActions: [],
      },
    });
    (proc as any).handleNotification("item/completed", {
      item: {
        type: "commandExecution",
        id: "late-read-1",
        command: "sed -n '1,40p' /tmp/demo/README.md",
        status: "completed",
        commandActions: [
          {
            type: "read",
            command: "sed -n '1,40p' /tmp/demo/README.md",
            name: "sed",
            path: "/tmp/demo/README.md",
          },
        ],
        aggregatedOutput: "read output",
        exitCode: 0,
      },
    });

    const toolUses = messages
      .filter((message) => message.type === "assistant")
      .map((message) => message.message.content[0]);
    expect(toolUses).toEqual([
      expect.objectContaining({ id: "late-read-1", name: "Bash" }),
      expect.objectContaining({
        id: "late-read-1",
        name: "Read",
        input: expect.objectContaining({
          file_path: "/tmp/demo/README.md",
          status: "completed",
        }),
      }),
    ]);
    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "tool_result",
        toolUseId: "late-read-1",
        toolName: "Read",
      }),
    );
  });

  it("emits plan notifications as structured checklist messages", async () => {
    const proc = new CodexProcess("linux");
    const messages: unknown[] = [];
    proc.on("message", (msg) => messages.push(msg));

    proc.start("/tmp/project-d");
    const child = fakeChildren[0];

    await tick();
    const initReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: initReq.id, result: {} })}\n`,
    );
    await tick();
    nextOutgoingNotification(child); // initialized
    const threadReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: threadReq.id, result: { thread: { id: "thr_4" } } })}\n`,
    );

    await tick();
    drainSkillsList(child);
    proc.sendInput("make a plan");
    await tick();
    const turnReq = nextOutgoingRequest(child);
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: turnReq.id, result: { turn: { id: "turn_3" } } })}\n`,
    );
    child.stdout.emit(
      "data",
      `${JSON.stringify({ method: "turn/started", params: { turn: { id: "turn_3" } } })}\n`,
    );

    child.stdout.emit(
      "data",
      `${JSON.stringify({
        method: "item/plan/delta",
        params: { delta: "1. gather requirements" },
      })}\n`,
    );
    child.stdout.emit(
      "data",
      `${JSON.stringify({
        method: "turn/plan/updated",
        params: {
          explanation: "Initial plan drafted",
          plan: [{ step: "Gather requirements", status: "inProgress" }],
        },
      })}\n`,
    );

    await tick();

    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "thinking_delta",
        text: "1. gather requirements",
      }),
    );
    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "assistant",
        message: expect.objectContaining({
          role: "assistant",
          content: expect.arrayContaining([
            expect.objectContaining({
              type: "tool_use",
              name: "UpdatePlan",
              input: expect.objectContaining({
                title: "Plan update",
                explanation: "Initial plan drafted",
                todos: [
                  {
                    content: "Gather requirements",
                    status: "in_progress",
                    activeForm: "",
                  },
                ],
              }),
            }),
          ]),
        }),
      }),
    );

    proc.stop();
  });

  it("ignores completion entity update echoes during fetch cooldown", async () => {
    const proc = new CodexProcess("linux");
    const child = new FakeChildProcess();
    fakeChildren.push(child);
    const internal = proc as any;
    attachFakeTransport(internal, child);
    internal._projectPath = "/tmp/project-completions";
    const emitRpc = (message: Record<string, unknown>) => {
      internal.handleStdoutChunk(`${JSON.stringify(message)}\n`);
    };

    const fetchPromise = internal.fetchCompletionEntities(
      "/tmp/project-completions",
    ) as Promise<void>;

    await tick();
    expect(outgoingRequests(child).map((request) => request.method)).toEqual([
      "skills/list",
      "app/list",
      "plugin/list",
    ]);

    const skillsReq = await waitForOutgoingRequest(child, "skills/list");
    expect(skillsReq.method).toBe("skills/list");
    emitRpc({ id: skillsReq.id, result: { data: [] } });
    await tick();

    const appsReq = await waitForOutgoingRequest(child, "app/list");
    expect(appsReq.method).toBe("app/list");
    emitRpc({ method: "app/list/updated", params: {} });
    emitRpc({ id: appsReq.id, result: { data: [] } });
    const pluginsReq = await waitForOutgoingRequest(child, "plugin/list");
    expect(pluginsReq.method).toBe("plugin/list");
    emitRpc({ id: pluginsReq.id, result: { marketplaces: [] } });
    await fetchPromise;
    await tick();

    expect(outgoingRequests(child)).toHaveLength(0);

    emitRpc({ method: "app/list/updated", params: {} });
    await tick();
    expect(outgoingRequests(child)).toHaveLength(0);

    internal._completionFetchCooldownUntil = 0;
    emitRpc({ method: "app/list/updated", params: {} });
    await tick();

    const refetchSkillsReq = await waitForOutgoingRequest(child, "skills/list");
    expect(refetchSkillsReq.method).toBe("skills/list");
    emitRpc({ id: refetchSkillsReq.id, result: { data: [] } });
    const refetchAppsReq = await waitForOutgoingRequest(child, "app/list");
    expect(refetchAppsReq.method).toBe("app/list");
    emitRpc({ id: refetchAppsReq.id, result: { data: [] } });
    const refetchPluginsReq = await waitForOutgoingRequest(
      child,
      "plugin/list",
    );
    expect(refetchPluginsReq.method).toBe("plugin/list");
    emitRpc({ id: refetchPluginsReq.id, result: { marketplaces: [] } });
    await tick();

    proc.stop();
  });

  it("emits an empty skill snapshot before slower completion sources finish", async () => {
    const proc = new CodexProcess("linux");
    const child = new FakeChildProcess();
    fakeChildren.push(child);
    const messages: unknown[] = [];
    proc.on("message", (msg) => messages.push(msg));
    const internal = proc as any;
    attachFakeTransport(internal, child);
    const emitRpc = (message: Record<string, unknown>) => {
      internal.handleStdoutChunk(`${JSON.stringify(message)}\n`);
    };

    const fetchPromise = internal.fetchCompletionEntities(
      "/tmp/project-empty-completions",
    ) as Promise<void>;
    const skillsReq = await waitForOutgoingRequest(child, "skills/list");
    const appsReq = await waitForOutgoingRequest(child, "app/list");
    const pluginsReq = await waitForOutgoingRequest(child, "plugin/list");

    emitRpc({ id: skillsReq.id, result: { data: [] } });
    await tick();

    expect(messages).toContainEqual({
      type: "system",
      subtype: "supported_commands",
      skills: [],
      skillMetadata: [],
      apps: [],
      appMetadata: [],
      plugins: [],
      pluginMetadata: [],
    });

    emitRpc({ id: appsReq.id, result: { data: [] } });
    emitRpc({ id: pluginsReq.id, result: { marketplaces: [] } });
    await fetchPromise;
    proc.stop();
  });

  it("emits installed enabled plugins from plugin/list as completion entities", async () => {
    const proc = new CodexProcess("linux");
    const child = new FakeChildProcess();
    fakeChildren.push(child);
    const messages: unknown[] = [];
    proc.on("message", (msg) => messages.push(msg));
    const internal = proc as any;
    attachFakeTransport(internal, child);
    internal._projectPath = "/tmp/project-plugins";
    const emitRpc = (message: Record<string, unknown>) => {
      internal.handleStdoutChunk(`${JSON.stringify(message)}\n`);
    };

    const fetchPromise = internal.fetchCompletionEntities(
      "/tmp/project-plugins",
    ) as Promise<void>;

    const skillsReq = await waitForOutgoingRequest(child, "skills/list");
    emitRpc({ id: skillsReq.id, result: { data: [] } });
    const appsReq = await waitForOutgoingRequest(child, "app/list");
    emitRpc({ id: appsReq.id, result: { data: [] } });
    const pluginsReq = await waitForOutgoingRequest(child, "plugin/list");
    emitRpc({
      id: pluginsReq.id,
      result: {
        marketplaces: [
          {
            name: "test",
            path: "/tmp/marketplace",
            plugins: [
              {
                id: "sample@test",
                name: "sample",
                installed: true,
                enabled: true,
                interface: {
                  displayName: "Sample Plugin",
                  shortDescription: "Example plugin",
                  longDescription: "Long plugin description",
                  defaultPrompt: ["Use sample", "Try another prompt"],
                  brandColor: "#123456",
                  composerIcon: ["unexpected", "path"],
                  composerIconUrl: "https://example.test/icon.png",
                },
              },
              {
                id: "disabled@test",
                name: "disabled",
                installed: true,
                enabled: false,
              },
            ],
          },
        ],
      },
    });
    await fetchPromise;

    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "system",
        subtype: "supported_commands",
        plugins: ["sample"],
        pluginMetadata: [
          expect.objectContaining({
            id: "sample@test",
            name: "sample",
            path: "plugin://sample@test",
            marketplaceName: "test",
            marketplacePath: "/tmp/marketplace",
            displayName: "Sample Plugin",
            shortDescription: "Example plugin",
            defaultPrompt: "Use sample",
          }),
        ],
      }),
    );
    const supportedCommands = messages.find(
      (msg): msg is { pluginMetadata: Array<Record<string, unknown>> } =>
        typeof msg === "object" &&
        msg !== null &&
        (msg as { subtype?: unknown }).subtype === "supported_commands" &&
        Array.isArray((msg as { pluginMetadata?: unknown }).pluginMetadata) &&
        (msg as { pluginMetadata: unknown[] }).pluginMetadata.length > 0,
    );
    expect(supportedCommands?.pluginMetadata[0]?.composerIcon).toBeUndefined();

    proc.stop();
  });

  it("keeps skills and apps when plugin/list fails", async () => {
    const proc = new CodexProcess("linux");
    const child = new FakeChildProcess();
    fakeChildren.push(child);
    const messages: unknown[] = [];
    proc.on("message", (msg) => messages.push(msg));
    const internal = proc as any;
    attachFakeTransport(internal, child);
    internal._projectPath = "/tmp/project-plugin-error";
    const emitRpc = (message: Record<string, unknown>) => {
      internal.handleStdoutChunk(`${JSON.stringify(message)}\n`);
    };

    const fetchPromise = internal.fetchCompletionEntities(
      "/tmp/project-plugin-error",
    ) as Promise<void>;

    const skillsReq = await waitForOutgoingRequest(child, "skills/list");
    emitRpc({
      id: skillsReq.id,
      result: {
        data: [
          {
            cwd: "/tmp/project-plugin-error",
            skills: [
              {
                name: "review",
                path: "/tmp/review/SKILL.md",
                description: "Review code",
                enabled: true,
                scope: "user",
              },
            ],
          },
        ],
      },
    });
    await tick();
    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "system",
        subtype: "supported_commands",
        skills: ["review"],
        apps: [],
        plugins: [],
      }),
    );
    const appsReq = await waitForOutgoingRequest(child, "app/list");
    emitRpc({
      id: appsReq.id,
      result: {
        data: [
          {
            id: "demo-app",
            name: "Demo App",
            description: "Example connector",
            isAccessible: true,
            isEnabled: true,
          },
        ],
      },
    });
    const pluginsReq = await waitForOutgoingRequest(child, "plugin/list");
    emitRpc({
      id: pluginsReq.id,
      error: { code: -32601, message: "unknown method" },
    });
    await fetchPromise;

    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "system",
        subtype: "supported_commands",
        skills: ["review"],
        apps: ["demo-app"],
        plugins: [],
      }),
    );

    proc.stop();
  });
});

function outgoingRequests(child: FakeChildProcess): Record<string, unknown>[] {
  return child.stdin.writes
    .flatMap((chunk) => chunk.split("\n"))
    .map((line) => line.trim())
    .filter((line) => line.length > 0)
    .map((line) => JSON.parse(line) as Record<string, unknown>)
    .filter(
      (value) => typeof value.method === "string" && value.id !== undefined,
    );
}

async function waitForOutgoingRequest(
  child: FakeChildProcess,
  method: string,
): Promise<Record<string, unknown>> {
  for (let attempt = 0; attempt < 10; attempt++) {
    const match = outgoingRequests(child).some(
      (value) => value.method === method,
    );
    if (match) {
      return consumeOutgoing(child, (value) => value.method === method);
    }
    await tick();
  }
  throw new Error(`Expected outgoing ${method} request was not found`);
}

function consumeOutgoing(
  child: FakeChildProcess,
  predicate: (value: Record<string, unknown>) => boolean,
): Record<string, unknown> {
  const lines = child.stdin.writes
    .flatMap((chunk) => chunk.split("\n"))
    .map((line) => line.trim())
    .filter((line) => line.length > 0);
  const parsed = lines.map(
    (line) => JSON.parse(line) as Record<string, unknown>,
  );
  const index = parsed.findIndex(predicate);
  if (index < 0) {
    throw new Error("Expected outgoing JSON-RPC message was not found");
  }
  const remaining = lines.filter((_, lineIndex) => lineIndex !== index);
  child.stdin.writes =
    remaining.length > 0 ? [`${remaining.join("\n")}\n`] : [];

  return parsed[index];
}

function nextOutgoingRequest(child: FakeChildProcess): Record<string, unknown> {
  return consumeOutgoing(
    child,
    (value) => typeof value.method === "string" && value.id !== undefined,
  );
}

/** Consume and reply to the background skills/list request that fires after thread/start. */
function drainSkillsList(child: FakeChildProcess): void {
  try {
    const req = consumeOutgoing(
      child,
      (value) => value.method === "skills/list" && value.id !== undefined,
    );
    child.stdout.emit(
      "data",
      `${JSON.stringify({ id: req.id, result: { data: [] } })}\n`,
    );
  } catch {
    // skills/list may not have been emitted yet — safe to ignore
  }
}

function nextOutgoingNotification(
  child: FakeChildProcess,
): Record<string, unknown> {
  return consumeOutgoing(
    child,
    (value) => typeof value.method === "string" && value.id === undefined,
  );
}

function nextOutgoingResponse(
  child: FakeChildProcess,
): Record<string, unknown> {
  return consumeOutgoing(
    child,
    (value) =>
      value.id !== undefined &&
      value.result !== undefined &&
      value.method === undefined,
  );
}

function nextOutgoingError(child: FakeChildProcess): Record<string, unknown> {
  return consumeOutgoing(
    child,
    (value) =>
      value.id !== undefined &&
      value.error !== undefined &&
      value.method === undefined,
  );
}

function attachFakeTransport(
  internal: { transport?: unknown },
  child: FakeChildProcess,
): void {
  internal.transport = {
    isRunning: true,
    write(envelope: Record<string, unknown>) {
      child.stdin.write(`${JSON.stringify(envelope)}\n`);
    },
    stop() {},
    on() {
      return this;
    },
  };
}

async function tick(): Promise<void> {
  await Promise.resolve();
  await Promise.resolve();
}
