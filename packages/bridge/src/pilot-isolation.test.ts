import {
  chmod,
  lstat,
  mkdir,
  readFile,
  realpath,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { createServer, type Server } from "node:net";
import { dirname, join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  assertPilotPort,
  buildPilotEnvironment,
  PILOT_HOST,
  PILOT_PORT,
  preparePilotDaemon,
  preparePilotIdentity,
  preparePilotIsolation,
  preflightPilotIsolation,
  resolvePilotPaths,
  startPilotDaemon,
  stopPilotDaemon,
  verifyPilotDaemon,
  verifyPilotIdentity,
} from "./pilot-isolation.js";

const roots = new Set<string>();
const sourceHomes = new Set<string>();
const servers = new Set<Server>();
let sequence = 0;

function freshRoot(): string {
  sequence += 1;
  const root = `/private/tmp/ccp-sr-${process.pid}-${sequence}`;
  roots.add(root);
  return root;
}

function freshSourceHome(): string {
  sequence += 1;
  const path = `/private/tmp/ccp-sr-source-${process.pid}-${sequence}`;
  sourceHomes.add(path);
  return path;
}

const CODEX_VERSION = "0.146.0-alpha.9.2";

async function createFakeSourceCli(root: string): Promise<string> {
  await preparePilotIsolation(root);
  const sourceCli = join(root, "desktop-codex-source");
  await writeFile(sourceCli, "#!/bin/sh\nexit 99\n", { mode: 0o700 });
  return sourceCli;
}

async function prepareTestIdentity(root: string): Promise<string> {
  const sourceHome = freshSourceHome();
  await mkdir(sourceHome, { mode: 0o700 });
  await writeFile(
    join(sourceHome, "auth.json"),
    JSON.stringify({ testOnlyCredential: "not-a-real-token" }),
    { mode: 0o600 },
  );
  await preparePilotIdentity(root, sourceHome);
  return sourceHome;
}

async function listenOnSocket(socketPath: string): Promise<Server> {
  await mkdir(dirname(socketPath), { recursive: true, mode: 0o700 });
  const server = createServer();
  servers.add(server);
  await new Promise<void>((resolvePromise, reject) => {
    server.once("error", reject);
    server.listen(socketPath, resolvePromise);
  });
  return server;
}

afterEach(async () => {
  for (const server of servers) {
    if (server.listening) {
      await new Promise<void>((resolvePromise) =>
        server.close(() => resolvePromise()),
      );
    }
  }
  servers.clear();
  for (const sourceHome of sourceHomes) {
    if (!sourceHome.startsWith(`/private/tmp/ccp-sr-source-${process.pid}-`)) {
      continue;
    }
    await rm(sourceHome, { recursive: true, force: true });
  }
  sourceHomes.clear();
  for (const root of roots) {
    if (!root.startsWith(`/private/tmp/ccp-sr-${process.pid}-`)) continue;
    await rm(root, { recursive: true, force: true });
  }
  roots.clear();
});

describe.runIf(process.platform === "darwin")(
  "shared-runtime pilot isolation",
  () => {
    it("prepares a short private root and a private random API key", async () => {
      const root = freshRoot();
      const report = await preparePilotIsolation(root);
      const rootStats = await lstat(root);
      const keyStats = await lstat(report.paths.apiKeyFile);
      const key = await readFile(report.paths.apiKeyFile, "utf8");

      expect(rootStats.mode & 0o777).toBe(0o700);
      expect(keyStats.mode & 0o777).toBe(0o600);
      expect(key).toMatch(/^[A-Za-z0-9_-]{43}$/);
      expect(report.paths.home).not.toBe(process.env.HOME);
      expect(report.paths.codexHome).not.toBe(process.env.CODEX_HOME);
      expect(Buffer.byteLength(report.paths.daemonSocket)).toBeLessThanOrEqual(
        100,
      );

      const firstKey = key;
      await preparePilotIsolation(root);
      expect(await readFile(report.paths.apiKeyFile, "utf8")).toBe(firstKey);
    });

    it("rejects production, non-temporary, and overlong pilot targets", () => {
      expect(() => assertPilotPort(8765)).toThrow("never use production");
      expect(() => assertPilotPort(18766)).toThrow("restricted to port");
      expect(() =>
        resolvePilotPaths(join(process.env.HOME!, "ccp-sr-test")),
      ).toThrow("direct child of /private/tmp");
      expect(() =>
        resolvePilotPaths(`/private/tmp/ccp-sr-${"x".repeat(90)}`),
      ).toThrow("too long");
    });

    it("copies only auth.json into the isolated identity with a hash-only manifest", async () => {
      const root = freshRoot();
      const sourceHome = freshSourceHome();
      await mkdir(sourceHome, { mode: 0o700 });
      const auth = JSON.stringify({
        testOnlyCredential: "not-a-real-token",
      });
      await writeFile(join(sourceHome, "auth.json"), auth, { mode: 0o600 });
      await writeFile(
        join(sourceHome, "config.toml"),
        "must-not-copy = true\n",
      );
      await mkdir(join(sourceHome, "sessions"), { mode: 0o700 });

      const manifest = await preparePilotIdentity(root, sourceHome);
      const paths = resolvePilotPaths(root);
      const authStats = await lstat(paths.identityFile);
      const manifestStats = await lstat(paths.identityManifest);
      const manifestText = await readFile(paths.identityManifest, "utf8");

      expect(authStats.mode & 0o777).toBe(0o600);
      expect(manifestStats.mode & 0o777).toBe(0o600);
      expect(await readFile(paths.identityFile, "utf8")).toBe(auth);
      expect(manifest.sourceCodexHome).toBe(await realpath(sourceHome));
      expect(manifest.authSha256).toMatch(/^[a-f0-9]{64}$/);
      expect(manifestText).not.toContain("not-a-real-token");
      await expect(
        lstat(join(paths.codexHome, "config.toml")),
      ).rejects.toMatchObject({ code: "ENOENT" });
      await expect(
        lstat(join(paths.codexHome, "sessions")),
      ).rejects.toMatchObject({ code: "ENOENT" });
      await expect(verifyPilotIdentity(root)).resolves.toEqual(manifest);
    });

    it("rejects a symbolic-link auth source", async () => {
      const root = freshRoot();
      const sourceHome = freshSourceHome();
      await mkdir(sourceHome, { mode: 0o700 });
      await writeFile(join(sourceHome, "auth-real.json"), "{}", {
        mode: 0o600,
      });
      await symlink("auth-real.json", join(sourceHome, "auth.json"));

      await expect(preparePilotIdentity(root, sourceHome)).rejects.toThrow(
        "real regular file",
      );
    });

    it("fails closed when root or API key permissions are relaxed", async () => {
      const root = freshRoot();
      const report = await preparePilotIsolation(root);
      await chmod(report.paths.apiKeyFile, 0o644);
      await expect(
        preflightPilotIsolation(root, { checkPort: false }),
      ).rejects.toThrow("mode 0600");

      await chmod(report.paths.apiKeyFile, 0o600);
      await chmod(root, 0o755);
      await expect(
        preflightPilotIsolation(root, { checkPort: false }),
      ).rejects.toThrow("mode 0700");
    });

    it("builds a minimal environment without inherited credentials or production paths", async () => {
      const root = freshRoot();
      const sourceCli = await createFakeSourceCli(root);
      const report = await preparePilotIsolation(root);
      await preparePilotDaemon(root, sourceCli, CODEX_VERSION, {
        runCommand: async () => ({
          exitCode: 0,
          stdout: `codex-cli ${CODEX_VERSION}\n`,
          stderr: "",
        }),
      });
      const key = (await readFile(report.paths.apiKeyFile, "utf8")).trim();
      const env = await buildPilotEnvironment(
        report,
        { cliPath: sourceCli, expectedVersion: CODEX_VERSION },
        {
          PATH: process.env.PATH,
          HOME: process.env.HOME,
          BRIDGE_PORT: "8765",
          BRIDGE_API_KEY: "production-secret",
          BRIDGE_PUBLIC_WS_URL: "wss://production.invalid",
          ANTHROPIC_API_KEY: "must-not-be-inherited",
        },
      );

      expect(env.HOME).toBe(report.paths.home);
      expect(env.CODEX_HOME).toBe(report.paths.codexHome);
      expect(env.CODEX_SQLITE_HOME).toBe(report.paths.codexHome);
      expect(env.PWD).toBe(report.paths.canaryProject);
      expect(env.BRIDGE_HOST).toBe(PILOT_HOST);
      expect(env.BRIDGE_PORT).toBe(String(PILOT_PORT));
      expect(env.BRIDGE_API_KEY).toBe(key);
      expect(env.BRIDGE_API_KEY).not.toBe("production-secret");
      expect(env.BRIDGE_DISABLE_PUSH).toBe("1");
      expect(env.BRIDGE_DISABLE_MDNS).toBe("1");
      expect(env.BRIDGE_AUTO_ARTIFACTS).toBe("0");
      expect(env.BRIDGE_DEMO_MODE).toBe("1");
      expect(env.BRIDGE_CODEX_APP_SERVER_MODE).toBe("daemon");
      expect(env.BRIDGE_CODEX_SHARED_PILOT).toBe("1");
      expect(env.BRIDGE_CODEX_SHARED_PILOT_ALLOW_THREAD_START).toBe("0");
      expect(env.BRIDGE_CODEX_SHARED_PILOT_ALLOW_TURN_START).toBe("0");
      expect(env.BRIDGE_CODEX_DAEMON_CLI).toBe(report.paths.managedCodexCli);
      expect(env.BRIDGE_CODEX_DAEMON_CLI).not.toBe(sourceCli);
      expect(env.BRIDGE_CODEX_DAEMON_SOCKET).toBe(report.paths.daemonSocket);
      expect(env.BRIDGE_ALLOWED_DIRS).toBe(report.paths.canaryProject);
      expect(env.BRIDGE_PUBLIC_WS_URL).toBeUndefined();
      expect(env.ANTHROPIC_API_KEY).toBeUndefined();
      expect(Object.values(env)).not.toContain("must-not-be-inherited");

      const phoneEnv = await buildPilotEnvironment(report, {
        cliPath: sourceCli,
        expectedVersion: CODEX_VERSION,
        phoneLink: true,
      });
      expect(phoneEnv.BRIDGE_DEMO_MODE).toBeUndefined();
      expect(phoneEnv.BRIDGE_API_KEY).toBe(key);
    });

    it("copies the exact source CLI into a private managed slot and records a private manifest", async () => {
      const root = freshRoot();
      const sourceCli = await createFakeSourceCli(root);
      const runCommand = vi.fn(
        async (_cli: string, args: string[], env: NodeJS.ProcessEnv) => {
          expect(env.HOME).toBe(resolvePilotPaths(root).home);
          expect(env.CODEX_HOME).toBe(resolvePilotPaths(root).codexHome);
          expect(env.CODEX_SQLITE_HOME).toBe(resolvePilotPaths(root).codexHome);
          expect(env.TMPDIR).toBe(resolvePilotPaths(root).temporaryDirectory);
          expect(env.PWD).toBe(resolvePilotPaths(root).canaryProject);
          expect(args).toEqual(["--version"]);
          return {
            exitCode: 0,
            stdout: `codex-cli ${CODEX_VERSION}\n`,
            stderr: "",
          };
        },
      );

      const manifest = await preparePilotDaemon(
        root,
        sourceCli,
        CODEX_VERSION,
        { runCommand },
      );
      const paths = resolvePilotPaths(root);
      const managedStats = await lstat(paths.managedCodexCli);
      const manifestStats = await lstat(paths.daemonManifest);

      expect(managedStats.isSymbolicLink()).toBe(false);
      expect(managedStats.mode & 0o777).toBe(0o700);
      expect(manifestStats.mode & 0o777).toBe(0o600);
      expect(await readFile(paths.managedCodexCli, "utf8")).toBe(
        await readFile(sourceCli, "utf8"),
      );
      expect(manifest.sourceCliPath).toBe(await realpath(sourceCli));
      expect(manifest.managedCliPath).toBe(paths.managedCodexCli);
      expect(manifest.sourceSha256).toMatch(/^[a-f0-9]{64}$/);
      expect(manifest.managedSha256).toBe(manifest.sourceSha256);
      expect(manifest.expectedVersion).toBe(CODEX_VERSION);
    });

    it("refuses to start before the isolated identity is prepared", async () => {
      const root = freshRoot();
      const sourceCli = await createFakeSourceCli(root);
      const runCommand = vi.fn();

      await expect(
        startPilotDaemon(root, sourceCli, CODEX_VERSION, { runCommand }),
      ).rejects.toThrow("prepare-identity first");
      expect(runCommand).not.toHaveBeenCalled();
    });

    it("starts, verifies, and stops only the exact isolated daemon without bootstrap", async () => {
      const root = freshRoot();
      const sourceCli = await createFakeSourceCli(root);
      await prepareTestIdentity(root);
      const paths = resolvePilotPaths(root);
      const invocations: Array<{
        args: string[];
        env: NodeJS.ProcessEnv;
      }> = [];
      let socketServer: Server | undefined;
      const runCommand = vi.fn(
        async (_cli: string, args: string[], env: NodeJS.ProcessEnv) => {
          invocations.push({ args: [...args], env: { ...env } });
          if (args.length === 1 && args[0] === "--version") {
            return {
              exitCode: 0,
              stdout: `codex-cli ${CODEX_VERSION}\n`,
              stderr: "",
            };
          }
          if (args.at(-1) === "start") {
            socketServer ??= await listenOnSocket(paths.daemonSocket);
            return { exitCode: 0, stdout: "", stderr: "" };
          }
          if (args.at(-1) === "version") {
            return {
              exitCode: 0,
              stdout: JSON.stringify({
                status: "running",
                backend: "pid",
                cliVersion: CODEX_VERSION,
                appServerVersion: CODEX_VERSION,
                managedCodexPath: paths.managedCodexCli,
                managedCodexVersion: CODEX_VERSION,
                socketPath: paths.daemonSocket,
              }),
              stderr: "",
            };
          }
          if (args.at(-1) === "stop") {
            if (!socketServer) throw new Error("Test daemon was not started");
            await new Promise<void>((resolvePromise) =>
              socketServer.close(() => resolvePromise()),
            );
            return { exitCode: 0, stdout: "", stderr: "" };
          }
          throw new Error(`Unexpected command: ${args.join(" ")}`);
        },
      );

      await preparePilotDaemon(root, sourceCli, CODEX_VERSION, { runCommand });
      const started = await startPilotDaemon(root, sourceCli, CODEX_VERSION, {
        runCommand,
      });
      expect(started.socketPath).toBe(paths.daemonSocket);
      expect(started.expectedVersion).toBe(CODEX_VERSION);

      const verified = await verifyPilotDaemon(root, sourceCli, CODEX_VERSION, {
        runCommand,
      });
      expect(verified.socketInode).toBe(started.socketInode);

      await stopPilotDaemon(root, sourceCli, CODEX_VERSION, {
        runCommand,
        wait: async () => {},
      });
      await expect(lstat(paths.daemonSocket)).rejects.toMatchObject({
        code: "ENOENT",
      });
      expect(invocations.some(({ args }) => args.includes("bootstrap"))).toBe(
        false,
      );
      for (const { env } of invocations) {
        expect(env.HOME).toBe(paths.home);
        expect(env.CODEX_HOME).toBe(paths.codexHome);
        expect(env.TMPDIR).toBe(paths.temporaryDirectory);
        expect(env.PWD).toBe(paths.canaryProject);
        expect(env.BRIDGE_PORT).toBeUndefined();
        expect(env.BRIDGE_API_KEY).toBeUndefined();
      }
    });

    it("fails closed when the source CLI or managed copy no longer matches the manifest", async () => {
      const root = freshRoot();
      const sourceCli = await createFakeSourceCli(root);
      const runCommand = vi.fn(async () => ({
        exitCode: 0,
        stdout: `codex-cli ${CODEX_VERSION}\n`,
        stderr: "",
      }));
      await preparePilotDaemon(root, sourceCli, CODEX_VERSION, { runCommand });
      await writeFile(resolvePilotPaths(root).managedCodexCli, "tampered", {
        mode: 0o700,
      });

      await expect(
        verifyPilotDaemon(root, sourceCli, CODEX_VERSION, { runCommand }),
      ).rejects.toThrow("hash no longer matches");
      const report = await preflightPilotIsolation(root, {
        checkPort: false,
      });
      await expect(
        buildPilotEnvironment(report, {
          cliPath: sourceCli,
          expectedVersion: CODEX_VERSION,
        }),
      ).rejects.toThrow("hash no longer matches");
    });
  },
);
