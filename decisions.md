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
