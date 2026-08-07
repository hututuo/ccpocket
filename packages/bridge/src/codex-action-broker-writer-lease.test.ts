import { createHash } from "node:crypto";
import {
  mkdtemp,
  readFile,
  readdir,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { CodexActionBroker } from "./codex-action-broker.js";
import { CodexActionBrokerWriterLease } from "./codex-action-broker-writer-lease.js";
import type { CodexSharedRuntimeSafeDaemonIdentity } from "./codex-shared-runtime-control.js";

const roots: string[] = [];
const DAEMON: CodexSharedRuntimeSafeDaemonIdentity = {
  expectedVersion: "1.0.0",
  cliVersion: "1.0.0",
  appServerVersion: "1.0.0",
  socketDevice: 17,
  socketInode: 29,
};

afterEach(async () => {
  await Promise.all(
    roots.splice(0).map((root) => rm(root, { recursive: true, force: true })),
  );
});

async function rootFixture(): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), "cab-writer-lease-"));
  roots.push(root);
  return root;
}

describe("CodexActionBrokerWriterLease", () => {
  it("admits one Bridge for the same daemon/source and transfers monotonically", async () => {
    const root = await rootFixture();
    const alive = new Map([
      [101, true],
      [202, true],
    ]);
    const first = new CodexActionBrokerWriterLease("source-a", {
      rootDir: root,
      pid: 101,
      randomToken: () => "first-process",
      processAlive: (pid) => alive.get(pid) ?? false,
    });
    const second = new CodexActionBrokerWriterLease("source-a", {
      rootDir: root,
      pid: 202,
      randomToken: () => "second-process",
      processAlive: (pid) => alive.get(pid) ?? false,
    });

    await expect(first.acquire(DAEMON)).resolves.toMatchObject({
      held: true,
      leaseEpoch: 1,
    });
    await expect(second.acquire(DAEMON)).resolves.toMatchObject({
      held: false,
      ownerPid: 101,
      reason: "owned_elsewhere",
    });
    await first.release();
    await expect(second.acquire(DAEMON)).resolves.toMatchObject({
      held: true,
      leaseEpoch: 2,
    });
    expect(await first.assertHeld(DAEMON)).toBe(false);
    expect(await second.assertHeld(DAEMON)).toBe(true);
    await second.release();
  });

  it("recovers a dead owner but never steals a live owner for a late heartbeat", async () => {
    const root = await rootFixture();
    let firstAlive = true;
    const first = new CodexActionBrokerWriterLease("source-a", {
      rootDir: root,
      pid: 303,
      randomToken: () => "dead-owner",
      processAlive: (pid) => pid === 303 && firstAlive,
    });
    const second = new CodexActionBrokerWriterLease("source-a", {
      rootDir: root,
      pid: 404,
      randomToken: () => "replacement-owner",
      processAlive: (pid) => pid === 303 && firstAlive,
    });
    await first.acquire(DAEMON);
    await expect(second.acquire(DAEMON)).resolves.toMatchObject({
      held: false,
    });
    firstAlive = false;
    await expect(second.acquire(DAEMON)).resolves.toMatchObject({
      held: true,
      leaseEpoch: 2,
    });
    expect(await first.assertHeld(DAEMON)).toBe(false);
    await second.release();
  });

  it("prevents two daemon sockets for the same Codex source from splitting the writer", async () => {
    const root = await rootFixture();
    const first = new CodexActionBrokerWriterLease("source-a", {
      rootDir: root,
      pid: 707,
      randomToken: () => "daemon-one",
      processAlive: (pid) => pid === 707,
    });
    const second = new CodexActionBrokerWriterLease("source-a", {
      rootDir: root,
      pid: 808,
      randomToken: () => "daemon-two",
      processAlive: (pid) => pid === 707,
    });
    await expect(first.acquire(DAEMON)).resolves.toMatchObject({ held: true });
    await expect(
      second.acquire({ ...DAEMON, socketInode: DAEMON.socketInode + 1 }),
    ).resolves.toMatchObject({
      held: false,
      ownerPid: 707,
      reason: "owned_elsewhere",
    });
    await first.release();
  });

  it("releases the old socket identity before reacquiring a restarted daemon", async () => {
    const root = await rootFixture();
    const lease = new CodexActionBrokerWriterLease("source-a", {
      rootDir: root,
      pid: 909,
      randomToken: () => "same-bridge-new-daemon",
      processAlive: (pid) => pid === 909,
    });
    await expect(lease.acquire(DAEMON)).resolves.toMatchObject({
      held: true,
      leaseEpoch: 1,
    });
    const restarted = { ...DAEMON, socketInode: DAEMON.socketInode + 10 };
    await expect(lease.acquire(restarted)).resolves.toMatchObject({
      held: true,
      leaseEpoch: 2,
    });
    expect(await lease.assertHeld(DAEMON)).toBe(false);
    expect(await lease.assertHeld(restarted)).toBe(true);
    await lease.release();
  });

  it("reports an asynchronously lost heartbeat lease", async () => {
    const root = await rootFixture();
    const lease = new CodexActionBrokerWriterLease("source-a", {
      rootDir: root,
      pid: 913,
      randomToken: () => "heartbeat-owner",
      processAlive: (pid) => pid === 913,
      heartbeatMs: 100,
    });
    const acquired = await lease.acquire(DAEMON);
    expect(acquired).toMatchObject({ held: true });
    const ownerPath = join(acquired.lockPath!, "owner.json");
    const owner = JSON.parse(await readFile(ownerPath, "utf8"));
    const loss = new Promise<string>((resolve) => lease.once("lost", resolve));
    await writeFile(
      ownerPath,
      `${JSON.stringify({ ...owner, processNonce: "replacement-owner" })}\n`,
      { mode: 0o600 },
    );

    await expect(loss).resolves.toBe("owner_mismatch");
    expect(lease.health).toMatchObject({ held: false });
  });

  it("does not strand an empty source lock when setup fails after mkdir", async () => {
    const root = await rootFixture();
    const sourceKey = createHash("sha256")
      .update("source-a")
      .digest("hex")
      .slice(0, 32);
    await writeFile(join(root, `${sourceKey}.epoch`), "not-an-epoch\n", {
      mode: 0o600,
    });
    const lease = new CodexActionBrokerWriterLease("source-a", {
      rootDir: root,
      pid: 919,
      randomToken: () => "failed-setup",
      processAlive: () => false,
    });

    await expect(lease.acquire(DAEMON)).resolves.toMatchObject({
      held: false,
      reason: "unsafe_lock",
    });
    expect(
      (await readdir(root)).filter((entry) => entry.endsWith(".lock")),
    ).toEqual([]);
  });

  it("reloads the newest shared ledger only after standby wins the lease", async () => {
    const root = await rootFixture();
    const leaseRoot = join(root, "lease");
    const ledgerPath = join(root, "broker.json");
    const alive = new Map([
      [505, true],
      [606, true],
    ]);
    const leaderLease = new CodexActionBrokerWriterLease("source-a", {
      rootDir: leaseRoot,
      pid: 505,
      randomToken: () => "leader",
      processAlive: (pid) => alive.get(pid) ?? false,
    });
    const standbyLease = new CodexActionBrokerWriterLease("source-a", {
      rootDir: leaseRoot,
      pid: 606,
      randomToken: () => "standby",
      processAlive: (pid) => alive.get(pid) ?? false,
    });
    const leader = new CodexActionBroker({ filePath: ledgerPath });
    const standby = new CodexActionBroker({ filePath: ledgerPath });

    await leaderLease.acquire(DAEMON);
    await leader.reloadFromDisk();
    const generation = await leader.beginSourceGeneration("source-a");
    await leader.observePending({
      identity: {
        codexSourceId: "source-a",
        threadId: "thread-a",
        turnId: "turn-a",
        requestId: "request-a",
        generation: generation.generation,
      },
      method: "item/commandExecution/requestApproval",
      kind: "command_approval",
    });

    await standby.health();
    const bytesBeforeStandbyRead = await readFile(ledgerPath, "utf8");
    await standby.listReadonly({ codexSourceId: "source-a" });
    expect(await readFile(ledgerPath, "utf8")).toBe(bytesBeforeStandbyRead);

    await leader.observePending({
      identity: {
        codexSourceId: "source-a",
        threadId: "thread-b",
        turnId: "turn-b",
        requestId: "request-b",
        generation: generation.generation,
      },
      method: "item/fileChange/requestApproval",
      kind: "file_approval",
    });
    await expect(standbyLease.acquire(DAEMON)).resolves.toMatchObject({
      held: false,
    });

    await leaderLease.release();
    await expect(standbyLease.acquire(DAEMON)).resolves.toMatchObject({
      held: true,
    });
    await standby.reloadFromDisk();
    const handoffGeneration = await standby.beginSourceGeneration("source-a");
    expect(handoffGeneration.generation).toBe(generation.generation + 1);
    expect(
      (
        await standby.list({
          codexSourceId: "source-a",
          includeTerminal: true,
        })
      ).map((record) => [record.identity.threadId, record.state]),
    ).toEqual([
      ["thread-a", "expired"],
      ["thread-b", "expired"],
    ]);
    await standbyLease.release();
  });
});
