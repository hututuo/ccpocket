import { LocalFeaturesController } from "./controller.js";
import type { LocalFeatureRuntime } from "./runtime.js";
import { createAutoApprovalHandlers } from "./slots/auto-approval.js";
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
): LocalFeaturesController {
  return new LocalFeaturesController(runtime, [
    ...createAutoApprovalHandlers(runtime),
    ...createCodexCoreActionsHandlers(runtime),
    ...createCodexDesktopContinuityHandlers(runtime),
    ...createConversationMirrorHandlers(runtime),
    ...createConversationContentHandlers(runtime),
    ...createConversationSyncV2Handlers(runtime),
    ...createFileBrowserHandlers(runtime),
    ...createSessionInsightsHandlers(runtime),
    ...createSubagentsHandlers(runtime),
    ...createSideChatHandlers(runtime),
  ]);
}
