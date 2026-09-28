import { EventEmitter } from "node:events";
import { describe, expect, it, vi } from "vitest";
import { ConversationWireFaults } from "../scripts/conversation-wire-faults.mjs";

class ReceiverSocket extends EventEmitter {
  readyState = 1;
  sent: string[] = [];
  send(data: string, callback?: () => void) {
    this.sent.push(data);
    callback?.();
  }
  terminate() { this.readyState = 3; this.emit("close"); }
  ack(subscriptionId: string, sequence: number) {
    this.emit("message", JSON.stringify({ type: "conversation_sync_ack", subscriptionId, sequence }));
  }
}

const frame = (sequence: number, event = "timeline_page", subscriptionId = "first") =>
  JSON.stringify({ type: "conversation_sync_v2", subscriptionId, sequence, event, content: "正文\n" });

function fixture() {
  const observed: string[] = [];
  const wire = new ConversationWireFaults((raw: string) => observed.push(raw));
  const socket = new ReceiverSocket();
  wire.attach(socket);
  return { wire, socket, observed };
}

describe("real Bridge wire fault fixture", () => {
  it("replays only committed subscription bytes and waits for every duplicate ACK", async () => {
    const { wire, socket } = fixture();
    const original = [frame(1, "sync_begin"), frame(2), frame(3, "sync_complete")];
    original.forEach((raw) => socket.send(raw));
    socket.send(frame(4));
    socket.send(frame(1, "timeline_page", "other"));
    const checkpoint = wire.checkpoint("old", { subscriptionId: "first", sequence: 3 });
    expect(checkpoint.count).toBe(3);
    let complete = false;
    const replay = wire.replay("old", { reverse: true, repeats: 2, ackSequence: 4 })
      .then((result: unknown) => { complete = true; return result; });
    expect(socket.sent.slice(-6)).toEqual([...original].reverse().concat([...original].reverse()));
    socket.ack("other", 99);
    socket.ack("first", 3);
    for (let i = 0; i < 5; i++) socket.ack("first", 4);
    await Promise.resolve();
    expect(complete).toBe(false);
    socket.ack("first", 4);
    expect(await replay).toMatchObject({ count: 6, acknowledged: 6 });
    expect(wire.trace.filter((entry: { action: string }) => entry.action === "replay")).toHaveLength(6);
  });

  it("drains all emitted frames before using a checkpoint as a replay barrier", async () => {
    const { wire, socket } = fixture();
    socket.send(frame(2));
    socket.send(frame(3, "sync_complete"));
    socket.ack("first", 2);
    let complete = false;
    const barrier = wire.barrier({ subscriptionId: "first", sequence: 2 })
      .then((result: unknown) => { complete = true; return result; });
    await Promise.resolve();
    expect(complete).toBe(false);
    socket.ack("first", 3);
    expect(await barrier).toMatchObject({ sequence: 3 });
  });

  it("does not credit ordinary concurrent traffic toward replay ACKs", async () => {
    const { wire, socket } = fixture();
    socket.send(frame(1));
    socket.ack("first", 1);
    wire.checkpoint("old", { subscriptionId: "first", sequence: 1 });
    const replay = wire.replay("old", { ackSequence: 1 });
    socket.send(frame(2));
    socket.ack("first", 2);
    let complete = false;
    void replay.then(() => { complete = true; });
    await Promise.resolve();
    expect(complete).toBe(false);
    socket.ack("first", 1);
    expect(await replay).toMatchObject({ count: 1, acknowledged: 1 });
  });

  it("reorders two original frames exactly once while preserving callbacks", async () => {
    const { wire, socket, observed } = fixture();
    const callback = vi.fn();
    wire.arm("reorder");
    socket.send(frame(1, "sync_begin"));
    socket.send(frame(2), callback);
    expect(socket.sent).toEqual([frame(1, "sync_begin")]);
    socket.send(frame(3, "sync_checkpoint"), callback);
    socket.send(frame(4, "sync_complete"));
    await Promise.resolve();
    expect(socket.sent).toEqual([frame(1, "sync_begin"), frame(3, "sync_checkpoint"), frame(2), frame(4, "sync_complete")]);
    expect(observed).toHaveLength(4);
    expect(callback).toHaveBeenCalledTimes(2);
    expect(wire.pendingFault).toBeNull();
    const [hold, , release] = wire.trace.filter((entry: { sha256?: string }) => entry.sha256);
    expect(hold.sha256).toBe(release.sha256);
  });

  it("drops one non-begin frame and resumes ordinary delivery", async () => {
    const { wire, socket } = fixture();
    const callback = vi.fn();
    wire.arm("drop");
    socket.send(frame(1, "sync_begin"));
    socket.send(frame(2), callback);
    socket.send(frame(3, "sync_complete"));
    await Promise.resolve();
    expect(socket.sent).toEqual([frame(1, "sync_begin"), frame(3, "sync_complete")]);
    expect(callback).toHaveBeenCalledOnce();
    expect(wire.trace.filter((entry: { action: string }) => entry.action === "drop")).toHaveLength(1);
  });

  it("rejects an unfinished ACK barrier when the actual socket closes", async () => {
    const { wire, socket } = fixture();
    socket.send(frame(1));
    const barrier = wire.barrier({ subscriptionId: "first", sequence: 1 });
    const rejected = expect(barrier).rejects.toThrow("Socket closed before ACK barrier");
    wire.disconnect();
    await rejected;
    expect(socket.readyState).toBe(3);
  });

  it("replays original old-subscription bytes on a genuinely new socket", async () => {
    const { wire, socket } = fixture();
    const raw = frame(1);
    socket.send(raw);
    wire.checkpoint("old", { subscriptionId: "first", sequence: 1 });
    wire.disconnect();
    const second = new ReceiverSocket();
    wire.attach(second);
    expect(await wire.replay("old")).toMatchObject({ connection: 2, count: 1 });
    expect(second.sent).toEqual([raw]);
  });

  it("refuses checkpoints without an actual timeline payload and unbounded replay", async () => {
    const { wire, socket } = fixture();
    socket.send(frame(1, "sync_begin"));
    expect(() => wire.checkpoint("empty", { subscriptionId: "first", sequence: 1 }))
      .toThrow("no actual timeline");
    await expect(wire.replay("missing", { repeats: 100 })).rejects.toThrow("Invalid bounded");
    wire.arm("drop");
    expect(() => wire.arm("reorder")).toThrow("overlapping");
  });
});
