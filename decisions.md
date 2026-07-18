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
