# Conversation sync stability audit — 2026-08-06

## Scope and baseline

This is a read-only source/runtime audit of the complete CC Pocket conversation path:

`Codex/app-server or Claude provider → Bridge conversation sync → v2/legacy wire → Mobile SQLite cache → Session/Chat cubit → Flutter timeline and scroll state`.

Baseline inspected: branch `fix/conversation-sync-stability-20260806`, HEAD `65ed0f4cd16e56f17a7968a56d740828476b454a`, clean before this report. No source/config/database/runtime/build/deploy/OTA/IPA/device file was changed.

The current target rollout is approximately 390.5 MB / 114.8k JSONL lines and still growing. Only metadata (size, line count, first/last event type) was inspected; no rollout body was copied into this report.

## Executive verdict

The chain is not yet stable enough to claim “open → load → retry → live → SQLite → render” closure. The strongest blockers are:

1. Provider timeline read failures are emitted as uncorrelated target errors, then the Bridge still emits checkpoints and `sync_complete`; Mobile discards the error because no request ID maps it to a UI operation. There is no terminal error/retry state for the initial timeline.
2. The v2 initial Codex reader calls `thread/turns/list` without an explicit deadline. `CodexProcess` has no default timeout for that method. A hung read can leave `runSync` awaiting forever. The observed runtime already reports `thread/items/list` unsupported and `thread/turns/list` timing out after 15 seconds on the target.
3. Direct runtime messages only advance a synthetic revision; they are not retained as a bounded content overlay. When canonical history fails, a live message can be absent from the durable snapshot, especially when there is no previous snapshot.
4. Mobile cache replacement/reset paths can delete the visible hot window on a stale base or generic cache error. There is no provider content sequence/monotonic commit guard; an accepted live projection can be replaced by an older snapshot or disappear during recovery.
5. Rebinding/detaching a durable runtime clears `currentStreaming`, the streaming cubit, and every `StreamingChatEntry`. A temporary authority loss therefore visibly rewinds a running session instead of only revoking mutation authority.
6. Retry/input operations do not have a deadline-backed terminal state. `retryMessage` sets `sending` before calling the Bridge; a disconnected/queued send has no local timeout or failure transition, so the bubble can remain pending indefinitely.

These are P1 release blockers (P0-like user impact for a first-open spinner/data disappearance), not cosmetic issues.

## Runtime evidence (bounded and de-identified)

- `/tmp/ccpocket-bridge.err` was about 491 KB at inspection. For the target thread it contains repeated:
  - `thread/items/list is not supported yet`;
  - fallback `thread/turns/list` requests;
  - `thread/turns/list timed out after 15000ms`;
  - `Conversation mirror watch closed` / watch poll failures.
- `/tmp/ccpocket-bridge.log` shows a successful `resume_session` with `historyMode=deferred_sync` and `messages=0`, followed by repeated sync subscriptions/ACKs. No `timeline_failed` or `history_read_failed` UI correlation is logged.
- The target rollout metadata currently reports 390,521,667 bytes and 114,763 lines; first event type is `session_meta`, last event type is `response_item`. It is still growing.

The runtime evidence corroborates the static failure paths, but does not prove that every observed timeout came from the v2 path rather than the compatibility mirror. Device acceptance was not attempted.

## Findings

### F1 — Uncorrelated timeline failure is treated as a successful sync (P1)

Bridge v2 `sendTimelineRecords` catches each provider read failure, sends `timeline_failed` with `requestId` omitted, and returns `null` for that thread (`packages/bridge/src/local-features/conversation-sync-v2.ts:2312-2357`). The caller treats the batch as complete and proceeds to `sync_checkpoint` and `sync_complete` (`:2049-2140`). A failed thread is therefore absent from the advertised thread state but does not keep the operation failed or retryable.

Mobile only completes an error when its `requestId` matches a pending turns/items/latest-turn request or the pending subscription (`apps/mobile/lib/features/conversation_content_sync/conversation_content_sync_service.dart:1653-1683`). A target-level error with no request ID is ACKed and dropped. The legacy implementation has the same shape: `history_read_failed` is sent with no request ID (`packages/bridge/src/local-features/conversation-content-sync.ts:712-733,1070-1088`), while Mobile `_handleError` only handles the pending subscription ID (`apps/mobile/lib/features/conversation_content_sync/conversation_content_sync_service.dart:1988-1993`).

**User effect:** an empty/new durable route can remain blank or keep an old cached window with no visible error/retry; a first-open loading state has no terminal transition. The existing Bridge test “isolates one timeline reader failure” (`packages/bridge/src/local-features/conversation-sync-v2.test.ts:1111-1133`) asserts the error plus `sync_complete`, but does not assert a per-thread terminal state or UI retry, so it currently codifies the hole.

### F2 — Initial Codex history read has no Bridge deadline, and the bounded path still performs a full rollout pass (P1)

`CodexProcess` applies method-specific timeouts only to a small mutating/core set; `thread/turns/list` and `thread/items/list` are absent (`packages/bridge/src/codex-process.ts:369-379`). When no option is passed, `request()` leaves `timeoutMs` undefined (`:6807-6816`). The v2 initial reader calls `listThreadTurns(limit: 5, itemsView: "full")` without options (`packages/bridge/src/local-features/conversation-sync-v2.ts:5703-5723`); latest-turn repair similarly calls `limit: 1` without a deadline (`:5748-5757`). A hung app-server can therefore keep `snapshotFor`/`runSync` pending indefinitely.

The initial v2 Codex path also starts `getCodexDesktopToolTimeline` in parallel. Its first read streams the entire rollout from offset zero (`packages/bridge/src/local-features/conversation-sync-v2.ts:5708-5722`; `packages/bridge/src/sessions-index.ts:4192-4265`). The builder bounds retained events, but the I/O is still O(file size), and a Bridge restart/cache eviction repeats it. This violates the plan’s “large Codex latest-turn bounded fast path; no full JSONL per retry” requirement even though the app-server page itself is limited to five turns.

**User effect:** the target can sit in a spinner without a deadline; a 390+ MB growing rollout increases CPU/I/O and makes retry storms/self-reconnects more likely. Current logs show the same provider endpoint timing out at 15 seconds in the mirror path.

### F3 — Accepted live content is not durable when canonical history fails (P1)

For ordinary runtime messages, `sessionMessage` only calls `queueLiveContent`/`publishLiveContent` and advances a synthetic revision (`packages/bridge/src/local-features/conversation-sync-v2.ts:905-928`). It does not retain the actual message. Bounded message maps exist for the external rollout monitor and shared observer, not for the direct runtime stream.

`snapshotFor` only bypasses a provider read when a shared observer buffer **and** a previous snapshot exist and the read scope is direct (`packages/bridge/src/local-features/conversation-sync-v2.ts:2404-2429`). With no previous snapshot, it calls the canonical history reader. If that reader rejects or hangs, no live-only snapshot is built or sent. The later merge logic can preserve observer messages only after the provider promise resolves (`:2431-2456`).

**User effect:** a live assistant/tool item that was already accepted by the runtime can be missing from the durable route when the history endpoint is unavailable. Reopening a running session after a transient app-server failure is therefore not guaranteed to show the accepted turn.

The existing live-message test (`packages/bridge/src/local-features/conversation-sync-v2.test.ts:3498-3638`) first completes a successful initial sync, then tests observer messages. It does not cover “no previous snapshot + canonical reader failure”.

### F4 — Cache commits/recovery are not monotonic and can delete the visible window (P1)

The Mobile hot-window snapshot carries an opaque `revision`, cursors, and entries, but no provider content sequence or live-overlay generation (`apps/mobile/lib/features/session_list/cache/session_catalog_cache_repository.dart:93-125`).

- A v2 patch whose base does not match immediately deletes the conversation window before throwing (`apps/mobile/lib/features/conversation_content_sync/conversation_content_sync_service.dart:1376-1382`).
- Snapshot mode deletes all hot entries and replaces the window once the pages arrive (`apps/mobile/lib/features/session_list/cache/session_catalog_cache_repository.dart:1565-1590`). There is no comparison against a newer committed live sequence.
- Legacy `replaceConversationWindow` also replaces the whole entry set (`:1835-1901`). A failed legacy patch deletes the window and resubscribes (`apps/mobile/lib/features/conversation_content_sync/conversation_content_sync_service.dart:1934-1944`).
- Any v2 commit error other than a recognized sequence/base mismatch calls `cache.clearTarget(target)` (`apps/mobile/lib/features/conversation_content_sync/conversation_content_sync_service.dart:1140-1164`). `clearTarget` removes timeline, hot windows, catalog, status, and sync-state tables for the whole partition (`apps/mobile/lib/features/session_list/cache/session_catalog_cache_repository.dart:446-462,2392-2423`).
- An explicit thread reset also deletes the hot window and timeline stages without retaining an overlay until replacement (`apps/mobile/lib/features/session_list/cache/session_catalog_cache_repository.dart:1298-1363`).

**User effect:** a stale/late snapshot, base mismatch, or transient SQLite error can visibly rewind/blank one session or the entire source partition. The canonical provider data is not deleted, but the Mobile projection and its recovery base are. The cache tests cover a stale patch base returning `false`; they do not cover a newer live window followed by an older snapshot, or preserving the window across generic reset.

### F5 — Runtime authority loss clears live visual state (P1)

`updateDetachedLiveRuntime` calls `_clearDetachedRuntimeTransients` for every runtime handle change, including `null` during a temporary disappearance (`apps/mobile/lib/features/chat_session/state/chat_session_cubit.dart:1013-1047`). The helper resets `currentStreaming`, the streaming cubit, continuity handlers, and removes all `StreamingChatEntry` values from the visible state (`:1069-1110`). It also clears delivery-pending inputs and queued interactions. Status projection may be retained, but the timeline/stream is not.

**User effect:** a running session can jump back to the last durable cache when the Bridge/app-server attachment flickers. Mutation authority should be revoked immediately, but accepted visual content, anchor, and bounded optimistic delivery state should survive until canonical replacement or a terminal timeout.

Existing tests verify authority/approval revocation on replacement; there is no test that emits a streaming entry, detaches the runtime, and asserts visual continuity.

### F6 — Retry/input operations have no terminal deadline (P1)

`retryMessage` creates a new client ID, changes the bubble to `sending`/`queued`, and calls `_bridge.send` with no `try/catch`, deadline, or operation record (`apps/mobile/lib/features/chat_session/state/chat_session_cubit.dart:7680-7718`). In detached mode it returns silently when no runtime mutation lease exists (`:7682-7685`). Bridge ordinary sends catch socket write errors by queuing the message and scheduling reconnect (`apps/mobile/lib/services/bridge_service.dart:3675-3704`), but do not emit a failure/timeout to this Cubit.

**User effect:** after a retry during a broken connection, the bubble can remain `sending` until an ACK that may never arrive. The normal `sendMessage` path has a preparation/send failure handler; `retryMessage` bypasses it. There is no owner/request/deadline/terminal state to distinguish queued, accepted, provider-rejected, or expired.

### F7 — Empty/failed cache refreshes are silently non-authoritative (P2)

`updateDetachedPreviewHistory` updates paging metadata but returns immediately for an empty message list (`apps/mobile/lib/features/chat_session/state/chat_session_cubit.dart:1113-1128`). `DurableSessionPreviewUpdater` schedules this callback whenever the revision changes (`apps/mobile/lib/features/chat_session/widgets/durable_session_preview.dart:221-234`). Thus an authoritative empty snapshot (or a `null` cache after reset) cannot clear/reconcile the old Cubit entries; old content may linger across a rewrite.

The Codex/Claude screen loaders catch SQLite/cache read errors and only `debugPrint` them (`apps/mobile/lib/features/codex_session/codex_session_screen.dart:620-660`; `apps/mobile/lib/features/claude_session/claude_session_screen.dart:421-466`). No visible error/retry state is set.

### F8 — Scroll restoration is a raw pixel offset, not a content anchor (P2)

`useScrollTracking` stores `_scrollOffsets` keyed only by `sessionId` and restores the raw pixel value after the first frame (`apps/mobile/lib/hooks/use_scroll_tracking.dart:7-8,29-35,73-85`). It has no provider/source fingerprint, committed revision/sequence, stable entry ID, or anchor validity check. The custom controller correctly handles explicit disclosure/layout mutations, but not a cache replacement or a different-height snapshot.

**User effect:** after a live/canonical refresh, the same pixel can land on a different message; a reused session ID across source/provider partitions can restore another route’s position. The hook test covers initial state and the 100 px threshold only.

### F9 — Raw provider error text can cross the wire (P2 privacy/diagnostics)

`timeline_failed` and page failures use `errorMessage(error)` directly (`packages/bridge/src/local-features/conversation-sync-v2.ts:2342-2351,4985-4994`), and `sendError` forwards that string (`:5101-5122`). The legacy path does the same (`packages/bridge/src/local-features/conversation-content-sync.ts:728-733,1070-1088`). Some optional rollout readers deliberately sanitize to an error kind, but the main failure path does not. Provider/app-server errors may contain local filesystem details. Sanitize to bounded error codes/kinds before sending to Mobile or logging.

## What is already sound or partially sound

- Target partitioning is source-scoped (Bridge instance/Codex source/provider/session), and data-source conflict fences exist around SQLite reads.
- V2 sequence validation and cumulative ACK are serialized; ACK is sent after cache commit in the normal path (`_commitV2Event`), which is a good durability boundary.
- Explicit turns/items/latest-turn page requests have request IDs, 15-second Mobile waits, bounded pages/bytes, and UI paging catches that set an error state.
- The v2 observer/external buffers are byte/count bounded and canonical/live identity merging is one-to-one. The gap is that direct runtime messages are not put into the same bounded overlay and canonical failure is not a terminal operation.
- Reading-position anchor corrections for disclosure changes are layout-time and avoid the visible pre-correction frame. They do not solve cross-revision raw-offset restoration.

## Priority remediation order

1. Add a per-thread content operation ledger on both sides: `owner`, `requestId`, source/provider/session target, generation, provider sequence/revision, deadline, retry count, and terminal state (`pending`, `committed`, `retryable`, `unavailable`, `superseded`). Timeline failure must carry a request ID/target and prevent `sync_complete` from claiming that thread succeeded.
2. Wrap every Codex read RPC in an explicit abort/deadline. Separate the latest-turn fast path from optional tool enrichment. Use a stable rollout file identity plus bounded tail/incremental offsets as a fallback; never rescan the full growing rollout for each retry.
3. Retain a byte/count-bounded live overlay for direct runtime messages and publish it even when canonical history is unavailable or no previous snapshot exists. Drop it only after a canonical snapshot with a newer provider sequence proves coverage.
4. Add a monotonic content sequence to the v2 wire/cache and reject older snapshots/patches before touching hot entries. Replace target-wide generic reset with scoped failure while retaining the last valid window and live overlay. A thread reset must stage replacement before removing the visible projection.
5. On runtime handle loss, revoke only mutation authority. Preserve timeline/streaming/anchor/optimistic delivery state and expose a non-blocking unavailable/reconnecting banner with Retry.
6. Route `retryMessage` through the same delivery ledger as normal input, catch Bridge queue/write failures, and transition to explicit queued/failed/expired states with a retry action. Keep idempotency identity stable for a single operation.
7. Make an empty snapshot authoritative, expose cache-load failure state in the route, and replace raw scroll offsets with `(source, revision, stable entry ID, intra-row offset)` anchors. Sanitize provider error strings.

## Required regression matrix before source acceptance

Static tests should cover:

- initial v2 provider timeout, unsupported endpoint, and target-level error: prior cache remains visible, operation becomes retryable/unavailable, and no false per-thread `sync_complete` is accepted;
- no previous snapshot + shared/direct live item + canonical reader failure: live item is sent/persisted in the bounded overlay;
- newer live sequence followed by older snapshot/patch/reset: older data is ignored and hot window is not deleted;
- generic SQLite commit failure: only the affected operation/thread is marked failed, not the whole source partition;
- runtime streaming entry followed by handle `null`/replacement: stream and anchor remain visible while mutation controls are disabled;
- retry send while socket write fails/queues: bubble reaches a bounded terminal state and can be retried without an indefinite spinner;
- authoritative empty snapshot clears prior entries; cache-load error renders Retry;
- scroll restoration across source/revision/height changes uses an anchor or safely falls back to bottom.

Verification still needed outside this read-only audit: focused Bridge/Mobile tests, a large-rollout cold/hot/tail benchmark, isolated live Bridge smoke with exact PID/path/listener/health, and separate iOS/device acceptance. No build, restart, deployment, OTA, IPA, phone, or stable-channel claim was made here.

## Root-agent review

The coordinating agent independently checked the cited call sites after the
Luna Max audit. F1-F6 are accepted as real chain defects rather than style or
architecture preferences:

- F1 is confirmed with one nuance: `sync_complete` does not advance the failed
  thread's revision, but it does close the batch without a Mobile-correlatable
  terminal result for that target. The user-visible outcome is still an
  operation that appears to load forever or silently retains stale content.
- F2 is confirmed: the initial/latest v2 Codex reads have no RPC deadline, and
  the optional Desktop enrichment starts an unbounded first pass over the
  rollout on the critical path.
- F3 is confirmed: direct runtime messages advance content revision without
  joining either bounded message overlay used by snapshot reconciliation.
- F4 is confirmed: base mismatch, generic commit recovery, and explicit thread
  reset can remove a valid visible cache before a replacement is committed.
- F5 is confirmed: runtime attachment changes revoke authority and also delete
  visual streaming state, although those concerns have different lifetimes.
- F6 is confirmed: retry bypasses the normal ordered input preparation and
  failure path, and has no bounded terminal state of its own.

F7-F9 remain accepted secondary findings. The first implementation slice must
therefore improve provider-read bounds and fallback, preserve the last valid
Mobile projection during recovery, and keep visual continuity separate from
mutation authority. Scroll anchoring and diagnostic sanitization follow after
those data-path changes; they must not replace them.

## Implemented stability slice and verification

The root implementation deliberately stayed on the existing Bridge v2,
SQLite repository and ChatSessionCubit ownership paths. It did not add another
coordinator or replace the timeline UI.

- `bdf62a5f` gives Codex history RPCs an explicit 10-second deadline, bounds
  the first optional Desktop-tool enrichment read to the recent 16 MiB tail,
  retains stable direct runtime messages in the existing bounded observer
  overlay, and turns canonical history failure into an incomplete retryable
  timeline instead of a silent missing thread. Unexpected wire failures are
  correlated to the subscription and do not expose raw provider error text.
- `057ad4dd` preserves the last committed Mobile hot window across generic
  commit recovery, base mismatch and scoped thread reset; runtime handle
  replacement revokes mutations without clearing visible streaming output;
  Codex latest-turn repair requests one summary turn before detailed item
  paging; message retry uses the normal ordered dispatch path. A detached page
  that reports no progress now becomes a terminal retryable error rather than
  retaining `hasMore=true` behind an endless spinner.
- `d2bf80cc` exposes cache-read failure as a real Retry action in both Codex
  and Claude routes, coalesces retry with an in-flight read, and stops restoring
  a raw pixel offset for durable cache-first conversations whose entry heights
  and revisions can change.

Verification on the final source state:

- Bridge: `conversation-sync-v2.test.ts` plus `sessions-index.test.ts`, 214/214
  tests passed; the test preflight also passed TypeScript and native helper
  builds.
- Mobile: five focused service/repository/Cubit/scroll/preview files, 261/261
  tests passed.
- Targeted Flutter analysis of the six changed source files reported no error
  or warning; only two existing `prefer_initializing_formals` infos remain.
- A fresh-process read of the real approximately 390 MB target rollout through
  the built bounded timeline reader completed in 88 ms and produced 1,577
  retained events / 3,210 timestamps. This is a local synthetic invocation of
  the production-shaped file, not a phone or deployed Bridge acceptance test.
- `git diff --check` passed before the behavior commits.

Still open by design rather than hidden:

- A socket frame admitted to the persistent outbox still lacks an end-to-end
  provider-ACK deadline that can safely mark the message failed without risking
  a duplicate later delivery. That needs an idempotent delivery-status query or
  cancel contract, not a UI timer.
- An authoritative empty durable snapshot still needs explicit provenance to
  distinguish a true provider rewrite from accepted live/optimistic content.
  The implementation keeps visible content rather than guessing and deleting.
- The bounded initial Desktop enrichment tail is supplemental to canonical
  app-server history. A future background disk index can backfill older omitted
  raw tool metadata without putting a full rollout scan back on the interactive
  path.
- No Bridge runtime, Mobile release, OTA, IPA, phone or stable channel was
  changed in this source task. Device acceptance remains separate.
