# 统一领域、生命周期与全链数据流

状态：`ROOT_DECISION / DESIGN_ONLY / REGISTRY_BINDING_PENDING`

本文把 Phase 1 Kernel 与 Phase 2 产品能力放进同一套执行模型。它解释数据为什么这样流动、状态由谁拥有，以及失败后如何恢复；字段、枚举、消息和数据库约束的机器权威仍是 `contracts/`。最终验证必须证明本文引用的每个跨边界术语都能在唯一 registry、Schema 或 DDL 中解析，不能让本文成为第二份可自由漂移的协议。

## 1. 不变量

1. Codex Provider durable history 是历史事实权威；CC Pocket 只能保存经证据验证的 projection。
2. `CanonicalTimelineWriter` 是 Bridge canonical timeline 唯一 writer；`ReplicaApplyCoordinator` 是 Mobile rebuildable replica 唯一 writer。
3. live observation 只存在于内存 overlay；它不能直接变成 durable history，也没有 stream checkpoint。
4. `OperationKernel` 独占 admission、queue、dispatch barrier、terminal 和 reconcile；任何产品模块都不能直接调用 Provider mutation。
5. `InteractionBroker` 独占 claim lease；响应的 actor 只来自 authenticated connection context。
6. 数据身份不使用 IP、route、路径、标题、正文、时间戳、到达顺序、rowid 或 generation。
7. cache 复用不创造 authority；内容不完整时可以显示已证明的片段，但片段内部和片段之间的顺序都必须有 proof。
8. 任何 Provider call 已经开始但结果无法证明时，operation 进入不可重新 dispatch 的 `OUTCOME_UNKNOWN`。
9. control/live plane 使用 UTF-8 JSON，单 envelope 上限 64 KiB；大内容走 HTTP content plane，以 digest、ETag、Range 和短期 ticket 校验。
10. V2、Mirror writer、legacy runtime、旧数据库迁移和双写不进入新运行时；Claude 只有不可达的 typed `NOT_IMPLEMENTED` seam。

## 2. 身份、定位和 fence

### 2.1 身份层级

| 名称 | 语义 | 唯一 owner | 是否持久 | 明确不是 |
|---|---|---|---:|---|
| `ComputerRef` | Mobile 侧对一台已验证电脑的产品分组 | Connectivity/Device repository | 是 | IP、单条 route、canonical 数据分区 |
| `BridgeIdentityRef` | Bridge 签名公钥身份及其验证状态 | `BridgeIdentityStore` | 是 | Bridge state installation ID |
| `BridgeInstanceRef` | 一份 Bridge 私有 state installation 的随机稳定 ID | `BridgeInstallationStore` | 是 | `BridgeIdentityRef`、端口、进程 PID |
| `RouteRef` | LAN/Tailscale/DNS/manual/SSH 等一条连接通道 | Connectivity repository | 是 | source、actor、电脑身份 |
| `CodexSourceRef` | 由 `SourceRegistry` 为一个 Codex data source 生成的稳定 ID | `SourceRegistry` | 是 | `CODEX_HOME` 路径、providerKind |
| `SourcePartition` | `(bridgeIdentityId, bridgeInstanceId, codexSourceId)` | Registry + generated types | 是 | 二元简写、全局 provider thread namespace |
| `ThreadRef` | `SourcePartition + providerThreadId` | `ConversationCatalog` | 是 | 标题/目录/最近打开时间 |
| `TurnRef` | `ThreadRef + providerTurnId` | `CanonicalTimeline` | 是 | turn 序号或时间 |
| `ItemRef` | `TurnRef + providerItemId` | `CanonicalTimeline` | 是 | body digest、列表 index |
| `OperationRef` | `SourcePartition + operationId`，并绑定 exact typed target | `OperationKernel` | 是 | clientMessageId 的别名 |
| `InteractionRef` | `SourcePartition + thread/turn/request/variant` | `InteractionBroker` | 是/按 variant | notification action ID |
| `ContentRef` | content-addressed digest、size、media type 与安全分类 | `ContentStore` | 引用持久 | 路径或下载 ticket |

`providerKind` 在当前产品中是编译期常量 `codex`。它可以出现在诊断 provenance，但不得进入身份键、wire union、DDL discriminator 或 Mobile route。未来 Claude 若实现，必须通过新 ADR 证明是否需要扩展 identity，而不是提前把 provider-neutral 字段铺满全系统。

### 2.2 actor 与 authority

`AuthenticatedExecutionContext` 由 Bridge transport 在认证成功后生成，至少绑定：

- authenticated principal；
- assurance/mode 与 revocation epoch；
- connection epoch；
- verified `BridgeIdentityRef`、`BridgeInstanceRef`、`CodexSourceRef`；
- 当前 capability snapshot digest；
- request deadline 与 trace ID。

业务 payload 不包含可自报的 actor、role、Face ID 结果、route trust 或 source authority。HTTP content ticket、notification action、native callback 和 WebSocket operation 都必须重新绑定或验证上述上下文；客户端传来的同名字段一律拒绝。

### 2.3 fence 不等于身份

| Fence | 防止的问题 | 失效后动作 |
|---|---|---|
| connection epoch | 旧 socket callback 写入新连接 | 丢弃 callback，必要时触发只读 repair |
| source generation | source switch 后旧任务回流 | 取消旧 importer/observer，不复用 checkpoint |
| provider runtime epoch | 旧 runtime event 混入新进程 | 只丢 live；canonical 等 durable read |
| host/lifecycle epoch | native plugin late/duplicate callback | fail stale；不关闭更新请求 |
| stream revision/checkpoint | Mobile ACK 越过未提交数据 | 拒绝 ACK 或发送 typed gap/snapshot repair |
| queue lane/entry revision | edit/cancel 与 dispatch race | CAS conflict，不在新 revision 重放 |
| interaction lease revision | 多设备重复响应 | stale claim/response fail closed |

## 3. 读、缓存、顺序与 canonical commit

### 3.1 读取理由

Provider 读取必须由 typed `ReadIntent` 触发，例如 catalog discovery、focused thread materialization、gap repair、operation reconcile 或 explicit refresh。页面 reopen、Widget rebuild、route 切换本身都不是 Provider read 理由。

读取顺序固定为：

```text
Mobile committed replica
  -> Bridge verified canonical/cache
  -> bounded Provider read
```

前一层已经满足请求的 coverage 和 freshness 时，后一层不调用。缓存 miss 只能触发已登记的 bounded read，不能退化成完整会话无界加载。

### 3.2 Provider read 进入 canonical 的唯一通路

```text
ReadIntent + authenticated source fence
  -> ProviderHistoryReader (bounded request)
  -> immutable RawReadEvidence
  -> Codex adapter normalization
  -> CandidateTurnSpine + bodies + coverage/order proofs
  -> CandidateVerifier
  -> CanonicalTimelineWriter transaction
  -> PostCommitEvent
```

`RawReadEvidence` 保存请求、Provider build/capability digest、响应 digest、边界和错误 provenance，不允许调用方直接抽取部分字段写 timeline。Candidate 必须同时通过：

- source/thread/turn/item 强身份一致；
- required item 与 body digest 一致；
- coverage claim 可由读取边界证明；
- order proof 形成无矛盾的局部有序链；
- capacity、UTF-8、Schema 与安全分类；
- CAS base revision 仍是读取开始时的 last-good head。

任何一项失败都保留旧 canonical。`EMPTY` 只有在请求覆盖整个被声明范围且 Provider 明确证明 empty 时才可替换；timeout、partial、unknown、decode error 或 stale generation 永远不能把 last-good 清空。

### 3.3 cache island 与显示顺序

缓存单元按强身份和 proof 形成 `CacheIsland`。一个 island 可以不完整，但必须满足：

1. island 内每个相邻 turn/item 都存在 Provider order、cursor boundary、adjacency 或 canonical predecessor proof；
2. 两个 island 只有在存在 bridge proof 时才能拼接；
3. 缺少 bridge proof 时保留 typed `Gap`，不能用时间戳、arrival、数组 index、正文相似或本地 rowid 猜位置；
4. `Gap` 是 coverage/load state，不是聊天 item，UI 用固定占位和可重试 action 表示；
5. eviction 删除可重建 body/cache，不改写 canonical identity、coverage head 或本地 draft；
6. pin、LRU、size budget 只影响物理保留，不改变显示顺序或 authority。

显示 reducer 只组合：

```text
committed canonical materialization
+ sender-local admitted/queued projection
+ focused, generation-fenced live overlay
```

三者使用显式 layer 和 stable anchors，不进行时间排序。来自相同强 `ItemRef` 的 live item 在 canonical commit 后原位晋升；无法证明相同强身份时，先移除 stale live，再由 canonical 显示，不能 fuzzy merge。

### 3.4 live overlay

合法 producer 只有 direct runtime observer、shared runtime observer 和 detached observer。每条 live observation 绑定 `SourcePartition + thread + runtimeEpoch + subscriptionId`；能关联时再带强 Turn/Item identity。

live 永不：

- 写 Bridge canonical/cache head；
- 写 Mobile durable replica；
- 推进 stream checkpoint；
- 在 reconnect 后 replay；
- 以 terminal delta 代替 Provider durable read。

terminal 或异常只触发 bounded repair intent。旧 epoch、source switch、disconnect、TTL 或 canonical promotion 会清理 overlay。

## 4. Bridge 到 Mobile 的 durable sync

每次 canonical/operation/interaction/thread-state/relation commit 生成一个 owner-scoped `PostCommitEvent`。`SyncProjection` 把它投影成 capability-bound durable envelope；同一 source/thread 同一逻辑 owner 只有一条 active projection stream。

Mobile 应用顺序固定为：

```text
receive bytes
  -> envelope/schema/capability/source validation
  -> durable inbox insert (dedupe)
  -> staging decode and cross-record checks
  -> one SQLite transaction apply
  -> readback invariant check
  -> persisted checkpoint advance
  -> Repository publish
  -> ACK exact committed checkpoint
```

任何 decode、FK、capacity、revision、source 或 readback 失败都不 ACK。Bridge 可以重发相同 envelope；同 ID/同 digest 必须幂等，同 ID/不同 digest 必须 typed conflict。unknown message kind 不写局部实体：若 capability 声明 optional，可保留 bounded opaque envelope 并要求 snapshot repair；若 required，暂停该 feature stream，不使整个连接断线。

snapshot 只替换其 owner 声明的 namespace。它不能 cascade 删除 Mobile unique local state，例如 draft、read watermark、pin、route、credential、UI preference 或 offline intent。

## 5. 发送、队列、reconcile

### 5.1 三种不同的“待发送”

| 层 | owner | 能否离线存在 | 语义 |
|---|---|---:|---|
| Mobile local intent | `LocalIntentRepository` | 是 | 尚未被 Bridge 接受，恢复连接后默认需确认 |
| Bridge queue | `OperationKernel` | 否，需已到 Bridge | 已 durable admission、尚未开始 Provider call |
| sender-local outgoing projection | UI reducer | 短暂 | 只展示 admission/queue/dispatch 状态，不是 canonical history |

三者不能共用一个 boolean `pending`，也不能互相覆盖 writer。

### 5.2 typed admission

每种 mutation 有独立 typed body 和 `OperationHeader`：`operationId`、target、expected revisions、deadline、clientMessageId（如需要）与 capability binding。fingerprint 使用 RFC 8785 JCS 对“Schema 验证后的 typed 值”计算；用户字符串按原始 Unicode code points 保持，不做 NFC/NFKC 等规范化。

唯一性与幂等规则：

- 同 `OperationRef`、同 fingerprint：返回原 admission/state；
- 同 `OperationRef`、不同 fingerprint：`OPERATION_FINGERPRINT_CONFLICT`；
- 同 ID、不同 actor：`OPERATION_ACTOR_MISMATCH`；
- retry/resend 创建新的 operationId 和 clientMessageId，并用 `retryOfOperationId` 指向旧 operation；
- 禁止 generic command、任意 method name、untyped map mutation。

### 5.3 dispatch 状态机

```text
RECEIVED
  -> REJECTED
  -> ADMITTED -> QUEUED -> DISPATCH_OWNED -> CALL_STARTED
                                          -> PROVIDER_ACCEPTED
                                          -> CANONICAL_OBSERVED -> SUCCEEDED
                                          -> OUTCOME_UNKNOWN
                                          -> PROVIDER_REJECTED
                                          -> CANCELLED (only before dispatch ownership)
```

在 `CALL_STARTED` 前必须 durable commit admission、fingerprint、actor、target、payload refs、queue/lane revision 和 dispatch attempt。进入 `CALL_STARTED` 后发生 crash/disconnect/timeout，重启只能进行只读 reconcile；绝不自动再次调用 Provider。

`OUTCOME_UNKNOWN` 是不可变 dispatch terminal。后续 reconciliation 只能追加 `OBSERVED_ACCEPTED`、`OBSERVED_CANONICAL`、`OBSERVED_NOT_FOUND_WITH_BOUNDED_PROOF` 或 `STILL_UNKNOWN` observation；它不能删除/改写 terminal，也不能使原 operation 再 dispatch。存在会与未知结果冲突的 operation 时，同 thread 的后续 mutation 默认阻断，读取、resource fetch 和 reconcile 可继续；最终 UX 由 U-002 审核决定。

### 5.4 queue

每 thread 默认最多 16 个 Bridge queued entries。queue 有 lane revision，每 entry 有 entry revision。edit/cancel 必须同时 CAS exact lane/entry revision，且 entry 尚未被 dispatch owner 获取。允许 FIFO 和明确的 priority lane，但不提供任意 reorder；若未来新增 reorder，必须先成为独立 typed operation 和新状态机。

steer、stop、Interaction response、compact 和其他要求当前 runtime/authority 的操作不进入离线 outbox。Goal/settings 等 reconcile-only mutation 保留 operation ledger，但失败恢复通过 authoritative readback，不进行盲重放。

## 6. Interaction、Goal、Plan 与关系图

### 6.1 Interaction Broker

统一 variant：approval、question、MCP elicitation、ExitPlan。每个 open interaction 绑定 exact source/thread/turn/request/variant/authority fence。状态：

```text
OPEN -> CLAIMED_ACTIVE -> RESPONDED
  |          |             |
  |          -> RELEASED --+
  -> EXPIRED / WITHDRAWN / STALE
```

同一 interaction 最多一个 ACTIVE lease。claim、renew、release、respond 都必须 CAS lease revision；claim actor 来自 authenticated context。notification action 只能携带不含 secret body 的 action locator，唤醒后重新 fetch Broker 并 claim；未知 variant 或旧 native host 无法无损携带 actionId 时只 Open App。

Interaction Broker 只决定“谁可以响应、响应什么 exact request”；真正发送 Provider response 仍通过 `OperationKernel` typed dispatch，不产生第二份 operation ledger。

### 6.2 ThreadState

- Goal：Provider-backed authoritative aggregate，区分 missing、present、completed、cleared、unknown 和 budget/usage；response loss 后 readback reconcile。
- collaboration/effort/settings：完整 authoritative snapshot + revision/hash；unknown fields 可保存在 extensions/display，但 mutation 不盲目回写。
- Plan timeline item：由 `CanonicalTimeline` 投影。
- ExitPlan：由 `InteractionBroker` 管理。
- Mobile motion/fire slider：只把用户选择提交为 typed effort mutation；动画值不是 authority。

### 6.3 RelationGraph

persisted Side Chat、ordinary Fork、review child 和 subagent 都使用普通 child thread 加 typed relation edge；child timeline 仍由 `CanonicalTimeline` 管理，不复制 catalog/history/watch 协议。

- persisted Side Chat：同 operation/fingerprint 幂等返回同 child；durable relation。
- ephemeral Side Chat：connection/source generation scoped、memory-only，断开即清理。
- ordinary Fork：保留自己的 fork intent/ancestor locator，不冒充 Side Chat。
- subagent：relation + 普通 child conversation + bounded live status；不进入 primary catalog，支持分页/上限/cancel token。Provider 未证明 exact descendant cancellation 前，取消能力 disabled。

## 7. ProductPlatform 的 core-facing interfaces

Phase 2 不能重新定义 Kernel 语义，只能使用以下窄接口：

| Interface | 允许 | 禁止 |
|---|---|---|
| `AuthenticatedSourcePort` | 验证 Bridge/instance/source、生成 execution context | 信任 payload 自报 actor/source |
| `PostCommitProjectionPort` | 读取 canonical/operation/interaction 的 redacted committed event | 写 timeline 或 operation terminal |
| `TypedOperationContributionPort` | 注册已有 registry 中的 typed operation handler/policy | generic command、直接 Provider call |
| `InteractionActionPort` | re-fetch/claim/respond exact interaction | notification 直接 approve |
| `ContentStorePort` | digest manifest、offer/ticket/receipt、Range download、GC | 把文件路径当 wire identity |
| `NativeCapabilitySnapshotPort` | versioned snapshot、host epoch、method capability | 万能 method channel 或 untyped dynamic map |
| `LocalStateNamespacePort` | 声明独立 namespace、clear policy、size/retention | 删除 Kernel replica 或其他 feature 私有状态 |
| `SourceLifecyclePort` | start/stop/disconnect/source-switch deadline | 私自保活 canonical writer |

P-001–P-026 的绑定规则：

- P-001–P-004（电脑/routes/配对/readiness）提供 verified source context，但 route 不成为数据身份。
- P-005–P-013（文件/传输/ingress/mutation/preview/artifact/media/Git/capture）使用 ContentRef、typed authorization 与独立 content plane；只在用户把内容显式附加到 operation 时进入 Session Kernel。
- P-014（通知）只消费 post-commit/redacted projection，interaction action 必须回 Broker。
- P-015（后台）只能推进有界 transport/repair，不取得 canonical writer。
- P-016（权限）管理 platform fact 与 request lifecycle，不冒充业务 authority。
- P-017（更新）把 availability、download/install、发布/验收状态分开，不门控核心数据正确性。
- P-018–P-023（voice/icon/supporter/shell/routes/localization）默认 `NO_CORE_CHANGE`；voice 只产生 draft input，P-022 必须保持 zero reachable Claude。
- P-024（native host）属于 ProductPlatform/Mobile shared host，不属于 Session Kernel。
- P-025（effort visual）只有 authoritative effort 设置经 ThreadState mutation；其余 motion/status/insights 只读。
- P-026（cache management）按 namespace registry 清理可重建数据，不以一个全局 clear 删除 local unique state。

## 8. 存储边界

### 8.1 Bridge Kernel logical namespaces

- source registry 与 installation metadata；
- provider read evidence/candidate staging；
- canonical turn/item/body ref/coverage/order/last-good；
- operation/event/dispatch/queue lane；
- interaction/claim lease；
- thread state/settings/Goal；
- relation；
- capability/cutover/checkpoint；
- bounded diagnostics。

业务模块不得直接 SQL。最终实施由一个 storage worker/connection owner 串行化 schema install、migration 和 transaction；是否物理拆文件只由性能/生命周期实验决定，不能从 logical namespace 数量推导。

### 8.2 Mobile

`conversation_replica_v4` 保存可由 Bridge 重建的 canonical、operation、interaction、thread-state、relation、capability 和 durable inbox/checkpoint。`conversation_local_state` 保存 draft、local intent、read watermark、pin、UI preference、route/computer display order 等 Mobile unique state。native/plugin、transfer、gallery 等 feature 可拥有独立 namespace，但必须登记 clear/retention/backup policy。

旧数据库默认不打开、不导入、不修改、不删除。若用户未来要求一次性保留部分数据，必须由进程外、只读、可审计 importer 输出到 staging；新 Kernel 不保留 runtime adapter 或 legacy fallback。

## 9. Error、unknown 与 capability 规则

所有跨边界失败使用 typed union，至少覆盖：

- `UNSUPPORTED_CAPABILITY` / `UNSUPPORTED_MESSAGE`；
- `INVALID_TARGET` / `SOURCE_FENCE_MISMATCH` / `STALE_REVISION`；
- `AUTHENTICATION_REQUIRED` / `AUTHORITY_DENIED` / `ACTOR_MISMATCH`；
- `CAPACITY_EXCEEDED` / `PAYLOAD_TOO_LARGE` / `CONTENT_INTEGRITY_FAILED`；
- `CONFLICT` / `FINGERPRINT_CONFLICT` / `LEASE_CONFLICT`；
- `PROVIDER_UNAVAILABLE` / `PROVIDER_REJECTED` / `PROVIDER_SHAPE_UNKNOWN`；
- `OUTCOME_UNKNOWN` / `RECONCILE_REQUIRED`；
- `STORAGE_CORRUPT` / `CHECKPOINT_GAP` / `SNAPSHOT_REQUIRED`。

error 必须指出 retry class（never、same-request lookup、after-refresh、new-operation-only、user-action）并限制 diagnostic fields。error message 只用于显示，不驱动状态机。

unknown field/enum/item 的统一政策：

1. decode 层保留 bounded `extensions`，前提是 scalar/size/depth 满足 Schema；
2. snapshot 可以 round-trip unknown extension；
3. mutation 不盲目回写 unknown；
4. unknown required enum/message 阻断该 feature apply 并请求 capability/snapshot repair；
5. unknown timeline item 保留 strong identity、order anchor 和 typed placeholder，不丢弃相邻已知 item；
6. opaque Provider DTO 只能停留在 adapter/evidence blob，不能进入 domain/wire/DDL。

## 10. 生命周期

每个 feature manifest 必须声明 `start / stop / disconnect / sourceSwitch / hostEpochChange / appBackground / memoryPressure` 的处理：

- start 幂等，重复注册同 feature/message/owner 应在启动验证失败；
- stop 有 deadline，取消 observer/read/HTTP lease/native request；
- disconnect 冻结 durable owners、清理 ephemeral relation/live，保留 last-good；
- source switch 创建新 generation，旧 work 不可 commit 或 ACK；
- app background 只运行 manifest 允许的有界任务；
- memory pressure 先清 live/render cache，再按 namespace eviction policy，不能删 draft/operation evidence。

manifest 启动验证还必须拒绝 dependency cycle、多个 sole writer、handler/capability 不匹配、mutation 缺 fingerprint/delivery/reconcile、消息缺 Schema/golden、namespace 无 owner/clear policy，以及 Product module 绕过 Kernel port。

## 11. 必须故意失败的集成向量

最终验证器至少主动构造并拒绝：

1. route/IP 相同但 Bridge identity 不同的数据合并；
2. 同 providerThreadId 跨 SourcePartition 关联；
3. payload 自报 actor 或 assurance；
4. 旧 connection/source/host epoch callback commit；
5. partial/empty/error 读取清除 last-good；
6. 无 order proof 的两个 cache islands 拼接；
7. live delta 直接推进 durable checkpoint；
8. 两个 canonical writer 或两个 ACTIVE interaction claim；
9. same operationId/different fingerprint；
10. `CALL_STARTED` crash 后自动 redispatch；
11. queue edit/cancel 与 dispatch ownership race；
12. Mobile apply 未 commit/readback 就 ACK；
13. snapshot cascade 删除 draft/local intent；
14. notification 未 re-fetch Broker 就响应；
15. HTTP ticket 跨 actor/source/content 使用；
16. 64 KiB 以上 control envelope 或 digest/Range 不一致；
17. unknown setting field 被 mutation 全量覆盖；
18. product feature 直接写 canonical/operation/interaction 私有表；
19. Claude/V2/Mirror/legacy runtime route 在 composition 中 reachable；
20. cache clear 删除不可重建 local unique state。

## 12. 审核与实施边界

本地设计完成后，本文与 registry/schema/DDL、能力矩阵、源码处置、实验/决策表和验证报告共同进入审核包。设计验证只能证明合同自洽、机器可解析、DDL 约束可执行和故意失败向量按预期失败；Provider、App、设备和发布事实仍保持 `EXPERIMENT_REQUIRED` 或 `NOT_RUN`。

用户接受审核包之前，不创建产品数据库、不接入 composition root、不发布 capability、不运行 Provider/Bridge/App、不访问 8765，也不实施任何源码修改。用户接受后，从批准的 exact open-source baseline 逐 vertical slice 实施；本文不授权机械合并当前 donor source 或设计分支。
