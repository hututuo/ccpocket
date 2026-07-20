import type {
  LocalFeatureHandleContext,
  LocalFeatureHandler,
} from "./runtime.js";
import type { LocalFeatureClientMessage } from "./protocol.js";

const RESPONSE_TYPE = "persisted_side_chat_opened";

/**
 * Creates a durable official Codex child and hands it back to Mobile's normal
 * conversation screen. The legacy ephemeral side-chat handler remains intact
 * for older clients.
 */
export class PersistedSideChatFeatureHandler implements LocalFeatureHandler {
  readonly messageTypes = ["open_persisted_side_chat"] as const;

  async handle(
    message: LocalFeatureClientMessage,
    context: LocalFeatureHandleContext,
  ): Promise<void> {
    if (message.type !== "open_persisted_side_chat") return;
    if (!context.runtime.supports(context.client, RESPONSE_TYPE)) {
      this.sendFailure(
        message,
        context,
        "unsupported_capability",
        "Durable side chat was not negotiated",
      );
      return;
    }
    const create = context.runtime.createPersistedCodexChildSession;
    if (!create) {
      this.sendFailure(
        message,
        context,
        "unsupported_bridge",
        "This Bridge cannot create a durable side chat",
      );
      return;
    }

    try {
      const child = await create(message.parentSessionId, {
        threadSource: "ccpocket_side_chat",
        excludeTurnsOnOpen: true,
      });
      context.runtime.send(context.client, {
        type: RESPONSE_TYPE,
        parentSessionId: message.parentSessionId,
        requestId: message.requestId,
        childSessionId: child.sessionId,
        projectPath: child.projectPath,
        ...(child.worktreePath ? { worktreePath: child.worktreePath } : {}),
        ...(child.worktreeBranch
          ? { worktreeBranch: child.worktreeBranch }
          : {}),
        ...(child.permissionMode
          ? { permissionMode: child.permissionMode }
          : {}),
        ...(child.sandboxMode ? { sandboxMode: child.sandboxMode } : {}),
        ...(child.approvalPolicy
          ? { approvalPolicy: child.approvalPolicy }
          : {}),
        ...(child.approvalsReviewer
          ? { approvalsReviewer: child.approvalsReviewer }
          : {}),
      });
    } catch (error) {
      this.sendFailure(
        message,
        context,
        "create_failed",
        error instanceof Error ? error.message : String(error),
      );
    }
  }

  private sendFailure(
    message: Extract<
      LocalFeatureClientMessage,
      { type: "open_persisted_side_chat" }
    >,
    context: LocalFeatureHandleContext,
    errorCode: string,
    error: string,
  ): void {
    context.runtime.send(context.client, {
      type: RESPONSE_TYPE,
      parentSessionId: message.parentSessionId,
      requestId: message.requestId,
      error,
      errorCode,
    });
  }
}
