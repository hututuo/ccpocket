# CC Pocket 会话同步 v2：实施、性能、安全与交付审计

状态：`validated source candidate`

日期：2026-07-30

## 1. 审计范围与边界

本报告对应《CC Pocket 会话同步、性能收束与最终交付实施计划》，审计范围从
Provider/app-server 一直覆盖到 Bridge、协议、Mobile SQLite、状态投影、UI、
iOS 原生宿主、构建和运行时交付。

权威边界不变：

```text
Codex app-server / Claude / legacy rollout
                ↓
Bridge provider adapters
                ↓
Bridge directory + status + sync state engine
                ↓
one authenticated WebSocket
                ↓
Mobile staging + SQLite
                ↓
repository/reducer/UI
```

- Provider 历史是权威数据；Mobile SQLite 是可重建副本。
- 目录和只读历史同步不得 `resume` 或取得写入权。
- IP、Tailscale 地址和域名只是连接路线；正式数据身份是认证后的
  `(bridgeInstanceId, codexSourceId)`。
- 新协议全部通过 capability negotiation 加法接入。
- 本报告中的源码、测试、构建、Bridge 部署、IPA、物理设备、Shorebird
  `owner` 与 `stable` 是彼此独立的门禁。

## 2. 基线、上游与提交线

- 起始基线：`c9499403e7771985276d444d606ae4847cff6402`
- 官方上游：`upstream/main@c53fe420d197de64488a53c6f6de071231732aac`
  (`1.110.1+204`)
- 开发分支：`feature/mobile-tiered-session-sync-20260730`
- 最终集成分支：`integration/mobile-session-sync-v2-20260730`
- Mobile 候选版本：`1.110.1+206`
- Bridge 候选版本：`1.69.4-compat.4`

官方 1.110.1 以 merge commit `7e74f678` 接入，保留官方 subsession 设计、
HTML 预览、WebView 依赖、预览滚动修复和版本变化。冲突按语义合并处理，
没有用旧本地文件覆盖新版官方文件。

当前功能提交按依赖顺序为：

1. `af914d57`：显示逐条消息的真实事件时间。
2. `41729eec`：官方临时会话只使用实时内存历史。
3. `829fc82f`：悬浮窗按当前主会话隔离临时会话和子 Agent。
4. `5abe35f5`：悬浮窗自由拖动、贴边、折叠和统一位置。
5. `5db5e453`：显示连接、认证、目录和状态刷新阶段。
6. `6952482f`：未读优先并投影会话状态。
7. `801af2bc`：项目/最近聊天双模式。
8. `78ee2ee7`：重要会话始终可见。
9. `f900d768`：Bridge 读取 app-server 目录和权威状态。
10. `9786dfed`：Bridge 增加 state token、分层同步和分页协议。
11. `8aa7ad8a`：Mobile 持久化目录、状态、时间线、缺口和同步 state。
12. `44eb2487`：状态投影、首页 readiness 与显式缓存进入。
13. `f836cfa6`：持久会话本地优先打开并延迟 live attach。
14. `608ed178`：按轮次渐进加载持久会话历史。
15. `cb8f58b8`：按 provider 轮次渐进加载工具详情。
16. `2e398341`：按数据源和会话精确清理缓存。
17. `1e830798`：Mobile build 206。
18. `1bd02160`：同步调度合并、竞态修复、身份缓存迁移和性能基准。
19. `61fdf931`：Bridge API key URI 编码和受影响依赖升级。
20. `41a49d32`：Bridge compat.4 候选版本。

## 3. 原始需求逐项台账

| 原始产品要求 | 方案/实现证据 | 当前状态 | 验证证据 |
|---|---|---|---|
| 所有持久会话直接可读，不再点开后激活 | `conversation_sync_v2`、`conversation_content_sync_service.dart`、`durable_session_preview.dart`、`pending_session_binding.dart` | 已完成并验证 | Bridge/Mobile 全量测试；本地缓存打开 p95 见性能表 |
| Bridge 负责目录、状态、Need You、revision 和调度 | `codex-process.ts`、`local-features/runtime.ts`、`conversation-sync-v2.ts` | 已完成并验证 | Bridge 1857 项；首次状态/增量/重连专项覆盖 |
| idle 不显示 Ready，unknown 不伪装成 Ready | `session_list_projection.dart`、`session_card.dart` | 已完成并验证 | `session_card_test.dart`、`session_list_projection_test.dart` |
| Working 与 Need You 可同时存在，Need You 显示优先 | 复合状态协议和 projection 优先级 | 已完成并验证 | Bridge v2 状态测试、Mobile 投影测试 |
| 首次连接先准备特殊状态和最近会话，再进入首页 | `session_list_screen.dart`、`session_list_cubit.dart`、`connect_form.dart` | 已完成并验证 | `home_screen_test.dart`、`session_list_cubit_test.dart` |
| WebSocket 变绿不能自动进入；缓存进入必须用户选择 | readiness 阶段、三秒缓存操作入口 | 已完成并验证 | 首页和连接阶段 widget 测试 |
| 不先显示整页 No description | 目录 commit 门禁和 skeleton | 已完成并验证 | `home_content_skeleton_test.dart` |
| 第一层全部 Working/Need You/Error/未读实时同步 | Bridge status ledger、priority catalog、实时事件调度 | 已完成并验证 | 特殊状态首次批量、事件更新、watchdog 测试 |
| 第二层最近三天且至少十个，最近五轮/三轮完整/200 工具预算 | v2 tier policy、turn shell、detail budget | 已完成并验证 | Bridge v2 和 Mobile paging/protocol 测试 |
| 第三层冷会话只保存目录和 revision，长周期对账 | Bridge cold tier/state token | 已完成并验证 | synthetic 1500 会话基准；无变化正文读取为 0 |
| 手机只使用一条同步 WebSocket，不逐会话建连接 | v2 订阅在现有认证 WebSocket 内复用 | 已完成并验证 | 多订阅/多客户端/重连测试 |
| 逻辑大包物理分帧、ACK 后推进 state | `conversation_sync_v2` protocol slot | 已完成并验证 | 最大帧 57,638 B；单轮未 ACK 804,019 B |
| 同步结果写 staging，成功后原子提交 | `session_catalog_cache_database.dart`、repository staging API | 已完成并验证 | staging/generation/rollback 测试与内存基准 |
| 打开会话先渲染 SQLite，不重复拉整段历史 | `durable_session_preview.dart` 和 delayed binding | 已完成并验证 | `durable_session_preview_test.dart`、input 测试 |
| 向上滑按 turn 分页，展开工具时再取 items | turns page + provider item-detail fallback | 已完成并验证 | local history paging、v2 detail tests |
| 最近五轮结构、三轮完整、200 条工具预算不是硬截断 | gap/cursor/sourceEntryCount 和显式 truncation marker | 已完成并验证 | paging/protocol/large snapshot tests |
| 正在运行的当前 turn 不受历史 200 条预算限制 | live revision ledger 与实时 delta 路径 | 已完成并验证 | 100 live delta 合并测试 |
| 增量更新不能折回已经展开的中间过程 | 稳定 item/turn identity；UI expansion state 不绑定 snapshot 实例 | 已在当前线验证 | 全量 UI 折叠测试；设备视觉仍需用户确认 |
| 工具展开框最多约八行并内部滚动 | 当前基线 process surface 的有界 viewport | 已在当前线验证 | 现有 process surface widget 回归；视觉待真机 |
| thinking、tools、result、guardian 在同一过程面板 | 当前基线两层过程树及稳定 interval ownership | 已在当前线验证 | 全量消息/折叠回归；视觉待真机 |
| 时间戳显示真实消息产生时间，不显示同步时间 | `af914d57` 贯穿 parser/history/model/UI | 已完成并验证 | Bridge timestamp 与 Mobile model/handler tests |
| 官方临时会话不得请求 `includeTurns` | `41729eec` 使用实时内存历史 | 已完成并验证 | `websocket.test.ts` |
| 悬浮窗非模态、可拖动贴边折叠，不阻断底层 | `auxiliary_floating_dock.dart` | 已完成并验证 | dock widget tests；视觉待真机 |
| 每个主会话只显示自己的临时会话和子 Agent | `829fc82f` + Bridge subagent ownership | 已完成并验证 | dock/subagent tests |
| 最近聊天按最近使用排序，重要状态始终可见 | projection 双模式、未读优先和 important union | 已完成并验证 | projection/home tests |
| 完成未读显示蓝点，并由手机 read watermark 管理 | status sync + SQLite watermark | 已完成并验证 | cache/projection/unread tests |
| 同一台 Bridge 的不同 IP 共享数据与缓存 | 认证身份 `(bridgeInstanceId, codexSourceId)`；路线只用于连接 | 已完成并验证 | identity migration、跨 IP、route-only fail-closed tests |
| 身份未确认时不得重放写操作或误迁缓存 | offline queue identity fence；legacy endpoint cache 保持隔离 | 已完成并验证 | replay 和 cache migration security tests |
| API key 含 `+ / & #` 等字符仍能正确认证 | `withBridgeApiKey` 统一 URI 编码 | 已完成并验证 | `network_endpoint_test.dart` |
| 设置可一键、按机器、按数据源、按会话清缓存 | `cache_management_screen.dart`、repository precise delete | 已完成并验证 | cache management tests |
| 普通清缓存不能删除草稿、凭据、设置和传输断点 | 清理仅作用于 rebuildable session cache tables | 已完成并验证 | repository scope tests |
| HTML 本地文件应用内安全预览，互联网 URL 交给浏览器 | 官方 HTML preview + navigation gate | 已在当前线保留并验证 | Bridge artifact 129 项、Mobile preview 90 项 |
| JSON/文本使用本地预览，Office 等优先 Quick Look | artifact preview、File Peek、Quick Look fallback | 已在当前线保留并验证 | RunnerTests Quick Look 3 项及 Mobile preview tests |
| 预览提供下载和分享；全盘可读不再因旧根目录失败 | token 化 artifact read/download/share；全盘读需显式 `*`+API key | 已在当前线保留并验证 | artifact/transfer/security suites；真机文件选择待验收 |
| 修改/删除需 Bridge 密码或 Face ID，不限制 Agent 原机制 | mutation verifier + biometric challenge；Agent path 保持原协议 | 已在当前线保留并验证 | Bridge security tests、Runner native auth bounds |
| 请求审批通知可长按允许/拒绝 | 原生 notification action + opaque payload | 已在当前线保留并验证 | RunnerTests notification action 2 项；真机待验收 |
| 通知分类、中文、本地完成/进度/审批和未读 | notification settings、Bridge projection、Mobile local notification | 代码完成，外部验收未完成 | Bridge/Mobile/Functions tests；APNs/FCM 和物理后台待验收 |
| Always Location 仅维持轻量通知，不上传坐标 | background keep-alive host + notification-only mode | 代码完成，物理设备待验收 | RunnerTests、iOS build；真实后台时间/功耗未声明通过 |
| 前台恢复按 state token 补差，不后台同步正文 | background coordinator + v2 unsubscribe/foreground catch-up | 已完成并验证 | lifecycle/notification/background tests；物理设备待验收 |
| 状态蓝条和同步光晕只反映真实运行/commit | activity projection 和 conversation sync commit state | 已在当前线验证 | UI 状态测试；动效视觉与能耗待真机 |
| 不自动跳入未准备页面、不显示“正在创建会话” | readiness gate + local-first session screen | 已完成并验证 | home/input/pending binding tests |
| 新会话不能因无 thread ID 查询 goal 报错 | 当前基线延迟 goal/session binding | 已在当前线回归 | Mobile 全量测试；真实新建流程待设备 smoke |
| 权限不得在打开/附着会话时退回 On Request | 权限 hydration 与会话 attach 解耦 | 已在当前线回归 | 权限与 settings 测试；物理设备待验收 |
| Spark 模型额度使用 Spark quota | 当前基线模型/usage 投影 | 已在当前线回归 | usage 和模型选择测试 |

## 4. 计划假设与当前实现偏差

### 4.1 app-server 没有 `thread/items/list`

原计划假设当前 app-server 支持 `thread/items/list`。对本机
Codex `0.146.0-alpha.3.1` 的实际 schema/runtime 探测显示该方法不受支持。

等价实现：

1. `thread/turns/list(itemsView:"summary")` 获取轮次外壳；
2. 对有限窗口使用 `thread/turns/list(itemsView:"full")`；
3. 最近三轮保留完整 items，较旧轮次保留 shell/gap/cursor；
4. Bridge 维护按 turn 的 detail cache；
5. 展开时通过 v2 detail request 返回最多八个 item；
6. legacy provider 只在其适配器能够证明 cursor 被消费且读取有界时分页；
   不具备 bounded turns/items RPC 的旧 app-server 明确返回不支持，不做整份
   rollout 扫描。

该实现仍满足“按需渐进披露、不 resume、不全量扫描、不静默截断”的产品
约束。当前 app-server 的能力名为 `conversation_items_by_id_v1`；旧
app-server 的文件窗口兼容缺口见本文末 newest-turn addendum。

### 4.2 身份未确认时的旧缓存

原计划要求同一 Bridge 的路线共享缓存，同时要求身份确认前不得误合并。
因此未认证的 endpoint-only 旧缓存不会直接迁入 source-scoped 正式分区。
认证后同一 `(bridgeInstanceId, codexSourceId)` 的路线共享正式缓存；
下一次连接可以使用已保存的稳定身份 hint 预热。该 fail-closed 行为已有
专门回归测试。

### 4.3 Need You 的跨进程可见性

Codex app-server 的 request/status 生命周期是权威来源；Bridge 自己托管的
运行时使用 request ID 台账。若独立 Desktop/Claude 进程没有向 Bridge
暴露 request 生命周期，Bridge 标记 unknown/degraded，不从正文猜测
Need You，也不伪装为无待办。

## 5. 数据一致性和竞态审计

最终审计确认并修复两项真实问题：

1. **历史读取与实时 delta 竞态**：读取开始后若同一会话收到实时 revision，
   可变 catalog record 会让旧历史被错误标记成新 revision，进而漏掉第二次
   读取。现在读取前冻结目标 revision，旧结果只能按旧 revision 提交，
   live ledger 会触发后续补读。
2. **Bridge API key URL 拼接**：旧代码直接把 key 拼到 query string，
   `+`、`&`、`#` 等合法字符会改变解析结果。现在统一通过 `Uri.replace`
   编码并替换旧 token。

调度收束：

- catalog refresh 是 single-flight dirty loop；
- 同一次目录变化只刷新一次并扇出给所有客户端；
- live delta 使用一个全局 32 ms coalescer；
- Need You/status 事件立即发送，不触发历史重读；
- 每个会话的 live revision ledger 有界保留；
- timer 异常不会让调度器永久停止；
- 100 个 live delta 的回归只产生一次历史读取和零次目录扫描。

## 6. 性能结果

### 6.1 Bridge

| 指标 | 结果 | 目标 |
|---|---:|---:|
| 实际 state DB 302 条目录 p95 | 19.675 ms | 1500 条 p95 < 500 ms |
| 合成 1500 条 priority p95 | 15.321 ms | 首批 < 2 s |
| 合成 1500 条 complete p95 | 28.937 ms | 首批 < 2 s |
| 首次历史读取 | 14 | 有界 |
| 无变化重复同步历史读取 | 0 | 0 |
| provider history 最大并发 | 2 | ≤ 2 |
| 最大 WebSocket frame | 57,638 B | ≤ 65,536 B |
| 单轮最大未 ACK 发送量 | 804,019 B | ≤ 1 MiB |

本机 app-server 初始化加 `thread/list` 十次测量 p95 为 80.898 ms。

### 6.2 Mobile SQLite

| 指标 | 结果 | 目标 |
|---|---:|---:|
| 1500 条目录写入 | 201.619 ms | 有界事务 |
| 目录读取 p95 | 7.942 ms | 首页 < 2 s |
| 200 条热窗口打开 p95 | 1.931 ms | < 100 ms |
| 2000 条 staging 写入 | 222.558 ms | 不线性持有 snapshot |
| staging RSS 峰值增量 | 0.953 MiB | 不随总分页线性增长 |
| 基准数据库大小 | 3.922 MiB | 可重建、可清理 |

`EXPLAIN QUERY PLAN` 确认热窗口使用
`conversation_hot_entries_order` 索引。

### 6.3 旧性能分支复核

`audit/mobile-app-performance-20260724@917afcf9` 的结论：

- Streaming delta 合并：当前线已包含并有全量回归。
- 路径后缀缓存：当前线已包含。
- 工具预览有界扫描：当前线已包含。
- Mirror ordinal 分页/启动清理：当前线已包含或被新 v2 分页替代。
- 首帧延后高亮/清理和顶层 selector：当前线已包含。
- Prompt history single-flight：当前线已包含。
- 新 v2 调度器另补 catalog single-flight、live coalescing 和 revision race。

## 7. 安全审计

已确认：

- API key 存在 Flutter Secure Storage；Machine model 只保存 `hasApiKey`。
- cache route alias 对 endpoint 做哈希，不包含 query、userinfo 或 fragment。
- 连接诊断不记录 URL/token。
- WebSocket auth 对候选值做恒定时间比较。
- 私有 HTTP 仅接受 loopback 或有效 bearer/已认证 peer。
- 全盘读取只有 `BRIDGE_ALLOWED_DIRS=*` 且设置 API key 时才启用。
- artifact descriptor 不向手机发送 canonical absolute path；链接是 opaque、
  有 TTL，打开前复核文件 identity。
- 文件写操作密码只保存 Argon2/scrypt verifier；私有状态文件为
  nofollow/0600；密码尝试限流。
- Face ID proof 绑定 Bridge、client、device、operation digest 和一次性
  短期 challenge。
- approval/question 是 ephemeral RPC，不进入离线重放；持久 mutation
  等待当前 socket 的权威身份。
- HTML preview 使用强 CSP、默认禁用 JS、去除 meta refresh，并限制导航。
- root/Bridge 和 Functions 的 production `npm audit` 均为 0 vulnerabilities。

依赖更新：

- `@hono/node-server` 统一到 2.0.12；
- `@modelcontextprotocol/sdk` 升到 1.30.0；
- Vitest/coverage 升到 4.1.10；
- Firebase Admin/Functions 升到 14.2.0/7.3.2；
- `brace-expansion` 和 `uuid` 使用安全 override。

非阻断维护项：

- `flutter_markdown` 上游已停止维护，未来应单独评估迁移到
  `flutter_markdown_plus`；本轮不在发布候选中进行高风险 UI 依赖替换。
- Xcode/Flutter 当前提示三个插件未来需要 Swift Package Manager 支持；
  当前 CocoaPods 构建仍通过。
- 默认 Flutter launch image 仍是 placeholder；不影响功能，但应作为后续
  品牌资源任务处理。

审计结论：源码范围 P0/P1 为零；没有需要阻止当前本地候选构建的 P2。

## 8. 历史分支语义映射

| 分支 | 结论 |
|---|---|
| `audit/mobile-app-performance-20260724@917afcf9` | 优化已包含、增强或被 v2 替代；保留报告和基准作证据，不整枝合并 |
| `feature/mobile-notification-settings@3b48055f` | 分级通知、显式订阅和限流已在当前线保留；Cloud/真机仍是独立门禁 |
| `feature/mobile-background-sync@d5c1ee29` | 有限续租、BGAppRefresh、前台补偿和 fail-closed 能力已保留 |
| `feature/mobile-background-location-notify@8d6f206a` | notification-only、Always Location 宿主和隐私边界已保留；真机功耗待验收 |
| `feature/mobile-codex-image-references@b2e6d45e` | artifact/image references 与统一预览已在当前线增强实现 |
| `docs/project-handoff-manual@41cdc65f` | 只作长期原则参考；已用当前源码和测试重新核对，不作为完成声明 |
| 旧 persistent Side Chat / modal bottom sheet | 产品决策废弃，不进入当前线 |

以下补丁无需重复 cherry-pick：

- `1645dfe3`、`30a33de3`、`7226c6ab` 已是起始基线祖先；
- `9265c2a4` 被 `6952482f` 等价替代；
- `9293e773`、`eb510015` 被 `78ee2ee7` 的完整列表行为替代。

## 9. 自动验证

- Bridge：96 files / 1857 tests，TypeScript 和 native file-browser build 通过。
- Functions：typecheck、24 tests、build 通过。
- Mobile：2635 tests 通过；4 个外部 SSH smoke 因环境变量未设置而跳过。
- Flutter analyze：0 error、0 warning、52 个仓库既有 info。
- Artifact/HTML/JSON/Quick Look：
  - Bridge 8 files / 129 tests；
  - Mobile 90 tests。
- iOS Simulator Debug：通过。
- iOS device Release `--no-codesign`：通过，`Runner.app` 66.2 MB。
- RunnerTests：27/27 通过。
- Shorebird 1.6.114 / Flutter 3.44.7 no-codesign dry-run：
  version 1.110.1、build 206、Bundle ID `com.k9i.ccpocket`、minimum iOS 15，
  archive 通过，未上传 release。
- `git diff --check`：通过。

## 10. 最终运行时和 IPA 交付

部署使用的已验证源码 HEAD：
`065cddc01342ad1da41920553600ac48fec2a93f`。

- 安全标签：
  - `safety/mobile-session-sync-v2-pre-20260730`
  - `validated/mobile-session-sync-v2-20260730`
- Bridge runtime：
  `/Users/huyiyang/Library/Application Support/ccPocket Bridge/runtime/1.69.4-compat.4-065cddc0`
- Bridge PID/listener/health/version：
  部署时 PID `58249`；唯一 `127.0.0.1:8765`；health ok；
  `1.69.4-compat.4`。PID 是瞬时证据，后续须以 live 检查为准。
- Bridge rollback runtime：`1.69.4-compat.3-8c1d9907`
- Functions 部署：CLI 未登录，未部署；本地 typecheck/test/build 通过。
- IPA：
  `/Users/huyiyang/Documents/Downloads/CC-Pocket-1.110.1-build206-session-sync-v2-065cddc0-AltStore.ipa`
- IPA bytes / SHA-256：
  `26,009,487` /
  `87f1c73e87cadca50b3fb8a6f3d0c0e5270e73f76be7e0434ba70dc9217c5e03`
- Firebase configuration：仓库 dummy plist。
- 架构、provisioning、ZIP path audit：
  38 个 Mach-O 全 arm64；无 provisioning/签名；ZIP/fresh extraction 通过。

完整全局切换与回滚记录：

- `patches/bridge-runtime-deploy_v16_20260730-053519.md`
- `runs/20260730-053519_bridge-1.69.4-compat.4-065cddc0-deploy/DEPLOYMENT.md`
- `backups/20260730-053519_bridge-1.69.4-compat.4-065cddc0-deploy/README.md`

## 11. 仍需物理设备验收

自动化和模拟器不能证明以下项目：

- AltStore/AltServer 重签与物理安装；
- 两阶段 Always Location 权限和后台系统指示；
- iOS 实际分配的后台时间、force-quit 后行为和长任务功耗；
- 锁屏本地通知、长按审批允许/拒绝；
- APNs/FCM 远程送达；
- Face ID 文件 mutation 的真实 Secure Enclave 路径；
- 悬浮窗、八行工具面板、时间戳和状态动效的最终视觉手感；
- 真实 LAN/Tailscale 路线切换后的缓存复用；
- 两个独立 app-server 的 writer-owned-elsewhere 交互文案。

这些门禁不降低源码候选的验证结论，也不得在未实际验收前宣称完成。

## 2026-07-30 build 207 recovery addendum

物理 build 206 继续出现“会话内已连接、正在载入会话运行状态”以及 v2
subscribe/ACK/unsubscribe 循环后，重新沿
`provider → Bridge → protocol → SQLite → reducer → UI` 复核，确认：

- durable detached preview 并未等待 provider attachment，原 banner 是 UI
  假加载；
- 当前协议帧可以在干净数据库完整重放，真实问题不是 320 项目录或 2 MB 批次
  本身不可解析；
- Mobile commit failure 恢复会在每个 ACK 后重置退避，导致重复失败固定两秒
  重订阅；
- global state reset 仍保留旧 thread revisions，旧客户端可能收不到重建热窗口。

build 207 和 Bridge compat.7 分别加入真实 pending gate、一次性可重建缓存自愈、
per-thread revision recovery、稳定 checkpoint 退避，以及 global reset 后的有界
热窗口重建。验证结果：

- Mobile full：2,641 passed、4 expected skips；
- Bridge serial full：96 files、1,859 passed；
- iOS Simulator build、RunnerTests 27/27、device Release build 和 Shorebird
  no-codesign dry-run 全部通过；
- compat.7 在正式 8765 对真实 320 项目录/status 返回 102 个 timeline pages，
  最大 frame 65,139 bytes；
- build 207 AltStore 输入 IPA 的结构、arm64/iPhoneOS、无签名和原生能力审计
  通过。

完整 runtime、回滚、IPA 哈希和物理设备门禁分别记录在：

- `runs/20260730-101950_bridge-1.69.4-compat.7-4c5f875e-deploy/DEPLOYMENT.md`
- `runs/20260730-104039_ccpocket-build207-ipa/README.md`

## 2026-07-30 newest-turn and insights remediation addendum

物理设备随后暴露出两个相互独立的问题：长的最新活动轮次只能看到尾部少量
消息，重试仍无法补齐；durable detached preview 的额度和上下文栏无法稳定取得
数据。沿 `provider → Bridge → protocol → SQLite → controller → UI` 复核确认：

1. Bridge 虽先选最近五轮，但随后按序列化字节裁剪，可能直接切进最新活动轮次；
   较旧历史 cursor 无法修复这个“当前轮次前缀”。
2. 显式分页在部分路径重复启停 app-server，64 KiB 预算只约束内部 payload，
   没有约束最终 JSON envelope；传输失败还可能错误推进 sequence 或追加伪失败。
3. Mobile 没有把当前轮次缺口与向上翻页 cursor 分开，订阅换代和本地提交失败
   后的恢复边界也不完整。
4. durable thread ID 与 runtime session ID 被混作同一个 Insights identity；新版
   Bridge、旧版 Bridge 和延迟返回之间会互相丢弃或误接收数据。

提交 `183cf9bc` 至 `66fc104f` 将修复拆成八个可回滚单元：

- Bridge 保留最新轮次的 user/thinking/process/result spine，把超预算详情变成
  带稳定 ID 的显式 gap，并通过
  `latestTurnComplete/latestTurnGap` 发布可修复边界；
- turns/items page 使用共享只读 reader，最终 wire envelope 不超过帧预算；
  单个不可容纳的详情明确失败，不截断后推进 cursor；
- socket 写失败保留原响应和 sequence，不同时生成虚假 page failure；
- Mobile SQLite schema v5 加法保存当前轮次 gap，先修复当前 gap，再使用独立
  cursor 向上翻历史；每页 commit 后才 ACK；
- generation replacement 可重试；数据库、页数、字节或时间预算失败只保留
  单会话 gap，不清空整个机器/数据源缓存；
- durable Insights 使用稳定的 Bridge/source/thread cache key；runtime ID 仅作为
  旧 Bridge 请求别名；新版请求使用 request ID，legacy lane 采用 single-flight
  和超时隔离。

兼容边界：当前 app-server 的 bounded turns/items RPC 已完整覆盖。旧 app-server
若不提供任何有界 turns/items RPC，Bridge 现在明确拒绝显式分页，不再为了兼容
而扫描整个 rollout。要恢复这一条旧版本能力，必须实现带文件身份、固定
snapshot、offset cursor、rollback 处理和跨页稳定 ID 的 rollout window reader；
不得退回无界 `thread/read(includeTurns:true)` 或整文件解析。该限制不影响当前
app-server、目录同步、本地已有缓存或旧客户端既有 v1 路径。

定向回归在最终源码上覆盖了大于 512 KiB 的两页当前轮次修复、v4→v5 数据库
升级、重开数据库、损坏 gap 元数据、订阅换代、SQLite 失败、8 MiB 预算失败、
最大帧、cursor、发送失败 sequence、legacy lane、延迟响应和 controller
identity。Bridge 独立终审和 Mobile/Insights 独立终审均为 `NO BLOCKER`。
全量测试、静态检查、构建和实际发布仍是分立门禁；源码终审不代表 Bridge
已经重启、OTA 已发布或新 IPA 已安装。

最终全量 Mobile 回归还暴露了一个被旧 Insights 偶发额外帧遮蔽的生命周期
缺陷：`paused/hidden` 会先禁用渲染帧，Codex 页面原先却只在下一次 widget
rebuild 时更新 background ref，因而后台收到 Write 结果仍可能请求文件列表。
修复后，后台 guard 和 genuine-resume 记忆均由同步 lifecycle observer 更新，
不依赖被禁用的 frame；`inactive → resumed` 仍不会触发历史/文件重载。相邻
Codex history/join widget 测试也改为明确等待事件交付和下一渲染帧，不再依赖
Insights 子组件制造额外 frame。新增定向生命周期与 File Peek 回归共 10 项
通过，四个改动文件 targeted analyze 为 `No issues found`。

最终源码门禁：

- Mobile full：2,686 passed、4 expected skips、0 failed；
- Mobile full analyze：0 error、0 warning、52 个仓库既有 info
  （49 `prefer_initializing_formals`、3 `deprecated_member_use`）；
- Bridge full：96/96 files、1,914/1,914 tests；TypeScript build 与
  darwin arm64 native file-browser helper build 通过；
- 最终差异与文档 `git diff --check` 通过；三组独立终审均为
  `NO BLOCKER`。

这些门禁对应源码候选，不代表运行中的 Bridge、Shorebird owner channel 或
物理 iPhone 已切换到该 HEAD。发布继续由固定发布会话按独立交接和回滚门禁
执行。
