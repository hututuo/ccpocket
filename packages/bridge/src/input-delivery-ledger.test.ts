import {
  mkdtemp,
  readFile,
  readdir,
  rm,
  stat,
  symlink,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import {
  InputDeliveryLedger,
  InputDeliveryLedgerError,
  MAX_DURABLE_QUEUED_INPUTS_PER_THREAD,
  inputDeliveryLedgerFileForPort,
  type DurableInputPayload,
  type InputDeliveryIdentity,
  type InputDeliveryScope,
} from "./input-delivery-ledger.js";

const temporaryDirectories: string[] = [];

afterEach(async () => {
  await Promise.all(
    temporaryDirectories
      .splice(0)
      .map((directory) => rm(directory, { recursive: true, force: true })),
  );
});

describe("InputDeliveryLedger", () => {
  it("uses a distinct store for non-default Bridge ports", () => {
    expect(inputDeliveryLedgerFileForPort(8765)).toContain(
      "input-delivery-v1.json",
    );
    expect(inputDeliveryLedgerFileForPort(18765)).toContain(
      "input-delivery-v1-18765.json",
    );
    expect(
      inputDeliveryLedgerFileForPort(18765, "/tmp/custom-input.json"),
    ).toBe("/tmp/custom-input.json");
  });

  it("restores an exact queued payload after Bridge admission and restart", async () => {
    const { file } = await temporaryLedgerFile();
    const identity = inputIdentity("queued-restart");
    const payload = inputPayload("queued exact", "queued-item");
    const first = await readyLedger(file);

    await first.admit({ identity, acceptedSeq: 12, queued: true, payload });
    await first.flush();

    const second = await readyLedger(file);
    expect(
      second.recoveryPlan(inputScope(), identity.providerThreadId),
    ).toEqual({
      records: [
        expect.objectContaining({
          ...identity,
          state: "queued",
          queued: true,
          replaySafety: "queue_exact",
        }),
      ],
      replay: [
        {
          record: expect.objectContaining({
            clientMessageId: "queued-restart",
          }),
          payload,
          requireClientUserMessageId: false,
        },
      ],
      outcomeUnknown: [],
    });
  });

  it("persists a bounded FIFO of multiple next-turn inputs per thread", async () => {
    const { file } = await temporaryLedgerFile();
    const ledger = await readyLedger(file, { maxQueuedInputsPerThread: 3 });
    for (var index = 1; index <= 3; index++) {
      await ledger.admit({
        identity: inputIdentity(`queued-${index}`),
        acceptedSeq: index,
        queued: true,
        payload: inputPayload(`queued text ${index}`, `queued-item-${index}`),
      });
    }

    await expect(
      ledger.admit({
        identity: inputIdentity("queued-overflow"),
        acceptedSeq: 4,
        queued: true,
        payload: inputPayload("overflow", "queued-item-overflow"),
      }),
    ).rejects.toMatchObject<InputDeliveryLedgerError>({ code: "queue_full" });

    await ledger.flush();
    const restarted = await readyLedger(file, {
      maxQueuedInputsPerThread: 3,
    });
    const plan = restarted.recoveryPlan(inputScope(), "thread-a");
    expect(plan.replay.map(({ record }) => record.clientMessageId)).toEqual([
      "queued-1",
      "queued-2",
      "queued-3",
    ]);
    expect(plan.outcomeUnknown).toEqual([]);
  });

  it("never allows a configured queue capacity above the protocol limit", async () => {
    const { file } = await temporaryLedgerFile();
    const ledger = await readyLedger(file, { maxQueuedInputsPerThread: 99 });
    for (
      var index = 1;
      index <= MAX_DURABLE_QUEUED_INPUTS_PER_THREAD;
      index++
    ) {
      await ledger.admit({
        identity: inputIdentity(`bounded-${index}`),
        acceptedSeq: index,
        queued: true,
        payload: inputPayload(`bounded ${index}`, `bounded-item-${index}`),
      });
    }

    await expect(
      ledger.admit({
        identity: inputIdentity("bounded-overflow"),
        acceptedSeq: MAX_DURABLE_QUEUED_INPUTS_PER_THREAD + 1,
        queued: true,
        payload: inputPayload("overflow", "bounded-item-overflow"),
      }),
    ).rejects.toMatchObject<InputDeliveryLedgerError>({ code: "queue_full" });
  });

  it("deduplicates a retry after persistence but before the phone receives ACK", async () => {
    const { file } = await temporaryLedgerFile();
    const ledger = await readyLedger(file);
    const identity = inputIdentity("before-ack");
    const admission = {
      identity,
      acceptedSeq: 20,
      queued: false,
      payload: inputPayload("persisted before ACK"),
    };

    expect((await ledger.admit(admission)).outcome).toBe("created");
    expect((await ledger.admit(admission)).outcome).toBe("existing");
    expect(ledger.health.recordCount).toBe(1);

    const restarted = await readyLedger(file);
    const plan = restarted.recoveryPlan(
      inputScope(),
      identity.providerThreadId,
    );
    expect(plan.replay).toHaveLength(1);
    expect(plan.replay[0]).toMatchObject({
      requireClientUserMessageId: true,
      record: {
        state: "provider_dispatching",
        replaySafety: "client_message_id",
      },
    });
  });

  it("uses the provider idempotency key after ACK when support is not known to be false", async () => {
    const { file } = await temporaryLedgerFile();
    const ledger = await readyLedger(file);
    const identity = inputIdentity("after-ack-before-provider");

    await ledger.admit({
      identity,
      acceptedSeq: 21,
      queued: false,
      payload: inputPayload("ACK persisted before provider"),
    });

    const restarted = await readyLedger(file);
    expect(
      restarted.recoveryPlan(inputScope(), identity.providerThreadId).replay,
    ).toMatchObject([
      {
        requireClientUserMessageId: true,
        record: { clientMessageId: identity.clientMessageId },
      },
    ]);
  });

  it("never blindly resends an old-server write window", async () => {
    const { file } = await temporaryLedgerFile();
    const ledger = await readyLedger(file);
    const observed = inputIdentity("old-server-observation");
    await ledger.admit({
      identity: observed,
      acceptedSeq: 30,
      queued: false,
      payload: inputPayload("old server baseline"),
    });
    await ledger.recordProviderOutcome({
      identity: observed,
      stage: "provider_accepted",
      method: "turn/start",
      occurredAt: "2026-08-01T01:00:00.000Z",
      clientUserMessageIdAccepted: false,
    });

    const uncertain = inputIdentity("old-server-unknown");
    await ledger.admit({
      identity: uncertain,
      acceptedSeq: 31,
      queued: false,
      payload: inputPayload("never replay unkeyed"),
    });

    const restarted = await readyLedger(file);
    const plan = restarted.recoveryPlan(
      inputScope(),
      uncertain.providerThreadId,
    );
    expect(plan.replay).toEqual([]);
    expect(plan.outcomeUnknown).toMatchObject([
      {
        clientMessageId: "old-server-unknown",
        replaySafety: "none",
        state: "provider_dispatching",
      },
    ]);
  });

  it("persists provider acceptance before a phone receipt and never replays it", async () => {
    const { file } = await temporaryLedgerFile();
    const now = () => new Date("2026-08-01T01:01:01.000Z");
    const ledger = await readyLedger(file, { now });
    const identity = inputIdentity("accepted-before-phone-receipt");
    await ledger.admit({
      identity,
      acceptedSeq: 40,
      queued: false,
      payload: inputPayload("accepted once"),
    });
    await ledger.recordProviderOutcome({
      identity,
      stage: "provider_accepted",
      method: "turn/start",
      occurredAt: "2026-08-01T01:01:00.000Z",
      clientUserMessageIdAccepted: true,
    });

    const restarted = await readyLedger(file, { now });
    const plan = restarted.recoveryPlan(
      inputScope(),
      identity.providerThreadId,
    );
    expect(plan.replay).toEqual([]);
    expect(plan.outcomeUnknown).toEqual([]);
    expect(plan.records).toMatchObject([
      {
        state: "provider_accepted",
        clientUserMessageIdAccepted: true,
      },
    ]);
    expect(plan.records[0].payload).toBeUndefined();
  });

  it("fails closed for image recovery instead of retaining image bytes", async () => {
    const { file } = await temporaryLedgerFile();
    const ledger = await readyLedger(file);

    await expect(
      ledger.admit({
        identity: inputIdentity("queued-image"),
        acceptedSeq: 50,
        queued: true,
        payload: inputPayload("queued image"),
        containsImages: true,
      }),
    ).rejects.toMatchObject<InputDeliveryLedgerError>({
      code: "unsafe_payload",
    });

    const immediate = inputIdentity("immediate-image");
    await ledger.admit({
      identity: immediate,
      acceptedSeq: 51,
      queued: false,
      payload: inputPayload("image is held outside the ledger"),
      containsImages: true,
    });
    const raw = await readFile(file, "utf8");
    expect(raw).not.toContain("base64");

    const restarted = await readyLedger(file);
    const plan = restarted.recoveryPlan(
      inputScope(),
      immediate.providerThreadId,
    );
    expect(plan.replay).toEqual([]);
    expect(plan.outcomeUnknown).toMatchObject([
      { clientMessageId: "immediate-image", containsImages: true },
    ]);
  });

  it("isolates identical thread and client ids by Bridge and Codex source", async () => {
    const { file } = await temporaryLedgerFile();
    const ledger = await readyLedger(file);
    const sourceA = inputScope("bridge-a", "source-a");
    const sourceB = inputScope("bridge-a", "source-b");
    const sourceC = inputScope("bridge-b", "source-a");
    for (const [scope, text] of [
      [sourceA, "source A"],
      [sourceB, "source B"],
      [sourceC, "bridge B"],
    ] as const) {
      await ledger.admit({
        identity: {
          ...scope,
          providerThreadId: "same-thread",
          clientMessageId: "same-message",
        },
        acceptedSeq: 1,
        queued: false,
        payload: inputPayload(text),
      });
    }

    expect(ledger.listThread(sourceA, "same-thread")[0].payload?.text).toBe(
      "source A",
    );
    expect(ledger.listThread(sourceB, "same-thread")[0].payload?.text).toBe(
      "source B",
    );
    expect(ledger.listThread(sourceC, "same-thread")[0].payload?.text).toBe(
      "bridge B",
    );
  });

  it("persists queued edits and cancellation before changing public queue state", async () => {
    const { file } = await temporaryLedgerFile();
    const ledger = await readyLedger(file);
    const identity = inputIdentity("edit-and-cancel");
    await ledger.admit({
      identity,
      acceptedSeq: 60,
      queued: true,
      payload: inputPayload("original", "editable-item"),
    });
    const updated = inputPayload("updated", "editable-item");
    updated.updatedAt = "2026-08-01T01:03:00.000Z";
    await ledger.updateQueued(identity, updated);

    let restarted = await readyLedger(file);
    expect(restarted.get(identity)?.payload).toEqual(updated);
    await restarted.cancel(identity);

    restarted = await readyLedger(file);
    expect(restarted.get(identity)).toMatchObject({
      state: "cancelled",
      errorCode: "cancelled",
    });
    expect(restarted.get(identity)?.payload).toBeUndefined();
    expect(
      restarted.recoveryPlan(inputScope(), identity.providerThreadId).replay,
    ).toEqual([]);
  });

  it("keeps active records when record or byte capacity is exhausted", async () => {
    const { file } = await temporaryLedgerFile();
    const ledger = await readyLedger(file, { maxRecords: 1 });
    const first = inputIdentity("capacity-first", "thread-first");
    await ledger.admit({
      identity: first,
      acceptedSeq: 70,
      queued: true,
      payload: inputPayload("first active"),
    });

    await expect(
      ledger.admit({
        identity: inputIdentity("capacity-second", "thread-second"),
        acceptedSeq: 71,
        queued: false,
        payload: inputPayload("second active"),
      }),
    ).rejects.toMatchObject<InputDeliveryLedgerError>({ code: "capacity" });
    expect(ledger.get(first)).toMatchObject({ state: "queued" });

    const tiny = await readyLedger(
      join((await temporaryLedgerFile()).directory, "tiny.json"),
      {
        maxPayloadBytes: 80,
      },
    );
    await expect(
      tiny.admit({
        identity: inputIdentity("payload-too-large"),
        acceptedSeq: 72,
        queued: false,
        payload: inputPayload("x".repeat(512)),
      }),
    ).rejects.toMatchObject<InputDeliveryLedgerError>({
      code: "payload_too_large",
    });
    expect(tiny.health.recordCount).toBe(0);
  });

  it("degrades on corrupt storage and rejects later admissions", async () => {
    const { file } = await temporaryLedgerFile();
    await writeFile(file, "{not-json", { mode: 0o600 });
    const ledger = new InputDeliveryLedger({ filePath: file });

    await expect(ledger.init()).rejects.toBeInstanceOf(SyntaxError);
    expect(ledger.health).toMatchObject({
      initialized: false,
      ready: false,
      degraded: true,
      lastError: "SyntaxError",
    });
    await expect(
      ledger.admit({
        identity: inputIdentity("after-corruption"),
        acceptedSeq: 80,
        queued: false,
        payload: inputPayload("must fail closed"),
      }),
    ).rejects.toMatchObject<InputDeliveryLedgerError>({ code: "unavailable" });
  });

  it.runIf(process.platform !== "win32")(
    "rejects a symlink store without following it",
    async () => {
      const { directory, file } = await temporaryLedgerFile();
      const target = join(directory, "target.json");
      await writeFile(
        target,
        `${JSON.stringify({
          version: 1,
          revision: 0,
          records: [],
          clientIdCapabilities: [],
        })}\n`,
        { mode: 0o600 },
      );
      await symlink(target, file);
      const ledger = new InputDeliveryLedger({ filePath: file });

      await expect(ledger.init()).rejects.toBeTruthy();
      expect(ledger.health).toMatchObject({ ready: false, degraded: true });
    },
  );

  it("acknowledges the published mutation but degrades before later writes when post-publication hardening fails", async () => {
    const { file } = await temporaryLedgerFile();
    const ledger = new FailingHardenLedger({ filePath: file });
    await ledger.init();

    await expect(
      ledger.admit({
        identity: inputIdentity("disk-failure"),
        acceptedSeq: 90,
        queued: false,
        payload: inputPayload("published but not acknowledged"),
      }),
    ).resolves.toMatchObject({
      outcome: "created",
      record: { clientMessageId: "disk-failure" },
    });
    expect(ledger.health).toMatchObject({ ready: false, degraded: true });
    expect((await stat(file)).mode & 0o777).toBe(0o600);
    expect(JSON.parse(await readFile(file, "utf8"))).toMatchObject({
      records: [{ clientMessageId: "disk-failure" }],
    });
  });

  it("does not let a mutation already waiting behind a disk failure proceed", async () => {
    const { file } = await temporaryLedgerFile();
    const ledger = new FailingHardenLedger({ filePath: file });
    await ledger.init();

    const first = ledger.admit({
      identity: inputIdentity("concurrent-first", "thread-first"),
      acceptedSeq: 91,
      queued: false,
      payload: inputPayload("first"),
    });
    const second = ledger.admit({
      identity: inputIdentity("concurrent-second", "thread-second"),
      acceptedSeq: 92,
      queued: false,
      payload: inputPayload("second"),
    });
    const outcomes = await Promise.allSettled([first, second]);

    expect(outcomes[0]).toMatchObject({
      status: "fulfilled",
      value: expect.objectContaining({
        record: expect.objectContaining({
          clientMessageId: "concurrent-first",
        }),
      }),
    });
    expect(outcomes[1]).toMatchObject({
      status: "rejected",
      reason: expect.objectContaining({ code: "unavailable" }),
    });
    expect(JSON.parse(await readFile(file, "utf8"))).toMatchObject({
      records: [{ clientMessageId: "concurrent-first" }],
    });
  });

  it.runIf(process.platform !== "win32")(
    "publishes a 0600 file without temporary leftovers",
    async () => {
      const { directory, file } = await temporaryLedgerFile();
      const ledger = await readyLedger(file);
      await ledger.admit({
        identity: inputIdentity("private-file"),
        acceptedSeq: 100,
        queued: false,
        payload: inputPayload("private"),
      });

      expect((await stat(file)).mode & 0o777).toBe(0o600);
      expect(
        (await readdir(directory)).filter((name) => name.endsWith(".tmp")),
      ).toEqual([]);
    },
  );
});

class FailingHardenLedger extends InputDeliveryLedger {
  protected override async hardenPublishedStore(): Promise<void> {
    throw new Error("simulated directory fsync failure");
  }
}

function inputScope(
  bridgeInstanceId = "bridge-instance-a",
  codexSourceId = "codex-source-a",
): InputDeliveryScope {
  return { bridgeInstanceId, codexSourceId };
}

function inputIdentity(
  clientMessageId: string,
  providerThreadId = "thread-a",
  scope = inputScope(),
): InputDeliveryIdentity {
  return { ...scope, providerThreadId, clientMessageId };
}

function inputPayload(
  text: string,
  itemId = "input-item",
): DurableInputPayload {
  return {
    itemId,
    text,
    createdAt: "2026-08-01T01:00:00.000Z",
    userMessageUuid: `user-${itemId}`,
    skills: [{ name: "review", path: "/tmp/review.md" }],
    mentions: [{ name: "file", path: "/tmp/file.txt" }],
  };
}

async function readyLedger(
  file: string,
  options: {
    maxRecords?: number;
    maxStoreBytes?: number;
    maxPayloadBytes?: number;
    maxQueuedInputsPerThread?: number;
    terminalRetentionMs?: number;
    now?: () => Date;
  } = {},
): Promise<InputDeliveryLedger> {
  const ledger = new InputDeliveryLedger({ filePath: file, ...options });
  await ledger.init();
  return ledger;
}

async function temporaryLedgerFile(): Promise<{
  directory: string;
  file: string;
}> {
  const directory = await mkdtemp(join(tmpdir(), "ccpocket-input-delivery-"));
  temporaryDirectories.push(directory);
  return { directory, file: join(directory, "input-delivery.json") };
}
