import { LocalFeaturesController } from "./controller.js";
import type { LocalFeatureRuntime } from "./runtime.js";
import { readCodexAppServerMode } from "../codex-app-server-config.js";
import { createAutoApprovalHandlers } from "./slots/auto-approval.js";
import { createCodexActionBrokerHandlers } from "./slots/codex-action-broker.js";
import { createCodexCoreActionsHandlers } from "./slots/codex-core-actions.js";
import { createCodexDesktopContinuityHandlers } from "./slots/codex-desktop-continuity.js";
import { createConversationMirrorHandlers } from "./slots/conversation-mirror.js";
import { createConversationContentHandlers } from "./slots/conversation-content.js";
import { createConversationSyncV2Handlers } from "./slots/conversation-sync-v2.js";
import { createFileBrowserHandlers } from "./slots/file-browser.js";
import { createSessionInsightsHandlers } from "./slots/session-insights.js";
import { createSideChatHandlers } from "./slots/side-chat.js";
import { createSubagentsHandlers } from "./slots/subagents.js";

/**
 * The only concrete feature registry. Every slot exists in the foundation as
 * a disabled stub. A feature commit activates only its own slot, so reverting
 * that commit restores the stub without touching this composition root.
 */
export function createLocalFeaturesController(
  runtime: LocalFeatureRuntime,
  env: NodeJS.ProcessEnv = process.env,
): LocalFeaturesController {
  const appServerMode = readCodexAppServerMode(env);
  const desktopContinuityHandlers =
    appServerMode === "daemon"
      ? []
      : createCodexDesktopContinuityHandlers(runtime);
  return new LocalFeaturesController(runtime, [
    ...createCodexActionBrokerHandlers(runtime),
    ...createAutoApprovalHandlers(runtime, {
      topology: appServerMode === "daemon" ? "shared" : "private_legacy",
    }),
    ...createCodexCoreActionsHandlers(runtime),
    ...desktopContinuityHandlers,
    ...createConversationMirrorHandlers(runtime),
    ...createConversationContentHandlers(runtime),
    ...createConversationSyncV2Handlers(runtime),
    ...createFileBrowserHandlers(runtime),
    ...createSessionInsightsHandlers(runtime),
    ...createSubagentsHandlers(runtime),
    ...createSideChatHandlers(runtime),
  ]);
}
