# CC Pocket 1.109.2 全面修复、兼容整合与性能收束方案

> 状态：active
>
> 本方案记录 2026-07-25 已确认的产品目标、当前证据、实施顺序和验收门槛。
> 它是执行路线和完成审计清单，不是对当前源码或运行状态的完成声明。
> 具体类名、协议字段和接缝在实施时仍必须以合并后的真实源码为准；发现更深层
> 原因时，应修正设计和测试，不能为了照抄本文只修表面症状。

## 0. 权威边界与当前基线

### 0.1 官方基线

- 官方远端 `upstream/main` 已现场核对为
  `aa215a3b98a8035cba0e6bdd8005803f76041d66`。
- 对应 Mobile 为 `1.109.2+201`，Bridge 为 `1.69.4`。
- 相比本地统一基线中的 `9ff2e76c`，官方新增的功能性变化包括：
  - Codex app-server 错误、active writer、归档线程和流恢复加固；
  - Codex Auto Review 组织策略约束；
  - 生成图片分组、全屏画廊和稳定图片引用；
  - 图片密集会话恢复的缓存、进度、重试和超时；
  - 外部会话链接和 recent session 的精确恢复。
- 上述改动与本地会话恢复、图片引用、权限、历史同步和性能热点直接交错。实施
  必须先合并官方提交并理解双方语义，不能对热点文件整文件选择 ours/theirs。

### 0.2 本地功能底座

- 当前最完整且工作树干净的本地候选为：
  - worktree：
    `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-background-notify-candidate-20260724`
  - branch：`integration/mobile-1.108.1-background-notify-candidate-20260724`
  - HEAD：`99956f60ceb02a8657316d1d04d47611b8038e4f`
- 该候选已经包含：
  - 本地统一 Mobile/Bridge 兼容栈；
  - Codex 图片引用；
  - 五组 Mobile 性能优化；
  - 有限后台同步；
  - 分级通知设置、Bridge/Cloud progress 通知；
  - opt-in 始终定位后台 notification-only 链路及候选加固。
- `feature/mobile-session-tools` 主工作树存在大量未提交的持久 Side Chat 实验，
  且产品方向已明确取消该持久会话方案。必须原样保留供审计，不得把其工作树
  改动直接带入新集成分支。
- `docs/project-handoff-manual` 中的 owner 文件、统一预览、文件变更二次授权和
  统一会话方案仍是设计文档，不表示已经实现。

### 0.3 当前运行态证据

- Mac 当前实际运行的 Bridge 是 `1.69.0-compat.6`，监听 `*:8765`，不是候选
  Bridge，也不是官方 `1.69.4`。
- 该运行时不包含：
  - `background_notification_delivery_v1`
  - `set_client_delivery_mode`
  - `background_notification_v1`
  - `session_progress`
  - `push_notification_preferences_v1`
- 当前 Bridge 日志中的 relay 返回过 `tokenCount: 0`。这只证明当次 Cloud/FCM
  路径没有可投递 token，不能用来判断定位保活的本地 WebSocket 通知链路。
- 已找到本地 IPA：
  `/Users/huyiyang/Downloads/CC-Pocket-1.108.1-build201-background-notify-99956f60-AltStore.ipa`。
  包内确实包含 location background mode、Always Location 用途说明、原生
  `backgroundLocationKeepAlive` capability 和 Dart
  `background_notification_delivery_v1`。该 IPA payload 本身未签名、无内嵌
  provisioning profile，符合交给 AltStore 现场重签的输入形态，但不能据此
  证明已经安装或真机权限已通过。
- 官方和本地候选都使用 build `201`。完成语义合并后必须分配新的 owner 基础
  build（至少 `202`，最终以仓库最新版本为准），不能让两个不同源码共用同一
  build 身份。

## 1. 不可变产品原则

1. 官方 provider/app-server 和原始持久化记录是会话事实来源；Bridge 负责统一
   语义，Mobile Mirror/SQLite 只是可重建缓存。
2. 旧 Mobile、新 Mobile、旧 Bridge、新 Bridge和新旧基础 IPA必须能力协商；
   additive 字段可忽略，破坏性协议必须升版本。
3. 修复必须先建立真实因果链和回归夹具。发现疑似 bug 时先确认数据、身份、
   generation、事件顺序和运行对象，不能凭表象修改。
4. 不通过截断真实历史、隐藏错误、降低产品上限或停止实时反馈来换取“性能优化”。
5. 未打开会话只同步和归一化必要增量，不构建聊天 Widget、不做 Markdown 布局、
   不解析折叠工具详情。
6. Agent/provider 的原有文件工具权限保持不变；owner 手动文件管理是另一条
   authority。只读与直接文件变更必须分开。
7. 源码集成、Bridge 构建、Bridge 部署、Cloud 部署、IPA 构建、AltStore 安装、
   owner OTA 和 stable 晋级是不同门槛。
8. 本轮只做固定界面和确定性系统文案本地化，不引入运行时翻译包、云翻译 API
   或自动翻译 Agent/命令/日志内容。

## 2. 统一架构目标

```text
Provider/App-server canonical state
               │
               ▼
Bridge SessionProjection / Revision Ledger
  ├─ compact catalog deltas ──────────────┐
  ├─ bounded transcript envelopes         │
  ├─ on-demand tool/process details       │
  ├─ pending interaction ledger           │
  └─ notification projection              │
                                          ▼
Mobile rebuildable store
  ├─ unified session rows + unread/revision
  ├─ recent five-turn window
  ├─ lightweight intermediate envelopes
  ├─ lazy tool/process detail pages
  └─ stable disclosure/scroll state by identity
```

所有会话相关修复都优先汇入一个可测试的 session projection/reducer，而不是继续
让 session list、recent list、live runtime、Mirror、通知、审批和 UI 各自猜测
同一会话的身份与状态。

## 2A. 已完成探索结论登记

以下是进入本方案前已经通过源码、Git、产物或运行态确认的结论。实施时应先在
新的官方合并基线上复核位置是否变化，再以同一因果链修复；不能退回仅根据问题
描述重新猜测。

### 2A.1 历史加载和折叠

- 当前“200 条”主要是平铺在 Bridge history、Mobile runtime/Cubit 和 Mirror
  render window 上的 envelope 上限，并不是用户要求的“最近 5 个根回合 +
  最多 200 个工具详情”两层预算。现有窗口机制可复用，但需要 turn-aware
  envelope/detail 分离。
- 增量更新导致展开内容重新折叠已有直接调用链：
  1. `ChatMessageHandler._handleAssistant` 对普通 assistant 更新也发出
     `ChatSideEffect.collapseToolResults`；
  2. history delta append 会把新增消息逐条送入该路径；
  3. screen 收到 notifier 后清空 `_expandedProcessSegments`、
     `_expandedIntermediateTurns` 和 `_expandedCurrentProgress`；
  4. lifecycle 回调还有另一条 collapse-all 路径；
  5. 旧测试曾把“assistant message 必须触发 collapse”锁成预期。
- 因此该问题不是 Flutter 偶发丢 State。修复必须撤销隐式全局 collapse，保留
  显式 collapse-all，并为 partial/full、current/history 身份迁移补回归。
- “中间过程重复两次”目前只确认最可能发生在 canonical history、live
  provisional 和 Mirror merge identity 边界；尚未取得一个实际出错 session
  的四层数据。实施前必须抓取对应 raw/provider、Bridge normalized、Mirror 和
  render sections，不能直接按相同文本去重。

### 2A.2 会话列表、导航和 Goal

- 实施期进一步核对后修正早期判断：Bridge 的 recent provider 列表已经按
  `modified` 降序；真正导致“最近使用的会话跑到底部”的是 running 列表来自
  `SessionManager` 的 `Map` 插入顺序，而 Mobile 的 `prioritizePinned()` 只分
  pin tier、不在 tier 内按 `lastActivityAt` 排序。
- 首页当前不是一套列表，而是三个互斥分类：顶部 resident/downloaded 区、
  running 区和 recent 区；recent 还会显式排除 running identity 与 resident
  identity。因此同一个 durable thread 会在三个区域之间移动，不能仅靠调整
  Section 顺序解决。
- 点击 recent session 当前先调用 resume，再等待 runtime/session created 后
  导航；这正是“先激活才能用”的用户可见步骤。
- 现有 `session-link` 已经实现 `resumeRequestId` correlation，但首页 recent
  点击仍没有复用该边界；新建会话的 pending chat shell 可以复用，不过其当前
  只按 project path 接收 `session_created`，同项目并发时仍可能串绑，实施时必须
  将 request ID 传到 pending screen 并只消费精确匹配事件。
- `BridgeService.connect()` 在 WebSocket channel 建立后、收到 Bridge handshake
  和 authoritative session list 前就发布 `connected`。依赖该状态的 connection
  UI 可能提前离开选 IP 页面。
- 已确认首页原先直接以 transport `connected/reconnecting` 切换整页内容：
  WebSocket HTTP upgrade 成功就进入会话首页，首次失败后进入自动重连也会进入，
  因此确实可能出现“还没有拿到 Bridge 数据就跳进去”。
- 已增加按规范化连接目标隔离的 session-home readiness gate：首次连接必须收到
  当前连接 epoch 的 authoritative `session_list` 才允许进入；同一目标已经成功
  进入过后，短暂 connecting/reconnecting 保留现有首页并显示重连状态；切换
  machine/URL 会清空 gate，不能借用上一台 Bridge 的就绪状态。
- 旧 session-created 消费缺少完整 request correlation；官方 1.109.2 新增的
  `resumeRequestId` 和 session-link coordinator 是应保留的修复基础。
- `Failed to get goal: No thread ID available for goal lookup` 是 Goal 请求在
  durable provider thread ID 尚未绑定前发出，不应在 UI 隐藏英文错误了事。
- 当前 `DesktopSessionListContinuityTracker` 会为已有 Codex runtime 建立 rollout
  watch；Bridge 也会把所有 active runtime 的流式增量广播到连接中的 Mobile，
  所以“后台同步”不是从零开始。但 tracker 在 Desktop 回合结束后会请求 canonical
  history，且最多只覆盖 Bridge 保留的 30 个 idle runtime；Conversation Mirror
  又是最多 8 个 full resident watch。两者都不能直接扩展成全会话机制。
- 全会话连续性应另加 metadata-only catalog change：只携带 durable
  provider identity、电脑侧修改时间、轻量状态/revision，触发 Mobile 合并和
  有界 recent 首屏刷新；未打开会话不请求 history、不解析工具、不启动第二个
  app-server。现有 active runtime message path 和打开后的 history delta 继续复用。

### 2A.3 Side Chat、辅助会话与配额

- 旧本地持久 Side Chat 是一套独立会话实现，与最终产品决定不符；脏工作树中
  仍有未提交实验，不能混入。
- 官方 app-server 的临时 thread/fork 生命周期应由 capability 和官方接口
  决定；没有可依赖的公开固定“半小时 TTL”契约，因此不能硬编码用户用于描述
  语义的时间。
- 现有原生 Side Chat 面板、输入和消息组件可复用，后端 thread 类型才是需要
  替换的部分。
- Spark 额度圆环选择错误已经确认：Bridge 的
  `account/rateLimits/read` 结果已经保留 `rateLimitsByLimitId`，其中可直接
  出现 `gpt-5.3-codex-spark` 卡片；但 Mobile 顶栏 selector 完全没有接收当前
  会话模型，只取第一张完整卡片/普通 Codex 总额度。不是额度数据本身缺失。
- 已把当前 runtime `codexModel` 作为只读 feature context 传给额度栏，按规范化
  后的完整 model ID 精确选择同名卡片；无同名卡时优先回退 `codex` 总额度，
  再回退旧 Bridge 的 legacy windows。不会用显示名称包含 `Spark` 的模糊判断，
  也不改变详情页展示全部额度卡片的行为。

### 2A.4 权限、审批和风险提示

- 会话权限同时受新会话默认值、recent factual settings、runtime
  `session_created`、permission restart、Mobile 本地持久化和 reconnect 更新；
  “变回 on request”不是单一 Switch 的问题。
- 已通过源码调用链和 live Bridge 只读快照确认根因：`SessionManager.list()`
  会把尚未知晓的 Codex approval policy 通过 process 默认 getter 发布成
  `on-request`；resume 在 Mobile 未传 override 且本地 JSONL 索引缺权限时，又会
  实际向官方 `thread/resume` 补入 `on-request + workspace-write`。当时 12 个
  active Codex runtime 中有 8 个缺索引权限，其中一个真实为 full access，因此
  这条回退既会污染 UI，也可能改变 thread 的生效权限。
- 已采用“显式 Mobile override > factual JSONL metadata > 不传、由官方 runtime
  解析”的顺序；bootstrap 的 session list/session_created 不再发明权限，官方
  init 返回真实设置后再广播。Mobile 对缺失权限信号保持既有状态。
- 已确认 Plan 首次退出后审批消失的两处竞态：Bridge 的真实 pending ledger
  被 `waiting_approval` 状态快照额外门控；Mobile 又会先恢复 runtime pending，
  随后被缓存或 canonical history 的 idle/stale 尾部清空。Plan 拒绝路径还会
  错误退出 Plan，并把其他待处理问题一并隐藏。
- 已确认 Guardian risk 虽然 Bridge 已携带 `targetItemId`，Mobile 仍把它当普通
  transcript row，process layout 完全没有消费该关联，所以会跑到过程外层并
  永久累积；修复应按 tool-use identity 归属，而不是用 CSS/Widget 绝对定位。
- 原生通知 category/actions 目前不存在；“长按通知 Allow/Reject”不能靠普通
  Flutter local notification payload 自动获得。

### 2A.5 通知和未读

- 分级通知原始本地提交链为：
  `2bb9bc30 → ac6f499e → 3b48055f`，在统一候选中以
  `f36d6e2d → 160e4815 → b375c951` 重放。
- 定位保活 notification-only 原始提交链为：
  `2c57364b → 804518fe → 90153726 → c45813a4 → 8d6f206a`，
  在候选中以
  `20e9bfb8 → eed7bb39 → 05cf9630 → 0c0a79ab → 0a387f91`
  重放，并由 `d94d15b1` 加固流式批次、重连和隐私边界。
- build 201 IPA 已确认包含原生和 Dart 能力，但当前 live Bridge
  `1.69.0-compat.6` 完全没有对应协议；因此即使手机安装了该 IPA，也只能得到
  `bridge_update_required` 或旧有限后台路径。
- Cloud relay 日志出现 `tokenCount: 0`，说明当次 FCM 无 token；它与本地
  location notification-only 是不同失败点。
- progress 偏好默认关闭；没有显式开启就不会生成中间进度。
- 当前未读状态主要依赖 active runtime/页面状态，缺少 durable
  thread+revision ledger，不能可靠跨 App 重启和多会话同步。
- 已确认旧时间显示不是单纯格式问题：`ChatEntry` 默认使用手机当前时间，
  canonical history 又只给用户项提供 provider timestamp，助手/工具项会继承
  上一个用户时间；因此旧 UI 的 `HH:mm` 可能同时混入手机同步时间、provider
  时间和父项时间。
- 已将 Bridge 首次接收实时 transcript 事件的墙钟时间作为 additive
  `receivedAt` 写入内存 history，并通过 live、delta/snapshot 和 canonical
  对账保留；provider history/Mirror 只写 `sourceTimestamp`，明确作为近似
  fallback。字段不要求能力协商，旧 Mobile 会安全忽略，旧 Bridge 仍可由新
  Mobile 按近似时间显示。
- Mobile 在解码层以 out-of-band metadata 保存来源，不扩散修改所有消息模型；
  optimistic 用户消息在 Bridge echo 到达后升级为电脑接收时间。每条可见消息
  均显示到秒，近似时间加 `~`，不再用“同发送者/两分钟”规则隐藏。
- Bridge 重启前未持久化的旧实时接收时间无法被事后精确恢复；此时只使用
  provider/Mirror timestamp 并保留近似标记，不能伪造精确电脑接收时间。

### 2A.6 文件和预览

- Agent 文件路径识别和 hyperlink 转换已经存在于
  `artifact-candidates`/`artifact-manager` 及 Mobile artifact link 路径；
  不得再写第二套正则解析器。
- 手动文件浏览和 Agent 引用最终已经能进入同一
  `ArtifactPreviewScreen`，分享、下载、进度和取消也已有实现。
- 现有 Dart 仍以有限扩展名白名单决定是否尝试 Quick Look，导致 JSON 等格式
  没机会交给设备 `canPreview`；native unsupported 后也没有完整自动本地回退。
- 互联网 URL、本地 HTML 和普通本地文件目前没有统一安全路由。
- 当前 live Bridge 监听 `*:8765` 且未配置 API key。全盘只读前必须先完成设备
  配对和所有 private endpoint 的共同认证，不能仅以“虚拟局域网自用”代替
  应用层边界。

### 2A.7 UI 状态和性能

- running 蓝条已有部分官方/本地实现；缺的是把“任务运行”和“history 正在增量
  对账”拆成两个权威状态。
- 当前旋转/光晕若直接监听大对象会造成无关重建；应使用小 selector、单一 ticker
  和不可见停机。
- 实施期已确认原旋转边框实际绑定 `inPlanMode && isActive`，而前台恢复路径会由
  `BackgroundSyncCoordinator` 对所有活动 session 发起有界 canonical/delta
  reconciliation；两者此前没有任何数据关联。
- 已在 `BridgeService` 增加会话级 foreground history sync transaction：
  只有请求真正写入健康 WebSocket 后才进入 syncing；history delta/snapshot/
  legacy history 应用完毕后退出。断线、Bridge 切换、旧 Bridge
  `get_history_delta` fallback、后台 delta-only 覆盖、重复请求和 20 秒失联超时
  均有明确收束；排队中的离线请求不会伪装为正在同步。
- `ChatSessionCubit` 用独立 `ValueNotifier<bool>` 接收当前会话的小粒度变化，不把
  动画状态塞入大 Freezed chat state；顶栏旋转边框改为蓝色 sync 信号，Plan
  仍由文字 chip 表示。任务横条只在严格 `running` 时蓝色脉冲，其余状态统一
  静态灰色。两处 painter 均加 `RepaintBoundary`，并在 Reduce Motion 与
  `TickerMode` 停机。
- 已重放的五组性能提交分别覆盖：
  流式 delta 合并、消息路径/工具预览、Mirror 清理与尾页、首帧/顶层 rebuild、
  Prompt History single-flight。官方 1.109.2 又修改图片恢复、Bridge
  websocket 和 session resume，合并后必须重新测量，不能把旧基准直接当完成证据。
- 旧性能审计仍留下 continuity watch fanout、Mirror active generation 扫描、
  resident full snapshot、首页组合复杂度、mDNS、图片缓存、artifact chunk
  rebuild 和真机动画能耗等未处理热点；最终全软件审计必须重新覆盖。

## 3. 官方更新整合

### 3.1 合并方式

1. 从干净候选 `99956f60` 建立新的 integration worktree 和安全分支；
2. 建立 pre-upstream safety ref；
3. merge `upstream/main@aa215a3b`，保留显式双亲；
4. 热点文件逐段语义合并：
   - `packages/bridge/src/codex-process.ts`
   - `packages/bridge/src/websocket.ts`
   - `packages/bridge/src/image-store.ts`
   - `apps/mobile/lib/services/bridge_service.dart`
   - `chat_session_cubit.dart`
   - `chat_message_list.dart`
   - `session_list_screen.dart`
   - `main.dart`
   - messages/freezed/l10n/generated router 文件
5. 官方会话 resume correlation、restore progress、图片缓存和 app-server
   hardening 为优先事实；本地 continuity、Mirror、通知、bounded history、
   图片引用和兼容字段作为增量接缝保留；
6. 合并后先完成 Bridge build、定向测试、Flutter analyze/test 和 iOS simulator
   build，再开始新的功能修改。

### 3.2 禁止做法

- 不因提交名相似就丢弃本地图片引用或官方生成图片画廊；
- 不保留两个相互独立的 session resume coordinator；
- 不让本地 notification-only raw frame filter 绕过官方 restore events；
- 不沿用冲突的 `1.108.1+201` 版本标识；
- 不从脏的 `feature/mobile-session-tools` 复制整目录。

## 4. 会话首页与直接使用

### 4.1 单一列表

- 首页只呈现一套 durable session list。
- running、waiting approval、unread、downloaded、syncing、offline、
  Bridge/machine 归属均为行内状态。
- 删除独立占据顶部空间的 resident/downloaded 区域；完整下载后只将下载图标
  变为勾号，不改变排序。
- 排序以 authoritative `lastActivityAt` 降序；相同时间使用稳定 durable ID
  作为 tie-breaker。自动同步、下载完成或 UI rebuild 不能把最近会话放到底部。

### 4.2 直接打开

- 点击任意已知会话立即进入，并先显示本地最近窗口。
- Bridge runtime attach/resume、interactive mode、增量对账在后台进行。
- 不再出现“先激活，再点第二次才能使用”的产品步骤。
- 官方 `session-link`/`resumeRequestId` correlation 应作为恢复基础；新建或恢复
  只消费与本次请求匹配的 `session_created`，不能被其他 socket/旧请求误导航。

### 4.3 全会话前台轻量同步

- App 在前台且 Bridge 已连接时，对所有已知会话接收 compact revision/status
  变化和必要的 changed-session delta。
- 未打开会话不建立完整聊天 runtime，不做全量 history、图片展开、代码高亮或
  工具结果解析。
- iOS 挂起或回收后不承诺常驻；恢复前台后按 durable thread ID +
  revision/sequence 追平。
- watcher 必须有总量、并发、速率和退避门槛，避免 N 会话 fanout 形成 N 个
  无界 app-server 读取。

### 4.4 实施期校正与已落地边界（2026-07-25）

- Mobile 已建立统一 projection：以 `provider + durable thread ID` 合并 running、
  recent 和 resident fallback；仅在新 runtime 尚未获得 thread ID 时保留一个临时
  runtime 行。同一 pin tier 内按电脑侧活动时间降序，时间相同按稳定 identity
  排序，不再继承 Bridge runtime `Map` 的插入顺序。
- 首页已移除独立 resident 与 running 分类；运行状态、未读、审批、停止、下载和
  同步能力继续使用原卡片行为，只是作为同一列表内的行内状态。resident metadata
  仍作为离线 fallback 合入列表，不会因取消顶部分类而失去入口；普通本地副本图标
  已改为勾，resident 自动同步仍保留独立 pin 状态。
- running 也执行 provider/project/named/search 过滤，避免 unified UI 在筛选时泄漏
  不匹配的 active row；pending resume 继续用专用占位卡，并隐藏其重复 catalog 行。
- 新 Bridge/Mobile 通过 `session_activity_at_v1` 协商，在既有 session frame 上附加
  Bridge 电脑时间，不新增每条 delta 的独立消息；Mobile 只在至少前进 1 秒时发布
  session-list 更新，避免流式输出每 32 ms 重建首页。旧客户端不收到字段，旧 Bridge
  下继续使用最近一次 authoritative session list 时间。
- “任意 recent 点击即进”的请求所有权已经按真实代码落地：Mobile 在发送前为每次
  新建/恢复建立独立 binding，新 Bridge/Mobile 通过
  `session_request_correlation_v1` 协商 `startRequestId` 和既有
  `resumeRequestId`；Bridge 在成功和失败事件中回显对应 ID。两个同项目请求、
  Desktop 自己创建的会话或上一条连接的迟到事件不再能抢占 pending 页面。
- pending 页面现在会在一次点击后立即打开，但前提是当前 WebSocket 已连接且已收到
  本代 authoritative `session_list`。连接选择页、重连早期或离线队列只登记请求，
  不自动进入消息页；全局 `session_created` 监听只分派事件，不再主动导航。
- 新 Bridge 的精确失败只关闭自己的 pending 页面并只清理对应 in-flight action；
  错误 request ID 不影响另一个请求。旧 Bridge 仍按 provider、project 和 durable
  provider session identity 做“唯一候选”兼容回退；若旧 Bridge 只返回无关联的
  全局启动错误，页面不会猜测归属，用户可返回首页后重试。
- 同一 start 的离线/重连去重会忽略 `startRequestId`，避免同一业务动作仅因重试
  UUID 不同而重复创建；Mobile 还会同时检查 queue 和尚未进入可见 action 列表的
  in-flight 请求，关闭原先约 650 ms 的重复点击窗口。
- “全持久会话 metadata-only catalog”已按真实存储布局落地：Bridge 只在至少一个
  支持 `session_catalog_watch_v1` 且处于 interactive 的客户端存在时，监听
  `~/.claude/projects`、`~/.codex/sessions` 和 Codex 的名称/CC Pocket 设置索引。
  为兼容 Node 18 及 macOS/Linux/Windows，没有依赖平台限定的 recursive watch，
  而是对浅层 provider 目录安装有 1024 目录总上限的非递归 watcher；目录增删会
  有界重建监听，最后一个前台客户端离开或进入 notification-only 后立即释放。
- 文件写入只产生 `session_catalog_changed_v1` revision，不读取完整历史、不创建
  runtime、不启动 app-server，也不把工具/图片正文推到手机；连续写入先 750 ms
  合并，并限制为最快 2.5 秒一次。Mobile 再做 250 ms 合并，同一时刻只允许一个
  catalog 请求，超时可恢复，按当前 project/provider/named/search 条件刷新。
- 自动刷新只重取已经可见的前 20–200 条 metadata；若用户已经加载更多，深层尾页
  原样保留，第一页的新增、更新、删除由 authoritative prefix 替换。Claude 与
  Codex 的去重键已从裸 `sessionId` 修正为 `provider + sessionId`；普通刷新、
  append、project 和 catalog 使用独立 `requestScope`，筛选切换仍能淘汰旧响应，
  catalog 不会激活会话或抢走用户正在加载的下一页。
- 旧 Mobile 不声明新 server message，Bridge 不启动 watcher；旧 Bridge 不广播
  revision，新 Mobile 继续保留手动刷新、连接恢复及回到前台时的有界 recent
  刷新。因此这一步关闭的是前台轻量目录同步，不改变 iOS 被挂起/回收时的能力承诺。

## 5. 分层历史和渐进披露

### 5.1 首次窗口

- 默认保留最近 5 个根用户回合及其 assistant 最终回复；
- 同时保留这 5 回合中的轻量中间文本、过程段落、临时会话摘要和工具 shell；
- 自动物化的工具详情全局最多 200 条，200 是详情预算，不是对话轮次预算；
- 超出预算的工具仍保留 identity、类型、状态、摘要、所属 segment 和详情计数，
  但正文/长结果不读取、不解析、不建 Widget。

### 5.2 向上分页

- 用户向上滚动时按 ordinal/keyset 增量加载更早的根回合和轻量 envelope；
- 不使用越来越慢的 OFFSET；
- 分页不得破坏当前视觉锚点；
- 完整下载与普通渲染窗口分离：本地可拥有全部历史，但每次只挂载有限页面。

### 5.3 按需详情

- 点击工具、过程或临时会话时，以稳定 item/tool/turn ID 请求对应详情页；
- 同一详情请求 single-flight、可取消、有 generation fence；
- 详情超过大小门槛时分页或截断显示，并保留下载完整结果入口；
- 旧 Bridge 无详情分页能力时使用有界兼容回退，不能一次拉取整个超长 transcript。

### 5.4 实施期校正（2026-07-25）

- 首轮深挖确认，一个 assistant envelope 可能同时含可见文本和多个工具调用，
  因此不能简单删掉整个旧 envelope；当前实现会保留 text/thinking spine，只剥离
  超出 200 预算的 tool input/result，并附加稳定的轻量 gap metadata。
- 新增能力均为 additive/capability-gated：
  `turn_aware_history_window_v1`、`history_page_v1`、
  `history_tool_detail_v1`；旧 Mobile 仍获得原来的平铺 200 条窗口。
- 工具详情只有在既有“中间过程”折叠被展开后才请求；每页最多 8 个唯一 tool ID，
  与工具组内部最多 8 行可见 viewport 对齐。请求按 gap single-flight，并受连接
  epoch、逻辑 Bridge identity、session ID 和当前 gap generation 约束。
- Mobile/Bridge 的内部硬上限由早期草案的 705 调整为 755 个轻重混合 envelope：
  这是 5 根回合、300 个普通 envelope、200 个完整工具调用（use/result 配对）和
  有界 gap shell 的安全总门槛，不是新的用户可见“消息条数”限制。
- 单个按需工具 input 和 result 文本在 Bridge 侧各最多 64 KiB，图片/附件元数据各
  最多 32 个；异常大字段显示截断标记，避免一次展开造成多 MiB 解码、布局和内存
  峰值。后续完整结果导出必须走独立下载入口，不能重新塞回聊天首屏协议。
- 已下载会话不要求在线 Bridge 才能展开旧工具。Mirror 使用现有 active generation
  和 JSON1 按最多 8 个 tool ID 精确读取匹配的 assistant/tool-result envelope，
  非支持 JSON1 的兼容宿主才走有界 fallback；不迁移 schema、不扫描或解码整段
  历史。读取前后校验 generation/revision/runtime identity，防止并发 patch 或
  会话重绑后发布旧详情。手机本地结果与远端缺失项按请求顺序合并。
- 在线 Codex 详情展开复用首次 `thread/read` 后已经保存在 session 的 canonical
  raw snapshot，只扫描身份并转换最多 8 个工具对应的少量 envelope；每个详情页
  不再重复触发 provider 全历史读取和全量 artifact enrichment。当前 live cache
  与 raw snapshot 按工具 ID 合并，连接或会话 identity 变化仍直接丢弃迟到结果。
- 无稳定非空 tool ID 的异常工具 payload 不进入完整预算，也不生成不可回取的
  gap；Mobile 与 Bridge 都在投影层丢弃它，防止畸形历史用匿名工具绕过 200 条
  详情预算。

## 6. 折叠、工具组和消息稳定性

### 6.1 稳定 disclosure identity

- 展开状态不能以 list index 或临时 Widget key 保存；
- 使用 durable thread ID + turn ID + segment ID + tool ID；
- partial → full、current progress → canonical history、Mirror → live runtime
  合并时迁移同一逻辑项的 disclosure 状态；
- 增量消息、history delta、普通 assistant 更新不得触发全局 collapse。
- 只有用户显式“一键全部折叠”、离开/切换到不同 durable 会话，或结构确实失效
  时才清理相关状态。

### 6.2 最多八个可见工具

- 一个已展开工具组的内部 viewport 最多显示当前宽度和 Dynamic Type 下约 8 个
  工具行；
- 更多工具通过组内纵向滚动查看，不截断、不丢弃；
- “8 个”是可见容量，不是数据上限；
- 处理内外滚动的手势交接、VoiceOver、键盘和滚动位置恢复；
- 不固定八个像素高度；应根据实测 row extent 和无障碍字号计算上限。

### 6.3 重复过程修复

- 对出现“中间过程 + 工具 + 最终回复按顺序重复两次”的真实会话，逐层比对：
  provider raw history → Bridge normalized projection → Mirror rows →
  Mobile reducer → render sections。
- canonical 与 live provisional 只能按稳定身份合并，不能按相同文本去重，也不能
  同时保留同一 item 的两种 envelope。
- 回归必须覆盖 streamed final、迟到 canonical snapshot、subagent tool log、
  history delta 和 reconnect。

## 7. 官方临时 Side Chat 与辅助悬浮窗

### 7.1 Side Chat

- 取消本地持久 Side Chat 产品类型。
- 已用当前安装的 Codex app-server schema 复核：官方可实现原语是
  `thread/fork` 并显式传 `ephemeral: true`；成功响应还必须满足
  `thread.ephemeral == true` 且 `thread.path == null`，即运行时内存线程而非
  另一条落盘会话；
- 生命周期和过期由官方运行时决定，Mobile/Bridge 不硬编码用户口述的“半小时”；
- 新 Bridge 以 `ephemeral_side_chat_v1` 暴露 live-only child registry：
  child 不进入 durable session list、不写 worktree/profile/additional-root 映射，
  仅在用户明确结束、父 runtime 被销毁或 Bridge 关闭时销毁；关闭/隐藏手机面板
  只移除 UI，不结束 child；
- capability 不可用时回退现有隔离式 ephemeral Side Chat 面板，不请求旧的
  persisted Side Chat，也不伪造另一种持久会话；
- 新路径直接复用普通 `CodexSessionScreen` 的输入、消息、审批、折叠和滚动套件；
  原有独立 Side Chat 面板只保留为旧 Bridge 兼容回退，不再造第三套界面。

### 7.2 App 内悬浮窗

- 建立一个 session auxiliary registry，统一登记：
  - 正在运行的子 Agent；
  - 官方临时 Side Chat；
  - 待处理审批/问题；
  - 必要的未读完成状态。
- 浮窗可拖拽、吸附屏幕边缘、半隐藏并可拉出；
- 浮窗挂在真实手机 Codex 会话页而非仅宽屏 Workspace；第一版提供临时会话
  registry 和原有 `SubagentsPanel` 两个页签，点击存活 child 可重新打开普通
  会话界面，明确“结束”才向 Bridge 发销毁请求；
- 关闭面板不销毁 registry 中仍存活的官方临时线程；
- 避免昂贵阴影、持续离屏合成和常驻 ticker；Reduce Motion/TickerMode 下停动画；
- registry 与具体 UI 解耦，后续 iPad 布局可替换而不改变会话协议。

## 8. 权限、审批和 Goal 一致性

### 8.1 权限回到 on request

- 已完成源码事件链和 live runtime/index 对照，确认两处最早错误状态：
  - session list 在 runtime bootstrap 未知时把 `CodexProcess` 的展示 fallback
    当成事实；
  - resume 在显式 override 和 indexed settings 都缺失时写入安全默认值，而不是
    让官方 runtime 保留/解析 thread 配置。
- 修复后的权威顺序：
  - 新/旧 Mobile 显式传来的设置最高；
  - JSONL 中确实存在的 per-thread 设置其次；
  - 两者都没有时不发送 approval/sandbox 字段；
  - 官方 `system/init` 的 resolved settings 到达后更新 SessionInfo 并广播；
  - bootstrap snapshot 缺字段时，Mobile 保留当前 toolbar 状态。
- session 当前生效配置、下一轮期望配置和默认新会话配置必须是三个字段；
- 当前配置只能由 authoritative session event 更新，不能被全局默认或迟到 history
  覆盖；
- 每次修改带 revision/effectiveFromTurn，断线后以 Bridge 确认值收敛。
- 兼容边界：旧 Mobile 的显式 legacy override 仍优先；有 factual index 的旧
  thread 仍精确恢复；新 Mobile + 新 Bridge 才获得 unknown-preserving 行为。

### 8.2 Plan 审批不应消失

- pending interaction 由 Bridge ledger 权威保存，不能只存在于一次弹窗 State；
- Bridge 发布 ledger 时不再依赖异步 status 快照；Mobile 在缓存、mirror 和
  canonical history 重建完成后重新叠加当前 runtime pending；
- 页面退出、首次未选择、history refresh、rotation 和 reconnect 后仍可恢复；
- resolved/rejected/expired 必须有明确终态和 generation；
- Reject `ExitPlanMode` 的官方语义是继续 Plan，不能把 `inPlanMode` 清零；批准、
  拒绝或回答一个 interaction 后都应推进到下一条真实 pending；
- 同一 interaction 只显示一处，避免底部卡片和过程卡片并存。

### 8.3 Guardian 风险提示

- Bridge 的结构化 `targetItemId` 关联到发起工具；迟到 review 仍回到原工具所在
  segment，不能被错误归到后来出现的工具；
- 风险附着在对应 tool/approval 下方，属于中间过程；当前进度只显示最新工具的
  最新一条；
- 当前外层提示使用单个按事件创建的 Timer，3 秒后仅视觉隐藏，不删除 transcript
  审计记录，也不引入常驻 ticker；
- 不在会话最底部累积多个永久卡片；
- 当前详情展开时排除已内联的 risk row，避免同一条显示两遍；历史 segment 内仍
  可展开查看结构化 risk/authorization 信息。

### 8.4 Goal 新建错误

- 已确认根因不仅是空 ID：resume 会在官方 app-server 完成
  `thread/resume` 前预填 durable ID，原实现又会在 socket connected、缓存 init
  和 live init 的 state 更新前分别触发读取，因此仍可能撞上
  `No thread ID available for goal lookup`；
- `thread/goal/get` 只有在 durable provider thread ID 已确定，并且收到当前
  `system/init` 或非 `starting` 的 authoritative runtime snapshot 后发送；
- 新会话创建阶段合并重复读取意图，等待匹配的 thread binding；用户主动刷新
  意图保留到就绪后，但不会提前显示底层错误；
- 缺 ID 时不请求、不显示原始 `No thread ID available` 错误；
- thread identity 发生变化时先清除旧 Goal/sequence，再读取新线程，避免跨会话
  短暂串值；
- 旧 Bridge 回退必须有界且不能把另一会话的 Goal 路由过来。

## 9. 导航、状态、额度和时间

### 9.1 不自动进入消息页

- 已将 transport 与首页就绪拆开：
  - WebSocket upgrade 只保留为传输层 `connected`，不直接推进 UI；
  - 首次连接只有收到当前 Bridge 的 authoritative `session_list` 后才从 IP/
    machine 选择页进入会话首页；
  - 首次连接失败后的 `reconnecting` 不会伪装成已经连接；
  - 已经进入首页的同一 Bridge 重连继续留在首页，并把“upgrade 完成但新
    session_list 未到”的间隙继续呈现为 reconnecting；
  - 目标 machine/URL 变化会清空 readiness latch，必须由新目标重新证明就绪；
  - 显式断开回到连接页，existing new/resume request correlation 继续负责
    chat 页面导航，连接状态本身不打开任何会话。

### 9.2 额度

- 已确认并接通 `ChatSessionState.codexModel → local feature context →
  SessionInsightsBar → rateLimitsByLimitId`：
  - 选择 `gpt-5.3-codex-spark` 时，两个额度圆环读取该模型卡片；
  - 普通模型没有专属卡片时读取 `codex` 总额度；
  - selector 使用完整 model ID 大小写无关精确匹配，不按显示名称模糊匹配；
  - 旧 Bridge 没有 named cards 时继续读取原有 five-hour/seven-day 字段；
  - model 切换会触发 Widget 重建并立即重新选卡，不额外请求、不增加轮询。
- 详情页仍显示 Bridge 返回的全部卡片，便于核对总额度、Spark 与未来新增限额；
  未知未来模型只走上述兼容回退，不被误识别成 Spark。

### 9.3 消息时间

- 已实现 Bridge 在首次接收实时 provider/transcript 消息时写入 `receivedAt`，
  精确到毫秒；SDK user echo 合并保留第一次时间，canonical history 与 live
  项匹配时继承该时间，delta/snapshot 原样发送。
- provider canonical history 和 Mirror 使用独立 `sourceTimestamp`，不会把
  provider 文件时间伪装成 Bridge 接收时间，也不会因每次同步生成新时间而让
  Mirror revision 抖动。
- Mobile 解码后保留时间值与 provenance；实时用户 echo 会替换 optimistic
  手机时间，历史窗口裁剪、Mirror 合并、重试和状态变更复制均保留 provenance。
- 每条可见消息显示本地时区 `HH:mm:ss`；精确 Bridge 时间无前缀，provider、
  旧 Bridge 或手机 fallback 显示 `~HH:mm:ss`。旧字段全部 additive，新旧
  Mobile/Bridge 可混用。
- 已补 Bridge history/delta 协议断言、Mobile 解码/handler/Cubit/widget 回归；
  timestamp 定向 Mobile 343 项和 Bridge 定向 2 项通过。Bridge 重启前没有
  持久记录的旧事件只能近似恢复，这是明确兼容边界而不是伪造精度。

### 9.4 运行与同步动效

- 顶部横条：会话任务 running 为蓝色，非 running 为灰色；
- 独立旋转光晕：仅在实际 history/session delta reconciliation 进行中显示；
- transport reconnect、普通 Widget rebuild 和任务运行不能冒充“消息正在刷新”；
- 两种动画使用隔离 selector、RepaintBoundary、单一 ticker，并在不可见/
  Reduce Motion/TickerMode 时停用。
- 已按上述语义实现并验证：前台请求开始/完成、离线排队后真实发送、旧 Bridge
  增量不支持时保持到 full-history 完成、后台 delta-only 不点亮、断线收束；
  状态/模式栏、Bridge、ChatSessionCubit 和后台协调定向测试共 229 项通过，
  相关 analyze 只剩
  `ChatSessionCubit` 两条既有 initializing-formal info。

## 10. 通知、未读与本地化

### 10.1 两条通知链路分开

1. Cloud/FCM：
   Cloud Function token 注册与远程推送；取决于真实 Firebase、APS entitlement、
   token 和部署版本。
2. owner 本地 notification-only：
   新基础 IPA 的 Always Location host 保持轻量 Bridge socket，由 Bridge 投影
   compact notification，Mobile 生成本地通知；不依赖 Cloud token。

UI 和诊断必须分别显示两条链路的 capability、权限、token、Bridge ack 和最后
事件，不能用一个“通知已启用”覆盖全部失败点。

### 10.2 定位保活可用门槛

- 安装包含 `backgroundLocationKeepAlive: 1` 和 permission host v3 的新基础 IPA；
- 用户显式开启实验开关；
- iOS 通知权限和 Always Location 两阶段授权完成；
- Bridge 部署 `background_notification_delivery_v1`；
- WebSocket 已连接且存在 active work；
- notification-only mode 收到匹配 requestId 的 ack；
- Low Power Mode 关闭、温控低于 serious；
- 进度通知偏好显式开启（默认关闭）；
- iOS 未回收进程且用户未 force-quit。

任一门槛失败时显示具体 phase。不能把“源码已有”“IPA 文件存在”或“开关保存”
描述为整条链路可用。

### 10.3 通知内容和未读

- action required、question、completed、failed、progress 全部使用确定性本地化文案；
- progress 仅工具阶段发生变化时产生，按 session 45 秒限流并去重；
- 完成/失败后为对应 durable session 写入 unread revision；
- 首页行显示蓝点；用户实际打开并读到相应 revision 后清除；
- unread ledger 持久化并按 machine/provider/thread/revision 识别，App 重启后保留；
- 当前打开会话不产生多余前台 banner，但仍更新状态。

### 10.4 通知长按批准/拒绝

- 新基础 IPA 注册原生 `UNNotificationCategory` 和 Allow/Reject actions；
- action payload 只携带 opaque pending interaction identity，不携带可伪造命令；
- App/Bridge 收到动作后重新验证：
  - 设备和连接 generation；
  - interaction 仍 pending；
  - session/thread identity；
  - action 尚未消费；
  - 当前策略允许该动作。
- 离线、过期、重复或已解决动作 fail closed，并给出已失效提示；
- 这是新的 native 边界，不能通过旧基础 IPA 的 Dart OTA 冒充已经支持。

## 11. 文件 authority、安全握手和预览

### 11.1 两套文件入口

- Agent 文件工具保持 provider 原机制；
- 手动文件管理独立存在；
- Agent 输出本地路径继续复用现有 artifact candidate/manager，不再造解析器；
- 两个入口共用 owner read authority、opaque capability、统一预览、下载和分享。

### 11.2 owner 全盘只读

- 只读覆盖 Bridge 进程在 macOS TCC/Unix/SIP 下真实可读的文件；
- 不受旧 project/cwd 产品白名单限制；
- canonicalize 路径、重新校验 symlink target、拒绝 traversal/NUL/非法 URI；
- Mobile/HTTP 不直接提交任意绝对路径，先由 Bridge 解析并签发短期 opaque token；
- token 绑定设备、连接、文件 identity、范围、过期和 read-only action；
- 目录列表和搜索分页、可取消、有超时和结果上限。

源码复核后的第一步实现边界（2026-07-25）：

- 现有 `BRIDGE_ALLOWED_DIRS=*` 在多数 Bridge 路径中已代表 unrestricted，但手动
  `FileBrowserManager` 会把空 roots 重新解释成 Home，因此此前并没有真正暴露
  全盘浏览；
- 自动 Agent artifact 已经有 owner/message/registry identity、短期随机 URL 和
  变更后拒绝读取，不需要重写路径解析器；真正的失败点是注册和 resolve 时再次
  套用了 session cwd/additional writable roots；
- 现在只有同时显式配置 `BRIDGE_ALLOWED_DIRS=*` 和非空 `BRIDGE_API_KEY` 时，
  Bridge 才会：
  - 给手动文件管理增加不泄露绝对路径的 `Mac` 根；
  - 允许 Agent 输出的真实外部本地文件登记为 exact-identity preview artifact；
- 未配置 API key 时仍只显示 Home/session roots 并打印警告；旧客户端、旧 Bridge
  和非 unrestricted 配置的既有行为不变；
- 这一步没有放宽 source editor，也没有接受 Mobile 传入任意绝对路径；外部引用
  只能由 Agent 消息候选解析、Bridge 实际检查和 registry 绑定后打开；
- artifact URL 当前已是高熵、短期、单文件 identity capability，但尚未绑定设备/
  connection；后续 endpoint 审计仍需决定是否在不破坏 WebView/Quick Look/
  分享的前提下再加一层设备会话约束。

### 11.3 连接安全先行

当前 live Bridge 监听所有接口且没有 API key。在开放 owner 全盘读取前必须：

- 建立显式设备配对和可撤销设备密钥；
- 所有私有 WebSocket/HTTP/artifact/gallery/file endpoints 共享认证边界；
- 防 replay、连接 generation 混用和跨设备 token 复用；
- Tailscale/可信局域网只是网络层，不替代应用认证；
- 认证验证使用内存常数时间检查和短 token，不对每个增量做昂贵密码哈希。

源码复核后的实现边界（2026-07-25）：

- WebSocket 和私有 HTTP 控制面现在复用同一个 `BRIDGE_API_KEY` authenticator；
  候选值先做有界 SHA-256，再用 `timingSafeEqual` 比较，不在消息增量热路径运行
  scrypt；
- `/usage`、`/doctor`、Gallery 列表/上传/删除全部进入私有 HTTP 门禁。新 Mobile
  从当前 WebSocket URL 取出已经保存在 Secure Storage 的 API key，以 Bearer
  header 发送，不新增明文持久化；
- 旧 Mobile 仍可在其已通过 API key 的直接 WebSocket 存活期间，从同一网络地址
  使用旧 HTTP 调用；该兼容口拒绝浏览器 `Origin`，socket 关闭后立即撤销。显式
  错误 Bearer 不会被兼容口放行；
- direct-loopback 例外现在同时要求没有 `Forwarded`/`X-Forwarded-*`。反向代理
  把远端流量转成本机 socket 时不能再借 loopback 绕过私有门禁；Artifact 与
  File Transfer 的本地 control endpoint 也复用此判断；
- `/health`、`/version` 保持公开，便于连接前探测；Artifact、Gallery 图片和
  内存图片保持 capability URL 读取，避免破坏 Quick Look/WebView/分享。内存图片
  ID 已从可预测内容哈希改成每进程随机密钥 HMAC；持久 Gallery 继续使用随机 UUID；
- Gallery HTTP 上传现在有约 10 MiB 图片/有界 JSON body、严格 canonical base64、
  MIME 白名单和字符串上限；远端 `filePath` 模式被关闭，只有无 Origin 的直接
  loopback + `x-ccpocket-control: 1` 才可复制本机路径；
- Gallery index 写入改成串行、`0600` 临时文件加原子 rename，避免中断时留下半份
  JSON。上述 Bridge build、WebSocket、Artifact、File Transfer、Gallery、Image
  和认证定向测试共 332 项通过；Mobile Bearer helper 2 项及定向 analyze 通过。
- 这仍不等于 live Bridge 已安全切换：当前 `1.69.0-compat.6` 运行态没有被重启。
  发布前还要在候选配置核对真实 API key、监听地址、反向代理/mDNS/Tailscale
  拓扑，并决定共享 API key 是否要进一步升级为逐设备可撤销密钥。

### 11.4 文件变更二次授权

- Mobile/Bridge 文件管理直接发起的 create/write/append/overwrite/move/rename/
  upload/delete 都必须 step-up；
- Bridge 本地保存慢哈希 verifier，不保存明文密码；算法以实施时可审计、跨平台、
  不增加脆弱依赖的方案为准；
- Face ID 路径使用 Secure Enclave 非导出私钥签名 Bridge challenge，不能相信
  `faceIdPassed: true`；
- challenge 绑定具体操作、canonical paths、file identity、设备、generation、
  nonce 和短 expiry，单次消费；
- 执行前再 stat/identity 检查，原子写入；删除默认进入废纸篓。

源码复核后的首个实现范围（2026-07-25）：

- 当前 Mobile 文件管理本身仍是只读；现有直接文件变更面只有“手机上传并在 Mac
  落盘”。没有为了看起来完整而提前增加 create/rename/move/delete；以后增加
  这些操作时必须复用同一 authorizer，不能另开旁路；
- Bridge 增加本地 `file-access` 管理入口。密码经内置 scrypt
  （固定版本化参数、独立随机 salt）生成 verifier，凭据文件使用私有目录、`0600`、
  no-follow 打开和原子替换；明文不写磁盘、命令行、普通日志或会话记录。选择
  scrypt 而不是方案初稿里的 Argon2id，是为了复用 Node 自带且可审计的实现，
  避免为这一条冷路径增加原生密码依赖；
- Bridge 在每次认证冷路径重新读取这一份很小的状态文件，因此 Mac CLI 修改密码
  后，运行中的 Bridge 下一次认证即可生效；聊天、历史、文件字节流和增量同步
  热路径不增加文件读取或密码哈希；
- 密码成功或 Secure Enclave 签名只授权一个精确 upload operation
  （client、Bridge instance、transfer ID、文件名、大小、nonce、expiry），
  Face ID challenge 每次验证尝试都会消费，断线会撤销；修改密码会撤销全部旧
  Face ID 公钥；
- iOS 私钥由 Secure Enclave P-256 与 `biometryCurrentSet` 保护且不可导出，
  Bridge 只保存公钥。Mobile 只在当前连接的 ephemeral RPC/prepare 帧中使用密码
  或签名，不进入离线队列、transfer checkpoint、SharedPreferences、Keychain
  或普通日志；取消、断线、机器切换、完成和 dispose 都清除内存中的待用证明；
- 兼容采用 `file_mutation_auth_v1`、`file_transfer_upload_auth_v1` 和 native
  `fileMutationBiometricAuth` additive capability。新 Bridge 要求 step-up 时，
  旧 Mobile 的 upload fail closed；新 Mobile 对旧 Bridge 保留原有上传；旧基础
  IPA 缺 Secure Enclave 插件时仍可输入密码，Face ID 明确 fail closed；
- 初版仍以“已认证的 Tailscale 加密连接”为密码传输边界，不把它写成公网密码
  协议。若将来开放非 Tailscale `ws://`，必须先增加 WSS 或 PAKE/等价应用层
  保护；本轮最终安全审计还要核对真实监听、配对以及所有私有 HTTP endpoint。

### 11.5 统一预览路由

```text
Internet URL -> 系统默认浏览器
Local HTML   -> 隔离的应用内只读 WebView -> 不支持时外部浏览器/分享
Local file   -> iOS Quick Look canPreview -> 本地有界预览器 -> metadata/download/share
```

- iOS 上不再由 Dart 扩展名白名单决定 Quick Look；由当前设备
  `QLPreviewController.canPreview` 最终判断；
- JSON 优先尝试 Quick Look，失败自动进入本地格式化/原文预览；
- 文本、代码、XML/YAML/CSV/日志有界读取；
- HTML/SVG/Markdown 隔离网络、file URL、任意 JS-native bridge 和跨源访问；
- 互联网 URL 直接跳系统浏览器，不把远程页面伪装成本地文件；
- 未知二进制显示 metadata、下载和分享，不猜编码；
- 复用现有 `ArtifactPreviewScreen`、下载、分享、进度和取消。

源码复核后的实现说明（2026-07-25）：

- 互联网 URL 原本就经统一 markdown link handler 使用系统外部浏览器，予以保留，
  不再造第二套路由；
- JSON 在 Bridge 原本已被归为 text，但只显示压缩原文；现在对完整且有效的有界
  JSON 先 pretty-print，损坏或截断内容仍回退原文，不把格式化失败变成 500；
- `.html/.htm/text/html` 从普通转义文本中独立为 `html` preview kind，经
  `/artifacts/<opaque-token>/sandbox` 打开；外层 iframe 与响应 CSP 双层 sandbox，
  只允许本文件 inline script/style/data/blob 资源，禁用网络、connect、frame、
  form、worker、object、base 和原生 JS bridge；
- iOS 仍由原生 `QLPreviewController.canPreview` 作最终判断。Dart 不再只对白名单
  Office 文件尝试 Quick Look，而是对 64 MiB 内的非 HTML 文件尝试；`unsupported`
  和旧基础 IPA 缺插件时自动进入现有 WebView/有界文本/metadata fallback，真实
  传输或 presentation 错误才显示重试；
- 64 MiB 自动 Quick Look 上限避免点开超大文件就完整下载；更大文件继续使用
  流式 WebView/metadata 和现有下载、分享入口；
- 普通 `/content` 仍保持原先 `sandbox; default-src 'none'`，只有经过类型复核的
  HTML token 才能进入专用 sandbox 路由。

## 12. 固定 UI 中文化

- 扫描 Dart/Swift/Bridge 直接面向用户的硬编码字符串；
- 连接、权限、审批、Goal、通知、文件、预览、同步和错误先进入现有 ARB 或
  feature strings；
- Bridge error 使用稳定 errorCode + Mobile 本地化，不依赖解析英文正文；
- 命令、代码、路径、provider 原文、日志和未知未来消息不机械翻译；
- 不引入本地翻译模型或免费翻译 API。

## 13. Bug 修复纪律

实施过程中发现新的 bug 或业务错误时：

1. 记录真实输入、权威状态、实际输出和预期；
2. 找到最早产生错误状态的层，而不是只在 UI 隐藏结果；
3. 判断是否同一根因覆盖多个症状；
4. 先写最小回归夹具，再修 owning layer；
5. 检查旧客户端、重连、迟到帧、相同文本不同身份和多设备；
6. 与当前任务无关、证据不足或需要产品选择的项登记后继续，不擅自改变语义。

## 14. 性能审计与优化

性能不是最后跑一次 analyze，而是贯穿实施并在功能完成后做全量收束。

### 14.1 每阶段门槛

- 记录变更前后事件数量、数据库查询、build 次数和数据尺寸；
- 新 reducer/selectors 保证未打开会话更新不重建整个 MaterialApp/Home；
- 流式 delta 合并保持首 delta 即时，后续使用有界批次；
- detail lazy load 不进入 collapsed build path；
- SQLite 使用 keyset/ordinal 和覆盖索引；
- 所有 subscription/timer/ticker/request 在生命周期结束后释放。

### 14.2 最终全软件审计

- 启动到首帧及首个可交互；
- 前台恢复到会话增量追平完成；
- 10k/100k 消息和高工具密度会话；
- 多会话 catalog delta fanout；
- 流式输出、当前进度和 Markdown rebuild；
- Mirror bootstrap、patch、tail paging、cleanup；
- 图片密集 session restore 和缓存；
- 文件列表、搜索、Quick Look 准备和大文件预览；
- 悬浮窗、quota ring、running bar、sync spinner 和 Effort 动画；
- 后台 location notification-only 的 CPU、网络、唤醒、电量和温控；
- Bridge RSS、event-loop latency、WebSocket send queue 和 provider read 并发。

### 14.3 验收方法

- 合成微基准用于定位热点，不替代真实 session；
- Flutter DevTools frame/build/Raster、Xcode Instruments、Node profiler 和
  SQLite query plan 按需要使用；
- 真机至少验证长会话滚动、前台 catch-up、动画、电量和后台通知；
- 优化不得删除核心同步反馈或静默降低历史上限。

## 15. 实施阶段与提交拆分

### Phase 0：方案、基线和安全工作区

- 提交本文及手册入口；
- 创建新 integration worktree；
- 保存 branch/HEAD/remote/status/runtime/IPA 清单；
- 建立 pre-upstream safety ref。

### Phase 1：官方 1.109.2 语义整合

- 一个显式 upstream merge commit；
- 冲突加固和版本/build 修正使用独立 commit；
- 完成基线 Bridge/Flutter/iOS 回归。

### Phase 2：统一 session projection

- Bridge durable identity/revision/catalog delta；
- Mobile normalized store/reducer；
- 单一首页、排序、直接打开、unread 基础和同步状态。

### Phase 3：分层历史与 disclosure

- turn-aware envelope/detail 协议；
- 最近 5 回合 + 200 工具详情预算；
- keyset paging；
- 8 行工具 viewport；
- disclosure/scroll identity 和重复过程修复。
- 当前完成：稳定 cursor 的更早回合分页、旧工具 gap 投影、展开后每批 8 个详情、
  连接/历史代际 fence、字段与附件上限、Mirror 离线按 ID 精确读取；仍需在最终
  全链审计中用真实超长会话样本复核投影、滚动锚点和内存峰值。

### Phase 4：临时会话与辅助悬浮窗

- 官方 ephemeral side thread adapter；
- 复用原生前端；
- auxiliary registry；
- 浮窗、吸边、隐藏、恢复和性能门槛。

### Phase 5：权限与业务一致性

- 权限 factual/desired/revision；
- pending interaction ledger；
- Plan/Guardian；
- Goal correlation；
- 导航、Spark quota、消息时间和状态动效。

### Phase 6：文件和安全

- 配对认证与统一 private endpoint boundary；
- owner read authority；
- Agent 引用和手动文件入口收束；
- Quick Look/HTML/JSON/fallback/download/share；
- 密码 step-up；
- Secure Enclave + Face ID。
- 当前完成：owner 全盘只读的显式配置门槛、Agent 外部引用的 exact artifact
  映射、统一 Quick Look/HTML/JSON fallback、Bridge 密码 verifier、operation
  step-up、Secure Enclave Face ID、Mobile upload 接线、私有 HTTP/WebSocket
  统一认证、旧 Mobile 同地址兼容、不可预测图片 URL 和 Gallery 上传边界；
- 仍未完成：在候选运行配置上确认真实监听地址、API key、反向代理、mDNS/
  Tailscale 和旧客户端降级，并在全功能结束后再做一次跨模块安全复审。完成这些
  检查前不能替换 live Bridge。

### Phase 7：通知和本地化

- 分级通知链路和诊断；
- location notification-only 真正可部署路径；
- unread；
- 原生 Allow/Reject actions；
- 全部固定 UI 中文化。

### Phase 8：完整审计、性能收束和发布候选

- requirement-by-requirement 功能/兼容/安全审计；
- 全软件性能测量和窄优化 commits；
- Bridge/Cloud 候选构建，但不未经审查直接替换 live runtime；
- 分配新基础 build，构建 IPA；
- 包结构、原生 capability、签名输入和 AltStore 安装门槛；
- 物理 iPhone 验收后再决定 owner OTA 或 stable。

## 16. 兼容矩阵

| 组合 | 预期 |
|---|---|
| 旧 Mobile + 新 Bridge | 原会话、历史和文件行为保持；未知新事件被 capability 下转换或忽略 |
| 新 Mobile + 旧 Bridge | session/notification/file 新入口明确降级；不发无界 fallback，不允许未授权 mutation |
| 新 Dart + 旧基础 IPA | 缺 native capability 的 location、Face ID、通知 action fail closed；普通前台功能继续 |
| 新基础 IPA + 旧 Dart | 新 native plugin dormant；旧 Dart 行为不变 |
| 新两端 + iOS 挂起/回收 | location opt-in 时尽力接收本地通知；被回收或 force-quit 后等待前台 catch-up |
| 无 FCM/APS | Cloud 锁屏推送不可用；前台、本地 notification-only 和会话同步分别按自身门槛工作 |
| owner read + 旧 Mobile | 只允许旧协议可安全表达的读取；所有新 mutation fail closed |

## 17. 验证清单

### Bridge

- TypeScript build；
- parser/protocol/capability；
- app-server active writer/archived/recovery；
- resume correlation；
- session catalog/delta/detail；
- canonical/live/Mirror dedup；
- notification projection/privacy/rate limit；
- auth/replay/symlink/TOCTOU/file limits；
- multi-client and old-client fixtures。

### Mobile

- targeted unit/widget tests；
- full Flutter tests；
- `flutter analyze`；
- generated code consistency；
- 5-turn/200-tool/8-row/disclosure；
- reconnect/lifecycle/navigation/Goal/permissions；
- Quick Look/HTML/JSON/share/download；
- unread/notification actions/localization；
- iOS simulator build/install/launch。

### 真机

- AltStore 重签后 capability snapshot；
- Always Location 两阶段授权和系统指示；
- lock-screen approval/progress/completion；
- 通知长按 Allow/Reject；
- foreground catch-up 和 unread 清除；
- Face ID enrollment/challenge/revocation；
- project 外 Agent 引用和 owner 文件预览；
- 长会话、动画、后台电量和温控。

## 18. 完成定义

只有以下条件同时满足才可称为本轮完成：

1. 本文每个显式需求有源码、测试或明确不适用证据；
2. 官方 `aa215a3b` 或实施时更新的更高官方 HEAD 已语义整合；
3. 新旧 Mobile/Bridge/native 兼容矩阵通过；
4. 当前运行 Bridge 是否替换有独立、可验证记录；
5. 新 IPA 使用唯一版本/build，包内能力与源码一致；
6. 全软件性能审计完成，发现的确定性回归已修复；
7. 安全审计覆盖配对、HTTP/WebSocket、全盘读取和 mutation step-up；
8. 工作树干净，commits 按行为拆分，构建产物未混入 Git；
9. 剩余只能由物理设备或用户视觉判断的门槛被明确列出，不能用模拟器代替。
