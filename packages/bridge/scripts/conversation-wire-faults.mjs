import { EventEmitter } from "node:events";
import { createHash } from "node:crypto";

// Test-only wire faults around the real Bridge. Replays preserve every byte;
// this fixture never fabricates revisions, subscription IDs or server events.
export class ConversationWireFaults {
  constructor(onFrame) {
    this.onFrame = onFrame;
    this.connections = [];
    this.checkpoints = new Map();
    this.trace = [];
    this.pendingFault = null;
  }

  attach(socket) {
    const connection = {
      id: this.connections.length + 1,
      socket,
      send: socket.send.bind(socket),
      frames: [],
      emissionCount: 0,
      acks: new Map(),
      events: new EventEmitter(),
    };
    this.connections.push(connection);
    socket.on("message", (data) => {
      let message;
      try { message = JSON.parse(data.toString()); } catch { return; }
      if (message.type !== "conversation_sync_ack") return;
      connection.acks.set(message.subscriptionId, Math.max(
        connection.acks.get(message.subscriptionId) ?? 0, message.sequence,
      ));
      connection.events.emit("ack", message);
    });
    socket.on("close", () => connection.events.emit("closed"));
    socket.send = (data, ...args) => {
      const raw = data.toString();
      this.onFrame(raw);
      let frame;
      try { frame = JSON.parse(raw); } catch {
        return connection.send(data, ...args);
      }
      if (frame.type === "conversation_sync_v2") {
        connection.emissionCount += 1;
        connection.frames.push({ raw, frame });
        if (connection.frames.length > 512) connection.frames.shift();
        const fault = this.pendingFault;
        if (fault?.connection === connection && frame.event !== "sync_begin") {
          if (fault.kind === "drop") {
            this.pendingFault = null;
            this.record("drop", connection, frame, raw);
          } else if (!fault.held) {
            fault.held = { raw, frame };
            this.record("hold", connection, frame, raw);
          } else {
            this.pendingFault = null;
            this.record("overtake", connection, frame, raw);
            connection.send(data, ...args);
            this.record("release-late", connection, fault.held.frame, fault.held.raw);
            return connection.send(fault.held.raw);
          }
          const callback = args.find((value) => typeof value === "function");
          if (callback) queueMicrotask(() => callback());
          return;
        }
      }
      return connection.send(data, ...args);
    };
  }

  record(action, connection, frame = {}, raw) {
    this.trace.push({
      action, connection: connection.id, event: frame.event,
      subscriptionId: frame.subscriptionId, sequence: frame.sequence,
      ...(raw == null ? {} : { sha256: createHash("sha256").update(raw).digest("hex") }),
    });
  }

  current() {
    const connection = this.connections.findLast((entry) => entry.socket.readyState === 1);
    if (!connection) throw new Error("No open fixture receiver socket");
    return connection;
  }

  checkpoint(name, { subscriptionId, sequence }) {
    if (this.checkpoints.size >= 8 && !this.checkpoints.has(name)) {
      throw new Error("Too many wire checkpoints");
    }
    const connection = this.current();
    const frames = connection.frames.filter(({ frame }) =>
      frame.subscriptionId === subscriptionId && frame.sequence <= sequence,
    ).slice(-128);
    if (!frames.some(({ frame }) => frame.event === "timeline_page")) {
      throw new Error("Checkpoint has no actual timeline payload");
    }
    this.checkpoints.set(name, frames);
    return { connection: connection.id, count: frames.length, subscriptions: [...new Set(frames.map(({ frame }) => frame.subscriptionId))] };
  }

  waitForAcks(connection, subscriptionId, sequence, count = 1, timeoutMs = 8000) {
    return new Promise((resolve, reject) => {
      let observed = 0;
      const cleanup = () => {
        clearTimeout(timer);
        connection.events.off("ack", onAck);
        connection.events.off("closed", onClose);
      };
      const onAck = (message) => {
        if (message.subscriptionId !== subscriptionId || message.sequence < sequence) return;
        if (++observed < count) return;
        cleanup();
        resolve({ acknowledged: observed, sequence: message.sequence });
      };
      const onClose = () => { cleanup(); reject(new Error("Socket closed before ACK barrier")); };
      const timer = setTimeout(() => {
        cleanup();
        reject(new Error(`ACK barrier timed out: ${observed}/${count}, sequence=${sequence}`));
      }, timeoutMs);
      connection.events.on("ack", onAck);
      connection.events.on("closed", onClose);
    });
  }

  async barrier({ subscriptionId, sequence }) {
    const connection = this.current();
    // Include every frame already emitted for this subscription, not just the
    // last timeline page, so outstanding ordinary ACKs cannot satisfy a replay.
    sequence = Math.max(sequence, ...connection.frames.filter(
      ({ frame }) => frame.subscriptionId === subscriptionId,
    ).map(({ frame }) => frame.sequence));
    if ((connection.acks.get(subscriptionId) ?? 0) < sequence) {
      await this.waitForAcks(connection, subscriptionId, sequence);
    }
    return { subscriptionId, sequence, connection: connection.id };
  }

  async replay(name, { reverse = false, repeats = 1, ackSequence } = {}) {
    const saved = this.checkpoints.get(name);
    if (!saved || !Number.isInteger(repeats) || repeats < 1 || repeats > 2) {
      throw new Error("Invalid bounded wire replay");
    }
    const connection = this.current();
    const frames = reverse ? [...saved].reverse() : saved;
    const originalEmissionCount = connection.emissionCount;
    const acknowledgement = ackSequence == null ? null : this.waitForAcks(
      connection, frames[0].frame.subscriptionId, ackSequence, frames.length * repeats,
    );
    for (let i = 0; i < repeats; i += 1) {
      for (const { raw, frame } of frames) {
        connection.send(raw);
        this.record("replay", connection, frame, raw);
      }
    }
    const acknowledged = acknowledgement == null ? {} : await acknowledgement;
    if (acknowledgement != null && connection.emissionCount !== originalEmissionCount) {
      throw new Error("Ordinary emissions overlapped the replay ACK barrier");
    }
    return { connection: connection.id, count: frames.length * repeats, ...acknowledged };
  }

  arm(kind) {
    if (!["drop", "reorder"].includes(kind) || this.pendingFault) {
      throw new Error("Invalid or overlapping wire fault");
    }
    const connection = this.current();
    this.pendingFault = { kind, connection };
    this.record(`arm-${kind}`, connection);
    return { connection: connection.id, kind };
  }

  disconnect() {
    const connection = this.current();
    this.record("disconnect", connection);
    connection.socket.terminate();
    return { connection: connection.id };
  }
}
