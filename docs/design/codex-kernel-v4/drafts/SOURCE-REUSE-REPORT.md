# Source Reuse Disposition Report

## Scope and result

This is a read-only source-fact audit for the v4 two-stage design. The audit target is the worktree `/Users/developer/AI agent/Codex/_keep/projects/ccpocket-worktrees/ccpocket-v4-design-source-reuse-20260830`, branch `codex/v4-design-source-reuse-20260830`, at `d152b118045264abeb8a1760b94113e323e46283` (`docs(design): initialize Codex kernel v4 local design baseline`). The source-reuse table covers all 52 capability IDs, K-001 through K-026 and P-001 through P-026.

`SOURCE-REUSE-DISPOSITION.csv` records a candidate disposition only. `KEEP`, `ADAPT`, `REWRITE`, and `DELETE` are implementation vocabulary for the root coordinator to reconcile; they are not an architecture decision or an authorization to change source. No source, native, configuration, test, or other document was changed in this audit. No service was started, no port 8765 was touched, and no test, build, release, install, or publish operation was run.

Static checks found 52 data rows, 9 CSV columns, and zero missing paths across the current-to-target map's Bridge, Mobile, native, and representative-test path sets. No whole capability is marked `DELETE`: all 52 visible capabilities remain in scope under v4, while the `REWRITE`/`ADAPT` notes identify obsolete writers, fallback routes, or duplicated owners that may need deletion after a root decision.

## Evidence boundary

The evidence order used here is: current source and native files, symbol/call-site search, representative test-file existence, then the supplied design maps and capsules. A source path proves that code exists in this checkout; it does not prove that the code is the active runtime, that a Bridge is listening, that a provider app-server accepts a method, or that a device/native entitlement works.

Evidence levels in the CSV are deliberately uniform:

- `E2_STATIC_RG_TEST_PATHS` means the current path and representative test paths exist and the named symbols/seams were checked with `rg`; tests were not executed.
- `E3_STATIC_RG_TEST_PATHS_NATIVE` means the same static evidence also includes a native host file.
- `CODEGRAPH_UNAVAILABLE` means the target project was not indexed and the CodeGraph call returned no project index. The package's CodeGraph map remains a structural reference only.
- `RUNTIME_NOT_RUN` means there is no live-process, provider, database, Flutter, simulator, device, or native runtime claim in this audit.

The CSV map-path check was run in the target worktree with Ruby `CSV`: every current Bridge, Mobile, native, and representative-test path in `CAPABILITY-CURRENT-TO-TARGET-MAP.csv` resolved to an existing filesystem path. The same parser verified 52 data rows, nine fields per row, and only allowed disposition values. `git diff --check` is a required final gate after these two draft files are committed.

## Hotspots and reuse evidence

| area | current seam and static evidence | reuse implication |
|---|---|---|
| Bridge composition and protocol | `packages/bridge/src/websocket.ts:1767` defines `BridgeWebSocketServer`; connection handling is at `:5690`, the large client-message dispatch at `:6009`, and direct Codex input dispatch sites include `:6962`. | This is a high-coupling route/auth/envelope/lifecycle hotspot. Existing envelope and authentication behavior can be characterized, but new kernel owners should not be copied into the switch or left as parallel route-owned terminals. |
| Session lifecycle and history mutation | `packages/bridge/src/session.ts:454` defines `SessionManager`; history append paths are `:1658` and `:1868`, and queued structured input reaches a process at `:3096`. | Reuse lifecycle effects and queue/receipt evidence through typed ports. Do not preserve an implicit second history writer or infer provider facts from Mobile reducers. |
| Provider I/O and bounded reads | `packages/bridge/src/codex-process.ts:733` defines `CodexProcess`; read-only RPC is `:2414`, `readThread` is `:2430`, turn/item page reads are `:2607`/`:2632`, and structured input is `:3197`. | This is the strongest current Codex provider I/O seam for K-001/K-005/K-008/K-015/K-019/K-022/K-026. The actual provider process and method behavior remain unverified because runtime was not started. |
| Catalog and archive | `sessions-index.ts` supplies JSONL/index/history projections; `session-catalog-monitor.ts:98` defines `SessionCatalogMonitor`; `archive-store.ts` owns archive identity and state. | Reuse bounded scan/index/archive behavior as characterization. Converge catalog writes behind one source-scoped repository; do not retain v2/legacy refresh writers. |
| Live and operation safety | `input-delivery-ledger.ts:175` defines the Bridge admission/receipt ledger (`admit` at `:311`, provider outcome at `:455`); `codex-action-broker.ts:281` and `codex-action-broker-runtime.ts:115` provide action request state, subscriptions, and leases. | These are reusable safety facts for operation admission, idempotency, `OUTCOME_UNKNOWN`, and interaction claims. Actor provenance and the single writer still require root reconciliation. |
| Mobile transport and cache | `apps/mobile/lib/services/bridge_service.dart:474` defines `BridgeService`; history delta handling is `:3727`, generic send is `:4283`, ephemeral RPC is `:4513`, offline enqueue is `:4538`, and flush is `:4878`. `session_catalog_cache_repository.dart:384` owns the large local catalog/timeline cache. | Preserve connection/readiness, queue visibility, cache rebuild, and last-good behavior, but separate transport from canonical timeline reduction and protect local namespaces. |
| Mobile session projection | `apps/mobile/lib/features/chat_session/state/chat_session_cubit.dart:237` defines `ChatSessionCubit`; message intake is `:4774`, state merge is `:5344`, and send is `:8020`. `messages.dart` contains the broad wire/domain model and `chat_message_list.dart:1036` owns the principal list widget. | Existing renderers and interaction effects are valuable reuse evidence. The Cubit/model combination is a high-risk duplicate-owner seam for K-005/K-012/K-014/K-022/K-026 and needs typed boundary work rather than file-level copying. |
| Content, file, and native hosts | Bridge `FileTransferManager`, `ArtifactManager`, `ArtifactStore`, `FileBrowserManager`, and related HTTP/state stores are path-verified. Mobile has file-transfer storage/service, artifact preview/access, gallery/image screens, and native `FileTransferPlugin.swift`, `ArtifactQuickLookPlugin.swift`, and `FileMutationAuthPlugin.swift`. | Keep the independent content plane, bounded transfer, opaque refs, Quick Look, and operation-bound mutation authorization. These must not become a generic Session Kernel byte store or a connection-auth shortcut. |
| Product-platform services | Machine/route, discovery/SSH, readiness, background, notifications, permissions, updates, voice, icons, commerce, shell, localization, mobile host, motion/status, and cache-management paths all exist per map check. | These are mostly isolated feature owners. Their adapters may be retained or narrowed, but source existence does not establish launchd, device, entitlement, or store behavior. |

## Shared symbols and call seams

The following symbols are the most consequential reuse points found by source search:

1. `BridgeWebSocketServer.handleConnection` -> `handleClientMessage` -> `SessionManager`, `CodexProcess`, `InputDeliveryLedger`, action broker, file/artifact managers, and push/projector helpers. It is the largest shared route seam and the principal duplicate-owner risk.
2. `SessionManager` provider event listeners -> `appendHistoryToSession` -> history/list/status emissions. This is current lifecycle/history evidence, not proof that its in-memory history is the durable provider authority.
3. `CodexProcess.requestReadOnlyRpc` -> `readThread`/`listThreadTurns`/`listThreadItems`, and `sendInputStructured` for provider dispatch. This separates bounded provider reads from the current route and should be the reusable Codex-side seam.
4. `InputDeliveryLedger.admit`/`recordProviderOutcome` and `CodexActionBroker` claim/submit/resolve methods form two related but distinct safety families. The root must decide their exact operation/interaction ownership before integration.
5. `BridgeService.send` -> ephemeral RPC/offline queue/flush and `ChatSessionCubit._onMessage` -> `_applyUpdate` -> `sendMessage` form the transport-to-projection path on Mobile. Existing pending/canonical behavior should be characterized, not duplicated.
6. `SessionCatalogCacheRepository` is consumed by session list, conversation sync, diagnostics, and cache management. Any clear or rebuild implementation must preserve draft, queue, credential, settings, and transfer namespaces.
7. `ArtifactManager`/`ArtifactStore`/`ImageStore` and `FileTransferManager`/`FileTransferStateStore` are independent resource/content seams. Their current IDs, tickets, ranges, digests, and expiry behavior must not be collapsed into timeline identity.
8. Native hosts (`NotificationActionHostPlugin`, `ArtifactQuickLookPlugin`, `FileTransferPlugin`, `FileMutationAuthPlugin`, `PermissionHostPlugin`, background plugins, and `MobileHostSnapshotPlugin`) are platform seams. Their source paths are evidence of an implementation surface only; device callback, entitlement, and lifecycle behavior are unknown.

## Unknown runtime facts

The following facts remain intentionally unknown and require live verification in later, authorized gates:

- Which Bridge process, launch configuration, working tree, environment, and listener (if any) is active; port 8765 was not inspected or touched for this task.
- Whether the Codex app-server/provider currently supports the read, settings, Goal, action, and thread/item methods represented by `CodexProcess` and whether returned IDs/order/timestamps satisfy the source assumptions.
- Whether the active provider durable history, JSONL index, SQLite/cache data, and current source identity agree; no session, database, cache, migration, or real history was opened.
- Whether Mobile `BridgeService`, Cubits, cache repositories, notification paths, background paths, and router are the active built bundle and how they behave after reconnect, source switch, restart, or delayed events.
- Whether iOS native plugins, entitlements, Secure Enclave/biometric behavior, Quick Look, background deadlines, notification actions, file access, and capability snapshots work on a real simulator/device.
- Frame timing, reduced-motion, RTL, memory, large-file behavior, and actual 15 GiB transfer behavior for P-006/P-009/P-025.
- Build/test status, generated localization status, dependency versions, and release-artifact/install/store state; none was run or inferred.

## Conflicts requiring root decision

These are explicit reconciliation points, not decisions made by this worker:

1. **K-001/K-006/K-007:** current v2/Mirror and continuity paths contain useful last-good, live, gap, and fixture behavior, while the fixed v4 lock prohibits retaining them as runtime writers. Root must choose the exact behavior-preserving extraction boundary.
2. **K-002/P-001/P-003:** Bridge/source identity, computer grouping, route selection, mDNS, and SSH records overlap in current seams. Root must prevent route/IP identity while preserving independent route UX.
3. **K-005/K-014/K-022:** the giant WebSocket switch, broad `messages.dart` model, core-action feature, and operation broker overlap. Root must assign each typed operation/timeline/interaction owner before editing.
4. **K-012/K-013/K-014:** Bridge admission/receipt, Mobile pending UI, offline outbox, and generic action terminals currently cross transport and projection. Root must define ACK-loss, `OUTCOME_UNKNOWN`, queue revision, and restart ownership.
5. **K-015/P-025:** authoritative settings/ACK and effort mapping are coupled to presentation motion/fire/status. Root must keep the slider renderer presentation-only while choosing the exact settings adapter seam.
6. **K-016/K-017:** interaction broker writer leases and auto-approval policy both touch permission/approval behavior. Root must assign actor, policy, claim, timeout, and audit ownership to one coherent path.
7. **K-018/K-019:** provider Goal, Plan timeline, collaboration settings, and ExitPlan interaction are currently adjacent in UI/core-action seams. Root must retain the fixed distinction without creating a second product-document authority.
8. **K-020/K-021:** persisted/ephemeral Side Chat and subagent child conversations must remain visible product effects while legacy writers/timeline/catalog paths are removed. Root must define relation and cleanup ownership.
9. **P-008/P-009/P-010/P-024:** mutation authorization, artifact refs/content, Quick Look, and native capability snapshots share content/platform boundaries. Root must keep step-up authorization and opaque resource access separate from connection auth and session identity.
10. **P-022:** the current router still has a Claude path according to the source map, while the fixed lock requires an unreachable typed unfinished seam. Root must inventory and remove every reachable route/runtime/UI path in a later authorized change.
11. **P-026:** cache-management clearing crosses catalog, timeline, local composer, operation queue, credentials, settings, and transfer checkpoint namespaces. Root must approve a namespace ledger before any clear behavior changes.

## Gate status

| gate | status | evidence |
|---|---|---|
| Capability coverage | PASS | 52 CSV data rows, K-001..K-026 and P-001..P-026 |
| Current-map path existence | PASS | 0 missing Bridge/Mobile/native/test paths |
| CSV parse/shape | PASS | Ruby CSV parsed 52 rows, 9 fields, allowed dispositions |
| Source/static symbol audit | PASS | Target checkout searched with `rg`; representative seams recorded |
| CodeGraph | NOT_AVAILABLE | Target project not indexed; package map treated as structural reference only |
| `git diff --check` | NOT_RUN | Must run after final report edits, before commit |
| Bridge/provider runtime | NOT_RUN | Explicit task boundary; no service or port 8765 |
| Flutter/native/device/E2E | NOT_RUN | Explicit task boundary |
| Build/release/install/publish | NOT_RUN | Explicit task boundary |
