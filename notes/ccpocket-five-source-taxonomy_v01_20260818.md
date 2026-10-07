# CC Pocket 五类原始数据来源边界与重设计基础

版本：v0.2-raw-only（2026-08-18）  
用途：为下一轮会话同步、时间线和状态架构重设计提供事实边界。  
范围：只整理 Codex/Bridge 侧的原始数据、观察路径、结构化 provider 刷新和权威持久历史。

## 0. 先纠正“5 个来源”的含义

当前 Bridge 源码在
[`packages/bridge/src/local-features/conversation-sync-v2.ts`](../packages/bridge/src/local-features/conversation-sync-v2.ts:542)
里实际声明了四个 `projectionSource` 值：

```text
runtime
sharedObserver
externalObserver
providerRefresh
```

这四个值描述“某条观察结果或投影是由哪条读取/观察路径产生的”，不是四个 Bridge，也不是四个可以互相覆盖的数据库。

为了重设计，必须补上第五层：`canonicalHistory`（权威持久历史）。它不是第五个实时 overlay producer，而是 provider 已落盘的 durable history 及其结构化读取结果的权威归宿。也就是说：

- 四个现有值是“观察/读取来源”;
- `canonicalHistory` 是“最终事实层和唯一 canonical writer 边界”。

本文件只保留原始数据边界。五条路径都直接插入 canonical timeline 仍然会造成重复条目、旧消息回灌、时间线跳动和最终回复被中间过程覆盖，因此 canonical 写入权必须单独限定。

## 1. 总体分层

```text
                 ┌──────────── runtime ────────────┐
                 │                                  │
                 ├────── sharedObserver ────────────┤
provider/runtime ┤                                  ├─> observed overlays
                 ├───── externalObserver ───────────┤       │
                 │                                  │       │
                 └───── providerRefresh ────────────┘       │
                                                         ┌───▼──────────┐
                                                         │ canonical     │
durable rollout / provider DB / app-server history ────>│ History       │
                                                         │ (SSOT writer)  │
                                                         └───┬──────────┘
                                                             │ canonical snapshot/patch
                                                             ▼
                                                   canonical snapshot/patch
                                                             ▼
                                                    raw Bridge protocol data
```

核心原则：

1. `canonicalHistory` 是唯一可以创建、替换或删除 canonical timeline entry 的层。
2. `runtime`、`sharedObserver`、`externalObserver` 只能产生有 generation 边界的临时 overlay 或状态观察，不能把观察消息直接写成永久历史。
3. `providerRefresh` 负责向 provider 请求可验证的结构化事实；它的结果在提交到 canonical store 后才成为 canonical。
4. 本轮只记录原始数据和 canonical 提交边界。
5. 任何来源暂时不可用，都保留上一次有效 canonical 内容；不得用空结果清空原始事实，也不得用时间戳/文本猜测覆盖稳定 ID。

## 2. 来源一：`runtime`（Bridge 运行时实时源）

### 2.1 真实定义

`runtime` 是 Bridge 自己持有的当前运行时会话 fanout/action broker 路径。它对应正在运行的 turn 和实时事件，包括流式文本、thinking、工具执行、审批/问题请求、停止和当前运行状态。当前代码的 runtime 生命周期入口和 overlay 资格判断位于 `conversation_sync_v2.ts` 约 1080–1150 行；runtime 消息在共享观察缓存中以 `projectionSource: "runtime"` 保存（约 2023–2040 行）。

### 2.2 能提供的事实

- 当前 Bridge 看到的运行状态：working、waiting、completed、failed 等；
- 当前 active turn、authority generation、runtime session；
- 流式文本 delta、thinking、工具开始/更新/结束；
- 审批、问题、权限或表单请求及其 resolved 生命周期；
- 当前运行轮次的低延迟进度和控制反馈；
- 当前 Bridge 连接下是否仍能控制这个 turn。

### 2.3 明确不能提供的事实

- 不能单独决定最终 provider item ID；
- 不能证明历史已经持久化成功；
- 不能在重连后证明某个旧 delta 仍属于当前 turn；
- 不能替代完整的 thread/turn/item 顺序；
- 不能把某次本地重放或延迟事件当作新用户输入再次提交。

### 2.4 身份和时序

runtime 事件必须至少带：

```text
bridgeInstanceId
codexSourceId
providerThreadId
runtimeSessionId
authorityGeneration
activeTurnId
overlayId / providerItemId（若 provider 已提供）
observedAt
```

如果 provider 还没有稳定 item ID，`overlayId` 只能是本次 runtime generation 内部的临时 ID，不能写进 canonical history 作为永久身份。

### 2.5 输出边界

`runtime` 只写 `runtime_overlay`：

```text
runtime_overlay key =
(provider, threadId, runtimeSessionId, authorityGeneration,
 activeTurnId, overlayId)
```

当 providerRefresh/canonicalHistory 提交了相同 provider item，原子删除对应 overlay；当 turn 结束、authority generation 变化、Bridge 重连或 control ownership 失效时，只删除对应 generation 的 overlay。不能清空整个会话的 canonical timeline。

### 2.6 取证状态

- 真实 app-server/Unix daemon stream 已有实时内容和 idle/complete 边界捕获；
- Bridge 内部 runtime fanout 的逐帧手机回执尚未由物理 iPhone 验证；
- 因此“runtime 能观察到原始事件”是 `PASS`。

## 3. 来源二：`sharedObserver`（共享 app-server/Desktop 观察源）

### 3.1 真实定义

`sharedObserver` 是 Bridge 对共享 Codex app-server/daemon 或 Desktop 运行时的观察路径。它观察同一共享进程正在产生的通知、状态和内容，不等同于 Bridge 自己启动的一次 runtime turn。创建/订阅入口在 `conversation_sync_v2.ts` 约 907–932 行；缓存和 `projectionSource: "sharedObserver"` 的保存路径在约 2023–2040 行。

### 3.2 能提供的事实

- Desktop 或共享 app-server 当前正在发生的 turn/status 变化；
- 共享 daemon 发出的内容增量、工具/审批活动；
- 某个线程被其他客户端占用、切换或重新挂接的观察证据；
- 在 Bridge 没有直接控制权时，尽可能提供运行中提示。

### 3.3 不能提供的事实

- 不能保证冷线程一定会发通知；
- 不能保证通知包含完整 turn/item identity；
- 不能把观察到的文本直接当作 provider 的最终历史；
- 不能在没有 authority/source fingerprint 时允许写设置或发送消息；
- 不能用“同文本、同时间”推断它就是 canonical item。

### 3.4 身份和时序

观察结果至少使用：

```text
bridgeInstanceId
codexSourceId
providerThreadId
sharedObserverGeneration
runtimeSessionId（若有）
turnId（若有）
providerItemId（若有）
observerEventId
observedAt
```

没有稳定 turn/item ID 时，只能作为 `observed` overlay；不能生成一个看似永久的 fallback ID 再写入历史。

### 3.5 输出边界

`sharedObserver` 只更新 `shared_observer_overlay` 和运行状态证据。它可以触发一次受限的 `providerRefresh`，但不能直接替换 canonical snapshot。观察中断时保留旧 canonical 内容，并把观察状态标成 unavailable/degraded；不要把“暂时没收到事件”解释成 idle 或空历史。

### 3.6 取证状态

- 已有 Unix socket WebSocket 和共享 daemon 的真实传输捕获；
- 因此共享 observer 的原始传输观察为 `PASS/PARTIAL`。

## 4. 来源三：`externalObserver`（rollout/JSONL 外部观察源）

### 4.1 真实定义

`externalObserver` 读取或 tail 外部已落盘的 rollout/JSONL、Desktop 活动和相关索引，以补充 Bridge 当前 runtime/共享 observer 看不到的线程。监控接口 `observeCodexThread`、`inspectCodexThread` 位于 `conversation_sync_v2.ts` 约 5413 行以后；消息进入外部观察缓存并标记 `projectionSource: "externalObserver"` 的路径约在 5595–5726 行。

### 4.2 能提供的事实

- 已落盘的 `event_msg`、`response_item`、活动尾部和历史事件；
- Desktop 曾经发生过某轮活动的延迟证据；
- rollout 中的 idle/running 线索、最近观察时间和部分 turn 线索；
- providerRefresh 还未完成时的“可能有变化”提示；
- 跨 Bridge 重启后可重新发现的历史活动。

### 4.3 不能提供的事实

- 不能单独证明“此刻正在运行”；
- 不能保证事件到达顺序等于 canonical item 顺序；
- 不能区分所有重复的 `event_msg` 和 `response_item`；
- 不能用文件尾的一个时间戳覆盖完整轮次顺序；
- 不能直接决定 Need You、发送成功或 provider 接受。

### 4.4 身份和时序

优先使用：

```text
rolloutId / file identity
providerThreadId
turnId
providerItemId
event kind + sequence/offset
observedAt
```

同一 rollout 同时出现 `event_msg` 和 `response_item` 时，必须保留来源类型和原始 offset；二者不能因为文本相同就各写一条 canonical entry，也不能因为一条先到就删除另一条证据。

### 4.5 输出边界

`externalObserver` 只产生 `external_activity_overlay`、状态线索和 refresh trigger。它可以请求 providerRefresh 重新核对；核对完成前不能把外部观察直接合入最终 timeline。外部观察延迟或解析失败时，不清除现有历史，不把 unknown 静默降级为 idle/Ready。

### 4.6 取证状态

- 已保留 13 类真实 rollout，包括短、长、分叉、子 Agent、流式和 idle-gap 样本；
- 已有完整长流逻辑记录和原始事件类型；
- 这是“真实落盘源可采集”的 `PASS`，不是“实时 externalObserver 到手机已验证”的 `PASS`。

## 5. 来源四：`providerRefresh`（结构化 provider 刷新源）

### 5.1 真实定义

`providerRefresh` 是 Bridge 向 Codex/provider 请求结构化历史的路径，使用 `historyReader`、`latestTurnHistoryReader`、catalog/state DB 和相应的 thread/turn/item 读取接口。类型入口在 `conversation_sync_v2.ts` 约 437–450 行；读取器注入在约 346–349、587–590 行；provider refresh 的 merge/覆盖路径约在 3290–3620 行和 7757 行附近。

### 5.2 能提供的事实

- 结构化 thread、turn、item；
- provider 给出的稳定 threadId/turnId/itemId、顺序和 revision；
- 最近一轮和有界历史窗口；
- canonical snapshot、增量 patch、cursor 和 gap；
- 最终回复、工具结果和已持久化的用户消息；
- 通过 provider 直接读取的 settings/model/effort/权限字段（能力允许时）。

### 5.3 不能提供的事实

- 不是低延迟流式源；
- 读取失败、接口暂不支持或返回空页时，不能清空本地旧快照；
- 不能保证正在执行 turn 的每个最新 delta 已经落盘；
- 不能把一次读取结果当作永远不变的全局版本，必须带 revision/state token；
- 不能绕过 provider 的写入所有权。

### 5.4 身份和时序

结构化结果应携带：

```text
provider
codexSourceId
providerThreadId
providerRevision / state token
turnId
itemId
turn ordinal
item ordinal
cursor / page boundary
readObservedAt
```

排序优先级是 provider revision、turn ordinal、item ordinal；时间戳只能用于显示和缺失字段的最后 tie-breaker，不能重新编排已有 provider 顺序。

### 5.5 输出边界

providerRefresh 的结果要先进入 staging，再以一个 revision 原子提交到 `canonicalHistory`。只有提交成功后才：

1. 前移 state token；
2. 删除已被 canonical 覆盖的 runtime/shared/external overlay；
3. 记录 canonical commit 的 revision、范围和原始提交证据；
4. 由后续协议/客户端设计决定如何消费该事实，本文件不规定消费端。

如果 base revision 不匹配，只做该 thread 的 scoped reset/gap 请求；保留现有可读窗口，禁止把新旧窗口简单拼接。

### 5.6 取证状态

- app-server 结构化协议 schema 和 thread/read/turns 类捕获已存在；
- 某些 `thread/items/list` 能力是否在每个当前运行版本都可用，需要按实际 CLI 做能力探测；
- 因此“provider refresh 可提供稳定结构化顺序”是 `PASS（有能力差异说明）`，不能宣称所有 item 详情接口都已覆盖。

## 6. 来源五：`canonicalHistory`（权威持久历史层）

### 6.1 它为什么必须单独列为第五类

`canonicalHistory` 不是又一个实时 observer，而是所有最终历史必须汇聚到的唯一事实层。它来自 provider 已持久化的 rollout/JSONL、app-server state/history DB 以及 providerRefresh 的结构化读取结果。把它和 `providerRefresh` 混为一个来源，会误以为“发起一次读取”就等于“历史已经提交”；把它和 runtime 混为一个来源，会导致临时 delta 直接污染永久历史。

### 6.2 能提供的事实

- 已持久化的 thread/turn/item；
- 稳定 provider identity 和 provider 顺序；
- 最终回复、工具结果、用户消息和轮次边界；
- fork/subsession/parent-child 等 provider 关系（数据实际存在时）；
- 重启、重连后可以重新构建的 durable timeline；
- 作为任何下游副本或重建过程的唯一原始基准。

### 6.3 不能提供的事实

- 不能保证刚刚产生的 runtime delta 已经立即落盘；
- 不能替代实时 approval、thinking、工具进度；
- 不能把不同 provider/source 的同名 thread 合成一条；
- 不能在 snapshot 不完整时假装完整；
- 不能被手机端“修复”或反向写入。

### 6.4 身份和写入所有权

canonical entry 的最低身份是：

```text
codexSourceId
providerThreadId
turnId
itemId
provider order / revision
```

若 provider 本身没有 itemId，必须保存可审计的原始 offset/ordinal，并把 identity confidence 标记为 degraded；不得生成一个普通 UUID 后就声称它是 provider 永久 ID。

canonical writer 只有一个：Bridge 的 providerRefresh/canonical commit 事务。runtime、sharedObserver、externalObserver 和任何下游客户端都没有 canonical 写入权。

### 6.5 取证状态

- 已有完整逻辑长流和真实 rollout 样本；
- 已保存大量数据库元数据、抽样原始行和扩展 body；
- 约 2.2 GiB 的原始 SQLite 页面级完整副本没有放进包内，这是取证包体积和敏感原始数据边界，不代表 canonical 逻辑历史不存在；
- 因此“逻辑 canonical 历史可取证”是 `PASS`，“完整生产 SQLite 页面级副本已随包交付”是 `UNSUPPORTED/未交付`。

## 7. 五类原始来源的能力矩阵

| 来源 | 低延迟 | 稳定 ID | 可证明已落盘 | 能提供最终顺序 | 允许写 canonical | 正确输出 |
|---|---:|---:|---:|---:|---:|---|
| `runtime` | 高 | 通常否/临时 | 否 | 否 | 否 | 当前 turn overlay |
| `sharedObserver` | 高/中 | 可能缺失 | 否 | 否 | 否 | 共享运行观察 overlay |
| `externalObserver` | 中/低 | rollout/offset 级 | 部分 | 否 | 否 | 延迟活动证据与 refresh trigger |
| `providerRefresh` | 中/低 | 是（能力支持时） | 读取结果可验证 | 是 | 通过事务提交 | canonical snapshot/patch |
| `canonicalHistory` | 低/持久 | 是/降级可审计 | 是 | 是 | 是，唯一 writer | durable timeline |

注意：`providerRefresh` 是“怎么读”，`canonicalHistory` 是“读到并提交后的权威事实”。两者不能合并成一个没有状态边界的万能来源。

## 8. 推荐的合并和去重规则

### 9.1 来源优先级不是简单覆盖优先级

显示投影应采用：

```text
canonicalHistory
  + 当前 generation 且当前 active turn 匹配的 runtime overlay
  + sharedObserver/externalObserver 的已标注观察 overlay
```

overlay 只能补足 canonical 尚未提交的当前过程，不能改变 canonical 的顺序。来源优先级不能靠“最后到达者覆盖先到达者”。

### 9.2 去重 key

优先级：

1. `provider itemId`；
2. `(threadId, turnId, item ordinal)`；
3. provider 给出的 revision/offset；
4. 只有在没有上述信息时才使用受限的 source-local identity，并标记 degraded。

禁止把“相同正文 + 相近时间”作为跨来源稳定 ID。相同正文可能是用户重复提问、不同轮次的工具输出或 `event_msg` 与 `response_item` 两种记录。

### 9.3 迟到和旧 generation

拒绝条件：

- connection generation 旧；
- source epoch 旧；
- authority generation 旧；
- turn 已结束且 canonical 已覆盖；
- base revision 与当前 staging 不匹配；
- overlay ID 已见且 payload 没有更高 sequence。

拒绝时保留诊断 evidence，但不插入第二条 canonical entry。发现重复 canonical stable key 时 fail closed：保留上一个有效事实，写入 duplicate diagnostic，触发 scoped repair，而不是把重复内容继续传播。

## 9. 各来源失效时的原始数据行为

| 失效 | 必须保留 | 可以更新 | 禁止行为 |
|---|---|---|---|
| runtime 断流 | canonical 历史 | overlay stale/运行状态 unknown | 清空历史、自动重发旧 pending |
| sharedObserver 断开 | canonical 历史 | observer unavailable、请求 refresh | unknown 静默变 idle/Ready |
| externalObserver 延迟 | canonical 和已确认状态 | observedAt、refresh trigger | 用尾部事件改写最终顺序 |
| providerRefresh 失败 | 上一次 canonical snapshot | retry/gap/degraded | 用空响应覆盖缓存 |
| canonical commit 冲突 | 旧有效 revision | scoped reset/gap | 新旧窗口拼接、全会话膨胀 |
| raw commit 失败 | 上一次有效 canonical snapshot | retry/gap/degraded | 用半提交结果冒充 canonical |

## 10. 重设计必须删除/禁止的隐式路径

以下行为不能再作为“兼容补丁”保留：

- runtime assistant completion 直接写 durable timeline；
- sharedObserver 和 externalObserver 各自创建一份 canonical assistant；
- 用文本、时间戳或展示顺序弱匹配不同来源的 item；
- revision 变化时对整个 `state.entries` 反复编织 provisional 副本；
- providerRefresh 空页清空原始数据库/状态；
- 未经 `codexSourceId + providerThreadId + authorityGeneration` 确认就允许设置/停止/发送。

## 11. 重设计原始数据验收矩阵

至少要在真实 Bridge、真实协议、真实 provider 数据和 canonical commit 上覆盖：

1. runtime delta 先到，canonical 后提交；
2. canonical 先到，迟到 runtime 被删除；
3. sharedObserver 与 externalObserver 同时报同一 provider item；
4. `event_msg` 与 `response_item` 同时存在；
5. 旧 generation/旧 turn 的迟到消息；
6. providerRefresh 空页、分页 cursor、base revision mismatch；
7. 700–1000 条 canonical 窗口和长流；
8. Bridge 重连、observer generation 变化和迟到原始事件；
9. canonical commit 失败、部分页、空页和 cursor 回退；
10. fork/subsession/子 Agent 的 parent-child identity；
11. 最终回复与中间过程同文本、同时间、不同 itemId；
12. rollout/JSONL 与结构化 provider 读取之间的顺序和 ID 对照。

每个场景的 expected 必须由 provider 顺序、原始 offset/revision 和人工冻结的事实样本定义，不能由待测 merge/reducer 自己生成 expected，避免自证循环。

## 12. 事实包中的原始证据索引

以下路径对应当前事实包中的证据类别（路径以包根为准）：

- `03_SOURCE_AND_GIT/repository/packages/bridge/src/local-features/conversation-sync-v2.ts`：四个 `projectionSource`、reader seam、runtime/shared/external/providerRefresh 实现；
- `04_DATABASES/`：Bridge/provider/SQLite 原始 schema、元数据和抽样行；
- `05_REAL_CONVERSATIONS/CASE-001..CASE-013/`：真实 rollout、短/长/分叉/子 Agent/流式/idle-gap 样本；
- `06_PROTOCOL_CAPTURES/appserver/`：app-server 协议捕获；
- `06_PROTOCOL_CAPTURES/generated-json-schema/`、`generated-ts/`：当前 CLI 生成的协议资料；
- `09_END_TO_END_REPLAY/real-stream-capture-20260818/`：真实传输 lifecycle/error；
- `09_END_TO_END_REPLAY/real-stream-capture-local-xhigh-20260818/`：认证的本地 xhigh stream；
- `09_END_TO_END_REPLAY/real-stream-capture-stdio-idle-gap-20260818/`：stdio idle-gap 事实；
- `09_END_TO_END_REPLAY/real-stream-capture-unix-daemon-20260818/`：Unix daemon WebSocket 事实；

## 13. 最终设计决策（可直接作为新方案的边界）

```text
四个 producer：runtime / sharedObserver / externalObserver / providerRefresh
一个 authority：canonicalHistory
一个 canonical writer：providerRefresh 结果的原子提交
一个原始事实面：canonical + 当前 generation 的 bounded overlays
```

如果未来要增加新来源，必须先回答四个问题：

1. 它观察的是运行时、外部落盘，还是结构化 provider 历史？
2. 它有没有 provider 稳定 ID 和明确 generation？
3. 它输出的是 overlay、状态证据，还是 canonical snapshot？
4. 谁拥有写入权、如何在 canonical commit 后删除其 overlay？

回答不清楚时，默认只能进入 evidence/observed 层，不能成为第五个以上的 canonical writer。
