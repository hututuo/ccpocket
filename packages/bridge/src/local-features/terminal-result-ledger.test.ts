import {
  chmod,
  mkdtemp,
  readFile,
  readdir,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import {
  TerminalResultLedger,
  type TerminalResultScope,
} from "./terminal-result-ledger.js";

const temporaryDirectories: string[] = [];

afterEach(async () => {
  await Promise.all(
    temporaryDirectories
      .splice(0)
      .map((directory) => rm(directory, { recursive: true, force: true })),
  );
});

describe("TerminalResultLedger", () => {
  it("atomically restores terminal results after a restart", async () => {
    const { directory, file } = await temporaryLedgerFile();
    const scope = terminalScope();
    const first = new TerminalResultLedger(file);
    await first.init();
    expect(first.health).toEqual({
      initialized: true,
      ready: true,
      degraded: false,
    });

    const persisted = await first.record({
      ...scope,
      provider: "codex",
      threadId: "thread-restart",
      turnId: "turn-restart",
      result: "completed",
      observedAt: "2026-08-01T00:00:00.000Z",
    });
    await first.flush();

    const second = new TerminalResultLedger(file);
    await second.init();
    expect(second.list(scope)).toEqual([persisted]);
    expect((await stat(file)).mode & 0o777).toBe(0o600);
    expect(
      (await readdir(directory)).filter((name) => name.endsWith(".tmp")),
    ).toEqual([]);
    expect(JSON.parse(await readFile(file, "utf8"))).toMatchObject({
      version: 1,
      revision: persisted.revision,
    });
  });

  it("reads v1 records without turn ids and upgrades the same slot additively", async () => {
    const { file } = await temporaryLedgerFile();
    const scope = terminalScope();
    await writeFile(
      file,
      `${JSON.stringify({
        version: 1,
        revision: 4,
        records: [
          {
            ...scope,
            provider: "codex",
            threadId: "thread-legacy",
            result: "completed",
            observedAt: "2026-08-01T00:00:01.000Z",
            revision: 4,
          },
        ],
      })}\n`,
      { mode: 0o600 },
    );

    const ledger = new TerminalResultLedger(file);
    await ledger.init();
    expect(ledger.list(scope)).toEqual([
      {
        ...scope,
        provider: "codex",
        threadId: "thread-legacy",
        result: "completed",
        observedAt: "2026-08-01T00:00:01.000Z",
        revision: 4,
      },
    ]);

    await ledger.record({
      ...scope,
      provider: "codex",
      threadId: "thread-legacy",
      turnId: "turn-new",
      result: "failed",
      observedAt: "2026-08-01T00:00:02.000Z",
    });

    expect(JSON.parse(await readFile(file, "utf8"))).toMatchObject({
      version: 1,
      records: [{ threadId: "thread-legacy", turnId: "turn-new" }],
    });
  });

  it("keeps one thread slot while a later terminal turn replaces the old turn", async () => {
    const { file } = await temporaryLedgerFile();
    const scope = terminalScope();
    const ledger = new TerminalResultLedger(file);
    await ledger.init();
    await ledger.record({
      ...scope,
      provider: "codex",
      threadId: "thread-reused",
      turnId: "turn-1",
      result: "completed",
      observedAt: "2026-08-01T00:00:02.000Z",
    });
    const latest = await ledger.record({
      ...scope,
      provider: "codex",
      threadId: "thread-reused",
      turnId: "turn-2",
      result: "completed",
      observedAt: "2026-08-01T00:00:02.000Z",
    });

    expect(ledger.list(scope)).toEqual([latest]);
    expect(latest).toMatchObject({
      threadId: "thread-reused",
      turnId: "turn-2",
      result: "completed",
    });
  });

  it.each(["", " turn", "turn\nid", "t".repeat(257)])(
    "rejects an unsafe turn id %j",
    async (turnId) => {
      const { file } = await temporaryLedgerFile();
      const ledger = new TerminalResultLedger(file);
      await ledger.init();

      await expect(
        ledger.record({
          ...terminalScope(),
          provider: "codex",
          threadId: "thread-invalid-turn",
          turnId,
          result: "completed",
          observedAt: "2026-08-01T00:00:02.000Z",
        }),
      ).rejects.toThrow("Terminal result turn identity is invalid");
      expect(ledger.list(terminalScope())).toEqual([]);
    },
  );

  it.each([
    ["malformed JSON", "{not-json"],
    ["an unsupported legacy version", JSON.stringify({ version: 0 })],
  ])("fails safe on %s and replaces it on the next write", async (_, raw) => {
    const { file } = await temporaryLedgerFile();
    await writeFile(file, raw, { mode: 0o600 });

    const ledger = new TerminalResultLedger(file);
    await ledger.init();
    expect(ledger.list(terminalScope())).toEqual([]);

    await ledger.record({
      ...terminalScope(),
      provider: "claude",
      threadId: "thread-recovered",
      result: "failed",
      observedAt: "2026-08-01T00:00:01.000Z",
    });
    const reloaded = new TerminalResultLedger(file);
    await reloaded.init();
    expect(reloaded.list(terminalScope())).toMatchObject([
      {
        provider: "claude",
        threadId: "thread-recovered",
        result: "failed",
      },
    ]);
  });

  it.runIf(process.platform !== "win32")(
    "tightens existing directory and file permissions before restoring IDs",
    async () => {
      const { directory, file } = await temporaryLedgerFile();
      await writeFile(
        file,
        `${JSON.stringify({
          version: 1,
          revision: 1,
          records: [
            {
              ...terminalScope(),
              provider: "codex",
              threadId: "thread-private",
              result: "completed",
              observedAt: "2026-08-01T00:00:01.000Z",
              revision: 1,
            },
          ],
        })}\n`,
      );
      await chmod(directory, 0o777);
      await chmod(file, 0o666);

      const ledger = new TerminalResultLedger(file);
      await ledger.init();

      expect(ledger.list(terminalScope())).toHaveLength(1);
      expect((await stat(directory)).mode & 0o777).toBe(0o700);
      expect((await stat(file)).mode & 0o777).toBe(0o600);
    },
  );

  it("isolates equal thread ids by Bridge, source, and provider", async () => {
    const { file } = await temporaryLedgerFile();
    const ledger = new TerminalResultLedger(file);
    await ledger.init();
    const observedAt = "2026-08-01T00:00:02.000Z";
    const records = [
      {
        bridgeInstanceId: "bridge-a",
        codexSourceId: "source-a",
        provider: "codex" as const,
        result: "completed" as const,
      },
      {
        bridgeInstanceId: "bridge-a",
        codexSourceId: "source-b",
        provider: "codex" as const,
        result: "failed" as const,
      },
      {
        bridgeInstanceId: "bridge-b",
        codexSourceId: "source-a",
        provider: "codex" as const,
        result: "failed" as const,
      },
      {
        bridgeInstanceId: "bridge-a",
        codexSourceId: "source-a",
        provider: "claude" as const,
        result: "failed" as const,
      },
    ];
    for (const record of records) {
      await ledger.record({
        ...record,
        threadId: "same-thread",
        observedAt,
      });
    }

    expect(
      ledger
        .list({ bridgeInstanceId: "bridge-a", codexSourceId: "source-a" })
        .map(({ provider, result }) => ({ provider, result }))
        .sort((left, right) => left.provider.localeCompare(right.provider)),
    ).toEqual([
      { provider: "claude", result: "failed" },
      { provider: "codex", result: "completed" },
    ]);
    expect(
      ledger.list({ bridgeInstanceId: "bridge-a", codexSourceId: "source-b" }),
    ).toMatchObject([{ provider: "codex", result: "failed" }]);
    expect(
      ledger.list({ bridgeInstanceId: "bridge-b", codexSourceId: "source-a" }),
    ).toMatchObject([{ provider: "codex", result: "failed" }]);
  });

  it("keeps only the newest bounded results", async () => {
    const { file } = await temporaryLedgerFile();
    const ledger = new TerminalResultLedger(file, 2);
    await ledger.init();
    for (let index = 0; index < 3; index += 1) {
      await ledger.record({
        ...terminalScope(),
        provider: "codex",
        threadId: `thread-${index}`,
        result: "completed",
        observedAt: `2026-08-01T00:00:0${index}.000Z`,
      });
    }

    expect(
      ledger.list(terminalScope()).map((record) => record.threadId),
    ).toEqual(["thread-2", "thread-1"]);
    const reloaded = new TerminalResultLedger(file, 2);
    await reloaded.init();
    expect(
      reloaded.list(terminalScope()).map((record) => record.threadId),
    ).toEqual(["thread-2", "thread-1"]);
  });

  it("does not let an older clear remove a newer result", async () => {
    const { file } = await temporaryLedgerFile();
    const ledger = new TerminalResultLedger(file);
    await ledger.init();
    await ledger.record({
      ...terminalScope(),
      provider: "codex",
      threadId: "thread-stale-clear",
      result: "completed",
      observedAt: "2026-08-01T00:00:05.000Z",
    });

    await expect(
      ledger.clear(
        terminalScope(),
        "codex",
        "thread-stale-clear",
        "2026-08-01T00:00:04.000Z",
      ),
    ).resolves.toBe(false);
    expect(ledger.list(terminalScope())).toHaveLength(1);
  });

  it("clears only the exact terminal turn when one is supplied", async () => {
    const { file } = await temporaryLedgerFile();
    const scope = terminalScope();
    const ledger = new TerminalResultLedger(file);
    await ledger.init();
    await ledger.record({
      ...scope,
      provider: "codex",
      threadId: "thread-exact-clear",
      turnId: "turn-current",
      result: "completed",
      observedAt: "2026-08-01T00:00:05.000Z",
    });

    await expect(
      ledger.clear(
        scope,
        "codex",
        "thread-exact-clear",
        "2026-08-01T00:00:06.000Z",
        "turn-old",
      ),
    ).resolves.toBe(false);
    expect(ledger.list(scope)).toMatchObject([{ turnId: "turn-current" }]);

    await expect(
      ledger.clear(
        scope,
        "codex",
        "thread-exact-clear",
        "2026-08-01T00:00:06.000Z",
        "turn-current",
      ),
    ).resolves.toBe(true);
    expect(ledger.list(scope)).toEqual([]);
  });

  it("commits memory after rename even when post-publication hardening fails", async () => {
    const { file } = await temporaryLedgerFile();
    const ledger = new FailOnceAfterPublishLedger(file);
    await ledger.init();

    await expect(
      ledger.record({
        ...terminalScope(),
        provider: "codex",
        threadId: "thread-published-before-error",
        result: "completed",
        observedAt: "2026-08-01T00:00:06.000Z",
      }),
    ).rejects.toThrow("injected post-publication failure");
    expect(ledger.health).toMatchObject({
      initialized: true,
      ready: false,
      degraded: true,
      lastError: "Error",
    });
    expect(ledger.health.lastFailureAt).toEqual(expect.any(String));

    expect(ledger.list(terminalScope())).toMatchObject([
      { threadId: "thread-published-before-error", result: "completed" },
    ]);
    expect(JSON.parse(await readFile(file, "utf8"))).toMatchObject({
      revision: 1,
      records: [{ threadId: "thread-published-before-error" }],
    });

    await ledger.record({
      ...terminalScope(),
      provider: "codex",
      threadId: "thread-after-hardening-error",
      result: "failed",
      observedAt: "2026-08-01T00:00:07.000Z",
    });
    expect(ledger.health).toEqual({
      initialized: true,
      ready: true,
      degraded: false,
    });

    const reloaded = new TerminalResultLedger(file);
    await reloaded.init();
    expect(
      reloaded
        .list(terminalScope())
        .map(({ threadId, result }) => ({ threadId, result })),
    ).toEqual([
      { threadId: "thread-after-hardening-error", result: "failed" },
      { threadId: "thread-published-before-error", result: "completed" },
    ]);
  });
});

class FailOnceAfterPublishLedger extends TerminalResultLedger {
  private shouldFail = true;

  protected override async hardenPublishedStore(
    directory: string,
  ): Promise<void> {
    if (this.shouldFail) {
      this.shouldFail = false;
      throw new Error("injected post-publication failure");
    }
    await super.hardenPublishedStore(directory);
  }
}

async function temporaryLedgerFile(): Promise<{
  directory: string;
  file: string;
}> {
  const directory = await mkdtemp(join(tmpdir(), "ccpocket-terminal-ledger-"));
  temporaryDirectories.push(directory);
  return { directory, file: join(directory, "terminal-results.json") };
}

function terminalScope(): TerminalResultScope {
  return { bridgeInstanceId: "bridge-a", codexSourceId: "source-a" };
}
