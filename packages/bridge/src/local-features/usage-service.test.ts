import { describe, expect, it, vi } from "vitest";
import type { CodexProcess } from "../codex-process.js";
import type { LocalFeatureRuntime } from "./runtime.js";
import { UsageFeatureHandler, UsageService } from "./usage-service.js";

const response = {
  rateLimits: {
    limitId: "codex",
    primary: {
      usedPercent: 10,
      windowDurationMins: 300,
      resetsAt: 1_800_000_000,
    },
    secondary: null,
  },
  rateLimitsByLimitId: null,
  rateLimitResetCredits: null,
};

describe("UsageService", () => {
  it("reuses the active process and single-flights reconnect bursts", async () => {
    let resolveRead!: (value: Record<string, unknown>) => void;
    const read = vi.fn(
      () =>
        new Promise<Record<string, unknown>>((resolve) => {
          resolveRead = resolve;
        }),
    );
    const active = {
      requestReadOnlyRpc: read,
      stop: vi.fn(),
    } as unknown as CodexProcess;
    const standalone = vi.fn();
    const service = new UsageService({
      getActiveCodexProcess: () => active,
      createStandaloneCodexProcess: standalone,
    });

    const first = service.getUsage();
    const second = service.getUsage();
    expect(read).toHaveBeenCalledTimes(1);
    resolveRead(response);
    await expect(first).resolves.toMatchObject([
      { provider: "codex", source: "app_server" },
    ]);
    await expect(second).resolves.toMatchObject([
      { provider: "codex", source: "app_server" },
    ]);
    expect(standalone).not.toHaveBeenCalled();
    expect(active.stop).not.toHaveBeenCalled();
  });

  it("deduplicates account quota across different session processes", async () => {
    const first = {
      requestReadOnlyRpc: vi.fn(async () => response),
      stop: vi.fn(),
    } as unknown as CodexProcess;
    const secondResponse = structuredClone(response);
    secondResponse.rateLimits.primary.usedPercent = 66;
    const second = {
      requestReadOnlyRpc: vi.fn(async () => secondResponse),
      stop: vi.fn(),
    } as unknown as CodexProcess;
    const service = new UsageService({
      getActiveCodexProcess: () => first,
      createStandaloneCodexProcess: vi.fn(),
    });

    const [left, right] = await Promise.all([
      service.getUsage(first),
      service.getUsage(second),
    ]);
    expect(left[0]?.fiveHour?.utilization).toBe(10);
    expect(right[0]?.fiveHour?.utilization).toBe(10);
    expect(first.requestReadOnlyRpc).toHaveBeenCalledTimes(1);
    expect(second.requestReadOnlyRpc).not.toHaveBeenCalled();
  });

  it("stops a short-lived process and falls back when RPC fails", async () => {
    const standalone = {
      requestReadOnlyRpc: vi.fn(async () => {
        throw new Error("unavailable");
      }),
      stop: vi.fn(),
    } as unknown as CodexProcess;
    const fallback = vi.fn(async () => [
      {
        provider: "codex" as const,
        fiveHour: null,
        sevenDay: null,
        source: "session_log" as const,
      },
    ]);
    const service = new UsageService({
      getActiveCodexProcess: () => null,
      createStandaloneCodexProcess: async () => standalone,
      fallback,
    });

    await expect(service.getUsage()).resolves.toMatchObject([
      { source: "session_log" },
    ]);
    expect(standalone.stop).toHaveBeenCalledTimes(1);
    expect(fallback).toHaveBeenCalledTimes(1);
  });

  it("times out a quota read, stops the owned process, and recovers inFlight", async () => {
    vi.useFakeTimers();
    const warning = vi.spyOn(console, "warn").mockImplementation(() => {});
    try {
      const first = {
        requestReadOnlyRpc: vi.fn(
          () => new Promise<Record<string, unknown>>(() => {}),
        ),
        stop: vi.fn(),
      } as unknown as CodexProcess;
      const second = {
        requestReadOnlyRpc: vi.fn(async () => response),
        stop: vi.fn(),
      } as unknown as CodexProcess;
      const standalone = vi
        .fn()
        .mockResolvedValueOnce(first)
        .mockResolvedValueOnce(second);
      const fallback = vi.fn(async () => [
        {
          provider: "codex" as const,
          fiveHour: null,
          sevenDay: null,
          source: "session_log" as const,
        },
      ]);
      const service = new UsageService({
        getActiveCodexProcess: () => null,
        createStandaloneCodexProcess: standalone,
        cacheTtlMs: 0,
        requestTimeoutMs: 25,
        fallback,
      });

      const timedOut = service.getUsage();
      await Promise.resolve();
      await Promise.resolve();
      await Promise.resolve();
      await Promise.resolve();
      expect(first.requestReadOnlyRpc).toHaveBeenCalledWith(
        "account/rateLimits/read",
        {},
        { timeoutMs: 25 },
      );
      await vi.advanceTimersByTimeAsync(125);
      await expect(timedOut).resolves.toMatchObject([
        { source: "session_log" },
      ]);
      expect(first.stop).toHaveBeenCalledTimes(1);

      await expect(service.getUsage()).resolves.toMatchObject([
        { source: "app_server" },
      ]);
      expect(second.stop).toHaveBeenCalledTimes(1);
      expect(standalone).toHaveBeenNthCalledWith(1, 25);
      expect(standalone).toHaveBeenNthCalledWith(2, 25);
    } finally {
      warning.mockRestore();
      vi.useRealTimers();
    }
  });

  it("stops a standalone process that arrives after initialization timeout", async () => {
    vi.useFakeTimers();
    const warning = vi.spyOn(console, "warn").mockImplementation(() => {});
    try {
      let resolveLate!: (process: CodexProcess) => void;
      const lateCreation = new Promise<CodexProcess>((resolve) => {
        resolveLate = resolve;
      });
      const late = {
        requestReadOnlyRpc: vi.fn(async () => response),
        stop: vi.fn(),
      } as unknown as CodexProcess;
      const recovered = {
        requestReadOnlyRpc: vi.fn(async () => response),
        stop: vi.fn(),
      } as unknown as CodexProcess;
      const standalone = vi
        .fn()
        .mockReturnValueOnce(lateCreation)
        .mockResolvedValueOnce(recovered);
      const fallback = vi.fn(async () => [
        {
          provider: "codex" as const,
          fiveHour: null,
          sevenDay: null,
          source: "session_log" as const,
        },
      ]);
      const service = new UsageService({
        getActiveCodexProcess: () => null,
        createStandaloneCodexProcess: standalone,
        cacheTtlMs: 0,
        requestTimeoutMs: 25,
        fallback,
      });

      const timedOut = service.getUsage();
      await vi.advanceTimersByTimeAsync(125);
      await expect(timedOut).resolves.toMatchObject([
        { source: "session_log" },
      ]);
      expect(late.stop).not.toHaveBeenCalled();

      resolveLate(late);
      await Promise.resolve();
      await Promise.resolve();
      expect(late.stop).toHaveBeenCalledTimes(1);
      expect(late.requestReadOnlyRpc).not.toHaveBeenCalled();

      await expect(service.getUsage()).resolves.toMatchObject([
        { source: "app_server" },
      ]);
      expect(recovered.stop).toHaveBeenCalledTimes(1);
      expect(standalone).toHaveBeenCalledTimes(2);
    } finally {
      warning.mockRestore();
      vi.useRealTimers();
    }
  });

  it("guards a fallback that never settles and recovers inFlight", async () => {
    vi.useFakeTimers();
    const warning = vi.spyOn(console, "warn").mockImplementation(() => {});
    try {
      const active = {
        requestReadOnlyRpc: vi.fn(async () => {
          throw new Error("unsupported");
        }),
        stop: vi.fn(),
      } as unknown as CodexProcess;
      const fallback = vi
        .fn()
        .mockReturnValueOnce(
          new Promise<
            Array<{
              provider: "codex";
              fiveHour: null;
              sevenDay: null;
              source: "session_log";
            }>
          >(() => {}),
        )
        .mockResolvedValueOnce([
          {
            provider: "codex" as const,
            fiveHour: null,
            sevenDay: null,
            source: "session_log" as const,
          },
        ]);
      const service = new UsageService({
        getActiveCodexProcess: () => active,
        createStandaloneCodexProcess: vi.fn(),
        cacheTtlMs: 0,
        requestTimeoutMs: 25,
        fallback,
      });

      const timedOut = expect(service.getUsage()).rejects.toThrow(
        "bounded rollout usage fallback timed out after 125ms",
      );
      await Promise.resolve();
      await Promise.resolve();
      await Promise.resolve();
      expect(fallback).toHaveBeenCalledTimes(1);
      await vi.advanceTimersByTimeAsync(125);
      await timedOut;

      await expect(service.getUsage()).resolves.toMatchObject([
        { source: "session_log" },
      ]);
      expect(fallback).toHaveBeenCalledTimes(2);
      expect(active.stop).not.toHaveBeenCalled();
    } finally {
      warning.mockRestore();
      vi.useRealTimers();
    }
  });

  it("keeps the default standalone, RPC, and fallback deadlines inside the Mobile window", async () => {
    vi.useFakeTimers();
    const warning = vi.spyOn(console, "warn").mockImplementation(() => {});
    try {
      const fallback = vi.fn(async () => [
        {
          provider: "codex" as const,
          fiveHour: null,
          sevenDay: null,
          source: "session_log" as const,
        },
      ]);
      const neverCreated = new Promise<CodexProcess>(() => {});
      const standalone = vi.fn(() => neverCreated);
      const service = new UsageService({
        getActiveCodexProcess: () => null,
        createStandaloneCodexProcess: standalone,
        fallback,
      });

      const request = service.getUsage();
      expect(standalone).toHaveBeenCalledWith(2_500);
      await vi.advanceTimersByTimeAsync(2_600);
      await expect(request).resolves.toMatchObject([
        { source: "session_log" },
      ]);
      expect(fallback).toHaveBeenCalledTimes(1);

      const active = {
        requestReadOnlyRpc: vi.fn(
          () => new Promise<Record<string, unknown>>(() => {}),
        ),
        stop: vi.fn(),
      } as unknown as CodexProcess;
      const activeService = new UsageService({
        getActiveCodexProcess: () => active,
        createStandaloneCodexProcess: vi.fn(),
        cacheTtlMs: 0,
        fallback,
      });
      const activeRequest = activeService.getUsage();
      expect(active.requestReadOnlyRpc).toHaveBeenCalledWith(
        "account/rateLimits/read",
        {},
        { timeoutMs: 4_000 },
      );
      await vi.advanceTimersByTimeAsync(4_100);
      await expect(activeRequest).resolves.toMatchObject([
        { source: "session_log" },
      ]);
    } finally {
      warning.mockRestore();
      vi.useRealTimers();
    }
  });

  it("logs only a safe result category and elapsed time on fallback", async () => {
    const warning = vi.spyOn(console, "warn").mockImplementation(() => {});
    try {
      const active = {
        requestReadOnlyRpc: vi.fn(async () => {
          throw new Error(
            "private thread 019f1234-5678-7abc-8def-0123456789ab failed",
          );
        }),
        stop: vi.fn(),
      } as unknown as CodexProcess;
      const service = new UsageService({
        getActiveCodexProcess: () => active,
        createStandaloneCodexProcess: vi.fn(),
        fallback: async () => [],
      });

      await expect(service.getUsage()).resolves.toEqual([]);
      const output = warning.mock.calls.flat().join(" ");
      expect(output).toContain("result=fallback");
      expect(output).toContain("reason=Error");
      expect(output).toMatch(/elapsedMs=\d+/);
      expect(output).not.toContain("019f1234");
      expect(output).not.toContain("private thread");
    } finally {
      warning.mockRestore();
    }
  });
});

describe("UsageFeatureHandler", () => {
  it("strictly echoes the requesting session and request ids", async () => {
    const sent: unknown[] = [];
    const process = {
      requestReadOnlyRpc: vi.fn(async () => response),
      stop: vi.fn(),
    } as unknown as CodexProcess;
    const runtime = featureRuntime(process, sent);
    const handler = new UsageFeatureHandler(runtime);

    await handler.handle(
      {
        type: "get_session_usage",
        sessionId: "session-1",
        requestId: "quota-1",
      },
      {
        client: {},
        signal: new AbortController().signal,
        runtime,
      },
    );

    expect(sent).toEqual([
      expect.objectContaining({
        type: "session_usage_result",
        sessionId: "session-1",
        requestId: "quota-1",
        providers: [expect.objectContaining({ source: "app_server" })],
      }),
    ]);
  });

  it("capability-gates the feature before reading account quota", async () => {
    const sent: unknown[] = [];
    const process = {
      requestReadOnlyRpc: vi.fn(async () => response),
      stop: vi.fn(),
    } as unknown as CodexProcess;
    const runtime = featureRuntime(process, sent, false);

    await new UsageFeatureHandler(runtime).handle(
      {
        type: "get_session_usage",
        sessionId: "session-1",
        requestId: "quota-1",
      },
      {
        client: {},
        signal: new AbortController().signal,
        runtime,
      },
    );

    expect(process.requestReadOnlyRpc).not.toHaveBeenCalled();
    expect(sent).toEqual([
      expect.objectContaining({
        type: "error",
        errorCode: "unsupported_capability",
      }),
    ]);
  });

  it("serves account quota for a durable thread through the active process", async () => {
    const sent: unknown[] = [];
    const process = {
      requestReadOnlyRpc: vi.fn(async () => response),
      stop: vi.fn(),
    } as unknown as CodexProcess;
    const standalone = vi.fn();
    const runtime: LocalFeatureRuntime = {
      getSession: () => undefined,
      getCodexThreadId: () => undefined,
      getActiveCodexProcess: () => process,
      createStandaloneCodexProcess: standalone,
      send: (_client, message) => sent.push(message),
      supports: (_client, type) => type === "session_usage_result",
    };

    await new UsageFeatureHandler(runtime).handle(
      {
        type: "get_session_usage",
        sessionId: "019f1234-5678-7abc-8def-0123456789ab",
        requestId: "quota-durable-active",
      },
      {
        client: {},
        signal: new AbortController().signal,
        runtime,
      },
    );

    expect(process.requestReadOnlyRpc).toHaveBeenCalledTimes(1);
    expect(standalone).not.toHaveBeenCalled();
    expect(sent).toEqual([
      expect.objectContaining({
        type: "session_usage_result",
        sessionId: "019f1234-5678-7abc-8def-0123456789ab",
        requestId: "quota-durable-active",
        providers: [expect.objectContaining({ source: "app_server" })],
      }),
    ]);
  });

  it("serves account quota for a durable thread through a short-lived process", async () => {
    const sent: unknown[] = [];
    const process = {
      requestReadOnlyRpc: vi.fn(async () => response),
      stop: vi.fn(),
    } as unknown as CodexProcess;
    const standalone = vi.fn(async () => process);
    const runtime: LocalFeatureRuntime = {
      getSession: () => undefined,
      getCodexThreadId: () => undefined,
      getActiveCodexProcess: () => null,
      createStandaloneCodexProcess: standalone,
      send: (_client, message) => sent.push(message),
      supports: (_client, type) => type === "session_usage_result",
    };

    await new UsageFeatureHandler(runtime).handle(
      {
        type: "get_session_usage",
        sessionId: "019f1234-5678-7abc-8def-0123456789ab",
        requestId: "quota-durable-standalone",
      },
      {
        client: {},
        signal: new AbortController().signal,
        runtime,
      },
    );

    expect(standalone).toHaveBeenCalledWith(2_500);
    expect(process.requestReadOnlyRpc).toHaveBeenCalledTimes(1);
    expect(process.stop).toHaveBeenCalledTimes(1);
    expect(sent).toEqual([
      expect.objectContaining({
        type: "session_usage_result",
        requestId: "quota-durable-standalone",
        providers: [expect.objectContaining({ source: "app_server" })],
      }),
    ]);
  });

  it("releases a disconnected caller without cancelling the account single-flight", async () => {
    const sent: unknown[] = [];
    let resolveRead!: (value: Record<string, unknown>) => void;
    const process = {
      requestReadOnlyRpc: vi.fn(
        () =>
          new Promise<Record<string, unknown>>((resolve) => {
            resolveRead = resolve;
          }),
      ),
      stop: vi.fn(),
    } as unknown as CodexProcess;
    const runtime = featureRuntime(process, sent);
    const controller = new AbortController();
    const request = new UsageFeatureHandler(runtime).handle(
      {
        type: "get_session_usage",
        sessionId: "session-1",
        requestId: "quota-1",
      },
      {
        client: {},
        signal: controller.signal,
        runtime,
      },
    );
    await vi.waitFor(() => {
      expect(process.requestReadOnlyRpc).toHaveBeenCalledOnce();
    });

    controller.abort(new Error("client disconnected"));
    await request;
    expect(sent).toEqual([]);

    resolveRead(response);
    await Promise.resolve();
    await Promise.resolve();
    expect(process.requestReadOnlyRpc).toHaveBeenCalledOnce();
  });
});

function featureRuntime(
  process: CodexProcess,
  sent: unknown[],
  supported = true,
): LocalFeatureRuntime {
  return {
    getSession: (sessionId) =>
      sessionId === "session-1"
        ? { id: sessionId, provider: "codex", process }
        : undefined,
    getCodexThreadId: () => "thread-1",
    getActiveCodexProcess: () => process,
    createStandaloneCodexProcess: async () => process,
    send: (_client, message) => sent.push(message),
    supports: (_client, type) =>
      supported && type === "session_usage_result",
  };
}
