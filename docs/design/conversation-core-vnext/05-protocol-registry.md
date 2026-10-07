# 05. 协议消息注册表

本文给出 vNext 首版消息面的**冻结候选**；`protocol-registry.v1.json` 当前状态是
`draft_architecture_baseline`，并非 implementation-ready。Phase 0 必须为每一行生成完整 payload/error JSON Schema、
TypeScript/Dart 类型和正反 golden fixtures；
没有登记的 mutation 不得临时塞进 `websocket.ts` 或 generic command。字段的详细语义、authority 和状态机以
[01-domain-and-receive.md](01-domain-and-receive.md)、[02-wire-and-operations.md](02-wire-and-operations.md) 和
[03-feature-module-contract.md](03-feature-module-contract.md) 为准。

## 1. 标量与通用结构

| 类型 | 约束 |
|---|---|
| `OpaqueId` | UTF-8，1–256 bytes；不得 trim 后改变语义 |
| `OperationId` | vNext UUIDv7；时间部分仅用于幂等窗口拒绝，不用于排序/authority；legacy adapter 可映射旧 opaque ID |
| `FeatureId/MessageType` | ASCII lower snake/dot namespace，1–128 bytes |
| `UInt64` | JSON safe integer 范围；更大 provider 数值以 decimal string |
| `Sha256` | 64 lowercase hex |
| `OpaqueRevision` | 1–256 bytes，不排序、不做数值运算 |
| `BoundedString` | 上限来自 capability；超限明确拒绝，不静默截断 |
| `KnownOrUnknownEnum` | `{raw, known?}`；未知 raw 必须保留 |
| `PathCapabilityRef` | Bridge 签发的 opaque path scope；wire 不把任意 path 当授权 |

通用类型：`Envelope`、`SourceRefWire`、`ThreadRefWire`、`ThreadTargetWire`、`OperationHeader`、
`SyncFrameMeta`、`OperationError`、`TurnSpine`、`PayloadRef` 由前述规范定义。
registry 每条消息同时固定 `featureMajor + featureMinor`；major 改变 wire 语义，minor 只能 additive，并受握手范围协商。

### 1.1 Presence 与 clear

- optional 缺失表示“不提供/不修改”；`null` 只有 schema 明确赋予语义时可用。
- patch 使用 `{set: {...}, clear: [fieldName...]}`，同一字段不得同时 set/clear。
- 未知字段保留但不回写为 mutation；未知 enum 的 snapshot 可读，mutation 默认只读/fail closed。

### 1.2 标准终态

```text
MutationResult {
  operationId
  operationKind
  originClientId
  deliveryAudience: "origin_only"
  outcome: "confirmed" | "rejected" | "outcome_unknown" | "existing"
  currentRevision?: OpaqueRevision
  providerIds?: BoundedTypedMap
  error?: OperationError
}
```

mutation receipt/result 默认只发 origin client；共享状态变化通过对应 feature state/invalidation 另行发布。
`accepted/admitted` 不是 `confirmed`；`outcome_unknown` 不能翻译成可自动重试。

## 2. Core/authenticated connection

| request/event type | 必需 payload | 对应结果/行为 |
|---|---|---|
| `core.hello` | deviceId、clientInstanceId、build、protocol ranges、feature ranges | `core.welcome` 或连接关闭前 typed error |
| `core.welcome` | selected protocol、Bridge ID、authenticated sources、features、topology、trustLevel、limits | server-only |
| `core.capabilities.get` | requestId | `core.capabilities.snapshot` |
| `core.capabilities.snapshot` | source descriptors、feature capability、availability/reason/limits | server-only |
| `core.capabilities_changed` | content-free source/feature IDs | 客户端重新 get；不隐含 mutation 成功 |
| `core.error` | code、scope、safe details、request/operation correlation | 不携带 secret/raw provider body |

认证失败、协议 major 无交集可以关闭连接；单个 feature major 不匹配只能禁用该 feature，不能全局断链。

## 3. Catalog 与 timeline sync

| type | 必需 payload | 结果/事件 |
|---|---|---|
| `catalog.subscribe` | requestId、filters、knownRevision、checkpoint? | `sync.begin` → snapshot/patch → `sync.complete` |
| `timeline.subscribe` | requestId、ThreadRef、window、knownRevision、focus | 同上；长期 subscription |
| `timeline.focus` | subscriptionId、Thread/Turn target、focusGeneration | `timeline.focused` 或 error |
| `timeline.priority_watch.set` | source、bounded ThreadRef[]、watchGeneration、reason=`home_active` | foreground-only watch state |
| `timeline.page.read` | requestId、ThreadRef、locator、direction、limit、knownRevision | bounded batch/typed gap |
| `timeline.repair.request` | requestId、ThreadRef、gap IDs/turn IDs、knownRevision | repair batch/result |
| `sync.unsubscribe` | subscriptionId、subscription kind | catalog/timeline 通用 idempotent `sync.unsubscribed` |
| `sync.begin` | SyncFrameMeta、scope、window request | server-only |
| `catalog.snapshot` | meta、catalog revision、entries、completeness | staging |
| `catalog.patch` | meta、base revision、upserts/deletes、coverage | deletes 仅完整 scope |
| `timeline.turn_batch` | meta、ordered inline Spines/content descriptors、coverage | staging |
| `timeline.index_page` | meta、user/turn locators、coverage | 仅导航 shell |
| `timeline.latest_tail` | meta、verified tail、latestTurnGap? | 不 whole-window delete |
| `timeline.runtime_overlay` | meta、runtime/authority/turn fence、typed overlay | memory-only |
| `timeline.priority_watch.state` | accepted/rejected targets、watchGeneration、maxTargets | content-free response |
| `timeline.gap` | meta、reason、`GapDescriptor`、repairCursor（可为 null）、retry class | 保留 committed data |
| `sync.complete` | meta、windowComplete、latestTurnComplete、latestTurnGap（字段必存、可为 null）、checkpoint | commit/ready boundary |
| `sync.resync_required` | subscriptionId、exact scope、reason、expected revision | scoped resubscribe |
| `sync.ack` | subscriptionId、batchId、committedThroughSequence、contentRevision | SQLite committed ACK |
| `flow.ack` | subscriptionId、observedThroughSequence | transient flow control only |

`sync.begin/complete/resync_required/ack/flow.ack` 使用 union `SyncScope = SourceRef | ThreadRef`；catalog 不能使用 thread scope，
timeline 不能丢失 ThreadRef。`GapDescriptor` 是 `range(from, through?) | turns(non-empty TurnRef[])`；repair cursor 无法提供时
显式传 `null`。`latestTurnComplete=true` 当且仅当 `latestTurnGap=null`。一次 `sync.complete` 完成当前 batch，不关闭长期
subscription；真正终止由 `sync.unsubscribe`/disconnect。

## 4. Content download 与 input upload

| type | 必需 payload | policy |
|---|---|---|
| `content.offer` | offerId、object scope/kind、manifest/object digest、length、ETag、expiry、secret URL | server event |
| `content.receipt` | offerId、manifest digest、stored bytes、outcome | SQLite/content commit 后 |
| `content.cancel` | offerId、reason | live idempotent |
| `content.cancelled` | offerId、released bytes/lease state | terminal response |
| `content.repair.request` | object scope、expected digest、offset? | bounded read |
| `content.error` | offerId/object scope、typed code | 不泄漏 URL/token |
| `input_payload.prepare` | requestId、ThreadRef、payload digest/type/length | bounded admission |
| `input_payload.offer` | uploadId、secret URL、expiry、maxBytes、offset | 不触发 provider mutation |
| `input_payload.receipt` | uploadId、payloadId、verified/already/rejected | verified ref 才可用于 input |
| `input_payload.release` | uploadId/payloadId | orphan lease idempotent release |
| `input_payload.released` | uploadId/payloadId、outcome | terminal response |

所有 download/upload HTTP 请求重新校验 authenticated scope。显式 file browser/download 可以有自己的更高容量合同，
不能借用 conversation payload capability 绕过授权。

## 5. Operation query 与输入队列

| type | 必需 payload | policy/result |
|---|---|---|
| `operation.get` | requestId、module、operation kind/id、target | bounded read → `operation.state` |
| `operation.state` | operation identity、fingerprint hash、state、revision、safe result/error | server response/event |
| `operation.result` | MutationResult、target、result revision? | 所有 typed mutation 的通用外层终态；业务 payload 仍由各 feature schema 定义 |
| `turn.input.submit` | header、clientMessageId、InputPart[]、queuePolicy | durable queueable before dispatch |
| `turn.input.admitted` | operation/client IDs、originClientId、origin_only、direct/queued、persisted state、queue fields? | `input_intent` scope；sender-local persist-before-dispatch ACK |
| `queue.item_admitted` | operation/client/origin、queueItemId/revision/position | sender-local queue 第二阶段 |
| `turn.input.state` | operation/client/origin、delivery state、queueItemId?、providerTurnId?、reason? | `input_intent` scope；sender-local delivery event |
| `queue.read` | requestId、ThreadRef、knownRevision? | `queue.snapshot` |
| `queue.snapshot` | ThreadRef、queueRevision、ordered safe item summaries | no raw attachment bytes |
| `queue.changed` | ThreadRef、queueRevision | all authorized watchers 的 content-free invalidation |
| `queue.item.update` | header、queueItemId、expectedRevision、new content/digest | queued only |
| `queue.item.cancel` | header、queueItemId、expectedRevision | queued only |
| `queue.item.reorder` | header、queueItemId、before/after ID、expectedRevision | optional capability |
| `turn.steer.submit` | header、clientMessageId、content、expectedTurn/runtime/authority | live_fenced |
| `turn.stop.submit` | header、expectedTurn/runtime/authority | live_fenced |

`queue.item.*` 必须有 OperationHeader、originClientId、exact item、expectedQueueRevision 和 fingerprint；update/cancel 可走
专用 queue-mutation outbox，但只在重连后 authoritative snapshot 仍证明 item queued/revision 相同时提交。steer/stop 断线不 replay。
所有 sender receipt 都是 `origin_only`；跨设备只发布 `queue.changed` 和 canonical timeline。

## 6. Interaction 与 auto approval

| type | 必需 payload | policy/result |
|---|---|---|
| `interaction.watch` | requestId、ThreadRef/runtime fence、subscriptionId | live subscription |
| `interaction.unwatch` | subscriptionId | idempotent |
| `interaction.unwatched` | subscriptionId | terminal response |
| `interaction.snapshot` | active public request refs、broker health/lease | server-only；body 只限当前 live binding |
| `interaction.request` | InteractionRef、public ID、kind、safe presentation、expiry? | server event |
| `interaction.respond` | header、InteractionRef、claimantId、typed response | live_fenced |
| `interaction.result` | operationId、InteractionRef、outcome/error | server result |
| `interaction.expired` | InteractionRef、reason/generation | server event |
| `auto_approval.policy.get` | requestId、ThreadRef | bounded read |
| `auto_approval.policy.patch` | header、set/clear allowlist/policy、expected revision | reconcile-only |
| `auto_approval.policy.state` | ThreadRef、revision、policy、owner applicability | server state |
| `auto_approval.disable_all` | header、scope、expected revision | 独立 safety outbox；只收紧 policy，不回答 request |

`interaction.respond.response.kind` 的首版 union 是 approve/reject/answer/cancel；approve 可以有 typed
`updatedInput/updatedPermissions`。未知 interaction kind 可展示只读/update hint，不得用 approve fallback。

## 7. Goal、settings、Plan 与 core actions

| type | 必需 payload | policy/result |
|---|---|---|
| `thread.goal.get` | requestId、ThreadRef | bounded read → state |
| `thread.goal.set` | header、set/clear objective/status/tokenBudget、expected goal facts/revision | reconcile-only |
| `thread.goal.clear` | header、expected goal facts/revision | reconcile-only |
| `thread.goal.state` | GoalSnapshot 或 explicit absent、revision/change/operation sequence | server state |
| `thread.settings.get` | requestId、ThreadRef | bounded read |
| `thread.settings.patch` | header（durable ThreadRef only）、set/clear typed fields、expected revision、effectiveAt expectation | reconcile-only；禁止 runtime target |
| `thread.settings.state` | snapshot、revision、effectiveAt、unknown fields | server state |
| `thread.settings.invalidated` | ThreadRef、newRevision?、operationId? | content-free broadcast；客户端精确 get |
| `runtime.settings.patch` | header、RuntimeBinding/authority fence、typed patch、expected active facts | private/legacy live-fenced compatibility |
| `thread.compact.start` | header、runtimeSessionId、authorityGeneration、mode/provider options、idle/owner precondition | live-fenced typed core action；不离线 replay |
| `thread.compact.result` | MutationResult、provider item/marker anchor? | 不伪装 chat input |
| `thread.review.start` | header、typed review target/options | typed core action |
| `thread.review.result` | MutationResult、child/relation/provider turn? | server result |
| `thread.mcp_status.get` | requestId、ThreadRef/runtime target | bounded read |
| `thread.mcp_status.state` | typed server/tool status、revision/observedAt | read model |

Plan 不另设含糊的 `plan.toggle`：collaboration mode 走 settings；Plan item 走 timeline；ExitPlanMode 走 interaction；
编辑走 interaction updatedInput。

## 8. Thread lifecycle 与关系图

| type | 必需 payload | policy/result |
|---|---|---|
| `thread.start` | header/source、project capability、initial typed settings | reconcile-only |
| `thread.resume` | header、ThreadRef、desired runtime mode | reconcile-only/live attach by capability |
| `thread.fork` | header、parent ThreadRef、anchor Turn/Item、resolved settings | reconcile-only |
| `thread.rename` | header、ThreadRef、new title、expected catalog revision | reconcile-only |
| `thread.archive` / `thread.unarchive` | header、ThreadRef、expected lifecycle revision | reconcile-only |
| `thread.delete` | header、ThreadRef、expected lifecycle revision、confirmation token | destructive reconcile-only |
| `thread.edit_fork` | header、Codex ThreadRef、beforeTurnId/anchor、fork mode | `conversation_edit_fork_v1`；产生 child relation，禁用 deprecated rollback |
| `thread.rewind_files` | header、provider-specific ThreadRef/target item、affected-file preview digest、step-up confirmation | 独立 `rewind_files_v1` destructive capability |
| `thread.lifecycle.result` | MutationResult、ThreadRef/runtime binding/catalog revision | server result |
| `thread.relations.list` | requestId、parent/child ThreadRef、kind filters、cursor/limit | bounded read |
| `thread.relations.snapshot` | nodes/edges、revision、coverage | server read model |
| `thread.relation.changed` | edge upsert/delete、revision、provider proof | server event |

路径、标题和时间不参与 thread 定位。`thread.delete` 等 destructive 操作可以要求连接层 step-up token，但 token 不持久化。
Claude conversation rewind 必须使用 Claude 专属 feature/message schema；不存在跨 provider generic rewind fallback。

## 9. Side Chat

### 9.1 Persisted

| type | 必需 payload | policy/result |
|---|---|---|
| `side_chat.persisted.create` | header、parent ThreadRef、anchor?、initial settings/fork options | reconcile-only |
| `side_chat.persisted.result` | operationId、child ThreadRef、relation edge、MutationResult | 普通 Conversation Core 接管 child |

相同 operation/fingerprint 必须返回同一 child；响应丢失先查 operation/relation，不能再次 fork。

### 9.2 Official ephemeral

| type | 必需 payload | policy/result |
|---|---|---|
| `side_chat.ephemeral.open` | OperationHeader、parent ThreadRef、anchor?、registry generation | connection-scoped live-fenced mutation |
| `side_chat.ephemeral.opened` | ephemeral child ref、relation、source/registry generation | server result |
| `side_chat.ephemeral.list` | requestId、parent/source scope | bounded live registry read |
| `side_chat.ephemeral.snapshot` | current child refs/relations/generation | server result |
| `side_chat.ephemeral.input` | OperationHeader、child、registry generation、clientMessageId、InputPart[] | live-fenced；不进 durable input queue |
| `side_chat.ephemeral.close` | OperationHeader、exact child/source/registry generation | live-fenced mutation |

child input 只复用 `InputPart` value schema，不复用 `turn.input.submit` message/policy；interaction 复用本来就是 live-fenced 的
Interaction schema。两者都无 canonical storage，不能因为结构相似进入 durable queue。

### 9.3 Legacy compatibility

`side_chat_open/input/approve/reject/answer/interrupt/close` 等现有 frame 只存在于
`compat.side_chat_legacy_v1` adapter，不新增到 vNext registry。新端 fallback 时明确切换 controller/语义。

## 10. Subagents

| type | 必需 payload | policy/result |
|---|---|---|
| `subagents.list` | requestId、parent ThreadRef、cursor/limit、attached runtime fence? | bounded read |
| `subagents.list_result` | parent、child descriptors/edges、coverage/cursor、source revision | server result |
| `subagents.history` | requestId、parent/child ThreadRef、cursor/limit | bounded read |
| `subagents.history_result` | child TurnSpines、coverage/cursor、descendant proof | server result |
| `subagents.watch` | requestId、subscriptionId、parent ThreadRef、generation | live watch |
| `subagents.activity` | subscriptionId、child refs、activity/attention、generation/revision | content-free event |
| `subagents.unwatch` | subscriptionId | idempotent |
| `subagents.unwatched` | subscriptionId | terminal response |

detached 请求仍携带完整 authenticated parent/child source；read 不得隐式 resume/start/fork。unsupported 与 empty 是不同结果。

## 11. Artifacts、Mirror、insights 与 background

| type | 必需 payload | policy/result |
|---|---|---|
| `artifact.resolve` | requestId、PayloadRef/object scope、desired representation | bounded read |
| `artifact.resolved` | authenticated content offer/typed unavailable | server result |
| `file_browser.list` | requestId、PathCapabilityRef、cursor/limit | bounded read |
| `file_browser.read` | requestId、PathCapabilityRef、range/representation | bounded read/content offer |
| `mirror.subscribe` | requestId、ThreadRef、known generation/revision | accepted=`mirror.begin`；rebuildable subscription |
| `mirror.unsubscribe` | subscriptionId、ThreadRef | idempotent disconnect/stop watch |
| `mirror.unsubscribed` | subscriptionId、ThreadRef | terminal response |
| `mirror.begin` | MirrorFrameMeta、generation、baseRevision | batch accepted/start boundary |
| `mirror.snapshot/patch` | MirrorFrameMeta、generation/revision、coverage/changes | separate Mirror writer staging |
| `mirror.complete` | MirrorFrameMeta、generation、revision、coverage、checkpoint | atomic promote/ready boundary |
| `mirror.ack` | subscriptionId、batchId、committedThroughSequence、generation/revision | SQLite committed ACK |
| `mirror.status` | generation、state | memory-only；不推进 durable ACK |
| `insights.get` | requestId、ThreadRef、namespaces | bounded read |
| `insights.state` | provenance/confidence/revision/observedAt、typed metrics | server read model |
| `background.delivery_mode.set` | mode=`interactive|notifications_only`、connection generation | live connection control |
| `background.delivery_mode.state` | effective mode、connection generation | terminal/content-free response |
| `background.activity` | content-free ThreadRef hash/attention/status confidence | notifications-only event |

`MirrorFrameMeta` 的 `sequence` 在一个 subscription/generation 内严格递增；duplicate/gap/baseRevision 处理与
`SyncFrameMeta` 相同，但 Mirror 使用自己的 writer、checkpoint 与 `mirror.ack`，不能借用 timeline 的
`windowComplete/latestTurnGap` 语义。`mirror.complete` 只完成当前 batch，subscription 持续到 unsubscribe/disconnect。

## 12. Diagnostics 与 topology

| type | 必需 payload | policy/result |
|---|---|---|
| `diagnostic.capture.prepare` | requestId、scope、time window、redaction profile | explicit user action |
| `diagnostic.capture.summary` | captureId、included layers、redacted size/hash | 用户确认前不上传 |
| `diagnostic.capture.upload` | operationId、captureId、authenticated transfer receipt expectation | reconcile-only transfer |
| `diagnostic.capture.receipt` | operationId、archive digest、stored/rejected、retention | server result |
| `projection_lab.snapshot` | requestId、hashed target、layer milestones | local/debug bounded read |
| `topology.get` | requestId | bounded read |
| `topology.state` | private/daemon/read-only、owner/lease/capability health、no secrets | read-only |

enable/restart/restore shared daemon **不属于** conversation wire 首版；它是需要用户明确授权、独立审计与 rollback 的
运维协议，不能由 Mobile 收到 topology state 后自动执行。

## 13. 未知消息与旧 Bridge 错误

1. 已协商 feature 中的未知 server event：保留 envelope/type 到 bounded diagnostic，若 manifest 标 optional 则忽略；
   若影响 mutation/authority/completeness，进入 feature `update_required/degraded`，不能继续猜。
2. 未协商 feature 的事件：忽略正文并记录 content-free anomaly。
3. 客户端发送未知 request：Bridge 返回 `unsupported_message`，包含原 type 和 feature hint，不广播普通 chat error。
4. request-specific generic error 必须通过 `requestId + featureId + request type` 路由到对应 controller，不能污染 timeline。
5. future enum/item：read path 保留 raw；write path 默认 fail closed，直到新 schema/feature minor 明确支持。

## 14. Schema 完整性门禁

CI 必须同时运行 `node scripts/validate-protocol-registry.mjs` 与 Phase 0 的完整 per-payload JSON Schema validator；两者是
互补门禁，任何一个都不能替代另一个。Draft 2020-12 的单个 registry schema 不能表达跨数组全局唯一/引用完整性，
因此由脚本检查：

- 每个 request 有 terminal result/error；
- 每个 mutation 有 operation kind/policy/fingerprint/precondition/reconcile；
- 每个 event 有 feature/version/target/generation/unknown policy；
- 每个 subscription 有 unsubscribe、disconnect cleanup、sequence/ACK semantics；
- 每个 content message 有 auth scope/limit/digest/expiry；
- TS/Dart union 覆盖率与 JSON Schema type 枚举完全一致；
- 文档表、manifest、schema、handler registry 和测试 fixture 没有孤儿/缺项。

此门禁通过之前不得开始 feature 业务实现；后续增加消息必须修改 registry、schema、双端类型、compat matrix 和 fault tests，
不能只在一端添加 `case`。
