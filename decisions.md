# ccPocket Compatibility Decisions

## 2026-07-25 comprehensive remediation execution

- `plans/mobile-comprehensive-remediation_v01_20260725-012458.md` 是 build 202
  已完成阶段的 accepted requirement/implementation/validation ledger，不得把
  它改写成“当时没有做过”。
- build 202 真机反馈后的 active investigation/draft 是
  `plans/mobile-comprehensive-remediation_v02_20260726-004125.md`。它补充连接
  门禁、真正非模态悬浮窗、会话状态/缓存、紧凑时间戳、统一过程框、目录同步、
  durable view 与 runtime attach 分离，以及 Cockpit 多 Home 权威边界。用户
  确认前只调查和设计，不授权业务实现；正式实施仍须按当时 HEAD 重新取证。
- 实施基线必须先语义合并官方
  `upstream/main@aa215a3b98a8035cba0e6bdd8005803f76041d66`
  （Mobile `1.109.2+201` / Bridge `1.69.4`）或开工时更高的官方 HEAD，再保留
  本地兼容行为。官方 session resume、image restore 和 app-server 加固不得被
  本地整文件覆盖。
- 本地 opt-in Always Location notification-only 方案是 owner 兼容栈功能，
  不是官方功能，也不是 APNs 等价物。它在用户显式授权、存在 active work、
  新基础 IPA 和新 Bridge 均具备 capability 时才可工作；iOS 回收或 force-quit
  后仍依靠前台增量追平。此前“不要用 location”的一般后台同步决定不再用于
  禁止这条用户明确选择的 owner 可选通知路径，但普通后台同步仍不得伪称永久
  daemon。
- 持久 Side Chat 产品方向废弃。后续只接官方 app-server 支持的临时
  thread/fork 生命周期，并复用现有原生前端；不从脏的
  `feature/mobile-session-tools` 工作树带入另一套持久会话实现。
- 固定 UI 与确定性错误继续中文化；本轮不加入运行时翻译模型、云翻译 API 或
  自动翻译 provider 内容。旧系统通过显示原文保持兼容。

## 2026-07-26 conversation catalog and durable-view audit directions

- 本节是
  `plans/mobile-comprehensive-remediation_v02_20260726-004125.md`
  第二轮静态审计形成的实施门禁，不是业务代码已经完成或已获发布授权。真正开工
  时必须在当时 HEAD、最新官方 upstream、真实 Bridge 事件线和真机上重新验证。
- 首次进入会话首页的 readiness 是复合事实：当前 transport、当前 connection
  epoch 的 runtime snapshot，以及同 machine/source/filter 的可用持久 catalog
  或权威 catalog response。不得用固定 1～2 秒延迟，也不得先展示整页
  `(no description)`。
- recent catalog response 必须作为一个原子 envelope 提交；rows、query key、
  request/generation、revision/cursor、scope、tombstone 和 health 不得再从
  stream payload 与“最后一份全局 message”分别读取。目录 identity 必须包含
  machine/Bridge、source Home、provider 和 durable session ID。
- `SessionCatalogRepository` 是持久目录唯一写入者。断线结束 flights 并标记
  stale/degraded，但不清用户筛选和同目标缓存；authoritative empty、delete、
  archive、move 和 project exhaustion 都有独立语义。Cockpit/`CODEX_HOME`
  必须通过显式 source registry 接入，不能继续硬编码普通 Home 后把两套记录按
  raw session ID 合并。
- 阅读 durable conversation 与 provider runtime attachment 分离。点开先以
  durable identity 展示 catalog + local hot/full content；发送、审批或需要 live
  provider 行为时才 attach。runtime ID 变化不能替换页面 identity，也不能清掉
  草稿、锚点、未读或 disclosure 状态。
- `HistorySyncArbiter` 每个 durable conversation 同时只允许一个 provider
  history flight。interactive 可升级 background flight；后来的低优先级
  delta-only 请求不得取消已经确认的 interactive fallback 权限。新协议回显
  request/generation；旧 Bridge 每会话串行且有 deadline，unscoped capability
  error 不得触发所有 pending 会话的 full-history fallback。
- 普通“一键清理缓存”只删除明确列出的可重建 catalog/hot/tool/preview caches，
  不删除完整下载副本、草稿、未发送队列、凭据、设置和传输断点。Settings 的
  “已下载会话历史”逐项管理复用现有 Conversation Mirror
  `removeLocalCopyTarget()` 删除/取消链路，并列出包括暂停 auto-sync 在内的全部
  full copies；不另写一套删除 SQL。
- 消息时间由 semantic row/bubble/disclosure 持有，不再由
  `ChatEntryWidget` 在每个 entry 顶部插入独立全宽时间行。tool/process 摘要时间
  位于 chevron 左侧；无法内嵌的中间文本使用最小间距标签；approximate provenance
  保留。
- 当前回合只有一个 stable-turn process surface。expanded 时 thinking、tool、
  result 和 guardian 都在同一有边界、最多约八个紧凑工具行高、内部可滚动的
  viewport；collapsed 时当前进度才显示单行摘要。`live:`/`entry:` 渲染来源不得
  再成为 expansion identity。
- `plans/mobile-comprehensive-remediation_v02_20260726-004125.md` 的
  v02-014 是当前全需求覆盖账本。v01 保留为 build 202 的历史实施记录；用户反馈
  与 v01 旧合同冲突时采用 v02 最新语义，不能以旧 commit/test 通过拒绝重开问题。
- 当前要求是“一键清理可重建缓存 + 完整下载历史逐项删除”。普通清缓存不得删除
  full copies；本轮也不默认提供“清除全部已下载历史”。以后若新增批量删除，
  必须重新确认 destructive scope，并使用批事务而不是循环触发逐项 vacuum。

## 2026-07-28 stable Bridge identity across connection routes

- `Machine.id` 继续表示一条连接路线，保存 IP/域名、端口、TLS、API key、SSH
  与跳板配置；不得因为多个地址连到同一台电脑就删除或物理合并 Machine。
- Bridge 数据身份使用认证后 `session_list` 返回的持久
  `bridgeInstanceId`，Codex 会话缓存再叠加 `codexSourceId`。硬件序列号、MAC
  地址和 `IOPlatformUUID` 不进入协议，也不作为授权凭证。
- 保存到 Machine 的 Bridge/source 只用于下次连接前预热 canonical cache。
  readiness、写操作和离线消息重放仍必须等待当前 socket 的权威
  `session_list`；身份不匹配时切换分区，旧 Bridge 不返回身份时清除旧提示并按
  route 隔离。
- 离线持久 mutation 使用 v2 identity envelope，记录 route、Bridge 与 source。
  WebSocket ready 本身不得触发重放；只有权威身份匹配才可发送。同一 Bridge 的
  不同 IP 可以恢复队列，不同 Bridge 或不同 Codex Home 的队列保留但不误发。
  无身份的旧 v1 队列只迁移保存，不自动重放。
- `list_sessions` 等启动请求和首次连接中尚未绑定 canonical identity 的只读请求
  可在 WebSocket ready 后按当前 route 发送，避免旧 Bridge 或测试宿主因等待
  `session_list` 形成死锁。已经带有旧 Bridge/source 身份的数据请求仍等待当前
  握手确认；显式切换 route 时丢弃旧 route 的非持久请求，不削弱上述 mutation
  重放门禁。
- `logicalConnectionIdentity` 保持 transport/readiness 身份，不能在握手中途替换
  为 Bridge UUID，否则会破坏后台重连对 `machine:<UUID>` 的解析和 connection
  generation 门禁。
- 本节只授权隔离分支内的源码与自动验证，不等于合入稳定分支、替换运行中
  Bridge、发布 OTA、签名 IPA 或安装真机。

## 2026-07-29 Mobile application-readiness watchdog

- `WebSocketChannel.ready` 只代表 transport 可写，不代表当前 Bridge/source 已
  认证，也不代表会话目录可用。交互模式下每个新 socket 由 `BridgeService`
  自己发送一次 `list_sessions`，不得依赖某个页面生命周期回调恰好触发。
- 当前 epoch 的 authority 请求实际写入 socket 后启动 10 秒看门狗。超时必须先
  推进 connection epoch，再关闭旧 socket、保留一份只读 authority 请求并按既有
  指数退避重连；旧 socket 的迟到 frame/onDone 不得满足或破坏新连接。
  `_reconnectAttempt` 只有在权威 `session_list` 成功解析后才归零，单纯 Upgrade
  成功不能把连续半开连接伪装成多次独立成功。
- 同一 epoch 已有 authority 请求在等待时，重复 `list_sessions` 合并为一次。
  旧 Bridge 不返回 `bridgeInstanceId`/`codexSourceId` 时仍以 legacy
  `session_list` 完成 readiness，不新增 capability 或 wire 字段。
- `notifications_only` 后台连接不请求完整 `session_list`、不启动 authority
  看门狗，也不记录每个后台 frame；恢复 interactive 后先发送模式切换，再恢复
  authority 请求，保持后台轻量投递和功耗边界。
- 手机诊断沿用 Debug 页的 Talker 内存日志，最多保留 1000 条。连接日志只允许
  epoch、事件/消息类型、字节数、耗时、计数、重连原因和错误类别；不得写 URL、
  token、主机地址、会话正文/标题、项目路径或 raw payload。目录 bootstrap 只记
  generation、布尔 readiness 与 bounded recovery action；每个连接普通 frame
  诊断最多 32 条，避免调试本身放大流式负载。
- 本节只授权隔离分支源码与自动验证；新的物理 build、签名 IPA、安装、OTA、
  stable 合并及 Bridge 替换仍是独立门禁。

## 2026-07-28 repository single-line convergence

- 当前唯一源码收束线是
  `fix/mobile-comprehensive-source-closure-20260728`。收束源码 HEAD
  `e4b8118c` 时，当日 109 个 ref 可达 CC Pocket 提交均为其真实祖先。
- 官方 `upstream/main@82962136` 通过 `563bcedd` 接入真实血缘；官方导航行为
  继续使用当前来源身份/嵌入式工作区语义下的适配提交 `c2cc8379`，版本保持本地
  单调递增的 `1.109.3+205`。
- 稳定 Bridge 身份原分支通过 `509afe71`、共享 Codex 来源原分支通过
  `df1d821d` 登记为真实祖先。两次 merge 不改变当前源码树，因为有效行为已经
  分别由 `fac56c47` 和 `8aabde45 → 170621dd → 0e6d2525` 适配。
- 旧 v02 脏工作树只提取当前线确实缺少的外部深链来源身份，形成
  `b20d2d01`；不复制旧的冗余 `resolve_session_link` wire 字段。旧
  `feature/mobile-session-tools` 的 modal/持久 Side Chat 不恢复，当前官方
  ephemeral + 原生会话 UI + 非模态 floating dock 继续作为产品合同。
- 两个脏工作树、旧分支和 review worktree 原样保留。源码收束不授权删除、
  stable merge、push、Bridge/Cloud 部署、签名 IPA、物理设备安装或 OTA 发布。
- 完整提交台账、冲突处置、自动验证和未授权门槛见
  `plans/repository-branch-convergence_v02_20260728-222804.md`。

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
- Agent path extraction, Bridge artifact mapping, the shared `ArtifactPreviewScreen`, and Flutter-owned share/download already exist; extend these seams instead of rebuilding them.
- On iOS, use the existing narrow system Quick Look adapter as the first preview route for every artifact that the current OS reports through `QLPreviewController.canPreview`, including JSON when the system recognizes it as `public.json`/`public.text`. Reuse the authenticated, bounded artifact download into app-temporary storage; validate that the native path remains inside the app home directory; keep the file until the native dismissal callback; then remove it.
- If Quick Look reports unsupported or cannot start, fall back automatically inside the same screen to the bounded local renderer. The local renderer owns text/code, JSON, XML, YAML, CSV, logs, DOCX and future explicit adapters; unknown binary files show metadata plus the existing share/download actions. Do not upload files to an external preview service, duplicate the preview page, or move this behavior into the Bridge protocol.
- Fixed Mobile UI strings use the existing ARB/feature localization system and a small reviewed product glossary; do not run fixed controls through runtime machine translation.
- Dynamic user-facing English warnings and explanations may use Apple Translation on supported systems, must preserve accessible source text, and must exclude commands, code, paths, payloads, identifiers, and secrets. Unsupported older systems remain compatible and show the source text; do not add ML Kit or a cloud translation fallback.
- The consolidated implementation reference for owner full-disk read, unified preview, file-mutation step-up authorization, UI localization, and Apple on-device translation is `docs/owner-file-access-preview-and-local-translation-plan.md`. It is intentionally provisional at code level and must be revalidated against the actual integration baseline before implementation.

## Mobile background conversation sync

- Background sync extends the existing Flutter runtime and WebSocket; it is not
  a permanent daemon. An active turn receives one finite
  `UIBackgroundTask`, followed only by opportunistic `BGAppRefresh` work that
  iOS may delay or omit. Process reclamation and force-quit converge through
  the next foreground catch-up.
- The default finite-sync path must not use audio, location, VoIP, or another
  unrelated background entitlement to prolong execution. The later optional
  notification-only extension is the sole location exception: it requires
  explicit Always Location authorization, never consumes coordinates, and may
  not synchronize conversation data while backgrounded.
- Native capability negotiation uses additive
  `backgroundContinuation` and `backgroundRefreshWarmRuntime` keys. The latter
  explicitly does not promise a cold/headless Flutter engine; such an engine
  would require a new capability and a separate compatibility review.
- Background history is cached-delta-only. An old Bridge rejection must never
  fall back to an unbounded full transcript while backgrounded; ordinary
  foreground reconciliation retains the compatibility fallback.
- Rapid lifecycle changes are generation-fenced. A resume must cancel and end
  the active continuation before restoring resident watches, and a cancelled
  resume must retain its pending foreground catch-up for the next definite
  resume.
- Conversation Mirror remains optional and rebuildable. Background work may
  sync an existing watch but may not restore a missing watch or begin a large
  first snapshot. Deadline and lifecycle cancellation must release the
  underlying pending request and reject late frames.
- The native plugin, Xcode registration, `Info.plist`, and capability snapshot
  require a new base IPA. Later Dart-only tuning may use the `owner` OTA track.
  This branch does not publish, install, promote to `stable`, replace the live
  Bridge, or change behavior on an already installed phone by itself.
- The detailed compatibility matrix, bounds, and physical-device acceptance
  gates are maintained in `docs/mobile-background-sync.md`.

## Optional background local-notification keep-alive

- This section supersedes the earlier blanket location prohibition only for the
  explicitly enabled notification-only extension. The existing finite
  continuation and `BGAppRefresh` behavior remains the compatibility fallback.
- Mobile may pre-arm a coarse location lease during the iOS inactive transition
  only when a task is active and every native, Bridge, permission, power and
  thermal gate passes. Coordinates must never be read, stored, logged or sent,
  and the iOS background indicator must remain visible.
- Once backgrounded, the Bridge socket is either `notifications_only` or the
  feature is considered unavailable. Both Bridge and Mobile independently drop
  full stream, history, Mirror, file and tool payloads; a warm `BGAppRefresh`
  must not reintroduce background conversation synchronization.
- Task completion, user disable, foreground resume, Low Power Mode, serious
  thermal pressure, permission loss, location error, or a two-minute Bridge
  disconnect stops the native lease. Intermediate progress remains opt-in and
  rate-limited.
- Foreground restoration must request `interactive` delivery before watches,
  session lists or history. Canonical history remains authoritative and the
  existing sequence-based reconciliation fills the background gap.
- The native host and `UIBackgroundModes/location` require a new base IPA.
  `permissionHost` v3 adds `locationAlways`, while Dart keeps v2 as its minimum
  so existing permissions on old base IPAs continue to work. The additive
  Bridge capability is `background_notification_delivery_v1`; old clients
  never opt in and new clients fall back when it is absent.
- Detailed ownership, privacy, compatibility and physical-iPhone gates live in
  `docs/mobile-background-notification-keepalive.md`.

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

- Backend-first delivery is the default for this compatibility fork. Codex and
  Claude protocol drift, session-state authority, stream/history normalization,
  replay deduplication and provider lineage extraction belong in Bridge whenever
  an already-installed Mobile can consume the existing wire shape. Mobile is a
  cache and presentation surface, not a second source of canonical truth.
- A correctness or compatibility fix must not require a new IPA merely because
  it is convenient to implement in Flutter. Bridge should capability-negotiate,
  omit or down-convert additive messages for older clients and keep their legacy
  history/session flow usable. Mobile releases are reserved for behavior that is
  inherently local: visible controls and rendering, local-database paging, iOS
  native integration, or a genuinely new client protocol. Batch those changes
  instead of coupling them to every Bridge rollout.
- The locally sideloaded IPA is not assumed to participate in the official
  Shorebird release/patch channel. Until a separately owned and verified OTA
  release chain exists, Dart changes in this fork still require a rebuilt IPA;
  native Swift/plugin changes always require a new base release.
- Backend-first is a delivery architecture, not merely a rule to move individual
  bug fixes into Bridge. The long-term Mobile target is a stable Dynamic
  Capability Host: Bridge can publish versioned declarative manifests for
  navigation entries, allowlisted UI components, state bindings and typed RPC
  actions, while the installed app validates and renders them with pre-shipped
  Flutter/iOS primitives. Unknown components, actions or schema versions fail
  closed and fall back without destabilizing chat.
- Do not use the Bridge protocol to download arbitrary Dart or native executable
  code. Evolve the host's Dart implementation through a separately owned
  Shorebird app/release channel, never the official CC Pocket `app_id`; reserve
  a rebuilt and re-signed base IPA for Swift/plugin, entitlement, Flutter-engine
  or other native-runtime changes. The free Apple profile's seven-day AltStore
  refresh remains a separate requirement from delivering feature updates.
- The base iOS host exposes permission API v1 for notifications, camera,
  microphone, speech recognition, local network and system file selection.
  Loading a manifest or launching the app may inspect status but must never
  trigger a prompt; only a deliberate in-app user action may request access.
  Unknown permission identifiers and newer native API requirements fail closed
  as an app-update requirement. Local-network and file-picker access remain
  explicitly system-managed because iOS exposes no trustworthy persistent
  grant query for those flows. Do not predeclare speculative location,
  contacts, Bluetooth or photo-library permissions before a concrete feature
  requires them.
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
- A visible intermediate assistant update, reasoning segment, or tool preface is
  not by itself a completed reply. Do not infer completion merely because a
  later `AssistantServerMessage` exists in the same user turn. The current Fork
  wire contract carries the preceding Codex user-turn ordinal, not an
  assistant-item identity; until an item-level backend contract exists, Mobile
  must not present reasoning or intermediate progress as an item-level branch
  point. Parent and child histories may legitimately share the inherited
  prefix, but branch lineage must be identified by provider thread IDs and
  `forked_from_id`, never collapsed or explained by matching titles/previews.
  Diagnose and repair presentation/runtime state without rewriting or deleting
  the canonical rollout files.
- Branch lineage is an additive compatibility contract. Bridge normalizes the
  provider's `forkedFromId` / rollout `forked_from_id` to
  `forkedFromThreadId`, retains the transient Bridge parent separately as
  `forkedFromSessionId`, and preserves both through session-list publication
  and runtime replacement. Mobile treats both fields as optional: a new client
  with an old Bridge renders the old list unchanged, while an old client safely
  ignores the new fields. The visible Fork badge is presentation only and may
  not participate in history identity or deduplication.
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
- Desktop rollout response items use
  `internal_chat_message_metadata_passthrough.turn_id` as canonical turn
  identity when the top-level field is absent. This keeps assistant and tool
  events attributable during overlapping or orphaned task lifecycles instead
  of suppressing them until the conversation is reopened.
- A successful Bridge runtime rehydrate sends an additive v1 idle state with
  `historyReady: true`. Mobile performs canonical history reconciliation only
  after that signal, with one delayed fallback for an older Bridge. Older Apps
  ignore the field but still benefit from the repeated idle state. A
  `runtime_rehydrate_failed` event is advisory and must not release the live
  watch; silent or transient watch setup failures retry with bounded backoff.
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

## Mobile OTA host and two-track update policy

- The installed IPA remains a versioned native host. `MobileHostSnapshot v1`
  advertises bounded native capability versions, while Dart OTA code and Bridge
  diagnostics consume only additive optional metadata. Missing capabilities
  fail closed and require a new base IPA; old Mobile and old Bridge behavior is
  otherwise unchanged.
- `stable` is the default channel. The local owner device may unlock `owner` by
  tapping the version seven times; the unlock and selected channel live in iOS
  secure storage. Changing channels affects future checks only and must never
  pretend to downgrade an already installed patch.
- Manual checks always bypass the six-hour automatic throttle and never begin a
  download without a second user action. Automatic and silent modes may check
  and download in the background; silent mode suppresses the restart prompt.
  The public Shorebird SDK does not expose the remote patch number before the
  download, so the UI identifies the checked track first and shows the concrete
  patch number once it is available locally.
- The repository must not reuse the upstream Shorebird app id. Until the owner
  logs in and runs `shorebird init`, `shorebird.yaml` keeps a rejected placeholder.
  Base releases and owner patches require RSA signing; native, entitlement,
  plugin, asset, Flutter/Xcode and native-dependency changes require a new base
  IPA. Stable promotion requires the explicit `--confirm-stable` gate and user
  approval after physical-iPhone validation.
- The update implementation originated in the `feature/mobile-ota-host`
  lineage. Personal app binding `52ac916e`, permission-host v2 `b55c5cb1` and
  release build `242c98d5` established `1.107.2+199` as the previous native
  baseline candidate, including photo-library and biometric permission
  surfaces without speculative unrelated permissions.
- The unified `1.108.1+200` integration adds the native background-sync host
  and therefore supersedes build 199 as the next base-IPA candidate. It must
  be built, signed, installed and accepted on the physical owner iPhone before
  any owner patch or stable promotion. Merging source does not publish a
  Shorebird release, deploy a backend, install an IPA or change the phone.

## Full conversation storage and bounded turn navigation

- A downloaded conversation is durable local data, not permission to mount the
  entire transcript in Flutter. Bridge and Mobile accept up to 100,000
  normalized entries / 64 MiB per conversation, while the ordinary live
  render surface remains a 200-entry window.
- The History picker indexes every non-synthetic user turn from the complete
  local mirror, including turns outside the rendered window. Each index row
  carries its stored ordinal internally so selecting a distant turn can read
  the 200-entry window beginning at that turn directly.
- A distant selection keeps the picker visible behind a blocking loading
  indicator. Mobile swaps in the target window only after the database read
  completes, then performs the scroll; it must not progressively mount every
  intervening page. Older drag paging continues immediately before the newly
  selected window, and another History selection may jump to any newer or
  older turn even when `hasMore` is false at the current window.
- `bounded_history_window_v1` is an additive client capability. A new Bridge
  sends only the latest 200 canonical entries to an opting-in Mobile; legacy
  clients continue receiving the prior full response. A new Mobile also bounds
  an unbounded legacy Bridge response locally, while the complete mirror
  remains available through its independent download path.
- The implementation is split across `ca427a89` (Bridge full download and
  capability), `d33aa31c` (Mobile storage/render window and indexed target
  loading), and `253c1ab3` (shared History loading UI).

## Codex Desktop image-reference restoration

- Codex Desktop `view_image` history is a structured tool exchange: the call
  carries the local path and the result may carry an `input_image` data URI.
  Bridge must preserve that structure instead of stringifying the image block
  into transcript text.
- Prefer the lightweight local path when it is still readable. When only
  inline data is available, Bridge registers it in the existing bounded
  `ImageStore` and sends only an opaque `ImageRef`; raw base64 never crosses
  the client protocol.
- This is an additive conversion on the existing tool-result and image-ref
  model, not a protocol-schema fork. Older clients and Bridges retain their
  previous behavior, while the Mobile companion change ensures an
  image-owning result is not discarded merely because the corresponding tool
  call also has a summary.
- Collapsed tool results do not build or fetch their image preview. The
  existing preview is created only after explicit disclosure, preserving the
  bounded first-render behavior of long conversations.
- The implementation is isolated on
  `feature/mobile-codex-image-references` as `2108a3a9` (Bridge history/live
  conversion) and `bdac4e5e` (Mobile lazy disclosure). These commits are not a
  Bridge deployment, OTA publication, stable promotion, or physical-device
  installation.

## Self-signed notification preferences v1

- Local notifications remain available in a self-signed build after the user
  grants iOS notification permission. Delivery while iOS has fully suspended
  the app is a separate APNs/FCM gate: it works only when the final AltStore
  provisioning profile preserves the APS entitlement and the build contains
  the real Firebase configuration. Source entitlements alone are not proof of
  the re-signed IPA's runtime capability.
- Mobile keeps notification preferences locally and exposes one dedicated
  settings screen. Action-required, successful completion and failure are on
  by default; intermediate tool-stage progress is off by default and is
  limited by Bridge to one changed stage per session every 45 seconds.
  Foreground banners are independently configurable and remain suppressed for
  the session currently being viewed.
- `enabledEventTypes` on `push_register` and
  `push_notification_preferences_v1` are additive protocol extensions. An old
  Bridge ignores the extra registration field and retains established
  notifications. A new relay preserves established notifications for legacy
  tokens but never opts them into intermediate progress. A new Bridge also
  refuses to generate progress unless at least one token explicitly subscribed.
- Release order is Cloud Function, Bridge, then Mobile/OTA. This branch adds no
  native dependency, entitlement or asset; its Mobile portion is Dart-only and
  may be delivered by Shorebird against a base IPA that already contains the
  existing Firebase and local-notification plugins. If the installed AltStore
  base lacks usable APS provisioning or Firebase configuration, remote
  lock-screen delivery requires a newly signed base IPA; local/in-app behavior
  remains available.
- A 2026-07-24 production-dependency audit against the official npm registry
  reports the same pre-existing findings before and after this integration:
  root/Bridge has 9 advisories (4 high) and Cloud Functions has 20 (2 critical,
  5 high). The notification commits do not change npm manifests or lockfiles.
  Source integration is therefore not a security regression, but Cloud/Bridge
  deployment must not be described as security-cleared until those dependency
  upgrades receive a separate compatibility review.

## Full-disk read and Bridge-verified file mutation authorization

- This accepted design applies to the owner's self-hosted deployment and has
  two file entry surfaces: user-driven manual file management, and Agent
  local-file references rendered as hyperlinks. They keep separate UI and
  mutation semantics but share one Bridge-owned full-disk read authority and
  preview/download pipeline.
- Bridge may browse, search, read, preview and download every file that its
  macOS host can actually access. Codex and Claude provider tools remain
  governed by their existing sandbox, permission and approval systems; this
  decision does not add a biometric prompt to every agent-authored code edit.
  When an Agent references a local file outside the current project, session
  cwd or legacy allowed directories, Bridge canonicalizes it and issues a
  short-lived opaque read capability instead of returning `path_not_allowed`.
  Real TCC, Unix permission, missing-file and non-regular-file failures remain
  distinct.
- Every filesystem mutation initiated directly by Mobile or a Bridge file
  management RPC requires step-up authorization. This includes create, write,
  append, overwrite, rename, move, phone-to-Mac upload, replace and delete.
  Read-only access still requires ordinary authenticated Bridge connectivity,
  but it does not require the mutation password or Face ID.
- The mutation password is configured locally on the Mac. Bridge stores only a
  versioned Argon2id verifier and salt in a `0600` file, never plaintext. It is
  not logged or persisted on Mobile. Rate limiting, bounded lockout and local
  reset are mandatory; reset revokes devices and all outstanding challenges.
- Face ID is proven cryptographically, not by trusting a client boolean. After
  password-authorized enrollment, Mobile creates a non-exportable Secure
  Enclave signing key protected by `biometryCurrentSet`; Bridge stores the
  public key. Face ID unlocks a signature over a Bridge nonce bound to the
  exact action, canonical paths, file identity, device, connection generation
  and expiry. Biometry changes, reinstall, revocation or stale generations fail
  closed.
- A successful password or biometric proof produces one short-lived,
  single-use authorization for the exact operation or explicit batch. Bridge
  rechecks canonical paths, symlinks and file identity immediately before
  atomic execution. Disconnect, replay, timeout, Bridge restart and late
  signatures cannot execute the mutation. Recoverable Trash is the default
  delete; permanent deletion requires a fresh authorization and warning.
- Owner full-disk configuration is not enabled before Bridge connectivity and
  every private HTTP/WebSocket route share an authentication boundary, Gallery
  upload/list/read/delete cannot bypass it, request/storage limits are bounded,
  and the listener is restricted to Tailscale or an equivalent verified
  firewall rule. macOS Full Disk Access belongs to a stable Bridge host or
  narrow helper, not a version-changing Node runtime path.
- The protocol remains additive through capabilities such as
  `full_disk_read_v1`, `full_disk_reference_preview_v1`,
  `file_mutation_step_up_v1` and `biometric_device_signature_v1`. Old peers
  retain read/session behavior but must fail closed for mutations they cannot
  authorize. A new Mobile with an old Bridge reports that a project-external
  Agent reference needs a Bridge update instead of pretending the file is
  absent. Secure Enclave support may require a new base IPA and must be checked
  before claiming an OTA-only delivery.
- The complete accepted design, sequencing and verification matrix is in
  `docs/full-disk-read-mutation-authorization.md`. No source implementation,
  runtime configuration, Bridge deployment, IPA, OTA or physical-device
  enrollment is implied by this documentation decision.

## Sequential Codex runtimes may share one explicit session authority

- `CODEX_HOME` remains the physical runtime/configuration root. A separate
  `BRIDGE_CODEX_SOURCE_ID` may identify one canonical session and lifecycle
  authority shared by mutually exclusive Cockpit/Codex runtimes.
- The shared ID is a public opaque identifier, not authentication. New IDs are
  `codex-source-` plus 128 random bits; one exact existing
  `codex-home-<24 hex>` may be selected to retain that canonical partition's
  archive, catalog cache and Mirror data. Invalid or empty configured values
  fail closed. When unset, the historical Home-derived identity is unchanged.
- Bridge instance identity, connection/app-server generations, provider thread
  identity and every source-mismatch guard remain independent. Equal source
  IDs do not authorize cross-machine cache merging and do not make delayed
  frames from an old runtime current.
- Cockpit owns the external safety contract: the same Codex account/profile,
  complete app-server database and rollout index, a persistent source ID, and
  a fail-closed single-writer lock that detects residual processes. Bridge
  does not infer authority from a sessions symlink or silently merge a
  successful but incomplete `thread/list` response with filesystem scans.
- Multi-runtime turn ownership, cross-runtime approval routing and conflict UI
  are deferred while the owner guarantees sequential use. The detailed
  contract, compatibility matrix and activation boundary are in
  `docs/codex-shared-session-source.md`.

## Bridge behind Tailscale TCP Serve

- When Tailscale TCP Serve owns the machine's Tailnet address and forwards
  `Tailnet-IP:8765` to `127.0.0.1:8765`, the Bridge service must bind its local
  listener to `127.0.0.1`, not `0.0.0.0`. A wildcard bind conflicts with the
  userspace Tailscale listener after a Bridge restart even when a previously
  started process appeared to coexist.
- The public Mobile route remains the Tailnet address; loopback is the private
  forwarding target. Local `/health` plus `tailscale serve status` proves the
  server and forwarding configuration, while an actual phone reconnect remains
  a separate end-to-end gate because the Mac may not hairpin through its own
  Tailnet TCP listener.
- Runtime rollback must preserve the loopback host while swapping only
  `BRIDGE_CLI_ENTRY`. Loading an older plist that restores `0.0.0.0` is unsafe
  until the Tailscale Serve listener has been deliberately removed.

## Codex resume settings must be authoritative on large rollouts

- Recent-session list rendering may keep using bounded head/tail JSONL reads.
  Those windows are presentation caches and are not authoritative enough to
  resume a Codex thread: a large rollout can place the latest
  `turn_context` megabytes before EOF, or place the first user message outside
  the fast head while current tool output occupies the tail.
- A direct Codex resume now requests an explicit authoritative settings read.
  Bridge searches backward from one stable file-size boundary in bounded
  chunks, finds the latest complete `turn_context`, and overlays any newer
  complete `thread_settings_applied` event. A partially appended final JSONL
  record is ignored rather than replacing the last valid settings.
- Official permission profiles are restored as a tuple. In particular,
  `:danger-full-access` maps to sandbox `danger-full-access` while the paired
  approval policy remains `never`; Bridge must not combine that sandbox with
  its default `on-request`, because Mobile correctly renders that mixed tuple
  as Custom.
- Resume settings are independent of the fast presentation parser succeeding.
  If list metadata is temporarily unavailable, an exact filename match plus a
  valid settings record is sufficient to preserve permissions. This path is
  only used for the thread being resumed, so the recent-session directory does
  not scan every large rollout.
- This is a Bridge-only compatibility repair. It adds no protocol field,
  database migration, Mobile/native dependency or IPA boundary. Existing
  capable Mobile clients continue omitting resume overrides and let Bridge
  preserve the official Codex settings.
