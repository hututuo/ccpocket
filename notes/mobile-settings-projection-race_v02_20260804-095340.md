# Mobile settings projection race follow-up

Status: `source-fixed / targeted-verified / deployment-pending / device-pending`

## Source lane

- Worktree: `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-toolbar-batch-settings-20260804`
- Branch: `fix/mobile-toolbar-batch-settings-20260804`
- Base: `83c0cf5662ba403e58ebafdede6b0d77dfffd453`
- Bridge: `5120b478d17a3f4e14911eb2ed1eec352a87f95f`
- Mobile: `882b02ffc4810a4234523d5421356c314f297e51`

## Confirmed causes

The remaining first-open delay and post-mutation stale value were separate
problems.

1. The initial v2 catalog carried bounded metadata, while an authoritative
   settings read started only after a thread became focused. A newly opened
   recent conversation could therefore render before model, reasoning effort,
   service tier, Plan and permission facts arrived.
2. Detached/shared settings deliberately did not update optimistically. After
   the Bridge confirmed a durable model, effort or speed mutation, Mobile only
   cleared its rollback marker; it did not project the acknowledged value into
   the current `ChatSessionCubit`. Leaving and reopening the page let a later
   catalog refresh display the correct value, which looked like a cache refresh
   problem even though the provider write had already succeeded.

## Bridge correction

- A full `conversation_sync_v2` subscription prewarms authoritative Codex
  settings for the focused thread, the five most recent Codex threads and
  special-status threads.
- Initial catalog/status/timeline delivery remains non-blocking. Fast reads can
  join the first catalog frame; slower reads use the same v2 subscription and
  publish follow-up `catalog_changes`.
- Total settings-read concurrency is `3`; the pending queue is capped at `32`.
  The recent five are reserved before remaining slots are filled with special
  threads, so a large Working/Need You set cannot starve recent conversations.
- Focus changes use the same global queue and move the focused key to the front;
  they cannot create a fourth reader.
- Complete authoritative snapshots are not redundantly prewarmed. Disconnect,
  unsubscribe and transition to notification-only clear the unstarted queue.
- Every read is fenced by shared-control generation, per-thread epoch and
  catalog revision. Reconnect clears the old queue, refreshes the catalog, then
  selects priorities again. Late results cannot overwrite a newer authority.
- A read has a five-second timeout. A permanently stuck file/app-server read
  releases its slot without blocking catalog, status, messages or later focus.

These changes add no protocol field, database schema, native code or Cloud
dependency.

## Mobile correction

- A valid Codex `set_codex_model` or `set_codex_speed` system acknowledgement
  immediately updates the current page and the in-memory runtime-session
  snapshot.
- Detached writes remain non-optimistic: the selected value is shown only after
  the provider/Bridge success acknowledgement. The authoritative catalog still
  performs final correction and SQLite persistence.
- Missing or malformed acknowledgement fields do not clear the pending rollback
  state; a subsequent rejection still restores provider facts.
- Model and reasoning effort are now considered known independently of service
  tier. An old or sparse source may leave speed read-only/unknown without hiding
  the known model and effort.
- Content-free diagnostics now include `model_ack_applied` and
  `speed_ack_applied`; raw thread IDs, paths and message bodies are not logged.

## Verification

- Bridge `conversation-sync-v2.test.ts`: `118/118` passed.
- Bridge TypeScript build and Darwin native file-browser helper: passed.
- Mobile `chat_session_cubit_test.dart` plus `session_mode_bar_test.dart`:
  `217/217` passed.
- Targeted Flutter analyze: `0 error / 0 warning`; two pre-existing
  `prefer_initializing_formals` infos remain.
- `git diff --check`: passed.
- Independent Luna Max review: `LGTM`, no P0/P1 blocker after the race, timeout,
  malformed-ACK and saturated-queue follow-ups.

## Release boundary

This is source-only verification. The production Bridge, owner OTA, IPA,
physical iPhone, Cloud, Desktop configuration and stable channel were not
changed. Bridge deployment and Mobile owner release remain separate user-
authorized gates.
