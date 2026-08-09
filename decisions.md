# ccPocket Compatibility Decisions

## 2026-08-09 Codex Desktop project identity is presentation authority

- Codex app-server `cwd` remains the canonical provider/resume path, but it is
  not Codex Desktop's project identity or user-facing project name.
- Bridge reads `$CODEX_HOME/.codex-global-state.json` read-only and with bounded
  caching. `local-projects`, `thread-project-assignments`, registered roots and
  `projectless-thread-ids` provide Desktop-compatible grouping and names.
- The additive `projectGroup*` projection never replaces `projectPath` or
  `resumeCwd`. It only controls Mobile grouping, labels, local project filters,
  collapse state and pins.
- Different worktrees assigned to one Desktop project share its stable project
  ID and current name. Explicitly projectless or unmatched Codex threads share
  one localized projectless group rather than creating fake projects from temp
  path basenames.
- Desktop project renames/reassignments invalidate the Bridge catalog without
  reading conversation history. Mobile preserves a complete cached grouping
  across sparse legacy refreshes, while a newer complete snapshot can rename,
  move or clear the assignment.
- Durable conversation titles are separate provider metadata. In shared mode,
  Mobile writes through app-server `thread/name/set`; Desktop and Mobile both
  consume `thread/name/updated` and the refreshed catalog, so either side's
  rename converges without maintaining a second title authority. Project names
  remain Desktop-owned and are not rewritten by Mobile.
- Old Mobile ignores the fields; new Mobile with old/malformed/missing Desktop
  state falls back to legacy path grouping. Bridge never writes Desktop global
  state.
- The current Bridge catalog retains its existing 1,000-thread scan bound.
  Mobile must not repeatedly expand beyond that bound. True paging beyond it is
  a separate cursor-protocol change and must not be represented as a complete
  snapshot in the meantime.
- The implementation contract is documented in
  `docs/codex-desktop-project-sync.md`. Source completion does not authorize
  Bridge deployment, OTA, IPA construction, device installation or stable.

## 2026-08-09 one repository root and one canonical development branch

- The only CC Pocket source project root is
  `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-compat`.
- Local `main` is the canonical independent product line. The non-Git parent
  workspace, dated worktrees, release-task cwd and upstream branch are not
  source authority.
- Ordinary task branches are short-lived. Once their semantics are verified on
  `main`, remove their worktree and branch; retain an archive ref only when it
  carries unique recovery or audit value.
- The fixed release task may keep one linked checkout on
  `release/ccpocket-local`, but that branch must be fast-forwarded to the exact
  authorized source before every release and must never become a parallel
  development line.
- A historical branch that is not an ancestor may be closed only after
  patch-id or semantic comparison and a recoverable ref. Branch names and
  identical commit subjects are not merge evidence.
- Project-specific operational records may be archived in this repository;
  installed daemons, global skills and cross-project system tooling keep their
  own system-tools ownership and release gates.
- The convergence record is
  `notes/repository-single-root-consolidation_v01_20260809-144837.md`.

## 2026-08-08 provider identity and lightweight history are the only merge authority

- A displayed message is reconciled by provider item id, provider turn id and
  client submission id. Timestamp and text are not global identities and may
  only support a bounded live-tail fallback when no strong identities conflict.
- Assistant, thinking, tool use, tool result, disclosure state and tool-detail
  requests inherit the exact provider turn scope. A fallback UUID or tool id
  reused in another turn or source page is a different item.
- History pages capture the expected source revision and cursor before the
  request and compare again in the SQLite commit transaction. A late page may
  be retried, but cannot rewind a newer cache or visible live tail.
- User-message navigation no longer requires a complete local conversation
  mirror. `conversation_user_index_v1` stores only rebuildable user shells and
  locators; the selected turn and tool detail are fetched on demand.
- The floating todo list is device-local and scoped by Bridge identity, Codex
  source, provider and durable parent thread. It sends through the existing
  composer path and never creates a second provider input channel.
- A cold durable conversation becomes focused on open. Settings may begin as
  unknown, but the mounted page must consume the authoritative focused update;
  leaving and reopening is not a valid refresh mechanism.
- Connection progress is derived from producer milestones. The stalled warning
  is keyed by generation, stage, percent and progress identity and appears only
  after ten seconds without effective progress.
- Bridge-owned auto approval remains the only offline approval supervisor and
  must hold the exact Action Broker writer lease/source generation. Mobile does
  not run a parallel approval loop.
- The accepted plan is
  `plans/mobile-message-history-todo-reliability_v01_20260808-094120.md`; final
  source evidence is
  `notes/message-history-todo-reliability-audit_v01_20260808-133652.md`.
  Runtime deployment, Mobile publication and device acceptance remain separate
  gates.

## 2026-08-07 selective upstream adoption and independent product line

- CC Pocket now evolves as an independent product line. Clean replay onto every
  official upstream commit is no longer a mandatory product constraint.
- Upstream changes are reviewed commit by commit. Absorb behavior that improves
  the accepted CC Pocket architecture or user experience; omit pure version,
  release-process or conflicting implementation changes without manufacturing
  merge ancestry.
- The current useful upstream change is `8c075b33` (long-session Mobile
  performance). The adjacent `4bb3d2e3` version bump is not part of the local
  implementation line.
- Selective adoption is recorded by behavior and tests, not by manufacturing
  merge ancestry. A conflict-resolved local commit may intentionally differ
  from the official patch when CC Pocket already has stronger interaction or
  compatibility semantics.
- Independence does not remove CC Pocket's own compatibility obligations: new
  and old Mobile/Bridge combinations, additive protocol evolution, provider
  history authority, local cache readability and rollback remain required.
- The active implementation plan is
  `plans/full-architecture-review-remediation_v01_20260807-071715.md`.
- Source completion and validation are recorded in
  `notes/full-architecture-review-remediation_v01_20260807-083002.md`; runtime,
  Mobile release and physical-device acceptance remain separate decisions.

## 2026-08-06 conversation chain stability precedes structural cleanup

- Conversation open, loading, retry, live delivery, SQLite persistence and
  rendering must form one observable business loop. A spinner, a sent frame or
  a passing Widget test is not completion unless the requested provider result
  commits and reaches a terminal UI state.
- The Mobile hot window is the latest committed rebuildable replica, not a
  startup-era snapshot. Accepted live content must be persisted promptly; an
  older snapshot/history page can fill a gap but cannot replace newer live or
  committed content.
- Mutation authority and visual continuity are separate. An uncertain runtime
  generation revokes writes immediately, but it does not clear already shown
  messages, streaming output, durable identity or the reading anchor.
- Reopening a conversation with newer/unread/active content shows the latest
  content. Raw pixel offsets are not restored across content revisions; stable
  message anchors may be restored only when no newer content exists.
- Fixes should repair or remove the existing owning path. Do not add abstraction
  layers, duplicate coordinators, high-frequency polling or broad refactors for
  appearance. New additive protocol state is justified only when the existing
  revision/generation facts cannot prove monotonic ordering.
- The active implementation plan is
  `plans/conversation-sync-stability_v01_20260806-160058.md`. Investigation is
  read-only first, then root-reviewed implementation. Deployment and Mobile
  release remain separately authorized gates.

## 2026-08-04 priority settings prewarm and acknowledged projection

- `conversation_sync_v2` 在首次 full subscription 中异步预热 focused、最近五个
  Codex 会话及特殊状态会话的权威设置；目录、状态和 timeline 首批不得等待预热。
- 设置读取总并发为 3、待执行队列上限为 32、单次读取上限为 5 秒。最近五个先保留，
  再用剩余槽位容纳特殊会话；完整快照不重复读取，最后一个 interactive client 离开
  或切换 notification-only 后不再启动旧队列。
- settings hydration 必须同时服从 shared-control generation、thread epoch 和 catalog
  revision。重连先清旧队列、刷新 catalog，再重新选优先级；旧 generation 的迟到结果
  不得重新投影。
- detached/shared 设置仍禁止发送时乐观更新。只有结构完整的成功 ACK 可以立即更新当前
  页面并清 rollback；catalog 继续负责权威校准和 SQLite 持久化，畸形 ACK 不能吞掉后续
  rejection 的回滚能力。
- model/effort 的已知性不再依赖 service tier。旧 Bridge 缺 tier 时只让 speed 保持未知或
  只读，不能连带隐藏已知模型和思考强度。

## 2026-08-02 historical coordinator task is not an authorized contact

- 用户只授权了发布任务 `019f8e9d-2490-79c0-817c-87e3eb93ea2f`，且只有用户当次明确
  要求构建、部署或发布交接时才可以联系。
- `019f8ff9-0945-72a3-a29e-c17df6f112e5` 不是用户授权的协调入口。旧交接文档中要求
  实现 Agent 主动向它回报的规则已作废；禁止再向它发送完成回报、命令或纠正消息。
- 普通源码实现、审计、测试、提交和合并判断均在当前任务内向用户汇报，不自行唤醒或
  联系其他历史任务。

## 2026-08-02 project policy and release-task cwd must not conflict

- 权威开发入口固定为无日期 worktree
  `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/current`，分支
  `integration/ccpocket-current`。旧任务保存的 cwd、Codex 项目选择器、临时 release
  worktree 和运行时路径都不是源码基线；交接仍必须写完整 worktree、branch 和 HEAD。
- `.codex/config.toml` 不再固定 `approval_policy`，项目规则也不再对 Node、npm、Git、
  Dart、Flutter、Simulator、Pod、Python 等命令附加 `decision=prompt`。审批和 sandbox
  完全服从用户为当前 Codex 任务选择的 Normal / Full Access：开启完全访问时，项目文件
  不得再制造第二层审批或拒绝。
- Bridge build/test、Functions 本地 typecheck/build/test、Flutter test/analyze 和本地
  iOS build 仍可保留精确 allow 规则，用于普通模式下减少确定性本地验证的重复询问；
  这些 allow 规则不能扩大 sandbox，也不能代替用户对部署、发布、stable、Cloud、远端
  Git 或破坏性操作的工作流授权。
- 固定发布任务只接收一次完整发布包并独立执行。协调任务不持续监看，但发布任务必须在
  完成或真实阻断时主动回报。流程自治不扩大 stable、Cloud、Desktop、网络、会话数据
  或物理设备权限。
- 清理 worktree 前必须同时满足：HEAD 已进入当前线或有 archive ref、脏改动已单独归档、
  没有运行进程持有 cwd、运行时/回滚/交付物不依赖该目录。仍被任务或 MCP 进程占用的旧
  worktree 明确标为 temporary retained，不能强删。完成进程退出和归档后，日期 worktree
  应移除；持久任务下一次运行必须显式切换到 `current`，不得为兼容旧 cwd 重建同名目录。

## 2026-08-02 shared threads separate turn authority from durable settings

- 当前 turn 的 stop、steer、approval/question response 和消息投递仍只有一个精确
  execution owner，并继续使用 runtime session、authority generation 和 Action
  Broker 门禁。共享架构不等于同一个 turn 可以被两端无条件重复控制。
- model、reasoning effort、service tier、Plan/default collaboration、approval
  policy、reviewer 和 sandbox 是 durable thread 的后续轮次设置。官方
  `thread/settings/update` 可以按精确 `threadId` 更新而不执行 `thread/resume`；
  因此 idle 无 attachment 或当前 Desktop-active 都不能再成为设置只读理由。
- 新协议只增加 capability `codex_durable_thread_settings_v1` 和
  `settingsTarget=durable_thread + codexSourceId + threadId + operationId`。
  它不得携带 transient runtime identity；混合或不完整 target 必须拒绝。
- Bridge durable settings writer 必须处于 daemon shared mode，持有 Action Broker
  writer lease，并通过既有 turn-start pilot gate。写入按 thread 串行、按 operation
  幂等，不 resume、不 attach、不读历史；source 或 writer 不确定时 fail closed。
- 设置 ACK 后只发 content-free `thread/settings/updated` invalidation，v2 只重读
  当前 focused thread 的设置，不扫描目录、状态或历史。Mobile 也只增加精确线程的
  settings ACK/error 订阅，不能形成第二套 conversation subscription。
- 新 Mobile + 旧 Bridge 保留原 waiting/read-only 路径；旧 Mobile + 新 Bridge
  保持原 wire 行为。旧 app-server、writer 未就绪或 capability 缺失时不得假装修改
  成功。设置影响后续 turns，不声称改变已运行中的 turn。

## 2026-08-02 focused Codex settings use incomplete/complete snapshots

- 普通目录读取继续使用有界 head/tail 元数据，未命中 model、effort、tier、
  approval、sandbox 或 collaboration 时必须视为 sparse snapshot，不能解释为
  权威清空。
- 用户聚焦一个 Codex durable thread 后，Bridge 只对该精确 thread 做一次异步的
  authoritative settings 读取。该读取不得阻塞首次 `sync_complete`，不得扫描
  其他目录会话，并使用 single-flight、5 秒失败冷却和 revision/modifiedAt 代次
  门禁；迟到结果只能丢弃并针对最新 revision 重试。
- Bridge 目录刷新与 Mobile SQLite catalog commit 都遵守同一规则：incomplete
  snapshot 只补充或保留已知设置，`codexSettingsSnapshotComplete=true` 才能权威
  清除缺失字段。设置快照完整性不改变 provider 历史、状态或运行时所有权。
- quota/usage 是独立 RPC，不能用额度可见推断模型、权限或 Plan 已同步。UI 的
  设置事实仍来自 durable catalog，运行与停止权限仍来自 status/authority。
- 新 Bridge 与旧 Mobile 继续使用既有 additive 字段；新 Mobile 与旧 Bridge 只
  保留已经确认过的设置，不凭 sparse snapshot 编造首次值。此修复没有 schema、
  Swift/native、Cloud 或破坏性协议变化。

## 2026-07-30 durable Codex threads use external rollout activity

- 所有 durable Codex 会话都可直接读取本地缓存；`thread/loaded/list`、
  Bridge-owned runtime attachment 和用户是否点开页面都不是可用性门禁。
- 独立 Codex Desktop/Cockpit 进程的运行态由现有 `CodexRolloutMonitor` 和
  rollout 尾部活动发现补充到 `conversation_sync_v2`。首次连接只做一次有界
  64 KiB 尾部检查；事件监听负责后续增量，禁止每五秒逐会话重读历史。
- “已发现状态集合”和“实时内容 watcher 集合”必须分离。所有已发现的
  Working 都保留在状态快照中；实时内容 watcher 仍有 32 个上限，超限不得把
  Working 静默改成 idle。
- 默认不为普通近期 idle 会话常驻 rollout watcher。用户聚焦或会话进入
  Working 后再附着；当前 turn 的实时回放只进入 v2 路径，旧 continuity 协议
  行为保持不变。
- 目录、状态和 live delta 使用 source generation、`observedAt` 与稳定
  provider thread ID 拒绝迟到结果。标题、项目路径和同名显示文本永远不能作为
  会话身份，也不能把两个同名会话绑定到同一份历史。
- 独立 Desktop app-server 的 Need You 仍没有可从 rollout 权威恢复的完整请求
  台账。Bridge-owned/shared app-server 的请求生命周期保持权威；外部实例能力
  不足时标为 unknown/degraded，不能根据正文或旧 Working 伪造 Need You。

## 2026-07-30 conversation sync batches keep one subscription

- `conversation_sync_v2` 的 `sync_begin` 标记一次逻辑批次，不代表创建新订阅。
  同一订阅在 read watermark、focus、状态或目录变化后会继续产生新批次，并沿用
  原始 `requestId` 和单调递增的 sequence。Mobile 只有第一次 `sync_begin`
  建立 staging/readiness；后续 `sync_begin` 必须正常提交和 ACK，不能忽略后再把
  下一帧误判为 sequence gap。
- sequence gap 或批次身份不连续只证明流需要重新订阅，不证明已提交的 SQLite
  目录、状态或时间线损坏。此类恢复不得清空 target cache；只有实际 SQLite
  commit/结构校验失败才允许执行既有的一次性可重建缓存清理。
- `SessionListCubit` 只在 catalog、status、read watermark、priority checkpoint
  或全局 reset 后重读目录投影，并把同一时段的事件合并为有界 reload。timeline、
  completed 和单会话 reset 不得撤销整页 readiness 或触发全目录 decode。
- 列表行身份固定使用 durable conversation identity。working/Need You 可以改变
  排序层级，但 recent/runtime 表示切换不能改变 Widget key；这样真实状态更新仍可
  置顶，同时避免无关 subtree 被销毁重建。
- pending durable view 只能通过 `PendingSessionBinding` 的 exact request/durable
  identity 绑定 runtime。项目路径和标题不是会话身份；不得监听同项目任意
  `session_created` 作为兜底，否则同名或同项目线程会串入同一份历史。

## 2026-07-30 conversation sync catalog display bounds

- `conversation_sync_v2` 的 catalog 是有限展示摘要，不是权威历史。Bridge 必须
  在 state hash 和分帧之前把 `name` 限制为 512 字符，把 `summary`、
  `firstPrompt` 和展示用 `projectPath` 限制为 4,096 字符，并避免拆分 UTF-16
  surrogate pair。不得用目录摘要截断去改写 Provider 权威会话正文。
- 新 Mobile 同时容忍旧 Bridge 发送的超长可选展示字段：本地安全截断后继续提交
  整批目录。结构身份、revision、时间和枚举字段继续严格校验；不能把所有协议
  错误都静默吞掉。
- 物理手机停在 85% 的已确认链路是：`sync_begin` ACK → 第一个
  `catalog_changes` 含约 28 KiB `firstPrompt` → Mobile 4,096 字符边界解码失败
  → 下一帧 sequence gap → unsubscribe/retry。连接成功、Bridge 目录读取成功和
  App readiness 必须继续作为不同门禁诊断。
- build 206 没有对应 Shorebird 云端 base release，不能发布定向 patch。Bridge
  端边界修复可让现有 build 206 直接恢复；Mobile 容错必须进入下一次真实 base
  IPA/release，不能把 dry-run archive 说成 OTA 基线。

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
- 局域网发现和手工地址入口若命中已保存的同一 endpoint，必须从该 Machine 的
  Secure Storage 复用 API key；发现包和地址输入不携带凭据，不能因此退回无认证
  WebSocket。显式输入的新 key 优先并覆盖旧值，真正无认证的 legacy Bridge 仍可
  保持空凭据。连接日志和错误提示不得输出 key，只报告认证阶段与脱敏原因。
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

## 2026-07-29 Bridge-owned next-turn queue and compaction

- Codex 正在运行或压缩时，手机提交的下一条输入必须立刻发送给 Bridge。Bridge
  只有在把它放入当前会话的单项权威队列后，才返回
  `input_ack(queued: true)`；手机收到该确认后不再是队列权威，只展示
  `conversation_queue`。退出手机 App 不得取消 Bridge 中的队列。
- 手机在收到 `input_ack` / `input_rejected` 之前，仍保留一份按
  `bridgeInstanceId + codexSourceId` 隔离的可重放 outbox。它只用于覆盖 socket
  写入后尚未确认便退出或断线的窗口；重连时复用 `clientMessageId`，由 Bridge
  幂等确认，不能生成重复回合。Bridge 已确认后才从手机 outbox 删除。
- 用户取消已确认的排队输入时，手机发送现有 `cancel_queued_input`，Bridge
  校验 `sessionId + itemId` 后清除自己的队列并广播空
  `conversation_queue`。离线取消沿用现有身份隔离的持久 mutation 队列。
- `thread/compact/start` 是独立 `compacting` 业务状态，不再伪装成普通
  `running` 工具阶段。压缩请求确认到 `turn/started` 的窗口内，新输入进入
  Bridge 队列而不是被拒绝；压缩完成、失败或启动超时恢复普通 input loop 时，
  必须重新发布 `input_ready` 并自动排空该队列。
- 这些行为复用既有 additive `input_ack`、`conversation_queue`、
  `cancel_queued_input` 和稳定身份字段，不增加旧客户端必须理解的新 wire
  字段。旧手机继续使用原输入流程；旧 Bridge 不提供权威队列确认时，手机保留
  既有兼容回退。
- 本节只授权隔离分支源码与自动验证；不等于稳定分支合并、运行中 Bridge
  替换、OTA、IPA 或真机安装。

## 2026-08-04 Native compaction and bounded Bridge input queue

- 本节取代 2026-07-29 “单项权威队列”的数量限制，但保留其身份隔离、持久
  admission、幂等重放和手机不成为队列权威的原则。新 Bridge 为每个 Codex
  thread 提供最多 16 项的持久 FIFO；一次真实 `input_ready` 只交付队首一项，
  后续项等待下一次 turn readiness，不能在一轮开始时一次性倾泻给 provider。
- Bridge 是 next-turn backlog 的权威，因为当前 Codex app-server 没有原生的
  “多个后续主任务”队列接口。Bridge 使用官方 `turn/start` 交付队首；明确的
  当前轮引导继续使用官方 `turn/steer(expectedTurnId)`，两者不得因 UI 文案而
  混用。队列编辑、取消和 steer 必须使用精确 `itemId`，不能按文本猜测。
- 第一勾只在 Bridge 已把该输入持久写入 delivery ledger 后出现；第二勾只在
  provider RPC 接受或权威 provider 事实确认后出现。普通在线在途消息仍不是
  conversation queue。Mobile 只能投影 `conversation_queue` 与 delivery status，
  不得用定时器或本地 optimistic 状态伪造后端排队。
- 新能力通过 additive `codex_multi_input_queue_v1`、`queuedInputs` 和
  `queuedInputLimit` 暴露。旧 Mobile 继续读取队首 `queuedInput`；新 Mobile
  连接旧 Bridge 时继续采用单项权威队列，并保留旧 transport 在权威排队结果
  到达前允许多个普通在途提交的行为。
- 用户手动压缩统一调用官方 `thread/compact/start`。输入框中的精确
  `/compact`（无附件）是该 core action 的快捷入口，不作为普通用户消息写入
  历史；若 durable thread 尚未挂接，Mobile 先请求精确 runtime attachment，
  authority 确认后只发送一次 compact request。
- 用户手动压缩是独立业务动作：完成后显示独立提示，不归入上一轮的工具调用，
  也不生成普通 assistant result。Agent 在正在运行的 turn 内触发的自动压缩仍
  保留为该轮的 `ContextCompaction` process item，且不能提前释放 next-turn
  队列。
- app-server 可能先发送 `thread/status=idle`，后发送 compact 的终止事件。
  Bridge 必须以 compact 的真实完成/失败终止作为重新检查 readiness 的边界；
  即使状态已经是 idle，也只发布一次 `input_ready`，随后按 FIFO 交付一项。
- 队列恢复、广播和 UI 均必须有界；重启只恢复 replay-safe 的持久记录，超过
  上限的 admission 明确拒绝，不允许无界内存 backlog。发布、Bridge 替换、
  IPA/OTA 和真机验收仍是独立门禁。

## 2026-07-30 Mobile session list modes

- 首页会话目录保留两种明确模式：默认“按项目”分组，以及“最近聊天”全局
  混排。沿用既有 `session_list_group_recent_sessions` 偏好键，避免升级后丢失
  用户已经选择的布局。
- “最近聊天”不按项目聚集；每张会话卡沿用现有项目小标签区分来源。显式置顶
  会话优先，其后未读会话跨项目置顶，再按真实最近活动时间排序。项目置顶只
  影响“按项目”模式，不得把该项目的全部会话聚到全局最近列表前面。
- “按项目”的项目组顺序只由显式会话置顶、显式项目置顶和项目内最新活动
  决定；未读状态可以调整项目内部的会话顺序，但不得改变整个项目组的顺序。
- 这是纯 Mobile 展示投影和本地偏好语义，不新增 Bridge wire 字段、数据库
  schema、原生能力或基础 IPA 边界；源码合入、OTA 和真机视觉验收仍是独立
  门槛。

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
  view. Both the detail view's `Compact context` action and the native
  `/compact` command must issue the existing correlated compact request
  immediately, without navigating to a second page or asking for another
  confirmation. The `codex_core_actions` pane retains Review and MCP only; its
  redundant Compact card is intentionally removed. Future upstream merges must
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

## Shorebird patches require the exact uploaded release binary

- A local `shorebird release --dry-run` archive is a build check, not a cloud
  release baseline. Even when its source, version and build number match, its
  `App.framework/App` may differ materially from an actual uploaded Shorebird
  release and must not be assumed patch-compatible.
- Before publishing or testing a patch, retain and checksum an AltStore input
  IPA made from the exact archive uploaded as the Shorebird release. If an
  earlier dry-run IPA was installed, replace it with this exact release IPA
  before asking the app to download the patch.
- OTA publication remains channel-gated. The default owner test path publishes
  only to `owner`; `stable` promotion is a separate explicit user decision
  after physical-device verification.
- Build `1.109.3+205` release `737381` and owner Patch 1 (`570773`) establish
  this boundary. The detailed artifact hashes and test order are recorded in
  `runs/20260729-181000_shorebird-build205-owner-patch-1/README.md`.

## Mobile connection progress follows real readiness milestones

- Keep the structured connection and catalog diagnostics introduced by
  `6b701a39` as the single diagnostic source. Do not add a second logging
  pipeline merely to drive the loading screen.
- The visible percentage is deterministic event progress, not a time or byte
  estimate. The transport path records opening (`5%`), WebSocket ready
  (`15%`), capabilities sent (`22%`), session-list request sent (`30%`), frame
  received (`40%`), envelope decoded (`48%`), model validated (`58%`),
  authority accepted (`68%`), identity resolved (`74%`) and list published
  (`78%`). Conversation Sync v2 then records subscription/SQLite-committed
  catalog, status, timeline and priority-checkpoint pages through `98%`;
  projection reload and the complete application gate are `99%` and `100%`.
  A legacy catalog keeps its correlated request/response milestones.
- The activity ring is intentionally indeterminate and keeps rotating while
  work is active. The separate percentage and linear bar remain determinate;
  a stationary ring must never be used to represent a numeric checkpoint.
- Conversation Sync progress advances only after the corresponding SQLite
  transaction has committed and includes sequence, generation, phase, logical
  timeline position and per-timeline page in sanitized logs. A timeline page's
  `pageIndex/pageCount` is thread-scoped and must never be presented as global
  bootstrap completion. New Bridge versions add optional
  `timelineIndex/timelineCount`; legacy peers stay at the timeline-stage
  checkpoint until the priority checkpoint. Once the application gate is
  ready, ongoing timeline patches no longer rebuild the entire connection
  screen merely to update startup progress.
- Prompt History is excluded from the startup critical path. It starts once
  per authenticated socket only after application readiness, prefers stable
  Bridge identity across IP routes, skips unchanged revisions, serializes
  legacy import with snapshot sync, and never queues a read-only snapshot for
  replay after reconnect. New Bridge versions echo an additive request ID and
  advertise `prompt_history_request_correlation_v1`; a legacy response lane is
  quarantined until reconnect after any timeout so a late snapshot cannot
  satisfy the next import or sync. The exact old-Bridge `Invalid message
  format` reply is surfaced immediately as unsupported instead of waiting the
  full timeout.
- Machine/IP status refresh feedback is driven by
  `MachineManagerState.isLoading`. Its refresh arrow animates only while the
  real health check is active and stops immediately afterward, avoiding an
  always-running ticker.
- The Bridge additions are optional fields/capabilities only. Old Mobile
  ignores them, while new Mobile retains a bounded stage-only fallback for old
  Bridge versions. There is no database migration, native boundary or
  old-client requirement.

## Important sessions bypass the automatic five-row project limit

- The grouped Mobile session list keeps five rows as the default compact view
  for ordinary sessions. A session that needs user action, is actively
  starting/running/compacting, or is unread must remain visible even when that
  makes the project section longer than five rows.
- In the flat recent-chat view, ordering is explicit session pin, unread,
  needs-you, working, error, then ordinary. In the grouped view, explicit session and
  project pins determine project-section priority separately; a project pin
  never clusters all of that project's rows at the top of the flat view.
  Stable ordering activity continues to order sessions within the same
  urgency; Working uses its discrete assistant-output checkpoint when present.
- `Show more` remains available for ordinary rows after the last important
  session. This automatic-limit exception does not undo an explicit manual
  collapse of the entire project section.
- The urgency classification reuses the same authoritative visual-status
  mapping as the session card, including pending approvals, `waiting_approval`,
  `starting`, `running`, `compacting`, and external desktop turns. Unknown
  statuses do not silently become working or unread.

## Durable sessions are local-first and sync by authenticated source identity

- Every durable conversation is directly readable from the Mobile SQLite
  replica. Opening a conversation must not resume it, acquire writer
  ownership, or wait for a fresh provider-history transfer. A live provider
  attachment is deferred until the user performs an interactive operation.
- Bridge owns catalog, compound status, Need You, revisions, tier assignment
  and sync scheduling. Mobile owns durable replica commits, read watermarks and
  presentation state. IP addresses, DNS names and Tailnet routes are transport
  aliases only; canonical cache identity is the authenticated pair
  `(bridgeInstanceId, codexSourceId)`.
- An endpoint-only legacy cache is not migrated into a source-scoped partition
  until the Bridge identity is proven. This deliberate fail-closed boundary
  prevents a reused IP or DNS route from merging data from another machine.
  Once authenticated, all routes for the same identity reuse one catalog,
  timeline, unread state and cache.
- Initial synchronization is tiered. All working, compacting, Need You, error
  and completion-unread sessions form the priority set. Recent sessions keep
  five turn shells, three full turns and a historical 200-tool detail budget.
  Cold sessions keep catalog/status/revision metadata until changed or opened.
  Live current-turn details are outside the historical budget but remain
  protected by an explicit payload ceiling.
- Sync uses one authenticated WebSocket, monotonic state tokens, bounded
  physical frames, ACK-after-SQLite-commit and per-thread gaps. A stale
  generation or base revision cannot overwrite newer data. An unchanged
  reconnect must not reread or resend history.
- The installed app-server does not currently expose `thread/items/list`.
  Bridge therefore implements equivalent progressive disclosure with bounded
  `thread/turns/list` full pages, per-turn detail caches and an additive
  `conversation_items_by_id_v1` capability. Read-only synchronization never
  falls back to `thread/resume`.
- Ordinary idle conversations have no `Ready` badge. `notLoaded` is runtime
  attachment state, not user availability. Unknown or degraded observations
  remain explicit and never silently become idle/Ready.
- The complete implementation, performance, security, compatibility and
  historical-branch audit is recorded in
  `docs/mobile-session-sync-v2-final-audit-20260730.md`.

## `notLoaded` is an attachment observation, not a conversation failure

- Official app-server `notLoaded` means only that a durable thread is not
  resident in that app-server process. It does not make the conversation
  unavailable, does not require `thread/resume`, and must not render as
  `Ready` or “status unavailable”.
- Canonical v2 status keeps `activity=unknown`,
  `runtimeAttachment=notLoaded`, and `confidence=unknown` until an
  authoritative activity observation exists. A real unknown status returned
  by a loaded app-server is distinguished with `runtimeAttachment=loaded`.
- New Mobile advertises additive capability `app_server_status_v1` and
  suppresses only the ordinary unknown/notLoaded badge. `systemError`,
  `ownedElsewhere`, and loaded-but-unknown observations remain visible.
- Bridge projects only ordinary unknown/notLoaded/no-attention states to
  `activity=idle` for legacy Mobile that supports `conversation_sync_v2` but
  not `app_server_status_v1`. It keeps attachment and confidence truthful, so
  this compatibility projection cannot become a `Ready` claim.
- Status state tokens include a schema version. A semantic projection change
  increments that version and emits a scoped status reset, preventing an old
  persisted snapshot from surviving a Bridge upgrade.
- Switching a LaunchAgent runtime is a separate delivery gate. After
  `bootout`, confirm both the job and listener are gone and allow launchd at
  least two seconds before `bootstrap`; an immediate retry can return
  `Input/output error` even with a valid plist.

## Detached durable previews must not impersonate provider attachment

- Opening a durable conversation renders its local SQLite replica and remains
  intentionally detached from the provider. It must not display a generic
  runtime-loading banner merely because `detachedPreview` is true.
- The attachment banner is valid only after an interactive operation has
  queued a submission and `deferredSubmissionPending` is true. It disappears
  after the authoritative `session_created` attachment event.
- Read-only opening, scrolling and local history rendering never acquire
  app-server writer ownership. A persistent loading label for a state that is
  not being requested is a product bug, not harmless progress wording.

## Conversation sync retries reset only at a stable checkpoint

- ACKing an individual v2 frame proves only that one SQLite commit succeeded.
  It must not reset retry backoff after a previous batch failure. Retry state
  resets only after a priority checkpoint or `sync_complete`.
- The first non-thread commit failure for one authenticated
  `(bridgeInstanceId, codexSourceId)` may clear that target's rebuildable
  catalog/status/timeline/sync-state cache once. Read watermarks, credentials,
  drafts, settings, mutation authorization and Mac authority remain intact.
- A thread base-revision mismatch clears only that thread window. Repeated
  failures back off and emit privacy-safe diagnostics; they do not repeatedly
  clear the target or log URLs, tokens, titles, paths, message bodies or raw
  payloads.
- When Bridge emits a global catalog/status reset, stale client thread revision
  hints are invalid for that subscription and must be discarded so one bounded
  hot-window rebuild can occur. Read watermarks remain valid.
- Launch/recovery shell code must avoid shell-reserved names such as zsh
  `status`. A failed recovery trap is itself a deployment fault and must be
  recorded rather than described as a seamless switch.

## Build 208 establishes the real Shorebird base for sync-list stability

- Live Shorebird inspection confirmed that the locally delivered build 207
  had no cloud base release and therefore could not receive an OTA patch.
  Build 208 advances the version monotonically and is the first
  `1.110.1` base uploaded for the owner's Shorebird app.
- The build 208 source includes the stable long-lived v2 sync subscription,
  scoped list-cache reloads, stable durable-row identity, and exact pending
  runtime binding fixes. Production Bridge code and native Swift/plugin/asset
  sources are unchanged by those repairs.
- Shorebird release `1.110.1+208` is active and has no patch immediately after
  creation. No existing patch was promoted to or removed from `owner` or
  `stable`.
- The unsigned arm64 IPA is an AltStore/AltServer input package. Its cloud
  release, local archive audit, transfer to CC Pocket, AltStore installation,
  and physical-device behavior remain separate gates. A failed transfer
  because no compatible phone is connected is not an installation.
- The package retains the repository's `dummy-project` Firebase configuration.
  Local/Bridge notification behavior may be tested, but APNs/FCM delivery is
  not established by this build.

## The newest turn is a separately repairable sync boundary

- Selecting the newest five turns and then cutting the serialized payload by a
  byte budget is invalid: it can cut through the newest active turn while an
  older-turn cursor remains unable to repair that missing prefix. Bridge must
  preserve the newest turn's user/thinking/process/result spine, replace
  oversized details with stable gaps, and publish
  `latestTurnComplete/latestTurnGap` explicitly.
- Mobile persists the newest-turn gap separately from the older-history cursor.
  Opening or retrying a durable conversation first repairs that current gap,
  commits each page atomically to SQLite, and ACKs only after commit. A
  subscription generation change is retryable; a local database or page-budget
  failure preserves the gap and must not clear the whole source cache.
- Explicit turns/items responses, including their final JSON envelope, remain
  within the protocol frame ceiling. A single item that cannot fit fails
  explicitly; it is never truncated while advancing the cursor. A failed
  socket write retains the valid queued response and sequence rather than
  emitting a second, false page error.
- Current app-server paging uses one shared read-only process. On an older
  app-server without bounded turns/items RPCs, Bridge fails the explicit page
  request safely instead of falling back to an unbounded whole-rollout scan.
  Restoring that legacy capability requires a real file-offset window reader
  with stable file identity, snapshot bounds, rollback handling, and
  cross-page stable item IDs; whole-history parsing is not an acceptable
  compatibility shortcut.

## Durable session insights keep one stable cache identity

- Quota and context are keyed by authenticated Bridge/source plus durable
  thread ID. Runtime session IDs are aliases used only when an old Bridge
  requires the legacy request shape; attaching a runtime must not replace the
  durable cache identity or discard a valid response.
- New Bridge context requests are correlated by request ID. The legacy
  uncorrelated lane is single-flight and quarantines late responses after a
  timeout until reconnect, preventing one delayed response from satisfying a
  later request.
- The insights widget recreates its owned controller when durable/runtime
  identity or Bridge ownership changes. A public refresh waits for the
  authoritative capability/session-list decision and cannot guess the legacy
  path before negotiation completes.

## Background guards observe lifecycle events synchronously

- A `paused`, `hidden`, or `detached` transition can disable Flutter frames
  before a HookWidget rebuilds. Any guard used by an already-running stream
  listener must therefore update from `WidgetsBindingObserver` lifecycle
  callbacks, not only by assigning a ref during `build`.
- Genuine resume callbacks use the same observer path and remember whether a
  real background state occurred. An `inactive → resumed` transition alone
  remains a no-op.
- Widget tests that validate UI produced by an asynchronous broadcast and a
  following Bloc rebuild must pump the delivery and render frames explicitly.
  They must not rely on an unrelated child controller to schedule an
  incidental extra frame.

## Provider state, errors, and detached reads use one source-scoped contract

- A conversation has one composite activity/attention projection and one
  execution host. `desktopAppServer` and `bridge` explain who currently owns
  execution; they do not create separate Working states. Mirror download and
  sync activity is an action indicator, never a third conversation state.
- Ordinary idle conversations show no Ready badge. `unknown`, `notLoaded`, and
  `ownedElsewhere` remain distinct internal facts and must not be silently
  rewritten as Ready.
- Conversation-entry timeout is based on time since the last meaningful,
  request-correlated progress: a real stage transition, accepted chunk,
  committed page, revision advance, or increase in visible content. Repeated
  heartbeat frames do not renew the deadline. A larger hard cap remains only
  as a safety diagnostic.
- Bridge-owned auto approval is persisted and keyed by
  `codexSourceId + threadId`. Legacy policy without a proven source fails
  closed. A Bridge must not approve a request owned by another private
  app-server.
- A malformed frame without a proven `sessionId` goes only to global
  diagnostics. History and delta failures include a target `sessionId` and
  stable sanitized `errorCode`; an unscoped error must never become a chat
  message in every open conversation.
- Reading subagents for a detached durable Desktop conversation uses the
  additive capability `detached_subagents_read_v1` and the identity
  `providerThreadId + codexSourceId`. Bridge validates the source before
  opening a reader, uses only bounded read/list RPCs, and never resumes,
  starts, forks, creates a runtime session, or acquires writer ownership merely
  to populate the floating dock.
- If another independent app-server owns an active turn, CC Pocket does not
  steal or kill that owner. Input is durably acknowledged by Bridge, queued,
  and delivered to the next turn after ownership becomes available. True
  cross-client live steer requires a shared app-server or a future official,
  verifiable owner-control API; UI and the second ACK must not claim that
  capability before it exists.

## 2026-07-31 ordinary delivery is not a conversation queue

- 普通在线消息的 ACK 等待只属于消息气泡的 delivery 状态：发送中，Bridge 接收后
  显示一个勾。Provider 后续接收仍是内部交付事实，但普通消息气泡不显示双勾；
  双勾只属于 Bridge 权威下一轮队列中的第二阶段。不得再用固定延迟把普通在途
  消息投影为下一轮队列。
- “已在本地排队”只表示真正尚未进入 Bridge 的断线 outbox；输入框上方的队列面板
  只表示 Bridge 权威确认的下一轮队列。两者不能复用同一个文案或卡片 badge。
- `clientMessageId` 是 optimistic 气泡与 Bridge 队列的首选关联。旧 Bridge 缺少
  该字段时，只允许关联唯一且同文本的在途消息；有歧义时保留两个可见事实，不能
  猜测并删除用户消息。
- Delivery recovery metadata 可以在 Mobile 内部保留以支持页面重建，但不得写入
  `SessionInfo.queuedInput`、不得触发后台工作 badge，也不得暴露不能真正撤回的
  编辑/取消操作。
- Detached Desktop 详情从已经提交的 source-scoped v2 cache 读取状态和设置，
  不得为了显示 Working 或 effort 而 resume 会话。缺失 effort 保持 unknown；
  独立 Desktop owner 活跃时，Mobile 与 Bridge 均拒绝 model/speed 写回。

## Unread and discrete assistant output define stable conversation ordering

- Explicit user pins remain the outermost tier. Within each pin tier, unread
  conversations sort before Need You, Working, error and ordinary rows. The
  grouped view keeps project sections independent from unread priority; unread
  changes only the order and visibility of rows inside their project.
- A Working conversation advances its row clock and its project's activity
  clock only when a committed discrete assistant message contains non-empty
  visible text. Stream/thinking deltas, tool-only assistant messages, tool
  results, status/result frames and history wrappers may update content and
  runtime state but must not make Working rows repeatedly trade positions.
- Mobile persists this assistant-output checkpoint inside rebuildable catalog
  JSON and derives it from committed bounded timeline pages. This adds no wire
  field or SQLite schema and works with an older Bridge; direct runtime
  assistant frames provide the compatibility fallback before timeline commit.
  If no checkpoint exists yet, ordering falls back to the existing durable
  activity timestamp.
- Bridge may keep a process-local assistant-only live catalog overlay to reduce
  churn for older Mobile versions, but provider catalog recency remains
  canonical across refresh and restart. Mobile's persisted checkpoint is the
  ordering authority; Bridge must not clamp provider seeds or invent a new
  provider timestamp contract.
- Opening a durable conversation marks it read when focus is acquired and
  marks it again before focus is cleared or switched. The persisted watermark
  is anchored to the latest committed authoritative `status.observedAt` when
  one exists; without an authoritative status clock, v2 read persistence is
  deferred instead of trusting the phone clock. A completion seen while the
  page is open therefore cannot reappear as unread, and a fast phone clock
  cannot swallow a truly newer Bridge completion after focus is cleared.
  Because WebSocket frames and Mobile cache writes are ordered, Bridge accepts
  a lower read-watermark correction so an older fast-phone timestamp can be
  repaired without waiting for reconnect.

## The primary Codex catalog excludes internal subagent threads

- Main-session discovery asks app-server only for `cli`, `vscode`, `exec`, and
  `appServer` source kinds. Subagent threads remain attached to their owning
  conversation and belong in the per-session process surface, not the home
  conversation catalog.
- Safe rollout metadata is resolved for every returned primary thread. The old
  64-thread cutoff is removed, while opaque app-server `thread.preview` remains
  forbidden because it may contain private agent-to-agent content.
- An older app-server that explicitly rejects the `sourceKinds` parameter with
  `thread/list -32602` falls back to the existing bounded sessions index. Other
  invalid-parameter failures are not swallowed.
- Empty Codex history is marked incomplete only with positive evidence of
  content or activity: safe first prompt/summary, provider turn evidence,
  live-buffer content, Working/Compacting/error, attention, or result. Timestamp
  movement alone is not proof that an otherwise empty new thread has history.
- Initial reconnect revision validation is bounded to 16 hot windows and 1000
  entries. Omitted revisions are replayed by Bridge; they are never treated as
  proof that cached content is current. This is a safe startup bound, not
  permission to skip later incremental reconciliation.

## Shared Codex runtime begins with a reversible exact-version pilot

- The accepted shared-runtime plan is active, but source work must follow the
  Stage 0 deviation ledger rather than unverified protocol assumptions.
- Pilot Desktop and Bridge must use the exact Codex version bundled with the
  installed Desktop. The daemon is verified and connected over a local Unix
  socket; Bridge never owns, starts, stops or bootstraps that daemon.
- A global `thread/started` observation is not proof of a writable attachment.
  A thread with no durable rollout remains discoverable but may not yet be
  resumable from another connection; first-turn ownership and later adoption
  are separate states and separate tests.
- Shared-daemon pilot is observer-first and single-writer. A server request can
  be delivered to multiple subscribers and the first response wins, so a
  Bridge attachment must prove thread, turn, connection generation and local
  write authority before answering it. Incompatible single-subscriber
  features fail closed.
- Desktop is switched only through its existing local-daemon environment gate;
  the application bundle is not patched or re-signed. Static store behavior is
  insufficient: correct project sidebar visibility remains a user-observed
  pilot gate.
- Stage 0–2 do not modify Mobile, SQLite, native iOS code, notifications,
  production Bridge or release channels. After the real pilot, private mode is
  restored and implementation stops until the user explicitly confirms the
  next stage.
- The automated Stage 2 gate is now proven on an isolated
  `1.69.6-compat.12` candidate: two authenticated Bridge clients observed one
  real canary, settings-neutral resume did not replay transcript history,
  Bridge-only restart preserved the daemon identity, and a replacement
  attachment followed one already-active turn to completion. This is runtime
  evidence only; it does not satisfy the independent Desktop sidebar gate.
- The global control connection remains initialize-only. It never resumes a
  thread or answers a server request. Turn diagnostics are contributed by the
  single authoritative Bridge attachment only after exact thread and runtime
  generation filtering, and contain no title, path, body or tool payload.
- A shared Bridge attachment may answer a server request or steer only a turn
  whose successful `turn/start` response was received by that exact
  attachment. Ownership is removed on completion, stop and generation change;
  adopted/Desktop turns fail closed. This prevents Bridge from answering a
  Desktop turn, but it is not the future Action Broker: Desktop may still be a
  first responder for a Bridge-originated request, so the Stage 2 Desktop Pilot
  remains strictly no-tool and serial.
- Pilot assets are exact-version, manifest-hashed copies inside a private
  `CODEX_HOME`; daemon verification checks the managed path, requires the
  audited `pid` lifecycle backend, and uses only a bounded short-lived metadata
  cache. Desktop GUI environment changes are a one-use
  `captured → enabling → shared → restoring → restored` transaction with
  verified rollback and interrupted-state recovery, not an ambient permanent
  configuration.

## 2026-08-01 private and daemon Codex runtime paths both remain supported

- `private` 继续是默认和旧部署兼容路径；未设置
  `BRIDGE_CODEX_APP_SERVER_MODE` 时不得自动切换到共享 daemon，也不得因为安装了
  新 Bridge 就改变 Desktop 的运行方式。
- `daemon` 继续作为显式配置、精确版本、可回滚的共享运行时路径。它只有在本地
  Unix socket、版本、writer lease、control stream 和用户侧 Desktop 试验门禁均
  通过后才可启用；不满足条件时 fail closed，不伪装成 private 已成功。
- 两条路径共用目录、状态、历史、来源身份和 Mobile v2 缓存语义。项目无关的只读
  catalog/status/history 读取复用一个有界 app-server 连接；private 下仍为 Bridge
  自己的只读进程，daemon 下仍连接共享运行时。会话 resume、发送、审批等 mutation
  继续走各模式原有的所有权和 writer fence，不能借读取复用跨越写入边界。
- launchd 的进程 cwd 不是会话 cwd。项目无关的只读进程从第一个已配置 authority
  root（owner 全盘只读时回退用户 Home）启动；实际 resume/mutation 始终传入该
  durable 会话的真实项目路径。
- Mobile 从 `conversation_sync_v2` 持久目录打开的会话，不得回头要求该会话同时
  出现在旧的 bounded `recentSessions` 列表中才允许首次发送。接管必须使用当前已
  认证 Bridge/source 分区里的精确 provider thread ID 和 v2 metadata；相同 thread
  ID 出现在另一 Codex Home 时继续 fail closed。
- 源码合入、运行 Bridge 切换、Desktop daemon 试验、OTA/IPA 和真机验收仍是独立
  门禁。本决定只保留两条产品路径，不授权自动修改当前生产模式或发布通道。

### 2026-08-01：真实 Desktop 共享运行时不得使用隔离 Pilot Home

- `codex-desktop-shared-runtime enable-shared --root <pilot>` 曾把 GUI launchd 的
  `CODEX_HOME` 指向 `/private/tmp` 隔离目录，导致 Desktop 左栏只显示 pilot 中的
  两个任务。真实 `~/.codex`、1498 个会话和数据库没有丢失，但该入口不能用于生产。
- CLI 入口改名为 `enable-isolated-pilot`，名称必须明确表达会切换到隔离 Home；旧的
  `enable-shared` 直接拒绝，防止发布流程再次误用。
- 真实 Desktop 共享模式必须由官方 `codex app-server daemon bootstrap
  --remote-control` 在真实 `~/.codex` 中管理。Desktop GUI 环境只设置
  `CODEX_APP_SERVER_USE_LOCAL_DAEMON=1`，不得设置 `CODEX_HOME`；Bridge 也指向同一
  真实 Home、同一用户私有 Unix socket。
- 官方安装包可能出现 CLI 版本 `0.146.0-alpha.9.2`、managed/app-server 版本
  `0.146.0` 的合法双标签。Bridge 分别精确固定两者，不再错误要求字符串相同；socket、
  CLI 文件、所有权、路径和版本仍全部 fail closed。

## 2026-08-02 runtime attachment changes invalidate v2 authority immediately

- Shared Codex `input_ready`, attachment recovery, replacement, settings and
  capability lifecycle changes can occur without a provider transcript
  message. `SessionManager` must therefore invalidate the affected durable
  runtime projection explicitly; a later assistant/tool/status message is not
  an acceptable trigger for control readiness.
- `conversation_sync_v2` recomputes only the affected
  `provider + providerSessionId` key from the host's content-free runtime
  snapshot. It publishes the current execution host, control state, active
  turn and authority generation without rereading catalog or history.
- The ordinary `session_list` runtime handle and the v2 authority projection
  remain separate facts but are emitted from the same lifecycle boundary. A
  Mobile client may mutate settings, stop, steer or send only after both form
  one exact current target.
- Reopening or replacing a runtime creates a new authority generation. Mobile
  continues to reject the old generation; Bridge must actively publish the new
  generation even when Desktop produces no subsequent message. Missing
  authority remains fail-closed and must never be bypassed to hide a loading
  symptom.

## 2026-08-02 Bridge-only 本地生产发布使用单一强制 SOP

- 本机 `com.ccpocket.bridge` 生产发布遵循
  `docs/bridge-local-production-release-sop.md`。`test-bridge` 的源码门禁和
  `release-bridge` 的 npm/GitHub 流程均不能替代该 SOP 的候选、切换和运行时验收。
- 生产环境与独立探针以当前 LaunchAgent plist、真实进程、loopback listener 和
  health/readyz 的交叉验证为准；不得从发布会话的继承环境推断。候选和探针显式继承
  plist 的 `CODEX_HOME`、daemon socket 与 source identity，候选不得随意改写 source id。
- raw rollout、正式 metadata API 与认证 `conversation_sync_v2` 是逐层门禁。raw 有字段
  而 metadata/v2 未产出时 fail closed，保留最小差异证据交回开发会话，不以构建或候选
  启动成功替代生产可用。
- 生产切换仅允许修改 `BRIDGE_CLI_ENTRY`，保留共享 app-server、LAN proxy、网络和用户
  会话数据；所有失败都停止候选或恢复旧 entry，最终只留当前 runtime 和一个回滚 runtime。

## 2026-08-02 Bridge 连接密钥改为显式可选配置

- `BRIDGE_API_KEY` 只保存连接密钥；`BRIDGE_REQUIRE_API_KEY=1/0` 明确表示是否要求手机
  提交该密钥。开关未配置时继续兼容旧部署：有 key 即开启、无 key 即关闭。
- 显式 `0` 本身就是用户对可信局域网无认证暴露的确认，不再要求同时设置旧的
  `BRIDGE_ALLOW_UNAUTHENTICATED_REMOTE=1`。但认证关闭时，依赖已认证手机的 owner
  全盘读取等高权限表面继续 fail closed，不能把“可连接”误报成“高权限也可用”。
- 当前开发期生产 Bridge 保持 `BRIDGE_REQUIRE_API_KEY=1`。以后默认关闭必须作为独立
  产品/部署决定执行，不能在普通 runtime 更新中顺便改变。
- 新 Bridge 在 `/health` 加法声明认证是否必需，并在 WebSocket upgrade 阶段对缺失或
  错误密钥返回 401；旧 Bridge 的 4001 close code 继续兼容。
- Mobile 遇到缺失或错误密钥时必须停止 5% 进度和自动重试，显示明确的连接密钥弹窗，
  允许覆盖 Secure Storage 中本机路线的密钥或重新扫码。网络拒绝、普通 WebSocket
  故障和旧服务器不得被无条件误判为密钥错误。
- Bridge 连接密钥只负责设备连接认证，与文件修改/删除使用的 Bridge 口令和 Face ID
  step-up 授权是两套边界，UI、配置和日志不得混称。

## 2026-08-08 LAN 地址与 writer lease 恢复

- Bridge 继续只绑定 `127.0.0.1:8765`，避免与 Tailscale TCP Serve 的 Tailnet
  listener 冲突。局域网入口由独立认证代理绑定当前私有 `en0` IPv4；不得再把某次
  DHCP 地址写成长期固定配置。代理在地址缺失时等待，在地址变化时重绑，API Key
  摘要和 loopback upstream 不变。
- Action Broker writer lease 的心跳如果发现 owner 不匹配或持久化失败，必须向
  runtime 发布明确的 lease-loss 事件。Runtime 清除旧 generation/live binding，
  进入既有的 1 秒 fenced retry；不得只清空 lease 内存后永久停在
  `writer_lease_unavailable`。
- Mobile 的 79% 表示 Bridge 认证与目录已完成、但 `/readyz` 尚未允许应用进入。
  该门禁继续 fail closed；修复后端 readiness，不得把 79% 改成假完成。

## 2026-08-08 外部静态审计必须按真实职责复核后修复

- 外部审计报告是问题线索，不因其标注“P0/P1 已确认”就成为源码权威。每项必须沿
  provider/app-server → Bridge → protocol → SQLite/runtime cache → Cubit/UI 的实际调用
  条件复核；已有等价实现、兼容握手或分层缓存职责不得被同名表象覆盖。
- 断线恢复继续使用现有 v2 state token/ACK/scoped reset 和 runtime seq/canonical history；
  不新增第二套无范围通用 backlog。瞬态 stream/thinking 可在断线时丢弃，最终 provider
  history 才是 durable authority。
- `input_ack` 是发送设备的投递收据；其他设备通过权威 `user_input` broadcast 获取消息，
  不广播设备本地 ACK。
- Push token register/unregister 可有界重试；notify 在 Cloud 尚无 deliveryId 幂等去重前
  保持单次发送，防止重复通知。
- Shared daemon 的 durable settings 应复用已存在的健康 app-server client，只有没有可用
  client 时才创建短暂 fallback；writer lease/source/operation-id 门禁不可降低。
- Claude durable input、Claude session model mutation、catalog repository 和 idle eviction
  lease 需要独立能力或运行证据，不能以“顺手修复”名义猜测实现。

## 2026-08-08 退役完整历史下载入口与手动压缩分割线

- 新 Mobile 不再提供“完整下载并常驻”、手动完整同步、卡片下载图标或等价 action
  handler。历史导航统一使用轻量用户轮次索引、持久热窗口和按需分页；不得用另一个
  全量副本作为正常使用前提。
- 旧版本已经写入手机的完整副本不自动删除。卡片只显示不可点击的保存标记，管理
  页面只允许取消旧常驻和删除手机副本；普通缓存清理和电脑端权威会话仍保持隔离。
  Bridge Mirror 协议和服务层兼容能力暂时保留，避免破坏旧 Mobile，但新 UI 不得重新
  暴露调用入口。
- 官方 `thread/compact/start` 产生的独立 compaction turn 投影为带
  `historyTurnId` 的 `manual_context_compacted` 系统标记。它必须跨 canonical refresh
  保留、按 turn 去重，并在 Mobile 时间线上显示两侧分割线和“已压缩上下文”；它不是
  上一轮中间过程或工具调用。
- Agent 运行 turn 内的自动压缩继续显示为该 turn 的 `ContextCompaction` process item。
  Bridge 只有在一个 app-server turn 的有效 items 全部是 context-compaction 类型时才
  将其视为显式手动压缩；camelCase、snake_case 和 kebab-case 只做加法兼容。
- 较老的 summary 分页若 provider 本身省略 compaction item，可以不为补一个分割线而
  退化成无界 full-history 读取；实时路径、近期五轮 full 窗口和显式 full items 页必须
  保留该标记。发布、Bridge runtime、OTA、IPA 和真机视觉验收仍是独立门禁。

## 2026-08-09 发布流程采用按差异分流和阶段化续跑

- 固定发布任务先比较当前生产 Bridge、Mobile/IPA 基线与目标 HEAD 的真实产品 tree，
  只执行受影响层；仓库总 HEAD 变化不自动要求所有 runtime 和产物升级。
- 发布级全量测试仍由固定发布任务负责，但每个受影响层只跑一次。出现失败时直接回报
  协调任务；修复后从第一个失效阶段续跑，不重复仍有效的全量测试、候选或生产快照。
- 无 Bridge 产品差异时禁止为了 runtime 名称追随总 HEAD 而重建、smoke 或重启 Bridge。
  无 Mobile 交付输入差异时同样禁止生成新 OTA/IPA。
- 当前机器的正式发布不得临时试验新的 LaunchAgent 或 wire 探针。使用最近已验证流程，
  并遵守 `docs/local-release-fast-path.md` 的时间目标、主动超时回报和 fingerprint 证据合同。

## 2026-08-09 Bridge 签名身份、设备配对与机器路线归并

- `Machine.id` 仍表示一条可独立编辑、删除和排序的 IP、Tailnet、DNS 或 SSH 连接路线；
  多条路线只在界面中按经过 Ed25519 签名证明的 `bridgeIdentityId` 归为同一台电脑，
  不物理合并路线记录。无签名能力的旧 Bridge 仅在已认证
  `bridgeInstanceId` 一致时兼容归组；完全未证明的 endpoint 继续隔离。
- Bridge 首次运行生成随机 Ed25519 身份，私钥只存于当前用户的 `0700` 状态目录和
  `0600` 文件。身份不读取 Mac 序列号、MAC、`IOPlatformUUID` 或其他硬件标识，
  也不把这些值用作鉴权。身份、信任或配对文件只在不存在时创建；损坏、无权限、
  非普通文件或密钥不匹配全部 fail closed，不静默换身份或清空受信设备。
- `BRIDGE_AUTH_MODE` 明确区分 `key`、`paired_or_key` 和 `open`。旧 API key 永久保留
  为兼容/恢复入口；`paired_or_key` 允许已配对手机用设备签名连接，也允许 key
  客户端无中断登记设备。二维码使用一次性 256-bit token；无二维码时手机显示六位
  确认码，由用户在 Mac 本机执行 `ccpocket-bridge pair approve <code>`。本机批准等待
  最长五分钟，批准后必须重新挑战，业务消息在设备认证完成前不得发送。
- Mobile 必须把“允许登记设备”和“允许设备签名免 key 登录”作为两个独立能力判断。
  `key` 模式始终要求连接 key，并在设备登记后保留该 key；只有明确声明
  `paired_or_key` / `device_signature` 的 Bridge 才能跳过 key 输入，并在登记成功后
  从后续重连 URL 中移除旧 key。不能仅凭 pairing methods 就推断无 key 可连接。
- 设备认证成功后，Bridge 签发只在该 WebSocket 存活期间有效、且绑定直接网络 peer
  的随机 HTTP bearer；断开即撤销。它只替代连接密钥，不替代文件修改/删除使用的
  Face ID 或 Bridge 口令 step-up。两套授权的存储、UI 和日志保持分离。
- Mobile 冷启动只并发、有界地探测已保存路线的 health 与签名身份，不自动建立
  WebSocket，也不展示“正在连接”进度。只有用户点选在线电脑或具体路线后才连接；
  该次显式连接成功后的前后台恢复和断线自动重连继续保留。电脑卡片显示系统电脑名
  或用户别名，展开后显示全部路线，并优先选择在线且延迟最低的路线。
- 签名身份只负责机器/路线归并和身份固定；会话目录、SQLite 缓存、未读和离线 mutation
  的 canonical 数据分区仍以权威 `bridgeInstanceId + codexSourceId` 为准。不同 IP
  连到同一 Bridge 时复用同一数据分区，身份不匹配时禁止写入或队列重放。
- 新 Mobile + 旧 Bridge 继续走 endpoint/key 兼容路径；旧 Mobile + 新 Bridge 在
  `key` 或持有 API key 的 `paired_or_key` 模式下保持原行为。`bridge_identity_v3`、
  配对消息和模型字段全部为加法能力。本节是源码与自动验证决定，不授权切换当前生产
  `BRIDGE_AUTH_MODE`、重启 Bridge、发布 OTA/IPA、安装设备或晋级 stable。
