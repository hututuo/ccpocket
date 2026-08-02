# Shared Codex durable thread settings control

Status: `source-verified / deployment-pending / phone-acceptance-pending`

## User-visible fault

Two detached durable-thread states were incorrectly treated as different
authorization classes:

- An idle thread could display model, reasoning effort, Plan and permissions,
  but Mobile rejected edits with “waiting for Bridge to sync settings” because
  no transient runtime attachment existed.
- A Desktop-active thread could lose the same controls or report that Desktop
  owned them, even though both clients were connected to the shared app-server.

The old rule conflated execution ownership for the current turn with durable
settings ownership for later turns.

## Confirmed contract

The current turn still has one exact execution authority. Stop, steer,
approval, question response and input delivery continue to require the current
runtime target and authority generation. This preserves exactly-once behavior
and prevents a stale phone from controlling another turn.

Model, reasoning effort, service tier, collaboration mode, approval policy,
reviewer and sandbox are durable thread settings for subsequent turns. The
official app-server `thread/settings/update` RPC accepts an exact `threadId`
without `thread/resume`; therefore these settings do not belong exclusively to
the Desktop or Bridge process that currently owns a turn.

## Implementation

Bridge adds the capability `codex_durable_thread_settings_v1` and an additive
settings target:

```text
settingsTarget = durable_thread
codexSourceId
threadId
operationId
```

This target deliberately omits transient `sessionId`, `runtimeSessionId` and
`authorityGeneration`. Mixed or partial envelopes are rejected by the parser.
Old clients and old Bridges keep the previous exact-runtime/legacy paths.

The durable mutation path:

1. requires daemon shared mode, the Action Broker writer lease and the existing
   turn-start pilot gate;
2. verifies the exact Codex source and source-scoped durable thread metadata;
3. serializes operations per thread and deduplicates them by operation ID and
   settings fingerprint;
4. creates an initialize-only Codex process and calls
   `thread/settings/update` without resume, attachment or history loading;
5. preserves authoritative network and writable-root context when rebuilding a
   sandbox policy;
6. publishes a content-free `thread/settings/updated` invalidation so
   `conversation_sync_v2` rehydrates only the focused thread settings;
7. returns setting-specific acknowledgements or rejections so Mobile clears or
   rolls back its pending UI state.

Mobile uses this target only when the Bridge advertises the capability and the
current connection has an authoritative source identity. Idle detached and
Desktop-active durable threads then expose editable next-turn settings. A
narrow exact-thread subscription receives only setting acknowledgements and
known setting failures; it does not create a second history, status or chat
subscription.

## Compatibility and safety

- New Mobile + new Bridge: detached durable settings are editable whether the
  thread is idle or the current turn is Desktop-active.
- New Mobile + old Bridge: the old waiting/read-only behavior remains; Mobile
  does not send the new target.
- Old Mobile + new Bridge: existing private and exact-runtime messages remain
  unchanged.
- Older app-server or unavailable writer: the capability is absent or the
  operation fails closed. Current settings remain unchanged.
- The current active turn is not restarted or retroactively changed. Updated
  settings apply to subsequent turns.
- No SQLite/schema, Swift/native, Cloud, Desktop configuration, session-history
  or network change is included.

## Verification

- Bridge targeted settings suite: 6 files / 782 tests passed.
- Bridge full single-worker suite: 114 files / 2,304 tests passed.
- An earlier full run executed concurrently with the Mobile suite and hit two
  fixed 5-second timeouts in `session-catalog-monitor.test.ts`; the isolated
  file passed 8/8 and the subsequent resource-isolated full run passed
  2,304/2,304. This was retained as resource-contention evidence, not hidden as a
  clean first run.
- Mobile focused cubit/widget suite: 215 tests passed.
- Mobile full suite: 2,889 tests passed with 4 environment-dependent skips.
- Full Flutter analysis: 0 errors, 0 warnings and 52 repository-existing infos.
- TypeScript build, native file-browser helper build, Dart formatting and
  `git diff --check` passed.

No Bridge runtime, OTA, IPA or physical phone was changed during source work.
Deployment and physical-phone acceptance remain separate gates.
