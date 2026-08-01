# CC Pocket Codex 双路径全链路审查

- 状态：`source-remediation-verified / runtime-device-gates-pending`
- 审查分支：`feature/codex-shared-runtime-20260731`
- 审查基线：`93c21f6d1145667f8eb93b296133b855a497e445`
- 审查日期：2026-08-01
- 范围：Codex Desktop 发起/托管线程、Bridge 发起/附着线程，经 app-server、Bridge、协议、Mobile SQLite、Cubit/Reducer 到 UI 和操作回路的完整链路

## 当前结论（修复与复验后）

本分支已经把 Codex Desktop 发起和 Bridge 发起两条路径收束到同一套 durable thread、权威状态、Action Broker、增量内容和 Mobile 本地缓存模型。原始审计的 12 个 P1 与独立复审新增的 4 个 P1 均已有源码修复和自动回归证据；冻结源码上的 Bridge、Functions、Mobile、iOS Simulator 和既有同源 RunnerTests 门禁均通过。

当前源码门禁为 `0 P0 / 0 P1 / 2 个非阻断 P2 / 1 个兼容性 P3`。剩余 P2 是极端超长单行 Claude JSONL 的有界读取取舍，以及低频输入台账在约 1.4 MiB 时仍整文件重写；P3 是兼容保留的 `/health` 与 `/readyz` 双语义。它们不伪装成已消失，详见第十一节。

这仍不等于生产和设备验收。生产 8765、Codex Desktop 运行模式、Cloud Function、OTA、IPA 和物理 iPhone 均未因本轮审查而改变；真实 Desktop 双客户端、Bridge 切换、通知动作和物理设备视觉/功耗仍属于后续独立门禁。

## 一、初始审计结论（修复前快照）

初始审计时的实现不能判定为“共享 Codex 运行时产品功能完成”。当时的准确边界是：

- Stage 0–2 的严格 daemon 配置、UDS 传输、settings-neutral attach、Bridge 发起的无工具 canary 和部分 attachment 级连续性已通过自动验证；
- Codex Desktop 发起的线程尚未完整接入 Mobile 的实时状态、增量内容、审批/问题、操作权和持久恢复；
- 两条路径在 Bridge 与 Mobile 中仍通过不同身份、不同实时通道和不同页面分支处理；
- 已确认 `0 P0 / 12 P1 / 6 P2 / 1 P3`。P1/P2 为本报告的合并去重结果，不是三轮审查计数的简单相加。

因此，之前的 `2039/2039` Bridge 测试只能证明已实现代码的回归，不能证明 Desktop ↔ Bridge ↔ Mobile 双发起方产品闭环。

## 二、两条真实路径与当前断点

### A. Bridge 发起或由 Bridge 当前 attachment 启动的 turn

```text
Mobile input
  → Bridge SessionInfo / CodexProcess
  → shared daemon thread/start 或 thread/resume
  → turn/start
  → CodexProcess live messages/status
  → sessionMessage + runtime overlay
  → conversation_sync_v2 / session_list
  → Mobile SQLite / live Cubit
  → UI
```

这条路径有本地 `SessionInfo`、本地 CodexProcess 消息和 Bridge 内存中的 turn ownership，因此状态、消息、审批和自动批准通常可工作。现有自动测试主要覆盖此路径。

### B. Codex Desktop 发起或先持有的 turn

```text
Codex Desktop
  → shared daemon
  ├─ shared control diagnostic ring（未接产品链）
  ├─ settings-neutral adoption（只在用户打开/恢复后存在）
  └─ legacy JSONL continuity（daemon 下仍启用）
       → conversation_sync_v2 / continuity message
       → detached durable page 或临时 runtime page
       → UI
```

这条路径没有统一 Action Broker、持久请求台账或明确的 `turnOrigin/controlState`。当前实现同时依赖 app-server、Bridge runtime overlay 和 JSONL continuity，导致漏报、重复、误分类、排序变化和操作能力不一致。

## 三、P1 问题

### P1-1：app-server 状态和 shared control 没有进入产品同步链

证据：

- `packages/bridge/src/local-features/conversation-sync-v2.ts:447` 构造 `statusReader`，但全文件没有调用点；
- `conversation-sync-v2.ts:1800` 的 5 秒 watchdog 只刷新 legacy monitor 和 runtime overlay；
- `packages/bridge/src/index.ts:74` 启动 `CodexSharedRuntimeControl`，但只用于 health/readiness/pilot diagnostics；构造 `BridgeWebSocketServer` 时没有传入；
- app-server 状态只在首次/冷目录刷新进入，冷周期是 10 分钟。

影响：未被 Bridge 显式 attach 的 Desktop turn 不会通过权威 daemon 事件实时进入手机；Working/Need You 可迟到、停留旧值或完全漏掉。

修复：把 control/status 变化接入统一状态引擎；5 秒 `thread/list(useStateDbOnly)` 只作防漏。增加 fake control、迟到 generation 和 watchdog 合同测试。

### P1-2：daemon 下 app-server 与 JSONL continuity 形成双实时数据平面

证据：

- `packages/bridge/src/local-features/registry.ts:19` 无条件注册 continuity handler；
- `packages/bridge/src/websocket.ts:10784` 无条件广告 continuity capability；
- `conversation-sync-v2.ts:3119` 自己还会创建 `CodexRolloutMonitor`；
- `apps/mobile/lib/features/chat_session/state/chat_session_cubit.dart:524` 同时监听正常 session 消息和 continuity 消息。

影响：同一 Desktop turn 可能经两套 item key、两个 handler 和两种排序规则进入 Mobile；可造成重复内容、列表状态跳变、错误 rehydrate 或漏报。

修复：daemon 模式以 app-server 事件为唯一实时主通道；JSONL 只保留 private/legacy fallback 和显式离线 gap 审计。旧 Mobile 通过 capability 缺失安全停用 continuity。

### P1-3：`source`、turn 发起方和写入所有权被混成一个概念

证据：

- v2 `ConversationSyncStatus` 没有计划要求的 `executionHost`、`activeTurnId`、`controlState`、`authorityGeneration`；
- `apps/mobile/lib/widgets/session_visual_status.dart:74` 将 `appServer` 直接显示为 Desktop，将 `bridgeRuntime` 显示为 Bridge；
- `chat_session_cubit.dart:706` 用 `source != bridgeRuntime` 推断 Desktop 所有权；
- shared daemon 的权威事件无论发起方都是 `source: appServer`。

影响：Bridge 发起 turn 在共享 daemon 下可显示成 Desktop；被动 adoption 又可显示成 Bridge；模型、速度、引导等按钮随错误布尔值被禁用或放开。

修复：协议增加可选独立字段；`source` 只表示证据来源，`executionHost/turnOrigin` 只表示发起方，`controlState` 是唯一 mutation 门禁。旧字段保持加法兼容。

### P1-4：同一 durable 会话因是否存在 runtime 而进入两套页面

证据：

- `apps/mobile/lib/features/session_list/session_list_projection.dart:95` 将任意 runtime 合并到 durable 行；
- `home_content.dart:846` 只要 `running != null` 就进入 runtime route；
- 无 runtime 才进入 durable/local-first route。

影响：同一线程会在缓存完整的 durable 页面和 transient runtime 页面之间切换；历史、草稿、滚动、悬浮窗、状态和操作能力随刷新改变。

修复：只要有 durable provider ID，始终使用同一个 durable route；runtime ID 只是可替换 attachment handle。只有没有 durable ID 的新建临时 runtime 才使用 runtime-only route。

### P1-5：Desktop 实时增量会移动同一 item 的相对位置

证据：

- `conversation-sync-v2.ts:2339` 更新已有 live item 时执行 `delete` 再 `set`；
- `conversation-sync-v2.ts:3171` 按 Map 迭代顺序合入 canonical history；
- SQLite 随后按 `entry_index` 固化该顺序。

影响：较早的 assistant/thinking 在继续流式更新时可跳到后续工具之后；退出重进或 canonical 对账后又恢复。

修复：更新同一稳定 item 不改变槽位；合并优先使用 turn/item/chunk ordinal，时间戳只作缺失结构字段时的最终 tie-breaker。

### P1-6：Desktop-originated Need You 只有状态，没有可操作请求

证据：

- v2 只投影 attention 和可选 request ID，没有审批/问题/form payload；
- detached Cubit 只映射成 `waitingApproval`，不创建 `ApprovalState`；
- shared attachment 对非本 attachment 启动的 server request 直接忽略；
- control observer 也明确忽略 JSON-RPC requests。

影响：手机能显示 Need You，却不能批准、拒绝或回答；Bridge-originated request 同时广播给 Desktop 时仍有 first-responder 风险。

修复：增加以 `{codexSourceId, threadId, turnId, requestId, generation}` 为身份的持久 request ledger 和 Action Broker；聊天页、自动批准和通知动作共用同一个 opaque request identity。

### P1-7：turn ownership 判定错误，且 foreign turn 可被中断

证据：

- adoption 水合 Desktop active turn 时同样写入 `pendingTurnId`；
- `getLocallyActiveCodexTurnId` 把任意 attachment 的 `activeTurnId` 当本地 turn；
- steer 已检查 `sharedRuntimeOwnedTurnIds`，但 interrupt 没有同类检查；
- pilot allowlist 允许 adoption 的 `turn/interrupt`。

影响：Desktop 发起 turn 可被误标为 Bridge turn；手机 Stop/Interrupt 可能中断 Desktop 正在执行的任务。

修复：`activeTurnId` 与 ownership 分离；shared interrupt/steer/approval 必须校验 exact turn + generation + control lease。foreign turn 默认只读或明确 detach，不能中断。

### P1-8：共享断线后没有自动重新附着，并会伪装成 Working

证据：

- established UDS 断开后 transport 直接 exit，不自动重连；
- shared exit 将 session 状态设为 `starting` 并保留队列；
- v2 将 `starting` 投影为权威 `working + loaded`；
- 没有 attachment coordinator 重建和 scoped reconcile。

影响：短暂 daemon/UDS 断线后手机可能永久显示运行中，实际 attachment 已丢，队列也不恢复。

修复：增加明确 `reconciling/unavailable` 控制态和有界 attachment 重建；恢复后按 thread scoped gap 对账，禁止盲重放 mutation。

### P1-9：shared settings mutation 可提示成功但实际不生效

证据：

- shared attach 正确地不在 resume 时覆盖设置；
- 但 model/speed/permission/Plan 路径会先改本地并广播，后台 `thread/settings/update` 失败可被吞成 false；
- pilot gate 又拒绝 settings update；
- restart-now 路径先 destroy 健康 session，再以不符合 shared attach 契约的参数重建。

影响：Desktop 实际 Ultra 可在手机显示 High/default；用户修改后界面看似成功，下一轮仍用原设置；失败还可毁掉原 attachment。

修复：共享模式在 Action Broker/权威 settings ACK 完成前明确禁用 mutation；后续采用 await canonical ACK、CAS revision 和 staged neutral replacement，失败不改 UI、不 destroy 旧 session。

### P1-10：daemon resume 在 attach 前读取完整历史

证据：

- `packages/bridge/src/websocket.ts:8093` 先调用 `getCodexThreadHistory`；
- `getCodexThreadHistoryFromRpc` 使用 `thread/read(includeTurns:true)`；
- 随后才创建 settings-neutral daemon adoption；
- daemon 测试使用空历史 mock，只验证没有向客户端发送 past_history。

影响：长会话打开、发送和重连仍有高延迟、内存峰值和重复解析，与 local-first/分页目标相反。

修复：daemon attach 不读取全历史；初始页面从现有 SQLite/v2 最近窗口渲染，Bridge 只按需调用 turns/items 分页。

### P1-11：打开页面没有把 cache update 锁到原始 Bridge/source

证据：

- 页面虽保存 `BridgeDataSourceIdentity`，但 cache update 主要按 provider/thread ID 过滤；
- `loadCachedWindow` 使用当前全局 cache target，调用者不能传 route-bound target；
- cache update 没有 target fingerprint。

影响：两个 Codex source 出现相同 thread ID，或连接切换 source 时，旧页面可能读取、分页或显示新 source 的内容。

修复：页面持有不可变 source fingerprint；每个 update/page/load 请求携带并校验 target fingerprint，不匹配时 fail closed。

### P1-12：自动批准仍绑定 transient Bridge runtime

证据：

- Mobile 按 runtime session ID 查找自动批准目标；
- Bridge auto-approval 只监听 Bridge-owned CodexProcess 的 permission message；
- detached/shared Desktop thread 被当作 external app-server 拒绝。

影响：同一 durable thread 从 Bridge 发起时可自动批准，从 Desktop 发起时不可用；手机断开后的监督也不完整。

修复：配置与监督都改为 durable target；Action Broker 明确声明 supervision availability；真正 legacy independent app-server 继续 fail closed。

## 四、P2 / P3 问题

### P2-1：完成/失败未读只存在 Bridge 内存

`resultLedger` 未持久化，Bridge 重启后 app-server status 又固定为 `result:none`。手机离线完成、Bridge 随后重启时蓝点可能丢失。

### P2-2：detached 页面展示可编辑设置，但操作静默 no-op

未知模型会回退显示列表默认项；detached 的 model/permission/speed setter 直接 return。需要 `settingsKnown + settingsActionability`，未知显示未知，不可编辑时明确说明。

### P2-3：官方临时 thread/fork 在 daemon pilot 被 gate 拒绝

child 创建走 `thread/fork`，但 pilot 没有独立 fork gate。后续必须增加受约束的 fork 能力、parent identity 和 ephemeral lease 测试，不能放开全部 mutation。

### P2-4：Stop Session 在 shared 模式实际是 detach，文案却称已停止

关闭 attachment 不等于终止 daemon 中的 turn。必须区分“从手机断开”和“中断并断开”；foreign turn 只允许 detach。

### P2-5：Desktop Plan、live 时间戳和部分设置事实不完整

shared resume 没有完整保留 collaboration mode；live app-server assistant/tool 消息缺权威 source timestamp，而 JSONL 路径有，导致对账后时间跳变。

### P2-6：悬浮窗附属状态仍按 route/runtime 分叉

Side Chat registry 仍使用逻辑连接身份而非认证后的 Bridge/source；折叠按钮只统计 side chat，不统计 detached subagents。现有 detached subagent source 校验可复用。

### P3-1：`/health` 与 `/readyz` 语义容易被混淆

daemon control 不 ready 时 `/health` 仍返回顶层 `status:ok`，只有 `/readyz` 返回 503。旧探针或只看绿色 WebSocket 的 UI 可能把“Bridge 进程活着”误解为“Codex runtime 可用”。

## 五、已确认正确、不得重写的基础层

- v2 durable 身份是 provider + provider thread ID，不使用标题；
- SQLite 主分区已按 `bridgeInstanceId + codexSourceId` 隔离；
- Mobile 对 v2 event 有 Bridge/source/subscription/generation fence，SQLite commit 后才 ACK；
- 同名会话按 durable ID 区分；
- detached subagent 协议已有 provider thread + source 校验；
- shared attach 已做到 settings-neutral resume；
- private/legacy 模式仍需保留兼容 fallback，不能为 daemon 修复而删除。

## 六、修复顺序

### 批次 1：先消除错误状态与破坏性操作

1. watchdog 真正读取 app-server 状态；
2. 增加 `executionHost/activeTurnId/controlState/authorityGeneration` 可选字段；
3. Mobile 停止从 `source` 猜发起方；
4. shared foreign interrupt/steer/settings fail closed；
5. daemon 禁用 legacy continuity 广告和 JSONL 实时双写。

### 批次 2：统一 durable route、缓存和排序

1. durable 会话始终进入同一 route；
2. source fingerprint 贯穿 cache update/load/page；
3. live item 原位更新和结构序号排序；
4. daemon resume 去除完整历史读取。

### 批次 3：Coordinator、Action Broker 和恢复

1. shared control/status 接入统一事件引擎；
2. active/Need You/聚焦线程按需 attachment；
3. 持久 request、binding、queue、receipt 和 terminal-result ledger；
4. reconnect/reconcile/generation fence；
5. Desktop/Bridge first-responder 与 alreadyResolved 语义；
6. durable auto approval。

### 批次 4：设置、fork、Plan、时间戳和附属 UI

1. canonical settings CAS；
2. staged replacement；
3.受限 fork/ephemeral lease；
4. detach/interrupt 文案与行为；
5. provider timestamp；
6. floating dock authenticated scope 和 subagent badge。

## 七、验收门禁

修复后必须重新验证：

- Bridge full test/build/native helper；
- Flutter full test/analyze；
- private/daemon、Bridge-origin/Desktop-origin、旧新 Mobile/Bridge、Claude/Codex 兼容矩阵；
- Desktop turn → Mobile status/content/Need You/action；
- Bridge turn → Desktop 实时显示；
- active turn 中真实 Bridge 进程重启；
- pending request 重启恢复且 exactly-once；
- 长会话 resume 内存与延迟；
- Desktop event → Mobile SQLite commit p95、空闲 CPU/RSS、连接数、UI rebuild；
- 真实 Desktop 侧栏、项目归属、排序和不抢焦点；
- 物理手机 L1。

源代码修复和自动测试通过不自动授权：生产 8765 切换、Desktop shared 模式、OTA、IPA、手机安装或 stable 发布。

## 八、本轮运行边界

审查期间：

- 生产 Bridge 仍为 `1.69.5-compat.11.c64bf5ed`，监听 `127.0.0.1:8765`；
- 隔离候选仍为 `1.69.6-compat.12`，监听 `127.0.0.1:18765`；
- Desktop 已恢复 private 模式；
- 未重启生产服务、未切 Desktop、未发布 OTA/IPA、未修改手机数据；
- 审查前工作树干净。

## 九、修复阶段独立复审补充（2026-08-01）

首轮报告完成后，又对当前实现做了一轮不改代码的独立跨层复审。该轮确认 Mobile 曾把 `conversation_sync` 的 `daemon:*` generation 与 Action Broker 的 `cab:*` generation 当成同一命名空间；此问题已在修复阶段改为只跨 feature 校验 exact turn，CAB generation 只与 CAB health 比较，并经独立 Mobile 复审确认不再阻断。

独立复审另发现以下未包含在首轮 12 个 P1 计数中的问题；它们进入同一 remediation 门禁，不能因首轮报告已完成而遗漏：

### 新增 P1

1. **备用 Bridge 的旧客户端写入口绕过 writer lease**：daemon adoption、旧 `input` 和旧 `approve/reject/answer` 直接进入 attachment transport；`/readyz=503` 只反映诊断状态，并不阻止既有 WebSocket mutation。备用 Bridge 因此仍可能启动 turn 或成为第二个审批响应者。
2. **content observer 与正式 adoption 共用不可抢占 attachment lease**：聚焦或活跃线程的只读 observer 可能先占位，使用户随后正式恢复该线程同步失败；control reconnect 后旧 observer interest 还可能持续抢在 replacement recovery 前面。
3. **同 operation 并发响应可能写两次**：两个并发 `respond` 都可能通过 claim/refresh，第二个 `markSubmitting=idempotent` 仍继续 transport write，破坏 exactly-once。
4. **scoped reconnect recovery 可永久卡住**：最多 64 个目标完全串行读取；任一 `thread/turns/list` 无响应且没有 timeout/abort 时，其余线程会长期停在 reconciling/unavailable。

### 新增 P2 / P3

- Action Broker snapshot 原先没有 thread scope、条目上限或总字节预算，理论上可把其他线程的 live request payload 聚成巨帧。
- terminal-result ledger 原先没有 terminal turn identity；Bridge 停机期间新 turn 已开始时，旧 completed/failed 仍可能覆盖成 `working + completed` 并产生错误未读。
- capable/legacy 状态投影共用同一 `statusState` token；旧 build 缓存原地升级后可能永远收不到 truthful unknown 状态。
- terminal ledger 初始化或写入降级尚未进入 health/readiness 诊断字段。

### 修复阶段新增验收

- leader/standby 双 Bridge + 旧 Mobile：standby 不能 resume 后启动 turn，也不能通过旧审批帧写 app-server；leader 对同 request 严格一次响应。
- focused observer → formal resume，以及 control reconnect → formal recovery：正式 attachment 必须确定性获胜，observer 不得反抢。
- 并发同 operation barrier 测试：transport response 数必须严格为 1。
- recovery 第一个 reader 永不 resolve：超时后其他目标仍可恢复；generation 切换必须 abort 旧 workers。
- 旧 build status token → 新 capable build：必须触发 scoped status reset/full projection。
- terminal turn A completed → Bridge 离线期间 turn B active：最终只能是 `working + result:none`，旧 A 终态不得制造未读。

## 十、P1 修复台账

| 初始问题 | 当前处置 | 自动验证证据 |
|---|---|---|
| P1-1 app-server 状态未进入产品链 | shared control/status 进入统一状态引擎；目录 watchdog 只作防漏；状态携带 source epoch、authority generation 和 confidence | control、v2 status、迟到 generation、watchdog 回归 |
| P1-2 daemon 与 JSONL 双实时平面 | daemon/capable 模式停用 legacy continuity 实时双写；private/legacy 保留受能力门控的 fallback | registry、websocket、conversation sync 兼容回归 |
| P1-3 source/发起方/写入权混用 | 协议和 Mobile 独立使用 `executionHost`、`activeTurnId`、`controlState`、`authorityGeneration`；unknown 不降级为 Ready | protocol、Cubit、mode bar、detached detail 回归 |
| P1-4 durable/runtime 两套页面 | durable provider ID 始终进入同一 durable route；runtime 仅作可替换 attachment | durable preview、home/session route、重连回归 |
| P1-5 live item 更新导致排序跳动 | 稳定 item 原位更新；使用结构 ordinal/revision，时间戳只作最终 tie-breaker | conversation sync 与 chat ordering 回归 |
| P1-6 Desktop Need You 不可操作 | 持久 Action Broker 以 source/thread/turn/request/generation 精确标识；聊天页、通知和自动批准共用 opaque request identity | broker、Mobile approval coordinator、notification 回归 |
| P1-7 foreign turn 可被误中断 | active 与 ownership 分离；steer/interrupt/approval/goal/compact/review/rewind/fork 等 mutation 全部经过 exact lease/generation 门禁 | writer lease、core actions、websocket 回归 |
| P1-8 断线不重附且伪装 Working | 增加 reconciling/unavailable、有限并发恢复、单目标超时、旧代 abort 和 scoped reconcile | readiness、runtime recovery、hung-reader 回归 |
| P1-9 settings 假成功 | settings 只在 canonical ACK 后提交 UI；完整/部分 snapshot 有明确语义，旧客户端继续加法兼容 | settings protocol、Mobile settings、shared runtime 回归 |
| P1-10 daemon attach 先读全历史 | daemon attach 不再调用全量 `includeTurns`；Codex 使用分页，Claude 使用有界尾读 | session/websocket、Claude paging、长历史基准 |
| P1-11 页面未绑定原始 source | 页面和分页动态绑定唯一认证 runtime/source fingerprint；歧义、换源和迟到回包 fail closed | durable preview、source mismatch、generation 回归 |
| P1-12 自动批准依赖 transient runtime | 配置、监督和执行改为 durable target + Action Broker；standby/authority generation 下拒绝 mutation | auto approval 与 broker runtime 回归 |
| 新 P1-13 standby 绕过 writer lease | 旧 input、审批、answer、daemon adoption 与新协议共用 writer lease/readiness gate | leader/standby、旧 Mobile 写入口回归 |
| 新 P1-14 observer 抢占正式 attachment | observer 使用可让位租约；正式 resume/recovery 确定性替换，旧 generation 不得反抢 | content observer、control reconnect 回归 |
| 新 P1-15 同 operation 并发双写 | claim/submitting/terminal 使用原子状态转换和 exact removal；并发响应 transport 写入严格一次 | Action Broker barrier 回归 |
| 新 P1-16 单个挂起 reader 卡死全恢复 | 每个 scoped reader 有 timeout/abort；恢复有界并发，单线程失败不阻塞其他线程 | recovery timeout、generation abort 回归 |

对应源码提交：

- `4e66fbcb`：Bridge 权威运行时、Action Broker、writer lease、恢复、v2 增量、Claude 有界历史和安全/性能门禁；
- `93ad516b`：Mobile durable route、source fence、Action Broker UI、原子逻辑分页和本地优先缓存；
- `e54b8eca`：iOS 审批动作宿主与 Cloud 通知隐私投影。

## 十一、P2/P3 处置

原始六个 P2 已分别通过持久 terminal ledger、settings 可操作性、受限 fork/ephemeral parent、detach/interrupt 区分、权威时间与协作设置、认证后 Dock scope/subagent badge 处理。独立复审补充的 snapshot 体积、terminal turn identity、capable/legacy token 隔离和 ledger health 也已加入边界与测试。

仍保留并明确登记：

1. **P2：极端超长 Claude JSONL 单行。** 新 reader 默认只读最多 512 KiB 尾部，游标绑定 inode/设备/快照长度，可接受后续 append 并拒绝截断或跨文件。若单条合法 JSONL 自身超过预算，该条可能以缺口形式跳过，而不是突破内存上限；正常分页、追加和损坏游标均有测试。旧 Codex app-server 不支持分页时同样 scoped fail closed，不回退无界全量扫描。
2. **P2：输入投递台账整文件重写。** 在 4,095 个终态记录、约 1,413,351 字节文件上，10 次 admission + provider-accepted 的最小值 25.0 ms、中位数 26.0 ms、p90/最大值 37.81 ms。它位于低频用户 mutation 路径且有上限，目前不阻断；后续若台账规模或发送频率上升，应改为 append/compaction 或 SQLite。
3. **P3：`/health` 与 `/readyz`。** 为兼容旧探针，进程存活仍可返回 health；可写运行时必须以 readiness、writer lease 和协议阶段为准。Mobile 已使用细分阶段，Bridge 生成的 LaunchAgent/systemd 配置默认仅绑定 `127.0.0.1`，非 loopback 且无 API key 时拒绝启动，除非显式 legacy opt-in。

Mobile 的 catalog 与 status 各自按逻辑 batch 原子落 SQLite；两者不是同一个跨表总事务，因此一次 sync 最多产生两次列表投影，但不会暴露缺页或混代页面。这个边界是刻意的可恢复性取舍，不计为阻断项。

## 十二、性能结果

冻结源码执行 `benchmark:session-sync`：

| 场景 | 结果 |
|---|---|
| 真实目录 312 项 | median 23.915 ms；p95 27.855 ms；max 37.992 ms |
| 合成目录 1,500 项 | priority p95 26.750 ms；complete p95 39.712 ms |
| 合成目录 10,000 项 | priority p95 61.890 ms；complete p95 74.089 ms |
| 1,000 个 live delta | 1,500 项场景 p95 2.181 ms；10,000 项场景 p95 0.787 ms |
| 历史读取 | 首次 14；无变化重连 0；单一 live 变化 1 |
| provider 并发 | 最大 2 |
| WebSocket | 最大帧 57,603 字节；未 ACK/排队合计 2 MiB 时施加 backpressure |

Claude 1 GiB 稀疏历史尾读基准只读取 65,536 字节，20 次暖运行中位数 0.103 ms，p95/最大值 1.111 ms。测试夹具第一次生成稀疏文件时未显式指定 EOF 写入位置，导致尾部事实错误；已删除该临时目录并用明确 offset 重跑。后续稀疏/截断型基准必须同时断言文件尾内容、实际读取字节和结果语义，不能只看文件逻辑大小。

旧性能分支 `917afcf9` 的流式 delta 合并、路径后缀缓存、有界预览扫描、Mirror 尾分页/清理、首帧后初始化、精确 selector 和 Prompt History single-flight 均在当前线保留了等价或增强实现；本轮没有把旧分支整枝回放。

## 十三、冻结验证

- Bridge：113 个测试文件、2,264 项全部通过；TypeScript build 和 native file-browser helper 通过。
- Functions：typecheck、build 通过；1 个测试文件、26 项通过；未部署。
- Mobile：2,876 项通过，4 个环境 smoke 跳过；全量 analyze 为 0 error / 0 warning，52 个仓库既有 info。
- iOS：当前冻结源码 `flutter build ios --simulator --debug --no-pub` 通过，Xcode 317.9 秒；本轮原生改动后的同源 RunnerTests 29/29 通过。
- 格式与差异：Prettier 全部匹配；62 个变更 Dart 文件 0 changed；`git diff --check` 通过。
- 安全：parser 限制消息/token/app version，WebSocket 关闭 per-message deflate 且限制 32 MiB；debug disk trace 默认关闭并具有 no-follow、0700/0600、TTL/大小约束；push 日志只记录哈希身份，不输出响应正文。

## 十四、尚未执行的真实环境门禁

本轮没有：

- 替换或重启生产 Bridge；
- 把 Codex Desktop 从 private 切到 shared daemon；
- 部署 Cloud Function；
- 发布 Shorebird OTA、构建/发送 IPA、安装或修改物理 iPhone；
- 合并 stable、push 或改写其他分支历史。

后续仍需单独授权并观察：Desktop-origin turn 在手机的状态/内容/Need You/审批，Bridge-origin turn 在 Desktop 侧栏的实时出现，同一 active turn 的温和 Bridge 切换，物理通知长按动作、后台行为、视觉连续性和真机功耗。自动测试通过不能替代这些门禁。

本轮一次非安静的 Xcode 诊断曾把当前 shell 继承环境写入工具日志。代码与交付物没有保存这些值，但应把该日志视为可能暴露凭据，并轮换当时 shell 中的可用凭据；后续 Xcode 只使用安静输出或经过清洗的环境。
