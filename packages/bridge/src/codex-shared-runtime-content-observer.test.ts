import { EventEmitter } from "node:events";

import { afterEach, describe, expect, it, vi } from "vitest";

import type { CodexStartOptions } from "./codex-process.js";
import {
  claimSharedRuntimePilotAttachment,
  releaseSharedRuntimePilotAttachment,
  sharedRuntimePilotAttachmentCount,
  snapshotSharedRuntimePilotGates,
} from "./codex-shared-runtime-pilot.js";
import {
  SharedCodexContentObserverCoordinator,
  type SharedCodexContentObserverInterest,
  type SharedCodexContentObserverProcess,
} from "./codex-shared-runtime-content-observer.js";
import type { ServerMessage } from "./parser.js";

class FakeObserverProcess extends EventEmitter {
  activeTurnId = "turn-live";
  isRunning = true;
  readonly starts: Array<{ projectPath: string; options: CodexStartOptions }> =
    [];
  stop = vi.fn(() => {
    this.isRunning = false;
  });
  attachment = Promise.resolve();

  start(projectPath: string, options: CodexStartOptions): void {
    this.starts.push({ projectPath, options });
  }

  waitUntilAttached(): Promise<void> {
    return this.attachment;
  }

  asObserver(): SharedCodexContentObserverProcess {
    return this as unknown as SharedCodexContentObserverProcess;
  }

  message(message: ServerMessage): void {
    this.emit("message", message);
  }
}

function interest(
  threadId: string,
  overrides: Partial<SharedCodexContentObserverInterest> = {},
): SharedCodexContentObserverInterest {
  return {
    threadId,
    projectPath: `/workspace/${threadId}`,
    focused: false,
    needsAttention: false,
    active: true,
    observedAt: "2026-08-01T00:00:00.000Z",
    ...overrides,
  };
}

function fixture(
  options: {
    maxObservers?: number;
    unfocusGraceMs?: number;
    retryDelaysMs?: readonly number[];
  } = {},
) {
  const processes: FakeObserverProcess[] = [];
  const messages: Array<Record<string, unknown>> = [];
  const completions: Array<Record<string, unknown>> = [];
  const coordinator = new SharedCodexContentObserverCoordinator({
    createProcess: () => {
      const process = new FakeObserverProcess();
      processes.push(process);
      return process.asObserver();
    },
    onMessage: (event) => messages.push(event),
    onCompletion: (event) => completions.push(event),
    now: () => Date.parse("2026-08-01T01:02:03.000Z"),
    ...options,
  });
  return { coordinator, processes, messages, completions };
}

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllEnvs();
});

describe("SharedCodexContentObserverCoordinator", () => {
  it("attaches an active Desktop turn with an exact settings-neutral observer resume", async () => {
    const value = fixture();
    value.coordinator.setAuthority(7, true);
    value.coordinator.setActive(true);
    value.coordinator.setInterests([interest("thread-active")]);
    await vi.waitFor(() => expect(value.processes).toHaveLength(1));

    expect(value.processes[0]!.starts).toEqual([
      {
        projectPath: "/workspace/thread-active",
        options: {
          threadId: "thread-active",
          sharedRuntimeAttach: "observer",
        },
      },
    ]);
    value.processes[0]!.message({
      type: "assistant",
      message: {
        id: "assistant-live",
        role: "assistant",
        model: "test",
        content: [{ type: "text", text: "live" }],
      },
    });
    expect(value.messages).toMatchObject([
      {
        threadId: "thread-active",
        connectionGeneration: 7,
        turnId: "turn-live",
        observedAt: "2026-08-01T01:02:03.000Z",
      },
    ]);
    value.coordinator.close();
  });

  it("prioritizes Need You and multiple focused threads over ordinary working threads", () => {
    const value = fixture({ maxObservers: 3 });
    value.coordinator.setAuthority(1, true);
    value.coordinator.setActive(true);
    value.coordinator.setInterests([
      interest("working-a"),
      interest("working-b"),
      interest("focused-a", { focused: true, active: false }),
      interest("focused-b", { focused: true, active: false }),
      interest("need-you", { needsAttention: true }),
    ]);

    expect(new Set(value.coordinator.observedThreadIds)).toEqual(
      new Set(["need-you", "focused-a", "focused-b"]),
    );
    value.coordinator.close();
  });

  it("bounds concurrent observer attachment work while draining the selected set", async () => {
    const value = fixture({ maxObservers: 10 });
    value.coordinator.setAuthority(1, true);
    value.coordinator.setActive(true);
    value.coordinator.setInterests(
      Array.from({ length: 10 }, (_, index) => interest(`working-${index}`)),
    );
    expect(value.processes).toHaveLength(4);
    await vi.waitFor(() => expect(value.processes).toHaveLength(10));
    value.coordinator.close();
  });

  it("keeps a focused idle observer through grace, then closes it", async () => {
    vi.useFakeTimers();
    const value = fixture({ unfocusGraceMs: 1_000 });
    value.coordinator.setAuthority(1, true);
    value.coordinator.setActive(true);
    value.coordinator.setInterests([
      interest("focused-idle", { focused: true, active: false }),
    ]);
    expect(value.coordinator.observedThreadIds).toEqual(["focused-idle"]);

    value.coordinator.setInterests([]);
    await vi.advanceTimersByTimeAsync(999);
    expect(value.coordinator.observedThreadIds).toEqual(["focused-idle"]);
    await vi.advanceTimersByTimeAsync(1);
    expect(value.coordinator.observedThreadIds).toEqual([]);
    expect(value.processes[0]!.stop).toHaveBeenCalledOnce();
    value.coordinator.close();
  });

  it("deduplicates two clients focused on the same thread", () => {
    const value = fixture();
    value.coordinator.setAuthority(1, true);
    value.coordinator.setActive(true);
    value.coordinator.setInterests([
      interest("same", { focused: true, active: false }),
      interest("same", { focused: true, active: true }),
    ]);
    expect(value.processes).toHaveLength(1);
    expect(value.coordinator.observedThreadIds).toEqual(["same"]);
    value.coordinator.close();
  });

  it("fences late messages across daemon generations and reconnects cleanly", () => {
    const value = fixture();
    value.coordinator.setAuthority(1, true);
    value.coordinator.setActive(true);
    value.coordinator.setInterests([interest("thread-generation")]);
    const old = value.processes[0]!;

    value.coordinator.setAuthority(1, false);
    old.message({ type: "stream_delta", text: "late" });
    expect(value.messages).toEqual([]);
    expect(old.stop).toHaveBeenCalledOnce();

    value.coordinator.setAuthority(2, true);
    expect(value.processes).toHaveLength(2);
    value.processes[1]!.message({ type: "stream_delta", text: "current" });
    expect(value.messages).toMatchObject([
      { threadId: "thread-generation", connectionGeneration: 2 },
    ]);
    value.coordinator.close();
  });

  it("never observes a server-request channel and forces a final reconcile only for results", () => {
    const value = fixture();
    value.coordinator.setAuthority(1, true);
    value.coordinator.setActive(true);
    value.coordinator.setInterests([interest("thread-request")]);
    const process = value.processes[0]!;

    process.emit("request", {
      method: "item/commandExecution/requestApproval",
      params: { command: "rm -rf /" },
    });
    expect(value.messages).toEqual([]);
    expect(value.completions).toEqual([]);

    process.message({ type: "result", subtype: "success", result: "done" });
    expect(value.messages).toHaveLength(1);
    expect(value.completions).toMatchObject([
      { threadId: "thread-request", turnId: "turn-live" },
    ]);
    value.coordinator.close();
  });

  it("bounds retries after repeated observer failures", async () => {
    vi.useFakeTimers();
    const processes: FakeObserverProcess[] = [];
    const coordinator = new SharedCodexContentObserverCoordinator({
      codexSourceId: "observer-handoff-source",
      createProcess: () => {
        const process = new FakeObserverProcess();
        process.attachment = Promise.reject(new Error("attach failed"));
        processes.push(process);
        return process.asObserver();
      },
      onMessage: () => {},
      onCompletion: () => {},
      retryDelaysMs: [10, 20],
    });
    coordinator.setAuthority(1, true);
    coordinator.setActive(true);
    coordinator.setInterests([interest("retry")]);
    await vi.runAllTimersAsync();
    await Promise.resolve();
    await vi.runAllTimersAsync();
    await Promise.resolve();
    await vi.runAllTimersAsync();

    expect(processes).toHaveLength(3);
    expect(
      processes.every((process) => process.stop.mock.calls.length === 1),
    ).toBe(true);
    coordinator.close();
  });

  it("restores the full retry budget after an attachment succeeds", async () => {
    vi.useFakeTimers();
    const processes: FakeObserverProcess[] = [];
    const coordinator = new SharedCodexContentObserverCoordinator({
      createProcess: () => {
        const process = new FakeObserverProcess();
        // Fail once, recover, then fail every attachment in the new failure
        // episode. With two retry delays, the post-recovery exit gets both
        // bounded reattachment attempts instead of inheriting one consumed
        // attempt from the earlier failure.
        if (processes.length !== 1) {
          process.attachment = Promise.reject(new Error("attach failed"));
        }
        processes.push(process);
        return process.asObserver();
      },
      onMessage: () => {},
      onCompletion: () => {},
      retryDelaysMs: [10, 20],
    });
    coordinator.setAuthority(1, true);
    coordinator.setActive(true);
    coordinator.setInterests([interest("retry-after-success")]);

    await vi.runAllTimersAsync();
    await vi.waitFor(() => expect(processes).toHaveLength(2));
    expect(coordinator.observedThreadIds).toEqual(["retry-after-success"]);

    processes[1]!.emit("exit", 1);
    await vi.runAllTimersAsync();
    await Promise.resolve();
    await vi.runAllTimersAsync();
    await Promise.resolve();
    await vi.runAllTimersAsync();

    expect(processes).toHaveLength(4);
    expect(
      processes
        .filter((_, index) => index !== 1)
        .every((process) => process.stop.mock.calls.length === 1),
    ).toBe(true);
    coordinator.close();
  });

  it("keeps reconnect interest while formal recovery preempts the observer", async () => {
    vi.stubEnv("BRIDGE_CODEX_APP_SERVER_MODE", "daemon");
    vi.stubEnv("BRIDGE_CODEX_SHARED_PILOT", "1");
    vi.stubEnv("BRIDGE_CODEX_SOURCE_ID", "observer-handoff-source");
    vi.stubEnv("BRIDGE_CODEX_SHARED_PILOT_ALLOW_THREAD_START", "0");
    vi.stubEnv("BRIDGE_CODEX_SHARED_PILOT_ALLOW_TURN_START", "0");
    const frozen = snapshotSharedRuntimePilotGates();
    const processes: FakeObserverProcess[] = [];
    const observerClaims: Array<{
      owner: object;
      key: string | null;
    }> = [];
    const coordinator = new SharedCodexContentObserverCoordinator({
      createProcess: () => {
        const process = new FakeObserverProcess();
        const originalStart = process.start.bind(process);
        const originalStop = process.stop;
        let key: string | null = null;
        process.start = (projectPath, options) => {
          originalStart(projectPath, options);
          key = claimSharedRuntimePilotAttachment(
            process,
            options.threadId!,
            frozen,
            "observer",
            () => process.emit("shared_runtime_yield"),
          );
          observerClaims.push({ owner: process, key });
        };
        process.stop = vi.fn(() => {
          releaseSharedRuntimePilotAttachment(process, key);
          originalStop();
        });
        processes.push(process);
        return process.asObserver();
      },
      onMessage: () => {},
      onCompletion: () => {},
    });

    coordinator.setAuthority(1, true);
    coordinator.setActive(true);
    coordinator.setInterests([
      interest("thread-recovery", { focused: true, active: false }),
    ]);
    await vi.waitFor(() => expect(processes).toHaveLength(1));

    // A daemon reconnect keeps the old focused interest and creates a fresh
    // observer. Formal recovery must still be able to take that exact thread.
    coordinator.setAuthority(1, false);
    coordinator.setAuthority(2, true);
    await vi.waitFor(() => expect(processes).toHaveLength(2));

    const formalRecovery = {};
    const formalKey = claimSharedRuntimePilotAttachment(
      formalRecovery,
      "thread-recovery",
      frozen,
      "adoption",
    );
    expect(coordinator.observedThreadIds).toEqual([]);
    expect(processes[1]!.stop).toHaveBeenCalledOnce();

    // Repeated reconciliation while recovery is pending cannot spawn a
    // competing observer. Releasing recovery wakes the retained interest.
    coordinator.setInterests([
      interest("thread-recovery", { focused: true, active: false }),
    ]);
    expect(processes).toHaveLength(2);
    releaseSharedRuntimePilotAttachment(formalRecovery, formalKey);
    await vi.waitFor(() => expect(processes).toHaveLength(3));
    expect(coordinator.observedThreadIds).toEqual(["thread-recovery"]);

    coordinator.close();
    for (const claim of observerClaims) {
      releaseSharedRuntimePilotAttachment(claim.owner, claim.key);
    }
    expect(sharedRuntimePilotAttachmentCount()).toBe(0);
  });
});
