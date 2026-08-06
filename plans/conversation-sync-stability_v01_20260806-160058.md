# CC Pocket 会话同步链路稳定性实施方案 v01

> 状态：**active / investigation-first / implementation-required**
>
> 创建时间：2026-08-06 16:00:58 +0800
>
> 工作树：`/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/conversation-sync-stability-20260806`
>
> 分支：`fix/conversation-sync-stability-20260806`
>
> 起始基线：`98d48eccddd6e52ef4733c27e11a8ee5fe493ac3`
>
> 生产观察基线：Bridge `1.69.6-compat.19-98d48ecc`；源码、部署、Mobile/IPA、
> OTA、物理设备验收继续是独立门禁。

## 1. 本轮目标和优先级

本轮先把会话链路做稳，再谈结构美化、抽象统一或局部性能微调。代码是否“漂亮”不是
验收标准，用户能否稳定打开、加载、重试、接收实时消息、持久保存并继续操作才是。

必须解决的用户可感知问题包括但不限于：

- 打开已有会话时落到一条旧历史消息，而不是当前最新位置；
- 最新消息曾经出现，但缓存仍停在旧时间点，退出重进后又显示旧内容；
- 运行中的会话会在增量更新、runtime 重挂接或目录刷新时跳回旧内容；
- 会话加载、最新轮修复、历史分页和错误卡片上的“重试”入口看似可点击，实际只转圈，
  没有形成可观察的请求、结果、失败或恢复闭环；
- 加载动作长期停留在模糊 spinner，没有真实进度、超时原因和可恢复状态；
- 超长 Codex 会话在官方分页能力不完整或读取超时时无法及时得到最新轮；
- Bridge 托管、共享 daemon/Codex Desktop 托管、detached durable 页面、旧 Bridge
  回退路径表现不一致。

本方案是实施约束，不是用文档替代修改。具体代码位置、协议字段和内部类型必须在实施前
重新探索；若源码事实与本文假设不同，应记录证据并采用更直接、更可靠的等价实现，不能
借“具体分析”删除稳定性目标。

## 2. 当前已知事实和仍需验证的假设

### 2.1 已确认事实

- 当前生产 Bridge 源码和本分支基线同为 `98d48ecc…`，运行时为
  `1.69.6-compat.19-98d48ecc`；开工时 `/health`、`/readyz`、共享 daemon、
  Action Broker 和 writer lease 正常。
- 当前复现线程 `019fa630-e195-7eb1-a856-9b6e95e6e494` 的 rollout 约
  388,814,504 bytes、114,553 行，并仍在增长。
- Bridge 日志在该线程上出现：
  - `thread/items/list is not supported yet`；
  - `thread/turns/list timed out after 15000ms`；
  - Mirror watch 关闭或轮询失败。
- Mobile 的 `useScrollTracking` 会按 `sessionId` 保存并恢复原始像素 offset；重新
  打开页面时可能主动回到上一次历史位置，且新内容插入后同一像素不再代表同一消息。
- durable 页面每次 SQLite hot-window 更新都会重新读取快照，并通过
  `HistoryMessage` 注入现有 `ChatSessionCubit`。
- v2 patch 有 `baseRevision` 门禁，但 v2 snapshot 会替换 hot window；当前数据库层
  没有一个可比较的 per-thread content sequence 来证明 snapshot 比已提交内容更新。
- durable runtime handle 暂时消失时，Mobile 会撤销 attachment 并重置流式状态；
  mutation authority 与可见实时内容连续性仍耦合得过紧。

### 2.2 尚未证明、必须由调查补齐

- 真机故障当次究竟是哪一个 operation/requestId 进入 loading，又在哪里停止；
- `conversation_sync_v2` 最新轮读取是否与 legacy Mirror 同时超时，还是成功结果在
  Bridge → Mobile → SQLite 的后半段被丢弃；
- 运行中跳回旧内容时是否同时发生 runtime session-list 短暂缺项、subscription
  generation 切换、snapshot replacement 或仅仅是旧 scroll offset 恢复；
- 哪些“重试”按钮没有发请求，哪些发了请求但被 generation/identity 门禁拒绝，哪些
  请求成功却没有将结果投影回 UI；
- Bridge 直接观察到的 stable live items 是否在 history read 失败时仍能形成可持久化
  的增量，还是只存在于进程内临时 buffer；
- 相同故障在 Bridge-owned turn、Desktop/shared-daemon turn、idle durable thread、
  Claude 和旧 Bridge fallback 上的差异。

调查报告必须把“日志直接证明”“源码静态风险”“可复现确认”和“仍未知”分开。

## 3. 不可破坏的产品与数据约束

1. Provider/app-server/Claude 原始历史仍是权威数据；Mobile SQLite 是可重建副本，
   不得反写、裁剪或修复 Mac 端 canonical history。
2. 所有 durable conversation 都能从本地副本直接打开；读取不依赖 `resume`、激活或
   writer ownership。
3. 新消息一旦被当前 Mobile 权威接受，就必须在有界时间内进入同一 source partition
   的 SQLite hot window。旧缓存只能补历史缺口，不能覆盖 live/current 内容。
4. 视觉连续性与 mutation authority 分离。authority 未确认时写操作 fail closed，
   但已经显示的权威消息、当前流式文本和用户阅读位置不能因此被清空或倒退。
5. 一个 operation 只能有一个 owner、requestId、generation、deadline 和终态。
   spinner 不是状态；按钮点击必须产生真实请求或立即说明为什么不能请求。
6. retry 必须重试失败的同一业务目标，而不是只重建 Widget、重复订阅全部会话或清空
   整个缓存。重复点击需幂等或明确合并。
7. 迟到 generation、旧 source fingerprint、旧 authority generation、旧 page 和旧
   snapshot 不能覆盖新状态。显示时间戳不能替代协议顺序。
8. 同一 Bridge 的不同 IP 继续共享 `(bridgeInstanceId, codexSourceId)` 缓存；不同
   source 继续隔离。
9. 新协议保持 additive/capability-gated；新 Mobile + 旧 Bridge、旧 Mobile + 新
   Bridge、private/daemon、Codex/Claude 都要有明确降级，不得为修当前设备破坏兼容。
10. 不用高频轮询、整份 JSONL 重读、全量内存 snapshot、无限重试或隐藏错误换取表面
    成功。

## 4. 调查范围：必须从入口走到真实终态

调查不能只围绕预设文件。Luna Max 应开放式扫描仓库、测试和运行证据，再按以下链路
建立业务操作台账：

```text
用户点击/页面生命周期
  → Mobile UI operation
  → Cubit/Service request + generation
  → WebSocket frame
  → Bridge parser/router/scheduler
  → app-server/Claude/legacy reader
  → Bridge normalized revision/live event
  → WebSocket ACK/backpressure
  → Mobile staging/SQLite transaction
  → repository/cache update
  → Cubit live-overlay reconciliation
  → list/render/scroll anchor/loading/error presentation
```

每一种已发现的加载或重试入口至少记录：

| 字段 | 必须回答的问题 |
|---|---|
| 用户入口 | 哪个页面、按钮、自动触发或生命周期触发 |
| 业务目标 | 打开、最新轮修复、早期历史、工具详情、runtime attach、状态、设置等 |
| owner | 哪个类/服务唯一拥有操作 |
| identity | Bridge/source/provider/thread/turn/item 如何绑定 |
| request | requestId、generation、cursor/baseRevision、deadline 是否存在 |
| transport | 实际发送什么 frame，旧 Bridge 如何降级 |
| backend | Bridge 是否收到、是否真正调用 provider、是否并发重复 |
| commit | 哪个 SQLite 事务完成后才算成功，ACK 何时发送 |
| projection | 哪个 reducer/Cubit 消费成功或失败 |
| UI terminal state | 成功、可重试失败、不可重试失败、取消分别显示什么 |
| observability | 日志能否关联同一次操作且不包含正文、路径、key/token |
| tests | 当前测试是否只验证 spinner/按钮，还是验证了真实闭环 |

已知入口只是最低集合，不能限制调查：会话初开、最新轮 gap、早期 turn 分页、items/tool
详情、Mirror 错误卡、runtime attach、连接/重连恢复、设置 hydration、Goal/usage 等凡是会
阻断会话可用性的加载或重试都要登记。

## 5. 目标实现原则

### 5.1 优先修业务闭环，不为抽象而抽象

- 优先复用并修正现有 `ConversationContentSyncService`、SQLite repository、
  `ChatSessionCubit` 和 Bridge v2 scheduler。
- 如果已有两套竞争 owner，优先删除或停用错误路径；不要再叠第三套 adapter、全局
  coordinator 或 feature flag。
- 只有现有协议无法表达“新旧顺序”时才增加最小 additive 字段或事件；增加前必须证明
  单靠现有 revision/generation 无法安全判断。
- 不做与稳定性无关的格式化、目录搬迁、命名重构和大面积 Widget 重写。

### 5.2 缓存必须单调前进

目标语义：

```text
durableBase(SQLite committed)
  + liveOverlay(current source/generation)
  + optimisticLocal(user input only)
  → visible timeline
```

- live stable item 到达后先进入有界 overlay，并尽快事务性 upsert 到 hot window；
- SQLite commit 成功后才能 ACK/发布 cache revision；
- cache snapshot 只能升级 durable base，不能直接清空 live overlay；
- cache 中已包含同一 stable item 后，把该 item 从 overlay 原子“晋升”到 base；
- history page 只补早期 prefix 或明确 gap，不得替换更新的 current tail；
- snapshot/patch 必须有可验证的 lineage。若 hash revision 不可比较，就引入最小的
  per-thread content epoch/sequence 或同等机制；不能拿 `cachedAt` 和显示时间猜顺序；
- scoped reset 只清对应 source/thread 的可重建窗口，并保留 read watermark、草稿、
  未发送队列和当前已确认 live overlay，直到替代快照真正提交。

### 5.3 超长会话必须有最新轮快路径

- focused/working/Need You 会话优先读取最新 1 轮，再读取最近 5 轮；不要让最近五轮
  失败阻塞最新一轮。
- 官方 `thread/items/list` 缺失时使用受支持的 `thread/turns/list`，但真实 300–400 MB
  rollout 超时必须有有界兜底。
- 兜底可以基于已存在的 rollout index、稳定文件身份和尾部增量读取；不得退化为每次
  `thread/read(includeTurns:true)` 或整文件解析。
- Bridge 已直接观察到的 user/assistant/tool/result stable items 不应因为 canonical
  history 暂时超时而消失。它们可以先作为 source-scoped live overlay 发送，随后由
  provider 读取校准；校准失败不能把 overlay 当成已完成的全历史 snapshot。
- provider rewrite、compaction、文件替换和 Bridge 重启都要有明确 reset/重建语义。

### 5.4 retry 和 loading 必须是真状态机

不要求为了形式新建一个“大而全状态机”类，但每个业务 operation 必须具备等价事实：

```text
idle
  → queued/sent
  → backendStarted
  → pageReceived/committing
  → success
  | retryableFailure(reason, retryAfter)
  | terminalFailure(reason)
  | cancelled
```

- 进度来自真实阶段，不使用固定延时或永动 spinner 冒充；
- 有进展时延长 inactivity deadline；没有进展才超时；
- retry 复用同一业务 target，创建新的 operation generation，并让旧结果失效；
- provider 不支持、认证失败、source 不匹配、超大单项、数据库失败和普通网络超时是不同
  错误，UI 给出不同恢复动作；
- 重试成功后必须清除旧错误、停止旧 timer、关闭 spinner 并显示已提交内容；
- 页面 dispose、切换 thread、切换 source 和 App 后台化要取消或降级 operation，不能让
  迟到回调重新点亮旧页面。

### 5.5 runtime 绑定只控制操作权限

- 一次 `session_list` 暂时缺少 runtime handle 时，立即撤销当前 mutation 权限是安全的；
  但不得清空 durable timeline、live overlay、流式文本或阅读锚点。
- 只有 source/connection generation 变化、明确 runtime replacement/end 或权威状态证明
  当前 turn 已结束时，才结束对应 live overlay generation。
- shared daemon/Codex Desktop 与 Bridge-owned runtime 使用同一 durable timeline，
  但 mutation 仍要求精确 authority generation；不能用“共享”绕过写入门禁。

### 5.6 打开与滚动位置语义

- 有新消息、未读、working/compacting/Need You 或缓存 revision 已前进时，重新打开默认
  显示最新内容，不恢复旧像素 offset。
- 没有任何新内容、用户只是临时切页时，可以恢复稳定 message anchor + intra-item
  offset；不能保存裸像素并跨 revision 复用。
- 实时增量和 cache promotion 使用 stable message/turn identity 保持当前可见锚点；
  不允许因为列表 index 改变跳到另一条历史消息。
- 用户主动停在旧内容阅读时不强制滚到底；显示“有新消息/回到底部”即可。

## 6. 实施阶段和提交边界

### Stage 0：Luna Max 全链路只读调查

- 不修改源码、配置、数据库、运行时和手机；
- 自主探索真实调用链，不被固定文件清单限制；
- 使用当前 Bridge 日志、必要的只读 SQLite/rollout 元数据和测试源码；
- 输出逐项 operation 台账、根因、复现、证据、风险级别和建议修复切片；
- 明确哪些结论需要 Mobile 诊断日志或真机再次触发。

### Stage 1：主线程复审与最小修复切片

主线程逐条复核 Luna 报告：

- 用源码和运行证据确认 owning layer；
- 驳回只改 spinner、吞错误、增加无用 abstraction 或扩大轮询的建议；
- 确定第一批可独立验证、可回滚的实质修复；
- 需要新增协议时先固定兼容矩阵和 migration/reset 语义。

### Stage 2：让重试和加载真正闭环

优先修会话初开、最新轮 gap、早期历史和 tool/items 详情的真实 request/commit/error
路径。一个提交只覆盖同一业务闭环，不混入缓存架构或视觉重构。

### Stage 3：修复缓存单调性和 live 持久化

在 Bridge revision、v2 wire、Mobile staging/SQLite 和 Cubit overlay 之间建立端到端
单调门禁。新消息持久化、旧 snapshot 拒绝、scoped reset 和重连恢复必须成套验证。

### Stage 4：修复超长会话与 runtime/scroll 连续性

加入最新轮有界快路或经证明需要的索引/尾读兜底；解耦视觉内容与 mutation attachment；
按 stable anchor 修正重新打开和运行中跳动。

### Stage 5：兼容、性能与完整审计

- Bridge 定向与全量测试、TypeScript/native helper build；
- Mobile 定向与全量测试、analyze；
- 真实大 rollout 的冷开、热开、增量、断线重连和 retry 基准；
- SQLite query plan、事务、DB 增长和内存峰值；
- WebSocket frame/ACK/backpressure、provider read 并发和事件循环延迟；
- 新旧 Mobile/Bridge、private/daemon、Codex/Claude、多设备和后台恢复矩阵；
- iOS Simulator build 与 RunnerTests；物理 iPhone 行为仍由用户验收。

建议按行为拆分提交：

1. `诊断：贯通会话加载与重试操作日志`
2. `修复：让会话加载与分页重试形成真实闭环`
3. `协议：增加会话内容单调提交门禁`（仅在调查证明需要时）
4. `修复：持久化实时增量并拒绝旧缓存回退`
5. `Bridge：为超长会话增加最新轮有界快路`
6. `移动端：分离 durable base 与 live overlay`
7. `移动端：按新内容和稳定锚点恢复阅读位置`
8. `测试：覆盖断线、重连、超时、重试和缓存回退`
9. `审计：记录兼容、性能和设备门禁`

实际调查若证明更少提交即可安全完成，应减少提交和新机制；不得为了符合清单制造空层。

## 7. 必须新增或补强的验证场景

### 7.1 retry/load 端到端

- 点击每个 retry 后断言：新 requestId 发出、Bridge 收到、provider operation 开始、
  SQLite commit、UI 终态；不能只断言 spinner 出现。
- provider 超时一次后 retry 成功；第一次迟到结果不能覆盖第二次成功。
- source 切换、页面关闭和重连期间 retry 不串 thread。
- unsupported、wrong source、auth、timeout、DB failure、oversized item 分别得到正确错误。

### 7.2 缓存与实时消息

- live item 已显示后注入旧 snapshot，timeline 不倒退；
- SQLite commit 后销毁页面/进程再打开，仍能看到该 item；
- Bridge 重启丢失内存 snapshot 后，Mobile 已知 revision 不被旧 provider 窗口覆盖；
- snapshot 与 live item 同 ID 时只保留一份且提升为 durable；
- runtime handle 暂时缺失只撤销 mutation，不清消息或 streaming；
- provider compaction/rewrite 只触发有界 scoped reset。

### 7.3 长会话

- 使用至少一个接近当前 389 MB/11 万行结构的合成或脱敏夹具；
- 最新一轮读取不依赖完整历史解析；
- 最近五轮失败时，已观察 live current turn 仍可显示并落盘；
- 读取超时有明确失败与 retry，不无限旋转；
- 同时多个近期会话时 provider history 并发仍有界。

### 7.4 滚动与页面连续性

- 退出时在旧消息处、期间有新消息：重开显示最新并提供返回阅读位置的能力；
- 没有新消息的短暂切页：稳定 anchor 可恢复；
- 当前运行中 cache promotion、history prepend、tool detail 展开不会跳到另一消息；
- 用户主动向上阅读时，新增流式内容不抢滚动。

## 8. 性能目标

这些是初始目标，真实基准可调整，但有界和事件驱动原则不能删除：

- 已有可用缓存的会话打开至首帧：p95 小于 100 ms；
- Bridge 已观察到 stable live item 后，正常前台链路 Mobile SQLite 提交：目标 p95
  小于 1 s；
- focused 超长会话最新轮快路：正常本机目标小于 2 s；超过 5 s 必须进入明确的
  progress/error/retry 状态，不能只转圈；
- 100 个未变化近期会话：零正文读取；
- 无变化重连：不重发历史窗口；
- 单帧不超过既有 64 KiB，未 ACK 队列保持既有上限；
- Mobile 内存不随历史总页数线性增长；
- 不新增逐会话 WebSocket、全局高频 timer 或每 delta SQLite transaction；稳定增量
  允许 16–50 ms 有界合并后单事务提交。

## 9. 诊断日志要求

为解决“偶发、重进恢复、运行中回退”，需要一条可关联但不泄露正文的 operation trace：

- `operationId/requestId`、connection/source/runtime generation；
- provider + 脱敏 thread token；
- operation kind、cursor/base revision/content sequence；
- Bridge read source、开始/结束/耗时/条数/超时类别；
- frame sequence、ACK、SQLite transaction commit；
- cache revision、live-overlay count、UI applied revision；
- retry attempt、deadline 延长原因和终态。

禁止记录 API key、URL 中凭据、完整路径、标题、消息正文、工具结果和原始 payload。
日志必须有界并能关闭；正式稳定后保留低成本状态转移和错误摘要，删除逐帧调试噪声。

## 10. 完成标准

本轮不能以“代码已改”“测试通过一个文件”“按钮会转圈”结束。完成必须同时满足：

1. Luna Max 调查结果经主线程源码复审，所有高优先级结论有证据；
2. 所有已发现会话加载/重试入口都有真实闭环台账；
3. 新消息及时持久化，旧 snapshot/cache 无法覆盖更新内容；
4. 会话运行、重连、runtime 重挂接期间不跳回旧消息；
5. 当前约 389 MB 的真实长会话和有界测试夹具通过；
6. retry 成功、失败、超时、取消、迟到结果和 source 切换都有自动回归；
7. 全量功能、兼容和性能审计无 P0/P1，P2 有明确处置；
8. 源码提交可回滚、工作树干净、没有无关重构或构建产物；
9. Bridge 部署、Mobile OTA/IPA 和真机验收仍按独立授权执行，不能由源码完成自动推导。

未经用户后续明确授权，本调查和源码修复阶段不联系固定发布会话，不部署 Bridge，不发布
OTA/stable，不安装物理设备，也绝不联系已禁止的历史任务
`019f8ff9-0945-72a3-a29e-c17df6f112e5`。
