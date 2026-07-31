import { readFile, rm, symlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  DESKTOP_SHARED_RUNTIME_ENV_KEYS,
  enableDesktopSharedRuntime,
  parseLaunchctlEnvironment,
  restoreDesktopPrivateRuntime,
  snapshotDesktopEnvironment,
  verifyDesktopSharedRuntime,
  type DesktopProcessRecord,
  type DesktopEnvironmentSnapshot,
} from "./codex-desktop-shared-runtime.js";
import { preparePilotIsolation, resolvePilotPaths } from "./pilot-isolation.js";

const roots = new Set<string>();
let sequence = 0;

function freshRoot(): string {
  sequence += 1;
  const root = `/private/tmp/ccp-sr-desktop-${process.pid}-${sequence}`;
  roots.add(root);
  return root;
}

function printDomain(environment: ReadonlyMap<string, string>): string {
  const rows = [...environment.entries()].map(
    ([key, value]) => `\t\t${key} => ${value}`,
  );
  return ["gui = {", "\tenvironment = {", ...rows, "\t}", "}"].join("\n");
}

async function readTransaction(
  root: string,
): Promise<DesktopEnvironmentSnapshot> {
  return JSON.parse(
    await readFile(join(root, "desktop-environment-snapshot.json"), "utf8"),
  ) as DesktopEnvironmentSnapshot;
}

function fakeDependencies(
  environment: Map<string, string>,
  processes: DesktopProcessRecord[] = [],
  socketPids: ReadonlySet<number> = new Set(),
) {
  return {
    uid: process.getuid?.() ?? 501,
    now: () => new Date("2026-08-01T00:00:00.000Z"),
    printGuiDomain: vi.fn(async () => printDomain(environment)),
    setGuiEnvironment: vi.fn(async (name: string, value: string) => {
      environment.set(name, value);
    }),
    unsetGuiEnvironment: vi.fn(async (name: string) => {
      environment.delete(name);
    }),
    listProcesses: vi.fn(async () => processes),
    listUnixSockets: vi.fn(async (pid: number) =>
      socketPids.has(pid)
        ? [
            `node 1 user 1u unix ${resolvePilotPaths([...roots][0]).daemonSocket}`,
          ]
        : [],
    ),
  };
}

afterEach(async () => {
  for (const root of roots) {
    await rm(root, { recursive: true, force: true });
  }
  roots.clear();
});

describe.runIf(process.platform === "darwin")(
  "Codex Desktop shared-runtime pilot helper",
  () => {
    it("parses exact presence, including an explicitly empty value", () => {
      const parsed = parseLaunchctlEnvironment(
        [
          "gui = {",
          "  environment = {",
          "    CODEX_HOME => /tmp/codex home",
          "    CODEX_CLI_PATH => ",
          "  }",
          "}",
        ].join("\n"),
      );
      expect(parsed.get("CODEX_HOME")).toBe("/tmp/codex home");
      expect(parsed.has("CODEX_CLI_PATH")).toBe(true);
      expect(parsed.get("CODEX_CLI_PATH")).toBe("");
    });

    it("snapshots once, enables isolated shared mode, and restores exact values", async () => {
      const root = freshRoot();
      await preparePilotIsolation(root);
      const environment = new Map<string, string>([
        ["SSH_AUTH_SOCK", "/tmp/agent.sock"],
        ["CODEX_HOME", "/Users/test/.codex-original"],
        ["CODEX_CLI_PATH", ""],
      ]);
      const deps = fakeDependencies(environment);

      const first = await snapshotDesktopEnvironment(root, deps);
      expect(first.reused).toBe(false);
      expect(first.snapshot.state).toBe("captured");
      const second = await snapshotDesktopEnvironment(root, deps);
      expect(second.reused).toBe(true);
      expect(second.snapshot.createdAt).toBe(first.snapshot.createdAt);
      expect(second.snapshot.transactionId).toBe(first.snapshot.transactionId);

      await enableDesktopSharedRuntime(root, deps);
      expect((await readTransaction(root)).state).toBe("shared");
      expect(environment.get("CODEX_APP_SERVER_USE_LOCAL_DAEMON")).toBe("1");
      expect(environment.get("CODEX_HOME")).toBe(
        resolvePilotPaths(root).codexHome,
      );
      for (const key of [
        "CODEX_SQLITE_HOME",
        "CODEX_APP_SERVER_FORCE_CLI",
        "CODEX_CLI_PATH",
        "CODEX_APP_SERVER_WS_URL",
      ]) {
        expect(environment.has(key)).toBe(false);
      }

      await restoreDesktopPrivateRuntime(root, deps);
      expect((await readTransaction(root)).state).toBe("restored");
      expect(environment.get("CODEX_HOME")).toBe("/Users/test/.codex-original");
      expect(environment.has("CODEX_CLI_PATH")).toBe(true);
      expect(environment.get("CODEX_CLI_PATH")).toBe("");
      expect(environment.has("CODEX_APP_SERVER_USE_LOCAL_DAEMON")).toBe(false);
      expect(environment.get("SSH_AUTH_SOCK")).toBe("/tmp/agent.sock");
      expect(Object.keys(first.snapshot.values).sort()).toEqual(
        [...DESKTOP_SHARED_RUNTIME_ENV_KEYS].sort(),
      );

      environment.set("CODEX_HOME", "/Users/test/.codex-next-pilot");
      const next = await snapshotDesktopEnvironment(root, deps);
      expect(next.reused).toBe(false);
      expect(next.snapshot.state).toBe("captured");
      expect(next.snapshot.transactionId).not.toBe(
        first.snapshot.transactionId,
      );
      expect(next.snapshot.values.CODEX_HOME).toEqual({
        present: true,
        value: "/Users/test/.codex-next-pilot",
      });
    });

    it("refuses enable after the captured GUI environment has drifted", async () => {
      const root = freshRoot();
      await preparePilotIsolation(root);
      const environment = new Map<string, string>([
        ["CODEX_HOME", "/Users/test/.codex-original"],
      ]);
      const deps = fakeDependencies(environment);
      await snapshotDesktopEnvironment(root, deps);
      environment.set("CODEX_HOME", "/Users/test/.codex-changed-elsewhere");

      await expect(enableDesktopSharedRuntime(root, deps)).rejects.toThrow(
        "GUI environment value mismatch for CODEX_HOME",
      );
      expect(deps.setGuiEnvironment).not.toHaveBeenCalled();
      expect(deps.unsetGuiEnvironment).not.toHaveBeenCalled();
      expect((await readTransaction(root)).state).toBe("captured");
    });

    it("allows only captured to shared to restored transitions", async () => {
      const root = freshRoot();
      await preparePilotIsolation(root);
      const environment = new Map<string, string>();
      const deps = fakeDependencies(environment);
      await snapshotDesktopEnvironment(root, deps);

      await expect(restoreDesktopPrivateRuntime(root, deps)).rejects.toThrow(
        "must be shared before restore",
      );
      await enableDesktopSharedRuntime(root, deps);
      await expect(enableDesktopSharedRuntime(root, deps)).rejects.toThrow(
        "must be captured before enable",
      );
      await expect(snapshotDesktopEnvironment(root, deps)).rejects.toThrow(
        "already in shared mode",
      );
      await restoreDesktopPrivateRuntime(root, deps);
      await expect(restoreDesktopPrivateRuntime(root, deps)).rejects.toThrow(
        "must be shared before restore",
      );
    });

    it("rejects a symbolic-link transaction file", async () => {
      const root = freshRoot();
      await preparePilotIsolation(root);
      const target = join(root, "desktop-environment-snapshot-target.json");
      await writeFile(target, "{}", { mode: 0o600 });
      await symlink(target, join(root, "desktop-environment-snapshot.json"));

      await expect(
        snapshotDesktopEnvironment(root, fakeDependencies(new Map())),
      ).rejects.toThrow("must be a 0600 regular file");
    });

    it("rejects a transaction file not owned by the expected user", async () => {
      const root = freshRoot();
      await preparePilotIsolation(root);
      const environment = new Map<string, string>();
      const deps = fakeDependencies(environment);
      await snapshotDesktopEnvironment(root, deps);

      await expect(
        snapshotDesktopEnvironment(root, {
          ...deps,
          uid: deps.uid + 1,
        }),
      ).rejects.toThrow("must be a 0600 regular file");
    });

    it("rolls back to the snapshot if enabling the shared environment fails", async () => {
      const root = freshRoot();
      await preparePilotIsolation(root);
      const environment = new Map<string, string>([
        ["CODEX_HOME", "/Users/test/.codex-original"],
      ]);
      const deps = fakeDependencies(environment);
      await snapshotDesktopEnvironment(root, deps);
      let failed = false;
      deps.setGuiEnvironment.mockImplementation(
        async (name: string, value: string) => {
          if (!failed && name === "CODEX_HOME") {
            failed = true;
            throw new Error("launchctl failed");
          }
          environment.set(name, value);
        },
      );

      await expect(enableDesktopSharedRuntime(root, deps)).rejects.toThrow(
        "launchctl failed",
      );
      expect(environment.get("CODEX_HOME")).toBe("/Users/test/.codex-original");
      expect(environment.has("CODEX_APP_SERVER_USE_LOCAL_DAEMON")).toBe(false);
      expect((await readTransaction(root)).state).toBe("captured");
      expect(deps.printGuiDomain).toHaveBeenCalledTimes(3);
    });

    it("verifies one Desktop tree on the pilot socket without a private stdio server", async () => {
      const root = freshRoot();
      await preparePilotIsolation(root);
      const environment = new Map<string, string>();
      const deps = fakeDependencies(
        environment,
        [
          {
            pid: 100,
            parentPid: 1,
            arguments: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT",
          },
          {
            pid: 101,
            parentPid: 100,
            arguments: "ChatGPT Helper (Renderer)",
          },
        ],
        new Set([101]),
      );
      await snapshotDesktopEnvironment(root, deps);
      await enableDesktopSharedRuntime(root, deps);

      await expect(verifyDesktopSharedRuntime(root, deps)).resolves.toEqual({
        desktopPids: [100],
        descendantPids: [100, 101],
        daemonSocketConnected: true,
        privateStdioAppServers: 0,
      });
    });
  },
);
