# 01. 领域模型与接收链规范

本文使用 **MUST / MUST NOT / SHOULD / MAY** 表示规范强度。所有时间戳只用于展示和诊断，除非明确说明，
均不得参与身份、去重、顺序或 authority 判定。

## 1. 身份模型

### 1.1 基础类型

```text
SourceRef {
  bridgeInstanceId: OpaqueId
  provider: "codex" | "claude" | FutureProvider
  providerSourceId: OpaqueId
}

ThreadRef {
  source: SourceRef
  providerThreadId: OpaqueId
}

TurnRef {
  thread: ThreadRef
  providerTurnId: OpaqueId
}

ItemRef {
  turn: TurnRef
  providerItemId: OpaqueId
}

IdentityFence {
  connectionGeneration: UInt64
  sourceEpoch: UInt64
  sourceRevision?: OpaqueRevision
  contentRevision?: OpaqueRevision
  authorityGeneration?: UInt64
}

RuntimeBinding {
  thread: ThreadRef
  runtimeSessionId: OpaqueId
  fence: IdentityFence             // authorityGeneration required for writable/live control
  activeTurnId?: OpaqueId
  ownerKind: "bridge" | "desktop" | "cli" | "external" | "unknown"
}
```

Codex 的 `providerSourceId` MUST 等于握手后由 Bridge 认证并公布的 `codexSourceId`；不能由 Mobile
请求体自报后直接信任。为了兼容现有字段，wire adapter 可以同时输出 `codexSourceId` 和
`providerSessionId`，但进入领域层前 MUST 归一为 `SourceRef/ThreadRef`，并验证别名一致。
Claude 等没有公开 source ID 的 provider，必须由 Bridge 根据已认证 profile/config authority 生成并持久化 opaque
`providerSourceId`；不得从 route、cwd 或会话标题派生。其官方 session ID 归一为 `providerThreadId`。

### 1.2 身份层级

| 字段 | 持久身份 | 用途 |
|---|---:|---|
| `bridgeInstanceId` | 是 | 隔离不同 Bridge 安装及其认证边界 |
| `provider` | 是 | 隔离 Codex/Claude 及未来 provider |
| `providerSourceId` | 是 | 隔离账号/profile/权威会话存储 |
| `providerThreadId` | 是 | durable conversation/thread 身份 |
| `providerTurnId` | 是 | provider turn 身份 |
| `providerItemId` | 是 | provider item 身份 |
| `connectionGeneration` | 否 | 拒绝旧 socket 帧 |
| `sourceEpoch` | 否 | 拒绝旧 authority source incarnation |
| `runtimeSessionId` | 否 | 定位当前运行时 |
| `authorityGeneration` | 否 | 拒绝旧 owner/control 操作 |
| `sourceRevision` | 否 | provider snapshot precondition |
| `contentRevision` | 否 | Bridge projection precondition |
| route/IP/DNS/URL | 否 | transport alias |

### 1.3 Alias 规则

1. route 变化只更新连接信息，不迁移数据分区。
2. runtime session 与 durable thread 的绑定必须来自 provider 确认或已验证的 session catalog，不能靠标题/目录猜测。
3. `clientMessageId` 是一次用户输入意图的 ledger key/echo alias，不是 provider item ID。
4. `requestId` 只做一次 RPC correlation；`operationId` 才是 mutation 幂等键。
5. legacy 数据缺强身份时只能标记 `identityConfidence=legacy_unverified`，不能跨 source 自动合并。

## 2. Authority 与五类输入

### 2.1 Authority 层级

```text
provider durable history/state
          │
          ▼
ProviderHistoryProjectionWriter ──唯一 provider-derived timeline writer
          │
          ▼
Bridge verified projection/cache
          │
          ▼
Mobile rebuildable replica
          │
          ▼
Repository/UI projection
```

Bridge 可以规范化、完整性验证、缓存和对账，但 MUST NOT 把观察到的 live event 反向声明为 provider durable
history。Mobile 只发操作意图，不向 Bridge 写 canonical timeline。

### 2.2 当前四种 observation source

| `projectionSource` | 可做 | 不可做 |
|---|---|---|
| `runtime` | focused live overlay、当前 status、interaction | 删除/替换历史窗口 |
| `sharedObserver` | shared app-server live overlay、owner/status | 未经完整读取提交 canonical |
| `externalObserver` | invalidation、活动提示、有界 provisional overlay | 单独证明完整历史 |
| `providerRefresh` | 发起 structured canonical read、产生 repair 证据 | 在失败/空/不完整时清旧数据 |

`canonicalHistory` 是当前源码中“完整 provider read 经验证后的 timeline 投影层”这一概念标签，不是第五个随意竞争的
observer，更不是第二个 provider authority。只有 `ProviderHistoryProjectionWriter` 能更新该派生 base。完整 commit 后，
已被覆盖范围内的 observer buffer 才可丢弃。Catalog、Mirror 和 Mobile replica 仍由各自 projection writer 管理。

### 2.3 失败保留规则

出现以下任一情况时 MUST 保留上一次有效 canonical projection，并附加 `Gap/DegradedState`：

- provider RPC 失败、超时或返回不支持；
- 返回空列表但没有 authoritative empty proof；
- page/window 未完整；
- `sourceRevision/baseRevision` 不匹配；
- cursor、compact、fork 或 source epoch 使 locator 失效；
- identity/ordering 存在歧义；
- capacity 上限导致内容没有全部读取。

## 3. Turn 领域模型

### 3.1 TurnSpine

`TurnSpine` 是历史层的最小可见原子单位：

```text
TurnSpine {
  ref: TurnRef
  sourceRevision: OpaqueRevision
  schemaVersion: UInt32
  terminalState: "completed" | "failed" | "interrupted" | "cancelled" | FutureValue
  startedAt?: TimestampForDisplay
  completedAt?: TimestampForDisplay
  orderedItems: TurnItemCore[]
  payloadRefs: PayloadRef[]
  orderProof: ProviderOrderProof
  completeness: TurnCompletenessProof
  digest: Sha256
}

TurnItemCore {
  ref: ItemRef | LegacyScopedItemRef
  ordinal: UInt32
  kind: KnownItemKind | UnknownProviderItem
  lifecycle: "started" | "completed" | "failed" | FutureValue
  renderCore: TypedRenderCore
  payloadRefs: PayloadRef[]
  identityConfidence: "provider_exact" | "provider_turn_scoped" | "legacy_unverified"
}

PayloadRef {
  payloadId: ContentDigest
  mediaType: string
  byteLength: UInt64
  availability: "inline" | "bridge_content" | "provider_remote" | "unavailable"
  requiredForHistoryVisibility: bool
  omissionReason?: TypedReason
}
```

### 3.2 Spine 必须包含什么

以下信息 MUST 在一次原子 commit 中存在：

- 所有已确认 item 的类型、稳定 ID、provider 顺序和 lifecycle；
- 用户输入的可渲染正文或明确的受保护 payload ref；
- assistant 最终文本、必要 reasoning summary、plan/process/compact marker 等可见核心；
- tool call 名称、安全参数摘要、结果状态；
- 大工具结果、图片、artifact 的类型/大小/digest/可用性；
- 未知 future item 的 raw type、稳定 envelope 与安全的 bounded raw metadata；
- completeness/order/source revision proof。

大工具正文、图片 bytes、diff/file artifact 等 MAY 延迟下载，前提是对应 `PayloadRef` 明确存在，UI 能显示
“可加载/不可用/超限”，且不能把未下载伪装为空字符串。若某 payload 是当前 UI 正确渲染所必需，
`requiredForHistoryVisibility=true`，Spine 在它存在前不得晋升为可见 canonical。

### 3.3 Turn 状态机

```text
absent
  ├─ index observation ───────────────► index_only
  └─ live turn started ───────────────► live_open

index_only ─ live started ────────────► live_open
live_open ─ terminal event ───────────► finalizing
finalizing ─ complete provider proof ─► canonical_spine
canonical_spine ─ all optional bytes ─► canonical_full

live_open/finalizing/canonical_spine
  └─ incomplete/failure/revision gap ─► repair_needed

repair_needed ─ successful proof ─────► canonical_spine/canonical_full
```

状态语义：

- `index_only`：只可用于导航 shell，不能渲染伪正文。
- `live_open`：仅 focused live overlay 可见，不写 canonical tables。
- `finalizing`：保留当前 live final snapshot，并显示正在校准；terminal event 本身不证明历史完整。
- `canonical_spine`：完整可渲染历史已原子提交。
- `canonical_full`：所有可选 payload 已下载；这是缓存层级，不改变历史身份。
- `repair_needed`：保留最近有效 Spine/latest tail，记录 typed gap 与 retry cursor；不清空。

### 3.4 Completeness proof

Turn 只有同时满足以下条件才能进入 `canonical_spine`：

1. target `ThreadRef/TurnRef` 与请求一致；
2. provider adapter 证明该 turn 的 item 页面完整，或使用已验证的等价完整读取；
3. 所有 page cursor 闭合，未触发 capacity truncation；
4. ordered item IDs/ordinals 无冲突；
5. `sourceRevision` 仍是请求对应的 revision；
6. 所有 `requiredForHistoryVisibility` payload 已验证；
7. deterministic encoding 的 digest、item count、payload byte count 一致；
8. staging transaction 尚未被 source/connection generation 取消。

`turn/completed`、一个 `turnId`、item count、SHA-256 或 HTTP 200 中任意单项都不是充分证明。

### 3.5 Deterministic encoding

项目 MUST 选用公开且跨语言可验证的确定性编码：JSON 使用 RFC 8785 JCS，或使用确定性 CBOR。不得只写
`ccp-json-v1` 名称而不定义 Unicode、number、map order、unknown field 和版本迁移。正式实现前必须有
Node/Dart 双向 golden vectors，至少覆盖中文、emoji、大整数、浮点拒绝规则、未知 item 和 payload ref。

## 4. 顺序、去重与覆盖

### 4.1 身份优先级

同一 source/thread 内的去重顺序：

1. exact `providerItemId`；
2. exact `providerTurnId + provider item scoped ID/ordinal`；
3. provider-confirmed alias（例如 user item 与已 admission 的 `clientMessageId`）；
4. legacy 单 turn 内有界 LCS，仅作为展示 fallback，`identityConfidence=legacy_unverified`。

文本、时间、标题、工具名或相近 ordinal MUST NOT 单独触发跨源删除/覆盖。歧义时保留两项并记录 anomaly，
比误删真实 item 更安全。

### 4.2 顺序

- item 顺序只来自 provider order/ordinal/page contract。
- turn 顺序只来自 provider list/cursor/order proof。
- timestamp 只做显示，不用于 sort repair。
- compact/edit/fork 后旧 locator 必须标 stale，重新做 bounded lookup。

### 4.3 Coverage

```text
CoverageSegment {
  thread: ThreadRef
  direction: "newest_to_oldest" | "oldest_to_newest"
  startLocator: ProviderLocator
  endLocator: ProviderLocator
  sourceRevision: OpaqueRevision
  completeBefore: bool
  completeAfter: bool
  verifiedTurnIds: OpaqueId[]
}
```

两个 segment 只有 provider 证明边界相邻且 revision 一致时才能合并。缓存岛、root user index 和搜索结果只提供
locator hint；跳转后若目标不在页内，执行有上限的 neighbor search，仍找不到则显示明确 gap，不插入假消息。

### 4.4 Latest-turn gap

最新 turn 允许存在 `canonicalLatestTail + latestTurnGap`：已经验证的 user/assistant/process/result Spine 可保留，
缺失部分由 repair cursor 继续拉取。非完整最新页不得 whole-window delete，也不得覆盖较旧但完整的 committed window。

## 5. Bridge 接收链

### 5.1 标准流程

```text
provider raw notification/page/RPC
  → ProviderAdapter.decodeAndNormalize
  → IdentityFence.validate
  → ObservationRouter
      ├─ runtime/shared/external → LiveObservationHub
      └─ structured provider read → ProviderHistoryProjectionWriter
  → TurnReconciler + CoverageEngine
  → VerifiedProjectionStore transaction
  → SyncBatchBuilder
  → vNext and/or v2 ProtocolAdapter
```

每个阶段输入/输出必须是 typed object，不传递任意 `Map<string, unknown>` 到 UI 层。未知 provider item 只允许在
bounded `UnknownProviderItem` envelope 中透传。

### 5.2 ProviderAdapter 合同

每个 provider adapter MUST 实现：

```text
probeCapabilities(source) -> ProviderCapabilitySet
listThreads(source, cursor, limit, filters) -> BoundedPage<ThreadFact>
readTurn(thread, turnLocator, itemCursor, limit) -> BoundedPage<TurnItemFact>
readWindow(thread, windowRequest) -> CanonicalReadResult
observeRuntime(binding) -> AsyncStream<RuntimeObservation>
readThreadState(thread, namespaces) -> ThreadStateFacts
dispatchTypedOperation(operation) -> ProviderDispatchResult
```

Adapter MUST 显式报告 `complete/incomplete/unsupported/ambiguous`，不能用空数组同时表示“没有内容”和“读取失败”。
Codex persisted-history fallback 顺序固定为：

1. `thread/items/list`（若实际 capability probe 成功），严格 page/limit/cursor；
2. `thread/turns/list(itemsView: full)`，严格 page/limit/cursor；
3. 经过 fixture 验证的 legacy turns 参数重试；
4. 仅当声明 `boundedWholeThreadFallback` 且前三者明确 unsupported 时，使用
   `thread/read(includeTurns: true)`，随后按 100,000 entries/64 MiB 硬上限做 post-response normalization；超限视为
   incomplete，不发布/删除 last-good；
5. read-only 路径绝不退回 `thread/resume`。

每个 app-server process + thread 缓存实际 adapter 选择，因为同一 process 可能同时托管 legacy/paginated thread。
unsupported、partial、timeout、cursor loop 或 normalization 超限都保留上一次有效 projection 并产生 typed gap；source epoch
变化后重新 probe。

### 5.3 ObservationRouter

- raw runtime item/delta 进入 live hub；不进入 provider-history projection writer。
- terminal result 只触发 canonical refresh，不直接证明 commit。
- shared observer 只在 owner/generation 精确匹配时产生 live overlay。
- external rollout monitor 默认只触发 invalidation/refresh；若展示 provisional 内容，必须带
  `projectionSource=externalObserver` 且不能删除 canonical。
- 前台会话页使用 `focused` full-content watch；前台 Home 使用独立、每 source 有界的 `home_active_priority` watch set，
  追踪真正 running/attention 会话，即使页面未打开也能接收 bounded live core 并在 Turn 结束后触发 canonical refresh。
- background `notifications_only` 模式不传正文，只保留 content-free activity/attention；回前台重新 subscribe/catch-up。

### 5.4 ProviderHistoryProjectionWriter

投影器对同一 `ThreadRef` 串行 commit，并执行：

1. 捕获请求时的 source/content revision；
2. bounded provider read 到 staging；
3. 验证 identity、order、coverage、capacity 和 digest；
4. 生成 `ProjectionCommitPlan`；
5. 在一个 storage transaction 中写 turn/items/coverage/index/checkpoint；
6. 仅在 complete coverage 内执行删除或替换；
7. commit 后发布 immutable `ProjectionCommitted`；
8. sync adapter 据此发 batch；不得在 DB commit 前发 durable ACK 要求。

任何 source epoch/revision mismatch 都取消 staging，保留现有 committed projection。

### 5.5 LiveObservationHub

Hub 将 stable item key 与 transient fence 分开：

```text
StableLiveItemKey = SourceRef + providerThreadId + providerTurnId + providerItemId
LiveFence = connectionGeneration + sourceEpoch + runtimeSessionId + authorityGeneration
PromotionPrecondition = sourceRevision + contentRevision + exact TurnRef/ItemRef
```

generation/revision 不成为 durable identity，但 fence/promotion 任一不匹配都必须拒绝迟到 overlay 或晋升。Hub MUST：

- 向当前 focused thread 投递完整 live core；向明确 `home_active_priority` watch set 投递有界 live core；除此之外不广播正文；
- 每 source 的 Home watch 数量由 capability 限制，默认 8，focus 永远优先；watch generation/target 变化取消旧流；
- completed snapshot 覆盖同 item 的 delta 拼接结果；
- owner/generation 变化立即使旧 binding stale；
- 为同 stable item key 提供 live→canonical promotion；
- 有界保存，过载时发 `live_gap`，不伪造完整；
- 断线时清 memory overlay，不清 SQLite/history。

Mobile 可把 Home priority overlay 保存在有界 memory/hot projection 中，但不得作为 canonical SQLite history；Home 离开前台或
delivery mode 变为 `notifications_only` 时清正文 overlay，只保留已提交历史和 content-free activity。

## 6. Bridge derived stores

### 6.1 Verified Projection Store

逻辑表及唯一写者：

| 表/集合 | 主键 | 唯一写者 |
|---|---|---|
| `source_registry` | `SourceRef` | authenticated source registry |
| `thread_catalog` | `ThreadRef` | CatalogProjector |
| `thread_status` | `ThreadRef` | StatusProjector |
| `turn_spines` | `TurnRef + contentRevision` | ProviderHistoryProjectionWriter |
| `turn_items` | `ItemRef + contentRevision` | ProviderHistoryProjectionWriter |
| `payload_refs` | `TurnRef + contentRevision + payloadId` | ProviderHistoryProjectionWriter |
| `provider_turn_projection_heads` | `TurnRef` → active `contentRevision + digest + commitId` | ProviderHistoryProjectionWriter |
| `coverage_segments` | `ThreadRef + segmentId` | CoverageEngine via projector |
| `user_turn_index` | `ThreadRef + provider item/turn id` | ProviderHistoryProjectionWriter |
| `relation_edges` | `relationId` | RelationGraphService |
| `feature_snapshots` | `featureId + target + revision` | owning Feature Module |
| `feature_snapshot_heads` | `featureId + target` → active revision/commitId | owning Feature Module |

version row 与对应 head pointer 必须在同一 transaction 中提交；读者只通过 head 选择可见版本，绝不对 opaque revision
做 `max()` 或按时间猜 active head。coverage/index/checkpoint 与 head 使用同一个 `commitId`，crash 后要么全部可见，要么全部不可见。
feature snapshot 采用相同规则。这些都是 derived cache；store 损坏时可以从 provider 重建，绝不能反向写 provider。

### 6.2 Content Store

大内容使用内容寻址：

```text
ContentKey = sha256(canonical bytes)
ObjectScope = SourceRef + ThreadRef + TurnRef + manifestVersion + contentKey
```

Bridge 必须有：临时文件、长度/digest 校验、file fsync、atomic rename、目录 fsync、metadata transaction、
reader lease、LRU/retention、per-source/per-thread quota 和 rollback generation。content-addressed 相同 bytes 可以物理去重，
但授权检查仍按完整 ObjectScope，不能因 digest 相同跨 source 泄漏。

## 7. Mobile 接收链

### 7.1 标准流程

```text
authenticated WSS frame / HTTPS content
  → Envelope + target + generation validation
  → per-subscription serialized mutation queue
  → staging tables / temp content
  → revision + digest + coverage validation
  → SQLite transaction commit
  → cumulative projection ACK / content receipt
  → Repository snapshot
  → pure TimelineProjectionReducer
      canonical + outgoing intent + focused live overlay
  → UI
```

Mobile MUST 在处理 local feature frame 后再决定是否交给 legacy history handler，避免同一帧被两条链重复消费。

### 7.2 Mobile 存储分层

物理文件名可在实现 ADR 中最终确定，但逻辑上必须分离：

1. **Rebuildable replica**：catalog、status、Turn Spine、items、coverage、index、relation、feature snapshot、checkpoint。
2. **Local user state**：draft、read watermark、pin、UI preference、未提交输入意图。
3. **Memory-only transient**：runtime overlay、pending interaction body、watch subscription、socket generation。
4. **Optional Mirror**：完整离线副本，仍是独立可重建投影，不成为 normal timeline 的第二写者。

清理 rebuildable cache MUST NOT 删除 draft/read/pin/outgoing intent。source switch 只 reset 精确 partition。
Mobile replica 也必须有 target-scoped active-head/commit receipt；Repository 只能读取已提交 head，不能把 staging 或最高字符串
revision 当当前版本。

### 7.3 Staging 与 commit

- 所有 multi-page canonical batch 先写 staging，并绑定 request/subscription/batch/source/base revision。
- duplicate sequence 返回当前累计 ACK；sequence gap 停止该 batch 并 resubscribe，不 broad clear。
- base revision mismatch 只 reset 对应 thread/feature scope。
- `runtime_overlay` 不写 canonical tables。
- commit 成功后才能 ACK durable projection；UI receipt 不是 commit proof。

### 7.4 Repository 与 UI

Repository 是页面唯一读入口。timeline reducer 必须是纯函数：

```text
VisibleTimeline = reduce(
  committedCanonicalWindow,
  localOutgoingByClientMessageId,
  focusedRuntimeOverlay,
  typedLocalDecorations
)
```

`typedLocalDecorations` 仅用于本地明确语义（例如 manual compact divider、delivery failure），必须锚定精确 TurnRef，
不能伪装 provider assistant/user message。Goal、settings、subagent list 和 Side Chat relation 不进入此 reducer。

## 8. Catalog、Status 与 Timeline 必须分开

| 事实 | 所属投影 | 说明 |
|---|---|---|
| 标题、project group、archived、fork lineage | catalog | cwd/path 不是 identity |
| running/idle/attention/control owner/confidence | status | observer 可更新但需 generation |
| TurnSpine/items/coverage/gap | provider-history timeline projection | 仅 ProviderHistoryProjectionWriter 持久提交 |
| Goal/settings | thread state | 独立 revision 与 operation |
| Side Chat/subagent/review parent-child | relation graph | child history不复制到 parent |
| pending approval/question | interaction | live binding + identity-only ledger |

`thread/started` 只说明观察到 thread，不等于 materialized、resumable、sidebar visible 或 history complete。readiness 必须是
由 catalog/materialization/capability/source health 组成的 typed state，而不是一个布尔值。

## 9. 接收链异常代码

以下错误码为稳定语义，展示文案可本地化：

| code | 含义 | 默认动作 |
|---|---|---|
| `identity_mismatch` | source/thread/turn 不一致 | 丢弃帧、记录 anomaly、必要时重新认证 |
| `stale_generation` | connection/source/authority 已变化 | 丢弃 transient，不清 durable |
| `revision_mismatch` | base/source revision 失配 | scoped resubscribe/repair |
| `sequence_gap` | subscription sequence 缺失 | 保留 cache，重新订阅 |
| `coverage_incomplete` | page/window 不完整 | 保留旧窗口并显示 gap |
| `turn_incomplete` | terminal 但 Spine 未获完整证明 | finalizing/repair |
| `content_digest_mismatch` | payload/manifest 校验失败 | 删除 staging，重新获取 |
| `capacity_exceeded` | 超过协商硬上限 | typed gap/deferred payload，不静默截断 |
| `provider_read_failed` | provider 读取失败 | 保留旧事实，指数退避 |
| `unsupported_capability` | 当前 source/provider 不支持 | feature 降级/隐藏，不伪造数据 |

## 10. 接收链完成定义

只有以下证据同时存在，才能说新接收链完成：

- provider fixtures 覆盖 supported/unsupported items list、cursor、compact、fork、多 user item、未知 item；
- Bridge ProviderHistoryProjectionWriter 的完整性、失败保留和 target-scoped sole-writer 测试通过；
- WSS/可选 HTTP → Dart → staging → SQLite → Repository → reducer 的真实链测试通过；
- sequence/revision/source/authority fault injection 不丢旧 cache、不产生假连续；
- old/new/private/daemon 兼容矩阵通过；
- 真实 Mobile UI 与物理设备的滚动、跳转、重连、后台恢复验收通过。

静态源码存在、单元测试通过或 manifest digest 正确都不能单独满足此完成定义。
