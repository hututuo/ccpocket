import { createServer } from "node:http";
import {
  mkdirSync,
  mkdtempSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { execFileSync } from "node:child_process";
import { open as openFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { resolvePlatformPath } from "./path-utils.js";

const {
  getSessionHistoryMock,
  getCodexSessionHistoryMock,
  getCodexDesktopToolTimelineMock,
  codexThreadToSessionHistoryMock,
  extractMessageImagesMock,
  getAllRecentSessionsMock,
  getCodexSessionIndexMetadataMock,
  saveCodexSessionProfileMock,
  generateCommitMessageMock,
  gitCommitMock,
} = vi.hoisted(() => ({
  getSessionHistoryMock: vi.fn(),
  getCodexSessionHistoryMock: vi.fn(),
  getCodexDesktopToolTimelineMock: vi.fn(),
  codexThreadToSessionHistoryMock: vi.fn(),
  extractMessageImagesMock: vi.fn(),
  getAllRecentSessionsMock: vi.fn(),
  getCodexSessionIndexMetadataMock: vi.fn(),
  saveCodexSessionProfileMock: vi.fn(),
  generateCommitMessageMock: vi.fn(),
  gitCommitMock: vi.fn(),
}));

vi.mock("./sessions-index.js", () => ({
  getSessionHistory: getSessionHistoryMock,
  getCodexSessionHistory: getCodexSessionHistoryMock,
  getCodexDesktopToolTimeline: getCodexDesktopToolTimelineMock,
  codexThreadToSessionHistory: codexThreadToSessionHistoryMock,
  extractMessageImages: extractMessageImagesMock,
  codexUserTurnUuid: (ordinal: number) => `codex:user-turn:${ordinal}`,
  getAllRecentSessions: getAllRecentSessionsMock,
  getCodexSessionIndexMetadata: getCodexSessionIndexMetadataMock,
  normalizeWorktreePath: (path: string) => {
    const match = path.match(/^(.+)-worktrees[\\/][^\\/]+$/);
    return match?.[1] ?? path;
  },
  saveCodexSessionProfile: saveCodexSessionProfileMock,
  renameClaudeSession: vi.fn().mockResolvedValue(true),
  renameCodexSession: vi.fn().mockResolvedValue(true),
}));

vi.mock("./debug-trace-store.js", () => ({
  DebugTraceStore: class MockDebugTraceStore {
    init() {
      return Promise.resolve();
    }

    getTraceFilePath(sessionId: string) {
      return `/tmp/${sessionId}.jsonl`;
    }

    getBundleFilePath(sessionId: string, generatedAt: string) {
      return `/tmp/${sessionId}-${generatedAt}.json`;
    }

    saveBundle(sessionId: string, generatedAt: string) {
      return this.getBundleFilePath(sessionId, generatedAt);
    }

    saveBundleAtPath() {}

    record() {}
  },
}));

vi.mock("./git-assist.js", () => ({
  generateCommitMessage: generateCommitMessageMock,
}));

vi.mock("./git-operations.js", async () => {
  const actual = await vi.importActual<typeof import("./git-operations.js")>(
    "./git-operations.js",
  );
  return {
    ...actual,
    gitCommit: gitCommitMock,
  };
});

vi.mock("./session.js", async () => {
  const { extractArtifactCandidates } = await vi.importActual<
    typeof import("./artifact-candidates.js")
  >("./artifact-candidates.js");
  const artifactCandidateRootsForSession = (session: any): string[] => [
    ...new Set(
      [
        session.worktreePath ?? session.projectPath,
        session.projectPath,
        ...(session.codexSettings?.additionalWritableRoots ?? []),
      ]
        .map((root: string) => root.trim())
        .filter((root: string) => root.length > 0),
    ),
  ];
  const publicQueuedInput = (item?: any, receipt?: any) =>
    item
      ? {
          itemId: item.itemId,
          text: item.text,
          createdAt: item.createdAt,
          ...(item.updatedAt ? { updatedAt: item.updatedAt } : {}),
          ...(item.clientMessageId
            ? { clientMessageId: item.clientMessageId }
            : {}),
          ...(receipt?.stage ? { deliveryStage: receipt.stage } : {}),
          ...(receipt?.error ? { deliveryError: receipt.error } : {}),
          ...(item.imageCount ? { imageCount: item.imageCount } : {}),
          ...(item.skills?.length ? { skills: item.skills } : {}),
          ...(item.mentions?.length ? { mentions: item.mentions } : {}),
        }
      : undefined;

  class MockSessionManager {
    private sessions = new Map<string, any>();
    private seq = 0;
    private onMessage: (sessionId: string, msg: any) => void;
    private artifactManager: any;
    public codexQueueDrainHooks: any;

    constructor(
      onMessage?: (sessionId: string, msg: any) => void,
      _imageStore?: unknown,
      _galleryStore?: unknown,
      _onGalleryImage?: unknown,
      _worktreeStore?: unknown,
      _onSessionUpdated?: unknown,
      artifactManager?: unknown,
      codexQueueDrainHooks?: unknown,
    ) {
      this.onMessage = onMessage ?? (() => {});
      this.artifactManager = artifactManager;
      this.codexQueueDrainHooks = codexQueueDrainHooks ?? {};
    }

    async enrichArtifactsForSession(
      session: any,
      message: any,
      detachedCandidates?: any[],
    ) {
      const embeddedCandidates =
        message.type === "tool_result"
          ? (message.artifactCandidates ?? [])
          : [];
      let cleanMessage = message;
      if (message.type === "tool_result" && "artifactCandidates" in message) {
        const { artifactCandidates: _, ...clean } = message;
        cleanMessage = clean;
      }

      if (session.provider !== "codex" || !this.artifactManager) {
        return cleanMessage;
      }
      const ownerId = session.claudeSessionId ?? session.process?.sessionId;
      if (!ownerId) return cleanMessage;

      const candidates = [...(detachedCandidates ?? []), ...embeddedCandidates];
      let messageId: string | undefined;
      if (cleanMessage.type === "assistant") {
        messageId = cleanMessage.message.id;
        if (detachedCandidates === undefined) {
          for (const [
            index,
            content,
          ] of cleanMessage.message.content.entries()) {
            if (content.type !== "text") continue;
            candidates.push(
              ...extractArtifactCandidates(content.text, {
                source: "assistant_markdown",
                textContentIndex: index,
                platform: process.platform,
              }),
            );
          }
        }
      } else if (cleanMessage.type === "tool_result") {
        messageId = cleanMessage.toolUseId;
      } else {
        return cleanMessage;
      }
      if (!messageId || candidates.length === 0) return cleanMessage;

      const artifacts = await this.artifactManager.registerCandidates({
        ownerId,
        messageId,
        cwd: session.worktreePath ?? session.projectPath,
        candidateRoots: artifactCandidateRootsForSession(session),
        candidates,
      });
      return artifacts.length > 0
        ? { ...cleanMessage, artifacts }
        : cleanMessage;
    }

    create(
      projectPath: string,
      options?: {
        sessionId?: string;
        continueMode?: boolean;
        permissionMode?: string;
        initialInput?: string;
      },
      pastMessages?: unknown[],
      _worktreeOptions?: unknown,
      provider: "claude" | "codex" = "claude",
      codexOptions?: unknown,
      internal?: {
        auxiliary?: {
          kind: "ephemeral_side_chat";
          parentSessionId: string;
        };
      },
    ): string {
      const id = `s-${++this.seq}`;
      const process = {
        status: "idle",
        isRunning: true,
        isAttachmentReady: true,
        waitUntilAttached: vi.fn(async () => {}),
        activeTurnId: undefined as string | undefined,
        _authorityGeneration: "authority-test-1",
        usesSharedRuntimeTopology: false,
        authoritativeThreadStatus: { type: "idle" },
        hasPendingCoreAction: false,
        sessionId:
          codexOptions &&
          typeof codexOptions === "object" &&
          "threadId" in codexOptions
            ? (codexOptions as { threadId?: string }).threadId
            : options?.sessionId,
        isWaitingForInput: true,
        setPermissionMode: vi.fn(async () => {}),
        approvalPolicy: "never",
        approvalsReviewer: "user",
        collaborationMode: "default",
        setApprovalPolicy: vi.fn(function (this: any, value: string) {
          this.approvalPolicy = value;
        }),
        setApprovalsReviewer: vi.fn(function (this: any, value: string) {
          this.approvalsReviewer = value;
        }),
        updatePermissionSettingsForNextTurn: vi.fn(async function (
          this: any,
          value: Record<string, unknown>,
        ) {
          if (value.approvalPolicy !== undefined) {
            this.approvalPolicy = value.approvalPolicy ?? "on-request";
          }
          if (value.approvalsReviewer !== undefined) {
            this.approvalsReviewer = value.approvalsReviewer ?? "user";
          }
        }),
        updateSharedRuntimeSettingsForNextTurn: vi.fn(async function (
          this: any,
          value: Record<string, unknown>,
        ) {
          if (value.model !== undefined) this.model = value.model;
          if (value.modelReasoningEffort !== undefined) {
            this.modelReasoningEffort = value.modelReasoningEffort;
          }
          if (value.serviceTier !== undefined) {
            this.serviceTier = value.serviceTier;
          }
          if (value.approvalPolicy !== undefined) {
            this.approvalPolicy = value.approvalPolicy ?? "on-request";
          }
          if (value.approvalsReviewer !== undefined) {
            this.approvalsReviewer = value.approvalsReviewer ?? "user";
          }
        }),
        supportsNextTurnPermissionUpdates: true,
        supportsNativePlanMode: true,
        nativePlanModeCapabilityKnown: true,
        interruptCurrentTurn: vi.fn(async () => {}),
        interruptCurrentTurnAndWait: vi.fn(async () => {}),
        setCollaborationMode: vi.fn(function (this: any, value: string) {
          this.collaborationMode = value;
        }),
        setModel: vi.fn(function (
          this: any,
          model: string,
          modelReasoningEffort?: string,
        ) {
          this.model = model;
          this.modelReasoningEffort = modelReasoningEffort;
        }),
        persistRuntimeModelForNextTurn: vi.fn(async () => true),
        setServiceTier: vi.fn(function (this: any, value: string) {
          this.serviceTier = value;
        }),
        persistRuntimeServiceTierForNextTurn: vi.fn(async () => true),
        listThreads: vi.fn(async () => ({ data: [], nextCursor: null })),
        listAvailableModels: vi.fn(async () => []),
        listAvailableModelMetadata: vi.fn(async () => []),
        readProfileConfig: vi.fn(async () => ({ profiles: [] })),
        readThread: vi.fn(async () => ({ id: "thread-read", turns: [] })),
        archiveThread: vi.fn(async () => {}),
        unarchiveThread: vi.fn(async () => {}),
        deleteThread: vi.fn(async () => {}),
        rollbackThread: vi.fn(async () => ({
          id: "thread-rollback",
          turns: [],
        })),
        rollbackThreadById: vi.fn(async () => ({
          id: "thread-forked",
          turns: [],
        })),
        forkThread: vi.fn(async () => ({
          threadId: "thread-forked",
          thread: { id: "thread-forked", turns: [] },
        })),
        getGoal: vi.fn(async () => null),
        getGoalSnapshot: vi.fn(async function (this: any) {
          return { goal: await this.getGoal(), stable: true };
        }),
        lastGoalRpcSequence: undefined,
        recordAuthoritativeGoalStateChange: vi.fn(function (this: any) {
          this.lastGoalRpcSequence = (this.lastGoalRpcSequence ?? 0) + 1;
          return this.lastGoalRpcSequence;
        }),
        setGoal: vi.fn(async (update: Record<string, unknown>) => ({
          threadId: "thread-goal",
          objective: update.objective ?? "Existing goal",
          status: update.status ?? "active",
          tokenBudget: null,
          tokensUsed: 0,
          timeUsedSeconds: 0,
          createdAt: 1,
          updatedAt: 2,
        })),
        clearGoal: vi.fn(async () => true),
        sendInput: vi.fn(() => false),
        sendInputWithImage: vi.fn(),
        sendInputWithImages: vi.fn(() => false),
        steerInputStructured: vi.fn(async () => {}),
        steerTurnStructured: vi.fn(async () => {}),
        steerExternalTurnStructured: vi.fn(async () => {}),
        approve: vi.fn(),
        approveAlways: vi.fn(),
        reject: vi.fn(),
        answer: vi.fn(),
        installToolSuggestion: vi.fn(async () => {}),
        interrupt: vi.fn(),
        getPendingPermission: vi.fn(() => undefined),
        stop: vi.fn(),
      };
      this.sessions.set(id, {
        id,
        projectPath,
        startOptions: options,
        claudeSessionId:
          provider === "codex" &&
          codexOptions &&
          typeof codexOptions === "object" &&
          "threadId" in codexOptions
            ? (codexOptions as { threadId?: string }).threadId
            : options?.sessionId,
        pastMessages,
        codexInitialHistoryPending: false,
        codexOptions,
        codexSettings: codexOptions,
        history: [],
        historyEntries: [],
        historyRevision: 0,
        historyLowWatermark: 1,
        status: "idle",
        provider,
        createdAt: new Date(),
        lastActivityAt: new Date(),
        process,
        auxiliary: internal?.auxiliary,
      });
      return id;
    }

    async replaceCodexSession(
      sessionId: string,
      projectPath: string,
      pastMessages: unknown[],
      worktreeOptions: unknown,
      codexOptions: unknown,
      _replacementReadyTimeoutMs?: number,
      replacementStillValid?: () => boolean,
    ): Promise<string> {
      const current = this.sessions.get(sessionId);
      if (!current || current.provider !== "codex") {
        throw new Error("Cannot replace a missing or non-Codex session");
      }
      if (replacementStillValid?.() === false) {
        throw new Error("Codex replacement invalidated before it became ready");
      }
      const temporaryId = this.create(
        projectPath,
        undefined,
        pastMessages,
        worktreeOptions,
        "codex",
        codexOptions,
      );
      const replacement = this.sessions.get(temporaryId);
      this.sessions.delete(temporaryId);
      replacement.id = sessionId;
      replacement.name = current.name;
      replacement.forkedFromSessionId = current.forkedFromSessionId;
      replacement.forkedFromThreadId = current.forkedFromThreadId;
      replacement.codexQueuedInput = current.codexQueuedInput;
      replacement.codexGoal = current.codexGoal;
      replacement.codexGoalUpdatedAt = current.codexGoalUpdatedAt;
      replacement.codexGoalOperationSequence =
        current.codexGoalOperationSequence;
      replacement.codexGoalControlSupported = current.codexGoalControlSupported;
      this.sessions.set(sessionId, replacement);
      current.process.stop();
      return sessionId;
    }

    get(id: string) {
      return this.sessions.get(id);
    }

    queueCodexInput(id: string, input: any) {
      const session = this.sessions.get(id);
      if (
        !session ||
        session.provider !== "codex" ||
        session.codexQueuedInput
      ) {
        return false;
      }
      session.codexQueuedInput = input;
      return true;
    }

    recordInputBridgeAcceptance(
      id: string,
      clientMessageId: string,
      acceptedSeq: number,
      queued: boolean,
    ) {
      const session = this.sessions.get(id);
      if (!session) return null;
      session.inputDeliveryReceipts ??= new Map();
      const existing = session.inputDeliveryReceipts.get(clientMessageId);
      if (existing && existing.stage !== "bridge_accepted") {
        return existing;
      }
      const receipt = {
        clientMessageId,
        stage: "bridge_accepted",
        acceptedSeq,
        queued,
        occurredAt: new Date().toISOString(),
      };
      session.inputDeliveryReceipts.set(clientMessageId, receipt);
      return receipt;
    }

    getInputDeliveryReceipt(id: string, clientMessageId: string) {
      return (
        this.sessions.get(id)?.inputDeliveryReceipts?.get(clientMessageId) ??
        null
      );
    }

    updateCodexQueuedInput(
      id: string,
      itemId: string,
      text: string,
      options?: { skills?: unknown[]; mentions?: unknown[] },
    ) {
      const session = this.sessions.get(id);
      if (
        !session?.codexQueuedInput ||
        session.codexQueuedInput.itemId !== itemId
      ) {
        return false;
      }
      session.codexQueuedInput = {
        ...session.codexQueuedInput,
        text,
        skills: options?.skills,
        mentions: options?.mentions,
      };
      return true;
    }

    cancelCodexQueuedInput(id: string, itemId: string) {
      const session = this.sessions.get(id);
      if (
        !session?.codexQueuedInput ||
        session.codexQueuedInput.itemId !== itemId
      ) {
        return false;
      }
      session.codexQueuedInput = undefined;
      return true;
    }

    async steerCodexQueuedInput(
      id: string,
      itemId: string,
      expectedTurnId: string,
      isExpectedTurnCurrent?: () => boolean,
      allowExternalSharedRuntimeTurn = false,
    ) {
      const session = this.sessions.get(id);
      if (!session || session.provider !== "codex") {
        return { ok: false, error: "No active Codex session." };
      }
      const queued = session.codexQueuedInput;
      if (!queued || queued.itemId !== itemId) {
        return { ok: false, error: "Queued message not found." };
      }
      if (!expectedTurnId || isExpectedTurnCurrent?.() === false) {
        return {
          ok: false,
          error: "The target turn changed before guidance was applied.",
        };
      }
      try {
        if (isExpectedTurnCurrent?.() === false) {
          return {
            ok: false,
            error: "The target turn changed before guidance was applied.",
          };
        }
        const options = {
          images: queued.images,
          skills: queued.skills,
          mentions: queued.mentions,
        };
        if (allowExternalSharedRuntimeTurn) {
          await session.process.steerExternalTurnStructured(
            expectedTurnId,
            queued.text,
            options,
          );
        } else {
          await session.process.steerTurnStructured(
            expectedTurnId,
            queued.text,
            options,
          );
        }
      } catch (err) {
        return {
          ok: false,
          error: err instanceof Error ? err.message : String(err),
        };
      }
      session.codexQueuedInput = undefined;
      const userMsg = {
        type: "user_input",
        text: queued.text,
        timestamp: new Date().toISOString(),
        ...(queued.userMessageUuid
          ? { userMessageUuid: queued.userMessageUuid }
          : {}),
        ...(queued.imageCount ? { imageCount: queued.imageCount } : {}),
        ...(queued.imageRefs ? { images: queued.imageRefs } : {}),
      };
      this.appendHistory(id, userMsg);
      this.onMessage(id, userMsg);
      return { ok: true };
    }

    drainCodexQueuedInputIfReady(id: string) {
      const session = this.sessions.get(id);
      if (!session?.codexQueuedInput || !session.process.isWaitingForInput) {
        return false;
      }
      if (this.codexQueueDrainHooks.canDrain?.(session) === false) {
        this.codexQueueDrainHooks.onBlocked?.(session);
        return false;
      }
      session.process.sendInputStructured?.(session.codexQueuedInput.text, {
        images: session.codexQueuedInput.images,
        skills: session.codexQueuedInput.skills,
        mentions: session.codexQueuedInput.mentions,
        ...(session.codexQueuedInput.clientMessageId
          ? { clientMessageId: session.codexQueuedInput.clientMessageId }
          : {}),
      });
      session.codexQueuedInput = undefined;
      return true;
    }

    appendHistory(id: string, msg: any) {
      const session = this.sessions.get(id);
      if (!session) return undefined;
      msg.receivedAt = new Date().toISOString();
      const entry = {
        seq: session.historyRevision + 1,
        message: msg,
      };
      msg.historySeq = entry.seq;
      session.historyRevision = entry.seq;
      session.history.push(msg);
      session.historyEntries.push(entry);
      if (session.provider === "codex" && msg.type === "user_input") {
        session.codexLatestUserInput = msg;
      }
      if (session.history.length > 100) {
        session.history.shift();
        session.historyEntries.shift();
      }
      session.historyLowWatermark =
        session.historyEntries[0]?.seq ?? session.historyRevision + 1;
      return entry;
    }

    getHistorySince(id: string, sinceSeq: number) {
      const session = this.sessions.get(id);
      if (!session) return undefined;
      const entries = session.historyEntries;
      if (entries.length === 0) {
        return {
          kind: "delta",
          fromSeq: session.historyRevision + 1,
          toSeq: session.historyRevision,
          entries: [],
        };
      }
      const firstSeq = entries[0].seq;
      if (sinceSeq < firstSeq - 1) {
        return {
          kind: "snapshot",
          fromSeq: firstSeq,
          toSeq: session.historyRevision,
          entries,
          reason: "compacted",
        };
      }
      const deltaEntries = entries.filter((entry: any) => entry.seq > sinceSeq);
      return {
        kind: "delta",
        fromSeq: deltaEntries[0]?.seq ?? session.historyRevision + 1,
        toSeq: session.historyRevision,
        entries: deltaEntries,
      };
    }

    list() {
      return Array.from(this.sessions.values())
        .filter((session) => session.auxiliary == null)
        .map((s) => ({
          id: s.id,
          provider: s.provider,
          projectPath: s.projectPath,
          claudeSessionId: s.claudeSessionId,
          forkedFromSessionId: s.forkedFromSessionId,
          forkedFromThreadId: s.forkedFromThreadId,
          status: s.status,
          createdAt: "",
          lastActivityAt: "",
          gitBranch: "",
          lastMessage: "",
          codexSettings: s.codexSettings,
          codexPermissionApplyStrategySupported:
            s.process.supportsNextTurnPermissionUpdates ?? false,
          ...(s.process.nativePlanModeCapabilityKnown
            ? {
                codexNativePlanModeSupported:
                  s.process.supportsNativePlanMode ?? false,
              }
            : {}),
          ...(s.codexGoalControlSupported !== undefined
            ? { codexGoalControlSupported: s.codexGoalControlSupported }
            : {}),
          queuedInput: publicQueuedInput(
            s.codexQueuedInput,
            s.codexQueuedInput?.clientMessageId
              ? s.inputDeliveryReceipts?.get(s.codexQueuedInput.clientMessageId)
              : undefined,
          ),
        }));
    }

    listEphemeralSideChats() {
      return Array.from(this.sessions.values()).filter(
        (session) => session.auxiliary?.kind === "ephemeral_side_chat",
      );
    }

    getCachedCommands() {
      return undefined;
    }

    destroy(id: string) {
      const session = this.sessions.get(id);
      if (!session) return false;
      for (const child of this.listEphemeralSideChats()) {
        if (child.auxiliary.parentSessionId === id) {
          this.destroy(child.id);
        }
      }
      this.sessions.delete(id);
      session.process.stop();
      return true;
    }

    destroyAll() {}

    async rewindFiles(_id: string, _targetUuid: string, _dryRun?: boolean) {
      return {
        canRewind: true,
        filesChanged: ["test.ts"],
        insertions: 1,
        deletions: 0,
      };
    }

    rewindConversation(
      id: string,
      _targetUuid: string,
      onReady: (newSessionId: string) => void,
    ) {
      const session = this.sessions.get(id);
      if (!session) throw new Error(`Session ${id} not found`);
      this.sessions.delete(id);
      const newId = `s-${++this.seq}`;
      const process = {
        isWaitingForInput: true,
        setPermissionMode: vi.fn(async () => {}),
        approvalPolicy: "never",
        approvalsReviewer: "user",
        collaborationMode: "default",
        setApprovalPolicy: vi.fn(function (this: any, value: string) {
          this.approvalPolicy = value;
        }),
        setApprovalsReviewer: vi.fn(function (this: any, value: string) {
          this.approvalsReviewer = value;
        }),
        updatePermissionSettingsForNextTurn: vi.fn(async function (
          this: any,
          value: Record<string, unknown>,
        ) {
          if (value.approvalPolicy !== undefined) {
            this.approvalPolicy = value.approvalPolicy ?? "on-request";
          }
          if (value.approvalsReviewer !== undefined) {
            this.approvalsReviewer = value.approvalsReviewer ?? "user";
          }
        }),
        supportsNextTurnPermissionUpdates: true,
        supportsNativePlanMode: true,
        nativePlanModeCapabilityKnown: true,
        interruptCurrentTurn: vi.fn(async () => {}),
        interruptCurrentTurnAndWait: vi.fn(async () => {}),
        setCollaborationMode: vi.fn(function (this: any, value: string) {
          this.collaborationMode = value;
        }),
        persistRuntimeModelForNextTurn: vi.fn(async () => true),
        persistRuntimeServiceTierForNextTurn: vi.fn(async () => true),
        listThreads: vi.fn(async () => ({ data: [], nextCursor: null })),
        sendInput: vi.fn(() => false),
        sendInputWithImage: vi.fn(),
        sendInputWithImages: vi.fn(() => false),
        approve: vi.fn(),
        approveAlways: vi.fn(),
        reject: vi.fn(),
        answer: vi.fn(),
        installToolSuggestion: vi.fn(async () => {}),
        interrupt: vi.fn(),
        getPendingPermission: vi.fn(() => undefined),
      };
      this.sessions.set(newId, {
        id: newId,
        projectPath: session.projectPath,
        startOptions: session.startOptions,
        claudeSessionId: session.claudeSessionId,
        history: [],
        historyEntries: [],
        historyRevision: 0,
        historyLowWatermark: 1,
        status: "idle",
        provider: session.provider,
        createdAt: new Date(),
        lastActivityAt: new Date(),
        process,
      });
      onReady(newId);
    }
  }

  return {
    MAX_HISTORY_PER_SESSION: 100,
    artifactCandidateRootsForSession,
    publicQueuedInput,
    SessionManager: MockSessionManager,
  };
});

import { BridgeWebSocketServer, isPrivateOrigin } from "./websocket.js";
import {
  CodexProcess,
  CodexRpcError,
  CodexSharedRuntimeTurnOwnershipError,
} from "./codex-process.js";
import { ArtifactResolveError } from "./artifact-manager.js";
import { GalleryStore } from "./gallery-store.js";
import { WebSocket as WsClient } from "ws";
import type {
  CodexActionBrokerRuntime,
  CodexActionBrokerRuntimeHealth,
  CodexActionBrokerRuntimeUpdate,
} from "./codex-action-broker-runtime.js";

function writableCodexActionBrokerRuntime(): CodexActionBrokerRuntime {
  return {
    health: {
      ready: true,
      controlReady: true,
      degraded: false,
      writerLeaseHeld: true,
      authorityGeneration: "cab:test:1",
    },
    listRequests: vi.fn(() => []),
    currentRequestForThread: vi.fn(),
    respond: vi.fn(async () => ({ outcome: "submitted" as const })),
    subscribe: vi.fn(() => () => undefined),
  } as unknown as CodexActionBrokerRuntime;
}

describe("BridgeWebSocketServer resume/get_history flow", () => {
  const OPEN_STATE = 1;
  let httpServer: ReturnType<typeof createServer>;
  let originalFetch: typeof globalThis.fetch;

  beforeEach(() => {
    originalFetch = globalThis.fetch;
    httpServer = createServer();
    getSessionHistoryMock.mockReset();
    getCodexSessionHistoryMock.mockReset();
    getCodexDesktopToolTimelineMock.mockReset();
    codexThreadToSessionHistoryMock.mockReset();
    extractMessageImagesMock.mockReset();
    getAllRecentSessionsMock.mockReset();
    getCodexSessionIndexMetadataMock.mockReset();
    saveCodexSessionProfileMock.mockReset();
    generateCommitMessageMock.mockReset();
    gitCommitMock.mockReset();
    getAllRecentSessionsMock.mockResolvedValue({
      sessions: [],
      hasMore: false,
    });
    getCodexSessionIndexMetadataMock.mockResolvedValue(new Map());
    getCodexSessionHistoryMock.mockResolvedValue([]);
    getCodexDesktopToolTimelineMock.mockResolvedValue({
      events: [],
      callIds: new Set(),
    });
    codexThreadToSessionHistoryMock.mockReturnValue([]);
    extractMessageImagesMock.mockResolvedValue([]);
    saveCodexSessionProfileMock.mockResolvedValue(undefined);
  });

  afterEach(() => {
    globalThis.fetch = originalFetch;
    vi.unstubAllEnvs();
    vi.useRealTimers();
    httpServer.close();
  });

  it("advertises, gates, routes, disconnects, and closes the optional v2 file-transfer module", async () => {
    const fileTransfer = {
      connect: vi.fn(),
      disconnect: vi.fn(),
      handleClientMessage: vi
        .fn()
        .mockRejectedValueOnce(new Error("file transfer cleanup failed")),
      close: vi.fn(async () => {}),
    };
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      fileTransfer: fileTransfer as any,
      fileMutationAuthorizer: {} as any,
    });
    const listeners = new Map<string, (...args: any[]) => void>();
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
      on: vi.fn((event: string, listener: (...args: any[]) => void) => {
        listeners.set(event, listener);
      }),
    } as any;

    (bridge as any).handleConnection(ws, {
      headers: {
        host: "100.104.72.123:8765",
        "x-forwarded-proto": "http",
      },
      socket: {},
    });
    expect(fileTransfer.connect).toHaveBeenCalledOnce();
    const initialMessages = ws.send.mock.calls.map((call: unknown[]) =>
      JSON.parse(call[0] as string),
    );
    expect(initialMessages).toContainEqual(
      expect.objectContaining({
        type: "session_list",
        bridgeCapabilities: expect.arrayContaining([
          "file_transfer_v2",
          "codex_desktop_continuity_v1",
          "codex_resume_preserves_settings_v1",
          "ephemeral_side_chat_v1",
          "turn_aware_history_window_v1",
          "history_page_v1",
          "session_request_correlation_v1",
          "prompt_history_request_correlation_v1",
          "file_list_request_correlation_v1",
          "git_diff_request_correlation_v1",
          "git_project_result_correlation_v1",
          "durable_session_insights_v1",
          "bridge_application_readiness_v1",
          "codex_runtime_detach_v1",
        ]),
      }),
    );
    const initialSessionList = initialMessages.find(
      (message: any) => message.type === "session_list",
    );
    expect(initialSessionList.bridgeCapabilities).not.toContain(
      "file_mutation_auth_v1",
    );
    expect(initialSessionList.bridgeCapabilities).not.toContain(
      "file_transfer_upload_auth_v1",
    );
    expect(initialSessionList.bridgeCapabilities).not.toContain(
      "scoped_context_usage_v1",
    );

    const binding = fileTransfer.connect.mock.calls[0][1];
    expect(binding.httpBaseUrl).toBe("http://100.104.72.123:8765");
    expect(binding.supports("file_transfer_offer_v2")).toBe(false);
    expect(
      binding.send({
        type: "file_transfer_offer_v2",
        transferId: "download_1234567",
        filename: "x.txt",
        mimeType: "text/plain",
        sizeBytes: 1,
        downloadUrl:
          "http://100.64.0.1:8765/api/file-transfers/downloads/download_1234567",
        downloadToken: "d".repeat(43),
        etag: `"${"e".repeat(32)}"`,
        expiresAt: "2030-01-01T00:00:00.000Z",
      }),
    ).toBe(false);

    listeners.get("message")?.(
      Buffer.from(
        JSON.stringify({
          type: "client_capabilities",
          supportedServerMessages: [
            "file_transfer_offer_v2",
            "file_transfer_upload_ready_v2",
            "file_transfer_upload_result_v2",
          ],
        }),
      ),
    );
    await vi.waitFor(() =>
      expect(binding.supports("file_transfer_offer_v2")).toBe(true),
    );
    expect(
      binding.send({
        type: "file_transfer_offer_v2",
        transferId: "download_1234567",
        filename: "x.txt",
        mimeType: "text/plain",
        sizeBytes: 1,
        downloadUrl:
          "http://100.64.0.1:8765/api/file-transfers/downloads/download_1234567",
        downloadToken: "d".repeat(43),
        etag: `"${"e".repeat(32)}"`,
        expiresAt: "2030-01-01T00:00:00.000Z",
      }),
    ).toBe(true);
    expect(JSON.parse(ws.send.mock.calls.at(-1)[0])).toMatchObject({
      type: "file_transfer_offer_v2",
      transferId: "download_1234567",
    });

    const uploadPrepare = {
      type: "file_transfer_upload_prepare_v2",
      requestId: "request-1",
      transferId: "upload_123456789",
      resumeToken: "r".repeat(43),
      filename: "phone.bin",
      sizeBytes: 1,
    };
    const consoleError = vi
      .spyOn(console, "error")
      .mockImplementation(() => {});
    listeners.get("message")?.(Buffer.from(JSON.stringify(uploadPrepare)));
    await vi.waitFor(() => {
      expect(fileTransfer.handleClientMessage).toHaveBeenCalledWith(
        ws,
        uploadPrepare,
      );
    });
    await vi.waitFor(() => {
      expect(consoleError).toHaveBeenCalledWith(
        "[ws] Failed to handle file_transfer_upload_prepare_v2:",
        "file transfer cleanup failed",
      );
    });
    const retryPrepare = { ...uploadPrepare, requestId: "request-2" };
    listeners.get("message")?.(Buffer.from(JSON.stringify(retryPrepare)));
    await vi.waitFor(() => {
      expect(fileTransfer.handleClientMessage).toHaveBeenCalledWith(
        ws,
        retryPrepare,
      );
    });
    consoleError.mockRestore();
    listeners.get("close")?.();
    expect(fileTransfer.disconnect).toHaveBeenCalledWith(ws);
    await bridge.close();
    expect(fileTransfer.close).toHaveBeenCalledOnce();
  });

  it("does not advertise JSONL desktop continuity in daemon mode", async () => {
    vi.stubEnv("BRIDGE_CODEX_APP_SERVER_MODE", "daemon");
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    (bridge as any).bridgeInstanceId = "bridge-daemon-test";
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
      on: vi.fn(),
    } as any;

    (bridge as any).handleConnection(ws, {
      headers: { host: "127.0.0.1:8765" },
      socket: {},
    });
    const sessionList = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.type === "session_list");
    expect(sessionList.bridgeCapabilities).not.toContain(
      "codex_desktop_continuity_v1",
    );
    expect(sessionList.bridgeCapabilities).toEqual(
      expect.arrayContaining([
        "bridge_application_readiness_v1",
        "codex_runtime_detach_v1",
        "scoped_context_usage_v1",
      ]),
    );

    await bridge.close();
  });

  it("keeps the Action Broker capability advertised for standby, leader, and not-ready daemon states", async () => {
    vi.stubEnv("BRIDGE_CODEX_APP_SERVER_MODE", "daemon");
    const runtimeListeners: Array<
      (update: CodexActionBrokerRuntimeUpdate) => void
    > = [];
    const health: CodexActionBrokerRuntimeHealth = {
      ready: false,
      controlReady: true,
      degraded: false,
      writerLeaseHeld: false,
      degradedReason: "writer_lease_unavailable" as const,
    };
    const request = {
      opaqueRequestId: "opaque-action",
      codexSourceId: "source-action",
      threadId: "thread-action",
      turnId: "turn-action",
      kind: "command_approval" as const,
      state: "pending" as const,
      observedAt: "2026-08-01T00:00:00.000Z",
      expiresAt: "2026-08-02T00:00:00.000Z",
      updatedAt: "2026-08-01T00:00:00.000Z",
      authorityGeneration: "cab:1:1",
      live: true,
      toolName: "Bash",
      input: { command: "pwd" },
      allowedActions: ["approve", "reject"] as const,
    };
    const respond = vi.fn(async () =>
      health.ready
        ? ({ outcome: "submitted", request } as const)
        : ({ outcome: "unavailable" } as const),
    );
    const actionRuntime = {
      get health() {
        return health;
      },
      listRequests: vi.fn(() => [request]),
      currentRequestForThread: vi.fn(() => request),
      respond,
      subscribe: vi.fn(
        (next: (update: CodexActionBrokerRuntimeUpdate) => void) => {
          runtimeListeners.push(next);
          return () => {
            const index = runtimeListeners.indexOf(next);
            if (index >= 0) runtimeListeners.splice(index, 1);
          };
        },
      ),
    } as unknown as CodexActionBrokerRuntime;
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      codexActionBrokerRuntime: actionRuntime,
    });
    const listeners = new Map<string, (...args: any[]) => void>();
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
      on: vi.fn((event: string, callback: (...args: any[]) => void) => {
        listeners.set(event, callback);
      }),
    } as any;
    (bridge as any).handleConnection(ws, {
      headers: { host: "127.0.0.1:8765" },
      socket: {},
    });
    const messages = () =>
      ws.send.mock.calls.map((call: unknown[]) =>
        JSON.parse(call[0] as string),
      );
    expect(
      messages().find((message: any) => message.type === "session_list")
        .bridgeCapabilities,
    ).toContain("codex_action_broker_v1");

    listeners.get("message")?.(
      Buffer.from(
        JSON.stringify({
          type: "client_capabilities",
          supportedServerMessages: ["codex_action_broker_v1"],
        }),
      ),
    );
    await vi.waitFor(() =>
      expect(
        messages().find(
          (message: any) =>
            message.type === "codex_action_broker_v1" &&
            message.event === "snapshot",
        ),
      ).toMatchObject({ requests: [] }),
    );
    expect(actionRuntime.subscribe).toHaveBeenCalledTimes(4);
    expect(runtimeListeners).toHaveLength(4);

    const respondFromPhone = (requestId: string): void => {
      listeners.get("message")?.(
        Buffer.from(
          JSON.stringify({
            type: "respond_codex_action",
            requestId,
            opaqueRequestId: "opaque-action",
            codexSourceId: "source-action",
            threadId: "thread-action",
            turnId: "turn-action",
            authorityGeneration: "cab:1:1",
            claimantId: "phone-a",
            operationId: `operation-${requestId}`,
            action: "approve",
          }),
        ),
      );
    };

    respondFromPhone("wire-standby");
    await vi.waitFor(() => expect(respond).toHaveBeenCalledTimes(1));
    expect(messages()).toContainEqual(
      expect.objectContaining({
        event: "response",
        requestId: "wire-standby",
        outcome: "unavailable",
      }),
    );

    Object.assign(health, {
      ready: true,
      writerLeaseHeld: true,
      authorityGeneration: "cab:1:1",
    });
    delete (health as { degradedReason?: string }).degradedReason;
    for (const runtimeListener of [...runtimeListeners]) {
      runtimeListener({ kind: "health", health });
    }
    await vi.waitFor(() =>
      expect(messages()).toContainEqual(
        expect.objectContaining({
          event: "health",
          health: expect.objectContaining({
            ready: true,
            writerLeaseHeld: true,
          }),
        }),
      ),
    );
    (bridge as any).sendSessionList(ws);
    expect(
      messages()
        .filter((message: any) => message.type === "session_list")
        .at(-1).bridgeCapabilities,
    ).toContain("codex_action_broker_v1");

    respondFromPhone("wire-leader");
    await vi.waitFor(() => expect(respond).toHaveBeenCalledTimes(2));
    expect(messages()).toContainEqual(
      expect.objectContaining({
        type: "codex_action_broker_v1",
        event: "response",
        requestId: "wire-leader",
        outcome: "submitted",
      }),
    );

    Object.assign(health, {
      ready: false,
      controlReady: false,
      writerLeaseHeld: false,
      degradedReason: "generation_unavailable" as const,
    });
    delete (health as { authorityGeneration?: string }).authorityGeneration;
    for (const runtimeListener of [...runtimeListeners]) {
      runtimeListener({ kind: "health", health });
    }
    await vi.waitFor(() =>
      expect(messages()).toContainEqual(
        expect.objectContaining({
          event: "health",
          health: expect.objectContaining({
            ready: false,
            writerLeaseHeld: false,
          }),
        }),
      ),
    );
    (bridge as any).sendSessionList(ws);
    expect(
      messages()
        .filter((message: any) => message.type === "session_list")
        .at(-1).bridgeCapabilities,
    ).toContain("codex_action_broker_v1");
    respondFromPhone("wire-not-ready");
    await vi.waitFor(() => expect(respond).toHaveBeenCalledTimes(3));
    expect(messages()).toContainEqual(
      expect.objectContaining({
        event: "response",
        requestId: "wire-not-ready",
        outcome: "unavailable",
      }),
    );
    await bridge.close();
  });

  it("projects shared Codex broker actions to v2 notification clients only", async () => {
    vi.stubEnv("BRIDGE_CODEX_APP_SERVER_MODE", "daemon");
    const subscribers: Array<(update: CodexActionBrokerRuntimeUpdate) => void> =
      [];
    const request = (
      opaqueRequestId: string,
      threadId: string,
      toolName: string,
    ) => ({
      opaqueRequestId,
      codexSourceId: "source-1",
      threadId,
      turnId: `turn-${threadId}`,
      kind: "command_approval" as const,
      state: "pending" as const,
      observedAt: "2026-08-01T00:00:00.000Z",
      expiresAt: "2026-08-01T00:10:00.000Z",
      updatedAt: "2026-08-01T00:00:01.000Z",
      authorityGeneration: "cab:1:1",
      live: true,
      toolName,
      input: { command: `secret-${threadId}` },
      allowedActions: ["approve", "reject"] as ("approve" | "reject")[],
    });
    const desktopRequest = request(
      "opaque-desktop",
      "thread-desktop",
      "DesktopSecretTool",
    );
    const bridgeRequest = request(
      "opaque-bridge",
      "thread-bridge",
      "BridgeSecretTool",
    );
    const actionRuntime = {
      health: {
        ready: true,
        controlReady: true,
        degraded: false,
        writerLeaseHeld: true,
        authorityGeneration: "cab:1:1",
      },
      listRequests: vi.fn(() => [desktopRequest, bridgeRequest]),
      currentRequestForThread: vi.fn(),
      respond: vi.fn(),
      subscribe: vi.fn(
        (listener: (update: CodexActionBrokerRuntimeUpdate) => void) => {
          subscribers.push(listener);
          return () => {
            const index = subscribers.indexOf(listener);
            if (index >= 0) subscribers.splice(index, 1);
          };
        },
      ),
    } as unknown as CodexActionBrokerRuntime;
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      codexActionBrokerRuntime: actionRuntime,
    });
    (bridge as any).bridgeInstanceId = "bridge-1";
    const capable = { readyState: OPEN_STATE, send: vi.fn() } as any;
    const legacy = { readyState: OPEN_STATE, send: vi.fn() } as any;
    (bridge as any).wss.clients.add(capable);
    (bridge as any).wss.clients.add(legacy);
    const backgroundCapabilities = [
      "client_delivery_mode_state_v1",
      "background_notification_v1",
      "background_activity_state_v1",
    ];
    await (bridge as any).handleClientMessage(
      {
        type: "client_capabilities",
        supportedServerMessages: [
          ...backgroundCapabilities,
          "codex_action_broker_v1",
        ],
      },
      capable,
    );
    await (bridge as any).handleClientMessage(
      {
        type: "client_capabilities",
        supportedServerMessages: backgroundCapabilities,
      },
      legacy,
    );
    capable.send.mockClear();
    legacy.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "set_client_delivery_mode",
        mode: "notifications_only",
        requestId: "mode-capable",
        privacyMode: true,
      },
      capable,
    );
    await (bridge as any).handleClientMessage(
      {
        type: "set_client_delivery_mode",
        mode: "notifications_only",
        requestId: "mode-legacy",
        privacyMode: true,
      },
      legacy,
    );

    const notifications = capable.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .filter((message: any) => message.type === "background_notification_v1");
    expect(notifications).toHaveLength(2);
    expect(notifications).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          sessionId: "thread-desktop",
          data: expect.objectContaining({
            actionPayloadVersion: "2",
            opaqueRequestId: "opaque-desktop",
            codexSourceId: "source-1",
            threadId: "thread-desktop",
            turnId: "turn-thread-desktop",
            authorityGeneration: "cab:1:1",
            allowedActions: "approve,reject",
          }),
        }),
        expect.objectContaining({
          sessionId: "thread-bridge",
          data: expect.objectContaining({
            opaqueRequestId: "opaque-bridge",
          }),
        }),
      ]),
    );
    expect(JSON.stringify(notifications)).not.toContain("SecretTool");
    expect(JSON.stringify(notifications)).not.toContain("secret-thread");
    expect(JSON.stringify(notifications)).not.toContain("permissionId");
    expect(
      legacy.send.mock.calls
        .map((call: unknown[]) => JSON.parse(call[0] as string))
        .filter(
          (message: any) => message.type === "background_notification_v1",
        ),
    ).toHaveLength(0);

    await bridge.close();
  });

  it("keeps standby daemon writes read-only and rejects legacy approval frames even on the leader", async () => {
    vi.stubEnv("BRIDGE_CODEX_APP_SERVER_MODE", "daemon");
    vi.stubEnv("BRIDGE_CODEX_SHARED_PILOT", "1");
    vi.stubEnv(
      "BRIDGE_CODEX_SOURCE_ID",
      "codex-source-11111111111111111111111111111111",
    );
    vi.stubEnv("BRIDGE_CODEX_SHARED_PILOT_ALLOW_THREAD_START", "1");
    vi.stubEnv("BRIDGE_CODEX_SHARED_PILOT_ALLOW_TURN_START", "1");
    const health: CodexActionBrokerRuntimeHealth = {
      ready: false,
      controlReady: true,
      degraded: false,
      writerLeaseHeld: false,
      degradedReason: "writer_lease_unavailable",
    };
    const actionRuntime = {
      get health() {
        return health;
      },
      listRequests: vi.fn(() => []),
      currentRequestForThread: vi.fn(),
      respond: vi.fn(async () => ({ outcome: "unavailable" as const })),
      subscribe: vi.fn(() => () => undefined),
    } as unknown as CodexActionBrokerRuntime;
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      allowedDirs: ["/tmp"],
      codexActionBrokerRuntime: actionRuntime,
    });
    const listeners = new Map<string, (...args: any[]) => void>();
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
      on: vi.fn((event: string, callback: (...args: any[]) => void) => {
        listeners.set(event, callback);
      }),
    } as any;
    (bridge as any).handleConnection(ws, {
      headers: { host: "127.0.0.1:8765" },
      socket: {},
    });
    const sendClient = (message: Record<string, unknown>): void => {
      listeners.get("message")?.(Buffer.from(JSON.stringify(message)));
    };
    const messages = () =>
      ws.send.mock.calls.map((call: unknown[]) =>
        JSON.parse(call[0] as string),
      );

    sendClient({
      type: "start",
      provider: "codex",
      projectPath: "/tmp/shared-standby",
      startRequestId: "standby-start",
    });
    await vi.waitFor(() =>
      expect(messages()).toContainEqual(
        expect.objectContaining({
          type: "error",
          errorCode: "codex_shared_runtime_writer_unavailable",
        }),
      ),
    );
    expect(messages()).toContainEqual(
      expect.objectContaining({
        type: "system",
        subtype: "session_start_failed",
        startRequestId: "standby-start",
      }),
    );

    sendClient({
      type: "resume_session",
      provider: "codex",
      sessionId: "thread-standby",
      projectPath: "/tmp/shared-standby",
      resumeRequestId: "standby-resume",
    });
    await vi.waitFor(() =>
      expect(messages()).toContainEqual(
        expect.objectContaining({
          type: "system",
          subtype: "session_resume_failed",
          sourceSessionId: "thread-standby",
          resumeRequestId: "standby-resume",
        }),
      ),
    );

    Object.assign(health, {
      ready: true,
      writerLeaseHeld: true,
      authorityGeneration: "cab:1:1",
    });
    delete (health as { degradedReason?: string }).degradedReason;
    sendClient({
      type: "start",
      provider: "codex",
      projectPath: "/tmp",
      startRequestId: "leader-start",
    });
    await vi.waitFor(() =>
      expect(
        messages().find(
          (message: any) =>
            message.type === "system" &&
            message.subtype === "session_created" &&
            message.startRequestId === "leader-start",
        ),
      ).toBeDefined(),
    );
    const created = messages().find(
      (message: any) =>
        message.type === "system" &&
        message.subtype === "session_created" &&
        message.startRequestId === "leader-start",
    );
    const session = (bridge as any).sessionManager.get(created.sessionId);

    sendClient({
      type: "approve",
      sessionId: created.sessionId,
      id: "legacy-approval",
    });
    await vi.waitFor(() =>
      expect(messages()).toContainEqual(
        expect.objectContaining({
          type: "error",
          errorCode: "codex_action_broker_required",
          sessionId: created.sessionId,
        }),
      ),
    );
    expect(session.process.approve).not.toHaveBeenCalled();

    Object.assign(health, {
      ready: false,
      writerLeaseHeld: false,
      degradedReason: "writer_lease_unavailable",
    });
    delete (health as { authorityGeneration?: string }).authorityGeneration;
    sendClient({
      type: "input",
      sessionId: created.sessionId,
      clientMessageId: "standby-input",
      text: "must not start a turn",
    });
    await vi.waitFor(() =>
      expect(messages()).toContainEqual(
        expect.objectContaining({
          type: "input_rejected",
          sessionId: created.sessionId,
          clientMessageId: "standby-input",
        }),
      ),
    );
    expect(session.process.sendInput).not.toHaveBeenCalled();

    for (const message of [
      {
        type: "set_goal",
        sessionId: created.sessionId,
        objective: "must not mutate",
        goalChangeId: "standby-goal",
      },
      { type: "interrupt", sessionId: created.sessionId },
      {
        type: "fork",
        sessionId: created.sessionId,
        targetUuid: "codex:user-turn:latest",
      },
    ]) {
      sendClient(message);
    }
    await vi.waitFor(() =>
      expect(
        messages().filter(
          (message: any) =>
            message.errorCode === "codex_shared_runtime_writer_unavailable",
        ).length,
      ).toBeGreaterThanOrEqual(4),
    );
    expect(session.process.setGoal).not.toHaveBeenCalled();
    expect(session.process.interruptCurrentTurn).not.toHaveBeenCalled();
    expect(session.process.forkThread).not.toHaveBeenCalled();

    await bridge.close();
  });

  it("does not advertise the Action Broker in private topology even if a runtime is injected", async () => {
    const actionRuntime = {
      health: {
        ready: true,
        controlReady: true,
        degraded: false,
        writerLeaseHeld: true,
        authorityGeneration: "cab:1:1",
      },
      listRequests: vi.fn(() => []),
      currentRequestForThread: vi.fn(),
      respond: vi.fn(async () => ({ outcome: "submitted" })),
      subscribe: vi.fn(() => () => undefined),
    } as unknown as CodexActionBrokerRuntime;
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      codexActionBrokerRuntime: actionRuntime,
    });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
      on: vi.fn(),
    } as any;
    (bridge as any).handleConnection(ws, {
      headers: { host: "127.0.0.1:8765" },
      socket: {},
    });
    const sessionList = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.type === "session_list");
    expect(sessionList.bridgeCapabilities).not.toContain(
      "codex_action_broker_v1",
    );
    expect(actionRuntime.subscribe).not.toHaveBeenCalled();
    await bridge.close();
  });

  it("advertises upload step-up only with both transfer and authorization surfaces", async () => {
    const fileTransfer = {
      connect: vi.fn(),
      disconnect: vi.fn(),
      handleClientMessage: vi.fn(async () => {}),
      close: vi.fn(async () => {}),
    };
    const fileBrowser = {
      connect: vi.fn(),
      disconnect: vi.fn(),
      handleClientMessage: vi.fn(async () => {}),
      close: vi.fn(async () => {}),
    };
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      fileTransfer: fileTransfer as any,
      fileBrowser: fileBrowser as any,
      fileMutationAuthorizer: {} as any,
    });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
      on: vi.fn(),
    } as any;

    (bridge as any).handleConnection(ws, {
      headers: { host: "100.104.72.123:8765" },
      socket: {},
    });
    const sessionList = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.type === "session_list");
    expect(sessionList.bridgeCapabilities).toEqual(
      expect.arrayContaining([
        "file_browser_v1",
        "file_browser_project_preview_v1",
        "file_transfer_v2",
        "file_mutation_auth_v1",
        "file_transfer_upload_auth_v1",
      ]),
    );

    await bridge.close();
  });

  it("preserves the phone-side loopback HTTP origin used by an SSH tunnel", async () => {
    const fileTransfer = {
      connect: vi.fn(),
      disconnect: vi.fn(),
      handleClientMessage: vi.fn(async () => {}),
      close: vi.fn(async () => {}),
    };
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      fileTransfer: fileTransfer as any,
    });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
      on: vi.fn(),
    } as any;
    (bridge as any).handleConnection(ws, {
      headers: { host: "127.0.0.1:18765" },
      socket: {},
    });
    expect(fileTransfer.connect.mock.calls[0][1].httpBaseUrl).toBe(
      "http://127.0.0.1:18765",
    );
    await bridge.close();
  });

  it("does not persist Codex archive bookkeeping when the official RPC fails", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    const reservation = {
      sessionId: "thread-archive",
      provider: "codex",
      identityKey: "codex\0thread-archive",
      token: Symbol("archive"),
      alreadyArchived: false,
    };
    const reserveArchiveCapacity = vi.fn(async () => reservation);
    const commitReservedArchive = vi.fn(async () => {});
    const releaseArchiveCapacity = vi.fn(async () => {});
    const archiveThread = vi.fn(async () => {
      throw new Error("official archive rejected");
    });
    const stop = vi.fn();
    (bridge as any).archiveStoreReady = Promise.resolve();
    (bridge as any).archiveStoreInitializationError = null;
    (bridge as any).archiveStore = {
      reserveArchiveCapacity,
      commitReservedArchive,
      releaseArchiveCapacity,
      list: vi.fn(() => []),
      archivedIds: vi.fn(() => new Set()),
      archivedKeys: vi.fn(() => new Set()),
    };
    const createStandalone = vi
      .spyOn(bridge as any, "createStandaloneCodexProcess")
      .mockResolvedValue({ archiveThread, stop });

    (bridge as any).handleClientMessage(
      {
        type: "archive_session",
        requestId: "archive-request",
        sessionId: "thread-archive",
        provider: "codex",
        projectPath: "/project",
      },
      ws,
    );

    await vi.waitFor(() => {
      expect(ws.send).toHaveBeenCalled();
    });
    expect(reserveArchiveCapacity).toHaveBeenCalledWith(
      "thread-archive",
      "codex",
      expect.stringMatching(/^codex-home-[0-9a-f]{24}$/),
    );
    expect(archiveThread).toHaveBeenCalledWith("thread-archive");
    expect(commitReservedArchive).not.toHaveBeenCalled();
    expect(releaseArchiveCapacity).toHaveBeenCalledWith(reservation);
    expect(stop).toHaveBeenCalledOnce();
    expect(createStandalone).toHaveBeenCalledWith("/project");
    expect(
      ws.send.mock.calls.map((call: unknown[]) =>
        JSON.parse(call[0] as string),
      ),
    ).toContainEqual(
      expect.objectContaining({
        type: "archive_result",
        requestId: "archive-request",
        sessionId: "thread-archive",
        success: false,
        errorCode: "provider_rpc_failed",
      }),
    );
    bridge.close();
  });

  it("persists Codex archive bookkeeping after the official RPC succeeds", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    const reservation = {
      sessionId: "thread-archive",
      provider: "codex",
      identityKey: "codex\0thread-archive",
      token: Symbol("archive"),
      alreadyArchived: false,
    };
    const reserveArchiveCapacity = vi.fn(async () => reservation);
    const commitReservedArchive = vi.fn(async () => {});
    const releaseArchiveCapacity = vi.fn(async () => {});
    const archiveThread = vi.fn(async () => {});
    const stop = vi.fn();
    (bridge as any).archiveStoreReady = Promise.resolve();
    (bridge as any).archiveStoreInitializationError = null;
    (bridge as any).archiveStore = {
      reserveArchiveCapacity,
      commitReservedArchive,
      releaseArchiveCapacity,
    };
    vi.spyOn(bridge as any, "createStandaloneCodexProcess").mockResolvedValue({
      archiveThread,
      unarchiveThread: vi.fn(async () => {}),
      stop,
    });

    (bridge as any).handleClientMessage(
      {
        type: "archive_session",
        requestId: "archive-request",
        sessionId: "thread-archive",
        provider: "codex",
        projectPath: "/project",
        name: "Saved title",
      },
      ws,
    );

    await vi.waitFor(() => {
      expect(commitReservedArchive).toHaveBeenCalled();
    });
    expect(reserveArchiveCapacity.mock.invocationCallOrder[0]).toBeLessThan(
      archiveThread.mock.invocationCallOrder[0],
    );
    expect(archiveThread.mock.invocationCallOrder[0]).toBeLessThan(
      commitReservedArchive.mock.invocationCallOrder[0],
    );
    expect(commitReservedArchive).toHaveBeenCalledWith(
      reservation,
      "/project",
      expect.objectContaining({ name: "Saved title" }),
    );
    expect(releaseArchiveCapacity).toHaveBeenCalledWith(reservation);
    expect(JSON.parse(ws.send.mock.calls.at(-1)?.[0] as string)).toMatchObject({
      type: "archive_result",
      requestId: "archive-request",
      success: true,
    });
    bridge.close();
  });

  it("reserves local capacity before the official Codex archive RPC", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    const reserveArchiveCapacity = vi.fn(async () => {
      throw new Error(
        "Archive store has reached the supported 10000-entry limit",
      );
    });
    const archiveThread = vi.fn(async () => {});
    const stop = vi.fn();
    (bridge as any).archiveStoreReady = Promise.resolve();
    (bridge as any).archiveStoreInitializationError = null;
    (bridge as any).archiveStore = { reserveArchiveCapacity };
    vi.spyOn(bridge as any, "createStandaloneCodexProcess").mockResolvedValue({
      archiveThread,
      stop,
    });

    (bridge as any).handleClientMessage(
      {
        type: "archive_session",
        requestId: "archive-full",
        sessionId: "thread-overflow",
        provider: "codex",
        projectPath: "/project",
      },
      ws,
    );

    await vi.waitFor(() => {
      expect(ws.send).toHaveBeenCalled();
    });
    expect(reserveArchiveCapacity).toHaveBeenCalledOnce();
    expect(archiveThread).not.toHaveBeenCalled();
    expect(stop).toHaveBeenCalledOnce();
    expect(JSON.parse(ws.send.mock.calls.at(-1)?.[0] as string)).toMatchObject({
      type: "archive_result",
      requestId: "archive-full",
      success: false,
      errorCode: "local_store_failed",
    });
    bridge.close();
  });

  it("holds the reservation through local failure compensation", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    const reservation = {
      sessionId: "thread-compensated",
      provider: "codex",
      identityKey: "codex\0thread-compensated",
      token: Symbol("archive"),
      alreadyArchived: false,
    };
    const reserveArchiveCapacity = vi.fn(async () => reservation);
    const commitReservedArchive = vi.fn(async () => {
      throw new Error("disk full");
    });
    const releaseArchiveCapacity = vi.fn(async () => {});
    const archiveThread = vi.fn(async () => {});
    const unarchiveThread = vi.fn(async () => {});
    (bridge as any).archiveStoreReady = Promise.resolve();
    (bridge as any).archiveStoreInitializationError = null;
    (bridge as any).archiveStore = {
      reserveArchiveCapacity,
      commitReservedArchive,
      releaseArchiveCapacity,
    };
    vi.spyOn(bridge as any, "createStandaloneCodexProcess").mockResolvedValue({
      archiveThread,
      unarchiveThread,
      stop: vi.fn(),
    });

    (bridge as any).handleClientMessage(
      {
        type: "archive_session",
        requestId: "archive-compensated",
        sessionId: "thread-compensated",
        provider: "codex",
        projectPath: "/project",
      },
      ws,
    );

    await vi.waitFor(() => {
      expect(ws.send).toHaveBeenCalled();
    });
    expect(archiveThread).toHaveBeenCalledOnce();
    expect(unarchiveThread).toHaveBeenCalledOnce();
    expect(unarchiveThread.mock.invocationCallOrder[0]).toBeLessThan(
      releaseArchiveCapacity.mock.invocationCallOrder[0],
    );
    expect(JSON.parse(ws.send.mock.calls.at(-1)?.[0] as string)).toMatchObject({
      type: "archive_result",
      requestId: "archive-compensated",
      success: false,
      errorCode: "local_store_failed",
    });
    bridge.close();
  });

  it("fails closed when archive store initialization failed", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    const reserveArchiveCapacity = vi.fn(async () => {});
    (bridge as any).archiveStoreReady = Promise.resolve();
    (bridge as any).archiveStoreInitializationError = new Error("bad json");
    (bridge as any).archiveStore = { reserveArchiveCapacity };
    const standalone = vi.spyOn(bridge as any, "createStandaloneCodexProcess");

    (bridge as any).handleClientMessage(
      {
        type: "archive_session",
        requestId: "archive-request",
        sessionId: "thread-archive",
        provider: "codex",
        projectPath: "/project",
      },
      ws,
    );

    await vi.waitFor(() => {
      expect(ws.send).toHaveBeenCalled();
    });
    expect(reserveArchiveCapacity).not.toHaveBeenCalled();
    expect(standalone).not.toHaveBeenCalled();
    expect(JSON.parse(ws.send.mock.calls.at(-1)?.[0] as string)).toMatchObject({
      type: "archive_result",
      success: false,
      errorCode: "local_store_failed",
    });
    bridge.close();
  });

  it("uses a standalone Codex app-server to restore an archived thread", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    const unarchive = vi.fn(async () => ({ sessionId: "thread-restore" }));
    const unarchiveThread = vi.fn(async () => {});
    const stop = vi.fn();
    const entry = {
      sessionId: "thread-restore",
      provider: "codex",
      projectPath: "/project",
      archivedAt: "2026-07-18T00:00:00Z",
    };
    (bridge as any).archiveStoreReady = Promise.resolve();
    (bridge as any).archiveStoreInitializationError = null;
    (bridge as any).archiveStore = {
      list: vi.fn(() => [entry]),
      unarchive,
    };
    vi.spyOn(bridge as any, "createStandaloneCodexProcess").mockResolvedValue({
      unarchiveThread,
      archiveThread: vi.fn(async () => {}),
      stop,
    });

    (bridge as any).handleClientMessage(
      {
        type: "unarchive_session",
        requestId: "restore-request",
        sessionId: "thread-restore",
        provider: "codex",
        projectPath: "/project",
      },
      ws,
    );

    await vi.waitFor(() => {
      expect(unarchive).toHaveBeenCalledWith(
        "thread-restore",
        "codex",
        undefined,
      );
    });
    expect(unarchiveThread).toHaveBeenCalledWith("thread-restore");
    expect(unarchiveThread.mock.invocationCallOrder[0]).toBeLessThan(
      unarchive.mock.invocationCallOrder[0],
    );
    expect(stop).toHaveBeenCalledOnce();
    expect(JSON.parse(ws.send.mock.calls.at(-1)?.[0] as string)).toMatchObject({
      type: "unarchive_result",
      requestId: "restore-request",
      success: true,
    });
    bridge.close();
  });

  it("returns a bounded archived-session list correlated to its request", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    const entries = Array.from({ length: 1_001 }, (_, index) => ({
      sessionId: `thread-${index}`,
      provider: "codex",
      projectPath: "/project",
      archivedAt: "2026-07-18T00:00:00Z",
    }));
    (bridge as any).archiveStoreReady = Promise.resolve();
    (bridge as any).archiveStoreInitializationError = null;
    (bridge as any).archiveStore = {
      list: vi.fn(() => entries),
    };

    (bridge as any).handleClientMessage(
      { type: "list_archived_sessions", requestId: "list-request" },
      ws,
    );

    await vi.waitFor(() => {
      expect(ws.send).toHaveBeenCalled();
    });
    const result = JSON.parse(ws.send.mock.calls.at(-1)?.[0] as string);
    expect((bridge as any).archiveStore.list).toHaveBeenCalledWith(
      1_001,
      expect.stringMatching(/^codex-home-[0-9a-f]{24}$/),
    );
    expect(result).toMatchObject({
      type: "archived_sessions_result",
      requestId: "list-request",
      success: true,
      truncated: true,
    });
    expect(result.sessions).toHaveLength(1_000);
    bridge.close();
  });

  it("uses a standalone Codex app-server for confirmed permanent deletion", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    const remove = vi.fn(async () => ({ sessionId: "thread-delete" }));
    const deleteThread = vi.fn(async () => {});
    const stop = vi.fn();
    const entry = {
      sessionId: "thread-delete",
      provider: "codex",
      projectPath: "/project",
      archivedAt: "2026-07-18T00:00:00Z",
    };
    (bridge as any).archiveStoreReady = Promise.resolve();
    (bridge as any).archiveStoreInitializationError = null;
    (bridge as any).archiveStore = {
      list: vi.fn(() => [entry]),
      remove,
    };
    vi.spyOn(bridge as any, "createStandaloneCodexProcess").mockResolvedValue({
      deleteThread,
      stop,
    });

    (bridge as any).handleClientMessage(
      {
        type: "delete_session",
        requestId: "delete-request",
        sessionId: "thread-delete",
        provider: "codex",
        projectPath: "/project",
        confirmDescendantDeletion: true,
      },
      ws,
    );

    await vi.waitFor(() => {
      expect(remove).toHaveBeenCalledWith("thread-delete", "codex", undefined);
    });
    expect(deleteThread).toHaveBeenCalledWith("thread-delete");
    expect(deleteThread.mock.invocationCallOrder[0]).toBeLessThan(
      remove.mock.invocationCallOrder[0],
    );
    expect(stop).toHaveBeenCalledOnce();
    expect(JSON.parse(ws.send.mock.calls.at(-1)?.[0] as string)).toMatchObject({
      type: "delete_session_result",
      requestId: "delete-request",
      success: true,
    });
    bridge.close();
  });

  it("reports irreversible local cleanup failure after provider deletion as partial", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    const deleteThread = vi.fn(async () => {});
    const remove = vi.fn(async () => {
      throw new Error("disk full");
    });
    (bridge as any).archiveStoreReady = Promise.resolve();
    (bridge as any).archiveStoreInitializationError = null;
    (bridge as any).archiveStore = {
      list: vi.fn(() => [
        {
          sessionId: "thread-delete",
          provider: "codex",
          projectPath: "/project",
          archivedAt: "2026-07-18T00:00:00Z",
        },
      ]),
      remove,
    };
    vi.spyOn(bridge as any, "createStandaloneCodexProcess").mockResolvedValue({
      deleteThread,
      stop: vi.fn(),
    });

    (bridge as any).handleClientMessage(
      {
        type: "delete_session",
        requestId: "delete-partial",
        sessionId: "thread-delete",
        provider: "codex",
        projectPath: "/project",
        confirmDescendantDeletion: true,
      },
      ws,
    );

    await vi.waitFor(() => {
      expect(ws.send).toHaveBeenCalled();
    });
    expect(deleteThread).toHaveBeenCalledOnce();
    expect(JSON.parse(ws.send.mock.calls.at(-1)?.[0] as string)).toMatchObject({
      type: "delete_session_result",
      requestId: "delete-partial",
      success: false,
      errorCode: "partial_failure",
    });
    bridge.close();
  });

  it("refuses archive lifecycle mutations for a live provider thread", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    const reserveArchiveCapacity = vi.fn(async () => {});
    (bridge as any).archiveStoreReady = Promise.resolve();
    (bridge as any).archiveStoreInitializationError = null;
    (bridge as any).archiveStore = { reserveArchiveCapacity };
    (bridge as any).sessionManager.create(
      "/project",
      { sessionId: "thread-live" },
      [],
      undefined,
      "codex",
      { threadId: "thread-live" },
    );
    const standalone = vi.spyOn(bridge as any, "createStandaloneCodexProcess");

    (bridge as any).handleClientMessage(
      {
        type: "archive_session",
        requestId: "archive-live",
        sessionId: "thread-live",
        provider: "codex",
        projectPath: "/project",
      },
      ws,
    );

    await vi.waitFor(() => {
      expect(ws.send).toHaveBeenCalled();
    });
    expect(reserveArchiveCapacity).not.toHaveBeenCalled();
    expect(standalone).not.toHaveBeenCalled();
    expect(JSON.parse(ws.send.mock.calls.at(-1)?.[0] as string)).toMatchObject({
      type: "archive_result",
      success: false,
      errorCode: "session_active",
    });
    bridge.close();
  });

  it("rechecks activity after a racing Codex resume acquires the thread", async () => {
    let resolveHistory:
      ((messages: Array<Record<string, unknown>>) => void) | undefined;
    getCodexSessionHistoryMock.mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          resolveHistory = resolve;
        }),
    );
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const resumeWs = { readyState: OPEN_STATE, send: vi.fn() } as any;
    const archiveWs = { readyState: OPEN_STATE, send: vi.fn() } as any;
    const reserveArchiveCapacity = vi.fn(async () => {});
    (bridge as any).archiveStoreReady = Promise.resolve();
    (bridge as any).archiveStoreInitializationError = null;
    (bridge as any).archiveStore = {
      reserveArchiveCapacity,
      isArchived: vi.fn(() => false),
    };
    const acquire = vi.spyOn(bridge as any, "acquireCodexThreadOperation");

    const resume = (bridge as any).handleClientMessage(
      {
        type: "resume_session",
        sessionId: "thread-racing-resume",
        provider: "codex",
        projectPath: "/project",
      },
      resumeWs,
    );
    await vi.waitFor(() => {
      expect(resolveHistory).toBeTypeOf("function");
    });

    (bridge as any).handleClientMessage(
      {
        type: "archive_session",
        requestId: "archive-racing-resume",
        sessionId: "thread-racing-resume",
        provider: "codex",
        projectPath: "/project",
      },
      archiveWs,
    );
    await vi.waitFor(() => {
      expect(acquire).toHaveBeenCalledTimes(2);
    });

    resolveHistory?.([]);
    await resume;
    await vi.waitFor(() => {
      expect(archiveWs.send).toHaveBeenCalled();
    });

    const session = (bridge as any).sessionManager.get("s-1");
    expect(session.process.archiveThread).not.toHaveBeenCalled();
    expect(reserveArchiveCapacity).not.toHaveBeenCalled();
    expect(
      JSON.parse(archiveWs.send.mock.calls.at(-1)?.[0] as string),
    ).toMatchObject({
      type: "archive_result",
      requestId: "archive-racing-resume",
      provider: "codex",
      success: false,
      errorCode: "session_active",
    });

    bridge.close();
  });

  it("rejects an archived Codex thread resumed through legacy start", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    const create = vi.spyOn((bridge as any).sessionManager, "create");
    const acquire = vi.spyOn(bridge as any, "acquireCodexThreadOperation");
    (bridge as any).archiveStoreReady = Promise.resolve();
    (bridge as any).archiveStoreInitializationError = null;
    (bridge as any).archiveStore = {
      isArchived: vi.fn(() => true),
    };

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        sessionId: "thread-archived-start",
        provider: "codex",
        projectPath: "/project",
      },
      ws,
    );

    expect(acquire).toHaveBeenCalledWith("thread-archived-start");
    expect(create).not.toHaveBeenCalled();
    expect(getCodexSessionHistoryMock).not.toHaveBeenCalled();
    expect(
      ws.send.mock.calls
        .map((call: unknown[]) => JSON.parse(call[0] as string))
        .find((message: any) => message.type === "error"),
    ).toMatchObject({
      message: expect.stringContaining(
        "The Codex thread is archived. Restore it before resuming.",
      ),
    });

    bridge.close();
  });

  it("deduplicates legacy Codex start-with-session across clients", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const wsA = { readyState: OPEN_STATE, send: vi.fn() } as any;
    const wsB = { readyState: OPEN_STATE, send: vi.fn() } as any;
    const create = vi.spyOn((bridge as any).sessionManager, "create");
    (bridge as any).archiveStoreReady = Promise.resolve();
    (bridge as any).archiveStoreInitializationError = null;
    (bridge as any).archiveStore = {
      isArchived: vi.fn(() => false),
    };
    const request = {
      type: "start",
      sessionId: "thread-legacy-start-once",
      provider: "codex",
      projectPath: "/project",
    };

    await (bridge as any).handleClientMessage(request, wsA);
    await (bridge as any).handleClientMessage(request, wsB);

    expect(create).toHaveBeenCalledTimes(1);
    expect(getCodexSessionHistoryMock).toHaveBeenCalledTimes(1);
    const createdFor = (ws: typeof wsA) =>
      ws.send.mock.calls
        .map((call: unknown[]) => JSON.parse(call[0] as string))
        .find(
          (message: any) =>
            message.type === "system" && message.subtype === "session_created",
        );
    expect(createdFor(wsA)).toMatchObject({
      sessionId: "s-1",
      claudeSessionId: "thread-legacy-start-once",
    });
    expect(createdFor(wsB)).toMatchObject({
      sessionId: "s-1",
      claudeSessionId: "thread-legacy-start-once",
    });

    bridge.close();
  });

  it("serializes legacy Codex start with a cross-socket archive", async () => {
    let resolveHistory:
      ((messages: Array<Record<string, unknown>>) => void) | undefined;
    getCodexSessionHistoryMock.mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          resolveHistory = resolve;
        }),
    );
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const startWs = { readyState: OPEN_STATE, send: vi.fn() } as any;
    const archiveWs = { readyState: OPEN_STATE, send: vi.fn() } as any;
    const archive = vi.fn(async () => {});
    (bridge as any).archiveStoreReady = Promise.resolve();
    (bridge as any).archiveStoreInitializationError = null;
    (bridge as any).archiveStore = {
      archive,
      isArchived: vi.fn(() => false),
    };
    const acquire = vi.spyOn(bridge as any, "acquireCodexThreadOperation");

    const start = (bridge as any).handleClientMessage(
      {
        type: "start",
        sessionId: "thread-racing-start-archive",
        provider: "codex",
        projectPath: "/project",
      },
      startWs,
    );
    await vi.waitFor(() => {
      expect(resolveHistory).toBeTypeOf("function");
    });

    (bridge as any).handleClientMessage(
      {
        type: "archive_session",
        requestId: "archive-racing-start",
        sessionId: "thread-racing-start-archive",
        provider: "codex",
        projectPath: "/project",
      },
      archiveWs,
    );
    await vi.waitFor(() => {
      expect(acquire).toHaveBeenCalledTimes(2);
    });

    resolveHistory?.([]);
    await start;
    await vi.waitFor(() => {
      expect(archiveWs.send).toHaveBeenCalled();
    });

    const session = (bridge as any).sessionManager.get("s-1");
    expect(session.process.archiveThread).not.toHaveBeenCalled();
    expect(archive).not.toHaveBeenCalled();
    expect(
      JSON.parse(archiveWs.send.mock.calls.at(-1)?.[0] as string),
    ).toMatchObject({
      type: "archive_result",
      requestId: "archive-racing-start",
      provider: "codex",
      success: false,
      errorCode: "session_active",
    });

    bridge.close();
  });

  it("serializes legacy Codex start with a cross-socket permanent delete", async () => {
    let resolveHistory:
      ((messages: Array<Record<string, unknown>>) => void) | undefined;
    getCodexSessionHistoryMock.mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          resolveHistory = resolve;
        }),
    );
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const startWs = { readyState: OPEN_STATE, send: vi.fn() } as any;
    const deleteWs = { readyState: OPEN_STATE, send: vi.fn() } as any;
    const remove = vi.fn(async () => {});
    (bridge as any).archiveStoreReady = Promise.resolve();
    (bridge as any).archiveStoreInitializationError = null;
    (bridge as any).archiveStore = {
      // Force admission past the independent archive guard so this test
      // exercises the shared lock and the second live-session check directly.
      isArchived: vi.fn(() => false),
      list: vi.fn(() => [
        {
          sessionId: "thread-racing-start-delete",
          provider: "codex",
          projectPath: "/project",
          archivedAt: "2026-07-18T00:00:00Z",
        },
      ]),
      remove,
    };
    const acquire = vi.spyOn(bridge as any, "acquireCodexThreadOperation");

    const start = (bridge as any).handleClientMessage(
      {
        type: "start",
        sessionId: "thread-racing-start-delete",
        provider: "codex",
        projectPath: "/project",
      },
      startWs,
    );
    await vi.waitFor(() => {
      expect(resolveHistory).toBeTypeOf("function");
    });

    (bridge as any).handleClientMessage(
      {
        type: "delete_session",
        requestId: "delete-racing-start",
        sessionId: "thread-racing-start-delete",
        provider: "codex",
        projectPath: "/project",
        confirmDescendantDeletion: true,
      },
      deleteWs,
    );
    await vi.waitFor(() => {
      expect(acquire).toHaveBeenCalledTimes(2);
    });

    resolveHistory?.([]);
    await start;
    await vi.waitFor(() => {
      expect(deleteWs.send).toHaveBeenCalled();
    });

    const session = (bridge as any).sessionManager.get("s-1");
    expect(session.process.deleteThread).not.toHaveBeenCalled();
    expect(remove).not.toHaveBeenCalled();
    expect(
      JSON.parse(deleteWs.send.mock.calls.at(-1)?.[0] as string),
    ).toMatchObject({
      type: "delete_session_result",
      requestId: "delete-racing-start",
      success: false,
      errorCode: "session_active",
    });

    bridge.close();
  });

  it("echoes recent session request metadata for project scoped requests", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    getAllRecentSessionsMock.mockResolvedValue({
      sessions: [{ sessionId: "s1", projectPath: "/tmp/project" }],
      hasMore: true,
    });
    await (bridge as any).archiveStoreReady;

    (bridge as any).handleClientMessage(
      {
        type: "list_recent_sessions",
        limit: 20,
        offset: 40,
        projectPath: "/tmp/project",
        requestScope: "project",
        requestId: "catalog-7-12",
        queryGeneration: 7,
        provider: "claude",
        namedOnly: true,
        searchQuery: "needle",
      },
      ws,
    );
    let recent: any;
    await vi.waitFor(() => {
      recent = ws.send.mock.calls
        .map((c: unknown[]) => JSON.parse(c[0] as string))
        .find((m: any) => m.type === "recent_sessions");
      expect(recent).toBeDefined();
    });
    expect(recent).toMatchObject({
      type: "recent_sessions",
      hasMore: true,
      limit: 20,
      offset: 40,
      projectPath: "/tmp/project",
      requestScope: "project",
      requestId: "catalog-7-12",
      queryGeneration: 7,
      provider: "claude",
      namedOnly: true,
      searchQuery: "needle",
    });
    expect(recent.catalogRevision).toEqual(expect.any(Number));

    bridge.close();
  });

  it("binds Codex catalog rows and lifecycle mutations to one source Home", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    await (bridge as any).archiveStoreReady;
    const sourceId = (bridge as any).codexSourceId as string;
    const otherSourceId = `${sourceId}-other`;

    expect(
      (bridge as any).attachCodexSourceToRecentSessions([
        { sessionId: "codex-thread", provider: "codex" },
        { sessionId: "claude-thread", provider: "claude" },
      ]),
    ).toEqual([
      {
        sessionId: "codex-thread",
        provider: "codex",
        codexSourceId: sourceId,
      },
      { sessionId: "claude-thread", provider: "claude" },
    ]);

    await (bridge as any).handleClientMessage(
      {
        type: "resume_session",
        sessionId: "codex-thread",
        projectPath: "/project",
        provider: "codex",
        resumeRequestId: "resume-wrong-source",
        codexSourceId: otherSourceId,
      },
      ws,
    );
    expect(
      ws.send.mock.calls
        .map((call: unknown[]) => JSON.parse(call[0] as string))
        .find((message: any) => message.errorCode === "codex_source_mismatch"),
    ).toMatchObject({
      type: "error",
      sessionId: "codex-thread",
    });

    const runningLookup = vi
      .spyOn((bridge as any).sessionManager, "get")
      .mockReturnValue({ provider: "codex" } as any);
    const renameRunning = vi.fn();
    (bridge as any).sessionManager.renameSession = renameRunning;
    ws.send.mockClear();
    await (bridge as any).handleRenameSession(ws, "codex-thread", "renamed", {
      type: "rename_session",
      sessionId: "codex-thread",
      provider: "codex",
      providerSessionId: "codex-thread",
      projectPath: "/project",
      codexSourceId: otherSourceId,
    });
    expect(JSON.parse(ws.send.mock.calls.at(-1)?.[0] as string)).toMatchObject({
      type: "rename_result",
      success: false,
      errorCode: "codex_source_mismatch",
    });
    expect(renameRunning).not.toHaveBeenCalled();
    runningLookup.mockRestore();
    delete (bridge as any).sessionManager.renameSession;

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "fork",
        sessionId: "codex-thread",
        targetUuid: "codex:user-turn:latest",
        projectPath: "/project",
        codexSourceId: otherSourceId,
      },
      ws,
    );
    await vi.waitFor(() => {
      expect(
        JSON.parse(ws.send.mock.calls.at(-1)?.[0] as string),
      ).toMatchObject({
        type: "error",
        sessionId: "codex-thread",
        errorCode: "codex_source_mismatch",
      });
    });

    ws.send.mockClear();
    (bridge as any).handleClientMessage(
      {
        type: "archive_session",
        requestId: "archive-wrong-source",
        sessionId: "codex-thread",
        provider: "codex",
        projectPath: "/project",
        codexSourceId: otherSourceId,
      },
      ws,
    );
    await vi.waitFor(() => {
      expect(
        JSON.parse(ws.send.mock.calls.at(-1)?.[0] as string),
      ).toMatchObject({
        type: "archive_result",
        requestId: "archive-wrong-source",
        success: false,
        errorCode: "codex_source_mismatch",
      });
    });

    for (const [type, resultType] of [
      ["unarchive_session", "unarchive_result"],
      ["delete_session", "delete_session_result"],
    ] as const) {
      ws.send.mockClear();
      (bridge as any).handleClientMessage(
        {
          type,
          requestId: `${type}-wrong-source`,
          sessionId: "codex-thread",
          provider: "codex",
          projectPath: "/project",
          ...(type === "delete_session"
            ? { confirmDescendantDeletion: true }
            : {}),
          codexSourceId: otherSourceId,
        },
        ws,
      );
      await vi.waitFor(() => {
        expect(
          JSON.parse(ws.send.mock.calls.at(-1)?.[0] as string),
        ).toMatchObject({
          type: resultType,
          success: false,
          errorCode: "codex_source_mismatch",
        });
      });
    }

    bridge.close();
  });

  it("resolves a live Claude provider session id to its bridge session", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    (bridge as any).clientSupportedServerMessages.set(
      ws,
      new Set(["session_link_progress_v1"]),
    );
    const bridgeSessionId = (bridge as any).sessionManager.create(
      "/tmp/project",
      { sessionId: "claude-live-uuid" },
    );

    await (bridge as any).handleClientMessage(
      {
        type: "resolve_session_link",
        requestId: "req-live",
        sessionId: "claude-live-uuid",
        provider: "claude",
        sessionLinkGeneration: 7,
      },
      ws,
    );

    expect(
      ws.send.mock.calls
        .map((call: unknown[]) => JSON.parse(call[0] as string))
        .find((message: any) => message.type === "session_link_resolution"),
    ).toMatchObject({
      requestId: "req-live",
      sourceSessionId: "claude-live-uuid",
      status: "live",
      bridgeSessionId,
      provider: "claude",
      sessionLinkGeneration: 7,
    });
    expect(
      ws.send.mock.calls
        .map((call: unknown[]) => JSON.parse(call[0] as string))
        .filter((message: any) => message.type === "session_link_progress_v1")
        .map((message: any) => ({
          stage: message.stage,
          generation: message.generation,
          sequence: message.sequence,
        })),
    ).toEqual([
      { stage: "request_accepted", generation: 7, sequence: 1 },
      { stage: "runtime_checked", generation: 7, sequence: 2 },
      { stage: "resolution_ready", generation: 7, sequence: 3 },
    ]);
    expect(getAllRecentSessionsMock).not.toHaveBeenCalled();

    bridge.close();
  });

  it("resolves a non-live session from the recent sessions index", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    getAllRecentSessionsMock.mockResolvedValue({
      sessions: [
        {
          sessionId: "claude-recent-uuid",
          provider: "claude",
          projectPath: "/tmp/project",
          resumeCwd: "/tmp/project-worktree",
          firstPrompt: "continue this work",
        },
      ],
      hasMore: false,
    });

    await (bridge as any).handleClientMessage(
      {
        type: "resolve_session_link",
        requestId: "req-recent",
        sessionId: "claude-recent-uuid",
        provider: "claude",
      },
      ws,
    );

    expect(getAllRecentSessionsMock).toHaveBeenCalledWith(
      expect.objectContaining({
        limit: 1,
        provider: "claude",
        sessionId: "claude-recent-uuid",
      }),
    );
    expect(
      ws.send.mock.calls
        .map((call: unknown[]) => JSON.parse(call[0] as string))
        .find((message: any) => message.type === "session_link_resolution"),
    ).toMatchObject({
      requestId: "req-recent",
      sourceSessionId: "claude-recent-uuid",
      status: "recent",
      provider: "claude",
      recentSession: {
        sessionId: "claude-recent-uuid",
        projectPath: "/tmp/project",
        resumeCwd: "/tmp/project-worktree",
      },
    });

    bridge.close();
  });

  it("stamps a resolved recent Codex session with the current source", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    getAllRecentSessionsMock.mockResolvedValue({
      sessions: [
        {
          sessionId: "codex-recent-thread",
          provider: "codex",
          projectPath: "/tmp/project",
          firstPrompt: "continue Codex work",
          codexSourceId: "stale-source-from-index",
        },
      ],
      hasMore: false,
    });

    await (bridge as any).handleClientMessage(
      {
        type: "resolve_session_link",
        requestId: "req-codex-recent",
        sessionId: "codex-recent-thread",
        provider: "codex",
      },
      ws,
    );

    const resolution = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.type === "session_link_resolution");
    expect(resolution).toMatchObject({
      requestId: "req-codex-recent",
      status: "recent",
      provider: "codex",
      recentSession: {
        sessionId: "codex-recent-thread",
        codexSourceId: (bridge as any).codexSourceId,
      },
    });
    expect(resolution.recentSession.codexSourceId).not.toBe(
      "stale-source-from-index",
    );

    bridge.close();
  });

  it("returns unavailable for an unknown session link", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "resolve_session_link",
        requestId: "req-missing",
        sessionId: "missing-uuid",
        provider: "claude",
      },
      ws,
    );

    expect(
      ws.send.mock.calls
        .map((call: unknown[]) => JSON.parse(call[0] as string))
        .find((message: any) => message.type === "session_link_resolution"),
    ).toMatchObject({
      requestId: "req-missing",
      sourceSessionId: "missing-uuid",
      status: "unavailable",
      provider: "claude",
    });
    expect(
      ws.send.mock.calls
        .map((call: unknown[]) => JSON.parse(call[0] as string))
        .some((message: any) => message.type === "session_link_progress_v1"),
    ).toBe(false);

    bridge.close();
  });

  it("does not publish a running Codex rename when the provider rejects it", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex-rename",
        provider: "codex",
      },
      ws,
    );
    const created = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.subtype === "session_created");
    const session = (bridge as any).sessionManager.get(created.sessionId);
    session.name = "original";
    session.process.renameThread = vi
      .fn()
      .mockRejectedValueOnce(new Error("provider rename rejected"));

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "rename_session",
        sessionId: created.sessionId,
        name: "optimistic-would-be-wrong",
      },
      ws,
    );

    expect(session.name).toBe("original");
    expect(
      ws.send.mock.calls
        .map((call: unknown[]) => JSON.parse(call[0] as string))
        .find((message: any) => message.type === "rename_result"),
    ).toMatchObject({
      success: false,
      errorCode: "provider_rpc_failed",
      error: "provider rename rejected",
    });
    await bridge.close();
  });

  it("scopes history not-found errors to the requested session", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    for (const request of [
      { type: "get_history", sessionId: "missing-session" },
      {
        type: "get_history_delta",
        sessionId: "missing-session",
        sinceSeq: 0,
      },
    ]) {
      ws.send.mockClear();
      await (bridge as any).handleClientMessage(request, ws);

      expect(
        ws.send.mock.calls
          .map((call: unknown[]) => JSON.parse(call[0] as string))
          .find((message: any) => message.type === "error"),
      ).toEqual({
        type: "error",
        message: "Session missing-session not found",
        errorCode: "session_not_found",
        sessionId: "missing-session",
      });
    }

    bridge.close();
  });

  it("archives a Codex thread before recording the local archive marker", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const archiveProjectPath = resolvePlatformPath("/tmp/project-archive");
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    const order: string[] = [];
    const reservation = {
      sessionId: "codex-thread-1",
      provider: "codex",
      identityKey: "codex\0codex-thread-1",
      token: Symbol("archive"),
      alreadyArchived: false,
    };
    const archiveThread = vi.fn(async () => {
      order.push("rpc");
    });
    const commitReservedArchive = vi.fn(async () => {
      order.push("local");
    });
    const releaseArchiveCapacity = vi.fn(async () => {});
    (bridge as any).archiveStoreReady = Promise.resolve();
    (bridge as any).archiveStoreInitializationError = null;
    (bridge as any).archiveStore = {
      reserveArchiveCapacity: vi.fn(async () => reservation),
      commitReservedArchive,
      releaseArchiveCapacity,
    };
    vi.spyOn(bridge as any, "createStandaloneCodexProcess").mockResolvedValue({
      archiveThread,
      unarchiveThread: vi.fn(async () => {}),
      stop: vi.fn(),
    });

    await (bridge as any).handleClientMessage(
      {
        type: "archive_session",
        sessionId: "codex-thread-1",
        provider: "codex",
        projectPath: "/tmp/project-archive",
      },
      ws,
    );
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(order).toEqual(["rpc", "local"]);
    expect(commitReservedArchive).toHaveBeenCalledWith(
      reservation,
      archiveProjectPath,
      expect.objectContaining({
        name: undefined,
        summary: undefined,
      }),
    );
    expect(
      ws.send.mock.calls
        .map((call: unknown[]) => JSON.parse(call[0] as string))
        .find((message: any) => message.type === "archive_result"),
    ).toMatchObject({
      sessionId: "codex-thread-1",
      success: true,
    });

    bridge.close();
  });

  it("refuses to archive a Desktop-active shared Codex thread", async () => {
    vi.stubEnv("BRIDGE_CODEX_APP_SERVER_MODE", "daemon");
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      codexActionBrokerRuntime: writableCodexActionBrokerRuntime(),
    });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    const reserveArchiveCapacity = vi.fn();
    (bridge as any).archiveStoreReady = Promise.resolve();
    (bridge as any).archiveStoreInitializationError = null;
    (bridge as any).archiveStore = { reserveArchiveCapacity };
    vi.spyOn(
      (bridge as any).localFeatures,
      "conversationActivity",
    ).mockReturnValue("active");

    await (bridge as any).handleClientMessage(
      {
        type: "archive_session",
        sessionId: "desktop-active-thread",
        provider: "codex",
        projectPath: "/tmp/project-desktop-active",
      },
      ws,
    );
    await vi.waitFor(() =>
      expect(
        ws.send.mock.calls
          .map((call: unknown[]) => JSON.parse(call[0] as string))
          .find((message: any) => message.type === "archive_result"),
      ).toMatchObject({
        success: false,
        errorCode: "session_active",
      }),
    );
    expect(reserveArchiveCapacity).not.toHaveBeenCalled();
    await bridge.close();
  });

  it("archives a Codex thread through a standalone process when none is active", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const archiveProjectPath = resolvePlatformPath(
      "/tmp/project-archive-standalone",
    );
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    const codexProcess = {
      archiveThread: vi.fn().mockResolvedValue(undefined),
      stop: vi.fn(),
    };
    const createStandalone = vi
      .spyOn(bridge as any, "createStandaloneCodexProcess")
      .mockResolvedValue(codexProcess);
    const reservation = {
      sessionId: "codex-thread-standalone",
      provider: "codex",
      identityKey: "codex\0codex-thread-standalone",
      token: Symbol("archive"),
      alreadyArchived: false,
    };
    const commitReservedArchive = vi.fn(async () => {});
    (bridge as any).archiveStoreReady = Promise.resolve();
    (bridge as any).archiveStoreInitializationError = null;
    (bridge as any).archiveStore = {
      reserveArchiveCapacity: vi.fn(async () => reservation),
      commitReservedArchive,
      releaseArchiveCapacity: vi.fn(async () => {}),
    };

    await (bridge as any).handleClientMessage(
      {
        type: "archive_session",
        sessionId: "codex-thread-standalone",
        provider: "codex",
        projectPath:
          "/tmp/project-archive-standalone/../project-archive-standalone",
      },
      ws,
    );
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(codexProcess.archiveThread).toHaveBeenCalledWith(
      "codex-thread-standalone",
    );
    expect(createStandalone).toHaveBeenCalledWith(archiveProjectPath);
    expect(codexProcess.stop).toHaveBeenCalledTimes(1);
    expect(commitReservedArchive).toHaveBeenCalledWith(
      reservation,
      archiveProjectPath,
      expect.any(Object),
    );
    bridge.close();
  });

  it("rejects standalone Codex archive outside allowed directories", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    (bridge as any).allowedDirs = ["/tmp/allowed"];
    const createStandalone = vi.spyOn(
      bridge as any,
      "createStandaloneCodexProcess",
    );
    const reserveArchiveCapacity = vi.fn(async () => {});
    (bridge as any).archiveStoreReady = Promise.resolve();
    (bridge as any).archiveStoreInitializationError = null;
    (bridge as any).archiveStore = { reserveArchiveCapacity };

    await (bridge as any).handleClientMessage(
      {
        type: "archive_session",
        sessionId: "codex-thread-denied",
        provider: "codex",
        projectPath: "/tmp/denied",
      },
      ws,
    );
    await vi.waitFor(() => {
      expect(
        ws.send.mock.calls
          .map((call: unknown[]) => JSON.parse(call[0] as string))
          .find((message: any) => message.type === "archive_result"),
      ).toBeDefined();
    });

    expect(createStandalone).not.toHaveBeenCalled();
    expect(reserveArchiveCapacity).not.toHaveBeenCalled();
    expect(
      ws.send.mock.calls
        .map((call: unknown[]) => JSON.parse(call[0] as string))
        .find((message: any) => message.type === "archive_result"),
    ).toMatchObject({
      sessionId: "codex-thread-denied",
      success: false,
      error: expect.stringContaining("outside the Bridge allowlist"),
    });
    bridge.close();
  });

  it("does not record a local archive marker when Codex rejects writer ownership", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-archive-conflict",
        provider: "codex",
      },
      ws,
    );
    const session = (bridge as any).sessionManager.get("s-1");
    session.process.archiveThread.mockRejectedValue(
      new CodexRpcError(
        "thread/archive",
        "thread codex-thread-1 already has an active writer",
        -32600,
      ),
    );
    const reservation = {
      sessionId: "codex-thread-1",
      provider: "codex",
      identityKey: "codex\0codex-thread-1",
      token: Symbol("archive"),
      alreadyArchived: false,
    };
    const commitReservedArchive = vi.fn(async () => {});
    (bridge as any).archiveStoreReady = Promise.resolve();
    (bridge as any).archiveStoreInitializationError = null;
    (bridge as any).archiveStore = {
      reserveArchiveCapacity: vi.fn(async () => reservation),
      commitReservedArchive,
      releaseArchiveCapacity: vi.fn(async () => {}),
    };

    await (bridge as any).handleClientMessage(
      {
        type: "archive_session",
        sessionId: "codex-thread-1",
        provider: "codex",
        projectPath: "/tmp/project-archive-conflict",
      },
      ws,
    );
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(commitReservedArchive).not.toHaveBeenCalled();
    expect(
      ws.send.mock.calls
        .map((call: unknown[]) => JSON.parse(call[0] as string))
        .find((message: any) => message.type === "archive_result"),
    ).toMatchObject({
      sessionId: "codex-thread-1",
      success: false,
      error:
        "This Codex thread is already open in another client. Close it there and try again.",
    });

    bridge.close();
  });

  it("drops stale project scoped recent session responses after filter refresh", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    let resolveProject:
      ((value: { sessions: any[]; hasMore: boolean }) => void) | undefined;
    let resolveList:
      ((value: { sessions: any[]; hasMore: boolean }) => void) | undefined;
    getAllRecentSessionsMock
      .mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            resolveProject = resolve;
          }),
      )
      .mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            resolveList = resolve;
          }),
      );
    await (bridge as any).archiveStoreReady;

    (bridge as any).handleClientMessage(
      {
        type: "list_recent_sessions",
        limit: 20,
        offset: 0,
        projectPath: "/tmp/project",
        requestScope: "project",
        provider: "claude",
      },
      ws,
    );
    (bridge as any).handleClientMessage(
      {
        type: "list_recent_sessions",
        limit: 20,
        offset: 0,
        provider: "claude",
      },
      ws,
    );

    await vi.waitFor(() => {
      expect(resolveProject).toBeTypeOf("function");
      expect(resolveList).toBeTypeOf("function");
    });

    resolveProject?.({
      sessions: [{ sessionId: "stale", projectPath: "/tmp/project" }],
      hasMore: true,
    });
    await new Promise((resolve) => setTimeout(resolve, 0));
    let recentMessages = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .filter((m: any) => m.type === "recent_sessions");
    expect(recentMessages).toHaveLength(0);

    resolveList?.({
      sessions: [{ sessionId: "fresh", projectPath: "/tmp/project" }],
      hasMore: false,
    });
    await new Promise((resolve) => setTimeout(resolve, 0));
    recentMessages = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .filter((m: any) => m.type === "recent_sessions");
    expect(recentMessages).toHaveLength(1);
    expect(recentMessages[0].sessions[0].sessionId).toBe("fresh");

    bridge.close();
  });

  it("keeps recent session request generations isolated between clients", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    await (bridge as any).archiveStoreReady;
    const wsA = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    const wsB = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    let resolveA:
      ((value: { sessions: any[]; hasMore: boolean }) => void) | undefined;
    let resolveB:
      ((value: { sessions: any[]; hasMore: boolean }) => void) | undefined;
    getAllRecentSessionsMock
      .mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            resolveA = resolve;
          }),
      )
      .mockImplementationOnce(
        () =>
          new Promise((resolve) => {
            resolveB = resolve;
          }),
      );

    (bridge as any).handleClientMessage(
      { type: "list_recent_sessions", provider: "claude" },
      wsA,
    );
    (bridge as any).handleClientMessage(
      { type: "list_recent_sessions", provider: "claude" },
      wsB,
    );
    await vi.waitFor(() => {
      expect(resolveA).toBeDefined();
      expect(resolveB).toBeDefined();
    });

    resolveB?.({ sessions: [{ sessionId: "client-b" }], hasMore: false });
    await new Promise((resolve) => setTimeout(resolve, 0));
    resolveA?.({ sessions: [{ sessionId: "client-a" }], hasMore: false });
    await new Promise((resolve) => setTimeout(resolve, 0));

    const recentFor = (ws: typeof wsA) =>
      ws.send.mock.calls
        .map((call: unknown[]) => JSON.parse(call[0] as string))
        .filter((message: any) => message.type === "recent_sessions");
    expect(recentFor(wsA)).toHaveLength(1);
    expect(recentFor(wsA)[0].sessions[0].sessionId).toBe("client-a");
    expect(recentFor(wsB)).toHaveLength(1);
    expect(recentFor(wsB)[0].sessions[0].sessionId).toBe("client-b");

    bridge.close();
  });

  it("sends codex model list without deprecated models", () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    (bridge as any).codexProfiles = ["ccpocket", "research"];
    (bridge as any).defaultCodexProfile = "ccpocket";

    (bridge as any).sendSessionList(ws);

    const sessionList = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((msg: any) => msg.type === "session_list");

    expect(sessionList.bridgeInstanceId).toBe((bridge as any).bridgeInstanceId);
    expect(sessionList.codexSourceId).toMatch(/^codex-home-[0-9a-f]{24}$/);
    expect(sessionList.bridgeCapabilities).toContain(
      "session_catalog_request_correlation_v1",
    );
    expect(sessionList.bridgeCapabilities).toContain("codex_home_identity_v1");
    expect(sessionList.bridgeCapabilities).toContain(
      "conversation_mirror_source_identity_v1",
    );
    expect(sessionList.codexModels).toEqual([
      "gpt-5.6-sol",
      "gpt-5.6-terra",
      "gpt-5.6-luna",
      "gpt-5.5",
      "gpt-5.4",
      "gpt-5.4-mini",
      "gpt-5.3-codex",
      "gpt-5.3-codex-spark",
    ]);
    expect(sessionList.codexModels).not.toContain("gpt-5.2-codex");
    expect(sessionList.codexModelReasoningEfforts["gpt-5.6-sol"]).toEqual([
      "low",
      "medium",
      "high",
      "xhigh",
      "max",
      "ultra",
    ]);
    expect(sessionList.codexModelReasoningEfforts["gpt-5.6-luna"]).toEqual([
      "low",
      "medium",
      "high",
      "xhigh",
      "max",
    ]);
    expect(sessionList.codexProfiles).toEqual(["ccpocket", "research"]);
    expect(sessionList.defaultCodexProfile).toBe("ccpocket");

    bridge.close();
  });

  it("updates codex model list from app-server model/list", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    const codexProcess = {
      readProfileConfig: vi.fn(async () => ({ profiles: [] })),
      listAvailableModelMetadata: vi.fn(async () => [
        {
          model: "gpt-dynamic-default",
          supportedReasoningEfforts: ["low", "medium", "high"],
        },
        {
          model: "gpt-dynamic-fast",
          supportedReasoningEfforts: ["low"],
        },
      ]),
      stop: vi.fn(),
    };
    vi.spyOn(bridge as any, "createStandaloneCodexProcess").mockResolvedValue(
      codexProcess,
    );

    await (bridge as any).refreshCodexMetadata("/tmp/project-models");
    (bridge as any).sendSessionList(ws);

    const sessionList = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((msg: any) => msg.type === "session_list");

    expect(codexProcess.listAvailableModelMetadata).toHaveBeenCalledTimes(1);
    expect(sessionList.codexModels).toEqual([
      "gpt-dynamic-default",
      "gpt-dynamic-fast",
    ]);
    expect(sessionList.codexModelReasoningEfforts).toEqual({
      "gpt-dynamic-default": ["low", "medium", "high"],
      "gpt-dynamic-fast": ["low"],
    });

    bridge.close();
  });

  it("falls back to built-in codex model list when model/list fails", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    const codexProcess = {
      readProfileConfig: vi.fn(async () => ({ profiles: [] })),
      listAvailableModelMetadata: vi.fn(async () => {
        throw new Error("unsupported method");
      }),
      stop: vi.fn(),
    };
    vi.spyOn(bridge as any, "createStandaloneCodexProcess").mockResolvedValue(
      codexProcess,
    );

    await (bridge as any).refreshCodexMetadata("/tmp/project-models");
    (bridge as any).sendSessionList(ws);

    const sessionList = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((msg: any) => msg.type === "session_list");

    expect(sessionList.codexModels).toEqual([
      "gpt-5.6-sol",
      "gpt-5.6-terra",
      "gpt-5.6-luna",
      "gpt-5.5",
      "gpt-5.4",
      "gpt-5.4-mini",
      "gpt-5.3-codex",
      "gpt-5.3-codex-spark",
    ]);

    bridge.close();
  });

  it("suppresses conversation_queue for clients that did not opt in", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    const msg = {
      type: "conversation_queue",
      sessionId: "s-1",
      limit: 1,
      items: [],
    };

    (bridge as any).send(ws, msg);
    expect(ws.send).not.toHaveBeenCalled();

    await (bridge as any).handleClientMessage(
      {
        type: "client_capabilities",
        supportedServerMessages: ["conversation_queue"],
      },
      ws,
    );
    (bridge as any).send(ws, msg);
    expect(ws.send).toHaveBeenCalledWith(JSON.stringify(msg));

    bridge.close();
  });

  it("capability-gates provider input receipts while keeping legacy input_ack compatible", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    const receipt = {
      type: "input_delivery_status_v1",
      sessionId: "session-1",
      clientMessageId: "mobile-1",
      stage: "provider_accepted",
      provider: "codex",
      method: "turn/start",
      occurredAt: "2026-07-31T00:00:00.000Z",
      acceptedSeq: 1,
      queued: true,
      clientUserMessageIdAccepted: true,
    };

    (bridge as any).send(ws, receipt);
    expect(ws.send).not.toHaveBeenCalled();

    await (bridge as any).handleClientMessage(
      {
        type: "client_capabilities",
        supportedServerMessages: ["input_delivery_status_v1"],
      },
      ws,
    );
    (bridge as any).send(ws, receipt);
    expect(ws.send).toHaveBeenCalledWith(JSON.stringify(receipt));

    bridge.close();
  });

  it("stores mobile host metadata as diagnostics without changing capabilities", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    const mobileRuntime = {
      baseVersion: "1.107.2",
      buildNumber: "198",
      patchNumber: 7,
      hostSchemaVersion: 1,
      nativeCapabilities: { fileTransfer: 2, quickLook: 1 },
    };

    await (bridge as any).handleClientMessage(
      {
        type: "client_capabilities",
        supportedServerMessages: [],
        mobileRuntime,
      },
      ws,
    );

    expect((bridge as any).clientMobileRuntime.get(ws)).toEqual(mobileRuntime);
    expect((bridge as any).clientSupportedServerMessages.get(ws)).toEqual(
      new Set(),
    );
    bridge.close();
  });

  it("suppresses guardian approvals unless the client opts in", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    const msg = {
      type: "guardian_approval",
      risk: "medium",
      reason: "Writes build files outside the workspace.",
    };

    (bridge as any).send(ws, msg);
    expect(ws.send).not.toHaveBeenCalled();

    await (bridge as any).handleClientMessage(
      {
        type: "client_capabilities",
        supportedServerMessages: ["guardian_approval"],
      },
      ws,
    );
    (bridge as any).send(ws, msg);
    expect(ws.send).toHaveBeenCalledWith(JSON.stringify(msg));

    bridge.close();
  });

  it("filters guardian approvals from history for legacy clients", () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    const msg = {
      type: "history_delta",
      fromSeq: 1,
      toSeq: 2,
      messages: [
        { seq: 1, message: { type: "status", status: "running" } },
        {
          seq: 2,
          message: {
            type: "guardian_approval",
            risk: "high",
            reason: "Changes files outside the workspace.",
          },
        },
      ],
    };

    (bridge as any).send(ws, msg);

    expect(ws.send).toHaveBeenCalledWith(
      JSON.stringify({ ...msg, messages: [msg.messages[0]] }),
    );
    bridge.close();
  });

  it("suppresses prompt_history_status for clients that did not opt in", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    const msg = {
      type: "prompt_history_status",
      bridgeInstanceId: "bridge-1",
      revision: 1,
      entryCount: 2,
    };

    (bridge as any).send(ws, msg);
    expect(ws.send).not.toHaveBeenCalled();

    await (bridge as any).handleClientMessage(
      {
        type: "client_capabilities",
        supportedServerMessages: ["prompt_history_status"],
      },
      ws,
    );
    (bridge as any).send(ws, msg);
    expect(ws.send).toHaveBeenCalledWith(JSON.stringify(msg));

    bridge.close();
  });

  it("routes correlated Codex core actions through the local-feature websocket seam", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    // The synthetic process has no rollout file. Declare the ownership fact
    // explicitly so the production fail-closed verifier is not mistaken for
    // a Desktop-owned turn in this core-action routing test.
    (bridge as any).localFeatures.hasExternalCodexActivityVerified = vi.fn(
      async () => false,
    );
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    const sessionId = (bridge as any).sessionManager.create(
      "/tmp/project-core-actions",
      undefined,
      undefined,
      undefined,
      "codex",
      { threadId: "thread-core-actions" },
    );
    const session = (bridge as any).sessionManager.get(sessionId);
    session.process.compactThread = vi.fn(async () => {});
    session.process.startInlineReview = vi.fn(async () => ({
      turnId: "turn-review",
      reviewThreadId: "thread-core-actions",
    }));
    session.process.listMcpServerStatus = vi.fn(async () => ({
      data: [
        {
          name: "filesystem",
          authStatus: "unsupported",
          tools: {},
          serverInfo: null,
        },
      ],
      nextCursor: null,
    }));

    await (bridge as any).handleClientMessage(
      {
        type: "client_capabilities",
        supportedServerMessages: [
          "codex_action_result",
          "codex_mcp_status_result",
        ],
      },
      ws,
    );
    ws.send.mockClear();

    await (bridge as any).handleClientMessage(
      {
        type: "codex_compact_request",
        sessionId,
        requestId: "compact-ws-1",
      },
      ws,
    );
    await (bridge as any).handleClientMessage(
      {
        type: "codex_mcp_status_request",
        sessionId,
        requestId: "mcp-ws-1",
      },
      ws,
    );

    expect(session.process.compactThread).toHaveBeenCalledOnce();
    expect(session.process.listMcpServerStatus).toHaveBeenCalledOnce();
    expect(
      ws.send.mock.calls.map((call: unknown[]) =>
        JSON.parse(call[0] as string),
      ),
    ).toEqual([
      expect.objectContaining({
        type: "codex_action_result",
        sessionId,
        requestId: "compact-ws-1",
        action: "compact",
        status: "accepted",
      }),
      expect.objectContaining({
        type: "codex_mcp_status_result",
        sessionId,
        requestId: "mcp-ws-1",
        status: "completed",
        servers: [
          expect.objectContaining({
            name: "filesystem",
            authStatus: "unsupported",
          }),
        ],
      }),
    ]);

    bridge.close();
  });

  it("queues input and rejects a second action during the core-action ack window", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    (bridge as any).localFeatures.hasExternalCodexActivityVerified = vi.fn(
      async () => false,
    );
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    const sessionId = (bridge as any).sessionManager.create(
      "/tmp/project-core-action-admission",
      undefined,
      undefined,
      undefined,
      "codex",
      { threadId: "thread-core-action-admission" },
    );
    const session = (bridge as any).sessionManager.get(sessionId);
    session.process.sendInputStructured = vi.fn();
    session.process.compactThread = vi.fn(async () => {
      session.process.hasPendingCoreAction = true;
      session.process.isWaitingForInput = false;
    });
    session.process.startInlineReview = vi.fn(async () => ({
      turnId: "turn-review",
      reviewThreadId: "thread-core-action-admission",
    }));
    session.process.listMcpServerStatus = vi.fn(async () => ({
      data: [],
      nextCursor: null,
    }));

    await (bridge as any).handleClientMessage(
      {
        type: "client_capabilities",
        supportedServerMessages: [
          "codex_action_result",
          "codex_mcp_status_result",
        ],
      },
      ws,
    );
    ws.send.mockClear();

    await (bridge as any).handleClientMessage(
      {
        type: "codex_compact_request",
        sessionId,
        requestId: "compact-admission",
      },
      ws,
    );
    await (bridge as any).handleClientMessage(
      {
        type: "codex_review_request",
        sessionId,
        requestId: "review-admission",
        target: { type: "uncommittedChanges" },
      },
      ws,
    );
    await (bridge as any).handleClientMessage(
      {
        type: "input",
        sessionId,
        text: "run after compact",
        clientMessageId: "message-admission",
      },
      ws,
    );
    await (bridge as any).handleClientMessage(
      {
        type: "codex_mcp_status_request",
        sessionId,
        requestId: "mcp-admission",
      },
      ws,
    );

    const admissionMessages = ws.send.mock.calls.map((call: unknown[]) =>
      JSON.parse(call[0] as string),
    );
    expect(admissionMessages).toContainEqual(
      expect.objectContaining({
        type: "codex_action_result",
        requestId: "review-admission",
        status: "rejected",
        errorCode: "session_busy",
      }),
    );
    expect(admissionMessages).toContainEqual(
      expect.objectContaining({
        type: "input_ack",
        clientMessageId: "message-admission",
        queued: true,
      }),
    );
    expect(admissionMessages).not.toContainEqual(
      expect.objectContaining({
        type: "user_input",
        clientMessageId: "message-admission",
      }),
    );
    expect(session.history).toEqual([]);
    expect(session.codexQueuedInput).toMatchObject({
      text: "run after compact",
      clientMessageId: "message-admission",
    });
    expect(session.process.sendInput).not.toHaveBeenCalled();
    expect(session.process.startInlineReview).not.toHaveBeenCalled();
    expect(session.process.listMcpServerStatus).toHaveBeenCalledOnce();

    // Models compaction completing while the normal input-loop resolver is
    // still alive. The process re-announces readiness and the Bridge drains
    // the exact queued next turn without another phone request.
    session.process.hasPendingCoreAction = false;
    session.process.isWaitingForInput = true;
    expect(
      (bridge as any).sessionManager.drainCodexQueuedInputIfReady(sessionId),
    ).toBe(true);
    expect(session.codexQueuedInput).toBeUndefined();
    expect(session.process.sendInputStructured).toHaveBeenCalledWith(
      "run after compact",
      expect.objectContaining({ clientMessageId: "message-admission" }),
    );

    bridge.close();
  });

  it("requires artifact_resolved capability before resolving an artifact", async () => {
    const artifactManager = {
      registerCandidates: vi.fn(async () => []),
      resolve: vi.fn(async () => ({
        artifactId: "artifact-1",
        relativeUrl: "/artifacts/token",
        expiresAt: "2026-07-16T06:00:00.000Z",
      })),
    };
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      artifactManager: artifactManager as any,
    });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    const runtimeSessionId = (bridge as any).sessionManager.create(
      "/tmp/project-artifact-resolve",
      undefined,
      undefined,
      undefined,
      "codex",
      { threadId: "thread-stable-owner" },
    );
    (bridge as any).sessionManager.get(runtimeSessionId).claudeSessionId =
      "thread-stable-owner";

    await (bridge as any).handleClientMessage(
      {
        type: "resolve_artifact",
        requestId: "request-without-capability",
        sessionId: runtimeSessionId,
        messageId: "assistant-message-1",
        artifactId: "artifact-1",
      },
      ws,
    );

    expect(artifactManager.resolve).not.toHaveBeenCalled();
    expect(JSON.parse(ws.send.mock.calls[0][0])).toMatchObject({
      type: "error",
      errorCode: "unsupported_capability",
    });

    bridge.close();
  });

  it("routes artifact success and failure to the requesting client by requestId", async () => {
    const artifactManager = {
      registerCandidates: vi.fn(async () => []),
      resolve: vi
        .fn()
        .mockResolvedValueOnce({
          artifactId: "artifact-1",
          relativeUrl: `/artifacts/${"A".repeat(43)}`,
          expiresAt: "2026-07-16T06:00:00.000Z",
        })
        .mockRejectedValueOnce(
          new ArtifactResolveError(
            404,
            "artifact_not_found",
            "Artifact not found",
          ),
        ),
    };
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      artifactManager: artifactManager as any,
    });
    const requestingWs = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    const unrelatedWs = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    (bridge as any).wss.clients.add(requestingWs);
    (bridge as any).wss.clients.add(unrelatedWs);
    const runtimeSessionId = (bridge as any).sessionManager.create(
      "/tmp/project-artifact-resolve",
      undefined,
      undefined,
      undefined,
      "codex",
      { threadId: "thread-stable-owner" },
    );
    const runtimeSession = (bridge as any).sessionManager.get(runtimeSessionId);
    runtimeSession.claudeSessionId = "thread-stable-owner";
    runtimeSession.worktreePath = "/tmp/project-artifact-resolve-worktree";
    runtimeSession.codexSettings = {
      additionalWritableRoots: ["/tmp/shared-artifact-root"],
    };
    await (bridge as any).handleClientMessage(
      {
        type: "client_capabilities",
        supportedServerMessages: ["artifact_resolved"],
      },
      requestingWs,
    );
    await (bridge as any).handleClientMessage(
      {
        type: "client_capabilities",
        supportedServerMessages: ["artifact_resolved"],
      },
      unrelatedWs,
    );
    requestingWs.send.mockClear();
    unrelatedWs.send.mockClear();

    await (bridge as any).handleClientMessage(
      {
        type: "resolve_artifact",
        requestId: "request-success",
        sessionId: runtimeSessionId,
        messageId: "assistant-message-1",
        artifactId: "artifact-1",
      },
      requestingWs,
    );
    await (bridge as any).handleClientMessage(
      {
        type: "resolve_artifact",
        requestId: "request-failure",
        sessionId: runtimeSessionId,
        messageId: "assistant-message-2",
        artifactId: "artifact-2",
      },
      requestingWs,
    );

    expect(artifactManager.resolve).toHaveBeenNthCalledWith(1, {
      artifactId: "artifact-1",
      ownerId: "thread-stable-owner",
      messageId: "assistant-message-1",
      candidateRoots: [
        "/tmp/project-artifact-resolve-worktree",
        "/tmp/project-artifact-resolve",
        "/tmp/shared-artifact-root",
      ],
    });
    expect(artifactManager.resolve).toHaveBeenNthCalledWith(2, {
      artifactId: "artifact-2",
      ownerId: "thread-stable-owner",
      messageId: "assistant-message-2",
      candidateRoots: [
        "/tmp/project-artifact-resolve-worktree",
        "/tmp/project-artifact-resolve",
        "/tmp/shared-artifact-root",
      ],
    });
    const responses = requestingWs.send.mock.calls.map((call: unknown[]) =>
      JSON.parse(call[0] as string),
    );
    expect(responses).toEqual([
      expect.objectContaining({
        type: "artifact_resolved",
        requestId: "request-success",
        artifactId: "artifact-1",
        relativeUrl: `/artifacts/${"A".repeat(43)}`,
      }),
      expect.objectContaining({
        type: "artifact_resolved",
        requestId: "request-failure",
        artifactId: "artifact-2",
        error: "Artifact not found",
        errorCode: "artifact_not_found",
      }),
    ]);
    expect(unrelatedWs.send).not.toHaveBeenCalled();

    bridge.close();
  });

  it("reads an artifact source from the authorized handle and closes it", async () => {
    const projectPath = mkdtempSync(
      resolve(tmpdir(), "ccpocket-artifact-source-"),
    );
    const sourcePath = resolve(projectPath, "README.md");
    const source = "# Hello\nWorld\nThird\n";
    writeFileSync(sourcePath, source);
    let sourceHandle: Awaited<ReturnType<typeof openFile>> | undefined;
    const artifactManager = {
      registerCandidates: vi.fn(async () => []),
      openAuthorizedSource: vi.fn(async () => {
        sourceHandle = await openFile(sourcePath, "r");
        const stats = await sourceHandle.stat();
        return {
          handle: sourceHandle,
          filename: "README.md",
          mimeType: "text/markdown; charset=utf-8",
          sizeBytes: stats.size,
          identity: {
            dev: stats.dev,
            ino: stats.ino,
            size: stats.size,
            mtimeMs: stats.mtimeMs,
          },
          line: 2,
        };
      }),
    };
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      artifactManager: artifactManager as any,
    });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    const sessionId = (bridge as any).sessionManager.create(
      projectPath,
      undefined,
      undefined,
      undefined,
      "codex",
      { threadId: "thread-source-owner" },
    );
    const session = (bridge as any).sessionManager.get(sessionId);
    session.claudeSessionId = "thread-source-owner";

    try {
      await (bridge as any).handleClientMessage(
        {
          type: "read_artifact_source",
          requestId: "source-read-1",
          sessionId,
          messageId: "assistant-message",
          artifactId: "artifact-source",
          filePath: "README.md",
          maxLines: 2,
        },
        ws,
      );
      await expect.poll(() => ws.send.mock.calls.length).toBeGreaterThan(0);

      expect(artifactManager.openAuthorizedSource).toHaveBeenCalledWith({
        artifactId: "artifact-source",
        ownerId: "thread-source-owner",
        messageId: "assistant-message",
        candidateRoots: [projectPath],
        cwd: projectPath,
        projectRelativePath: "README.md",
      });
      expect(JSON.parse(ws.send.mock.calls[0][0])).toEqual({
        type: "file_content",
        requestId: "source-read-1",
        filePath: "README.md",
        kind: "text",
        content: "# Hello\nWorld",
        language: "markdown",
        totalLines: 4,
        truncated: true,
        sizeBytes: Buffer.byteLength(source),
      });
      await expect
        .poll(async () => {
          try {
            await sourceHandle?.stat();
            return false;
          } catch {
            return true;
          }
        })
        .toBe(true);
    } finally {
      await sourceHandle?.close().catch(() => undefined);
      bridge.close();
      rmSync(projectPath, { recursive: true, force: true });
    }
  });

  it("limits artifact source reads to one active request per client", async () => {
    let rejectOpen!: (error: Error) => void;
    const pendingOpen = new Promise<never>((_resolve, reject) => {
      rejectOpen = reject;
    });
    const artifactManager = {
      registerCandidates: vi.fn(async () => []),
      openAuthorizedSource: vi.fn(() => pendingOpen),
    };
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      artifactManager: artifactManager as any,
    });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    const sessionId = (bridge as any).sessionManager.create(
      "/tmp/project-artifact-source-limit",
      undefined,
      undefined,
      undefined,
      "codex",
      { threadId: "thread-source-limit" },
    );
    const session = (bridge as any).sessionManager.get(sessionId);
    session.claudeSessionId = "thread-source-limit";

    const message = (requestId: string) => ({
      type: "read_artifact_source",
      requestId,
      sessionId,
      messageId: "assistant-message",
      artifactId: "artifact-source",
      filePath: "README.md",
    });

    try {
      await (bridge as any).handleClientMessage(message("source-read-1"), ws);
      await (bridge as any).handleClientMessage(message("source-read-2"), ws);

      expect(artifactManager.openAuthorizedSource).toHaveBeenCalledTimes(1);
      expect(JSON.parse(ws.send.mock.calls[0][0])).toEqual({
        type: "file_content",
        requestId: "source-read-2",
        filePath: "README.md",
        content: "",
        error: "Another artifact source read is already in progress.",
        errorCode: "artifact_source_busy",
      });
    } finally {
      rejectOpen(new Error("test cleanup"));
      await expect.poll(() => ws.send.mock.calls.length).toBeGreaterThan(1);
      bridge.close();
    }
  });

  it("returns correlated artifact source authorization errors", async () => {
    const artifactManager = {
      registerCandidates: vi.fn(async () => []),
      openAuthorizedSource: vi
        .fn()
        .mockRejectedValueOnce(
          new ArtifactResolveError(
            404,
            "artifact_not_found",
            "Artifact not found",
          ),
        )
        .mockRejectedValueOnce(
          new ArtifactResolveError(
            409,
            "source_path_mismatch",
            "Artifact source path does not match",
          ),
        )
        .mockRejectedValueOnce(
          new ArtifactResolveError(
            409,
            "file_changed",
            "Artifact file changed",
          ),
        ),
    };
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      artifactManager: artifactManager as any,
    });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    const sessionId = (bridge as any).sessionManager.create(
      "/tmp/project-artifact-source-errors",
      undefined,
      undefined,
      undefined,
      "codex",
      { threadId: "thread-source-owner" },
    );
    (bridge as any).sessionManager.get(sessionId).claudeSessionId =
      "thread-source-owner";

    for (const [index, artifactId] of [
      "wrong-owner-artifact",
      "wrong-path-artifact",
      "changed-artifact",
    ].entries()) {
      await (bridge as any).handleClientMessage(
        {
          type: "read_artifact_source",
          requestId: `source-error-${index}`,
          sessionId,
          messageId: "assistant-message",
          artifactId,
          filePath: "src/main.ts",
        },
        ws,
      );
      await expect.poll(() => ws.send.mock.calls.length).toBe(index + 1);
    }
    expect(
      ws.send.mock.calls.map((call: unknown[]) =>
        JSON.parse(call[0] as string),
      ),
    ).toEqual([
      expect.objectContaining({
        type: "file_content",
        requestId: "source-error-0",
        errorCode: "artifact_not_found",
      }),
      expect.objectContaining({
        type: "file_content",
        requestId: "source-error-1",
        errorCode: "source_path_mismatch",
      }),
      expect.objectContaining({
        type: "file_content",
        requestId: "source-error-2",
        errorCode: "file_changed",
      }),
    ]);
    bridge.close();
  });

  it("fails artifact source reads safely when unavailable, changed, or oversized", async () => {
    const projectPath = mkdtempSync(
      resolve(tmpdir(), "ccpocket-artifact-source-limits-"),
    );
    const sourcePath = resolve(projectPath, "source.ts");
    writeFileSync(sourcePath, "same-size");
    const changedHandle = await openFile(sourcePath, "r");
    const changedStats = await changedHandle.stat();
    const oversizedClose = vi.fn(async () => undefined);
    const artifactManager = {
      registerCandidates: vi.fn(async () => []),
      openAuthorizedSource: vi
        .fn()
        .mockResolvedValueOnce({
          handle: changedHandle,
          filename: "source.ts",
          mimeType: "text/typescript",
          sizeBytes: changedStats.size,
          identity: {
            dev: changedStats.dev,
            ino: changedStats.ino,
            size: changedStats.size,
            mtimeMs: changedStats.mtimeMs - 1000,
          },
        })
        .mockResolvedValueOnce({
          handle: { close: oversizedClose },
          filename: "huge.ts",
          mimeType: "text/typescript",
          sizeBytes: 8 * 1024 * 1024 + 1,
          identity: { dev: 1, ino: 1, size: 8 * 1024 * 1024 + 1, mtimeMs: 1 },
        }),
    };
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      artifactManager: artifactManager as any,
    });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    const sessionId = (bridge as any).sessionManager.create(
      projectPath,
      undefined,
      undefined,
      undefined,
      "codex",
      { threadId: "thread-source-owner" },
    );
    (bridge as any).sessionManager.get(sessionId).claudeSessionId =
      "thread-source-owner";

    try {
      for (const [index, artifactId] of ["changed", "oversized"].entries()) {
        await (bridge as any).handleClientMessage(
          {
            type: "read_artifact_source",
            requestId: `source-limit-${index}`,
            sessionId,
            messageId: "assistant-message",
            artifactId,
            filePath: "source.ts",
          },
          ws,
        );
        await expect.poll(() => ws.send.mock.calls.length).toBe(index + 1);
      }
      const responses = ws.send.mock.calls.map((call: unknown[]) =>
        JSON.parse(call[0] as string),
      );
      expect(
        responses.find(
          (response: any) => response.requestId === "source-limit-0",
        ),
      ).toMatchObject({
        requestId: "source-limit-0",
        errorCode: "file_changed",
        content: "",
      });
      expect(
        responses.find(
          (response: any) => response.requestId === "source-limit-1",
        ),
      ).toMatchObject({
        requestId: "source-limit-1",
        errorCode: "file_too_large",
        content: "",
      });
      await expect.poll(() => oversizedClose.mock.calls.length).toBe(1);
    } finally {
      await changedHandle.close().catch(() => undefined);
      bridge.close();
      rmSync(projectPath, { recursive: true, force: true });
    }

    const noManagerBridge = new BridgeWebSocketServer({ server: httpServer });
    const noManagerWs = { readyState: OPEN_STATE, send: vi.fn() } as any;
    const noManagerSession = (noManagerBridge as any).sessionManager.create(
      "/tmp/project-no-artifacts",
      undefined,
      undefined,
      undefined,
      "codex",
      { threadId: "thread-no-artifacts" },
    );
    (noManagerBridge as any).sessionManager.get(
      noManagerSession,
    ).claudeSessionId = "thread-no-artifacts";
    await (noManagerBridge as any).handleClientMessage(
      {
        type: "read_artifact_source",
        requestId: "source-unavailable",
        sessionId: noManagerSession,
        messageId: "assistant-message",
        artifactId: "artifact",
        filePath: "source.ts",
      },
      noManagerWs,
    );
    expect(JSON.parse(noManagerWs.send.mock.calls[0][0])).toMatchObject({
      requestId: "source-unavailable",
      errorCode: "artifact_unavailable",
    });
    noManagerBridge.close();
  });

  it("reads artifact source images from the authorized handle", async () => {
    const projectPath = mkdtempSync(
      resolve(tmpdir(), "ccpocket-artifact-source-image-"),
    );
    const pngBase64 =
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";
    const imagePath = resolve(projectPath, "pixel.png");
    writeFileSync(imagePath, Buffer.from(pngBase64, "base64"));
    let imageHandle: Awaited<ReturnType<typeof openFile>> | undefined;
    const artifactManager = {
      registerCandidates: vi.fn(async () => []),
      openAuthorizedSource: vi.fn(async () => {
        imageHandle = await openFile(imagePath, "r");
        const stats = await imageHandle.stat();
        return {
          handle: imageHandle,
          filename: "pixel.png",
          mimeType: "image/png",
          sizeBytes: stats.size,
          identity: {
            dev: stats.dev,
            ino: stats.ino,
            size: stats.size,
            mtimeMs: stats.mtimeMs,
          },
        };
      }),
    };
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      artifactManager: artifactManager as any,
    });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    const sessionId = (bridge as any).sessionManager.create(
      projectPath,
      undefined,
      undefined,
      undefined,
      "codex",
      { threadId: "thread-image-owner" },
    );
    (bridge as any).sessionManager.get(sessionId).claudeSessionId =
      "thread-image-owner";

    try {
      await (bridge as any).handleClientMessage(
        {
          type: "read_artifact_source",
          requestId: "source-image-1",
          sessionId,
          messageId: "assistant-message",
          artifactId: "artifact-image",
          filePath: "pixel.png",
        },
        ws,
      );
      await expect.poll(() => ws.send.mock.calls.length).toBe(1);
      expect(JSON.parse(ws.send.mock.calls[0][0])).toMatchObject({
        type: "file_content",
        requestId: "source-image-1",
        filePath: "pixel.png",
        kind: "image",
        base64: pngBase64,
        mimeType: "image/png",
      });
    } finally {
      await imageHandle?.close().catch(() => undefined);
      bridge.close();
      rmSync(projectPath, { recursive: true, force: true });
    }
  });

  it("limits file list payloads and reports truncation", async () => {
    const repo = mkdtempSync(resolve(tmpdir(), "ccpocket-file-list-"));
    try {
      execFileSync("git", ["init"], { cwd: repo });
      writeFileSync(resolve(repo, "a.ts"), "a\n");
      writeFileSync(resolve(repo, "b.ts"), "b\n");
      writeFileSync(resolve(repo, "c.ts"), "c\n");
      const bridge = new BridgeWebSocketServer({
        server: httpServer,
        fileListMaxEntries: 2,
        fileListMaxBytes: 1024,
      });
      const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;

      await (bridge as any).handleClientMessage(
        { type: "list_files", projectPath: repo, requestId: "files-1" },
        ws,
      );
      for (let i = 0; i < 50 && ws.send.mock.calls.length === 0; i++) {
        await new Promise((resolvePromise) => setTimeout(resolvePromise, 10));
      }

      const message = ws.send.mock.calls
        .map((call: unknown[]) => JSON.parse(call[0] as string))
        .find((sent: { type: string }) => sent.type === "file_list");
      expect(message).toMatchObject({
        type: "file_list",
        requestId: "files-1",
        projectPath: repo,
        truncated: true,
      });
      expect(message.files).toHaveLength(2);
      expect(message.totalFiles).toBeUndefined();
      bridge.close();
    } finally {
      rmSync(repo, { recursive: true, force: true });
    }
  });

  it("returns terminal git results when a project path is denied", async () => {
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      allowedDirs: ["/tmp/allowed"],
    });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "get_diff",
        projectPath: "/tmp/denied",
        requestId: "diff-denied",
      },
      ws,
    );
    await (bridge as any).handleClientMessage(
      {
        type: "git_stage",
        projectPath: "/tmp/denied",
        files: ["a.ts"],
      },
      ws,
    );
    await (bridge as any).handleClientMessage(
      {
        type: "git_fetch",
        projectPath: "/tmp/denied",
      },
      ws,
    );
    await (bridge as any).handleClientMessage(
      {
        type: "git_remote_status",
        projectPath: "/tmp/denied",
      },
      ws,
    );

    const messages = ws.send.mock.calls.map((call: unknown[]) =>
      JSON.parse(call[0] as string),
    );
    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "diff_result",
        requestId: "diff-denied",
        errorCode: "path_not_allowed",
      }),
    );
    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "git_stage_result",
        success: false,
        projectPath: "/tmp/denied",
      }),
    );
    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "git_fetch_result",
        success: false,
        projectPath: "/tmp/denied",
      }),
    );
    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "git_remote_status_result",
        projectPath: "/tmp/denied",
        errorCode: "path_not_allowed",
        error: expect.stringContaining("not in the allowed directories"),
      }),
    );
    expect(messages.some((message) => message.type === "error")).toBe(false);
    bridge.close();
  });

  it("rejects project symlinks that escape a restricted allowed root", async () => {
    const root = mkdtempSync(resolve(tmpdir(), "ccpocket-project-scope-"));
    const allowedRoot = resolve(root, "allowed");
    const outsideProject = resolve(root, "outside-project");
    const linkedProject = resolve(allowedRoot, "linked-project");
    mkdirSync(allowedRoot);
    mkdirSync(outsideProject);
    execFileSync("git", ["init", outsideProject]);
    symlinkSync(outsideProject, linkedProject);

    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      allowedDirs: [allowedRoot],
    });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    const create = vi.spyOn((bridge as any).sessionManager, "create");

    try {
      await (bridge as any).handleClientMessage(
        {
          type: "start",
          projectPath: linkedProject,
          provider: "codex",
          startRequestId: "start-symlink-escape",
        },
        ws,
      );
      await (bridge as any).handleClientMessage(
        {
          type: "get_diff",
          projectPath: linkedProject,
          requestId: "diff-symlink-escape",
        },
        ws,
      );

      const messages = ws.send.mock.calls.map((call: unknown[]) =>
        JSON.parse(call[0] as string),
      );
      expect(create).not.toHaveBeenCalled();
      expect(messages).toContainEqual(
        expect.objectContaining({
          type: "system",
          subtype: "session_start_failed",
          startRequestId: "start-symlink-escape",
          errorMessage: expect.stringContaining(
            "not in the allowed directories",
          ),
        }),
      );
      expect(messages).toContainEqual(
        expect.objectContaining({
          type: "diff_result",
          requestId: "diff-symlink-escape",
          errorCode: "path_not_allowed",
        }),
      );
    } finally {
      bridge.close();
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("refreshes connection metadata initially and after the cooldown", () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const refreshCodexMetadata = vi
      .spyOn(bridge as any, "refreshCodexMetadata")
      .mockResolvedValue(undefined);
    const refreshClaudeModels = vi
      .spyOn(bridge as any, "refreshClaudeModels")
      .mockResolvedValue(undefined);

    (bridge as any).refreshConnectionMetadata(1_000);
    (bridge as any).refreshConnectionMetadata(2_000);
    (bridge as any).refreshConnectionMetadata(301_000);

    expect(refreshCodexMetadata).toHaveBeenCalledTimes(2);
    expect(refreshClaudeModels).toHaveBeenCalledTimes(2);
    bridge.close();
  });

  it("loads codex profiles and models with one standalone process", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const codexProcess = {
      readProfileConfig: vi.fn().mockResolvedValue({
        profiles: ["ccpocket"],
        defaultProfile: "ccpocket",
      }),
      listAvailableModelMetadata: vi.fn().mockResolvedValue([
        {
          model: "gpt-test",
          supportedReasoningEfforts: ["high"],
        },
      ]),
      readConfigRequirements: vi.fn().mockResolvedValue({
        autoReviewDisabled: true,
      }),
      stop: vi.fn(),
    };
    const createStandalone = vi
      .spyOn(bridge as any, "createStandaloneCodexProcess")
      .mockResolvedValue(codexProcess);
    vi.spyOn(bridge as any, "broadcastSessionList").mockImplementation(
      () => {},
    );

    await (bridge as any).refreshCodexMetadata("/tmp/project-a");

    expect(createStandalone).toHaveBeenCalledTimes(1);
    expect(codexProcess.readProfileConfig).toHaveBeenCalledWith(
      "/tmp/project-a",
    );
    expect(codexProcess.listAvailableModelMetadata).toHaveBeenCalledTimes(1);
    expect(codexProcess.readConfigRequirements).toHaveBeenCalledTimes(1);
    expect(codexProcess.stop).toHaveBeenCalledTimes(1);
    expect((bridge as any).codexProfiles).toEqual(["ccpocket"]);
    expect((bridge as any).codexModels).toEqual(["gpt-test"]);
    expect((bridge as any).codexAutoReviewDisabled).toBe(true);
    expect((bridge as any).codexAutoReviewPolicyLoaded).toBe(true);
    bridge.close();
  });

  it("keeps codex models when profile metadata fails", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const codexProcess = {
      readProfileConfig: vi.fn().mockRejectedValue(new Error("profile failed")),
      listAvailableModelMetadata: vi.fn().mockResolvedValue([
        {
          model: "gpt-test",
          supportedReasoningEfforts: ["medium"],
        },
      ]),
      stop: vi.fn(),
    };
    vi.spyOn(bridge as any, "createStandaloneCodexProcess").mockResolvedValue(
      codexProcess,
    );
    vi.spyOn(bridge as any, "broadcastSessionList").mockImplementation(
      () => {},
    );

    await (bridge as any).refreshCodexMetadata();

    expect((bridge as any).codexProfiles).toEqual([]);
    expect((bridge as any).codexModels).toEqual(["gpt-test"]);
    expect(codexProcess.stop).toHaveBeenCalledTimes(1);
    bridge.close();
  });

  it("runs a project metadata refresh after an in-flight connect refresh", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    let releaseFirst!: () => void;
    const firstGate = new Promise<void>((resolvePromise) => {
      releaseFirst = resolvePromise;
    });
    const paths: Array<string | undefined> = [];
    vi.spyOn(bridge as any, "loadAndApplyCodexMetadata").mockImplementation(
      async (projectPath?: string) => {
        paths.push(projectPath);
        if (paths.length === 1) await firstGate;
      },
    );

    const connectRefresh = (bridge as any).refreshCodexMetadata();
    const projectRefresh = (bridge as any).refreshCodexMetadata(
      "/tmp/project-a",
    );
    await Promise.resolve();
    expect(paths).toEqual([undefined]);

    releaseFirst();
    await Promise.all([connectRefresh, projectRefresh]);
    expect(paths).toEqual([undefined, "/tmp/project-a"]);
    bridge.close();
  });

  it("stops a standalone codex process when initialization fails", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const initializeOnly = vi
      .spyOn(CodexProcess.prototype, "initializeOnly")
      .mockRejectedValueOnce(new Error("initialize failed"));
    const stop = vi
      .spyOn(CodexProcess.prototype, "stop")
      .mockImplementation(() => {});
    try {
      await expect(
        (bridge as any).createStandaloneCodexProcess("/tmp/project-a"),
      ).rejects.toThrow("initialize failed");
      expect(initializeOnly).toHaveBeenCalledWith("/tmp/project-a");
      expect(stop).toHaveBeenCalledTimes(1);
    } finally {
      initializeOnly.mockRestore();
      stop.mockRestore();
      bridge.close();
    }
  });

  it("boots project-agnostic Codex readers from the configured authority root", async () => {
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      allowedDirs: ["/Users/test/allowed-root"],
    });
    const initializeOnly = vi
      .spyOn(CodexProcess.prototype, "initializeOnly")
      .mockResolvedValue(undefined);
    const stop = vi
      .spyOn(CodexProcess.prototype, "stop")
      .mockImplementation(() => {});
    try {
      const process = await (bridge as any).createStandaloneCodexProcess(
        undefined,
        15_000,
      );

      expect(initializeOnly).toHaveBeenCalledWith(
        "/Users/test/allowed-root",
        15_000,
      );
      process.stop();
    } finally {
      initializeOnly.mockRestore();
      stop.mockRestore();
      bridge.close();
    }
  });

  it("keeps standalone and legacy side-chat Codex processes behind the live shared writer fence", async () => {
    vi.stubEnv("BRIDGE_CODEX_APP_SERVER_MODE", "daemon");
    const health: CodexActionBrokerRuntimeHealth = {
      ready: true,
      controlReady: true,
      degraded: false,
      writerLeaseHeld: true,
      authorityGeneration: "cab:writer:1",
    };
    const actionRuntime = {
      get health() {
        return health;
      },
      listRequests: vi.fn(() => []),
      currentRequestForThread: vi.fn(),
      respond: vi.fn(async () => ({ outcome: "unavailable" as const })),
      subscribe: vi.fn(() => () => undefined),
    } as unknown as CodexActionBrokerRuntime;
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      codexActionBrokerRuntime: actionRuntime,
    });
    const initializeOnly = vi
      .spyOn(CodexProcess.prototype, "initializeOnly")
      .mockResolvedValue(undefined);
    const stop = vi
      .spyOn(CodexProcess.prototype, "stop")
      .mockImplementation(() => {});
    try {
      const standalone = await (bridge as any).createStandaloneCodexProcess(
        "/tmp/project-a",
      );
      const dedicated = (
        bridge as any
      ).localFeatures.runtime.createDedicatedCodexProcess() as CodexProcess;

      expect((standalone as any).sharedRuntimeMutationAllowed()).toBe(true);
      expect((dedicated as any).sharedRuntimeMutationAllowed()).toBe(true);

      Object.assign(health, {
        ready: false,
        writerLeaseHeld: false,
        degradedReason: "writer_lease_unavailable",
      });
      delete (health as { authorityGeneration?: string }).authorityGeneration;

      await expect(
        standalone.renameThreadById("thread-a", "renamed"),
      ).rejects.toMatchObject({
        name: "CodexSharedRuntimeWriterUnavailableError",
        method: "thread/name/set",
      });
      await expect(
        dedicated.renameThreadById("thread-side-chat", "renamed"),
      ).rejects.toMatchObject({
        name: "CodexSharedRuntimeWriterUnavailableError",
        method: "thread/name/set",
      });
    } finally {
      initializeOnly.mockRestore();
      stop.mockRestore();
      await bridge.close();
    }
  });

  it("rejects start when selected codex profile does not exist", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    vi.spyOn(bridge as any, "validateCodexProfile").mockResolvedValue(false);

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-a",
        provider: "codex",
        profile: "missing",
        startRequestId: "start-request-missing-profile",
      },
      ws,
    );

    await Promise.resolve();

    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    expect(sends).toContainEqual(
      expect.objectContaining({
        type: "error",
        message: "Codex profile not found: missing",
      }),
    );
    expect(sends).toContainEqual(
      expect.objectContaining({
        type: "system",
        subtype: "session_start_failed",
        startRequestId: "start-request-missing-profile",
        errorMessage: "Codex profile not found: missing",
      }),
    );

    bridge.close();
  });

  it("forwards selected codex profile on start", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    vi.spyOn(bridge as any, "validateCodexProfile").mockResolvedValue(true);

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-a",
        provider: "codex",
        profile: "ccpocket",
      },
      ws,
    );

    await Promise.resolve();

    const session = (bridge as any).sessionManager.get("s-1");
    expect(session.codexOptions).toMatchObject({
      profile: "ccpocket",
    });

    bridge.close();
  });

  it("refreshes codex metadata after a codex session starts", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    const refreshCodexMetadata = vi
      .spyOn(bridge as any, "refreshCodexMetadata")
      .mockResolvedValue(undefined);

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-a",
        provider: "codex",
      },
      ws,
    );
    await Promise.resolve();
    await Promise.resolve();

    expect(refreshCodexMetadata).toHaveBeenCalledWith(
      resolve("/tmp/project-a"),
    );
    bridge.close();
  });

  it("normalizes and forwards additional writable roots on codex start", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-a",
        provider: "codex",
        additionalWritableRoots: ["../shared", "/tmp/project-a/../shared"],
      },
      ws,
    );

    await Promise.resolve();

    const session = (bridge as any).sessionManager.get("s-1");
    expect(session.codexOptions).toMatchObject({
      additionalWritableRoots: [resolve("/tmp/shared")],
    });

    bridge.close();
  });

  it("rejects additional writable roots outside bridge allowed directories", async () => {
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      allowedDirs: ["/tmp/project-a"],
    });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-a",
        provider: "codex",
        additionalWritableRoots: ["/tmp/other"],
        startRequestId: "start-request-denied-root",
      },
      ws,
    );

    await Promise.resolve();

    expect((bridge as any).sessionManager.get("s-1")).toBeUndefined();
    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    expect(sends).toContainEqual(
      expect.objectContaining({
        type: "error",
        errorCode: "path_not_allowed",
      }),
    );
    expect(sends).toContainEqual(
      expect.objectContaining({
        type: "system",
        subtype: "session_start_failed",
        startRequestId: "start-request-denied-root",
        errorMessage: expect.stringContaining("not in the allowed directories"),
      }),
    );

    bridge.close();
  });

  it("rejects an additional writable root whose symlink escapes allowed directories", async () => {
    const root = mkdtempSync(resolve(tmpdir(), "ccpocket-writable-scope-"));
    const allowedRoot = resolve(root, "allowed");
    const projectPath = resolve(allowedRoot, "project");
    const outsideRoot = resolve(root, "outside");
    const linkedRoot = resolve(allowedRoot, "linked-writable");
    mkdirSync(projectPath, { recursive: true });
    mkdirSync(outsideRoot);
    symlinkSync(outsideRoot, linkedRoot);

    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      allowedDirs: [allowedRoot],
    });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    const create = vi.spyOn((bridge as any).sessionManager, "create");

    try {
      await (bridge as any).handleClientMessage(
        {
          type: "start",
          projectPath,
          provider: "codex",
          additionalWritableRoots: [linkedRoot],
          startRequestId: "start-linked-writable-root",
        },
        ws,
      );

      expect(create).not.toHaveBeenCalled();
      expect(
        ws.send.mock.calls
          .map((call: unknown[]) => JSON.parse(call[0] as string))
          .find(
            (message: any) =>
              message.type === "system" &&
              message.subtype === "session_start_failed",
          ),
      ).toMatchObject({
        startRequestId: "start-linked-writable-root",
        errorMessage: expect.stringContaining("not in the allowed directories"),
      });
    } finally {
      bridge.close();
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("rejects a client-supplied worktree outside allowed directories", async () => {
    const root = mkdtempSync(resolve(tmpdir(), "ccpocket-worktree-scope-"));
    const allowedRoot = resolve(root, "allowed");
    const projectPath = resolve(allowedRoot, "project");
    const outsideWorktree = resolve(root, "outside-worktree");
    mkdirSync(projectPath, { recursive: true });
    mkdirSync(outsideWorktree);

    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      allowedDirs: [allowedRoot],
    });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    const create = vi.spyOn((bridge as any).sessionManager, "create");

    try {
      await (bridge as any).handleClientMessage(
        {
          type: "start",
          projectPath,
          provider: "codex",
          existingWorktreePath: outsideWorktree,
          startRequestId: "start-outside-worktree",
        },
        ws,
      );

      expect(create).not.toHaveBeenCalled();
      expect(
        ws.send.mock.calls
          .map((call: unknown[]) => JSON.parse(call[0] as string))
          .find(
            (message: any) =>
              message.type === "system" &&
              message.subtype === "session_start_failed",
          ),
      ).toMatchObject({
        startRequestId: "start-outside-worktree",
        errorMessage: expect.stringContaining("not in the allowed directories"),
      });
    } finally {
      bridge.close();
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("forwards selected codex profile on resume", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    vi.spyOn(bridge as any, "loadCodexProfiles").mockResolvedValue({
      profiles: ["ccpocket"],
      defaultProfile: "ccpocket",
    });

    await (bridge as any).handleClientMessage(
      {
        type: "resume_session",
        sessionId: "thr_123",
        projectPath: "/tmp/project-a",
        provider: "codex",
        profile: "ccpocket",
      },
      ws,
    );

    await Promise.resolve();
    await Promise.resolve();

    const session = (bridge as any).sessionManager.get("s-1");
    expect(session.codexOptions).toMatchObject({
      threadId: "thr_123",
      profile: "ccpocket",
    });

    bridge.close();
  });

  it("falls back to the default codex profile on resume when the saved profile no longer exists", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    vi.spyOn(bridge as any, "loadCodexProfiles").mockResolvedValue({
      profiles: ["ccpocket"],
      defaultProfile: "ccpocket",
    });

    await (bridge as any).handleClientMessage(
      {
        type: "resume_session",
        sessionId: "thr_123",
        projectPath: "/tmp/project-a",
        provider: "codex",
        profile: "research",
      },
      ws,
    );

    await Promise.resolve();
    await Promise.resolve();

    const session = (bridge as any).sessionManager.get("s-1");
    expect(session.codexOptions).toMatchObject({
      threadId: "thr_123",
      profile: "ccpocket",
    });
    expect(saveCodexSessionProfileMock).toHaveBeenCalledWith(
      "thr_123",
      "ccpocket",
    );
    expect(ws.send).not.toHaveBeenCalledWith(
      expect.stringContaining("Codex profile not found"),
    );

    bridge.close();
  });

  it("forwards additional writable roots on codex resume", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "resume_session",
        sessionId: "thr_123",
        projectPath: "/tmp/project-a",
        provider: "codex",
        additionalWritableRoots: ["/tmp/shared"],
      },
      ws,
    );

    await Promise.resolve();
    await Promise.resolve();

    const session = (bridge as any).sessionManager.get("s-1");
    expect(session.codexOptions).toMatchObject({
      threadId: "thr_123",
      additionalWritableRoots: [resolve("/tmp/shared")],
    });

    bridge.close();
  });

  it("preserves indexed Codex settings when a direct resume omits overrides", async () => {
    getCodexSessionIndexMetadataMock.mockResolvedValueOnce(
      new Map([
        [
          "thr_preserve_settings",
          {
            forkedFromThreadId: "thr_parent",
            codexSettings: {
              profile: "ccpocket",
              model: "gpt-5.6-sol",
              modelReasoningEffort: "ultra",
              serviceTier: "fast",
              approvalPolicy: "never",
              approvalsReviewer: "user",
              sandboxMode: "danger-full-access",
              networkAccessEnabled: true,
              webSearchMode: "live",
              additionalWritableRoots: ["/tmp/shared"],
            },
          },
        ],
      ]),
    );
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    vi.spyOn(bridge as any, "loadCodexProfiles").mockResolvedValue({
      profiles: ["ccpocket"],
      defaultProfile: "ccpocket",
    });

    await (bridge as any).handleClientMessage(
      {
        type: "resume_session",
        sessionId: "thr_preserve_settings",
        projectPath: "/tmp/project-a",
        provider: "codex",
      },
      ws,
    );

    expect(getCodexSessionIndexMetadataMock).toHaveBeenCalledWith(
      ["thr_preserve_settings"],
      { authoritativeCodexSettings: true },
    );
    const session = (bridge as any).sessionManager.get("s-1");
    expect(session.codexOptions).toMatchObject({
      threadId: "thr_preserve_settings",
      profile: "ccpocket",
      model: "gpt-5.6-sol",
      modelReasoningEffort: "ultra",
      serviceTier: "fast",
      approvalPolicy: "never",
      approvalsReviewer: "user",
      sandboxMode: "danger-full-access",
      networkAccessEnabled: true,
      webSearchMode: "live",
      additionalWritableRoots: [resolve("/tmp/shared")],
    });
    expect(session.forkedFromThreadId).toBe("thr_parent");
    const resumed = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find(
        (message: any) =>
          message.type === "system" &&
          message.subtype === "session_created" &&
          message.sessionId === session.id,
      );
    expect(resumed.forkedFromThreadId).toBe("thr_parent");

    bridge.close();
  });

  it("leaves missing Codex resume permissions to the official runtime", async () => {
    getCodexSessionIndexMetadataMock.mockResolvedValueOnce(new Map());
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "resume_session",
        sessionId: "thr_runtime_owned_permissions",
        projectPath: "/tmp/project-a",
        provider: "codex",
      },
      ws,
    );

    const session = (bridge as any).sessionManager.get("s-1");
    expect(session.codexOptions).toMatchObject({
      threadId: "thr_runtime_owned_permissions",
    });
    expect(session.codexOptions.approvalPolicy).toBeUndefined();
    expect(session.codexOptions.sandboxMode).toBeUndefined();

    const resumed = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find(
        (message: any) =>
          message.type === "system" &&
          message.subtype === "session_created" &&
          message.sessionId === session.id,
      );
    expect(resumed.permissionMode).toBeUndefined();
    expect(resumed.executionMode).toBeUndefined();
    expect(resumed.approvalPolicy).toBeUndefined();
    expect(resumed.sandboxMode).toBeUndefined();

    bridge.close();
  });

  it("keeps explicit legacy Mobile resume overrides ahead of indexed settings", async () => {
    getCodexSessionIndexMetadataMock.mockResolvedValueOnce(
      new Map([
        [
          "thr_legacy_overrides",
          {
            codexSettings: {
              model: "gpt-5.6-sol",
              serviceTier: "fast",
              approvalPolicy: "never",
              sandboxMode: "danger-full-access",
            },
          },
        ],
      ]),
    );
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "resume_session",
        sessionId: "thr_legacy_overrides",
        projectPath: "/tmp/project-a",
        provider: "codex",
        model: "gpt-5.5",
        serviceTier: "standard",
        approvalPolicy: "on-request",
        sandboxMode: "workspace-write",
      },
      ws,
    );

    const session = (bridge as any).sessionManager.get("s-1");
    expect(session.codexOptions).toMatchObject({
      model: "gpt-5.5",
      serviceTier: "standard",
      approvalPolicy: "on-request",
      sandboxMode: "workspace-write",
    });

    bridge.close();
  });

  it("reuses an already running Codex provider thread across clients", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const wsA = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    const wsB = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    const manager = (bridge as any).sessionManager;
    const create = vi.spyOn(manager, "create");
    const request = {
      type: "resume_session",
      sessionId: "thr_running_once",
      projectPath: "/tmp/project-a",
      provider: "codex",
    };

    await (bridge as any).handleClientMessage(request, wsA);
    await (bridge as any).handleClientMessage(request, wsB);

    expect(create).toHaveBeenCalledTimes(1);
    expect(getCodexSessionHistoryMock).toHaveBeenCalledTimes(1);
    const createdFor = (ws: typeof wsA) =>
      ws.send.mock.calls
        .map((call: unknown[]) => JSON.parse(call[0] as string))
        .find(
          (message: any) =>
            message.type === "system" && message.subtype === "session_created",
        );
    expect(createdFor(wsA)?.sessionId).toBe("s-1");
    expect(createdFor(wsB)?.sessionId).toBe("s-1");
    expect(createdFor(wsB)?.claudeSessionId).toBe("thr_running_once");

    bridge.close();
  });

  it("does not attach a Codex resume to a stopped provider runtime", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    const manager = (bridge as any).sessionManager;
    const create = vi.spyOn(manager, "create");
    const request = {
      type: "resume_session",
      sessionId: "thr_restart_stopped",
      projectPath: "/tmp/project-a",
      provider: "codex",
    };

    await (bridge as any).handleClientMessage(request, ws);
    manager.get("s-1").process.isRunning = false;
    await (bridge as any).handleClientMessage(request, ws);

    expect(create).toHaveBeenCalledTimes(2);
    expect(getCodexSessionHistoryMock).toHaveBeenCalledTimes(2);
    const createdSessionIds = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .filter(
        (message: any) =>
          message.type === "system" && message.subtype === "session_created",
      )
      .map((message: any) => message.sessionId);
    expect(createdSessionIds).toEqual(["s-1", "s-2"]);

    bridge.close();
  });

  it("does not reuse a completed daemon resume after attachment readiness is lost", async () => {
    vi.stubEnv("BRIDGE_CODEX_APP_SERVER_MODE", "daemon");
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      codexActionBrokerRuntime: writableCodexActionBrokerRuntime(),
    });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    const manager = (bridge as any).sessionManager;
    const create = vi.spyOn(manager, "create");
    const request = {
      type: "resume_session",
      sessionId: "thr_restart_unattached",
      projectPath: "/tmp/project-a",
      provider: "codex",
    };

    await (bridge as any).handleClientMessage(request, ws);
    manager.get("s-1").process.isAttachmentReady = false;
    await (bridge as any).handleClientMessage(request, ws);

    expect(create).toHaveBeenCalledTimes(2);
    // Shared adoption never rebuilds the provider transcript during resume;
    // only the runtime attachment is rebuilt.
    expect(getCodexSessionHistoryMock).not.toHaveBeenCalled();
    const createdSessionIds = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .filter(
        (message: any) =>
          message.type === "system" && message.subtype === "session_created",
      )
      .map((message: any) => message.sessionId);
    expect(createdSessionIds).toEqual(["s-1", "s-2"]);

    bridge.close();
  });

  it("coalesces concurrent Codex resumes for one provider thread", async () => {
    let resolveHistory:
      ((messages: Array<Record<string, unknown>>) => void) | undefined;
    getCodexSessionHistoryMock.mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          resolveHistory = resolve;
        }),
    );
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const wsA = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    const wsB = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    const manager = (bridge as any).sessionManager;
    const create = vi.spyOn(manager, "create");
    const request = {
      type: "resume_session",
      sessionId: "thr_concurrent_once",
      projectPath: "/tmp/project-a",
      provider: "codex",
    };

    const resumeA = (bridge as any).handleClientMessage(request, wsA);
    await vi.waitFor(() => {
      expect(resolveHistory).toBeTypeOf("function");
    });
    const resumeB = (bridge as any).handleClientMessage(request, wsB);
    await Promise.resolve();
    resolveHistory?.([]);
    await Promise.all([resumeA, resumeB]);

    expect(create).toHaveBeenCalledTimes(1);
    expect(getCodexSessionHistoryMock).toHaveBeenCalledTimes(1);
    const createdSessionIds = [wsA, wsB].map(
      (ws) =>
        ws.send.mock.calls
          .map((call: unknown[]) => JSON.parse(call[0] as string))
          .find(
            (message: any) =>
              message.type === "system" &&
              message.subtype === "session_created",
          )?.sessionId,
    );
    expect(createdSessionIds).toEqual(["s-1", "s-1"]);

    bridge.close();
  });

  it("sends one Codex resume result when the same client retries concurrently", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    let resolveName: (() => void) | undefined;
    vi.spyOn(bridge as any, "loadAndSetSessionName").mockImplementationOnce(
      () =>
        new Promise<void>((resolve) => {
          resolveName = resolve;
        }),
    );
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    const request = {
      type: "resume_session",
      sessionId: "thr_same_client_concurrent",
      projectPath: "/tmp/project-a",
      provider: "codex",
    };

    const firstResume = (bridge as any).handleClientMessage(request, ws);
    await vi.waitFor(() => {
      expect(resolveName).toBeTypeOf("function");
      expect((bridge as any).sessionManager.list()).toHaveLength(1);
    });
    const retryResume = (bridge as any).handleClientMessage(request, ws);
    await Promise.resolve();
    resolveName?.();
    await Promise.all([firstResume, retryResume]);

    const createdMessages = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .filter(
        (message: any) =>
          message.type === "system" && message.subtype === "session_created",
      );
    expect(createdMessages).toHaveLength(1);
    expect(createdMessages[0]).toMatchObject({
      sessionId: "s-1",
      claudeSessionId: "thr_same_client_concurrent",
    });

    bridge.close();
  });

  it("sends one Codex resume error when the same client retries concurrently", async () => {
    let rejectHistory: ((reason: Error) => void) | undefined;
    getCodexSessionHistoryMock.mockImplementationOnce(
      () =>
        new Promise((_resolve, reject) => {
          rejectHistory = reject;
        }),
    );
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    const request = {
      type: "resume_session",
      sessionId: "thr_same_client_failure",
      projectPath: "/tmp/project-a",
      provider: "codex",
    };

    const firstResume = (bridge as any).handleClientMessage(request, ws);
    await vi.waitFor(() => {
      expect(rejectHistory).toBeTypeOf("function");
    });
    const retryResume = (bridge as any).handleClientMessage(request, ws);
    await Promise.resolve();
    rejectHistory?.(new Error("history unavailable"));
    await Promise.all([firstResume, retryResume]);

    const errors = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .filter(
        (message: any) =>
          message.type === "error" &&
          String(message.message).includes("history unavailable"),
      );
    expect(errors).toHaveLength(1);

    bridge.close();
  });

  it("does not send past_history on resume_session and sends it on get_history with sessionId", async () => {
    getSessionHistoryMock.mockResolvedValue([
      {
        role: "user",
        content: [{ type: "text", text: "restored question" }],
      },
    ]);

    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    (bridge as any).clientSupportedServerMessages.set(
      ws,
      new Set(["session_link_progress_v1"]),
    );

    await (bridge as any).handleClientMessage(
      {
        type: "resume_session",
        sessionId: "claude-session-1",
        projectPath: "/tmp/project-a",
        provider: "claude",
        resumeRequestId: "link-request-claude",
        sessionLinkGeneration: 11,
      },
      ws,
    );

    await Promise.resolve();
    await Promise.resolve();
    const resumeSends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    expect(resumeSends.some((m: any) => m.type === "past_history")).toBe(false);

    const created = resumeSends.find(
      (m: any) => m.type === "system" && m.subtype === "session_created",
    );
    expect(created).toBeDefined();
    expect(created.provider).toBe("claude");
    expect(created.sourceSessionId).toBeUndefined();
    expect(created.resumeRequestId).toBe("link-request-claude");
    const resumeProgress = resumeSends.filter(
      (message: any) => message.type === "session_link_progress_v1",
    );
    expect(resumeProgress.map((message: any) => message.stage)).toEqual([
      "request_accepted",
      "resume_lock_acquired",
      "history_reading",
      "history_read",
      "runtime_starting",
      "metadata_loading",
      "ready",
    ]);
    expect(
      resumeProgress.every(
        (message: any) =>
          message.generation === 11 &&
          message.requestId === "link-request-claude" &&
          message.sourceSessionId === "claude-session-1" &&
          message.projectPath === undefined,
      ),
    ).toBe(true);
    const newSessionId = created.sessionId as string;

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      { type: "get_history", sessionId: newSessionId },
      ws,
    );

    const historySends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    expect(historySends[0]).toMatchObject({
      type: "past_history",
      sessionId: newSessionId,
    });
    expect(historySends[1]).toMatchObject({
      type: "history",
      sessionId: newSessionId,
    });
    expect(historySends[2]).toMatchObject({
      type: "status",
      sessionId: newSessionId,
    });

    bridge.close();
  });

  it("queues input addressed to a Claude session while resume history loads", async () => {
    let resolveHistory!: (messages: unknown[]) => void;
    getSessionHistoryMock.mockReturnValue(
      new Promise<unknown[]>((resolve) => {
        resolveHistory = resolve;
      }),
    );
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    void (bridge as any).handleClientMessage(
      {
        type: "resume_session",
        sessionId: "claude-session-pending",
        projectPath: "/tmp/project-a",
        provider: "claude",
      },
      ws,
    );
    await (bridge as any).handleClientMessage(
      {
        type: "input",
        sessionId: "claude-session-pending",
        text: "hello while resuming",
        clientMessageId: "cm-pending",
      },
      ws,
    );
    await (bridge as any).handleClientMessage(
      {
        type: "input",
        sessionId: "claude-session-pending",
        text: "second queued input",
        clientMessageId: "cm-pending-2",
      },
      ws,
    );

    expect((bridge as any).sessionManager.get("s-1")).toBeUndefined();
    expect(ws.send).not.toHaveBeenCalledWith(
      expect.stringContaining("No active session"),
    );

    resolveHistory([]);
    await vi.waitFor(() => {
      const session = (bridge as any).sessionManager.get("s-1");
      expect(session.process.sendInput).toHaveBeenCalledWith(
        "hello while resuming",
      );
    });
    expect(
      (bridge as any).sessionManager.get("s-1").process.sendInput.mock.calls,
    ).toEqual([["hello while resuming"], ["second queued input"]]);

    const sends = ws.send.mock.calls.map((call: unknown[]) =>
      JSON.parse(call[0] as string),
    );
    const createdIndex = sends.findIndex(
      (message: any) =>
        message.type === "system" && message.subtype === "session_created",
    );
    const ackIndex = sends.findIndex(
      (message: any) =>
        message.type === "input_ack" &&
        message.clientMessageId === "cm-pending",
    );
    expect(createdIndex).toBeGreaterThanOrEqual(0);
    expect(ackIndex).toBeGreaterThan(createdIndex);
    expect(sends[ackIndex]).toMatchObject({
      sessionId: "s-1",
      clientMessageId: "cm-pending",
    });
    expect(
      sends.findIndex(
        (message: any) =>
          message.type === "input_ack" &&
          message.clientMessageId === "cm-pending-2",
      ),
    ).toBeGreaterThan(ackIndex);

    bridge.close();
  });

  it("joins a Claude resume from a reconnected client", async () => {
    let resolveHistory!: (messages: unknown[]) => void;
    getSessionHistoryMock.mockReturnValue(
      new Promise<unknown[]>((resolve) => {
        resolveHistory = resolve;
      }),
    );
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const firstWs = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    const reconnectWs = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    (bridge as any).clientSupportedServerMessages.set(
      firstWs,
      new Set(["session_link_progress_v1"]),
    );
    (bridge as any).clientSupportedServerMessages.set(
      reconnectWs,
      new Set(["session_link_progress_v1"]),
    );
    const firstRequest = {
      type: "resume_session",
      sessionId: "claude-session-idempotent",
      projectPath: "/tmp/project-a",
      provider: "claude",
      resumeRequestId: "resume-before-reconnect",
      sessionLinkGeneration: 31,
    };
    const reconnectRequest = {
      ...firstRequest,
      resumeRequestId: "resume-after-reconnect",
      sessionLinkGeneration: 32,
    };
    await (bridge as any).handleClientMessage(firstRequest, firstWs);
    (bridge as any).clearPendingClaudeResumeInputs(firstWs);
    await (bridge as any).handleClientMessage(reconnectRequest, reconnectWs);

    expect(getSessionHistoryMock).toHaveBeenCalledTimes(1);
    resolveHistory([]);
    await vi.waitFor(() => {
      const reconnectCreated = reconnectWs.send.mock.calls
        .map((call: unknown[]) => JSON.parse(call[0] as string))
        .find(
          (message: any) =>
            message.type === "system" && message.subtype === "session_created",
        );
      expect(reconnectCreated?.sessionId).toBe("s-1");
      expect(reconnectCreated?.resumeRequestId).toBe("resume-after-reconnect");
      expect(reconnectCreated?.sessionLinkGeneration).toBe(32);
    });

    const firstCreated = firstWs.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find(
        (message: any) =>
          message.type === "system" && message.subtype === "session_created",
      );
    expect(firstCreated).toBeUndefined();
    const reconnectProgress = reconnectWs.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .filter((message: any) => message.type === "session_link_progress_v1");
    expect(reconnectProgress.length).toBeGreaterThan(1);
    expect(
      reconnectProgress.every(
        (message: any) =>
          message.requestId === "resume-after-reconnect" &&
          message.generation === 32,
      ),
    ).toBe(true);
    expect(getSessionHistoryMock).toHaveBeenCalledTimes(1);

    bridge.close();
  });

  it("coalesces correlation-only resume variants but replies to each request", async () => {
    let resolveHistory!: (messages: unknown[]) => void;
    getSessionHistoryMock.mockReturnValue(
      new Promise<unknown[]>((resolve) => {
        resolveHistory = resolve;
      }),
    );
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const wsA = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    const wsB = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    for (const ws of [wsA, wsB]) {
      (bridge as any).clientSupportedServerMessages.set(
        ws,
        new Set(["session_link_progress_v1"]),
      );
    }

    const common = {
      type: "resume_session",
      sessionId: "claude-session-correlated",
      projectPath: "/tmp/project-a",
      provider: "claude",
      model: "claude-sonnet",
    };
    await (bridge as any).handleClientMessage(
      {
        ...common,
        resumeRequestId: "resume-a",
        sessionLinkGeneration: 41,
      },
      wsA,
    );
    await (bridge as any).handleClientMessage(
      {
        ...common,
        resumeRequestId: "resume-b",
        sessionLinkGeneration: 42,
      },
      wsB,
    );

    expect(getSessionHistoryMock).toHaveBeenCalledTimes(1);
    resolveHistory([]);
    await vi.waitFor(() => {
      for (const [ws, requestId] of [
        [wsA, "resume-a"],
        [wsB, "resume-b"],
      ] as const) {
        const created = ws.send.mock.calls
          .map((call: unknown[]) => JSON.parse(call[0] as string))
          .find(
            (message: any) =>
              message.type === "system" &&
              message.subtype === "session_created",
          );
        expect(created?.resumeRequestId).toBe(requestId);
        expect(created?.sessionLinkGeneration).toBe(
          requestId === "resume-a" ? 41 : 42,
        );
      }
    });

    for (const [ws, requestId, generation] of [
      [wsA, "resume-a", 41],
      [wsB, "resume-b", 42],
    ] as const) {
      const progress = ws.send.mock.calls
        .map((call: unknown[]) => JSON.parse(call[0] as string))
        .filter((message: any) => message.type === "session_link_progress_v1");
      expect(progress.length).toBeGreaterThan(1);
      expect(
        progress.every(
          (message: any) =>
            message.requestId === requestId &&
            message.generation === generation,
        ),
      ).toBe(true);
    }
    expect(getSessionHistoryMock).toHaveBeenCalledTimes(1);

    bridge.close();
  });

  it("starts a new Claude resume when completed settings differ", async () => {
    getSessionHistoryMock.mockResolvedValue([]);
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "resume_session",
        sessionId: "claude-session-settings",
        projectPath: "/tmp/project-a",
        provider: "claude",
        model: "claude-sonnet",
      },
      ws,
    );
    await vi.waitFor(() => {
      expect(
        ws.send.mock.calls
          .map((call: unknown[]) => JSON.parse(call[0] as string))
          .some(
            (message: any) =>
              message.type === "system" &&
              message.subtype === "session_created" &&
              message.sessionId === "s-1",
          ),
      ).toBe(true);
    });

    await (bridge as any).handleClientMessage(
      {
        type: "resume_session",
        sessionId: "claude-session-settings",
        projectPath: "/tmp/project-a",
        provider: "claude",
        model: "claude-opus",
      },
      ws,
    );
    await vi.waitFor(() => {
      expect(
        ws.send.mock.calls
          .map((call: unknown[]) => JSON.parse(call[0] as string))
          .some(
            (message: any) =>
              message.type === "system" &&
              message.subtype === "session_created" &&
              message.sessionId === "s-2",
          ),
      ).toBe(true);
    });
    expect(getSessionHistoryMock).toHaveBeenCalledTimes(2);

    bridge.close();
  });

  it("does not reuse a completed Claude fork resume", async () => {
    getSessionHistoryMock.mockResolvedValue([]);
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    const request = {
      type: "resume_session",
      sessionId: "claude-session-fork",
      projectPath: "/tmp/project-a",
      provider: "claude",
      forkSession: true,
    };

    await (bridge as any).handleClientMessage(request, ws);
    await vi.waitFor(() => {
      expect((bridge as any).sessionManager.get("s-1")).toBeDefined();
    });
    await (bridge as any).handleClientMessage(request, ws);
    await vi.waitFor(() => {
      expect((bridge as any).sessionManager.get("s-2")).toBeDefined();
    });
    expect(getSessionHistoryMock).toHaveBeenCalledTimes(2);

    bridge.close();
  });

  it("times out a stalled resume and releases its waiters", async () => {
    vi.useFakeTimers();
    try {
      getSessionHistoryMock.mockReturnValue(new Promise(() => {}));
      const bridge = new BridgeWebSocketServer({ server: httpServer });
      const ws = {
        readyState: OPEN_STATE,
        send: vi.fn(),
      } as any;

      void (bridge as any).handleClientMessage(
        {
          type: "resume_session",
          sessionId: "claude-session-timeout",
          projectPath: "/tmp/project-a",
          provider: "claude",
        },
        ws,
      );
      await vi.advanceTimersByTimeAsync(5 * 60 * 1000);

      expect((bridge as any).resumeOperations.size).toBe(0);
      expect(
        ws.send.mock.calls
          .map((call: unknown[]) => JSON.parse(call[0] as string))
          .find((message: any) => message.type === "error")?.message,
      ).toContain("made no progress");
      expect(
        ws.send.mock.calls
          .map((call: unknown[]) => JSON.parse(call[0] as string))
          .find(
            (message: any) =>
              message.type === "system" &&
              message.subtype === "session_resume_failed",
          ),
      ).toMatchObject({
        sourceSessionId: "claude-session-timeout",
        provider: "claude",
        projectPath: resolve("/tmp/project-a"),
      });
      bridge.close();
    } finally {
      vi.useRealTimers();
    }
  });

  it("keeps a resume alive while meaningful progress crosses the old hard cap", async () => {
    vi.useFakeTimers();
    try {
      let reportHistoryProgress:
        ((progress: { completedUnits: number }) => void) | undefined;
      getSessionHistoryMock.mockImplementation(
        (
          _sessionId: string,
          options: {
            onProgress?: (progress: { completedUnits: number }) => void;
          },
        ) => {
          reportHistoryProgress = options.onProgress;
          return new Promise(() => {});
        },
      );
      const bridge = new BridgeWebSocketServer({ server: httpServer });
      const ws = {
        readyState: OPEN_STATE,
        send: vi.fn(),
      } as any;

      void (bridge as any).handleClientMessage(
        {
          type: "resume_session",
          sessionId: "claude-session-progressing",
          projectPath: "/tmp/project-a",
          provider: "claude",
        },
        ws,
      );
      expect(reportHistoryProgress).toBeTypeOf("function");

      await vi.advanceTimersByTimeAsync(4 * 60 * 1000);
      reportHistoryProgress?.({ completedUnits: 1 });
      await vi.advanceTimersByTimeAsync(4 * 60 * 1000);
      reportHistoryProgress?.({ completedUnits: 2 });

      expect((bridge as any).resumeOperations.size).toBe(1);
      expect(
        ws.send.mock.calls
          .map((call: unknown[]) => JSON.parse(call[0] as string))
          .some(
            (message: any) =>
              message.type === "system" &&
              message.subtype === "session_resume_failed",
          ),
      ).toBe(false);

      await vi.advanceTimersByTimeAsync(5 * 60 * 1000);
      expect((bridge as any).resumeOperations.size).toBe(0);
      expect(
        ws.send.mock.calls
          .map((call: unknown[]) => JSON.parse(call[0] as string))
          .find((message: any) => message.type === "error")?.message,
      ).toContain("made no progress");
      bridge.close();
    } finally {
      vi.useRealTimers();
    }
  });

  it("discards a stale completion after a timed-out resume is retried", async () => {
    let resolveOldHistory!: (messages: unknown[]) => void;
    let resolveNewHistory!: (messages: unknown[]) => void;
    getSessionHistoryMock
      .mockReturnValueOnce(
        new Promise<unknown[]>((resolve) => {
          resolveOldHistory = resolve;
        }),
      )
      .mockReturnValueOnce(
        new Promise<unknown[]>((resolve) => {
          resolveNewHistory = resolve;
        }),
      );
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    const request = {
      type: "resume_session",
      sessionId: "claude-session-stale-completion",
      projectPath: "/tmp/project-a",
      provider: "claude",
    };
    const destroySpy = vi.spyOn((bridge as any).sessionManager, "destroy");

    vi.useFakeTimers();
    try {
      void (bridge as any).handleClientMessage(request, ws);
      await vi.advanceTimersByTimeAsync(5 * 60 * 1000);
    } finally {
      vi.useRealTimers();
    }

    void (bridge as any).handleClientMessage(request, ws);
    resolveNewHistory([]);
    await vi.waitFor(() => {
      expect((bridge as any).sessionManager.get("s-1")).toBeDefined();
    });

    resolveOldHistory([]);
    await vi.waitFor(() => {
      expect(destroySpy).toHaveBeenCalledWith("s-2");
    });
    expect((bridge as any).sessionManager.get("s-2")).toBeUndefined();

    const createdMessages = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .filter(
        (message: any) =>
          message.type === "system" && message.subtype === "session_created",
      );
    expect(createdMessages).toHaveLength(1);
    expect(createdMessages[0].sessionId).toBe("s-1");
    expect(
      [...(bridge as any).resumeOperations.values()][0].completed.sessionId,
    ).toBe("s-1");

    bridge.close();
  });

  it("prefers an existing bridge session id over a pending resume alias", async () => {
    let resolveHistory!: (messages: unknown[]) => void;
    getSessionHistoryMock.mockReturnValue(
      new Promise<unknown[]>((resolve) => {
        resolveHistory = resolve;
      }),
    );
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      { type: "start", projectPath: "/tmp/existing", provider: "claude" },
      ws,
    );
    void (bridge as any).handleClientMessage(
      {
        type: "resume_session",
        sessionId: "s-1",
        projectPath: "/tmp/resumed",
        provider: "claude",
      },
      ws,
    );
    await (bridge as any).handleClientMessage(
      { type: "input", sessionId: "s-1", text: "existing session input" },
      ws,
    );

    const existing = (bridge as any).sessionManager.get("s-1");
    expect(existing.process.sendInput).toHaveBeenCalledWith(
      "existing session input",
    );

    resolveHistory([]);
    await vi.waitFor(() => {
      expect((bridge as any).sessionManager.get("s-2")).toBeDefined();
    });
    const resumed = (bridge as any).sessionManager.get("s-2");
    expect(resumed.process.sendInput).not.toHaveBeenCalled();

    bridge.close();
  });

  it("does not deliver queued resume input after the client disconnects", async () => {
    let resolveHistory!: (messages: unknown[]) => void;
    getSessionHistoryMock.mockReturnValue(
      new Promise<unknown[]>((resolve) => {
        resolveHistory = resolve;
      }),
    );
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    void (bridge as any).handleClientMessage(
      {
        type: "resume_session",
        sessionId: "claude-session-disconnected",
        projectPath: "/tmp/project-a",
        provider: "claude",
      },
      ws,
    );
    await (bridge as any).handleClientMessage(
      {
        type: "input",
        sessionId: "claude-session-disconnected",
        text: "must not run after disconnect",
        clientMessageId: "cm-disconnected",
      },
      ws,
    );

    (bridge as any).clearPendingClaudeResumeInputs(ws);
    expect(
      [...(bridge as any).resumeOperations.values()][0].waiters.some(
        (waiter: any) => waiter.ws === ws,
      ),
    ).toBe(false);
    resolveHistory([]);
    await vi.waitFor(() => {
      expect((bridge as any).sessionManager.get("s-1")).toBeDefined();
    });
    expect(
      (bridge as any).sessionManager.get("s-1").process.sendInput,
    ).not.toHaveBeenCalled();

    bridge.close();
  });

  it("rejects queued input and clears it when Claude resume fails", async () => {
    let rejectHistory!: (error: Error) => void;
    getSessionHistoryMock.mockReturnValue(
      new Promise<unknown[]>((_, reject) => {
        rejectHistory = reject;
      }),
    );
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    void (bridge as any).handleClientMessage(
      {
        type: "resume_session",
        sessionId: "claude-session-failed",
        projectPath: "/tmp/project-a",
        provider: "claude",
      },
      ws,
    );
    await (bridge as any).handleClientMessage(
      {
        type: "input",
        sessionId: "claude-session-failed",
        text: "input that cannot be delivered",
        clientMessageId: "cm-failed",
      },
      ws,
    );

    rejectHistory(new Error("history unavailable"));
    await vi.waitFor(() => {
      const sends = ws.send.mock.calls.map((call: unknown[]) =>
        JSON.parse(call[0] as string),
      );
      expect(sends).toContainEqual(
        expect.objectContaining({
          type: "input_rejected",
          sessionId: "claude-session-failed",
          clientMessageId: "cm-failed",
          reason: "Session resume failed",
        }),
      );
      expect(sends).toContainEqual(
        expect.objectContaining({
          type: "system",
          subtype: "session_resume_failed",
          sourceSessionId: "claude-session-failed",
          provider: "claude",
          projectPath: resolve("/tmp/project-a"),
        }),
      );
    });
    expect(
      (bridge as any).pendingClaudeResumeInputs
        .get(ws)
        ?.has("claude-session-failed"),
    ).toBe(false);

    bridge.close();
  });

  it("serves get_history_delta with sequenced messages", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-a",
        provider: "claude",
      },
      ws,
    );
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "system" && m.subtype === "session_created");
    const sessionId = created.sessionId as string;
    expect(created).not.toHaveProperty("claudeSessionId");
    const manager = (bridge as any).sessionManager;
    const first = manager.appendHistory(sessionId, {
      type: "status",
      status: "running",
    });
    const second = manager.appendHistory(sessionId, {
      type: "status",
      status: "idle",
    });

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "get_history_delta",
        sessionId,
        sinceSeq: first.seq,
      },
      ws,
    );

    const delta = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "history_delta");
    expect(delta).toMatchObject({
      sessionId,
      fromSeq: second.seq,
      toSeq: second.seq,
      messages: [
        { seq: second.seq, message: { type: "status", status: "idle" } },
      ],
      status: "idle",
    });
    const receivedAt = delta.messages[0].message.receivedAt;
    expect(receivedAt).toEqual(expect.any(String));
    expect(Number.isNaN(Date.parse(receivedAt))).toBe(false);

    bridge.close();
  });

  it("includes resume past_history before get_history_delta", async () => {
    getSessionHistoryMock.mockResolvedValue([
      {
        role: "user",
        content: [{ type: "text", text: "previous prompt" }],
      },
      {
        role: "assistant",
        content: [{ type: "text", text: "previous answer" }],
      },
    ]);
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "resume_session",
        sessionId: "claude-session-1",
        projectPath: "/tmp/project-a",
        provider: "claude",
      },
      ws,
    );
    await Promise.resolve();
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "system" && m.subtype === "session_created");
    const sessionId = created.sessionId as string;

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "get_history_delta",
        sessionId,
        sinceSeq: 1,
      },
      ws,
    );

    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    expect(sends[0]).toMatchObject({
      type: "past_history",
      sessionId,
      claudeSessionId: "claude-session-1",
      messages: [{ role: "user" }, { role: "assistant" }],
    });
    expect(sends[1]).toMatchObject({
      type: "history_delta",
      sessionId,
    });

    bridge.close();
  });

  it("serves codex history deltas from canonical thread/read", async () => {
    const desktopToolTimeline = {
      callIds: new Set(["call-skill"]),
      events: [
        {
          turnId: "turn-1",
          callId: "call-skill",
          afterVisibleMessage: 1,
          sequence: 1,
          type: "tool_use",
          name: "ReadSkill",
          input: { file_path: "/tmp/pdf/SKILL.md" },
        },
      ],
    };
    getCodexDesktopToolTimelineMock.mockResolvedValue(desktopToolTimeline);
    codexThreadToSessionHistoryMock.mockReturnValue([
      {
        role: "user",
        uuid: "codex:user-turn:1",
        rawItemId: "raw-user-1",
        timestamp: "2026-05-29T00:00:00.000Z",
        content: [{ type: "text", text: "sync this thread" }],
      },
      {
        role: "assistant",
        uuid: "assistant-1",
        content: [{ type: "text", text: "synced" }],
      },
    ]);

    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
        model: "gpt-5.3-codex",
      },
      ws,
    );
    await Promise.resolve();
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "system" && m.subtype === "session_created");
    const sessionId = created.sessionId as string;
    const manager = (bridge as any).sessionManager;
    const session = manager.get(sessionId);
    session.claudeSessionId = "thr_codex_1";
    session.codexSettings = {
      model: "gpt-5.3-codex",
      modelReasoningEffort: "xhigh",
      serviceTier: "fast",
    };
    session.process.readThread.mockResolvedValue({
      id: "thr_codex_1",
      turns: [],
    });

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "get_history_delta",
        sessionId,
        sinceSeq: 0,
      },
      ws,
    );

    expect(session.process.readThread).toHaveBeenCalledWith(
      "thr_codex_1",
      true,
    );
    expect(getCodexDesktopToolTimelineMock).toHaveBeenCalledWith("thr_codex_1");
    expect(codexThreadToSessionHistoryMock).toHaveBeenCalledWith(
      { id: "thr_codex_1", turns: [] },
      { desktopToolTimeline },
    );
    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    expect(sends.some((m: any) => m.type === "history_delta")).toBe(false);
    expect(sends[0]).toMatchObject({
      type: "history_snapshot",
      sessionId,
      fromSeq: 1,
      toSeq: 2,
      status: "idle",
      reason: "reset",
      messages: [
        {
          seq: 1,
          message: {
            type: "user_input",
            text: "sync this thread",
            userMessageUuid: "codex:user-turn:1",
            timestamp: "2026-05-29T00:00:00.000Z",
          },
        },
        {
          seq: 2,
          message: {
            type: "assistant",
            messageUuid: "assistant-1",
            message: {
              role: "assistant",
              content: [{ type: "text", text: "synced" }],
              model: "gpt-5.3-codex",
            },
          },
        },
      ],
    });
    expect(sends[1]).toMatchObject({
      type: "system",
      subtype: "codex_settings",
      sessionId,
      model: "gpt-5.3-codex",
      modelReasoningEffort: "xhigh",
      serviceTier: "fast",
    });
    expect(session.pastMessages).toHaveLength(2);
    expect(session.history).toEqual([]);
    expect(session.historyEntries).toEqual([]);
    expect(session.historyRevision).toBe(2);
    expect(session.codexCanonicalHistoryRevision).toBe(2);
    expect(session.codexUserTurnUuidByRawId?.get("raw-user-1")).toBe(
      "codex:user-turn:1",
    );

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "input",
        sessionId,
        text: "next turn",
      },
      ws,
    );

    const inputSends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    expect(inputSends[0]).toMatchObject({
      type: "user_input",
      text: "next turn",
      userMessageUuid: "codex:user-turn:2",
      historySeq: 3,
    });

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "get_history_delta",
        sessionId,
        sinceSeq: 2,
      },
      ws,
    );

    expect(session.process.readThread).toHaveBeenCalledTimes(1);
    const deltaSends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    expect(deltaSends[0]).toMatchObject({
      type: "history_delta",
      sessionId,
      fromSeq: 3,
      toSeq: 3,
      messages: [
        {
          seq: 3,
          message: {
            type: "user_input",
            text: "next turn",
            userMessageUuid: "codex:user-turn:2",
            historySeq: 3,
          },
        },
      ],
    });
    expect(deltaSends[1]).toMatchObject({
      type: "system",
      subtype: "codex_settings",
      sessionId,
      model: "gpt-5.3-codex",
      modelReasoningEffort: "xhigh",
      serviceTier: "fast",
    });

    bridge.close();
  });

  it("serves codex get_history as legacy history from canonical thread/read", async () => {
    codexThreadToSessionHistoryMock.mockReturnValue([
      {
        role: "user",
        uuid: "codex:user-turn:1",
        timestamp: "2026-05-29T00:00:00.000Z",
        content: [{ type: "text", text: "restore legacy shape" }],
      },
      {
        role: "assistant",
        uuid: "assistant-legacy-1",
        content: [{ type: "text", text: "legacy history restored" }],
      },
    ]);

    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
        model: "gpt-5.3-codex",
      },
      ws,
    );
    await Promise.resolve();
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "system" && m.subtype === "session_created");
    const sessionId = created.sessionId as string;
    const session = (bridge as any).sessionManager.get(sessionId);
    session.claudeSessionId = "thr_codex_legacy";
    session.codexSettings = {
      model: "gpt-5.3-codex",
      modelReasoningEffort: "xhigh",
      serviceTier: "fast",
    };
    session.process.readThread.mockResolvedValue({
      id: "thr_codex_legacy",
      turns: [],
    });

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "get_history",
        sessionId,
      },
      ws,
    );

    expect(session.process.readThread).toHaveBeenCalledWith(
      "thr_codex_legacy",
      true,
    );
    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    expect(sends.some((m: any) => m.type === "history_snapshot")).toBe(false);
    expect(sends[0]).toMatchObject({
      type: "history",
      sessionId,
      messages: [
        {
          type: "user_input",
          text: "restore legacy shape",
          userMessageUuid: "codex:user-turn:1",
          timestamp: "2026-05-29T00:00:00.000Z",
        },
        {
          type: "assistant",
          messageUuid: "assistant-legacy-1",
          message: {
            role: "assistant",
            content: [{ type: "text", text: "legacy history restored" }],
            model: "gpt-5.3-codex",
          },
        },
      ],
    });
    expect(sends[1]).toMatchObject({
      type: "system",
      subtype: "codex_settings",
      sessionId,
      provider: "codex",
      model: "gpt-5.3-codex",
      modelReasoningEffort: "xhigh",
      serviceTier: "fast",
    });
    expect(sends[2]).toMatchObject({
      type: "status",
      status: "idle",
      sessionId,
    });

    bridge.close();
  });

  it("bounds canonical history only for clients that opt into a render window", async () => {
    codexThreadToSessionHistoryMock.mockReturnValue(
      Array.from({ length: 205 }, (_, index) => ({
        role: "user" as const,
        uuid: `codex:user-turn:${index + 1}`,
        content: [{ type: "text" as const, text: `history item ${index}` }],
      })),
    );

    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex-window",
        provider: "codex",
      },
      ws,
    );
    await Promise.resolve();
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find(
        (message: any) =>
          message.type === "system" && message.subtype === "session_created",
      );
    const sessionId = created.sessionId as string;
    const session = (bridge as any).sessionManager.get(sessionId);
    session.claudeSessionId = "thr_codex_window";
    session.process.readThread.mockResolvedValue({
      id: "thr_codex_window",
      turns: [],
    });

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      { type: "get_history", sessionId },
      ws,
    );
    const legacyHistory = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.type === "history");
    expect(legacyHistory.messages).toHaveLength(205);

    await (bridge as any).handleClientMessage(
      {
        type: "client_capabilities",
        supportedServerMessages: ["bounded_history_window_v1"],
      },
      ws,
    );
    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      { type: "get_history", sessionId },
      ws,
    );
    const boundedHistory = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.type === "history");
    expect(boundedHistory.messages).toHaveLength(200);
    expect(boundedHistory.messages[0]).toMatchObject({
      type: "user_input",
      text: "history item 5",
    });
    expect(boundedHistory.messages.at(-1)).toMatchObject({
      type: "user_input",
      text: "history item 204",
    });

    await (bridge as any).handleClientMessage(
      {
        type: "client_capabilities",
        supportedServerMessages: ["turn_aware_history_window_v1"],
      },
      ws,
    );
    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      { type: "get_history", sessionId },
      ws,
    );
    const turnAwareHistory = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.type === "history");
    expect(turnAwareHistory.messages).toHaveLength(5);
    expect(turnAwareHistory.messages[0]).toMatchObject({
      type: "user_input",
      text: "history item 200",
    });
    expect(turnAwareHistory.messages.at(-1)).toMatchObject({
      type: "user_input",
      text: "history item 204",
    });
    expect(turnAwareHistory.historyWindow).toMatchObject({
      capability: "turn_aware_history_window_v1",
      hasMore: true,
    });

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "get_history_page",
        requestId: "history-page-1",
        sessionId,
        beforeSeq: turnAwareHistory.historyWindow.fromSeq,
        beforeCursor: turnAwareHistory.historyWindow.cursor,
      },
      ws,
    );
    const olderPage = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.type === "history_page");
    expect(olderPage).toMatchObject({
      requestId: "history-page-1",
      sessionId,
      hasMore: true,
    });
    expect(olderPage.nextBeforeCursor).toMatch(/^v1:\d+:[a-f0-9]{24}$/);
    expect(olderPage.nextBeforeCursor.length).toBeLessThan(64);
    expect(olderPage.messages).toHaveLength(5);
    expect(olderPage.messages[0].message).toMatchObject({
      type: "user_input",
      text: "history item 195",
    });
    expect(olderPage.messages.at(-1).message).toMatchObject({
      type: "user_input",
      text: "history item 199",
    });

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "get_history_page",
        requestId: "history-page-2",
        sessionId,
        beforeSeq: olderPage.nextBeforeSeq,
        beforeCursor: olderPage.nextBeforeCursor,
      },
      ws,
    );
    const nextOlderPage = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.type === "history_page");
    expect(nextOlderPage.messages).toHaveLength(5);
    expect(nextOlderPage.messages[0].message).toMatchObject({
      type: "user_input",
      text: "history item 190",
    });
    expect(nextOlderPage.messages.at(-1).message).toMatchObject({
      type: "user_input",
      text: "history item 194",
    });

    bridge.close();
  });

  it("keeps history page cursors bounded across canonical sequence drift", () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const message = {
      type: "assistant",
      message: {
        id: "",
        role: "assistant",
        model: "test",
        content: [{ type: "text", text: "x".repeat(4096) }],
      },
    } as any;
    const cursor = (bridge as any).historyPageCursor({
      seq: 400,
      message,
    });

    expect(cursor).toMatch(/^v1:400:[a-f0-9]{24}$/);
    expect(cursor.length).toBeLessThan(64);
    expect(
      (bridge as any).historyPageCursorIndex(
        [
          {
            seq: 400,
            message: {
              type: "user_input",
              text: "other",
              userMessageUuid: "other",
            },
          },
          { seq: 401, message },
        ],
        cursor,
      ),
    ).toBe(1);

    bridge.close();
  });

  it("returns only requested canonical tool details in a bounded response", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    const sessionId = (bridge as any).sessionManager.create(
      "/tmp/project-history-tools",
    );
    const session = (bridge as any).sessionManager.get(sessionId);
    session.historyEntries = [
      {
        seq: 1,
        message: {
          type: "assistant",
          message: {
            id: "assistant-tools",
            role: "assistant",
            model: "test",
            content: [
              {
                type: "tool_use",
                id: "tool-1",
                name: "Read",
                input: { file_path: "/tmp/a.txt" },
              },
              {
                type: "tool_use",
                id: "tool-2",
                name: "Search",
                input: { query: "needle" },
              },
            ],
          },
        },
      },
      {
        seq: 2,
        message: {
          type: "tool_result",
          toolUseId: "tool-1",
          toolName: "Read",
          content: "file contents",
        },
      },
    ];

    await (bridge as any).handleClientMessage(
      {
        type: "get_history_tool_details",
        requestId: "history-tools-1",
        sessionId,
        toolUseIds: ["tool-1", "missing"],
      },
      ws,
    );

    const response = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.type === "history_tool_details");
    expect(response).toEqual({
      type: "history_tool_details",
      requestId: "history-tools-1",
      sessionId,
      details: [
        {
          toolUseId: "tool-1",
          toolName: "Read",
          input: { file_path: "/tmp/a.txt" },
          result: {
            content: "file contents",
            toolName: "Read",
          },
        },
      ],
    });

    bridge.close();
  });

  it("reuses cached codex history when older tool details are expanded", async () => {
    codexThreadToSessionHistoryMock.mockReturnValue([
      {
        role: "user",
        uuid: "codex:user-turn:1",
        content: [{ type: "text", text: "read it" }],
      },
      {
        role: "assistant",
        uuid: "assistant-tool",
        content: [
          {
            type: "tool_use",
            id: "tool-cached",
            name: "Read",
            input: { file_path: "/tmp/cached.txt" },
          },
        ],
      },
      {
        role: "tool_result",
        toolUseId: "tool-cached",
        toolName: "Read",
        content: "cached contents",
      },
    ]);

    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex-tool-cache",
        provider: "codex",
      },
      ws,
    );
    await Promise.resolve();
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find(
        (message: any) =>
          message.type === "system" && message.subtype === "session_created",
      );
    const sessionId = created.sessionId as string;
    const session = (bridge as any).sessionManager.get(sessionId);
    session.claudeSessionId = "thr_codex_tool_cache";
    session.process.readThread.mockResolvedValue({
      id: "thr_codex_tool_cache",
      turns: [],
    });

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      { type: "get_history", sessionId },
      ws,
    );
    expect(session.process.readThread).toHaveBeenCalledTimes(1);

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "get_history_tool_details",
        requestId: "history-tools-cached",
        sessionId,
        toolUseIds: ["tool-cached"],
      },
      ws,
    );

    const response = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.type === "history_tool_details");
    expect(session.process.readThread).toHaveBeenCalledTimes(1);
    expect(response.details).toEqual([
      {
        toolUseId: "tool-cached",
        toolName: "Read",
        input: { file_path: "/tmp/cached.txt" },
        result: { content: "cached contents", toolName: "Read" },
      },
    ]);

    bridge.close();
  });

  it("bounds pathological tool detail fields before sending them", () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const largeText = "界".repeat(100_000);
    const details = (bridge as any).historyToolDetails(
      [
        {
          seq: 1,
          message: {
            type: "assistant",
            message: {
              id: "assistant-large-tool",
              role: "assistant",
              model: "test",
              content: [
                {
                  type: "tool_use",
                  id: "tool-large",
                  name: "Write",
                  input: { file_path: "/tmp/large.txt", content: largeText },
                },
              ],
            },
          },
        },
        {
          seq: 2,
          message: {
            type: "tool_result",
            toolUseId: "tool-large",
            toolName: "Write",
            content: largeText,
            images: Array.from({ length: 40 }, (_, index) => ({
              id: `image-${index}`,
              url: `/images/${index}`,
              mimeType: "image/png",
            })),
          },
        },
      ],
      ["tool-large"],
    );

    expect(details[0].input).toMatchObject({ truncated: true });
    expect(details[0].result.content).toContain("[truncated by Bridge]");
    expect(details[0].result.images).toHaveLength(32);
    expect(Buffer.byteLength(JSON.stringify(details), "utf8")).toBeLessThan(
      140 * 1024,
    );

    bridge.close();
  });

  it("does not publish fallback settings while a resumed thread is unresolved", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex-unresolved",
        provider: "codex",
      },
      ws,
    );
    await Promise.resolve();
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find(
        (message: any) =>
          message.type === "system" && message.subtype === "session_created",
      );
    const sessionId = created.sessionId as string;
    const session = (bridge as any).sessionManager.get(sessionId);
    const unresolvedProcess = Object.create(CodexProcess.prototype) as any;
    unresolvedProcess.readThread = vi.fn(async () => ({
      id: "thread-unresolved",
      turns: [],
    }));
    session.process = unresolvedProcess;
    session.claudeSessionId = "thread-unresolved";
    session.codexSettings = {};
    codexThreadToSessionHistoryMock.mockReturnValue([]);

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      { type: "get_history", sessionId },
      ws,
    );

    const settings = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find(
        (message: any) =>
          message.type === "system" && message.subtype === "codex_settings",
      );
    expect(unresolvedProcess.model).toBe("gpt-5.5");
    expect(unresolvedProcess.knownModel).toBeUndefined();
    expect(settings).not.toHaveProperty("model");
    expect(settings).not.toHaveProperty("modelReasoningEffort");
    expect(settings).not.toHaveProperty("serviceTier");

    bridge.close();
  });

  it("replays cached Codex goal state with history responses", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "client_capabilities",
        supportedServerMessages: ["goal_state"],
      },
      ws,
    );
    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
      },
      ws,
    );
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "system" && m.subtype === "session_created");
    const sessionId = created.sessionId as string;
    const session = (bridge as any).sessionManager.get(sessionId);
    session.codexGoal = {
      threadId: "thread-goal",
      objective: "Keep this goal visible",
      status: "active",
      tokenBudget: null,
      tokensUsed: 10,
      timeUsedSeconds: 5,
      createdAt: 1,
      updatedAt: 2,
    };

    const expectGoalReplay = async (
      request: Record<string, unknown>,
      expectedHistoryType: string,
    ) => {
      ws.send.mockClear();
      await (bridge as any).handleClientMessage(request, ws);
      const sends = ws.send.mock.calls.map((c: unknown[]) =>
        JSON.parse(c[0] as string),
      );
      expect(sends.some((m: any) => m.type === expectedHistoryType)).toBe(true);
      const goalState = sends.find((m: any) => m.type === "goal_state");
      expect(goalState).toEqual({
        type: "goal_state",
        sessionId,
        goal: session.codexGoal,
      });
    };

    await expectGoalReplay({ type: "get_history", sessionId }, "history");
    await expectGoalReplay(
      { type: "get_history_delta", sessionId, sinceSeq: 0 },
      "history_delta",
    );

    session.claudeSessionId = "thread-goal";
    session.process.readThread.mockResolvedValue({
      id: "thread-goal",
      turns: [],
    });
    await expectGoalReplay({ type: "get_history", sessionId }, "history");
    session.codexCanonicalHistoryRevision = undefined;
    session.codexHistoryResetRevision = undefined;
    await expectGoalReplay(
      { type: "get_history_delta", sessionId, sinceSeq: 0 },
      "history_snapshot",
    );

    bridge.close();
  });

  it("reads codex history from the process that owns the target session", async () => {
    codexThreadToSessionHistoryMock.mockReturnValue([]);

    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
      },
      ws,
    );
    await Promise.resolve();
    await Promise.resolve();

    const firstCreated = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "system" && m.subtype === "session_created");
    const firstSession = (bridge as any).sessionManager.get(
      firstCreated.sessionId,
    );
    firstSession.claudeSessionId = "thr_codex_first";
    firstSession.process.readThread.mockRejectedValue(
      new Error("thread not loaded: thr_codex_second"),
    );

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
      },
      ws,
    );
    await Promise.resolve();
    await Promise.resolve();

    const secondCreated = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "system" && m.subtype === "session_created");
    const secondSessionId = secondCreated.sessionId as string;
    const secondSession = (bridge as any).sessionManager.get(secondSessionId);
    secondSession.claudeSessionId = "thr_codex_second";
    secondSession.process.readThread.mockResolvedValue({
      id: "thr_codex_second",
      turns: [],
    });

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "get_history",
        sessionId: secondSessionId,
      },
      ws,
    );

    expect(firstSession.process.readThread).not.toHaveBeenCalled();
    expect(secondSession.process.readThread).toHaveBeenCalledWith(
      "thr_codex_second",
      true,
    );
    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    expect(sends.some((m: any) => m.type === "error")).toBe(false);
    expect(sends[0]).toMatchObject({
      type: "history",
      sessionId: secondSessionId,
      messages: [],
    });

    bridge.close();
  });

  it("serves empty codex history for unmaterialized threads", async () => {
    codexThreadToSessionHistoryMock.mockReturnValue([]);

    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
        model: "gpt-5.3-codex",
      },
      ws,
    );
    await Promise.resolve();
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "system" && m.subtype === "session_created");
    const sessionId = created.sessionId as string;
    const manager = (bridge as any).sessionManager;
    const session = manager.get(sessionId);
    session.claudeSessionId = "thr_codex_empty";
    session.process.readThread.mockRejectedValue(
      new Error(
        "thread thr_codex_empty is not materialized yet; includeTurns is unavailable before first user message",
      ),
    );

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "get_history_delta",
        sessionId,
        sinceSeq: 0,
      },
      ws,
    );

    expect(getCodexSessionHistoryMock).not.toHaveBeenCalled();
    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    expect(sends.some((m: any) => m.type === "error")).toBe(false);
    expect(sends[0]).toMatchObject({
      type: "history_snapshot",
      sessionId,
      messages: [],
      reason: "reset",
    });
    expect(sends[0].fromSeq).toBe(sends[0].toSeq + 1);
    expect(sends[0].toSeq).toBeGreaterThan(0);
    expect(session.pastMessages).toEqual([]);
    expect(session.history).toEqual([]);
    expect(session.historyRevision).toBe(sends[0].toSeq);
    expect(session.codexCanonicalHistoryRevision).toBe(0);

    const baselineRevision = session.historyRevision;
    manager.appendHistory(sessionId, {
      type: "user_input",
      text: "first materialized input",
      userMessageUuid: "codex:user-turn:1",
    });
    expect(session.historyRevision).toBe(baselineRevision + 1);

    bridge.close();
  });

  it("preserves codex live history when a canonical delta reset is needed", async () => {
    codexThreadToSessionHistoryMock.mockReturnValue([
      {
        role: "user",
        uuid: "codex:user-turn:1",
        timestamp: "2026-05-29T00:00:00.000Z",
        content: [{ type: "text", text: "restore this thread" }],
      },
    ]);

    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
        model: "gpt-5.3-codex",
      },
      ws,
    );
    await Promise.resolve();
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "system" && m.subtype === "session_created");
    const sessionId = created.sessionId as string;
    const manager = (bridge as any).sessionManager;
    const session = manager.get(sessionId);
    session.claudeSessionId = "thr_codex_live";
    session.codexSettings = { model: "gpt-5.3-codex" };
    session.process.readThread.mockResolvedValue({
      id: "thr_codex_live",
      turns: [],
    });
    manager.appendHistory(sessionId, {
      type: "assistant",
      message: {
        id: "live-assistant-1",
        role: "assistant",
        content: [{ type: "text", text: "live answer still streaming" }],
        model: "gpt-5.3-codex",
      },
      messageUuid: "live-assistant-1",
    });

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "get_history_delta",
        sessionId,
        sinceSeq: 0,
      },
      ws,
    );

    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    expect(sends[0]).toMatchObject({
      type: "history_snapshot",
      sessionId,
      reason: "reset",
      messages: [
        {
          message: {
            type: "user_input",
            text: "restore this thread",
            userMessageUuid: "codex:user-turn:1",
          },
        },
        {
          message: {
            type: "assistant",
            messageUuid: "live-assistant-1",
            message: {
              id: "live-assistant-1",
              role: "assistant",
              content: [{ type: "text", text: "live answer still streaming" }],
              model: "gpt-5.3-codex",
            },
          },
        },
      ],
    });
    expect(sends[0].fromSeq).toBe(sends[0].messages[0].seq);
    expect(sends[0].toSeq).toBe(sends[0].messages[1].seq);
    expect(sends[0].fromSeq).toBeGreaterThan(1);
    expect(session.codexCanonicalHistoryRevision).toBe(
      sends[0].messages[0].seq,
    );
    expect(session.historyEntries).toMatchObject([
      {
        seq: sends[0].messages[1].seq,
        message: {
          type: "assistant",
          messageUuid: "live-assistant-1",
        },
      },
    ]);
    expect(session.historyRevision).toBe(sends[0].toSeq);

    bridge.close();
  });

  it("keeps omitted live tool logs before the final reply across canonical refreshes", async () => {
    codexThreadToSessionHistoryMock.mockReturnValue([
      {
        role: "user",
        uuid: "codex:user-turn:1",
        content: [{ type: "text", text: "delegate this task" }],
      },
      {
        role: "assistant",
        uuid: "commentary-1",
        content: [{ type: "text", text: "I will delegate this task." }],
      },
      {
        role: "assistant",
        uuid: "final-1",
        content: [{ type: "text", text: "The task is complete." }],
      },
    ]);

    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
        model: "gpt-5.3-codex",
      },
      ws,
    );
    await Promise.resolve();
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find(
        (message: any) =>
          message.type === "system" && message.subtype === "session_created",
      );
    const sessionId = created.sessionId as string;
    const manager = (bridge as any).sessionManager;
    const session = manager.get(sessionId);
    session.claudeSessionId = "thr_codex_subagent_order";
    session.codexSettings = { model: "gpt-5.3-codex" };
    session.status = "running";
    session.process.readThread.mockResolvedValue({
      id: "thr_codex_subagent_order",
      turns: [],
    });

    manager.appendHistory(sessionId, {
      type: "user_input",
      text: "delegate this task",
      userMessageUuid: "codex:user-turn:1",
    });
    manager.appendHistory(sessionId, {
      type: "assistant",
      messageUuid: "commentary-1",
      message: {
        id: "commentary-1",
        role: "assistant",
        content: [{ type: "text", text: "I will delegate this task." }],
        model: "gpt-5.3-codex",
      },
    });
    for (let index = 0; index < 101; index++) {
      manager.appendHistory(sessionId, {
        type: "tool_result",
        toolUseId: `background-${index}`,
        toolName: "SubAgent",
        content: `background result ${index}`,
      });
    }
    manager.appendHistory(sessionId, {
      type: "assistant",
      message: {
        id: "subagent-1",
        role: "assistant",
        content: [
          {
            type: "tool_use",
            id: "subagent-1",
            name: "SubAgent",
            input: { tool: "wait" },
          },
        ],
        model: "gpt-5.3-codex",
      },
    });
    manager.appendHistory(sessionId, {
      type: "tool_result",
      toolUseId: "subagent-1",
      toolName: "SubAgent",
      content: "status: completed",
    });
    manager.appendHistory(sessionId, {
      type: "assistant",
      messageUuid: "live-final-1",
      message: {
        id: "live-final-1",
        role: "assistant",
        content: [{ type: "text", text: "The task is complete." }],
        model: "gpt-5.3-codex",
      },
    });
    expect(
      session.history.some((message: any) => message.type === "user_input"),
    ).toBe(false);

    const readHistoryOrder = async (): Promise<string[]> => {
      ws.send.mockClear();
      await (bridge as any).handleClientMessage(
        { type: "get_history", sessionId },
        ws,
      );
      const sentMessages = ws.send.mock.calls.map((call: unknown[]) =>
        JSON.parse(call[0] as string),
      );
      const history = sentMessages.find(
        (message: any) => message.type === "history",
      );
      expect(history, JSON.stringify(sentMessages)).toBeDefined();
      return history.messages.map((message: any) => {
        if (message.type === "user_input") return "user";
        if (message.type === "tool_result") {
          return message.toolUseId === "subagent-1"
            ? "subagent-result"
            : "background-result";
        }
        const content = message.message.content[0];
        if (content.type === "tool_use") return "subagent-use";
        return content.text;
      });
    };

    const assertOrder = (order: string[]): void => {
      expect(order.slice(0, 2)).toEqual(["user", "I will delegate this task."]);
      expect(order.slice(-3)).toEqual([
        "subagent-use",
        "subagent-result",
        "The task is complete.",
      ]);
      expect(
        order.filter((item) => item === "The task is complete."),
      ).toHaveLength(1);
    };

    const firstOrder = await readHistoryOrder();
    assertOrder(firstOrder);
    const firstRevision = session.historyRevision;
    expect(session.codexCanonicalHistoryRevision).toBe(firstRevision);
    expect(firstRevision).toBeGreaterThan(firstOrder.length);
    expect(session.codexOrderedHistoryEntries).toHaveLength(100);

    const secondOrder = await readHistoryOrder();
    assertOrder(secondOrder);
    const secondRevision = session.historyRevision;
    expect(secondRevision).toBeGreaterThan(firstRevision);
    expect(session.codexOrderedHistoryEntries).toHaveLength(100);

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      { type: "get_history_delta", sessionId, sinceSeq: firstRevision },
      ws,
    );
    expect(
      ws.send.mock.calls
        .map((call: unknown[]) => JSON.parse(call[0] as string))
        .find((message: any) => message.type === "history_snapshot"),
    ).toMatchObject({ reason: "reset" });

    const resetRevision = session.historyRevision;
    expect(resetRevision).toBeGreaterThan(secondRevision);
    manager.appendHistory(sessionId, {
      type: "tool_result",
      toolUseId: "after-refresh",
      toolName: "SubAgent",
      content: "new result",
    });
    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      { type: "get_history_delta", sessionId, sinceSeq: resetRevision },
      ws,
    );
    expect(
      ws.send.mock.calls
        .map((call: unknown[]) => JSON.parse(call[0] as string))
        .find((message: any) => message.type === "history_delta"),
    ).toMatchObject({
      fromSeq: resetRevision + 1,
      toSeq: resetRevision + 1,
      messages: [
        {
          seq: resetRevision + 1,
          message: { type: "tool_result", toolUseId: "after-refresh" },
        },
      ],
    });

    bridge.close();
  });

  it("deduplicates a residual live assistant after an earlier baseline consumed its user row", async () => {
    const canonicalUser = {
      role: "user" as const,
      uuid: "codex:user-turn:1",
      timestamp: "2026-05-29T00:00:00.000Z",
      content: [{ type: "text", text: "Reply with OK" }],
    };
    const canonicalAssistant = {
      role: "assistant" as const,
      uuid: "canonical-ok",
      content: [{ type: "text", text: "OK" }],
    };
    codexThreadToSessionHistoryMock
      .mockReturnValueOnce([canonicalUser])
      .mockReturnValue([canonicalUser, canonicalAssistant]);

    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
        model: "gpt-5.3-codex",
      },
      ws,
    );
    await Promise.resolve();
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "system" && m.subtype === "session_created");
    const sessionId = created.sessionId as string;
    const manager = (bridge as any).sessionManager;
    const session = manager.get(sessionId);
    session.claudeSessionId = "thr_codex_residual";
    session.codexSettings = { model: "gpt-5.3-codex" };
    session.process.readThread.mockResolvedValue({
      id: "thr_codex_residual",
      turns: [],
    });
    manager.appendHistory(sessionId, {
      type: "user_input",
      text: "Reply with OK",
      userMessageUuid: "codex:user-turn:1",
    });

    await (bridge as any).handleClientMessage(
      {
        type: "get_history_delta",
        sessionId,
        sinceSeq: 0,
      },
      ws,
    );
    expect(session.historyEntries).toEqual([]);

    manager.appendHistory(sessionId, {
      type: "assistant",
      message: {
        id: "live-ok",
        role: "assistant",
        content: [{ type: "text", text: "OK" }],
        model: "gpt-5.3-codex",
      },
    });
    ws.send.mockClear();

    await (bridge as any).handleClientMessage(
      {
        type: "get_history_delta",
        sessionId,
        sinceSeq: 0,
      },
      ws,
    );

    const snapshot = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((message: any) => message.type === "history_snapshot");
    expect(snapshot.messages).toHaveLength(2);
    expect(snapshot.messages[0].message).toMatchObject({
      type: "user_input",
      userMessageUuid: "codex:user-turn:1",
    });
    expect(snapshot.messages[1].message).toMatchObject({
      type: "assistant",
      messageUuid: "canonical-ok",
      message: { id: "canonical-ok" },
    });
    expect(session.historyEntries).toEqual([]);

    bridge.close();
  });

  it("keeps codex live assistant with same text as canonical assistant when ids differ", async () => {
    codexThreadToSessionHistoryMock.mockReturnValue([
      {
        role: "assistant",
        uuid: "canonical-ok",
        content: [{ type: "text", text: "OK" }],
      },
    ]);

    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
        model: "gpt-5.3-codex",
      },
      ws,
    );
    await Promise.resolve();
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "system" && m.subtype === "session_created");
    const sessionId = created.sessionId as string;
    const manager = (bridge as any).sessionManager;
    const session = manager.get(sessionId);
    session.claudeSessionId = "thr_codex_same_text";
    session.codexSettings = { model: "gpt-5.3-codex" };
    session.process.readThread.mockResolvedValue({
      id: "thr_codex_same_text",
      turns: [],
    });
    manager.appendHistory(sessionId, {
      type: "assistant",
      message: {
        id: "live-ok",
        role: "assistant",
        content: [{ type: "text", text: "OK" }],
        model: "gpt-5.3-codex",
      },
    });

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "get_history_delta",
        sessionId,
        sinceSeq: 0,
      },
      ws,
    );

    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    expect(sends[0]).toMatchObject({
      type: "history_snapshot",
      sessionId,
      messages: [
        {
          message: {
            type: "assistant",
            messageUuid: "canonical-ok",
            message: {
              id: "canonical-ok",
              role: "assistant",
              content: [{ type: "text", text: "OK" }],
              model: "gpt-5.3-codex",
            },
          },
        },
        {
          message: {
            type: "assistant",
            message: {
              id: "live-ok",
              role: "assistant",
              content: [{ type: "text", text: "OK" }],
              model: "gpt-5.3-codex",
            },
          },
        },
      ],
    });
    expect(sends[0].fromSeq).toBe(sends[0].messages[0].seq);
    expect(sends[0].toSeq).toBe(sends[0].messages[1].seq);
    expect(sends[0].fromSeq).toBeGreaterThan(1);
    expect(session.historyEntries).toMatchObject([
      {
        seq: sends[0].messages[1].seq,
        message: {
          type: "assistant",
          message: {
            id: "live-ok",
          },
        },
      },
    ]);

    bridge.close();
  });

  it("deduplicates a live assistant from the same canonical user turn", async () => {
    codexThreadToSessionHistoryMock.mockReturnValue([
      {
        role: "user",
        uuid: "codex:user-turn:1",
        content: [{ type: "text", text: "Reply with OK" }],
      },
      {
        role: "assistant",
        uuid: "canonical-first",
        content: [{ type: "text", text: "FIRST" }],
      },
      {
        role: "user",
        uuid: "codex:user-turn:2",
        content: [{ type: "text", text: "Reply with SECOND" }],
      },
      {
        role: "assistant",
        uuid: "canonical-second",
        content: [{ type: "text", text: "SECOND" }],
      },
    ]);

    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
        model: "gpt-5.3-codex",
      },
      ws,
    );
    await Promise.resolve();
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "system" && m.subtype === "session_created");
    const sessionId = created.sessionId as string;
    const manager = (bridge as any).sessionManager;
    const session = manager.get(sessionId);
    session.claudeSessionId = "thr_codex_same_turn";
    session.codexSettings = { model: "gpt-5.3-codex" };
    session.process.readThread.mockResolvedValue({
      id: "thr_codex_same_turn",
      turns: [],
    });
    manager.appendHistory(sessionId, {
      type: "user_input",
      text: "Reply with OK",
      userMessageUuid: "codex:user-turn:1",
    });
    manager.appendHistory(sessionId, {
      type: "assistant",
      message: {
        id: "live-first",
        role: "assistant",
        content: [{ type: "text", text: "FIRST" }],
        model: "gpt-5.3-codex",
      },
    });
    manager.appendHistory(sessionId, {
      type: "user_input",
      text: "Reply with SECOND",
      userMessageUuid: "codex:user-turn:2",
    });
    manager.appendHistory(sessionId, {
      type: "assistant",
      messageUuid: "canonical-second",
      message: {
        id: "canonical-second",
        role: "assistant",
        content: [{ type: "text", text: "SECOND" }],
        model: "gpt-5.3-codex",
      },
    });
    manager.appendHistory(sessionId, {
      type: "assistant",
      message: {
        id: "live-second-extra",
        role: "assistant",
        content: [{ type: "text", text: "SECOND" }],
        model: "gpt-5.3-codex",
      },
    });

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "get_history_delta",
        sessionId,
        sinceSeq: 0,
      },
      ws,
    );

    const snapshot = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((message: any) => message.type === "history_snapshot");
    expect(snapshot.messages).toHaveLength(5);
    expect(snapshot.messages.map((entry: any) => entry.message.type)).toEqual([
      "user_input",
      "assistant",
      "user_input",
      "assistant",
      "assistant",
    ]);
    expect(snapshot.messages[1].message).toMatchObject({
      type: "assistant",
      messageUuid: "canonical-first",
      message: { id: "canonical-first" },
    });
    expect(snapshot.messages[3].message).toMatchObject({
      type: "assistant",
      messageUuid: "canonical-second",
      message: { id: "canonical-second" },
    });
    expect(snapshot.messages[4].message).toMatchObject({
      type: "assistant",
      message: { id: "live-second-extra" },
    });
    expect(session.historyEntries).toMatchObject([
      {
        seq: snapshot.messages[4].seq,
        message: {
          type: "assistant",
          message: { id: "live-second-extra" },
        },
      },
    ]);

    bridge.close();
  });

  it("deduplicates codex live tool use by canonical item id", async () => {
    codexThreadToSessionHistoryMock.mockReturnValue([
      {
        role: "assistant",
        content: [
          {
            type: "tool_use",
            id: "cmd-1",
            name: "Bash",
            input: { command: "npm test" },
          },
        ],
      },
    ]);

    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
        model: "gpt-5.3-codex",
      },
      ws,
    );
    await Promise.resolve();
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "system" && m.subtype === "session_created");
    const sessionId = created.sessionId as string;
    const manager = (bridge as any).sessionManager;
    const session = manager.get(sessionId);
    session.claudeSessionId = "thr_codex_tool_dedupe";
    session.codexSettings = { model: "gpt-5.3-codex" };
    session.process.readThread.mockResolvedValue({
      id: "thr_codex_tool_dedupe",
      turns: [],
    });
    manager.appendHistory(sessionId, {
      type: "assistant",
      message: {
        id: "cmd-1",
        role: "assistant",
        content: [
          {
            type: "tool_use",
            id: "cmd-1",
            name: "Bash",
            input: { command: "npm test" },
          },
        ],
        model: "gpt-5.3-codex",
      },
    });

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "get_history_delta",
        sessionId,
        sinceSeq: 0,
      },
      ws,
    );

    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    expect(sends[0]).toMatchObject({
      type: "history_snapshot",
      sessionId,
      messages: [
        {
          message: {
            type: "assistant",
            message: {
              id: "cmd-1",
              content: [
                {
                  type: "tool_use",
                  id: "cmd-1",
                  name: "Bash",
                },
              ],
            },
          },
        },
      ],
    });
    expect(sends[0].fromSeq).toBe(sends[0].toSeq);
    expect(sends[0].messages[0].seq).toBe(sends[0].toSeq);
    expect(sends[0].toSeq).toBeGreaterThan(1);
    expect(session.historyEntries).toEqual([]);
    expect(session.historyRevision).toBe(sends[0].toSeq);

    bridge.close();
  });

  it("deduplicates codex live tool result by canonical item id when content differs", async () => {
    codexThreadToSessionHistoryMock.mockReturnValue([
      {
        role: "tool_result",
        toolUseId: "cmd-1",
        toolName: "Bash",
        content: "status: completed\nexitCode: 0\nclean",
      },
    ]);

    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
        model: "gpt-5.3-codex",
      },
      ws,
    );
    await Promise.resolve();
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "system" && m.subtype === "session_created");
    const sessionId = created.sessionId as string;
    const manager = (bridge as any).sessionManager;
    const session = manager.get(sessionId);
    session.claudeSessionId = "thr_codex_tool_result_dedupe";
    session.codexSettings = { model: "gpt-5.3-codex" };
    session.process.readThread.mockResolvedValue({
      id: "thr_codex_tool_result_dedupe",
      turns: [],
    });
    manager.appendHistory(sessionId, {
      type: "tool_result",
      toolUseId: "cmd-1",
      toolName: "Bash",
      content: "clean",
    });

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "get_history_delta",
        sessionId,
        sinceSeq: 0,
      },
      ws,
    );

    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    expect(sends[0]).toMatchObject({
      type: "history_snapshot",
      sessionId,
      messages: [
        {
          message: {
            type: "tool_result",
            toolUseId: "cmd-1",
            toolName: "Bash",
            content: "status: completed\nexitCode: 0\nclean",
          },
        },
      ],
    });
    expect(sends[0].fromSeq).toBe(sends[0].toSeq);
    expect(sends[0].messages[0].seq).toBe(sends[0].toSeq);
    expect(sends[0].toSeq).toBeGreaterThan(1);
    expect(session.historyEntries).toEqual([]);
    expect(session.historyRevision).toBe(sends[0].toSeq);

    bridge.close();
  });

  it("preserves codex live history appended while canonical read is pending", async () => {
    codexThreadToSessionHistoryMock.mockReturnValue([
      {
        role: "user",
        uuid: "codex:user-turn:1",
        content: [{ type: "text", text: "stored before pending read" }],
      },
    ]);

    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
        model: "gpt-5.3-codex",
      },
      ws,
    );
    await Promise.resolve();
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "system" && m.subtype === "session_created");
    const sessionId = created.sessionId as string;
    const manager = (bridge as any).sessionManager;
    const session = manager.get(sessionId);
    session.claudeSessionId = "thr_codex_pending";
    session.codexSettings = { model: "gpt-5.3-codex" };

    let resolveRead!: (thread: unknown) => void;
    const pendingRead = new Promise((resolve) => {
      resolveRead = resolve;
    });
    session.process.readThread.mockReturnValue(pendingRead);

    ws.send.mockClear();
    const pendingHistory = (bridge as any).handleClientMessage(
      {
        type: "get_history_delta",
        sessionId,
        sinceSeq: 0,
      },
      ws,
    );
    await Promise.resolve();

    manager.appendHistory(sessionId, {
      type: "assistant",
      message: {
        id: "live-during-read",
        role: "assistant",
        content: [{ type: "text", text: "arrived during read" }],
        model: "gpt-5.3-codex",
      },
      messageUuid: "live-during-read",
    });
    resolveRead({ id: "thr_codex_pending", turns: [] });
    await pendingHistory;

    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    expect(sends[0]).toMatchObject({
      type: "history_snapshot",
      sessionId,
      messages: [
        {
          message: {
            type: "user_input",
            text: "stored before pending read",
            userMessageUuid: "codex:user-turn:1",
          },
        },
        {
          message: {
            type: "assistant",
            messageUuid: "live-during-read",
            message: {
              id: "live-during-read",
              role: "assistant",
              content: [{ type: "text", text: "arrived during read" }],
              model: "gpt-5.3-codex",
            },
          },
        },
      ],
    });
    expect(sends[0].fromSeq).toBe(sends[0].messages[0].seq);
    expect(sends[0].toSeq).toBe(sends[0].messages[1].seq);
    expect(sends[0].fromSeq).toBeGreaterThan(1);
    expect(session.historyEntries).toMatchObject([
      {
        seq: sends[0].messages[1].seq,
        message: {
          type: "assistant",
          messageUuid: "live-during-read",
        },
      },
    ]);

    bridge.close();
  });

  it("keeps codex ViewImage refs in canonical history snapshots", async () => {
    codexThreadToSessionHistoryMock.mockReturnValue([
      {
        role: "tool_result",
        toolUseId: "view-image-1",
        toolName: "ViewImage",
        content: "Viewed image",
        imageBase64: [{ data: "aGVsbG8=", mimeType: "image/png" }],
      },
    ]);
    const imageStore = {
      extractImagePaths: vi.fn(() => []),
      registerImages: vi.fn(async () => []),
      registerFromBase64: vi.fn(() => ({
        id: "img-canonical",
        url: "/images/img-canonical",
        mimeType: "image/png",
      })),
    };

    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      imageStore: imageStore as any,
    });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
      },
      ws,
    );
    await Promise.resolve();
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "system" && m.subtype === "session_created");
    const sessionId = created.sessionId as string;
    const session = (bridge as any).sessionManager.get(sessionId);
    session.claudeSessionId = "thr_codex_images";
    session.process.readThread.mockResolvedValue({
      id: "thr_codex_images",
      turns: [],
    });

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "get_history_delta",
        sessionId,
        sinceSeq: 0,
      },
      ws,
    );

    expect(imageStore.registerFromBase64).toHaveBeenCalledWith(
      "aGVsbG8=",
      "image/png",
    );
    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    expect(sends[0]).toMatchObject({
      type: "history_snapshot",
      messages: [
        {
          message: {
            type: "tool_result",
            toolUseId: "view-image-1",
            toolName: "ViewImage",
            images: [
              {
                id: "img-canonical",
                url: "/images/img-canonical",
                mimeType: "image/png",
              },
            ],
          },
        },
      ],
    });
    expect(sends[0].messages[0].seq).toBe(sends[0].toSeq);
    expect(sends[0].toSeq).toBeGreaterThan(1);

    bridge.close();
  });

  it("replays stable artifact refs for canonical Markdown and ImageGeneration history", async () => {
    codexThreadToSessionHistoryMock.mockReturnValue([
      {
        role: "assistant",
        uuid: "assistant-artifact-1",
        content: [
          {
            type: "text",
            text: "Open [the source](src/main.ts:12) after the run.",
          },
        ],
      },
      {
        role: "tool_result",
        toolUseId: "image-generation-1",
        toolName: "ImageGeneration",
        content: "status: completed",
        imagePaths: ["/tmp/project-codex/generated image.png"],
      },
    ]);

    const stableIds = new Map<string, string>();
    const artifactManager = {
      registerCandidates: vi.fn(async (input: any) =>
        input.candidates.map((candidate: any) => {
          const key = `${input.ownerId}:${input.messageId}:${candidate.localPath}`;
          const id =
            stableIds.get(key) ?? `stable-artifact-${stableIds.size + 1}`;
          stableIds.set(key, id);
          return {
            id,
            filename: candidate.localPath.split("/").at(-1) ?? "artifact",
            mimeType:
              candidate.source === "image_generation"
                ? "image/png"
                : "text/typescript",
            sizeBytes: 42,
            kind:
              candidate.source === "image_generation" ? "preview" : "source",
            source: candidate.source,
            ...(candidate.originalHref
              ? { originalHref: candidate.originalHref }
              : {}),
            ...(candidate.textContentIndex !== undefined
              ? { textContentIndex: candidate.textContentIndex }
              : {}),
          };
        }),
      ),
      resolve: vi.fn(),
    };
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      artifactManager: artifactManager as any,
    });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
      },
      ws,
    );
    await Promise.resolve();
    await Promise.resolve();
    const created = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find(
        (message: any) =>
          message.type === "system" && message.subtype === "session_created",
      );
    const sessionId = created.sessionId as string;
    const session = (bridge as any).sessionManager.get(sessionId);
    session.claudeSessionId = "thread-artifact-owner";
    session.process.readThread.mockResolvedValue({
      id: "thread-artifact-owner",
      turns: [],
    });

    const replay = async (): Promise<any> => {
      ws.send.mockClear();
      await (bridge as any).handleClientMessage(
        { type: "get_history", sessionId },
        ws,
      );
      return ws.send.mock.calls
        .map((call: unknown[]) => JSON.parse(call[0] as string))
        .find((message: any) => message.type === "history");
    };
    const firstReplay = await replay();
    const secondReplay = await replay();

    expect(firstReplay.messages).toHaveLength(2);
    expect(firstReplay.messages[0]).toMatchObject({
      type: "assistant",
      messageUuid: "assistant-artifact-1",
      artifacts: [
        {
          id: "stable-artifact-1",
          source: "assistant_markdown",
          originalHref: "src/main.ts:12",
          textContentIndex: 0,
        },
      ],
    });
    expect(firstReplay.messages[1]).toMatchObject({
      type: "tool_result",
      toolUseId: "image-generation-1",
      toolName: "ImageGeneration",
      artifacts: [
        {
          id: "stable-artifact-2",
          source: "image_generation",
          kind: "preview",
        },
      ],
    });
    expect(
      secondReplay.messages.map((message: any) => message.artifacts),
    ).toEqual(firstReplay.messages.map((message: any) => message.artifacts));
    expect(artifactManager.registerCandidates).toHaveBeenCalledWith(
      expect.objectContaining({
        ownerId: "thread-artifact-owner",
        messageId: "assistant-artifact-1",
      }),
    );
    expect(artifactManager.registerCandidates).toHaveBeenCalledWith(
      expect.objectContaining({
        ownerId: "thread-artifact-owner",
        messageId: "image-generation-1",
      }),
    );
    expect(JSON.stringify(firstReplay)).not.toContain("artifactCandidates");
    expect(stableIds).toHaveLength(2);

    bridge.close();
  });

  it("materializes canonical ImageGeneration history before image and gallery reads", async () => {
    const rawPath = "/tmp/codex/generated_images/生成 raw image.png";
    const managedPath = "/tmp/ccpocket-managed/hash/生成 raw image.png";
    codexThreadToSessionHistoryMock.mockReturnValue([
      {
        role: "tool_result",
        toolUseId: "image-generation-history",
        toolName: "ImageGeneration",
        content: `status: completed\nsavedPath: ${rawPath}`,
        imagePaths: [rawPath],
      },
    ]);
    const imageRef = {
      id: "img-managed-history",
      url: "/images/img-managed-history",
      mimeType: "image/png",
    };
    const imageStore = {
      extractImagePaths: vi.fn(() => ["/image.png"]),
      registerImages: vi.fn(async () => [imageRef]),
      registerFromBase64: vi.fn(),
    };
    const galleryMeta = {
      id: "gallery-managed-history",
      filename: "managed.png",
      mimeType: "image/png",
      projectPath: "/tmp/project-codex",
      sessionId: "runtime",
      sourcePath: managedPath,
      addedAt: "2026-07-16T00:00:00.000Z",
      sizeBytes: 10,
    };
    let hasGalleryEntry = false;
    const galleryStore = {
      bindProviderSessionIdBySourcePath: vi.fn(async () =>
        hasGalleryEntry ? galleryMeta : null,
      ),
      addImage: vi.fn(async () => {
        hasGalleryEntry = true;
        return galleryMeta;
      }),
      metaToInfo: vi.fn(() => ({
        id: galleryMeta.id,
        url: `/api/gallery/${galleryMeta.id}`,
        mimeType: galleryMeta.mimeType,
        projectPath: galleryMeta.projectPath,
        projectName: "project-codex",
        sessionId: galleryMeta.sessionId,
        addedAt: galleryMeta.addedAt,
        sizeBytes: galleryMeta.sizeBytes,
      })),
    };
    const artifactManager = {
      materializeGeneratedCandidates: vi.fn(async () => [managedPath]),
      registerCandidates: vi.fn(async () => []),
    };
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      imageStore: imageStore as any,
      galleryStore: galleryStore as any,
      artifactManager: artifactManager as any,
    });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;

    await (bridge as any).handleClientMessage(
      { type: "start", projectPath: "/tmp/project-codex", provider: "codex" },
      ws,
    );
    await Promise.resolve();
    await Promise.resolve();
    const created = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find(
        (message: any) =>
          message.type === "system" && message.subtype === "session_created",
      );
    const sessionId = created.sessionId as string;
    const session = (bridge as any).sessionManager.get(sessionId);
    session.claudeSessionId = "thread-managed-history";
    session.process.readThread.mockResolvedValue({
      id: "thread-managed-history",
      turns: [],
    });

    const replay = async (): Promise<void> => {
      ws.send.mockClear();
      await (bridge as any).handleClientMessage(
        { type: "get_history", sessionId },
        ws,
      );
    };
    await replay();
    await replay();

    expect(artifactManager.materializeGeneratedCandidates).toHaveBeenCalledWith(
      expect.objectContaining({
        ownerId: "thread-managed-history",
        messageId: "image-generation-history",
        candidates: [expect.objectContaining({ localPath: rawPath })],
      }),
    );
    expect(imageStore.extractImagePaths).not.toHaveBeenCalled();
    expect(imageStore.registerImages).toHaveBeenCalledWith(
      [managedPath],
      "/tmp/project-codex",
    );
    expect(imageStore.registerImages).not.toHaveBeenCalledWith(
      expect.arrayContaining([rawPath, "/image.png"]),
      expect.anything(),
    );
    expect(galleryStore.addImage).toHaveBeenCalledTimes(1);
    expect(galleryStore.addImage).toHaveBeenCalledWith(
      managedPath,
      "/tmp/project-codex",
      sessionId,
      "thread-managed-history",
    );
    const history = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.type === "history");
    expect(history.messages[0]).toMatchObject({
      type: "tool_result",
      toolUseId: "image-generation-history",
      images: [imageRef],
    });
    bridge.close();
  });

  it("repairs a legacy Gallery provider binding without copying the managed image again", async () => {
    const root = mkdtempSync(join(tmpdir(), "ccpocket-history-gallery-"));
    const galleryDirectory = join(root, "gallery");
    const managedDirectory = join(root, "managed");
    mkdirSync(managedDirectory, { recursive: true });
    const managedPath = join(managedDirectory, "legacy managed.png");
    writeFileSync(managedPath, Buffer.from("89504e470d0a1a0a", "hex"));

    const initialGallery = new GalleryStore({ directory: galleryDirectory });
    await initialGallery.init();
    const legacyMeta = await initialGallery.addImage(
      managedPath,
      root,
      "runtime-before-restart",
    );
    expect(legacyMeta).not.toBeNull();

    const restartedGallery = new GalleryStore({ directory: galleryDirectory });
    await restartedGallery.init();
    const addImageSpy = vi.spyOn(restartedGallery, "addImage");
    codexThreadToSessionHistoryMock.mockReturnValue([
      {
        role: "tool_result",
        toolUseId: "legacy-gallery-history",
        toolName: "ImageGeneration",
        content: "status: completed",
        imagePaths: ["/tmp/codex/generated_images/legacy managed.png"],
      },
    ]);
    const imageStore = {
      extractImagePaths: vi.fn(),
      registerImages: vi.fn(async () => []),
      registerFromBase64: vi.fn(),
    };
    const artifactManager = {
      materializeGeneratedCandidates: vi.fn(async () => [managedPath]),
      registerCandidates: vi.fn(async () => []),
    };
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      imageStore: imageStore as any,
      galleryStore: restartedGallery,
      artifactManager: artifactManager as any,
    });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;

    try {
      await (bridge as any).handleClientMessage(
        { type: "start", projectPath: root, provider: "codex" },
        ws,
      );
      await Promise.resolve();
      await Promise.resolve();
      const runtimeSessionId = ws.send.mock.calls
        .map((call: unknown[]) => JSON.parse(call[0] as string))
        .find(
          (message: any) =>
            message.type === "system" && message.subtype === "session_created",
        ).sessionId as string;
      expect(runtimeSessionId).not.toBe("runtime-before-restart");
      const session = (bridge as any).sessionManager.get(runtimeSessionId);
      session.claudeSessionId = "thread-gallery-stable";
      session.process.readThread.mockResolvedValue({
        id: "thread-gallery-stable",
        turns: [],
      });

      await (bridge as any).handleClientMessage(
        { type: "get_history", sessionId: runtimeSessionId },
        ws,
      );
      expect(addImageSpy).not.toHaveBeenCalled();
      expect(restartedGallery.list()).toHaveLength(1);

      ws.send.mockClear();
      await (bridge as any).handleClientMessage(
        { type: "list_gallery", sessionId: runtimeSessionId },
        ws,
      );
      const galleryList = ws.send.mock.calls
        .map((call: unknown[]) => JSON.parse(call[0] as string))
        .find((message: any) => message.type === "gallery_list");
      expect(galleryList.images).toEqual([
        expect.objectContaining({ id: legacyMeta!.id }),
      ]);
      expect(JSON.stringify(galleryList)).not.toContain(
        "thread-gallery-stable",
      );

      const persistedGallery = new GalleryStore({
        directory: galleryDirectory,
      });
      await persistedGallery.init();
      expect(
        persistedGallery.list({
          sessionId: "another-runtime",
          providerSessionId: "thread-gallery-stable",
        }),
      ).toHaveLength(1);
    } finally {
      bridge.close();
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("repairs a missing managed Gallery row once and reuses it after a server restart", async () => {
    const root = mkdtempSync(join(tmpdir(), "ccpocket-history-gallery-"));
    const galleryDirectory = join(root, "gallery");
    const managedDirectory = join(root, "managed");
    mkdirSync(managedDirectory, { recursive: true });
    const managedPath = join(managedDirectory, "crash repair.png");
    writeFileSync(managedPath, Buffer.from("89504e470d0a1a0a", "hex"));
    codexThreadToSessionHistoryMock.mockReturnValue([
      {
        role: "tool_result",
        toolUseId: "crash-gallery-history",
        toolName: "ImageGeneration",
        content: "status: completed",
        imagePaths: ["/tmp/codex/generated_images/crash repair.png"],
      },
    ]);
    const imageStore = {
      extractImagePaths: vi.fn(),
      registerImages: vi.fn(async () => []),
      registerFromBase64: vi.fn(),
    };
    const artifactManager = {
      materializeGeneratedCandidates: vi.fn(async () => [managedPath]),
      registerCandidates: vi.fn(async () => []),
    };
    const firstGallery = new GalleryStore({ directory: galleryDirectory });
    await firstGallery.init();
    const firstAddSpy = vi.spyOn(firstGallery, "addImage");
    const firstBridge = new BridgeWebSocketServer({
      server: httpServer,
      imageStore: imageStore as any,
      galleryStore: firstGallery,
      artifactManager: artifactManager as any,
    });
    const firstWs = { readyState: OPEN_STATE, send: vi.fn() } as any;
    const secondHttpServer = createServer();
    let secondBridge: BridgeWebSocketServer | undefined;

    try {
      await (firstBridge as any).handleClientMessage(
        { type: "start", projectPath: root, provider: "codex" },
        firstWs,
      );
      await Promise.resolve();
      await Promise.resolve();
      const firstRuntimeId = firstWs.send.mock.calls
        .map((call: unknown[]) => JSON.parse(call[0] as string))
        .find(
          (message: any) =>
            message.type === "system" && message.subtype === "session_created",
        ).sessionId as string;
      const firstSession = (firstBridge as any).sessionManager.get(
        firstRuntimeId,
      );
      firstSession.claudeSessionId = "thread-crash-stable";
      firstSession.process.readThread.mockResolvedValue({
        id: "thread-crash-stable",
        turns: [],
      });
      await (firstBridge as any).handleClientMessage(
        { type: "get_history", sessionId: firstRuntimeId },
        firstWs,
      );
      await (firstBridge as any).handleClientMessage(
        { type: "get_history", sessionId: firstRuntimeId },
        firstWs,
      );
      expect(firstAddSpy).toHaveBeenCalledTimes(1);
      expect(firstGallery.list()).toHaveLength(1);
      firstBridge.close();

      const restartedGallery = new GalleryStore({
        directory: galleryDirectory,
      });
      await restartedGallery.init();
      const restartedAddSpy = vi.spyOn(restartedGallery, "addImage");
      secondBridge = new BridgeWebSocketServer({
        server: secondHttpServer,
        imageStore: imageStore as any,
        galleryStore: restartedGallery,
        artifactManager: artifactManager as any,
      });
      const secondWs = { readyState: OPEN_STATE, send: vi.fn() } as any;

      // Consume one runtime id so the resumed session proves that filtering is
      // independent of the previous process-local id.
      await (secondBridge as any).handleClientMessage(
        { type: "start", projectPath: root, provider: "codex" },
        secondWs,
      );
      await Promise.resolve();
      await Promise.resolve();
      secondWs.send.mockClear();
      await (secondBridge as any).handleClientMessage(
        { type: "start", projectPath: root, provider: "codex" },
        secondWs,
      );
      await Promise.resolve();
      await Promise.resolve();
      const secondRuntimeId = secondWs.send.mock.calls
        .map((call: unknown[]) => JSON.parse(call[0] as string))
        .find(
          (message: any) =>
            message.type === "system" && message.subtype === "session_created",
        ).sessionId as string;
      const secondSession = (secondBridge as any).sessionManager.get(
        secondRuntimeId,
      );
      secondSession.claudeSessionId = "thread-crash-stable";
      secondSession.process.readThread.mockResolvedValue({
        id: "thread-crash-stable",
        turns: [],
      });
      await (secondBridge as any).handleClientMessage(
        { type: "get_history", sessionId: secondRuntimeId },
        secondWs,
      );
      expect(restartedAddSpy).not.toHaveBeenCalled();
      expect(restartedGallery.list()).toHaveLength(1);

      secondWs.send.mockClear();
      await (secondBridge as any).handleClientMessage(
        { type: "list_gallery", sessionId: secondRuntimeId },
        secondWs,
      );
      const galleryList = secondWs.send.mock.calls
        .map((call: unknown[]) => JSON.parse(call[0] as string))
        .find((message: any) => message.type === "gallery_list");
      expect(galleryList.images).toHaveLength(1);
    } finally {
      firstBridge.close();
      secondBridge?.close();
      secondHttpServer.close();
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("keeps an empty canonical ImageGeneration tool result when its managed artifact survives", async () => {
    const rawPath = "/tmp/codex/generated_images/artifact-only.png";
    const managedPath = "/tmp/ccpocket-managed/hash/artifact-only.png";
    codexThreadToSessionHistoryMock.mockReturnValue([
      {
        role: "tool_result",
        toolUseId: "image-generation-artifact-only",
        toolName: "ImageGeneration",
        content: "",
        imagePaths: [rawPath],
      },
    ]);
    const imageStore = {
      extractImagePaths: vi.fn(),
      registerImages: vi.fn(async () => []),
      registerFromBase64: vi.fn(),
    };
    const artifactManager = {
      materializeGeneratedCandidates: vi.fn(async () => [managedPath]),
      registerCandidates: vi.fn(async () => [
        {
          id: "artifact-only-ref",
          filename: "artifact-only.png",
          mimeType: "image/png",
          sizeBytes: 10,
          kind: "preview",
          source: "image_generation",
        },
      ]),
    };
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      imageStore: imageStore as any,
      artifactManager: artifactManager as any,
    });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;

    await (bridge as any).handleClientMessage(
      { type: "start", projectPath: "/tmp/project-codex", provider: "codex" },
      ws,
    );
    await Promise.resolve();
    await Promise.resolve();
    const sessionId = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find(
        (message: any) =>
          message.type === "system" && message.subtype === "session_created",
      ).sessionId as string;
    const session = (bridge as any).sessionManager.get(sessionId);
    session.claudeSessionId = "thread-artifact-only";
    session.process.readThread.mockResolvedValue({
      id: "thread-artifact-only",
      turns: [],
    });

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      { type: "get_history", sessionId },
      ws,
    );
    const history = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.type === "history");
    expect(history.messages).toEqual([
      expect.objectContaining({
        type: "tool_result",
        toolUseId: "image-generation-artifact-only",
        content: "",
        artifacts: [expect.objectContaining({ id: "artifact-only-ref" })],
      }),
    ]);
    expect(history.messages[0]).not.toHaveProperty("images");
    expect(history.messages[0]).not.toHaveProperty("artifactCandidates");
    bridge.close();
  });

  it("keeps legacy canonical image path extraction when artifacts are disabled", async () => {
    const rawPath = "/tmp/codex/generated_images/legacy.png";
    codexThreadToSessionHistoryMock.mockReturnValue([
      {
        role: "tool_result",
        toolUseId: "image-generation-legacy-history",
        toolName: "ImageGeneration",
        content: `savedPath: ${rawPath}`,
        imagePaths: [rawPath],
      },
    ]);
    const imageRef = {
      id: "img-legacy-history",
      url: "/images/img-legacy-history",
      mimeType: "image/png",
    };
    const imageStore = {
      extractImagePaths: vi.fn(() => ["/legacy.png"]),
      registerImages: vi.fn(async () => [imageRef]),
      registerFromBase64: vi.fn(),
    };
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      imageStore: imageStore as any,
    });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;

    await (bridge as any).handleClientMessage(
      { type: "start", projectPath: "/tmp/project-codex", provider: "codex" },
      ws,
    );
    await Promise.resolve();
    await Promise.resolve();
    const created = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find(
        (message: any) =>
          message.type === "system" && message.subtype === "session_created",
      );
    const sessionId = created.sessionId as string;
    const session = (bridge as any).sessionManager.get(sessionId);
    session.claudeSessionId = "thread-legacy-history";
    session.process.readThread.mockResolvedValue({
      id: "thread-legacy-history",
      turns: [],
    });

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      { type: "get_history", sessionId },
      ws,
    );

    expect(imageStore.extractImagePaths).toHaveBeenCalledWith(
      `savedPath: ${rawPath}`,
    );
    expect(imageStore.registerImages).toHaveBeenCalledWith(
      [rawPath, "/legacy.png"],
      "/tmp/project-codex",
    );
    const history = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.type === "history");
    expect(history.messages[0]).toMatchObject({ images: [imageRef] });
    bridge.close();
  });

  it("keeps codex canonical user image refs in history snapshots", async () => {
    codexThreadToSessionHistoryMock.mockReturnValue([
      {
        role: "user",
        uuid: "codex:user-turn:1",
        content: [{ type: "text", text: "look at this" }],
        imageCount: 2,
        imagePaths: ["/tmp/project-codex/local.png"],
        imageBase64: [{ data: "aGVsbG8=", mimeType: "image/png" }],
      },
    ]);
    const imageStore = {
      registerImages: vi.fn(async () => [
        {
          id: "img-local",
          url: "/images/img-local",
          mimeType: "image/png",
        },
      ]),
      registerFromBase64: vi.fn(() => ({
        id: "img-base64",
        url: "/images/img-base64",
        mimeType: "image/png",
      })),
    };

    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      imageStore: imageStore as any,
    });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
      },
      ws,
    );
    await Promise.resolve();
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "system" && m.subtype === "session_created");
    const sessionId = created.sessionId as string;
    const session = (bridge as any).sessionManager.get(sessionId);
    session.claudeSessionId = "thr_codex_user_images";
    session.process.readThread.mockResolvedValue({
      id: "thr_codex_user_images",
      turns: [],
    });

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "get_history_delta",
        sessionId,
        sinceSeq: 0,
      },
      ws,
    );

    expect(imageStore.registerImages).toHaveBeenCalledWith(
      ["/tmp/project-codex/local.png"],
      resolve("/tmp/project-codex"),
    );
    expect(imageStore.registerFromBase64).toHaveBeenCalledWith(
      "aGVsbG8=",
      "image/png",
    );
    expect(extractMessageImagesMock).not.toHaveBeenCalled();
    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    expect(sends[0]).toMatchObject({
      type: "history_snapshot",
      messages: [
        {
          message: {
            type: "user_input",
            text: "look at this",
            imageCount: 2,
            images: [
              {
                id: "img-local",
                url: "/images/img-local",
                mimeType: "image/png",
              },
              {
                id: "img-base64",
                url: "/images/img-base64",
                mimeType: "image/png",
              },
            ],
          },
        },
      ],
    });
    expect(sends[0].messages[0].seq).toBe(sends[0].toSeq);
    expect(sends[0].toSeq).toBeGreaterThan(1);

    bridge.close();
  });

  it("scopes codex canonical history read failures without JSONL fallback", async () => {
    codexThreadToSessionHistoryMock.mockReturnValue([]);

    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
      },
      ws,
    );
    await Promise.resolve();
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "system" && m.subtype === "session_created");
    const sessionId = created.sessionId as string;
    const session = (bridge as any).sessionManager.get(sessionId);
    session.claudeSessionId = "thr_codex_error";
    session.process.readThread.mockRejectedValue(new Error("rpc unavailable"));

    for (const request of [
      { type: "get_history", sessionId },
      { type: "get_history_delta", sessionId, sinceSeq: 0 },
    ]) {
      ws.send.mockClear();
      await (bridge as any).handleClientMessage(request, ws);

      const sends = ws.send.mock.calls.map((c: unknown[]) =>
        JSON.parse(c[0] as string),
      );
      expect(sends).toEqual([
        {
          type: "error",
          message: "Failed to read Codex thread history",
          errorCode: "history_read_failed",
          sessionId,
        },
      ]);
    }
    expect(getCodexSessionHistoryMock).not.toHaveBeenCalled();

    bridge.close();
  });

  it("keeps restored image generation results in past history order", async () => {
    getSessionHistoryMock.mockResolvedValue([
      {
        role: "user",
        content: [{ type: "text", text: "$imagegen make a hero" }],
      },
      {
        role: "tool_result",
        toolUseId: "ig-1",
        toolName: "ImageGeneration",
        content: "status: completed\nsavedPath: /tmp/generated.png",
        imagePaths: ["/tmp/generated.png"],
      },
    ]);
    const imageStore = {
      extractImagePaths: vi.fn(() => []),
      registerImages: vi.fn(async () => [
        { id: "img-1", url: "/images/img-1", mimeType: "image/png" },
      ]),
    };

    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      imageStore: imageStore as any,
    });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "resume_session",
        sessionId: "claude-session-1",
        projectPath: "/tmp/project-a",
        provider: "claude",
      },
      ws,
    );

    await Promise.resolve();
    await Promise.resolve();
    const resumeSends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    const created = resumeSends.find(
      (m: any) => m.type === "system" && m.subtype === "session_created",
    );
    const newSessionId = created.sessionId as string;

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      { type: "get_history", sessionId: newSessionId },
      ws,
    );

    const historySends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    expect(historySends[0]).toMatchObject({
      type: "past_history",
      messages: [
        { role: "user" },
        {
          role: "tool_result",
          toolUseId: "ig-1",
          toolName: "ImageGeneration",
          images: [
            { id: "img-1", url: "/images/img-1", mimeType: "image/png" },
          ],
        },
      ],
    });
    expect(historySends[1]).toMatchObject({ type: "history", messages: [] });

    bridge.close();
  });

  it("restores user message images into past history", async () => {
    getSessionHistoryMock.mockResolvedValue([
      {
        role: "user",
        uuid: "user-msg-1",
        content: [{ type: "text", text: "What is in this image?" }],
        imageCount: 1,
      },
    ]);
    extractMessageImagesMock.mockResolvedValue([
      { base64: "aGVsbG8=", mimeType: "image/png" },
    ]);
    const imageStore = {
      registerFromBase64: vi.fn(() => ({
        id: "img-user",
        url: "/images/img-user",
        mimeType: "image/png",
      })),
    };

    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      imageStore: imageStore as any,
    });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "resume_session",
        sessionId: "claude-session-1",
        projectPath: "/tmp/project-a",
        provider: "claude",
      },
      ws,
    );

    await Promise.resolve();
    await Promise.resolve();
    const resumeSends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    const created = resumeSends.find(
      (m: any) => m.type === "system" && m.subtype === "session_created",
    );
    const newSessionId = created.sessionId as string;

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      { type: "get_history", sessionId: newSessionId },
      ws,
    );

    const historySends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    expect(extractMessageImagesMock).toHaveBeenCalledWith(
      "claude-session-1",
      "user-msg-1",
    );
    expect(historySends[0]).toMatchObject({
      type: "past_history",
      messages: [
        {
          role: "user",
          uuid: "user-msg-1",
          imageCount: 1,
          images: [
            { id: "img-user", url: "/images/img-user", mimeType: "image/png" },
          ],
        },
      ],
    });

    bridge.close();
  });

  it("registers restored image generation base64 results through regular history", async () => {
    getSessionHistoryMock.mockResolvedValue([
      {
        role: "tool_result",
        toolUseId: "ig-2",
        toolName: "ImageGeneration",
        content: "status: completed",
        imageBase64: [{ data: "aGVsbG8=", mimeType: "image/png" }],
      },
    ]);
    const imageStore = {
      extractImagePaths: vi.fn(() => []),
      registerImages: vi.fn(async () => []),
      registerFromBase64: vi.fn(() => ({
        id: "img-base64",
        url: "/images/img-base64",
        mimeType: "image/png",
      })),
    };

    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      imageStore: imageStore as any,
    });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "resume_session",
        sessionId: "claude-session-1",
        projectPath: "/tmp/project-a",
        provider: "claude",
      },
      ws,
    );

    await Promise.resolve();
    await Promise.resolve();
    const resumeSends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    const created = resumeSends.find(
      (m: any) => m.type === "system" && m.subtype === "session_created",
    );
    const newSessionId = created.sessionId as string;

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      { type: "get_history", sessionId: newSessionId },
      ws,
    );

    const historySends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    expect(imageStore.registerFromBase64).toHaveBeenCalledWith(
      "aGVsbG8=",
      "image/png",
    );
    expect(historySends[0]).toMatchObject({
      type: "past_history",
      messages: [
        {
          role: "tool_result",
          toolUseId: "ig-2",
          toolName: "ImageGeneration",
          images: [
            {
              id: "img-base64",
              url: "/images/img-base64",
              mimeType: "image/png",
            },
          ],
        },
      ],
    });
    expect(historySends[1]).toMatchObject({ type: "history", messages: [] });

    bridge.close();
  });

  it("allows Windows subdirectories under BRIDGE_ALLOWED_DIRS", async () => {
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      allowedDirs: ["D:\\Users\\alice"],
      platform: "win32",
    });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "D:\\Users\\alice\\src\\ccpocket",
        provider: "claude",
      },
      ws,
    );

    await Promise.resolve();

    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    const created = sends.find(
      (m: any) => m.type === "system" && m.subtype === "session_created",
    );
    expect(created).toBeDefined();
    expect(created.projectPath).toBe("D:\\Users\\alice\\src\\ccpocket");

    bridge.close();
  });

  it("returns unstaged diff for mixed ASCII and non-ASCII untracked paths", async () => {
    const projectPath = mkdtempSync(resolve(tmpdir(), "ccpocket-diff-"));
    execFileSync("git", ["init"], { cwd: projectPath });
    execFileSync("git", ["config", "user.email", "test@test.com"], {
      cwd: projectPath,
    });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: projectPath });
    writeFileSync(resolve(projectPath, "initial.txt"), "initial\n");
    execFileSync("git", ["add", "initial.txt"], { cwd: projectPath });
    execFileSync("git", ["commit", "-m", "initial"], { cwd: projectPath });
    mkdirSync(resolve(projectPath, "docs"));
    writeFileSync(resolve(projectPath, "docs", "啊.md"), "hello\n");
    writeFileSync(resolve(projectPath, "normal.txt"), "normal\n");

    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      allowedDirs: [projectPath],
    });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    try {
      await (bridge as any).handleClientMessage(
        {
          type: "get_diff",
          projectPath,
          staged: false,
        },
        ws,
      );

      await expect
        .poll(() =>
          ws.send.mock.calls
            .map((c: unknown[]) => JSON.parse(c[0] as string))
            .find((m: any) => m.type === "diff_result"),
        )
        .toBeDefined();

      const diffResult = ws.send.mock.calls
        .map((c: unknown[]) => JSON.parse(c[0] as string))
        .find((m: any) => m.type === "diff_result");
      expect(diffResult.error).toBeUndefined();
      expect(diffResult.diff).toContain("diff --git a/docs/啊.md b/docs/啊.md");
      expect(diffResult.diff).toContain("diff --git a/normal.txt b/normal.txt");
      expect(diffResult.diff).not.toContain("\\345\\225");
    } finally {
      bridge.close();
      rmSync(projectPath, { recursive: true, force: true });
    }
  });

  it("returns all diff for mixed staged and non-ASCII untracked paths", async () => {
    const projectPath = mkdtempSync(resolve(tmpdir(), "ccpocket-diff-"));
    execFileSync("git", ["init"], { cwd: projectPath });
    execFileSync("git", ["config", "user.email", "test@test.com"], {
      cwd: projectPath,
    });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: projectPath });
    writeFileSync(resolve(projectPath, "initial.txt"), "initial\n");
    execFileSync("git", ["add", "initial.txt"], { cwd: projectPath });
    execFileSync("git", ["commit", "-m", "initial"], { cwd: projectPath });
    writeFileSync(resolve(projectPath, "initial.txt"), "changed\n");
    execFileSync("git", ["add", "initial.txt"], { cwd: projectPath });
    mkdirSync(resolve(projectPath, "docs"));
    writeFileSync(resolve(projectPath, "docs", "啊.md"), "hello\n");

    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      allowedDirs: [projectPath],
    });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    try {
      await (bridge as any).handleClientMessage(
        {
          type: "get_diff",
          projectPath,
        },
        ws,
      );

      await expect
        .poll(() =>
          ws.send.mock.calls
            .map((c: unknown[]) => JSON.parse(c[0] as string))
            .find((m: any) => m.type === "diff_result"),
        )
        .toBeDefined();

      const diffResult = ws.send.mock.calls
        .map((c: unknown[]) => JSON.parse(c[0] as string))
        .find((m: any) => m.type === "diff_result");
      expect(diffResult.error).toBeUndefined();
      expect(diffResult.diff).toContain(
        "diff --git a/initial.txt b/initial.txt",
      );
      expect(diffResult.diff).toContain("diff --git a/docs/啊.md b/docs/啊.md");
      expect(diffResult.diff).not.toContain("\\345\\225");
    } finally {
      bridge.close();
      rmSync(projectPath, { recursive: true, force: true });
    }
  });

  it("echoes the get_diff requestId in diff_result and omits it when absent", async () => {
    const projectPath = mkdtempSync(resolve(tmpdir(), "ccpocket-diff-"));
    execFileSync("git", ["init"], { cwd: projectPath });
    execFileSync("git", ["config", "user.email", "test@test.com"], {
      cwd: projectPath,
    });
    execFileSync("git", ["config", "user.name", "Test"], { cwd: projectPath });
    writeFileSync(resolve(projectPath, "initial.txt"), "initial\n");
    execFileSync("git", ["add", "initial.txt"], { cwd: projectPath });
    execFileSync("git", ["commit", "-m", "initial"], { cwd: projectPath });
    writeFileSync(resolve(projectPath, "initial.txt"), "changed\n");

    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      allowedDirs: [projectPath],
    });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    try {
      await (bridge as any).handleClientMessage(
        { type: "get_diff", projectPath, requestId: "gitdiff-42" },
        ws,
      );

      await expect
        .poll(() =>
          ws.send.mock.calls
            .map((c: unknown[]) => JSON.parse(c[0] as string))
            .find((m: any) => m.type === "diff_result"),
        )
        .toBeDefined();

      const withId = ws.send.mock.calls
        .map((c: unknown[]) => JSON.parse(c[0] as string))
        .find((m: any) => m.type === "diff_result");
      expect(withId.requestId).toBe("gitdiff-42");
      expect(withId.diff).toContain("diff --git a/initial.txt b/initial.txt");

      // Legacy clients that send no requestId must not get one back.
      ws.send.mockClear();
      await (bridge as any).handleClientMessage(
        { type: "get_diff", projectPath },
        ws,
      );
      await expect
        .poll(() =>
          ws.send.mock.calls
            .map((c: unknown[]) => JSON.parse(c[0] as string))
            .find((m: any) => m.type === "diff_result"),
        )
        .toBeDefined();
      const withoutId = ws.send.mock.calls
        .map((c: unknown[]) => JSON.parse(c[0] as string))
        .find((m: any) => m.type === "diff_result");
      expect("requestId" in withoutId).toBe(false);
    } finally {
      bridge.close();
      rmSync(projectPath, { recursive: true, force: true });
    }
  });

  it("echoes the get_diff requestId on the error path too", async () => {
    const projectPath = mkdtempSync(resolve(tmpdir(), "ccpocket-nogit-"));

    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      allowedDirs: [projectPath],
    });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    try {
      await (bridge as any).handleClientMessage(
        { type: "get_diff", projectPath, requestId: "gitdiff-err-1" },
        ws,
      );

      await expect
        .poll(() =>
          ws.send.mock.calls
            .map((c: unknown[]) => JSON.parse(c[0] as string))
            .find((m: any) => m.type === "diff_result"),
        )
        .toBeDefined();

      const diffResult = ws.send.mock.calls
        .map((c: unknown[]) => JSON.parse(c[0] as string))
        .find((m: any) => m.type === "diff_result");
      expect(diffResult.errorCode).toBe("git_not_available");
      expect(diffResult.requestId).toBe("gitdiff-err-1");
    } finally {
      bridge.close();
      rmSync(projectPath, { recursive: true, force: true });
    }
  });

  it("echoes project and request identity in diff image results", async () => {
    const projectPath = mkdtempSync(resolve(tmpdir(), "ccpocket-diff-image-"));
    const pngBase64 =
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";
    writeFileSync(
      resolve(projectPath, "logo.png"),
      Buffer.from(pngBase64, "base64"),
    );

    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      allowedDirs: [projectPath],
    });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    try {
      await (bridge as any).handleClientMessage(
        {
          type: "get_diff_image",
          projectPath,
          filePath: "logo.png",
          version: "new",
          requestId: "gitimage-42",
        },
        ws,
      );

      await expect
        .poll(() =>
          ws.send.mock.calls
            .map((call: unknown[]) => JSON.parse(call[0] as string))
            .find((message: any) => message.type === "diff_image_result"),
        )
        .toBeDefined();
      const result = ws.send.mock.calls
        .map((call: unknown[]) => JSON.parse(call[0] as string))
        .find((message: any) => message.type === "diff_image_result");
      expect(result).toMatchObject({
        type: "diff_image_result",
        projectPath,
        requestId: "gitimage-42",
        filePath: "logo.png",
        version: "new",
        base64: pngBase64,
      });
    } finally {
      bridge.close();
      rmSync(projectPath, { recursive: true, force: true });
    }
  });

  it("returns base64 image data for image file peek", async () => {
    const projectPath = mkdtempSync(resolve(tmpdir(), "ccpocket-bridge-"));
    const pngBase64 =
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";
    writeFileSync(
      resolve(projectPath, "pixel.png"),
      Buffer.from(pngBase64, "base64"),
    );

    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      allowedDirs: [projectPath],
    });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    try {
      await (bridge as any).handleClientMessage(
        {
          type: "read_file",
          requestId: "file-image-1",
          projectPath,
          filePath: "pixel.png",
        },
        ws,
      );

      await expect.poll(() => ws.send.mock.calls.length).toBeGreaterThan(0);

      const sends = ws.send.mock.calls.map((c: unknown[]) =>
        JSON.parse(c[0] as string),
      );
      expect(sends).toContainEqual({
        type: "file_content",
        requestId: "file-image-1",
        filePath: "pixel.png",
        kind: "image",
        content: "",
        base64: pngBase64,
        mimeType: "image/png",
        sizeBytes: Buffer.from(pngBase64, "base64").length,
      });
    } finally {
      bridge.close();
      rmSync(projectPath, { recursive: true, force: true });
    }
  });

  it("keeps text file peek responses as text content", async () => {
    const projectPath = mkdtempSync(resolve(tmpdir(), "ccpocket-bridge-"));
    writeFileSync(resolve(projectPath, "README.md"), "# Hello\n\nWorld\n");

    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      allowedDirs: [projectPath],
    });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    try {
      await (bridge as any).handleClientMessage(
        {
          type: "read_file",
          projectPath,
          filePath: "README.md",
        },
        ws,
      );

      await expect.poll(() => ws.send.mock.calls.length).toBeGreaterThan(0);

      const sends = ws.send.mock.calls.map((c: unknown[]) =>
        JSON.parse(c[0] as string),
      );
      expect(sends).toContainEqual({
        type: "file_content",
        filePath: "README.md",
        kind: "text",
        content: "# Hello\n\nWorld\n",
        language: "markdown",
        totalLines: 4,
        truncated: false,
      });
    } finally {
      bridge.close();
      rmSync(projectPath, { recursive: true, force: true });
    }
  });

  it("bounds minified JSON file peek before sending it to Mobile", async () => {
    const projectPath = mkdtempSync(resolve(tmpdir(), "ccpocket-bridge-json-"));
    const minified = `{"payload":"${"x".repeat(1024 * 1024)}"}`;
    writeFileSync(resolve(projectPath, "large.json"), minified);

    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      allowedDirs: [projectPath],
    });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    try {
      await (bridge as any).handleClientMessage(
        {
          type: "read_file",
          requestId: "file-minified-json",
          projectPath,
          filePath: "large.json",
        },
        ws,
      );

      await expect.poll(() => ws.send.mock.calls.length).toBeGreaterThan(0);
      const response = ws.send.mock.calls
        .map((call: unknown[]) => JSON.parse(call[0] as string))
        .find(
          (message: any) =>
            message.type === "file_content" &&
            message.requestId === "file-minified-json",
        );

      expect(response).toMatchObject({
        kind: "text",
        language: "json",
        totalLines: 1,
        truncated: true,
      });
      expect(response.content).toHaveLength(64 * 1024);
      expect(response.content).toMatch(/^{"payload":"x+/);
    } finally {
      bridge.close();
      rmSync(projectPath, { recursive: true, force: true });
    }
  });

  it("keeps file peek inside the canonical project root", async () => {
    const root = mkdtempSync(resolve(tmpdir(), "ccpocket-bridge-scope-"));
    const projectPath = resolve(root, "project");
    const outsidePath = resolve(root, "outside");
    mkdirSync(projectPath);
    mkdirSync(outsidePath);
    writeFileSync(resolve(outsidePath, "secret.txt"), "secret");
    symlinkSync(
      resolve(outsidePath, "secret.txt"),
      resolve(projectPath, "escape.txt"),
    );

    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      // Both paths are globally allowed; read_file must still remain scoped to
      // the project root named by this request.
      allowedDirs: [root],
    });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    try {
      for (const [requestId, filePath] of [
        ["file-traversal", "../outside/secret.txt"],
        ["file-symlink", "escape.txt"],
      ] as const) {
        const before = ws.send.mock.calls.length;
        await (bridge as any).handleClientMessage(
          { type: "read_file", requestId, projectPath, filePath },
          ws,
        );
        await expect
          .poll(() => ws.send.mock.calls.length)
          .toBeGreaterThan(before);
      }

      const responses = ws.send.mock.calls.map((call: unknown[]) =>
        JSON.parse(call[0] as string),
      );
      expect(responses).toEqual(
        expect.arrayContaining([
          {
            type: "file_content",
            requestId: "file-traversal",
            filePath: "../outside/secret.txt",
            content: "",
            error: "Path not allowed",
          },
          {
            type: "file_content",
            requestId: "file-symlink",
            filePath: "escape.txt",
            content: "",
            error: "Path not allowed",
          },
        ]),
      );
      expect(
        responses.some((response: any) => response.content === "secret"),
      ).toBe(false);
    } finally {
      bridge.close();
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("returns a friendly error for symbolic links to directories", async () => {
    const projectPath = mkdtempSync(resolve(tmpdir(), "ccpocket-bridge-"));
    const targetDir = resolve(projectPath, "target-dir");
    const symlinkPath = resolve(projectPath, "linked-dir");
    mkdirSync(targetDir);
    symlinkSync("target-dir", symlinkPath);

    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      allowedDirs: [projectPath],
    });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    try {
      (bridge as any).handleClientMessage(
        {
          type: "read_file",
          projectPath,
          filePath: "linked-dir",
        },
        ws,
      );

      await expect.poll(() => ws.send.mock.calls.length).toBeGreaterThan(0);

      const sends = ws.send.mock.calls.map((c: unknown[]) =>
        JSON.parse(c[0] as string),
      );
      expect(sends).toContainEqual({
        type: "file_content",
        filePath: "linked-dir",
        content: "",
        error:
          "This symbolic link points to a directory (target-dir). Open the target directory instead.",
      });
    } finally {
      bridge.close();
      rmSync(projectPath, { recursive: true, force: true });
    }
  });

  it("normalizes extended Windows project paths during resume", async () => {
    getCodexSessionHistoryMock.mockResolvedValue([]);

    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      allowedDirs: ["D:\\Users\\alice"],
      platform: "win32",
    });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "resume_session",
        sessionId: "thr-win32",
        projectPath: "\\\\?\\D:\\Users\\alice\\src\\ccpocket",
        provider: "codex",
      },
      ws,
    );

    await Promise.resolve();
    await Promise.resolve();

    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    const created = sends.find(
      (m: any) => m.type === "system" && m.subtype === "session_created",
    );
    expect(created).toBeDefined();
    expect(created.projectPath).toBe("D:\\Users\\alice\\src\\ccpocket");

    bridge.close();
  });

  it("sends provider=codex on codex resume_session", async () => {
    getCodexSessionHistoryMock.mockResolvedValue([
      {
        role: "user",
        content: [{ type: "text", text: "restored codex question" }],
      },
    ]);

    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      platform: "darwin",
      codexActionBrokerRuntime: writableCodexActionBrokerRuntime(),
    });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    (bridge as any).clientSupportedServerMessages.set(
      ws,
      new Set(["session_link_progress_v1"]),
    );

    await (bridge as any).handleClientMessage(
      {
        type: "resume_session",
        sessionId: "codex-thread-1",
        projectPath: "/tmp/project-codex",
        provider: "codex",
        resumeRequestId: "link-request-codex",
        sessionLinkGeneration: 17,
      },
      ws,
    );

    await Promise.resolve();
    await Promise.resolve();

    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    const created = sends.find(
      (m: any) => m.type === "system" && m.subtype === "session_created",
    );
    expect(created).toBeDefined();
    expect(created.provider).toBe("codex");
    expect(created.claudeSessionId).toBe("codex-thread-1");
    expect(created.sourceSessionId).toBeUndefined();
    expect(created.resumeRequestId).toBe("link-request-codex");
    const resumeStartedIndex = sends.findIndex(
      (message: any) =>
        message.type === "system" &&
        message.subtype === "session_resume_started",
    );
    const sessionCreatedIndex = sends.findIndex(
      (message: any) =>
        message.type === "system" && message.subtype === "session_created",
    );
    expect(resumeStartedIndex).toBeGreaterThanOrEqual(0);
    expect(resumeStartedIndex).toBeLessThan(sessionCreatedIndex);
    expect(sends[resumeStartedIndex]).toMatchObject({
      sourceSessionId: "codex-thread-1",
      provider: "codex",
      projectPath: "/tmp/project-codex",
      resumeRequestId: "link-request-codex",
    });
    expect(getCodexSessionHistoryMock).toHaveBeenCalledTimes(1);
    expect(getCodexSessionHistoryMock).toHaveBeenCalledWith("codex-thread-1");
    expect(
      (bridge as any).sessionManager.get(created.sessionId).pastMessages,
    ).toEqual([
      {
        role: "user",
        content: [{ type: "text", text: "restored codex question" }],
      },
    ]);
    expect(
      sends
        .filter((message: any) => message.type === "session_link_progress_v1")
        .map((message: any) => message.stage),
    ).toEqual([
      "request_accepted",
      "resume_lock_waiting",
      "resume_lock_acquired",
      "history_reading",
      "history_read",
      "runtime_starting",
      "metadata_loading",
      "ready",
    ]);

    bridge.close();
  });

  it("waits for a settings-neutral daemon adoption before reporting resume ready", async () => {
    vi.stubEnv("BRIDGE_CODEX_APP_SERVER_MODE", "daemon");
    getCodexSessionHistoryMock.mockResolvedValue([
      {
        role: "user",
        content: [{ type: "text", text: "must stay deferred" }],
      },
    ]);

    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      platform: "darwin",
      codexActionBrokerRuntime: writableCodexActionBrokerRuntime(),
    });
    const manager = (bridge as any).sessionManager;
    const originalCreate = manager.create.bind(manager);
    let resolveAttachment!: () => void;
    const attachmentReady = new Promise<void>((resolve) => {
      resolveAttachment = resolve;
    });
    vi.spyOn(manager, "create").mockImplementation((...args: unknown[]) => {
      const id = originalCreate(...args);
      manager.get(id).process.waitUntilAttached = vi.fn(() => attachmentReady);
      manager.get(id).process.isAttachmentReady = false;
      return id;
    });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    (bridge as any).clientSupportedServerMessages.set(
      ws,
      new Set(["session_link_progress_v1"]),
    );

    const resume = (bridge as any).handleClientMessage(
      {
        type: "resume_session",
        sessionId: "codex-daemon-thread",
        projectPath: "/tmp/project-codex",
        provider: "codex",
        model: "must-not-be-replayed",
        modelReasoningEffort: "high",
        sandboxMode: "danger-full-access",
        approvalPolicy: "never",
        resumeRequestId: "daemon-resume-request",
        sessionLinkGeneration: 23,
      },
      ws,
    );

    await vi.waitFor(() => expect(manager.get("s-1")).toBeDefined());
    const pendingSession = manager.get("s-1");
    expect(pendingSession.codexOptions).toEqual({
      threadId: "codex-daemon-thread",
      sharedRuntimeAttach: "adoption",
    });
    expect(pendingSession.pastMessages).toEqual([]);
    expect(getCodexSessionHistoryMock).not.toHaveBeenCalled();
    expect(pendingSession.process.readThread).not.toHaveBeenCalled();
    expect(manager.create.mock.calls[0]?.[2]).toEqual([]);
    expect(
      ws.send.mock.calls
        .map((call: unknown[]) => JSON.parse(call[0] as string))
        .some(
          (message: any) =>
            message.type === "system" && message.subtype === "session_created",
        ),
    ).toBe(false);

    resolveAttachment();
    await resume;
    expect(pendingSession.process.waitUntilAttached).toHaveBeenCalledWith(
      30_000,
    );
    expect(
      ws.send.mock.calls
        .map((call: unknown[]) => JSON.parse(call[0] as string))
        .some(
          (message: any) =>
            message.type === "system" && message.subtype === "session_created",
        ),
    ).toBe(true);
    const messages = ws.send.mock.calls.map((call: unknown[]) =>
      JSON.parse(call[0] as string),
    );
    expect(
      messages
        .filter((message: any) => message.type === "session_link_progress_v1")
        .map((message: any) => message.stage),
    ).toEqual([
      "request_accepted",
      "resume_lock_waiting",
      "resume_lock_acquired",
      "runtime_starting",
      "metadata_loading",
      "ready",
    ]);
    expect(
      messages.some(
        (message: any) =>
          message.stage === "history_reading" ||
          message.stage === "history_read",
      ),
    ).toBe(false);
    expect(pendingSession.codexInitialHistoryPending).toBe(false);

    await (bridge as any).handleClientMessage(
      { type: "get_history", sessionId: pendingSession.id },
      ws,
    );
    expect(pendingSession.process.readThread).toHaveBeenCalledWith(
      "codex-daemon-thread",
      true,
    );

    bridge.close();
  });

  it("projects private, shared-owned, foreign, and disconnected runtime authority", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-runtime-authority",
        provider: "codex",
      },
      ws,
    );
    const created = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find(
        (message: any) =>
          message.type === "system" && message.subtype === "session_created",
      );
    const session = (bridge as any).sessionManager.get(created.sessionId);
    const process = session.process;
    delete process.usesSharedRuntimeTopology;
    Object.setPrototypeOf(process, CodexProcess.prototype);
    process.sessionId = "thread-runtime-authority";
    session.claudeSessionId = "thread-runtime-authority";
    process._authorityGeneration = "authority-private";
    process._sharedRuntimePilotGates = null;
    process._sharedRuntimeAttachMode = null;
    process._lastStopWasSharedRuntime = false;
    process.sharedRuntimeOwnedTurnIds = new Set<string>();
    process.stopped = false;
    process.status = "running";
    process.activeTurnId = "private-turn";
    process.isRunning = true;
    process.isAttachmentReady = true;

    const runtime = (bridge as any).localFeatures.runtime;
    const state = () =>
      runtime
        .listRuntimeConversationStates()
        .find((item: any) => item.bridgeSessionId === session.id);

    expect(state()).toMatchObject({
      executionHost: "bridge",
      activeTurnId: "private-turn",
      controlState: "steerable",
      authorityGeneration: "authority-private",
    });
    expect(runtime.isCodexThreadLocallyActive("thread-runtime-authority")).toBe(
      true,
    );
    expect(
      runtime.getLocallyActiveCodexTurnId("thread-runtime-authority"),
    ).toBe("private-turn");
    expect(runtime.getSessionCodexActiveTurnId(session.id)).toBe(
      "private-turn",
    );

    process._sharedRuntimePilotGates = {
      enabled: true,
      codexSourceId: "source-one",
      allowThreadStart: true,
      allowTurnStart: true,
    };
    process._sharedRuntimeAttachMode = "adoption";
    process._lastStopWasSharedRuntime = false;
    process._authorityGeneration = "authority-shared";
    process.activeTurnId = "desktop-turn";
    process.sharedRuntimeOwnedTurnIds.clear();

    expect(state()).toMatchObject({
      executionHost: "desktopAppServer",
      activeTurnId: "desktop-turn",
      controlState: "readOnly",
      authorityGeneration: "authority-shared",
    });
    expect(runtime.isCodexThreadLocallyActive("thread-runtime-authority")).toBe(
      false,
    );
    expect(
      runtime.getLocallyActiveCodexTurnId("thread-runtime-authority"),
    ).toBeUndefined();
    expect(runtime.getSessionCodexActiveTurnId(session.id)).toBeUndefined();

    process.sharedRuntimeOwnedTurnIds.add("desktop-turn");
    expect(state()).toMatchObject({
      executionHost: "bridge",
      activeTurnId: "desktop-turn",
      controlState: "steerable",
      authorityGeneration: "authority-shared",
    });
    expect(
      runtime.getLocallyActiveCodexTurnId("thread-runtime-authority"),
    ).toBe("desktop-turn");

    // A lost shared attachment must fail closed even if the retired process
    // still carries a stale running/owned turn snapshot. Recovery phases are
    // authority state, not synthetic Working activity.
    session.codexAttachmentState = "unavailable";
    expect(state()).toMatchObject({
      executionHost: "unknown",
      controlState: "unavailable",
      authorityGeneration: "authority-shared",
    });
    expect(state()).not.toHaveProperty("activeTurnId");

    session.codexAttachmentState = "reconciling";
    expect(state()).toMatchObject({
      executionHost: "unknown",
      controlState: "reconciling",
      authorityGeneration: "authority-shared",
    });
    expect(state()).not.toHaveProperty("activeTurnId");
    session.codexAttachmentState = "connected";

    process.isRunning = false;
    process.status = "starting";
    process.isAttachmentReady = false;
    expect(state()).toMatchObject({
      executionHost: "unknown",
      controlState: "unavailable",
      authorityGeneration: "authority-shared",
    });
    expect(state()).not.toHaveProperty("activeTurnId");

    process.isRunning = true;
    expect(state()).toMatchObject({
      executionHost: "unknown",
      controlState: "reconciling",
      authorityGeneration: "authority-shared",
    });
    expect(state()).not.toHaveProperty("activeTurnId");

    await bridge.close();
  });

  it("waits for authoritative daemon thread/start before reporting a new session", async () => {
    vi.stubEnv("BRIDGE_CODEX_APP_SERVER_MODE", "daemon");
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      platform: "darwin",
      codexActionBrokerRuntime: writableCodexActionBrokerRuntime(),
    });
    const manager = (bridge as any).sessionManager;
    const originalCreate = manager.create.bind(manager);
    let resolveAttachment!: () => void;
    const attachmentReady = new Promise<void>((resolve) => {
      resolveAttachment = resolve;
    });
    vi.spyOn(manager, "create").mockImplementation((...args: unknown[]) => {
      const id = originalCreate(...args);
      manager.get(id).process.waitUntilAttached = vi.fn(() => attachmentReady);
      manager.get(id).process.isAttachmentReady = false;
      return id;
    });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;

    const start = (bridge as any).handleClientMessage(
      {
        type: "start",
        provider: "codex",
        projectPath: "/tmp/project-codex",
        startRequestId: "daemon-start-request",
      },
      ws,
    );
    await vi.waitFor(() => expect(manager.get("s-1")).toBeDefined());
    expect(
      ws.send.mock.calls
        .map((call: unknown[]) => JSON.parse(call[0] as string))
        .some((message: any) => message.subtype === "session_created"),
    ).toBe(false);

    resolveAttachment();
    await start;
    expect(manager.get("s-1").process.waitUntilAttached).toHaveBeenCalledWith(
      30_000,
    );
    expect(
      ws.send.mock.calls
        .map((call: unknown[]) => JSON.parse(call[0] as string))
        .some(
          (message: any) =>
            message.subtype === "session_created" &&
            message.startRequestId === "daemon-start-request",
        ),
    ).toBe(true);

    bridge.close();
  });

  it("reuses the Codex history loaded by resume for the first get_history", async () => {
    getCodexSessionHistoryMock.mockResolvedValue([
      {
        role: "user",
        content: [{ type: "text", text: "restored once" }],
      },
    ]);

    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      platform: "darwin",
    });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "resume_session",
        sessionId: "codex-thread-single-read",
        projectPath: "/tmp/project-codex",
        provider: "codex",
      },
      ws,
    );

    const created = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find(
        (message: any) =>
          message.type === "system" && message.subtype === "session_created",
      );

    await (bridge as any).handleClientMessage(
      { type: "get_history", sessionId: created.sessionId },
      ws,
    );

    const session = (bridge as any).sessionManager.get(created.sessionId);
    expect(getCodexSessionHistoryMock).toHaveBeenCalledTimes(1);
    expect(session.process.readThread).not.toHaveBeenCalled();
    expect(session.codexInitialHistoryPending).toBe(false);
    const history = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.type === "history");
    expect(history.messages).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          type: "user_input",
          text: "restored once",
        }),
      ]),
    );

    bridge.close();
  });

  it("joins duplicate Codex resumes without loading or creating twice", async () => {
    let resolveHistory!: (history: unknown[]) => void;
    getCodexSessionHistoryMock.mockReturnValue(
      new Promise((resolve) => {
        resolveHistory = resolve;
      }),
    );

    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      platform: "darwin",
    });
    const firstWs = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    const reconnectWs = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    const request = {
      type: "resume_session",
      sessionId: "codex-thread-idempotent",
      projectPath: "/tmp/project-codex",
      provider: "codex",
    };

    const firstResume = (bridge as any).handleClientMessage(request, firstWs);
    const duplicateResume = (bridge as any).handleClientMessage(
      request,
      reconnectWs,
    );

    await vi.waitFor(() => {
      expect(getCodexSessionHistoryMock).toHaveBeenCalledTimes(1);
    });
    resolveHistory([
      {
        role: "user",
        content: [{ type: "text", text: "restored once" }],
      },
    ]);
    await Promise.all([firstResume, duplicateResume]);

    const firstCreated = firstWs.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find(
        (message: any) =>
          message.type === "system" && message.subtype === "session_created",
      );
    const reconnectCreated = reconnectWs.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find(
        (message: any) =>
          message.type === "system" && message.subtype === "session_created",
      );

    expect(firstCreated.sessionId).toBe("s-1");
    expect(reconnectCreated.sessionId).toBe(firstCreated.sessionId);
    expect(getCodexSessionHistoryMock).toHaveBeenCalledTimes(1);

    bridge.close();
  });

  it("does not reload an empty Codex history on the first get_history", async () => {
    getCodexSessionHistoryMock.mockResolvedValue([]);

    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      platform: "darwin",
    });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "resume_session",
        sessionId: "codex-thread-empty",
        projectPath: "/tmp/project-codex",
        provider: "codex",
      },
      ws,
    );

    const created = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find(
        (message: any) =>
          message.type === "system" && message.subtype === "session_created",
      );

    await (bridge as any).handleClientMessage(
      { type: "get_history", sessionId: created.sessionId },
      ws,
    );

    expect(getCodexSessionHistoryMock).toHaveBeenCalledTimes(1);

    bridge.close();
  });

  it("preserves internal codex sandbox mode on resume_session", async () => {
    getCodexSessionHistoryMock.mockResolvedValue([
      {
        role: "user",
        content: [{ type: "text", text: "restored codex question" }],
      },
    ]);

    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "resume_session",
        sessionId: "codex-thread-danger",
        projectPath: "/tmp/project-codex",
        provider: "codex",
        sandboxMode: "danger-full-access",
      },
      ws,
    );

    await Promise.resolve();
    await Promise.resolve();

    const session = (bridge as any).sessionManager.get("s-1");
    expect(session.codexOptions?.sandboxMode).toBe("danger-full-access");

    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    const created = sends.find(
      (m: any) => m.type === "system" && m.subtype === "session_created",
    );
    expect(created?.sandboxMode).toBe("off");

    bridge.close();
  });

  it("uses stored worktree mapping for codex resume when available", async () => {
    getCodexSessionHistoryMock.mockResolvedValue([
      {
        role: "user",
        content: [{ type: "text", text: "restored codex question" }],
      },
    ]);

    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    const worktreeStore = (bridge as any).worktreeStore;
    vi.spyOn(worktreeStore, "get").mockReturnValue({
      worktreePath: "/tmp/project-main-worktrees/feature-x",
      worktreeBranch: "feature/x",
      projectPath: "/tmp/project-main",
    });

    await (bridge as any).handleClientMessage(
      {
        type: "resume_session",
        sessionId: "codex-thread-with-mapping",
        projectPath: "/tmp/incorrect-project-path",
        provider: "codex",
      },
      ws,
    );

    await Promise.resolve();
    await Promise.resolve();

    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    const created = sends.find(
      (m: any) => m.type === "system" && m.subtype === "session_created",
    );
    expect(created).toBeDefined();
    expect(created.provider).toBe("codex");
    expect(created.projectPath).toBe(resolve("/tmp/project-main"));

    bridge.close();
  });

  it("forwards set_permission_mode to Claude session process", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-a",
        provider: "claude",
      },
      ws,
    );
    await Promise.resolve();

    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    const created = sends.find(
      (m: any) => m.type === "system" && m.subtype === "session_created",
    );
    expect(created).toBeDefined();
    const sessionId = created.sessionId as string;

    const session = (bridge as any).sessionManager.get(sessionId);
    const setPermissionModeMock = session.process
      .setPermissionMode as ReturnType<typeof vi.fn>;

    const callCountBefore = ws.send.mock.calls.length;
    (bridge as any).handleClientMessage(
      {
        type: "set_permission_mode",
        sessionId,
        mode: "plan",
      },
      ws,
    );
    await Promise.resolve();

    expect(setPermissionModeMock).toHaveBeenCalledTimes(1);
    expect(setPermissionModeMock).toHaveBeenCalledWith("plan");
    expect(ws.send.mock.calls).toHaveLength(callCountBefore);

    bridge.close();
  });

  it("falls back Claude auto mode to default on start when auto is unavailable", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    const sessionManager = (bridge as any).sessionManager;
    const realCreate = sessionManager.create.bind(sessionManager);
    let failFirstCreate = true;
    const createSpy = vi
      .spyOn(sessionManager, "create")
      .mockImplementation((...args: any[]) => {
        if (failFirstCreate) {
          failFirstCreate = false;
          throw new Error(
            'Permission mode "auto" is unavailable for your plan',
          );
        }
        return realCreate(...args);
      });

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-auto",
        provider: "claude",
        permissionMode: "auto",
      },
      ws,
    );
    await Promise.resolve();
    await Promise.resolve();

    expect(createSpy.mock.calls[0]?.[1]?.permissionMode).toBe("auto");
    expect(createSpy.mock.calls[1]?.[1]?.permissionMode).toBe("default");

    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    const created = sends.find(
      (m: any) => m.type === "system" && m.subtype === "session_created",
    );
    const tip = sends.find(
      (m: any) => m.type === "system" && m.subtype === "tip",
    );

    expect(created).toMatchObject({
      permissionMode: "default",
      executionMode: "default",
      planMode: false,
    });
    expect(tip).toMatchObject({
      tipCode: "auto_mode_fallback_default",
      sessionId: created.sessionId,
    });

    bridge.close();
  });

  it("falls back Claude auto mode to default on resume when auto is unavailable", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    getSessionHistoryMock.mockResolvedValue([]);

    const sessionManager = (bridge as any).sessionManager;
    const realCreate = sessionManager.create.bind(sessionManager);
    let failFirstCreate = true;
    const createSpy = vi
      .spyOn(sessionManager, "create")
      .mockImplementation((...args: any[]) => {
        if (failFirstCreate) {
          failFirstCreate = false;
          throw new Error(
            'Permission mode "auto" is unavailable for your plan',
          );
        }
        return realCreate(...args);
      });

    (bridge as any).handleClientMessage(
      {
        type: "resume_session",
        sessionId: "claude-resume-1",
        projectPath: "/tmp/project-auto",
        provider: "claude",
        permissionMode: "auto",
      },
      ws,
    );
    await Promise.resolve();
    await Promise.resolve();

    expect(createSpy.mock.calls[0]?.[1]?.permissionMode).toBe("auto");
    expect(createSpy.mock.calls[1]?.[1]?.permissionMode).toBe("default");

    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    const created = sends.find(
      (m: any) => m.type === "system" && m.subtype === "session_created",
    );
    const tip = sends.find(
      (m: any) => m.type === "system" && m.subtype === "tip",
    );

    expect(created).toMatchObject({
      permissionMode: "default",
      executionMode: "default",
      planMode: false,
      claudeSessionId: "claude-resume-1",
    });
    expect(tip).toMatchObject({
      tipCode: "auto_mode_fallback_default",
      sessionId: created.sessionId,
    });

    bridge.close();
  });

  it("returns structured error when Claude auto mode cannot be enabled in-session", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-a",
        provider: "claude",
      },
      ws,
    );
    await Promise.resolve();

    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    const created = sends.find(
      (m: any) => m.type === "system" && m.subtype === "session_created",
    );
    expect(created).toBeDefined();

    const sessionId = created.sessionId as string;
    const session = (bridge as any).sessionManager.get(sessionId);
    const setPermissionModeMock = session.process
      .setPermissionMode as ReturnType<typeof vi.fn>;
    setPermissionModeMock.mockRejectedValue(
      new Error('Permission mode "auto" is unavailable for your plan'),
    );

    (bridge as any).handleClientMessage(
      {
        type: "set_permission_mode",
        sessionId,
        mode: "auto",
      },
      ws,
    );
    await Promise.resolve();
    await Promise.resolve();

    const last = JSON.parse(ws.send.mock.calls.at(-1)?.[0] as string);
    expect(last).toEqual({
      type: "error",
      message:
        "Auto mode is unavailable in this environment. Keeping the current permission mode.",
      errorCode: "auto_mode_unavailable",
    });

    bridge.close();
  });

  it("maps set_permission_mode plan to collaborationMode for codex session in-place when idle", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
      },
      ws,
    );
    await Promise.resolve();

    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    const created = sends.find(
      (m: any) => m.type === "system" && m.subtype === "session_created",
    );
    expect(created).toBeDefined();
    const sessionId = created.sessionId as string;

    const session = (bridge as any).sessionManager.get(sessionId);
    expect(session).toBeDefined();
    session.status = "idle";
    (session.process as any).setApprovalPolicy("on-request");

    (bridge as any).handleClientMessage(
      {
        type: "set_permission_mode",
        sessionId,
        mode: "plan",
      },
      ws,
    );

    const updatedSession = (bridge as any).sessionManager.get(sessionId);
    expect(updatedSession).toBeDefined();
    expect(updatedSession.id).toBe(sessionId);
    expect((bridge as any).sessionManager.list()).toHaveLength(1);

    bridge.close();
  });

  it("does not fabricate an approval policy for a collaboration-only change when the policy is unknown", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    (bridge as any).wss.clients.add(ws);

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex-unknown-policy",
        provider: "codex",
      },
      ws,
    );
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.subtype === "session_created");
    const sessionId = created.sessionId as string;
    const session = (bridge as any).sessionManager.get(sessionId);
    session.status = "idle";
    // Model a Desktop-created thread taken over via resume: neither the
    // stored settings nor the runtime ever had a resolved policy.
    session.process.approvalPolicy = undefined;
    if (session.codexSettings) delete session.codexSettings.approvalPolicy;
    ws.send.mockClear();

    await (bridge as any).handleClientMessage(
      {
        type: "set_permission_mode",
        sessionId,
        mode: "plan",
        planMode: true,
        permissionChangeId: "collab-unknown-1",
      },
      ws,
    );

    expect(session.process.collaborationMode).toBe("plan");
    expect(session.process.setApprovalPolicy).not.toHaveBeenCalled();
    expect(session.codexSettings?.approvalPolicy).toBeUndefined();
    const modeMsg = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find(
        (message: any) =>
          message.type === "system" &&
          message.subtype === "set_permission_mode",
      );
    expect(modeMsg).toBeDefined();
    expect(modeMsg).not.toHaveProperty("approvalPolicy");

    bridge.close();
  });

  it("omits the fabricated approval policy from a plan-toggle restart when the policy is unknown", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex-unknown-policy-restart",
        provider: "codex",
      },
      ws,
    );
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.subtype === "session_created");
    const sessionId = created.sessionId as string;
    const session = (bridge as any).sessionManager.get(sessionId);
    session.status = "running";
    session.process.approvalPolicy = undefined;
    const createSpy = vi.spyOn((bridge as any).sessionManager, "create");

    await (bridge as any).handleClientMessage(
      {
        type: "set_permission_mode",
        sessionId,
        mode: "plan",
      },
      ws,
    );

    expect(createSpy).toHaveBeenCalledTimes(1);
    const codexOptions = createSpy.mock.calls[0][5] as Record<string, unknown>;
    // A fabricated "on-request" here would override the user's config-file
    // policy on the replacement thread.
    expect(codexOptions.approvalPolicy).toBeUndefined();

    bridge.close();
  });

  it("carries a pending plan approval across a permission restart", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex-plan-carry",
        provider: "codex",
      },
      ws,
    );
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.subtype === "session_created");
    const sessionId = created.sessionId as string;
    const session = (bridge as any).sessionManager.get(sessionId);
    // The plan approval is on screen while the user switches execution mode.
    session.status = "waiting_approval";
    session.process.collaborationMode = "plan";
    session.process.pendingPlanCompletionSnapshot = {
      toolUseId: "plan_carry_1",
      planText: "Execute the reviewed plan",
    };
    const createSpy = vi.spyOn((bridge as any).sessionManager, "create");

    await (bridge as any).handleClientMessage(
      {
        type: "set_permission_mode",
        sessionId,
        mode: "plan",
        planMode: true,
        executionMode: "acceptEdits",
        applyStrategy: "restart_now",
      },
      ws,
    );

    expect(createSpy).toHaveBeenCalledTimes(1);
    const codexOptions = createSpy.mock.calls[0][5] as Record<string, unknown>;
    // Without the carry, the replacement session silently drops the plan and
    // the approval card on the phone can never resolve.
    expect(codexOptions.restorePlanCompletion).toEqual({
      toolUseId: "plan_carry_1",
      planText: "Execute the reviewed plan",
    });

    bridge.close();
  });

  it("fails closed when the exact Codex runtime lacks native Plan mode", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex-no-plan",
        provider: "codex",
      },
      ws,
    );
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.subtype === "session_created");
    const sessionId = created.sessionId as string;
    const session = (bridge as any).sessionManager.get(sessionId);
    session.status = "idle";
    session.process.supportsNativePlanMode = false;
    ws.send.mockClear();

    await (bridge as any).handleClientMessage(
      {
        type: "set_permission_mode",
        sessionId,
        mode: "plan",
        planMode: true,
        permissionChangeId: "plan-unsupported-1",
      },
      ws,
    );

    expect(session.process.setCollaborationMode).not.toHaveBeenCalled();
    expect(session.process.collaborationMode).toBe("default");
    expect(
      ws.send.mock.calls.map((call: unknown[]) =>
        JSON.parse(call[0] as string),
      ),
    ).toContainEqual({
      type: "error",
      message:
        "Native Codex Plan mode is unavailable on this app-server. Update Codex before enabling Plan mode.",
      errorCode: "codex_native_plan_mode_unsupported",
      sessionId,
      permissionChangeId: "plan-unsupported-1",
    });

    bridge.close();
  });

  it("returns a retryable error when a native Plan toggle stays unknown", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex-plan-probe-retry",
        provider: "codex",
      },
      ws,
    );
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.subtype === "session_created");
    const sessionId = created.sessionId as string;
    const session = (bridge as any).sessionManager.get(sessionId);
    session.status = "idle";
    session.process.supportsNativePlanMode = false;
    session.process.nativePlanModeCapabilityKnown = false;
    session.process.confirmNativePlanModeSupportForUserAction = vi
      .fn()
      .mockResolvedValue(false);
    ws.send.mockClear();

    await (bridge as any).handleClientMessage(
      {
        type: "set_permission_mode",
        sessionId,
        mode: "plan",
        planMode: true,
        permissionChangeId: "plan-probe-retry-1",
      },
      ws,
    );

    expect(
      session.process.confirmNativePlanModeSupportForUserAction,
    ).toHaveBeenCalledOnce();
    expect(session.process.setCollaborationMode).not.toHaveBeenCalled();
    expect(session.process.collaborationMode).toBe("default");
    expect(session.process.nativePlanModeCapabilityKnown).toBe(false);
    expect(
      ws.send.mock.calls.map((call: unknown[]) =>
        JSON.parse(call[0] as string),
      ),
    ).toContainEqual({
      type: "error",
      message:
        "Failed to set permission mode: native Codex Plan mode support could not be confirmed. Retry after Codex becomes responsive.",
      errorCode: "codex_native_plan_mode_probe_retry",
      sessionId,
      permissionChangeId: "plan-probe-retry-1",
    });

    bridge.close();
  });

  it("preserves codex auto-review when enabling plan mode in-place", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    (bridge as any).wss.clients.add(ws);
    (bridge as any).codexAutoReviewPolicyLoaded = true;

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
        codexPermissionsMode: "autoReview",
      },
      ws,
    );
    await Promise.resolve();

    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    const created = sends.find(
      (m: any) => m.type === "system" && m.subtype === "session_created",
    );
    expect(created).toBeDefined();
    const sessionId = created.sessionId as string;

    const session = (bridge as any).sessionManager.get(sessionId);
    expect(session).toBeDefined();
    session.status = "idle";
    session.process.setApprovalPolicy("on-request");
    session.process.setApprovalsReviewer("auto_review");
    ws.send.mockClear();

    (bridge as any).handleClientMessage(
      {
        type: "set_permission_mode",
        sessionId,
        mode: "plan",
        executionMode: "default",
        planMode: true,
      },
      ws,
    );

    const updatedSession = (bridge as any).sessionManager.get(sessionId);
    expect(updatedSession).toBeDefined();
    expect(updatedSession.id).toBe(sessionId);
    expect(updatedSession.codexSettings).toMatchObject({
      approvalPolicy: "on-request",
      approvalsReviewer: "auto_review",
      codexPermissionsMode: "autoReview",
    });
    expect(updatedSession.process.collaborationMode).toBe("plan");

    const messages = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    const modeChanged = messages.find(
      (m: any) => m.type === "system" && m.subtype === "set_permission_mode",
    );
    expect(modeChanged).toMatchObject({
      approvalPolicy: "on-request",
      approvalsReviewer: "auto_review",
      codexPermissionsMode: "autoReview",
      planMode: true,
    });

    bridge.close();
  });

  it("restarts instead of applying auto-review in-place while policy is unknown", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    (bridge as any).wss.clients.add(ws);

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex-policy-unknown",
        provider: "codex",
        codexPermissionsMode: "autoReview",
      },
      ws,
    );
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find(
        (message: any) =>
          message.type === "system" && message.subtype === "session_created",
      );
    const oldSessionId = created.sessionId as string;
    const session = (bridge as any).sessionManager.get(oldSessionId);
    session.status = "idle";
    session.process.setApprovalPolicy("on-request");
    session.process.setApprovalsReviewer("auto_review");

    (bridge as any).handleClientMessage(
      {
        type: "set_permission_mode",
        sessionId: oldSessionId,
        mode: "plan",
        planMode: true,
      },
      ws,
    );

    expect((bridge as any).sessionManager.get(oldSessionId)).toBeUndefined();
    const newSessionSummary = (bridge as any).sessionManager.list()[0];
    const newSession = (bridge as any).sessionManager.get(newSessionSummary.id);
    expect(newSession.codexOptions.autoReviewDisabledByPolicy).toBeNull();
    bridge.close();
  });

  it("coerces auto-review settings when Browser Use policy disables it", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    (bridge as any).codexAutoReviewDisabled = true;
    (bridge as any).codexAutoReviewPolicyLoaded = true;

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex-managed",
        provider: "codex",
        codexPermissionsMode: "autoReview",
        approvalsReviewer: "auto_review",
      },
      ws,
    );

    const created = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find(
        (message: any) =>
          message.type === "system" && message.subtype === "session_created",
      );
    const session = (bridge as any).sessionManager.get(created.sessionId);
    expect(session.codexOptions).toMatchObject({
      approvalPolicy: "on-request",
      approvalsReviewer: "user",
      codexPermissionsMode: "default",
      sandboxMode: "workspace-write",
      autoReviewDisabledByPolicy: true,
    });

    session.status = "idle";
    session.process.setApprovalsReviewer("auto_review");
    session.codexSettings = {
      ...(session.codexSettings ?? {}),
      approvalPolicy: "on-request",
      approvalsReviewer: "auto_review",
      codexPermissionsMode: "autoReview",
      sandboxMode: "workspace-write",
    };
    (bridge as any).handleClientMessage(
      {
        type: "set_permission_mode",
        sessionId: session.id,
        mode: "plan",
        planMode: true,
      },
      ws,
    );
    expect(session.process.setApprovalsReviewer).toHaveBeenLastCalledWith(
      "user",
    );
    expect(session.codexSettings).toMatchObject({
      approvalsReviewer: "user",
      codexPermissionsMode: "default",
    });

    (bridge as any).sendSessionList(ws);
    const sessionList = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .reverse()
      .find((message: any) => message.type === "session_list");
    expect(sessionList.codexAutoReviewDisabled).toBe(true);
    bridge.close();
  });

  it("preserves and coerces Codex review settings across sandbox restart", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    (bridge as any).codexAutoReviewDisabled = true;
    (bridge as any).codexAutoReviewPolicyLoaded = true;

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex-managed-sandbox",
        provider: "codex",
      },
      ws,
    );
    const created = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find(
        (message: any) =>
          message.type === "system" && message.subtype === "session_created",
      );
    const oldSession = (bridge as any).sessionManager.get(created.sessionId);
    oldSession.codexSettings = {
      ...(oldSession.codexSettings ?? {}),
      approvalsReviewer: "auto_review",
      codexPermissionsMode: "autoReview",
      sandboxMode: "workspace-write",
    };

    (bridge as any).handleClientMessage(
      {
        type: "set_sandbox_mode",
        sessionId: oldSession.id,
        sandboxMode: "off",
      },
      ws,
    );

    const newSessionSummary = (bridge as any).sessionManager.list()[0];
    const newSession = (bridge as any).sessionManager.get(newSessionSummary.id);
    expect(newSession.codexOptions).toMatchObject({
      approvalsReviewer: "user",
      codexPermissionsMode: "default",
      sandboxMode: "danger-full-access",
      autoReviewDisabledByPolicy: true,
    });

    newSession.claudeSessionId = "thread-managed-sandbox";
    newSession.history.push({ type: "user_input", text: "hello" });
    (bridge as any).handleClientMessage(
      {
        type: "set_sandbox_mode",
        sessionId: newSession.id,
        sandboxMode: "on",
      },
      ws,
    );
    await new Promise((resolve) => setTimeout(resolve, 0));

    const resumedSummary = (bridge as any).sessionManager.list()[0];
    const resumedSession = (bridge as any).sessionManager.get(
      resumedSummary.id,
    );
    expect(resumedSession.codexOptions).toMatchObject({
      threadId: "thread-managed-sandbox",
      approvalsReviewer: "user",
      codexPermissionsMode: "default",
      sandboxMode: "workspace-write",
      autoReviewDisabledByPolicy: true,
    });
    bridge.close();
  });

  it("updates codex model in-place and broadcasts session settings", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    (bridge as any).wss.clients.add(ws);

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex-model",
        provider: "codex",
        model: "gpt-5.5",
        modelReasoningEffort: "high",
      },
      ws,
    );
    await Promise.resolve();

    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    const created = sends.find(
      (m: any) => m.type === "system" && m.subtype === "session_created",
    );
    expect(created).toBeDefined();
    const sessionId = created.sessionId as string;

    const session = (bridge as any).sessionManager.get(sessionId);
    expect(session).toBeDefined();
    ws.send.mockClear();

    await (bridge as any).handleClientMessage(
      {
        type: "set_codex_model",
        sessionId,
        model: "gpt-5.6-sol",
        modelReasoningEffort: "ultra",
      },
      ws,
    );

    expect(session.process.setModel).toHaveBeenCalledWith(
      "gpt-5.6-sol",
      "ultra",
    );
    expect(
      session.process.persistRuntimeModelForNextTurn,
    ).toHaveBeenCalledOnce();
    expect(session.codexSettings).toMatchObject({
      model: "gpt-5.6-sol",
      modelReasoningEffort: "ultra",
    });

    const messages = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    expect(
      messages.find(
        (m: any) => m.type === "system" && m.subtype === "set_codex_model",
      ),
    ).toMatchObject({
      sessionId,
      provider: "codex",
      model: "gpt-5.6-sol",
      modelReasoningEffort: "ultra",
    });
    expect(messages.find((m: any) => m.type === "session_list")).toMatchObject({
      sessions: expect.arrayContaining([
        expect.objectContaining({
          id: sessionId,
          codexSettings: expect.objectContaining({
            model: "gpt-5.6-sol",
            modelReasoningEffort: "ultra",
          }),
        }),
      ]),
    });

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "set_codex_speed",
        sessionId,
        serviceTier: "fast",
      },
      ws,
    );

    expect(session.process.setServiceTier).toHaveBeenCalledWith("fast");
    expect(
      session.process.persistRuntimeServiceTierForNextTurn,
    ).toHaveBeenCalledOnce();
    expect(session.codexSettings).toMatchObject({ serviceTier: "fast" });
    expect(
      ws.send.mock.calls
        .map((c: unknown[]) => JSON.parse(c[0] as string))
        .find(
          (m: any) => m.type === "system" && m.subtype === "set_codex_speed",
        ),
    ).toMatchObject({ sessionId, serviceTier: "fast" });

    const ownerCheck = vi
      .spyOn((bridge as any).localFeatures, "hasExternalCodexActivityVerified")
      .mockResolvedValue(true);
    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "set_codex_model",
        sessionId,
        model: "gpt-5.6-sol",
        modelReasoningEffort: "ultra",
      },
      ws,
    );
    await (bridge as any).handleClientMessage(
      {
        type: "set_codex_speed",
        sessionId,
        serviceTier: "fast",
      },
      ws,
    );
    expect(ownerCheck).not.toHaveBeenCalled();
    expect(ws.send).not.toHaveBeenCalled();

    await (bridge as any).handleClientMessage(
      {
        type: "set_codex_model",
        sessionId,
        model: "gpt-5.5",
        modelReasoningEffort: "high",
      },
      ws,
    );
    await (bridge as any).handleClientMessage(
      {
        type: "set_codex_speed",
        sessionId,
        serviceTier: "standard",
      },
      ws,
    );

    expect(session.process.setModel).toHaveBeenCalledTimes(1);
    expect(session.process.setServiceTier).toHaveBeenCalledTimes(1);
    expect(ownerCheck).toHaveBeenCalledTimes(2);
    const ownerErrors = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .filter((message: any) => message.type === "error");
    expect(ownerErrors).toHaveLength(2);
    expect(ownerErrors[0]).toMatchObject({
      sessionId,
      errorCode: "codex_settings_owned_elsewhere",
    });
    expect(ownerErrors[1]).toMatchObject({
      sessionId,
      errorCode: "codex_settings_owned_elsewhere",
    });

    bridge.close();
  });

  it("rejects shared-runtime settings before mutation, broadcast, or restart", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    (bridge as any).wss.clients.add(ws);

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex-shared-settings",
        provider: "codex",
        model: "gpt-5.5",
        modelReasoningEffort: "high",
      },
      ws,
    );
    const created = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find(
        (message: any) =>
          message.type === "system" && message.subtype === "session_created",
      );
    const session = (bridge as any).sessionManager.get(created.sessionId);
    session.process.usesSharedRuntimeTopology = true;
    session.codexSettings = {
      ...(session.codexSettings ?? {}),
      model: "gpt-5.5",
      modelReasoningEffort: "high",
      serviceTier: "standard",
      sandboxMode: "workspace-write",
    };
    ws.send.mockClear();

    await (bridge as any).handleClientMessage(
      {
        type: "set_permission_mode",
        sessionId: session.id,
        mode: "plan",
        planMode: true,
        permissionChangeId: "shared-permission-change",
      },
      ws,
    );
    await (bridge as any).handleClientMessage(
      {
        type: "set_sandbox_mode",
        sessionId: session.id,
        sandboxMode: "off",
      },
      ws,
    );
    await (bridge as any).handleClientMessage(
      {
        type: "set_codex_model",
        sessionId: session.id,
        model: "gpt-5.6-sol",
        modelReasoningEffort: "ultra",
      },
      ws,
    );
    await (bridge as any).handleClientMessage(
      {
        type: "set_codex_speed",
        sessionId: session.id,
        serviceTier: "fast",
      },
      ws,
    );

    expect(session.process.setApprovalPolicy).not.toHaveBeenCalled();
    expect(session.process.setApprovalsReviewer).not.toHaveBeenCalled();
    expect(session.process.setCollaborationMode).not.toHaveBeenCalled();
    expect(
      session.process.updatePermissionSettingsForNextTurn,
    ).not.toHaveBeenCalled();
    expect(session.process.interruptCurrentTurnAndWait).not.toHaveBeenCalled();
    expect(session.process.setModel).not.toHaveBeenCalled();
    expect(session.process.setServiceTier).not.toHaveBeenCalled();
    expect(session.process.stop).not.toHaveBeenCalled();
    expect((bridge as any).sessionManager.get(session.id)).toBe(session);
    expect(session.codexSettings).toMatchObject({
      model: "gpt-5.5",
      modelReasoningEffort: "high",
      serviceTier: "standard",
      sandboxMode: "workspace-write",
    });

    const messages = ws.send.mock.calls.map((call: unknown[]) =>
      JSON.parse(call[0] as string),
    );
    const errors = messages.filter((message: any) => message.type === "error");
    expect(errors).toHaveLength(4);
    expect(errors).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          errorCode: "codex_shared_runtime_settings_read_only",
          sessionId: session.id,
          permissionChangeId: "shared-permission-change",
        }),
        expect.objectContaining({
          errorCode: "codex_shared_runtime_settings_read_only",
          sessionId: session.id,
        }),
      ]),
    );
    expect(
      messages.some(
        (message: any) =>
          message.type === "system" &&
          (message.subtype === "set_permission_mode" ||
            message.subtype === "set_codex_model" ||
            message.subtype === "set_codex_speed"),
      ),
    ).toBe(false);

    await bridge.close();
  });

  it("does not downgrade a detached settings envelope onto a private runtime", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex-private-settings-envelope",
        provider: "codex",
      },
      ws,
    );
    const created = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.subtype === "session_created");
    const session = (bridge as any).sessionManager.get(created.sessionId);
    session.claudeSessionId = "thread-private-settings";
    ws.send.mockClear();

    await (bridge as any).handleClientMessage(
      {
        type: "set_codex_model",
        sessionId: session.id,
        model: "gpt-5.6-sol",
        codexSourceId: (bridge as any).codexSourceId,
        threadId: "thread-private-settings",
        runtimeSessionId: session.id,
        authorityGeneration: "authority-private-stale",
        operationId: "private-must-not-downgrade",
      },
      ws,
    );

    expect(session.process.setModel).not.toHaveBeenCalled();
    expect(JSON.parse(ws.send.mock.calls.at(-1)?.[0] as string)).toMatchObject({
      errorCode: "codex_shared_runtime_settings_stale_authority",
      sessionId: session.id,
    });
    await bridge.close();
  });

  it("applies an exact idle shared-runtime setting once after the provider ACK", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    (bridge as any).wss.clients.add(ws);
    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex-shared-settings-exact",
        provider: "codex",
      },
      ws,
    );
    const created = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.subtype === "session_created");
    const session = (bridge as any).sessionManager.get(created.sessionId);
    const process = session.process;
    process.usesSharedRuntimeTopology = true;
    process.authorityGeneration = "authority-settings-1";
    process.authoritativeThreadStatus = { type: "idle" };
    process.status = "idle";
    process.activeTurnId = undefined;
    session.status = "idle";
    session.claudeSessionId = "thread-settings-1";
    session.codexSettings = { model: "gpt-5.5" };
    (bridge as any).codexActionBrokerRuntime =
      writableCodexActionBrokerRuntime();
    vi.spyOn(
      (bridge as any).localFeatures,
      "hasExternalCodexActivityVerified",
    ).mockResolvedValue(false);

    let acknowledge!: () => void;
    const providerAck = new Promise<void>((resolve) => {
      acknowledge = resolve;
    });
    process.updateSharedRuntimeSettingsForNextTurn.mockReturnValue(providerAck);
    const request = {
      type: "set_codex_model",
      sessionId: session.id,
      model: "gpt-5.6-sol",
      modelReasoningEffort: "ultra",
      codexSourceId: (bridge as any).codexSourceId,
      threadId: "thread-settings-1",
      runtimeSessionId: session.id,
      authorityGeneration: "authority-settings-1",
      operationId: "settings-operation-1",
    } as const;
    ws.send.mockClear();
    const first = (bridge as any).handleClientMessage(request, ws);
    const replay = (bridge as any).handleClientMessage(request, ws);
    await new Promise((resolve) => setImmediate(resolve));

    expect(
      process.updateSharedRuntimeSettingsForNextTurn,
    ).toHaveBeenCalledOnce();
    expect(session.codexSettings.model).toBe("gpt-5.5");
    expect(
      ws.send.mock.calls
        .map((call: unknown[]) => JSON.parse(call[0] as string))
        .some((message: any) => message.subtype === "set_codex_model"),
    ).toBe(false);

    acknowledge();
    await Promise.all([first, replay]);
    expect(process.updateSharedRuntimeSettingsForNextTurn).toHaveBeenCalledWith(
      {
        model: "gpt-5.6-sol",
        modelReasoningEffort: "ultra",
      },
    );
    expect(session.codexSettings).toMatchObject({
      model: "gpt-5.6-sol",
      modelReasoningEffort: "ultra",
    });
    expect(
      ws.send.mock.calls
        .map((call: unknown[]) => JSON.parse(call[0] as string))
        .filter((message: any) => message.subtype === "set_codex_model"),
    ).toHaveLength(1);

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      { ...request, model: "gpt-5.5" },
      ws,
    );
    expect(
      process.updateSharedRuntimeSettingsForNextTurn,
    ).toHaveBeenCalledOnce();
    expect(JSON.parse(ws.send.mock.calls.at(-1)?.[0] as string)).toMatchObject({
      errorCode: "codex_shared_runtime_settings_operation_conflict",
    });

    await bridge.close();
  });

  it("rejects stale, foreign-active, and failed shared-runtime settings without optimistic state", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    (bridge as any).wss.clients.add(ws);
    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex-shared-settings-guarded",
        provider: "codex",
      },
      ws,
    );
    const created = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.subtype === "session_created");
    const session = (bridge as any).sessionManager.get(created.sessionId);
    const process = session.process;
    process.usesSharedRuntimeTopology = true;
    process.authorityGeneration = "authority-settings-2";
    process.authoritativeThreadStatus = { type: "idle" };
    process.status = "idle";
    process.activeTurnId = undefined;
    session.status = "idle";
    session.claudeSessionId = "thread-settings-2";
    session.codexSettings = { serviceTier: "standard" };
    (bridge as any).codexActionBrokerRuntime =
      writableCodexActionBrokerRuntime();
    const external = vi
      .spyOn((bridge as any).localFeatures, "hasExternalCodexActivityVerified")
      .mockResolvedValue(false);
    const target = {
      sessionId: session.id,
      codexSourceId: (bridge as any).codexSourceId,
      threadId: "thread-settings-2",
      runtimeSessionId: session.id,
      authorityGeneration: "authority-settings-2",
    };

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "set_codex_speed",
        serviceTier: "fast",
        ...target,
        authorityGeneration: "stale-authority",
        operationId: "settings-stale",
      },
      ws,
    );
    expect(
      process.updateSharedRuntimeSettingsForNextTurn,
    ).not.toHaveBeenCalled();
    expect(JSON.parse(ws.send.mock.calls.at(-1)?.[0] as string)).toMatchObject({
      errorCode: "codex_shared_runtime_settings_stale_authority",
    });

    ws.send.mockClear();
    external.mockResolvedValueOnce(true);
    await (bridge as any).handleClientMessage(
      {
        type: "set_codex_speed",
        serviceTier: "fast",
        ...target,
        operationId: "settings-foreign-active",
      },
      ws,
    );
    expect(
      process.updateSharedRuntimeSettingsForNextTurn,
    ).not.toHaveBeenCalled();
    expect(JSON.parse(ws.send.mock.calls.at(-1)?.[0] as string)).toMatchObject({
      errorCode: "codex_settings_owned_elsewhere",
    });

    ws.send.mockClear();
    process.updateSharedRuntimeSettingsForNextTurn.mockRejectedValueOnce(
      new CodexRpcError("thread/settings/update", "Method not found", -32601),
    );
    await (bridge as any).handleClientMessage(
      {
        type: "set_codex_speed",
        serviceTier: "fast",
        ...target,
        operationId: "settings-unsupported",
      },
      ws,
    );
    expect(session.codexSettings.serviceTier).toBe("standard");
    expect(JSON.parse(ws.send.mock.calls.at(-1)?.[0] as string)).toMatchObject({
      errorCode: "set_codex_speed_rejected",
    });

    ws.send.mockClear();
    process.updateSharedRuntimeSettingsForNextTurn.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "set_permission_mode",
        mode: "default",
        codexPermissionsMode: "default",
        applyStrategy: "next_turn",
        ...target,
        operationId: "settings-permission",
      },
      ws,
    );
    expect(process.updateSharedRuntimeSettingsForNextTurn).toHaveBeenCalledWith(
      expect.objectContaining({
        approvalPolicy: "on-request",
        approvalsReviewer: "user",
        codexPermissionsMode: "default",
        sandboxMode: "workspace-write",
      }),
    );
    expect(session.codexSettings).toMatchObject({
      approvalPolicy: "on-request",
      sandboxMode: "workspace-write",
    });
    expect(
      ws.send.mock.calls
        .map((call: unknown[]) => JSON.parse(call[0] as string))
        .some((message: any) => message.subtype === "set_permission_mode"),
    ).toBe(true);

    ws.send.mockClear();
    process.updateSharedRuntimeSettingsForNextTurn.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "set_sandbox_mode",
        sandboxMode: "off",
        ...target,
        operationId: "settings-sandbox",
      },
      ws,
    );
    expect(process.updateSharedRuntimeSettingsForNextTurn).toHaveBeenCalledWith(
      {
        sandboxMode: "danger-full-access",
      },
    );
    expect(session.codexSettings.sandboxMode).toBe("danger-full-access");

    ws.send.mockClear();
    process.updateSharedRuntimeSettingsForNextTurn.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "set_permission_mode",
        mode: "plan",
        planMode: true,
        applyStrategy: "next_turn",
        ...target,
        operationId: "settings-plan-not-expanded",
      },
      ws,
    );
    expect(
      process.updateSharedRuntimeSettingsForNextTurn,
    ).not.toHaveBeenCalled();
    expect(JSON.parse(ws.send.mock.calls.at(-1)?.[0] as string)).toMatchObject({
      errorCode: "codex_shared_runtime_collaboration_settings_read_only",
    });

    await bridge.close();
  });

  it("gets, updates, and clears a Codex goal", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    (bridge as any).wss.clients.add(ws);
    await (bridge as any).handleClientMessage(
      {
        type: "client_capabilities",
        supportedServerMessages: ["goal_state"],
      },
      ws,
    );
    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex-goal",
        provider: "codex",
      },
      ws,
    );
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "system" && m.subtype === "session_created");
    const sessionId = created.sessionId as string;
    const session = (bridge as any).sessionManager.get(sessionId);
    ws.send.mockClear();

    await (bridge as any).handleClientMessage(
      { type: "get_goal", sessionId },
      ws,
    );
    await (bridge as any).handleClientMessage(
      {
        type: "set_goal",
        sessionId,
        objective: "Ship Goal support",
        status: "active",
        tokenBudget: 12_000,
        goalChangeId: "goal-edit-1",
      },
      ws,
    );
    await (bridge as any).handleClientMessage(
      { type: "clear_goal", sessionId, goalChangeId: "goal-clear-1" },
      ws,
    );

    expect(session.process.getGoal).toHaveBeenCalledOnce();
    expect(session.process.setGoal).toHaveBeenCalledWith(
      {
        objective: "Ship Goal support",
        status: "active",
        tokenBudget: 12_000,
      },
      expect.objectContaining({ validateCurrentGoal: expect.any(Function) }),
    );
    expect(session.process.clearGoal).toHaveBeenCalledOnce();
    const goals = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .filter((m: any) => m.type === "goal_state");
    expect(goals).toEqual([
      { type: "goal_state", sessionId, goal: null },
      expect.objectContaining({
        type: "goal_state",
        sessionId,
        goalChangeId: "goal-edit-1",
        goal: expect.objectContaining({ objective: "Ship Goal support" }),
      }),
      {
        type: "goal_state",
        sessionId,
        goal: null,
        goalChangeId: "goal-clear-1",
      },
    ]);
    expect(
      (bridge as any).sessionManager
        .list()
        .find((item: any) => item.id === sessionId).codexGoalControlSupported,
    ).toBe(true);
    expect(
      session.history.some((message: any) => message.type === "goal_state"),
    ).toBe(false);

    bridge.close();
  });

  it("keeps Goal mutations read-only while Desktop owns the turn", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex-goal-desktop",
        provider: "codex",
      },
      ws,
    );
    const created = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.subtype === "session_created");
    const session = (bridge as any).sessionManager.get(created.sessionId);
    vi.spyOn(
      (bridge as any).localFeatures,
      "hasExternalCodexActivityVerified",
    ).mockResolvedValue(true);

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "set_goal",
        sessionId: created.sessionId,
        objective: "must remain read-only",
        goalChangeId: "desktop-owned-goal",
      },
      ws,
    );

    expect(session.process.setGoal).not.toHaveBeenCalled();
    expect(
      ws.send.mock.calls
        .map((call: unknown[]) => JSON.parse(call[0] as string))
        .find((message: any) => message.goalChangeId === "desktop-owned-goal"),
    ).toMatchObject({
      type: "error",
      errorCode: "codex_shared_runtime_turn_owned_elsewhere",
    });
    await bridge.close();
  });

  it("correlates every Goal failure to its session and mutation", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    (bridge as any).wss.clients.add(ws);
    await (bridge as any).handleClientMessage(
      {
        type: "client_capabilities",
        supportedServerMessages: ["goal_state"],
      },
      ws,
    );
    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex-goal-errors",
        provider: "codex",
      },
      ws,
    );
    await Promise.resolve();
    const created = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.subtype === "session_created");
    const sessionId = created.sessionId as string;
    const session = (bridge as any).sessionManager.get(sessionId);
    session.process.getGoal.mockRejectedValueOnce(new Error("get failed"));
    session.process.setGoal.mockRejectedValueOnce(new Error("set failed"));
    session.process.clearGoal.mockRejectedValueOnce(new Error("clear failed"));
    ws.send.mockClear();

    await (bridge as any).handleClientMessage(
      { type: "get_goal", sessionId },
      ws,
    );
    await (bridge as any).handleClientMessage(
      {
        type: "set_goal",
        sessionId,
        status: "paused",
        goalChangeId: "goal-set-failure",
      },
      ws,
    );
    await (bridge as any).handleClientMessage(
      {
        type: "clear_goal",
        sessionId,
        goalChangeId: "goal-clear-failure",
      },
      ws,
    );

    const errors = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .filter((message: any) => message.type === "error");
    expect(errors).toEqual([
      expect.objectContaining({
        errorCode: "goal_get_failed",
        sessionId,
      }),
      expect.objectContaining({
        errorCode: "goal_set_failed",
        sessionId,
        goalChangeId: "goal-set-failure",
      }),
      expect.objectContaining({
        errorCode: "goal_clear_failed",
        sessionId,
        goalChangeId: "goal-clear-failure",
      }),
    ]);

    bridge.close();
  });

  it("fails closed for future Goal statuses unless the client advertises raw status support", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const legacy = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    const raw = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    (bridge as any).wss.clients.add(legacy);
    (bridge as any).wss.clients.add(raw);
    await (bridge as any).handleClientMessage(
      {
        type: "client_capabilities",
        supportedServerMessages: ["goal_state"],
      },
      legacy,
    );
    await (bridge as any).handleClientMessage(
      {
        type: "client_capabilities",
        supportedServerMessages: ["goal_state", "goal_state_raw_status"],
      },
      raw,
    );
    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex-future-goal-status",
        provider: "codex",
      },
      legacy,
    );
    const sessionId = legacy.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.subtype === "session_created")
      .sessionId as string;
    const session = (bridge as any).sessionManager.get(sessionId);
    const futureGoal = {
      threadId: "thread-future-goal-status",
      objective: "Future Goal",
      status: "awaitingExternalSystem",
      tokenBudget: null,
      tokensUsed: 1,
      timeUsedSeconds: 1,
      createdAt: 1,
      updatedAt: 2,
    };
    session.process.getGoal.mockResolvedValue(futureGoal);
    session.process.setGoal.mockResolvedValue(futureGoal);

    legacy.send.mockClear();
    raw.send.mockClear();
    await (bridge as any).handleClientMessage(
      { type: "get_goal", sessionId },
      legacy,
    );
    expect(
      legacy.send.mock.calls.map((call: unknown[]) =>
        JSON.parse(call[0] as string),
      ),
    ).toContainEqual(
      expect.objectContaining({
        type: "error",
        errorCode: "goal_status_unsupported",
        sessionId,
      }),
    );
    expect(
      legacy.send.mock.calls
        .map((call: unknown[]) => JSON.parse(call[0] as string))
        .some((message: any) => message.type === "goal_state"),
    ).toBe(false);

    await (bridge as any).handleClientMessage(
      { type: "get_goal", sessionId },
      raw,
    );
    expect(
      raw.send.mock.calls.map((call: unknown[]) =>
        JSON.parse(call[0] as string),
      ),
    ).toContainEqual(
      expect.objectContaining({
        type: "goal_state",
        sessionId,
        goal: expect.objectContaining({ status: "awaitingExternalSystem" }),
      }),
    );

    legacy.send.mockClear();
    raw.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "set_goal",
        sessionId,
        status: "paused",
        goalChangeId: "future-status-set",
      },
      legacy,
    );
    expect(
      legacy.send.mock.calls.map((call: unknown[]) =>
        JSON.parse(call[0] as string),
      ),
    ).toContainEqual(
      expect.objectContaining({
        type: "error",
        errorCode: "goal_status_unsupported",
        goalChangeId: "future-status-set",
      }),
    );
    expect(
      raw.send.mock.calls.map((call: unknown[]) =>
        JSON.parse(call[0] as string),
      ),
    ).toContainEqual(
      expect.objectContaining({
        type: "goal_state",
        goalChangeId: "future-status-set",
        goal: expect.objectContaining({ status: "awaitingExternalSystem" }),
      }),
    );

    bridge.close();
  });

  it("atomically rejects stale Goal mutations before invoking Codex", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    (bridge as any).wss.clients.add(ws);
    await (bridge as any).handleClientMessage(
      {
        type: "client_capabilities",
        supportedServerMessages: ["goal_state"],
      },
      ws,
    );
    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex-goal-cas",
        provider: "codex",
      },
      ws,
    );
    const created = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.subtype === "session_created");
    const sessionId = created.sessionId as string;
    const session = (bridge as any).sessionManager.get(sessionId);
    session.codexGoalOperationSequence = 7;

    let operationSequence = 7;
    Object.defineProperty(session.process, "lastGoalRpcSequence", {
      configurable: true,
      get: () => operationSequence,
    });
    let markFirstStarted!: () => void;
    const firstStarted = new Promise<void>((resolve) => {
      markFirstStarted = resolve;
    });
    let releaseFirst!: () => void;
    const firstGate = new Promise<void>((resolve) => {
      releaseFirst = resolve;
    });
    session.process.setGoal.mockImplementationOnce(
      async (update: Record<string, unknown>) => {
        markFirstStarted();
        await firstGate;
        operationSequence = 8;
        return {
          threadId: "thread-goal-cas",
          objective: String(update.objective),
          status: "active",
          tokenBudget: null,
          tokensUsed: 0,
          timeUsedSeconds: 0,
          createdAt: 1,
          updatedAt: 2,
        };
      },
    );
    ws.send.mockClear();

    const first = (bridge as any).handleClientMessage(
      {
        type: "set_goal",
        sessionId,
        objective: "First writer",
        expectedGoalOperationSequence: 7,
        goalChangeId: "goal-cas-first",
      },
      ws,
    );
    await firstStarted;
    const staleSet = (bridge as any).handleClientMessage(
      {
        type: "set_goal",
        sessionId,
        objective: "Stale writer",
        expectedGoalOperationSequence: 7,
        goalChangeId: "goal-cas-stale-set",
      },
      ws,
    );

    expect(session.process.setGoal).toHaveBeenCalledOnce();
    releaseFirst();
    await Promise.all([first, staleSet]);
    await (bridge as any).handleClientMessage(
      {
        type: "clear_goal",
        sessionId,
        expectedGoalOperationSequence: 7,
        goalChangeId: "goal-cas-stale-clear",
      },
      ws,
    );

    expect(session.process.setGoal).toHaveBeenCalledOnce();
    expect(session.process.clearGoal).not.toHaveBeenCalled();
    const conflicts = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .filter((message: any) => message.errorCode === "goal_conflict");
    expect(conflicts).toEqual([
      expect.objectContaining({
        sessionId,
        goalChangeId: "goal-cas-stale-set",
      }),
      expect.objectContaining({
        sessionId,
        goalChangeId: "goal-cas-stale-clear",
      }),
    ]);

    bridge.close();
  });

  it("publishes unsupported Goal capability after an explicit RPC response", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    (bridge as any).wss.clients.add(ws);
    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex-goal-unsupported",
        provider: "codex",
      },
      ws,
    );
    await Promise.resolve();
    const created = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.subtype === "session_created");
    const sessionId = created.sessionId as string;
    const session = (bridge as any).sessionManager.get(sessionId);
    session.process.getGoal.mockRejectedValueOnce(
      Object.assign(new Error("Method not found"), { code: -32601 }),
    );
    ws.send.mockClear();

    await (bridge as any).handleClientMessage(
      { type: "get_goal", sessionId },
      ws,
    );

    const messages = ws.send.mock.calls.map((call: unknown[]) =>
      JSON.parse(call[0] as string),
    );
    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "error",
        errorCode: "goal_get_unsupported",
        sessionId,
      }),
    );
    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "session_list",
        sessions: expect.arrayContaining([
          expect.objectContaining({
            id: sessionId,
            codexGoalControlSupported: false,
          }),
        ]),
      }),
    );

    bridge.close();
  });

  it("maps set_permission_mode plan to collaborationMode for codex session with restart when active", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
      },
      ws,
    );
    await Promise.resolve();

    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    const created = sends.find(
      (m: any) => m.type === "system" && m.subtype === "session_created",
    );
    expect(created).toBeDefined();
    const oldSessionId = created.sessionId as string;

    const oldSession = (bridge as any).sessionManager.get(oldSessionId);
    expect(oldSession).toBeDefined();
    oldSession.status = "running";

    await (bridge as any).handleClientMessage(
      {
        type: "set_permission_mode",
        sessionId: oldSessionId,
        mode: "plan",
      },
      ws,
    );

    expect(
      oldSession.process.interruptCurrentTurnAndWait,
    ).toHaveBeenCalledOnce();
    expect((bridge as any).sessionManager.get(oldSessionId)).toBeUndefined();

    const sessions = (bridge as any).sessionManager.list();
    expect(sessions).toHaveLength(1);
    expect(sessions[0].id).not.toBe(oldSessionId);
    expect(sessions[0].provider).toBe("codex");

    bridge.close();
  });

  it("persists codex permissions for the next turn without replacing an active session", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    (bridge as any).wss.clients.add(ws);

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex-next-turn",
        provider: "codex",
        codexPermissionsMode: "default",
      },
      ws,
    );
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.subtype === "session_created");
    const sessionId = created.sessionId as string;
    const session = (bridge as any).sessionManager.get(sessionId);
    session.status = "waiting_approval";
    const pendingPermission = {
      toolUseId: "pending-current-turn",
      toolName: "Bash",
      input: { command: "git status" },
    };
    session.process.getPendingPermission.mockReturnValue(pendingPermission);
    ws.send.mockClear();

    await (bridge as any).handleClientMessage(
      {
        type: "set_permission_mode",
        sessionId,
        mode: "acceptEdits",
        executionMode: "fullAccess",
        approvalPolicy: "never",
        approvalsReviewer: "user",
        codexPermissionsMode: "fullAccess",
        planMode: false,
        applyStrategy: "next_turn",
        permissionChangeId: "permission-change-next",
      },
      ws,
    );

    expect((bridge as any).sessionManager.get(sessionId)).toBe(session);
    expect((bridge as any).sessionManager.list()).toHaveLength(1);
    expect(
      session.process.updatePermissionSettingsForNextTurn,
    ).toHaveBeenCalledWith({
      approvalPolicy: "never",
      approvalsReviewer: "user",
      codexPermissionsMode: "fullAccess",
      sandboxMode: "danger-full-access",
    });
    expect(session.process.getPendingPermission()).toMatchObject({
      toolUseId: "pending-current-turn",
    });
    expect(session.process.interruptCurrentTurnAndWait).not.toHaveBeenCalled();

    const messages = ws.send.mock.calls.map((call: unknown[]) =>
      JSON.parse(call[0] as string),
    );
    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "system",
        subtype: "set_permission_mode",
        sessionId,
        codexPermissionsMode: "fullAccess",
        sandboxMode: "danger-full-access",
        permissionChangeId: "permission-change-next",
      }),
    );
    expect(messages).toContainEqual({
      type: "system",
      subtype: "tip",
      sessionId,
      tipCode: "permission_mode_next_turn_applied",
    });
    expect(
      messages.find((message: any) => message.type === "session_list")
        ?.bridgeCapabilities,
    ).toContain("codex_permission_apply_strategy_v1");

    bridge.close();
  });

  it("arms confirmed native Plan mode for the next Bridge-started turn", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    (bridge as any).wss.clients.add(ws);

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex-plan-next-turn",
        provider: "codex",
      },
      ws,
    );
    const created = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.subtype === "session_created");
    const sessionId = created.sessionId as string;
    const session = (bridge as any).sessionManager.get(sessionId);
    session.status = "running";
    session.process.supportsNativePlanMode = true;
    ws.send.mockClear();

    await (bridge as any).handleClientMessage(
      {
        type: "set_permission_mode",
        sessionId,
        mode: "plan",
        planMode: true,
        applyStrategy: "next_turn",
        permissionChangeId: "plan-next-turn-1",
      },
      ws,
    );

    expect(
      session.process.updatePermissionSettingsForNextTurn,
    ).not.toHaveBeenCalled();
    expect(session.process.setCollaborationMode).toHaveBeenCalledWith("plan");
    expect(session.process.collaborationMode).toBe("plan");
    expect(session.process.interruptCurrentTurnAndWait).not.toHaveBeenCalled();
    expect(
      ws.send.mock.calls.map((call: unknown[]) =>
        JSON.parse(call[0] as string),
      ),
    ).toContainEqual(
      expect.objectContaining({
        type: "system",
        subtype: "set_permission_mode",
        sessionId,
        planMode: true,
        permissionChangeId: "plan-next-turn-1",
      }),
    );

    bridge.close();
  });

  it("interrupts an active codex turn before an explicit permission restart", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    (bridge as any).wss.clients.add(ws);

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex-restart-now",
        provider: "codex",
      },
      ws,
    );
    await Promise.resolve();
    const created = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.subtype === "session_created");
    const oldSessionId = created.sessionId as string;
    const oldSession = (bridge as any).sessionManager.get(oldSessionId);
    oldSession.status = "running";
    oldSession.claudeSessionId = "thread-restart-now";
    oldSession.process.approvalPolicy = "on-request";
    oldSession.process.approvalsReviewer = "auto_review";
    oldSession.codexSettings = {
      approvalPolicy: "on-request",
      approvalsReviewer: "auto_review",
      codexPermissionsMode: "autoReview",
      sandboxMode: "workspace-write",
    };

    await (bridge as any).handleClientMessage(
      {
        type: "set_permission_mode",
        sessionId: oldSessionId,
        mode: "acceptEdits",
        codexPermissionsMode: "autoReview",
        applyStrategy: "restart_now",
        permissionChangeId: "permission-change-restart",
      },
      ws,
    );

    expect(
      oldSession.process.updatePermissionSettingsForNextTurn,
    ).not.toHaveBeenCalled();
    expect(
      oldSession.process.interruptCurrentTurnAndWait,
    ).toHaveBeenCalledOnce();
    expect((bridge as any).sessionManager.get(oldSessionId)).toBeUndefined();
    expect((bridge as any).sessionManager.list()).toHaveLength(1);

    const messages = ws.send.mock.calls.map((call: unknown[]) =>
      JSON.parse(call[0] as string),
    );
    expect(messages).toContainEqual(
      expect.objectContaining({
        type: "system",
        subtype: "set_permission_mode",
        sessionId: oldSessionId,
        permissionChangeId: "permission-change-restart",
      }),
    );

    bridge.close();
  });

  it("continues a non-goal turn after an explicit permission restart", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    (bridge as any).wss.clients.add(ws);

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex-restart-continue",
        provider: "codex",
      },
      ws,
    );
    const oldSessionId = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.subtype === "session_created")
      .sessionId as string;
    const oldSession = (bridge as any).sessionManager.get(oldSessionId);
    oldSession.status = "running";
    oldSession.claudeSessionId = "thread-restart-continue";
    oldSession.history.push({
      type: "user_input",
      text: "finish the interrupted task",
    });
    oldSession.process.interruptCurrentTurnAndWait.mockResolvedValueOnce(true);

    await (bridge as any).handleClientMessage(
      {
        type: "set_permission_mode",
        sessionId: oldSessionId,
        mode: "acceptEdits",
        codexPermissionsMode: "autoReview",
        applyStrategy: "restart_now",
      },
      ws,
    );

    const replacementSummary = (bridge as any).sessionManager.list()[0];
    const replacement = (bridge as any).sessionManager.get(
      replacementSummary.id,
    );
    expect(replacement.codexOptions).toMatchObject({
      threadId: "thread-restart-continue",
      continueInterruptedTurnAfterStart: true,
      continuationFallbackText: "继续",
    });
    expect(replacement.codexOptions.resumeGoalAfterStart).toBeUndefined();
    bridge.close();
  });

  it("blocks input and approval while an explicit permission restart settles", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    (bridge as any).wss.clients.add(ws);

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex-restart-gate",
        provider: "codex",
      },
      ws,
    );
    const oldSessionId = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.subtype === "session_created")
      .sessionId as string;
    const oldSession = (bridge as any).sessionManager.get(oldSessionId);
    oldSession.status = "running";
    oldSession.claudeSessionId = "thread-restart-gate";

    let releaseInterrupt!: () => void;
    oldSession.process.interruptCurrentTurnAndWait.mockImplementation(
      () =>
        new Promise<void>((resolve) => {
          releaseInterrupt = resolve;
        }),
    );
    const restart = (bridge as any).handleClientMessage(
      {
        type: "set_permission_mode",
        sessionId: oldSessionId,
        mode: "acceptEdits",
        codexPermissionsMode: "autoReview",
        applyStrategy: "restart_now",
        permissionChangeId: "permission-change-gated",
      },
      ws,
    );
    await vi.waitFor(() => {
      expect(oldSession.permissionRestartInProgress).toBe(true);
      expect(
        oldSession.process.interruptCurrentTurnAndWait,
      ).toHaveBeenCalledOnce();
    });

    await (bridge as any).handleClientMessage(
      {
        type: "input",
        sessionId: oldSessionId,
        text: "must not overtake restart",
        clientMessageId: "blocked-input",
      },
      ws,
    );
    await (bridge as any).handleClientMessage(
      { type: "approve", sessionId: oldSessionId, id: "old-approval" },
      ws,
    );
    await (bridge as any).handleClientMessage(
      {
        type: "set_goal",
        sessionId: oldSessionId,
        objective: "must not replace the paused goal",
        status: "active",
      },
      ws,
    );
    await (bridge as any).handleClientMessage(
      { type: "stop_session", sessionId: oldSessionId },
      ws,
    );

    expect(oldSession.process.sendInput).not.toHaveBeenCalled();
    expect(oldSession.process.approve).not.toHaveBeenCalled();
    expect(oldSession.process.setGoal).not.toHaveBeenCalled();
    expect((bridge as any).sessionManager.get(oldSessionId)).toBe(oldSession);
    const blockedMessages = ws.send.mock.calls.map((call: unknown[]) =>
      JSON.parse(call[0] as string),
    );
    expect(blockedMessages).toContainEqual({
      type: "input_rejected",
      sessionId: oldSessionId,
      clientMessageId: "blocked-input",
      reason: "Permission restart in progress",
    });
    expect(blockedMessages).toContainEqual(
      expect.objectContaining({
        type: "error",
        errorCode: "permission_restart_in_progress",
        sessionId: oldSessionId,
      }),
    );
    expect(
      blockedMessages.filter(
        (message: any) =>
          message.errorCode === "permission_restart_in_progress",
      ),
    ).toHaveLength(3);

    releaseInterrupt();
    await restart;
    bridge.close();
  });

  it("pauses an active goal and resumes it through the replacement runtime", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    (bridge as any).wss.clients.add(ws);

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex-goal-restart",
        provider: "codex",
      },
      ws,
    );
    const oldSessionId = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.subtype === "session_created")
      .sessionId as string;
    const oldSession = (bridge as any).sessionManager.get(oldSessionId);
    oldSession.status = "running";
    oldSession.claudeSessionId = "thread-goal-restart";
    oldSession.history.push({ type: "user_input", text: "continue goal" });
    const activeGoal = {
      threadId: "thread-goal-restart",
      objective: "Complete the goal",
      status: "active",
      tokenBudget: null,
      tokensUsed: 1,
      timeUsedSeconds: 1,
      createdAt: 1,
      updatedAt: 2,
    };
    const pausedGoal = {
      ...activeGoal,
      status: "paused",
      timeUsedSeconds: 2,
      updatedAt: 3,
    };
    oldSession.process.getGoal
      .mockResolvedValueOnce(activeGoal)
      .mockResolvedValueOnce(pausedGoal);
    oldSession.process.setGoal.mockResolvedValueOnce(pausedGoal);

    await (bridge as any).handleClientMessage(
      {
        type: "set_permission_mode",
        sessionId: oldSessionId,
        mode: "acceptEdits",
        codexPermissionsMode: "autoReview",
        applyStrategy: "restart_now",
        permissionChangeId: "permission-change-goal",
      },
      ws,
    );

    expect(oldSession.process.setGoal).toHaveBeenCalledWith(
      { status: "paused" },
      expect.objectContaining({
        validateCurrentGoal: expect.any(Function),
      }),
    );
    expect(oldSession.process.setGoal.mock.invocationCallOrder[0]).toBeLessThan(
      oldSession.process.interruptCurrentTurnAndWait.mock
        .invocationCallOrder[0],
    );
    const replacementSummary = (bridge as any).sessionManager.list()[0];
    const replacement = (bridge as any).sessionManager.get(
      replacementSummary.id,
    );
    expect(replacement.codexOptions).toMatchObject({
      threadId: "thread-goal-restart",
      resumeGoalAfterStart: true,
      resumeGoalLease: {
        threadId: "thread-goal-restart",
        objective: "Complete the goal",
        tokenBudget: null,
        tokensUsed: 1,
        timeUsedSeconds: 2,
        createdAt: 1,
        pausedUpdatedAt: 3,
      },
    });
    expect(
      replacement.codexOptions.continueInterruptedTurnAfterStart,
    ).toBeUndefined();
    bridge.close();
  });

  it("resumes the same Codex thread for a Goal-only permission restart", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    (bridge as any).wss.clients.add(ws);

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex-goal-only-restart",
        provider: "codex",
      },
      ws,
    );
    const oldSessionId = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.subtype === "session_created")
      .sessionId as string;
    const oldSession = (bridge as any).sessionManager.get(oldSessionId);
    oldSession.status = "idle";
    oldSession.claudeSessionId = "stale-thread-id";
    oldSession.process.sessionId = "thread-goal-only";
    const activeGoal = {
      threadId: "thread-goal-only",
      objective: "Goal without chat history",
      status: "active",
      tokenBudget: null,
      tokensUsed: 0,
      timeUsedSeconds: 1,
      createdAt: 1,
      updatedAt: 2,
    };
    const pausedGoal = {
      ...activeGoal,
      status: "paused",
      updatedAt: 3,
    };
    oldSession.process.getGoal
      .mockResolvedValueOnce(activeGoal)
      .mockResolvedValueOnce(pausedGoal);
    oldSession.process.setGoal.mockResolvedValueOnce(pausedGoal);

    await (bridge as any).handleClientMessage(
      {
        type: "set_permission_mode",
        sessionId: oldSessionId,
        mode: "acceptEdits",
        codexPermissionsMode: "autoReview",
        applyStrategy: "restart_now",
      },
      ws,
    );

    const replacementSummary = (bridge as any).sessionManager.list()[0];
    const replacement = (bridge as any).sessionManager.get(
      replacementSummary.id,
    );
    expect(replacement.codexOptions).toMatchObject({
      threadId: "thread-goal-only",
      resumeGoalAfterStart: true,
      resumeGoalLease: {
        threadId: "thread-goal-only",
        objective: "Goal without chat history",
        pausedUpdatedAt: 3,
      },
    });
    expect(oldSession.process.readThread).not.toHaveBeenCalled();
    expect(replacement.codexOptions.threadId).not.toBe("stale-thread-id");
    bridge.close();
  });

  it("keeps the old goal session usable when restart history preflight fails", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    (bridge as any).wss.clients.add(ws);

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex-goal-preflight",
        provider: "codex",
      },
      ws,
    );
    const oldSessionId = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.subtype === "session_created")
      .sessionId as string;
    const oldSession = (bridge as any).sessionManager.get(oldSessionId);
    oldSession.status = "running";
    oldSession.claudeSessionId = "thread-goal-preflight";
    oldSession.history.push({ type: "user_input", text: "continue goal" });
    const activeGoal = {
      threadId: "thread-goal-preflight",
      objective: "Complete the goal",
      status: "active",
      tokenBudget: null,
      tokensUsed: 1,
      timeUsedSeconds: 1,
      createdAt: 1,
      updatedAt: 2,
    };
    const pausedGoal = {
      ...activeGoal,
      status: "paused",
      updatedAt: 3,
    };
    oldSession.process.getGoal
      .mockResolvedValueOnce(activeGoal)
      .mockResolvedValueOnce(pausedGoal);
    oldSession.process.setGoal
      .mockResolvedValueOnce(pausedGoal)
      .mockResolvedValueOnce({
        ...pausedGoal,
        status: "active",
        updatedAt: 4,
      });
    oldSession.process.readThread.mockRejectedValueOnce(
      new Error("history unavailable"),
    );

    await (bridge as any).handleClientMessage(
      {
        type: "set_permission_mode",
        sessionId: oldSessionId,
        mode: "acceptEdits",
        codexPermissionsMode: "autoReview",
        applyStrategy: "restart_now",
        permissionChangeId: "permission-change-preflight",
      },
      ws,
    );

    expect((bridge as any).sessionManager.get(oldSessionId)).toBe(oldSession);
    expect(oldSession.permissionRestartInProgress).toBe(false);
    expect(oldSession.process.setGoal).toHaveBeenNthCalledWith(
      1,
      { status: "paused" },
      expect.objectContaining({
        validateCurrentGoal: expect.any(Function),
      }),
    );
    expect(oldSession.process.setGoal).toHaveBeenNthCalledWith(
      2,
      { status: "active" },
      expect.objectContaining({
        validateCurrentGoal: expect.any(Function),
      }),
    );
    const failure = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) =>
        String(message.message).includes("history unavailable"),
      );
    expect(failure).toMatchObject({
      type: "error",
      errorCode: "set_permission_mode_rejected",
      sessionId: oldSessionId,
      permissionChangeId: "permission-change-preflight",
    });
    bridge.close();
  });

  it("does not resume a replacement Goal after a turn-settle restart abort", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    (bridge as any).wss.clients.add(ws);

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex-goal-settle-race",
        provider: "codex",
      },
      ws,
    );
    const oldSessionId = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.subtype === "session_created")
      .sessionId as string;
    const oldSession = (bridge as any).sessionManager.get(oldSessionId);
    oldSession.status = "running";
    oldSession.claudeSessionId = "thread-goal-settle-race";
    const activeGoal = {
      threadId: "thread-goal-settle-race",
      objective: "Original Goal",
      status: "active",
      tokenBudget: null,
      tokensUsed: 1,
      timeUsedSeconds: 1,
      createdAt: 1,
      updatedAt: 2,
    };
    const pausedGoal = {
      ...activeGoal,
      status: "paused",
      updatedAt: 3,
    };
    const replacementGoal = {
      ...activeGoal,
      objective: "Desktop replacement",
      createdAt: 4,
      updatedAt: 4,
    };
    oldSession.process.getGoal
      .mockResolvedValueOnce(activeGoal)
      .mockResolvedValueOnce(replacementGoal);
    oldSession.process.setGoal.mockResolvedValueOnce(pausedGoal);
    oldSession.process.interruptCurrentTurnAndWait.mockRejectedValueOnce(
      new Error("turn did not settle"),
    );

    await (bridge as any).handleClientMessage(
      {
        type: "set_permission_mode",
        sessionId: oldSessionId,
        mode: "acceptEdits",
        codexPermissionsMode: "autoReview",
        applyStrategy: "restart_now",
        permissionChangeId: "permission-change-settle-race",
      },
      ws,
    );

    expect((bridge as any).sessionManager.get(oldSessionId)).toBe(oldSession);
    expect(oldSession.permissionRestartInProgress).toBe(false);
    expect(oldSession.process.setGoal).toHaveBeenCalledTimes(1);
    expect(oldSession.process.setGoal).toHaveBeenCalledWith(
      { status: "paused" },
      expect.objectContaining({
        validateCurrentGoal: expect.any(Function),
      }),
    );
    expect(oldSession.codexGoal).toMatchObject({
      objective: "Desktop replacement",
    });
    bridge.close();
  });

  it("does not resume a replacement Goal after history preflight abort", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    (bridge as any).wss.clients.add(ws);

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex-goal-history-race",
        provider: "codex",
      },
      ws,
    );
    const oldSessionId = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.subtype === "session_created")
      .sessionId as string;
    const oldSession = (bridge as any).sessionManager.get(oldSessionId);
    oldSession.status = "running";
    oldSession.claudeSessionId = "thread-goal-history-race";
    oldSession.history.push({ type: "user_input", text: "continue goal" });
    const activeGoal = {
      threadId: "thread-goal-history-race",
      objective: "Original Goal",
      status: "active",
      tokenBudget: null,
      tokensUsed: 1,
      timeUsedSeconds: 1,
      createdAt: 1,
      updatedAt: 2,
    };
    const pausedGoal = {
      ...activeGoal,
      status: "paused",
      updatedAt: 3,
    };
    const replacementGoal = {
      ...activeGoal,
      objective: "Desktop replacement",
      createdAt: 4,
      updatedAt: 4,
    };
    oldSession.process.getGoal
      .mockResolvedValueOnce(activeGoal)
      .mockResolvedValueOnce(replacementGoal);
    oldSession.process.setGoal.mockResolvedValueOnce(pausedGoal);
    oldSession.process.readThread.mockRejectedValueOnce(
      new Error("history unavailable"),
    );

    await (bridge as any).handleClientMessage(
      {
        type: "set_permission_mode",
        sessionId: oldSessionId,
        mode: "acceptEdits",
        codexPermissionsMode: "autoReview",
        applyStrategy: "restart_now",
        permissionChangeId: "permission-change-history-race",
      },
      ws,
    );

    expect((bridge as any).sessionManager.get(oldSessionId)).toBe(oldSession);
    expect(oldSession.permissionRestartInProgress).toBe(false);
    expect(oldSession.process.setGoal).toHaveBeenCalledTimes(1);
    expect(oldSession.codexGoal).toMatchObject({
      objective: "Desktop replacement",
    });
    bridge.close();
  });

  it("aborts the final permission restart check without activating a replacement Goal", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    (bridge as any).wss.clients.add(ws);

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex-goal-final-race",
        provider: "codex",
      },
      ws,
    );
    const oldSessionId = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.subtype === "session_created")
      .sessionId as string;
    const oldSession = (bridge as any).sessionManager.get(oldSessionId);
    oldSession.status = "idle";
    oldSession.claudeSessionId = "thread-goal-final-race";
    oldSession.history.push({ type: "user_input", text: "continue goal" });
    const activeGoal = {
      threadId: "thread-goal-final-race",
      objective: "Original Goal",
      status: "active",
      tokenBudget: null,
      tokensUsed: 1,
      timeUsedSeconds: 1,
      createdAt: 1,
      updatedAt: 2,
    };
    const pausedGoal = {
      ...activeGoal,
      status: "paused",
      updatedAt: 3,
    };
    const replacementGoal = {
      ...activeGoal,
      objective: "Desktop replacement",
      createdAt: 4,
      updatedAt: 4,
    };
    oldSession.process.getGoal
      .mockResolvedValueOnce(activeGoal)
      .mockResolvedValueOnce(replacementGoal);
    oldSession.process.setGoal.mockResolvedValueOnce(pausedGoal);

    await (bridge as any).handleClientMessage(
      {
        type: "set_permission_mode",
        sessionId: oldSessionId,
        mode: "acceptEdits",
        codexPermissionsMode: "autoReview",
        applyStrategy: "restart_now",
        permissionChangeId: "permission-change-final-race",
      },
      ws,
    );

    expect((bridge as any).sessionManager.get(oldSessionId)).toBe(oldSession);
    expect(oldSession.permissionRestartInProgress).toBe(false);
    expect(oldSession.process.setGoal).toHaveBeenCalledTimes(1);
    expect(
      ws.send.mock.calls
        .map((call: unknown[]) => JSON.parse(call[0] as string))
        .find((message: any) =>
          String(message.message).includes(
            "goal changed while the permission restart was settling",
          ),
        ),
    ).toMatchObject({
      errorCode: "set_permission_mode_rejected",
      permissionChangeId: "permission-change-final-race",
    });
    bridge.close();
  });

  it("maps set_permission_mode to approval_policy for codex session", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    (bridge as any).wss.clients.add(ws);
    (bridge as any).codexAutoReviewPolicyLoaded = true;

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
      },
      ws,
    );
    await Promise.resolve();

    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    const created = sends.find(
      (m: any) => m.type === "system" && m.subtype === "session_created",
    );
    expect(created).toBeDefined();
    const sessionId = created.sessionId as string;
    const session = (bridge as any).sessionManager.get(sessionId);
    ws.send.mockClear();

    // Should not return an error — it maps to approval_policy internally
    (bridge as any).handleClientMessage(
      {
        type: "set_permission_mode",
        sessionId,
        mode: "bypassPermissions",
        approvalsReviewer: "auto_review",
      },
      ws,
    );

    const lastMessages = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    const errors = lastMessages.filter((m: any) => m.type === "error");
    // No errors should be produced for valid permission mode on codex
    expect(errors.length).toBe(0);
    expect(session.process.setApprovalsReviewer).toHaveBeenCalledWith(
      "auto_review",
    );
    expect(session.codexSettings).toMatchObject({
      approvalPolicy: "on-request",
      approvalsReviewer: "auto_review",
    });
    const sessionList = lastMessages.find(
      (m: any) => m.type === "session_list",
    );
    expect(sessionList?.sessions[0].codexSettings).toMatchObject({
      approvalsReviewer: "auto_review",
    });

    bridge.close();
  });

  it("starts codex custom permissions without bridge approval or sandbox overrides", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
        codexPermissionsMode: "custom",
      },
      ws,
    );
    await Promise.resolve();

    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    const created = sends.find(
      (m: any) => m.type === "system" && m.subtype === "session_created",
    );
    expect(created).toMatchObject({
      provider: "codex",
      codexPermissionsMode: "custom",
    });
    const session = (bridge as any).sessionManager.get(created.sessionId);
    expect(session.codexOptions.codexPermissionsMode).toBe("custom");
    expect(session.codexOptions.approvalPolicy).toBeUndefined();
    expect(session.codexOptions.approvalsReviewer).toBeUndefined();
    expect(session.codexOptions.sandboxMode).toBeUndefined();

    bridge.close();
  });

  it("switches codex to custom permissions by recreating without stale reviewer", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    (bridge as any).wss.clients.add(ws);

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
        codexPermissionsMode: "autoReview",
      },
      ws,
    );
    await Promise.resolve();

    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    const created = sends.find(
      (m: any) => m.type === "system" && m.subtype === "session_created",
    );
    const oldSessionId = created.sessionId as string;
    const oldSession = (bridge as any).sessionManager.get(oldSessionId);
    expect(oldSession.codexOptions.approvalsReviewer).toBe("auto_review");

    ws.send.mockClear();
    (bridge as any).handleClientMessage(
      {
        type: "set_permission_mode",
        sessionId: oldSessionId,
        mode: "default",
        codexPermissionsMode: "custom",
      },
      ws,
    );

    expect((bridge as any).sessionManager.get(oldSessionId)).toBeUndefined();
    const sessions = (bridge as any).sessionManager.list();
    expect(sessions).toHaveLength(1);
    const newSessionSummary = sessions[0];
    expect(newSessionSummary.id).not.toBe(oldSessionId);
    const newSession = (bridge as any).sessionManager.get(newSessionSummary.id);
    expect(newSession.codexOptions.codexPermissionsMode).toBe("custom");
    expect(newSession.codexOptions.approvalPolicy).toBeUndefined();
    expect(newSession.codexOptions.approvalsReviewer).toBeUndefined();
    expect(newSession.codexOptions.sandboxMode).toBeUndefined();

    const createdAfterSwitch = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "system" && m.subtype === "session_created");
    expect(createdAfterSwitch).toMatchObject({
      provider: "codex",
      codexPermissionsMode: "custom",
      sourceSessionId: oldSessionId,
    });
    expect(createdAfterSwitch.approvalsReviewer).toBeUndefined();
    expect(createdAfterSwitch.approvalPolicy).toBeUndefined();
    expect(createdAfterSwitch.sandboxMode).toBeUndefined();

    bridge.close();
  });

  it("includes explicit execution and plan modes when codex sandbox change recreates session", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
        executionMode: "fullAccess",
        planMode: true,
      },
      ws,
    );
    await Promise.resolve();

    const initialMessages = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    const created = initialMessages.find(
      (m: any) => m.type === "system" && m.subtype === "session_created",
    );
    expect(created).toBeDefined();
    const oldSessionId = created.sessionId as string;
    const session = (bridge as any).sessionManager.get(oldSessionId);
    session.process.approvalPolicy = "never";
    session.process.collaborationMode = "plan";

    const buildSessionCreatedMessageSpy = vi.spyOn(
      bridge as any,
      "buildSessionCreatedMessage",
    );
    ws.send.mockClear();
    (bridge as any).handleClientMessage(
      {
        type: "set_sandbox_mode",
        sessionId: oldSessionId,
        sandboxMode: "off",
      },
      ws,
    );

    const params = buildSessionCreatedMessageSpy.mock.calls.at(-1)?.[0];
    expect(params).toBeDefined();
    expect(params.executionMode).toBe("fullAccess");
    expect(params.planMode).toBe(true);
    expect(params.permissionMode).toBe("plan");
    expect(params.sandboxMode).toBe("off");

    bridge.close();
  });

  it("preserves Goal-only lineage and restart lease for legacy sandbox changes", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    (bridge as any).wss.clients.add(ws);

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex-goal-only-sandbox",
        provider: "codex",
      },
      ws,
    );
    const oldSessionId = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.subtype === "session_created")
      .sessionId as string;
    const oldSession = (bridge as any).sessionManager.get(oldSessionId);
    oldSession.status = "idle";
    oldSession.process.sessionId = "thread-goal-only-sandbox";
    const activeGoal = {
      threadId: "thread-goal-only-sandbox",
      objective: "Keep Goal across legacy sandbox restart",
      status: "active",
      tokenBudget: null,
      tokensUsed: 0,
      timeUsedSeconds: 1,
      createdAt: 1,
      updatedAt: 2,
    };
    const pausedGoal = {
      ...activeGoal,
      status: "paused",
      updatedAt: 3,
    };
    oldSession.process.getGoal
      .mockResolvedValueOnce(activeGoal)
      .mockResolvedValueOnce(pausedGoal);
    oldSession.process.setGoal.mockResolvedValueOnce(pausedGoal);

    await (bridge as any).handleClientMessage(
      {
        type: "set_sandbox_mode",
        sessionId: oldSessionId,
        sandboxMode: "off",
      },
      ws,
    );

    const replacementSummary = (bridge as any).sessionManager.list()[0];
    const replacement = (bridge as any).sessionManager.get(
      replacementSummary.id,
    );
    expect(replacement.codexOptions).toMatchObject({
      threadId: "thread-goal-only-sandbox",
      resumeGoalAfterStart: true,
      resumeGoalLease: {
        threadId: "thread-goal-only-sandbox",
        pausedUpdatedAt: 3,
      },
    });
    expect(oldSession.process.readThread).not.toHaveBeenCalled();
    bridge.close();
  });

  it("includes permissionMode in codex session_created on start", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
        permissionMode: "bypassPermissions",
        serviceTier: "fast",
        startRequestId: "start-request-1",
      },
      ws,
    );
    await Promise.resolve();

    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    const created = sends.find(
      (m: any) => m.type === "system" && m.subtype === "session_created",
    );
    expect(created).toMatchObject({
      provider: "codex",
      permissionMode: "bypassPermissions",
      serviceTier: "fast",
      startRequestId: "start-request-1",
    });

    bridge.close();
  });

  it("correlates a failed start without relying on the global error", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    vi.spyOn((bridge as any).sessionManager, "create").mockImplementationOnce(
      () => {
        throw new Error("profile missing");
      },
    );

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
        startRequestId: "start-request-failed",
      },
      ws,
    );

    const sends = ws.send.mock.calls.map((call: unknown[]) =>
      JSON.parse(call[0] as string),
    );
    expect(sends).toContainEqual(
      expect.objectContaining({
        type: "system",
        subtype: "session_start_failed",
        provider: "codex",
        startRequestId: "start-request-failed",
        errorMessage: "profile missing",
      }),
    );
    expect(sends).toContainEqual(
      expect.objectContaining({
        type: "error",
        message: "Failed to start session: profile missing",
      }),
    );

    bridge.close();
  });

  it("correlates a start rejected before session construction", async () => {
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      allowedDirs: ["/tmp/allowed"],
    });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/denied",
        provider: "codex",
        startRequestId: "start-request-denied",
      },
      ws,
    );

    const sends = ws.send.mock.calls.map((call: unknown[]) =>
      JSON.parse(call[0] as string),
    );
    expect(sends).toContainEqual(
      expect.objectContaining({
        type: "system",
        subtype: "session_start_failed",
        provider: "codex",
        startRequestId: "start-request-denied",
        errorMessage: expect.stringContaining("not in the allowed directories"),
      }),
    );
    expect(sends).toContainEqual(
      expect.objectContaining({
        type: "error",
        errorCode: "path_not_allowed",
      }),
    );

    bridge.close();
  });

  it("includes cached Codex completions in session_created", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    const getCachedCommands = vi
      .spyOn((bridge as any).sessionManager, "getCachedCommands")
      .mockReturnValue({
        slashCommands: [],
        skills: ["skill-creator"],
        skillMetadata: [
          {
            name: "skill-creator",
            path: "/tmp/skill-creator/SKILL.md",
          },
        ],
        apps: [],
        plugins: [],
      });

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
      },
      ws,
    );
    await Promise.resolve();

    expect(getCachedCommands).toHaveBeenCalledWith(
      "codex",
      resolvePlatformPath("/tmp/project-codex"),
    );
    const sends = ws.send.mock.calls.map((call: unknown[]) =>
      JSON.parse(call[0] as string),
    );
    const created = sends.find(
      (message: any) =>
        message.type === "system" && message.subtype === "session_created",
    );
    expect(created).toMatchObject({
      provider: "codex",
      skills: ["skill-creator"],
      skillMetadata: [
        {
          name: "skill-creator",
          path: "/tmp/skill-creator/SKILL.md",
        },
      ],
    });

    bridge.close();
  });

  it("returns error when set_permission_mode is sent without active session", () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    (bridge as any).handleClientMessage(
      {
        type: "set_permission_mode",
        sessionId: "missing",
        mode: "plan",
      },
      ws,
    );

    const last = JSON.parse(ws.send.mock.calls.at(-1)?.[0] as string);
    expect(last).toEqual({
      type: "error",
      message: "No active session.",
      errorCode: "set_permission_mode_rejected",
      sessionId: "missing",
    });

    bridge.close();
  });

  it("can force set_permission_mode failure for testing", () => {
    vi.stubEnv("BRIDGE_FAIL_SET_PERMISSION_MODE", "1");
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    (bridge as any).handleClientMessage(
      {
        type: "set_permission_mode",
        sessionId: "s-1",
        mode: "plan",
      },
      ws,
    );

    const last = JSON.parse(ws.send.mock.calls.at(-1)?.[0] as string);
    expect(last).toEqual({
      type: "error",
      message: "Failed to set permission mode: forced test failure",
      errorCode: "set_permission_mode_rejected",
      sessionId: "s-1",
    });

    bridge.close();
  });

  it("can force set_sandbox_mode failure for testing", () => {
    vi.stubEnv("BRIDGE_FAIL_SET_SANDBOX_MODE", "1");
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    (bridge as any).handleClientMessage(
      {
        type: "set_sandbox_mode",
        sessionId: "s-1",
        sandboxMode: "off",
      },
      ws,
    );

    const last = JSON.parse(ws.send.mock.calls.at(-1)?.[0] as string);
    expect(last).toEqual({
      type: "error",
      message: "Failed to set sandbox mode: forced test failure",
      errorCode: "set_sandbox_mode_rejected",
    });

    bridge.close();
  });

  it("returns debug_bundle for an active session", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-a",
        provider: "claude",
      },
      ws,
    );
    await Promise.resolve();

    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    const created = sends.find(
      (m: any) => m.type === "system" && m.subtype === "session_created",
    );
    expect(created).toBeDefined();
    const sessionId = created.sessionId as string;

    const session = (bridge as any).sessionManager.get(sessionId);
    (bridge as any).sessionManager.appendHistory(session.id, {
      type: "status",
      status: "running",
    });

    ws.send.mockClear();
    (bridge as any).handleClientMessage(
      {
        type: "get_debug_bundle",
        sessionId,
        includeDiff: false,
        traceLimit: 50,
      },
      ws,
    );

    const bundle = JSON.parse(ws.send.mock.calls.at(-1)?.[0] as string);
    expect(bundle.type).toBe("debug_bundle");
    expect(bundle.sessionId).toBe(sessionId);
    expect(bundle.session.provider).toBe("claude");
    // History may contain a system/tip (git_not_available) before the running status
    expect(
      bundle.historySummary.some((s: string) => s.includes("running")),
    ).toBe(true);
    expect(Array.isArray(bundle.debugTrace)).toBe(true);
    expect(typeof bundle.traceFilePath).toBe("string");
    expect(typeof bundle.savedBundlePath).toBe("string");
    expect(bundle.reproRecipe).toMatchObject({
      wsUrlHint: expect.any(String),
      resumeSessionMessage: expect.objectContaining({
        type: "resume_session",
        provider: "claude",
      }),
    });
    expect(typeof bundle.agentPrompt).toBe("string");

    bridge.close();
  });

  it("does not create debug trace buckets for unknown session ids", () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    (bridge as any).handleClientMessage(
      {
        type: "set_permission_mode",
        sessionId: "missing-session",
        mode: "plan",
      },
      ws,
    );

    expect((bridge as any).debugEvents.has("missing-session")).toBe(false);
    bridge.close();
  });

  it("cleans debug events when session is stopped", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-a",
        provider: "claude",
      },
      ws,
    );
    await Promise.resolve();

    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    const created = sends.find(
      (m: any) => m.type === "system" && m.subtype === "session_created",
    );
    const sessionId = created.sessionId as string;
    expect((bridge as any).debugEvents.has(sessionId)).toBe(true);

    (bridge as any).handleClientMessage(
      {
        type: "stop_session",
        sessionId,
      },
      ws,
    );

    expect((bridge as any).debugEvents.has(sessionId)).toBe(false);
    bridge.close();
  });

  it("keeps a shared session attached when interrupt or stop targets a foreign turn", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex-foreign-turn",
        provider: "codex",
      },
      ws,
    );
    const created = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find(
        (message: any) =>
          message.type === "system" && message.subtype === "session_created",
      );
    const session = (bridge as any).sessionManager.get(created.sessionId);
    session.process.usesSharedRuntimeTopology = true;
    session.process.authoritativeThreadStatus = {
      type: "active",
      activeFlags: [],
    };
    session.process.activeTurnId = "desktop-owned-turn";
    session.process.interruptCurrentTurn.mockRejectedValue(
      new CodexSharedRuntimeTurnOwnershipError(
        "interrupt",
        "desktop-owned-turn",
      ),
    );
    session.process.interruptCurrentTurnAndWait.mockResolvedValue(false);
    ws.send.mockClear();

    await (bridge as any).handleClientMessage(
      { type: "interrupt", sessionId: session.id },
      ws,
    );
    await (bridge as any).handleClientMessage(
      { type: "stop_session", sessionId: session.id },
      ws,
    );

    expect(session.process.interruptCurrentTurn).toHaveBeenCalledOnce();
    expect(session.process.interruptCurrentTurnAndWait).toHaveBeenCalledOnce();
    expect(session.process.stop).not.toHaveBeenCalled();
    expect((bridge as any).sessionManager.get(session.id)).toBe(session);
    const messages = ws.send.mock.calls.map((call: unknown[]) =>
      JSON.parse(call[0] as string),
    );
    expect(
      messages.filter(
        (message: any) =>
          message.errorCode === "codex_shared_runtime_turn_owned_elsewhere",
      ),
    ).toHaveLength(2);
    expect(
      messages.some(
        (message: any) =>
          message.type === "result" && message.subtype === "stopped",
      ),
    ).toBe(false);

    await bridge.close();
  });

  it("interrupts an owned shared turn before detaching the session", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    (bridge as any).wss.clients.add(ws);

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex-owned-turn",
        provider: "codex",
      },
      ws,
    );
    const created = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find(
        (message: any) =>
          message.type === "system" && message.subtype === "session_created",
      );
    const session = (bridge as any).sessionManager.get(created.sessionId);
    session.process.usesSharedRuntimeTopology = true;
    session.process.authoritativeThreadStatus = {
      type: "active",
      activeFlags: [],
    };
    session.process.activeTurnId = "bridge-owned-turn";
    session.process.interruptCurrentTurnAndWait.mockImplementation(async () => {
      session.process.activeTurnId = undefined;
      session.process.authoritativeThreadStatus = { type: "idle" };
      return true;
    });
    ws.send.mockClear();

    await (bridge as any).handleClientMessage(
      { type: "stop_session", sessionId: session.id },
      ws,
    );

    expect(session.process.interruptCurrentTurnAndWait).toHaveBeenCalledOnce();
    expect(session.process.stop).toHaveBeenCalledOnce();
    expect((bridge as any).sessionManager.get(session.id)).toBeUndefined();
    expect(
      ws.send.mock.calls
        .map((call: unknown[]) => JSON.parse(call[0] as string))
        .some(
          (message: any) =>
            message.type === "result" && message.subtype === "stopped",
        ),
    ).toBe(true);

    await bridge.close();
  });

  it("clearContext approve recreates session immediately with plan input", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-a",
        provider: "claude",
      },
      ws,
    );
    await Promise.resolve();

    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    const created = sends.find(
      (m: any) => m.type === "system" && m.subtype === "session_created",
    );
    const sessionId = created.sessionId as string;
    const session = (bridge as any).sessionManager.get(sessionId);
    session.claudeSessionId = "claude-session-1";
    (
      session.process.getPendingPermission as ReturnType<typeof vi.fn>
    ).mockReturnValue({
      toolUseId: "tool-exit-1",
      toolName: "ExitPlanMode",
      input: { plan: "original plan text" },
    });
    const broadcastSpy = vi.spyOn(bridge as any, "broadcast");

    (bridge as any).handleClientMessage(
      {
        type: "approve",
        id: "tool-exit-1",
        clearContext: true,
        sessionId,
      },
      ws,
    );

    expect((bridge as any).sessionManager.get(sessionId)).toBeUndefined();
    expect(session.process.approve).not.toHaveBeenCalled();

    const sessions = (bridge as any).sessionManager.list();
    expect(sessions).toHaveLength(1);
    const newSession = (bridge as any).sessionManager.get(sessions[0].id);
    expect(newSession.startOptions).toMatchObject({
      sessionId: "claude-session-1",
      continueMode: true,
      initialInput: "original plan text",
    });
    const clearContextCreated = broadcastSpy.mock.calls
      .map((call: unknown[]) => call[0] as Record<string, unknown>)
      .find(
        (m) =>
          m.type === "system" &&
          m.subtype === "session_created" &&
          m.clearContext === true,
      );
    expect(clearContextCreated).toMatchObject({
      sourceSessionId: sessionId,
    });

    bridge.close();
  });

  it.each([
    {
      label: "stale approval",
      pending: undefined,
    },
    {
      label: "non-plan approval",
      pending: {
        toolUseId: "tool-exit-1",
        toolName: "Bash",
        input: { command: "pwd" },
      },
    },
  ])(
    "clearContext rejects an unbound $label without replacing the session",
    async ({ pending }) => {
      const bridge = new BridgeWebSocketServer({ server: httpServer });
      const ws = {
        readyState: OPEN_STATE,
        send: vi.fn(),
      } as any;

      (bridge as any).handleClientMessage(
        {
          type: "start",
          projectPath: "/tmp/project-clear-context-binding",
          provider: "claude",
        },
        ws,
      );
      await Promise.resolve();

      const sends = ws.send.mock.calls.map((call: unknown[]) =>
        JSON.parse(call[0] as string),
      );
      const created = sends.find(
        (message: any) =>
          message.type === "system" && message.subtype === "session_created",
      );
      const sessionId = created.sessionId as string;
      const session = (bridge as any).sessionManager.get(sessionId);
      (
        session.process.getPendingPermission as ReturnType<typeof vi.fn>
      ).mockReturnValue(pending);
      ws.send.mockClear();

      (bridge as any).handleClientMessage(
        {
          type: "approve",
          id: "tool-exit-1",
          clearContext: true,
          sessionId,
        },
        ws,
      );

      expect((bridge as any).sessionManager.get(sessionId)).toBe(session);
      expect((bridge as any).sessionManager.list()).toHaveLength(1);
      expect(session.process.approve).not.toHaveBeenCalled();
      expect(
        ws.send.mock.calls.map((call: unknown[]) =>
          JSON.parse(call[0] as string),
        ),
      ).toContainEqual({
        type: "error",
        errorCode: "invalid_clear_context_approval",
        message: "Clear context requires the matching pending plan approval.",
      });

      bridge.close();
    },
  );

  it("routes tool suggestion installation to the Codex process", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-tool-suggestion",
        provider: "codex",
      },
      ws,
    );

    const sends = ws.send.mock.calls.map((call: unknown[]) =>
      JSON.parse(call[0] as string),
    );
    const created = sends.find(
      (message: any) =>
        message.type === "system" && message.subtype === "session_created",
    );
    const session = (bridge as any).sessionManager.get(created.sessionId);

    await (bridge as any).handleClientMessage(
      {
        type: "install_tool_suggestion",
        toolUseId: "approval-0",
        sessionId: created.sessionId,
      },
      ws,
    );

    expect(session.process.installToolSuggestion).toHaveBeenCalledWith(
      "approval-0",
    );
    bridge.close();
  });

  it("batches deltas for clients that were connected when each delta arrived", () => {
    vi.useFakeTimers();
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      deltaBatchMs: 100,
    });
    const first = { readyState: OPEN_STATE, send: vi.fn() } as any;
    const late = { readyState: OPEN_STATE, send: vi.fn() } as any;
    (bridge as any).wss.clients.add(first);

    (bridge as any).broadcastSessionMessage("s-1", {
      type: "stream_delta",
      text: "before ",
    });
    (bridge as any).wss.clients.add(late);
    (bridge as any).broadcastSessionMessage("s-1", {
      type: "stream_delta",
      text: "after",
    });
    vi.advanceTimersByTime(100);

    expect(first.send).toHaveBeenCalledTimes(1);
    expect(JSON.parse(first.send.mock.calls[0][0] as string)).toEqual({
      type: "stream_delta",
      text: "before after",
      sessionId: "s-1",
    });
    expect(late.send).toHaveBeenCalledTimes(1);
    expect(JSON.parse(late.send.mock.calls[0][0] as string)).toEqual({
      type: "stream_delta",
      text: "after",
      sessionId: "s-1",
    });

    bridge.close();
  });

  it("adds computer activity time only for clients that advertise support", () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const supported = { readyState: OPEN_STATE, send: vi.fn() } as any;
    const legacy = { readyState: OPEN_STATE, send: vi.fn() } as any;
    (bridge as any).wss.clients.add(supported);
    (bridge as any).wss.clients.add(legacy);
    (bridge as any).clientSupportedServerMessages.set(
      supported,
      new Set(["session_activity_at_v1"]),
    );
    const sessionId = (bridge as any).sessionManager.create(
      "/tmp/activity",
      undefined,
      undefined,
      undefined,
      "codex",
      { threadId: "thread-activity" },
    );
    (bridge as any).sessionManager.get(sessionId).lastActivityAt = new Date(
      "2026-07-25T01:02:03.456Z",
    );

    (bridge as any).broadcastSessionMessage(sessionId, {
      type: "status",
      status: "running",
    });

    expect(JSON.parse(supported.send.mock.calls[0][0] as string)).toEqual({
      type: "status",
      status: "running",
      sessionId,
      activityAt: "2026-07-25T01:02:03.456Z",
    });
    expect(JSON.parse(legacy.send.mock.calls[0][0] as string)).toEqual({
      type: "status",
      status: "running",
      sessionId,
    });

    bridge.close();
  });

  it("flushes alternating deltas before a non-delta session message", () => {
    vi.useFakeTimers();
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      deltaBatchMs: 100,
    });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    (bridge as any).wss.clients.add(ws);

    (bridge as any).broadcastSessionMessage("s-1", {
      type: "stream_delta",
      text: "answer ",
    });
    (bridge as any).broadcastSessionMessage("s-1", {
      type: "thinking_delta",
      text: "thought",
    });
    (bridge as any).broadcastSessionMessage("s-1", {
      type: "stream_delta",
      text: "done",
    });
    (bridge as any).broadcastSessionMessage("s-1", {
      type: "status",
      status: "idle",
    });

    expect(
      ws.send.mock.calls.map((call: unknown[]) =>
        JSON.parse(call[0] as string),
      ),
    ).toEqual([
      { type: "stream_delta", text: "answer ", sessionId: "s-1" },
      { type: "thinking_delta", text: "thought", sessionId: "s-1" },
      { type: "stream_delta", text: "done", sessionId: "s-1" },
      { type: "status", status: "idle", sessionId: "s-1" },
    ]);
    vi.advanceTimersByTime(100);
    expect(ws.send).toHaveBeenCalledTimes(4);

    bridge.close();
  });

  it("keeps batches isolated by session", () => {
    vi.useFakeTimers();
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      deltaBatchMs: 100,
    });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    (bridge as any).wss.clients.add(ws);

    (bridge as any).broadcastSessionMessage("s-1", {
      type: "stream_delta",
      text: "one",
    });
    (bridge as any).broadcastSessionMessage("s-2", {
      type: "stream_delta",
      text: "two",
    });
    (bridge as any).broadcastSessionMessage("s-1", {
      type: "status",
      status: "idle",
    });

    expect(
      ws.send.mock.calls.map((call: unknown[]) =>
        JSON.parse(call[0] as string),
      ),
    ).toEqual([
      { type: "stream_delta", text: "one", sessionId: "s-1" },
      { type: "status", status: "idle", sessionId: "s-1" },
    ]);
    vi.advanceTimersByTime(100);
    expect(JSON.parse(ws.send.mock.calls[2][0] as string)).toEqual({
      type: "stream_delta",
      text: "two",
      sessionId: "s-2",
    });

    bridge.close();
  });

  it("splits oversized deltas without breaking Unicode characters", () => {
    vi.useFakeTimers();
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      deltaBatchMs: 100,
      deltaBatchMaxChars: 2,
    });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    (bridge as any).wss.clients.add(ws);

    (bridge as any).broadcastSessionMessage("s-1", {
      type: "stream_delta",
      text: "A😀BC",
    });
    vi.advanceTimersByTime(100);

    const messages = ws.send.mock.calls.map((call: unknown[]) =>
      JSON.parse(call[0] as string),
    );
    expect(
      messages.map((message: { text: string }) => message.text).join(""),
    ).toBe("A😀BC");
    expect(
      messages.every(
        (message: { text: string }) => Array.from(message.text).length <= 2,
      ),
    ).toBe(true);

    bridge.close();
  });

  it("flushes pending deltas before excluding a client from a later delta", () => {
    vi.useFakeTimers();
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      deltaBatchMs: 100,
    });
    const included = { readyState: OPEN_STATE, send: vi.fn() } as any;
    const excluded = { readyState: OPEN_STATE, send: vi.fn() } as any;
    (bridge as any).wss.clients.add(included);
    (bridge as any).wss.clients.add(excluded);

    (bridge as any).broadcastSessionMessage("s-1", {
      type: "stream_delta",
      text: "first",
    });
    (bridge as any).broadcastSessionMessage(
      "s-1",
      { type: "stream_delta", text: "second" },
      excluded,
    );

    expect(
      included.send.mock.calls.map((call: unknown[]) =>
        JSON.parse(call[0] as string),
      ),
    ).toEqual([
      { type: "stream_delta", text: "first", sessionId: "s-1" },
      { type: "stream_delta", text: "second", sessionId: "s-1" },
    ]);
    expect(JSON.parse(excluded.send.mock.calls[0][0] as string)).toEqual({
      type: "stream_delta",
      text: "first",
      sessionId: "s-1",
    });

    bridge.close();
  });

  it("flushes pending deltas before destroying a session", () => {
    vi.useFakeTimers();
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      deltaBatchMs: 100,
    });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    (bridge as any).wss.clients.add(ws);
    const destroy = vi.spyOn((bridge as any).sessionManager, "destroy");

    (bridge as any).broadcastSessionMessage("s-1", {
      type: "stream_delta",
      text: "final",
    });
    (bridge as any).destroySession("s-1");

    expect(JSON.parse(ws.send.mock.calls[0][0] as string)).toEqual({
      type: "stream_delta",
      text: "final",
      sessionId: "s-1",
    });
    expect(ws.send.mock.invocationCallOrder[0]).toBeLessThan(
      destroy.mock.invocationCallOrder[0],
    );

    bridge.close();
  });

  it("discards pending deltas when a client disconnects", () => {
    vi.useFakeTimers();
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      deltaBatchMs: 100,
    });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    (bridge as any).wss.clients.add(ws);

    (bridge as any).broadcastSessionMessage("s-1", {
      type: "stream_delta",
      text: "discarded",
    });
    (bridge as any).discardClientDeltaBatches(ws);
    vi.advanceTimersByTime(100);

    expect(ws.send).not.toHaveBeenCalled();

    bridge.close();
  });

  it("records original deltas immediately instead of recording batches", () => {
    vi.useFakeTimers();
    const recordingStore = {
      init: vi.fn(async () => {}),
      record: vi.fn(),
      saveMeta: vi.fn(),
    };
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      deltaBatchMs: 100,
      recordingStore: recordingStore as any,
    });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    (bridge as any).wss.clients.add(ws);

    (bridge as any).broadcastSessionMessage("s-1", {
      type: "stream_delta",
      text: "a",
    });
    (bridge as any).broadcastSessionMessage("s-1", {
      type: "stream_delta",
      text: "b",
    });

    expect(recordingStore.record.mock.calls).toEqual([
      ["s-1", "outgoing", { type: "stream_delta", text: "a" }],
      ["s-1", "outgoing", { type: "stream_delta", text: "b" }],
    ]);
    expect(ws.send).not.toHaveBeenCalled();
    vi.advanceTimersByTime(100);
    expect(JSON.parse(ws.send.mock.calls[0][0] as string).text).toBe("ab");

    bridge.close();
  });

  it("supports disabled batching and strict environment defaults", () => {
    vi.stubEnv("BRIDGE_DELTA_BATCH_MS", "100ms");
    vi.stubEnv("BRIDGE_DELTA_BATCH_MAX_CHARS", "-1");
    const fallbackBridge = new BridgeWebSocketServer({ server: httpServer });
    expect((fallbackBridge as any).deltaBatchMs).toBe(100);
    expect((fallbackBridge as any).deltaBatchMaxChars).toBe(4096);
    fallbackBridge.close();

    vi.stubEnv("BRIDGE_DELTA_BATCH_MS", "3000000000");
    const overflowBridge = new BridgeWebSocketServer({ server: httpServer });
    expect((overflowBridge as any).deltaBatchMs).toBe(100);
    overflowBridge.close();

    const overflowOptionBridge = new BridgeWebSocketServer({
      server: httpServer,
      deltaBatchMs: 3_000_000_000,
    });
    expect((overflowOptionBridge as any).deltaBatchMs).toBe(100);
    overflowOptionBridge.close();

    const disabledBridge = new BridgeWebSocketServer({
      server: httpServer,
      deltaBatchMs: 0,
    });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    (disabledBridge as any).wss.clients.add(ws);
    (disabledBridge as any).broadcastSessionMessage("s-1", {
      type: "stream_delta",
      text: "now",
    });
    expect(JSON.parse(ws.send.mock.calls[0][0] as string).text).toBe("now");
    disabledBridge.close();
  });

  it("projects detached Desktop activity into the background work state", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    (bridge as any).wss.clients.add(ws);
    await (bridge as any).handleClientMessage(
      {
        type: "client_capabilities",
        supportedServerMessages: ["background_activity_state_v1"],
      },
      ws,
    );
    const activeKeys = new Set(["codex\0desktop-thread"]);
    vi.spyOn(
      (bridge as any).localFeatures,
      "backgroundActiveConversationKeys",
    ).mockImplementation(() => new Set(activeKeys));

    ws.send.mockClear();
    (bridge as any).scheduleBackgroundActivityBroadcast();
    await vi.waitFor(() =>
      expect(
        ws.send.mock.calls
          .map((call: unknown[]) => JSON.parse(call[0] as string))
          .at(-1),
      ).toMatchObject({
        type: "background_activity_state_v1",
        activeWorkCount: 1,
      }),
    );

    activeKeys.clear();
    (bridge as any).scheduleBackgroundActivityBroadcast();
    await vi.waitFor(() =>
      expect(
        ws.send.mock.calls
          .map((call: unknown[]) => JSON.parse(call[0] as string))
          .at(-1),
      ).toMatchObject({ activeWorkCount: 0 }),
    );
    await bridge.close();
  });

  it("delivers only lightweight notifications while a client is backgrounded", async () => {
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      deltaBatchMs: 0,
    });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    (bridge as any).wss.clients.add(ws);
    await (bridge as any).handleClientMessage(
      {
        type: "client_capabilities",
        supportedServerMessages: [
          "client_delivery_mode_state_v1",
          "background_notification_v1",
          "background_activity_state_v1",
        ],
      },
      ws,
    );
    await (bridge as any).handleClientMessage(
      {
        type: "set_client_delivery_mode",
        mode: "notifications_only",
        requestId: "background-1",
        locale: "zh",
        enabledEventTypes: ["approval_required", "session_completed"],
      },
      ws,
    );
    expect(
      ws.send.mock.calls.map((call: unknown[]) =>
        JSON.parse(call[0] as string),
      ),
    ).toEqual([
      expect.objectContaining({
        type: "client_delivery_mode_state_v1",
        mode: "notifications_only",
        requestId: "background-1",
      }),
      expect.objectContaining({
        type: "background_activity_state_v1",
        activeWorkCount: 0,
      }),
    ]);

    ws.send.mockClear();
    (bridge as any).send(ws, {
      type: "error",
      errorCode: "session_runtime_error",
      message: "sensitive background failure detail",
    });
    (bridge as any).broadcastSessionMessage("session-1", {
      type: "stream_delta",
      text: "large streaming payload",
    });
    (bridge as any).broadcastSessionMessage("session-1", {
      type: "permission_request",
      toolUseId: "tool-1",
      toolName: "Bash",
      input: { command: "cat /private/secret" },
    });
    const backgroundMessages = ws.send.mock.calls.map((call: unknown[]) =>
      JSON.parse(call[0] as string),
    );
    expect(backgroundMessages).toHaveLength(1);
    expect(backgroundMessages[0]).toMatchObject({
      type: "background_notification_v1",
      eventType: "approval_required",
      sessionId: "session-1",
    });
    expect(JSON.stringify(backgroundMessages)).not.toContain(
      "large streaming payload",
    );
    expect(JSON.stringify(backgroundMessages)).not.toContain(
      "cat /private/secret",
    );

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "set_client_delivery_mode",
        mode: "interactive",
        requestId: "foreground-1",
      },
      ws,
    );
    (bridge as any).broadcastSessionMessage("session-1", {
      type: "stream_delta",
      text: "foreground payload",
    });
    expect(
      ws.send.mock.calls.map((call: unknown[]) =>
        JSON.parse(call[0] as string),
      ),
    ).toEqual([
      expect.objectContaining({
        type: "client_delivery_mode_state_v1",
        mode: "interactive",
        requestId: "foreground-1",
      }),
      expect.objectContaining({
        type: "stream_delta",
        text: "foreground payload",
      }),
    ]);
    bridge.close();
  });

  it("projects detached Desktop progress and terminal events without transcript leakage or replay", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    (bridge as any).bridgeInstanceId = "bridge-background-test";
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    (bridge as any).wss.clients.add(ws);
    await (bridge as any).handleClientMessage(
      {
        type: "client_capabilities",
        supportedServerMessages: [
          "client_delivery_mode_state_v1",
          "background_notification_v1",
          "background_activity_state_v1",
        ],
      },
      ws,
    );
    await (bridge as any).handleClientMessage(
      {
        type: "set_client_delivery_mode",
        mode: "notifications_only",
        requestId: "desktop-background",
        privacyMode: true,
        enabledEventTypes: [
          "session_progress",
          "session_completed",
          "session_failed",
        ],
      },
      ws,
    );
    ws.send.mockClear();

    (bridge as any).dispatchExternalCodexBackgroundCandidate({
      codexSourceId: (bridge as any).codexSourceId,
      threadId: "desktop-thread",
      turnId: "desktop-turn",
      observedAt: "2026-08-01T05:20:00.000Z",
      label: "Sensitive project",
      message: {
        type: "assistant",
        message: {
          id: "desktop-tool-message",
          role: "assistant",
          model: "",
          content: [
            {
              type: "tool_use",
              id: "desktop-tool",
              name: "Read",
              input: {},
            },
          ],
        },
      },
    });
    const progress = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.eventType === "session_progress");
    expect(progress).toMatchObject({
      type: "background_notification_v1",
      sessionId: "desktop-thread",
      provider: "codex",
      data: {
        providerSessionId: "desktop-thread",
        codexSourceId: (bridge as any).codexSourceId,
      },
    });
    expect(JSON.stringify(progress)).not.toContain("Sensitive project");
    expect(JSON.stringify(progress)).not.toContain("Read");
    expect(JSON.stringify(progress)).not.toContain("desktop-tool");

    const terminal = {
      codexSourceId: (bridge as any).codexSourceId,
      threadId: "desktop-thread",
      turnId: "desktop-turn",
      observedAt: "2026-08-01T05:20:05.000Z",
      message: {
        type: "result",
        subtype: "success",
        sessionId: "desktop-thread",
      },
    } as const;
    (bridge as any).dispatchExternalCodexBackgroundCandidate(terminal);
    (bridge as any).dispatchExternalCodexBackgroundCandidate(terminal);
    expect(
      ws.send.mock.calls
        .map((call: unknown[]) => JSON.parse(call[0] as string))
        .filter((message: any) => message.eventType === "session_completed"),
    ).toHaveLength(1);

    await (bridge as any).handleClientMessage(
      {
        type: "set_client_delivery_mode",
        mode: "interactive",
        requestId: "desktop-foreground",
      },
      ws,
    );
    ws.send.mockClear();
    (bridge as any).dispatchExternalCodexBackgroundCandidate({
      ...terminal,
      turnId: "desktop-turn-2",
    });
    expect(ws.send).not.toHaveBeenCalled();
    await bridge.close();
  });

  it("suppresses FCM only after the background client acknowledges local display", async () => {
    vi.useFakeTimers();
    const registeredPushToken = "b".repeat(32);
    const fetchMock = vi.fn(async () => new Response("", { status: 200 }));
    globalThis.fetch = fetchMock as unknown as typeof globalThis.fetch;
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      firebaseAuth: {
        uid: "bridge-test",
        getIdToken: vi.fn(async () => "mock-token"),
        initialize: vi.fn(async () => {}),
      } as any,
    });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    (bridge as any).wss.clients.add(ws);

    await (bridge as any).handleClientMessage(
      {
        type: "client_capabilities",
        supportedServerMessages: [
          "client_delivery_mode_state_v1",
          "background_notification_v1",
          "background_activity_state_v1",
        ],
      },
      ws,
    );
    await (bridge as any).handleClientMessage(
      {
        type: "push_register",
        token: registeredPushToken,
        platform: "ios",
      },
      ws,
    );
    await (bridge as any).handleClientMessage(
      {
        type: "set_client_delivery_mode",
        mode: "notifications_only",
        requestId: "background-with-ack",
        enabledEventTypes: ["approval_required"],
      },
      ws,
    );
    fetchMock.mockClear();
    ws.send.mockClear();

    (bridge as any).broadcastSessionMessage("session-1", {
      type: "permission_request",
      toolUseId: "permission-1",
      toolName: "Bash",
      input: { command: "true" },
    });

    const localNotification = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.type === "background_notification_v1");
    expect(localNotification.deliveryId).toEqual(expect.any(String));
    expect(fetchMock).not.toHaveBeenCalled();

    await (bridge as any).handleClientMessage(
      {
        type: "background_notification_ack_v1",
        deliveryId: localNotification.deliveryId,
      },
      ws,
    );
    await vi.advanceTimersByTimeAsync(750);

    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(JSON.parse(String(init.body))).toMatchObject({
      op: "notify",
      eventType: "approval_required",
      excludedTokens: [registeredPushToken],
      data: {
        deliveryId: localNotification.deliveryId,
      },
    });
    await bridge.close();
  });

  it("falls back to FCM when local background display is not acknowledged", async () => {
    vi.useFakeTimers();
    const registeredPushToken = "b".repeat(32);
    const fetchMock = vi.fn(async () => new Response("", { status: 200 }));
    globalThis.fetch = fetchMock as unknown as typeof globalThis.fetch;
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      firebaseAuth: {
        uid: "bridge-test",
        getIdToken: vi.fn(async () => "mock-token"),
        initialize: vi.fn(async () => {}),
      } as any,
    });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    (bridge as any).wss.clients.add(ws);
    await (bridge as any).handleClientMessage(
      {
        type: "client_capabilities",
        supportedServerMessages: [
          "client_delivery_mode_state_v1",
          "background_notification_v1",
          "background_activity_state_v1",
        ],
      },
      ws,
    );
    await (bridge as any).handleClientMessage(
      {
        type: "push_register",
        token: registeredPushToken,
        platform: "ios",
      },
      ws,
    );
    await (bridge as any).handleClientMessage(
      {
        type: "set_client_delivery_mode",
        mode: "notifications_only",
        requestId: "background-without-ack",
        enabledEventTypes: ["approval_required"],
      },
      ws,
    );
    fetchMock.mockClear();

    (bridge as any).broadcastSessionMessage("session-1", {
      type: "permission_request",
      toolUseId: "permission-1",
      toolName: "Bash",
      input: { command: "true" },
    });
    expect(fetchMock).not.toHaveBeenCalled();

    await vi.advanceTimersByTimeAsync(750);

    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    const body = JSON.parse(String(init.body)) as Record<string, unknown>;
    expect(body.op).toBe("notify");
    expect(body.excludedTokens).toBeUndefined();
    expect((body.data as Record<string, unknown>).deliveryId).toEqual(
      expect.any(String),
    );
    await bridge.close();
  });

  it("runs the catalog monitor only for an interactive opt-in client", async () => {
    let notifyCatalogChanged:
      | ((
          revision: number,
          change?: {
            revision: number;
            provider?: "claude" | "codex";
            providerSessionId?: string;
          },
        ) => void)
      | undefined;
    let active = false;
    const monitor = {
      get isActive() {
        return active;
      },
      start: vi.fn(async () => {
        active = true;
      }),
      close: vi.fn(() => {
        active = false;
      }),
    };
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      sessionCatalogMonitorFactory: (onChanged) => {
        notifyCatalogChanged = onChanged;
        return monitor;
      },
    });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    (bridge as any).wss.clients.add(ws);
    const catalogChanged = vi.spyOn(
      (bridge as any).localFeatures,
      "sessionCatalogChanged",
    );

    await (bridge as any).handleClientMessage(
      {
        type: "client_capabilities",
        supportedServerMessages: [
          "session_catalog_changed_v1",
          "client_delivery_mode_state_v1",
          "background_notification_v1",
          "background_activity_state_v1",
        ],
      },
      ws,
    );
    expect(monitor.start).toHaveBeenCalledOnce();
    notifyCatalogChanged?.(3, {
      revision: 3,
      provider: "codex",
      providerSessionId: "thread-3",
    });
    expect(JSON.parse(ws.send.mock.calls.at(-1)[0] as string)).toMatchObject({
      type: "session_catalog_changed_v1",
      revision: 3,
    });
    expect(catalogChanged).toHaveBeenCalledWith({
      revision: 3,
      provider: "codex",
      providerSessionId: "thread-3",
    });

    await (bridge as any).handleClientMessage(
      {
        type: "set_client_delivery_mode",
        mode: "notifications_only",
        requestId: "catalog-background",
      },
      ws,
    );
    expect(monitor.close).toHaveBeenCalled();
    ws.send.mockClear();
    notifyCatalogChanged?.(4);
    expect(ws.send).not.toHaveBeenCalled();

    await (bridge as any).handleClientMessage(
      {
        type: "set_client_delivery_mode",
        mode: "interactive",
        requestId: "catalog-foreground",
      },
      ws,
    );
    expect(monitor.start).toHaveBeenCalledTimes(2);
    await bridge.close();
    expect(active).toBe(false);
  });

  it("does not queue batched stream deltas for a background client", async () => {
    vi.useFakeTimers();
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      deltaBatchMs: 100,
    });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    (bridge as any).wss.clients.add(ws);
    await (bridge as any).handleClientMessage(
      {
        type: "client_capabilities",
        supportedServerMessages: [
          "client_delivery_mode_state_v1",
          "background_notification_v1",
          "background_activity_state_v1",
        ],
      },
      ws,
    );
    await (bridge as any).handleClientMessage(
      {
        type: "set_client_delivery_mode",
        mode: "notifications_only",
        requestId: "background-batched",
      },
      ws,
    );
    ws.send.mockClear();

    (bridge as any).broadcastSessionMessage("session-1", {
      type: "stream_delta",
      text: "sensitive batched payload",
    });
    vi.advanceTimersByTime(100);

    expect(ws.send).not.toHaveBeenCalled();
    expect((bridge as any).deltaBatches.has(ws)).toBe(false);
    bridge.close();
  });

  it("flushes every client batch during shutdown", () => {
    vi.useFakeTimers();
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      deltaBatchMs: 100,
    });
    const first = { readyState: OPEN_STATE, send: vi.fn() } as any;
    const second = { readyState: OPEN_STATE, send: vi.fn() } as any;
    (bridge as any).wss.clients.add(first);
    (bridge as any).wss.clients.add(second);

    (bridge as any).broadcastSessionMessage("s-1", {
      type: "thinking_delta",
      text: "closing",
    });
    bridge.close();

    expect(first.send).toHaveBeenCalledTimes(1);
    expect(second.send).toHaveBeenCalledTimes(1);
    vi.advanceTimersByTime(100);
    expect(first.send).toHaveBeenCalledTimes(1);
    expect(second.send).toHaveBeenCalledTimes(1);
  });

  it("acknowledges push registration only after the relay accepts it", async () => {
    const fetchMock = vi.fn(async () => new Response("", { status: 200 }));
    globalThis.fetch = fetchMock as unknown as typeof globalThis.fetch;
    const mockAuth = {
      uid: "bridge-test",
      getIdToken: vi.fn(async () => "mock-token"),
      initialize: vi.fn(async () => {}),
    };
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      firebaseAuth: mockAuth as any,
    });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    (bridge as any).wss.clients.add(ws);
    await (bridge as any).handleClientMessage(
      {
        type: "client_capabilities",
        supportedServerMessages: ["push_registration_state_v1"],
      },
      ws,
    );
    ws.send.mockClear();

    await (bridge as any).handleClientMessage(
      {
        type: "push_register",
        requestId: "push-register-1",
        token: "token-1",
        platform: "ios",
        locale: "zh",
        enabledEventTypes: ["approval_required"],
        approvalActionsSupported: true,
        approvalActionsVersion: 2,
      },
      ws,
    );
    await Promise.resolve();
    await Promise.resolve();

    expect(
      ws.send.mock.calls.map((call: unknown[]) =>
        JSON.parse(call[0] as string),
      ),
    ).toContainEqual({
      type: "push_registration_state_v1",
      operation: "register",
      requestId: "push-register-1",
      success: true,
    });
    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(JSON.parse(String(init.body))).toMatchObject({
      op: "register",
      approvalActionsSupported: true,
      approvalActionsVersion: 2,
    });
    bridge.close();
  });

  it("preserves the legacy push registration error for older clients", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    const registrationId = "legacy-registration-id";

    await (bridge as any).handleClientMessage(
      {
        type: "push_register",
        token: registrationId,
        platform: "ios",
      },
      ws,
    );

    expect(
      ws.send.mock.calls.map((call: unknown[]) =>
        JSON.parse(call[0] as string),
      ),
    ).toContainEqual({
      type: "error",
      message: "Push relay is not configured on bridge",
    });
    bridge.close();
  });

  it("rolls back in-memory push preferences when registration fails", async () => {
    const fetchMock = vi.fn(
      async () => new Response("relay failed", { status: 503 }),
    );
    globalThis.fetch = fetchMock as unknown as typeof globalThis.fetch;
    const mockAuth = {
      uid: "bridge-test",
      getIdToken: vi.fn(async () => "mock-token"),
      initialize: vi.fn(async () => {}),
    };
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      firebaseAuth: mockAuth as any,
    });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    const registrationId = "failed-registration-id";
    (bridge as any).wss.clients.add(ws);
    await (bridge as any).handleClientMessage(
      {
        type: "client_capabilities",
        supportedServerMessages: ["push_registration_state_v1"],
      },
      ws,
    );
    ws.send.mockClear();

    await (bridge as any).handleClientMessage(
      {
        type: "push_register",
        requestId: "push-register-failed",
        token: registrationId,
        platform: "ios",
        privacyMode: true,
        enabledEventTypes: ["session_progress"],
      },
      ws,
    );
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();

    expect((bridge as any).tokenLocales.has(registrationId)).toBe(false);
    expect((bridge as any).tokenPrivacyMode.has(registrationId)).toBe(false);
    expect((bridge as any).tokenEnabledEventTypes.has(registrationId)).toBe(
      false,
    );
    expect(
      ws.send.mock.calls.map((call: unknown[]) =>
        JSON.parse(call[0] as string),
      ),
    ).toContainEqual({
      type: "push_registration_state_v1",
      operation: "register",
      requestId: "push-register-failed",
      success: false,
      errorCode: "registration_failed",
    });
    bridge.close();
  });

  it("preserves the last confirmed push preferences when re-registration fails", async () => {
    const fetchMock = vi.fn(
      async () => new Response("relay failed", { status: 503 }),
    );
    globalThis.fetch = fetchMock as unknown as typeof globalThis.fetch;
    const mockAuth = {
      uid: "bridge-test",
      getIdToken: vi.fn(async () => "mock-token"),
      initialize: vi.fn(async () => {}),
    };
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      firebaseAuth: mockAuth as any,
    });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    (bridge as any).tokenLocales.set("token-existing", "ja");
    (bridge as any).tokenPrivacyMode.set("token-existing", false);
    (bridge as any).tokenEnabledEventTypes.set(
      "token-existing",
      new Set(["session_completed"]),
    );

    await (bridge as any).handleClientMessage(
      {
        type: "push_register",
        token: "token-existing",
        platform: "ios",
        locale: "zh",
        privacyMode: true,
        enabledEventTypes: ["session_progress"],
      },
      ws,
    );

    expect((bridge as any).tokenLocales.get("token-existing")).toBe("ja");
    expect((bridge as any).tokenPrivacyMode.get("token-existing")).toBe(false);
    expect([
      ...(bridge as any).tokenEnabledEventTypes.get("token-existing"),
    ]).toEqual(["session_completed"]);
    bridge.close();
  });

  it("sends push notification once per permission toolUseId", async () => {
    const fetchMock = vi.fn(async () => new Response("", { status: 200 }));
    globalThis.fetch = fetchMock as unknown as typeof globalThis.fetch;
    const mockAuth = {
      uid: "bridge-test",
      getIdToken: vi.fn(async () => "mock-token"),
      initialize: vi.fn(async () => {}),
    };

    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      firebaseAuth: mockAuth as any,
    });
    (bridge as any).broadcastSessionMessage("s-1", {
      type: "permission_request",
      toolUseId: "tool-1",
      toolName: "AskUserQuestion",
      input: {},
    });
    (bridge as any).broadcastSessionMessage("s-1", {
      type: "permission_request",
      toolUseId: "tool-1",
      toolName: "AskUserQuestion",
      input: {},
    });

    await Promise.resolve();
    await Promise.resolve();

    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    const payload = JSON.parse(String(init.body)) as Record<string, unknown>;
    expect(payload).toMatchObject({
      op: "notify",
      bridgeId: "bridge-test",
      eventType: "ask_user_question",
    });

    bridge.close();
  });

  it("keeps FCM privacy mode while retaining an opaque approval identity", async () => {
    const fetchMock = vi.fn(async () => new Response("", { status: 200 }));
    globalThis.fetch = fetchMock as unknown as typeof globalThis.fetch;
    const mockAuth = {
      uid: "bridge-test",
      getIdToken: vi.fn(async () => "mock-token"),
      initialize: vi.fn(async () => {}),
    };
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      firebaseAuth: mockAuth as any,
    });
    (bridge as any).bridgeInstanceId = "bridge-source-test";
    (bridge as any).tokenPrivacyMode.set("private-token", true);

    (bridge as any).broadcastSessionMessage("s-1", {
      type: "permission_request",
      toolUseId: "opaque-permission-id",
      toolName: "SensitiveToolName",
      input: { command: "private command" },
    });
    await Promise.resolve();
    await Promise.resolve();

    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    const payload = JSON.parse(String(init.body)) as {
      data?: Record<string, unknown>;
    };
    expect(payload.data).toMatchObject({
      sessionId: "s-1",
      permissionId: "opaque-permission-id",
      bridgeInstanceId: "bridge-source-test",
    });
    expect(payload.data).not.toHaveProperty("toolUseId");
    expect(payload.data).not.toHaveProperty("toolName");
    expect(JSON.stringify(payload)).not.toContain("SensitiveToolName");
    expect(JSON.stringify(payload)).not.toContain("private command");
    bridge.close();
  });

  it("fails private after restart until a phone re-registers its push policy", async () => {
    const fetchMock = vi.fn(async () => new Response("", { status: 200 }));
    globalThis.fetch = fetchMock as unknown as typeof globalThis.fetch;
    const mockAuth = {
      uid: "bridge-test",
      getIdToken: vi.fn(async () => "mock-token"),
      initialize: vi.fn(async () => {}),
    };
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      firebaseAuth: mockAuth as any,
    });

    // Cloud may still hold a durable token even though this fresh Bridge has
    // not yet reconstructed locale/privacy maps from Mobile registration.
    expect((bridge as any).tokenPrivacyMode.size).toBe(0);
    (bridge as any).broadcastSessionMessage("s-after-restart", {
      type: "result",
      subtype: "success",
      result: "private completion result",
      duration: 1.2,
    });
    await Promise.resolve();
    await Promise.resolve();

    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    const payload = JSON.parse(String(init.body)) as Record<string, unknown>;
    expect(payload).toMatchObject({
      op: "notify",
      eventType: "session_completed",
      locale: "en",
    });
    expect(JSON.stringify(payload)).not.toContain("private completion result");
    await bridge.close();
  });

  it("sends push notification for successful result and skips stopped result", async () => {
    const fetchMock = vi.fn(async () => new Response("", { status: 200 }));
    globalThis.fetch = fetchMock as unknown as typeof globalThis.fetch;
    const mockAuth = {
      uid: "bridge-test",
      getIdToken: vi.fn(async () => "mock-token"),
      initialize: vi.fn(async () => {}),
    };

    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      firebaseAuth: mockAuth as any,
    });
    (bridge as any).broadcastSessionMessage("s-1", {
      type: "result",
      subtype: "success",
      duration: 3.2,
      cost: 0.0045,
    });
    (bridge as any).broadcastSessionMessage("s-1", {
      type: "result",
      subtype: "stopped",
    });

    await Promise.resolve();
    await Promise.resolve();

    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    const payload = JSON.parse(String(init.body)) as Record<string, unknown>;
    expect(payload).toMatchObject({
      op: "notify",
      bridgeId: "bridge-test",
      eventType: "session_completed",
    });

    bridge.close();
  });

  it("rate limits and deduplicates intermediate progress notifications", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-07-24T00:00:00Z"));
    const fetchMock = vi.fn(async () => new Response("", { status: 200 }));
    globalThis.fetch = fetchMock as unknown as typeof globalThis.fetch;
    const mockAuth = {
      uid: "bridge-test",
      getIdToken: vi.fn(async () => "mock-token"),
      initialize: vi.fn(async () => {}),
    };

    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      firebaseAuth: mockAuth as any,
    });
    (bridge as any).tokenEnabledEventTypes.set(
      "token-progress",
      new Set(["session_progress"]),
    );
    (bridge as any).tokenPrivacyMode.set("token-progress", false);
    const assistantTool = (id: string, name: string) => ({
      type: "assistant",
      message: {
        role: "assistant",
        content: [{ type: "tool_use", id, name, input: {} }],
      },
    });

    (bridge as any).broadcastSessionMessage(
      "s-1",
      assistantTool("tool-1", "Read"),
    );
    (bridge as any).broadcastSessionMessage(
      "s-1",
      assistantTool("tool-1", "Read"),
    );
    vi.advanceTimersByTime(30_000);
    (bridge as any).broadcastSessionMessage(
      "s-1",
      assistantTool("tool-2", "Bash"),
    );
    vi.advanceTimersByTime(15_000);
    (bridge as any).broadcastSessionMessage(
      "s-1",
      assistantTool("tool-3", "Edit"),
    );

    await Promise.resolve();
    await Promise.resolve();

    expect(fetchMock).toHaveBeenCalledTimes(2);
    const payloads = fetchMock.mock.calls.map(([, init]) =>
      JSON.parse(String((init as RequestInit).body)),
    );
    expect(payloads).toEqual([
      expect.objectContaining({
        eventType: "session_progress",
        data: expect.objectContaining({ toolUseId: "tool-1" }),
      }),
      expect.objectContaining({
        eventType: "session_progress",
        data: expect.objectContaining({ toolUseId: "tool-3" }),
      }),
    ]);

    bridge.close();
  });

  it("does not generate intermediate progress without an explicit subscriber", async () => {
    const fetchMock = vi.fn(async () => new Response("", { status: 200 }));
    globalThis.fetch = fetchMock as unknown as typeof globalThis.fetch;
    const mockAuth = {
      uid: "bridge-test",
      getIdToken: vi.fn(async () => "mock-token"),
      initialize: vi.fn(async () => {}),
    };

    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      firebaseAuth: mockAuth as any,
    });
    (bridge as any).broadcastSessionMessage("s-1", {
      type: "assistant",
      message: {
        role: "assistant",
        content: [{ type: "tool_use", id: "tool-1", name: "Read", input: {} }],
      },
    });

    await Promise.resolve();
    await Promise.resolve();

    expect(fetchMock).not.toHaveBeenCalled();
    bridge.close();
  });

  it("derives Codex permissions mode in session_created output", () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const complete = (bridge as any).buildSessionCreatedMessage({
      sessionId: "codex-read-only",
      provider: "codex",
      projectPath: "/tmp/project",
      session: {
        codexSettings: {
          approvalPolicy: "on-request",
          sandboxMode: "read-only",
        },
      },
    });
    const partial = (bridge as any).buildSessionCreatedMessage({
      sessionId: "codex-partial",
      provider: "codex",
      projectPath: "/tmp/project",
      session: { codexSettings: { approvalPolicy: "on-request" } },
    });

    expect(complete.codexPermissionsMode).toBe("custom");
    expect(partial.codexPermissionsMode).toBeUndefined();
    bridge.close();
  });

  it("claude busy input is acked as queued and interrupts current turn", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-a",
        provider: "claude",
      },
      ws,
    );
    await Promise.resolve();

    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    const created = sends.find(
      (m: any) => m.type === "system" && m.subtype === "session_created",
    );
    expect(created).toBeDefined();
    const sessionId = created.sessionId as string;

    const session = (bridge as any).sessionManager.get(sessionId);
    session.process.isWaitingForInput = false;
    session.process.sendInput.mockReturnValue(true);

    ws.send.mockClear();
    (bridge as any).handleClientMessage(
      {
        type: "input",
        sessionId,
        text: "interrupt this",
      },
      ws,
    );

    const inputAck = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "input_ack");
    expect(inputAck).toMatchObject({
      type: "input_ack",
      sessionId,
      queued: true,
    });

    expect(session.process.sendInput).toHaveBeenCalledWith("interrupt this");
    expect(session.process.interrupt).toHaveBeenCalledTimes(1);

    bridge.close();
  });

  it("claude input uses dispatch result for queued ack and interrupt", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-a",
        provider: "claude",
      },
      ws,
    );
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "system" && m.subtype === "session_created");
    const sessionId = created.sessionId as string;
    const session = (bridge as any).sessionManager.get(sessionId);

    // Simulate race: snapshot says idle, but the SDK atomically decides to
    // queue and interrupt based on its current state.
    session.process.isWaitingForInput = true;
    session.process.dispatchInput = vi.fn(() => ({
      queued: true,
      shouldInterrupt: true,
    }));

    ws.send.mockClear();
    (bridge as any).handleClientMessage(
      {
        type: "input",
        sessionId,
        text: "race queued",
      },
      ws,
    );

    const inputAck = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "input_ack");
    expect(inputAck).toMatchObject({
      type: "input_ack",
      sessionId,
      queued: true,
    });
    expect(session.process.dispatchInput).toHaveBeenCalledWith("race queued");
    expect(session.process.interrupt).toHaveBeenCalledTimes(1);

    bridge.close();
  });

  it("does not interrupt queued Claude input while approval is pending", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-a",
        provider: "claude",
      },
      ws,
    );
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "system" && m.subtype === "session_created");
    const sessionId = created.sessionId as string;
    const session = (bridge as any).sessionManager.get(sessionId);
    session.process.dispatchInput = vi.fn(() => ({
      queued: true,
      shouldInterrupt: false,
    }));

    ws.send.mockClear();
    (bridge as any).handleClientMessage(
      {
        type: "input",
        sessionId,
        text: "after approval",
      },
      ws,
    );

    const inputAck = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "input_ack");
    expect(inputAck).toMatchObject({
      type: "input_ack",
      sessionId,
      queued: true,
    });
    expect(session.process.dispatchInput).toHaveBeenCalledWith(
      "after approval",
    );
    expect(session.process.interrupt).not.toHaveBeenCalled();

    bridge.close();
  });

  it("echoes clientMessageId and acceptedSeq on input_ack", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-a",
        provider: "claude",
      },
      ws,
    );
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "system" && m.subtype === "session_created");
    const sessionId = created.sessionId as string;

    ws.send.mockClear();
    (bridge as any).handleClientMessage(
      {
        type: "input",
        sessionId,
        text: "strict input",
        clientMessageId: "cm-1",
        baseSeq: 0,
      },
      ws,
    );

    const inputAck = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "input_ack");
    expect(inputAck).toMatchObject({
      type: "input_ack",
      sessionId,
      clientMessageId: "cm-1",
      stage: "bridge_accepted",
      acceptedSeq: expect.any(Number),
      queued: false,
    });
    expect(inputAck.acceptedSeq).toBeGreaterThan(0);

    bridge.close();
  });

  it("acks a retried clientMessageId without delivering it twice", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-idempotent-input",
        provider: "claude",
      },
      ws,
    );
    const created = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find(
        (message: any) =>
          message.type === "system" && message.subtype === "session_created",
      );
    const sessionId = created.sessionId as string;
    const session = (bridge as any).sessionManager.get(sessionId);

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "input",
        sessionId,
        text: "send exactly once",
        clientMessageId: "cm-idempotent-1",
        baseSeq: 0,
      },
      ws,
    );
    const firstAck = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.type === "input_ack");
    const historyLength = session.historyEntries.length;

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "input",
        sessionId,
        text: "different retry body must not run",
        clientMessageId: "cm-idempotent-1",
        baseSeq: 0,
      },
      ws,
    );
    const retryAck = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.type === "input_ack");
    const retryFrames = ws.send.mock.calls.map((call: unknown[]) =>
      JSON.parse(call[0] as string),
    );

    expect(retryAck).toMatchObject({
      type: "input_ack",
      sessionId,
      clientMessageId: "cm-idempotent-1",
      acceptedSeq: firstAck.acceptedSeq,
      queued: firstAck.queued,
    });
    expect(session.historyEntries).toHaveLength(historyLength);
    expect(
      retryFrames.filter((message: any) => message.type === "user_input"),
    ).toHaveLength(0);

    bridge.close();
  });

  it("broadcasts accepted claude user input to other connected clients", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    const otherWs = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    (bridge as any).wss.clients.add(ws);
    (bridge as any).wss.clients.add(otherWs);

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-a",
        provider: "claude",
      },
      ws,
    );
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "system" && m.subtype === "session_created");
    const sessionId = created.sessionId as string;

    ws.send.mockClear();
    otherWs.send.mockClear();
    (bridge as any).handleClientMessage(
      {
        type: "input",
        sessionId,
        text: "hello from phone",
        clientMessageId: "cm-phone-1",
      },
      ws,
    );

    const peerMessages = otherWs.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    expect(
      peerMessages.find((m: any) => m.type === "user_input"),
    ).toMatchObject({
      type: "user_input",
      sessionId,
      text: "hello from phone",
      clientMessageId: "cm-phone-1",
      historySeq: expect.any(Number),
    });
    expect(
      ws.send.mock.calls
        .map((c: unknown[]) => JSON.parse(c[0] as string))
        .some((m: any) => m.type === "user_input"),
    ).toBe(false);

    bridge.close();
  });

  it("rejects strict input when another user input exists after baseSeq", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-a",
        provider: "claude",
      },
      ws,
    );
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "system" && m.subtype === "session_created");
    const sessionId = created.sessionId as string;
    const baseSeq = (bridge as any).sessionManager.get(
      sessionId,
    ).historyRevision;
    (bridge as any).sessionManager.appendHistory(sessionId, {
      type: "user_input",
      text: "from another client",
    });

    ws.send.mockClear();
    (bridge as any).handleClientMessage(
      {
        type: "input",
        sessionId,
        text: "offline input",
        clientMessageId: "cm-conflict",
        baseSeq,
      },
      ws,
    );

    const rejected = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "input_rejected");
    expect(rejected).toMatchObject({
      type: "input_rejected",
      sessionId,
      clientMessageId: "cm-conflict",
      reason: "conflict",
    });

    bridge.close();
  });

  it("rejects codex strict input older than canonical baseline", async () => {
    codexThreadToSessionHistoryMock.mockReturnValue([
      {
        role: "user",
        uuid: "codex:user-turn:1",
        content: [{ type: "text", text: "canonical turn" }],
      },
    ]);

    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
      },
      ws,
    );
    await Promise.resolve();
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "system" && m.subtype === "session_created");
    const sessionId = created.sessionId as string;
    const session = (bridge as any).sessionManager.get(sessionId);
    session.claudeSessionId = "thr_codex_base_seq";
    session.process.readThread.mockResolvedValue({
      id: "thr_codex_base_seq",
      turns: [],
    });

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "get_history_delta",
        sessionId,
        sinceSeq: 0,
      },
      ws,
    );
    expect(session.codexCanonicalHistoryRevision).toBeGreaterThan(1);

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "input",
        sessionId,
        text: "offline input",
        clientMessageId: "cm-codex-conflict",
        baseSeq: 0,
      },
      ws,
    );

    const rejected = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "input_rejected");
    expect(rejected).toMatchObject({
      type: "input_rejected",
      sessionId,
      clientMessageId: "cm-codex-conflict",
      reason: "conflict",
    });
    expect(
      ws.send.mock.calls
        .map((c: unknown[]) => JSON.parse(c[0] as string))
        .some((m: any) => m.type === "user_input"),
    ).toBe(false);

    bridge.close();
  });

  it("codex busy input is queued and included in session_list", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    await (bridge as any).handleClientMessage(
      {
        type: "client_capabilities",
        supportedServerMessages: ["conversation_queue"],
      },
      ws,
    );

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
      },
      ws,
    );
    await Promise.resolve();

    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    const created = sends.find(
      (m: any) => m.type === "system" && m.subtype === "session_created",
    );
    expect(created).toBeDefined();
    const sessionId = created.sessionId as string;

    const session = (bridge as any).sessionManager.get(sessionId);
    session.process.isWaitingForInput = false;

    ws.send.mockClear();
    (bridge as any).handleClientMessage(
      {
        type: "input",
        sessionId,
        text: "while busy",
        clientMessageId: "mobile-queued-state-1",
      },
      ws,
    );

    let sent = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    expect(sent.find((m: any) => m.type === "input_ack")).toMatchObject({
      type: "input_ack",
      sessionId,
      queued: true,
    });
    expect(session.codexQueuedInput).toMatchObject({ text: "while busy" });
    expect(session.process.sendInput).not.toHaveBeenCalled();
    (bridge as any).sendSessionList(ws);
    sent = ws.send.mock.calls.map((c: unknown[]) => JSON.parse(c[0] as string));
    const sessionList = sent.find((m: any) => m.type === "session_list");
    expect(sessionList.sessions[0].queuedInput).toMatchObject({
      text: "while busy",
      clientMessageId: "mobile-queued-state-1",
      deliveryStage: "bridge_accepted",
    });
    ws.send.mockClear();
    (bridge as any).sendCodexQueueState(ws, sessionId, session);
    const queueState = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "conversation_queue");
    expect(queueState.items[0]).toMatchObject({
      clientMessageId: "mobile-queued-state-1",
      deliveryStage: "bridge_accepted",
    });

    bridge.close();
  });

  it("adds synthetic UUIDs to live codex user input", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
      },
      ws,
    );
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "system" && m.subtype === "session_created");
    expect(created).not.toHaveProperty("claudeSessionId");
    const sessionId = created.sessionId as string;

    (bridge as any).handleClientMessage(
      {
        type: "input",
        sessionId,
        text: "first codex turn",
        clientMessageId: "cm-codex-1",
      },
      ws,
    );

    const session = (bridge as any).sessionManager.get(sessionId);
    const userInput = session.history.find(
      (message: any) => message.type === "user_input",
    );
    expect(userInput).toMatchObject({
      type: "user_input",
      text: "first codex turn",
      userMessageUuid: "codex:user-turn:1",
    });
    const echoedUserInput = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find(
        (m: any) =>
          m.type === "user_input" && m.clientMessageId === "cm-codex-1",
      );
    expect(echoedUserInput).toMatchObject({
      type: "user_input",
      sessionId,
      text: "first codex turn",
      userMessageUuid: "codex:user-turn:1",
      clientMessageId: "cm-codex-1",
    });
    expect(session.process.sendInput).toHaveBeenCalledWith(
      "first codex turn",
      "cm-codex-1",
    );

    bridge.close();
  });

  it("broadcasts accepted codex user input with UUID to other connected clients", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    const otherWs = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    (bridge as any).wss.clients.add(ws);
    (bridge as any).wss.clients.add(otherWs);

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
      },
      ws,
    );
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "system" && m.subtype === "session_created");
    const sessionId = created.sessionId as string;

    ws.send.mockClear();
    otherWs.send.mockClear();
    (bridge as any).handleClientMessage(
      {
        type: "input",
        sessionId,
        text: "codex from mac",
        clientMessageId: "cm-mac-1",
      },
      ws,
    );

    const peerMessages = otherWs.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    expect(
      peerMessages.find((m: any) => m.type === "user_input"),
    ).toMatchObject({
      type: "user_input",
      sessionId,
      text: "codex from mac",
      clientMessageId: "cm-mac-1",
      userMessageUuid: "codex:user-turn:1",
      historySeq: expect.any(Number),
    });

    bridge.close();
  });

  it("rolls back codex conversation turns and recreates the bridge session", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    (bridge as any).localFeatures.hasExternalCodexActivityVerified = vi.fn(
      async () => false,
    );
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    getCodexSessionHistoryMock.mockResolvedValue([
      {
        role: "user",
        uuid: "codex:user-turn:1",
        content: [{ type: "text", text: "first codex turn" }],
      },
    ]);

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
      },
      ws,
    );
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "system" && m.subtype === "session_created");
    const sessionId = created.sessionId as string;
    const session = (bridge as any).sessionManager.get(sessionId);
    session.claudeSessionId = "thread-rollback";
    session.process.sessionId = "thread-rollback";
    session.pastMessages = [
      {
        role: "user",
        uuid: "codex:user-turn:1",
        content: [{ type: "text", text: "first codex turn" }],
      },
      {
        role: "assistant",
        content: [{ type: "text", text: "first answer" }],
      },
      {
        role: "user",
        uuid: "codex:user-turn:2",
        content: [{ type: "text", text: "second codex turn" }],
      },
    ];
    const rollbackThread = session.process.rollbackThread;

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "rewind",
        sessionId,
        targetUuid: "codex:user-turn:1",
        mode: "conversation",
      },
      ws,
    );
    await Promise.resolve();

    expect(rollbackThread).toHaveBeenCalledWith(2);
    expect(getCodexSessionHistoryMock).not.toHaveBeenCalled();

    await vi.waitFor(() => {
      const messages = ws.send.mock.calls.map((c: unknown[]) =>
        JSON.parse(c[0] as string),
      );
      expect(
        messages.find((m: any) => m.type === "rewind_result"),
      ).toMatchObject({
        success: true,
        mode: "conversation",
      });
    });
    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    const newCreated = sends.find(
      (m: any) => m.type === "system" && m.subtype === "session_created",
    );
    expect(newCreated).toMatchObject({
      provider: "codex",
      projectPath: resolve("/tmp/project-codex"),
      sourceSessionId: sessionId,
    });
    const newSession = (bridge as any).sessionManager.get(newCreated.sessionId);
    expect(newSession.codexOptions).toMatchObject({
      threadId: "thread-rollback",
    });
    expect(newSession.pastMessages).toEqual([]);

    bridge.close();
  });

  it("forks codex conversation at a target turn and rolls back only the fork", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    (bridge as any).localFeatures.hasExternalCodexActivityVerified = vi.fn(
      async () => false,
    );
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
      },
      ws,
    );
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "system" && m.subtype === "session_created");
    const sessionId = created.sessionId as string;
    const session = (bridge as any).sessionManager.get(sessionId);
    session.process.sessionId = "thread-source";
    session.process.forkThread.mockResolvedValueOnce({
      threadId: "thread-forked",
      thread: { id: "thread-forked", turns: [] },
    });
    session.history = [
      {
        type: "user_input",
        text: "first codex turn",
        userMessageUuid: "codex:user-turn:1",
      },
      {
        type: "assistant",
        message: {
          id: "a1",
          role: "assistant",
          content: [{ type: "text", text: "first answer" }],
          model: "",
        },
      },
      {
        type: "user_input",
        text: "second codex turn",
        userMessageUuid: "codex:user-turn:2",
      },
      {
        type: "assistant",
        message: { id: "a2", role: "assistant", content: [], model: "" },
      },
    ];

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "fork",
        sessionId,
        targetUuid: "codex:user-turn:1",
      },
      ws,
    );
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();

    await vi.waitFor(() => {
      expect(session.process.forkThread).toHaveBeenCalledTimes(1);
    });
    expect(session.process.rollbackThreadById).toHaveBeenCalledWith(
      "thread-forked",
      1,
    );
    expect(getCodexSessionHistoryMock).not.toHaveBeenCalled();

    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    const newCreated = sends.find(
      (m: any) => m.type === "system" && m.subtype === "session_created",
    );
    expect(newCreated).toMatchObject({
      provider: "codex",
      projectPath: resolve("/tmp/project-codex"),
      sourceSessionId: sessionId,
    });
    const oldSession = (bridge as any).sessionManager.get(sessionId);
    expect(oldSession).toBeDefined();
    const newSession = (bridge as any).sessionManager.get(newCreated.sessionId);
    expect(newSession.codexOptions).toMatchObject({
      threadId: "thread-forked",
    });
    expect(newSession.pastMessages).toMatchObject([
      {
        role: "user",
        uuid: "codex:user-turn:1",
        content: [{ type: "text", text: "first codex turn" }],
      },
      {
        role: "assistant",
        uuid: undefined,
        content: [{ type: "text", text: "first answer" }],
      },
    ]);

    bridge.close();
  });

  it("forks the complete active Codex conversation at its latest turn", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    (bridge as any).localFeatures.hasExternalCodexActivityVerified = vi.fn(
      async () => false,
    );
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
      },
      ws,
    );
    const created = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find(
        (message: any) =>
          message.type === "system" && message.subtype === "session_created",
      );
    const session = (bridge as any).sessionManager.get(created.sessionId);
    session.process.sessionId = "thread-source-latest";
    session.history = [
      {
        type: "user_input",
        text: "first",
        userMessageUuid: "codex:user-turn:1",
      },
      {
        type: "assistant",
        message: { id: "a1", role: "assistant", content: [], model: "" },
      },
      {
        type: "user_input",
        text: "second",
        userMessageUuid: "codex:user-turn:2",
      },
    ];

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "fork",
        sessionId: created.sessionId,
        targetUuid: "codex:user-turn:latest",
      },
      ws,
    );

    await vi.waitFor(() => {
      expect(session.process.forkThread).toHaveBeenCalledTimes(1);
    });
    expect(session.process.rollbackThreadById).not.toHaveBeenCalled();
    const forkCreated = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find(
        (message: any) =>
          message.type === "system" && message.subtype === "session_created",
      );
    expect(forkCreated).toMatchObject({
      provider: "codex",
      sourceSessionId: created.sessionId,
      forkedFromSessionId: created.sessionId,
      forkedFromThreadId: "thread-source-latest",
    });
    const forked = (bridge as any).sessionManager.get(forkCreated.sessionId);
    expect(forked).toMatchObject({
      forkedFromSessionId: created.sessionId,
      forkedFromThreadId: "thread-source-latest",
    });
    expect(forked.pastMessages).toHaveLength(3);

    const sessionList = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.type === "session_list");
    expect(sessionList.sessions).toContainEqual(
      expect.objectContaining({
        id: forkCreated.sessionId,
        forkedFromSessionId: created.sessionId,
        forkedFromThreadId: "thread-source-latest",
      }),
    );

    bridge.close();
  });

  it("forks a persisted Codex thread into a normal listed session", async () => {
    getCodexSessionHistoryMock.mockResolvedValueOnce([
      {
        role: "user",
        uuid: "codex:user-turn:1",
        content: [{ type: "text", text: "persisted prompt" }],
      },
      {
        role: "assistant",
        content: [{ type: "text", text: "persisted answer" }],
      },
    ]);
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "fork",
        sessionId: "thread-persisted",
        targetUuid: "codex:user-turn:latest",
        projectPath: "/tmp/project-codex",
      },
      ws,
    );

    await vi.waitFor(() => {
      expect(
        ws.send.mock.calls
          .map((call: unknown[]) => JSON.parse(call[0] as string))
          .some(
            (message: any) =>
              message.type === "system" &&
              message.subtype === "session_created",
          ),
      ).toBe(true);
    });
    const forkCreated = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find(
        (message: any) =>
          message.type === "system" && message.subtype === "session_created",
      );
    expect(forkCreated).toMatchObject({
      provider: "codex",
      projectPath: resolve("/tmp/project-codex"),
      forkedFromThreadId: "thread-persisted",
    });
    expect(forkCreated).not.toHaveProperty("sourceSessionId");
    const forked = (bridge as any).sessionManager.get(forkCreated.sessionId);
    expect(forked.forkedFromThreadId).toBe("thread-persisted");
    expect(forked.codexOptions).toMatchObject({
      forkFromThreadId: "thread-persisted",
    });
    expect(forked.pastMessages).toHaveLength(2);

    bridge.close();
  });

  it("registers a durable side chat as an ordinary Codex child session", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const parentSessionId = (bridge as any).sessionManager.create(
      "/tmp/project-codex",
      undefined,
      [],
      undefined,
      "codex",
      {
        threadId: "thread-side-parent",
        model: "gpt-5.6-sol",
        modelReasoningEffort: "ultra",
        serviceTier: "fast",
        approvalPolicy: "never",
        sandboxMode: "danger-full-access",
      },
    );
    const parent = (bridge as any).sessionManager.get(parentSessionId);
    Object.setPrototypeOf(parent.process, CodexProcess.prototype);

    const opened = await (bridge as any).createPersistedCodexChildSession(
      parentSessionId,
      {
        threadSource: "ccpocket_side_chat",
        excludeTurnsOnOpen: true,
      },
    );

    const child = (bridge as any).sessionManager.get(opened.sessionId);
    expect(child).toBeDefined();
    expect(child.pastMessages).toEqual([]);
    expect(child.codexOptions).toMatchObject({
      forkFromThreadId: "thread-side-parent",
      excludeTurnsOnOpen: true,
      threadSource: "ccpocket_side_chat",
      model: "gpt-5.6-sol",
      modelReasoningEffort: "ultra",
      serviceTier: "fast",
      approvalPolicy: "never",
      sandboxMode: "danger-full-access",
    });
    expect(opened).toMatchObject({
      sessionId: child.id,
      projectPath: "/tmp/project-codex",
      permissionMode: "bypassPermissions",
    });

    bridge.close();
  });

  it("opens, lists, and closes an official ephemeral side chat without catalog persistence", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    const parentSessionId = (bridge as any).sessionManager.create(
      "/tmp/project-codex",
      undefined,
      [],
      undefined,
      "codex",
      {
        threadId: "thread-side-parent",
        model: "gpt-5.6-sol",
        modelReasoningEffort: "ultra",
        serviceTier: "fast",
        approvalPolicy: "never",
        sandboxMode: "danger-full-access",
      },
    );
    const parent = (bridge as any).sessionManager.get(parentSessionId);
    Object.setPrototypeOf(parent.process, CodexProcess.prototype);

    await (bridge as any).handleClientMessage(
      {
        type: "client_capabilities",
        supportedServerMessages: [
          "ephemeral_side_chat_opened",
          "ephemeral_side_chat_registry",
        ],
      },
      ws,
    );
    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "open_ephemeral_side_chat",
        parentSessionId,
        requestId: "request-open",
      },
      ws,
    );

    const openMessage = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.type === "ephemeral_side_chat_opened");
    expect(openMessage).toMatchObject({
      parentSessionId,
      requestId: "request-open",
      entry: {
        parentSessionId,
        projectPath: "/tmp/project-codex",
        permissionMode: "bypassPermissions",
      },
    });
    const childSessionId = openMessage.entry.childSessionId;
    const child = (bridge as any).sessionManager.get(childSessionId);
    expect(child.auxiliary).toEqual({
      kind: "ephemeral_side_chat",
      parentSessionId,
      parentProviderSessionId: "thread-side-parent",
    });
    expect(child.codexOptions).toMatchObject({
      ephemeralForkFromThreadId: "thread-side-parent",
      excludeTurnsOnOpen: true,
      threadSource: "ccpocket_side_chat",
      model: "gpt-5.6-sol",
      modelReasoningEffort: "ultra",
      serviceTier: "fast",
      approvalPolicy: "never",
      sandboxMode: "danger-full-access",
    });
    const readThread = child.process.readThread as ReturnType<typeof vi.fn>;
    readThread.mockRejectedValue(
      new Error("ephemeral threads do not support includeTurns"),
    );
    (bridge as any).sessionManager.appendHistory(childSessionId, {
      type: "assistant",
      message: {
        id: "ephemeral-answer",
        role: "assistant",
        content: [{ type: "text", text: "live-only answer" }],
        model: "gpt-5.6-sol",
      },
    });

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "get_history",
        sessionId: childSessionId,
      },
      ws,
    );
    const historyMessages = ws.send.mock.calls.map((call: unknown[]) =>
      JSON.parse(call[0] as string),
    );
    expect(
      historyMessages.find((message: any) => message.type === "history"),
    ).toMatchObject({
      sessionId: childSessionId,
      messages: [
        {
          type: "assistant",
          message: {
            id: "ephemeral-answer",
            content: [{ type: "text", text: "live-only answer" }],
          },
        },
      ],
    });
    expect(
      historyMessages.find((message: any) => message.type === "error"),
    ).toBeUndefined();
    expect(readThread).not.toHaveBeenCalled();
    expect(
      (bridge as any).sessionManager
        .list()
        .map((session: { id: string }) => session.id),
    ).toEqual([parentSessionId]);

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "list_ephemeral_side_chats",
        requestId: "request-list",
      },
      ws,
    );
    expect(
      ws.send.mock.calls
        .map((call: unknown[]) => JSON.parse(call[0] as string))
        .find(
          (message: any) =>
            message.type === "ephemeral_side_chat_registry" &&
            message.requestId === "request-list",
        ),
    ).toMatchObject({
      entries: [{ childSessionId, parentSessionId }],
    });

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "close_ephemeral_side_chat",
        childSessionId,
        requestId: "request-close",
      },
      ws,
    );
    expect((bridge as any).sessionManager.get(childSessionId)).toBeUndefined();
    expect(
      ws.send.mock.calls
        .map((call: unknown[]) => JSON.parse(call[0] as string))
        .find(
          (message: any) =>
            message.type === "ephemeral_side_chat_registry" &&
            message.requestId === "request-close",
        ),
    ).toMatchObject({ entries: [] });

    bridge.close();
  });

  it("forks an ephemeral child from a detached durable Codex thread on demand", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    getCodexSessionIndexMetadataMock.mockResolvedValueOnce(
      new Map([
        [
          "thread-side-detached",
          {
            resumeCwd: "/tmp/project-codex-detached",
            codexSettings: {
              model: "gpt-5.6-sol",
              modelReasoningEffort: "high",
              approvalPolicy: "never",
              sandboxMode: "danger-full-access",
            },
          },
        ],
      ]),
    );

    await (bridge as any).handleClientMessage(
      {
        type: "client_capabilities",
        supportedServerMessages: [
          "ephemeral_side_chat_opened",
          "ephemeral_side_chat_registry",
        ],
      },
      ws,
    );
    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "open_ephemeral_side_chat",
        parentSessionId: "detached-thread-route",
        parentProviderSessionId: "thread-side-detached",
        requestId: "request-open-detached",
      },
      ws,
    );

    expect(getCodexSessionIndexMetadataMock).toHaveBeenCalledWith(
      ["thread-side-detached"],
      { authoritativeCodexSettings: true },
    );
    const openMessage = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.type === "ephemeral_side_chat_opened");
    expect(openMessage).toMatchObject({
      parentSessionId: "detached-thread-route",
      requestId: "request-open-detached",
      entry: {
        parentSessionId: "detached-thread-route",
        parentProviderSessionId: "thread-side-detached",
        projectPath: "/tmp/project-codex-detached",
      },
    });
    const child = (bridge as any).sessionManager.get(
      openMessage.entry.childSessionId,
    );
    expect(child.codexOptions).toMatchObject({
      ephemeralForkFromThreadId: "thread-side-detached",
      excludeTurnsOnOpen: true,
      threadSource: "ccpocket_side_chat",
      model: "gpt-5.6-sol",
      modelReasoningEffort: "high",
      approvalPolicy: "never",
      sandboxMode: "danger-full-access",
    });
    expect(child.auxiliary).toEqual({
      kind: "ephemeral_side_chat",
      parentSessionId: "detached-thread-route",
      parentProviderSessionId: "thread-side-detached",
    });

    bridge.close();
  });

  it("fails closed when a runtime parent claims a different durable thread", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const parentSessionId = (bridge as any).sessionManager.create(
      "/tmp/project-codex",
      undefined,
      [],
      undefined,
      "codex",
      { threadId: "thread-side-parent" },
    );
    const parent = (bridge as any).sessionManager.get(parentSessionId);
    Object.setPrototypeOf(parent.process, CodexProcess.prototype);

    await expect(
      (bridge as any).createEphemeralCodexChildSession(parentSessionId, {
        threadSource: "ccpocket_side_chat",
        excludeTurnsOnOpen: true,
        parentProviderSessionId: "different-thread",
      }),
    ).rejects.toThrow(
      "The parent runtime does not match the requested Codex thread",
    );
    expect((bridge as any).sessionManager.listEphemeralSideChats()).toEqual([]);

    bridge.close();
  });

  it("rejects codex code rewind modes", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
      },
      ws,
    );
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "system" && m.subtype === "session_created");
    ws.send.mockClear();

    await (bridge as any).handleClientMessage(
      {
        type: "rewind",
        sessionId: created.sessionId,
        targetUuid: "codex:user-turn:1",
        mode: "code",
      },
      ws,
    );

    const result = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "rewind_result");
    expect(result).toMatchObject({
      success: false,
      mode: "code",
      error: "Codex only supports conversation rewind",
    });

    bridge.close();
  });

  it("codex busy input is rejected when the queue is full", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
      },
      ws,
    );
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "system" && m.subtype === "session_created");
    const sessionId = created.sessionId as string;
    const session = (bridge as any).sessionManager.get(sessionId);
    session.process.isWaitingForInput = false;
    session.codexQueuedInput = {
      itemId: "queued-1",
      text: "already queued",
      createdAt: new Date().toISOString(),
    };

    ws.send.mockClear();
    (bridge as any).handleClientMessage(
      {
        type: "input",
        sessionId,
        text: "second",
      },
      ws,
    );

    const last = JSON.parse(ws.send.mock.calls.at(-1)?.[0] as string);
    expect(last).toMatchObject({
      type: "input_rejected",
      sessionId,
      reason: "Queue is full",
    });
    expect(session.process.sendInput).not.toHaveBeenCalled();

    bridge.close();
  });

  it("updates and cancels codex queued input", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
      },
      ws,
    );
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "system" && m.subtype === "session_created");
    const sessionId = created.sessionId as string;
    const session = (bridge as any).sessionManager.get(sessionId);
    session.codexQueuedInput = {
      itemId: "queued-1",
      text: "original",
      createdAt: new Date().toISOString(),
    };

    (bridge as any).handleClientMessage(
      {
        type: "update_queued_input",
        sessionId,
        itemId: "queued-1",
        text: "edited",
      },
      ws,
    );
    expect(session.codexQueuedInput.text).toBe("edited");

    (bridge as any).handleClientMessage(
      {
        type: "cancel_queued_input",
        sessionId,
        itemId: "queued-1",
      },
      ws,
    );
    expect(session.codexQueuedInput).toBeUndefined();

    bridge.close();
  });

  it("wires local feature guards into SessionManager queue drains", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
      },
      ws,
    );
    await Promise.resolve();
    const created = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.subtype === "session_created");
    const session = (bridge as any).sessionManager.get(created.sessionId);
    session.process.isWaitingForInput = true;
    session.codexQueuedInput = {
      itemId: "queued-wiring",
      text: "stay queued",
      createdAt: new Date().toISOString(),
    };
    const admit = vi
      .spyOn((bridge as any).localFeatures, "admitCodexQueuedInputDrain")
      .mockReturnValue(false);
    const blocked = vi.spyOn(
      (bridge as any).localFeatures,
      "codexQueuedInputDrainBlocked",
    );

    expect(
      (bridge as any).sessionManager.drainCodexQueuedInputIfReady(
        created.sessionId,
      ),
    ).toBe(false);
    expect(admit).toHaveBeenCalledWith(session);
    expect(blocked).toHaveBeenCalledWith(session);
    expect(session.codexQueuedInput?.itemId).toBe("queued-wiring");
    bridge.close();
  });

  it("steers codex queued input and clears the queue", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    const otherWs = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;
    (bridge as any).wss.clients.add(ws);
    (bridge as any).wss.clients.add(otherWs);

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
      },
      ws,
    );
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "system" && m.subtype === "session_created");
    const sessionId = created.sessionId as string;
    const session = (bridge as any).sessionManager.get(sessionId);
    session.process.activeTurnId = "local-turn-1";
    session.codexQueuedInput = {
      itemId: "queued-1",
      text: "steer now",
      createdAt: new Date().toISOString(),
      userMessageUuid: "codex:user-turn:1",
      skills: [{ name: "skill", path: "/skills/skill" }],
    };
    ws.send.mockClear();
    otherWs.send.mockClear();

    await (bridge as any).handleClientMessage(
      {
        type: "steer_queued_input",
        sessionId,
        itemId: "queued-1",
      },
      ws,
    );

    expect(session.process.steerTurnStructured).toHaveBeenCalledWith(
      "local-turn-1",
      "steer now",
      {
        images: undefined,
        skills: [{ name: "skill", path: "/skills/skill" }],
        mentions: undefined,
      },
    );
    expect(session.codexQueuedInput).toBeUndefined();
    const peerMessages = otherWs.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    expect(
      peerMessages.find((m: any) => m.type === "user_input"),
    ).toMatchObject({
      type: "user_input",
      sessionId,
      text: "steer now",
      userMessageUuid: "codex:user-turn:1",
      historySeq: expect.any(Number),
    });

    bridge.close();
  });

  it("keeps codex queued input when steer fails", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
      },
      ws,
    );
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "system" && m.subtype === "session_created");
    const sessionId = created.sessionId as string;
    const session = (bridge as any).sessionManager.get(sessionId);
    session.process.activeTurnId = "local-turn-1";
    session.codexQueuedInput = {
      itemId: "queued-1",
      text: "steer now",
      createdAt: new Date().toISOString(),
    };
    session.process.steerTurnStructured.mockRejectedValueOnce(
      new Error("No active Codex turn to steer"),
    );

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "steer_queued_input",
        sessionId,
        itemId: "queued-1",
      },
      ws,
    );

    expect(session.codexQueuedInput?.text).toBe("steer now");
    const error = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "error");
    expect(error).toMatchObject({
      type: "error",
      errorCode: "queued_input_steer_failed",
    });

    bridge.close();
  });

  it("does not reroute a local guide when Desktop starts before the RPC", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
      },
      ws,
    );
    await Promise.resolve();
    const created = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.subtype === "session_created");
    const session = (bridge as any).sessionManager.get(created.sessionId);
    session.process.activeTurnId = "local-turn-a";
    session.codexQueuedInput = {
      itemId: "queued-local-race",
      text: "guide local A only",
      createdAt: new Date().toISOString(),
    };
    vi.spyOn((bridge as any).localFeatures, "hasExternalCodexActivity")
      .mockReturnValueOnce(false)
      .mockReturnValue(true);

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "steer_queued_input",
        sessionId: created.sessionId,
        itemId: "queued-local-race",
      },
      ws,
    );

    expect(session.process.steerTurnStructured).not.toHaveBeenCalled();
    expect(session.codexQueuedInput?.itemId).toBe("queued-local-race");
    expect(JSON.parse(ws.send.mock.calls.at(-1)?.[0] as string)).toMatchObject({
      type: "error",
      errorCode: "queued_input_steer_stale_turn",
    });
    bridge.close();
  });

  it("rejects delayed guidance when the Desktop turn identity changed", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
      },
      ws,
    );
    await Promise.resolve();
    const created = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.subtype === "session_created");
    const session = (bridge as any).sessionManager.get(created.sessionId);
    session.codexQueuedInput = {
      itemId: "queued-stale-turn",
      text: "guide old turn",
      createdAt: new Date().toISOString(),
    };
    vi.spyOn(
      (bridge as any).localFeatures,
      "externalCodexTurnId",
    ).mockReturnValue("desktop-turn-new");

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "steer_queued_input",
        sessionId: created.sessionId,
        itemId: "queued-stale-turn",
        expectedTurnId: "desktop-turn-old",
      },
      ws,
    );

    expect(session.process.steerTurnStructured).not.toHaveBeenCalled();
    expect(session.codexQueuedInput?.itemId).toBe("queued-stale-turn");
    expect(JSON.parse(ws.send.mock.calls.at(-1)?.[0] as string)).toMatchObject({
      type: "error",
      errorCode: "queued_input_steer_stale_turn",
    });
    bridge.close();
  });

  it("keeps external Desktop guidance queued without proven app-server ownership", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
      },
      ws,
    );
    await Promise.resolve();
    const created = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.subtype === "session_created");
    const session = (bridge as any).sessionManager.get(created.sessionId);
    Object.setPrototypeOf(session.process, CodexProcess.prototype);
    session.process.activeTurnId = undefined;
    session.codexQueuedInput = {
      itemId: "queued-external",
      text: "keep this for later",
      createdAt: new Date().toISOString(),
    };
    vi.spyOn(
      (bridge as any).localFeatures,
      "hasExternalCodexActivity",
    ).mockReturnValue(true);
    vi.spyOn(
      (bridge as any).localFeatures,
      "externalCodexTurnId",
    ).mockReturnValue("desktop-turn");
    const steerQueuedInput = vi.spyOn(
      (bridge as any).sessionManager,
      "steerCodexQueuedInput",
    );

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "steer_queued_input",
        sessionId: created.sessionId,
        itemId: "queued-external",
        expectedTurnId: "desktop-turn",
      },
      ws,
    );

    expect(steerQueuedInput).not.toHaveBeenCalled();
    expect(session.process.steerTurnStructured).not.toHaveBeenCalled();
    expect(session.codexQueuedInput?.itemId).toBe("queued-external");
    expect(JSON.parse(ws.send.mock.calls.at(-1)?.[0] as string)).toMatchObject({
      type: "error",
      errorCode: "external_turn_not_steerable",
      sessionId: created.sessionId,
    });
    bridge.close();
  });

  it("steers an external turn only when the Bridge process owns the exact turn", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
      },
      ws,
    );
    await Promise.resolve();
    const created = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.subtype === "session_created");
    const session = (bridge as any).sessionManager.get(created.sessionId);
    Object.setPrototypeOf(session.process, CodexProcess.prototype);
    session.process.activeTurnId = "shared-turn";
    session.codexQueuedInput = {
      itemId: "queued-shared",
      text: "guide the shared turn",
      createdAt: new Date().toISOString(),
    };
    vi.spyOn(
      (bridge as any).localFeatures,
      "hasExternalCodexActivity",
    ).mockReturnValue(true);
    vi.spyOn(
      (bridge as any).localFeatures,
      "externalCodexTurnId",
    ).mockReturnValue("shared-turn");

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "steer_queued_input",
        sessionId: created.sessionId,
        itemId: "queued-shared",
        expectedTurnId: "shared-turn",
      },
      ws,
    );

    expect(session.process.steerTurnStructured).toHaveBeenCalledWith(
      "shared-turn",
      "guide the shared turn",
      {
        images: undefined,
        skills: undefined,
        mentions: undefined,
      },
    );
    expect(session.codexQueuedInput).toBeUndefined();
    bridge.close();
  });

  it("steers a shared Desktop turn only with the exact source and authority generation", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
      },
      ws,
    );
    await Promise.resolve();
    const created = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.subtype === "session_created");
    const session = (bridge as any).sessionManager.get(created.sessionId);
    Object.setPrototypeOf(session.process, CodexProcess.prototype);
    delete session.process.usesSharedRuntimeTopology;
    session.claudeSessionId = "thread-desktop-exact";
    session.process._sharedRuntimePilotGates = {
      enabled: true,
      codexSourceId: "source-one",
      allowThreadStart: true,
      allowTurnStart: true,
    };
    session.process._sharedRuntimeAttachMode = "adoption";
    session.process._runtimeGeneration = 4;
    session.process._attachmentRuntimeGeneration = 4;
    session.process._attachmentReady = true;
    session.process._authoritativeThreadStatus = {
      type: "active",
      activeFlags: [],
    };
    session.process.sharedRuntimeOwnedTurnIds = new Set<string>();
    session.process.stopped = false;
    session.process.activeTurnId = "desktop-turn-exact";
    session.process._authorityGeneration = "authority-exact";
    session.codexQueuedInput = {
      itemId: "queued-desktop-exact",
      text: "guide the Desktop turn",
      createdAt: new Date().toISOString(),
    };
    vi.stubEnv("BRIDGE_CODEX_APP_SERVER_MODE", "daemon");
    (bridge as any).codexActionBrokerRuntime =
      writableCodexActionBrokerRuntime();

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "steer_queued_input",
        sessionId: created.sessionId,
        itemId: "queued-desktop-exact",
        expectedTurnId: "desktop-turn-exact",
        codexSourceId: (bridge as any).codexSourceId,
        threadId: "thread-desktop-exact",
        authorityGeneration: "stale-authority",
      },
      ws,
    );
    expect(session.process.steerExternalTurnStructured).not.toHaveBeenCalled();
    expect(session.codexQueuedInput?.itemId).toBe("queued-desktop-exact");
    expect(JSON.parse(ws.send.mock.calls.at(-1)?.[0] as string)).toMatchObject({
      type: "error",
      errorCode: "queued_input_steer_stale_authority",
    });

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "steer_queued_input",
        sessionId: created.sessionId,
        itemId: "queued-desktop-exact",
        expectedTurnId: "desktop-turn-exact",
        codexSourceId: (bridge as any).codexSourceId,
        threadId: "thread-desktop-exact",
        authorityGeneration: "authority-exact",
      },
      ws,
    );

    expect(session.process.steerExternalTurnStructured).toHaveBeenCalledWith(
      "desktop-turn-exact",
      "guide the Desktop turn",
      { images: undefined, skills: undefined, mentions: undefined },
    );
    expect(session.process.steerTurnStructured).not.toHaveBeenCalled();
    expect(session.codexQueuedInput).toBeUndefined();

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "detach_session",
        sessionId: created.sessionId,
        codexSourceId: (bridge as any).codexSourceId,
        threadId: "thread-desktop-exact",
        authorityGeneration: "authority-exact",
      },
      ws,
    );
    expect(session.process.stop).toHaveBeenCalledOnce();
    expect(
      (bridge as any).sessionManager.get(created.sessionId),
    ).toBeUndefined();
    expect(
      ws.send.mock.calls
        .map((call: unknown[]) => JSON.parse(call[0] as string))
        .some(
          (message: any) =>
            message.type === "result" && message.subtype === "stopped",
        ),
    ).toBe(false);
    bridge.close();
  });

  it("rejects guidance when overlapping Desktop turns have no unique target", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
      },
      ws,
    );
    await Promise.resolve();
    const created = ws.send.mock.calls
      .map((call: unknown[]) => JSON.parse(call[0] as string))
      .find((message: any) => message.subtype === "session_created");
    const session = (bridge as any).sessionManager.get(created.sessionId);
    const steerQueuedInput = vi.spyOn(
      (bridge as any).sessionManager,
      "steerCodexQueuedInput",
    );
    session.codexQueuedInput = {
      itemId: "queued-ambiguous-turn",
      text: "do not route this ambiguously",
      createdAt: new Date().toISOString(),
    };
    vi.spyOn(
      (bridge as any).localFeatures,
      "hasExternalCodexActivity",
    ).mockReturnValue(true);
    vi.spyOn(
      (bridge as any).localFeatures,
      "externalCodexTurnId",
    ).mockReturnValue(undefined);

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "steer_queued_input",
        sessionId: created.sessionId,
        itemId: "queued-ambiguous-turn",
      },
      ws,
    );

    expect(session.process.steerTurnStructured).not.toHaveBeenCalled();
    expect(steerQueuedInput).not.toHaveBeenCalled();
    expect(session.codexQueuedInput?.itemId).toBe("queued-ambiguous-turn");
    expect(JSON.parse(ws.send.mock.calls.at(-1)?.[0] as string)).toMatchObject({
      type: "error",
      errorCode: "queued_input_steer_ambiguous_turn",
    });
    bridge.close();
  });

  it("rejects steer_queued_input for claude sessions", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-claude",
        provider: "claude",
      },
      ws,
    );
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "system" && m.subtype === "session_created");
    const sessionId = created.sessionId as string;

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "steer_queued_input",
        sessionId,
        itemId: "queued-1",
      },
      ws,
    );

    const error = JSON.parse(ws.send.mock.calls.at(-1)?.[0] as string);
    expect(error).toMatchObject({
      type: "error",
      message: "No active Codex session.",
    });

    bridge.close();
  });

  it("includes sourceSessionId in rewind conversation session_created", async () => {
    vi.useFakeTimers();
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      deltaBatchMs: 100,
    });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;
    (bridge as any).wss.clients.add(ws);

    // Create a session first
    (bridge as any).handleClientMessage(
      { type: "start", projectPath: "/tmp/rewind-test", provider: "claude" },
      ws,
    );
    await Promise.resolve();

    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    const created = sends.find(
      (m: any) => m.type === "system" && m.subtype === "session_created",
    );
    const sessionId = created.sessionId as string;

    ws.send.mockClear();

    (bridge as any).broadcastSessionMessage(sessionId, {
      type: "stream_delta",
      text: "before rewind",
    });

    // Send rewind (conversation mode)
    (bridge as any).handleClientMessage(
      {
        type: "rewind",
        sessionId,
        targetUuid: "user-msg-1",
        mode: "conversation",
      },
      ws,
    );
    await Promise.resolve();
    await Promise.resolve();

    const rewindSends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    expect(rewindSends[0]).toEqual({
      type: "stream_delta",
      text: "before rewind",
      sessionId,
    });
    const rewindCreated = rewindSends.find(
      (m: any) => m.type === "system" && m.subtype === "session_created",
    );
    expect(rewindCreated).toBeDefined();
    expect(rewindCreated.sourceSessionId).toBe(sessionId);

    bridge.close();
  });

  it("includes sourceSessionId in rewind both session_created", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = { readyState: OPEN_STATE, send: vi.fn() } as any;

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/rewind-both-test",
        provider: "claude",
      },
      ws,
    );
    await Promise.resolve();

    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    const created = sends.find(
      (m: any) => m.type === "system" && m.subtype === "session_created",
    );
    const sessionId = created.sessionId as string;

    ws.send.mockClear();

    // Send rewind (both mode)
    (bridge as any).handleClientMessage(
      { type: "rewind", sessionId, targetUuid: "user-msg-1", mode: "both" },
      ws,
    );
    await Promise.resolve();
    await Promise.resolve();

    const rewindSends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    const rewindCreated = rewindSends.find(
      (m: any) => m.type === "system" && m.subtype === "session_created",
    );
    expect(rewindCreated).toBeDefined();
    expect(rewindCreated.sourceSessionId).toBe(sessionId);

    bridge.close();
  });

  it("uses active codex thread/list for codex recent sessions", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
      },
      ws,
    );

    await Promise.resolve();
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "system" && m.subtype === "session_created");
    const session = (bridge as any).sessionManager.get(created.sessionId);
    session.process.listThreads.mockResolvedValue({
      data: [
        {
          id: "thr_codex_1",
          preview: "Investigate crash",
          createdAt: 1771492643,
          updatedAt: 1771496243,
          cwd: "/tmp/project-codex",
          agentNickname: "Atlas",
          agentRole: "explorer",
          gitBranch: "feat/protocol",
          name: "Crash triage",
        },
      ],
      nextCursor: null,
    });
    getCodexSessionIndexMetadataMock.mockResolvedValue(
      new Map([
        [
          "thr_codex_1",
          {
            codexSettings: {
              approvalPolicy: "never",
              sandboxMode: "danger-full-access",
              model: "gpt-5.3-codex",
            },
            resumeCwd: "/tmp/project-codex-worktree",
            firstPrompt: "Investigate crash in the parser",
            lastPrompt: "add a regression test",
            summary: "Fixed the off-by-one in the tokenizer",
            forkedFromThreadId: "thr_parent",
          },
        ],
      ]),
    );

    const payload = await (bridge as any).listRecentCodexThreads({
      type: "list_recent_sessions",
      provider: "codex",
      projectPath: "/tmp/project-codex",
    });

    expect(session.process.listThreads).toHaveBeenCalledWith({
      limit: 20,
      searchTerm: undefined,
      sourceKinds: ["cli", "vscode", "exec", "appServer"],
    });
    expect(getCodexSessionIndexMetadataMock).toHaveBeenCalledWith([
      "thr_codex_1",
    ]);
    expect(getAllRecentSessionsMock).not.toHaveBeenCalled();
    expect(payload.sessions).toHaveLength(1);
    expect(payload.sessions[0]).toMatchObject({
      provider: "codex",
      sessionId: "thr_codex_1",
      forkedFromThreadId: "thr_parent",
      name: "Crash triage",
      agentNickname: "Atlas",
      agentRole: "explorer",
      gitBranch: "feat/protocol",
      projectPath: "/tmp/project-codex",
      resumeCwd: "/tmp/project-codex-worktree",
      // Rollout-parsed texts win over the thread/list preview blob.
      firstPrompt: "Investigate crash in the parser",
      lastPrompt: "add a regression test",
      summary: "Fixed the off-by-one in the tokenizer",
      codexSettings: {
        approvalPolicy: "never",
        sandboxMode: "danger-full-access",
        model: "gpt-5.3-codex",
      },
    });

    bridge.close();
  });

  it("paginates unscoped codex thread/list and filters worktrees locally", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const stop = vi.fn();
    const listThreads = vi
      .fn()
      .mockResolvedValueOnce({
        data: [
          {
            id: "thr_other_project",
            preview: "Unrelated thread",
            createdAt: 1771492643,
            updatedAt: 1771496244,
            cwd: "/tmp/other-project",
            agentNickname: null,
            agentRole: null,
            gitBranch: null,
            name: null,
          },
        ],
        nextCursor: "next-page",
      })
      .mockResolvedValueOnce({
        data: [
          {
            id: "thr_project_worktree",
            preview: "Worktree thread",
            createdAt: 1771492643,
            updatedAt: 1771496243,
            cwd: "/tmp/project-codex-worktrees/fix-tests",
            agentNickname: null,
            agentRole: null,
            gitBranch: "fix/tests",
            name: "Worktree fixes",
          },
        ],
        nextCursor: null,
      });

    (bridge as any).createStandaloneCodexProcess = vi.fn(async () => ({
      listThreads,
      stop,
    }));

    const payload = await (bridge as any).listRecentCodexThreads({
      type: "list_recent_sessions",
      provider: "codex",
      projectPath: "/tmp/project-codex",
      limit: 1,
    });

    expect(listThreads).toHaveBeenNthCalledWith(1, {
      limit: 20,
      searchTerm: undefined,
      sourceKinds: ["cli", "vscode", "exec", "appServer"],
    });
    expect(listThreads).toHaveBeenNthCalledWith(2, {
      limit: 20,
      cursor: "next-page",
      searchTerm: undefined,
      sourceKinds: ["cli", "vscode", "exec", "appServer"],
    });
    expect(payload).toMatchObject({
      hasMore: false,
      sessions: [
        {
          sessionId: "thr_project_worktree",
          projectPath: "/tmp/project-codex",
          resumeCwd: "/tmp/project-codex-worktrees/fix-tests",
        },
      ],
    });
    expect(stop).toHaveBeenCalledTimes(1);

    bridge.close();
  });

  it("bounds unscoped codex scanning by page count and reports more results", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const stop = vi.fn();
    const listThreads = vi.fn(async () => ({
      data: [],
      nextCursor: "cursor-that-keeps-going",
    }));
    (bridge as any).createStandaloneCodexProcess = vi.fn(async () => ({
      listThreads,
      stop,
    }));

    const payload = await (bridge as any).listRecentCodexThreads({
      type: "list_recent_sessions",
      provider: "codex",
      projectPath: "/tmp/sparse-project",
      limit: 1,
    });

    expect(listThreads).toHaveBeenCalledTimes(25);
    expect(payload).toEqual({ sessions: [], hasMore: true });
    expect(stop).toHaveBeenCalledTimes(1);

    bridge.close();
  });

  it("bounds unscoped codex scanning by thread count without losing search", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const stop = vi.fn();
    const unrelatedThreads = Array.from({ length: 100 }, (_, index) => ({
      id: `thr_unrelated_${index}`,
      preview: "Search match in another project",
      createdAt: 1771492643,
      updatedAt: 1771496243 - index,
      cwd: "/tmp/other-project",
      agentNickname: null,
      agentRole: null,
      gitBranch: null,
      name: null,
    }));
    const listThreads = vi.fn(async () => ({
      data: unrelatedThreads,
      nextCursor: "more-matching-search-results",
    }));
    (bridge as any).createStandaloneCodexProcess = vi.fn(async () => ({
      listThreads,
      stop,
    }));

    const payload = await (bridge as any).listRecentCodexThreads({
      type: "list_recent_sessions",
      provider: "codex",
      projectPath: "/tmp/sparse-project",
      searchQuery: "Search match",
      limit: 100,
    });

    expect(listThreads).toHaveBeenCalledTimes(10);
    expect(listThreads).toHaveBeenLastCalledWith({
      limit: 100,
      cursor: "more-matching-search-results",
      searchTerm: "Search match",
      sourceKinds: ["cli", "vscode", "exec", "appServer"],
    });
    expect(payload).toEqual({ sessions: [], hasMore: true });
    expect(stop).toHaveBeenCalledTimes(1);

    bridge.close();
  });

  it("uses standalone codex app-server for codex recent sessions when no active session exists", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const stop = vi.fn();

    (bridge as any).createStandaloneCodexProcess = vi.fn(async () => ({
      listThreads: vi.fn(async () => ({
        data: [
          {
            id: "thr_codex_2",
            preview: "Review failing tests",
            createdAt: 1771492643,
            updatedAt: 1771496243,
            cwd: "/tmp/project-codex-worktrees/fix-tests",
            agentNickname: null,
            agentRole: null,
            gitBranch: "fix/tests",
            name: "Test failures",
          },
        ],
        nextCursor: null,
      })),
      stop,
    }));

    const payload = await (bridge as any).listRecentCodexThreads({
      type: "list_recent_sessions",
      provider: "codex",
      projectPath: "/tmp/project-codex",
    });

    expect((bridge as any).createStandaloneCodexProcess).toHaveBeenCalledWith(
      "/tmp/project-codex",
    );
    expect(stop).toHaveBeenCalledTimes(1);
    expect(getCodexSessionIndexMetadataMock).toHaveBeenCalledWith([
      "thr_codex_2",
    ]);
    expect(getAllRecentSessionsMock).not.toHaveBeenCalled();
    expect(payload.sessions[0]).toMatchObject({
      provider: "codex",
      sessionId: "thr_codex_2",
      name: "Test failures",
      gitBranch: "fix/tests",
      projectPath: "/tmp/project-codex",
      resumeCwd: "/tmp/project-codex-worktrees/fix-tests",
    });

    bridge.close();
  });

  it("merges Claude scan with Codex thread/list without scanning Codex twice", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
      },
      ws,
    );

    await Promise.resolve();
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "system" && m.subtype === "session_created");
    const session = (bridge as any).sessionManager.get(created.sessionId);
    session.process.listThreads.mockResolvedValue({
      data: [
        {
          id: "thr_codex_all",
          preview: "Codex canonical result",
          createdAt: 1771492643,
          updatedAt: 1771496243,
          cwd: "/tmp/project-codex",
          agentNickname: null,
          agentRole: null,
          gitBranch: "main",
          name: "Codex thread",
        },
      ],
      nextCursor: null,
    });
    getAllRecentSessionsMock.mockClear();
    getAllRecentSessionsMock.mockResolvedValue({
      sessions: [
        {
          sessionId: "claude_recent",
          provider: "claude",
          firstPrompt: "Claude result",
          created: "2026-01-01T00:00:00.000Z",
          modified: "2026-01-01T00:00:00.000Z",
          gitBranch: "main",
          projectPath: "/tmp/project-claude",
          isSidechain: false,
        },
      ],
      hasMore: false,
    });
    getCodexSessionIndexMetadataMock.mockResolvedValue(new Map());

    const payload = await (bridge as any).listRecentSessions({
      type: "list_recent_sessions",
      limit: 20,
    });

    expect(getAllRecentSessionsMock).toHaveBeenCalledTimes(1);
    const scanOptions = getAllRecentSessionsMock.mock.calls[0][0];
    expect(scanOptions).toMatchObject({
      limit: 20,
      offset: 0,
      provider: "claude",
    });
    expect(session.process.listThreads).toHaveBeenCalledWith({
      limit: 20,
      cwd: undefined,
      searchTerm: undefined,
      sourceKinds: ["cli", "vscode", "exec", "appServer"],
    });
    expect(payload.hasMore).toBe(false);
    expect(payload.sessions.map((s: any) => s.sessionId)).toEqual([
      "thr_codex_all",
      "claude_recent",
    ]);
    expect(payload.sessions[0]).toMatchObject({
      sessionId: "thr_codex_all",
      provider: "codex",
      name: "Codex thread",
      // Opaque app-server previews may contain private agent-to-agent items.
      // Without rollout metadata the safe legacy display is empty.
      firstPrompt: "",
    });

    bridge.close();
  });

  it("uses a Codex-only rollout fallback when all-provider thread/list fails", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    (bridge as any).listRecentCodexThreads = vi
      .fn()
      .mockRejectedValue(new Error("thread/list unavailable"));
    getAllRecentSessionsMock
      .mockResolvedValueOnce({
        sessions: [
          {
            sessionId: "claude_recent",
            provider: "claude",
            firstPrompt: "Claude result",
            created: "2026-01-01T00:00:00.000Z",
            modified: "2026-01-01T00:00:00.000Z",
            gitBranch: "main",
            projectPath: "/tmp/project-claude",
            isSidechain: false,
          },
        ],
        hasMore: false,
      })
      .mockResolvedValueOnce({
        sessions: [
          {
            sessionId: "codex_fallback",
            provider: "codex",
            firstPrompt: "Codex rollout fallback",
            created: "2026-02-01T00:00:00.000Z",
            modified: "2026-02-01T00:00:00.000Z",
            gitBranch: "main",
            projectPath: "/tmp/project-codex",
            isSidechain: false,
          },
        ],
        hasMore: false,
      });

    const payload = await (bridge as any).listRecentSessions({
      type: "list_recent_sessions",
      limit: 20,
    });

    expect(getAllRecentSessionsMock).toHaveBeenCalledTimes(2);
    expect(getAllRecentSessionsMock.mock.calls[0][0]).toMatchObject({
      limit: 20,
      offset: 0,
      provider: "claude",
    });
    expect(getAllRecentSessionsMock.mock.calls[1][0]).toMatchObject({
      limit: 20,
      offset: 0,
      provider: "codex",
    });
    expect(payload).toMatchObject({
      hasMore: false,
      sessions: [
        { sessionId: "codex_fallback", provider: "codex" },
        { sessionId: "claude_recent", provider: "claude" },
      ],
    });

    bridge.close();
  });

  it("rejects git_commit autoGenerate without sessionId", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    (bridge as any).handleClientMessage(
      {
        type: "git_commit",
        projectPath: "/tmp/project-a",
        autoGenerate: true,
      },
      ws,
    );

    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    expect(sends).toContainEqual({
      type: "git_commit_result",
      success: false,
      projectPath: "/tmp/project-a",
      error: "git_commit with autoGenerate=true requires sessionId",
    });

    bridge.close();
  });

  it("rejects git_commit autoGenerate when projectPath does not match session cwd", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-a",
        provider: "claude",
      },
      ws,
    );
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "system" && m.subtype === "session_created");
    const sessionId = created.sessionId as string;

    ws.send.mockClear();
    (bridge as any).handleClientMessage(
      {
        type: "git_commit",
        sessionId,
        projectPath: "/tmp/other-project",
        autoGenerate: true,
      },
      ws,
    );

    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    expect(sends).toContainEqual({
      type: "git_commit_result",
      success: false,
      projectPath: "/tmp/other-project",
      error: "git_commit projectPath must match the active session cwd",
    });

    bridge.close();
  });

  it("auto-generates commit message for claude session", async () => {
    generateCommitMessageMock.mockReturnValue("feat: generated by claude");
    gitCommitMock.mockReturnValue({
      hash: "abc1234",
      message: "feat: generated by claude",
    });

    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-a",
        provider: "claude",
      },
      ws,
    );
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "system" && m.subtype === "session_created");
    const sessionId = created.sessionId as string;

    ws.send.mockClear();
    (bridge as any).handleClientMessage(
      {
        type: "git_commit",
        sessionId,
        projectPath: "/tmp/project-a",
        autoGenerate: true,
      },
      ws,
    );

    expect(generateCommitMessageMock).toHaveBeenCalledWith({
      provider: "claude",
      projectPath: "/tmp/project-a",
      model: undefined,
    });
    expect(gitCommitMock).toHaveBeenCalledWith(
      "/tmp/project-a",
      "feat: generated by claude",
    );

    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    expect(sends).toContainEqual({
      type: "git_commit_result",
      success: true,
      projectPath: "/tmp/project-a",
      commitHash: "abc1234",
      message: "feat: generated by claude",
    });

    bridge.close();
  });

  it("auto-generates commit message for codex session", async () => {
    generateCommitMessageMock.mockReturnValue("fix: generated by codex");
    gitCommitMock.mockReturnValue({
      hash: "def5678",
      message: "fix: generated by codex",
    });

    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    (bridge as any).handleClientMessage(
      {
        type: "start",
        projectPath: "/tmp/project-codex",
        provider: "codex",
        model: "gpt-5.4",
      },
      ws,
    );
    await Promise.resolve();

    const created = ws.send.mock.calls
      .map((c: unknown[]) => JSON.parse(c[0] as string))
      .find((m: any) => m.type === "system" && m.subtype === "session_created");
    const sessionId = created.sessionId as string;

    ws.send.mockClear();
    (bridge as any).handleClientMessage(
      {
        type: "git_commit",
        sessionId,
        projectPath: "/tmp/project-codex",
        autoGenerate: true,
      },
      ws,
    );

    expect(generateCommitMessageMock).toHaveBeenCalledWith({
      provider: "codex",
      projectPath: "/tmp/project-codex",
      model: "gpt-5.4",
    });
    expect(gitCommitMock).toHaveBeenCalledWith(
      "/tmp/project-codex",
      "fix: generated by codex",
    );

    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    expect(sends).toContainEqual({
      type: "git_commit_result",
      success: true,
      projectPath: "/tmp/project-codex",
      commitHash: "def5678",
      message: "fix: generated by codex",
    });

    bridge.close();
  });

  it("echoes projectPath in git result frames so project views can filter", () => {
    gitCommitMock.mockReturnValue({ hash: "aaa1111", message: "chore: echo" });

    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    (bridge as any).handleClientMessage(
      {
        type: "git_commit",
        projectPath: "/tmp/project-a",
        message: "chore: echo",
      },
      ws,
    );
    (bridge as any).handleClientMessage(
      { type: "git_fetch", projectPath: "/tmp/ccpocket-not-a-repo" },
      ws,
    );

    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    expect(sends).toContainEqual(
      expect.objectContaining({
        type: "git_commit_result",
        success: true,
        projectPath: "/tmp/project-a",
      }),
    );
    expect(sends).toContainEqual(
      expect.objectContaining({
        type: "git_fetch_result",
        success: false,
        projectPath: "/tmp/ccpocket-not-a-repo",
      }),
    );

    bridge.close();
  });

  it("preserves mobile queue changes made during Desktop history rehydration", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    const manager = (bridge as any).sessionManager;
    const oldSessionId = manager.create(
      "/tmp/project-codex",
      undefined,
      [],
      undefined,
      "codex",
      {
        threadId: "thread-desktop",
        approvalPolicy: "never",
        model: "gpt-5.6",
        modelReasoningEffort: "ultra",
      },
    );
    const oldSession = manager.get(oldSessionId);
    Object.setPrototypeOf(oldSession.process, CodexProcess.prototype);
    oldSession.name = "Continuity";

    let resolveHistory!: (history: unknown[]) => void;
    const historyPromise = new Promise<unknown[]>((resolve) => {
      resolveHistory = resolve;
    });
    const historyRead = vi
      .spyOn(bridge as any, "getCodexThreadHistory")
      .mockReturnValue(historyPromise);
    vi.spyOn(bridge as any, "loadAndSetSessionName").mockResolvedValue(
      undefined,
    );

    const rehydratePromise = (
      bridge as any
    ).rehydrateCodexSessionAfterExternalTurn(oldSessionId, "thread-desktop");
    await vi.waitFor(() => expect(historyRead).toHaveBeenCalledOnce());
    expect(oldSession.permissionRestartInProgress).toBeUndefined();

    const queuedInput = {
      itemId: "queue-during-preflight",
      text: "continue from the phone",
      createdAt: "2026-07-19T12:00:04Z",
      userMessageUuid: "codex:user-turn:2",
      clientMessageId: "mobile-during-preflight",
    };
    expect(manager.queueCodexInput(oldSessionId, queuedInput)).toBe(true);
    const canonicalHistory = [
      {
        role: "user",
        content: [{ type: "text", text: "desktop turn" }],
      },
    ];
    resolveHistory(canonicalHistory);

    await expect(rehydratePromise).resolves.toBe(true);
    const replacement = manager.get(oldSessionId);
    expect(replacement).toMatchObject({
      id: oldSessionId,
      name: "Continuity",
      pastMessages: canonicalHistory,
      codexQueuedInput: queuedInput,
      codexSettings: expect.objectContaining({
        threadId: "thread-desktop",
        model: "gpt-5.6",
        modelReasoningEffort: "ultra",
      }),
    });
    expect(oldSession.process.stop).toHaveBeenCalledOnce();

    await bridge.close();
  });
});

describe("BridgeWebSocketServer handshake Origin gate", () => {
  beforeEach(() => {
    getAllRecentSessionsMock.mockReset();
    getAllRecentSessionsMock.mockResolvedValue({
      sessions: [],
      hasMore: false,
    });
    getCodexSessionIndexMetadataMock.mockReset();
    getCodexSessionIndexMetadataMock.mockResolvedValue(new Map());
  });

  it("binds private browser Origins to the actual WebSocket host", async () => {
    const httpServer = createServer();
    const bridge = new BridgeWebSocketServer({ server: httpServer });
    await new Promise<void>((res) => {
      httpServer.listen(0, "127.0.0.1", res);
    });
    const port = (httpServer.address() as { port: number }).port;
    const url = `ws://127.0.0.1:${port}`;

    try {
      const browserAttempt = await new Promise<{
        opened: boolean;
        statusCode?: number;
      }>((res) => {
        const ws = new WsClient(url, { origin: "http://evil.example" });
        ws.on("unexpected-response", (_req, response) => {
          res({ opened: false, statusCode: response.statusCode });
          ws.terminate();
        });
        ws.on("error", () => {});
        ws.on("open", () => {
          res({ opened: true });
          ws.terminate();
        });
      });
      expect(browserAttempt).toEqual({ opened: false, statusCode: 403 });

      const nativeAttempt = await new Promise<boolean>((res) => {
        const ws = new WsClient(url);
        ws.on("open", () => {
          res(true);
          ws.close();
        });
        ws.on("error", () => res(false));
      });
      expect(nativeAttempt).toBe(true);

      const crossHostPrivateAttempt = await new Promise<boolean>((res) => {
        const ws = new WsClient(url, { origin: "http://100.105.41.82:8888" });
        ws.on("open", () => {
          res(true);
          ws.close();
        });
        ws.on("unexpected-response", () => res(false));
        ws.on("error", () => {});
      });
      expect(crossHostPrivateAttempt).toBe(false);

      const sameHostPrivateAttempt = await new Promise<boolean>((res) => {
        const ws = new WsClient(url, { origin: "http://127.0.0.1:8888" });
        ws.on("open", () => {
          res(true);
          ws.close();
        });
        ws.on("unexpected-response", () => res(false));
        ws.on("error", () => {});
      });
      expect(sameHostPrivateAttempt).toBe(true);
    } finally {
      await bridge.close();
      await new Promise<void>((res) => {
        httpServer.close(() => res());
      });
    }
  });

  it("allows an explicitly configured browser Origin", async () => {
    const httpServer = createServer();
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      allowedWebSocketOrigins: ["http://100.105.41.82:8888"],
    });
    await new Promise<void>((res) => {
      httpServer.listen(0, "127.0.0.1", res);
    });
    const port = (httpServer.address() as { port: number }).port;
    const url = `ws://127.0.0.1:${port}`;

    try {
      const opened = await new Promise<boolean>((res) => {
        const ws = new WsClient(url, { origin: "http://100.105.41.82:8888" });
        ws.on("open", () => {
          res(true);
          ws.close();
        });
        ws.on("unexpected-response", () => res(false));
        ws.on("error", () => {});
      });
      expect(opened).toBe(true);
    } finally {
      await bridge.close();
      await new Promise<void>((res) => {
        httpServer.close(() => res());
      });
    }
  });

  it("allows a valid API key to authenticate an otherwise untrusted Origin", async () => {
    const httpServer = createServer();
    const bridge = new BridgeWebSocketServer({
      server: httpServer,
      apiKey: "origin-gate-secret",
    });
    await new Promise<void>((res) => {
      httpServer.listen(0, "127.0.0.1", res);
    });
    const port = (httpServer.address() as { port: number }).port;
    const url = `ws://127.0.0.1:${port}?token=origin-gate-secret`;

    try {
      const opened = await new Promise<boolean>((res) => {
        const ws = new WsClient(url, { origin: "http://evil.example" });
        ws.on("open", () => {
          res(true);
          ws.close();
        });
        ws.on("unexpected-response", () => res(false));
        ws.on("error", () => {});
      });
      expect(opened).toBe(true);
    } finally {
      await bridge.close();
      await new Promise<void>((res) => {
        httpServer.close(() => res());
      });
    }
  });

  it("classifies origins as private strictly by hostname shape", () => {
    for (const origin of [
      "http://localhost:8888",
      "http://app.localhost",
      "http://my-mac.local:8888",
      "http://127.0.0.1:9000",
      "http://10.0.0.5",
      "http://192.168.1.10:8888",
      "http://172.16.0.2",
      "http://172.31.255.254",
      "http://100.64.0.1",
      "http://100.105.41.82:8888",
      "http://[::1]:8888",
      "http://[fd7a:115c:a1e0::1]",
    ]) {
      expect(isPrivateOrigin(origin), origin).toBe(true);
    }
    for (const origin of [
      "http://evil.example",
      "https://evil.example",
      "http://8.8.8.8",
      "http://172.15.0.1",
      "http://172.32.0.1",
      "http://100.63.0.1",
      "http://100.128.0.1",
      "https://attacker.tail1234.ts.net",
      "http://localhost.evil.example",
      "http://mylocal.example",
      "null",
      "not a url",
    ]) {
      expect(isPrivateOrigin(origin), origin).toBe(false);
    }
  });
});
