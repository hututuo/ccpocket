import type { LocalFeatureClientMessage } from "./protocol.js";
import type { LocalFeatureHandler, LocalFeatureRuntime } from "./runtime.js";

/**
 * Single integration point for local, removable Bridge modules. Adding a
 * future feature only requires registering another handler here and extending
 * local protocol types; parser.ts and websocket.ts keep the same seams.
 */
export class LocalFeaturesController {
  private readonly handlers = new Map<string, LocalFeatureHandler>();
  private readonly operations = new Map<object, Set<AbortController>>();

  constructor(
    private readonly runtime: LocalFeatureRuntime,
    handlers: readonly LocalFeatureHandler[],
  ) {
    for (const handler of handlers) {
      this.register(handler);
    }
  }

  handle(client: object, message: { type: string }): Promise<void> | null {
    const handler = this.handlers.get(message.type);
    if (!handler) return null;

    return this.runHandler(
      client,
      message as LocalFeatureClientMessage,
      handler,
    );
  }

  private async runHandler(
    client: object,
    message: Parameters<LocalFeatureHandler["handle"]>[0],
    handler: LocalFeatureHandler,
  ): Promise<void> {
    const controller = new AbortController();
    const active = this.operations.get(client) ?? new Set<AbortController>();
    active.add(controller);
    this.operations.set(client, active);
    try {
      await handler.handle(message, {
        client,
        signal: controller.signal,
        runtime: this.runtime,
      });
    } finally {
      active.delete(controller);
      if (active.size === 0) this.operations.delete(client);
    }
  }

  capabilitiesChanged(client: object): void {
    for (const handler of new Set(this.handlers.values())) {
      handler.capabilitiesChanged?.(client);
    }
  }

  disconnect(client: object): void {
    const active = this.operations.get(client);
    if (active) {
      for (const controller of active) {
        controller.abort(new Error("WebSocket disconnected"));
      }
      this.operations.delete(client);
    }
    for (const handler of new Set(this.handlers.values())) {
      handler.disconnect?.(client);
    }
  }

  close(): void {
    for (const active of this.operations.values()) {
      for (const controller of active) {
        controller.abort(new Error("Bridge shutting down"));
      }
    }
    this.operations.clear();
    for (const handler of new Set(this.handlers.values())) {
      handler.close?.();
    }
  }

  private register(handler: LocalFeatureHandler): void {
    for (const messageType of handler.messageTypes) {
      if (this.handlers.has(messageType)) {
        throw new Error(`Duplicate local feature handler: ${messageType}`);
      }
      this.handlers.set(messageType, handler);
    }
  }
}
