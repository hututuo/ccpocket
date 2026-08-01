import type { LocalFeatureClientMessage } from "./protocol.js";
import type { ServerMessage } from "../parser.js";
import type { SessionCatalogChange } from "../session-catalog-monitor.js";
import type {
  LocalFeatureHandler,
  LocalFeatureClientDeliveryMode,
  LocalFeatureInputAdmission,
  LocalFeatureInputMessage,
  LocalFeatureRuntime,
  LocalFeatureSession,
  LocalFeatureConversationActivity,
} from "./runtime.js";

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

  admitInput(
    client: object,
    session: LocalFeatureSession,
    message: LocalFeatureInputMessage,
  ): LocalFeatureInputAdmission | Promise<LocalFeatureInputAdmission> {
    const handlers = [...new Set(this.handlers.values())];
    const next = (
      index: number,
    ): LocalFeatureInputAdmission | Promise<LocalFeatureInputAdmission> => {
      for (let cursor = index; cursor < handlers.length; cursor += 1) {
        const result = handlers[cursor].admitInput?.(client, session, message);
        if (result instanceof Promise) {
          return result.then((admission) =>
            admission && admission.action !== "allow"
              ? admission
              : next(cursor + 1),
          );
        }
        if (result && result.action !== "allow") return result;
      }
      return { action: "allow" };
    };
    return next(0);
  }

  inputAccepted(
    client: object,
    session: LocalFeatureSession,
    message: LocalFeatureInputMessage,
    queued: boolean,
  ): void {
    for (const handler of new Set(this.handlers.values())) {
      handler.inputAccepted?.(client, session, message, queued);
    }
  }

  admitCodexQueuedInputDrain(session: LocalFeatureSession): boolean {
    for (const handler of new Set(this.handlers.values())) {
      if (handler.admitCodexQueuedInputDrain?.(session) === false) return false;
    }
    return true;
  }

  codexQueuedInputDrainBlocked(session: LocalFeatureSession): void {
    for (const handler of new Set(this.handlers.values())) {
      handler.codexQueuedInputDrainBlocked?.(session);
    }
  }

  externalCodexTurnId(session: LocalFeatureSession): string | undefined {
    for (const handler of new Set(this.handlers.values())) {
      const turnId = handler.externalCodexTurnId?.(session);
      if (turnId) return turnId;
    }
    return undefined;
  }

  hasExternalCodexActivity(session: LocalFeatureSession): boolean {
    for (const handler of new Set(this.handlers.values())) {
      if (handler.hasExternalCodexActivity?.(session) === true) return true;
    }
    return false;
  }

  /**
   * Union the content-free active/attention targets exposed by feature
   * handlers. The host combines these durable identities with transient
   * SessionManager work, preventing a Desktop-owned turn from disappearing
   * merely because Bridge has not formally attached it.
   */
  backgroundActiveConversationKeys(): Set<string> {
    const keys = new Set<string>();
    for (const handler of new Set(this.handlers.values())) {
      for (const key of handler.backgroundActiveConversationKeys?.() ?? []) {
        if (key) keys.add(key);
      }
    }
    return keys;
  }

  conversationActivity(
    provider: string,
    providerSessionId: string,
  ): LocalFeatureConversationActivity {
    let observedInactive = false;
    for (const handler of new Set(this.handlers.values())) {
      const activity = handler.conversationActivity?.(
        provider,
        providerSessionId,
      );
      if (activity === "active") return "active";
      if (activity === "unknown") return "unknown";
      if (activity === "inactive") observedInactive = true;
    }
    return observedInactive ? "inactive" : "unknown";
  }

  async hasExternalCodexActivityVerified(
    session: LocalFeatureSession,
  ): Promise<boolean> {
    for (const handler of new Set(this.handlers.values())) {
      try {
        if (handler.hasExternalCodexActivityVerified) {
          if (await handler.hasExternalCodexActivityVerified(session)) {
            return true;
          }
        } else if (handler.hasExternalCodexActivity?.(session) === true) {
          return true;
        }
      } catch {
        // A settings write must not proceed when the ownership check itself
        // failed. Ordinary input admission retains its separate compatibility
        // fallback, but model/speed mutation is intentionally fail-closed.
        return true;
      }
    }
    return false;
  }

  // These fan-outs run synchronously from timer callbacks (e.g. the catalog
  // monitor's debounce), where a handler throw would surface as an
  // uncaughtException. Isolate handlers so one failure cannot crash the
  // process or starve the remaining handlers.
  runtimeSessionChanged(session: LocalFeatureSession): void {
    for (const handler of new Set(this.handlers.values())) {
      try {
        handler.runtimeSessionChanged?.(session);
      } catch (err) {
        console.error(
          "[local-features] runtimeSessionChanged handler failed:",
          err,
        );
      }
    }
  }

  sessionMessage(session: LocalFeatureSession, message: ServerMessage): void {
    for (const handler of new Set(this.handlers.values())) {
      try {
        handler.sessionMessage?.(session, message);
      } catch (err) {
        console.error("[local-features] sessionMessage handler failed:", err);
      }
    }
  }

  sessionCatalogChanged(change: SessionCatalogChange): void {
    for (const handler of new Set(this.handlers.values())) {
      try {
        handler.sessionCatalogChanged?.(change);
      } catch (err) {
        console.error(
          "[local-features] sessionCatalogChanged handler failed:",
          err,
        );
      }
    }
  }

  clientDeliveryModeChanged(
    client: object,
    mode: LocalFeatureClientDeliveryMode,
  ): void {
    for (const handler of new Set(this.handlers.values())) {
      try {
        handler.clientDeliveryModeChanged?.(client, mode);
      } catch (err) {
        console.error(
          "[local-features] clientDeliveryModeChanged handler failed:",
          err,
        );
      }
    }
  }

  backgroundNotificationDemandChanged(): void {
    for (const handler of new Set(this.handlers.values())) {
      try {
        handler.backgroundNotificationDemandChanged?.();
      } catch (err) {
        console.error(
          "[local-features] backgroundNotificationDemandChanged handler failed:",
          err,
        );
      }
    }
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
      if (active.size === 0 && this.operations.get(client) === active) {
        this.operations.delete(client);
      }
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

  async close(): Promise<void> {
    for (const active of this.operations.values()) {
      for (const controller of active) {
        controller.abort(new Error("Bridge shutting down"));
      }
    }
    this.operations.clear();
    await Promise.allSettled(
      [...new Set(this.handlers.values())].map(async (handler) => {
        await handler.close?.();
      }),
    );
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
