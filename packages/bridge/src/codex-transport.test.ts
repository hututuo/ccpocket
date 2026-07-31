import { EventEmitter, once } from "node:events";
import { lstatSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { createServer, type Server } from "node:http";
import { createConnection } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PassThrough } from "node:stream";
import { afterEach, describe, expect, it, vi } from "vitest";
import WebSocket, { WebSocketServer } from "ws";
import type { VerifiedCodexDaemon } from "./codex-daemon-supervisor.js";

const { spawnMock } = vi.hoisted(() => ({ spawnMock: vi.fn() }));

vi.mock("node:child_process", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:child_process")>();
  return { ...actual, spawn: spawnMock };
});

import {
  createCodexTransport,
  UnixSocketCodexTransport,
  WebSocketCodexTransport,
} from "./codex-transport.js";

class FakeChild extends EventEmitter {
  stdout = new PassThrough();
  stderr = new PassThrough();
  stdin = new PassThrough();
  killed = false;
  kill = vi.fn((_signal?: string) => {
    this.killed = true;
    return true;
  });
}

function startStdioTransport() {
  const child = new FakeChild();
  spawnMock.mockReturnValueOnce(child);
  const transport = createCodexTransport("/tmp/project");
  transport.start("/tmp/project");
  return { transport, child };
}

interface UnixWebSocketFixture {
  root: string;
  socketPath: string;
  server: Server;
  webSocketServer: WebSocketServer;
}

const unixFixtures: UnixWebSocketFixture[] = [];

async function createUnixWebSocketFixture(): Promise<UnixWebSocketFixture> {
  const root = await mkdtemp(
    join(process.platform === "darwin" ? "/private/tmp" : tmpdir(), "ccp-t-"),
  );
  const socketPath = `${root}/s.sock`;
  const server = createServer();
  const webSocketServer = new WebSocketServer({ server });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, resolve);
  });
  const fixture = { root, socketPath, server, webSocketServer };
  unixFixtures.push(fixture);
  return fixture;
}

async function closeUnixWebSocketFixture(
  fixture: UnixWebSocketFixture,
): Promise<void> {
  for (const client of fixture.webSocketServer.clients) {
    client.terminate();
  }
  await new Promise<void>((resolve) =>
    fixture.webSocketServer.close(() => resolve()),
  );
  if (fixture.server.listening) {
    await new Promise<void>((resolve) => fixture.server.close(() => resolve()));
  }
}

function verifiedDaemon(socketPath: string): VerifiedCodexDaemon {
  const stats = lstatSync(socketPath);
  return {
    config: {
      codexHome: socketPath.slice(0, socketPath.lastIndexOf("/")),
      cliPath: "/Applications/ChatGPT.app/Contents/Resources/codex",
      socketPath,
      expectedVersion: "0.146.0-alpha.9.2",
    },
    cliVersion: "0.146.0-alpha.9.2",
    appServerVersion: "0.146.0-alpha.9.2",
    socketPath,
    socketIdentity: { device: stats.dev, inode: stats.ino },
  };
}

afterEach(async () => {
  spawnMock.mockReset();
  vi.unstubAllEnvs();
  for (const fixture of unixFixtures.splice(0)) {
    await closeUnixWebSocketFixture(fixture);
    await rm(fixture.root, { recursive: true, force: true });
  }
});

describe("StdioCodexTransport crash resilience (P0-5)", () => {
  it("surfaces stdin errors as transport errors instead of crashing", () => {
    const { transport, child } = startStdioTransport();
    const errors: Error[] = [];
    transport.on("error", (err) => errors.push(err));

    const epipe = Object.assign(new Error("write EPIPE"), { code: "EPIPE" });
    expect(() => child.stdin.emit("error", epipe)).not.toThrow();
    expect(errors).toEqual([epipe]);
  });

  it("logs (not crashes) stdin errors that arrive after the child exited", () => {
    const { transport, child } = startStdioTransport();
    const errors: Error[] = [];
    const logs: string[] = [];
    transport.on("error", (err) => errors.push(err));
    transport.on("log", (line) => logs.push(line));

    child.emit("exit", 1);
    const epipe = Object.assign(new Error("write EPIPE"), { code: "EPIPE" });
    expect(() => child.stdin.emit("error", epipe)).not.toThrow();
    expect(errors).toEqual([]);
    expect(logs.some((line) => line.includes("EPIPE"))).toBe(true);
  });

  it("rejects writes synchronously once stdin is no longer writable", () => {
    const { transport, child } = startStdioTransport();
    transport.on("error", () => {});

    // Child crashed on its own: killed stays false, exit not yet delivered.
    child.stdin.destroy();
    expect(child.killed).toBe(false);
    expect(() => transport.write({ hello: "world" })).toThrow(
      "codex app-server is not running",
    );
  });

  it("rejects writes after spawn-level errors (no exit event fires)", () => {
    const { transport, child } = startStdioTransport();
    transport.on("error", () => {});

    const enoent = Object.assign(new Error("spawn codex ENOENT"), {
      code: "ENOENT",
    });
    child.emit("error", enoent);
    expect(transport.isRunning).toBe(false);
    expect(() => transport.write({ hello: "world" })).toThrow(
      "codex app-server is not running",
    );
  });

  it("still delivers writes on a healthy child", async () => {
    const { transport, child } = startStdioTransport();
    const received = new Promise<string>((res) => {
      child.stdin.once("data", (chunk) => res(String(chunk)));
    });

    transport.write({ hello: "world" });
    expect(await received).toBe('{"hello":"world"}\n');
  });
});

describe.runIf(process.platform !== "win32")("UnixSocketCodexTransport", () => {
  it("uses the daemon UDS contract and only queues the first initialize", async () => {
    const fixture = await createUnixWebSocketFixture();
    let requestPath: string | undefined;
    let extensions: string | undefined;
    const received = new Promise<string>((resolve) => {
      fixture.webSocketServer.once("connection", (socket, request) => {
        requestPath = request.url;
        extensions = request.headers["sec-websocket-extensions"];
        socket.once("message", (data) => resolve(data.toString()));
      });
    });
    const transport = new UnixSocketCodexTransport(
      verifiedDaemon(fixture.socketPath),
    );
    transport.on("error", () => {});

    transport.start("/unused");
    expect(() =>
      transport.write({ id: 2, method: "thread/list", params: {} }),
    ).toThrow("request was not queued");
    transport.write({ id: 1, method: "initialize", params: {} });
    expect(() =>
      transport.write({ id: 3, method: "initialize", params: {} }),
    ).toThrow("request was not queued");

    expect(await received).toBe(
      JSON.stringify({ id: 1, method: "initialize", params: {} }),
    );
    expect(requestPath).toBe("/rpc");
    expect(extensions).toBeUndefined();
    transport.stop();
  });

  it("delivers UDS frames but rejects writes after disconnect", async () => {
    const fixture = await createUnixWebSocketFixture();
    const transport = new UnixSocketCodexTransport(
      verifiedDaemon(fixture.socketPath),
    );
    transport.on("error", () => {});
    const connection = once(fixture.webSocketServer, "connection");
    transport.start("/unused");
    transport.write({ id: 1, method: "initialize", params: {} });
    const [serverSocket] = (await connection) as [WebSocket];

    const data = once(transport, "data");
    serverSocket.send('{"id":1,"result":{}}');
    expect(await data).toEqual(['{"id":1,"result":{}}\n']);

    const exit = once(transport, "exit");
    serverSocket.close();
    expect(await exit).toEqual([1]);
    expect(() =>
      transport.write({ id: 2, method: "thread/list", params: {} }),
    ).toThrow("request was not queued");
    transport.stop();
  });

  it("fences old generations and never stops the daemon server", async () => {
    const fixture = await createUnixWebSocketFixture();
    const transport = new UnixSocketCodexTransport(
      verifiedDaemon(fixture.socketPath),
    );
    transport.on("error", () => {});
    const connected = once(fixture.webSocketServer, "connection");
    transport.start("/unused");
    transport.write({ id: 1, method: "initialize", params: {} });
    const [serverSocket] = (await connected) as [WebSocket];
    const generation = transport.connectionGeneration;

    transport.stop();
    expect(transport.connectionGeneration).toBeGreaterThan(generation);
    expect(fixture.server.listening).toBe(true);

    const independentClient = new WebSocket("ws://codex-app-server/rpc", {
      createConnection: () => createConnection(fixture.socketPath),
      perMessageDeflate: false,
    });
    await once(independentClient, "open");
    independentClient.close();
  });

  it("rejects a socket replaced after supervisor verification", async () => {
    const fixture = await createUnixWebSocketFixture();
    const daemon = verifiedDaemon(fixture.socketPath);
    await closeUnixWebSocketFixture(fixture);
    const replacementServer = createServer();
    const replacementWebSocketServer = new WebSocketServer({
      server: replacementServer,
    });
    fixture.server = replacementServer;
    fixture.webSocketServer = replacementWebSocketServer;
    await new Promise<void>((resolve, reject) => {
      replacementServer.once("error", reject);
      replacementServer.listen(fixture.socketPath, resolve);
    });

    const transport = new UnixSocketCodexTransport(daemon);
    const errors: Error[] = [];
    transport.on("error", (error) => errors.push(error));
    transport.start("/unused");

    expect(errors[0]?.message).toContain("socket was replaced");
    expect(replacementWebSocketServer.clients.size).toBe(0);
    transport.stop();
  });

  it("constructs daemon mode through strict config and verification", async () => {
    const fixture = await createUnixWebSocketFixture();
    const daemon = verifiedDaemon(fixture.socketPath);
    let observedConfig: unknown;
    const transport = createCodexTransport(
      "/unused",
      process.platform,
      {
        BRIDGE_CODEX_APP_SERVER_MODE: "daemon",
        CODEX_HOME: daemon.config.codexHome,
        BRIDGE_CODEX_DAEMON_CLI: daemon.config.cliPath,
        BRIDGE_CODEX_DAEMON_SOCKET: daemon.socketPath,
        BRIDGE_CODEX_DAEMON_EXPECTED_VERSION: daemon.config.expectedVersion,
      },
      (config) => {
        observedConfig = config;
        return daemon;
      },
    );

    expect(transport).toBeInstanceOf(UnixSocketCodexTransport);
    expect(observedConfig).toEqual(daemon.config);
    transport.stop();
  });
});

describe("WebSocketCodexTransport reconnect boundary", () => {
  it("exits after a post-connect close instead of reconnecting uninitialized", async () => {
    const server = createServer();
    const webSocketServer = new WebSocketServer({ server });
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(0, "127.0.0.1", resolve);
    });
    const address = server.address();
    if (!address || typeof address === "string") {
      throw new Error("test server did not expose a TCP port");
    }

    let connectionCount = 0;
    webSocketServer.on("connection", () => {
      connectionCount += 1;
    });
    const transport = new WebSocketCodexTransport(
      `ws://127.0.0.1:${address.port}`,
      5_000,
    );
    transport.on("error", () => {});
    const connection = once(webSocketServer, "connection");
    transport.start("/unused");
    transport.write({ id: 1, method: "initialize", params: {} });
    const [socket] = (await connection) as [WebSocket];
    const exit = once(transport, "exit");
    socket.close();

    await expect(exit).resolves.toEqual([1]);
    expect(connectionCount).toBe(1);
    expect(transport.isRunning).toBe(false);

    transport.stop();
    await new Promise<void>((resolve) =>
      webSocketServer.close(() => resolve()),
    );
    if (server.listening) {
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  });
});
