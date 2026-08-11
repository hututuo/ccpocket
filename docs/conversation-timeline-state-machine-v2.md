# CC Pocket 会话时间线状态机重建

> 状态：源码实现、三链门禁、全量验证、性能扫描和独立终审均已完成（2026-08-11）；
> 尚未部署 Bridge、构建/发布 IPA 或执行物理设备验收。
> 第 4 节记录修复前基线根因，第 9 节记录当前实现和实测证据。
> 它不替代 `docs/PROJECT_HANDOFF.md`、`decisions.md`，也不把尚未验证的假设写成已完成结论。

## 1. 问题与目标

当前会话时间线仍存在四类相互关联的故障：

1. 首次窗口缺少旧条目时，后续只追加新增量，缺口没有被稳定修复。
2. 多个 provider turn 的临时输出、thinking 和工具项会被折叠成同一大段“中间过程”。
3. 同一会话的“更新数”会在非零、零、非零之间反复变化。
4. 用户消息可能暂时消失，页面跳回上一轮；稍后消息又出现，但位置或副本数错误。

目标不是隐藏闪烁，而是重建一条可证明的状态机：

```text
Codex provider history / live runtime
  -> Bridge canonical turn store + bounded live overlay
  -> conversation_sync_v2 transaction
  -> Mobile SQLite committed window
  -> ChatSessionCubit local optimistic overlay
  -> turn-aware UI projection
```

核心约束：

- provider history 是持久时间线权威。
- Bridge 只能以明确的覆盖范围发布“替换”，不能把局部读冒充完整窗口。
- Mobile SQLite 是唯一持久副本写入者；UI 不直接把 WebSocket 批次当列表真相。
- 本地待发送消息是有稳定身份的临时覆盖层，ACK 只改变状态，不创建第二条消息。
- 显式 provider turn ID 优先于“看见一条用户消息就推断新一轮”。
- 未完成快照不能删除一个已提交、仍可读的窗口。
- 可见时间线在同一 source generation 内只能单调获得更完整的知识；网络抖动不能让已提交内容倒退。

## 2. 当前身份、顺序与写入者

### 2.1 唯一身份

时间线的持久分区键固定为：

```text
bridgeInstanceId + codexSourceId + provider + providerSessionId
```

其中：

- `providerSessionId` 是会话身份；标题、项目名、IP、cwd 均不能代替它。
- `historyTurnId` 是 provider turn 身份。
- `providerItemId` / provider 原始 item ID 是持久条目身份。
- `clientMessageId` 是手机本地发送意图身份，直到 Bridge/provider 返回 admission 映射。

### 2.2 权威顺序

```text
connectionGeneration
  -> sourceGeneration
  -> sourceRevision
  -> contentRevision
  -> provider turn ordinal
  -> provider item ordinal
  -> frame/page sequence
```

时间戳只用于展示、目录 recency 和结构字段缺失时的最终 tie-breaker，不负责修复跨 turn 顺序。

### 2.3 当前写入者清单

| 层 | 当前写入来源 | 允许写入 | 禁止行为 |
|---|---|---|---|
| Provider | app-server turns/items、共享运行时事件 | 持久 turn/item、运行时增量 | 以标题合并线程 |
| Bridge canonical | `conversation-sync-v2.ts` 的 provider reader | 有覆盖范围的 canonical window | 把 latest-turn-only 当完整 recent window |
| Bridge overlay | Desktop/shared runtime observer | 尚未进入 provider history 的有界条目 | 永久并入 canonical base；重复累积同一 provider item |
| Wire | `conversation_sync_v2` snapshot/patch | 带 revision、base、complete/gap 的事务 | 不完整批次发送 deletes 或无条件 replace |
| SQLite | `SessionCatalogCacheRepository` | staging 完整后原子提交 | 非完整 snapshot 清空已提交窗口 |
| Cubit | durable cache + bounded runtime/local overlays | 将 SQLite 窗口投影为稳定列表 | 让 runtime history 成为第二持久 writer |
| UI | `buildChatProcessLayout` | 按 turn/segment 派生折叠视图 | 仅靠可见 UserChatEntry 推断所有 turn 边界 |

## 3. 生产证据：当前会话不是偶发现象

当前任务 thread：

```text
019fe552-2d01-7730-aaf6-87ae94a777f7
```

生产日志对目标键执行脱敏哈希后为：

```text
9caa1ec63d78
```

二者的映射由当前 `traceTarget()` 算法现场复算确认。生产 Bridge 为
`1.69.6-compat.35-a3bd8537`，日志位于 `/tmp/ccpocket-bridge.log`。

同一会话在相邻批次中出现过以下窗口变化：

```text
71 complete
  -> 1 complete
  -> 72 complete
  -> 1 complete
  -> 72 complete
  -> 2 complete
  -> 73 complete
  -> 3 incomplete
  -> 91 complete
  -> 47 incomplete
  -> 126 incomplete
  -> 47 incomplete
  -> 126 incomplete
  -> 9 incomplete
  -> 120 incomplete
  -> 9 incomplete
```

另一个明确片段：

```text
canonical=576 observed=shared:runtime:56 merged=623 -> entries=47 incomplete
canonical=71  observed=shared:runtime:56 merged=126 -> entries=126 incomplete
canonical=458 observed=shared:runtime:50 merged=467 -> entries=9 incomplete
```

因此以下事实已经成立：

- 手机不是单纯“没刷新”；Bridge 本身在发布相互不等价的窗口。
- `latestTurnComplete` 不能代表整个 hot window 的覆盖完整性。
- 相同 source revision 下，provider recent read、旧 snapshot 与 shared runtime overlay 的组合会改变条目集合和数量。
- Mobile 若把这些非完整 snapshot 当完整替换，必然出现内容消失、跳回和计数翻转。

## 4. 已确认的源码根因

### 4.1 Bridge 没有描述窗口覆盖范围

`ConversationContentSnapshot` 只有 `latestTurnComplete`、`latestTurnGap`、
`hasEarlier`，没有说明该批次究竟覆盖：

- 完整 recent hot window；
- 一个完整 latest turn；
- latest turn 的 root + newest tail；
- provider 暂时缺失时的旧窗口 + runtime overlay。

结果是同一种 `snapshot` 可以表示完全不同的知识范围，接收端无法安全决定 replace 或 union。

### 4.2 latest-turn 快捷读没有以“已有完整 recent base”为前提

`conversation-sync-v2.ts::snapshotFor()` 在 source revision 相同且强制刷新时可以直接调用
`latestTurnHistoryReader()`，再把结果合入旧 snapshot。判断没有证明旧 snapshot 是完整 recent base，也没有记录旧 base 的 turn 覆盖范围。

后果：一旦旧 snapshot 来自尾部裁剪、provider 暂缺或不完整窗口，后续 latest-turn-only 刷新只会增加新内容，无法恢复缺失的最近几轮。

### 4.3 latest turn 按条目合并，没有按 turn 做权威替换

`mergeSnapshotWithLatestTurn()` 把旧 snapshot 条目与 latest read 做通用 observed-message merge。它不会：

1. 找到目标 `historyTurnId`；
2. 删除该 turn 的旧 provider 表示；
3. 用本次 provider turn 的稳定 item 集合替换；
4. 仅在本次 turn 不完整时保留明确的 live tail overlay。

因此读法或 ID 变化时，旧 thinking、临时 assistant、工具状态可能继续存在。

### 4.4 reasoning 等条目缺少跨读法稳定 provider item ID

`sessions-index.ts::codexThreadToSessionHistory()` 会给普通 assistant/plan 携带原始 item ID，
但 reasoning 路径没有把 raw item ID 传入 assistant UUID。随后
`sessionHistoryToServerMessages()` 只能按 `idPrefix-index` 生成 ID。

full recent read 与 latest-turn-only read 使用不同的索引域，同一 reasoning item 会得到不同身份，无法被替换或去重。

### 4.5 Bridge 对非空不完整窗口仍允许普通 snapshot/patch

`sendTimeline()` 只在以下情况保护旧窗口：

- provider history unavailable；或
- `latestTurnComplete=false` 且 `entries.isEmpty`。

只要非完整快照有 1 条以上内容，就可能走普通 snapshot/patch，并携带删除语义。这与“部分知识不能删除完整知识”冲突。

### 4.6 Mobile 只保护“空的不完整 snapshot”

`SessionCatalogCacheRepository.stageConversationTimelinePage()` 的
`preserveExistingIncompleteSnapshot` 仅在：

```text
mode == snapshot && entryCount == 0 && !latestTurnComplete
```

时生效。非空不完整 snapshot 会删除全部 `hotEntries`，再写入 1、2、3、9、47 条新集合。

这与生产日志完全吻合，是内容消失和回跳的直接提交点。

### 4.7 UI turn 分段忽略显式 `historyTurnId`

`buildChatProcessLayout()` 以可见 `UserChatEntry` 为唯一 turn 边界。窗口从 turn 中段开始，或用户根在一次替换中暂时消失时，连续多个 provider turn 会被视为一个 partial turn。

后果：

- 多轮临时输出合并成一个大“中间过程”；
- update count 随用户根出现/消失在 4、0、4 之间变化；
- active/final segment 的判定随列表形状变化，导致当前进度跳位。

### 4.8 本地 optimistic 消息的 canonical admission 仍有弱匹配窗口

Cubit 已使用 `clientMessageId` 保留本地 envelope，也会尝试用 provider item/turn 身份升级。
但 app-server canonical user item 不保证回显 `clientMessageId`。若 Bridge 没有提供
`clientMessageId -> providerItemId/historyTurnId` 的稳定 admission 映射，本地 sent envelope 与 canonical row 可能短暂并存、消失或被文本兜底误配。

这部分必须通过结构化映射和回归测试解决，不能扩大“同文本”去重，因为重复发送相同文本是合法行为。

### 4.9 turns-page repair 会用一轮 summary 删除丰富热尾

`ConversationContentSyncService` 在缺少可用 turn ID 时请求 Codex：

```text
limit = 1
itemsView = summary
```

随后 `replaceConversationLatestTurnsRepairPage()` 删除所有 `entry_index >= 0` 的热尾，
仅写入这一页 summary，并无条件把 `latest_turn_complete` 改为 1。

summary 不是 full item coverage，因此它没有删除 thinking、工具和中间文本的权力。这是更新数清零后又恢复的另一条独立路径。

### 4.10 items-page 对单条超大 item 存在永久不可修复缺口

当前 wire 单帧限制为 64 KiB，但 items-page 遇到单个大于帧预算的 item 时会失败且不前移 cursor。
如果 hot window 把该 item 记为 gap，用户重复重试仍会停在同一 item，旧缺口永远不能补齐。

该边界不能由传输层擅自截断并推进 cursor。Bridge 必须返回显式失败且保持 cursor 不变，
Mobile 终止当前修复请求、保留旧窗口和明确 payload gap；后续若产品增加独立的有界 payload
投影协议，再通过新的 capability 和稳定 gap identity 解决。不能把截断内容伪装成完整 provider item，
也不能通过增大无界帧规避。

### 4.11 分页 prepend 可把缓存写成永久不可读

hot window loader 只接受最多 2,000 条且负索引不小于 -2,000；
`prependConversationTurnsPage()` 当前写入前不执行相同上限。接近上限时继续向上分页会提交一个 loader 随后直接返回 null 的数据库状态。

分页事务必须在提交前裁剪或拒绝整页并保留原窗口，不能先写坏再依赖下一次重建。

### 4.12 非空坏窗口没有可见恢复入口

Codex/Claude 的 latest-turn recovery 只在 `cachedPreview.entries.isEmpty` 时显示。
但生产故障恰好会留下 1、2、9、47 条非空坏窗口，因此恢复按钮被隐藏；自动 repair 也不会替用户触发。

恢复资格必须由 coverage/gap 决定，而不是由 `entries.isEmpty` 决定。自动修复仍需有界、single-flight，且修复页不能破坏已提交窗口。

### 4.13 optimistic 保护会在第一次 canonical 命中后过早撤销

Cubit 在 canonical history 首次包含同一 `clientMessageId` 后，会把它从本地 overlay 保护集合移除。
这是 canonical 完整窗口下的正确收束；但当前下一批非完整 destructive replace 可以再次漏掉该 user，
此时 sent bubble 已失去保护并真正消失。

此外，已投递队列恢复仍存在“全局同文本 sent 即认为已显示”的兜底。用户在不同 turn 合法发送相同文本时，
该兜底可能吞掉新的 turn boundary。修复必须以 client/provider/turn 身份为先，并把文本匹配限制在确实没有稳定身份的同一待确认 turn。

## 5. 新状态机与协议语义

### 5.1 Bridge 内部窗口类型

Bridge 内部必须显式区分：

```text
canonicalRecentWindow
  coverage = completeRecent(turn range known)

canonicalLatestTurn
  coverage = completeTurn(turnId)

canonicalLatestTail
  coverage = partialTurn(turnId, retained item ids, gap)

runtimeOverlay
  coverage = provisional(turnId, producer, generation)
```

内部结构允许调整文件名，但必须能回答：

- 哪些 turn 被完整覆盖？
- 最新 turn 是否完整？
- 哪些 item 是 provider canonical？
- 哪些 item 仅来自 runtime overlay？
- 该批次是否有权删除旧 entry？

### 5.2 Replace 与 additive 的唯一规则

| 输入 | Bridge wire 语义 | SQLite 语义 |
|---|---|---|
| 完整 recent window | snapshot 或有 base 的 patch，可携带 deletes | 原子 replace/patch |
| 完整 latest turn + 已知完整 recent base | turn-scoped replacement | 仅替换该 turn，保留其他 turn |
| partial latest turn/tail | additive patch，无 deletes | upsert，不删除旧 committed rows |
| provider 暂不可用 + overlay | additive patch，无 deletes | upsert overlay，保留 canonical window |
| summary/repair page | additive repair，无 deletes | 合并可确认条目，不把 summary 标成 full |
| source generation 改变 | scoped reset + 新事务 | 清 staging；旧窗口保留到新权威 commit |
| 确认线程被删除 | explicit destroyed | 删除该线程副本 |

`latestTurnComplete=false` 时绝不允许 whole-window delete。

### 5.3 稳定条目身份

优先级：

```text
providerItemId
  > scoped toolUseId/historyTurnId
  > clientMessageId admission mapping
  > legacy deterministic fallback(provider, thread, turn, type, ordinal)
```

要求：

- reasoning、assistant text、plan、tool、tool result、user input 均携带原始 provider item ID（存在时）。
- 同一 item 在 full/latest/items-page/runtime promotion 中身份不变。
- occurrence suffix 只能区分 provider 明确存在的重复 item，不能依赖本次数组索引。

### 5.4 按 turn 合并

Bridge 先构建：

```text
TimelineTurn {
  turnId
  ordinal
  rootUserItem?
  canonicalItems[]
  runtimeItems[]
  completeness
}
```

规则：

- complete provider turn 到达：按 `turnId` 原子替换该 turn 的 canonical items；已被覆盖的 runtime items 删除。
- partial provider turn：按 stable item ID upsert；旧 canonical items 不删除。
- runtime item：只进入对应 turn 的 overlay；provider canonical 覆盖同 stable ID 后删除 overlay。
- 没有 turnId 的 legacy 条目使用有界 fallback 分组，不得跨越明确 turnId 边界。

### 5.5 SQLite 提交模型

不新建竞争数据库，扩展现有表或 staging 元数据：

- staging 保存 coverage/completeness/target turn。
- whole-window replacement 与 turn-scoped replacement 分开。
- partial transaction 采用稳定 order key 合并，不能直接复用不同读范围里的局部数组 index。
- additive latest-turn 新条目按现有 turn 尾部追加；同 entry ID 原地更新并保留已有 order。
- commit 后再 ACK；失败不推进 revision。
- UI 始终读取最后一次已提交窗口，staging 和网络错误不可见。

### 5.6 Cubit 覆盖层

Cubit 可见结果为：

```text
SQLite canonical entries
  + local optimistic user envelopes
  + bounded current-generation runtime-only status/guardian/result overlay
```

本地消息生命周期：

```text
local(clientMessageId, sending)
  -> Bridge ACK: same row, queued/sent
  -> provider admission: same row gains providerTurnId container identity
  -> canonical exact client echo: same row gains providerItemId
  -> canonical cache row: exact row becomes canonical
```

现代 app-server 回显 exact `clientMessageId` 时，任何阶段都不创建第二个用户气泡。Codex 一个
turn 可以同时包含 root user 和多次 steer，因此 `historyTurnId` 只是容器身份，不能把某个
provider user item 归给本地 envelope；相同文本也只能用于显示诊断。旧 app-server 若不回显
item 级关联，客户端 fail-open 保留两条事实，直到后续 exact echo/完整 canonical 证明身份，
而不是把 Desktop steer 错认成 Mobile root。

### 5.7 UI turn 投影

先按显式 `historyTurnId` 分区，再在每个 turn 内构建 segment：

1. 相邻同 `historyTurnId` 属同一 turn；
2. tool result 可按 toolUseId 回挂到同 turn 的 tool；
3. 无 turnId 的 legacy 条目才使用 UserChatEntry 边界；
4. 窗口从 turn 中段开始时，partial turn key 为 `turn:<historyTurnId>`；
5. 缺少 user root 不得把两个不同 historyTurnId 合并；
6. 展开状态 key 基于 turn/item identity，不基于当前数组 index。

## 6. 实施顺序

### 阶段 A：证据与测试先行

- 本机开发门禁直接只读冻结的真实 rollout 前缀，正文、ID、时间戳和工具结构原样保留，
  不脱敏、不摘要、不改写；大型原文件不复制进 Git，仓库只保存路径提示、prefix bytes、SHA-256、
  人工确认的业务 oracle 和小型协议场景。
- 记录每批 source/content revision、coverage、entry IDs、turn IDs、complete/gap、canonical/runtime 数量。
- 增加能复现 71→1→72、47→126→9 的单元/集成测试。

### 阶段 B：Bridge canonical/overlay 重构

- 为所有 Codex item 贯通 provider item ID。
- 引入覆盖范围和按 turn replacement。
- 修正 latest-turn 快捷读门禁。
- complete canonical 覆盖后才清理 runtime overlay。
- 非完整窗口只发 additive、无 deletes。

### 阶段 C：Mobile SQLite 单调提交

- 非完整 snapshot/patch 不删除 committed window。
- 引入稳定 order/turn merge，解决不同读范围 index 冲突。
- complete recent 或 explicit turn replacement 才删除已覆盖行。
- revision/base/generation 不匹配时仅丢弃 staging。

### 阶段 D：Cubit 与 UI

- optimistic admission 先绑定 exact provider turn；只有 item 级 exact client/provider/UUID
  证据才完成 canonical 原地升级。
- canonical admission 只结束对应本地 envelope；后续 partial transaction 不具有删除该 canonical user 的权力。
- turn 分段优先使用 historyTurnId。
- 保持展开、滚动锚点和当前进度 identity。
- 更新计数只统计稳定 segment，不因同一 incomplete transaction 翻转。

### 阶段 E：性能与兼容

- 不增加逐会话 WebSocket、全历史解析或 UI 全量排序。
- provider read 保持有界并发；同一 thread 串行 commit。
- 旧 Bridge/Mobile 继续走 legacy snapshot，但 unknown/incomplete 不伪装完整。
- Claude adapter 保持原行为，新增字段均为 additive/capability-gated。

## 7. 必须新增的回归矩阵

Bridge：

- incomplete prior snapshot 不能触发 latest-turn-only 修复捷径。
- full read 与 latest read 对同一 reasoning item 产生同一 ID。
- partial latest turn 不生成 deletes。
- complete latest turn 只替换目标 turn。
- runtime 50 条 + canonical partial/complete 不产生重复或数量回退。
- provider 暂时返回空/少量后恢复，窗口不倒退。
- 512 KiB fallback 到 latest-only 时标记为非权威整窗，即便 latest turn 自身 complete。
- 单个最终仍大于 64 KiB 的 item 明确失败，cursor 不推进，旧窗口不缩水。

Mobile SQLite：

- 已提交 72 条，收到 1/2/9/47 条 incomplete snapshot 后仍保留可读窗口。
- partial upsert 不产生 index 冲突，顺序由稳定 order 决定。
- complete replacement 可以删除旧条目。
- reset、断线、重订阅只清 staging，不清 committed cache。
- rich hot tail 收到一轮 summary repair 后不删除详情，也不伪装 complete。
- 1,999 条窗口继续 prepend 时保持在上限内或原子拒绝，loader 始终可读。

Cubit/UI：

- 同一 optimistic 消息从 sending 到 canonical 始终只有一条。
- provider 回显 clientMessageId 时原地升级；不回显时 fail-open，禁止用 turnId/文本猜 item 所有权。
- receipt→同 turn 的 Desktop steer→root exact echo 无论到达顺序如何都不串绑 client identity。
- 两个不同 turn 发送相同文本时，两条 user root 均保留且分别绑定自己的 turn。
- 四个不同 historyTurnId 在缺少 user roots 时仍是四个 turn。
- 增量更新后中间过程数量不出现 4→0→4。
- 展开状态、滚动位置和当前进度在 cache commit 后保持。
- 当前 turn 新增项不会使页面跳到上一轮。

端到端：

- 冷启动、前后台、断线重连、手动刷新、活跃长 turn、历史分页。
- 当前真实大型 thread 的未脱敏只读前缀。
- 新 Mobile+新 Bridge、旧 Mobile+新 Bridge、新 Mobile+旧 Bridge。

### 7.1 三条互补链路与唯一场景源

不能维护第二套 Bridge 或第二套业务归一化实现。黑盒门禁固定为：

1. 未脱敏真实 rollout → 真实 Bridge → 原始 WebSocket 帧；
2. 冻结原始协议帧 → 真实 BridgeService/SQLite/Cubit/layout；该链只验证 Mobile transport
   和投影，不宣称验证 Bridge normalization；
3. 假 Provider/app-server RPC → 真实 Bridge WebSocket → 真实 Headless Dart 接收端。

仓库里的 `test-fixtures/conversation-chain/scenarios.json` 只描述 Provider 原始事件、窗口序列和
人工业务不变量。Node harness 与 Dart receiver 读取同一场景；协议和稳定身份仍由生产 Bridge、
生产 decoder 生成。固定 wire fixture 只能由一次人工复核通过的真实 Bridge 输出捕获，运行时只
绑定 subscription/request 这类 transport ID，不能调用生产 normalizer 自动生成 expected。

每次运行在 `/private/tmp/ccpocket-chain/<run-id>/` 输出 Provider read、Mobile client frame、
Bridge frame、ACK、SQLite、Cubit、layout 和 summary 轨迹。测试断言使用
sequence/commit 因果顺序，不用 wall-clock sleep。固定 wire 的来源、源码摘要、能力协商、
规范化范围和不能证明的范围登记在
`test-fixtures/conversation-chain/protocol-wire.provenance.json`。

## 8. 完成门禁

以下全部完成前，不得把任务报告为已修复：

- 状态机文档与源码行为一致，并登记所有偏差。
- 四类症状各有失败测试和通过测试。
- Bridge 与 Mobile 定向测试、全量测试、静态检查通过。
- 对大型活跃 thread 做结构化 smoke，条目集合不倒退、不重复、turn 不串联。
- 性能扫描确认没有新增全历史热路径、逐会话轮询、线性内存增长或 UI 全量重建。
- 独立 Sol Max 复审无 P0/P1；P2 已修或有明确非阻断依据。
- 部署、IPA、OTA 与物理设备验收继续作为独立授权和完成状态。

## 9. 当前实现、兼容边界与验证证据

### 9.1 Bridge 覆盖状态机

已增加加法能力 `conversation_sync_window_coverage_v1` 和正式字段
`windowComplete`。当前行为为：

- 完整窗口可以 snapshot 或基于完整 base 做带 deletes 的 patch；
- 不完整窗口只发送 `mode=patch`、`baseRevision`、`deletes=[]`，且不推进 canonical
  replacement revision；
- partial 批次携带全部 stable-ID 重叠锚点，使 Mobile 能把扩大窗口里的旧条目插回
  正确位置，而不是追加到最新尾部；
- partial union 每会话最多 2,000 个 ID、最多 32 个目标；thread destroyed 时清理；
- Bridge 丢失可证明 base 后 fail-closed，直到完整 replacement；
- 未声明 coverage 的旧 Mobile 收不到任何 incomplete window，包括 revision 缺失的冷启动，
  防止旧 replacement 语义清空已有 SQLite cache；
- focused latest-turn read 只有在完整 recent base 上才走快捷路径；无法证明同一 provider turn
  时回退到完整有界读；完整 latest turn 按 turn 替换，不完整读只 union；
- reasoning 等路径贯通 provider 原始 item ID；单条超帧 item 明确失败且 cursor 不前移。

### 9.2 Mobile SQLite 与 UI 投影

SQLite schema 升至 v8，持久保存 `window_complete`；旧 v7 数据保守迁移为 incomplete。
提交规则为：

- snapshot/patch 分页先写 staging，事务成功后再累计 ACK；
- incomplete 只做 additive upsert，不删除 committed rows；
- complete replacement 才允许删除；
- partial 扩窗使用 shared stable-ID anchors 合并顺序；锚点相反时拒绝事务，不猜测顺序；
- 已分页的负索引前缀保留，hot rows 在同一 SQLite batch 中重新索引；
- staging、partial union、prepend 均有硬上限，内存不保存全量分页 snapshot。

UI 先按显式 `historyTurnId` 分轮，再构建 process surface。增量 commit 不再用数组位置作为
展开 identity；thinking、工具、result 和 guardian 保持在同一轮的稳定 surface。程序化滚动
使用独立抑制 fence，历史跳转/extent correction 不会误取消正在进行的定位。

### 9.3 用户消息 admission 与匿名 turn 身份

`turn/start` 现在先从 app-server RPC 结果提取 provider turn ID，再发布
`input_delivery_status_v1`；`turn/steer` 使用已由 compare-and-set 验证的 exact turn ID。
该可选字段贯穿：

```text
CodexProcess event
  -> durable input ledger
  -> SessionManager receipt
  -> WebSocket
  -> Mobile parser/handler/Cubit
```

Mobile 用 `clientMessageId -> providerTurnId` 给 optimistic envelope 标注 turn 容器。canonical
user 只有携带 exact client/provider/UUID 证据时才合并；`turn/start` 与 `turn/steer` 都不再用
turnId 或文本挑选 provider item。现代 exact echo 保持一个气泡；旧 app-server 无 item 级 echo
时 fail-open 保留本地意图与 provider 事实，避免把同 turn 的 Desktop steer 绑定到 Mobile root。
字段为可选、最长 256 字符；旧 Bridge/旧 Mobile 均可忽略。Claude 保留原有 legacy 一轮一用户
兼容路径，不把 Codex 的多 steer 约束错误扩散到 Claude。

缺失 app-server turn ID 的 fallback 不再使用 `distanceFromNewest`。现在使用线程、首个稳定
内容/时间锚点和同锚点的 chronological occurrence；追加新 turn 不会改写旧匿名 turn ID。
有界 full read 先按稳定内容做 LCS，再在稳定匹配之间按 root anchor 做 LCS，因此同一次刷新中
“旧活动轮继续增长 + 新同根轮次追加”仍把旧 ID 交给较早的演化轮次。完全空且无时间的 turn
才使用 page namespace，明确承认该数据本身无法提供跨页身份。

### 9.4 三条真实链路

统一入口：`scripts/test-conversation-chain.sh`。

1. 本机未脱敏 rollout 前缀（772,565,254 bytes、162,298 行、SHA-256
   `865b002221f84f77e92345714d3b5413de1d9c79171ed725280322c96ae48532`）经过真实
   CodexProcess、真实 Bridge 和原始 WebSocket；验证真实正文、稳定 ID、ACK 和最新 turn。
2. 由真实 Bridge 闭环捕获并规范化 transport ID 的固定 raw wire，经过真实
   BridgeService、协议 decoder、SQLite、Cubit 和 layout；fixture SHA-256 为
   `28a24db71400e29346d55aa4d727fede3492203dce05f699bbbcf4082ad11bd3`。
3. fake Provider boundary 只返回原始 `ServerMessage` 窗口；BridgeWebSocketServer、正式
   conversation_sync_v2、WebSocket、Headless Dart、SQLite、Cubit 和 layout 全部运行生产代码。

第 3 条实际生成并验证：

```text
Provider/Bridge payload:
71F -> 1P -> 72F -> 1P -> 72F -> 2P -> 73F -> 3P
    -> 91F -> 47P -> 126F -> 47P -> 126F -> 9P -> 120F -> 9P

SQLite committed rows:
71, 71, 72, 72, 72, 72, 73, 73,
91, 91, 126, 126, 126, 126, 120, 120
```

所有 P 批次均由正式 Bridge 生成 `mode=patch + baseRevision + 0 deletes`；测试逐批核对
Provider 实际 read 数、Bridge payload 数、sourceEntryCount、SQLite commit 和最终 ACK。
固定 wire 不再从 `scenarios.json` 的 expected count 冒充 raw payload；loader 会直接聚合
实际分页 entries 并在不一致时失败。

### 9.5 性能扫描

当前 Mac 合成结果：

- 当前真实目录 332 条、20 次 state DB 读取：p95 27.305 ms；
- 1,500 条目录：priority p95 37.046 ms，complete p95 53.299 ms；
- 10,000 条目录：priority p95 84.634 ms，complete p95 97.644 ms；
- provider history 并发最多 2；
- 最大实测 wire frame 57,603 bytes，低于 64 KiB；
- 1,000 次 delta dispatch p95：1,500 条目录 2.671 ms，10,000 条目录 0.880 ms；
- 第二客户端携带 state token 重连时正文 history read 为 0；单 dirty timeline 为 1 次，目录只读 1 次；
- per-subscription partial body 全量复制已删除，订阅只保留有界 ID union；
- 旧性能分支 `917afcf9` 的流式合并、路径缓存、预览有界扫描、镜像分页、首帧收窄仍在祖先链。

Mobile SQLite 现有 benchmark：

- 1,500 条目录写入 213.753 ms，读取 p95 11.781 ms；
- 200 条 hot window 本地打开 p95 1.844 ms；
- 2,000 条 staging 写入 248.037 ms，峰值 RSS 增量 24.453 MiB；
- 数据库 4.453 MiB，查询计划命中 `conversation_hot_entries_order` 索引。

剩余设备级观察项是 SQLite staging 的累计 COUNT/SUM、超大窗口批量 reindex、可见布局和
Cubit 的真机帧时间；它们不是当前正确性阻断，但不能用桌面单测声称真机功耗已验收。

### 9.6 实施偏差

原计划把完整黑盒写成单一 app-server seam。最终拆为两个互补边界：真实 rollout 链验证
Codex raw turn normalization；确定性 W0 链在 `historyReader` 这一 Provider adapter 边界注入
原始 `ServerMessage` 窗口。两条链都运行同一生产 Bridge normalizer/protocol，且没有 fake
Bridge 或第二套 stable-ID 生成器。这比让 fake app-server 用手写 normalized frame 更容易
明确每条测试能证明什么，也保留了真实 app-server 解析证据。

### 9.7 最终门禁与剩余边界

最终源码树取得以下信号：

- Bridge 全量单 worker：118 files passed、1 skipped；2,452 tests passed、1 skipped；
- Bridge TypeScript/native helper build 通过；
- Mobile 全量：3,144 passed、4 skipped，末行 `All tests passed!`；
- Flutter analyze：0 error、0 warning、53 个仓库 info；
- `git diff --check` 通过；
- 未脱敏 772,565,254-byte rollout、固定 raw wire replay、fake Provider→真实 Bridge→
  Headless Dart 三条链均通过；
- Sol Max 最终复审为 P0=0、P1=0。

仍有两个非阻断 P2 兼容边界，均选择“保守重复”而不是错误覆盖：

1. 旧 Codex app-server 若完全不回显 client/provider/UUID item identity，Mobile 无法证明本地
   root 与某个 provider user 是同一 item，会暂时同时显示两条事实；
2. 匿名 turn 同时没有 ID、时间，内容也不可区分，且两个滑动窗口完全无重叠时，不存在可证明
   的跨窗口稳定身份；当前只保证有重叠窗口的连续性。

本任务没有修改 Swift、Info.plist、entitlement、Podfile 或原生插件，因此没有为了本轮纯
TypeScript/Dart 正确性改动重做 IPA/真机门禁。部署、IPA、OTA 与物理设备验收仍是独立授权。
