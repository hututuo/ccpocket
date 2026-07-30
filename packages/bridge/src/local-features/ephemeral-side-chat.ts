import type {
  EphemeralSideChatClientMessage,
  EphemeralSideChatEntry,
} from "./slots/ephemeral-side-chat-protocol.js";
import type {
  LocalFeatureHandleContext,
  LocalFeatureHandler,
} from "./runtime.js";
import type { LocalFeatureClientMessage } from "./protocol.js";

const OPENED_RESPONSE = "ephemeral_side_chat_opened";
const REGISTRY_RESPONSE = "ephemeral_side_chat_registry";

/**
 * Adapts CC Pocket's existing conversation surface to Codex app-server's
 * official in-memory `thread/fork { ephemeral: true }` contract.
 *
 * The Bridge owns only the live runtime registry. No child transcript, TTL, or
 * synthetic expiration is persisted by this feature.
 */
export class EphemeralSideChatFeatureHandler implements LocalFeatureHandler {
  readonly messageTypes = [
    "open_ephemeral_side_chat",
    "list_ephemeral_side_chats",
    "close_ephemeral_side_chat",
  ] as const;

  async handle(
    message: LocalFeatureClientMessage,
    context: LocalFeatureHandleContext,
  ): Promise<void> {
    if (!isEphemeralSideChatMessage(message)) return;

    switch (message.type) {
      case "open_ephemeral_side_chat":
        await this.open(message, context);
        return;
      case "list_ephemeral_side_chats":
        this.list(message, context);
        return;
      case "close_ephemeral_side_chat":
        this.closeChild(message, context);
        return;
    }
  }

  private async open(
    message: Extract<
      EphemeralSideChatClientMessage,
      { type: "open_ephemeral_side_chat" }
    >,
    context: LocalFeatureHandleContext,
  ): Promise<void> {
    if (!context.runtime.supports(context.client, OPENED_RESPONSE)) {
      this.sendOpenFailure(
        message,
        context,
        "unsupported_capability",
        "Ephemeral side chat was not negotiated",
      );
      return;
    }
    const create = context.runtime.createEphemeralCodexChildSession;
    if (!create) {
      this.sendOpenFailure(
        message,
        context,
        "unsupported_bridge",
        "This Bridge cannot create an ephemeral side chat",
      );
      return;
    }

    try {
      const entry = await create(message.parentSessionId, {
        threadSource: "ccpocket_side_chat",
        excludeTurnsOnOpen: true,
        ...(message.parentProviderSessionId
          ? { parentProviderSessionId: message.parentProviderSessionId }
          : {}),
      });
      if (context.signal.aborted) return;
      context.runtime.send(context.client, {
        type: OPENED_RESPONSE,
        parentSessionId: message.parentSessionId,
        requestId: message.requestId,
        entry,
      });
    } catch (error) {
      if (context.signal.aborted) return;
      this.sendOpenFailure(
        message,
        context,
        "create_failed",
        errorMessage(error),
      );
    }
  }

  private list(
    message: Extract<
      EphemeralSideChatClientMessage,
      { type: "list_ephemeral_side_chats" }
    >,
    context: LocalFeatureHandleContext,
  ): void {
    if (!context.runtime.supports(context.client, REGISTRY_RESPONSE)) {
      this.sendRegistryFailure(
        message.requestId,
        context,
        "unsupported_capability",
        "Ephemeral side chat registry was not negotiated",
      );
      return;
    }
    const list = context.runtime.listEphemeralCodexChildSessions;
    if (!list) {
      this.sendRegistryFailure(
        message.requestId,
        context,
        "unsupported_bridge",
        "This Bridge cannot list ephemeral side chats",
      );
      return;
    }
    context.runtime.send(context.client, {
      type: REGISTRY_RESPONSE,
      requestId: message.requestId,
      entries: list(),
    });
  }

  private closeChild(
    message: Extract<
      EphemeralSideChatClientMessage,
      { type: "close_ephemeral_side_chat" }
    >,
    context: LocalFeatureHandleContext,
  ): void {
    if (!context.runtime.supports(context.client, REGISTRY_RESPONSE)) {
      this.sendRegistryFailure(
        message.requestId,
        context,
        "unsupported_capability",
        "Ephemeral side chat registry was not negotiated",
      );
      return;
    }
    const close = context.runtime.closeEphemeralCodexChildSession;
    const list = context.runtime.listEphemeralCodexChildSessions;
    if (!close || !list) {
      this.sendRegistryFailure(
        message.requestId,
        context,
        "unsupported_bridge",
        "This Bridge cannot close ephemeral side chats",
      );
      return;
    }
    if (!close(message.childSessionId)) {
      this.sendRegistryFailure(
        message.requestId,
        context,
        "side_chat_not_found",
        "The ephemeral side chat is no longer active",
      );
      return;
    }
    context.runtime.send(context.client, {
      type: REGISTRY_RESPONSE,
      requestId: message.requestId,
      entries: list(),
    });
  }

  private sendOpenFailure(
    message: Extract<
      EphemeralSideChatClientMessage,
      { type: "open_ephemeral_side_chat" }
    >,
    context: LocalFeatureHandleContext,
    errorCode: string,
    error: string,
  ): void {
    context.runtime.send(context.client, {
      type: OPENED_RESPONSE,
      parentSessionId: message.parentSessionId,
      requestId: message.requestId,
      errorCode,
      error,
    });
  }

  private sendRegistryFailure(
    requestId: string,
    context: LocalFeatureHandleContext,
    errorCode: string,
    error: string,
  ): void {
    context.runtime.send(context.client, {
      type: REGISTRY_RESPONSE,
      requestId,
      errorCode,
      error,
    });
  }
}

function isEphemeralSideChatMessage(
  message: LocalFeatureClientMessage,
): message is EphemeralSideChatClientMessage {
  return (
    message.type === "open_ephemeral_side_chat" ||
    message.type === "list_ephemeral_side_chats" ||
    message.type === "close_ephemeral_side_chat"
  );
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
