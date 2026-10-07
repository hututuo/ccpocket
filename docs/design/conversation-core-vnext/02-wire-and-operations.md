# 02. Wire、发送与控制操作规范

## 1. 协议演进原则

1. 协议家族名为 `ccpocket.conversation`；它的 major 只表示 envelope/基础语义，不等于 App 或 Bridge 版本。
2. 具体功能使用独立 `featureId + major + minor` 协商，不能以一个全局 exact-version 开关决定所有功能。
3. 已发布字段只能 additive；未知字段 MUST 忽略并保留，未知事件按 feature policy 降级。
4. mutation 必须是 tagged union 中的已知类型；禁止把任意字符串方法塞入 generic command 后允许离线 replay。
5. 现有 v2 adapter 与新 adapter 必须消费同一领域 commit/event，不维护第二份事实。

正式实现时 MUST 维护 JSON Schema 2020-12、生成的 TypeScript/Dart 类型和跨语言 golden vectors。本文件中的
结构是 schema 的规范来源；schema 不得只覆盖其中一部分消息。

## 2. Transport 与认证

### 2.1 Control/live plane

- 使用现有 authenticated WebSocket。
- API key、paired-device proof、Bridge identity 和 route policy 继续由连接层验证。
- 连接 trust level 分为 `paired_or_key`、显式 `trusted_open_reduced`、`legacy_reduced` 与 `unauthenticated`。未认证连接不能
  获得高权限/private source、content offer、诊断、destructive/shared mutation 等表面；显式 `BRIDGE_AUTH_MODE=open` 和旧无 key
  Bridge 可以按现有可信 LAN 合同提供 reduced-capability `/readyz`、session/v2 路径，但不能因此获得私有 HTTP 或写权限。
- WebSocket 可靠有序仅适用于一次连接；应用层仍需 subscription sequence/revision 以跨重连恢复。

### 2.2 Content plane

- 大 Turn Spine 或 payload MAY 使用现有私有 HTTP(S) transport 的 Range/ETag 能力。
- content plane 是优化，不是协议必需路径；无能力时使用 bounded inline/page fallback。
- transfer bearer 必须绑定 authenticated device/session、完整 object scope、connection generation、route、expiry。
- bearer/URL 不写普通日志、诊断或 SQLite；过期、source switch、connection revoke 后失效。

## 3. 公共 envelope

```text
Envelope<T> {
  protocol: "ccpocket.conversation"
  protocolMajor: 3
  protocolMinor: UInt16
  type: KnownMessageType
  messageId: OpaqueId
  connectionGeneration: UInt64
  requestId?: OpaqueId
  subscriptionId?: OpaqueId
  source?: SourceRefWire
  target?: ThreadTargetWire
  payload: T
}

SourceRefWire {
  bridgeInstanceId: OpaqueId
  provider: string
  providerSourceId: OpaqueId
  codexSourceId?: OpaqueId  // provider=codex 时必须与 providerSourceId 相同
  sourceEpoch: UInt64
}

ThreadRefWire {
  source: SourceRefWire
  providerThreadId: OpaqueId
}

ThreadTargetWire {
  thread: ThreadRefWire
  providerTurnId?: OpaqueId
  providerItemId?: OpaqueId
  runtimeSessionId?: OpaqueId
  authorityGeneration?: UInt64
}
```

约束：

- `messageId` 防止连接内重复处理，不承担 mutation 幂等。
- `requestId` 是 response correlation；服务端可在重连后忘记它。
- `operationId` 位于 typed mutation payload，才是稳定意图 ID。
- `source/target` 存在时，Bridge/Mobile 必须与 authenticated connection state 比较，不能仅信 envelope；二者同时
  存在时，`target.thread.source` 必须与 envelope `source` 完全一致。
- `sentAt` 若实现只能放 payload metadata，不能参与任何正确性判断。

## 4. Handshake 与能力

### 4.1 `core.hello`

```text
CoreHello {
  deviceId: OpaqueId
  clientInstanceId: OpaqueId
  clientBuild: string
  supportedProtocolRanges: [{ major, minMinor, maxMinor }]
  supportedFeatures: [{ featureId, major, minMinor, maxMinor }]
  resumeHints?: [{ subscriptionKind, checkpointToken }]
}
```

`deviceId` 是物理/安装授权 scope 的输入之一，`clientInstanceId` 标识本次 App 安装/profile 的稳定 sender；二者都不是
conversation 数据身份。Bridge 从已验证的 handshake context 生成 `originClientId`，客户端不得在业务 payload 中自报别人的
origin，也不得在 hello 中指定希望信任的 source 身份。

### 4.2 `core.welcome`

```text
CoreWelcome {
  selectedProtocol: { major, minor }
  bridgeInstanceId: OpaqueId
  authenticatedSources: SourceDescriptor[]
  features: FeatureCapability[]
  topology: "private_legacy" | "daemon_shared" | "mixed_read_only"
  trustLevel: "paired_or_key" | "trusted_open_reduced" | "legacy_reduced"
  connectionGeneration: UInt64
  limits: CoreLimits
}

FeatureCapability {
  featureId: string
  major: UInt16
  minor: UInt16
  modes: string[]
  targetKinds: string[]
  limits: object
  availability: "ready" | "read_only" | "degraded" | "unsupported" | "update_required"
  reasonCode?: string
}
```

精确 Codex/app-server/daemon version tuple 只可作为某个 shared mutation capability 的 readiness 条件，不能让
private history、旧同步或其他 provider 全部断开。

### 4.3 Capability 变化

`core.capabilities_changed` 只能 content-free 通知客户端重新获取 capability snapshot；不能隐含操作成功。
writer lease、source epoch 或 owner 变化必须同时增加相应 generation，旧 control 自动 stale。

## 5. Sync 消息族

### 5.1 请求

| type | 关键 payload | delivery |
|---|---|---|
| `catalog.subscribe` | filters、knownRevision、checkpoint | live subscription |
| `timeline.subscribe` | ThreadRef、window、knownRevision、focus | live subscription |
| `timeline.focus` | ThreadRef/TurnRef、focusGeneration | ephemeral |
| `timeline.priority_watch.set` | bounded ThreadRef[]、watchGeneration、reason=`home_active` | foreground ephemeral |
| `timeline.page.read` | locator、direction、limit、knownRevision | bounded read |
| `timeline.repair.request` | exact gaps/turns、knownRevision | bounded read |
| `sync.unsubscribe` | subscriptionId、原 subscription kind | catalog/timeline 通用 ephemeral |

`timeline.priority_watch.set(threads=[])` 清空 Home watch set；disconnect/delivery mode 降级也必须清空，不需要另造永久 watch。

### 5.2 事件

| type | 作用 |
|---|---|
| `sync.begin` | 建立 batch、base/source/content revision、scope |
| `catalog.snapshot` / `catalog.patch` | catalog/status 分层投影 |
| `timeline.turn_batch` | 一个或多个完整 inline TurnSpine，或 offer descriptor |
| `timeline.index_page` | user/turn locator，不含伪正文 |
| `timeline.latest_tail` | 已验证 latest spine + typed gap |
| `timeline.runtime_overlay` | focused、generation-fenced、memory-only |
| `timeline.priority_watch.state` | accepted/rejected targets、watchGeneration、limits | content-free control state |
| `timeline.gap` | reason、typed `GapDescriptor`、repair cursor、retry class |
| `sync.complete` | window completeness、latest completeness、nullable typed latest gap、checkpoint |
| `sync.resync_required` | scoped reason、expected revision；不得要求 broad cache clear |

### 5.3 每帧顺序信息

```text
SyncFrameMeta {
  subscriptionId: OpaqueId
  requestId: OpaqueId
  batchId: OpaqueId
  sequence: UInt64
  sourceRevision: OpaqueRevision
  baseRevision?: OpaqueRevision
  contentRevision: OpaqueRevision
  scope: TypedScope
}

GapDescriptor =
  | { kind: "range", from: TurnLocator, through?: TurnLocator }
  | { kind: "turns", turns: NonEmpty<TurnRef> }
```

`sync.begin/complete/resync_required/ack/flow.ack` 的 target 是 `SyncScope = SourceRef | ThreadRef`；catalog batch 使用
source scope，timeline batch 使用 thread scope。不能把 catalog 或 subscription-level flow ACK 伪装成某个 turn target。
`timeline.gap` 必须同时携带 `gap: GapDescriptor` 与 `repairCursor: OpaqueCursor | null`。`sync.complete.latestTurnGap`
字段始终存在：`latestTurnComplete=true` 时必须为 `null`，否则必须是 `GapDescriptor`。`sync.resync_required` 必须带
服务端当前期待的 `expectedRevision`；这些信息不能藏入未定型的 `meta`。

- sequence 在一个 subscription generation 内严格递增。
- duplicate sequence：接收端不重复应用，返回当前累计 ACK。
- sequence gap：停止应用后续 durable frame，保留 SQLite，发 scoped resubscribe。
- base revision mismatch：只重建精确 scope。
- 一次 subscription 可以产生多次 batch；`sync.complete` 不关闭 subscription。

### 5.4 ACK 分类

不同事实使用不同 ACK，禁止一个全局 `streamSeq ACK` 同时表示内存看到、SQLite 落盘和 payload 可用。

```text
sync.ack {
  subscriptionId
  batchId
  committedThroughSequence
  contentRevision
  ackKind: "sqlite_committed"
}

flow.ack {
  subscriptionId
  observedThroughSequence
  ackKind: "memory_observed"
}

content.receipt {
  offerId
  manifestDigest
  storedBytes
  outcome: "committed" | "already_present" | "rejected"
}
```

`timeline.runtime_overlay` 可以用 `flow.ack` 控制背压，但该 ACK 不能推进 durable checkpoint。

## 6. Inline 与 HTTP content

### 6.1 `content.offer`

```text
ContentOffer {
  offerId: OpaqueId
  objectKind: "turn_spine" | "payload"
  objectScope: { SourceRef, TurnRef, payloadId? }
  manifestVersion: UInt32
  manifestDigest: Sha256
  objectDigest: Sha256
  byteLength: UInt64
  mediaType: string
  etag: string
  rangeSupported: bool
  expiresAt: Timestamp
  transferUrl: SecretUrl
}
```

`transferUrl` 只能在内存中持有。Mobile 下载流程：Range temp → length/ETag/digest → deterministic manifest → staging
→ SQLite/content atomic commit → `content.receipt`。下载失败不改变已有 TurnSpine 可见性；若该内容是 required core，
对应 Turn 保持 `finalizing/repair_needed`。

`content.cancelled` 必须返回 `offerId + releasedBytes + leaseState`，使调用方可以区分已释放、仍有 reader 和已过期。
输入上传租约由 `(uploadId, payloadId)` 双身份定位；`input_payload.release` 与 `input_payload.released` 都必须携带二者，
不得只用可跨上传重试复用的 `payloadId` 猜测要释放哪一个 lease。

### 6.2 选择规则

- 小于协商 `maxInlineTurnSpineBytes` 的 Spine SHOULD 内联，减少双请求与 head-of-line latency。
- 大 Spine或 payload 使用 offer；不得为了架构整齐强制每个 Turn 走 HTTP。
- 单 payload 超限时返回 typed `capacity_exceeded` 和可恢复 locator；不得静默截断后标 complete。
- background `notifications_only` 不自动下载正文；前台或明确离线缓存策略才可调度。

## 7. Typed Operation 基础

### 7.1 公共 mutation header

```text
OperationTarget =
  | { kind: "source", source: SourceRefWire }
  | { kind: "thread", target: ThreadTargetWire }

OperationHeader {
  operationId: OperationId       // vNext: UUIDv7；legacy adapter 可映射旧 opaque ID
  operationKind: KnownOperationKind
  target: OperationTarget
  requestDigest: Sha256
  precondition?: TypedPrecondition
  runtimeFence?: {
    runtimeSessionId: OpaqueId
    authorityGeneration: UInt64
    expectedTurnId?: OpaqueId
  }
}
```

`OperationHeader.target` 永远是授权/串行化的 parent source 或 thread 容器。Registry 的 `targetScope=item|queue_item|
interaction|diagnostic_capture` 表示业务 subject，必须在 typed payload 中另带 exact subject ref；该 ref 同时进入 requestDigest、
fingerprint 和 precondition。Bridge 必须验证 subject 隶属于 header parent。不能把 queue item/interaction ID 单独当授权 target，
也不能在未来悄悄扩展 header union 绕过 SourceRef/ThreadRef。

规则：

- 幂等 key 是 `module namespace + target + operationKind + operationId`。
- 同 key、同 digest 返回已有状态；同 key、不同 digest 返回 `operation_conflict`。
- 服务端从 feature manifest 决定 replay policy，不能接受客户端任意声明“可重放”。
- mutation 在 provider RPC 之前和之后都重新校验 source/lease/precondition。
- response 丢失后，客户端先 query operation state；不能直接用新 requestId 重做 mutation。

`turn_input` 还有第二条不可绕过的唯一约束：

```text
InputIntentKey = SourceRef + providerThreadId + clientMessageId
```

该 key 首次 admission 后永久绑定首个 `operationId + requestDigest`（至少在声明的 idempotency window 内）。同 key、同
operation/digest 返回已有记录；同 `clientMessageId` 配不同 operation 或 digest 必须返回 `operation_conflict`。用户显式
“重新发送”时必须同时生成新的 `operationId` 和 `clientMessageId`。

`turn_steer` 使用 `SourceRef + thread + expectedTurnId + authorityGeneration + clientMessageId`；ephemeral child input 使用
`SourceRef + child + registryGeneration + clientMessageId` 的同类唯一约束。它们只在当前 live fence 内查询/去重，绝不跨重连
自动 dispatch。

### 7.2 四种 delivery policy

| policy | 允许持久化 | 断线前 dispatch | dispatch 后未知 | 自动 replay |
|---|---:|---|---|---:|
| `durable_queueable_before_dispatch` | 是 | 可排队 | 对账 | 仅 dispatch 前 |
| `durable_reconcile_only` | 是 | 立即/串行 | `outcome_unknown` 后只读回 | 否 |
| `live_fenced` | identity 可短期记账 | 必须在线 | stale/unknown | 否 |
| `bounded_read` | correlation only | 必须在线 | 可重新读取 | 不是 mutation replay |

只有普通“下一轮新 Turn 输入”允许第一种 policy。persisted child create、Goal、settings 等使用第二种；steer、stop、
approval/question 使用第三种；catalog/page/subagent read 使用第四种。

### 7.3 Ledger retention 与查询

- 每 module/source 默认最多 4,096 条、8 MiB；硬上限 16,384 条。feature 可以声明更低上限，提高需要容量 ADR。
- active、provider_dispatching、provider_accepted、outcome_unknown、claimed/submitting 记录不得自动 prune；容量不足时 fail closed
  拒绝新 mutation，不能删除未知结果后重新 dispatch。
- terminal 完整结果默认保留 7 天，之后压缩为 key + fingerprint + outcome/provider IDs 的 tombstone；tombstone 至少保留
  advertised `operationIdempotencyWindow`（默认 30 天）。vNext `OperationId` 使用 UUIDv7，Bridge 只用其中时间做窗口年龄
  拒绝（不用于顺序/identity/authority）；超窗口返回 `operation_expired_or_unknown`，客户端不得复用 ID，明确新意图生成新 ID。
- 所有 query/prune/GC 按 authenticated SourceRef/module scope；client 不能枚举其他 source 的 operation ID。
- ledger commit 必须 atomic/fsync，持久化 revision/checksum；损坏进入 degraded fail-closed，保留可读 last-good 备份。
- module manifest 必须声明 terminal TTL、tombstone TTL、max records/bytes、GC trigger 和 unresolved recovery；不能只依赖全局默认。

## 8. 新 Turn 与 Bridge Queue

### 8.1 `turn.input.submit`

```text
TurnInputSubmit {
  header: OperationHeader       // operationKind="turn_input"
  clientMessageId: OpaqueId
  content: InputPart[]
  queuePolicy: "enqueue_if_busy" | "reject_if_busy"
}

InputPart =
  | { kind: "text", text: BoundedString }
  | { kind: "image_ref", payloadId, mediaType, byteLength, digest }
  | { kind: "file_ref", payloadId, mediaType, byteLength, digest }
```

图片/文件 bytes 不进入普通 control frame；先走 authenticated payload admission。Bridge 对 normalized input 计算 digest，
并在返回 admission 前持久化。

Mobile 的 input outbox 只覆盖“用户已按发送且 socket write 后尚未收到 `turn.input.admitted/rejected`”的窄窗口；重连时
必须原样复用同一 `operationId + clientMessageId + digest`。它不能自行生成下一轮队列事实，也不能把普通未发送 draft 自动
变成 provider input。Bridge 若已有记录只返回已有 admission/state；若记录已到 `provider_dispatching/outcome_unknown`，只对账，
绝不再次 dispatch。收到 admission/rejection 后 Mobile 删除该 outbox 项。

发送侧 payload 使用独立的 content-admission 流程：

```text
input_payload.prepare {
  requestId
  target: ThreadRefWire
  payloadId: ContentDigest
  mediaType
  byteLength
  digest
}

input_payload.offer {
  uploadId
  transferUrl: SecretUrl
  expiresAt
  maxBytes
  offset
}

input_payload.receipt {
  uploadId
  payloadId
  outcome: "verified" | "already_present" | "rejected"
}
```

上传 bytes 可按 digest/offset 安全续传，因为 upload 本身不触发 provider mutation；Bridge 校验完成的 `payloadId` 才能
出现在 `TurnInputSubmit`。未被 admission 使用的 object 按短期 lease/GC 删除。旧 Bridge 无此能力时只能走已有的、明确有界的
attachment fallback，不能把任意大 base64 塞入 control frame。

### 8.2 admission/result

```text
turn.input.admitted {
  operationId
  clientMessageId
  originClientId
  deliveryAudience: "origin_only"
  admissionMode: "direct" | "queued"
  state: "persisted" | "existing"
  queueItemId?
  queueRevision?
}

queue.item_admitted {
  operationId
  clientMessageId
  originClientId
  deliveryAudience: "origin_only"
  queueItemId?
  queueRevision
  position
}

turn.input.state {
  operationId
  clientMessageId
  originClientId
  deliveryAudience: "origin_only"
  queueItemId
  state: InputDeliveryState
  providerTurnId?: OpaqueId
  reasonCode?: string
}
```

状态机：

```text
received
  → persisted_admitted
  ├─ busy/enqueue ─► persisted_queued ─┐
  └─ idle/direct ─────────────────────┴─► provider_dispatching
  → provider_accepted
  → provider_observed

persisted_admitted/persisted_queued → cancelled/rejected_before_dispatch
provider_dispatching → provider_rejected | outcome_unknown
provider_accepted → provider_observed | outcome_unknown
```

- Bridge 先持久化 ledger，随后向发送设备发 `turn.input.admitted(state=persisted)`。idle direct 与真正 queued 都遵守
  persist-before-dispatch；`admissionMode` 明确区分二者。
- queued 项再发 sender-local `queue.item_admitted`，表示它已进入 Bridge 权威下一轮队列。普通 direct delivery 不显示
  队列第二阶段/双勾。
- `provider_dispatching` 之前的进程重启可安全恢复队列。
- 进入 `provider_dispatching` 后，任何 crash/timeout 都不能自动再次 `turn/start`；必须进入 `outcome_unknown` 并
  对账 canonical history/provider response。
- `provider_accepted` 表示 provider RPC 接受，不等于 Turn 已出现在 canonical history。
- `provider_observed` 需要强 provider identity/alias 证据。
- 用户明确“重新发送”必须创建新 `operationId + clientMessageId`，并在 UI 提示可能重复；不能篡改旧账本。
- `turn.input.admitted/state` 只发 `originClientId` 对应设备；其他已授权客户端通过 `queue.changed/queue.snapshot` 观察
  Bridge 队列，并通过 canonical `user_input`/TurnSpine 看到 provider 已接收的消息，绝不把别人的 local receipt 当自己的 ACK。

### 8.3 Queue 操作

| type | target | policy | 条件 |
|---|---|---|---|
| `queue.read` | ThreadRef | bounded read | authoritative source |
| `queue.item.update` | queueItemId | durable before dispatch | expected queue revision、仍 queued |
| `queue.item.cancel` | queueItemId | durable before dispatch | exact item、仍 queued |
| `queue.item.reorder` | queueItemId | feature-gated | expected revision；默认可不支持 |

所有 queue mutation 必须带 `OperationHeader + originClientId + queueItemId + expectedQueueRevision`，fingerprint 包含目标 item、
旧 revision 和新内容/位置。update/cancel MAY 放入专用 durable queue-mutation outbox；重连后必须先取得 authoritative
`queue.snapshot`，仅当 item 仍为 `persisted_queued` 且 revision 匹配才提交，否则 `precondition_failed`。结果 sender-local，
Bridge 另向所有已授权 watcher 发 content-free `queue.changed(thread, queueRevision)` 供其重读。

每 thread 默认最多 16 条 FIFO；一次 `input_ready` 只 dispatch 一条。编辑后产生新 digest/revision，同 operation key
的 payload 不能悄悄改变。已 dispatch 项不能 update/cancel，只能 stop exact live turn（若 provider 支持）。

## 9. Steer 与 Stop

### 9.1 `turn.steer.submit`

必须带 `ThreadRef + runtimeSessionId + authorityGeneration + expectedTurnId + operationId + clientMessageId`。
它只对当前 owner 的精确活动 Turn 生效，policy=`live_fenced`，永不进入 next-turn queue 或 Mobile offline outbox。

provider 未返回稳定 owner/turn fence、owner 为外部且 topology 不支持 shared steer、或 generation 已变化时 MUST fail closed。

### 9.2 `turn.stop.submit`

必须带精确活动 Turn 与 authority generation。stop 是 best-effort live control：

- 同连接/同 generation 的重复 operation 可返回已有结果；
- 断线后不得自动重发；
- “未确认 stop”不能在 UI 显示为已停止；
- stop terminal event 最终由 provider timeline/status 校准。

## 10. Interaction Broker

审批、拒绝、AskUserQuestion、MCP elicitation、ExitPlanMode 等统一为 Interaction，但 response 仍是 typed union。

### 10.1 identity

```text
InteractionRef {
  source: SourceRef
  providerThreadId
  providerTurnId
  providerRequestId: string | number
  authorityGeneration
  requestGeneration
}
```

JSON-RPC 数字 `7` 与字符串 `"7"` 是不同 request ID，序列化时必须保留类型。

### 10.2 请求与响应

```text
interaction.request {
  interactionRef
  publicRequestId
  kind: "tool_approval" | "user_question" | "mcp_elicitation" | "exit_plan" | FutureKind
  safePresentation: TypedInteractionPresentation
  expiresAt?
}

interaction.respond {
  header: OperationHeader       // live_fenced
  interactionRef
  claimantId
  response:
    | { kind: "approve", updatedInput?, updatedPermissions? }
    | { kind: "reject", message? }
    | { kind: "answer", answers }
    | { kind: "cancel" }
}
```

Broker 流程：observe identity-only → claim → mark submitting → exact provider write → mark submitted/resolve。
传输失败进入 `outcome_unknown`，不冒充成功。持久 ledger 不保存敏感 request body；body 只存在于与当前 generation
绑定的 live binding。owner/lease/generation 变化使旧 binding stale。

private legacy approve/reject/answer 仅保留 active-runtime live adapter；daemon/shared 模式缺 Action Broker 能力时返回
`interaction_broker_required`，不能让旧 frame 越过 Desktop owner。

## 11. Thread-state 操作的 wire 分类

| 消息族 | target/policy | 关键 precondition |
|---|---|---|
| `thread.goal.get` | ThreadRef / bounded read | source capability |
| `thread.goal.set` / `clear` | ThreadRef / durable_reconcile_only | operationId、expected goal facts/revision、writer lease |
| `thread.settings.get` | ThreadRef / bounded read | source capability |
| `thread.settings.patch` | durable ThreadRef only / durable_reconcile_only | operationId、expected settings revision、shared writer lease；禁止 runtime identity |
| `runtime.settings.patch` | exact RuntimeBinding / live_fenced compatibility | runtimeSessionId、authorityGeneration、expected active facts |
| `thread.compact.start` | exact RuntimeBinding / live_fenced | operationId、idle/owner/capability、runtimeSessionId、authorityGeneration；永不离线 replay |
| `thread.review.start` | ThreadRef / typed core action | provider-specific precondition |

这些消息都有独立 schema；不能转成 `turn.input.submit` 或 generic method。Goal、settings 结果发布各自 snapshot/invalidation，
不写 chat history；compact/review 若 provider 产生 timeline item，由 canonical read 正常投影。
`createChild` 只是 RelationGraphService 的 domain API，不是 wire message；wire 必须选择具体的 `thread.fork`、
`side_chat.persisted.create` 或 provider-specific child operation，避免一个 generic child command 扩权。

## 12. 稳定错误模型

```text
OperationError {
  code: StableErrorCode
  retryClass: "never" | "after_refresh" | "same_intent_query" | "user_new_intent"
  operationId?: OpaqueId
  currentRevision?: OpaqueRevision
  safeMessage?: string
  details?: BoundedTypedDetails
}
```

核心 error code：

| code | retryClass | 含义 |
|---|---|---|
| `unsupported_feature` | never | capability 不存在 |
| `update_required` | never | 当前客户端不能安全表达该操作 |
| `source_mismatch` | after_refresh | authenticated source 已变化 |
| `stale_authority` | after_refresh | owner/generation/turn 已变化 |
| `writer_lease_unavailable` | after_refresh | 非当前单写者 |
| `precondition_failed` | after_refresh | Goal/settings/queue facts 已变化 |
| `operation_conflict` | never | 同 operation ID 不同 digest |
| `operation_expired_or_unknown` | user_new_intent | 超过已公布幂等窗口或 tombstone 已清；旧 ID 不得再次执行 |
| `outcome_unknown` | same_intent_query | dispatch 已开始，禁止重发 |
| `queue_full` | user_new_intent | 队列达到上限 |
| `content_too_large` | user_new_intent | 超硬上限/需改用 payload plane |
| `interaction_expired` | never | request 已终止或 generation stale |
| `provider_rejected` | user_new_intent | provider 明确拒绝 |

UI 不得把 `outcome_unknown` 翻译成普通“发送失败，点按重试”；它必须先提供“刷新并检查结果”，再允许创建新的明确意图。

## 13. Send-chain 完成定义

发送链只有在以下 fault matrix 通过后才算完成：

- 每个 ledger transition 前后 kill Bridge；
- admission response、provider response、canonical observation 任一点断网；
- 同 operationId 同/不同 digest；
- provider 接受相同 clientMessageId 但创建重复 Turn 的真实 fixture；
- queue edit/cancel 与 dispatch race；
- source/runtime/authority/writer lease 在操作中途变化；
- approval/question 在 observe/claim/submitting/submitted 各阶段断线；
- Goal/settings/persisted child create 响应丢失后的 read-back/reconcile；
- new/old Mobile/Bridge 组合确保 live control 永不被 offline queue 回放。
