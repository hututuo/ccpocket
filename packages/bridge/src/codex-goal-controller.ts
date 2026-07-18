import {
  CodexGoalSnapshotConflictError,
  matchesCodexGoalResumeLease,
  type CodexGoalResumeLease,
  type CodexProcess,
} from "./codex-process.js";
import type { CodexGoal, CodexGoalWritableStatus } from "./parser.js";
import type { SessionInfo } from "./session.js";

export interface CodexGoalUpdate {
  objective?: string;
  status?: CodexGoalWritableStatus;
  tokenBudget?: number | null;
}

export interface CodexGoalMergeResult {
  accepted: boolean;
  goal: CodexGoal | null;
  updatedAt?: number;
}

export interface CodexGoalControllerOptions {
  getSession: (sessionId: string) => SessionInfo | undefined;
  onCapabilityChanged?: (sessionId: string) => void;
}

export class CodexGoalConflictError extends Error {
  constructor(
    readonly expectedSequence: number | undefined,
    readonly currentSequence: number | undefined,
  ) {
    super(
      `Goal operation sequence changed (expected ${expectedSequence ?? "unknown"}, current ${currentSequence ?? "unknown"})`,
    );
    this.name = "CodexGoalConflictError";
  }
}

export class CodexGoalResumeLeaseConflictError extends Error {
  constructor(readonly currentGoal: CodexGoal | null) {
    super("The paused Goal was cleared, replaced, or changed");
    this.name = "CodexGoalResumeLeaseConflictError";
  }
}

function sameCodexGoalMutationVersion(
  left: CodexGoal | null | undefined,
  right: CodexGoal | null,
): boolean {
  if (left == null || right == null) return left == null && right == null;
  return (
    left.threadId === right.threadId &&
    left.objective === right.objective &&
    left.status === right.status &&
    left.tokenBudget === right.tokenBudget &&
    left.createdAt === right.createdAt
  );
}

/** Never let a delayed non-empty Goal move cached app-server time backwards. */
export function mergeCodexGoalState(
  current: CodexGoal | null | undefined,
  incoming: CodexGoal | null,
  lastUpdatedAt?: number,
  allowEqualAfterClear = false,
): CodexGoalMergeResult {
  const watermark = Math.max(
    current?.updatedAt ?? Number.NEGATIVE_INFINITY,
    lastUpdatedAt ?? Number.NEGATIVE_INFINITY,
  );
  if (
    incoming !== null &&
    (incoming.updatedAt < watermark ||
      (!allowEqualAfterClear &&
        current == null &&
        incoming.updatedAt === watermark))
  ) {
    return {
      accepted: false,
      goal: current ?? null,
      ...(Number.isFinite(watermark) ? { updatedAt: watermark } : {}),
    };
  }
  const nextWatermark =
    incoming === null ? watermark : Math.max(watermark, incoming.updatedAt);
  return {
    accepted: true,
    goal: incoming,
    ...(Number.isFinite(nextWatermark) ? { updatedAt: nextWatermark } : {}),
  };
}

/** Whether app-server explicitly reported that the Goal RPC is unavailable. */
export function isUnsupportedCodexGoalRpc(error: unknown): boolean {
  const record =
    error && typeof error === "object"
      ? (error as Record<string, unknown>)
      : undefined;
  const message = error instanceof Error ? error.message : String(error);
  return (
    record?.code === -32601 ||
    /goals feature is disabled|ephemeral thread does not support goals/i.test(
      message,
    ) ||
    /method not found|unsupported method|(?:thread\/goal\/(?:get|set|clear)|goal rpc|method).*not supported/i.test(
      message,
    )
  );
}

/**
 * Serializes Goal RPCs per Bridge session and coalesces concurrent refreshes.
 * Mutations deliberately call CodexProcess.setGoal(), preserving its pending
 * thread-settings barrier before an app-server-owned Goal continuation.
 */
export class CodexGoalController {
  private readonly tails = new Map<string, Promise<void>>();
  private readonly refreshes = new Map<string, Promise<CodexGoal | null>>();

  constructor(private readonly options: CodexGoalControllerOptions) {}

  refresh(sessionId: string): Promise<CodexGoal | null> {
    const existing = this.refreshes.get(sessionId);
    if (existing) return existing;

    const refresh = this.enqueue(sessionId, async () => {
      const session = this.requireCodexSession(sessionId);
      const process = session.process as CodexProcess;
      try {
        const snapshot = await process.getGoalSnapshot();
        this.setCapability(session, true);
        if (!snapshot.stable) return session.codexGoal ?? null;
        return this.mergeAuthoritativeRead(session, snapshot.goal, process);
      } catch (error) {
        if (isUnsupportedCodexGoalRpc(error)) {
          this.setCapability(session, false);
        }
        throw error;
      }
    });
    this.refreshes.set(sessionId, refresh);
    void refresh.then(
      () => this.removeRefresh(sessionId, refresh),
      () => this.removeRefresh(sessionId, refresh),
    );
    return refresh;
  }

  set(
    sessionId: string,
    update: CodexGoalUpdate,
    expectedOperationSequence?: number,
  ): Promise<CodexGoal | null> {
    // A refresh requested after this mutation must queue behind it rather than
    // joining a pre-mutation read that is still in flight.
    this.refreshes.delete(sessionId);
    return this.setInternal(sessionId, update, expectedOperationSequence);
  }

  /** Resume only the exact paused Goal owned by a permission restart. */
  resumeWithLease(
    sessionId: string,
    lease: CodexGoalResumeLease,
  ): Promise<CodexGoal | null> {
    this.refreshes.delete(sessionId);
    return this.setInternal(sessionId, { status: "active" }, undefined, lease);
  }

  private setInternal(
    sessionId: string,
    update: CodexGoalUpdate,
    expectedOperationSequence?: number,
    resumeLease?: CodexGoalResumeLease,
  ): Promise<CodexGoal | null> {
    return this.enqueue(sessionId, async () => {
      const session = this.requireCodexSession(sessionId);
      this.assertExpectedOperationSequence(
        session,
        expectedOperationSequence,
      );
      const process = session.process as CodexProcess;
      const baselineGoal = session.codexGoal ?? null;
      try {
        const goal = await process.setGoal(update, {
          validateCurrentGoal: (currentGoal) => {
            this.assertSameRuntime(sessionId, session, process);
            this.mergeAuthoritativeRead(session, currentGoal, process);
            if (
              resumeLease &&
              !matchesCodexGoalResumeLease(currentGoal, resumeLease)
            ) {
              throw new CodexGoalResumeLeaseConflictError(currentGoal);
            }
            if (
              expectedOperationSequence === undefined &&
              !resumeLease &&
              !sameCodexGoalMutationVersion(baselineGoal, currentGoal)
            ) {
              throw new CodexGoalConflictError(
                undefined,
                session.codexGoalOperationSequence,
              );
            }
            this.assertExpectedOperationSequence(
              session,
              expectedOperationSequence,
            );
          },
        });
        this.setCapability(session, true);
        const merged = this.mergeIntoSession(
          session,
          goal,
          process.lastGoalRpcSequence,
        );
        return merged;
      } catch (error) {
        if (error instanceof CodexGoalSnapshotConflictError) {
          if (resumeLease) {
            throw new CodexGoalResumeLeaseConflictError(
              session.codexGoal ?? null,
            );
          }
          throw new CodexGoalConflictError(
            expectedOperationSequence,
            session.codexGoalOperationSequence,
          );
        }
        if (isUnsupportedCodexGoalRpc(error)) {
          this.setCapability(session, false);
        }
        throw error;
      }
    });
  }

  clear(
    sessionId: string,
    expectedOperationSequence?: number,
  ): Promise<CodexGoal | null> {
    this.refreshes.delete(sessionId);
    return this.enqueue(sessionId, async () => {
      const session = this.requireCodexSession(sessionId);
      this.assertExpectedOperationSequence(
        session,
        expectedOperationSequence,
      );
      const process = session.process as CodexProcess;
      const baselineGoal = session.codexGoal ?? null;
      try {
        await process.clearGoal({
          validateCurrentGoal: (currentGoal) => {
            this.assertSameRuntime(sessionId, session, process);
            this.mergeAuthoritativeRead(session, currentGoal, process);
            if (
              expectedOperationSequence === undefined &&
              !sameCodexGoalMutationVersion(baselineGoal, currentGoal)
            ) {
              throw new CodexGoalConflictError(
                undefined,
                session.codexGoalOperationSequence,
              );
            }
            this.assertExpectedOperationSequence(
              session,
              expectedOperationSequence,
            );
          },
        });
        this.setCapability(session, true);
        return this.mergeIntoSession(
          session,
          null,
          process.lastGoalRpcSequence,
        );
      } catch (error) {
        if (error instanceof CodexGoalSnapshotConflictError) {
          throw new CodexGoalConflictError(
            expectedOperationSequence,
            session.codexGoalOperationSequence,
          );
        }
        if (isUnsupportedCodexGoalRpc(error)) {
          this.setCapability(session, false);
        }
        throw error;
      }
    });
  }

  private requireCodexSession(sessionId: string): SessionInfo {
    const session = this.options.getSession(sessionId);
    if (!session || session.provider !== "codex") {
      throw new Error(`Active Codex session not found: ${sessionId}`);
    }
    return session;
  }

  private assertExpectedOperationSequence(
    session: SessionInfo,
    expectedOperationSequence?: number,
  ): void {
    if (expectedOperationSequence === undefined) return;
    if (
      session.codexGoalOperationSequence !== expectedOperationSequence
    ) {
      throw new CodexGoalConflictError(
        expectedOperationSequence,
        session.codexGoalOperationSequence,
      );
    }
  }

  private assertSameRuntime(
    sessionId: string,
    expectedSession: SessionInfo,
    expectedProcess: CodexProcess,
  ): void {
    const current = this.requireCodexSession(sessionId);
    if (current !== expectedSession || current.process !== expectedProcess) {
      throw new Error(`Codex session changed during Goal mutation: ${sessionId}`);
    }
  }

  private mergeAuthoritativeRead(
    session: SessionInfo,
    incoming: CodexGoal | null,
    process: CodexProcess,
  ): CodexGoal | null {
    const result = mergeCodexGoalState(
      session.codexGoal,
      incoming,
      session.codexGoalUpdatedAt,
      true,
    );
    if (!result.accepted) return session.codexGoal ?? null;

    const changed = !sameCodexGoalMutationVersion(session.codexGoal, incoming);
    if (changed) {
      const allocateSequence = (
        process as CodexProcess & {
          recordAuthoritativeGoalStateChange?: () => number;
        }
      ).recordAuthoritativeGoalStateChange;
      session.codexGoalOperationSequence =
        typeof allocateSequence === "function"
          ? allocateSequence.call(process)
          : (session.codexGoalOperationSequence ?? 0) + 1;
    }
    session.codexGoalUpdatedAt = result.updatedAt;
    session.codexGoal = result.goal;
    return result.goal;
  }

  private mergeIntoSession(
    session: SessionInfo,
    incoming: CodexGoal | null,
    operationSequence?: number,
  ): CodexGoal | null {
    if (
      operationSequence !== undefined &&
      session.codexGoalOperationSequence !== undefined &&
      operationSequence < session.codexGoalOperationSequence
    ) {
      return session.codexGoal ?? null;
    }
    if (operationSequence !== undefined) {
      session.codexGoalOperationSequence = operationSequence;
    }
    const result = mergeCodexGoalState(
      session.codexGoal,
      incoming,
      session.codexGoalUpdatedAt,
      true,
    );
    session.codexGoalUpdatedAt = result.updatedAt;
    if (result.accepted) session.codexGoal = result.goal;
    return result.goal;
  }

  private setCapability(session: SessionInfo, supported: boolean): void {
    if (session.codexGoalControlSupported === supported) return;
    session.codexGoalControlSupported = supported;
    this.options.onCapabilityChanged?.(session.id);
  }

  private removeRefresh(
    sessionId: string,
    refresh: Promise<CodexGoal | null>,
  ): void {
    if (this.refreshes.get(sessionId) === refresh) {
      this.refreshes.delete(sessionId);
    }
  }

  private enqueue<T>(sessionId: string, operation: () => Promise<T>): Promise<T> {
    const previous = this.tails.get(sessionId) ?? Promise.resolve();
    const result = previous.then(operation);
    const tail = result.then(
      () => undefined,
      () => undefined,
    );
    this.tails.set(sessionId, tail);
    void tail.then(() => {
      if (this.tails.get(sessionId) === tail) this.tails.delete(sessionId);
    });
    return result;
  }
}
