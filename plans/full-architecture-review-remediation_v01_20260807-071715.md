# CC Pocket 全架构 Review 复核与稳定性修复计划

- 状态：`active`
- 审查输入：`/Users/huyiyang/WorkBuddy/2026-08-07-00-59-16/review/CC_Pocket_Full_Architecture_Review_20260807.md`
- 源码基线：`fix/conversation-sync-stability-20260806@b61597e9b0e4e49a84c2e2e87dbe85375c4c7614`
- 实施线：`fix/architecture-review-remediation-20260807`
- 边界：源码、测试、性能和兼容审计。Bridge 生产切换、OTA、IPA、Cloud、stable、Desktop 配置和物理设备均需单独授权。

## 1. 新的上游策略

CC Pocket 从本计划起按独立产品线演进，不再把“可无冲突回放官方 upstream”作为硬约束。

- 官方提交逐项按产品价值、冲突面和验证成本吸收，不做整枝追随。
- 当前官方 `8c075b33` 的长会话列表、键盘滚动和路径缓存优化与本轮目标一致，先做语义接入。
- 当前官方 `4bb3d2e3` 只有版本号和 changelog，不吸收；本地版本继续按本地发布线单调递增。
- 不再为保持官方文件形状而保留已证明有害的重复路径或状态模型。
- 仍保留 CC Pocket 自身的新旧 Mobile/Bridge 加法兼容、旧缓存可读、provider 权威历史和回滚边界。

## 2. Review 复核结论

原报告提供了有用的全链路地图，但严重度与部分因果关系需要修订。当前没有证据支持 P0 级数据丢失或安全事故；确认项按用户影响与可复现性调整为 P1/P2。

### 2.1 本轮确认并实施

| 编号 | 修订级别 | 复核结论 | 实施方向 |
|---|---|---|---|
| R1 | P1 | Mobile 对 `codex_shared_runtime_writer_unavailable` / `codex_action_broker_required` 只显示原始错误，缺少本地化恢复说明 | 保持 Bridge fail-closed；Mobile 识别错误码，显示明确的主 Bridge/当前审批卡恢复动作；不得把 standby 伪装成可写 |
| R2 | P1 | Codex 失败消息的实际 UI 未接入逐条重试；自动重连路径在 runtime lease 未就绪时会静默跳过 | `retryMessage` 返回是否已受理；Codex 消息气泡接入重试；未取得精确 authority 时给出一次性提示，不制造发送或排队假象 |
| R3 | P1 | v2 已有 `latestTurnComplete/latestTurnGap`，无需新增 provenance wire 字段，但空且不完整的窗口没有可见恢复入口 | 复用现有 gap 语义；只对“空且不完整”显示非模态恢复条并调用现有 latest-turn repair；权威空会话仍显示正常空态 |
| R4 | P1 性能 | provider 历史持续不可用时，同一会话会随 dirty sync 反复进入最长 10 秒读取 | Bridge 增加 per-thread、revision-scoped、有界退避；live/catalog revision 变化立即失效；退避期间不发送可能覆盖 Mobile 新缓存的降级 snapshot |
| R5 | P2 | runtime handle 替换时保留 streaming 是视觉连续性要求，但若后续权威 activeTurnId 已变化，旧 streaming 不能与新 turn 合并 | 保留同一 turn 的视觉 overlay；用 activeTurnId/generation 做延迟校验，确认不同 turn 或 idle 后截断旧 streaming；不在 attachment 暂时缺失时清屏 |

### 2.2 驳回为当前缺陷，不做机械修复

1. **三套同步必然竞争**：不成立。`conversation-content` 是旧 Mobile fallback；新 Mobile 在 v2 能力存在时不处理 v1。Mirror 是用户显式下载/驻留的完整离线副本，只恢复已标记 `autoSync` 的最多 8 个会话，不等于全目录与 v2 双跑。本轮不删 handler、不禁用 Mirror。
2. **`conversation_queue` 双广播**：不成立。`SessionManager.broadcastCodexQueue` 是状态变化广播；`sendCodexQueueState(ws, ...)` 是新连接/历史请求的单客户端权威补发。两者职责不同，不删除任一出口。
3. **Bridge 背压直接丢帧导致 sequence gap**：现有证据不足。`nextSequence` 在帧预算检查后才前移，目录/状态发送前有 capacity wait，timeline 以小批次和 2 MiB 水位暂停。保留大目录压力测试，但不凭推断重写协议。
4. **LRU 驱逐与 catalog 冲突**：durable catalog 仍存在、runtimeAttachment 变为未加载是设计语义，不是会话丢失。只补回归，不把 catalog 跟随内存 runtime 删除。
5. **runtime replacement 一律清 streaming**：会重新引入用户已报告的运行中内容闪退/回滚。必须按 turn 身份判断，不能按 session handle 变化粗暴清空。

### 2.3 结构债务，仅登记不混入稳定性修复

- `websocket.ts`、`chat_session_cubit.dart`、`bridge_service.dart` 的体积与 pending request 多实现是真实维护风险，但当前没有足够边界测试支持一次性拆分。
- Side Chat 旧文件、menubar remote key、Firebase/App Check 分别属于兼容清理、独立客户端和云端安全任务。
- 历史读取多入口服务不同代客户端和实时/离线场景；后续收敛必须先建立调用者矩阵，不能只按同名函数删除。

## 3. 执行分工与硬边界

本轮不按文件数量分工，而按“是否需要跨层架构判断”分工。任何执行者发现事实与本计划不一致时，必须先记录源码证据和影响，不得自行扩大范围。

### 3.1 Luna Max：简单、封闭、可独立验收的切片

Luna Max 只承接以下边界清晰的任务，每项使用独立提交并回报精确测试结果：

1. **L1 — Mobile 错误提示与消息重试（R1/R2）**
   - 仅修改 ErrorBubble、本地化资源、`retryMessage` 返回值、Codex 重试回调及直接相关测试。
   - 不修改 Bridge wire、authority 判定、发送队列、SQLite、运行时绑定或共享模式。
   - 验收：无 lease 时返回 false 且消息仍为 failed；有 lease 时生成新 `clientMessageId` 并走 ordered dispatch；两个 Bridge 错误码有本地化恢复说明；Codex 失败气泡有真实重试入口。
2. **L2 — 空且不完整窗口的恢复 UI（R3）**
   - 只复用既有 `latestTurnComplete/latestTurnGap/loadOlderTurns`；不得增加新协议字段或第二套历史加载器。
   - 仅在 `entries.isEmpty && !latestTurnComplete` 显示非模态恢复条；权威空会话和已有正文不得误报。
   - Codex 与 Claude 均需直接测试。
3. **L3 — 例行验证与证据收集**
   - 运行指定的 Flutter/Bridge 定向测试、analyze、build 和磁盘/产物检查；不得部署、发布、切生产或清理用户数据。

Luna Max 交付后由根协调任务做最小复核：检查 diff、断言是否覆盖验收、复跑关键测试。没有根任务复核，不视为已集成。

### 3.2 根协调任务：复杂链路与最终判断

根协调任务保留以下工作，不下放：

1. 官方提交选择、冲突语义合并和独立产品线上游策略。
2. **R4 Bridge provider 失败退避**：涉及 snapshot、revision、dirty sync、多客户端和缓存覆盖语义。
3. **R5 streaming turn 身份隔离**：涉及 runtime rebind、activeTurnId、generation fence 和视觉连续性。
4. 跨 Provider → Bridge → protocol → SQLite → Cubit → UI 的最终一致性复审。
5. 分支整合、冲突处理、提交边界、回滚点与最终完成判断。
6. 任何生产 Bridge、OTA、IPA、Cloud、stable、Desktop 配置或物理设备动作的授权判断。

### 3.3 并行与工作树规则

- 每个 Luna 切片必须使用明确 worktree/branch/HEAD；不得在另一个 Agent 正修改的文件上并发写入。
- 当前 L1 已有根任务开始的未提交草稿，因此本次由 Luna Max 在当前 worktree 接管并完成；根任务在其完成前暂停该 worktree 的源码写入。
- 后续 L2 若与根任务并行，必须从已验收 HEAD 新建独立 worktree，最后由根任务 cherry-pick；不得共享脏工作树。
- 发布会话只接收用户明确授权的发布任务。本轮源码修复不得向发布会话或其他用户任务发送命令。

## 4. 实施顺序

### Stage A：选择性吸收官方性能提交

1. 语义接入 `8c075b33`，逐文件保留本地稳定锚点、折叠和缓存行为。
2. 不接入 `4bb3d2e3` 版本提交。
3. 运行官方新增的长会话、键盘滚动、路径缓存和 overlay 定向测试。

### Stage B：Mobile 可恢复失败路径

1. 将共享 writer/action broker 错误码纳入 ErrorBubble 本地化映射；原始 server message 只作诊断补充。
2. `ChatSessionCubit.retryMessage` 返回 `bool`，只有建立当前 runtime mutation lease 后才把 failed 改为 sending。
3. Codex `ChatMessageList.onRetryMessage` 接入真实方法；false 时显示“会话控制权仍在同步，请稍后重试”，不改消息状态。
4. 自动重连保留 best-effort，但不得吞掉手动入口或显示假进度。

### Stage C：空且不完整窗口恢复

1. 将 `ConversationHotWindowSnapshot.latestTurnComplete/latestTurnGap` 投影到 Codex 与 Claude durable screen。
2. 仅 `entries.isEmpty && !latestTurnComplete` 显示紧凑非模态恢复条。
3. Retry 复用 `loadOlderTurns` 的 latest-turn repair；成功后依靠 SQLite update 重新投影，失败显示可重试错误。
4. `entries.isEmpty && latestTurnComplete` 保持权威空态；已有可见 entries 时只保留现有顶部 gap/retry，不用横幅遮挡正文。

### Stage D：Bridge provider 失败退避

1. 为 `provider + providerSessionId + requestedRevision` 记录失败时间、次数和下一次允许读取时间；采用有界指数退避并设最大值。
2. provider/live/catalog revision 前进、明确 focus/retry 或成功读取时清除退避。
3. 退避命中时：有 Bridge 同 revision 安全 snapshot 才可复用；否则发送 scoped `timeline_failed`，不发送空/旧降级 snapshot 覆盖 Mobile。
4. 失败状态不进入 canonical snapshot cache；多客户端共享读失败冷却但各自保持 ACK/state。

### Stage E：streaming turn 身份隔离

1. runtime replacement 暂时保留当前视觉 overlay，同时保存原 activeTurnId。
2. 新权威状态确认同 activeTurnId 时继续；确认新 activeTurnId 或 idle/terminal 时清旧 streaming buffer。
3. 旧 generation 的 delta 继续由既有 subscription fence 拒绝。

## 5. 兼容与性能门禁

- 新 Mobile + 新 Bridge：完整本地化、重试、gap repair、退避与 turn fence。
- 新 Mobile + 旧 Bridge：未知新诊断仍按普通 ErrorBubble；v2 缺失时继续 v1；Mirror 行为不变。
- 旧 Mobile + 新 Bridge：只收到既有 wire 字段和 error event；本轮尽量不新增必需字段。
- private Codex、daemon/shared Codex、Claude 均需覆盖；共享 writer 门只影响 daemon。
- 不改变 SQLite schema、provider 历史格式、Cloud、Swift/native channel。
- provider 持续失败 60 秒内，同 key 的真实 provider 读取次数必须有界；revision/live 变化后可立即恢复读取。
- retry false 不得改写消息状态；retry true 必须发出新的 clientMessageId 并走既有 ordered dispatch。
- runtime replacement 同 turn 不闪退，不同 turn 不串流。

## 6. 验证与提交

建议提交边界：

1. `集成：选择性接入官方长会话性能优化`
2. `移动端：补全共享运行时失败提示与消息重试`
3. `移动端：恢复空且不完整的会话窗口`
4. `Bridge：限制不可用历史的重复读取`
5. `移动端：按 turn 隔离 runtime 流式状态`
6. `审计：记录 Review 修订、兼容和性能证据`

验证顺序：

- 每个切片先跑对应定向测试和 `git diff --check`。
- Bridge：conversation-sync-v2、websocket/shared-runtime 定向测试，TypeScript/native helper build；最终再跑单 worker 全量。
- Mobile：chat session、Codex/Claude durable preview、content sync、long-session performance 定向测试和 targeted analyze；最终再跑全量。
- 性能：失败退避 fake-clock 测试、长会话列表/路径缓存基准、无重复 provider read 计数。
- iOS build、IPA、OTA、生产 Bridge 与真机是独立发布门禁，不在本计划的源码完成声明中混写。

## 7. 完成标准

- R1-R5 均有源代码证据和回归；被驳回项有调用条件证据，未被误删。
- 定向和全量测试无 P0/P1；analyze 单独报告新增与既有 info。
- 官方性能提交只吸收已验证行为，未夹带版本号或无关 upstream 变更。
- 分支提交可独立回滚，工作树干净；计划、CONTEXT、PROJECT_INDEX、decisions 与最终 HEAD 一致。
- 未经再次明确授权，不部署 Bridge、不发布 OTA/stable、不构建或发送 IPA。
