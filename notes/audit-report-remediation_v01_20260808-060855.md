# 2026-08-08 外部全链路审计复核与修复台账

状态：`source verified / release and device pending`。本文复核
`/Users/huyiyang/WorkBuddy/2026-08-08-00-41-43/cc-pocket-audit-report.md`
对 `d2dd008b` 的静态结论，并以当前修复线的真实源码和测试为准。外部报告是有用的
线索集，但其“所有 P0/P1 均已确认”声明不成立；若按原建议机械删除 v1/v2/Mirror
路径或广播 ACK，会制造新的兼容和一致性问题。

## 现场与边界

- 工作树：`ccpocket-worktrees/audit-report-remediation-20260808`
- 分支：`fix/audit-report-remediation-20260808`
- 基线：`0374900292f60b6e6e5888fc14a0ad9694dad0c8`
- 第一批：`7a04896932f25f1bb0c934df622421f9d0aa1815`
- 第二批：`28bbbd1ee99b550af535dc897cbc0c2f439a16f1`
- 本轮只修改源码、测试和项目文档；没有切换生产 Bridge、Cloud、OTA、IPA、Desktop
  配置、网络或物理手机。

## 已确认并修复

### 连接、状态与历史恢复

1. Mobile 断线时清除未完成 thinking/streaming，避免幽灵“正在输出”。
2. Claude 与 Codex 都订阅新连接代次的运行时快照；Claude 的新鲜 live status 不再被
   旧 history status 覆盖。
3. 重连后无论旧状态是 starting/running/idle 都请求该 runtime 的增量历史；不再等待
   一条偶然的新 Desktop 消息才恢复。
4. Bridge 增加 30 秒 ping/pong，终止半开 WebSocket。
5. Codex canonical history 同一 runtime 的并发读取合并为一个 in-flight Promise。
6. 客户端 watermark 高于 Bridge 重启后的 revision 时返回 reset snapshot，避免旧
   RuntimeStore 序号把重连永久卡住。
7. image-store 在本地路径提取前排除 URL，普通缺失/非文件不再产生重复 warning。

### 推送与共享 app-server 客户端

1. token register/unregister 是幂等 Cloud 写入，遇到网络、408/425/429/5xx 时最多重试
   3 次（250/500 ms）。401 和其他参数错误不重试。
2. notify 继续单次发送。在 Cloud relay 尚无 `deliveryId` 去重前，重试“请求已到达但
   回包丢失”的通知可能造成双通知，不能为了表面可靠性破坏 at-most-once 语义。
3. durable Codex model/effort/speed/permission 写入优先复用现有共享 app-server client；
   只有没有可用客户端时才短暂创建 standalone reader。writer lease、source 和 operation
   id 门禁均未放宽。

## 报告逐项处置

| 条目 | 复核结论 | 当前证据与处置 |
|---|---|---|
| P0-1 streaming 残留 | **确认，已修** | `ChatMessageHandler.resetTransientStreaming` 与断线测试。 |
| P0-2 Claude 重连状态不刷新 | **确认，已修** | provider-neutral snapshot 订阅、connection generation fence、Claude status 测试。 |
| P0-3 无通用 WS backlog | **现象部分成立，根因/方案过宽** | v2 已有 state token/ACK/scoped reset；runtime 已有 seq delta/canonical recovery；本轮补 reconnect history 和 restart reset。瞬态 delta 不承诺逐字回放，最终 provider history 才是权威。禁止再叠一套无范围的通用 backlog。 |
| P0-4 Mirror 仅 Codex | **严重度错误** | 手动 resident Mirror 是 Codex 特性；自动 `ConversationContentSyncService`/v2 同时支持 Claude/Codex 并写 SQLite。Claude 专用“手动下载镜像”属于产品功能选择，不是当前 P0 数据丢失。 |
| P1-1 无 heartbeat | **确认，已修** | 30 秒 ping/pong；半开客户端 terminate。 |
| P1-2 Claude 无持久输入 ledger | **真实能力缺口，未伪修** | Codex ledger 依赖 provider client message id 和可安全恢复的 turn/start/steer；Claude SDK queue 与 Bridge 进程同寿命。Bridge 重启也会终止 Claude runtime，在没有 provider receipt/可恢复队列契约前不能安全自动重放。需独立协议设计。 |
| P1-3 canonical read 无去重 | **确认，已修** | WeakMap per SessionInfo in-flight，失败/成功均释放。 |
| P1-4 compacted snapshot 总触发 RPC | **原建议不安全** | canonical baseline 后 `session.historyEntries` 只保留 live overlay；compacted snapshot 不能替代 canonical history，否则会把历史删成残留窗口。保留 canonical read，并由 P1-3 合并并发。 |
| P1-5 Claude history 覆盖 live status | **确认，已修** | live status authority 优先，后续直接 status 可正常 settle。 |
| P1-6 多设备 ACK 不广播 | **报告误判** | Bridge 已 append `user_input` 并 broadcast 给除发送端外的客户端；发送端收到 echo/acceptance。ACK 是单设备投递收据，广播会错误改变另一台设备的 optimistic 状态。 |
| P1-7 四套目录读取无共享缓存 | **性能机会，非已证实 P1** | v2 已有 catalog/status single-flight、共享 Codex read client、revision invalidation 和解析缓存；legacy recent list 仍有独立分页读取。须用真实 request/CPU profile 决定是否提取 provider catalog repository，不能用短 TTL 覆盖 archive/filter/page 语义。 |
| P1-8 连接双重 list 推送 | **报告误判** | 初始 session list 兼容未声明 capabilities 的旧客户端；Mobile capability 协商后的显式请求用于获取丰富字段和权威代次。删除会让新旧握手依赖时序。 |
| P1-9 Mirror 与 v2 双库竞争 | **报告误判** | Mirror 是用户显式 resident/download；v2 是自动有限窗口。Mirror 仅在 source/content epoch 守卫后发布可重建 snapshot，UI 合并有权威边界。不可机械删除。 |
| P1-10 Mobile 历史请求无 single-flight | **已存在等价实现** | `_pendingHistoryDeltaSinceSeq`、dirty bit、connection epoch；并发调用合并且最多一个 follow-up。 |
| P1-11 BackgroundSync 与 v2 竞争 | **未证实** | BackgroundSync 只补 active runtime cache 和 resident Mirror；v2 提供 durable preview。跳过 runtime history 会让打开的 live screen 无恢复来源。保留，后续仅凭 profile 调参。 |
| P1-12 Bridge restart 保留旧 seq | **确认，已修** | `sinceSeq > historyRevision` 返回 reset snapshot；Mobile reconnect 主动补差。 |
| P2-1 standalone 进程重复 | **部分成立，已收敛一处** | v2 内部已有共享 ref-counted Codex read client；durable settings 本轮改为复用 active shared client。legacy recent list 的进一步统一需和 P1-7 一并 profile。 |
| P2-2 append/project request id | **未证实** | list scope 提升内部 generation；append/project 继承 generation，Mobile 另带 requestId/queryGeneration。它用于丢弃旧筛选代次，不是全局分页序号。 |
| P2-3 idle eviction 与 read 竞态 | **理论竞态，缺复现** | 仅超过 30 个 idle runtime 且另一生命周期事件触发 eviction 时可能命中。贸然给所有 history read 加永久引用会阻止有界 runtime 淘汰；需故障注入后再决定短 lease。 |
| P2-4 ContentSync 与 v2 同时注册 | **报告误判** | ContentSync 是 Mobile focus/repair/paging coordinator；v2 是 Bridge wire engine。二者是同一功能的两端，不是重复 Bridge handler。 |
| P2-5 Claude 运行时切模型 | **真实产品缺口** | 当前协议明确只支持 Codex；需先确认 Claude SDK 的 session-level model mutation 契约，不能伪装成功。 |
| P2-6 LAN proxy 残留 | **部署项，已由前序修复** | `03749002` 记录动态 en0 地址与 readiness 恢复；本轮不修改网络/LaunchAgent。 |
| P2-7 push 无重试 | **部分确认，安全部分已修** | token register/unregister 有界重试；notify 等 Cloud deliveryId 去重后才能安全重试。 |
| P2-8 image warning 噪音 | **确认，已修** | URL 过滤与缺失文件降噪。 |
| P2-9 无 PID 锁 | **未证实** | 生产 LaunchAgent + 唯一监听者，第二实例受 EADDRINUSE；候选发布还需要不同端口。全局 PID 锁反而会破坏隔离候选。 |
| P2-10 durable settings 临时进程 | **性能项，已优化** | 优先复用 active shared client，保持 standalone fallback。 |
| P2-11 continuity 截断不可恢复 | **报告误判** | backlog 只保存 transient；turn idle/historyReady 后 ChatSessionCubit 请求 canonical history。1 MiB 前缀可暂时省略，不会被当作最终权威历史。 |
| P2-12 PromptHistory 独立 WS | **报告误判** | 当前 Bridge 走主 socket + request correlation + timeout；只有同步另一台在线 Bridge 才开独立 socket，finally 关闭。 |
| P2-13 history follow-up 级联 | **已受控** | per-session single-flight + dirty bit；任一时刻只有一个请求，follow-up 用于收敛请求中产生的新 revision。 |
| P2-14 streaming 断线残留 | **与 P0-1 重复，已修** | 同上。 |
| P2-15 FCM 乐观启用 | **报告误判** | 新 Bridge 支持 requestId ACK、12 秒 timeout、enabledPending/registrationFailed/relayUnavailable；旧 Bridge 保留兼容 fallback。 |
| P2-16 列表因 runtime attach 跳动 | **报告过时** | `session_list_projection.dart` 自 `53c9749f` 起以 durable catalog modified/created 为排序权威；runtime attach 不移动已有 durable card。 |
| P2-17 Claude unseen 不准 | **报告过宽** | v2 durable unread 按 provider+thread key；legacy runtime unseen 是兼容后备。仍需真机验证完成事件和 read watermark，而非从 `status == idle` 一行推断整条链失败。 |

P3 条目均未形成源码阻断：跨 provider 分页的每源 `offset+limit` 足以覆盖全局页候选；
Claude model list 是配置门禁；metadata cooldown、750 ms 本地 ACK 窗口、discovery 生命周期、
MachineManager 刷新和测试 double 继承均需运行指标或独立设计证据，不能在本轮顺手重构。

## 保留的开放项

1. **Claude durable input**：需要 Claude provider 可恢复 receipt/queue 语义，或明确显示
   “Bridge 重启会中断 Claude 托管任务”；当前不能安全 exactly-once replay。
2. **Claude session model mutation**：确认 SDK/CLI 是否支持同一 session 的下一轮模型更新。
3. **catalog repository**：采集首次连接与 100/1500 会话下各 reader 的次数、耗时、RSS，
   再决定是否把 legacy recent list 迁入 v2 的 revision cache。
4. **push notification retry**：Cloud 先实现按 bridgeId+deliveryId 的短期幂等去重，之后
   Bridge notify 才可安全重试。
5. **idle eviction fault injection**：并发历史读取、创建第 31 个 idle runtime 和 eviction，
   证明存在失败后再增加短操作 lease。

以上均不是降低当前连接/历史可靠性修复的理由，也不授权本轮部署。

## 验证证据

- 第一批：Bridge 定向 401 tests；Mobile `chat_session_cubit_test.dart` 196 tests；
  targeted analyze 0 error/0 warning（2 个既有 info）；Bridge build、Dart format、
  `git diff --check` 通过。
- 第二批定向：Bridge push-relay + websocket 308 tests、TypeScript/native helper build
  通过。
- Bridge 全量单 worker：114 files 中 113 直接通过；2331 tests 通过，
  `session-catalog-monitor` 的固定 5 秒用例在整套运行时超时。该文件隔离立即 8/8
  通过，和本轮改动无路径交集，登记为资源/文件 watcher 时序抖动，不伪装成全量 clean。
- Mobile 全量：2930 tests 通过，4 个无环境 smoke 跳过，零失败。
- Mobile analyze：0 error、0 warning、52 个仓库既有 info；命令因 info 报告非 clean，
  未伪装成零问题。
- conversation-sync 基准：真实目录 324 项 median 21.16 ms、p95 22.87 ms；合成 1500
  项 priority p95 37.39 ms、complete p95 53.26 ms；10,000 项 complete p95 101.40 ms；
  重复 sync 0 次 history read、最大 provider 并发 2、最大帧 57,603 bytes（低于 64 KiB）。
- `git diff --check` 通过；最终删除本工作树 `node_modules`、Bridge `dist`、Mobile
  `.dart_tool/build` 共约 332 MiB，源码和生产 runtime 未动，工作树干净。
