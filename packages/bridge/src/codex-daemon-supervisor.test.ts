import {
  appendFile,
  chmod,
  mkdir,
  mkdtemp,
  rm,
  symlink,
  writeFile,
} from "node:fs/promises";
import { createServer, type Server } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { CodexDaemonConfig } from "./codex-app-server-config.js";
import {
  assertCodexDaemonSocketIdentity,
  verifyCodexDaemon,
  type CodexDaemonSupervisorDependencies,
} from "./codex-daemon-supervisor.js";

const VERSION = "0.146.0-alpha.9.2";
const fixtures: DaemonFixture[] = [];

interface DaemonFixture {
  root: string;
  home: string;
  cliPath: string;
  socketPath: string;
  server: Server;
  config: CodexDaemonConfig;
  dependencies: CodexDaemonSupervisorDependencies;
}

async function listen(server: Server, socketPath: string): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, resolve);
  });
}

async function close(server: Server): Promise<void> {
  if (!server.listening) return;
  await new Promise<void>((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()));
  });
}

async function createFixture(): Promise<DaemonFixture> {
  // AF_UNIX paths are short (104 bytes on macOS), so keep the fixture terse.
  const root = await mkdtemp(
    join(process.platform === "darwin" ? "/private/tmp" : tmpdir(), "ccp-d-"),
  );
  const home = join(root, "h");
  const controlDirectory = join(home, "c");
  const cliDirectory = join(home, "packages", "standalone", "current");
  const cliPath = join(cliDirectory, "codex");
  const socketPath = join(controlDirectory, "s.sock");
  await mkdir(controlDirectory, { recursive: true, mode: 0o700 });
  await mkdir(cliDirectory, { recursive: true, mode: 0o700 });
  await writeFile(cliPath, "#!/bin/sh\nexit 0\n", { mode: 0o700 });
  const server = createServer();
  await listen(server, socketPath);

  const config: CodexDaemonConfig = {
    codexHome: home,
    cliPath,
    socketPath,
    expectedVersion: VERSION,
  };
  const dependencies: CodexDaemonSupervisorDependencies = {
    runVersion: () => ({
      status: "running",
      backend: "pid",
      cliVersion: VERSION,
      appServerVersion: VERSION,
      managedCodexPath: cliPath,
      managedCodexVersion: VERSION,
      socketPath,
    }),
  };
  const fixture = {
    root,
    home,
    cliPath,
    socketPath,
    server,
    config,
    dependencies,
  };
  fixtures.push(fixture);
  return fixture;
}

afterEach(async () => {
  for (const fixture of fixtures.splice(0)) {
    await close(fixture.server);
    await rm(fixture.root, { recursive: true, force: true });
  }
});

describe.runIf(process.platform !== "win32")("CodexDaemonSupervisor", () => {
  it("accepts an exact running daemon and records socket identity", async () => {
    const fixture = await createFixture();
    const verified = verifyCodexDaemon(fixture.config, fixture.dependencies);

    expect(verified.cliVersion).toBe(VERSION);
    expect(verified.appServerVersion).toBe(VERSION);
    expect(verified.socketPath).toBe(fixture.socketPath);
    expect(verified.socketIdentity.device).toBeTypeOf("number");
    expect(verified.socketIdentity.inode).toBeGreaterThan(0);
    expect(() =>
      assertCodexDaemonSocketIdentity(
        verified.socketPath,
        verified.socketIdentity,
      ),
    ).not.toThrow();
  });

  it("accepts separately pinned official CLI and app-server labels", async () => {
    const fixture = await createFixture();
    const appServerVersion = "0.146.0";
    const verified = verifyCodexDaemon(
      {
        ...fixture.config,
        expectedAppServerVersion: appServerVersion,
      },
      {
        runVersion: () => ({
          status: "running",
          backend: "pid",
          cliVersion: VERSION,
          appServerVersion,
          managedCodexPath: fixture.cliPath,
          managedCodexVersion: appServerVersion,
          socketPath: fixture.socketPath,
        }),
      },
    );

    expect(verified.cliVersion).toBe(VERSION);
    expect(verified.appServerVersion).toBe(appServerVersion);
  });

  it("requires an absolute executable CLI", async () => {
    const fixture = await createFixture();
    expect(() =>
      verifyCodexDaemon(
        { ...fixture.config, cliPath: "codex" },
        fixture.dependencies,
      ),
    ).toThrow("must be an absolute path");

    await chmod(fixture.cliPath, 0o600);
    expect(() =>
      verifyCodexDaemon(fixture.config, fixture.dependencies),
    ).toThrow();
  });

  it("requires an exact running CLI, managed, and app-server version", async () => {
    const fixture = await createFixture();
    expect(() =>
      verifyCodexDaemon(fixture.config, {
        runVersion: () => ({
          status: "running",
          backend: "pid",
          cliVersion: VERSION,
          appServerVersion: "0.145.0",
          managedCodexPath: fixture.cliPath,
          managedCodexVersion: VERSION,
          socketPath: fixture.socketPath,
        }),
      }),
    ).toThrow("version mismatch");

    expect(() =>
      verifyCodexDaemon(fixture.config, {
        runVersion: () => ({
          status: "stopped",
          cliVersion: VERSION,
          appServerVersion: VERSION,
          managedCodexPath: fixture.cliPath,
          managedCodexVersion: VERSION,
          socketPath: fixture.socketPath,
        }),
      }),
    ).toThrow("not running");
  });

  it("rejects a socket outside CODEX_HOME", async () => {
    const fixture = await createFixture();
    const outsideDirectory = join(fixture.root, "outside");
    const outsideSocket = join(outsideDirectory, "daemon.sock");
    await mkdir(outsideDirectory, { mode: 0o700 });
    const outsideServer = createServer();
    await close(fixture.server);
    fixture.server = outsideServer;
    await listen(outsideServer, outsideSocket);

    expect(() =>
      verifyCodexDaemon(
        { ...fixture.config, socketPath: outsideSocket },
        {
          runVersion: () => ({
            status: "running",
            backend: "pid",
            cliVersion: VERSION,
            appServerVersion: VERSION,
            managedCodexPath: fixture.cliPath,
            managedCodexVersion: VERSION,
            socketPath: outsideSocket,
          }),
        },
      ),
    ).toThrow("must be inside CODEX_HOME");
  });

  it("rejects unsafe parents and a socket owned by another uid", async () => {
    const fixture = await createFixture();
    await chmod(join(fixture.home, "c"), 0o777);
    expect(() =>
      verifyCodexDaemon(fixture.config, fixture.dependencies),
    ).toThrow("must not be group- or world-writable");

    await chmod(join(fixture.home, "c"), 0o700);
    await chmod(fixture.socketPath, 0o666);
    expect(() =>
      verifyCodexDaemon(fixture.config, fixture.dependencies),
    ).toThrow("must not be group- or world-writable");

    await chmod(fixture.socketPath, 0o600);
    const uid = process.getuid?.() ?? 0;
    expect(() =>
      verifyCodexDaemon(fixture.config, {
        ...fixture.dependencies,
        getUid: () => uid + 1,
      }),
    ).toThrow("owned by the current user");
  });

  it("rejects a non-socket and a replaced socket identity", async () => {
    const fixture = await createFixture();
    const verified = verifyCodexDaemon(fixture.config, fixture.dependencies);
    await close(fixture.server);
    await writeFile(fixture.socketPath, "not a socket");

    expect(() =>
      verifyCodexDaemon(fixture.config, fixture.dependencies),
    ).toThrow("must identify a Unix socket");
    expect(() =>
      assertCodexDaemonSocketIdentity(
        verified.socketPath,
        verified.socketIdentity,
      ),
    ).toThrow("was replaced after verification");
  });

  it("rejects a daemon that reports a different socket", async () => {
    const fixture = await createFixture();
    expect(() =>
      verifyCodexDaemon(fixture.config, {
        runVersion: () => ({
          status: "running",
          backend: "pid",
          cliVersion: VERSION,
          appServerVersion: VERSION,
          managedCodexPath: fixture.cliPath,
          managedCodexVersion: VERSION,
          socketPath: fixture.cliPath,
        }),
      }),
    ).toThrow("reported a different control socket");
  });

  it("requires a private current-user CLI inside a safe CODEX_HOME", async () => {
    const fixture = await createFixture();
    const outsideCli = join(fixture.root, "outside-codex");
    await writeFile(outsideCli, "#!/bin/sh\nexit 0\n", { mode: 0o700 });
    expect(() =>
      verifyCodexDaemon(
        { ...fixture.config, cliPath: outsideCli },
        fixture.dependencies,
      ),
    ).toThrow("must be inside CODEX_HOME");

    const symlinkCli = join(fixture.home, "codex-link");
    await symlink(fixture.cliPath, symlinkCli);
    expect(() =>
      verifyCodexDaemon(
        { ...fixture.config, cliPath: symlinkCli },
        fixture.dependencies,
      ),
    ).toThrow("must identify a regular file");

    await chmod(fixture.cliPath, 0o722);
    expect(() =>
      verifyCodexDaemon(fixture.config, fixture.dependencies),
    ).toThrow("must not be group- or world-writable");

    await chmod(fixture.cliPath, 0o700);
    await chmod(join(fixture.home, "packages"), 0o777);
    expect(() =>
      verifyCodexDaemon(fixture.config, fixture.dependencies),
    ).toThrow("parent directory must not be group- or world-writable");
  });

  it("requires the daemon to report the exact managed CLI", async () => {
    const fixture = await createFixture();
    expect(() =>
      verifyCodexDaemon(fixture.config, {
        runVersion: () => ({
          status: "running",
          backend: "pid",
          cliVersion: VERSION,
          appServerVersion: VERSION,
          managedCodexPath: fixture.home,
          managedCodexVersion: VERSION,
          socketPath: fixture.socketPath,
        }),
      }),
    ).toThrow("different managed Codex CLI");
  });

  it("rejects an unaudited daemon lifecycle backend", async () => {
    const fixture = await createFixture();
    expect(() =>
      verifyCodexDaemon(fixture.config, {
        runVersion: () => ({
          status: "running",
          backend: "launchd",
          cliVersion: VERSION,
          appServerVersion: VERSION,
          managedCodexPath: fixture.cliPath,
          managedCodexVersion: VERSION,
          socketPath: fixture.socketPath,
        }),
      }),
    ).toThrow("audited pid backend");
  });

  it("uses only a short burst cache and invalidates it on in-place CLI changes", async () => {
    const fixture = await createFixture();
    let nowMs = 10_000;
    const runVersion = vi.fn(fixture.dependencies.runVersion!);
    const dependencies: CodexDaemonSupervisorDependencies = {
      runVersion,
      now: () => nowMs,
    };

    verifyCodexDaemon(fixture.config, dependencies);
    verifyCodexDaemon(fixture.config, dependencies);
    expect(runVersion).toHaveBeenCalledTimes(1);

    await appendFile(fixture.cliPath, "# changed in place\n");
    verifyCodexDaemon(fixture.config, dependencies);
    expect(runVersion).toHaveBeenCalledTimes(2);

    nowMs += 2_001;
    verifyCodexDaemon(fixture.config, dependencies);
    expect(runVersion).toHaveBeenCalledTimes(3);
  });
});
