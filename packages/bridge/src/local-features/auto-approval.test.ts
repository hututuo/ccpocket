import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { CodexProcess } from "../codex-process.js";
import type {
  CodexActionBrokerRuntime,
  CodexActionBrokerRuntimeHealth,
  CodexActionBrokerRuntimeRequest,
  CodexActionBrokerRuntimeUpdate,
  CodexActionBrokerRespondInput,
  CodexActionBrokerRespondResult,
} from "../codex-action-broker-runtime.js";
import type { ServerMessage } from "../parser.js";
import {
  AutoApprovalFeatureHandler,
  AutoApprovalStore,
  isAutoApprovableBrokerRequest,
  isAutoApprovablePermission,
  shellCommandRequiresManualApproval,
} from "./auto-approval.js";
import {
  AUTO_APPROVAL_STATE_CAPABILITY,
  AUTO_APPROVAL_SUPERVISION_CAPABILITY,
} from "./slots/auto-approval-protocol.js";
import type { LocalFeatureRuntime, LocalFeatureSession } from "./runtime.js";

const temporaryRoots: string[] = [];
const CODEX_SOURCE_A = "codex-source-a";
const CODEX_SOURCE_B = "codex-source-b";

afterEach(async () => {
  await Promise.all(
    temporaryRoots.splice(0).map((path) => rm(path, { recursive: true })),
  );
});

async function storeFixture(): Promise<AutoApprovalStore> {
  const root = await mkdtemp(join(tmpdir(), "ccpocket-auto-approval-"));
  temporaryRoots.push(root);
  return new AutoApprovalStore({ filePath: join(root, "state.json") });
}

describe("Bridge-owned auto approval policy", () => {
  it("allows ordinary and network commands without treating quoted rm as executable", () => {
    const safeCommands = [
      "pwd",
      "curl -fsSL https://example.test/data",
      "echo 'rm -rf /'",
      "printf '%s\\n' rm > output.txt",
      "git fetch origin 2>&1",
      "env HTTPS_PROXY=http://127.0.0.1:8080 wget https://example.test",
    ];

    for (const command of safeCommands) {
      expect(shellCommandRequiresManualApproval(command), command).toBe(false);
    }
  });

  it("keeps direct, wrapped, nested, and compound rm commands manual", () => {
    const destructiveCommands = [
      "rm notes.txt",
      "/bin/rm -rf build",
      "sudo -u root rm -rf /tmp/example",
      "env MODE=clean rm output.txt",
      "pwd && rm output.txt",
      "bash -lc 'rm -rf build'",
      "xargs rm < files.txt",
      "xargs -0 sh -c 'rm -rf build' < files.txt",
      "busybox rm -rf build",
      "git reset --hard HEAD",
      "git clean -fdx",
      "find . -name '*.tmp' -delete",
      "find . -name '*.tmp' -exec sh -c 'rm -f \"$1\"' _ {} \\;",
      "echo $(rm -f hidden.txt)",
      "dd if=/dev/zero of=disk.img",
    ];

    for (const command of destructiveCommands) {
      expect(shellCommandRequiresManualApproval(command), command).toBe(true);
    }
  });

  it("allows canonical approvals but leaves questions and installations manual", () => {
    expect(
      isAutoApprovablePermission(
        permission("Bash", {
          networkApprovalContext: { host: "example.test" },
        }),
      ),
    ).toBe(true);
    expect(isAutoApprovablePermission(permission("FileChange"))).toBe(true);
    expect(isAutoApprovablePermission(permission("Permissions"))).toBe(true);
    expect(isAutoApprovablePermission(permission("ExitPlanMode"))).toBe(true);
    expect(
      isAutoApprovablePermission(
        permission("McpElicitation", {
          mode: "form",
          availableDecisions: ["accept", "decline"],
        }),
      ),
    ).toBe(true);

    expect(isAutoApprovablePermission(permission("AskUserQuestion"))).toBe(
      false,
    );
    expect(isAutoApprovablePermission(permission("ToolSuggestion"))).toBe(
      false,
    );
    expect(
      isAutoApprovablePermission(
        permission("McpElicitation", {
          mode: "form",
          availableDecisions: ["accept"],
          requestedSchema: { type: "object" },
        }),
      ),
    ).toBe(false);
  });

  it("applies the same fail-closed allowlist to live Action Broker requests", () => {
    expect(isAutoApprovableBrokerRequest(brokerRequest())).toBe(true);
    expect(
      isAutoApprovableBrokerRequest(
        brokerRequest({ input: { command: "sudo rm -rf build" } }),
      ),
    ).toBe(false);
    expect(
      isAutoApprovableBrokerRequest(
        brokerRequest({ kind: "user_input", toolName: "AskUserQuestion" }),
      ),
    ).toBe(false);
    expect(
      isAutoApprovableBrokerRequest(
        brokerRequest({ allowedActions: ["reject"] }),
      ),
    ).toBe(false);
    expect(isAutoApprovableBrokerRequest(brokerRequest({ live: false }))).toBe(
      false,
    );
  });
});

describe("AutoApprovalStore", () => {
  it("persists source-scoped grants and only disables the authenticated source", async () => {
    const store = await storeFixture();
    await store.setEnabled(CODEX_SOURCE_A, "thread-1", true);
    await store.setEnabled(CODEX_SOURCE_A, "thread-2", true);
    await store.setEnabled(CODEX_SOURCE_B, "thread-1", true);
    expect(await store.isActive(CODEX_SOURCE_A, "thread-1")).toBe(true);
    expect(await store.visibleState(CODEX_SOURCE_A, "thread-2")).toEqual({
      enabled: true,
      enabledConversationCount: 2,
    });
    expect(await store.visibleState(CODEX_SOURCE_B, "thread-1")).toEqual({
      enabled: true,
      enabledConversationCount: 1,
    });

    const reopened = new AutoApprovalStore({ filePath: store.filePath });
    expect(await reopened.isActive(CODEX_SOURCE_A, "thread-1")).toBe(true);
    expect(await reopened.isActive(CODEX_SOURCE_B, "thread-1")).toBe(true);
    await reopened.disableAll(CODEX_SOURCE_A);
    expect(await reopened.visibleState(CODEX_SOURCE_A, "thread-1")).toEqual({
      enabled: false,
      enabledConversationCount: 0,
    });
    expect(await reopened.isActive(CODEX_SOURCE_B, "thread-1")).toBe(true);
    expect(JSON.parse(await readFile(store.filePath, "utf8"))).toEqual({
      version: 2,
      enabledConversations: [
        {
          codexSourceId: CODEX_SOURCE_B,
          threadId: "thread-1",
        },
      ],
    });
  });

  it("reloads policy from disk when shared writer authority changes", async () => {
    const leader = await storeFixture();
    await leader.setEnabled(CODEX_SOURCE_A, "thread-1", true);
    const standby = new AutoApprovalStore({ filePath: leader.filePath });
    expect(await standby.isActive(CODEX_SOURCE_A, "thread-1")).toBe(true);

    await leader.setEnabled(CODEX_SOURCE_A, "thread-1", false);
    expect(await standby.isActive(CODEX_SOURCE_A, "thread-1")).toBe(true);
    await standby.reloadFromDisk();
    expect(await standby.isActive(CODEX_SOURCE_A, "thread-1")).toBe(false);
  });

  it("fails closed when persisted state is malformed", async () => {
    const store = await storeFixture();
    await store.setEnabled(CODEX_SOURCE_A, "thread-1", true);
    const invalid = new AutoApprovalStore({ filePath: store.filePath });
    await writeFile(store.filePath, '{"version":99}', "utf8");
    expect(await invalid.isActive(CODEX_SOURCE_A, "thread-1")).toBe(false);
  });

  it("quarantines a v1 thread-only file until one source is explicitly confirmed", async () => {
    const store = await storeFixture();
    await writeFile(
      store.filePath,
      JSON.stringify({
        version: 1,
        enabledThreadIds: ["thread-legacy"],
      }),
      "utf8",
    );

    expect(await store.isActive(CODEX_SOURCE_A, "thread-legacy")).toBe(false);
    expect(await store.isActive(CODEX_SOURCE_B, "thread-legacy")).toBe(false);

    await store.setEnabled(CODEX_SOURCE_A, "thread-legacy", true);
    expect(JSON.parse(await readFile(store.filePath, "utf8"))).toEqual({
      version: 2,
      enabledConversations: [
        {
          codexSourceId: CODEX_SOURCE_A,
          threadId: "thread-legacy",
        },
      ],
      quarantinedLegacyThreadIds: ["thread-legacy"],
    });

    const reopened = new AutoApprovalStore({ filePath: store.filePath });
    expect(await reopened.isActive(CODEX_SOURCE_A, "thread-legacy")).toBe(true);
    expect(await reopened.isActive(CODEX_SOURCE_B, "thread-legacy")).toBe(
      false,
    );
  });

  it("accepts an old Mobile import without turning unscoped IDs into grants", async () => {
    const store = await storeFixture();
    expect(await store.importLegacy(CODEX_SOURCE_A, ["thread-legacy"])).toBe(
      true,
    );
    expect(await store.isActive(CODEX_SOURCE_A, "thread-legacy")).toBe(false);
    expect(await store.isActive(CODEX_SOURCE_B, "thread-legacy")).toBe(false);
    expect(await store.importLegacy(CODEX_SOURCE_A, ["thread-stale"])).toBe(
      false,
    );
    expect(JSON.parse(await readFile(store.filePath, "utf8"))).toEqual({
      version: 2,
      enabledConversations: [],
      quarantinedLegacyThreadIds: ["thread-legacy"],
    });
  });
});

describe("AutoApprovalFeatureHandler", () => {
  it("stores the setting on Bridge and returns authoritative state", async () => {
    const store = await storeFixture();
    const fixture = handlerFixture(store);
    fixture.handler.capabilitiesChanged(fixture.client);

    await fixture.handler.handle(
      {
        type: "set_auto_approval",
        sessionId: fixture.session.id,
        requestId: "request-1",
        enabled: true,
      },
      fixture.context,
    );

    expect(await store.isActive(CODEX_SOURCE_A, "thread-1")).toBe(true);
    expect(fixture.sent).toContainEqual({
      type: "auto_approval_state_v1",
      requestId: "request-1",
      sessionId: "session-1",
      codexSourceId: CODEX_SOURCE_A,
      providerSessionId: "thread-1",
      enabled: true,
      enabledConversationCount: 1,
      approvedCount: 0,
      supervisionAvailable: true,
      supervisionMode: "private_legacy",
      reason: "updated",
    });
  });

  it("queries the same thread ID independently for each Codex source", async () => {
    const store = await storeFixture();
    const sourceA = handlerFixture(store, {
      codexSourceId: CODEX_SOURCE_A,
    });
    const sourceB = handlerFixture(store, {
      codexSourceId: CODEX_SOURCE_B,
    });
    sourceA.handler.capabilitiesChanged(sourceA.client);
    sourceB.handler.capabilitiesChanged(sourceB.client);

    await sourceA.handler.handle(
      {
        type: "set_auto_approval",
        sessionId: sourceA.session.id,
        requestId: "source-a-enable",
        enabled: true,
      },
      sourceA.context,
    );
    await sourceB.handler.handle(
      {
        type: "get_auto_approval_state",
        sessionId: sourceB.session.id,
        requestId: "source-b-query",
      },
      sourceB.context,
    );

    expect(sourceB.sent).toContainEqual({
      type: "auto_approval_state_v1",
      requestId: "source-b-query",
      sessionId: "session-1",
      codexSourceId: CODEX_SOURCE_B,
      providerSessionId: "thread-1",
      enabled: false,
      enabledConversationCount: 0,
      approvedCount: 0,
      supervisionAvailable: true,
      supervisionMode: "private_legacy",
      reason: "query",
    });
  });

  it("does not claim supervision for an independent Desktop app-server", async () => {
    const store = await storeFixture();
    const fixture = handlerFixture(store);
    fixture.session.process = {};
    fixture.handler.capabilitiesChanged(fixture.client);

    await fixture.handler.handle(
      {
        type: "get_auto_approval_state",
        sessionId: fixture.session.id,
        requestId: "desktop-request",
      },
      fixture.context,
    );

    expect(fixture.sent).toContainEqual({
      type: "auto_approval_state_v1",
      requestId: "desktop-request",
      sessionId: "session-1",
      codexSourceId: CODEX_SOURCE_A,
      enabledConversationCount: 0,
      supervisionAvailable: false,
      supervisionMode: "private_legacy",
      unavailableReason: "external_app_server",
      supervisionUnavailableReason: "external_app_server",
      reason: "query",
      errorCode: "external_app_server_approval_unsupported",
      error: expect.stringContaining("independent Codex app-server"),
    });
  });

  it("keeps the advertised v1 payload parseable for an older Mobile", async () => {
    const store = await storeFixture();
    const fixture = handlerFixture(store, {
      capabilities: new Set([AUTO_APPROVAL_STATE_CAPABILITY]),
    });
    fixture.session.process = {};
    fixture.handler.capabilitiesChanged(fixture.client);

    await fixture.handler.handle(
      {
        type: "get_auto_approval_state",
        sessionId: fixture.session.id,
        requestId: "legacy-v1-request",
      },
      fixture.context,
    );

    expect(fixture.sent).toContainEqual({
      type: "auto_approval_state_v1",
      requestId: "legacy-v1-request",
      sessionId: "session-1",
      enabledConversationCount: 0,
      reason: "query",
      errorCode: "external_app_server_approval_unsupported",
      error: expect.stringContaining("independent Codex app-server"),
    });
    expect(fixture.sent).not.toContainEqual(
      expect.objectContaining({
        supervisionAvailable: expect.anything(),
      }),
    );
  });

  it("fails closed when the Bridge cannot authenticate a Codex source", async () => {
    const store = await storeFixture();
    const fixture = handlerFixture(store, { codexSourceId: null });
    fixture.handler.capabilitiesChanged(fixture.client);

    await fixture.handler.handle(
      {
        type: "set_auto_approval",
        sessionId: fixture.session.id,
        requestId: "missing-source-request",
        enabled: true,
      },
      fixture.context,
    );

    expect(await store.isActive(CODEX_SOURCE_A, "thread-1")).toBe(false);
    expect(fixture.sent).toContainEqual({
      type: "auto_approval_state_v1",
      requestId: "missing-source-request",
      sessionId: "session-1",
      enabledConversationCount: 0,
      supervisionAvailable: false,
      supervisionMode: "private_legacy",
      unavailableReason: "unsupported_session",
      supervisionUnavailableReason: "unsupported_session",
      reason: "updated",
      errorCode: "codex_source_unavailable",
      error: "Auto approval requires an authenticated Codex source",
    });
  });

  it("approves a safe request without any connected phone", async () => {
    const store = await storeFixture();
    await store.setEnabled(CODEX_SOURCE_A, "thread-1", true);
    const fixture = handlerFixture(store);
    const pending = permission("Bash", {
      command: "curl https://example.test",
    });
    let current: ServerMessage | undefined = pending;
    vi.spyOn(fixture.process, "getPendingPermission").mockImplementation(
      (id) =>
        current?.type === "permission_request" && current.toolUseId === id
          ? {
              toolUseId: current.toolUseId,
              toolName: current.toolName,
              input: current.input,
            }
          : undefined,
    );
    const approve = vi
      .spyOn(fixture.process, "approve")
      .mockImplementation(() => {
        current = undefined;
      });

    fixture.handler.sessionMessage(fixture.session, pending);

    await vi.waitFor(() => expect(approve).toHaveBeenCalledWith("tool-1"));
    expect(fixture.sent).toEqual([]);
  });

  it("does not supervise the same thread ID under another Codex source", async () => {
    const store = await storeFixture();
    await store.setEnabled(CODEX_SOURCE_A, "thread-1", true);
    const fixture = handlerFixture(store, {
      codexSourceId: CODEX_SOURCE_B,
    });
    const pending = permission("Bash", {
      command: "curl https://example.test",
    });
    vi.spyOn(fixture.process, "getPendingPermission").mockReturnValue({
      toolUseId: pending.toolUseId,
      toolName: pending.toolName,
      input: pending.input,
    });
    const approve = vi.spyOn(fixture.process, "approve");

    fixture.handler.sessionMessage(fixture.session, pending);
    await new Promise<void>((resolve) => setImmediate(resolve));

    expect(approve).not.toHaveBeenCalled();
    expect(await store.isActive(CODEX_SOURCE_A, "thread-1")).toBe(true);
    expect(await store.isActive(CODEX_SOURCE_B, "thread-1")).toBe(false);
  });

  it("never approves rm and does not depend on Mobile eligibility", async () => {
    const store = await storeFixture();
    await store.setEnabled(CODEX_SOURCE_A, "thread-1", true);
    const fixture = handlerFixture(store);
    const approve = vi.spyOn(fixture.process, "approve");

    fixture.handler.sessionMessage(
      fixture.session,
      permission("Bash", { command: "sudo rm -rf build" }),
    );
    await new Promise((resolve) => setTimeout(resolve, 10));

    expect(approve).not.toHaveBeenCalled();
  });

  it("supervises a Desktop-origin shared request by durable source and thread while the phone is offline", async () => {
    const store = await storeFixture();
    const broker = actionBrokerFixture();
    const fixture = handlerFixture(store, {
      codexActionBroker: broker.runtime,
      topology: "shared",
      bridgeInstanceId: "bridge-a",
    });
    fixture.session.process = {};
    fixture.handler.capabilitiesChanged(fixture.client);

    await fixture.handler.handle(
      {
        type: "set_auto_approval",
        requestId: "desktop-enable",
        codexSourceId: CODEX_SOURCE_A,
        providerSessionId: "thread-1",
        enabled: true,
      },
      fixture.context,
    );
    expect(fixture.sent).toContainEqual(
      expect.objectContaining({
        requestId: "desktop-enable",
        codexSourceId: CODEX_SOURCE_A,
        providerSessionId: "thread-1",
        enabled: true,
        supervisionAvailable: true,
        supervisionMode: "action_broker",
      }),
    );

    fixture.handler.disconnect(fixture.client);
    const request = brokerRequest();
    broker.requests.push(request);
    broker.emit({ kind: "request", request });

    await vi.waitFor(() => expect(broker.respond).toHaveBeenCalledTimes(1));
    expect(broker.respond).toHaveBeenCalledWith(
      expect.objectContaining({
        opaqueRequestId: "opaque-1",
        codexSourceId: CODEX_SOURCE_A,
        threadId: "thread-1",
        turnId: "turn-1",
        authorityGeneration: "cab:7:3",
        action: "approve",
      }),
    );
    fixture.handler.close();
  });

  it("never uses transient process approval for a Bridge-origin shared attachment", async () => {
    const store = await storeFixture();
    const broker = actionBrokerFixture();
    const fixture = handlerFixture(store, {
      codexActionBroker: broker.runtime,
      topology: "shared",
    });
    const approve = vi.spyOn(fixture.process, "approve");

    await fixture.handler.handle(
      {
        type: "set_auto_approval",
        sessionId: fixture.session.id,
        requestId: "legacy-session-enable",
        enabled: true,
      },
      fixture.context,
    );
    expect(await store.isActive(CODEX_SOURCE_A, "thread-1")).toBe(true);

    fixture.handler.sessionMessage(
      fixture.session,
      permission("Bash", { command: "pwd" }),
    );
    await new Promise<void>((resolve) => setImmediate(resolve));
    expect(approve).not.toHaveBeenCalled();

    const request = brokerRequest();
    broker.requests.push(request);
    broker.emit({ kind: "request", request });
    await vi.waitFor(() => expect(broker.respond).toHaveBeenCalledTimes(1));
    expect(approve).not.toHaveBeenCalled();
    fixture.handler.close();
  });

  it("reports shared standby honestly and does not answer without the writer lease", async () => {
    const store = await storeFixture();
    await store.setEnabled(CODEX_SOURCE_A, "thread-1", true);
    const broker = actionBrokerFixture({
      ready: false,
      writerLeaseHeld: false,
    });
    const fixture = handlerFixture(store, {
      codexActionBroker: broker.runtime,
      topology: "shared",
    });
    fixture.handler.capabilitiesChanged(fixture.client);

    await fixture.handler.handle(
      {
        type: "get_auto_approval_state",
        requestId: "standby-query",
        codexSourceId: CODEX_SOURCE_A,
        providerSessionId: "thread-1",
      },
      fixture.context,
    );
    expect(fixture.sent).toContainEqual(
      expect.objectContaining({
        requestId: "standby-query",
        supervisionAvailable: false,
        supervisionMode: "action_broker",
        unavailableReason: "unsupported_session",
        supervisionUnavailableReason: "writer_lease_unavailable",
      }),
    );

    await fixture.handler.handle(
      {
        type: "set_auto_approval",
        requestId: "standby-mutation",
        codexSourceId: CODEX_SOURCE_A,
        providerSessionId: "thread-1",
        enabled: false,
      },
      fixture.context,
    );
    expect(await store.isActive(CODEX_SOURCE_A, "thread-1")).toBe(true);
    expect(fixture.sent).toContainEqual(
      expect.objectContaining({
        requestId: "standby-mutation",
        errorCode: "writer_lease_unavailable",
      }),
    );

    const request = brokerRequest();
    broker.requests.push(request);
    broker.emit({ kind: "request", request });
    await new Promise<void>((resolve) => setImmediate(resolve));
    expect(broker.respond).not.toHaveBeenCalled();

    broker.health.ready = true;
    broker.health.controlReady = true;
    broker.health.writerLeaseHeld = true;
    broker.emit({ kind: "health", health: broker.health });
    await vi.waitFor(() => expect(broker.respond).toHaveBeenCalledTimes(1));
    fixture.handler.close();
  });

  it("reloads the latest auto-approval policy before a standby generation supervises requests", async () => {
    const leader = await storeFixture();
    await leader.setEnabled(CODEX_SOURCE_A, "thread-1", true);
    const standbyStore = new AutoApprovalStore({ filePath: leader.filePath });
    expect(await standbyStore.isActive(CODEX_SOURCE_A, "thread-1")).toBe(true);
    await leader.setEnabled(CODEX_SOURCE_A, "thread-1", false);

    const broker = actionBrokerFixture({
      ready: false,
      writerLeaseHeld: false,
    });
    const fixture = handlerFixture(standbyStore, {
      codexActionBroker: broker.runtime,
      topology: "shared",
    });
    const request = brokerRequest({ authorityGeneration: "cab:8:4" });
    broker.requests.push(request);
    Object.assign(broker.health, {
      ready: true,
      controlReady: true,
      writerLeaseHeld: true,
      authorityGeneration: "cab:8:4",
    });
    broker.emit({ kind: "health", health: broker.health });
    broker.emit({ kind: "request", request });

    await vi.waitFor(async () =>
      expect(await standbyStore.isActive(CODEX_SOURCE_A, "thread-1")).toBe(
        false,
      ),
    );
    await new Promise<void>((resolve) => setImmediate(resolve));
    expect(broker.respond).not.toHaveBeenCalled();
    fixture.handler.close();
  });

  it("rejects a durable target from another Codex source", async () => {
    const store = await storeFixture();
    const broker = actionBrokerFixture();
    const fixture = handlerFixture(store, {
      codexActionBroker: broker.runtime,
      topology: "shared",
    });
    fixture.handler.capabilitiesChanged(fixture.client);

    await fixture.handler.handle(
      {
        type: "set_auto_approval",
        requestId: "foreign-source-enable",
        codexSourceId: CODEX_SOURCE_B,
        providerSessionId: "thread-1",
        enabled: true,
      },
      fixture.context,
    );

    expect(await store.isActive(CODEX_SOURCE_A, "thread-1")).toBe(false);
    expect(await store.isActive(CODEX_SOURCE_B, "thread-1")).toBe(false);
    expect(fixture.sent).toContainEqual(
      expect.objectContaining({
        requestId: "foreign-source-enable",
        errorCode: "codex_source_mismatch",
        supervisionAvailable: false,
      }),
    );
    fixture.handler.close();
  });

  it("single-flights concurrent broker emissions for one exact request", async () => {
    const store = await storeFixture();
    await store.setEnabled(CODEX_SOURCE_A, "thread-1", true);
    const broker = actionBrokerFixture();
    let release!: () => void;
    const barrier = new Promise<void>((resolve) => {
      release = resolve;
    });
    broker.respond.mockImplementation(
      async (): Promise<CodexActionBrokerRespondResult> => {
        await barrier;
        return { outcome: "submitted" };
      },
    );
    const fixture = handlerFixture(store, {
      codexActionBroker: broker.runtime,
      topology: "shared",
    });
    const request = brokerRequest();
    broker.requests.push(request);

    broker.emit({ kind: "request", request });
    broker.emit({ kind: "request", request });
    try {
      await vi.waitFor(() => expect(broker.respond).toHaveBeenCalledTimes(1));
      broker.emit({ kind: "request", request });
      expect(broker.respond).toHaveBeenCalledTimes(1);
    } finally {
      release();
    }
    await vi.waitFor(() => expect(broker.respond).toHaveBeenCalledTimes(1));
    fixture.handler.close();
  });

  it("releases handled broker request capacity after the exact request resolves", async () => {
    const store = await storeFixture();
    await store.setEnabled(CODEX_SOURCE_A, "thread-1", true);
    const broker = actionBrokerFixture();
    const fixture = handlerFixture(store, {
      codexActionBroker: broker.runtime,
      topology: "shared",
    });
    const request = brokerRequest();
    broker.requests.push(request);
    broker.emit({ kind: "request", request });
    await vi.waitFor(() => expect(broker.respond).toHaveBeenCalledTimes(1));
    expect((fixture.handler as any).handledBrokerRequests.size).toBe(1);

    broker.emit({
      kind: "request",
      request: { ...request, state: "resolved", live: false },
    });
    expect((fixture.handler as any).handledBrokerRequests.size).toBe(0);
    fixture.handler.close();
  });

  it.each(["alreadyResolved", "contended", "outcomeUnknown"] as const)(
    "does not retry the broker outcome %s",
    async (outcome) => {
      const store = await storeFixture();
      await store.setEnabled(CODEX_SOURCE_A, "thread-1", true);
      const broker = actionBrokerFixture({ outcome });
      const fixture = handlerFixture(store, {
        codexActionBroker: broker.runtime,
        topology: "shared",
      });
      const request = brokerRequest();
      broker.requests.push(request);

      broker.emit({ kind: "request", request });
      await vi.waitFor(() => expect(broker.respond).toHaveBeenCalledTimes(1));
      broker.emit({ kind: "request", request });
      await new Promise<void>((resolve) => setImmediate(resolve));
      expect(broker.respond).toHaveBeenCalledTimes(1);
      fixture.handler.close();
    },
  );

  it("revalidates the exact generation and turn before responding", async () => {
    const store = await storeFixture();
    await store.setEnabled(CODEX_SOURCE_A, "thread-1", true);
    const broker = actionBrokerFixture();
    const fixture = handlerFixture(store, {
      codexActionBroker: broker.runtime,
      topology: "shared",
    });
    await new Promise<void>((resolve) => setImmediate(resolve));
    const observed = brokerRequest();
    const current = brokerRequest({
      turnId: "turn-2",
      authorityGeneration: "cab:8:4",
    });
    broker.requests.push(current);

    broker.emit({ kind: "request", request: observed });
    await new Promise<void>((resolve) => setImmediate(resolve));
    expect(broker.respond).not.toHaveBeenCalled();

    broker.emit({ kind: "request", request: current });
    await vi.waitFor(() => expect(broker.respond).toHaveBeenCalledTimes(1));
    expect(broker.respond).toHaveBeenCalledWith(
      expect.objectContaining({
        turnId: "turn-2",
        authorityGeneration: "cab:8:4",
      }),
    );
    fixture.handler.close();
  });

  it("reuses stable claimant and operation IDs after a Bridge restart", async () => {
    const store = await storeFixture();
    await store.setEnabled(CODEX_SOURCE_A, "thread-1", true);
    const broker = actionBrokerFixture();
    broker.respond
      .mockResolvedValueOnce({ outcome: "unavailable" })
      .mockResolvedValueOnce({ outcome: "submitted" });
    broker.requests.push(brokerRequest());

    const first = handlerFixture(
      new AutoApprovalStore({ filePath: store.filePath }),
      {
        codexActionBroker: broker.runtime,
        topology: "shared",
        bridgeInstanceId: "stable-bridge",
      },
    );
    await vi.waitFor(() => expect(broker.respond).toHaveBeenCalledTimes(1));
    await new Promise<void>((resolve) => setImmediate(resolve));
    first.handler.close();

    const second = handlerFixture(
      new AutoApprovalStore({ filePath: store.filePath }),
      {
        codexActionBroker: broker.runtime,
        topology: "shared",
        bridgeInstanceId: "stable-bridge",
      },
    );
    await vi.waitFor(() => expect(broker.respond).toHaveBeenCalledTimes(2));
    const firstInput = broker.respond.mock
      .calls[0][0] as CodexActionBrokerRespondInput;
    const secondInput = broker.respond.mock
      .calls[1][0] as CodexActionBrokerRespondInput;
    expect(secondInput.claimantId).toBe(firstInput.claimantId);
    expect(secondInput.operationId).toBe(firstInput.operationId);
    expect(secondInput).toMatchObject({
      codexSourceId: CODEX_SOURCE_A,
      threadId: "thread-1",
      turnId: "turn-1",
      opaqueRequestId: "opaque-1",
      authorityGeneration: "cab:7:3",
    });
    second.handler.close();
  });

  it("capability-gates old clients without changing persisted state", async () => {
    const store = await storeFixture();
    const fixture = handlerFixture(store, { supports: false });

    await fixture.handler.handle(
      {
        type: "set_auto_approval",
        sessionId: fixture.session.id,
        requestId: "legacy-request",
        enabled: true,
      },
      fixture.context,
    );

    expect(await store.isActive(CODEX_SOURCE_A, "thread-1")).toBe(false);
    expect(fixture.sent).toEqual([
      {
        type: "error",
        errorCode: "unsupported_capability",
        message: "Bridge-owned auto approval was not negotiated",
      },
    ]);
  });
});

function permission(
  toolName: string,
  input: Record<string, unknown> = {},
): Extract<ServerMessage, { type: "permission_request" }> {
  return {
    type: "permission_request",
    toolUseId: "tool-1",
    toolName,
    input,
  };
}

function actionBrokerFixture(
  options: {
    ready?: boolean;
    writerLeaseHeld?: boolean;
    outcome?: CodexActionBrokerRespondResult["outcome"];
  } = {},
): {
  runtime: CodexActionBrokerRuntime;
  health: CodexActionBrokerRuntimeHealth;
  requests: CodexActionBrokerRuntimeRequest[];
  respond: ReturnType<typeof vi.fn>;
  emit(update: CodexActionBrokerRuntimeUpdate): void;
} {
  const health: CodexActionBrokerRuntimeHealth = {
    ready: options.ready ?? true,
    controlReady: options.ready ?? true,
    degraded: false,
    writerLeaseHeld: options.writerLeaseHeld ?? true,
    authorityGeneration: "cab:7:3",
  };
  const requests: CodexActionBrokerRuntimeRequest[] = [];
  const listeners: Array<(update: CodexActionBrokerRuntimeUpdate) => void> = [];
  const respond = vi.fn(
    async (
      _input: CodexActionBrokerRespondInput,
    ): Promise<CodexActionBrokerRespondResult> => ({
      outcome: options.outcome ?? "submitted",
    }),
  );
  const runtime = {
    health,
    listRequests: vi.fn(
      (
        query: {
          codexSourceId?: string;
          threadId?: string;
          limit?: number;
        } = {},
      ) => {
        const matching = requests.filter(
          (request) =>
            (!query.codexSourceId ||
              request.codexSourceId === query.codexSourceId) &&
            (!query.threadId || request.threadId === query.threadId),
        );
        return query.limit === undefined
          ? matching
          : matching.slice(-query.limit);
      },
    ),
    respond,
    subscribe: vi.fn(
      (listener: (update: CodexActionBrokerRuntimeUpdate) => void) => {
        listeners.push(listener);
        return () => {
          const index = listeners.indexOf(listener);
          if (index >= 0) listeners.splice(index, 1);
        };
      },
    ),
  } as unknown as CodexActionBrokerRuntime;
  return {
    runtime,
    health,
    requests,
    respond,
    emit(update) {
      for (const listener of [...listeners]) listener(update);
    },
  };
}

function brokerRequest(
  overrides: Partial<CodexActionBrokerRuntimeRequest> = {},
): CodexActionBrokerRuntimeRequest {
  return {
    opaqueRequestId: "opaque-1",
    codexSourceId: CODEX_SOURCE_A,
    threadId: "thread-1",
    turnId: "turn-1",
    kind: "command_approval",
    state: "pending",
    observedAt: "2026-08-01T00:00:00.000Z",
    expiresAt: "2026-08-01T00:05:00.000Z",
    updatedAt: "2026-08-01T00:00:00.000Z",
    authorityGeneration: "cab:7:3",
    live: true,
    toolName: "Bash",
    input: { command: "pwd" },
    allowedActions: ["approve", "reject"],
    ...overrides,
  };
}

function handlerFixture(
  store: AutoApprovalStore,
  options: {
    supports?: boolean;
    capabilities?: Set<string>;
    codexSourceId?: string | null;
    codexActionBroker?: CodexActionBrokerRuntime;
    topology?: "shared" | "private_legacy";
    bridgeInstanceId?: string;
  } = {},
): {
  handler: AutoApprovalFeatureHandler;
  runtime: LocalFeatureRuntime;
  session: LocalFeatureSession;
  process: CodexProcess;
  client: object;
  context: {
    client: object;
    signal: AbortSignal;
    runtime: LocalFeatureRuntime;
  };
  sent: unknown[];
} {
  const process = new CodexProcess("linux");
  const session: LocalFeatureSession = {
    id: "session-1",
    provider: "codex",
    process,
  };
  const sent: unknown[] = [];
  const runtime: LocalFeatureRuntime = {
    ...(options.codexSourceId === null
      ? {}
      : { codexSourceId: options.codexSourceId ?? CODEX_SOURCE_A }),
    ...(options.bridgeInstanceId
      ? { bridgeInstanceId: options.bridgeInstanceId }
      : {}),
    ...(options.codexActionBroker
      ? { codexActionBroker: options.codexActionBroker }
      : {}),
    getSession: (sessionId) => (sessionId === session.id ? session : undefined),
    getCodexThreadId: (candidate) =>
      candidate === session ? "thread-1" : undefined,
    getActiveCodexProcess: () => process,
    createStandaloneCodexProcess: async () => process,
    send: (_client, message) => sent.push(message),
    supports: (_client, capability) =>
      options.capabilities?.has(capability) ?? options.supports ?? true,
    isClientOpen: () => true,
    hasCodexQueuedInput: () => false,
  };
  const handler = new AutoApprovalFeatureHandler(runtime, {
    store,
    topology: options.topology,
  });
  const client = {};
  return {
    handler,
    runtime,
    session,
    process,
    client,
    context: {
      client,
      signal: new AbortController().signal,
      runtime,
    },
    sent,
  };
}
