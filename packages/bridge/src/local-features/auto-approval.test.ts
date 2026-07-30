import { mkdtemp, readFile, rm } from "node:fs/promises";
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
  it("persists stable Codex thread IDs and disables every thread atomically", async () => {
    const store = await storeFixture();
    await store.setEnabled("thread-1", true);
    await store.setEnabled("thread-2", true);
    expect(await store.isActive("thread-1")).toBe(true);
    expect(await store.visibleState("thread-2")).toEqual({
      enabled: true,
      enabledConversationCount: 2,
    });

    const reopened = new AutoApprovalStore({ filePath: store.filePath });
    expect(await reopened.isActive("thread-1")).toBe(true);
    await reopened.disableAll();
    expect(await reopened.visibleState("thread-1")).toEqual({
      enabled: false,
      enabledConversationCount: 0,
    });
    expect(JSON.parse(await readFile(store.filePath, "utf8"))).toEqual({
      version: 1,
      enabledThreadIds: [],
    });
  });

  it("fails closed when persisted state is malformed", async () => {
    const store = await storeFixture();
    await store.setEnabled("thread-1", true);
    const invalid = new AutoApprovalStore({ filePath: store.filePath });
    await import("node:fs/promises").then(({ writeFile }) =>
      writeFile(store.filePath, '{"version":99}', "utf8"),
    );
    expect(await invalid.isActive("thread-1")).toBe(false);
  });

  it("imports legacy state only before Bridge has authoritative settings", async () => {
    const store = await storeFixture();
    expect(await store.importLegacy(["thread-legacy"])).toBe(true);
    expect(await store.isActive("thread-legacy")).toBe(true);
    expect(await store.importLegacy(["thread-stale"])).toBe(false);
    expect(await store.isActive("thread-stale")).toBe(false);
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

    expect(await store.isActive("thread-1")).toBe(true);
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

  it("approves a safe request without any connected phone", async () => {
    const store = await storeFixture();
    await store.setEnabled("thread-1", true);
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

  it("never approves rm and does not depend on Mobile eligibility", async () => {
    const store = await storeFixture();
    await store.setEnabled("thread-1", true);
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

    expect(await store.isActive("thread-1")).toBe(false);
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
  options: { supports?: boolean; capabilities?: Set<string> } = {},
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
