import { execFileSync, spawn } from "node:child_process";
import { openSync } from "node:fs";

const plist =
  "/Users/huyiyang/Library/LaunchAgents/com.ccpocket.bridge.plist";
const cli =
  "/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.5-compat.8-4f24fbe2/packages/bridge/dist/cli.js";
const port = 18766;
const log =
  "/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-tiered-session-sync-20260730/runs/20260730-161447_bridge-1.69.5-compat.8-4f24fbe2-deploy/candidate-18766.log";

const configured = JSON.parse(
  execFileSync(
    "/usr/bin/plutil",
    ["-extract", "EnvironmentVariables", "json", "-o", "-", plist],
    { encoding: "utf8" },
  ),
);
const output = openSync(log, "a");
const child = spawn(process.execPath, [cli], {
  detached: true,
  stdio: ["ignore", output, output],
  env: {
    ...process.env,
    ...configured,
    BRIDGE_CLI_ENTRY: cli,
    BRIDGE_HOST: "127.0.0.1",
    BRIDGE_PORT: String(port),
    BRIDGE_PUBLIC_WS_URL: `ws://127.0.0.1:${port}`,
  },
});
child.unref();
console.log(JSON.stringify({ pid: child.pid, port }));
