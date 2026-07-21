# ccPocket Compatibility Decisions

## Upstream-compatible local fixes

- Local compatibility fixes must preserve the official protocol and data model wherever possible.
- Prefer narrow adapters and replaceable internal boundaries over broad rewrites.
- Every local behavior change needs regression coverage so official updates can be rebased and compared safely.
- Keep compatibility commits isolated by behavior; do not mix them with unrelated simulator, signing, or packaging work.
- For large session files, use bounded streaming or incremental reads. Do not restore whole-file JSONL loading merely to simplify an upstream merge.
- Sync official releases with an explicit merge commit after semantic review; retain a pre-sync safety branch and do not rewrite already validated compatibility commits by default.
- Resolve hotspot files from the latest official source plus the smallest necessary compatibility patch. Do not run whole-file formatters on large upstream-owned screens merely to resolve a small conflict.
- Embedded artifact previews are enabled only on iOS for now. Web, Android, macOS, Windows, and Linux keep the existing external-browser fallback until each platform has a user-visible native save destination and a verified WebView security configuration.
- In embedded mode the Bridge renders preview content only; Flutter owns back navigation, share, download, hide/reveal, transfer cancellation, and file persistence. Do not add a broad JavaScript-to-native channel for artifact actions.
- On iOS, Word, Excel, PowerPoint and RTF use a narrow system Quick Look adapter. Reuse the authenticated, bounded artifact download into app-temporary storage; validate that the native path remains inside the app home directory; keep the file until the native dismissal callback; then remove it. Do not upload Office files to an external preview service or move this behavior into the Bridge protocol.

## Session correctness boundaries

- Recent-session stale-response generations are per WebSocket client. A new
  top-level/filter request may invalidate older work from the same client but
  must never cancel another client's response.
- Codex recent-session discovery includes official `cli`, `vscode`, `exec`,
  and `appServer` sources. Worktree cwd normalization must use the same shared
  boundary for app-server and rollout results while preserving raw
  `resumeCwd`.
- Per-project Show more limits are local presentation intent, not server-backed
  filter state. Preserve them across offset-zero refresh and reconnect reset.
- One live Bridge owns at most one running app-server for a durable Codex
  thread. Replayed or cross-socket resumes attach to the existing runtime;
  concurrent resumes are coalesced, and a stopped runtime is never reused.
- Mobile Desktop-continuity state is scoped to one Bridge connection
  generation. Live continuity events outrank a matching `SessionInfo`, and a
  matching `SessionInfo` outranks rebuildable `HistoryMessage` state. Thread
  id, project path, model, reasoning effort, and service tier use field-level
  ownership so an older Bridge may fill omitted fields without letting stale
  history rebind fields already supplied by the current session list.
- Disconnect clears the current session-list ownership and continuity watch.
  A same-target reconnect must receive a newly generated authoritative
  `session_list` before cached sessions or cached capabilities can reclaim
  ownership or start a watch. Until then, history remains the old-Bridge
  fallback. Watch acknowledgement timeouts use bounded retry; a
  `path_not_allowed` identity stays suppressed until the connection or
  identity changes.
- Desktop tool continuity covers the currently recognized common Codex
  schemas (`function_call`, `custom_tool_call`, command execution, file
  changes, MCP, web search, and image-generation metadata), but it is not a
  promise to stream every future response item or private agent event. Image
  bytes and unrecognized future schemas converge through terminal canonical
  history rehydration rather than being advertised as fully live.

## Official 1.67.4 integration and rollback manifest

- The official source boundary is merge commit `fa23f5b`, whose second parent is official `ba2decd` (Mobile `1.107.1+194`, Bridge `1.67.4`). The pre-merge local tree is retained at `backup/pre-upstream-1.67.4-20260719` (`677555d`). Use that safety branch to inspect or restore the complete pre-update tree; do not remove an individual local feature by reverting the official merge.
- Treat streamed assistant identity as `(turnId, itemId)`, never as response text. The Bridge turn tracker is owned by `53a73ac` and is directly revertible. Anonymous deltas bind only when exactly one agent item is open; ambiguous data fails open rather than deleting a possibly distinct response.
- Cross-baseline Bridge reconciliation is owned by `a68b3dc` and is directly revertible. Mobile lossless history reconciliation is a two-commit stack: remove `b370f10` first, then `257767a`. This preserves one-to-one provisional aliases, rich content, artifacts, and images without collapsing two legitimate equal-text replies.
- The post-update Codex Effort animation is owned by `4bea555` and is directly revertible from the completed branch. `25b20b2` is the migration baseline that cancelled the pre-update animation ownership; do not revert it by itself. Reverting `4bea555` intentionally returns the UI to the official-style non-animated baseline while preserving the current Max/Ultra selection safeguard.
- `044ba72` changes tests only: it injects a fixed clock for file-transfer resume expiry fixtures and does not relax production expiry behavior. It may be reverted independently after those fixtures are rewritten around another explicit clock seam.
- Conflict-free reverse-application gates from the post-1.67.4 HEAD were executed for `53a73ac`, `a68b3dc`, the ordered pair `b370f10` then `257767a`, and `4bea555`. Every gate ended with `git revert --abort`, no retained `REVERT_HEAD`, and an unchanged final tree.
- Major older optional stacks retain their existing reverse-removal order: file transfer `83a0ca9` then `e439bf3`; core actions `135ed32` then `72f693a`; conversation mirror `3a126c1`, `8ab54a2`, `d0ebe92`; lifecycle/archive `57d4647`, `6e466b5`, `9e0bdc3`, `b138aee`, `ceafa4a`; auto approval `af4be66`, `e295582`, `16adec7`; Goal management `a83dc30`, `80ff466`, `3e676f9`; artifact preview/link handling `02a6f33`, `138d575`, `ec3b0d3`, `659e98c`, `79e7c93`, `f856690`, `9ae7158`, `4066f6e`.
- No update merge, rollback gate, or validation step in this integration authorizes deployment. Replacing the live Bridge, restarting its service, signing/installing iOS, or changing user configuration remains a separate explicit operation.

## Git-removable local session features

- “Independent” means Git-level removability, not merely placing code in separate directories. Each optional feature commit must be directly revertible from the completed branch without conflicts, and the remaining Bridge and mobile targets must still build and pass their relevant tests.
- Official-owned integration points live only in three foundation commits: the Bridge protocol/runtime seam, the composable mobile text-selection seam, and the mobile local-feature host. Feature commits opt into typed slots instead of adding unrelated branches throughout official files.
- Keep the seven commits in dependency order: Bridge seam, selection seam, mobile host, context and account usage, subagent browser, add selected text to conversation, and isolated side chat.
- Remove the complete extension stack in reverse order: the four feature commits first, then mobile host, selection seam, and Bridge seam. That full reverse chain must reproduce the official baseline tree exactly.
- A dependency on a documented foundation slot is allowed; cross-feature imports, shared feature state, and a combined hardening commit are not. Fixes discovered during review must be autosquashed into the module that owns the behavior.
- Optional local RPCs are transient and never enter canonical chat history or the offline chat queue. Errors from an older Bridge are correlated to the exact feature request and remain on the feature-local stream.
- Side Chat owns an in-memory ephemeral fork only. It is not a persisted or resumable conversation; reconnecting or creating a new child starts with an empty transcript, while filesystem changes still belong to the shared worktree.
- Context/account fallback reads and subagent history reads must remain bounded and paginated. Do not restore whole-rollout or unbounded `thread/read(includeTurns: true)` fallbacks to simplify compatibility.

## Mobile auto approval

- Auto approval is a phone-owned, Codex-only, per-conversation supervisor. It defaults off, requires the mobile app to remain running and connected, and uses only the existing live one-shot `approve` message; approvals are never queued offline and never become provider-owned `approve_always` rules.
- Persist authority by saved machine UUID, provider, and stable provider thread ID. A direct-URL fallback must remove credentials, query, and fragment. Runtime session IDs and reusable tunnel ports are not stable authority boundaries.
- The v1 allowlist is Bash, FileChange, Permissions, canonical MCP approval prompts, and ExitPlanMode. Questions, malformed questions, plugin or connector suggestions, authentication forms, unknown tools, Claude sessions, and Side Chat always remain manual. Approving ExitPlanMode starts the plan immediately.
- Reconnect processing is fail closed until a new authoritative session list arrives. Repeated requests are bounded to three attempts per connection and a 512-entry tracking cap; reaching the cap leaves new requests for manual handling.
- Settings owns an always-available offline `Disable all` action. Disabling suppresses sends immediately, then serially persists the empty allowlist; rapid and cross-session setting writes preserve tap-time identity and final intent.
- Keep the Bridge concurrent-pending fix, mobile pending-interaction restoration, and auto-approval feature in three dependency-ordered commits. Revert them in reverse order and require the final tree to equal the starting tree. Do not deploy this branch or replace the live Bridge without a separate explicit decision.
- Old iOS remains unaffected and new iOS keeps wire compatibility with old Bridge versions. An old Bridge can still start an approved plan before an overlapping command or question resolves, so matching the new iOS build with the concurrent-pending Bridge fix is required for robust unattended use.

## Mobile Codex Goal management

- Codex app-server remains the sole source of truth. Bridge and mobile use the official `thread/goal/get`, `thread/goal/set`, and `thread/goal/clear` RPCs plus `thread/goal/updated` and `thread/goal/cleared` notifications; no parallel mobile Goal store or locally invented lifecycle is allowed.
- Goal management is live-only. Reads may refresh the visible recent state, but create, edit, pause, resume, budget changes, and clear are ephemeral RPCs and are never added to canonical chat history or the offline message queue.
- Pause and clear take effect at the boundary between Goal steps and do not interrupt the currently running turn. A `budgetLimited` Goal may resume only when the same update raises the token budget above usage or removes it.
- Compatibility fields are optional and additive. New mobile advertises `goal_state_raw_status`; unknown future statuses remain visible but read-only at both UI and state-mutation boundaries. Older Bridge responses without `sessionId`, change IDs, or operation sequences are routed only when one live request owner can be identified uniquely and otherwise fail closed.
- Bridge serializes Goal RPCs per active Codex session and exposes a Bridge-local writable operation sequence for optimistic concurrency. Stable polling reads do not advance it; mutations re-read the authoritative Goal immediately before the app-server write and reject a detected conflict. This narrows, but cannot eliminate, the app-server Goal API's lack of an atomic cross-connection compare-and-set primitive.
- Permission or sandbox restarts may resume only the exact Goal paused by that restart. The lease binds thread, objective, budget, creation time, pause watermark, and nondecreasing usage counters; a cleared, replaced, or edited Goal is never resumed accidentally.
- Keep the feature in three dependency-ordered implementation commits: Bridge Goal runtime/protocol, mobile Goal state/protocol, and mobile Goal UI/localization. Remove it in reverse order and verify each remaining layer still builds and tests. Documentation may be a fourth commit.
- This branch does not replace the live Bridge or install an iOS build. Deployment remains a separate explicit decision after review and compatibility gates.

## Mobile conversation mirror

- Codex app-server history remains authoritative. The phone stores a rebuildable mirror in an independent `conversation_mirror_v1.db`; a breaking storage contract must use a new database filename rather than migrating official `ccpocket.db` or letting an older binary reinterpret newer tables.
- Mirror wire v1 is opt-in and request-driven. Requests carry `protocolVersion: 1`, responses require the negotiated `conversation_mirror_event_v1` capability, additive fields/events remain ignorable, and a breaking wire change must use v2 request/event names.
- A new Bridge emits an additive `accepted` event before long provider reads. New iOS uses a short first-frame deadline and a longer page-idle deadline; old iOS ignores the added event, while new iOS fails back to canonical history when a pre-feature Bridge cannot correlate its generic error.
- Current Bridges repeat `accepted` before every later watch transfer. When new iOS talks to a transitional mirror-capable Bridge that lacks this repeated boundary, the transfer may update the rebuildable database but is never published directly into the active runtime; canonical `get_history` performs the visible convergence.
- Read persisted history in this order: `thread/items/list`; legacy `thread/turns/list(itemsView: full)`; a validated old-parameter turns retry; then bounded post-response normalization of `thread/read(includeTurns: true)`. Cache the adapter per app-server process and thread, because one process can host both legacy and paginated conversations.
- Preserve official item and turn identity, stable client user-message IDs, and raw forward-compatible envelopes. v1 renders only user, assistant, and tool-result history; it does not promise image bytes, temporary artifact URLs, token streaming, or every transient process event.
- Never publish standalone-reader thread status into canonical mobile runtime status. A separate app-server cannot authoritatively clear a live approval, stream, or process state owned by the active Bridge session.
- Disconnecting the final watcher aborts its provider read and releases the shared semaphore. Local bootstrap must yield to preexisting canonical content, content-epoch changes, newer bootstrap generations, and service disposal.
- Keep stable provider identity and disabled registrations in neutral foundation commits. Bridge Mirror and Mobile Mirror each own one top-level, directly revertible behavior commit and must not edit the frozen composition roots. Do not merge this branch into the stable runtime or deploy it without an explicit user decision after verification.
- Freeze the compatibility matrix as follows: old iOS never opts into a new Bridge mirror; new iOS falls back from an old Bridge after a correlated refusal or bounded first-frame timeout; transitional v1 Bridge data is store-only without a transfer guard; current iOS and Bridge use guarded snapshot/patch reconciliation; old app-server history falls through items, full turns, validated legacy turns, then whole-thread read. Every unsupported path preserves canonical history and the existing WebSocket session.

## Purple particle motion, resident conversations, and native transfer gating

- High-tier Effort motion has two independent layers. Entering x-high, Max or
  Ultra plays one deterministic, finite radial arrival burst. Remaining on Max
  or Ultra runs the persistent fire; x-high does not. Max uses a distinct
  red-forward crimson palette at 35% of the original motion rate, while Ultra
  keeps the hotter purple-to-white reference palette at 70% of the original
  rate. Switching Max <-> Ultra updates front, intensity, palette and future
  phase rate without clearing the simulation or jumping its accumulated phase.
  The six wire values and model-advertised availability remain unchanged.
- The persistent fire owns one immutable, full-track 72-by-6 UV grid. Cell
  centres and dimensions derive only from track bounds. Slider movement changes
  only the simulation front and the `slider + 2%` visibility mask; it must never
  translate, stretch, compress or regenerate the grid. LTR maps increasing
  logical columns left-to-right, and RTL mirrors only the paint coordinate.
- Fire equations, delayed per-cell hash, decaying feedback, separable blur and
  tone-map constants are adapted in an isolated GPL module from Astraeus's
  `claude-range-slider` reference. The former locally invented reach/density/
  phase/advection model is retired. Max activation and its crimson-red palette
  are the explicit CC Pocket extension; Ultra retains the reference activation
  threshold and purple-white palette.
- Because field columns now use absolute logical UV coordinates instead of
  "distance from thumb", motion toward lower logical effort produces a negative
  cross-frame shift in LTR tests. Regression coverage locks grid invariance
  during dragging, long visible tail coverage, per-cell brighten/dim changes,
  RTL mirroring, Max/Ultra palette separation and bounded lifecycle cleanup.
  TickerMode and Reduce Motion suspend the fire without a hidden time jump.
- Fire performance changes must preserve the accepted equations, grid geometry
  and palettes. Cache immutable UV/hash/envelope inputs, evaluate RGB blur
  channels together, warm an already-selected tier from only the final 72
  feedback frames at the reference frame-228 clock, and cap stale-frame catch-up
  at two evaluated frames while retaining the last visible feedback buffer. The
  three glow/fringe/core layers share one cached indexed mesh and one
  `drawVertices` submission per frame; dispose each native `Vertices` object
  immediately after recording the draw.
- The active track ends 8 logical points before the thumb centre in LTR and 8
  points after it in RTL, leaving about 24 physical pixels of underlap on a 3x
  iPhone display. The persistent fire is clipped to that same active rectangle
  while its immutable 72-by-6 grid remains full-track. The thumb paints above
  the seam, so neither the fill nor glow may protrude beyond the resting circle.
- Primary-pointer down commits the selected tier and snaps the position in the
  same rendered frame; do not wait for pointer-up or Tap gesture-arena
  resolution. The one-shot reveal, colour transition and persistent fire still
  animate independently. Keyboard selection keeps the 120 ms glide, while drag
  release retains its independent 150 ms settle.
- The combined local fork is GPL-2.0-only. The original CC Pocket MIT notice is
  retained verbatim in `LICENSES/MIT.txt`, and the adapted reference keeps its
  attribution in `THIRD_PARTY_NOTICES.md` plus its module header. License
  metadata and animation behavior remain separate commits for future upstream
  reconciliation.
- A resident conversation is a policy over the existing rebuildable Mobile
  mirror, not a new Codex session type. Its identity is Bridge plus provider
  plus durable provider thread id; never persist a runtime session id. Enabling
  residency requests complete history and a watch, while disabling it stops the
  watch but keeps the phone copy unless the user separately deletes that copy.
- Resident metadata may appear on Home and in running/recent rows, but thousands
  of envelopes must not be instantiated there. Opening a complete mirror still
  publishes only the newest 200 renderable envelopes and prepends older pages
  in 200-envelope chunks. Restore only `autoSync` watches after reconnect and
  retain the Bridge's existing maximum of eight active watches.
- Both the outer running/recent list and the conversation's top-right More menu
  are first-class residency controls. An in-progress conversation is eligible;
  lack of a durable provider id may delay the operation but must not hide the
  control or persist a guessed identity.
- File transfer is advertised and requested only after the native iPhone shell
  reports iOS 15 or later and native file-transfer API v1. Missing/old native
  plugin, timeout, malformed response, exception, or unsupported iOS all fail
  closed. This protects Shorebird-style new Dart on an old native shell. Any
  auxiliary WebSocket must default file-transfer capability to false so it
  cannot impersonate a compatible phone.
- Keep the three behavior commits independently removable: `c9b472a` owns
  motion, `2ebd169` owns residency, and `5c29481` owns the native capability
  gate. Remove the documentation commit first, then those commits in reverse
  order to reproduce `d52001d^{tree}` exactly.

## Upstream mergeability and session-continuity integration

- This section supersedes the blanket interpretation of “independent” as
  “every local feature must be directly removable and the whole tree must
  reverse exactly to an official baseline.” The actual product requirement is
  that official code and local extensions keep clear ownership boundaries so a
  later official update can be merged and reviewed without the two becoming an
  indistinguishable patch. Earlier direct-revert and reverse-tree results remain
  useful historical verification, but they are not a universal acceptance gate.
- Prefer cohesive feature commits, typed extension seams, narrow edits to
  official hotspots, feature-owned tests, and a documented dependency order.
  Shared official files may still change when the behavior genuinely belongs
  there; avoid scattered feature flags, cross-feature private state, unrelated
  formatting churn, and catch-all hardening commits. During an official update,
  merge the official baseline first and then reconcile local behavior
  semantically at these bounded seams instead of replaying the local branch as
  one opaque patch.
- Direct revert is optional evidence for a feature intentionally designed to be
  removable. Do not split a coherent implementation or add adapter layers only
  to satisfy an artificial removal test. The primary update gate is that
  official changes, local ownership, conflicts, compatibility fallbacks, and
  regression tests remain separately understandable.
- Task `019f7ca9-f4bb-7983-8127-fb0ce7b92379` was integrated semantically rather
  than byte-cherry-picked because this branch already had newer file-manager,
  mirror, Fork, toolbar, and continuity work. Persisted Side Chat maps to
  `91485fe0` plus `50ac07d8`; subagent discovery/latest preview to `67fe3b15`;
  resume configuration ownership to `5770ac32` plus `5c25ff1f`; Desktop list
  activity to `f51fc32e`; and the quick-reconnect generation fence to
  `31db336e`.
- Side Chat and ordinary Fork remain separate. Side Chat now creates an
  official persisted child and reuses the complete Codex session screen; a new
  Mobile falls back to the prior isolated in-memory Side Chat only when the
  connected Bridge lacks `persisted_side_chat_v1`. This supersedes the earlier
  decision that Side Chat must always be ephemeral.
- Ordinary Fork is a message-owned action, matching the official Mobile action
  row: expose it only under each completed assistant reply beside Copy and
  Share, and fork from that reply's preceding Codex user turn. Do not duplicate
  it in the session-list context menu or the conversation-level overflow menu.
  Keep the additive persisted-fork wire contract for old/new peer compatibility
  even though Mobile no longer presents a session-level entry.
- Completion detection must cover both transcript shapes: a live Bridge turn
  normally ends with `ResultMessage`, while Desktop/app-server history may omit
  that synthetic marker. In the latter shape, the next user turn closes the
  preceding reply; a result-less transcript tail is forkable only while the
  session is idle, has no queued input, and is not streaming. Intermediate
  assistant/tool blocks remain ineligible.
- The context-window ring remains in the compact session mode toolbar through
  the `session_insights` slot. When quota windows are available, the same
  bounded entry adds labeled 5h and 7d utilization rings beside the context
  ring without creating another controller or toolbar slot. It is absent from
  the old status/top-right slot; tapping any part keeps the full insights detail
  view, and that view retains the `Compact context` action routed to the
  existing `codex_core_actions` compact request. Future upstream merges must
  preserve these invariants together.
- No item in this integration authorizes a live Bridge replacement, physical
  iPhone installation, stable-branch merge, or remote push. Those remain
  separate decisions after code and compatibility verification.

## Official 1.68 session experience and iOS file ingress

- Official Bridge 1.68.0 is integrated by explicit merge commit `a4999bce`.
  Preserve its configurable Codex-assist model and reasoning effort together
  with the existing artifact, transfer, mirror, Side Chat and Desktop
  continuity modules; future upstream work starts from this semantic merge,
  not from replaying one opaque local patch.
- While a Codex turn is running, only the unresolved newest assistant tail is
  ineligible for ordinary Fork. Earlier assistant replies remain branch points
  once a later user turn or explicit result proves their completion. Runtime
  metadata such as model, effort and continuation still hydrates session state
  but does not require a visible `System:` timeline chip.
- Historical process presentation has two independent render-only folds.
  Reasoning/tool calls/results are first grouped by the visible assistant
  update that owns them, so one long turn no longer concentrates every tool at
  a single point. Intermediate visible assistant updates and their own process
  segments then sit under a turn-level fold, while the final result stays
  visible. Expanding the turn reveals each still-collapsed process segment.
  Neither fold may discard canonical envelopes, hide image/artifact results,
  stop live accumulation or change runtime ownership. Persisted Side Chat
  reuses the same complete Codex session screen and suppresses unsupported
  actions through explicit capability parameters rather than a second chat UI.
- The Codex app-server `model/list` result carried by each authoritative
  `session_list` is the Mobile model/effort/service-tier catalog. BridgeService
  must install that metadata before publishing the matching session snapshot,
  and an already-open conversation observes catalog revisions without restart.
  The built-in model list remains only a compatibility fallback when an older
  Bridge or app-server cannot advertise a catalog.
- Home owns one bounded list-level continuity watcher for already activated
  running Desktop conversations. It stores completed user/assistant/tool
  payloads in the normal runtime cache and aggregates only bounded transient
  deltas. Opening the exact conversation transfers ownership to its watcher,
  drains the backlog and performs canonical reconciliation; old Bridges keep
  session-list/history fallback and never receive an unknown request.
- A downloaded conversation keeps its local mirror as a pageable prefix when
  canonical runtime history arrives. Canonical envelopes update overlapping
  entries and append the live tail, but they do not destroy the older-page
  cursor. The history picker queries a lightweight user-input index from the
  same active mirror generation; selecting an unloaded prompt pages backward
  until the real rendered entry is available, rather than rendering the whole
  transcript at open time.
- A single mirror envelope may exceed the original 512 KiB WebSocket event
  ceiling (most often a large tool result). New peers negotiate
  `conversation_mirror_entry_chunk_v1`: Bridge sends 256 KiB raw chunks as one
  logical snapshot page, and Mobile reassembles them under bounded memory,
  length, SHA-256, duplicate and generation checks before one atomic database
  write. Old Mobile builds keep the explicit `entry_too_large` error instead
  of receiving an event they cannot understand; new Mobile builds retain the
  original v1 path with an old Bridge.
- iOS drops reuse existing authorities. A known PNG/JPEG no larger than 20 MiB
  may remain an inline image; every other composer drop and every Home drop is
  streamed through the authenticated 15 GiB resumable transfer. Stage multiple
  drops serially, recheck free capacity for unknown sizes, sanitize by UTF-8
  byte length and never load a large file into one Dart byte array.
- A composer attachment becomes a Codex file mention only after protocol v3
  returns the Mac's saved absolute path. Old Bridge versions can still complete
  plain file transfer but cannot fabricate a chat mention; Mobile reports that
  limitation instead. Home drops are pure transport and never enter canonical
  chat or its offline queue.
- The received-file inbox is a bounded, symlink-safe view of completed files in
  the app-owned Downloads directory. First upgrade baselines existing files as
  seen; later completions persist an unread watermark. Preview reuses Quick
  Look, Share uses the platform sheet and Save to Files is native API v2, so a
  new Dart bundle on an API-v1 shell hides only Save while retaining transfer.
- Do not promise remote push for the current free/self-signed AltStore build.
  Without a paid provisioning profile carrying the APNs entitlement and a real
  Firebase/APNs project, local notification plus the durable in-app inbox is
  the supported behavior. Remote push remains a separate deployment feature.
- Keep the post-merge implementation order `0cd71b21`, `2e2fc0a7`,
  `e70bdf7e`, `705baa8c`, `eea8584a`, `4568c539`, `85d33c59`, and
  `586a6a78`. The final three commits deliberately separate transfer/storage
  foundations, drag/drop UI and received-file UI for future official updates.

## Bridge-owned automatic approval

- Mobile is only a control surface. The durable allowlist belongs to Bridge at
  `~/.ccpocket/auto-approval-v1.json`, keyed by official Codex thread ID rather
  than a transient runtime session. Bridge observes its own live Codex approval
  requests and can therefore continue supervising while every phone is
  disconnected. It cannot answer an approval owned by a separate Codex Desktop
  app-server connection; that remains under Desktop's authority.
- Auto approval is an additive, capability-gated local feature. A new Mobile
  with an old Bridge receives an unavailable control and never falls back to
  secretly approving on the phone. An old Mobile with a new Bridge retains its
  prior live-only approval behavior because Bridge does nothing until the new
  state protocol explicitly enables a thread.
- Existing Mobile-owned v1 identities are imported once only when Bridge has no
  authoritative state file. The import is bounded, bridge-identity scoped and
  idempotent; after a correlated success Mobile removes only the imported
  legacy identities. A pre-existing empty Bridge file is authoritative and may
  not be repopulated by a stale phone.
- The allowlist may approve ordinary commands, network access, file changes,
  permission expansion, canonical MCP approval forms and plan completion.
  `rm` remains human-only in direct, absolute-path, wrapper, compound, nested
  shell, `xargs` and command-substitution forms. Other clearly destructive
  executables and Git worktree-destroying operations also fail closed. User
  questions, plugin/connector installation and malformed or ambiguous shell
  commands remain manual.
- A disable request blocks visible supervision immediately and persists on the
  computer before becoming authoritative. If Mobile is offline, the emergency
  stop is queued locally and sent on reconnect; the UI must not imply that an
  unreachable computer was already changed. Multi-client updates are broadcast
  from Bridge, and Mobile waits for correlated state before treating a setting
  write as durable.

## Permission restart continuation

- `restart_now` remains the explicit immediate option; next-turn permission
  updates keep using the existing in-place admission path. Bridge interrupts a
  running turn only when it must recreate that runtime, and records whether the
  interrupt actually won the race with natural completion.
- An active Goal is paused and resumed only through its strict restart lease.
  Goal continuation and ordinary-turn continuation are mutually exclusive, so
  a replacement or externally cleared Goal is never revived as a plain turn.
- For an ordinary turn that Bridge itself interrupted, the replacement runtime
  first issues the schema-valid `turn/start` with `input: []` so continuation
  does not invent a visible user message. Only an app-server that rejects that
  request gets one compatibility fallback using the visible text `继续`.
- A naturally completed turn is not continued. If both continuation attempts
  fail, Bridge reports `permission_restart_continuation_failed` and leaves the
  replacement runtime idle and usable instead of destroying it or retrying an
  unbounded number of times.
