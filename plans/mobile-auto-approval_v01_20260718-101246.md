# Mobile Auto Approval v01

Status: accepted

## Goal

Add a mobile-owned, per-Codex-conversation auto-approval switch for periods
when the user wants CC Pocket to supervise a running session. The switch must
continue working while the conversation screen is closed, as long as the app
process remains connected to the Bridge.

## Authority and scope

- Reuse the existing core `approve` client message. Do not add a Bridge wire
  method or reinterpret Codex `Full access` / `Auto-review` settings.
- Auto-approve only the explicit v1 allowlist: Bash, FileChange, Permissions,
  recognized MCP approval prompts, and plan completion. A request must support
  the existing one-shot accept path (including legacy requests whose decision
  list is omitted). Unknown future request kinds fail closed.
- Never fabricate an answer for `AskUserQuestion` or another structured
  question. Never automatically install a suggested plugin/connector or
  complete its external authentication.
- The feature is Codex-only in v1. Claude already exposes its provider-owned
  `Auto` permission mode; this local supervisor must not silently replace it.

## Persistence and isolation

- Default off. Persist enabled conversations in a dedicated
  `local_feature.codex_auto_approval.enabled.v1` SharedPreferences key.
- Keep an app-level **Disable all** control in Settings that works without a
  Bridge connection or live session list. It synchronously suppresses all
  approval sends before persisting an empty allowlist.
- Scope an enabled record to the configured machine UUID, provider, and stable
  provider session ID. This survives SSH tunnels whose local forwarding port
  changes while preventing a different saved machine from inheriting approval
  authority. For a direct URL that has no saved machine UUID, use a sanitized
  endpoint fallback and strip URL user info, query, and fragment.
- Serialize preference mutations so rapid toggles and simultaneous changes to
  different conversations preserve the last requested state.
- Deduplicate by machine identity, runtime session, and tool-use ID. During one
  connection, send at most three attempts for a still-pending request and keep
  the tracked set bounded. At capacity, new requests fail closed for manual
  handling rather than evicting old counters and resetting their retry limit.
  After reconnect, reconsider only requests the Bridge still reports as
  pending; this is intentionally at-least-once rather than an unsafe offline
  queue.

## Modular boundary

- Add one inert mobile BridgeService observation seam inside the feature
  commit.
  Observers cannot suppress official permission delivery, so manual approval
  remains the fallback if an automatic send does not settle.
- Keep the observer seam, service, storage, strings, panel, status indicator,
  host slot, and app registration in one feature commit. The feature uses the
  existing local session UI host.
- Keep the independent Bridge fix for simultaneous pending interactions and
  the mobile fix that restores an earlier manual question after an automatic
  tool result in separate prerequisite commits. Reverting the mobile feature
  commit removes the complete UI and automation surface; reverting all three
  commits must reproduce the starting tree exactly.

## Lifecycle and compatibility

- The mobile app must be running and its WebSocket connected. iOS suspension,
  app termination, or network loss pauses supervision; a still-pending request
  is reconsidered after the session list reconnects.
- Old iOS clients are unchanged. New iOS remains wire-compatible with old and
  new Bridges because `approve` and `session_list.pendingPermission` are
  existing protocol fields. An old Bridge does not include the new concurrent
  interaction hardening: it may begin executing an approved plan before an
  overlapping command or question has been resolved. Only the matching new
  Bridge guarantees deferred plan execution, so it is recommended for robust
  unattended operation.
- If a Bridge omits stable provider identity, disable configuration for that
  session. Never persist authority against a reusable runtime session ID.
- Use only a one-shot, online-only `approve` message. Never queue an approval
  offline and never send `approve_always`, which would leave a provider-owned
  session allow rule after the switch is turned off.

## Verification gates

- Default-off and persistence restore.
- Offline global disable followed by reconnect with a pending request.
- Machine UUID stability across SSH forwarding ports, endpoint credential
  stripping for direct URLs, and cross-machine isolation.
- Stable provider-session rebinding across runtime IDs.
- Bounded retries for repeated live/session-list delivery, alternating pending
  snapshots, and reconnect reconsideration.
- Ask-user, malformed question, tool suggestion, and non-accept requests remain
  visible for manual handling.
- Existing behavior with no observer, throwing observer isolation, and
  observer removal.
- Flutter targeted and full tests, analyze, iOS simulator Debug build, Bridge
  full tests/build, independent review, and direct/reverse Git revert gates.

## Accepted verification snapshot

- Bridge TypeScript build and full suite: 52 files, 1051 tests passed.
- Flutter full suite: 1527 tests passed, 4 environment-gated tests skipped.
- Flutter analyze: no warnings or errors; 38 pre-existing informational lints.
- iOS simulator Debug build: `build/ios/iphonesimulator/Runner.app`.
- Two independent reviews found no remaining P0, P1, or P2 issue in the
  frozen implementation and no implicit Conversation Mirror dependency in the
  standalone port. Reverse-reverting the three modular commits reproduces the
  deployed feature baseline `cb143be` exactly.
