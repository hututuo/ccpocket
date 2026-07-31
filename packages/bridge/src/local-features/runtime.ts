import type { CodexProcess } from "../codex-process.js";
import type { FileBrowserManager } from "../file-browser-manager.js";
import type { ImageRef } from "../image-store.js";
import type { ClientMessage, ServerMessage } from "../parser.js";
import type { SessionCatalogChange } from "../session-catalog-monitor.js";
import type {
  LocalFeatureClientMessage,
  LocalFeatureServerMessage,
} from "./protocol.js";

export interface LocalFeatureSession {
  id: string;
  provider: string;
  process: unknown;
  projectPath?: string;
  createdAt?: Date;
}

export type LocalFeatureInputAdmission =
  | { action: "allow" }
  | { action: "queue"; reason: string }
  | { action: "reject"; reason: string };

export type LocalFeatureClientDeliveryMode =
  "interactive" | "notifications_only";

export interface LocalFeatureInputMessage {
  type: "input";
  sessionId?: string;
  clientMessageId?: string;
}

export interface PersistedCodexChildSession {
  sessionId: string;
  projectPath: string;
  worktreePath?: string;
  worktreeBranch?: string;
  permissionMode?: string;
  sandboxMode?: string;
  approvalPolicy?: string;
  approvalsReviewer?: string;
}

export interface EphemeralCodexChildSession {
  childSessionId: string;
  parentSessionId: string;
  parentProviderSessionId?: string;
  projectPath: string;
  worktreePath?: string;
  worktreeBranch?: string;
  permissionMode?: string;
  sandboxMode?: string;
  approvalPolicy?: string;
  approvalsReviewer?: string;
  status: string;
  createdAt: string;
  lastActivityAt: string;
}

export type LocalFeatureRuntimeProcessStatus =
  "starting" | "idle" | "running" | "waiting_approval" | "compacting";

export type LocalFeatureAttentionKind =
  "approval" | "question" | "permission" | "form";

/**
 * Privacy-bounded projection of one Bridge-owned runtime. Feature handlers use
 * this to overlay authoritative live state on the durable provider catalog
 * without receiving permission input, tool arguments, or conversation text.
 */
export interface LocalFeatureRuntimeConversationState {
  bridgeSessionId: string;
  provider: string;
  providerSessionId?: string;
  projectPath: string;
  processStatus: LocalFeatureRuntimeProcessStatus;
  pendingAttention?: {
    requestId: string;
    kind: LocalFeatureAttentionKind;
  };
  observedAt: string;
}

export interface LocalFeatureRuntime {
  /** Stable installation identity; persisted by the Bridge host when available. */
  readonly bridgeInstanceId?: string;
  /** Opaque identity of the selected Codex Home, when the host exposes one. */
  readonly codexSourceId?: string;
  /** Optional host-owned, root-scoped file-browser authority. */
  readonly fileBrowser?: FileBrowserManager;
  getSession(sessionId: string): LocalFeatureSession | undefined;
  getCodexThreadId(session: LocalFeatureSession): string | undefined;
  getProviderSessionId?(session: LocalFeatureSession): string | undefined;
  listRuntimeConversationStates?(): LocalFeatureRuntimeConversationState[];
  getClientDeliveryMode?(client: object): LocalFeatureClientDeliveryMode;
  getActiveCodexProcess(): CodexProcess | null;
  createStandaloneCodexProcess(
    timeoutMs?: number,
    projectPath?: string,
  ): Promise<CodexProcess>;
  createDedicatedCodexProcess?(): CodexProcess;
  /** Register a persisted official Codex child in the ordinary session runtime. */
  createPersistedCodexChildSession?(
    parentSessionId: string,
    options: { threadSource: string; excludeTurnsOnOpen: boolean },
  ): Promise<PersistedCodexChildSession>;
  /** Register an official in-memory Codex fork in the ordinary session runtime. */
  createEphemeralCodexChildSession?(
    parentSessionId: string,
    options: {
      threadSource: string;
      excludeTurnsOnOpen: boolean;
      parentProviderSessionId?: string;
    },
  ): Promise<EphemeralCodexChildSession>;
  listEphemeralCodexChildSessions?(): EphemeralCodexChildSession[];
  closeEphemeralCodexChildSession?(childSessionId: string): boolean;
  /** Host-owned authorization seam for optional features that accept a cwd. */
  isProjectPathAllowed?(projectPath: string): boolean;
  /** Host-owned identity check between a runtime session and a claimed cwd. */
  isSessionProjectPath?(
    session: LocalFeatureSession,
    projectPath: string,
  ): boolean;
  /** True only when this Bridge owns an active turn for the durable thread. */
  isCodexThreadLocallyActive?(threadId: string): boolean;
  /** Exact turn owned by this Bridge, when ownership can be proven. */
  getLocallyActiveCodexTurnId?(threadId: string): string | undefined;
  /**
   * Exact turn owned by one runtime session.
   *
   * Thread-level ownership is insufficient for user actions: two Bridge
   * runtime sessions can point at the same durable Codex thread. Actions such
   * as turn/steer must only be offered when the session bound to the Mobile
   * screen owns that exact turn.
   */
  getSessionCodexActiveTurnId?(sessionId: string): string | undefined;
  /** Recreate a stale Codex runtime from durable history after Desktop work. */
  rehydrateCodexSessionAfterExternalTurn?(
    sessionId: string,
    threadId: string,
    isStillSafe?: () => boolean,
  ): Promise<boolean>;
  hasCodexQueuedInput?(sessionId: string): boolean;
  /**
   * Converts trusted, already-decoded provider image output into opaque HTTP
   * references. Local features never serialize the raw base64 to a client.
   */
  registerInlineImages?(
    images: Array<{ data: string; mimeType: string }>,
  ): ImageRef[];
  /** Drain a queued phone turn only after a stale runtime refresh succeeded. */
  drainCodexQueuedInputIfReady?(
    sessionId: string,
    isStillSafe?: () => boolean,
  ): boolean;
  send(
    client: object,
    message:
      | LocalFeatureServerMessage
      | {
          type: "error";
          message: string;
          errorCode?: string;
        },
  ): void;
  isClientOpen?(client: object): boolean;
  supports(client: object, serverMessageType: string): boolean;
}

export interface LocalFeatureHandleContext {
  client: object;
  signal: AbortSignal;
  runtime: LocalFeatureRuntime;
}

export interface LocalFeatureHandler {
  readonly messageTypes: readonly LocalFeatureClientMessage["type"][];
  handle(
    message: LocalFeatureClientMessage,
    context: LocalFeatureHandleContext,
  ): Promise<void>;
  admitInput?(
    client: object,
    session: LocalFeatureSession,
    message: LocalFeatureInputMessage,
  ):
    | LocalFeatureInputAdmission
    | null
    | Promise<LocalFeatureInputAdmission | null>;
  inputAccepted?(
    client: object,
    session: LocalFeatureSession,
    message: LocalFeatureInputMessage,
    queued: boolean,
  ): void;
  /** Synchronous guard before SessionManager promotes a queued Codex input. */
  admitCodexQueuedInputDrain?(session: LocalFeatureSession): boolean;
  /** Notification that an input_ready/explicit drain was held by a guard. */
  codexQueuedInputDrainBlocked?(session: LocalFeatureSession): void;
  /** True when a Desktop-owned turn exists, even if no unique turn id exists. */
  hasExternalCodexActivity?(session: LocalFeatureSession): boolean;
  /**
   * Refreshes durable ownership evidence before a destructive settings write.
   * Implementations fail closed when ownership cannot be verified.
   */
  hasExternalCodexActivityVerified?(
    session: LocalFeatureSession,
  ): boolean | Promise<boolean>;
  externalCodexTurnId?(session: LocalFeatureSession): string | undefined;
  /** Observe one already-published session event without owning its transport. */
  sessionMessage?(session: LocalFeatureSession, message: ServerMessage): void;
  /** Observe one provider catalog/content invalidation without owning its watcher. */
  sessionCatalogChanged?(change: SessionCatalogChange): void;
  clientDeliveryModeChanged?(
    client: object,
    mode: LocalFeatureClientDeliveryMode,
  ): void;
  capabilitiesChanged?(client: object): void;
  disconnect?(client: object): void;
  close?(): void | Promise<void>;
}

export function asLocalFeatureMessage(
  message: ClientMessage,
  expected: LocalFeatureClientMessage["type"],
): LocalFeatureClientMessage | null {
  return message.type === expected
    ? (message as LocalFeatureClientMessage)
    : null;
}
