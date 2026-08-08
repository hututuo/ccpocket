import { mkdtemp, rm } from "node:fs/promises";
import { EventEmitter } from "node:events";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { describe, expect, it, vi } from "vitest";

import type { CodexProcess, CodexThreadSummary } from "../codex-process.js";
import type { SharedCodexContentObserverProcess } from "../codex-shared-runtime-content-observer.js";
import type {
  CodexActionBrokerRuntime,
  CodexActionBrokerRuntimeRequest,
  CodexActionBrokerRuntimeUpdate,
} from "../codex-action-broker-runtime.js";
import type { ServerMessage } from "../parser.js";
import { buildConversationContentSnapshot } from "./conversation-content-sync.js";
import {
  buildConversationSyncCodexCatalogSeed,
  CONVERSATION_SYNC_PRIMARY_CODEX_SOURCE_KINDS,
  ConversationSyncV2FeatureHandler,
} from "./conversation-sync-v2.js";
import {
  APP_SERVER_STATUS_CAPABILITY,
  CONVERSATION_SYNC_V2_CAPABILITY,
  conversationSyncV2ProtocolContribution,
  type ConversationSyncCatalogEntry,
  type ConversationSyncClientMessage,
  type ConversationSyncServerMessage,
  type ConversationSyncStatus,
} from "./slots/conversation-sync-v2-protocol.js";
import type {
  LocalFeatureRuntime,
  LocalFeatureRuntimeConversationState,
  LocalFeatureSharedRuntimeControlUpdate,
  LocalFeatureSession,
} from "./runtime.js";
import { TerminalResultLedger } from "./terminal-result-ledger.js";

class FakeSharedContentObserverProcess extends EventEmitter {
  activeTurnId = "turn-shared-live";
  isRunning = true;
  readonly starts: Array<{
    projectPath: string;
    options: Record<string, unknown>;
  }> = [];
  readonly stop = vi.fn(() => {
    this.isRunning = false;
  });

  start(projectPath: string, options: Record<string, unknown>): void {
    this.starts.push({ projectPath, options });
  }

  waitUntilAttached(): Promise<void> {
    return Promise.resolve();
  }

  asObserver(): SharedCodexContentObserverProcess {
    return this as unknown as SharedCodexContentObserverProcess;
  }

  message(message: ServerMessage): void {
    this.emit("message", message);
  }
}

describe("conversation_sync_v2 protocol", () => {
  it("keeps internal subagent source kinds out of the primary catalog", () => {
    expect(CONVERSATION_SYNC_PRIMARY_CODEX_SOURCE_KINDS).toEqual([
      "cli",
      "vscode",
      "exec",
      "appServer",
    ]);
  });

  it("omits opaque Codex previews and uses rollout-visible metadata", () => {
    const thread: CodexThreadSummary = {
      id: "thread-private-preview",
      sessionId: null,
      parentThreadId: null,
      preview: "private agent message",
      ephemeral: false,
      createdAt: 1,
      updatedAt: 2,
      recencyAt: 2,
      cwd: "/workspace/private-preview",
      modelProvider: null,
      status: { type: "idle" },
      canAcceptDirectInput: null,
      agentNickname: null,
      agentRole: null,
      gitBranch: null,
      name: null,
    };

    expect(
      buildConversationSyncCodexCatalogSeed(thread).entry,
    ).not.toMatchObject({
      firstPrompt: "private agent message",
    });
    expect(
      buildConversationSyncCodexCatalogSeed(thread, {
        firstPrompt: "visible user prompt",
        summary: "visible assistant answer",
      }).entry,
    ).toMatchObject({
      firstPrompt: "visible user prompt",
      summary: "visible assistant answer",
    });
  });

  it("projects durable Codex model settings into the catalog producer", () => {
    const seed = buildConversationSyncCodexCatalogSeed(
      {
        id: "thread-settings",
        sessionId: "thread-settings",
        parentThreadId: null,
        preview: "Preview",
        ephemeral: false,
        createdAt: 1,
        updatedAt: 2,
        recencyAt: 3,
        cwd: "/workspace",
        modelProvider: "openai",
        status: { type: "active", activeFlags: [] },
        canAcceptDirectInput: false,
        agentNickname: null,
        agentRole: null,
        gitBranch: null,
        name: "Settings thread",
      },
      {
        firstPrompt: "Real first prompt",
        codexSettings: {
          model: "gpt-5.6-sol",
          modelReasoningEffort: "ultra",
          serviceTier: "fast",
          approvalPolicy: "on-request",
          approvalsReviewer: "user",
          sandboxMode: "workspace-write",
          collaborationMode: "plan",
          networkAccessEnabled: true,
          webSearchMode: "live",
        },
      },
    );

    expect(seed.entry).toMatchObject({
      providerSessionId: "thread-settings",
      firstPrompt: "Real first prompt",
      model: "gpt-5.6-sol",
      modelReasoningEffort: "ultra",
      serviceTier: "fast",
      approvalPolicy: "on-request",
      approvalsReviewer: "user",
      sandboxMode: "workspace-write",
      collaborationMode: "plan",
      networkAccessEnabled: true,
      webSearchMode: "live",
    });
  });

  it("hydrates the focused Codex thread and prewarms priority settings", async () => {
    const focused = codexSeed(0, "thread-focused-settings");
    Object.assign(focused.entry, {
      model: "stale-model",
      webSearchMode: "live",
      codexSettingsSnapshotComplete: false,
    });
    const background = codexSeed(1, "thread-background-settings");
    const focusedCodexMetadataReader = vi.fn(async (threadId: string) =>
      threadId === focused.entry.providerSessionId
        ? {
            codexSettings: {
              model: "gpt-5.6-sol",
              modelReasoningEffort: "max",
              serviceTier: "standard",
              approvalPolicy: "on-request",
              approvalsReviewer: "auto_review",
              sandboxMode: "workspace-write",
              collaborationMode: "default" as const,
              networkAccessEnabled: false,
            },
          }
        : undefined,
    );
    const fixture = createFixture(
      [focused, background],
      async (target) => history(target.providerSessionId),
      { focusedCodexMetadataReader },
    );
    const client = {};
    const subscription = {
      ...subscribeMessage(),
      focused: {
        provider: "codex" as const,
        providerSessionId: focused.entry.providerSessionId,
      },
    };

    await fixture.handler.handle(
      subscription,
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "sync_complete").length,
      ).toBeGreaterThanOrEqual(1),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "catalog_changes")
          .flatMap((event) => [...event.created, ...event.updated])
          .find(
            (entry) =>
              entry.providerSessionId === focused.entry.providerSessionId &&
              entry.codexSettingsSnapshotComplete === true,
          ),
      ).toBeDefined(),
    );

    const catalogEntries = events(
      fixture.sent,
      client,
      "catalog_changes",
    ).flatMap((event) => [...event.created, ...event.updated]);
    const hydratedEntry = catalogEntries.find(
      (entry) =>
        entry.providerSessionId === focused.entry.providerSessionId &&
        entry.codexSettingsSnapshotComplete === true,
    );
    expect(hydratedEntry).toMatchObject({
      model: "gpt-5.6-sol",
      modelReasoningEffort: "max",
      serviceTier: "standard",
      approvalPolicy: "on-request",
      approvalsReviewer: "auto_review",
      sandboxMode: "workspace-write",
      collaborationMode: "default",
      networkAccessEnabled: false,
      codexSettingsSnapshotComplete: true,
    });
    expect(hydratedEntry).not.toHaveProperty("webSearchMode");
    expect(focusedCodexMetadataReader).toHaveBeenCalledTimes(2);
    expect(focusedCodexMetadataReader).toHaveBeenCalledWith(
      focused.entry.providerSessionId,
    );
    expect(focusedCodexMetadataReader).toHaveBeenCalledWith(
      background.entry.providerSessionId,
    );
    expect(
      catalogEntries.find(
        (entry) =>
          entry.providerSessionId === background.entry.providerSessionId,
      ),
    ).not.toHaveProperty("codexSettingsSnapshotComplete", true);
    fixture.handler.close();
  });

  it("prewarms the five recent Codex settings with bounded concurrency", async () => {
    const seeds = Array.from({ length: 7 }, (_, index) =>
      codexSeed(index, `thread-prewarm-${index}`),
    );
    type SettingsMetadata = {
      codexSettings: {
        model: string;
        modelReasoningEffort: string;
        serviceTier: string;
      };
    };
    const pending = new Map<string, (metadata: SettingsMetadata) => void>();
    let activeReads = 0;
    let maximumActiveReads = 0;
    const focusedCodexMetadataReader = vi.fn(
      (threadId: string) =>
        new Promise<SettingsMetadata>((resolve) => {
          activeReads += 1;
          maximumActiveReads = Math.max(maximumActiveReads, activeReads);
          pending.set(threadId, (metadata) => {
            activeReads -= 1;
            resolve(metadata);
          });
        }),
    );
    const fixture = createFixture(
      seeds,
      async (target) => history(target.providerSessionId),
      { focusedCodexMetadataReader },
    );
    const client = {};
    const subscription = subscribeMessage();

    await fixture.handler.handle(
      subscription,
      context(client, fixture.runtime),
    );

    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );
    expect(focusedCodexMetadataReader).toHaveBeenCalledTimes(3);

    await fixture.handler.handle(
      {
        type: "conversation_sync_focus",
        protocolVersion: 2,
        requestId: "focus-bounded-prewarm",
        subscriptionId: subscription.requestId,
        focused: {
          provider: "codex",
          providerSessionId: "thread-prewarm-4",
        },
      },
      context(client, fixture.runtime),
    );
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(focusedCodexMetadataReader).toHaveBeenCalledTimes(3);

    const firstPending = pending.entries().next().value as
      [string, (metadata: SettingsMetadata) => void] | undefined;
    expect(firstPending).toBeDefined();
    firstPending![1]({
      codexSettings: {
        model: "gpt-5.6-sol",
        modelReasoningEffort: "ultra",
        serviceTier: "standard",
      },
    });
    pending.delete(firstPending![0]);
    await vi.waitFor(() =>
      expect(focusedCodexMetadataReader).toHaveBeenCalledTimes(4),
    );
    expect(focusedCodexMetadataReader).toHaveBeenLastCalledWith(
      "thread-prewarm-4",
    );

    while (focusedCodexMetadataReader.mock.calls.length < 5) {
      const previousCalls = focusedCodexMetadataReader.mock.calls.length;
      for (const resolve of [...pending.values()]) {
        resolve({
          codexSettings: {
            model: "gpt-5.6-sol",
            modelReasoningEffort: "ultra",
            serviceTier: "standard",
          },
        });
      }
      pending.clear();
      await vi.waitFor(() =>
        expect(focusedCodexMetadataReader.mock.calls.length).toBe(
          Math.min(previousCalls + 3, 5),
        ),
      );
    }
    for (const resolve of [...pending.values()]) {
      resolve({
        codexSettings: {
          model: "gpt-5.6-sol",
          modelReasoningEffort: "ultra",
          serviceTier: "standard",
        },
      });
    }
    pending.clear();

    await vi.waitFor(() => {
      const hydratedIds = [
        ...new Set(
          events(fixture.sent, client, "catalog_changes")
            .flatMap((event) => [...event.created, ...event.updated])
            .filter((entry) => entry.codexSettingsSnapshotComplete === true)
            .map((entry) => entry.providerSessionId),
        ),
      ].sort();
      expect(hydratedIds).toEqual(
        Array.from({ length: 5 }, (_, index) => `thread-prewarm-${index}`),
      );
    });
    expect(maximumActiveReads).toBe(3);
    expect(focusedCodexMetadataReader).not.toHaveBeenCalledWith(
      "thread-prewarm-5",
    );
    expect(focusedCodexMetadataReader).not.toHaveBeenCalledWith(
      "thread-prewarm-6",
    );
    fixture.handler.close();
  });

  it("keeps the five recent Codex threads inside a saturated special queue", async () => {
    const seeds = Array.from({ length: 40 }, (_, index) => {
      const value = codexSeed(index, `thread-saturated-prewarm-${index}`);
      if (index >= 5) {
        value.status = {
          ...value.status,
          activity: "working",
          runtimeAttachment: "loaded",
          confidence: "authoritative",
        };
      }
      return value;
    });
    const focusedCodexMetadataReader = vi.fn(
      () => new Promise<undefined>(() => {}),
    );
    const fixture = createFixture(
      seeds,
      async (target) => history(target.providerSessionId),
      { focusedCodexMetadataReader },
    );
    const client = {};
    const internal = fixture.handler as unknown as {
      priorityCodexSettingsQueue: Set<string>;
    };

    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(focusedCodexMetadataReader).toHaveBeenCalledTimes(3),
    );

    expect(focusedCodexMetadataReader.mock.calls).toEqual([
      ["thread-saturated-prewarm-0"],
      ["thread-saturated-prewarm-1"],
      ["thread-saturated-prewarm-2"],
    ]);
    expect([...internal.priorityCodexSettingsQueue]).toEqual(
      expect.arrayContaining([
        "codex\0thread-saturated-prewarm-3",
        "codex\0thread-saturated-prewarm-4",
      ]),
    );
    expect(internal.priorityCodexSettingsQueue.size).toBe(29);
    await fixture.handler.close();
  });

  it("stops queued settings prewarm after the last client disconnects", async () => {
    const seeds = Array.from({ length: 7 }, (_, index) =>
      codexSeed(index, `thread-disconnect-prewarm-${index}`),
    );
    const pending: Array<() => void> = [];
    const focusedCodexMetadataReader = vi.fn(
      () =>
        new Promise<undefined>((resolve) => {
          pending.push(() => resolve(undefined));
        }),
    );
    const fixture = createFixture(
      seeds,
      async (target) => history(target.providerSessionId),
      { focusedCodexMetadataReader },
    );
    const client = {};

    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(focusedCodexMetadataReader).toHaveBeenCalledTimes(3),
    );

    fixture.handler.disconnect(client);
    for (const resolve of pending) resolve();
    await Promise.resolve();
    await Promise.resolve();

    expect(focusedCodexMetadataReader).toHaveBeenCalledTimes(3);
    await fixture.handler.close();
  });

  it("releases prewarm slots when a settings reader times out", async () => {
    const seeds = Array.from({ length: 6 }, (_, index) =>
      codexSeed(index, `thread-timeout-prewarm-${index}`),
    );
    const focusedCodexMetadataReader = vi.fn((threadId: string) => {
      if (/[0-2]$/.test(threadId)) {
        return new Promise<undefined>(() => {});
      }
      return Promise.resolve({
        codexSettings: {
          model: "gpt-5.6-sol",
          modelReasoningEffort: "ultra",
          serviceTier: "standard",
        },
      });
    });
    const fixture = createFixture(
      seeds,
      async (target) => history(target.providerSessionId),
      {
        focusedCodexMetadataReader,
        codexSettingsHydrationTimeoutMs: 5,
      },
    );
    const client = {};

    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );

    await vi.waitFor(() =>
      expect(focusedCodexMetadataReader).toHaveBeenCalledTimes(5),
    );
    await vi.waitFor(() => {
      const hydratedIds = events(fixture.sent, client, "catalog_changes")
        .flatMap((event) => [...event.created, ...event.updated])
        .filter((entry) => entry.codexSettingsSnapshotComplete === true)
        .map((entry) => entry.providerSessionId);
      expect(hydratedIds).toEqual(
        expect.arrayContaining([
          "thread-timeout-prewarm-3",
          "thread-timeout-prewarm-4",
        ]),
      );
    });
    await fixture.handler.close();
  });

  it("restores pending priority prewarm after shared control reconnects", async () => {
    const seeds = Array.from({ length: 7 }, (_, index) =>
      codexSeed(index, `thread-reconnect-prewarm-${index}`),
    );
    const control = createSharedControlSource({
      kind: "ready",
      connectionGeneration: 1,
    });
    const focusedCodexMetadataReader = vi.fn(
      () => new Promise<undefined>(() => {}),
    );
    const fixture = createFixture(
      seeds,
      async (target) => history(target.providerSessionId),
      {
        daemonMode: true,
        focusedCodexMetadataReader,
        sharedControlReconcileMs: 1,
      },
      { subscribeSharedRuntimeControl: control.subscribe },
    );
    const client = {};
    const internal = fixture.handler as unknown as {
      priorityCodexSettingsQueue: Set<string>;
    };

    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(focusedCodexMetadataReader).toHaveBeenCalledTimes(3),
    );
    expect(internal.priorityCodexSettingsQueue.size).toBe(2);

    control.emit({ kind: "not_ready", connectionGeneration: 1 });
    expect(internal.priorityCodexSettingsQueue.size).toBe(0);
    control.emit({ kind: "ready", connectionGeneration: 2 });

    await vi.waitFor(() =>
      expect(internal.priorityCodexSettingsQueue.size).toBe(2),
    );
    await fixture.handler.close();
  });

  it("does not block the initial focused sync on authoritative settings", async () => {
    const focused = codexSeed(0, "thread-nonblocking-settings");
    let resolveMetadata!: (value: {
      codexSettings: {
        model: string;
        modelReasoningEffort: string;
      };
    }) => void;
    const focusedCodexMetadataReader = vi.fn(
      () =>
        new Promise<{
          codexSettings: {
            model: string;
            modelReasoningEffort: string;
          };
        }>((resolve) => {
          resolveMetadata = resolve;
        }),
    );
    const fixture = createFixture(
      [focused],
      async (target) => history(target.providerSessionId),
      { focusedCodexMetadataReader },
    );
    const client = {};

    await fixture.handler.handle(
      {
        ...subscribeMessage(),
        focused: {
          provider: "codex",
          providerSessionId: focused.entry.providerSessionId,
        },
      },
      context(client, fixture.runtime),
    );

    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );
    expect(focusedCodexMetadataReader).toHaveBeenCalledTimes(1);
    expect(
      events(fixture.sent, client, "catalog_changes")
        .flatMap((event) => [...event.created, ...event.updated])
        .some((entry) => entry.codexSettingsSnapshotComplete === true),
    ).toBe(false);

    resolveMetadata({
      codexSettings: {
        model: "gpt-5.6-sol",
        modelReasoningEffort: "ultra",
      },
    });
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "catalog_changes")
          .flatMap((event) => [...event.created, ...event.updated])
          .find((entry) => entry.codexSettingsSnapshotComplete === true),
      ).toMatchObject({
        model: "gpt-5.6-sol",
        modelReasoningEffort: "ultra",
      }),
    );
    fixture.handler.close();
  });

  it("retries a focused settings timeout without requiring route re-entry", async () => {
    const focused = codexSeed(0, "thread-focused-settings-retry");
    let attempts = 0;
    const focusedCodexMetadataReader = vi.fn(() => {
      attempts += 1;
      if (attempts === 1) return new Promise<undefined>(() => {});
      return Promise.resolve({
        codexSettings: {
          model: "gpt-5.6-sol",
          modelReasoningEffort: "ultra",
          serviceTier: "standard",
          approvalPolicy: "never",
          approvalsReviewer: "user",
          sandboxMode: "danger-full-access",
          collaborationMode: "default" as const,
        },
      });
    });
    const fixture = createFixture(
      [focused],
      async (target) => history(target.providerSessionId),
      {
        focusedCodexMetadataReader,
        codexSettingsHydrationTimeoutMs: 5,
        focusedCodexSettingsRetryMs: 5,
      },
    );
    const client = {};

    await fixture.handler.handle(
      {
        ...subscribeMessage(),
        focused: {
          provider: "codex",
          providerSessionId: focused.entry.providerSessionId,
        },
      },
      context(client, fixture.runtime),
    );

    await vi.waitFor(() =>
      expect(focusedCodexMetadataReader).toHaveBeenCalledTimes(2),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "catalog_changes")
          .flatMap((event) => [...event.created, ...event.updated])
          .find(
            (entry) =>
              entry.providerSessionId === focused.entry.providerSessionId &&
              entry.codexSettingsSnapshotComplete === true,
          ),
      ).toMatchObject({
        model: "gpt-5.6-sol",
        modelReasoningEffort: "ultra",
        serviceTier: "standard",
      }),
    );
    await fixture.handler.close();
  });

  it("rejects settings hydration from an older shared-control generation", async () => {
    type SettingsMetadata = {
      codexSettings: {
        model: string;
        modelReasoningEffort: string;
      };
    };
    const thread = codexSeed(0, "thread-settings-control-generation");
    const control = createSharedControlSource({
      kind: "ready",
      connectionGeneration: 1,
    });
    const resolvers: Array<(value: SettingsMetadata) => void> = [];
    const focusedCodexMetadataReader = vi.fn(
      () =>
        new Promise<SettingsMetadata>((resolve) => {
          resolvers.push(resolve);
        }),
    );
    const fixture = createFixture(
      [thread],
      async (target) => history(target.providerSessionId),
      {
        daemonMode: true,
        focusedCodexMetadataReader,
        sharedControlReconcileMs: 1,
      },
      { subscribeSharedRuntimeControl: control.subscribe },
    );
    const client = {};

    await fixture.handler.handle(
      {
        ...subscribeMessage(),
        focused: {
          provider: "codex",
          providerSessionId: thread.entry.providerSessionId,
        },
      },
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(focusedCodexMetadataReader).toHaveBeenCalledTimes(1),
    );

    control.emit({ kind: "not_ready", connectionGeneration: 1 });
    control.emit({ kind: "ready", connectionGeneration: 2 });
    resolvers[0]!({
      codexSettings: {
        model: "stale-generation-model",
        modelReasoningEffort: "high",
      },
    });

    await vi.waitFor(() =>
      expect(focusedCodexMetadataReader).toHaveBeenCalledTimes(2),
    );
    resolvers[1]!({
      codexSettings: {
        model: "gpt-5.6-sol",
        modelReasoningEffort: "ultra",
      },
    });

    await vi.waitFor(() => {
      const complete = events(fixture.sent, client, "catalog_changes")
        .flatMap((event) => [...event.created, ...event.updated])
        .filter((entry) => entry.codexSettingsSnapshotComplete === true);
      expect(complete).toContainEqual(
        expect.objectContaining({
          providerSessionId: thread.entry.providerSessionId,
          model: "gpt-5.6-sol",
          modelReasoningEffort: "ultra",
        }),
      );
      expect(complete).not.toContainEqual(
        expect.objectContaining({ model: "stale-generation-model" }),
      );
    });
    await fixture.handler.close();
  });

  it("rejects a focused settings result from an older catalog revision", async () => {
    type SettingsMetadata = {
      codexSettings: {
        model: string;
        modelReasoningEffort: string;
      };
    };
    const focused = codexSeed(0, "thread-settings-generation");
    const seeds = [focused];
    const resolvers: Array<(value: SettingsMetadata) => void> = [];
    const focusedCodexMetadataReader = vi.fn(
      () =>
        new Promise<SettingsMetadata>((resolve) => {
          resolvers.push(resolve);
        }),
    );
    const fixture = createFixture(
      seeds,
      async (target) => history(target.providerSessionId),
      { focusedCodexMetadataReader },
    );
    const client = {};

    await fixture.handler.handle(
      {
        ...subscribeMessage(),
        focused: {
          provider: "codex",
          providerSessionId: focused.entry.providerSessionId,
        },
      },
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );
    const initialComplete = events(fixture.sent, client, "sync_complete")[0]!;
    await fixture.handler.handle(
      {
        type: "conversation_sync_ack",
        protocolVersion: 2,
        subscriptionId: initialComplete.subscriptionId,
        sequence: initialComplete.sequence,
      },
      context(client, fixture.runtime),
    );

    focused.entry.revision = "revision-settings-generation-2";
    focused.entry.modifiedAt = "2026-08-02T01:02:03.000Z";
    fixture.handler.sessionCatalogChanged();
    await vi.waitFor(() =>
      expect(fixture.catalogReader).toHaveBeenCalledTimes(2),
    );

    resolvers[0]!({
      codexSettings: {
        model: "stale-model",
        modelReasoningEffort: "low",
      },
    });
    await vi.waitFor(() =>
      expect(focusedCodexMetadataReader).toHaveBeenCalledTimes(2),
    );
    resolvers[1]!({
      codexSettings: {
        model: "gpt-5.6-sol",
        modelReasoningEffort: "ultra",
      },
    });

    await vi.waitFor(() => {
      const internal = fixture.handler as unknown as {
        catalog: Map<
          string,
          {
            entry: ConversationSyncCatalogEntry;
            status: ConversationSyncStatus;
          }
        >;
      };
      expect(
        internal.catalog.get("codex\0thread-settings-generation")?.entry,
      ).toMatchObject({
        revision: "revision-settings-generation-2",
        model: "gpt-5.6-sol",
        modelReasoningEffort: "ultra",
        codexSettingsSnapshotComplete: true,
      });
    });
    expect(
      events(fixture.sent, client, "catalog_changes")
        .flatMap((event) => [...event.created, ...event.updated])
        .some((entry) => entry.model === "stale-model"),
    ).toBe(false);
    fixture.handler.close();
  });

  it("preserves known Codex settings across a later sparse catalog refresh", async () => {
    const original = codexSeed(0, "thread-sparse-settings");
    Object.assign(original.entry, {
      model: "gpt-5.6-sol",
      modelReasoningEffort: "ultra",
      serviceTier: "fast",
      approvalPolicy: "never",
      approvalsReviewer: "user",
      sandboxMode: "danger-full-access",
      collaborationMode: "plan",
      networkAccessEnabled: true,
      codexSettingsSnapshotComplete: true,
    });
    const seeds = [original];
    const fixture = createFixture(seeds, async (target) =>
      history(target.providerSessionId),
    );
    const client = {};
    const subscription = subscribeMessage();

    await fixture.handler.handle(
      subscription,
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );
    const initialComplete = events(fixture.sent, client, "sync_complete")[0]!;
    await fixture.handler.handle(
      {
        type: "conversation_sync_ack",
        protocolVersion: 2,
        subscriptionId: initialComplete.subscriptionId,
        sequence: initialComplete.sequence,
      },
      context(client, fixture.runtime),
    );

    const sparse = codexSeed(0, original.entry.providerSessionId);
    sparse.entry.modifiedAt = "2026-08-02T00:57:53.000Z";
    sparse.entry.recencyAt = original.entry.recencyAt;
    sparse.entry.revision = original.entry.revision;
    seeds[0] = sparse;
    fixture.handler.sessionCatalogChanged();

    await vi.waitFor(() =>
      expect(fixture.catalogReader).toHaveBeenCalledTimes(2),
    );
    const internal = fixture.handler as unknown as {
      catalog: Map<
        string,
        { entry: ConversationSyncCatalogEntry; status: ConversationSyncStatus }
      >;
    };
    expect(
      internal.catalog.get("codex\0thread-sparse-settings")?.entry,
    ).toMatchObject({
      model: "gpt-5.6-sol",
      modelReasoningEffort: "ultra",
      serviceTier: "fast",
      approvalPolicy: "never",
      approvalsReviewer: "user",
      sandboxMode: "danger-full-access",
      collaborationMode: "plan",
      networkAccessEnabled: true,
      codexSettingsSnapshotComplete: true,
      modifiedAt: "2026-08-02T00:57:53.000Z",
    });
    fixture.handler.close();
  });

  it("accepts bounded state cursors and rejects duplicate thread identities", () => {
    expect(
      conversationSyncV2ProtocolContribution.parseClient(
        subscribeMessage([
          {
            provider: "codex",
            providerSessionId: "thread-1",
            revision: "revision-1",
          },
        ]),
      ),
    ).toMatchObject({
      type: "conversation_sync_subscribe",
      protocolVersion: 2,
      threadContentStates: [{ providerSessionId: "thread-1" }],
    });

    expect(
      conversationSyncV2ProtocolContribution.parseClient(
        subscribeMessage([
          {
            provider: "codex",
            providerSessionId: "thread-1",
            revision: "revision-1",
          },
          {
            provider: "codex",
            providerSessionId: "thread-1",
            revision: "revision-2",
          },
        ]),
      ),
    ).toBeNull();
  });

  it("keeps page requests read-only and rejects unbounded limits", () => {
    expect(
      conversationSyncV2ProtocolContribution.parseClient({
        type: "conversation_turns_page",
        protocolVersion: 2,
        requestId: "turns-1",
        subscriptionId: "sync-1",
        provider: "codex",
        providerSessionId: "thread-1",
        limit: 5,
        sortDirection: "desc",
        itemsView: "summary",
        projection: "user_index",
      }),
    ).toMatchObject({
      type: "conversation_turns_page",
      providerSessionId: "thread-1",
    });
    expect(
      conversationSyncV2ProtocolContribution.parseClient({
        type: "conversation_items_page",
        protocolVersion: 2,
        requestId: "items-1",
        subscriptionId: "sync-1",
        provider: "codex",
        providerSessionId: "thread-1",
        limit: 201,
      }),
    ).toBeNull();
    expect(
      conversationSyncV2ProtocolContribution.parseClient({
        type: "conversation_items_page",
        protocolVersion: 2,
        requestId: "items-2",
        subscriptionId: "sync-1",
        provider: "codex",
        providerSessionId: "thread-1",
        turnId: "turn-1",
        toolUseIds: ["tool-1", "tool-2"],
      }),
    ).toMatchObject({
      type: "conversation_items_page",
      turnId: "turn-1",
      toolUseIds: ["tool-1", "tool-2"],
    });
    expect(
      conversationSyncV2ProtocolContribution.parseClient({
        type: "conversation_items_page",
        protocolVersion: 2,
        requestId: "items-3",
        subscriptionId: "sync-1",
        provider: "codex",
        providerSessionId: "thread-1",
        toolUseIds: ["tool-1"],
      }),
    ).toBeNull();
  });

  it("accepts a bounded per-subscription read watermark", () => {
    expect(
      conversationSyncV2ProtocolContribution.parseClient({
        type: "conversation_sync_read",
        protocolVersion: 2,
        subscriptionId: "sync-1",
        provider: "codex",
        providerSessionId: "thread-1",
        readAt: "2026-07-30T00:00:00.000Z",
      }),
    ).toMatchObject({
      type: "conversation_sync_read",
      providerSessionId: "thread-1",
    });
    expect(
      conversationSyncV2ProtocolContribution.parseClient({
        type: "conversation_sync_read",
        protocolVersion: 2,
        subscriptionId: "sync-1",
        provider: "codex",
        providerSessionId: "thread-1",
        readAt: "not-a-date",
      }),
    ).toBeNull();
  });
});

describe("ConversationSyncV2FeatureHandler", () => {
  it("keeps one subscription across later sync batches", async () => {
    const fixture = createFixture([seed(0)], async (target) =>
      history(target.providerSessionId),
    );
    const client = {};
    const subscription = subscribeMessage();

    await fixture.handler.handle(
      subscription,
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "sync_complete").length,
      ).toBeGreaterThanOrEqual(1),
    );
    const firstComplete = events(fixture.sent, client, "sync_complete")[0]!;
    await fixture.handler.handle(
      {
        type: "conversation_sync_ack",
        protocolVersion: 2,
        subscriptionId: subscription.requestId,
        sequence: firstComplete.sequence,
      },
      context(client, fixture.runtime),
    );
    await fixture.handler.handle(
      {
        type: "conversation_sync_read",
        protocolVersion: 2,
        subscriptionId: subscription.requestId,
        provider: "claude",
        providerSessionId: "session-0",
        readAt: new Date().toISOString(),
      },
      context(client, fixture.runtime),
    );

    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_begin")).toHaveLength(2),
    );
    const begins = events(fixture.sent, client, "sync_begin");
    expect(begins[1]).toMatchObject({
      requestId: subscription.requestId,
      subscriptionId: subscription.requestId,
    });
    expect(begins[1]!.sequence).toBeGreaterThan(firstComplete.sequence);
    fixture.handler.close();
  });

  it("applies a read watermark without rereading conversation history", async () => {
    const historyReader = vi.fn(async (target) =>
      history(target.providerSessionId),
    );
    const fixture = createFixture([seed(0)], historyReader);
    const client = {};
    const subscription = subscribeMessage();

    await fixture.handler.handle(
      subscription,
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );
    const historyReads = historyReader.mock.calls.length;
    const timelinePages = events(fixture.sent, client, "timeline_page").length;

    await fixture.handler.handle(
      {
        type: "conversation_sync_read",
        protocolVersion: 2,
        subscriptionId: subscription.requestId,
        provider: "claude",
        providerSessionId: "session-0",
        readAt: new Date().toISOString(),
      },
      context(client, fixture.runtime),
    );

    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(2),
    );
    expect(historyReader).toHaveBeenCalledTimes(historyReads);
    expect(events(fixture.sent, client, "timeline_page")).toHaveLength(
      timelinePages,
    );
    expect(fixture.catalogReader).toHaveBeenCalledTimes(1);
    fixture.handler.close();
  });

  it("keeps one unavailable timeline retryable without aborting the remaining sync batch", async () => {
    const fixture = createFixture([seed(0), seed(1)], async (target) => {
      if (target.providerSessionId === "session-0") {
        throw new Error("one damaged legacy history");
      }
      return history(target.providerSessionId);
    });
    const client = {};

    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );

    expect(events(fixture.sent, client, "error")).toEqual([
      expect.objectContaining({
        errorCode: "timeline_failed",
        target: {
          provider: "claude",
          providerSessionId: "session-0",
        },
      }),
    ]);
    expect(
      events(fixture.sent, client, "timeline_page").find(
        (event) => event.providerSessionId === "session-0",
      ),
    ).toBeUndefined();
    expect(
      events(fixture.sent, client, "timeline_page").some(
        (event) => event.providerSessionId === "session-1",
      ),
    ).toBe(true);
    fixture.handler.close();
  });

  it("publishes direct runtime content when canonical history remains unavailable", async () => {
    const fixture = createFixture([seed(0)], async () => {
      throw new Error("canonical history unavailable");
    });
    fixture.runtime.getProviderSessionId = () => "session-0";
    const session: LocalFeatureSession = {
      id: "runtime-0",
      provider: "claude",
      process: {},
      projectPath: "/project/0",
    };
    const client = {};

    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );
    const firstComplete = events(fixture.sent, client, "sync_complete")[0]!;
    await fixture.handler.handle(
      {
        type: "conversation_sync_ack",
        protocolVersion: 2,
        subscriptionId: firstComplete.subscriptionId,
        sequence: firstComplete.sequence,
      },
      context(client, fixture.runtime),
    );

    fixture.handler.sessionMessage(session, {
      type: "assistant",
      messageUuid: "runtime-live-while-history-unavailable",
      message: {
        id: "runtime-live-while-history-unavailable",
        role: "assistant",
        model: "test",
        content: [{ type: "text", text: "retained live output" }],
      },
    });

    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(2),
    );
    expect(
      JSON.stringify(events(fixture.sent, client, "timeline_page").at(-1)),
    ).toContain("retained live output");
    fixture.handler.close();
  });

  it("adds live fallback content without deleting a phone-only cached window", async () => {
    const fixture = createFixture([seed(0)], async () => {
      throw new Error("canonical history unavailable");
    });
    fixture.runtime.getProviderSessionId = () => "session-0";
    const session: LocalFeatureSession = {
      id: "runtime-0",
      provider: "claude",
      process: {},
      projectPath: "/project/0",
    };
    const client = {};
    const subscription = subscribeMessage([
      {
        provider: "claude",
        providerSessionId: "session-0",
        revision: "phone-cache-only-revision",
      },
    ]);

    await fixture.handler.handle(
      subscription,
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );

    fixture.handler.sessionMessage(session, {
      type: "assistant",
      messageUuid: "runtime-live-additive-fallback",
      message: {
        id: "runtime-live-additive-fallback",
        role: "assistant",
        model: "test",
        content: [{ type: "text", text: "additive live output" }],
      },
    });

    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(2),
    );
    const livePage = events(fixture.sent, client, "timeline_page").at(-1);
    expect(livePage).toMatchObject({
      mode: "patch",
      baseRevision: "phone-cache-only-revision",
      deletes: [],
      latestTurnComplete: false,
    });
    expect(JSON.stringify(livePage)).toContain("additive live output");
    await fixture.handler.close();
  });

  it("accepts an ordered lower watermark that repairs phone clock skew", async () => {
    const fixture = createFixture([seed(0)], async (target) =>
      history(target.providerSessionId),
    );
    const client = {};
    const subscription = subscribeMessage();
    await fixture.handler.handle(
      subscription,
      context(client, fixture.runtime),
    );

    for (const readAt of [
      "2099-07-30T00:00:00.000Z",
      "2026-07-30T00:02:00.000Z",
    ]) {
      await fixture.handler.handle(
        {
          type: "conversation_sync_read",
          protocolVersion: 2,
          subscriptionId: subscription.requestId,
          provider: "claude",
          providerSessionId: "session-0",
          readAt,
        },
        context(client, fixture.runtime),
      );
    }

    const internal = fixture.handler as unknown as {
      subscriptions: Map<object, { readWatermarks: Map<string, string> }>;
    };
    expect(
      internal.subscriptions
        .get(client)!
        .readWatermarks.get("claude\0session-0"),
    ).toBe("2026-07-30T00:02:00.000Z");
    fixture.handler.close();
  });

  it("preserves an older-turn cursor and returns legacy pages chronologically", async () => {
    const historyReader = vi.fn(async (target) => ({
      messages: history(target.providerSessionId),
      nextTurnCursor: "older-turns-1",
    }));
    const fixture = createFixture([seed(0)], historyReader);
    const client = {};
    const subscription = subscribeMessage();

    await fixture.handler.handle(
      subscription,
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );
    expect(events(fixture.sent, client, "timeline_page")[0]).toMatchObject({
      hasEarlier: true,
      turnsNextCursor: "older-turns-1",
      phase: "priority",
      timelineIndex: 0,
      timelineCount: 1,
    });

    await fixture.handler.handle(
      {
        type: "conversation_turns_page",
        protocolVersion: 2,
        requestId: "turns-page-1",
        subscriptionId: subscription.requestId,
        provider: "claude",
        providerSessionId: "session-0",
        cursor: null,
        limit: 5,
        sortDirection: "desc",
        itemsView: "summary",
      },
      context(client, fixture.runtime),
    );

    const response = events(fixture.sent, client, "turns_page_response")[0]!;
    expect(response.data).toHaveLength(1);
    expect(response.data[0]).toMatchObject({
      messages: [
        { type: "user_input", text: "session-0" },
        { type: "assistant" },
      ],
    });
    fixture.handler.close();
  });

  it("re-reads oversized Codex turn pages with an exact bounded cursor", async () => {
    const turns = Array.from({ length: 4 }, (_, index) => ({
      id: `turn-${index}`,
      items: [
        {
          type: "agentMessage",
          id: `assistant-${index}`,
          text: `${index}:${"x".repeat(30 * 1024)}`,
        },
      ],
    }));
    const listThreadTurns = vi.fn(
      async ({ limit }: { limit?: number | null }) => {
        const pageLimit = limit ?? turns.length;
        return {
          data: turns.slice(0, pageLimit),
          nextCursor: pageLimit < turns.length ? `after-${pageLimit}` : null,
        };
      },
    );
    const fixture = createCodexPageFixture({ listThreadTurns });
    const subscription = subscribeMessage();
    await fixture.handler.handle(
      subscription,
      context(fixture.client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, fixture.client, "sync_complete"),
      ).toHaveLength(1),
    );

    await fixture.handler.handle(
      {
        type: "conversation_turns_page",
        protocolVersion: 2,
        requestId: "bounded-turns",
        subscriptionId: subscription.requestId,
        provider: "codex",
        providerSessionId: "thread-bounded",
        limit: 4,
        sortDirection: "desc",
        itemsView: "full",
      },
      context(fixture.client, fixture.runtime),
    );

    const response = events(
      fixture.sent,
      fixture.client,
      "turns_page_response",
    ).find((event) => event.requestId === "bounded-turns")!;
    const finalLimit = listThreadTurns.mock.calls.at(-1)![0].limit!;
    expect(
      listThreadTurns.mock.calls.map(([request]) => request.limit),
    ).toEqual(expect.arrayContaining([4, finalLimit]));
    expect(listThreadTurns).toHaveBeenCalledTimes(
      decreasingLimitCallCount(4, finalLimit),
    );
    expect(response.data).toHaveLength(finalLimit);
    expect(response.nextCursor).toBe(`after-${finalLimit}`);
    expect(
      Buffer.byteLength(JSON.stringify(response), "utf8"),
    ).toBeLessThanOrEqual(64 * 1024);
    fixture.handler.close();
  });

  it("preserves provider user item and turn identities across one Codex page", async () => {
    const fixture = createCodexPageFixture({
      listThreadTurns: vi.fn(async () => ({
        data: [
          {
            id: "turn-newer",
            items: [
              {
                type: "userMessage",
                id: "user-newer",
                content: [{ type: "text", text: "newer" }],
              },
              { type: "agentMessage", id: "agent-newer", text: "answer" },
            ],
          },
          {
            id: "turn-older",
            items: [
              {
                type: "userMessage",
                id: "user-older",
                content: [{ type: "text", text: "older" }],
              },
              { type: "agentMessage", id: "agent-older", text: "answer" },
            ],
          },
        ],
        nextCursor: "older-page",
      })),
    });
    const subscription = subscribeMessage();
    await fixture.handler.handle(
      subscription,
      context(fixture.client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, fixture.client, "sync_complete"),
      ).toHaveLength(1),
    );

    await fixture.handler.handle(
      {
        type: "conversation_turns_page",
        protocolVersion: 2,
        requestId: "provider-user-identities",
        subscriptionId: subscription.requestId,
        provider: "codex",
        providerSessionId: "thread-identities",
        limit: 5,
        sortDirection: "desc",
        itemsView: "summary",
        projection: "user_index",
      },
      context(fixture.client, fixture.runtime),
    );

    const response = events(
      fixture.sent,
      fixture.client,
      "turns_page_response",
    ).at(-1)!;
    const users = response.data.flatMap((rawTurn) => {
      const turn = rawTurn as { messages?: ServerMessage[] };
      return (turn.messages ?? []).filter(
        (message): message is Extract<ServerMessage, { type: "user_input" }> =>
          message.type === "user_input",
      );
    });
    expect(users).toHaveLength(2);
    expect(new Set(users.map((message) => message.providerItemId))).toEqual(
      new Set(["user-newer", "user-older"]),
    );
    expect(new Set(users.map((message) => message.historyTurnId))).toEqual(
      new Set(["turn-newer", "turn-older"]),
    );
    expect(
      response.data.map((rawTurn) => {
        const turn = rawTurn as { messages?: ServerMessage[] };
        return turn.messages?.map((message) => message.type);
      }),
    ).toEqual([["user_input"], ["user_input"]]);
    fixture.handler.close();
  });

  it("projects one oversized Codex turn with stable identity and an explicit gap", async () => {
    const listThreadTurns = vi.fn(async () => ({
      data: [
        {
          id: "turn-oversized",
          items: [
            {
              type: "agentMessage",
              id: "assistant-oversized",
              text: "z".repeat(100 * 1024),
            },
          ],
        },
      ],
      nextCursor: "after-oversized",
    }));
    const fixture = createCodexPageFixture({ listThreadTurns });
    const subscription = subscribeMessage();
    await fixture.handler.handle(
      subscription,
      context(fixture.client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, fixture.client, "sync_complete"),
      ).toHaveLength(1),
    );

    await fixture.handler.handle(
      {
        type: "conversation_turns_page",
        protocolVersion: 2,
        requestId: "projected-turn",
        subscriptionId: subscription.requestId,
        provider: "codex",
        providerSessionId: "thread-oversized",
        limit: 1,
        sortDirection: "desc",
        itemsView: "full",
      },
      context(fixture.client, fixture.runtime),
    );

    const response = events(
      fixture.sent,
      fixture.client,
      "turns_page_response",
    ).find((event) => event.requestId === "projected-turn")!;
    expect(response.nextCursor).toBe("after-oversized");
    expect(response.data[0]).toMatchObject({
      turnId: "turn-oversized",
      itemsView: "summary",
      latestTurnComplete: false,
      latestTurnGap: {
        turnId: "turn-oversized",
        payloadOmitted: true,
      },
    });
    expect(JSON.stringify(response.data[0])).toContain("assistant-oversized");
    expect(JSON.stringify(response.data[0])).toContain("truncated");
    expect(
      Buffer.byteLength(JSON.stringify(response), "utf8"),
    ).toBeLessThanOrEqual(64 * 1024);
    fixture.handler.close();
  });

  it("re-reads oversized Codex item pages without skipping provider items", async () => {
    const items = Array.from({ length: 4 }, (_, index) => ({
      turnId: "turn-items",
      item: {
        type: "agentMessage",
        id: `item-${index}`,
        text: `${index}:${"y".repeat(30 * 1024)}`,
      },
    }));
    const listThreadItems = vi.fn(
      async ({ limit }: { limit?: number | null }) => {
        const pageLimit = limit ?? items.length;
        return {
          data: items.slice(0, pageLimit),
          nextCursor:
            pageLimit < items.length ? `items-after-${pageLimit}` : null,
        };
      },
    );
    const fixture = createCodexPageFixture({ listThreadItems });
    const subscription = subscribeMessage();
    await fixture.handler.handle(
      subscription,
      context(fixture.client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, fixture.client, "sync_complete"),
      ).toHaveLength(1),
    );

    await fixture.handler.handle(
      {
        type: "conversation_items_page",
        protocolVersion: 2,
        requestId: "bounded-items",
        subscriptionId: subscription.requestId,
        provider: "codex",
        providerSessionId: "thread-items",
        turnId: "turn-items",
        limit: 4,
        sortDirection: "asc",
      },
      context(fixture.client, fixture.runtime),
    );

    const response = events(
      fixture.sent,
      fixture.client,
      "items_page_response",
    ).find((event) => event.requestId === "bounded-items")!;
    const finalLimit = listThreadItems.mock.calls.at(-1)![0].limit!;
    expect(listThreadItems).toHaveBeenCalledTimes(
      decreasingLimitCallCount(4, finalLimit),
    );
    expect(response.nextCursor).toBe(`items-after-${finalLimit}`);
    expect(
      Buffer.byteLength(JSON.stringify(response), "utf8"),
    ).toBeLessThanOrEqual(64 * 1024);
    fixture.handler.close();
  });

  it("fails one oversized Codex item without advancing its provider cursor", async () => {
    const listThreadItems = vi.fn(async () => ({
      data: [
        {
          turnId: "turn-one-large-item",
          item: {
            type: "agentMessage",
            id: "item-one-large",
            text: "x".repeat(100 * 1024),
          },
        },
      ],
      nextCursor: "after-one-large-item",
    }));
    const fixture = createCodexPageFixture({ listThreadItems });
    const subscription = subscribeMessage();
    await fixture.handler.handle(
      subscription,
      context(fixture.client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, fixture.client, "sync_complete"),
      ).toHaveLength(1),
    );

    await fixture.handler.handle(
      {
        type: "conversation_items_page",
        protocolVersion: 2,
        requestId: "one-large-item",
        subscriptionId: subscription.requestId,
        provider: "codex",
        providerSessionId: "thread-one-large-item",
        turnId: "turn-one-large-item",
        cursor: "before-one-large-item",
        limit: 1,
        sortDirection: "asc",
      },
      context(fixture.client, fixture.runtime),
    );

    expect(
      events(fixture.sent, fixture.client, "items_page_response").find(
        (event) => event.requestId === "one-large-item",
      ),
    ).toBeUndefined();
    expect(
      events(fixture.sent, fixture.client, "error").find(
        (event) => event.requestId === "one-large-item",
      ),
    ).toMatchObject({
      errorCode: "items_page_failed",
      error: expect.stringContaining("retry with the same cursor"),
    });
    expect(listThreadItems).toHaveBeenCalledTimes(1);
    expect(listThreadItems.mock.calls[0]![0]).toMatchObject({
      cursor: "before-one-large-item",
      limit: 1,
    });
    fixture.handler.close();
  });

  it("bounds raw Codex turns before the real conversion and detail path", async () => {
    let latePayloadReads = 0;
    const items: Array<Record<string, unknown>> = Array.from(
      { length: 12 },
      (_, index) => ({
        type: "agentMessage",
        id: `bounded-raw-${index}`,
        text: `${index}:${"r".repeat(30 * 1024)}`,
      }),
    );
    items.push({
      type: "agentMessage",
      id: "late-unread-item",
      get text() {
        latePayloadReads += 1;
        throw new Error("late raw payload must not be materialized");
      },
    });
    const listThreadTurns = vi.fn(async () => ({
      data: [{ id: "turn-bounded-raw", items }],
      nextCursor: "after-bounded-raw",
    }));
    const fixture = createCodexPageFixture({ listThreadTurns });
    const subscription = subscribeMessage();
    await fixture.handler.handle(
      subscription,
      context(fixture.client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, fixture.client, "sync_complete"),
      ).toHaveLength(1),
    );

    await fixture.handler.handle(
      {
        type: "conversation_turns_page",
        protocolVersion: 2,
        requestId: "bounded-raw-turn",
        subscriptionId: subscription.requestId,
        provider: "codex",
        providerSessionId: "thread-bounded-raw",
        limit: 1,
        sortDirection: "desc",
        itemsView: "full",
      },
      context(fixture.client, fixture.runtime),
    );

    const response = events(
      fixture.sent,
      fixture.client,
      "turns_page_response",
    ).find((event) => event.requestId === "bounded-raw-turn")!;
    expect(latePayloadReads).toBe(0);
    expect(response.data[0]).toMatchObject({
      turnId: "turn-bounded-raw",
      itemsView: "summary",
      latestTurnComplete: false,
      latestTurnGap: {
        turnId: "turn-bounded-raw",
        payloadOmitted: true,
        repair: "items_page",
      },
    });
    expect(
      Buffer.byteLength(JSON.stringify(response), "utf8"),
    ).toBeLessThanOrEqual(64 * 1024);
    fixture.handler.close();
  });

  it("keeps a valid turns response queued without a false page error when send throws", async () => {
    const listThreadTurns = vi.fn(async () => ({
      data: [
        {
          id: "turn-send-retry",
          items: [
            {
              type: "agentMessage",
              id: "answer-send-retry",
              text: "answer",
            },
          ],
        },
      ],
      nextCursor: null,
    }));
    const fixture = createCodexPageFixture({ listThreadTurns });
    const subscriptionMessage = subscribeMessage();
    await fixture.handler.handle(
      subscriptionMessage,
      context(fixture.client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, fixture.client, "sync_complete"),
      ).toHaveLength(1),
    );
    const internal = fixture.handler as unknown as {
      subscriptions: Map<
        object,
        {
          nextSequence: number;
          outbound: Array<{ message: ConversationSyncServerMessage }>;
        }
      >;
      flush(client: object, subscription: object): void;
    };
    const state = internal.subscriptions.get(fixture.client)!;
    const sequenceBefore = state.nextSequence;
    const originalSend = fixture.runtime.send;
    let failed = false;
    fixture.runtime.send = (client, message) => {
      if (
        !failed &&
        (message as ConversationSyncServerMessage).event ===
          "turns_page_response"
      ) {
        failed = true;
        throw new Error("socket write failed once");
      }
      originalSend(client, message);
    };

    await fixture.handler.handle(
      {
        type: "conversation_turns_page",
        protocolVersion: 2,
        requestId: "turns-send-retry",
        subscriptionId: subscriptionMessage.requestId,
        provider: "codex",
        providerSessionId: "thread-send-retry",
        limit: 1,
        sortDirection: "desc",
        itemsView: "summary",
      },
      context(fixture.client, fixture.runtime),
    );

    expect(state.outbound).toHaveLength(1);
    expect(state.outbound[0]!.message).toMatchObject({
      event: "turns_page_response",
      requestId: "turns-send-retry",
      sequence: sequenceBefore + 1,
    });
    expect(
      events(fixture.sent, fixture.client, "error").find(
        (event) => event.requestId === "turns-send-retry",
      ),
    ).toBeUndefined();

    internal.flush(fixture.client, state);
    const delivered = events(
      fixture.sent,
      fixture.client,
      "turns_page_response",
    ).find((event) => event.requestId === "turns-send-retry")!;
    expect(delivered.sequence).toBe(sequenceBefore + 1);
    expect(state.outbound).toHaveLength(0);

    await fixture.handler.handle(
      {
        type: "conversation_turns_page",
        protocolVersion: 2,
        requestId: "turns-after-retry",
        subscriptionId: subscriptionMessage.requestId,
        provider: "codex",
        providerSessionId: "thread-send-retry",
        limit: 1,
        sortDirection: "desc",
        itemsView: "summary",
      },
      context(fixture.client, fixture.runtime),
    );
    expect(
      events(fixture.sent, fixture.client, "turns_page_response").find(
        (event) => event.requestId === "turns-after-retry",
      )?.sequence,
    ).toBe(sequenceBefore + 2);
    fixture.handler.close();
  });

  it("keeps a valid items response queued without a false page error when send throws", async () => {
    const listThreadItems = vi.fn(async () => ({
      data: [
        {
          turnId: "turn-items-send-retry",
          item: {
            type: "agentMessage",
            id: "item-send-retry",
            text: "answer",
          },
        },
      ],
      nextCursor: null,
    }));
    const fixture = createCodexPageFixture({ listThreadItems });
    const subscriptionMessage = subscribeMessage();
    await fixture.handler.handle(
      subscriptionMessage,
      context(fixture.client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, fixture.client, "sync_complete"),
      ).toHaveLength(1),
    );
    const internal = fixture.handler as unknown as {
      subscriptions: Map<
        object,
        {
          nextSequence: number;
          outbound: Array<{ message: ConversationSyncServerMessage }>;
        }
      >;
      flush(client: object, subscription: object): void;
    };
    const state = internal.subscriptions.get(fixture.client)!;
    const sequenceBefore = state.nextSequence;
    const originalSend = fixture.runtime.send;
    let failed = false;
    fixture.runtime.send = (client, message) => {
      if (
        !failed &&
        (message as ConversationSyncServerMessage).event ===
          "items_page_response"
      ) {
        failed = true;
        throw new Error("socket write failed once");
      }
      originalSend(client, message);
    };

    await fixture.handler.handle(
      {
        type: "conversation_items_page",
        protocolVersion: 2,
        requestId: "items-send-retry",
        subscriptionId: subscriptionMessage.requestId,
        provider: "codex",
        providerSessionId: "thread-items-send-retry",
        turnId: "turn-items-send-retry",
        limit: 1,
        sortDirection: "asc",
      },
      context(fixture.client, fixture.runtime),
    );

    expect(state.outbound).toHaveLength(1);
    expect(state.outbound[0]!.message).toMatchObject({
      event: "items_page_response",
      requestId: "items-send-retry",
      sequence: sequenceBefore + 1,
    });
    expect(
      events(fixture.sent, fixture.client, "error").find(
        (event) => event.requestId === "items-send-retry",
      ),
    ).toBeUndefined();

    internal.flush(fixture.client, state);
    const delivered = events(
      fixture.sent,
      fixture.client,
      "items_page_response",
    ).find((event) => event.requestId === "items-send-retry")!;
    expect(delivered.sequence).toBe(sequenceBefore + 1);
    expect(state.outbound).toHaveLength(0);

    await fixture.handler.handle(
      {
        type: "conversation_items_page",
        protocolVersion: 2,
        requestId: "items-after-retry",
        subscriptionId: subscriptionMessage.requestId,
        provider: "codex",
        providerSessionId: "thread-items-send-retry",
        turnId: "turn-items-send-retry",
        limit: 1,
        sortDirection: "asc",
      },
      context(fixture.client, fixture.runtime),
    );
    expect(
      events(fixture.sent, fixture.client, "items_page_response").find(
        (event) => event.requestId === "items-after-retry",
      )?.sequence,
    ).toBe(sequenceBefore + 2);
    fixture.handler.close();
  });

  it("falls back to legacy paging only for unsupported Codex reads", async () => {
    const listThreadTurns = vi.fn(async () => {
      throw new Error("Method not found");
    });
    const listThreadItems = vi.fn(async () => {
      throw new Error("unknown method thread/items/list");
    });
    const historyReader = vi.fn(async () => [
      {
        type: "user_input" as const,
        text: "legacy prompt",
        userMessageUuid: "user-fallback",
      },
      {
        type: "assistant" as const,
        historyTurnId: "legacy-turn:user-fallback",
        messageUuid: "legacy-answer",
        message: {
          id: "legacy-answer",
          role: "assistant" as const,
          model: "test",
          content: [{ type: "text" as const, text: "legacy answer" }],
        },
      },
    ]);
    const fixture = createCodexPageFixture(
      { listThreadTurns, listThreadItems },
      historyReader,
    );
    const subscription = subscribeMessage();
    await fixture.handler.handle(
      subscription,
      context(fixture.client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, fixture.client, "sync_complete"),
      ).toHaveLength(1),
    );

    await fixture.handler.handle(
      {
        type: "conversation_turns_page",
        protocolVersion: 2,
        requestId: "legacy-turns",
        subscriptionId: subscription.requestId,
        provider: "codex",
        providerSessionId: "thread-legacy",
        limit: 5,
        sortDirection: "desc",
        itemsView: "summary",
      },
      context(fixture.client, fixture.runtime),
    );
    await fixture.handler.handle(
      {
        type: "conversation_items_page",
        protocolVersion: 2,
        requestId: "legacy-items",
        subscriptionId: subscription.requestId,
        provider: "codex",
        providerSessionId: "thread-legacy",
        turnId: "legacy-turn:user-fallback",
        limit: 50,
        sortDirection: "asc",
      },
      context(fixture.client, fixture.runtime),
    );

    expect(
      events(fixture.sent, fixture.client, "turns_page_response").find(
        (event) => event.requestId === "legacy-turns",
      ),
    ).toMatchObject({
      nextCursor: null,
      data: [{ turnId: expect.any(String) }],
    });
    expect(
      events(fixture.sent, fixture.client, "items_page_response").find(
        (event) => event.requestId === "legacy-items",
      ),
    ).toMatchObject({
      nextCursor: null,
      data: [
        { type: "user_input" },
        { type: "assistant", messageUuid: "legacy-answer" },
      ],
    });
    expect(listThreadItems).toHaveBeenCalledTimes(1);
    expect(listThreadTurns).toHaveBeenCalledTimes(2);
    expect(historyReader).toHaveBeenCalledTimes(2);
    fixture.handler.close();
  });

  it("preserves consumable opaque legacy cursors and rejects unproven ones", async () => {
    const listThreadTurns = vi.fn(async () => {
      throw new Error("Method not found");
    });
    const historyReader = vi.fn(
      async (
        _target: unknown,
        request?: { cursor: string | null },
      ): Promise<{
        messages: ServerMessage[];
        nextTurnCursor: string | null;
        sourceCursor?: string | null;
      }> => {
        if (request?.cursor === "opaque-unhandled") {
          return {
            messages: history("unhandled-window"),
            nextTurnCursor: null,
          };
        }
        const sourceCursor = request?.cursor ?? null;
        return {
          messages: history(
            sourceCursor === "opaque-page-2"
              ? "opaque-window-2"
              : "opaque-window-1",
          ),
          nextTurnCursor:
            sourceCursor === "opaque-page-1" ? "opaque-page-2" : null,
          sourceCursor,
        };
      },
    );
    const fixture = createCodexPageFixture({ listThreadTurns }, historyReader);
    const subscription = subscribeMessage();
    await fixture.handler.handle(
      subscription,
      context(fixture.client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, fixture.client, "sync_complete"),
      ).toHaveLength(1),
    );

    const requestPage = async (requestId: string, cursor: string) => {
      await fixture.handler.handle(
        {
          type: "conversation_turns_page",
          protocolVersion: 2,
          requestId,
          subscriptionId: subscription.requestId,
          provider: "codex",
          providerSessionId: "thread-opaque-legacy",
          cursor,
          limit: 1,
          sortDirection: "desc",
          itemsView: "summary",
        },
        context(fixture.client, fixture.runtime),
      );
    };

    await requestPage("opaque-1", "opaque-page-1");
    const first = events(
      fixture.sent,
      fixture.client,
      "turns_page_response",
    ).find((event) => event.requestId === "opaque-1")!;
    expect(first.nextCursor).toMatch(/^ccp-legacy-window-v1:/);
    expect(JSON.stringify(first.data[0])).toContain("opaque-window-1");

    await requestPage("opaque-2", first.nextCursor!);
    const second = events(
      fixture.sent,
      fixture.client,
      "turns_page_response",
    ).find((event) => event.requestId === "opaque-2")!;
    expect(second.nextCursor).toBeNull();
    expect(JSON.stringify(second.data[0])).toContain("opaque-window-2");

    await requestPage("opaque-unhandled", "opaque-unhandled");
    expect(
      events(fixture.sent, fixture.client, "turns_page_response").find(
        (event) => event.requestId === "opaque-unhandled",
      ),
    ).toBeUndefined();
    expect(
      events(fixture.sent, fixture.client, "error").find(
        (event) => event.requestId === "opaque-unhandled",
      ),
    ).toMatchObject({
      errorCode: "turns_page_failed",
      error: expect.stringContaining("did not consume"),
    });
    fixture.handler.close();
  });

  it("refuses an unsupported Codex page instead of scanning full durable history", async () => {
    const listThreadTurns = vi.fn(async () => {
      throw new Error("Method not found");
    });
    const fixture = createCodexPageFixture({ listThreadTurns });
    const subscription = subscribeMessage();
    await fixture.handler.handle(
      subscription,
      context(fixture.client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, fixture.client, "sync_complete"),
      ).toHaveLength(1),
    );

    await fixture.handler.handle(
      {
        type: "conversation_turns_page",
        protocolVersion: 2,
        requestId: "no-unbounded-fallback",
        subscriptionId: subscription.requestId,
        provider: "codex",
        providerSessionId: "thread-no-unbounded-fallback",
        cursor: "opaque-old-server-cursor",
        limit: 5,
        sortDirection: "desc",
        itemsView: "summary",
      },
      context(fixture.client, fixture.runtime),
    );

    expect(
      events(fixture.sent, fixture.client, "turns_page_response").find(
        (event) => event.requestId === "no-unbounded-fallback",
      ),
    ).toBeUndefined();
    expect(
      events(fixture.sent, fixture.client, "error").find(
        (event) => event.requestId === "no-unbounded-fallback",
      ),
    ).toMatchObject({
      errorCode: "turns_page_failed",
      error: expect.stringContaining("refusing an unbounded"),
    });
    expect(listThreadTurns).toHaveBeenCalledTimes(1);
    fixture.handler.close();
  });

  it("does not hide non-capability Codex page failures behind legacy history", async () => {
    const listThreadTurns = vi.fn(async () => {
      throw new Error("app-server exited");
    });
    const historyReader = vi.fn(async () => history("should-not-be-read"));
    const fixture = createCodexPageFixture({ listThreadTurns }, historyReader);
    const subscription = subscribeMessage();
    await fixture.handler.handle(
      subscription,
      context(fixture.client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, fixture.client, "sync_complete"),
      ).toHaveLength(1),
    );

    await fixture.handler.handle(
      {
        type: "conversation_turns_page",
        protocolVersion: 2,
        requestId: "real-failure",
        subscriptionId: subscription.requestId,
        provider: "codex",
        providerSessionId: "thread-failure",
        limit: 5,
        sortDirection: "desc",
        itemsView: "summary",
      },
      context(fixture.client, fixture.runtime),
    );

    expect(historyReader).not.toHaveBeenCalled();
    expect(
      events(fixture.sent, fixture.client, "error").find(
        (event) => event.requestId === "real-failure",
      ),
    ).toMatchObject({
      errorCode: "turns_page_failed",
      error: "app-server exited",
    });
    fixture.handler.close();
  });

  it("keeps the latest turn spine intact when one turn exceeds 512 KiB", async () => {
    const turnId = "turn-current";
    const largeTurn: ServerMessage[] = [
      {
        type: "user_input",
        text: "current prompt",
        userMessageUuid: "current-user",
      },
      {
        type: "assistant",
        messageUuid: "current-thinking",
        historyTurnId: turnId,
        message: {
          id: "current-thinking",
          role: "assistant",
          model: "test",
          content: [{ type: "thinking", thinking: "investigating" }],
        },
      },
      ...Array.from({ length: 180 }, (_, index) => {
        const toolUseId = `large-tool-${index}`;
        return [
          {
            type: "assistant" as const,
            messageUuid: `large-tool-call-${index}`,
            historyTurnId: turnId,
            message: {
              id: `large-tool-call-${index}`,
              role: "assistant" as const,
              model: "test",
              content: [
                {
                  type: "tool_use" as const,
                  id: toolUseId,
                  name: "Read",
                  input: { payload: "x".repeat(2 * 1024) },
                },
              ],
            },
          },
          {
            type: "tool_result" as const,
            toolUseId,
            toolName: "Read",
            historyTurnId: turnId,
            content: "y".repeat(4 * 1024),
          },
        ];
      }).flat(),
      {
        type: "assistant",
        messageUuid: "current-final",
        historyTurnId: turnId,
        message: {
          id: "current-final",
          role: "assistant",
          model: "test",
          content: [{ type: "text", text: "current final answer" }],
        },
      },
    ];
    const record = codexSeed(0, "thread-current");
    record.status = {
      ...record.status,
      activity: "working",
      confidence: "authoritative",
      runtimeAttachment: "loaded",
    };
    const fixture = createFixture(
      [record],
      vi.fn(async () => ({
        messages: largeTurn,
        nextTurnCursor: "older-turns-after-current",
      })),
      {
        initialExternalCodexMonitors: 0,
        inspectCodexThread: async () => null,
      },
    );
    const client = {};

    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );

    const timeline = events(fixture.sent, client, "timeline_page");
    const messages = timeline.flatMap((page) =>
      page.entries.map((entry) => entry.message),
    );
    expect(messages[0]).toMatchObject({
      type: "user_input",
      userMessageUuid: "current-user",
    });
    expect(
      messages.some(
        (message) =>
          message.type === "assistant" &&
          message.message.content.some(
            (content) =>
              content.type === "thinking" &&
              content.thinking === "investigating",
          ),
      ),
    ).toBe(true);
    expect(
      messages.some(
        (message) =>
          message.type === "assistant" &&
          message.message.content.some(
            (content) =>
              content.type === "text" &&
              content.text === "current final answer",
          ),
      ),
    ).toBe(true);
    expect(
      messages.some(
        (message) =>
          message.type === "assistant" &&
          (message.historyToolDetailGaps?.length ?? 0) > 0,
      ),
    ).toBe(true);
    expect(timeline[0]).toMatchObject({
      latestTurnComplete: false,
      latestTurnGap: {
        turnId,
        payloadOmitted: true,
        repair: "items_page",
      },
      turnsNextCursor: "older-turns-after-current",
    });
    expect(timeline[0]!.latestTurnGap?.missingEntryCount).toBeGreaterThan(0);
    for (const message of fixture.sent.get(client) ?? []) {
      expect(
        Buffer.byteLength(JSON.stringify(message), "utf8"),
      ).toBeLessThanOrEqual(64 * 1024);
    }
    fixture.handler.close();
  });

  it("budgets timeline patch entries and deletes in the same final envelope", async () => {
    const target = {
      provider: "codex" as const,
      providerSessionId: "thread-joint-patch",
    };
    const baseMessages: ServerMessage[] = [
      {
        type: "user_input",
        text: "base prompt",
        userMessageUuid: "base-user",
      },
      ...Array.from({ length: 300 }, (_, index) => {
        const toolUseId = `t${index}`;
        return [
          {
            type: "assistant" as const,
            messageUuid: `c${index}`,
            historyTurnId: "base-turn",
            message: {
              id: `c${index}`,
              role: "assistant" as const,
              model: "test",
              content: [
                {
                  type: "tool_use" as const,
                  id: toolUseId,
                  name: "Read",
                  input: { index },
                },
              ],
            },
          },
          {
            type: "tool_result" as const,
            toolUseId,
            toolName: "Read",
            historyTurnId: "base-turn",
            content: "ok",
          },
        ];
      }).flat(),
    ];
    const base = buildConversationContentSnapshot(target, baseMessages, {
      maxMessageTextBytes: 40 * 1024,
      maxSnapshotBytes: 512 * 1024,
      preserveLatestRootTurnTools: true,
    });
    const next = buildConversationContentSnapshot(
      target,
      [
        {
          type: "user_input",
          text: "replacement prompt",
          userMessageUuid: "replacement-user",
        },
        {
          type: "assistant",
          messageUuid: "replacement-answer",
          historyTurnId: "replacement-turn",
          message: {
            id: "replacement-answer",
            role: "assistant",
            model: "test",
            content: [{ type: "text", text: "n".repeat(38 * 1024) }],
          },
        },
      ],
      {
        maxMessageTextBytes: 40 * 1024,
        maxSnapshotBytes: 512 * 1024,
        preserveLatestRootTurnTools: true,
      },
    );
    expect(base.entries.length).toBeGreaterThan(500);
    const patchBase = {
      ...base,
      entries: base.entries.map((entry, index) => ({
        ...entry,
        entryId: `${entry.entryId}:${"d".repeat(96)}:${index}`,
      })),
    };
    const fixture = createFixture([], async () => []);
    const client = {};
    const subscription = subscribeMessage();
    await fixture.handler.handle(
      subscription,
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );
    const complete = events(fixture.sent, client, "sync_complete")[0]!;
    await fixture.handler.handle(
      {
        type: "conversation_sync_ack",
        protocolVersion: 2,
        subscriptionId: subscription.requestId,
        sequence: complete.sequence,
      },
      context(client, fixture.runtime),
    );
    const internal = fixture.handler as unknown as {
      subscriptions: Map<object, object>;
      timelinePatchPages(
        subscriptionState: object,
        baseRevision: string,
        nextSnapshot: typeof next,
        entries: typeof next.entries,
        deletes: string[],
        phase: "priority" | "recent" | "cold",
        timelineIndex: number,
        timelineCount: number,
      ): Array<{ entries: typeof next.entries; deletes: string[] }>;
      sendTimelinePatch(
        targetClient: object,
        subscriptionState: object,
        baseSnapshot: typeof base,
        nextSnapshot: typeof next,
        phase: "priority" | "recent" | "cold",
        timelineIndex: number,
        timelineCount: number,
      ): boolean;
    };
    const subscriptionState = internal.subscriptions.get(client)!;
    const rawPages = internal.timelinePatchPages(
      subscriptionState,
      patchBase.revision,
      next,
      next.entries,
      patchBase.entries.map((entry) => entry.entryId),
      "priority",
      0,
      1,
    );
    expect(rawPages.length).toBeGreaterThan(1);

    expect(
      internal.sendTimelinePatch(
        client,
        subscriptionState,
        patchBase,
        next,
        "priority",
        0,
        1,
      ),
    ).toBe(true);

    const patchPages = events(fixture.sent, client, "timeline_page").filter(
      (event) => event.mode === "patch",
    );
    expect(patchPages.length).toBeGreaterThan(1);
    expect(
      patchPages.some(
        (page) => page.entries.length > 0 && page.deletes.length > 0,
      ),
    ).toBe(true);
    expect(patchPages.flatMap((page) => page.deletes)).toHaveLength(
      patchBase.entries.length,
    );
    for (const page of patchPages) {
      expect(
        Buffer.byteLength(JSON.stringify(page), "utf8"),
      ).toBeLessThanOrEqual(64 * 1024);
    }
    fixture.handler.close();
  });

  it("sends special state first, limits provider concurrency, and reuses revisions", async () => {
    const seeds = Array.from({ length: 12 }, (_, index) =>
      seed(index, index === 10 ? workingStatus(index) : undefined),
    );
    let activeReads = 0;
    let maxActiveReads = 0;
    const historyReader = vi.fn(async (target) => {
      activeReads += 1;
      maxActiveReads = Math.max(maxActiveReads, activeReads);
      await new Promise<void>((resolve) => setTimeout(resolve, 2));
      activeReads -= 1;
      return history(target.providerSessionId);
    });
    const fixture = createFixture(seeds, historyReader);
    const firstClient = {};

    await fixture.handler.handle(
      subscribeMessage(),
      context(firstClient, fixture.runtime),
    );
    await vi.waitFor(
      () =>
        expect(events(fixture.sent, firstClient, "sync_complete")).toHaveLength(
          1,
        ),
      { timeout: 3_000 },
    );

    const timeline = events(fixture.sent, firstClient, "timeline_page");
    expect(timeline[0]).toMatchObject({
      providerSessionId: "session-10",
    });
    expect(maxActiveReads).toBeLessThanOrEqual(2);
    expect(
      events(fixture.sent, firstClient, "status_changes")
        .flatMap((event) => event.changes)
        .find((status) => status.providerSessionId === "session-0"),
    ).toMatchObject({
      activity: "idle",
      confidence: "unknown",
      runtimeAttachment: "notLoaded",
    });
    for (const message of fixture.sent.get(firstClient) ?? []) {
      expect(
        Buffer.byteLength(JSON.stringify(message), "utf8"),
      ).toBeLessThanOrEqual(64 * 1024);
    }

    const completion = events(fixture.sent, firstClient, "sync_complete")[0]!;
    const readsAfterFirstSync = historyReader.mock.calls.length;
    const secondClient = {};
    await fixture.handler.handle(
      subscribeMessage(completion.nextState.threadContentStates, {
        catalogState: completion.nextState.catalogState,
        statusState: completion.nextState.statusState,
      }),
      context(secondClient, fixture.runtime),
    );
    await vi.waitFor(
      () =>
        expect(
          events(fixture.sent, secondClient, "sync_complete"),
        ).toHaveLength(1),
      { timeout: 3_000 },
    );
    expect(historyReader).toHaveBeenCalledTimes(readsAfterFirstSync);

    const staleClient = {};
    await fixture.handler.handle(
      subscribeMessage(completion.nextState.threadContentStates, {
        catalogState: "unavailable-catalog-state",
        statusState: "unavailable-status-state",
      }),
      context(staleClient, fixture.runtime),
    );
    await vi.waitFor(
      () =>
        expect(events(fixture.sent, staleClient, "sync_complete")).toHaveLength(
          1,
        ),
      { timeout: 3_000 },
    );
    expect(
      events(fixture.sent, staleClient, "sync_reset").map(
        (event) => event.scope,
      ),
    ).toEqual(expect.arrayContaining(["catalog", "status"]));
    expect(
      events(fixture.sent, staleClient, "timeline_page").length,
    ).toBeGreaterThan(0);
    // The full hot-window bootstrap reuses the Bridge snapshot cache rather
    // than rereading provider history for every reconnecting phone.
    expect(historyReader).toHaveBeenCalledTimes(readsAfterFirstSync);
    fixture.handler.close();
  });

  it("keeps notLoaded status truthful for capable clients and neutral for legacy Mobile", async () => {
    const fixture = createFixture([seed(0)], async (target) =>
      history(target.providerSessionId),
    );
    const legacyClient = {};
    const capableClient = {};
    const capableClients = new Set<object>([capableClient]);
    fixture.runtime.supports = (client: object, type: string) =>
      type === CONVERSATION_SYNC_V2_CAPABILITY ||
      (capableClients.has(client) && type === APP_SERVER_STATUS_CAPABILITY);

    await fixture.handler.handle(
      subscribeMessage([], { statusState: "legacy-status-state" }),
      context(legacyClient, fixture.runtime),
    );
    await fixture.handler.handle(
      subscribeMessage(),
      context(capableClient, fixture.runtime),
    );
    await vi.waitFor(
      () => {
        expect(
          events(fixture.sent, legacyClient, "sync_complete"),
        ).toHaveLength(1);
        expect(
          events(fixture.sent, capableClient, "sync_complete"),
        ).toHaveLength(1);
      },
      { timeout: 3_000 },
    );

    expect(events(fixture.sent, legacyClient, "sync_reset")).toContainEqual(
      expect.objectContaining({ scope: "status" }),
    );
    expect(
      events(fixture.sent, legacyClient, "status_changes")
        .flatMap((event) => event.changes)
        .find((status) => status.providerSessionId === "session-0"),
    ).toMatchObject({
      activity: "idle",
      runtimeAttachment: "notLoaded",
      confidence: "unknown",
    });
    expect(
      events(fixture.sent, capableClient, "status_changes")
        .flatMap((event) => event.changes)
        .find((status) => status.providerSessionId === "session-0"),
    ).toMatchObject({
      activity: "unknown",
      runtimeAttachment: "notLoaded",
      confidence: "unknown",
    });

    const legacyState = events(fixture.sent, legacyClient, "sync_complete")[0]!
      .nextState.statusState;
    const capableState = events(
      fixture.sent,
      capableClient,
      "sync_complete",
    )[0]!.nextState.statusState;
    expect(legacyState).toMatch(/^legacy-status-v1:/);
    expect(capableState).toMatch(/^app-server-status-v1:/);
    const oldRawState = capableState.slice("app-server-status-v1:".length);

    const capableWithRaw = {};
    const capableWithLegacy = {};
    capableClients.add(capableWithRaw);
    capableClients.add(capableWithLegacy);
    const legacyWithCapable = {};
    for (const [client, statusState] of [
      [capableWithRaw, oldRawState],
      [capableWithLegacy, legacyState],
      [legacyWithCapable, capableState],
    ] as const) {
      await fixture.handler.handle(
        subscribeMessage([], { statusState }),
        context(client, fixture.runtime),
      );
      await vi.waitFor(() =>
        expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
      );
      expect(events(fixture.sent, client, "sync_reset")).toContainEqual(
        expect.objectContaining({ scope: "status" }),
      );
      expect(
        events(fixture.sent, client, "status_changes").flatMap(
          (event) => event.changes,
        ),
      ).toHaveLength(1);
    }

    const capableMatching = {};
    const legacyMatching = {};
    capableClients.add(capableMatching);
    for (const [client, statusState] of [
      [capableMatching, capableState],
      [legacyMatching, legacyState],
    ] as const) {
      await fixture.handler.handle(
        subscribeMessage([], { statusState }),
        context(client, fixture.runtime),
      );
      await vi.waitFor(() =>
        expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
      );
      expect(events(fixture.sent, client, "sync_reset")).toEqual([]);
      expect(events(fixture.sent, client, "status_changes")).toEqual([]);
    }
    fixture.handler.close();
  });

  it("keeps sent but unacknowledged frames within one MiB", async () => {
    const seeds = Array.from({ length: 40 }, (_, index) => seed(index));
    const historyReader = vi.fn(async (target) => [
      {
        type: "user_input" as const,
        text: target.providerSessionId,
        userMessageUuid: `user-${target.providerSessionId}`,
      },
      {
        type: "assistant" as const,
        messageUuid: `assistant-${target.providerSessionId}`,
        message: {
          id: `assistant-${target.providerSessionId}`,
          role: "assistant" as const,
          model: "test",
          content: [{ type: "text" as const, text: "x".repeat(34 * 1024) }],
        },
      },
    ]);
    const fixture = createFixture(seeds, historyReader);
    const client = {};

    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(
      () => expect(historyReader.mock.calls.length).toBeGreaterThan(20),
      {
        timeout: 3_000,
      },
    );
    const sentBytes = (fixture.sent.get(client) ?? []).reduce(
      (total, message) =>
        total + Buffer.byteLength(JSON.stringify(message), "utf8"),
      0,
    );
    expect(sentBytes).toBeLessThanOrEqual(1024 * 1024);
    for (const message of fixture.sent.get(client) ?? []) {
      expect(
        Buffer.byteLength(JSON.stringify(message), "utf8"),
      ).toBeLessThanOrEqual(64 * 1024);
    }
    fixture.handler.close();
  });

  it("pauses a ten-thousand-entry catalog at the sync backpressure budget until ACK", async () => {
    const seeds = Array.from({ length: 10_000 }, (_, index) => {
      const value = seed(index);
      value.entry.summary = `${index}:${"x".repeat(512)}`;
      return value;
    });
    const fixture = createFixture(
      seeds,
      vi.fn(async () => []),
    );
    const client = {};

    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    const internal = fixture.handler as unknown as {
      subscriptions: Map<
        object,
        {
          outstandingBytes: number;
          queuedBytes: number;
          capacityWaiters: Set<() => void>;
        }
      >;
    };
    await vi.waitFor(
      () => {
        const state = internal.subscriptions.get(client)!;
        expect(state.outstandingBytes + state.queuedBytes).toBeGreaterThan(
          1024 * 1024,
        );
        expect(state.capacityWaiters.size).toBeGreaterThan(0);
      },
      { timeout: 5_000 },
    );
    const state = internal.subscriptions.get(client)!;
    expect(state.outstandingBytes).toBeLessThanOrEqual(1024 * 1024);
    expect(state.outstandingBytes + state.queuedBytes).toBeLessThanOrEqual(
      2 * 1024 * 1024,
    );
    expect(events(fixture.sent, client, "sync_failed")).toEqual([]);

    await fixture.handler.close();
  });

  it("retains an outbound frame until runtime.send succeeds", async () => {
    const fixture = createFixture([], async () => []);
    const client = {};
    const subscriptionMessage = subscribeMessage();
    await fixture.handler.handle(
      subscriptionMessage,
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );

    const internal = fixture.handler as unknown as {
      subscriptions: Map<
        object,
        {
          nextSequence: number;
          queuedBytes: number;
          outbound: Array<{
            sequence: number;
            bytes: number;
            message: ConversationSyncServerMessage;
          }>;
          outstanding: Map<number, number>;
        }
      >;
      sendEvent(
        client: object,
        subscription: object,
        payload: Record<string, unknown>,
      ): number;
      flush(client: object, subscription: object): void;
    };
    const state = internal.subscriptions.get(client)!;
    const sequenceBeforeFailure = state.nextSequence;
    const originalSend = fixture.runtime.send;
    let shouldThrow = true;
    fixture.runtime.send = (target, message) => {
      if (shouldThrow) {
        shouldThrow = false;
        throw new Error("socket write failed");
      }
      originalSend(target, message);
    };

    expect(() =>
      internal.sendEvent(client, state, {
        event: "error",
        requestId: "retry-frame",
        errorCode: "test",
        error: "retry me",
      }),
    ).toThrow("socket write failed");
    expect(state.outbound).toHaveLength(1);
    expect(state.outbound[0]!.sequence).toBe(sequenceBeforeFailure + 1);
    expect(state.queuedBytes).toBe(state.outbound[0]!.bytes);
    expect(state.outstanding.has(sequenceBeforeFailure + 1)).toBe(false);

    internal.flush(client, state);
    expect(state.outbound).toHaveLength(0);
    expect(state.queuedBytes).toBe(0);
    expect(state.outstanding.has(sequenceBeforeFailure + 1)).toBe(true);
    expect(
      events(fixture.sent, client, "error").find(
        (event) => event.requestId === "retry-frame",
      )?.sequence,
    ).toBe(sequenceBeforeFailure + 1);

    const nextSequence = internal.sendEvent(client, state, {
      event: "error",
      requestId: "next-frame",
      errorCode: "test",
      error: "next",
    });
    expect(nextSequence).toBe(sequenceBeforeFailure + 2);
    fixture.handler.close();
  });

  it("bounds catalog display text before sending it to Mobile", async () => {
    const oversized = seed(0);
    oversized.entry.name = "n".repeat(800);
    oversized.entry.summary = "s".repeat(8_000);
    oversized.entry.firstPrompt = `${"p".repeat(4_094)}😀${"x".repeat(24_000)}`;
    oversized.entry.model = "gpt-5.6-sol";
    oversized.entry.modelReasoningEffort = "ultra";
    oversized.entry.serviceTier = "fast";
    oversized.entry.approvalPolicy = "never";
    oversized.entry.approvalsReviewer = "user";
    oversized.entry.sandboxMode = "danger-full-access";
    oversized.entry.collaborationMode = "plan";
    oversized.entry.networkAccessEnabled = true;
    oversized.entry.webSearchMode = "live";
    oversized.entry.codexSettingsSnapshotComplete = true;
    const fixture = createFixture(
      [oversized],
      vi.fn(async (target) => history(target.providerSessionId)),
    );
    const client = {};

    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "catalog_changes")).toHaveLength(1),
    );

    const entry = events(fixture.sent, client, "catalog_changes")[0]!
      .created[0]!;
    expect(entry.name).toHaveLength(512);
    expect(entry.summary).toHaveLength(4_096);
    expect(entry.firstPrompt).toHaveLength(4_095);
    expect(entry.firstPrompt).toMatch(/…$/);
    expect(entry.firstPrompt).not.toContain("\ud83d");
    expect(entry).toMatchObject({
      model: "gpt-5.6-sol",
      modelReasoningEffort: "ultra",
      serviceTier: "fast",
      approvalPolicy: "never",
      approvalsReviewer: "user",
      sandboxMode: "danger-full-access",
      collaborationMode: "plan",
      networkAccessEnabled: true,
      webSearchMode: "live",
      codexSettingsSnapshotComplete: true,
    });
    for (const message of fixture.sent.get(client) ?? []) {
      expect(
        Buffer.byteLength(JSON.stringify(message), "utf8"),
      ).toBeLessThanOrEqual(64 * 1024);
    }
    fixture.handler.close();
  });

  it("keeps catalog-backed empty history incomplete for bounded repair", async () => {
    const codex = codexSeed(0, "thread-empty-history");
    codex.entry.firstPrompt = "visible user prompt";
    const fixture = createFixture(
      [codex],
      vi.fn(async () => []),
    );
    const client = {};

    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );

    expect(events(fixture.sent, client, "timeline_page")).toEqual([
      expect.objectContaining({
        providerSessionId: "thread-empty-history",
        entries: [],
        hasEarlier: true,
        latestTurnComplete: false,
        latestTurnGap: {
          missingEntryCount: 1,
          payloadOmitted: false,
          repair: "turns_page",
        },
      }),
    ]);
    fixture.handler.close();
  });

  it("keeps a genuinely new empty Codex thread complete", async () => {
    const codex = codexSeed(0, "thread-new-empty");
    delete codex.entry.firstPrompt;
    delete codex.entry.summary;
    codex.entry.modifiedAt = new Date(
      Date.parse(codex.entry.createdAt) + 1_000,
    ).toISOString();
    codex.entry.recencyAt = codex.entry.modifiedAt;
    codex.status.activity = "idle";
    codex.status.confidence = "authoritative";
    const historyReader = vi.fn(async () => []);
    const fixture = createFixture([codex], historyReader);
    const client = {};

    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );

    expect(events(fixture.sent, client, "timeline_page")).toEqual([
      expect.objectContaining({
        providerSessionId: "thread-new-empty",
        entries: [],
        hasEarlier: false,
        latestTurnComplete: true,
      }),
    ]);
    fixture.handler.close();
  });

  it("rereads catalog-backed incomplete history at the same revision", async () => {
    const codex = codexSeed(0, "thread-delayed-history");
    codex.entry.firstPrompt = "visible user prompt";
    delete codex.entry.summary;
    let readCount = 0;
    const historyReader = vi.fn(async () => {
      readCount += 1;
      return readCount === 1 ? [] : history("thread-delayed-history");
    });
    const fixture = createFixture([codex], historyReader);
    const firstClient = {};
    const secondClient = {};

    await fixture.handler.handle(
      subscribeMessage(),
      context(firstClient, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, firstClient, "sync_complete")).toHaveLength(
        1,
      ),
    );
    expect(events(fixture.sent, firstClient, "timeline_page")).toEqual([
      expect.objectContaining({
        providerSessionId: "thread-delayed-history",
        entries: [],
        latestTurnComplete: false,
      }),
    ]);

    await fixture.handler.handle(
      subscribeMessage(),
      context(secondClient, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, secondClient, "sync_complete")).toHaveLength(
        1,
      ),
    );
    expect(historyReader).toHaveBeenCalledTimes(2);
    expect(
      events(fixture.sent, secondClient, "timeline_page").flatMap(
        (event) => event.entries,
      ),
    ).not.toHaveLength(0);
    fixture.handler.close();
  });

  it("shares a bounded provider-history cooldown across clients", async () => {
    const historyReader = vi.fn(async () => {
      throw new Error("provider temporarily unavailable");
    });
    const fixture = createFixture([seed(0)], historyReader, {
      providerHistoryRetryDelaysMs: [500, 10_000],
    });
    const firstClient = {};
    const secondClient = {};

    await fixture.handler.handle(
      subscribeMessage(),
      context(firstClient, fixture.runtime),
    );
    await vi.waitFor(() => expect(historyReader).toHaveBeenCalledTimes(1));
    await vi.waitFor(() =>
      expect(events(fixture.sent, firstClient, "sync_complete")).toHaveLength(
        1,
      ),
    );
    expect(events(fixture.sent, firstClient, "error")).toEqual([
      expect.objectContaining({ errorCode: "timeline_failed" }),
    ]);

    await fixture.handler.handle(
      subscribeMessage(),
      context(secondClient, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, secondClient, "sync_complete")).toHaveLength(
        1,
      ),
    );
    expect(historyReader).toHaveBeenCalledTimes(1);
    expect(events(fixture.sent, secondClient, "timeline_page")).toEqual([]);

    await vi.waitFor(() => expect(historyReader).toHaveBeenCalledTimes(2), {
      timeout: 2_000,
    });
    await fixture.handler.close();
  });

  it("lets explicit focus bypass a provider-history cooldown once", async () => {
    let attempts = 0;
    const historyReader = vi.fn(async () => {
      attempts += 1;
      if (attempts === 1) {
        throw new Error("provider temporarily unavailable");
      }
      return history("session-0-recovered");
    });
    const fixture = createFixture([seed(0)], historyReader, {
      providerHistoryRetryDelaysMs: [60_000],
    });
    const client = {};
    const subscription = subscribeMessage();

    await fixture.handler.handle(
      subscription,
      context(client, fixture.runtime),
    );
    await vi.waitFor(() => expect(historyReader).toHaveBeenCalledTimes(1));
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );

    await fixture.handler.handle(
      {
        type: "conversation_sync_focus",
        protocolVersion: 2,
        requestId: "focus-provider-history-retry",
        subscriptionId: subscription.requestId,
        focused: { provider: "claude", providerSessionId: "session-0" },
      },
      context(client, fixture.runtime),
    );

    await vi.waitFor(() => expect(historyReader).toHaveBeenCalledTimes(2));
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "timeline_page").flatMap(
          (event) => event.entries,
        ),
      ).not.toHaveLength(0),
    );
    await fixture.handler.close();
  });

  it("returns bounded detached tool details without a runtime session", async () => {
    const historyReader = vi.fn(async () => [
      {
        type: "user_input" as const,
        text: "prompt",
        userMessageUuid: "user-session-0",
      },
      {
        type: "assistant" as const,
        message: {
          id: "assistant-tools",
          role: "assistant" as const,
          model: "test",
          content: [
            {
              type: "tool_use" as const,
              id: "tool-1",
              name: "Read",
              input: { path: "/outside/runtime.txt" },
            },
          ],
        },
      },
      {
        type: "tool_result" as const,
        toolUseId: "tool-1",
        toolName: "Read",
        content: "detail result",
      },
    ]);
    const fixture = createFixture([seed(0)], historyReader);
    const client = {};
    const subscription = subscribeMessage();
    await fixture.handler.handle(
      subscription,
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );

    await fixture.handler.handle(
      {
        type: "conversation_items_page",
        protocolVersion: 2,
        requestId: "items-page-1",
        subscriptionId: subscription.requestId,
        provider: "claude",
        providerSessionId: "session-0",
        turnId: "legacy-turn:user-session-0",
        toolUseIds: ["tool-1"],
        limit: 200,
        sortDirection: "asc",
      },
      context(client, fixture.runtime),
    );

    expect(
      events(fixture.sent, client, "items_page_response")[0],
    ).toMatchObject({
      requestId: "items-page-1",
      turnId: "legacy-turn:user-session-0",
      data: [
        {
          type: "history_tool_details",
          details: [
            {
              toolUseId: "tool-1",
              toolName: "Read",
              input: { path: "/outside/runtime.txt" },
              result: { content: "detail result" },
            },
          ],
        },
      ],
    });
    fixture.handler.close();
  });

  it("publishes a catalog change immediately without rereading a clean catalog", async () => {
    const seeds = [seed(0)];
    const historyReader = vi.fn(async (target) =>
      history(target.providerSessionId),
    );
    const fixture = createFixture(seeds, historyReader);
    const client = {};

    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );
    const initialCatalogReads = fixture.catalogReader.mock.calls.length;

    seeds.push(seed(1));
    fixture.handler.sessionCatalogChanged();

    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "catalog_changes").some((event) =>
          event.created.some(
            (entry) => entry.providerSessionId === "session-1",
          ),
        ),
      ).toBe(true),
    );
    expect(fixture.catalogReader).toHaveBeenCalledTimes(
      initialCatalogReads + 1,
    );
    fixture.handler.close();
  });

  it("coalesces live deltas without advancing catalog recency or rescanning the catalog", async () => {
    const historyReader = vi.fn(async (target) =>
      history(target.providerSessionId),
    );
    const liveSeed = seed(0);
    liveSeed.entry.modifiedAt = "2026-07-01T00:00:00.000Z";
    liveSeed.entry.recencyAt = "2026-07-01T00:00:00.000Z";
    const fixture = createFixture([liveSeed], historyReader);
    const client = {};
    fixture.runtime.getProviderSessionId = () => "session-0";
    const session: LocalFeatureSession = {
      id: "runtime-0",
      provider: "claude",
      process: {},
      projectPath: "/project/0",
    };

    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );
    const initialComplete = events(fixture.sent, client, "sync_complete")[0]!;
    await fixture.handler.handle(
      {
        type: "conversation_sync_ack",
        protocolVersion: 2,
        subscriptionId: initialComplete.subscriptionId,
        sequence: initialComplete.sequence,
      },
      context(client, fixture.runtime),
    );
    const initialHistoryReads = historyReader.mock.calls.length;

    for (let index = 0; index < 1_000; index += 1) {
      fixture.handler.sessionMessage(session, {
        type: index % 2 === 0 ? "stream_delta" : "thinking_delta",
        text: `delta-${index}`,
      });
    }

    await vi.waitFor(
      () =>
        expect(events(fixture.sent, client, "sync_complete")).toHaveLength(2),
      { timeout: 3_000 },
    );
    expect(historyReader).toHaveBeenCalledTimes(initialHistoryReads + 1);
    expect(fixture.catalogReader).toHaveBeenCalledTimes(1);
    expect(
      events(fixture.sent, client, "catalog_changes")
        .flatMap((event) => event.updated)
        .find((entry) => entry.providerSessionId === "session-0"),
    ).toBeUndefined();
    const liveTimeline = events(fixture.sent, client, "timeline_page").at(-1);
    expect(liveTimeline?.providerSessionId).toBe("session-0");
    expect(liveTimeline?.revision).not.toBe(liveSeed.entry.revision);

    fixture.handler.sessionCatalogChanged();
    await vi.waitFor(() =>
      expect(fixture.catalogReader).toHaveBeenCalledTimes(2),
    );
    const reconnectClient = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(reconnectClient, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, reconnectClient, "sync_complete"),
      ).not.toHaveLength(0),
    );
    const reconnectEntry = events(
      fixture.sent,
      reconnectClient,
      "catalog_changes",
    )
      .flatMap((event) => event.created)
      .find((entry) => entry.providerSessionId === "session-0");
    expect(reconnectEntry?.modifiedAt).toBe(liveSeed.entry.modifiedAt);
    expect(reconnectEntry?.recencyAt).toBe(liveSeed.entry.recencyAt);
    expect(historyReader).toHaveBeenCalledTimes(initialHistoryReads + 1);
    fixture.handler.close();
  });

  it("advances catalog activity only for discrete assistant text output", async () => {
    const historyReader = vi.fn(async (target) =>
      history(target.providerSessionId),
    );
    const liveSeed = seed(0);
    liveSeed.entry.modifiedAt = "2026-07-01T00:00:00.000Z";
    liveSeed.entry.recencyAt = "2026-07-01T00:00:00.000Z";
    const fixture = createFixture([liveSeed], historyReader);
    const client = {};
    fixture.runtime.getProviderSessionId = () => "session-0";
    const session: LocalFeatureSession = {
      id: "runtime-0",
      provider: "claude",
      process: {},
      projectPath: "/project/0",
    };

    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );
    const initialComplete = events(fixture.sent, client, "sync_complete")[0]!;
    await fixture.handler.handle(
      {
        type: "conversation_sync_ack",
        protocolVersion: 2,
        subscriptionId: initialComplete.subscriptionId,
        sequence: initialComplete.sequence,
      },
      context(client, fixture.runtime),
    );

    fixture.handler.sessionMessage(session, {
      type: "assistant",
      messageUuid: "assistant-tool-only",
      message: {
        id: "assistant-tool-only",
        role: "assistant",
        model: "test",
        content: [
          { type: "text", text: " \n\t " },
          {
            type: "tool_use",
            id: "tool-1",
            name: "Read",
            input: { path: "/tmp/example.txt" },
          },
        ],
      },
    });
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(2),
    );
    expect(
      events(fixture.sent, client, "catalog_changes").flatMap(
        (event) => event.updated,
      ),
    ).toHaveLength(0);
    const toolOnlyRevision = events(fixture.sent, client, "timeline_page").at(
      -1,
    )?.revision;
    expect(toolOnlyRevision).toBeDefined();
    expect(toolOnlyRevision).not.toBe(liveSeed.entry.revision);

    const toolOnlyComplete = events(fixture.sent, client, "sync_complete")[1]!;
    await fixture.handler.handle(
      {
        type: "conversation_sync_ack",
        protocolVersion: 2,
        subscriptionId: toolOnlyComplete.subscriptionId,
        sequence: toolOnlyComplete.sequence,
      },
      context(client, fixture.runtime),
    );
    fixture.handler.sessionMessage(session, {
      type: "assistant",
      messageUuid: "assistant-text",
      message: {
        id: "assistant-text",
        role: "assistant",
        model: "test",
        content: [
          { type: "tool_use", id: "tool-2", name: "Bash", input: {} },
          { type: "text", text: "中间进度输出" },
        ],
      },
    });
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(3),
    );
    const textUpdate = events(fixture.sent, client, "catalog_changes")
      .flatMap((event) => event.updated)
      .find((entry) => entry.providerSessionId === "session-0");
    expect(textUpdate).toBeDefined();
    expect(textUpdate?.modifiedAt).toBe(textUpdate?.recencyAt);
    expect(Date.parse(textUpdate!.recencyAt)).toBeGreaterThan(
      Date.parse(liveSeed.entry.recencyAt),
    );
    const textActivityAt = textUpdate!.recencyAt;
    const textRevision = events(fixture.sent, client, "timeline_page").at(
      -1,
    )?.revision;

    const textComplete = events(fixture.sent, client, "sync_complete")[2]!;
    await fixture.handler.handle(
      {
        type: "conversation_sync_ack",
        protocolVersion: 2,
        subscriptionId: textComplete.subscriptionId,
        sequence: textComplete.sequence,
      },
      context(client, fixture.runtime),
    );
    await new Promise((resolve) => setTimeout(resolve, 10));
    const nonCatalogMessages: ServerMessage[] = [
      {
        type: "assistant",
        messageUuid: "assistant-later-tool",
        message: {
          id: "assistant-later-tool",
          role: "assistant",
          model: "test",
          content: [
            { type: "tool_use", id: "tool-3", name: "Grep", input: {} },
          ],
        },
      },
      {
        type: "tool_result",
        toolUseId: "tool-3",
        toolName: "Grep",
        content: "tool output",
      },
      { type: "stream_delta", text: "streaming" },
      { type: "thinking_delta", text: "thinking" },
      {
        type: "history_delta",
        sessionId: "runtime-0",
        fromSeq: 1,
        toSeq: 1,
        messages: [
          {
            seq: 1,
            message: {
              type: "assistant",
              message: {
                id: "historical-assistant",
                role: "assistant",
                model: "test",
                content: [{ type: "text", text: "historical output" }],
              },
            },
          },
        ],
      },
      { type: "result", subtype: "success", result: "done" },
    ];
    for (const message of nonCatalogMessages) {
      fixture.handler.sessionMessage(session, message);
    }

    await vi.waitFor(
      () =>
        expect(
          events(fixture.sent, client, "sync_complete").length,
        ).toBeGreaterThanOrEqual(4),
      { timeout: 3_000 },
    );
    const catalogUpdates = events(fixture.sent, client, "catalog_changes")
      .flatMap((event) => event.updated)
      .filter((entry) => entry.providerSessionId === "session-0");
    expect(catalogUpdates).toHaveLength(1);
    expect(catalogUpdates[0]?.modifiedAt).toBe(textActivityAt);
    expect(catalogUpdates[0]?.recencyAt).toBe(textActivityAt);
    expect(
      events(fixture.sent, client, "timeline_page").at(-1)?.revision,
    ).not.toBe(textRevision);

    fixture.handler.sessionCatalogChanged();
    await vi.waitFor(() =>
      expect(fixture.catalogReader).toHaveBeenCalledTimes(2),
    );
    const reconnectClient = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(reconnectClient, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, reconnectClient, "sync_complete"),
      ).not.toHaveLength(0),
    );
    const reconnectEntry = events(
      fixture.sent,
      reconnectClient,
      "catalog_changes",
    )
      .flatMap((event) => event.created)
      .find((entry) => entry.providerSessionId === "session-0");
    expect(reconnectEntry?.modifiedAt).toBe(textActivityAt);
    expect(reconnectEntry?.recencyAt).toBe(textActivityAt);
    fixture.handler.close();
  });

  it("settles a paced live stream before rereading one dirty conversation", async () => {
    const historyReader = vi.fn(async (target) =>
      history(target.providerSessionId),
    );
    const fixture = createFixture([seed(0)], historyReader);
    const client = {};
    fixture.runtime.getProviderSessionId = () => "session-0";
    const session: LocalFeatureSession = {
      id: "runtime-0",
      provider: "claude",
      process: {},
      projectPath: "/project/0",
    };

    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );
    const initialHistoryReads = historyReader.mock.calls.length;

    for (let index = 0; index < 20; index += 1) {
      fixture.handler.sessionMessage(session, {
        type: index % 2 === 0 ? "stream_delta" : "thinking_delta",
        text: `paced-delta-${index}`,
      });
      await new Promise((resolve) => setTimeout(resolve, 40));
    }

    await vi.waitFor(
      () =>
        expect(events(fixture.sent, client, "sync_complete")).toHaveLength(2),
      { timeout: 3_000 },
    );
    expect(historyReader).toHaveBeenCalledTimes(initialHistoryReads + 1);
    expect(fixture.catalogReader).toHaveBeenCalledTimes(1);
    fixture.handler.close();
  });

  it("shares one dirty snapshot read across two subscribed clients", async () => {
    const historyReader = vi.fn(async (target) => {
      await new Promise((resolve) => setTimeout(resolve, 10));
      return history(target.providerSessionId);
    });
    const fixture = createFixture([seed(0)], historyReader);
    const firstClient = {};
    const secondClient = {};
    fixture.runtime.getProviderSessionId = () => "session-0";
    const session: LocalFeatureSession = {
      id: "runtime-0",
      provider: "claude",
      process: {},
      projectPath: "/project/0",
    };

    await fixture.handler.handle(
      subscribeMessage(),
      context(firstClient, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, firstClient, "sync_complete")).toHaveLength(
        1,
      ),
    );
    await fixture.handler.handle(
      subscribeMessage(),
      context(secondClient, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, secondClient, "sync_complete")).toHaveLength(
        1,
      ),
    );
    const initialHistoryReads = historyReader.mock.calls.length;

    for (let index = 0; index < 100; index += 1) {
      fixture.handler.sessionMessage(session, {
        type: "stream_delta",
        text: `shared-delta-${index}`,
      });
    }

    await vi.waitFor(
      () => {
        expect(events(fixture.sent, firstClient, "sync_complete")).toHaveLength(
          2,
        );
        expect(
          events(fixture.sent, secondClient, "sync_complete"),
        ).toHaveLength(2);
      },
      { timeout: 3_000 },
    );
    expect(historyReader).toHaveBeenCalledTimes(initialHistoryReads + 1);
    expect(fixture.catalogReader).toHaveBeenCalledTimes(1);
    fixture.handler.close();
  });

  it("projects Desktop-owned rollout state and live messages without a Bridge runtime", async () => {
    const codex = codexSeed(0, "thread-0");
    type HandlerOptions = NonNullable<
      ConstructorParameters<typeof ConversationSyncV2FeatureHandler>[1]
    >;
    type ObserverCallback = Parameters<
      NonNullable<HandlerOptions["observeCodexThread"]>
    >[1];
    const callbacks = new Map<string, ObserverCallback>();
    const refreshNow = vi.fn(async () => {});
    const close = vi.fn();
    const historyReader = vi.fn(async () => history("canonical-before-live"));
    const fixture = createFixture([codex], historyReader, {
      initialExternalCodexMonitors: 1,
      maxExternalCodexMonitors: 2,
      observeCodexThread: async (threadId, onEvent) => {
        callbacks.set(threadId, onEvent);
        return {
          snapshot: { state: "running" as const, turnId: "turn-live" },
          refreshNow,
          close,
        };
      },
    });
    const client = {};

    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );
    expect(
      events(fixture.sent, client, "status_changes")
        .flatMap((event) => event.changes)
        .find((status) => status.providerSessionId === "thread-0"),
    ).toMatchObject({
      activity: "working",
      runtimeAttachment: "ownedElsewhere",
      source: "legacyRollout",
      confidence: "observed",
    });

    const callback = callbacks.get("thread-0");
    expect(callback).toBeDefined();
    callback!({
      kind: "message",
      itemKey: "assistant:desktop-live",
      timestamp: new Date().toISOString(),
      message: {
        type: "assistant",
        messageUuid: "desktop-live",
        message: {
          id: "desktop-live",
          role: "assistant",
          model: "codex",
          content: [{ type: "text", text: "desktop live update" }],
        },
      },
    });

    await vi.waitFor(
      () =>
        expect(
          JSON.stringify(events(fixture.sent, client, "timeline_page")),
        ).toContain("desktop live update"),
      { timeout: 3_000 },
    );
    expect(historyReader.mock.calls.length).toBeGreaterThanOrEqual(2);
    fixture.handler.close();
    expect(close).toHaveBeenCalledTimes(1);
  });

  it("keeps external live messages until canonical history covers them", async () => {
    type HandlerOptions = NonNullable<
      ConstructorParameters<typeof ConversationSyncV2FeatureHandler>[1]
    >;
    type ObserverCallback = Parameters<
      NonNullable<HandlerOptions["observeCodexThread"]>
    >[1];
    let callback: ObserverCallback | undefined;
    const codex = codexSeed(0, "thread-catalog-race");
    let canonicalHistory: ServerMessage[] = [];
    const historyReader = vi.fn(async () => canonicalHistory);
    const fixture = createFixture([codex], historyReader, {
      initialExternalCodexMonitors: 1,
      observeCodexThread: async (_threadId, onEvent) => {
        callback = onEvent;
        return {
          snapshot: { state: "running" as const },
          refreshNow: async () => {},
          close: () => {},
        };
      },
    });
    const client = {};
    const internal = fixture.handler as unknown as {
      externalCodexLiveMessages: Map<
        string,
        Map<string, { message: ServerMessage }>
      >;
      liveContentRevisions: Map<string, unknown>;
      pendingLiveContent: Map<string, unknown>;
    };

    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() => expect(callback).toBeDefined());
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );

    const liveAt = new Date().toISOString();
    const liveMessage: ServerMessage = {
      type: "assistant",
      messageUuid: "catalog-race",
      message: {
        id: "catalog-race",
        role: "assistant",
        model: "codex",
        content: [{ type: "text", text: "live before canonical history" }],
      },
    };
    callback!({
      kind: "message",
      itemKey: "assistant:catalog-race",
      timestamp: liveAt,
      message: liveMessage,
    });
    callback!({
      kind: "message",
      itemKey: "reasoning:catalog-race",
      timestamp: liveAt,
      message: {
        type: "thinking_delta",
        text: "transient reasoning before canonical history\n",
      },
    });
    await vi.waitFor(() =>
      expect(
        JSON.stringify(events(fixture.sent, client, "timeline_page")),
      ).toContain("live before canonical history"),
    );
    await vi.waitFor(
      () =>
        expect(
          JSON.stringify(events(fixture.sent, client, "timeline_page")),
        ).toContain("transient reasoning before canonical history"),
      { timeout: 3_000 },
    );
    await vi.waitFor(() =>
      expect(
        internal.pendingLiveContent.has("codex\0thread-catalog-race"),
      ).toBe(false),
    );
    const completedBeforeCatalog = events(
      fixture.sent,
      client,
      "sync_complete",
    ).length;

    const caughtUpAt = new Date(Date.parse(liveAt) + 1_000).toISOString();
    codex.entry.modifiedAt = caughtUpAt;
    codex.entry.recencyAt = caughtUpAt;
    codex.entry.revision = "revision-catalog-caught-up";
    fixture.handler.sessionCatalogChanged();

    await vi.waitFor(() =>
      expect(fixture.catalogReader.mock.calls.length).toBeGreaterThanOrEqual(2),
    );
    await vi.waitFor(() =>
      expect(
        internal.liveContentRevisions.has("codex\0thread-catalog-race"),
      ).toBe(false),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "sync_complete").length,
      ).toBeGreaterThan(completedBeforeCatalog),
    );
    const latestComplete = events(fixture.sent, client, "sync_complete").at(
      -1,
    )!;
    const latestTimeline = events(fixture.sent, client, "timeline_page").filter(
      (event) => event.batchId === latestComplete.batchId,
    );
    expect(JSON.stringify(latestTimeline)).toContain(
      "live before canonical history",
    );
    expect(
      internal.externalCodexLiveMessages.has("codex\0thread-catalog-race"),
    ).toBe(true);

    canonicalHistory = [liveMessage];
    const readsBeforeCanonical = historyReader.mock.calls.length;
    const secondClient = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(secondClient, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, secondClient, "sync_complete")).toHaveLength(
        1,
      ),
    );
    expect(
      JSON.stringify(events(fixture.sent, secondClient, "timeline_page")),
    ).toContain("live before canonical history");
    expect(
      JSON.stringify(events(fixture.sent, secondClient, "timeline_page")),
    ).not.toContain("transient reasoning before canonical history");
    expect(historyReader.mock.calls.length).toBeGreaterThan(
      readsBeforeCanonical,
    );
    expect(
      internal.liveContentRevisions.has("codex\0thread-catalog-race"),
    ).toBe(false);
    expect(
      internal.externalCodexLiveMessages.has("codex\0thread-catalog-race"),
    ).toBe(false);
    fixture.handler.close();
  });

  it("matches canonical and live users one-to-one while preserving equal delta chunks", async () => {
    type HandlerOptions = NonNullable<
      ConstructorParameters<typeof ConversationSyncV2FeatureHandler>[1]
    >;
    type ObserverCallback = Parameters<
      NonNullable<HandlerOptions["observeCodexThread"]>
    >[1];
    let callback: ObserverCallback | undefined;
    const sourceTimestamp = "2026-07-30T02:00:00.000Z";
    const fixture = createFixture(
      [codexSeed(0, "thread-0")],
      async () => [
        {
          type: "user_input",
          text: "继续",
          userMessageUuid: "codex:user-turn:1",
          timestamp: sourceTimestamp,
          sourceTimestamp,
          sourceTimestampIsAuthoritative: true,
        },
      ],
      {
        initialExternalCodexMonitors: 1,
        observeCodexThread: async (_threadId, onEvent) => {
          callback = onEvent;
          return {
            snapshot: {
              state: "running" as const,
              observedAt: "2026-07-30T02:00:01.000Z",
            },
            refreshNow: async () => {},
            close: () => {},
          };
        },
      },
    );
    const client = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() => expect(callback).toBeDefined());
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );

    callback!({
      kind: "message",
      itemKey: "user:desktop-1",
      timestamp: "2026-07-30T02:00:00.500Z",
      message: {
        type: "user_input",
        text: "继续",
        clientMessageId: "desktop-1",
        timestamp: "2026-07-30T02:00:00.500Z",
      },
    });
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "sync_complete").length,
      ).toBeGreaterThanOrEqual(2),
    );
    for (const itemKey of ["thinking:1", "thinking:2"]) {
      callback!({
        kind: "message",
        itemKey,
        timestamp: "2026-07-30T02:00:01.000Z",
        message: { type: "thinking_delta", text: "same delta chunk" },
      });
    }

    await vi.waitFor(
      () =>
        expect(
          events(fixture.sent, client, "sync_complete").length,
        ).toBeGreaterThanOrEqual(3),
      { timeout: 3_000 },
    );
    const latestComplete = events(fixture.sent, client, "sync_complete").at(
      -1,
    )!;
    const latestTimeline = events(fixture.sent, client, "timeline_page").filter(
      (event) => event.batchId === latestComplete.batchId,
    );
    const serialized = JSON.stringify(latestTimeline);
    expect(serialized.match(/继续/g)).toHaveLength(1);
    expect(serialized.match(/same delta chunk/g)).toHaveLength(2);
    const timestampedDeltas = latestTimeline
      .flatMap((event) => event.entries)
      .map((entry) => entry.message)
      .filter((message) => message.type === "thinking_delta");
    expect(timestampedDeltas).toHaveLength(2);
    for (const message of timestampedDeltas) {
      expect(message).toMatchObject({
        sourceTimestamp: "2026-07-30T02:00:01.000Z",
        sourceTimestampIsAuthoritative: true,
      });
    }
    fixture.handler.close();
  });

  it("reads Desktop item timestamps only when v2 content is requested and marks them authoritative", async () => {
    const sourceTimestamps = {
      user: "2026-07-30T02:00:00.000Z",
      toolStarted: "2026-07-30T02:00:02.000Z",
      toolCompleted: "2026-07-30T02:00:04.000Z",
      assistant: "2026-07-30T02:00:05.000Z",
    };
    const desktopToolTimelineReader = vi.fn(async () => ({
      events: [],
      callIds: new Set<string>(),
      itemTimestamps: new Map([
        [
          "user-item",
          {
            startedAt: sourceTimestamps.user,
            completedAt: sourceTimestamps.user,
          },
        ],
        [
          "tool-item",
          {
            startedAt: sourceTimestamps.toolStarted,
            completedAt: sourceTimestamps.toolCompleted,
          },
        ],
        [
          "assistant-item",
          {
            startedAt: sourceTimestamps.assistant,
            completedAt: sourceTimestamps.assistant,
          },
        ],
      ]),
    }));
    const listThreadTurns = vi.fn(async () => ({
      data: [timestampedCodexTurn()],
      nextCursor: null,
    }));
    const codex = codexSeed(0, "thread-timestamps");
    const fixture = createCodexPageFixture({ listThreadTurns }, undefined, {
      catalogReader: async () => [codex],
      desktopToolTimelineReader,
      initialExternalCodexMonitors: 0,
    });

    const cachedClient = {};
    await fixture.handler.handle(
      subscribeMessage([
        {
          provider: "codex",
          providerSessionId: codex.entry.providerSessionId,
          revision: codex.entry.revision,
        },
      ]),
      context(cachedClient, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, cachedClient, "sync_complete")).toHaveLength(
        1,
      ),
    );
    expect(listThreadTurns).not.toHaveBeenCalled();
    expect(desktopToolTimelineReader).not.toHaveBeenCalled();
    fixture.handler.disconnect(cachedClient);

    const freshClient = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(freshClient, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, freshClient, "sync_complete")).toHaveLength(
        1,
      ),
    );
    expect(desktopToolTimelineReader).toHaveBeenCalledTimes(1);
    expect(desktopToolTimelineReader).toHaveBeenCalledWith("thread-timestamps");
    const messages = events(fixture.sent, freshClient, "timeline_page").flatMap(
      (event) => event.entries.map((entry) => entry.message),
    );
    expect(
      messages.map((message) => ({
        type: message.type,
        sourceTimestamp: message.sourceTimestamp,
        authoritative: message.sourceTimestampIsAuthoritative,
      })),
    ).toEqual([
      {
        type: "user_input",
        sourceTimestamp: sourceTimestamps.user,
        authoritative: true,
      },
      {
        type: "assistant",
        sourceTimestamp: sourceTimestamps.toolStarted,
        authoritative: true,
      },
      {
        type: "tool_result",
        sourceTimestamp: sourceTimestamps.toolCompleted,
        authoritative: true,
      },
      {
        type: "assistant",
        sourceTimestamp: sourceTimestamps.assistant,
        authoritative: true,
      },
    ]);
    fixture.handler.close();
  });

  it("keeps turn-level timestamp fallback non-authoritative when no Desktop timeline exists", async () => {
    const desktopToolTimelineReader = vi.fn(async () => ({
      events: [],
      callIds: new Set<string>(),
    }));
    const fixture = createCodexPageFixture(
      {
        listThreadTurns: async () => ({
          data: [timestampedCodexTurn()],
          nextCursor: null,
        }),
      },
      undefined,
      {
        catalogReader: async () => [codexSeed(0, "thread-fallback-timestamps")],
        desktopToolTimelineReader,
        initialExternalCodexMonitors: 0,
      },
    );
    const client = {};

    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );

    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );
    const messages = events(fixture.sent, client, "timeline_page").flatMap(
      (event) => event.entries.map((entry) => entry.message),
    );
    expect(messages).not.toHaveLength(0);
    const timestampedMessages = messages.filter(
      (message) => message.sourceTimestamp != null,
    );
    expect(timestampedMessages).not.toHaveLength(0);
    expect(
      timestampedMessages.every(
        (message) => message.sourceTimestampIsAuthoritative !== true,
      ),
    ).toBe(true);
    fixture.handler.close();
  });

  it("does not seed full rollout monitors for unchanged idle recent threads", async () => {
    const observeCodexThread = vi.fn(async () => ({
      snapshot: { state: "idle" as const },
      refreshNow: async () => {},
      close: () => {},
    }));
    const fixture = createFixture(
      [codexSeed(0, "thread-0"), codexSeed(1, "thread-1")],
      async (target) => history(target.providerSessionId),
      {
        inspectCodexThread: async () => ({ state: "idle" as const }),
        observeCodexThread,
      },
    );
    const client = {};

    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );
    expect(observeCodexThread).not.toHaveBeenCalled();
    fixture.handler.close();
  });

  it("attaches the existing rollout monitor when any durable Codex thread changes", async () => {
    const callbacks = new Map<string, () => void>();
    const observedThreads: string[] = [];
    const fixture = createFixture(
      [codexSeed(0, "thread-0"), codexSeed(1, "thread-1")],
      async (target) => history(target.providerSessionId),
      {
        initialExternalCodexMonitors: 1,
        maxExternalCodexMonitors: 2,
        observeCodexThread: async (threadId, onEvent) => {
          observedThreads.push(threadId);
          callbacks.set(threadId, () =>
            onEvent({
              kind: "state",
              state: "running",
              turnId: `turn-${threadId}`,
              timestamp: new Date().toISOString(),
            }),
          );
          return {
            snapshot: {
              state: threadId === "thread-1" ? "running" : "idle",
            },
            refreshNow: async () => {},
            close: () => {},
          };
        },
      },
    );
    const client = {};

    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );
    expect(observedThreads).toEqual(["thread-0"]);

    fixture.handler.sessionCatalogChanged({
      revision: 2,
      provider: "codex",
      providerSessionId: "thread-1",
    });
    await vi.waitFor(() => expect(observedThreads).toContain("thread-1"));
    callbacks.get("thread-1")!();
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "status_changes").some((event) =>
          event.changes.some(
            (status) =>
              status.providerSessionId === "thread-1" &&
              status.activity === "working" &&
              status.runtimeAttachment === "ownedElsewhere",
          ),
        ),
      ).toBe(true),
    );
    fixture.handler.close();
  });

  it("rewarms external rollout monitors after the last client disconnects", async () => {
    const codex = codexSeed(0, "thread-0");
    type HandlerOptions = NonNullable<
      ConstructorParameters<typeof ConversationSyncV2FeatureHandler>[1]
    >;
    type ObserverCallback = Parameters<
      NonNullable<HandlerOptions["observeCodexThread"]>
    >[1];
    const callbacks: ObserverCallback[] = [];
    const closes: Array<ReturnType<typeof vi.fn>> = [];
    let observations = 0;
    const fixture = createFixture([codex], async () => history("thread-0"), {
      initialExternalCodexMonitors: 1,
      observeCodexThread: async (_threadId, onEvent) => {
        observations += 1;
        callbacks.push(onEvent);
        const close = vi.fn();
        closes.push(close);
        return {
          snapshot: {
            state:
              observations === 1 ? ("idle" as const) : ("running" as const),
          },
          refreshNow: async () => {},
          close,
        };
      },
    });
    const firstClient = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(firstClient, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, firstClient, "sync_complete")).toHaveLength(
        1,
      ),
    );
    expect(observations).toBe(1);

    fixture.handler.disconnect(firstClient);
    expect(closes[0]).toHaveBeenCalledTimes(1);

    const secondClient = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(secondClient, fixture.runtime),
    );
    await vi.waitFor(() => expect(observations).toBe(2));
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, secondClient, "status_changes")
          .flatMap((event) => event.changes)
          .some(
            (status) =>
              status.providerSessionId === "thread-0" &&
              status.activity === "working",
          ),
      ).toBe(true),
    );

    callbacks[0]!({
      kind: "state",
      state: "idle",
      timestamp: new Date().toISOString(),
    });
    await new Promise((resolve) => setTimeout(resolve, 0));
    const latest = events(fixture.sent, secondClient, "status_changes")
      .flatMap((event) => event.changes)
      .filter((status) => status.providerSessionId === "thread-0")
      .at(-1);
    expect(latest?.activity).toBe("working");
    fixture.handler.close();
    expect(closes[1]).toHaveBeenCalledTimes(1);
  });

  it("lets a newer external running observation override app-server idle", async () => {
    const codex = codexSeed(0, "thread-0");
    codex.status = {
      ...codex.status,
      activity: "idle",
      runtimeAttachment: "loaded",
      source: "appServer",
      confidence: "authoritative",
      observedAt: "2026-07-30T00:00:00.000Z",
    };
    const fixture = createFixture([codex], async () => history("thread-0"), {
      initialExternalCodexMonitors: 1,
      observeCodexThread: async () => ({
        snapshot: {
          state: "running" as const,
          turnId: "external-turn",
          observedAt: "2026-07-30T00:00:01.000Z",
        },
        refreshNow: async () => {},
        close: () => {},
      }),
    });
    const client = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "status_changes")
          .flatMap((event) => event.changes)
          .find((status) => status.providerSessionId === "thread-0"),
      ).toMatchObject({
        activity: "working",
        runtimeAttachment: "ownedElsewhere",
        source: "legacyRollout",
        confidence: "observed",
      }),
    );
    fixture.handler.close();
  });

  it("does not let an older external observation override authoritative idle or error", async () => {
    for (const activity of ["idle", "systemError"] as const) {
      const codex = codexSeed(0, `thread-${activity}`);
      codex.status = {
        ...codex.status,
        activity,
        runtimeAttachment: "loaded",
        source: "appServer",
        confidence: "authoritative",
        observedAt: "2026-07-30T00:00:02.000Z",
      };
      const fixture = createFixture(
        [codex],
        async () => history(`thread-${activity}`),
        {
          initialExternalCodexMonitors: 1,
          observeCodexThread: async () => ({
            snapshot: {
              state: "running" as const,
              observedAt: "2026-07-30T00:00:01.000Z",
            },
            refreshNow: async () => {},
            close: () => {},
          }),
        },
      );
      const client = {};
      await fixture.handler.handle(
        subscribeMessage(),
        context(client, fixture.runtime),
      );
      await vi.waitFor(() =>
        expect(
          events(fixture.sent, client, "status_changes")
            .flatMap((event) => event.changes)
            .find((status) => status.providerSessionId === `thread-${activity}`)
            ?.activity,
        ).toBe(activity),
      );
      fixture.handler.close();
    }
  });

  it("keeps trusted Desktop activity when a newer Bridge runtime observation is idle", async () => {
    const codex = codexSeed(0, "thread-0");
    codex.status = {
      ...codex.status,
      activity: "idle",
      runtimeAttachment: "loaded",
      source: "appServer",
      confidence: "authoritative",
      observedAt: "2026-07-30T00:00:00.000Z",
    };
    const observeCodexThread = vi.fn(async () => ({
      snapshot: {
        state: "running" as const,
        observedAt: "2026-07-30T00:00:02.000Z",
      },
      refreshNow: async () => {},
      close: () => {},
    }));
    const fixture = createFixture([codex], async () => history("thread-0"), {
      initialExternalCodexMonitors: 1,
      observeCodexThread,
    });
    fixture.runtime.listRuntimeConversationStates = () => [
      {
        bridgeSessionId: "runtime-idle",
        provider: "codex",
        providerSessionId: "thread-0",
        projectPath: "/project/0",
        processStatus: "idle",
        observedAt: "2026-07-30T00:00:03.000Z",
      },
    ];
    const client = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "status_changes")
          .flatMap((event) => event.changes)
          .find((status) => status.providerSessionId === "thread-0"),
      ).toMatchObject({
        activity: "working",
        runtimeAttachment: "ownedElsewhere",
        source: "legacyRollout",
      }),
    );
    expect(observeCodexThread).toHaveBeenCalledTimes(1);
    fixture.handler.close();
  });

  it("keeps app-server Need You over a newer passive Bridge runtime", async () => {
    const codex = codexSeed(0, "thread-0");
    codex.status = {
      ...codex.status,
      activity: "working",
      attention: "question",
      runtimeAttachment: "loaded",
      source: "appServer",
      confidence: "authoritative",
      observedAt: "2026-07-30T00:00:01.000Z",
    };
    const fixture = createFixture([codex], async () => history("thread-0"), {
      initialExternalCodexMonitors: 0,
      inspectCodexThread: async () => null,
    });
    fixture.runtime.listRuntimeConversationStates = () => [
      {
        bridgeSessionId: "runtime-idle",
        provider: "codex",
        providerSessionId: "thread-0",
        projectPath: "/project/0",
        processStatus: "idle",
        observedAt: "2026-07-30T00:00:02.000Z",
      },
    ];
    const client = {};

    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );

    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "status_changes")
          .flatMap((event) => event.changes)
          .find((status) => status.providerSessionId === "thread-0"),
      ).toMatchObject({
        activity: "working",
        attention: "question",
        runtimeAttachment: "loaded",
        source: "appServer",
        confidence: "authoritative",
      }),
    );
    fixture.handler.close();
  });

  it("keeps local attention authoritative over an external rollout", async () => {
    const codex = codexSeed(0, "thread-0");
    const observeCodexThread = vi.fn(async () => ({
      snapshot: {
        state: "running" as const,
        observedAt: "2026-07-30T00:00:02.000Z",
      },
      refreshNow: async () => {},
      close: () => {},
    }));
    const fixture = createFixture([codex], async () => history("thread-0"), {
      initialExternalCodexMonitors: 1,
      observeCodexThread,
    });
    fixture.runtime.listRuntimeConversationStates = () => [
      {
        bridgeSessionId: "runtime-attention",
        provider: "codex",
        providerSessionId: "thread-0",
        projectPath: "/project/0",
        processStatus: "idle",
        pendingAttention: {
          requestId: "approval-1",
          kind: "approval",
        },
        observedAt: "2026-07-30T00:00:01.000Z",
      },
    ];
    const client = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "status_changes")
          .flatMap((event) => event.changes)
          .find((status) => status.providerSessionId === "thread-0"),
      ).toMatchObject({
        attention: "approval",
        source: "bridgeRuntime",
        confidence: "authoritative",
      }),
    );
    expect(observeCodexThread).not.toHaveBeenCalled();
    fixture.handler.close();
  });

  it("keeps the private fallback's legacy starting runtime as Working", async () => {
    const codex = codexSeed(0, "thread-0");
    const fixture = createFixture([codex], async () => history("thread-0"), {
      initialExternalCodexMonitors: 0,
      inspectCodexThread: async () => null,
    });
    fixture.runtime.listRuntimeConversationStates = () => [
      {
        bridgeSessionId: "runtime-starting",
        provider: "codex",
        providerSessionId: "thread-0",
        projectPath: "/project/0",
        processStatus: "starting",
        observedAt: "2026-07-30T00:00:02.000Z",
      },
    ];
    const client = {};

    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );

    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "status_changes")
          .flatMap((event) => event.changes)
          .find((status) => status.providerSessionId === "thread-0"),
      ).toMatchObject({
        activity: "working",
        runtimeAttachment: "loaded",
        source: "bridgeRuntime",
        confidence: "authoritative",
      }),
    );
    fixture.handler.close();
  });

  it.each(["reconciling", "blocked", "unavailable"] as const)(
    "does not project an explicit %s control state as Working",
    async (controlState) => {
      const codex = codexSeed(0, `thread-${controlState}`);
      const fixture = createFixture(
        [codex],
        async () => history(`thread-${controlState}`),
        {
          daemonMode: true,
          initialExternalCodexMonitors: 0,
        },
      );
      fixture.runtime.listRuntimeConversationStates = () => [
        {
          bridgeSessionId: `runtime-${controlState}`,
          provider: "codex",
          providerSessionId: `thread-${controlState}`,
          projectPath: "/project/0",
          processStatus: "starting",
          executionHost: "unknown",
          controlState,
          authorityGeneration: `authority-${controlState}`,
          observedAt: "2026-07-30T00:00:02.000Z",
        },
      ];
      const client = {};

      await fixture.handler.handle(
        subscribeMessage(),
        context(client, fixture.runtime),
      );

      await vi.waitFor(() =>
        expect(
          events(fixture.sent, client, "status_changes")
            .flatMap((event) => event.changes)
            .find(
              (status) => status.providerSessionId === `thread-${controlState}`,
            ),
        ).toMatchObject({
          activity: "unknown",
          source: "bridgeRuntime",
          executionHost: "unknown",
          controlState,
          authorityGeneration: `authority-${controlState}`,
        }),
      );
      fixture.handler.close();
    },
  );

  it("discovers a running thread outside the hot set and rewarms it without rescanning after reconnect", async () => {
    const seeds = Array.from({ length: 12 }, (_, index) =>
      codexSeed(index, `thread-${index}`),
    );
    const inspected: string[] = [];
    const observed: string[] = [];
    const fixture = createFixture(
      seeds,
      async (target) => history(target.providerSessionId),
      {
        initialExternalCodexMonitors: 1,
        maxExternalCodexMonitors: 4,
        inspectCodexThread: async (threadId) => {
          inspected.push(threadId);
          return threadId === "thread-11"
            ? {
                state: "running" as const,
                observedAt: "2026-07-30T00:00:02.000Z",
              }
            : { state: "idle" as const };
        },
        observeCodexThread: async (threadId) => {
          observed.push(threadId);
          return {
            snapshot:
              threadId === "thread-11"
                ? {
                    state: "running" as const,
                    observedAt: "2026-07-30T00:00:02.000Z",
                  }
                : { state: "idle" as const },
            refreshNow: async () => {},
            close: () => {},
          };
        },
      },
    );

    const firstClient = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(firstClient, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, firstClient, "status_changes")
          .flatMap((event) => event.changes)
          .some(
            (status) =>
              status.providerSessionId === "thread-11" &&
              status.activity === "working",
          ),
      ).toBe(true),
    );
    expect(inspected).toHaveLength(12);
    expect(observed).toContain("thread-11");

    fixture.handler.disconnect(firstClient);
    inspected.length = 0;
    observed.length = 0;
    const secondClient = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(secondClient, fixture.runtime),
    );
    await vi.waitFor(() => expect(observed).toContain("thread-11"));
    expect(inspected).toHaveLength(0);
    fixture.handler.close();
  });

  it("rejects a stale discovery result after disconnect and rescans for the next client", async () => {
    let resolveFirstInspection:
      | ((snapshot: { state: "running"; observedAt: string }) => void)
      | undefined;
    const firstInspection = new Promise<{
      state: "running";
      observedAt: string;
    }>((resolve) => {
      resolveFirstInspection = resolve;
    });
    let inspections = 0;
    const fixture = createFixture(
      [codexSeed(0, "thread-0")],
      async () => history("thread-0"),
      {
        initialExternalCodexMonitors: 1,
        inspectCodexThread: async () => {
          inspections += 1;
          return inspections === 1
            ? firstInspection
            : {
                state: "idle" as const,
                observedAt: "2026-07-30T00:00:02.000Z",
              };
        },
        observeCodexThread: async () => ({
          snapshot: {
            state: "idle" as const,
            observedAt: "2026-07-30T00:00:02.000Z",
          },
          refreshNow: async () => {},
          close: () => {},
        }),
      },
    );
    const firstClient = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(firstClient, fixture.runtime),
    );
    await vi.waitFor(() => expect(inspections).toBe(1));
    fixture.handler.disconnect(firstClient);

    const secondClient = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(secondClient, fixture.runtime),
    );
    resolveFirstInspection!({
      state: "running",
      observedAt: "2026-07-30T00:00:01.000Z",
    });
    await vi.waitFor(() => expect(inspections).toBeGreaterThanOrEqual(2));
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, secondClient, "sync_complete").length,
      ).toBeGreaterThanOrEqual(1),
    );
    const latest = events(fixture.sent, secondClient, "status_changes")
      .flatMap((event) => event.changes)
      .filter((status) => status.providerSessionId === "thread-0")
      .at(-1);
    expect(latest?.activity).not.toBe("working");
    fixture.handler.close();
  });

  it("does not resurrect a completed external thread on the next catalog refresh", async () => {
    type HandlerOptions = NonNullable<
      ConstructorParameters<typeof ConversationSyncV2FeatureHandler>[1]
    >;
    type ObserverCallback = Parameters<
      NonNullable<HandlerOptions["observeCodexThread"]>
    >[1];
    let callback: ObserverCallback | undefined;
    const runningAt = new Date(Date.now() - 2_000).toISOString();
    const idleAt = new Date(Date.now() - 1_000).toISOString();
    const fixture = createFixture(
      [codexSeed(0, "thread-terminal")],
      async () => history("thread-terminal"),
      {
        initialExternalCodexMonitors: 1,
        inspectCodexThread: async () => ({
          state: "running",
          runningEvidence: "lifecycle",
          observedAt: runningAt,
        }),
        observeCodexThread: async (_threadId, onEvent) => {
          callback = onEvent;
          return {
            snapshot: {
              state: "running" as const,
              runningEvidence: "lifecycle" as const,
              observedAt: runningAt,
            },
            refreshNow: async () => {},
            close: () => {},
          };
        },
      },
    );
    const client = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "status_changes")
          .flatMap((event) => event.changes)
          .some(
            (status) =>
              status.providerSessionId === "thread-terminal" &&
              status.activity === "working",
          ),
      ).toBe(true),
    );

    callback!({
      kind: "state",
      state: "idle",
      outcome: "completed",
      timestamp: idleAt,
    });
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "status_changes")
          .flatMap((event) => event.changes)
          .filter((status) => status.providerSessionId === "thread-terminal")
          .at(-1)?.activity,
      ).not.toBe("working"),
    );

    const beginCount = events(fixture.sent, client, "sync_begin").length;
    fixture.handler.sessionCatalogChanged();
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_begin").length).toBeGreaterThan(
        beginCount,
      ),
    );
    const latest = events(fixture.sent, client, "status_changes")
      .flatMap((event) => event.changes)
      .filter((status) => status.providerSessionId === "thread-terminal")
      .at(-1);
    expect(latest?.activity).not.toBe("working");
    const internal = fixture.handler as unknown as {
      externalCodexDiscoveredRunning: Map<string, unknown>;
    };
    expect(internal.externalCodexDiscoveredRunning.has("thread-terminal")).toBe(
      false,
    );
    fixture.handler.close();
  });

  it("clears an unmonitored Working state when rediscovery observes idle", async () => {
    const seeds = Array.from({ length: 8 }, (_, index) =>
      codexSeed(index, `thread-${index}`),
    );
    const runningAt = new Date(Date.now() - 2_000).toISOString();
    const idleAt = new Date(Date.now() - 1_000).toISOString();
    let idleThreadId: string | undefined;
    const fixture = createFixture(
      seeds,
      async (target) => history(target.providerSessionId),
      {
        initialExternalCodexMonitors: 1,
        maxExternalCodexMonitors: 4,
        inspectCodexThread: async (threadId) =>
          threadId === idleThreadId
            ? { state: "idle" as const, observedAt: idleAt }
            : {
                state: "running" as const,
                runningEvidence: "lifecycle" as const,
                observedAt: runningAt,
              },
        observeCodexThread: async () => ({
          snapshot: {
            state: "running" as const,
            runningEvidence: "lifecycle" as const,
            observedAt: runningAt,
          },
          refreshNow: async () => {},
          close: () => {},
        }),
      },
    );
    const client = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "status_changes")
          .flatMap((event) => event.changes)
          .filter((status) => status.activity === "working"),
      ).toHaveLength(8),
    );
    const internal = fixture.handler as unknown as {
      externalCodexMonitors: Map<string, unknown>;
      externalCodexDiscoveredRunning: Map<string, unknown>;
      externalCodexDiscoveryCompletedAt: number;
    };
    idleThreadId = [...internal.externalCodexDiscoveredRunning.keys()].find(
      (threadId) => !internal.externalCodexMonitors.has(threadId),
    );
    expect(idleThreadId).toBeDefined();

    internal.externalCodexDiscoveryCompletedAt = 0;
    const beginCount = events(fixture.sent, client, "sync_begin").length;
    fixture.handler.sessionCatalogChanged();
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_begin").length).toBeGreaterThan(
        beginCount,
      ),
    );
    const latest = events(fixture.sent, client, "status_changes")
      .flatMap((event) => event.changes)
      .filter((status) => status.providerSessionId === idleThreadId)
      .at(-1);
    expect(latest?.activity).not.toBe("working");
    expect(internal.externalCodexDiscoveredRunning.has(idleThreadId!)).toBe(
      false,
    );
    fixture.handler.close();
  });

  it("does not promote stale response-only rollout activity to Working", async () => {
    const fixture = createFixture(
      [codexSeed(0, "thread-stale")],
      async () => history("thread-stale"),
      {
        initialExternalCodexMonitors: 1,
        inspectCodexThread: async () => ({
          state: "running",
          runningEvidence: "activity",
          observedAt: "2020-01-01T00:00:00.000Z",
        }),
        observeCodexThread: async () => ({
          snapshot: {
            state: "running",
            runningEvidence: "activity",
            observedAt: "2020-01-01T00:00:00.000Z",
          },
          refreshNow: async () => {},
          close: () => {},
        }),
      },
    );
    const client = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "sync_complete").length,
      ).toBeGreaterThanOrEqual(1),
    );
    const latest = events(fixture.sent, client, "status_changes")
      .flatMap((event) => event.changes)
      .find((status) => status.providerSessionId === "thread-stale");
    expect(latest?.activity).not.toBe("working");
    fixture.handler.close();
  });

  it("retains all discovered Working states when the live-monitor cap is full", async () => {
    const seeds = Array.from({ length: 8 }, (_, index) =>
      codexSeed(index, `thread-${index}`),
    );
    const fixture = createFixture(
      seeds,
      async (target) => history(target.providerSessionId),
      {
        initialExternalCodexMonitors: 1,
        maxExternalCodexMonitors: 4,
        inspectCodexThread: async () => ({
          state: "running",
          runningEvidence: "lifecycle",
          observedAt: "2026-07-30T00:00:00.000Z",
        }),
        observeCodexThread: async () => ({
          snapshot: {
            state: "running",
            runningEvidence: "lifecycle",
            observedAt: "2026-07-30T00:00:00.000Z",
          },
          refreshNow: async () => {},
          close: () => {},
        }),
      },
    );
    const client = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "sync_complete").length,
      ).toBeGreaterThanOrEqual(1),
    );
    const internal = fixture.handler as unknown as {
      externalCodexMonitors: Map<string, unknown>;
      externalCodexStatuses: Map<string, ConversationSyncStatus>;
    };
    expect(internal.externalCodexMonitors.size).toBeLessThanOrEqual(4);
    expect(
      [...internal.externalCodexStatuses.values()].filter(
        (status) => status.activity === "working",
      ),
    ).toHaveLength(8);
    fixture.handler.close();
  });

  it("bounds the external live-message buffer by bytes as well as count", async () => {
    type HandlerOptions = NonNullable<
      ConstructorParameters<typeof ConversationSyncV2FeatureHandler>[1]
    >;
    type ObserverCallback = Parameters<
      NonNullable<HandlerOptions["observeCodexThread"]>
    >[1];
    let callback: ObserverCallback | undefined;
    const fixture = createFixture(
      [codexSeed(0, "thread-0")],
      async () => history("thread-0"),
      {
        initialExternalCodexMonitors: 1,
        observeCodexThread: async (_threadId, onEvent) => {
          callback = onEvent;
          return {
            snapshot: { state: "running" as const },
            refreshNow: async () => {},
            close: () => {},
          };
        },
      },
    );
    const client = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() => expect(callback).toBeDefined());
    for (let index = 0; index < 4; index += 1) {
      callback!({
        kind: "message",
        itemKey: `assistant:large-${index}`,
        timestamp: new Date().toISOString(),
        message: {
          type: "assistant",
          messageUuid: `large-${index}`,
          message: {
            id: `large-${index}`,
            role: "assistant",
            model: "codex",
            content: [{ type: "text", text: "x".repeat(220 * 1024) }],
          },
        },
      });
    }
    const internal = fixture.handler as unknown as {
      externalCodexLiveMessages: Map<string, Map<string, { bytes: number }>>;
      externalCodexLiveBytes: Map<string, number>;
    };
    const key = "codex\0thread-0";
    expect(
      internal.externalCodexLiveMessages.get(key)?.size,
    ).toBeLessThanOrEqual(2);
    expect(internal.externalCodexLiveBytes.get(key)).toBeLessThanOrEqual(
      512 * 1024,
    );
    fixture.handler.close();
  });

  it("uses the watchdog app-server snapshot before an explicit daemon runtime overlay", async () => {
    const providerStatus: ConversationSyncStatus = {
      provider: "codex",
      providerSessionId: "thread-watchdog",
      activity: "working",
      attention: "question",
      result: "none",
      runtimeAttachment: "loaded",
      source: "appServer",
      confidence: "authoritative",
      observedAt: "2026-07-30T03:00:02.000Z",
      executionHost: "desktopAppServer",
      activeTurnId: "turn-desktop",
      controlState: "steerable",
      authorityGeneration: "authority-desktop",
    };
    const statusReader = vi.fn(
      async () => new Map([["codex\0thread-watchdog", providerStatus]]),
    );
    let runtimeStates: LocalFeatureRuntimeConversationState[] = [
      {
        bridgeSessionId: "adopted-without-authority",
        provider: "codex",
        providerSessionId: "thread-watchdog",
        projectPath: "/project/0",
        processStatus: "running",
        observedAt: "2026-07-30T03:00:03.000Z",
      },
    ];
    const fixture = createFixture(
      [codexSeed(0, "thread-watchdog")],
      async () => history("thread-watchdog"),
      {
        daemonMode: true,
        statusReader,
        statusWatchdogMs: 10,
      },
    );
    fixture.runtime.listRuntimeConversationStates = () => runtimeStates;
    const client = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    const internal = fixture.handler as unknown as {
      catalog: Map<string, { status: ConversationSyncStatus }>;
      refreshStatuses(): Promise<void>;
    };

    await vi.waitFor(() => expect(statusReader).toHaveBeenCalled());
    await vi.waitFor(() =>
      expect(
        internal.catalog.get("codex\0thread-watchdog")?.status,
      ).toMatchObject({
        source: "appServer",
        executionHost: "desktopAppServer",
        activeTurnId: "turn-desktop",
        controlState: "steerable",
        authorityGeneration: "authority-desktop",
      }),
    );

    runtimeStates = [
      {
        bridgeSessionId: "bridge-owned",
        provider: "codex",
        providerSessionId: "thread-watchdog",
        projectPath: "/project/0",
        processStatus: "running",
        executionHost: "bridge",
        activeTurnId: "turn-bridge",
        controlState: "writable",
        authorityGeneration: "authority-bridge",
        observedAt: "2026-07-30T03:00:04.000Z",
      },
    ];
    await internal.refreshStatuses();
    expect(
      internal.catalog.get("codex\0thread-watchdog")?.status,
    ).toMatchObject({
      source: "bridgeRuntime",
      executionHost: "bridge",
      activeTurnId: "turn-bridge",
      controlState: "writable",
      authorityGeneration: "authority-bridge",
    });
    fixture.handler.close();
  });

  it("publishes replacement runtime authority immediately without waiting for a provider message", async () => {
    let runtimeStates: LocalFeatureRuntimeConversationState[] = [
      {
        bridgeSessionId: "runtime-reconciling",
        provider: "codex",
        providerSessionId: "thread-runtime-lifecycle",
        projectPath: "/project/0",
        processStatus: "starting",
        executionHost: "unknown",
        controlState: "reconciling",
        authorityGeneration: "authority-old",
        observedAt: "2026-08-02T00:00:00.000Z",
      },
    ];
    const fixture = createFixture(
      [codexSeed(0, "thread-runtime-lifecycle")],
      async () => history("thread-runtime-lifecycle"),
      {
        daemonMode: true,
        initialExternalCodexMonitors: 0,
      },
      {
        getProviderSessionId: () => "thread-runtime-lifecycle",
        listRuntimeConversationStates: () => runtimeStates,
      },
    );
    const client = {};
    const session: LocalFeatureSession = {
      id: "runtime-current",
      provider: "codex",
      process: {},
      projectPath: "/project/0",
    };
    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );
    const initialCatalogReads = fixture.catalogReader.mock.calls.length;

    runtimeStates = [
      {
        bridgeSessionId: "runtime-current",
        provider: "codex",
        providerSessionId: "thread-runtime-lifecycle",
        projectPath: "/project/0",
        processStatus: "running",
        executionHost: "desktopAppServer",
        activeTurnId: "turn-desktop",
        controlState: "steerable",
        authorityGeneration: "authority-current",
        observedAt: "2026-08-02T00:00:01.000Z",
      },
    ];
    fixture.handler.runtimeSessionChanged(session);

    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "status_changes")
          .flatMap((event) => event.changes)
          .find(
            (status) =>
              status.providerSessionId === "thread-runtime-lifecycle" &&
              status.authorityGeneration === "authority-current",
          ),
      ).toMatchObject({
        activity: "working",
        executionHost: "desktopAppServer",
        activeTurnId: "turn-desktop",
        controlState: "steerable",
        authorityGeneration: "authority-current",
      }),
    );
    expect(fixture.catalogReader).toHaveBeenCalledTimes(initialCatalogReads);

    runtimeStates = [
      {
        bridgeSessionId: "runtime-reopened",
        provider: "codex",
        providerSessionId: "thread-runtime-lifecycle",
        projectPath: "/project/0",
        processStatus: "idle",
        executionHost: "unknown",
        controlState: "writable",
        authorityGeneration: "authority-reopened",
        observedAt: "2026-08-02T00:00:02.000Z",
      },
    ];
    fixture.handler.runtimeSessionChanged(session);

    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "status_changes")
          .flatMap((event) => event.changes)
          .find(
            (status) =>
              status.providerSessionId === "thread-runtime-lifecycle" &&
              status.authorityGeneration === "authority-reopened",
          ),
      ).toMatchObject({
        activity: "idle",
        controlState: "writable",
        authorityGeneration: "authority-reopened",
      }),
    );
    expect(fixture.catalogReader).toHaveBeenCalledTimes(initialCatalogReads);
    fixture.handler.close();
  });

  it("marks a failed app-server watchdog read unavailable without inventing ownership", async () => {
    const initial = codexSeed(0, "thread-status-failure");
    initial.status = {
      ...initial.status,
      activity: "working",
      runtimeAttachment: "loaded",
      confidence: "authoritative",
      executionHost: "desktopAppServer",
      activeTurnId: "turn-before-failure",
      controlState: "steerable",
      authorityGeneration: "authority-before-failure",
    };
    const failure = new Error("app-server status unavailable");
    const fixture = createFixture(
      [initial],
      async () => history("thread-status-failure"),
      {
        daemonMode: true,
        statusReader: vi.fn(async () => {
          throw failure;
        }),
      },
    );
    const client = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );
    const internal = fixture.handler as unknown as {
      catalog: Map<string, { status: ConversationSyncStatus }>;
      refreshStatuses(): Promise<void>;
    };

    await expect(internal.refreshStatuses()).rejects.toBe(failure);
    expect(
      internal.catalog.get("codex\0thread-status-failure")?.status,
    ).toMatchObject({
      activity: "working",
      attention: "none",
      source: "appServer",
      confidence: "unknown",
      executionHost: "desktopAppServer",
      controlState: "unavailable",
    });
    expect(
      internal.catalog.get("codex\0thread-status-failure")?.status.activeTurnId,
    ).toBe("turn-before-failure");
    expect(
      internal.catalog.get("codex\0thread-status-failure")?.status
        .authorityGeneration,
    ).toBeUndefined();
    fixture.handler.close();
  });

  it("rejects a late status snapshot from an older authority generation", async () => {
    let resolveStatus:
      ((value: Map<string, ConversationSyncStatus>) => void) | undefined;
    const pendingStatus = new Promise<Map<string, ConversationSyncStatus>>(
      (resolve) => {
        resolveStatus = resolve;
      },
    );
    const statusReader = vi.fn(() => pendingStatus);
    const fixture = createFixture(
      [codexSeed(0, "thread-late-status")],
      async () => history("thread-late-status"),
      { daemonMode: true, statusReader },
    );
    const client = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "sync_complete").length,
      ).toBeGreaterThanOrEqual(1),
    );
    const internal = fixture.handler as unknown as {
      catalog: Map<string, { status: ConversationSyncStatus }>;
      refreshStatuses(): Promise<void>;
    };
    const refresh = internal.refreshStatuses();
    await vi.waitFor(() => expect(statusReader).toHaveBeenCalledTimes(1));
    internal.catalog.get("codex\0thread-late-status")!.status = {
      provider: "codex",
      providerSessionId: "thread-late-status",
      activity: "working",
      attention: "none",
      result: "none",
      runtimeAttachment: "loaded",
      source: "appServer",
      confidence: "authoritative",
      observedAt: "2026-07-30T04:00:02.000Z",
      executionHost: "desktopAppServer",
      activeTurnId: "turn-new",
      controlState: "steerable",
      authorityGeneration: "authority-new",
    };
    resolveStatus!(
      new Map([
        [
          "codex\0thread-late-status",
          {
            provider: "codex",
            providerSessionId: "thread-late-status",
            activity: "idle",
            attention: "none",
            result: "none",
            runtimeAttachment: "loaded",
            source: "appServer",
            confidence: "authoritative",
            observedAt: "2026-07-30T04:00:01.000Z",
            executionHost: "desktopAppServer",
            controlState: "steerable",
            authorityGeneration: "authority-old",
          },
        ],
      ]),
    );
    await refresh;
    expect(
      internal.catalog.get("codex\0thread-late-status")?.status,
    ).toMatchObject({
      activity: "working",
      activeTurnId: "turn-new",
      authorityGeneration: "authority-new",
    });
    fixture.handler.close();
  });

  it("never creates or scans legacy rollout monitors in daemon mode", async () => {
    const inspectCodexThread = vi.fn(async () => ({
      state: "running" as const,
      observedAt: "2026-07-30T05:00:00.000Z",
    }));
    const observeCodexThread = vi.fn(async () => ({
      snapshot: { state: "running" as const },
      refreshNow: async () => {},
      close: () => {},
    }));
    const fixture = createFixture(
      [codexSeed(0, "thread-daemon-no-jsonl")],
      async () => history("thread-daemon-no-jsonl"),
      {
        daemonMode: true,
        initialExternalCodexMonitors: 1,
        inspectCodexThread,
        observeCodexThread,
      },
    );
    const client = {};
    const subscription = subscribeMessage();
    await fixture.handler.handle(
      subscription,
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );
    await fixture.handler.handle(
      {
        type: "conversation_sync_focus",
        protocolVersion: 2,
        requestId: "focus-daemon-no-jsonl",
        subscriptionId: subscription.requestId,
        focused: {
          provider: "codex",
          providerSessionId: "thread-daemon-no-jsonl",
        },
      },
      context(client, fixture.runtime),
    );
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(inspectCodexThread).not.toHaveBeenCalled();
    expect(observeCodexThread).not.toHaveBeenCalled();
    const internal = fixture.handler as unknown as {
      externalCodexMonitors: Map<string, unknown>;
      externalCodexMonitorFlights: Map<string, unknown>;
    };
    expect(internal.externalCodexMonitors.size).toBe(0);
    expect(internal.externalCodexMonitorFlights.size).toBe(0);
    fixture.handler.close();
  });

  it("keeps a live item in place when a later delta updates the same key", () => {
    const fixture = createFixture(
      [codexSeed(0, "thread-live-order")],
      async () => history("thread-live-order"),
    );
    const internal = fixture.handler as unknown as {
      rememberExternalCodexMessage(
        target: { provider: "codex"; providerSessionId: string },
        event: {
          kind: "message";
          itemKey: string;
          timestamp: string;
          message: ServerMessage;
        },
        observedAt: string,
      ): void;
      externalCodexLiveMessages: Map<
        string,
        Map<string, { message: ServerMessage }>
      >;
    };
    const target = {
      provider: "codex" as const,
      providerSessionId: "thread-live-order",
    };
    const liveMessage = (id: string, text: string): ServerMessage => ({
      type: "assistant",
      messageUuid: id,
      message: {
        id,
        role: "assistant",
        model: "codex",
        content: [{ type: "text", text }],
      },
    });
    internal.rememberExternalCodexMessage(
      target,
      {
        kind: "message",
        itemKey: "item-a",
        timestamp: "2026-07-30T06:00:00.000Z",
        message: liveMessage("a", "a-1"),
      },
      "2026-07-30T06:00:00.000Z",
    );
    internal.rememberExternalCodexMessage(
      target,
      {
        kind: "message",
        itemKey: "item-b",
        timestamp: "2026-07-30T06:00:01.000Z",
        message: liveMessage("b", "b-1"),
      },
      "2026-07-30T06:00:01.000Z",
    );
    internal.rememberExternalCodexMessage(
      target,
      {
        kind: "message",
        itemKey: "item-a",
        timestamp: "2026-07-30T06:00:02.000Z",
        message: liveMessage("a", "a-2"),
      },
      "2026-07-30T06:00:02.000Z",
    );

    const messages = internal.externalCodexLiveMessages.get(
      "codex\0thread-live-order",
    );
    expect([...messages!.keys()]).toEqual(["item-a", "item-b"]);
    expect(JSON.stringify(messages!.get("item-a")?.message)).toContain("a-2");
    fixture.handler.close();
  });

  it("reuses one standalone app-server for concurrent hot-window reads", async () => {
    const sent: ConversationSyncServerMessage[] = [];
    const listThreadTurns = vi.fn(async () => ({
      data: [],
      nextCursor: null,
    }));
    const listThreadItems = vi.fn(async () => ({
      data: [],
      nextCursor: null,
    }));
    const stop = vi.fn();
    const standalone = {
      listThreadTurns,
      listThreadItems,
      stop,
    } as unknown as CodexProcess;
    const createStandaloneCodexProcess = vi.fn(async () => standalone);
    const runtime: LocalFeatureRuntime = {
      bridgeInstanceId: "bridge-1",
      codexSourceId: "source-1",
      getSession: () => undefined,
      getCodexThreadId: () => undefined,
      getActiveCodexProcess: () => null,
      createStandaloneCodexProcess,
      send(_client, message) {
        sent.push(message as ConversationSyncServerMessage);
      },
      isClientOpen: () => true,
      supports: (_client, capability) =>
        capability === CONVERSATION_SYNC_V2_CAPABILITY,
    };
    const handler = new ConversationSyncV2FeatureHandler(runtime, {
      catalogReader: async () => [
        codexSeed(0, "thread-0"),
        codexSeed(1, "thread-1"),
      ],
      statusReader: async () => new Map(),
      observeCodexThread: async () => ({
        snapshot: { state: "idle" as const },
        refreshNow: async () => {},
        close: () => {},
      }),
      initialExternalCodexMonitors: 2,
      statusWatchdogMs: 60_000,
      coldReconcileMs: 60_000,
    });
    const client = {};
    const subscription = subscribeMessage();
    await handler.handle(subscription, context(client, runtime));
    await vi.waitFor(() =>
      expect(sent.some((message) => message.event === "sync_complete")).toBe(
        true,
      ),
    );
    await handler.handle(
      {
        type: "conversation_turns_page",
        protocolVersion: 2,
        requestId: "shared-turns-page",
        subscriptionId: subscription.requestId,
        provider: "codex",
        providerSessionId: "thread-0",
        limit: 5,
        sortDirection: "desc",
        itemsView: "summary",
      },
      context(client, runtime),
    );
    await handler.handle(
      {
        type: "conversation_items_page",
        protocolVersion: 2,
        requestId: "shared-items-page",
        subscriptionId: subscription.requestId,
        provider: "codex",
        providerSessionId: "thread-0",
        turnId: "turn-current",
        limit: 50,
        sortDirection: "asc",
      },
      context(client, runtime),
    );

    expect(listThreadTurns).toHaveBeenCalledTimes(3);
    expect(listThreadItems).toHaveBeenCalledTimes(1);
    expect(
      listThreadTurns.mock.calls.every(
        ([, options]) => options?.timeoutMs === 10_000,
      ),
    ).toBe(true);
    expect(listThreadItems.mock.calls[0]?.[1]).toMatchObject({
      timeoutMs: 10_000,
    });
    expect(createStandaloneCodexProcess).toHaveBeenCalledTimes(1);
    handler.close();
    expect(stop).toHaveBeenCalledTimes(1);
  });

  it("keeps catalog, status, and hot history on one private read app-server", async () => {
    const sent: ConversationSyncServerMessage[] = [];
    const listThreads = vi.fn(async () => ({
      data: [],
      nextCursor: null,
    }));
    const listThreadTurns = vi.fn(async () => ({
      data: [],
      nextCursor: null,
    }));
    const stop = vi.fn();
    const standalone = {
      isRunning: true,
      listThreads,
      listThreadTurns,
      stop,
    } as unknown as CodexProcess;
    const createStandaloneCodexProcess = vi.fn(async () => standalone);
    const runtime: LocalFeatureRuntime = {
      bridgeInstanceId: "bridge-1",
      codexSourceId: "source-1",
      getSession: () => undefined,
      getCodexThreadId: () => undefined,
      getActiveCodexProcess: () => null,
      createStandaloneCodexProcess,
      send(_client, message) {
        sent.push(message as ConversationSyncServerMessage);
      },
      isClientOpen: () => true,
      supports: (_client, capability) =>
        capability === CONVERSATION_SYNC_V2_CAPABILITY ||
        capability === APP_SERVER_STATUS_CAPABILITY,
    };
    let withSharedRead!: <T>(
      operation: (process: CodexProcess) => Promise<T>,
    ) => Promise<T>;
    const seed = codexSeed(0, "thread-private-read");
    const handler = new ConversationSyncV2FeatureHandler(runtime, {
      catalogReader: () =>
        withSharedRead(async (process) => {
          await process.listThreads({ limit: 1 });
          return [seed];
        }),
      statusReader: () =>
        withSharedRead(async (process) => {
          await process.listThreads({ limit: 1 });
          return new Map([["codex\0thread-private-read", seed.status]]);
        }),
      inspectCodexThread: async () => null,
      daemonMode: false,
      statusWatchdogMs: 60_000,
      coldReconcileMs: 60_000,
    });
    withSharedRead = (
      handler as unknown as {
        withSharedCodexReadProcess<T>(
          operation: (process: CodexProcess) => Promise<T>,
        ): Promise<T>;
      }
    ).withSharedCodexReadProcess.bind(handler);

    const client = {};
    await handler.handle(subscribeMessage(), context(client, runtime));
    await vi.waitFor(() =>
      expect(sent.some((message) => message.event === "sync_complete")).toBe(
        true,
      ),
    );
    await (
      handler as unknown as { refreshStatuses(): Promise<void> }
    ).refreshStatuses();

    expect(listThreads).toHaveBeenCalledTimes(2);
    expect(listThreadTurns).toHaveBeenCalledTimes(1);
    expect(createStandaloneCodexProcess).toHaveBeenCalledTimes(1);
    handler.close();
    expect(stop).toHaveBeenCalledTimes(1);
  });

  it("falls back to bounded turns/list on the shared reader when items/list is unavailable", async () => {
    const sent: ConversationSyncServerMessage[] = [];
    const listThreadTurns = vi.fn(async () => ({
      data: [
        {
          id: "turn-current",
          items: [
            {
              type: "userMessage",
              id: "user-current",
              content: [{ type: "inputText", text: "prompt" }],
            },
            {
              type: "agentMessage",
              id: "assistant-current",
              text: "answer",
            },
          ],
        },
      ],
      nextCursor: null,
    }));
    const listThreadItems = vi.fn(async () => {
      throw new Error("Method not found");
    });
    const stop = vi.fn();
    const standalone = {
      isRunning: true,
      listThreadTurns,
      listThreadItems,
      stop,
    } as unknown as CodexProcess;
    const createStandaloneCodexProcess = vi.fn(async () => standalone);
    const runtime: LocalFeatureRuntime = {
      bridgeInstanceId: "bridge-1",
      codexSourceId: "source-1",
      getSession: () => undefined,
      getCodexThreadId: () => undefined,
      getActiveCodexProcess: () => null,
      createStandaloneCodexProcess,
      send(_client, message) {
        sent.push(message as ConversationSyncServerMessage);
      },
      isClientOpen: () => true,
      supports: (_client, capability) =>
        capability === CONVERSATION_SYNC_V2_CAPABILITY,
    };
    const handler = new ConversationSyncV2FeatureHandler(runtime, {
      catalogReader: async () => [],
      statusReader: async () => new Map(),
      inspectCodexThread: async () => null,
      statusWatchdogMs: 60_000,
      coldReconcileMs: 60_000,
    });
    const client = {};
    const subscription = subscribeMessage();
    await handler.handle(subscription, context(client, runtime));
    await vi.waitFor(() =>
      expect(sent.some((message) => message.event === "sync_complete")).toBe(
        true,
      ),
    );

    await handler.handle(
      {
        type: "conversation_items_page",
        protocolVersion: 2,
        requestId: "fallback-items-page",
        subscriptionId: subscription.requestId,
        provider: "codex",
        providerSessionId: "thread-current",
        turnId: "turn-current",
        limit: 50,
        sortDirection: "asc",
      },
      context(client, runtime),
    );

    const response = sent.find(
      (message) =>
        message.event === "items_page_response" &&
        message.requestId === "fallback-items-page",
    );
    expect(response).toMatchObject({
      event: "items_page_response",
      turnId: "turn-current",
      nextCursor: null,
    });
    expect(listThreadItems).toHaveBeenCalledTimes(1);
    expect(listThreadTurns).toHaveBeenCalledTimes(1);
    expect(createStandaloneCodexProcess).toHaveBeenCalledTimes(1);
    handler.close();
    expect(stop).toHaveBeenCalledTimes(1);
  });

  it("recreates the shared app-server after its process exits", async () => {
    let firstRunning = true;
    const firstStop = vi.fn();
    const first = {
      get isRunning() {
        return firstRunning;
      },
      listThreadTurns: vi.fn(async () => {
        firstRunning = false;
        throw new Error("app-server exited");
      }),
      stop: firstStop,
    } as unknown as CodexProcess;
    const secondStop = vi.fn();
    const second = {
      isRunning: true,
      listThreadTurns: vi.fn(async () => ({
        data: [],
        nextCursor: null,
      })),
      stop: secondStop,
    } as unknown as CodexProcess;
    const createStandaloneCodexProcess = vi
      .fn()
      .mockResolvedValueOnce(first)
      .mockResolvedValueOnce(second);
    const runtime: LocalFeatureRuntime = {
      bridgeInstanceId: "bridge-1",
      codexSourceId: "source-1",
      getSession: () => undefined,
      getCodexThreadId: () => undefined,
      getActiveCodexProcess: () => null,
      createStandaloneCodexProcess,
      send: () => {},
      isClientOpen: () => true,
      supports: (_client, capability) =>
        capability === CONVERSATION_SYNC_V2_CAPABILITY,
    };
    const handler = new ConversationSyncV2FeatureHandler(runtime, {
      catalogReader: async () => [],
      statusReader: async () => new Map(),
      inspectCodexThread: async () => null,
      statusWatchdogMs: 60_000,
      coldReconcileMs: 60_000,
    });
    const internal = handler as unknown as {
      readRecentConversationHistory(target: {
        provider: "codex";
        providerSessionId: string;
      }): Promise<unknown>;
    };

    await expect(
      internal.readRecentConversationHistory({
        provider: "codex",
        providerSessionId: "thread-0",
      }),
    ).rejects.toThrow("app-server exited");
    await expect(
      internal.readRecentConversationHistory({
        provider: "codex",
        providerSessionId: "thread-0",
      }),
    ).resolves.toBeDefined();
    expect(createStandaloneCodexProcess).toHaveBeenCalledTimes(2);
    expect(firstStop).toHaveBeenCalled();
    handler.close();
    expect(secondStop).toHaveBeenCalledTimes(1);
  });

  it("does not label an in-flight stale snapshot with a newer live revision", async () => {
    let resolveFirstRead: ((messages: ServerMessage[]) => void) | undefined;
    const firstRead = new Promise<ServerMessage[]>((resolve) => {
      resolveFirstRead = resolve;
    });
    let readCount = 0;
    const historyReader = vi.fn(async (target) => {
      readCount += 1;
      if (readCount === 1) return firstRead;
      return history(`${target.providerSessionId}-new`);
    });
    const fixture = createFixture([seed(0)], historyReader);
    const client = {};
    fixture.runtime.getProviderSessionId = () => "session-0";
    const session: LocalFeatureSession = {
      id: "runtime-0",
      provider: "claude",
      process: {},
      projectPath: "/project/0",
    };

    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() => expect(historyReader).toHaveBeenCalledTimes(1));

    for (let index = 0; index < 100; index += 1) {
      fixture.handler.sessionMessage(session, {
        type: "assistant",
        messageUuid: `assistant-live-${index}`,
        message: {
          id: `assistant-live-${index}`,
          role: "assistant",
          model: "test",
          content: [{ type: "text", text: `new live content ${index}` }],
        },
      });
    }
    resolveFirstRead!(history("session-0-old"));

    await vi.waitFor(() => expect(historyReader).toHaveBeenCalledTimes(2), {
      timeout: 3_000,
    });
    await vi.waitFor(
      () =>
        expect(
          events(fixture.sent, client, "sync_complete").length,
        ).toBeGreaterThanOrEqual(2),
      { timeout: 3_000 },
    );
    const revisions = new Set(
      events(fixture.sent, client, "timeline_page").map(
        (event) => event.revision,
      ),
    );
    expect(revisions.size).toBeGreaterThanOrEqual(2);
    await new Promise((resolve) => setTimeout(resolve, 150));
    expect(historyReader).toHaveBeenCalledTimes(2);
    expect(fixture.catalogReader).toHaveBeenCalledTimes(1);
    fixture.handler.close();
  });

  it("pushes Need You state without rereading conversation content", async () => {
    const historyReader = vi.fn(async (target) =>
      history(target.providerSessionId),
    );
    const fixture = createFixture([seed(0)], historyReader);
    const client = {};
    fixture.runtime.getProviderSessionId = () => "session-0";
    let pendingApproval = false;
    fixture.runtime.listRuntimeConversationStates = () => [
      {
        bridgeSessionId: "runtime-0",
        provider: "claude",
        providerSessionId: "session-0",
        projectPath: "/project/0",
        processStatus: pendingApproval ? "waiting_approval" : "idle",
        ...(pendingApproval
          ? {
              pendingAttention: {
                requestId: "approval-1",
                kind: "approval" as const,
              },
            }
          : {}),
        observedAt: new Date().toISOString(),
      },
    ];
    const session: LocalFeatureSession = {
      id: "runtime-0",
      provider: "claude",
      process: {},
      projectPath: "/project/0",
    };

    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );
    const initialHistoryReads = historyReader.mock.calls.length;

    pendingApproval = true;
    fixture.handler.sessionMessage(session, {
      type: "permission_request",
      toolUseId: "approval-1",
      toolName: "Bash",
      input: {},
    });

    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "status_changes").some((event) =>
          event.changes.some(
            (status) =>
              status.providerSessionId === "session-0" &&
              status.attention === "approval",
          ),
        ),
      ).toBe(true),
    );
    expect(historyReader).toHaveBeenCalledTimes(initialHistoryReads);
    expect(fixture.catalogReader).toHaveBeenCalledTimes(1);
    fixture.handler.close();
  });

  it("projects Desktop events and lets cold reconciliation repair a missed terminal event", async () => {
    const backgroundActivityChanged = vi.fn();
    const control = createSharedControlSource({
      kind: "ready",
      connectionGeneration: 1,
    });
    let providerStatus: ConversationSyncStatus = {
      ...codexSeed(0, "thread-control").status,
      activity: "idle",
      runtimeAttachment: "loaded",
      confidence: "authoritative",
      observedAt: "2026-08-01T00:00:00.000Z",
    };
    const statusReader = vi.fn(
      async () => new Map([["codex\0thread-control", providerStatus]]),
    );
    const fixture = createFixture(
      [codexSeed(0, "thread-control")],
      async () => history("thread-control"),
      {
        daemonMode: true,
        statusReader,
        sharedControlReconcileMs: 60_000,
      },
      {
        subscribeSharedRuntimeControl: control.subscribe,
        notifyBackgroundActivityChanged: backgroundActivityChanged,
      },
    );
    const client = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );
    const internal = fixture.handler as unknown as {
      catalog: Map<string, { status: ConversationSyncStatus }>;
      runColdReconcile(): Promise<void>;
    };
    const current = () => internal.catalog.get("codex\0thread-control")!.status;

    control.emit({
      kind: "event",
      event: {
        sequence: 1,
        observedAt: "2026-08-01T00:00:01.000Z",
        connectionGeneration: 1,
        method: "thread/status/changed",
        threadId: "thread-control",
        threadStatus: {
          type: "active",
          activeFlags: ["waitingOnApproval"],
        },
      },
    });
    expect(current()).toMatchObject({
      activity: "working",
      attention: "approval",
      executionHost: "desktopAppServer",
      controlState: "readOnly",
      authorityGeneration: "daemon:1",
    });
    expect([...fixture.handler.backgroundActiveConversationKeys()]).toEqual([
      "codex\0thread-control",
    ]);
    expect(backgroundActivityChanged).toHaveBeenCalledTimes(1);

    control.emit({
      kind: "event",
      event: {
        sequence: 2,
        observedAt: "2026-08-01T00:00:02.000Z",
        connectionGeneration: 1,
        method: "thread/status/changed",
        threadId: "thread-control",
        threadStatus: {
          type: "active",
          activeFlags: ["waitingOnUserInput"],
        },
      },
    });
    expect(current().attention).toBe("question");
    expect(backgroundActivityChanged).toHaveBeenCalledTimes(1);

    control.emit({
      kind: "event",
      event: {
        sequence: 3,
        observedAt: "2026-08-01T00:00:03.000Z",
        connectionGeneration: 1,
        method: "turn/started",
        threadId: "thread-control",
        turnId: "turn-desktop",
        turnStatus: "inProgress",
      },
    });
    expect(current()).toMatchObject({
      activity: "working",
      activeTurnId: "turn-desktop",
      executionHost: "desktopAppServer",
      controlState: "readOnly",
    });

    control.emit({
      kind: "event",
      event: {
        sequence: 4,
        observedAt: "2026-08-01T00:00:04.000Z",
        connectionGeneration: 1,
        method: "turn/completed",
        threadId: "thread-control",
        turnId: "turn-desktop",
        turnStatus: "completed",
      },
    });
    expect(current()).toMatchObject({
      activity: "idle",
      result: "completed",
      controlState: "readOnly",
    });
    expect(current().activeTurnId).toBeUndefined();
    expect([...fixture.handler.backgroundActiveConversationKeys()]).toEqual([]);
    expect(backgroundActivityChanged).toHaveBeenCalledTimes(2);

    control.emit({
      kind: "event",
      event: {
        sequence: 5,
        observedAt: "2026-08-01T00:00:05.000Z",
        connectionGeneration: 1,
        method: "thread/status/changed",
        threadId: "thread-control",
        threadStatus: { type: "active", activeFlags: [] },
      },
    });
    expect(current().activity).toBe("working");
    expect(backgroundActivityChanged).toHaveBeenCalledTimes(3);

    // Simulate a lost turn/completed notification. The long-cadence cold
    // provider snapshot is the bounded repair path and must replace, rather
    // than be hidden by, the old live control overlay.
    providerStatus = {
      ...providerStatus,
      activity: "idle",
      attention: "none",
      observedAt: "2026-08-01T00:00:06.000Z",
    };
    await internal.runColdReconcile();
    expect(current()).toMatchObject({
      activity: "idle",
      attention: "none",
      executionHost: "unknown",
      controlState: "readOnly",
      authorityGeneration: "daemon:1",
    });
    expect(current().activeTurnId).toBeUndefined();
    expect([...fixture.handler.backgroundActiveConversationKeys()]).toEqual([]);
    expect(backgroundActivityChanged).toHaveBeenCalledTimes(4);
    fixture.handler.close();
  });

  it.each<{
    message: Extract<ServerMessage, { type: "result" }>;
    expected: "completed" | "failed" | null;
  }>([
    { message: { type: "result", subtype: "success" }, expected: "completed" },
    {
      message: { type: "result", subtype: "completed" },
      expected: "completed",
    },
    { message: { type: "result", subtype: "error" }, expected: "failed" },
    { message: { type: "result", subtype: "failed" }, expected: "failed" },
    {
      message: {
        type: "result",
        subtype: "stopped",
        stopReason: "provider error",
      },
      expected: "failed",
    },
    {
      message: { type: "result", subtype: "future", error: "explicit error" },
      expected: "failed",
    },
    { message: { type: "result", subtype: "stopped" }, expected: null },
    { message: { type: "result", subtype: "interrupted" }, expected: null },
    { message: { type: "result", subtype: "cancelled" }, expected: null },
    { message: { type: "result", subtype: "future" }, expected: null },
  ])(
    "classifies session result subtype $message.subtype as $expected",
    ({ message, expected }) => {
      const fixture = createFixture([seed(0)], async () =>
        history("session-0"),
      );
      fixture.runtime.getProviderSessionId = () => "session-0";
      const session: LocalFeatureSession = {
        id: "runtime-terminal-classifier",
        provider: "claude",
        process: {},
        projectPath: "/project/terminal",
      };
      const internal = fixture.handler as unknown as {
        resultLedger: Map<string, { result: "completed" | "failed" }>;
      };

      fixture.handler.sessionMessage(session, message);

      expect(
        internal.resultLedger.get("claude\0session-0")?.result ?? null,
      ).toBe(expected);
      fixture.handler.close();
    },
  );

  it("uses the same terminal whitelist for external rollout messages", async () => {
    const fixture = createFixture(
      [codexSeed(0, "thread-external-terminal")],
      async () => history("thread-external-terminal"),
      { daemonMode: false },
    );
    const client = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );
    const internal = fixture.handler as unknown as {
      externalCodexMonitorGenerations: Map<string, number>;
      resultLedger: Map<string, { result: "completed" | "failed" }>;
      onExternalCodexEvent(
        threadId: string,
        generation: number,
        event: {
          kind: "message";
          itemKey: string;
          timestamp: string;
          message: ServerMessage;
        },
      ): void;
    };
    internal.externalCodexMonitorGenerations.set("thread-external-terminal", 1);
    const emit = (
      itemKey: string,
      timestamp: string,
      message: Extract<ServerMessage, { type: "result" }>,
    ) =>
      internal.onExternalCodexEvent("thread-external-terminal", 1, {
        kind: "message",
        itemKey,
        timestamp,
        message,
      });

    emit("stopped", "2026-08-01T00:05:00.000Z", {
      type: "result",
      subtype: "stopped",
    });
    emit("future", "2026-08-01T00:05:01.000Z", {
      type: "result",
      subtype: "future",
    });
    expect(internal.resultLedger.has("codex\0thread-external-terminal")).toBe(
      false,
    );

    emit("success", "2026-08-01T00:05:02.000Z", {
      type: "result",
      subtype: "success",
    });
    expect(
      internal.resultLedger.get("codex\0thread-external-terminal")?.result,
    ).toBe("completed");

    emit("error", "2026-08-01T00:05:03.000Z", {
      type: "result",
      subtype: "error",
    });
    expect(
      internal.resultLedger.get("codex\0thread-external-terminal")?.result,
    ).toBe("failed");
    fixture.handler.close();
  });

  it("rehydrates only the focused thread after a durable settings invalidation", async () => {
    const threadId = "thread-settings-invalidated";
    const control = createSharedControlSource({
      kind: "ready",
      connectionGeneration: 1,
    });
    let model = "gpt-5.5";
    const focusedCodexMetadataReader = vi.fn(async (requested: string) => ({
      codexSettings: {
        model,
        modelReasoningEffort: model === "gpt-5.5" ? "high" : "ultra",
        serviceTier: "fast",
        approvalPolicy: "on-request",
        approvalsReviewer: "user",
        sandboxMode: "workspace-write",
        collaborationMode: "default" as const,
      },
      resumeCwd: `/project/${requested}`,
    }));
    const historyReader = vi.fn(async () => history(threadId));
    const fixture = createFixture(
      [codexSeed(0, threadId)],
      historyReader,
      {
        daemonMode: true,
        focusedCodexMetadataReader,
        sharedControlReconcileMs: 60_000,
      },
      { subscribeSharedRuntimeControl: control.subscribe },
    );
    const client = {};
    await fixture.handler.handle(
      {
        ...subscribeMessage(),
        focused: { provider: "codex", providerSessionId: threadId },
      },
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "catalog_changes")
          .flatMap((event) => [...event.created, ...event.updated])
          .find((entry) => entry.model === "gpt-5.5"),
      ).toBeDefined(),
    );
    const initialComplete = events(fixture.sent, client, "sync_complete").at(
      -1,
    )!;
    await fixture.handler.handle(
      {
        type: "conversation_sync_ack",
        protocolVersion: 2,
        subscriptionId: initialComplete.subscriptionId,
        sequence: initialComplete.sequence,
      },
      context(client, fixture.runtime),
    );
    const initialCatalogReads = fixture.catalogReader.mock.calls.length;
    const initialHistoryReads = historyReader.mock.calls.length;

    model = "gpt-5.6-sol";
    control.emit({
      kind: "event",
      event: {
        sequence: 1,
        observedAt: "2026-08-02T02:00:00.000Z",
        connectionGeneration: 1,
        method: "thread/settings/updated",
        threadId,
      },
    });

    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "catalog_changes")
          .flatMap((event) => event.updated)
          .find((entry) => entry.model === "gpt-5.6-sol"),
      ).toMatchObject({
        providerSessionId: threadId,
        modelReasoningEffort: "ultra",
        codexSettingsSnapshotComplete: true,
      }),
    );
    expect(focusedCodexMetadataReader).toHaveBeenCalledTimes(2);
    expect(focusedCodexMetadataReader).toHaveBeenLastCalledWith(threadId);
    expect(fixture.catalogReader).toHaveBeenCalledTimes(initialCatalogReads);
    expect(historyReader).toHaveBeenCalledTimes(initialHistoryReads);
    fixture.handler.close();
  });

  it("keeps interrupted shared-control turns non-terminal", async () => {
    const control = createSharedControlSource({
      kind: "ready",
      connectionGeneration: 1,
    });
    const fixture = createFixture(
      [codexSeed(0, "thread-control-terminal")],
      async () => history("thread-control-terminal"),
      { daemonMode: true, sharedControlReconcileMs: 60_000 },
      { subscribeSharedRuntimeControl: control.subscribe },
    );
    const client = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );
    const internal = fixture.handler as unknown as {
      resultLedger: Map<string, { result: "completed" | "failed" }>;
    };
    const event = (
      sequence: number,
      method: "turn/started" | "turn/completed",
      turnStatus: "inProgress" | "completed" | "interrupted" | "failed",
    ): LocalFeatureSharedRuntimeControlUpdate => ({
      kind: "event",
      event: {
        sequence,
        observedAt: `2026-08-01T00:06:0${sequence}.000Z`,
        connectionGeneration: 1,
        method,
        threadId: "thread-control-terminal",
        turnId: `turn-${sequence}`,
        turnStatus,
      },
    });

    control.emit(event(1, "turn/started", "inProgress"));
    control.emit(event(2, "turn/completed", "interrupted"));
    expect(internal.resultLedger.has("codex\0thread-control-terminal")).toBe(
      false,
    );

    control.emit(event(3, "turn/started", "inProgress"));
    control.emit(event(4, "turn/completed", "completed"));
    expect(
      internal.resultLedger.get("codex\0thread-control-terminal")?.result,
    ).toBe("completed");

    control.emit(event(5, "turn/started", "inProgress"));
    control.emit(event(6, "turn/completed", "failed"));
    expect(
      internal.resultLedger.get("codex\0thread-control-terminal")?.result,
    ).toBe("failed");
    fixture.handler.close();
  });

  it("restores an offline Desktop completion after the Bridge handler restarts", async () => {
    const directory = await mkdtemp(
      join(tmpdir(), "ccpocket-conversation-terminal-result-"),
    );
    const file = join(directory, "terminal-results.json");
    try {
      const firstLedger = new TerminalResultLedger(file);
      await firstLedger.init();
      const control = createSharedControlSource({
        kind: "ready",
        connectionGeneration: 1,
      });
      const offline = createFixture(
        [codexSeed(0, "thread-offline-completion")],
        async () => history("thread-offline-completion"),
        {
          daemonMode: true,
          sharedControlReconcileMs: 60_000,
        },
        {
          subscribeSharedRuntimeControl: control.subscribe,
          terminalResultLedger: firstLedger,
        },
      );

      control.emit({
        kind: "event",
        event: {
          sequence: 1,
          observedAt: "2026-08-01T00:10:00.000Z",
          connectionGeneration: 1,
          method: "turn/started",
          threadId: "thread-offline-completion",
          turnId: "turn-offline",
          turnStatus: "inProgress",
        },
      });
      control.emit({
        kind: "event",
        event: {
          sequence: 2,
          observedAt: "2026-08-01T00:10:01.000Z",
          connectionGeneration: 1,
          method: "turn/completed",
          threadId: "thread-offline-completion",
          turnId: "turn-offline",
          turnStatus: "completed",
        },
      });
      await offline.handler.close();

      const restoredLedger = new TerminalResultLedger(file);
      await restoredLedger.init();
      const restored = createFixture(
        [codexSeed(0, "thread-offline-completion")],
        async () => history("thread-offline-completion"),
        { daemonMode: false },
        { terminalResultLedger: restoredLedger },
      );
      const client = {};
      await restored.handler.handle(
        subscribeMessage(),
        context(client, restored.runtime),
      );
      await vi.waitFor(() =>
        expect(events(restored.sent, client, "sync_complete")).toHaveLength(1),
      );
      const terminal = events(restored.sent, client, "status_changes")
        .flatMap((event) => event.changes)
        .filter(
          (status) => status.providerSessionId === "thread-offline-completion",
        )
        .at(-1);
      expect(terminal).toMatchObject({
        result: "completed",
        observedAt: "2026-08-01T00:10:01.000Z",
      });
      await restored.handler.close();
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  it("does not restore an older terminal turn over a recovered active turn", async () => {
    const directory = await mkdtemp(
      join(tmpdir(), "ccpocket-conversation-active-after-terminal-"),
    );
    const file = join(directory, "terminal-results.json");
    try {
      const ledger = new TerminalResultLedger(file);
      await ledger.init();
      await ledger.record({
        ...terminalScopeForFixture(),
        provider: "codex",
        threadId: "thread-active-after-terminal",
        turnId: "turn-completed-before-restart",
        result: "completed",
        observedAt: "2026-08-01T00:11:00.000Z",
      });

      const control = createSharedControlSource({
        kind: "ready",
        connectionGeneration: 1,
      });
      const seed = codexSeed(0, "thread-active-after-terminal");
      const workingStatus: ConversationSyncStatus = {
        ...seed.status,
        activity: "working",
        result: "none",
        runtimeAttachment: "loaded",
        source: "appServer",
        confidence: "authoritative",
        observedAt: "2026-08-01T00:11:01.000Z",
        activeTurnId: "turn-active-after-restart",
      };
      const recoveryReader = vi.fn(async () => ({
        turnId: "turn-active-after-restart",
        status: "inProgress" as const,
        observedAt: "2026-08-01T00:11:02.000Z",
      }));
      const fixture = createFixture(
        [seed],
        async () => history("thread-active-after-terminal"),
        {
          daemonMode: true,
          statusReader: async () =>
            new Map([["codex\0thread-active-after-terminal", workingStatus]]),
          sharedControlRecoveryReader: recoveryReader,
          sharedControlReconcileMs: 1,
        },
        {
          subscribeSharedRuntimeControl: control.subscribe,
          terminalResultLedger: ledger,
        },
      );
      const client = {};
      await fixture.handler.handle(
        subscribeMessage(),
        context(client, fixture.runtime),
      );
      await vi.waitFor(() =>
        expect(events(fixture.sent, client, "sync_complete")).not.toHaveLength(
          0,
        ),
      );

      control.emit({ kind: "not_ready", connectionGeneration: 1 });
      control.emit({ kind: "ready", connectionGeneration: 2 });

      const internal = fixture.handler as unknown as {
        catalog: Map<string, { status: ConversationSyncStatus }>;
      };
      await vi.waitFor(() => expect(recoveryReader).toHaveBeenCalledOnce());
      await vi.waitFor(() =>
        expect(
          internal.catalog.get("codex\0thread-active-after-terminal")?.status,
        ).toMatchObject({
          activity: "working",
          result: "none",
          activeTurnId: "turn-active-after-restart",
          authorityGeneration: "daemon:2",
        }),
      );
      await fixture.handler.close();

      const reloaded = new TerminalResultLedger(file);
      await reloaded.init();
      expect(reloaded.list(terminalScopeForFixture())).toEqual([]);
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  it("keeps completion through late output and clears it on a proven new turn", async () => {
    const directory = await mkdtemp(
      join(tmpdir(), "ccpocket-conversation-late-terminal-output-"),
    );
    const file = join(directory, "terminal-results.json");
    const session: LocalFeatureSession = {
      id: "runtime-terminal",
      provider: "claude",
      process: {},
      projectPath: "/project/terminal",
    };
    try {
      const ledger = new TerminalResultLedger(file);
      await ledger.init();
      const completed = createFixture(
        [seed(0)],
        async () => history("session-0"),
        {},
        { terminalResultLedger: ledger },
      );
      completed.runtime.getProviderSessionId = () => "session-0";
      completed.handler.sessionMessage(session, {
        type: "result",
        subtype: "success",
        result: "done",
      });
      completed.handler.sessionMessage(session, {
        type: "tool_result",
        toolUseId: "late-tool",
        toolName: "Read",
        content: "late tool output",
      });
      completed.handler.sessionMessage(session, {
        type: "assistant",
        message: {
          id: "late-assistant",
          role: "assistant",
          model: "test",
          content: [{ type: "text", text: "late assistant output" }],
        },
      });
      await completed.handler.close();

      const afterLateOutput = new TerminalResultLedger(file);
      await afterLateOutput.init();
      expect(afterLateOutput.list(terminalScopeForFixture())).toMatchObject([
        {
          provider: "claude",
          threadId: "session-0",
          result: "completed",
        },
      ]);

      const nextTurn = createFixture(
        [seed(0)],
        async () => history("session-0"),
        {},
        { terminalResultLedger: afterLateOutput },
      );
      nextTurn.runtime.getProviderSessionId = () => "session-0";
      nextTurn.handler.sessionMessage(session, {
        type: "user_input",
        text: "start the next turn",
      });
      await nextTurn.handler.close();

      const cleared = new TerminalResultLedger(file);
      await cleared.init();
      expect(cleared.list(terminalScopeForFixture())).toEqual([]);
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  it("streams shared-daemon Desktop content through one bounded observer per thread", async () => {
    const control = createSharedControlSource({
      kind: "ready",
      connectionGeneration: 3,
    });
    const codex = codexSeed(0, "thread-shared-content");
    codex.status = {
      ...codex.status,
      activity: "working",
      attention: "none",
      runtimeAttachment: "loaded",
      confidence: "authoritative",
      observedAt: "2026-08-01T05:00:00.000Z",
    };
    const observers: FakeSharedContentObserverProcess[] = [];
    const legacyRolloutObserver = vi.fn(async () => {
      throw new Error("daemon mode must not open a rollout monitor");
    });
    const historyReader = vi.fn(async () => history("initial-shared-content"));
    let latestMessages: ServerMessage[] = [
      {
        type: "user_input",
        text: "desktop prompt",
        userMessageUuid: "desktop-user",
      },
      {
        type: "assistant",
        historyTurnId: "turn-shared-live",
        messageUuid: "desktop-partial",
        message: {
          id: "desktop-partial",
          role: "assistant",
          model: "test",
          content: [{ type: "text", text: "partial" }],
        },
      },
    ];
    const latestTurnHistoryReader = vi.fn(async () => ({
      messages: latestMessages,
      nextTurnCursor: "older-cursor",
    }));
    const registerInlineImages = vi.fn(() => [
      {
        id: "image-safe-ref",
        url: "/images/image-safe-ref",
        mimeType: "image/png",
      },
    ]);
    const publishSharedContextUsage = vi.fn();
    const fixture = createFixture(
      [codex],
      historyReader,
      {
        daemonMode: true,
        latestTurnHistoryReader,
        observeCodexThread: legacyRolloutObserver,
        createSharedContentObserverProcess: () => {
          const process = new FakeSharedContentObserverProcess();
          observers.push(process);
          return process.asObserver();
        },
        sharedContentObserverUnfocusGraceMs: 0,
        publishSharedContextUsage,
      },
      {
        subscribeSharedRuntimeControl: control.subscribe,
        registerInlineImages,
        supports: (_client: object, type: string) =>
          type === CONVERSATION_SYNC_V2_CAPABILITY || type === "context_usage",
      },
    );
    const firstClient = {};
    const secondClient = {};
    const firstSubscription = {
      ...subscribeMessage(),
      focused: {
        provider: "codex" as const,
        providerSessionId: "thread-shared-content",
      },
    };
    const secondSubscription = subscribeMessage();
    await fixture.handler.handle(
      firstSubscription,
      context(firstClient, fixture.runtime),
    );
    await fixture.handler.handle(
      secondSubscription,
      context(secondClient, fixture.runtime),
    );
    await vi.waitFor(() => {
      expect(
        events(fixture.sent, firstClient, "sync_complete").length,
      ).toBeGreaterThan(0);
      expect(
        events(fixture.sent, secondClient, "sync_complete").length,
      ).toBeGreaterThan(0);
      expect(observers).toHaveLength(1);
    });
    expect(observers[0]!.starts).toMatchObject([
      {
        projectPath: codex.entry.projectPath,
        options: {
          threadId: "thread-shared-content",
          sharedRuntimeAttach: "observer",
        },
      },
    ]);

    observers[0]!.message({
      type: "context_usage",
      turnId: "turn-shared-live",
      last: {
        totalTokens: 125,
        inputTokens: 100,
        cachedInputTokens: 20,
        cacheWriteInputTokens: 0,
        outputTokens: 25,
        reasoningOutputTokens: 5,
      },
      total: {
        totalTokens: 125,
        inputTokens: 100,
        cachedInputTokens: 20,
        cacheWriteInputTokens: 0,
        outputTokens: 25,
        reasoningOutputTokens: 5,
      },
      modelContextWindow: 200_000,
    });
    expect(publishSharedContextUsage).toHaveBeenCalledTimes(1);
    expect(publishSharedContextUsage).toHaveBeenCalledWith(
      firstClient,
      expect.objectContaining({
        type: "context_usage",
        sessionId: "thread-shared-content",
        threadId: "thread-shared-content",
        turnId: "turn-shared-live",
        bridgeInstanceId: "bridge-1",
        codexSourceId: "source-1",
        authorityGeneration: expect.stringMatching(/^daemon:3:\d+$/),
      }),
    );

    for (const [client, subscription] of [
      [firstClient, firstSubscription],
      [secondClient, secondSubscription],
    ] as const) {
      const complete = events(fixture.sent, client, "sync_complete").at(-1)!;
      await fixture.handler.handle(
        {
          type: "conversation_sync_ack",
          protocolVersion: 2,
          subscriptionId: subscription.requestId,
          sequence: complete.sequence,
        },
        context(client, fixture.runtime),
      );
    }

    for (let index = 0; index < 100; index += 1) {
      observers[0]!.message({ type: "stream_delta", text: `delta-${index}` });
    }
    observers[0]!.message({
      type: "assistant",
      message: {
        id: "tool-coalesced-with-stream",
        role: "assistant",
        model: "test",
        content: [
          {
            type: "tool_use",
            id: "tool-coalesced-with-stream",
            name: "Search",
            input: { query: "live" },
          },
        ],
      },
    });
    await vi.waitFor(
      () => expect(latestTurnHistoryReader).toHaveBeenCalledTimes(1),
      { timeout: 3_000 },
    );
    expect(historyReader).toHaveBeenCalledTimes(1);

    const toolUse: ServerMessage = {
      type: "assistant",
      message: {
        id: "tool-shared",
        role: "assistant",
        model: "test",
        content: [
          {
            type: "tool_use",
            id: "tool-shared",
            name: "Read",
            input: { path: "/tmp/example" },
          },
        ],
      },
    };
    observers[0]!.message(toolUse);
    observers[0]!.message({
      type: "tool_result",
      toolUseId: "tool-shared",
      toolName: "Read",
      content: "tool result",
      rawContentBlocks: [
        {
          type: "image",
          source: {
            type: "base64",
            data: "aW1hZ2U=",
            media_type: "image/png",
          },
        },
      ],
    });
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, firstClient, "timeline_page")
          .flatMap((event) => event.entries)
          .some(
            (entry) =>
              entry.message.type === "tool_result" &&
              entry.message.toolUseId === "tool-shared",
          ),
      ).toBe(true),
    );
    expect(latestTurnHistoryReader).toHaveBeenCalledTimes(1);
    expect(registerInlineImages).toHaveBeenCalledWith([
      { data: "aW1hZ2U=", mimeType: "image/png" },
    ]);
    const safeToolResult = events(fixture.sent, firstClient, "timeline_page")
      .flatMap((event) => event.entries)
      .map((entry) => entry.message)
      .find(
        (message) =>
          message.type === "tool_result" && message.toolUseId === "tool-shared",
      );
    expect(safeToolResult).toMatchObject({
      images: [{ id: "image-safe-ref" }],
    });
    expect(safeToolResult).not.toHaveProperty("rawContentBlocks");

    latestMessages = [
      ...latestMessages,
      toolUse,
      {
        type: "tool_result",
        historyTurnId: "turn-shared-live",
        toolUseId: "tool-shared",
        toolName: "Read",
        content: "tool result",
      },
      {
        type: "assistant",
        historyTurnId: "turn-shared-live",
        messageUuid: "desktop-final",
        message: {
          id: "desktop-final",
          role: "assistant",
          model: "test",
          content: [{ type: "text", text: "desktop final answer" }],
        },
      },
    ];
    const completesBefore = events(
      fixture.sent,
      firstClient,
      "sync_complete",
    ).length;
    const lastComplete = events(fixture.sent, firstClient, "sync_complete").at(
      -1,
    )!;
    await fixture.handler.handle(
      {
        type: "conversation_sync_ack",
        protocolVersion: 2,
        subscriptionId: firstSubscription.requestId,
        sequence: lastComplete.sequence,
      },
      context(firstClient, fixture.runtime),
    );
    observers[0]!.message({
      type: "result",
      subtype: "success",
      result: "desktop final answer",
    });
    await vi.waitFor(
      () => {
        expect(latestTurnHistoryReader).toHaveBeenCalledTimes(2);
        expect(
          events(fixture.sent, firstClient, "sync_complete").length,
        ).toBeGreaterThan(completesBefore);
      },
      { timeout: 3_000 },
    );
    expect(
      events(fixture.sent, firstClient, "timeline_page")
        .flatMap((event) => event.entries)
        .some(
          (entry) =>
            entry.message.type === "assistant" &&
            entry.message.message.content.some(
              (content) =>
                content.type === "text" &&
                content.text === "desktop final answer",
            ),
        ),
    ).toBe(true);
    expect(fixture.catalogReader).toHaveBeenCalledTimes(1);
    expect(legacyRolloutObserver).not.toHaveBeenCalled();
    await fixture.handler.close();
    expect(observers[0]!.stop).toHaveBeenCalledOnce();
  });

  it("keeps a narrow Desktop observer for notification-only progress and terminal events", async () => {
    const control = createSharedControlSource({
      kind: "ready",
      connectionGeneration: 7,
    });
    const codex = codexSeed(0, "thread-background-content");
    codex.entry.name = "Background task";
    codex.status = {
      ...codex.status,
      activity: "working",
      runtimeAttachment: "loaded",
      confidence: "authoritative",
      observedAt: "2026-08-01T05:10:00.000Z",
    };
    const observers: FakeSharedContentObserverProcess[] = [];
    const publishExternalCodexNotificationCandidate = vi.fn();
    const fixture = createFixture(
      [codex],
      async () => history("background-content"),
      {
        daemonMode: true,
        sharedControlReconcileMs: 1,
        createSharedContentObserverProcess: () => {
          const process = new FakeSharedContentObserverProcess();
          observers.push(process);
          return process.asObserver();
        },
      },
      {
        subscribeSharedRuntimeControl: control.subscribe,
        getClientDeliveryMode: () => "notifications_only",
        publishExternalCodexNotificationCandidate,
      },
    );
    const client = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() => expect(observers).toHaveLength(1));
    expect(events(fixture.sent, client, "sync_begin")).toEqual([]);

    observers[0]!.message({
      type: "assistant",
      message: {
        id: "background-tool-message",
        role: "assistant",
        model: "secret-model",
        content: [
          {
            type: "tool_use",
            id: "background-tool",
            name: "Read",
            input: { path: "/private/secret" },
          },
        ],
      },
    });
    expect(publishExternalCodexNotificationCandidate).toHaveBeenCalledWith(
      expect.objectContaining({
        codexSourceId: "source-1",
        threadId: "thread-background-content",
        label: "Background task (0)",
        message: {
          type: "assistant",
          message: {
            id: "background-tool-message",
            role: "assistant",
            model: "",
            content: [
              {
                type: "tool_use",
                id: "background-tool",
                name: "Read",
                input: {},
              },
            ],
          },
        },
      }),
    );

    control.emit({
      kind: "event",
      event: {
        sequence: 1,
        observedAt: "2026-08-01T05:10:05.000Z",
        connectionGeneration: 7,
        method: "turn/completed",
        threadId: "thread-background-content",
        turnId: "turn-background-content",
        turnStatus: "failed",
      },
    });
    expect(publishExternalCodexNotificationCandidate).toHaveBeenCalledWith(
      expect.objectContaining({
        threadId: "thread-background-content",
        turnId: "turn-background-content",
        observedAt: "2026-08-01T05:10:05.000Z",
        message: expect.objectContaining({
          type: "result",
          subtype: "error",
        }),
      }),
    );

    fixture.handler.disconnect(client);
    expect(observers[0]!.stop).toHaveBeenCalledOnce();
    await fixture.handler.close();
  });

  it("keeps Bridge-owned shared turns on the existing session stream without a duplicate observer", async () => {
    const control = createSharedControlSource({
      kind: "ready",
      connectionGeneration: 4,
    });
    const codex = codexSeed(0, "thread-bridge-owned-content");
    codex.status = {
      ...codex.status,
      activity: "working",
      runtimeAttachment: "loaded",
      confidence: "authoritative",
    };
    const observers: FakeSharedContentObserverProcess[] = [];
    let canonicalHistory = history("bridge-before-live");
    const fixture = createFixture(
      [codex],
      async () => canonicalHistory,
      {
        daemonMode: true,
        createSharedContentObserverProcess: () => {
          const process = new FakeSharedContentObserverProcess();
          observers.push(process);
          return process.asObserver();
        },
      },
      {
        subscribeSharedRuntimeControl: control.subscribe,
        listRuntimeConversationStates: () => [
          {
            bridgeSessionId: "runtime-bridge-owned",
            provider: "codex",
            providerSessionId: "thread-bridge-owned-content",
            projectPath: "/project/0",
            processStatus: "running",
            executionHost: "bridge",
            activeTurnId: "turn-bridge-owned",
            controlState: "steerable",
            authorityGeneration: "bridge-authority",
            observedAt: "2026-08-01T05:30:00.000Z",
          },
        ],
        getProviderSessionId: () => "thread-bridge-owned-content",
      },
    );
    const client = {};
    const subscription = subscribeMessage();
    await fixture.handler.handle(
      subscription,
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "sync_complete").length,
      ).toBeGreaterThan(0),
    );
    expect(observers).toHaveLength(0);
    const complete = events(fixture.sent, client, "sync_complete").at(-1)!;
    await fixture.handler.handle(
      {
        type: "conversation_sync_ack",
        protocolVersion: 2,
        subscriptionId: subscription.requestId,
        sequence: complete.sequence,
      },
      context(client, fixture.runtime),
    );
    canonicalHistory = [
      ...canonicalHistory,
      {
        type: "assistant",
        historyTurnId: "turn-bridge-owned",
        messageUuid: "bridge-live-answer",
        message: {
          id: "bridge-live-answer",
          role: "assistant",
          model: "test",
          content: [{ type: "text", text: "Bridge live answer" }],
        },
      },
    ];
    fixture.handler.sessionMessage(
      {
        id: "runtime-bridge-owned",
        provider: "codex",
        process: {},
        projectPath: "/project/0",
      },
      canonicalHistory.at(-1)!,
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "timeline_page")
          .flatMap((event) => event.entries)
          .some(
            (entry) =>
              entry.message.type === "assistant" &&
              entry.message.message.id === "bridge-live-answer",
          ),
      ).toBe(true),
    );
    expect(observers).toHaveLength(0);
    await fixture.handler.close();
  });

  it("reconciles once on daemon ready and not after 128 known-thread events", async () => {
    const control = createSharedControlSource({
      kind: "not_ready",
      connectionGeneration: 0,
    });
    const statusReader = vi.fn(
      async () =>
        new Map([
          [
            "codex\0thread-event-storm",
            codexSeed(0, "thread-event-storm").status,
          ],
        ]),
    );
    const fixture = createFixture(
      [codexSeed(0, "thread-event-storm")],
      async () => history("thread-event-storm"),
      {
        daemonMode: true,
        statusReader,
        statusWatchdogMs: 5,
        sharedControlReconcileMs: 5,
      },
      { subscribeSharedRuntimeControl: control.subscribe },
    );
    const client = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(events(fixture.sent, client, "sync_complete")).toHaveLength(1),
    );
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(statusReader).not.toHaveBeenCalled();

    control.emit({ kind: "ready", connectionGeneration: 1 });
    await vi.waitFor(() => expect(statusReader).toHaveBeenCalledTimes(1));
    const catalogReadsAfterReady = fixture.catalogReader.mock.calls.length;

    for (let sequence = 1; sequence <= 128; sequence += 1) {
      control.emit({
        kind: "event",
        event: {
          sequence,
          observedAt: new Date(
            Date.parse("2026-08-01T01:30:00.000Z") + sequence,
          ).toISOString(),
          connectionGeneration: 1,
          method: "thread/status/changed",
          threadId: "thread-event-storm",
          threadStatus:
            sequence % 2 === 0
              ? { type: "idle" }
              : { type: "active", activeFlags: [] },
        },
      });
    }
    control.emit({ kind: "ready", connectionGeneration: 1 });
    await new Promise((resolve) => setTimeout(resolve, 30));

    expect(statusReader).toHaveBeenCalledTimes(1);
    expect(fixture.catalogReader).toHaveBeenCalledTimes(catalogReadsAfterReady);
    fixture.handler.close();
  });

  it("keeps the five-second status watchdog for private compatibility mode", async () => {
    const statusReader = vi.fn(async () => new Map());
    const fixture = createFixture(
      [codexSeed(0, "thread-private-watchdog")],
      async () => history("thread-private-watchdog"),
      {
        daemonMode: false,
        statusReader,
        statusWatchdogMs: 5,
      },
    );
    const client = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );

    await vi.waitFor(() => expect(statusReader).toHaveBeenCalled());
    fixture.handler.close();
  });

  it("resolves a known-thread request without a full app-server reconciliation", async () => {
    const control = createSharedControlSource({
      kind: "ready",
      connectionGeneration: 1,
    });
    let providerStatus: ConversationSyncStatus = {
      ...codexSeed(0, "thread-request").status,
      activity: "working",
      attention: "question",
      runtimeAttachment: "loaded",
      confidence: "authoritative",
      observedAt: "2026-08-01T01:00:00.000Z",
    };
    const statusReader = vi.fn(
      async () => new Map([["codex\0thread-request", providerStatus]]),
    );
    const fixture = createFixture(
      [codexSeed(0, "thread-request")],
      async () => history("thread-request"),
      {
        daemonMode: true,
        statusReader,
        sharedControlReconcileMs: 5,
      },
      { subscribeSharedRuntimeControl: control.subscribe },
    );
    const client = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() => expect(statusReader).toHaveBeenCalled());
    statusReader.mockClear();

    control.emit({
      kind: "event",
      event: {
        sequence: 1,
        observedAt: "2026-08-01T01:00:01.000Z",
        connectionGeneration: 1,
        method: "thread/status/changed",
        threadId: "thread-request",
        threadStatus: {
          type: "active",
          activeFlags: ["waitingOnUserInput"],
        },
      },
    });
    providerStatus = {
      ...providerStatus,
      activity: "idle",
      attention: "none",
      observedAt: "2026-08-01T01:00:02.000Z",
    };
    control.emit({
      kind: "event",
      event: {
        sequence: 2,
        observedAt: "2026-08-01T01:00:02.000Z",
        connectionGeneration: 1,
        method: "serverRequest/resolved",
        threadId: "thread-request",
        requestId: "request-desktop",
      },
    });

    expect(statusReader).not.toHaveBeenCalled();
    const internal = fixture.handler as unknown as {
      catalog: Map<string, { status: ConversationSyncStatus }>;
    };
    expect(internal.catalog.get("codex\0thread-request")?.status).toMatchObject(
      {
        activity: "working",
        attention: "none",
        authorityGeneration: "daemon:1",
      },
    );
    fixture.handler.close();
  });

  it("fails daemon authority closed across reconnects and removes the control listener on close", async () => {
    const control = createSharedControlSource({
      kind: "ready",
      connectionGeneration: 1,
    });
    let providerStatus: ConversationSyncStatus = {
      ...codexSeed(0, "thread-reconnect").status,
      activity: "working",
      runtimeAttachment: "loaded",
      confidence: "authoritative",
      observedAt: "2026-08-01T02:00:00.000Z",
    };
    const statusReader = vi.fn(
      async () => new Map([["codex\0thread-reconnect", providerStatus]]),
    );
    const fixture = createFixture(
      [codexSeed(0, "thread-reconnect")],
      async () => history("thread-reconnect"),
      {
        daemonMode: true,
        statusReader,
        sharedControlReconcileMs: 5,
        sharedControlRecoveryReader: async () => ({
          turnId: "turn-reconnect",
          status: "interrupted",
          observedAt: "2026-08-01T02:00:02.000Z",
        }),
      },
      { subscribeSharedRuntimeControl: control.subscribe },
    );
    const client = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() => expect(statusReader).toHaveBeenCalled());
    const internal = fixture.handler as unknown as {
      catalog: Map<string, { status: ConversationSyncStatus }>;
    };

    control.emit({ kind: "not_ready", connectionGeneration: 1 });
    expect(
      internal.catalog.get("codex\0thread-reconnect")?.status,
    ).toMatchObject({
      activity: "working",
      controlState: "unavailable",
      confidence: "unknown",
    });
    expect(
      internal.catalog.get("codex\0thread-reconnect")?.status
        .authorityGeneration,
    ).toBeUndefined();

    control.emit({
      kind: "event",
      event: {
        sequence: 999,
        observedAt: "2026-08-01T02:00:01.000Z",
        connectionGeneration: 1,
        method: "thread/status/changed",
        threadId: "thread-reconnect",
        threadStatus: { type: "active", activeFlags: [] },
      },
    });
    expect(
      internal.catalog.get("codex\0thread-reconnect")?.status.activity,
    ).toBe("working");

    providerStatus = {
      ...providerStatus,
      activity: "idle",
      attention: "none",
      observedAt: "2026-08-01T02:00:02.000Z",
    };
    control.emit({ kind: "ready", connectionGeneration: 2 });
    expect(
      internal.catalog.get("codex\0thread-reconnect")?.status,
    ).toMatchObject({
      activity: "working",
      controlState: "reconciling",
      authorityGeneration: "daemon:2",
    });
    await vi.waitFor(() =>
      expect(
        internal.catalog.get("codex\0thread-reconnect")?.status,
      ).toMatchObject({
        activity: "idle",
        controlState: "readOnly",
        authorityGeneration: "daemon:2",
      }),
    );

    control.emit({
      kind: "event",
      event: {
        sequence: 1_000,
        observedAt: "2026-08-01T02:00:03.000Z",
        connectionGeneration: 1,
        method: "thread/status/changed",
        threadId: "thread-reconnect",
        threadStatus: { type: "active", activeFlags: [] },
      },
    });
    expect(
      internal.catalog.get("codex\0thread-reconnect")?.status.activity,
    ).toBe("idle");
    expect(control.listenerCount).toBe(1);
    fixture.handler.close();
    expect(control.listenerCount).toBe(0);
    control.emit({
      kind: "event",
      event: {
        sequence: 2,
        observedAt: "2026-08-01T02:00:04.000Z",
        connectionGeneration: 2,
        method: "thread/status/changed",
        threadId: "thread-reconnect",
        threadStatus: { type: "active", activeFlags: [] },
      },
    });
    expect(
      internal.catalog.get("codex\0thread-reconnect")?.status.activity,
    ).toBe("idle");
  });

  it("refreshes the bounded catalog when control reports an unknown Desktop thread", async () => {
    const control = createSharedControlSource({
      kind: "ready",
      connectionGeneration: 1,
    });
    const seeds = [codexSeed(0, "thread-known")];
    const fixture = createFixture(
      seeds,
      async (target) => history(target.providerSessionId),
      {
        daemonMode: true,
        statusReader: async () =>
          new Map(
            seeds.map((item) => [
              `codex\0${item.entry.providerSessionId}`,
              item.status,
            ]),
          ),
        sharedControlReconcileMs: 5,
      },
      { subscribeSharedRuntimeControl: control.subscribe },
    );
    const client = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "sync_complete").length,
      ).toBeGreaterThanOrEqual(1),
    );
    const readsBefore = fixture.catalogReader.mock.calls.length;
    const newDesktop = codexSeed(1, "thread-new-desktop");
    newDesktop.status = {
      ...newDesktop.status,
      activity: "working",
      runtimeAttachment: "loaded",
      confidence: "authoritative",
    };
    seeds.push(newDesktop);
    control.emit({
      kind: "event",
      event: {
        sequence: 1,
        observedAt: "2026-08-01T03:00:00.000Z",
        connectionGeneration: 1,
        method: "thread/started",
        threadId: "thread-new-desktop",
        threadStatus: { type: "active", activeFlags: [] },
      },
    });

    await vi.waitFor(() =>
      expect(fixture.catalogReader.mock.calls.length).toBeGreaterThan(
        readsBefore,
      ),
    );
    const internal = fixture.handler as unknown as {
      catalog: Map<string, { status: ConversationSyncStatus }>;
    };
    await vi.waitFor(() =>
      expect(
        internal.catalog.get("codex\0thread-new-desktop")?.status,
      ).toMatchObject({
        activity: "working",
        executionHost: "desktopAppServer",
        controlState: "readOnly",
        authorityGeneration: "daemon:1",
      }),
    );
    fixture.handler.close();
  });

  it("preserves special business state across control loss without churning idle rows", async () => {
    const control = createSharedControlSource({
      kind: "ready",
      connectionGeneration: 1,
    });
    const working = codexSeed(0, "thread-special");
    working.status = {
      ...working.status,
      activity: "working",
      attention: "question",
      runtimeAttachment: "loaded",
      confidence: "authoritative",
      observedAt: "2026-08-01T04:00:00.000Z",
      activeTurnId: "turn-special",
      attentionRequestId: "request-special",
    };
    const idle = codexSeed(1, "thread-idle");
    const statusReader = vi.fn(
      async () =>
        new Map([
          ["codex\0thread-special", working.status],
          ["codex\0thread-idle", idle.status],
        ]),
    );
    const fixture = createFixture(
      [working, idle],
      async (target) => history(target.providerSessionId),
      {
        daemonMode: true,
        statusReader,
        sharedControlReconcileMs: 5,
      },
      { subscribeSharedRuntimeControl: control.subscribe },
    );
    const client = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() => expect(statusReader).toHaveBeenCalled());
    const internal = fixture.handler as unknown as {
      catalog: Map<string, { status: ConversationSyncStatus }>;
    };
    const idleBefore = structuredClone(
      internal.catalog.get("codex\0thread-idle")!.status,
    );

    control.emit({ kind: "not_ready", connectionGeneration: 1 });
    expect(internal.catalog.get("codex\0thread-special")?.status).toMatchObject(
      {
        activity: "working",
        attention: "question",
        result: "none",
        activeTurnId: "turn-special",
        attentionRequestId: "request-special",
        controlState: "unavailable",
        confidence: "unknown",
        observedAt: "2026-08-01T04:00:00.000Z",
      },
    );
    expect(internal.catalog.get("codex\0thread-idle")?.status).toEqual(
      idleBefore,
    );
    fixture.handler.close();
  });

  it("repairs a completion missed during disconnect with one bounded special-thread read", async () => {
    const control = createSharedControlSource({
      kind: "ready",
      connectionGeneration: 1,
    });
    const seed = codexSeed(0, "thread-missed-completion");
    let providerStatus: ConversationSyncStatus = {
      ...seed.status,
      activity: "working",
      runtimeAttachment: "loaded",
      confidence: "authoritative",
      observedAt: "2026-08-01T05:00:00.000Z",
      activeTurnId: "turn-missed",
    };
    const recoveryReader = vi.fn(async () => ({
      turnId: "turn-missed",
      status: "completed" as const,
      observedAt: "2026-08-01T05:00:05.000Z",
    }));
    const fixture = createFixture(
      [seed],
      async (target) => history(target.providerSessionId),
      {
        daemonMode: true,
        statusReader: async () =>
          new Map([["codex\0thread-missed-completion", providerStatus]]),
        sharedControlRecoveryReader: recoveryReader,
        sharedControlReconcileMs: 5,
      },
      { subscribeSharedRuntimeControl: control.subscribe },
    );
    const client = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "sync_complete").length,
      ).toBeGreaterThanOrEqual(1),
    );
    control.emit({ kind: "not_ready", connectionGeneration: 1 });
    providerStatus = {
      ...providerStatus,
      activity: "idle",
      observedAt: "2026-08-01T05:00:05.000Z",
    };
    control.emit({ kind: "ready", connectionGeneration: 2 });

    const internal = fixture.handler as unknown as {
      catalog: Map<string, { status: ConversationSyncStatus }>;
      liveContentRevisions: Map<string, unknown>;
    };
    await vi.waitFor(() =>
      expect(
        internal.catalog.get("codex\0thread-missed-completion")?.status,
      ).toMatchObject({
        activity: "idle",
        result: "completed",
        controlState: "readOnly",
        authorityGeneration: "daemon:2",
      }),
    );
    expect(recoveryReader).toHaveBeenCalledTimes(1);
    expect(recoveryReader).toHaveBeenCalledWith(
      {
        provider: "codex",
        providerSessionId: "thread-missed-completion",
      },
      expect.any(AbortSignal),
    );
    expect(
      internal.liveContentRevisions.has("codex\0thread-missed-completion"),
    ).toBe(true);
    fixture.handler.close();
  });

  it("passes the recovery deadline and generation signal to the app-server read", async () => {
    const control = createSharedControlSource({
      kind: "ready",
      connectionGeneration: 1,
    });
    const value = codexSeed(0, "thread-default-recovery-reader");
    const status = {
      ...value.status,
      activity: "working" as const,
      runtimeAttachment: "loaded" as const,
      confidence: "authoritative" as const,
      observedAt: "2026-08-01T05:05:00.000Z",
    };
    const listThreadTurns = vi.fn(async () => ({
      data: [
        {
          id: "turn-default-recovery",
          status: "completed",
          completedAt: "2026-08-01T05:05:05.000Z",
        },
      ],
      nextCursor: null,
    }));
    const process = {
      isRunning: true,
      listThreadTurns,
      stop: vi.fn(),
    } as unknown as CodexProcess;
    const fixture = createFixture(
      [value],
      async (target) => history(target.providerSessionId),
      {
        daemonMode: true,
        statusReader: async () =>
          new Map([["codex\0thread-default-recovery-reader", status]]),
        sharedControlRecoveryTimeoutMs: 17,
        sharedControlReconcileMs: 1,
      },
      {
        subscribeSharedRuntimeControl: control.subscribe,
        getActiveCodexProcess: () => process,
      },
    );
    const client = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "sync_complete").length,
      ).toBeGreaterThanOrEqual(1),
    );
    control.emit({ kind: "not_ready", connectionGeneration: 1 });
    control.emit({ kind: "ready", connectionGeneration: 2 });

    await vi.waitFor(() => expect(listThreadTurns).toHaveBeenCalledOnce());
    expect(listThreadTurns).toHaveBeenCalledWith(
      {
        threadId: "thread-default-recovery-reader",
        limit: 1,
        sortDirection: "desc",
        itemsView: "summary",
      },
      {
        signal: expect.any(AbortSignal),
        timeoutMs: 17,
      },
    );
    fixture.handler.close();
  });

  it("times out one hung recovery read without blocking the next thread", async () => {
    const control = createSharedControlSource({
      kind: "ready",
      connectionGeneration: 1,
    });
    const seeds = [
      codexSeed(0, "thread-hung"),
      codexSeed(1, "thread-recovers"),
    ];
    const statuses = new Map(
      seeds.map((item) => [
        `codex\0${item.entry.providerSessionId}`,
        {
          ...item.status,
          activity: "working" as const,
          runtimeAttachment: "loaded" as const,
          confidence: "authoritative" as const,
          observedAt: "2026-08-01T05:10:00.000Z",
        },
      ]),
    );
    const recoveryReader = vi.fn(
      async (target: { providerSessionId: string }) => {
        if (target.providerSessionId === "thread-hung") {
          return new Promise<never>(() => undefined);
        }
        return {
          turnId: "turn-recovers",
          status: "completed" as const,
          observedAt: "2026-08-01T05:10:05.000Z",
        };
      },
    );
    const fixture = createFixture(
      seeds,
      async (target) => history(target.providerSessionId),
      {
        daemonMode: true,
        statusReader: async () => statuses,
        sharedControlRecoveryReader: recoveryReader,
        sharedControlRecoveryTimeoutMs: 25,
        maxConcurrentSharedControlRecoveries: 2,
        sharedControlReconcileMs: 1,
      },
      { subscribeSharedRuntimeControl: control.subscribe },
    );
    const client = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "sync_complete").length,
      ).toBeGreaterThanOrEqual(1),
    );
    control.emit({ kind: "not_ready", connectionGeneration: 1 });
    control.emit({ kind: "ready", connectionGeneration: 2 });

    const internal = fixture.handler as unknown as {
      catalog: Map<string, { status: ConversationSyncStatus }>;
    };
    await vi.waitFor(() =>
      expect(
        internal.catalog.get("codex\0thread-recovers")?.status,
      ).toMatchObject({
        activity: "idle",
        result: "completed",
        authorityGeneration: "daemon:2",
      }),
    );
    await vi.waitFor(() =>
      expect(internal.catalog.get("codex\0thread-hung")?.status).toMatchObject({
        activity: "working",
        controlState: "unavailable",
        confidence: "unknown",
      }),
    );
    expect(recoveryReader).toHaveBeenCalledTimes(2);
    fixture.handler.close();
  });

  it("aborts an old recovery generation before reconciling the replacement generation", async () => {
    const control = createSharedControlSource({
      kind: "ready",
      connectionGeneration: 1,
    });
    const value = codexSeed(0, "thread-generation-recovery");
    const status = {
      ...value.status,
      activity: "working" as const,
      runtimeAttachment: "loaded" as const,
      confidence: "authoritative" as const,
      observedAt: "2026-08-01T05:20:00.000Z",
    };
    let firstSignal: AbortSignal | undefined;
    const recoveryReader = vi.fn(
      async (_target: unknown, signal: AbortSignal) => {
        if (!firstSignal) {
          firstSignal = signal;
          return new Promise<never>((_resolve, reject) => {
            signal.addEventListener("abort", () => reject(signal.reason), {
              once: true,
            });
          });
        }
        return {
          turnId: "turn-generation-recovery",
          status: "interrupted" as const,
          observedAt: "2026-08-01T05:20:05.000Z",
        };
      },
    );
    const fixture = createFixture(
      [value],
      async (target) => history(target.providerSessionId),
      {
        daemonMode: true,
        statusReader: async () =>
          new Map([["codex\0thread-generation-recovery", status]]),
        sharedControlRecoveryReader: recoveryReader,
        sharedControlRecoveryTimeoutMs: 1_000,
        sharedControlReconcileMs: 1,
      },
      { subscribeSharedRuntimeControl: control.subscribe },
    );
    const client = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "sync_complete").length,
      ).toBeGreaterThanOrEqual(1),
    );
    control.emit({ kind: "not_ready", connectionGeneration: 1 });
    control.emit({ kind: "ready", connectionGeneration: 2 });
    await vi.waitFor(() => expect(firstSignal).toBeDefined());

    control.emit({ kind: "not_ready", connectionGeneration: 2 });
    expect(firstSignal!.aborted).toBe(true);
    control.emit({ kind: "ready", connectionGeneration: 3 });

    const internal = fixture.handler as unknown as {
      catalog: Map<string, { status: ConversationSyncStatus }>;
    };
    await vi.waitFor(() =>
      expect(
        internal.catalog.get("codex\0thread-generation-recovery")?.status,
      ).toMatchObject({
        activity: "idle",
        controlState: "readOnly",
        authorityGeneration: "daemon:3",
      }),
    );
    expect(recoveryReader).toHaveBeenCalledTimes(2);
    fixture.handler.close();
  });

  it("does not let a late same-generation recovery overwrite a live control event", async () => {
    const control = createSharedControlSource({
      kind: "ready",
      connectionGeneration: 1,
    });
    const value = codexSeed(0, "thread-live-wins-recovery");
    const status = {
      ...value.status,
      activity: "working" as const,
      runtimeAttachment: "loaded" as const,
      confidence: "authoritative" as const,
      observedAt: "2026-08-01T05:25:00.000Z",
      activeTurnId: "turn-live-wins-recovery",
    };
    let resolveRecovery:
      | ((snapshot: {
          turnId: string;
          status: "inProgress";
          observedAt: string;
        }) => void)
      | undefined;
    const recoveryReader = vi.fn(
      () =>
        new Promise<{
          turnId: string;
          status: "inProgress";
          observedAt: string;
        }>((resolve) => {
          resolveRecovery = resolve;
        }),
    );
    const fixture = createFixture(
      [value],
      async (target) => history(target.providerSessionId),
      {
        daemonMode: true,
        statusReader: async () =>
          new Map([["codex\0thread-live-wins-recovery", status]]),
        sharedControlRecoveryReader: recoveryReader,
        sharedControlRecoveryTimeoutMs: 1_000,
        sharedControlReconcileMs: 1,
      },
      { subscribeSharedRuntimeControl: control.subscribe },
    );
    const client = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "sync_complete").length,
      ).toBeGreaterThanOrEqual(1),
    );
    control.emit({ kind: "not_ready", connectionGeneration: 1 });
    control.emit({ kind: "ready", connectionGeneration: 2 });
    await vi.waitFor(() => expect(recoveryReader).toHaveBeenCalledOnce());

    control.emit({
      kind: "event",
      event: {
        sequence: 1,
        observedAt: "2026-08-01T05:25:05.000Z",
        connectionGeneration: 2,
        method: "turn/completed",
        threadId: "thread-live-wins-recovery",
        turnId: "turn-live-wins-recovery",
        turnStatus: "completed",
      },
    });
    resolveRecovery?.({
      turnId: "turn-live-wins-recovery",
      status: "inProgress",
      observedAt: "2026-08-01T05:25:01.000Z",
    });

    const internal = fixture.handler as unknown as {
      catalog: Map<string, { status: ConversationSyncStatus }>;
    };
    await vi.waitFor(() =>
      expect(
        internal.catalog.get("codex\0thread-live-wins-recovery")?.status,
      ).toMatchObject({
        activity: "idle",
        result: "completed",
        observedAt: "2026-08-01T05:25:05.000Z",
        authorityGeneration: "daemon:2",
      }),
    );
    expect(recoveryReader).toHaveBeenCalledOnce();
    fixture.handler.close();
  });

  it("recovers sixty-four targets with at most four concurrent reads", async () => {
    const control = createSharedControlSource({
      kind: "ready",
      connectionGeneration: 1,
    });
    const seeds = Array.from({ length: 64 }, (_, index) =>
      codexSeed(index, `thread-bounded-${index}`),
    );
    const statuses = new Map(
      seeds.map((item) => [
        `codex\0${item.entry.providerSessionId}`,
        {
          ...item.status,
          activity: "working" as const,
          runtimeAttachment: "loaded" as const,
          confidence: "authoritative" as const,
          observedAt: "2026-08-01T05:30:00.000Z",
        },
      ]),
    );
    let activeReads = 0;
    let maxActiveReads = 0;
    const recoveryReader = vi.fn(
      async (target: { providerSessionId: string }) => {
        activeReads += 1;
        maxActiveReads = Math.max(maxActiveReads, activeReads);
        await new Promise<void>((resolve) => setTimeout(resolve, 2));
        activeReads -= 1;
        return {
          turnId: `turn-${target.providerSessionId}`,
          status: "interrupted" as const,
          observedAt: "2026-08-01T05:30:05.000Z",
        };
      },
    );
    const fixture = createFixture(
      seeds,
      async (target) => history(target.providerSessionId),
      {
        daemonMode: true,
        statusReader: async () => statuses,
        sharedControlRecoveryReader: recoveryReader,
        sharedControlRecoveryTimeoutMs: 1_000,
        maxConcurrentSharedControlRecoveries: 4,
        sharedControlReconcileMs: 1,
      },
      { subscribeSharedRuntimeControl: control.subscribe },
    );
    const client = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    await vi.waitFor(() =>
      expect(
        events(fixture.sent, client, "sync_complete").length,
      ).toBeGreaterThanOrEqual(1),
    );
    control.emit({ kind: "not_ready", connectionGeneration: 1 });
    control.emit({ kind: "ready", connectionGeneration: 2 });

    await vi.waitFor(() => expect(recoveryReader).toHaveBeenCalledTimes(64), {
      timeout: 3_000,
    });
    expect(maxActiveReads).toBeGreaterThanOrEqual(2);
    expect(maxActiveReads).toBeLessThanOrEqual(4);
    const internal = fixture.handler as unknown as {
      catalog: Map<string, { status: ConversationSyncStatus }>;
    };
    await vi.waitFor(
      () =>
        expect(
          [...internal.catalog.values()].filter(
            (record) =>
              record.status.authorityGeneration === "daemon:2" &&
              record.status.activity === "idle",
          ),
        ).toHaveLength(64),
      { timeout: 3_000 },
    );
    fixture.handler.close();
  });

  it("reprojects an older pending action when the latest same-thread action resolves", async () => {
    const first = actionRequest("action-a", "turn-a", "user_input");
    const second = actionRequest("action-b", "turn-b", "command_approval");
    const broker = createActionBrokerSource([first, second]);
    const seed = codexSeed(0, "thread-actions");
    const fixture = createFixture(
      [seed],
      async (target) => history(target.providerSessionId),
      {},
      { codexActionBroker: broker.runtime },
    );
    const client = {};
    await fixture.handler.handle(
      subscribeMessage(),
      context(client, fixture.runtime),
    );
    const internal = fixture.handler as unknown as {
      catalog: Map<string, { status: ConversationSyncStatus }>;
    };
    await vi.waitFor(() =>
      expect(
        internal.catalog.get("codex\0thread-actions")?.status,
      ).toMatchObject({
        attention: "approval",
        attentionRequestId: "action-b",
      }),
    );

    broker.setRequests([first]);
    broker.emit({
      kind: "request",
      request: { ...second, state: "resolved", live: false },
    });
    expect(internal.catalog.get("codex\0thread-actions")?.status).toMatchObject(
      {
        attention: "question",
        attentionRequestId: "action-a",
        activeTurnId: "turn-a",
      },
    );
    fixture.handler.close();
  });
});

function createSharedControlSource(
  initial: Extract<
    LocalFeatureSharedRuntimeControlUpdate,
    { kind: "ready" | "not_ready" }
  >,
) {
  let current = initial;
  const listeners = new Set<
    (update: LocalFeatureSharedRuntimeControlUpdate) => void
  >();
  const subscribe: NonNullable<
    LocalFeatureRuntime["subscribeSharedRuntimeControl"]
  > = (listener) => {
    listeners.add(listener);
    listener(current);
    let active = true;
    return () => {
      if (!active) return;
      active = false;
      listeners.delete(listener);
    };
  };
  return {
    subscribe,
    emit(update: LocalFeatureSharedRuntimeControlUpdate): void {
      if (update.kind !== "event") current = update;
      for (const listener of [...listeners]) listener(update);
    },
    get listenerCount(): number {
      return listeners.size;
    },
  };
}

function actionRequest(
  opaqueRequestId: string,
  turnId: string,
  kind: CodexActionBrokerRuntimeRequest["kind"],
): CodexActionBrokerRuntimeRequest {
  return {
    opaqueRequestId,
    codexSourceId: "source-1",
    threadId: "thread-actions",
    turnId,
    kind,
    state: "pending",
    observedAt: "2026-08-01T06:00:00.000Z",
    expiresAt: "2026-08-02T06:00:00.000Z",
    updatedAt:
      opaqueRequestId === "action-a"
        ? "2026-08-01T06:00:00.000Z"
        : "2026-08-01T06:00:01.000Z",
    authorityGeneration: "cab:1:1",
    live: true,
    allowedActions:
      kind === "user_input" ? ["answer", "reject"] : ["approve", "reject"],
  };
}

function createActionBrokerSource(initial: CodexActionBrokerRuntimeRequest[]): {
  runtime: CodexActionBrokerRuntime;
  emit(update: CodexActionBrokerRuntimeUpdate): void;
  setRequests(requests: CodexActionBrokerRuntimeRequest[]): void;
} {
  let requests = [...initial];
  const listeners = new Set<(update: CodexActionBrokerRuntimeUpdate) => void>();
  const runtime = {
    health: {
      ready: true,
      controlReady: true,
      degraded: false,
      writerLeaseHeld: true,
      authorityGeneration: "cab:1:1",
    },
    listRequests: (options?: { threadId?: string }) =>
      requests.filter(
        (request) =>
          !options?.threadId || request.threadId === options.threadId,
      ),
    subscribe: (listener: (update: CodexActionBrokerRuntimeUpdate) => void) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
  } as unknown as CodexActionBrokerRuntime;
  return {
    runtime,
    emit(update) {
      for (const listener of [...listeners]) listener(update);
    },
    setRequests(next) {
      requests = [...next];
    },
  };
}

function createFixture(
  seeds: Array<{
    entry: ConversationSyncCatalogEntry;
    status: ConversationSyncStatus;
  }>,
  historyReader: (target: {
    provider: "claude" | "codex";
    providerSessionId: string;
  }) => Promise<
    | ServerMessage[]
    | { messages: ServerMessage[]; nextTurnCursor: string | null }
  >,
  handlerOptions: NonNullable<
    ConstructorParameters<typeof ConversationSyncV2FeatureHandler>[1]
  > = {},
  runtimeOverrides: Partial<LocalFeatureRuntime> = {},
) {
  const sent = new Map<object, ConversationSyncServerMessage[]>();
  const catalogReader = vi.fn(async () => seeds);
  const runtime: LocalFeatureRuntime = {
    bridgeInstanceId: "bridge-1",
    codexSourceId: "source-1",
    getSession: () => undefined,
    getCodexThreadId: () => undefined,
    getProviderSessionId: () => undefined,
    getActiveCodexProcess: () => null,
    createStandaloneCodexProcess: async () => {
      throw new Error("not used");
    },
    send(client: object, message: ConversationSyncServerMessage) {
      const messages = sent.get(client) ?? [];
      messages.push(message);
      sent.set(client, messages);
    },
    isClientOpen: () => true,
    supports: (_client: object, type: string) =>
      type === CONVERSATION_SYNC_V2_CAPABILITY,
    ...runtimeOverrides,
  };
  return {
    runtime,
    sent,
    catalogReader,
    handler: new ConversationSyncV2FeatureHandler(runtime, {
      catalogReader,
      statusReader: async () => new Map(),
      historyReader,
      statusWatchdogMs: 60_000,
      coldReconcileMs: 60_000,
      daemonMode: false,
      ...handlerOptions,
    }),
  };
}

function createCodexPageFixture(
  processMethods: Partial<
    Pick<CodexProcess, "listThreadTurns" | "listThreadItems">
  >,
  historyReader?: (target: {
    provider: "claude" | "codex";
    providerSessionId: string;
  }) => Promise<
    | ServerMessage[]
    | { messages: ServerMessage[]; nextTurnCursor: string | null }
  >,
  handlerOptions: NonNullable<
    ConstructorParameters<typeof ConversationSyncV2FeatureHandler>[1]
  > = {},
) {
  const sent = new Map<object, ConversationSyncServerMessage[]>();
  const client = {};
  const process = {
    isRunning: true,
    listThreadTurns:
      processMethods.listThreadTurns ??
      (async () => ({ data: [], nextCursor: null })),
    listThreadItems:
      processMethods.listThreadItems ??
      (async () => ({ data: [], nextCursor: null })),
    stop: vi.fn(),
  } as unknown as CodexProcess;
  const runtime: LocalFeatureRuntime = {
    bridgeInstanceId: "bridge-1",
    codexSourceId: "source-1",
    getSession: () => undefined,
    getCodexThreadId: () => undefined,
    getProviderSessionId: () => undefined,
    getActiveCodexProcess: () => process,
    createStandaloneCodexProcess: async () => {
      throw new Error("active reader should be reused");
    },
    send(targetClient: object, message: ConversationSyncServerMessage) {
      const messages = sent.get(targetClient) ?? [];
      messages.push(message);
      sent.set(targetClient, messages);
    },
    isClientOpen: () => true,
    supports: (_client: object, type: string) =>
      type === CONVERSATION_SYNC_V2_CAPABILITY,
  };
  return {
    client,
    runtime,
    sent,
    handler: new ConversationSyncV2FeatureHandler(runtime, {
      catalogReader: async () => [],
      statusReader: async () => new Map(),
      ...(historyReader ? { historyReader } : {}),
      inspectCodexThread: async () => null,
      statusWatchdogMs: 60_000,
      coldReconcileMs: 60_000,
      daemonMode: false,
      ...handlerOptions,
    }),
  };
}

function decreasingLimitCallCount(initial: number, final: number): number {
  let count = 1;
  let current = initial;
  while (current > final) {
    current = Math.max(1, Math.floor(current / 2));
    count += 1;
  }
  return count;
}

function context(client: object, runtime: LocalFeatureRuntime) {
  return {
    client,
    signal: new AbortController().signal,
    runtime,
  };
}

function terminalScopeForFixture() {
  return { bridgeInstanceId: "bridge-1", codexSourceId: "source-1" };
}

function subscribeMessage(
  threadContentStates: Array<{
    provider: "claude" | "codex";
    providerSessionId: string;
    revision: string;
  }> = [],
  state: { catalogState?: string; statusState?: string } = {},
): Extract<
  ConversationSyncClientMessage,
  { type: "conversation_sync_subscribe" }
> {
  return {
    type: "conversation_sync_subscribe",
    protocolVersion: 2,
    requestId: `sync-${Math.random().toString(36).slice(2)}`,
    ...state,
    threadContentStates,
    readWatermarks: [],
  };
}

function seed(
  index: number,
  status = unknownStatus(index),
): {
  entry: ConversationSyncCatalogEntry;
  status: ConversationSyncStatus;
} {
  const recency = new Date(Date.now() - index * 60_000).toISOString();
  return {
    entry: {
      provider: "claude",
      providerSessionId: `session-${index}`,
      revision: `revision-${index}`,
      projectPath: `/project/${index}`,
      firstPrompt: `Conversation ${index}`,
      createdAt: recency,
      modifiedAt: recency,
      recencyAt: recency,
      availability: "durable",
    },
    status,
  };
}

function codexSeed(index: number, threadId: string) {
  const value = seed(index);
  return {
    entry: {
      ...value.entry,
      provider: "codex" as const,
      providerSessionId: threadId,
    },
    status: {
      ...value.status,
      provider: "codex" as const,
      providerSessionId: threadId,
      source: "appServer" as const,
    },
  };
}

function unknownStatus(index: number): ConversationSyncStatus {
  return {
    provider: "claude",
    providerSessionId: `session-${index}`,
    activity: "unknown",
    attention: "none",
    result: "none",
    runtimeAttachment: "notLoaded",
    source: "legacyRollout",
    confidence: "unknown",
    observedAt: new Date(Date.now() - index * 60_000).toISOString(),
  };
}

function workingStatus(index: number): ConversationSyncStatus {
  return {
    ...unknownStatus(index),
    activity: "working",
    runtimeAttachment: "loaded",
    source: "bridgeRuntime",
    confidence: "authoritative",
  };
}

function timestampedCodexTurn() {
  return {
    id: "turn-timestamps",
    startedAt: 1_700_000_000,
    completedAt: 1_700_000_100,
    items: [
      {
        type: "userMessage",
        id: "user-item",
        content: [{ type: "text", text: "inspect this" }],
      },
      {
        type: "dynamicToolCall",
        id: "tool-item",
        tool: "Read",
        arguments: { path: "/tmp/example.txt" },
        status: "completed",
        contentItems: [{ type: "inputText", text: "contents" }],
      },
      {
        type: "agentMessage",
        id: "assistant-item",
        text: "finished",
      },
    ],
  };
}

function history(id: string): ServerMessage[] {
  return [
    {
      type: "user_input",
      text: id,
      userMessageUuid: `user-${id}`,
    },
    {
      type: "assistant",
      messageUuid: `assistant-${id}`,
      message: {
        id: `assistant-${id}`,
        role: "assistant",
        model: "test",
        content: [{ type: "text", text: `reply-${id}` }],
      },
    },
  ];
}

function events<Event extends ConversationSyncServerMessage["event"]>(
  sent: Map<object, ConversationSyncServerMessage[]>,
  client: object,
  event: Event,
): Array<Extract<ConversationSyncServerMessage, { event: Event }>> {
  return (sent.get(client) ?? []).filter(
    (
      message,
    ): message is Extract<ConversationSyncServerMessage, { event: Event }> =>
      message.event === event,
  );
}
