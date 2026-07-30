import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { CodexProcess } from "../codex-process.js";
import type { ServerMessage } from "../parser.js";
import {
  AutoApprovalFeatureHandler,
  AutoApprovalStore,
  isAutoApprovablePermission,
  shellCommandRequiresManualApproval,
} from "./auto-approval.js";
import {
  AUTO_APPROVAL_STATE_CAPABILITY,
  AUTO_APPROVAL_SUPERVISION_CAPABILITY,
} from "./slots/auto-approval-protocol.js";
import type {
  LocalFeatureRuntime,
  LocalFeatureSession,
} from "./runtime.js";

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
      isAutoApprovablePermission(permission("Bash", {
        networkApprovalContext: { host: "example.test" },
      })),
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

    expect(isAutoApprovablePermission(permission("AskUserQuestion"))).toBe(false);
    expect(isAutoApprovablePermission(permission("ToolSuggestion"))).toBe(false);
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

    expect(
      await store.isActive(CODEX_SOURCE_A, "thread-legacy"),
    ).toBe(false);
    expect(
      await store.isActive(CODEX_SOURCE_B, "thread-legacy"),
    ).toBe(false);

    await store.setEnabled(CODEX_SOURCE_A, "thread-legacy", true);
    expect(
      JSON.parse(await readFile(store.filePath, "utf8")),
    ).toEqual({
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
    expect(
      await reopened.isActive(CODEX_SOURCE_A, "thread-legacy"),
    ).toBe(true);
    expect(
      await reopened.isActive(CODEX_SOURCE_B, "thread-legacy"),
    ).toBe(false);
  });

  it("accepts an old Mobile import without turning unscoped IDs into grants", async () => {
    const store = await storeFixture();
    expect(
      await store.importLegacy(CODEX_SOURCE_A, ["thread-legacy"]),
    ).toBe(true);
    expect(
      await store.isActive(CODEX_SOURCE_A, "thread-legacy"),
    ).toBe(false);
    expect(
      await store.isActive(CODEX_SOURCE_B, "thread-legacy"),
    ).toBe(false);
    expect(
      await store.importLegacy(CODEX_SOURCE_A, ["thread-stale"]),
    ).toBe(false);
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
      providerSessionId: "thread-1",
      enabled: true,
      enabledConversationCount: 1,
      approvedCount: 0,
      supervisionAvailable: true,
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
      providerSessionId: "thread-1",
      enabled: false,
      enabledConversationCount: 0,
      approvedCount: 0,
      supervisionAvailable: true,
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
      enabledConversationCount: 0,
      supervisionAvailable: false,
      unavailableReason: "external_app_server",
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
      unavailableReason: "unsupported_session",
      reason: "updated",
      errorCode: "codex_source_unavailable",
      error: "Auto approval requires an authenticated Codex source",
    });
  });

  it("approves a safe request without any connected phone", async () => {
    const store = await storeFixture();
    await store.setEnabled(CODEX_SOURCE_A, "thread-1", true);
    const fixture = handlerFixture(store);
    const pending = permission("Bash", { command: "curl https://example.test" });
    let current: ServerMessage | undefined = pending;
    vi.spyOn(fixture.process, "getPendingPermission").mockImplementation((id) =>
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

function handlerFixture(
  store: AutoApprovalStore,
  options: {
    supports?: boolean;
    capabilities?: Set<string>;
    codexSourceId?: string | null;
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
  const handler = new AutoApprovalFeatureHandler(runtime, { store });
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
