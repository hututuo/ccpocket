# Mobile Conversation Mirror v01

Status: accepted

## Goal

Keep the existing recent-first session discovery, while allowing selected
Codex conversations to be downloaded into the mobile app, opened from a local
reconstructable copy, and reconciled incrementally while CC Pocket is
connected. Messages submitted from Codex Desktop must appear on mobile after
canonical reconciliation without requiring the user to leave and reopen the
conversation.

## Authority and identity

- Codex app-server remains the authority. The phone database is a rebuildable
  mirror, never a second source of truth.
- Persistent identity is `(bridgeInstanceId, provider, providerSessionId)`.
  Bridge runtime session IDs and the current `historySeq` are explicitly not
  persistent cursors.
- The mirror has its own content digest, snapshot generation, entry identity,
  and upsert/delete/reset operations.
- Official raw item IDs and turn IDs take precedence over synthetic display
  UUIDs. Content hashes detect same-count mutations.

## Compatibility and removability

- Add an opt-in local-feature protocol. Older mobile clients never request it;
  newer mobile clients fall back to the existing history path when an older
  Bridge reports the request as unsupported.
- Wire v1 is explicit: every client request carries `protocolVersion: 1`, and
  the only advertised response capability is `conversation_mirror_event_v1`.
  Additive response fields and unknown future event kinds are ignored by old
  iOS clients; a breaking wire change must use new v2 request/event names.
- Compatibility is bidirectional and request-driven:
  - old iOS + new Bridge: no mirror reader, watch, or unsolicited mirror event
    is created unless the client both advertises and requests the feature;
  - new iOS + old Bridge: exact `unsupported_message` / capability failures are
    isolated to the mirror request; older generic errors are correlated only
    when they name the exact mirror request type. The normal recent/history
    path then stays authoritative;
  - new iOS + transitional mirror-capable Bridge: if a later watch transfer
    predates per-transfer `accepted`, iOS may advance the rebuildable database
    revision but never publishes that unguarded transfer into the active
    runtime; it requests canonical history instead;
  - new iOS + new Bridge: mirror revisions are opaque, so either side can
    change its internal normalization without treating runtime history sequence
    numbers as durable cursors.
- Store mirror data in an independent `conversation_mirror_v1.db`. Do not bump
  or migrate the official `ccpocket.db` schema. The v1 schema is frozen at
  release; downgrade recovery may delete and rebuild this rebuildable mirror
  only. A future breaking schema must use `conversation_mirror_v2.db`, so an
  older binary never reinterprets newer tables or `user_version` state.
- Keep stable provider identity and the disabled protocol registrations in the
  neutral Bridge/Mobile foundation commits. Optional behavior is owned by one
  Bridge Mirror commit and one Mobile Mirror commit; neither edits the frozen
  composition roots. No mirror state enters canonical chat history or the
  offline outgoing-message queue.
- Removing the feature leaves only an unused app-sandbox database file and
  restores the official runtime behavior.

## Bridge synchronization

- Explicit sync and subscribed reconciliation prefer bounded
  `thread/items/list` pages, retaining each response element's official
  `turnId`. A legacy thread falls back to `thread/turns/list` with
  `itemsView: full`; summary/not-loaded turns are never committed as a full
  phone mirror.
- A still older app-server that explicitly rejects `itemsView` is retried once
  without that field, and the response is accepted only when each turn is
  absent the legacy marker or reports `itemsView: full`. Pagination mode is
  cached per `(app-server process, threadId)`, because one process can host
  legacy and paginated threads simultaneously. Transport failures are not
  sticky downgrades.
- Fall back per thread to stable `thread/read(includeTurns: true)` only when
  both pagination adapters are explicitly unavailable or cannot prove a full
  response. The fallback's total-entry, per-entry, and serialized-byte guards
  run after the full RPC response is already in Node memory; they are not
  provider-side pagination.
- Snapshot transport is chunked (at most 100 entries and approximately 512 KiB
  per page) with begin/page/complete framing.
- A current v1 Bridge sends an additive `accepted` frame before every
  potentially long transfer, including later reconciliations of an established
  watch. New iOS waits at most 10 seconds for the first correlated frame, then
  retains the official history path; every accepted/snapshot frame rearms the
  bounded 30-minute page-idle deadline. Old iOS safely treats `accepted` as an
  unknown additive event. This also bounds fallback against pre-1.67.3 Bridges
  that return only an uncorrelatable `Invalid message format` error. Those
  extreme legacy builds keep the socket and canonical history usable, but may
  still surface one generic error/log before the 10-second best-effort fallback;
  clean immediate fallback starts with Bridges that support either
  `unsupported_message` or the mirror `accepted` frame.
- A subscription retains the last snapshot per provider thread and emits
  bounded upsert/delete patches when the base digest matches. Revision
  mismatch, rollback, conversion changes, or a lost generation trigger a reset
  snapshot.
- Poll only subscribed conversations. Marker checks default to 5 seconds with
  deterministic ±20% jitter; a changed marker reconciles immediately. An
  unchanged thread receives a full safety reconcile every 5 minutes. Poll
  failures use exponential backoff up to 5 minutes and reset after success.
- Bound all marker and full-history reads from watch, probe, and explicit sync
  through one global semaphore (default concurrency 2). All watches still
  share at most one mirror-owned app-server process; this does not create a
  second Bridge service.
- Abort a watch reader when its last client disconnects and pass one-shot
  request cancellation through to app-server pagination. A dead connection
  therefore releases its global read permit before a reconnect queues new
  work.
- When project-path enforcement is active, missing provider `cwd` fails closed.
  Do not trust the client-supplied project path as proof that a globally stored
  thread belongs to an allowed project.
- Do not assume a separate Codex Desktop app-server broadcasts live
  notifications to Bridge. Reconciliation reads the official persisted thread.

## Mobile persistence and bootstrap

- Write snapshot pages into a shadow generation and atomically switch the
  conversation metadata only after the complete frame. Interrupted downloads
  keep the previous generation readable. Snapshot completion uses a
  generation/revision compare-and-swap; a newer Desktop patch wins and causes
  one reset snapshot instead of being overwritten.
- Read metadata plus active entries in one SQLite transaction. Enforce a 64 MiB
  per-generation ceiling and a 512 MiB logical mirror-database ceiling; abort
  the exact shadow generation on disconnect, timeout, removal, or validation
  failure.
- Store forward-compatible raw normalized message envelopes plus entry ID,
  ordinal, and content hash. Do not persist bearer tokens, temporary artifact
  URLs, local image paths, image bytes, stream deltas, or incomplete assistant
  drafts. User image count may be retained, but media payload is not an offline
  mirror guarantee in v1.
- v1 renders only the normalized `user_input`, `assistant`, and `tool_result`
  envelopes it defines. A newer Bridge envelope remains preserved in SQLite
  but is skipped by an older iOS renderer rather than becoming a false error;
  adding another visible canonical type requires a v2 contract.
- Subscribe to the live Bridge stream before loading SQLite. Merge by stable
  identity and never let a delayed local bootstrap overwrite newer live data.
  If canonical reconstructable content already exists before bootstrap starts,
  skip local publication and reconcile only in the background. Bootstrap
  generations and service-close gates prevent late SQLite reads from publishing
  into a disposed or superseded runtime.
- Capture Bridge identity, provider binding, bootstrap generation, and content
  epoch at each `accepted` transfer boundary, then revalidate them before and
  after database work. If canonical content changes during a transfer, keep the
  database reconciliation but refresh the active runtime through official
  history. A transitional Bridge without the repeated boundary is always
  store-only for that transfer.
- When a selected conversation resumes under a new runtime ID, bind that
  runtime in memory to its stable provider ID, render the local snapshot, then
  reconcile by mirror revision. Unsupported/timeout paths use the existing
  `get_history` behavior.
- For Git worktree sessions, use official `resumeCwd` as the reader and cache
  path; use the base `projectPath` only when no worktree resume directory is
  present.
- A canonical Desktop user item is rendered as sent (check mark). Persisted
  tool/process items are upserted as their canonical state changes. The mirror
  does not publish standalone-reader thread status into the live chat status
  channel, because that separate app-server cannot authoritatively clear an
  active approval or streaming state.

## Product surface

- Keep recent-first loading unchanged.
- v1 does not add a separate offline conversation-list/navigation product and
  cannot run Codex without a backend. It accelerates an existing recent/resume
  flow by publishing the phone copy before reconciliation; an unambiguous copy
  can survive a temporary identity gap inside that bootstrap seam.
- A recent Codex conversation action offers Download and auto-sync, Sync now,
  and Remove phone copy.
- The independent database uses incremental auto-vacuum. Explicit removal
  cascades the copy and reclaims eligible tail pages without a routine blocking
  full-database VACUUM.
- Downloaded conversations receive a local-copy indicator. Auto-sync is active
  only while the app has a Bridge connection; iOS background suspension still
  applies.
- Wording is "conversation text and tool history", not "complete media
  conversation" or "raw event log". The official persisted thread can omit
  transient process output, and a separate Desktop app-server cannot provide
  guaranteed cross-process token streaming.

## Verification gates

- Snapshot interruption, restart, endpoint/bridge isolation, >200 entries,
  same-text duplicate turns, mutation with unchanged count, rollback/delete,
  old-Bridge fallback, old pagination-parameter fallback, old-client capability
  gating, additive future responses, reconnect, app relaunch, Bridge identity
  A→B migration, duplicate-tap single flight, snapshot-vs-patch conflict,
  two-Bridge offline ambiguity, same-process legacy/paginated thread mixing,
  preexisting canonical content, and close-during-bootstrap races.
- A disconnect during an in-flight paginated RPC must abort the old read and
  let a reconnect acquire a single global permit immediately.
- Eight restored watches must respect the global read semaphore, have dispersed
  poll deadlines, and recover from backoff without overlapping full reads.
- Two WebSocket clients must not share request correlation or watch ownership.
- Bridge and Flutter full tests/builds, plus direct-revert checks for every
  feature commit and a reverse-stack tree comparison against the starting
  commit.

## Current verification

- The modular Bridge Mirror commit changes only its two activation slots and
  three feature-owned implementation/test files. Its TypeScript build and 36
  focused tests pass in isolation.
- The modular Mobile Mirror commit owns its independent SQLite store, runtime,
  synchronization service, bounded UI hooks, and feature tests. Lifecycle
  archive behavior is preserved at the shared recent-session UI boundary.
- Final full Bridge, Flutter, iOS simulator, and direct-revert results are
  recorded by the enclosing mobile Codex parity acceptance after all optional
  modules are composed.

## Implementation commits and rollback

- `BRIDGE_F0` / `MOBILE_F0`: stable identity seams and disabled Mirror/Core
  slots. These are neutral compatibility foundations, not active Mirror
  behavior.
- `MIRROR_BRIDGE`: versioned protocol, bounded persisted-history adapters,
  watch reconciliation, and Bridge tests.
- `MIRROR_MOBILE`: independent SQLite mirror, runtime reconciliation, recent
  actions, badge, and mobile tests.
- Revert `MIRROR_MOBILE` and `MIRROR_BRIDGE` to remove the optional feature;
  the two foundation slots return to their disabled implementations. Each side
  can also be removed alone: a new client falls back from an old Bridge, and an
  unused new Bridge never sends unsolicited Mirror events to an old client.
- The accepted branch remains local and undeployed. It is not merged into a
  stable branch and has not replaced or restarted the live Bridge or app.
