import { createHash, randomUUID } from "node:crypto";
import {
  chmod,
  mkdir,
  readFile,
  rename,
  rm,
  writeFile,
} from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import type { ServerMessage } from "../parser.js";
import { CodexProcess } from "../codex-process.js";
import type {
  CodexActionBrokerRuntimeRequest,
  CodexActionBrokerRuntimeUpdate,
} from "../codex-action-broker-runtime.js";
import type {
  AutoApprovalClientMessage,
  AutoApprovalStateMessage,
} from "./slots/auto-approval-protocol.js";
import {
  AUTO_APPROVAL_STATE_CAPABILITY,
  AUTO_APPROVAL_SUPERVISION_CAPABILITY,
} from "./slots/auto-approval-protocol.js";
import type {
  LocalFeatureHandleContext,
  LocalFeatureHandler,
  LocalFeatureRuntime,
  LocalFeatureSession,
} from "./runtime.js";

const AUTO_APPROVAL_STORE_VERSION = 2;
const LEGACY_AUTO_APPROVAL_STORE_VERSION = 1;
const MAX_ENABLED_THREADS = 4096;
const MAX_THREAD_ID_LENGTH = 256;
const MAX_CODEX_SOURCE_ID_LENGTH = 128;
const MAX_HANDLED_BROKER_REQUESTS = 4096;

interface AutoApprovalStoreFile {
  version: typeof AUTO_APPROVAL_STORE_VERSION;
  enabledConversations: AutoApprovalConversationIdentity[];
  /** Audit-only: unscoped legacy IDs never participate in authorization. */
  quarantinedLegacyThreadIds?: string[];
}

interface AutoApprovalConversationIdentity {
  codexSourceId: string;
  threadId: string;
}

interface AutoApprovalStoreOptions {
  filePath?: string;
}

export class AutoApprovalStore {
  readonly filePath: string;

  private readonly enabledConversations = new Map<
    string,
    AutoApprovalConversationIdentity
  >();
  private readonly quarantinedLegacyThreadIds = new Set<string>();
  private readonly settingIntents = new Map<
    string,
    AutoApprovalConversationIdentity & {
      enabled: boolean;
      generation: number;
    }
  >();
  private mutationTail: Promise<void> = Promise.resolve();
  private loadPromise: Promise<void> | undefined;
  private settingGeneration = 0;
  private disableAllGeneration = 0;
  private readonly disableAllPending = new Map<string, number>();
  private configured = false;

  constructor(options: AutoApprovalStoreOptions = {}) {
    this.filePath = options.filePath ?? defaultAutoApprovalStatePath();
  }

  async isActive(codexSourceId: string, threadId: string): Promise<boolean> {
    requireCodexSourceId(codexSourceId);
    requireThreadId(threadId);
    await this.ensureLoaded();
    return this.visibleEnabledThreadIds(codexSourceId).has(threadId);
  }

  async visibleState(
    codexSourceId: string,
    threadId?: string,
  ): Promise<{ enabled?: boolean; enabledConversationCount: number }> {
    requireCodexSourceId(codexSourceId);
    if (threadId !== undefined) requireThreadId(threadId);
    await this.ensureLoaded();
    const visible = this.visibleEnabledThreadIds(codexSourceId);
    return {
      ...(threadId ? { enabled: visible.has(threadId) } : {}),
      enabledConversationCount: visible.size,
    };
  }

  setEnabled(
    codexSourceId: string,
    threadId: string,
    enabled: boolean,
  ): Promise<void> {
    requireCodexSourceId(codexSourceId);
    requireThreadId(threadId);
    const identity = { codexSourceId, threadId };
    const identityKey = autoApprovalIdentityKey(identity);
    const generation = ++this.settingGeneration;
    this.settingIntents.set(identityKey, {
      ...identity,
      enabled,
      generation,
    });
    const operation = this.serializeMutation(async () => {
      await this.ensureLoaded();
      const next = new Map(this.enabledConversations);
      if (enabled) {
        if (next.size >= MAX_ENABLED_THREADS && !next.has(identityKey)) {
          throw new Error("Auto-approval conversation limit reached");
        }
        next.set(identityKey, identity);
      } else {
        next.delete(identityKey);
      }
      await this.persist(next, this.quarantinedLegacyThreadIds);
      this.replaceEnabledConversations(next);
    });
    return operation.finally(() => {
      if (this.settingIntents.get(identityKey)?.generation === generation) {
        this.settingIntents.delete(identityKey);
      }
    });
  }

  disableAll(codexSourceId: string): Promise<void> {
    requireCodexSourceId(codexSourceId);
    const generation = ++this.disableAllGeneration;
    this.disableAllPending.set(codexSourceId, generation);
    for (const [key, intent] of this.settingIntents) {
      if (intent.codexSourceId === codexSourceId) {
        this.settingIntents.delete(key);
      }
    }
    const operation = this.serializeMutation(async () => {
      await this.ensureLoaded();
      const next = new Map(this.enabledConversations);
      for (const [key, identity] of next) {
        if (identity.codexSourceId === codexSourceId) next.delete(key);
      }
      await this.persist(next, this.quarantinedLegacyThreadIds);
      this.replaceEnabledConversations(next);
    });
    return operation.finally(() => {
      if (this.disableAllPending.get(codexSourceId) === generation) {
        this.disableAllPending.delete(codexSourceId);
      }
    });
  }

  importLegacy(
    codexSourceId: string,
    threadIds: readonly string[],
  ): Promise<boolean> {
    requireCodexSourceId(codexSourceId);
    for (const threadId of threadIds) requireThreadId(threadId);
    if (threadIds.length > 512) {
      return Promise.reject(
        new Error("Legacy auto-approval import is too large"),
      );
    }
    return this.serializeMutation(async () => {
      await this.ensureLoaded();
      if (this.configured) return false;
      const quarantined = new Set(threadIds);
      await this.persist(new Map(), quarantined);
      this.replaceEnabledConversations(new Map());
      this.replaceQuarantinedLegacyThreadIds(quarantined);
      return true;
    });
  }

  /**
   * Refresh the source-global policy after a different Bridge acquires the
   * writer lease. Shared instances deliberately do not trust their startup
   * snapshot across authority generations.
   */
  reloadFromDisk(): Promise<void> {
    return this.serializeMutation(async () => {
      this.enabledConversations.clear();
      this.quarantinedLegacyThreadIds.clear();
      this.configured = false;
      const loading = this.load();
      this.loadPromise = loading;
      await loading;
    });
  }

  private visibleEnabledThreadIds(codexSourceId: string): Set<string> {
    const visible = new Set<string>();
    if (!this.disableAllPending.has(codexSourceId)) {
      for (const identity of this.enabledConversations.values()) {
        if (identity.codexSourceId === codexSourceId) {
          visible.add(identity.threadId);
        }
      }
    }
    for (const intent of this.settingIntents.values()) {
      if (intent.codexSourceId !== codexSourceId) continue;
      if (intent.enabled) visible.add(intent.threadId);
      else visible.delete(intent.threadId);
    }
    return visible;
  }

  private ensureLoaded(): Promise<void> {
    this.loadPromise ??= this.load();
    return this.loadPromise;
  }

  private async load(): Promise<void> {
    try {
      const decoded = JSON.parse(await readFile(this.filePath, "utf8")) as {
        version?: unknown;
        enabledConversations?: unknown;
        enabledThreadIds?: unknown;
        quarantinedLegacyThreadIds?: unknown;
      };
      if (decoded.version === LEGACY_AUTO_APPROVAL_STORE_VERSION) {
        if (
          !Array.isArray(decoded.enabledThreadIds) ||
          decoded.enabledThreadIds.length > MAX_ENABLED_THREADS
        ) {
          throw new Error("Unsupported auto-approval state file");
        }
        for (const value of decoded.enabledThreadIds) {
          requireThreadId(value);
          // A v1 thread ID cannot prove which Codex Home authorized it.
          // Preserve it for audit/migration, but deliberately grant nothing.
          this.quarantinedLegacyThreadIds.add(value);
        }
        this.configured = true;
        return;
      }
      if (decoded.version !== AUTO_APPROVAL_STORE_VERSION) {
        throw new Error("Unsupported auto-approval state file");
      }
      if (
        !Array.isArray(decoded.enabledConversations) ||
        decoded.enabledConversations.length > MAX_ENABLED_THREADS
      ) {
        throw new Error("Unsupported auto-approval state file");
      }
      const quarantined = decoded.quarantinedLegacyThreadIds ?? [];
      if (
        !Array.isArray(quarantined) ||
        quarantined.length > MAX_ENABLED_THREADS
      ) {
        throw new Error("Unsupported auto-approval state file");
      }
      for (const raw of decoded.enabledConversations) {
        if (!raw || typeof raw !== "object") {
          throw new Error("Unsupported auto-approval state file");
        }
        const identity = raw as {
          codexSourceId?: unknown;
          threadId?: unknown;
        };
        requireCodexSourceId(identity.codexSourceId);
        requireThreadId(identity.threadId);
        const value = {
          codexSourceId: identity.codexSourceId,
          threadId: identity.threadId,
        };
        this.enabledConversations.set(autoApprovalIdentityKey(value), value);
      }
      for (const value of quarantined) {
        requireThreadId(value);
        this.quarantinedLegacyThreadIds.add(value);
      }
      this.configured = true;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
        console.warn(
          `[auto-approval] Ignoring unreadable state: ${errorMessage(error)}`,
        );
        this.configured = true;
      }
      this.enabledConversations.clear();
      this.quarantinedLegacyThreadIds.clear();
    }
  }

  private serializeMutation<T>(operation: () => Promise<T>): Promise<T> {
    const current = this.mutationTail.then(operation);
    this.mutationTail = current.then(
      () => undefined,
      () => undefined,
    );
    return current;
  }

  private async persist(
    enabledConversations: ReadonlyMap<string, AutoApprovalConversationIdentity>,
    quarantinedLegacyThreadIds: ReadonlySet<string>,
  ): Promise<void> {
    const data: AutoApprovalStoreFile = {
      version: AUTO_APPROVAL_STORE_VERSION,
      enabledConversations: [...enabledConversations.values()].sort(
        compareAutoApprovalIdentities,
      ),
      ...(quarantinedLegacyThreadIds.size > 0
        ? {
            quarantinedLegacyThreadIds: [...quarantinedLegacyThreadIds].sort(),
          }
        : {}),
    };
    const directory = dirname(this.filePath);
    const temporaryPath = `${this.filePath}.tmp-${process.pid}-${randomUUID()}`;
    await mkdir(directory, { recursive: true, mode: 0o700 });
    try {
      await writeFile(temporaryPath, `${JSON.stringify(data, null, 2)}\n`, {
        encoding: "utf8",
        mode: 0o600,
      });
      await rename(temporaryPath, this.filePath);
      await chmod(this.filePath, 0o600).catch(() => {});
      this.configured = true;
    } finally {
      await rm(temporaryPath, { force: true }).catch(() => {});
    }
  }

  private replaceEnabledConversations(
    next: ReadonlyMap<string, AutoApprovalConversationIdentity>,
  ): void {
    this.enabledConversations.clear();
    for (const [key, value] of next) {
      this.enabledConversations.set(key, value);
    }
  }

  private replaceQuarantinedLegacyThreadIds(next: ReadonlySet<string>): void {
    this.quarantinedLegacyThreadIds.clear();
    for (const value of next) {
      this.quarantinedLegacyThreadIds.add(value);
    }
  }
}

export interface AutoApprovalFeatureOptions {
  store?: AutoApprovalStore;
  topology?: "shared" | "private_legacy";
}

interface AutoApprovalTarget {
  threadId: string;
  sessionId?: string;
  session?: LocalFeatureSession;
}

interface AutoApprovalSupervisionProjection {
  supervisionAvailable: boolean;
  supervisionMode: "action_broker" | "private_legacy";
  unavailableReason?: "external_app_server" | "unsupported_session";
  supervisionUnavailableReason?:
    | "external_app_server"
    | "writer_lease_unavailable"
    | "action_broker_unavailable";
}

export class AutoApprovalFeatureHandler implements LocalFeatureHandler {
  readonly messageTypes = [
    "get_auto_approval_state",
    "set_auto_approval",
    "disable_all_auto_approvals",
    "import_legacy_auto_approvals",
  ] as const;

  private readonly store: AutoApprovalStore;
  private readonly topology: "shared" | "private_legacy";
  private readonly capableClients = new Set<object>();
  private readonly handledRequests = new WeakMap<CodexProcess, Set<string>>();
  private readonly handledBrokerRequests = new Set<string>();
  private readonly approvedCounts = new Map<string, number>();
  private readonly correlationSessionIds = new Map<string, string>();
  private readonly unsubscribeBroker?: () => void;
  private sharedAuthorityGeneration?: string;
  private sharedAuthorityRefresh?: Promise<boolean>;
  private closed = false;

  constructor(
    private readonly runtime: LocalFeatureRuntime,
    options: AutoApprovalFeatureOptions = {},
  ) {
    this.store = options.store ?? new AutoApprovalStore();
    this.topology = options.topology ?? "private_legacy";
    if (this.topology === "shared") {
      this.unsubscribeBroker = runtime.codexActionBroker?.subscribe((update) =>
        this.handleBrokerUpdate(update),
      );
      queueMicrotask(() => {
        void this.activateSharedAuthorityAndReconcile().catch((error) => {
          console.warn(
            `[auto-approval] Failed to reconcile Action Broker requests: ${errorMessage(error)}`,
          );
        });
      });
    }
  }

  async handle(
    message: AutoApprovalClientMessage,
    context: LocalFeatureHandleContext,
  ): Promise<void> {
    if (!this.supportsClient(context.client)) {
      context.runtime.send(context.client, {
        type: "error",
        errorCode: "unsupported_capability",
        message: "Bridge-owned auto approval was not negotiated",
      });
      return;
    }

    const codexSourceId = validCodexSourceId(this.runtime.codexSourceId);
    if (!codexSourceId) {
      await this.sendFailure(
        message,
        context,
        new Error("Auto approval requires an authenticated Codex source"),
        "codex_source_unavailable",
        "unsupported_session",
      );
      return;
    }
    if (
      message.codexSourceId !== undefined &&
      message.codexSourceId !== codexSourceId
    ) {
      await this.sendFailure(
        message,
        context,
        new Error("Auto approval target does not match this Codex source"),
        "codex_source_mismatch",
        "unsupported_session",
      );
      return;
    }

    const sharedAuthorityReady = await this.ensureSharedAuthorityReady();
    if (
      this.topology === "shared" &&
      message.type !== "get_auto_approval_state" &&
      !sharedAuthorityReady
    ) {
      await this.sendFailure(
        message,
        context,
        new Error(
          "Auto approval can only be changed by the active shared-runtime Bridge.",
        ),
        "writer_lease_unavailable",
        "unsupported_session",
      );
      return;
    }

    if (message.type === "disable_all_auto_approvals") {
      try {
        await this.store.disableAll(codexSourceId);
        const state = await this.buildState(
          {
            requestId: message.requestId,
            sessionId: message.sessionId,
            reason: "disabled_all",
          },
          codexSourceId,
        );
        this.sendState(context.client, state);
        await this.broadcastState(
          { sessionId: message.sessionId, reason: "disabled_all" },
          codexSourceId,
          context.client,
        );
      } catch (error) {
        await this.sendFailure(message, context, error);
      }
      return;
    }

    if (message.type === "import_legacy_auto_approvals") {
      try {
        await this.store.importLegacy(
          codexSourceId,
          message.providerSessionIds,
        );
        const state = await this.buildState(
          {
            requestId: message.requestId,
            sessionId: message.sessionId,
            reason: "legacy_imported",
          },
          codexSourceId,
        );
        this.sendState(context.client, state);
        await this.broadcastState(
          { sessionId: message.sessionId, reason: "legacy_imported" },
          codexSourceId,
          context.client,
        );
      } catch (error) {
        await this.sendFailure(message, context, error);
      }
      return;
    }

    const targetResolution = this.resolveTarget(message);
    if (!targetResolution.target) {
      await this.sendFailure(
        message,
        context,
        new Error("Auto approval requires an exact Codex conversation"),
        "unsupported_session",
        targetResolution.unavailableReason,
      );
      return;
    }
    const target = targetResolution.target;
    if (target.sessionId) {
      this.correlationSessionIds.set(
        autoApprovalIdentityKey({ codexSourceId, threadId: target.threadId }),
        target.sessionId,
      );
    }
    const supervision = this.supervisionForTarget(target);
    if (
      this.topology === "private_legacy" &&
      supervision.unavailableReason === "external_app_server"
    ) {
      await this.sendFailure(
        message,
        context,
        new Error(
          "This conversation is owned by an independent Codex app-server; this private Bridge cannot observe or answer its approval requests",
        ),
        "external_app_server_approval_unsupported",
        "external_app_server",
      );
      return;
    }

    try {
      if (message.type === "set_auto_approval") {
        await this.store.setEnabled(
          codexSourceId,
          target.threadId,
          message.enabled,
        );
      }
      const state = await this.buildState(
        {
          requestId: message.requestId,
          ...(target.sessionId ? { sessionId: target.sessionId } : {}),
          providerSessionId: target.threadId,
          reason: message.type === "set_auto_approval" ? "updated" : "query",
        },
        codexSourceId,
        target,
      );
      this.sendState(context.client, state);
      if (message.type === "set_auto_approval") {
        await this.broadcastState(
          {
            ...(target.sessionId ? { sessionId: target.sessionId } : {}),
            providerSessionId: target.threadId,
            reason: "updated",
          },
          codexSourceId,
          context.client,
          target,
        );
        if (message.enabled) {
          void this.reconcileBrokerRequests().catch((error) => {
            console.warn(
              `[auto-approval] Failed to reconcile Action Broker requests: ${errorMessage(error)}`,
            );
          });
        }
      }
    } catch (error) {
      await this.sendFailure(message, context, error);
    }
  }

  sessionMessage(session: LocalFeatureSession, message: ServerMessage): void {
    if (
      this.closed ||
      this.topology !== "private_legacy" ||
      session.provider !== "codex" ||
      !(session.process instanceof CodexProcess)
    ) {
      return;
    }
    if (message.type === "permission_resolved") {
      this.handledRequests.get(session.process)?.delete(message.toolUseId);
      return;
    }
    if (
      message.type !== "permission_request" ||
      !isAutoApprovablePermission(message)
    ) {
      return;
    }
    const threadId = this.runtime.getCodexThreadId(session);
    const codexSourceId = validCodexSourceId(this.runtime.codexSourceId);
    if (!threadId || !codexSourceId) return;
    const handled = this.handledRequests.get(session.process) ?? new Set();
    if (handled.has(message.toolUseId)) return;
    handled.add(message.toolUseId);
    this.handledRequests.set(session.process, handled);
    queueMicrotask(() => {
      void this.autoApprove(session, codexSourceId, threadId, message).catch(
        (error) => {
          handled.delete(message.toolUseId);
          console.warn(
            `[auto-approval] Failed to supervise ${message.toolUseId}: ${errorMessage(error)}`,
          );
        },
      );
    });
  }

  capabilitiesChanged(client: object): void {
    if (this.supportsClient(client)) this.capableClients.add(client);
    else this.capableClients.delete(client);
  }

  disconnect(client: object): void {
    this.capableClients.delete(client);
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    this.unsubscribeBroker?.();
    this.capableClients.clear();
    this.correlationSessionIds.clear();
  }

  private handleBrokerUpdate(update: CodexActionBrokerRuntimeUpdate): void {
    if (this.closed || this.topology !== "shared") return;
    if (update.kind === "health") {
      if (update.health.ready && update.health.writerLeaseHeld) {
        void this.activateSharedAuthorityAndReconcile().catch((error) => {
          console.warn(
            `[auto-approval] Failed to reconcile Action Broker requests: ${errorMessage(error)}`,
          );
        });
      } else {
        this.sharedAuthorityGeneration = undefined;
      }
      return;
    }
    if (
      update.request.state === "resolved" ||
      update.request.state === "expired"
    ) {
      this.handledBrokerRequests.delete(
        autoApprovalBrokerRequestKey(update.request),
      );
      return;
    }
    this.queueBrokerRequest(update.request);
  }

  private async activateSharedAuthorityAndReconcile(): Promise<void> {
    if (!(await this.ensureSharedAuthorityReady())) return;
    await this.reconcileBrokerRequests();
  }

  private async ensureSharedAuthorityReady(): Promise<boolean> {
    if (this.topology !== "shared") return true;
    for (;;) {
      if (this.closed) return false;
      const broker = this.runtime.codexActionBroker;
      const health = broker?.health;
      const generation = health?.authorityGeneration;
      if (
        !broker ||
        health?.ready !== true ||
        health.writerLeaseHeld !== true ||
        !generation
      ) {
        this.sharedAuthorityGeneration = undefined;
        return false;
      }
      if (this.sharedAuthorityGeneration === generation) return true;
      const existing = this.sharedAuthorityRefresh;
      if (existing) {
        await existing;
        continue;
      }
      const refresh = this.store.reloadFromDisk().then(() => {
        const current = broker.health;
        if (
          this.closed ||
          current.ready !== true ||
          current.writerLeaseHeld !== true ||
          current.authorityGeneration !== generation
        ) {
          return false;
        }
        this.sharedAuthorityGeneration = generation;
        return true;
      });
      this.sharedAuthorityRefresh = refresh;
      try {
        return await refresh;
      } finally {
        if (this.sharedAuthorityRefresh === refresh) {
          this.sharedAuthorityRefresh = undefined;
        }
      }
    }
  }

  private async reconcileBrokerRequests(): Promise<void> {
    if (this.closed || this.topology !== "shared") return;
    const broker = this.runtime.codexActionBroker;
    const codexSourceId = validCodexSourceId(this.runtime.codexSourceId);
    if (
      !broker ||
      !codexSourceId ||
      !(await this.ensureSharedAuthorityReady()) ||
      !broker.health.ready ||
      !broker.health.writerLeaseHeld
    ) {
      return;
    }
    for (const request of broker.listRequests({
      codexSourceId,
      limit: 64,
    })) {
      this.queueBrokerRequest(request);
    }
  }

  private queueBrokerRequest(request: CodexActionBrokerRuntimeRequest): void {
    if (
      this.closed ||
      this.topology !== "shared" ||
      !isAutoApprovableBrokerRequest(request)
    ) {
      return;
    }
    const requestKey = autoApprovalBrokerRequestKey(request);
    if (this.handledBrokerRequests.has(requestKey)) return;
    // Do not evict an exact request fence and accidentally replay an uncertain
    // or contended operation. At the safety cap, new requests remain manual.
    if (this.handledBrokerRequests.size >= MAX_HANDLED_BROKER_REQUESTS) return;
    this.handledBrokerRequests.add(requestKey);
    queueMicrotask(() => {
      void this.autoApproveBrokerRequest(request, requestKey).catch((error) => {
        console.warn(
          `[auto-approval] Failed to supervise broker request ${request.opaqueRequestId}: ${errorMessage(error)}`,
        );
      });
    });
  }

  private async autoApproveBrokerRequest(
    observed: CodexActionBrokerRuntimeRequest,
    requestKey: string,
  ): Promise<void> {
    const broker = this.runtime.codexActionBroker;
    const codexSourceId = validCodexSourceId(this.runtime.codexSourceId);
    if (
      this.closed ||
      !broker ||
      !codexSourceId ||
      observed.codexSourceId !== codexSourceId
    ) {
      return;
    }
    if (!(await this.ensureSharedAuthorityReady())) {
      this.handledBrokerRequests.delete(requestKey);
      return;
    }
    if (!(await this.store.isActive(codexSourceId, observed.threadId))) {
      this.handledBrokerRequests.delete(requestKey);
      return;
    }
    if (!broker.health.ready || !broker.health.writerLeaseHeld) {
      this.handledBrokerRequests.delete(requestKey);
      return;
    }
    const current = broker
      .listRequests({
        codexSourceId,
        threadId: observed.threadId,
        limit: 64,
      })
      .find((request) => request.opaqueRequestId === observed.opaqueRequestId);
    if (
      !current ||
      !sameBrokerRequestFence(current, observed) ||
      !isAutoApprovableBrokerRequest(current)
    ) {
      return;
    }
    if (!(await this.store.isActive(codexSourceId, observed.threadId))) {
      this.handledBrokerRequests.delete(requestKey);
      return;
    }
    if (!broker.health.ready || !broker.health.writerLeaseHeld) {
      this.handledBrokerRequests.delete(requestKey);
      return;
    }

    const result = await broker.respond({
      opaqueRequestId: current.opaqueRequestId,
      codexSourceId: current.codexSourceId,
      threadId: current.threadId,
      turnId: current.turnId,
      authorityGeneration: current.authorityGeneration,
      claimantId: autoApprovalBrokerClaimantId(
        this.runtime.bridgeInstanceId,
        codexSourceId,
      ),
      operationId: autoApprovalBrokerOperationId(current),
      action: "approve",
    });
    if (result.outcome === "unavailable") {
      // No write occurred on the retryable unavailable path. A later broker
      // ready transition will rescan the durable pending set.
      this.handledBrokerRequests.delete(requestKey);
      return;
    }
    if (result.outcome !== "submitted") {
      // alreadyResolved, contended and outcomeUnknown are deliberately
      // terminal for this exact request attempt. The exact fence also makes
      // staleGeneration/invalid/expired unsafe to replay.
      return;
    }
    const identityKey = autoApprovalIdentityKey({
      codexSourceId,
      threadId: current.threadId,
    });
    this.approvedCounts.set(
      identityKey,
      (this.approvedCounts.get(identityKey) ?? 0) + 1,
    );
    const sessionId = this.correlationSessionId(
      codexSourceId,
      current.threadId,
    );
    // Existing Mobile decoders require a real sessionId. When a detached
    // Desktop thread has no unique runtime correlation, supervision remains
    // active but no malformed broadcast is manufactured.
    if (!sessionId) return;
    await this.broadcastState(
      {
        sessionId,
        providerSessionId: current.threadId,
        reason: "auto_approved",
      },
      codexSourceId,
      undefined,
      { threadId: current.threadId },
    );
  }

  private correlationSessionId(
    codexSourceId: string,
    threadId: string,
  ): string | undefined {
    const identityKey = autoApprovalIdentityKey({ codexSourceId, threadId });
    const remembered = this.correlationSessionIds.get(identityKey);
    if (remembered) return remembered;
    const matches =
      this.runtime
        .listRuntimeConversationStates?.()
        .filter(
          (state) =>
            state.provider === "codex" && state.providerSessionId === threadId,
        ) ?? [];
    return matches.length === 1 ? matches[0].bridgeSessionId : undefined;
  }

  private async autoApprove(
    session: LocalFeatureSession,
    codexSourceId: string,
    threadId: string,
    message: Extract<ServerMessage, { type: "permission_request" }>,
  ): Promise<void> {
    const originalProcess = session.process as CodexProcess;
    try {
      if (!(await this.store.isActive(codexSourceId, threadId))) return;
      const current = this.runtime.getSession(session.id);
      if (
        current !== session ||
        current.process !== originalProcess ||
        this.runtime.codexSourceId !== codexSourceId ||
        this.runtime.getCodexThreadId(current) !== threadId ||
        !(current.process instanceof CodexProcess)
      ) {
        return;
      }
      const pending = current.process.getPendingPermission(message.toolUseId);
      if (
        !pending ||
        pending.toolName !== message.toolName ||
        !isAutoApprovablePermission({
          type: "permission_request",
          toolUseId: pending.toolUseId,
          toolName: pending.toolName,
          input: pending.input,
        }) ||
        !(await this.store.isActive(codexSourceId, threadId))
      ) {
        return;
      }

      current.process.approve(message.toolUseId);
      if (current.process.getPendingPermission(message.toolUseId)) return;
      const identityKey = autoApprovalIdentityKey({
        codexSourceId,
        threadId,
      });
      this.approvedCounts.set(
        identityKey,
        (this.approvedCounts.get(identityKey) ?? 0) + 1,
      );
      await this.broadcastState(
        {
          sessionId: session.id,
          providerSessionId: threadId,
          reason: "auto_approved",
        },
        codexSourceId,
        undefined,
        { sessionId: session.id, session, threadId },
      );
    } finally {
      this.handledRequests.get(originalProcess)?.delete(message.toolUseId);
    }
  }

  private resolveTarget(message: AutoApprovalClientMessage): {
    target: AutoApprovalTarget | null;
    unavailableReason?: "unsupported_session";
  } {
    const providerSessionId =
      "providerSessionId" in message ? message.providerSessionId : undefined;
    if (providerSessionId) {
      const session = message.sessionId
        ? this.runtime.getSession(message.sessionId)
        : undefined;
      const matchingSession =
        session?.provider === "codex" &&
        this.runtime.getCodexThreadId(session) === providerSessionId
          ? session
          : undefined;
      return {
        target: {
          threadId: providerSessionId,
          ...(message.sessionId ? { sessionId: message.sessionId } : {}),
          ...(matchingSession ? { session: matchingSession } : {}),
        },
      };
    }
    const sessionId = message.sessionId;
    if (!sessionId) {
      return { target: null, unavailableReason: "unsupported_session" };
    }
    const session = this.runtime.getSession(sessionId);
    if (!session || session.provider !== "codex") {
      return { target: null, unavailableReason: "unsupported_session" };
    }
    const threadId = this.runtime.getCodexThreadId(session);
    return threadId
      ? { target: { sessionId, session, threadId } }
      : { target: null, unavailableReason: "unsupported_session" };
  }

  private supervisionForTarget(
    target?: AutoApprovalTarget,
  ): AutoApprovalSupervisionProjection {
    if (this.topology === "shared") {
      const broker = this.runtime.codexActionBroker;
      if (!broker) {
        return {
          supervisionAvailable: false,
          supervisionMode: "action_broker",
          unavailableReason: "unsupported_session",
          supervisionUnavailableReason: "action_broker_unavailable",
        };
      }
      if (!broker.health.writerLeaseHeld) {
        return {
          supervisionAvailable: false,
          supervisionMode: "action_broker",
          unavailableReason: "unsupported_session",
          supervisionUnavailableReason: "writer_lease_unavailable",
        };
      }
      if (!broker.health.ready) {
        return {
          supervisionAvailable: false,
          supervisionMode: "action_broker",
          unavailableReason: "unsupported_session",
          supervisionUnavailableReason: "action_broker_unavailable",
        };
      }
      if (
        !broker.health.authorityGeneration ||
        this.sharedAuthorityGeneration !== broker.health.authorityGeneration
      ) {
        return {
          supervisionAvailable: false,
          supervisionMode: "action_broker",
          unavailableReason: "unsupported_session",
          supervisionUnavailableReason: "action_broker_unavailable",
        };
      }
      return {
        supervisionAvailable: true,
        supervisionMode: "action_broker",
      };
    }
    if (target && !(target.session?.process instanceof CodexProcess)) {
      return {
        supervisionAvailable: false,
        supervisionMode: "private_legacy",
        unavailableReason: "external_app_server",
        supervisionUnavailableReason: "external_app_server",
      };
    }
    return {
      supervisionAvailable: true,
      supervisionMode: "private_legacy",
    };
  }

  private supportsClient(client: object): boolean {
    return (
      this.runtime.supports?.(client, AUTO_APPROVAL_STATE_CAPABILITY) ?? false
    );
  }

  private supportsSupervisionState(client: object): boolean {
    return (
      this.runtime.supports?.(client, AUTO_APPROVAL_SUPERVISION_CAPABILITY) ??
      false
    );
  }

  private sendState(client: object, state: AutoApprovalStateMessage): void {
    if (this.supportsSupervisionState(client)) {
      this.runtime.send(client, state);
      return;
    }
    const {
      supervisionAvailable: _supervisionAvailable,
      supervisionMode: _supervisionMode,
      unavailableReason: _unavailableReason,
      supervisionUnavailableReason: _supervisionUnavailableReason,
      codexSourceId: _codexSourceId,
      ...legacyState
    } = state;
    this.runtime.send(client, legacyState);
  }

  private async buildState(
    fields: Pick<AutoApprovalStateMessage, "reason"> &
      Partial<
        Pick<
          AutoApprovalStateMessage,
          "requestId" | "sessionId" | "providerSessionId"
        >
      >,
    codexSourceId: string,
    target?: AutoApprovalTarget,
  ): Promise<AutoApprovalStateMessage> {
    const visible = await this.store.visibleState(
      codexSourceId,
      fields.providerSessionId,
    );
    const identityKey = fields.providerSessionId
      ? autoApprovalIdentityKey({
          codexSourceId,
          threadId: fields.providerSessionId,
        })
      : undefined;
    return {
      type: AUTO_APPROVAL_STATE_CAPABILITY,
      ...fields,
      codexSourceId,
      ...visible,
      ...this.supervisionForTarget(target),
      ...(identityKey
        ? { approvedCount: this.approvedCounts.get(identityKey) ?? 0 }
        : {}),
    };
  }

  private async broadcastState(
    fields: Pick<AutoApprovalStateMessage, "reason"> &
      Partial<
        Pick<AutoApprovalStateMessage, "sessionId" | "providerSessionId">
      >,
    codexSourceId: string,
    excludedClient?: object,
    target?: AutoApprovalTarget,
  ): Promise<void> {
    const state = await this.buildState(fields, codexSourceId, target);
    for (const client of this.capableClients) {
      if (
        client === excludedClient ||
        this.runtime.isClientOpen?.(client) === false
      ) {
        continue;
      }
      this.sendState(client, state);
    }
  }

  private async sendFailure(
    message: AutoApprovalClientMessage,
    context: LocalFeatureHandleContext,
    error: unknown,
    errorCode = "state_update_failed",
    unavailableReason?: AutoApprovalStateMessage["unavailableReason"],
  ): Promise<void> {
    const codexSourceId = validCodexSourceId(this.runtime.codexSourceId);
    const visible = codexSourceId
      ? await this.store.visibleState(codexSourceId)
      : { enabledConversationCount: 0 };
    const supervision = unavailableReason
      ? {
          supervisionAvailable: false,
          supervisionMode:
            this.topology === "shared"
              ? ("action_broker" as const)
              : ("private_legacy" as const),
          unavailableReason,
          supervisionUnavailableReason: unavailableReason,
        }
      : this.supervisionForTarget();
    this.sendState(context.client, {
      type: AUTO_APPROVAL_STATE_CAPABILITY,
      requestId: message.requestId,
      ...(message.sessionId ? { sessionId: message.sessionId } : {}),
      ...(codexSourceId ? { codexSourceId } : {}),
      ...("providerSessionId" in message && message.providerSessionId
        ? { providerSessionId: message.providerSessionId }
        : {}),
      enabledConversationCount: visible.enabledConversationCount,
      ...supervision,
      reason:
        message.type === "disable_all_auto_approvals"
          ? "disabled_all"
          : message.type === "import_legacy_auto_approvals"
            ? "legacy_imported"
            : message.type === "set_auto_approval"
              ? "updated"
              : "query",
      errorCode,
      error: errorMessage(error),
    });
  }
}

export function isAutoApprovablePermission(
  message: Extract<ServerMessage, { type: "permission_request" }>,
): boolean {
  return isAutoApprovableToolInput(message.toolName, message.input, true);
}

export function isAutoApprovableBrokerRequest(
  request: CodexActionBrokerRuntimeRequest,
): boolean {
  if (
    request.state !== "pending" ||
    !request.live ||
    !request.input ||
    !request.allowedActions?.includes("approve")
  ) {
    return false;
  }
  switch (request.kind) {
    case "command_approval":
      return (
        request.toolName === "Bash" &&
        isAutoApprovableToolInput(request.toolName, request.input, false)
      );
    case "file_approval":
      return request.toolName === "FileChange";
    case "permissions_approval":
      return request.toolName === "Permissions";
    case "mcp_elicitation":
      return (
        request.toolName === "McpElicitation" &&
        isCanonicalMcpApproval(request.input)
      );
    default:
      return false;
  }
}

function isAutoApprovableToolInput(
  toolName: string,
  input: Record<string, unknown>,
  allowLegacyPlanCompletion: boolean,
): boolean {
  switch (toolName) {
    case "Bash": {
      const command = input.command;
      if (typeof command === "string" && command.trim()) {
        return !shellCommandRequiresManualApproval(command);
      }
      return (
        input.networkApprovalContext != null ||
        input.proposedNetworkPolicyAmendments != null
      );
    }
    case "FileChange":
    case "Permissions":
      return true;
    case "ExitPlanMode":
      return allowLegacyPlanCompletion;
    case "McpElicitation":
      return isCanonicalMcpApproval(input);
    default:
      return false;
  }
}

function sameBrokerRequestFence(
  current: CodexActionBrokerRuntimeRequest,
  observed: CodexActionBrokerRuntimeRequest,
): boolean {
  return (
    current.opaqueRequestId === observed.opaqueRequestId &&
    current.codexSourceId === observed.codexSourceId &&
    current.threadId === observed.threadId &&
    current.turnId === observed.turnId &&
    current.authorityGeneration === observed.authorityGeneration &&
    current.kind === observed.kind
  );
}

function autoApprovalBrokerRequestKey(
  request: CodexActionBrokerRuntimeRequest,
): string {
  return JSON.stringify([
    request.codexSourceId,
    request.threadId,
    request.turnId,
    request.opaqueRequestId,
    request.authorityGeneration,
  ]);
}

function autoApprovalBrokerClaimantId(
  bridgeInstanceId: string | undefined,
  codexSourceId: string,
): string {
  return `bridge-auto-approval-v1:${stableAutoApprovalHash([
    bridgeInstanceId ?? `source:${codexSourceId}`,
  ])}`;
}

function autoApprovalBrokerOperationId(
  request: CodexActionBrokerRuntimeRequest,
): string {
  return `auto-approve-v1:${stableAutoApprovalHash([
    request.codexSourceId,
    request.threadId,
    request.turnId,
    request.opaqueRequestId,
    request.authorityGeneration,
    "approve",
  ])}`;
}

function stableAutoApprovalHash(parts: readonly string[]): string {
  return createHash("sha256").update(JSON.stringify(parts)).digest("hex");
}

export function shellCommandRequiresManualApproval(command: string): boolean {
  const parsed = tokenizeShellCommand(command);
  if (!parsed || parsed.ambiguous) return true;
  return parsed.segments.some((segment) =>
    segmentRequiresManualApproval(segment),
  );
}

interface ParsedShellCommand {
  segments: string[][];
  ambiguous: boolean;
}

function tokenizeShellCommand(command: string): ParsedShellCommand | null {
  const segments: string[][] = [];
  let segment: string[] = [];
  let word = "";
  let started = false;
  let quote: "single" | "double" | null = null;
  let ambiguous = false;

  const pushWord = (): void => {
    if (!started) return;
    segment.push(word);
    word = "";
    started = false;
  };
  const pushSegment = (): void => {
    pushWord();
    if (segment.length > 0) segments.push(segment);
    segment = [];
  };

  for (let index = 0; index < command.length; index += 1) {
    const character = command[index];
    const next = command[index + 1];
    if (quote === "single") {
      if (character === "'") quote = null;
      else word += character;
      started = true;
      continue;
    }
    if (quote === "double") {
      if (character === '"') {
        quote = null;
      } else if (character === "\\" && next !== undefined) {
        word += next;
        index += 1;
      } else {
        if (character === "`" || (character === "$" && next === "(")) {
          ambiguous = true;
        }
        word += character;
      }
      started = true;
      continue;
    }

    if (character === "'") {
      quote = "single";
      started = true;
    } else if (character === '"') {
      quote = "double";
      started = true;
    } else if (character === "\\" && next !== undefined) {
      word += next;
      started = true;
      index += 1;
    } else if (character === "`" || (character === "$" && next === "(")) {
      ambiguous = true;
      word += character;
      started = true;
    } else if (character === "\n" || character === "\r") {
      pushSegment();
    } else if (/\s/.test(character)) {
      pushWord();
    } else if (";|&(){}".includes(character)) {
      pushSegment();
      if ((character === "&" || character === "|") && next === character) {
        index += 1;
      }
    } else if (character === ">" || character === "<") {
      if (/^\d+$/.test(word)) {
        word = "";
        started = false;
      } else {
        pushWord();
      }
      segment.push("__ccpocket_redirection__");
      if (next === character) {
        if (character === "<") ambiguous = true;
        index += 1;
      }
      if (command[index + 1] === "&") {
        index += 1;
        while (/[-0-9]/.test(command[index + 1] ?? "")) index += 1;
      }
    } else {
      word += character;
      started = true;
    }
  }
  if (quote !== null) return null;
  pushSegment();
  return { segments, ambiguous };
}

function segmentRequiresManualApproval(rawWords: string[]): boolean {
  const words: string[] = [];
  for (let index = 0; index < rawWords.length; index += 1) {
    if (rawWords[index] === "__ccpocket_redirection__") {
      index += 1;
      continue;
    }
    words.push(rawWords[index]);
  }
  let index = 0;
  while (index < words.length && isShellAssignment(words[index])) index += 1;
  index = unwrapCommandPrefix(words, index);
  if (index < 0 || index >= words.length) return true;

  const executable = commandBasename(words[index]);
  if (!executable || executable.includes("$") || executable.includes("`")) {
    return true;
  }
  if (
    DESTRUCTIVE_EXECUTABLES.has(executable) ||
    executable.startsWith("mkfs")
  ) {
    return true;
  }
  const argumentsAfter = words.slice(index + 1);
  if (executable === "git") return dangerousGitArguments(argumentsAfter);
  if (executable === "find") {
    if (argumentsAfter.includes("-delete")) return true;
    const execIndex = argumentsAfter.findIndex(
      (value) => value === "-exec" || value === "-execdir",
    );
    if (execIndex >= 0) {
      const endIndex = argumentsAfter.findIndex(
        (value, candidateIndex) =>
          candidateIndex > execIndex && (value === ";" || value === "+"),
      );
      const nested = argumentsAfter.slice(
        execIndex + 1,
        endIndex < 0 ? undefined : endIndex,
      );
      return nested.length === 0 || segmentRequiresManualApproval(nested);
    }
    return false;
  }
  if (executable === "xargs") {
    const commandIndex = skipWrapperOptions(
      argumentsAfter,
      0,
      new Set([
        "-E",
        "--eof",
        "-I",
        "--replace",
        "-L",
        "--max-lines",
        "-n",
        "--max-args",
        "-P",
        "--max-procs",
        "-s",
        "--max-chars",
        "-d",
        "--delimiter",
      ]),
    );
    return commandIndex < 0
      ? false
      : segmentRequiresManualApproval(argumentsAfter.slice(commandIndex));
  }
  if (executable === "busybox" || executable === "toybox") {
    return (
      argumentsAfter.length === 0 ||
      segmentRequiresManualApproval(argumentsAfter)
    );
  }
  if (SHELL_EXECUTABLES.has(executable)) {
    const commandIndex = shellCommandArgumentIndex(argumentsAfter);
    return commandIndex < 0
      ? true
      : shellCommandRequiresManualApproval(argumentsAfter[commandIndex]);
  }
  return executable === "eval" || executable === "source" || executable === ".";
}

const DESTRUCTIVE_EXECUTABLES = new Set([
  "rm",
  "rmdir",
  "unlink",
  "shred",
  "srm",
  "dd",
  "diskutil",
]);

const SHELL_EXECUTABLES = new Set(["sh", "bash", "zsh", "dash", "ksh", "fish"]);

function unwrapCommandPrefix(words: string[], start: number): number {
  let index = start;
  while (index < words.length) {
    const executable = commandBasename(words[index]);
    if (executable === "sudo" || executable === "doas") {
      index = skipWrapperOptions(
        words,
        index + 1,
        new Set([
          "-u",
          "--user",
          "-g",
          "--group",
          "-h",
          "--host",
          "-p",
          "--prompt",
          "-C",
          "--close-from",
          "-R",
          "--chroot",
          "-D",
          "--chdir",
        ]),
      );
    } else if (executable === "env") {
      index = skipWrapperOptions(
        words,
        index + 1,
        new Set(["-u", "--unset", "-C", "--chdir", "-S", "--split-string"]),
      );
      while (
        index >= 0 &&
        index < words.length &&
        isShellAssignment(words[index])
      ) {
        index += 1;
      }
    } else if (["command", "builtin", "nohup"].includes(executable)) {
      index = skipWrapperOptions(words, index + 1, new Set());
    } else if (executable === "nice") {
      index = skipWrapperOptions(
        words,
        index + 1,
        new Set(["-n", "--adjustment"]),
      );
    } else if (executable === "time") {
      index = skipWrapperOptions(words, index + 1, new Set(["-f", "-o"]));
    } else {
      return index;
    }
    if (index < 0) return -1;
  }
  return index;
}

function skipWrapperOptions(
  words: string[],
  start: number,
  optionsWithValues: Set<string>,
): number {
  let index = start;
  while (index < words.length) {
    const value = words[index];
    if (value === "--") return index + 1;
    if (!value.startsWith("-") || value === "-") return index;
    const option = value.includes("=")
      ? value.slice(0, value.indexOf("="))
      : value;
    if (optionsWithValues.has(option) && !value.includes("=")) {
      index += 2;
    } else {
      index += 1;
    }
  }
  return -1;
}

function dangerousGitArguments(args: string[]): boolean {
  let index = 0;
  while (index < args.length) {
    const value = args[index];
    if (
      value === "-C" ||
      value === "-c" ||
      value === "--git-dir" ||
      value === "--work-tree"
    ) {
      index += 2;
      continue;
    }
    if (value.startsWith("-")) {
      index += 1;
      continue;
    }
    return (
      ["clean", "restore", "checkout"].includes(value) ||
      (value === "reset" && args.slice(index + 1).includes("--hard"))
    );
  }
  return false;
}

function shellCommandArgumentIndex(args: string[]): number {
  for (let index = 0; index < args.length; index += 1) {
    const value = args[index];
    if (value === "-c") return index + 1 < args.length ? index + 1 : -1;
    if (/^-[^-]*c[^-]*$/.test(value)) {
      return index + 1 < args.length ? index + 1 : -1;
    }
    if (!value.startsWith("-")) return -1;
  }
  return -1;
}

function isShellAssignment(value: string): boolean {
  return /^[A-Za-z_][A-Za-z0-9_]*=/.test(value);
}

function commandBasename(value: string): string {
  return value.replace(/\\/g, "/").split("/").pop()?.toLowerCase() ?? "";
}

function isCanonicalMcpApproval(input: Record<string, unknown>): boolean {
  const decisions = input.availableDecisions;
  return (
    input.mode === "form" &&
    Array.isArray(decisions) &&
    decisions.includes("accept") &&
    !("requestedSchema" in input) &&
    !("url" in input) &&
    !("appsNeedingAuth" in input)
  );
}

function autoApprovalIdentityKey(
  identity: AutoApprovalConversationIdentity,
): string {
  return JSON.stringify([identity.codexSourceId, identity.threadId]);
}

function compareAutoApprovalIdentities(
  left: AutoApprovalConversationIdentity,
  right: AutoApprovalConversationIdentity,
): number {
  return (
    left.codexSourceId.localeCompare(right.codexSourceId) ||
    left.threadId.localeCompare(right.threadId)
  );
}

function validCodexSourceId(value: unknown): string | undefined {
  if (
    typeof value !== "string" ||
    value.trim().length === 0 ||
    value.trim() !== value ||
    value.length > MAX_CODEX_SOURCE_ID_LENGTH
  ) {
    return undefined;
  }
  return value;
}

function requireCodexSourceId(value: unknown): asserts value is string {
  if (!validCodexSourceId(value)) {
    throw new Error("Invalid Codex source ID in auto-approval state");
  }
}

function requireThreadId(value: unknown): asserts value is string {
  if (
    typeof value !== "string" ||
    value.trim().length === 0 ||
    value.length > MAX_THREAD_ID_LENGTH
  ) {
    throw new Error("Invalid Codex thread ID in auto-approval state");
  }
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function defaultAutoApprovalStatePath(): string {
  const override = process.env.CCPOCKET_AUTO_APPROVAL_STATE_FILE?.trim();
  if (override) return override;
  if (process.env.NODE_ENV === "test") {
    return join(
      tmpdir(),
      `ccpocket-auto-approval-${process.pid}-${randomUUID()}.json`,
    );
  }
  // Keep the historical filename so existing installs are migrated in place.
  return join(homedir(), ".ccpocket", "auto-approval-v1.json");
}
