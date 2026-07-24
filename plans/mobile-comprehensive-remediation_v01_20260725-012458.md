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
- Spark 额度圆环选择错误已经定位为 quota selector 仍使用普通总额度分类，
  不是额度数据本身缺失。

### 2A.4 权限、审批和风险提示

- 会话权限同时受新会话默认值、recent factual settings、runtime
  `session_created`、permission restart、Mobile 本地持久化和 reconnect 更新；
  “变回 on request”不是单一 Switch 的问题。尚缺一次真实复现的完整事件顺序，
  所以计划采用 factual/desired/revision 模型而不是先改 UI。
- Plan 首次退出后审批消失最可能是 pending interaction 只附着当前 runtime/UI，
  又被 history/session replacement 清理；必须以 Bridge pending ledger 和真实
  事件序列验证。
- Guardian risk 当前作为普通 transcript/system row 进入渲染，因此会跑到过程
  外层并累积；目标是按 tool-use identity 归属，而不是用 CSS/Widget 绝对定位。
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
- 当前部分时间戳来自手机收到/重建时 fallback 或父项继承，尚未把电脑 Bridge
  首次接收时间作为稳定字段贯穿 history/Mirror。

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
- 本节尚未宣称完成“任意 recent 点击即进”和“全持久会话 metadata-only catalog”；
  两者仍须分别完成 request correlation 与文件目录变更监听后再关闭 Phase 2。

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
- 通过 Codex app-server 当前实际支持的官方临时 thread/fork 接口创建；
- 生命周期和过期由官方运行时决定，Mobile/Bridge 不硬编码用户口述的“半小时”；
- capability 不可用时隐藏或明确提示，不伪造另一种持久会话；
- 复用现有原生 Side Chat 前端外壳、输入、消息、审批和滚动组件，不重造对话框。

### 7.2 App 内悬浮窗

- 建立一个 session auxiliary registry，统一登记：
  - 正在运行的子 Agent；
  - 官方临时 Side Chat；
  - 待处理审批/问题；
  - 必要的未读完成状态。
- 浮窗可拖拽、吸附屏幕边缘、半隐藏并可拉出；
- 关闭面板不销毁 registry 中仍存活的官方临时线程；
- 避免昂贵阴影、持续离屏合成和常驻 ticker；Reduce Motion/TickerMode 下停动画；
- registry 与具体 UI 解耦，后续 iPad 布局可替换而不改变会话协议。

## 8. 权限、审批和 Goal 一致性

### 8.1 权限回到 on request

- 建立一次真实复现的事件时间线，追踪：
  - recent session factual settings；
  - session resume 请求；
  - `session_created`/session list；
  - Bridge permission restart；
  - Mobile settings persistence；
  - reconnect 和 lifecycle。
- session 当前生效配置、下一轮期望配置和默认新会话配置必须是三个字段；
- 当前配置只能由 authoritative session event 更新，不能被全局默认或迟到 history
  覆盖；
- 每次修改带 revision/effectiveFromTurn，断线后以 Bridge 确认值收敛。

### 8.2 Plan 审批不应消失

- pending interaction 由 Bridge ledger 权威保存，不能只存在于一次弹窗 State；
- 页面退出、首次未选择、history refresh、rotation 和 reconnect 后仍可恢复；
- resolved/rejected/expired 必须有明确终态和 generation；
- 同一 interaction 只显示一处，避免底部卡片和过程卡片并存。

### 8.3 Guardian 风险提示

- 风险附着在对应 tool/approval 下方，属于中间过程；
- 外层只显示当前最新一条，3 秒后仅视觉隐藏，不删除审计记录；
- 不在会话最底部累积多个永久卡片；
- 结构化 risk/authorization 信息继续可展开查看。

### 8.4 Goal 新建错误

- `thread/goal/get` 只有在 durable provider thread ID 已确定后发送；
- 新会话创建阶段由 correlation router 等待匹配的 thread binding；
- 缺 ID 时不请求、不显示原始 `No thread ID available` 错误；
- 旧 Bridge 回退必须有界且不能把另一会话的 Goal 路由过来。

## 9. 导航、状态、额度和时间

### 9.1 不自动进入消息页

- WebSocket TCP open 只表示 transport connected，不表示 Bridge handshake、
  machine identity、session list 或目标 session ready；
- connection picker 不因 `connected` 字段提前跳转；
- 仅用户选择的连接请求和匹配 correlation 的 ready/handshake 可推进导航；
- 自动重连只更新状态，不抢占当前页面。

### 9.2 额度

- 选择 Spark 模型时，额度圆环读取 Spark 对应窗口；
- 普通模型读取普通总额度；
- quota selector 由实际 model/service tier 分类，不按显示名称字符串模糊匹配；
- 未知未来 tier 显示 generic/unknown，不误标为普通额度。

### 9.3 消息时间

- Bridge 在首次接收 provider 消息时写入 `receivedAt`，精确到毫秒并原样保留；
- Mobile 显示到秒 `HH:mm:ss`，必要时可展开日期；
- history replay、Mirror 写入和手机同步不得覆盖原始时间；
- 旧消息缺时间时使用明确 fallback，并不得伪称为电脑首次收到时间。

### 9.4 运行与同步动效

- 顶部横条：会话任务 running 为蓝色，非 running 为灰色；
- 独立旋转光晕：仅在实际 history/session delta reconciliation 进行中显示；
- transport reconnect、普通 Widget rebuild 和任务运行不能冒充“消息正在刷新”；
- 两种动画使用隔离 selector、RepaintBoundary、单一 ticker，并在不可见/
  Reduce Motion/TickerMode 时停用。

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

### 11.3 连接安全先行

当前 live Bridge 监听所有接口且没有 API key。在开放 owner 全盘读取前必须：

- 建立显式设备配对和可撤销设备密钥；
- 所有私有 WebSocket/HTTP/artifact/gallery/file endpoints 共享认证边界；
- 防 replay、连接 generation 混用和跨设备 token 复用；
- Tailscale/可信局域网只是网络层，不替代应用认证；
- 认证验证使用内存常数时间检查和短 token，不对每个增量做昂贵密码哈希。

### 11.4 文件变更二次授权

- Mobile/Bridge 文件管理直接发起的 create/write/append/overwrite/move/rename/
  upload/delete 都必须 step-up；
- Bridge 本地保存 Argon2id verifier，不保存明文密码；
- Face ID 路径使用 Secure Enclave 非导出私钥签名 Bridge challenge，不能相信
  `faceIdPassed: true`；
- challenge 绑定具体操作、canonical paths、file identity、设备、generation、
  nonce 和短 expiry，单次消费；
- 执行前再 stat/identity 检查，原子写入；删除默认进入废纸篓。

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
