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

const {
  getSessionHistoryMock,
  getCodexSessionHistoryMock,
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
    ): string {
      const id = `s-${++this.seq}`;
      const process = {
        status: "idle",
        isRunning: true,
        activeTurnId: undefined as string | undefined,
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
      replacement.codexQueuedInput = current.codexQueuedInput;
      replacement.codexGoal = current.codexGoal;
      replacement.codexGoalUpdatedAt = current.codexGoalUpdatedAt;
      replacement.codexGoalOperationSequence =
        current.codexGoalOperationSequence;
      replacement.codexGoalControlSupported =
        current.codexGoalControlSupported;
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
        await session.process.steerTurnStructured(expectedTurnId, queued.text, {
          images: queued.images,
          skills: queued.skills,
          mentions: queued.mentions,
        });
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
      });
      session.codexQueuedInput = undefined;
      return true;
    }

    appendHistory(id: string, msg: any) {
      const session = this.sessions.get(id);
      if (!session) return undefined;
      const entry = {
        seq: session.historyRevision + 1,
        message: msg,
      };
      msg.historySeq = entry.seq;
      session.historyRevision = entry.seq;
      session.history.push(msg);
      session.historyEntries.push(entry);
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
      return Array.from(this.sessions.values()).map((s) => ({
        id: s.id,
        provider: s.provider,
        projectPath: s.projectPath,
        claudeSessionId: s.claudeSessionId,
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
        queuedInput: s.codexQueuedInput,
      }));
    }

    getCachedCommands() {
      return undefined;
    }

    destroy(id: string) {
      this.sessions.delete(id);
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
    artifactCandidateRootsForSession,
    SessionManager: MockSessionManager,
  };
});

import { BridgeWebSocketServer } from "./websocket.js";
import { CodexProcess } from "./codex-process.js";
import { ArtifactResolveError } from "./artifact-manager.js";
import { GalleryStore } from "./gallery-store.js";

describe("BridgeWebSocketServer resume/get_history flow", () => {
  const OPEN_STATE = 1;
  let httpServer: ReturnType<typeof createServer>;
  let originalFetch: typeof globalThis.fetch;

  beforeEach(() => {
    originalFetch = globalThis.fetch;
    httpServer = createServer();
    getSessionHistoryMock.mockReset();
    getCodexSessionHistoryMock.mockReset();
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
    expect(initialMessages).toContainEqual(expect.objectContaining({
      type: "session_list",
      bridgeCapabilities: expect.arrayContaining([
        "file_transfer_v2",
        "codex_desktop_continuity_v1",
      ]),
    }));

    const binding = fileTransfer.connect.mock.calls[0][1];
    expect(binding.httpBaseUrl).toBe("http://100.104.72.123:8765");
    expect(binding.supports("file_transfer_offer_v2")).toBe(false);
    expect(binding.send({
      type: "file_transfer_offer_v2",
      transferId: "download_1234567",
      filename: "x.txt",
      mimeType: "text/plain",
      sizeBytes: 1,
      downloadUrl: "http://100.64.0.1:8765/api/file-transfers/downloads/download_1234567",
      downloadToken: "d".repeat(43),
      etag: `"${"e".repeat(32)}"`,
      expiresAt: "2030-01-01T00:00:00.000Z",
    })).toBe(false);

    listeners.get("message")?.(Buffer.from(JSON.stringify({
      type: "client_capabilities",
      supportedServerMessages: [
        "file_transfer_offer_v2",
        "file_transfer_upload_ready_v2",
        "file_transfer_upload_result_v2",
      ],
    })));
    await vi.waitFor(() => expect(binding.supports("file_transfer_offer_v2")).toBe(true));
    expect(binding.send({
      type: "file_transfer_offer_v2",
      transferId: "download_1234567",
      filename: "x.txt",
      mimeType: "text/plain",
      sizeBytes: 1,
      downloadUrl: "http://100.64.0.1:8765/api/file-transfers/downloads/download_1234567",
      downloadToken: "d".repeat(43),
      etag: `"${"e".repeat(32)}"`,
      expiresAt: "2030-01-01T00:00:00.000Z",
    })).toBe(true);
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
      expect(fileTransfer.handleClientMessage).toHaveBeenCalledWith(ws, uploadPrepare);
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
    expect(fileTransfer.connect.mock.calls[0][1].httpBaseUrl)
      .toBe("http://127.0.0.1:18765");
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
    );
    expect(archiveThread).toHaveBeenCalledWith("thread-archive");
    expect(commitReservedArchive).not.toHaveBeenCalled();
    expect(releaseArchiveCapacity).toHaveBeenCalledWith(reservation);
    expect(stop).toHaveBeenCalledOnce();
    expect(createStandalone).toHaveBeenCalledWith("/project");
    expect(
      ws.send.mock.calls.map((call: unknown[]) => JSON.parse(call[0] as string)),
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
      throw new Error("Archive store has reached the supported 10000-entry limit");
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
      expect(unarchive).toHaveBeenCalledWith("thread-restore", "codex");
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
      expect(remove).toHaveBeenCalledWith("thread-delete", "codex");
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
            message.type === "system" &&
            message.subtype === "session_created",
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
        provider: "claude",
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
      ws.send.mock.calls.map((call: unknown[]) => JSON.parse(call[0] as string)),
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

  it("rejects input and a second action during the process-owned core-action ack window", async () => {
    const bridge = new BridgeWebSocketServer({ server: httpServer });
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
    session.process.compactThread = vi.fn(async () => {
      session.process.hasPendingCoreAction = true;
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
        text: "must not receive a false ack",
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
    expect(admissionMessages).toContainEqual({
      type: "input_rejected",
      sessionId,
      clientMessageId: "message-admission",
      reason: "Codex compact or review is starting",
    });
    expect(admissionMessages).not.toContainEqual(
      expect.objectContaining({
        type: "input_ack",
        clientMessageId: "message-admission",
      }),
    );
    expect(admissionMessages).not.toContainEqual(
      expect.objectContaining({
        type: "user_input",
        clientMessageId: "message-admission",
      }),
    );
    expect(session.history).toEqual([]);
    expect(session.codexQueuedInput).toBeUndefined();
    expect(session.process.sendInput).not.toHaveBeenCalled();
    expect(session.process.startInlineReview).not.toHaveBeenCalled();
    expect(session.process.listMcpServerStatus).toHaveBeenCalledOnce();

    // Models the process releasing admission after an RPC failure. Only then
    // may the ordinary input path acknowledge and consume the message.
    session.process.hasPendingCoreAction = false;
    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "input",
        sessionId,
        text: "safe after admission release",
        clientMessageId: "message-after-release",
      },
      ws,
    );
    const releasedMessages = ws.send.mock.calls.map((call: unknown[]) =>
      JSON.parse(call[0] as string),
    );
    expect(releasedMessages).toContainEqual(
      expect.objectContaining({
        type: "input_ack",
        clientMessageId: "message-after-release",
        queued: false,
      }),
    );
    expect(session.process.sendInput).toHaveBeenCalledWith(
      "safe after admission release",
      "message-after-release",
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
          new ArtifactResolveError(409, "file_changed", "Artifact file changed"),
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
      ws.send.mock.calls.map((call: unknown[]) => JSON.parse(call[0] as string)),
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
        responses.find((response: any) => response.requestId === "source-limit-0"),
      ).toMatchObject({
        requestId: "source-limit-0",
        errorCode: "file_changed",
        content: "",
      });
      expect(
        responses.find((response: any) => response.requestId === "source-limit-1"),
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
    (noManagerBridge as any).sessionManager.get(noManagerSession).claudeSessionId =
      "thread-no-artifacts";
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
        { type: "list_files", projectPath: repo },
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
        truncated: true,
      });
      expect(message.files).toHaveLength(2);
      expect(message.totalFiles).toBeUndefined();
      bridge.close();
    } finally {
      rmSync(repo, { recursive: true, force: true });
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
    expect(codexProcess.stop).toHaveBeenCalledTimes(1);
    expect((bridge as any).codexProfiles).toEqual(["ccpocket"]);
    expect((bridge as any).codexModels).toEqual(["gpt-test"]);
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

    bridge.close();
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
            message.type === "system" &&
            message.subtype === "session_created",
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
    const createdSessionIds = [wsA, wsB].map((ws) =>
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
    expect(resumeSends.some((m: any) => m.type === "past_history")).toBe(false);

    const created = resumeSends.find(
      (m: any) => m.type === "system" && m.subtype === "session_created",
    );
    expect(created).toBeDefined();
    expect(created.provider).toBe("claude");
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
    const session = (bridge as any).sessionManager.get(sessionId);
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

  it("does not publish the 5.5 fallback while a resumed model is unresolved", async () => {
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
    const session = (bridge as any).sessionManager.get(sessionId);
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
      fromSeq: 1,
      toSeq: 0,
      messages: [],
      reason: "reset",
    });
    expect(session.pastMessages).toEqual([]);
    expect(session.history).toEqual([]);
    expect(session.historyRevision).toBe(0);
    expect(session.codexCanonicalHistoryRevision).toBe(0);

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
      fromSeq: 1,
      toSeq: 2,
      reason: "reset",
      messages: [
        {
          seq: 1,
          message: {
            type: "user_input",
            text: "restore this thread",
            userMessageUuid: "codex:user-turn:1",
          },
        },
        {
          seq: 2,
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
    expect(session.codexCanonicalHistoryRevision).toBe(1);
    expect(session.historyEntries).toMatchObject([
      {
        seq: 2,
        message: {
          type: "assistant",
          messageUuid: "live-assistant-1",
        },
      },
    ]);
    expect(session.historyRevision).toBe(2);

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
      fromSeq: 1,
      toSeq: 2,
      messages: [
        {
          seq: 1,
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
          seq: 2,
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
    expect(session.historyEntries).toMatchObject([
      {
        seq: 2,
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
        seq: 5,
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
      fromSeq: 1,
      toSeq: 1,
      messages: [
        {
          seq: 1,
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
    expect(session.historyEntries).toEqual([]);
    expect(session.historyRevision).toBe(1);

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
      fromSeq: 1,
      toSeq: 1,
      messages: [
        {
          seq: 1,
          message: {
            type: "tool_result",
            toolUseId: "cmd-1",
            toolName: "Bash",
            content: "status: completed\nexitCode: 0\nclean",
          },
        },
      ],
    });
    expect(session.historyEntries).toEqual([]);
    expect(session.historyRevision).toBe(1);

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
      fromSeq: 1,
      toSeq: 2,
      messages: [
        {
          seq: 1,
          message: {
            type: "user_input",
            text: "stored before pending read",
            userMessageUuid: "codex:user-turn:1",
          },
        },
        {
          seq: 2,
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
    expect(session.historyEntries).toMatchObject([
      {
        seq: 2,
        message: {
          type: "assistant",
          messageUuid: "live-during-read",
        },
      },
    ]);

    bridge.close();
  });

  it("keeps codex canonical tool result images in history snapshots", async () => {
    codexThreadToSessionHistoryMock.mockReturnValue([
      {
        role: "tool_result",
        toolUseId: "ig-1",
        toolName: "ImageGeneration",
        content: "status: completed",
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
          seq: 1,
          message: {
            type: "tool_result",
            toolUseId: "ig-1",
            toolName: "ImageGeneration",
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
    const rawPath =
      "/tmp/codex/generated_images/生成 raw image.png";
    const managedPath =
      "/tmp/ccpocket-managed/hash/生成 raw image.png";
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
            message.type === "system" &&
            message.subtype === "session_created",
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
            message.type === "system" &&
            message.subtype === "session_created",
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
            message.type === "system" &&
            message.subtype === "session_created",
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
          seq: 1,
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

    bridge.close();
  });

  it("reports codex canonical history read failures without JSONL fallback", async () => {
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

    ws.send.mockClear();
    await (bridge as any).handleClientMessage(
      {
        type: "get_history",
        sessionId,
      },
      ws,
    );

    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    expect(getCodexSessionHistoryMock).not.toHaveBeenCalled();
    expect(sends).toEqual([
      {
        type: "error",
        message: "Failed to read Codex thread history: rpc unavailable",
      },
    ]);

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
      expect(responses.some((response: any) => response.content === "secret")).toBe(
        false,
      );
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
    });
    const ws = {
      readyState: OPEN_STATE,
      send: vi.fn(),
    } as any;

    await (bridge as any).handleClientMessage(
      {
        type: "resume_session",
        sessionId: "codex-thread-1",
        projectPath: "/tmp/project-codex",
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
    expect(created.claudeSessionId).toBe("codex-thread-1");

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

    (bridge as any).handleClientMessage(
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
    (bridge as any).handleClientMessage(
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

    bridge.close();
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
      (bridge as any).sessionManager.list().find((item: any) => item.id === sessionId)
        .codexGoalControlSupported,
    ).toBe(true);
    expect(
      session.history.some((message: any) => message.type === "goal_state"),
    ).toBe(false);

    bridge.close();
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
        supportedServerMessages: [
          "goal_state",
          "goal_state_raw_status",
        ],
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
    expect(session.process.updatePermissionSettingsForNextTurn).toHaveBeenCalledWith(
      {
        approvalPolicy: "never",
        approvalsReviewer: "user",
        codexPermissionsMode: "fullAccess",
        sandboxMode: "danger-full-access",
      },
    );
    expect(session.process.getPendingPermission()).toMatchObject({
      toolUseId: "pending-current-turn",
    });
    expect(
      session.process.interruptCurrentTurnAndWait,
    ).not.toHaveBeenCalled();

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
    expect(
      session.process.interruptCurrentTurnAndWait,
    ).not.toHaveBeenCalled();
    expect(
      ws.send.mock.calls.map((call: unknown[]) => JSON.parse(call[0] as string)),
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
    expect(
      oldSession.process.setGoal.mock.invocationCallOrder[0],
    ).toBeLessThan(
      oldSession.process.interruptCurrentTurnAndWait.mock.invocationCallOrder[0],
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
      acceptedSeq: expect.any(Number),
      queued: false,
    });
    expect(inputAck.acceptedSeq).toBeGreaterThan(0);

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
    expect(session.codexCanonicalHistoryRevision).toBe(1);

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

    const sends = ws.send.mock.calls.map((c: unknown[]) =>
      JSON.parse(c[0] as string),
    );
    expect(sends.find((m: any) => m.type === "rewind_result")).toMatchObject({
      success: true,
      mode: "conversation",
    });
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

    expect(session.process.forkThread).toHaveBeenCalledTimes(1);
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
    vi.spyOn(
      (bridge as any).localFeatures,
      "hasExternalCodexActivity",
    )
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

  it("merges codex thread/list into all-provider recent sessions without dropping scan-only codex sessions", async () => {
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
          sessionId: "scan_codex_only",
          provider: "codex",
          firstPrompt: "Codex scan-only result",
          created: "2026-03-01T00:00:00.000Z",
          modified: "2026-03-01T00:00:00.000Z",
          gitBranch: "main",
          projectPath: "/tmp/project-codex",
          isSidechain: false,
        },
        {
          sessionId: "thr_codex_all",
          provider: "codex",
          firstPrompt: "Stale scan duplicate",
          created: "2026-01-01T00:00:00.000Z",
          modified: "2026-01-01T00:00:00.000Z",
          gitBranch: "main",
          projectPath: "/tmp/project-codex",
          isSidechain: false,
        },
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
    });
    expect(scanOptions).not.toHaveProperty("provider");
    expect(session.process.listThreads).toHaveBeenCalledWith({
      limit: 20,
      cwd: undefined,
      searchTerm: undefined,
      sourceKinds: ["cli", "vscode", "exec", "appServer"],
    });
    expect(payload.hasMore).toBe(false);
    expect(payload.sessions.map((s: any) => s.sessionId)).toEqual([
      "scan_codex_only",
      "thr_codex_all",
      "claude_recent",
    ]);
    expect(payload.sessions[1]).toMatchObject({
      sessionId: "thr_codex_all",
      provider: "codex",
      name: "Codex thread",
      firstPrompt: "Codex canonical result",
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
      commitHash: "def5678",
      message: "fix: generated by codex",
    });

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
    ).rehydrateCodexSessionAfterExternalTurn(
      oldSessionId,
      "thread-desktop",
    );
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
