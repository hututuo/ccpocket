import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  ContextFeatureHandler,
  loadCodexContextUsageFromRollout,
  parseCodexContextUsageNotification,
  parseCodexTokenCountEvent,
} from "./context.js";
import type { LocalFeatureRuntime } from "./runtime.js";

const temporaryRoots: string[] = [];
const durableThreadId = "019f1234-5678-7abc-8def-0123456789ab";
const otherDurableThreadId = "019f1234-5678-7abc-8def-0123456789ac";

afterEach(async () => {
  await Promise.all(
    temporaryRoots.splice(0).map((path) => rm(path, { recursive: true })),
  );
});

describe("Codex context usage", () => {
  it("parses current tokenUsage and retains last versus cumulative totals", () => {
    expect(
      parseCodexContextUsageNotification({
        turnId: "turn-1",
        tokenUsage: {
          last: {
            totalTokens: 80,
            inputTokens: 60,
            cachedInputTokens: 20,
            cacheWriteInputTokens: 3,
            outputTokens: 20,
            reasoningOutputTokens: 5,
          },
          total: {
            totalTokens: 180,
            inputTokens: 140,
            cachedInputTokens: 50,
            cacheWriteInputTokens: 4,
            outputTokens: 40,
            reasoningOutputTokens: 10,
          },
          modelContextWindow: 200,
        },
      }),
    ).toMatchObject({
      type: "context_usage",
      turnId: "turn-1",
      last: { totalTokens: 80 },
      total: { totalTokens: 180 },
      modelContextWindow: 200,
    });
  });

  it("accepts the legacy flat usage shape", () => {
    expect(
      parseCodexContextUsageNotification({
        usage: {
          input_tokens: 70,
          cached_input_tokens: 30,
          output_tokens: 10,
        },
      }),
    ).toMatchObject({
      last: {
        totalTokens: 80,
        inputTokens: 70,
        cachedInputTokens: 30,
        outputTokens: 10,
      },
      modelContextWindow: null,
    });
  });

  it("recovers the newest token_count from a bounded rollout tail", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-context-"));
    temporaryRoots.push(root);
    const day = join(root, "2026", "07", "18");
    await mkdir(day, { recursive: true });
    const threadId = "019f-thread";
    const filler = JSON.stringify({ type: "event_msg", payload: { type: "x" } });
    const tokenCount = JSON.stringify({
      type: "event_msg",
      payload: {
        type: "token_count",
        info: {
          last_token_usage: {
            total_tokens: 90,
            input_tokens: 75,
            output_tokens: 15,
          },
          total_token_usage: {
            total_tokens: 190,
            input_tokens: 160,
            output_tokens: 30,
          },
          model_context_window: 400,
        },
      },
    });
    await writeFile(
      join(day, `rollout-2026-07-18T00-00-00-${threadId}.jsonl`),
      `${`${filler}\n`.repeat(200)}${tokenCount}\n`,
    );

    await expect(
      loadCodexContextUsageFromRollout(threadId, {
        sessionsDir: root,
        maxTailBytes: 4096,
      }),
    ).resolves.toMatchObject({
      last: { totalTokens: 90 },
      total: { totalTokens: 190 },
      modelContextWindow: 400,
    });
  });

  it("parses the current payload.info rollout envelope", () => {
    expect(
      parseCodexTokenCountEvent({
        type: "event_msg",
        payload: {
          type: "token_count",
          info: {
            last_token_usage: { total_tokens: 48, input_tokens: 40 },
            total_token_usage: { total_tokens: 148, input_tokens: 120 },
            model_context_window: 256,
          },
        },
      }),
    ).toMatchObject({
      last: { totalTokens: 48 },
      total: { totalTokens: 148 },
      modelContextWindow: 256,
    });
  });

  it("bounds rollout discovery by directory-read count", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-context-bound-"));
    temporaryRoots.push(root);
    const day = join(root, "2026", "07", "18");
    await mkdir(day, { recursive: true });
    await writeFile(
      join(day, "rollout-2026-07-18T00-00-00-thread-bounded.jsonl"),
      `${JSON.stringify({
        type: "event_msg",
        payload: {
          type: "token_count",
          info: {
            last_token_usage: { total_tokens: 1 },
            total_token_usage: { total_tokens: 2 },
          },
        },
      })}\n`,
    );

    await expect(
      loadCodexContextUsageFromRollout("thread-bounded", {
        sessionsDir: root,
        maxDirectoryReads: 1,
      }),
    ).resolves.toBeNull();
  });

  it("requires matching rollout metadata for a durable provider thread", async () => {
    const root = await mkdtemp(join(tmpdir(), "ccpocket-context-durable-"));
    temporaryRoots.push(root);
    const day = join(root, "2026", "07", "18");
    await mkdir(day, { recursive: true });
    const tokenCount = JSON.stringify({
      type: "event_msg",
      payload: {
        type: "token_count",
        info: {
          last_token_usage: { total_tokens: 90 },
          total_token_usage: { total_tokens: 190 },
        },
      },
    });
    const rolloutPath = join(
      day,
      `rollout-2026-07-18T00-00-00-${durableThreadId}.jsonl`,
    );
    await writeFile(
      rolloutPath,
      `${JSON.stringify({
        type: "session_meta",
        payload: { id: otherDurableThreadId },
      })}\n${tokenCount}\n`,
    );

    await expect(
      loadCodexContextUsageFromRollout(durableThreadId, {
        sessionsDir: root,
        requireVerifiedIdentity: true,
      }),
    ).resolves.toBeNull();

    await writeFile(
      rolloutPath,
      `${JSON.stringify({
        type: "session_meta",
        payload: { id: durableThreadId },
      })}\n${tokenCount}\n`,
    );
    await expect(
      loadCodexContextUsageFromRollout(durableThreadId.toUpperCase(), {
        sessionsDir: root,
        requireVerifiedIdentity: true,
      }),
    ).resolves.toMatchObject({
      last: { totalTokens: 90 },
      total: { totalTokens: 190 },
    });
  });

  it("serves explicit usage with strict session correlation", async () => {
    const sent: unknown[] = [];
    const load = vi.fn(async () => ({
      type: "context_usage" as const,
      last: { totalTokens: 10, inputTokens: 8, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 2, reasoningOutputTokens: 0 },
      total: { totalTokens: 20, inputTokens: 16, cachedInputTokens: 0, cacheWriteInputTokens: 0, outputTokens: 4, reasoningOutputTokens: 0 },
      modelContextWindow: 100,
    }));
    const handler = new ContextFeatureHandler({ load });
    const runtime = contextRuntime(
      sent,
      new Set(["context_usage", "context_usage_result", "context_usage_error"]),
    );

    await handler.handle(
      {
        type: "get_context_usage",
        sessionId: "session-1",
        requestId: "context-1",
      },
      {
        client: {},
        signal: new AbortController().signal,
        runtime,
      },
    );

    expect(load).toHaveBeenCalledWith(
      "thread-1",
      expect.objectContaining({
        signal: expect.any(AbortSignal),
        scanDeadlineMs: 1_500,
        maxDirectoryReads: 256,
        requireVerifiedIdentity: false,
      }),
    );
    expect(sent).toEqual([
      expect.objectContaining({
        type: "context_usage_result",
        sessionId: "session-1",
        requestId: "context-1",
        last: expect.objectContaining({ totalTokens: 10 }),
      }),
    ]);
  });

  it("loads a verified durable thread without creating or resuming a runtime", async () => {
    const sent: unknown[] = [];
    const load = vi.fn(async () => ({
      type: "context_usage" as const,
      last: {
        totalTokens: 10,
        inputTokens: 8,
        cachedInputTokens: 0,
        cacheWriteInputTokens: 0,
        outputTokens: 2,
        reasoningOutputTokens: 0,
      },
      total: {
        totalTokens: 20,
        inputTokens: 16,
        cachedInputTokens: 0,
        cacheWriteInputTokens: 0,
        outputTokens: 4,
        reasoningOutputTokens: 0,
      },
      modelContextWindow: 100,
    }));
    const runtime = durableContextRuntime(
      sent,
      new Set([
        "context_usage",
        "context_usage_result",
        "context_usage_error",
      ]),
    );

    await new ContextFeatureHandler({ load }).handle(
      { type: "get_context_usage", sessionId: durableThreadId },
      {
        client: {},
        signal: new AbortController().signal,
        runtime,
      },
    );

    expect(load).toHaveBeenCalledWith(
      durableThreadId,
      expect.objectContaining({ requireVerifiedIdentity: true }),
    );
    expect(runtime.createStandaloneCodexProcess).not.toHaveBeenCalled();
    expect(sent).toEqual([
      expect.objectContaining({
        type: "context_usage_result",
        sessionId: durableThreadId,
      }),
    ]);
  });

  it("rejects a malformed durable id before touching rollout storage", async () => {
    const sent: unknown[] = [];
    const load = vi.fn();
    const runtime = durableContextRuntime(
      sent,
      new Set([
        "context_usage",
        "context_usage_result",
        "context_usage_error",
      ]),
    );

    await new ContextFeatureHandler({ load }).handle(
      {
        type: "get_context_usage",
        sessionId: "../../not-a-thread",
        requestId: "context-invalid",
      },
      {
        client: {},
        signal: new AbortController().signal,
        runtime,
      },
    );

    expect(load).not.toHaveBeenCalled();
    expect(sent).toEqual([
      expect.objectContaining({
        type: "context_usage_error",
        requestId: "context-invalid",
        errorCode: "context_usage_session_not_found",
      }),
    ]);
  });

  it("keeps the legacy context_usage response for older capable clients", async () => {
    const sent: unknown[] = [];
    const runtime = durableContextRuntime(
      sent,
      new Set(["context_usage"]),
    );
    const handler = new ContextFeatureHandler({
      load: async () => ({
        type: "context_usage",
        last: {
          totalTokens: 1,
          inputTokens: 1,
          cachedInputTokens: 0,
          cacheWriteInputTokens: 0,
          outputTokens: 0,
          reasoningOutputTokens: 0,
        },
        total: {
          totalTokens: 2,
          inputTokens: 2,
          cachedInputTokens: 0,
          cacheWriteInputTokens: 0,
          outputTokens: 0,
          reasoningOutputTokens: 0,
        },
        modelContextWindow: 100,
      }),
    });

    await handler.handle(
      { type: "get_context_usage", sessionId: durableThreadId },
      {
        client: {},
        signal: new AbortController().signal,
        runtime,
      },
    );

    expect(sent).toEqual([
      expect.objectContaining({
        type: "context_usage",
        sessionId: durableThreadId,
      }),
    ]);
  });

  it("enforces the explicit request deadline even if a loader ignores abort", async () => {
    const sent: unknown[] = [];
    const handler = new ContextFeatureHandler({
      load: () => new Promise(() => {}),
      deadlineMs: 5,
    });

    await handler.handle(
      { type: "get_context_usage", sessionId: "session-1" },
      {
        client: {},
        signal: new AbortController().signal,
        runtime: contextRuntime(
          sent,
          new Set([
            "context_usage",
            "context_usage_result",
            "context_usage_error",
          ]),
        ),
      },
    );

    expect(sent).toEqual([
      expect.objectContaining({
        type: "context_usage_error",
        sessionId: "session-1",
        errorCode: "context_usage_failed",
        message: expect.stringContaining("timed out"),
      }),
    ]);
  });

  it("echoes requestId on a typed context failure", async () => {
    const sent: unknown[] = [];
    const handler = new ContextFeatureHandler({
      load: async () => {
        throw new Error("bounded read failed");
      },
    });

    await handler.handle(
      {
        type: "get_context_usage",
        sessionId: "session-1",
        requestId: "context-error-1",
      },
      {
        client: {},
        signal: new AbortController().signal,
        runtime: contextRuntime(
          sent,
          new Set([
            "context_usage",
            "context_usage_result",
            "context_usage_error",
          ]),
        ),
      },
    );

    expect(sent).toEqual([
      expect.objectContaining({
        type: "context_usage_error",
        sessionId: "session-1",
        requestId: "context-error-1",
        errorCode: "context_usage_failed",
      }),
    ]);
  });
});

function contextRuntime(
  sent: unknown[],
  supported = new Set(["context_usage"]),
): LocalFeatureRuntime {
  return {
    getSession: (sessionId) =>
      sessionId === "session-1"
        ? { id: sessionId, provider: "codex", process: {} }
        : undefined,
    getCodexThreadId: () => "thread-1",
    getActiveCodexProcess: () => null,
    createStandaloneCodexProcess: async () => {
      throw new Error("not used");
    },
    send: (_client, message) => sent.push(message),
    supports: (_client, type) => supported.has(type),
  };
}

function durableContextRuntime(
  sent: unknown[],
  supported: Set<string>,
): LocalFeatureRuntime {
  return {
    getSession: () => undefined,
    getCodexThreadId: () => undefined,
    getActiveCodexProcess: () => null,
    createStandaloneCodexProcess: vi.fn(async () => {
      throw new Error("must not create a runtime for context usage");
    }),
    send: (_client, message) => sent.push(message),
    supports: (_client, type) => supported.has(type),
  };
}
