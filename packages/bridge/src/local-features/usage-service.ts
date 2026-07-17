import type { CodexProcess } from "../codex-process.js";
import type { SessionUsageInfoPayload } from "./protocol.js";
import { parseCodexAccountRateLimits } from "./account-usage.js";
import { fetchBoundedCodexUsageFallback } from "./bounded-usage-fallback.js";
import type { LocalFeatureClientMessage } from "./protocol.js";
import type {
  LocalFeatureHandler,
  LocalFeatureHandleContext,
  LocalFeatureRuntime,
} from "./runtime.js";

interface UsageServiceOptions {
  getActiveCodexProcess: () => CodexProcess | null;
  createStandaloneCodexProcess: (
    requestTimeoutMs?: number,
  ) => Promise<CodexProcess>;
  cacheTtlMs?: number;
  requestTimeoutMs?: number;
  fallback?: () => Promise<SessionUsageInfoPayload[]>;
}

const DEFAULT_USAGE_REQUEST_TIMEOUT_MS = 10_000;
const USAGE_TIMEOUT_GUARD_GRACE_MS = 100;

class UsageOperationTimeoutError extends Error {}

export class UsageFeatureHandler implements LocalFeatureHandler {
  readonly messageTypes = ["get_session_usage"] as const;
  private readonly service: UsageService;

  constructor(runtime: LocalFeatureRuntime) {
    this.service = new UsageService({
      getActiveCodexProcess: () => runtime.getActiveCodexProcess(),
      createStandaloneCodexProcess: (timeoutMs) =>
        runtime.createStandaloneCodexProcess(timeoutMs),
    });
  }

  async handle(
    message: LocalFeatureClientMessage,
    context: LocalFeatureHandleContext,
  ): Promise<void> {
    if (message.type !== "get_session_usage") return;
    if (!context.runtime.supports(context.client, "session_usage_result")) {
      context.runtime.send(context.client, {
        type: "error",
        errorCode: "unsupported_capability",
        message: "Session usage capability was not negotiated",
      });
      return;
    }
    const session = context.runtime.getSession(message.sessionId);
    if (
      !session ||
      session.provider !== "codex" ||
      !isCodexReadOnlyProcess(session.process)
    ) {
      context.runtime.send(context.client, {
        type: "session_usage_result",
        providers: [],
        sessionId: message.sessionId,
        requestId: message.requestId,
        error: "Codex session not found",
      });
      return;
    }

    try {
      // Caller cancellation releases the WebSocket operation immediately, but
      // does not cancel the Bridge/account single-flight shared by other clients.
      const providers = await waitForCaller(
        this.service.getUsage(session.process),
        context.signal,
      );
      context.runtime.send(context.client, {
        type: "session_usage_result",
        providers,
        sessionId: message.sessionId,
        requestId: message.requestId,
      });
    } catch (error) {
      if (context.signal.aborted) return;
      context.runtime.send(context.client, {
        type: "session_usage_result",
        providers: [],
        sessionId: message.sessionId,
        requestId: message.requestId,
        error: `Failed to fetch usage: ${
          error instanceof Error ? error.message : String(error)
        }`,
      });
    }
  }
}

/**
 * Fetch account quota without creating a second persistent Codex runtime.
 * Concurrent callers share one request and a small cache absorbs reconnect
 * bursts from mobile clients.
 */
export class UsageService {
  private readonly cacheTtlMs: number;
  private readonly requestTimeoutMs: number;
  private readonly fallback: () => Promise<SessionUsageInfoPayload[]>;
  private cache: {
    expiresAt: number;
    providers: SessionUsageInfoPayload[];
  } | null = null;
  private inFlight: Promise<SessionUsageInfoPayload[]> | null = null;

  constructor(private readonly options: UsageServiceOptions) {
    this.cacheTtlMs = options.cacheTtlMs ?? 15_000;
    this.requestTimeoutMs = normalizeTimeout(
      options.requestTimeoutMs,
      DEFAULT_USAGE_REQUEST_TIMEOUT_MS,
    );
    this.fallback = options.fallback ?? fetchBoundedCodexUsageFallback;
  }

  /**
   * Quota is account-scoped. A preferred session process only selects an
   * authenticated app-server transport; it never partitions the cache.
   */
  getUsage(
    preferredProcess: CodexProcess | null =
      this.options.getActiveCodexProcess(),
    now = Date.now(),
  ): Promise<SessionUsageInfoPayload[]> {
    if (this.cache && this.cache.expiresAt > now) {
      return Promise.resolve(this.cache.providers);
    }
    if (this.inFlight) return this.inFlight;

    const request = this.fetchFresh(preferredProcess)
      .then((providers) => {
        this.cache = {
          expiresAt: Date.now() + this.cacheTtlMs,
          providers,
        };
        return providers;
      })
      .finally(() => {
        if (this.inFlight === request) this.inFlight = null;
      });
    this.inFlight = request;
    return request;
  }

  clearCache(): void {
    this.cache = null;
  }

  private async fetchFresh(
    preferredProcess: CodexProcess | null,
  ): Promise<SessionUsageInfoPayload[]> {
    let process = preferredProcess;
    let ownsProcess = false;
    try {
      if (!process) {
        process = await this.createOwnedProcess();
        ownsProcess = true;
      }
      const response = await withTimeout(
        process.requestReadOnlyRpc<Record<string, unknown>>(
          "account/rateLimits/read",
          {},
          { timeoutMs: this.requestTimeoutMs },
        ),
        this.guardTimeoutMs,
        "account/rateLimits/read",
      );
      return [parseCodexAccountRateLimits(response)];
    } catch (error) {
      console.warn(
        `[usage] account/rateLimits/read failed, falling back to rollout data: ${
          error instanceof Error ? error.message : String(error)
        }`,
      );
      return withTimeout(
        this.fallback(),
        this.guardTimeoutMs,
        "bounded rollout usage fallback",
      );
    } finally {
      if (ownsProcess) process?.stop();
    }
  }

  private get guardTimeoutMs(): number {
    return this.requestTimeoutMs + USAGE_TIMEOUT_GUARD_GRACE_MS;
  }

  private async createOwnedProcess(): Promise<CodexProcess> {
    const creation = this.options.createStandaloneCodexProcess(
      this.requestTimeoutMs,
    );
    try {
      return await withTimeout(
        creation,
        this.guardTimeoutMs,
        "standalone Codex initialization",
      );
    } catch (error) {
      if (error instanceof UsageOperationTimeoutError) {
        // A factory cannot be cancelled generically. If it resolves after the
        // guard fires, stop the now-unowned runtime immediately.
        void creation.then(
          (lateProcess) => lateProcess.stop(),
          () => {},
        );
      }
      throw error;
    }
  }
}

function normalizeTimeout(value: number | undefined, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) && value > 0
    ? Math.floor(value)
    : fallback;
}

function withTimeout<T>(
  operation: Promise<T>,
  timeoutMs: number,
  label: string,
): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => {
      reject(
        new UsageOperationTimeoutError(
          `${label} timed out after ${timeoutMs}ms`,
        ),
      );
    }, timeoutMs);
    operation.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (error) => {
        clearTimeout(timer);
        reject(error);
      },
    );
  });
}

function waitForCaller<T>(
  operation: Promise<T>,
  signal: AbortSignal,
): Promise<T> {
  if (signal.aborted) {
    return Promise.reject(
      signal.reason instanceof Error
        ? signal.reason
        : new Error("Usage request aborted"),
    );
  }
  return new Promise<T>((resolve, reject) => {
    const abort = (): void => {
      cleanup();
      reject(
        signal.reason instanceof Error
          ? signal.reason
          : new Error("Usage request aborted"),
      );
    };
    const cleanup = (): void => signal.removeEventListener("abort", abort);
    signal.addEventListener("abort", abort, { once: true });
    operation.then(
      (value) => {
        cleanup();
        resolve(value);
      },
      (error) => {
        cleanup();
        reject(error);
      },
    );
  });
}

function isCodexReadOnlyProcess(value: unknown): value is CodexProcess {
  return (
    value !== null &&
    typeof value === "object" &&
    typeof (value as { requestReadOnlyRpc?: unknown }).requestReadOnlyRpc ===
      "function"
  );
}
