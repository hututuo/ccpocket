import { describe, expect, it, vi } from "vitest";
import {
  CodexGoalConflictError,
  CodexGoalController,
  isUnsupportedCodexGoalRpc,
  mergeCodexGoalState,
} from "./codex-goal-controller.js";
import { createCodexGoalResumeLease } from "./codex-process.js";
import type { CodexGoal } from "./parser.js";
import type { SessionInfo } from "./session.js";

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void;
  let reject!: (reason?: unknown) => void;
  const promise = new Promise<T>((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

function goal(
  updatedAt: number,
  overrides: Partial<CodexGoal> = {},
): CodexGoal {
  return {
    threadId: "thread-goal",
    objective: "Ship Goal management",
    status: "active",
    tokenBudget: null,
    tokensUsed: 0,
    timeUsedSeconds: 0,
    createdAt: 1,
    updatedAt,
    ...overrides,
  };
}

function sessionWithProcess(process: Record<string, unknown>): SessionInfo {
  if (typeof process.getGoal === "function" && !process.getGoalSnapshot) {
    process.getGoalSnapshot = vi.fn(async () => ({
      goal: await (process.getGoal as () => Promise<CodexGoal | null>)(),
      stable: true,
    }));
  }
  if (!process.recordAuthoritativeGoalStateChange) {
    process.recordAuthoritativeGoalStateChange = vi.fn(() => {
      const next = Number(process.lastGoalRpcSequence ?? 0) + 1;
      process.lastGoalRpcSequence = next;
      return next;
    });
  }
  return {
    id: "session-goal",
    provider: "codex",
    process,
    history: [],
    historyEntries: [],
    historyRevision: 0,
    historyLowWatermark: 1,
    projectPath: "/tmp/project",
    status: "idle",
    createdAt: new Date(0),
    lastActivityAt: new Date(0),
    gitBranch: "main",
  } as unknown as SessionInfo;
}

describe("CodexGoalController", () => {
  it("serializes edit, pause, and clear for one session", async () => {
    const firstStarted = deferred<void>();
    const releaseFirst = deferred<void>();
    const calls: string[] = [];
    let revision = 1;
    const process = {
      getGoal: vi.fn(),
      setGoal: vi.fn(async (update: Record<string, unknown>) => {
        calls.push(String(update.status ?? "edit"));
        if (calls.length === 1) {
          firstStarted.resolve();
          await releaseFirst.promise;
        }
        revision += 1;
        return goal(revision, {
          objective: String(update.objective ?? "Edited objective"),
          status: (update.status ?? "active") as CodexGoal["status"],
        });
      }),
      clearGoal: vi.fn(async () => {
        calls.push("clear");
        return true;
      }),
    };
    const session = sessionWithProcess(process);
    const controller = new CodexGoalController({
      getSession: () => session,
    });

    const edit = controller.set(session.id, { objective: "Edited objective" });
    await firstStarted.promise;
    const pause = controller.set(session.id, { status: "paused" });
    const clear = controller.clear(session.id);

    expect(calls).toEqual(["edit"]);
    releaseFirst.resolve();
    await Promise.all([edit, pause, clear]);

    expect(calls).toEqual(["edit", "paused", "clear"]);
    expect(process.setGoal).toHaveBeenNthCalledWith(
      1,
      { objective: "Edited objective" },
      expect.objectContaining({ validateCurrentGoal: expect.any(Function) }),
    );
    expect(process.setGoal).toHaveBeenNthCalledWith(
      2,
      { status: "paused" },
      expect.objectContaining({ validateCurrentGoal: expect.any(Function) }),
    );
    expect(session.codexGoal).toBeNull();
  });

  it("single-flights concurrent refreshes", async () => {
    const started = deferred<void>();
    const release = deferred<CodexGoal | null>();
    const process = {
      getGoal: vi.fn(async () => {
        started.resolve();
        return release.promise;
      }),
      setGoal: vi.fn(),
      clearGoal: vi.fn(),
    };
    const session = sessionWithProcess(process);
    const controller = new CodexGoalController({
      getSession: () => session,
    });

    const first = controller.refresh(session.id);
    const second = controller.refresh(session.id);
    expect(first).toBe(second);
    await started.promise;
    expect(process.getGoal).toHaveBeenCalledOnce();

    release.resolve(goal(5));
    await expect(Promise.all([first, second])).resolves.toEqual([
      goal(5),
      goal(5),
    ]);
  });

  it("does not single-flight a refresh across an intervening mutation", async () => {
    const releaseFirst = deferred<CodexGoal | null>();
    const order: string[] = [];
    const process = {
      getGoal: vi
        .fn()
        .mockImplementationOnce(async () => {
          order.push("get-before");
          return releaseFirst.promise;
        })
        .mockImplementationOnce(async () => {
          order.push("get-after");
          return goal(3, { objective: "After edit" });
        }),
      setGoal: vi.fn(async () => {
        order.push("set");
        return goal(2, { objective: "After edit" });
      }),
      clearGoal: vi.fn(),
    };
    const session = sessionWithProcess(process);
    const controller = new CodexGoalController({
      getSession: () => session,
    });

    const before = controller.refresh(session.id);
    const edit = controller.set(session.id, { objective: "After edit" });
    const after = controller.refresh(session.id);
    releaseFirst.resolve(goal(1, { objective: "Before edit" }));
    await Promise.all([before, edit, after]);

    expect(order).toEqual(["get-before", "set", "get-after"]);
    expect(process.getGoal).toHaveBeenCalledTimes(2);
    expect(session.codexGoal).toMatchObject({
      objective: "After edit",
      updatedAt: 3,
    });
  });

  it("keeps newer cached state when a delayed refresh is stale", async () => {
    const process = {
      getGoal: vi.fn(async () => goal(9, { objective: "Old" })),
      setGoal: vi.fn(),
      clearGoal: vi.fn(),
    };
    const session = sessionWithProcess(process);
    session.codexGoal = goal(10, { objective: "New" });
    const controller = new CodexGoalController({
      getSession: () => session,
    });

    await expect(controller.refresh(session.id)).resolves.toMatchObject({
      objective: "New",
      updatedAt: 10,
    });
    expect(session.codexGoal).toMatchObject({
      objective: "New",
      updatedAt: 10,
    });
    expect(mergeCodexGoalState(goal(10), goal(9)).accepted).toBe(false);
  });

  it("does not resurrect a cleared Goal from a stale notification", async () => {
    const process = {
      getGoal: vi.fn(),
      setGoal: vi.fn(),
      clearGoal: vi.fn(async () => true),
    };
    const session = sessionWithProcess(process);
    session.codexGoal = goal(10);
    session.codexGoalUpdatedAt = 10;
    const controller = new CodexGoalController({
      getSession: () => session,
    });
    await controller.clear(session.id);
    expect(session.codexGoal).toBeNull();
    expect(
      mergeCodexGoalState(
        session.codexGoal,
        goal(9, { objective: "Delayed old Goal" }),
        session.codexGoalUpdatedAt,
      ),
    ).toMatchObject({ accepted: false, goal: null, updatedAt: 10 });
    expect(session.codexGoal).toBeNull();
  });

  it("rejects an equal-timestamp echo after clear unless an RPC authorizes it", () => {
    expect(mergeCodexGoalState(null, goal(10), 10)).toMatchObject({
      accepted: false,
      goal: null,
      updatedAt: 10,
    });
    expect(mergeCodexGoalState(null, goal(10), 10, true)).toMatchObject({
      accepted: true,
      goal: goal(10),
      updatedAt: 10,
    });
  });

  it("does not let an older clear response erase a newer Goal event", async () => {
    const process = {
      lastGoalRpcSequence: 1,
      getGoal: vi.fn(),
      setGoal: vi.fn(),
      clearGoal: vi.fn(async () => true),
    };
    const session = sessionWithProcess(process);
    session.codexGoal = goal(20, { objective: "Newer Goal" });
    session.codexGoalUpdatedAt = 20;
    session.codexGoalOperationSequence = 2;
    const controller = new CodexGoalController({
      getSession: () => session,
    });

    await expect(controller.clear(session.id)).resolves.toMatchObject({
      objective: "Newer Goal",
    });
    expect(session.codexGoal).toMatchObject({ objective: "Newer Goal" });
  });

  it("does not advance the writable CAS revision for an unchanged queued read", async () => {
    const readStarted = deferred<void>();
    const releaseRead = deferred<{ goal: CodexGoal; stable: boolean }>();
    const current = goal(10);
    const process = {
      lastGoalRpcSequence: 7,
      getGoal: vi.fn(),
      getGoalSnapshot: vi.fn(async () => {
        readStarted.resolve();
        return releaseRead.promise;
      }),
      recordAuthoritativeGoalStateChange: vi.fn(() => 8),
      setGoal: vi.fn(
        async (
          _update: Record<string, unknown>,
          options?: {
            validateCurrentGoal?: (goal: CodexGoal | null) => void;
          },
        ) => {
          options?.validateCurrentGoal?.(current);
          process.lastGoalRpcSequence = 8;
          return goal(11, { objective: "Edited after poll" });
        },
      ),
      clearGoal: vi.fn(),
    };
    const session = sessionWithProcess(process);
    session.codexGoal = current;
    session.codexGoalUpdatedAt = current.updatedAt;
    session.codexGoalOperationSequence = 7;
    const controller = new CodexGoalController({ getSession: () => session });

    const refresh = controller.refresh(session.id);
    await readStarted.promise;
    const edit = controller.set(
      session.id,
      { objective: "Edited after poll" },
      7,
    );
    releaseRead.resolve({ goal: current, stable: true });

    await expect(refresh).resolves.toEqual(current);
    await expect(edit).resolves.toMatchObject({
      objective: "Edited after poll",
    });
    expect(process.recordAuthoritativeGoalStateChange).not.toHaveBeenCalled();
    expect(process.setGoal).toHaveBeenCalledOnce();
  });

  it.each([
    ["set", 7],
    ["clear", 7],
    ["set", undefined],
    ["clear", undefined],
  ] as const)(
    "rechecks authoritative Goal state after the settings barrier before %s (expected sequence %s)",
    async (kind, expectedSequence) => {
      const releaseBarrier = deferred<void>();
      const original = goal(10, { objective: "Original" });
      const desktopReplacement = goal(11, {
        objective: "Desktop replacement",
        createdAt: 2,
      });
      let mutationRpcStarted = false;
      const validateAfterBarrier = async (options?: {
        validateCurrentGoal?: (goal: CodexGoal | null) => void;
      }) => {
        await releaseBarrier.promise;
        options?.validateCurrentGoal?.(desktopReplacement);
        mutationRpcStarted = true;
      };
      const process = {
        lastGoalRpcSequence: 7,
        getGoal: vi.fn(),
        getGoalSnapshot: vi.fn(),
        recordAuthoritativeGoalStateChange: vi.fn(() => {
          process.lastGoalRpcSequence = 8;
          return 8;
        }),
        setGoal: vi.fn(
          async (
            _update: Record<string, unknown>,
            options?: {
              validateCurrentGoal?: (goal: CodexGoal | null) => void;
            },
          ) => {
            await validateAfterBarrier(options);
            return goal(12);
          },
        ),
        clearGoal: vi.fn(
          async (options?: {
            validateCurrentGoal?: (goal: CodexGoal | null) => void;
          }) => {
            await validateAfterBarrier(options);
            return true;
          },
        ),
      };
      const session = sessionWithProcess(process);
      session.codexGoal = original;
      session.codexGoalUpdatedAt = original.updatedAt;
      session.codexGoalOperationSequence = 7;
      const controller = new CodexGoalController({ getSession: () => session });

      const mutation =
        kind === "set"
          ? controller.set(
              session.id,
              { status: "paused" },
              expectedSequence,
            )
          : controller.clear(session.id, expectedSequence);
      releaseBarrier.resolve();

      await expect(mutation).rejects.toBeInstanceOf(CodexGoalConflictError);
      expect(mutationRpcStarted).toBe(false);
      expect(session.codexGoal).toMatchObject({
        objective: "Desktop replacement",
      });
      expect(session.codexGoalOperationSequence).toBe(8);
    },
  );

  it("rechecks a restart lease immediately before reactivating the Goal", async () => {
    const paused = goal(10, {
      objective: "Restart-owned Goal",
      status: "paused",
      tokensUsed: 4,
      timeUsedSeconds: 2,
    });
    const desktopReplacement = goal(11, {
      objective: "Desktop replacement",
      status: "paused",
      createdAt: 2,
    });
    let mutationRpcStarted = false;
    const process = {
      lastGoalRpcSequence: 7,
      getGoal: vi.fn(),
      getGoalSnapshot: vi.fn(),
      recordAuthoritativeGoalStateChange: vi.fn(() => {
        process.lastGoalRpcSequence = 8;
        return 8;
      }),
      setGoal: vi.fn(
        async (
          _update: Record<string, unknown>,
          options?: {
            validateCurrentGoal?: (goal: CodexGoal | null) => void;
          },
        ) => {
          options?.validateCurrentGoal?.(desktopReplacement);
          mutationRpcStarted = true;
          return goal(12);
        },
      ),
      clearGoal: vi.fn(),
    };
    const session = sessionWithProcess(process);
    session.codexGoal = paused;
    session.codexGoalUpdatedAt = paused.updatedAt;
    session.codexGoalOperationSequence = 7;
    const controller = new CodexGoalController({ getSession: () => session });

    await expect(
      controller.resumeWithLease(
        session.id,
        createCodexGoalResumeLease(paused),
      ),
    ).rejects.toMatchObject({
      name: "CodexGoalResumeLeaseConflictError",
    });
    expect(mutationRpcStarted).toBe(false);
    expect(session.codexGoal).toMatchObject({
      objective: "Desktop replacement",
    });
  });

  it("classifies explicit old-runtime Goal failures as unsupported", () => {
    expect(isUnsupportedCodexGoalRpc(new Error("goals feature is disabled")))
      .toBe(true);
    expect(
      isUnsupportedCodexGoalRpc(
        new Error("ephemeral thread does not support goals: thread-1"),
      ),
    ).toBe(true);
    expect(isUnsupportedCodexGoalRpc(new Error("sqlite state db unavailable")))
      .toBe(false);
  });

  it("probes supported and explicitly unsupported Goal capability", async () => {
    const onCapabilityChanged = vi.fn();
    const process = {
      getGoal: vi
        .fn()
        .mockResolvedValueOnce(null)
        .mockRejectedValueOnce(
          Object.assign(new Error("Method not found"), { code: -32601 }),
        ),
      setGoal: vi.fn(),
      clearGoal: vi.fn(),
    };
    const session = sessionWithProcess(process);
    const controller = new CodexGoalController({
      getSession: () => session,
      onCapabilityChanged,
    });

    await expect(controller.refresh(session.id)).resolves.toBeNull();
    expect(session.codexGoalControlSupported).toBe(true);
    await expect(controller.refresh(session.id)).rejects.toThrow(
      "Method not found",
    );
    expect(session.codexGoalControlSupported).toBe(false);
    expect(onCapabilityChanged).toHaveBeenCalledTimes(2);
  });
});
