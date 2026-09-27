import { createServer } from "node:net";
import { EventEmitter, once } from "node:events";
import { createInterface } from "node:readline";
import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";

// Only the provider is synthetic. The executable is a byte pipe, so the real
// CodexProcess still spawns, initializes, frames and decodes stdio JSON-RPC.
export async function startConversationAppServerFixture({
  home, projectPath, threadId, turnId, state, thread, turn, trace, reads,
}) {
  const connections = [];
  const events = new EventEmitter();
  let activeConnection;
  let acceptedInitialTurn = false;

  function send(connection, message) {
    const raw = JSON.stringify({ jsonrpc: "2.0", ...message });
    trace.push({ connection: connection.id, direction: "provider_to_bridge", raw });
    connection.socket.write(raw + "\n");
  }

  const server = createServer((socket) => {
    const connection = { id: connections.length + 1, socket };
    connections.push(connection);
    const input = createInterface({ input: socket, crlfDelay: Infinity });
    input.on("line", (raw) => {
      trace.push({ connection: connection.id, direction: "bridge_to_provider", raw });
      const request = JSON.parse(raw);
      if (request.id == null) return;
      const params = request.params ?? {};
      reads.push({ method: request.method, revision: state.revision, transport: "stdio-json-rpc" });
      let result;
      switch (request.method) {
        case "initialize": result = { userAgent: "ccpocket-synthetic-provider" }; break;
        case "config/read": result = { config: { profiles: {}, model: "gpt-5.6-sol" } }; break;
        case "configRequirements/read": result = { requirements: {} }; break;
        case "model/list":
          result = { data: [{ id: "gpt-5.6-sol", model: "gpt-5.6-sol", supportedReasoningEfforts: [{ reasoningEffort: "max" }] }], nextCursor: null };
          break;
        case "thread/list": result = { data: params.archived ? [] : [thread()], nextCursor: null }; break;
        case "thread/read": result = { thread: { ...thread(), turns: [turn()] } }; break;
        case "thread/resume":
          if (params.threadId !== threadId) throw new Error("Unexpected fixture thread");
          activeConnection = connection;
          result = { thread: { ...thread(), turns: params.excludeTurns ? [] : [turn()] }, model: "gpt-5.6-sol" };
          break;
        case "thread/turns/list": result = { data: params.threadId === threadId ? [turn()] : [], nextCursor: null }; break;
        case "thread/loaded/list": result = { data: [threadId], nextCursor: null }; break;
        case "skills/list": result = { data: [{ cwd: projectPath, skills: [] }] }; break;
        case "app/list": result = { data: [], nextCursor: null }; break;
        case "plugin/list": result = { marketplaces: [] }; break;
        case "turn/start":
          // Keep the later accepted outgoing request absent from canonical
          // history, as in the notification-only fixture's warm reopen check.
          if (acceptedInitialTurn) return;
          if (params.threadId !== threadId) throw new Error("Unexpected fixture turn");
          acceptedInitialTurn = true;
          activeConnection = connection;
          state.active = true;
          send(connection, { id: request.id, result: { turn: { id: turnId, status: "inProgress" } } });
          send(connection, { method: "turn/started", params: { threadId, turn: { id: turnId, status: "inProgress" } } });
          events.emit("turn-started");
          return;
        default:
          send(connection, { id: request.id, error: { code: -32601, message: `Unsupported synthetic provider method: ${request.method}` } });
          return;
      }
      send(connection, { id: request.id, result });
    });
    socket.on("error", () => input.close());
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const bin = join(home, "fixture-bin");
  await mkdir(bin, { recursive: true });
  await writeFile(join(bin, "codex"), [
    "#!/usr/bin/env node",
    'if (process.argv[2] !== "app-server") process.exit(2);',
    'const socket = require("node:net").createConnection({ host: "127.0.0.1", port: Number(process.env.CCPOCKET_FIXTURE_RPC_PORT) });',
    'process.stdin.pipe(socket); socket.pipe(process.stdout);',
    'socket.on("close", () => process.exit(0));',
    'socket.on("error", () => process.exit(1));',
  ].join("\n") + "\n", { mode: 0o700 });
  process.env.PATH = `${bin}:${process.env.PATH ?? ""}`;
  process.env.CCPOCKET_FIXTURE_RPC_PORT = String(server.address().port);

  return {
    async beginTurn(runtime) {
      if (acceptedInitialTurn) return;
      const signal = AbortSignal.timeout(8000);
      if (!runtime.isWaitingForInput) await once(runtime, "input_ready", { signal });
      const started = once(events, "turn-started", { signal });
      runtime.sendInput("Exercise live segment boundaries", "client-user-live-segments");
      await started;
    },
    notify(method, params) {
      if (!activeConnection || activeConnection.socket.destroyed) throw new Error("No active provider RPC connection");
      send(activeConnection, { method, params });
    },
    async close() {
      for (const connection of connections) connection.socket.destroy();
      await new Promise((resolve) => server.close(resolve));
    },
  };
}
