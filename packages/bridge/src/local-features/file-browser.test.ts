import { createServer } from "node:http";
import { describe, expect, it, vi } from "vitest";
import type { CodexProcess } from "../codex-process.js";
import type { FileBrowserManager } from "../file-browser-manager.js";
import { BridgeWebSocketServer } from "../websocket.js";
import { createFileBrowserHandlers } from "./slots/file-browser.js";
import type {
  LocalFeatureHandleContext,
  LocalFeatureRuntime,
} from "./runtime.js";

describe("file browser local-feature seam", () => {
  it("binds each client once, routes requests, and tears down independently", async () => {
    const manager = managerStub();
    const supported = new Set(["file_browser_roots_result_v1"]);
    const sent: unknown[] = [];
    const runtime = runtimeStub({ manager, supported, sent });
    const handler = createFileBrowserHandlers(runtime)[0];
    const client = {};
    const context = handleContext(client, runtime);

    handler.capabilitiesChanged?.(client);
    await handler.handle(
      { type: "file_browser_roots_v1", requestId: "roots-1" },
      context,
    );
    await handler.handle(
      { type: "file_browser_roots_v1", requestId: "roots-2" },
      context,
    );

    expect(manager.connect).toHaveBeenCalledOnce();
    expect(manager.handleClientMessage).toHaveBeenNthCalledWith(
      1,
      client,
      {
        type: "file_browser_roots_v1",
        requestId: "roots-1",
      },
      context.signal,
    );
    expect(manager.handleClientMessage).toHaveBeenNthCalledWith(
      2,
      client,
      {
        type: "file_browser_roots_v1",
        requestId: "roots-2",
      },
      context.signal,
    );

    const binding = manager.connect.mock.calls[0][1];
    expect(
      binding.send({
        type: "file_browser_roots_result_v1",
        requestId: "roots-1",
        success: false,
        errorCode: "test",
      }),
    ).toBe(true);
    expect(sent).toContainEqual(
      expect.objectContaining({ requestId: "roots-1" }),
    );

    handler.disconnect?.(client);
    expect(manager.disconnect).toHaveBeenCalledWith(client);
    await handler.close?.();
    expect(manager.close).toHaveBeenCalledOnce();
  });

  it("fails closed when the host did not initialize the optional manager", async () => {
    const sent: unknown[] = [];
    const runtime = runtimeStub({
      supported: new Set(["file_browser_list_result_v1"]),
      sent,
    });
    const handler = createFileBrowserHandlers(runtime)[0];

    await handler.handle(
      {
        type: "file_browser_list_v1",
        requestId: "list-1",
        rootId: "root-1",
        relativePath: "",
        pageSize: 100,
      },
      handleContext({}, runtime),
    );

    expect(sent).toEqual([
      {
        type: "file_browser_list_result_v1",
        requestId: "list-1",
        success: false,
        errorCode: "unsupported_capability",
        error: "File browser capability was not negotiated",
      },
    ]);
  });

  it("advertises the additive capability only when the manager exists", async () => {
    const server = createServer();
    const manager = managerStub();
    const bridge = new BridgeWebSocketServer({
      server,
      fileBrowser: manager as unknown as FileBrowserManager,
    });
    const ws = { readyState: 1, send: vi.fn() };

    (bridge as any).sendSessionList(ws);

    const sessionList = JSON.parse(ws.send.mock.calls[0][0] as string);
    expect(sessionList.bridgeCapabilities).toContain("file_browser_v1");

    await bridge.close();
    server.close();
    expect(manager.close).toHaveBeenCalledOnce();
  });
});

function managerStub() {
  return {
    connect: vi.fn(),
    disconnect: vi.fn(),
    close: vi.fn(),
    handleClientMessage: vi.fn(async () => {}),
  };
}

function runtimeStub(options: {
  manager?: ReturnType<typeof managerStub>;
  supported: Set<string>;
  sent: unknown[];
}): LocalFeatureRuntime {
  return {
    fileBrowser: options.manager as unknown as FileBrowserManager | undefined,
    getSession: () => undefined,
    getCodexThreadId: () => undefined,
    getActiveCodexProcess: () => null,
    createStandaloneCodexProcess: async () => ({}) as CodexProcess,
    hasCodexQueuedInput: () => false,
    isClientOpen: () => true,
    send: (_client, message) => options.sent.push(message),
    supports: (_client, type) => options.supported.has(type),
  };
}

function handleContext(
  client: object,
  runtime: LocalFeatureRuntime,
): LocalFeatureHandleContext {
  return {
    client,
    runtime,
    signal: new AbortController().signal,
  };
}
