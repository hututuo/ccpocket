# 03. Feature Module Contract 与 Codex 功能接入

## 1. 目标

“预留接口”不等于在核心类型里增加几十个 nullable 字段。真正的扩展点必须同时约束：

- 功能依赖什么身份和 authority；
- 请求/事件的 schema 与版本；
- 哪个模块拥有状态和存储；
- 是否持久、是否可排队、是否可重放；
- 断线/source switch/owner change 后如何处理；
- 在哪些 UI surface 出现；
- 旧 Mobile/Bridge/provider 不支持时如何降级；
- 容量、隐私和诊断边界。

未来功能只要无法完整填写本合同，就不得接入 root WebSocket、timeline 或会话 Cubit。

## 2. Feature Manifest

### 2.1 规范结构

```text
FeatureManifest {
  featureId: ReverseDnsLikeId
  protocol: { major: UInt16, minor: UInt16 }
  domainVersion: UInt16
  targetKinds: TargetKind[]
  dependencies: FeatureDependency[]
  providerRequirements: ProviderCapabilityRequirement[]

  messages: {
    clientRequests: MessageContract[]
    serverEvents: MessageContract[]
  }

  stateNamespaces: StateNamespaceContract[]
  operations: OperationContract[]
  authority: AuthorityContract
  lifecycle: LifecycleContract
  limits: LimitContract
  diagnostics: DiagnosticContract
  compatibility: CompatibilityContract
  uiSurfaces: UiSurfaceContract[]
  nativeHostRequirements: string[]
}

OperationContract {
  operationKind: string
  deliveryPolicy:
    "durable_queueable_before_dispatch" |
    "durable_reconcile_only" |
    "live_fenced" |
    "bounded_read"
  idempotencyScope: string[]
  fingerprintFields: string[]
  preconditions: string[]
  reconciliationRead?: string
}
```

### 2.2 Registry 启动校验

Bridge 和 Mobile 的 registry MUST 在启动/测试时拒绝：

- 重复 `featureId + major` 或重复 message type；
- 未满足或循环 dependencies；
- 两个模块声明同一 state/storage namespace 的 sole writer；
- mutation 未声明 delivery policy/fingerprint；
- live-fenced 操作缺 `ThreadRef/authorityGeneration`；
- durable 操作没有 operation query/reconcile 合同；
- UI surface ID 冲突；
- manifest 的 schema 未生成 TS/Dart 类型或缺 golden vector；
- capability 声明与实际 handler 不一致。

### 2.3 Host 提供的依赖

Feature 只能通过显式 service interface 使用核心能力：

```text
FeatureContext {
  identities: IdentityService
  providers: ProviderGateway
  canonicalReader: CanonicalProjectionReader
  liveHub: LiveObservationHub
  operations: OperationKernel
  interactions: InteractionBroker
  relations: RelationGraphService
  threadState: ThreadStateHost
  content: ContentService
  diagnostics: DiagnosticSink
  client: AuthenticatedClientContext
  abortSignal: AbortSignal
}
```

禁止 feature 直接持有全局 WebSocket、任意 `SessionManager` map、SQLite connection 或另一个 feature 的私有对象。
需要跨模块行为时依赖公开 interface/event，不访问目录内部文件。

### 2.4 当前 capability 到 vNext feature 的显式映射

vNext `featureId` 是领域/协议 namespace；下列当前 `_v1/_v2` 字符串是 compatibility adapter 必须精确识别的 wire
capability，不能靠去掉版本后缀或模糊包含关系匹配。

| vNext featureId | 当前 capability/message identity |
|---|---|
| `ccpocket.conversation.sync` | `conversation_sync_v2`, `conversation_sync_window_coverage_v1`, `conversation_sync_focus_refresh_v1`, `conversation_items_by_id_v1`, `conversation_user_index_v1`, `conversation_runtime_overlay_v1`, `app_server_status_v1` |
| `ccpocket.identity` | `bridge_identity_v2`, `codex_home_identity_v1` |
| `ccpocket.conversation.content` | `conversation_content_event_v1` |
| `ccpocket.conversation.mirror` | `conversation_mirror_entry_chunk_v1`, `conversation_mirror_source_identity_v1`, `conversation_mirror_event_v1` |
| `ccpocket.turn.input_queue` | `codex_multi_input_queue_v1` + legacy `update_queued_input/cancel_queued_input/steer_queued_input` |
| `ccpocket.interactions` | `codex_action_broker_v1`；private legacy approve/reject/answer 仅 adapter |
| `ccpocket.auto_approval` | `auto_approval_state_v1`, `auto_approval_supervision_state_v1` |
| `ccpocket.thread.settings` | `codex_durable_thread_settings_v1`, `codex_permission_apply_strategy_v1` |
| `ccpocket.thread.goals` | `codex_durable_thread_goals_v1` |
| `ccpocket.thread.lifecycle` | `codex_session_lifecycle_v1`, `codex_runtime_detach_v1`, `codex_resume_preserves_settings_v1` |
| `ccpocket.thread.relations` | 当前无单独 capability；由 lifecycle fork、`persisted_side_chat_v1`、`ephemeral_side_chat_v1`、subagent provider evidence 精确投影 |
| `ccpocket.side_chat.persisted` | **精确** `persisted_side_chat_v1` |
| `ccpocket.side_chat.ephemeral` | `ephemeral_side_chat_v1`, `ephemeral_side_chat_parent_identity_v1` |
| `ccpocket.side_chat.legacy` | legacy `open_side_chat/side_chat_*` messages；无新 capability |
| `ccpocket.subagents` | `detached_subagents_read_v1`, `subagent_activity_summary_v1` |
| `ccpocket.thread.core_actions` | `codex_core_actions` request/result family |
| `ccpocket.file_browser` | `file_browser_v1`, `file_browser_project_preview_v1` |
| `ccpocket.session_insights` | `durable_session_insights_v1`, `scoped_context_usage_v1` |
| `ccpocket.desktop_continuity` | `codex_desktop_continuity_v1`, `codex_desktop_continuity_event_v1` |

compatibility adapter 只负责精确双向映射和降级，不成为 feature state owner。新 manifest/schema 的 major 变化也不能
悄悄复用旧 `_v1` capability 字符串。

## 3. 生命周期

每个模块按需要声明以下 hook；未声明即不接收：

```text
onAuthenticatedConnection
onCapabilitiesChanged
onSourceActivated / onSourceInvalidated
onRuntimeBound / onRuntimeAuthorityChanged / onRuntimeExited
onProviderObservation
onCanonicalProjectionCommitted
onThreadCatalogChanged
onDeliveryModeChanged
onBackgroundDemandChanged
onClientDisconnected
onShutdown
```

所有异步 request/watch 必须绑定 client/source generation 的 `AbortSignal`。disconnect、source switch、target change
和 module disable 都取消操作。模块不能在被取消后向新 connection 发布旧结果。

## 4. UI Surface Contract

Mobile 保留并扩展现有 Local Session Feature Host，统一支持：

| surface | 用途 |
|---|---|
| `app_bar_action` | Goal、child、compact、terminal 等小入口 |
| `overflow_action` | 低频 thread action |
| `status_bar` | owner、Goal、queue、degraded 状态 |
| `composer_mode` | Plan/default、queue/steer 模式 |
| `composer_attachment` | image/file/artifact admission |
| `timeline_decoration` | typed local divider/operation state；不能伪装 provider item |
| `interaction_frame` | approval/question/elicitation |
| `primary_pane` | 普通 conversation screen |
| `related_pane` | persisted/ephemeral Side Chat、subagent browser |
| `floating_dock` | child/subagent activity |
| `session_list_badge` | Goal/attention/child relation 等 content-free 信息 |
| `settings_section` | provider/thread/app setting 的专属编辑器 |
| `debug_projection` | Projection Lab，只读 |

Surface 接收 Repository/feature controller 的 view model，不直接订阅 raw Bridge frame。

## 5. Thread Relation Graph

### 5.1 数据模型

```text
ThreadNode {
  thread: ThreadRef
  durability: "materialized" | "ephemeral" | "unknown"
  catalogVisibility: "primary" | "related_only" | "hidden_internal"
  lifecycle: "active" | "closed" | "expired" | "unavailable"
}

ThreadEdge {
  relationId: OpaqueId
  kind:
    "forked_from" |
    "persisted_side_chat_of" |
    "ephemeral_side_chat_of" |
    "subagent_of" |
    "review_of" |
    FutureKind
  parent: ThreadRef
  child: ThreadRef
  anchorTurnId?: OpaqueId
  anchorItemId?: OpaqueId
  providerRelationId?: OpaqueId
  createdByOperationId?: OpaqueId
  sourceRevision?: OpaqueRevision
}
```

关系只来自 provider fork/subagent evidence 或成功的 typed create result；不得根据标题、cwd、创建时间或文本相似度推断。
child transcript 保持在 child ThreadRef 下，parent 只保存 edge/summary，不复制内容。

### 5.2 生命周期与继承

- Goal 不隐式继承给 child；只有 provider 明确复制时才显示 child 自己的 Goal snapshot。
- settings 在 create/fork 时可按 provider 规则形成一次 resolved snapshot，之后 parent/child 独立 revision。
- parent 删除/归档不自动删除 child，除非 provider 明确提供且用户执行 typed cascade operation。
- shared worktree/file effects 与 conversation relation 是不同事实；Side Chat 关闭不回滚文件修改。

## 6. 功能模块规范

### 6.1 `ccpocket.conversation.sync`

- **职责**：catalog/status/timeline subscription、coverage、checkpoint、v2/vNext projection。
- **状态所有者**：Bridge sync session；Mobile SyncService/SQLite writer。
- **写入**：只消费 canonical commit/live overlay，不自行读 provider 业务状态。
- **兼容**：v2 与 vNext adapter 并存，使用同一 normalized batch。
- **禁止**：接收 Goal/settings/interaction/Side Chat 私有消息。

### 6.2 `ccpocket.turn.input_queue`

- **职责**：普通新 Turn admission、Bridge FIFO、edit/cancel、delivery reconcile。
- **policy**：`turn_input` 在 dispatch 前 durable queueable；dispatch 后 reconcile-only。
- **identity**：`ThreadRef + clientMessageId`，另有 operationId 和 payload digest。
- **限制**：默认每 thread 16 条；一次 ready dispatch 一条。
- **禁止**：承载 steer/stop/approval/question/Goal/settings/compact。

### 6.3 `ccpocket.interactions`

- **职责**：tool approval、AskUserQuestion、MCP elicitation、ExitPlanMode 的 observe/claim/respond/result。
- **policy**：`live_fenced`；identity-only durable ledger，敏感 body memory-only。
- **authority**：exact source/thread/turn/request/generation + writer lease。
- **兼容**：private legacy active runtime adapter；daemon/shared 缺 broker 时 update hint/fail closed。
- **禁止**：断线 replay、跨 owner 自动审批。

### 6.4 `ccpocket.auto_approval`

- **职责**：仅对 Bridge-owned request 应用 durable thread allowlist/one-shot policy。
- **状态**：thread-scoped policy，与 app 全局 emergency disable 分开。
- **authority**：必须先由 Interaction Broker 确认 Bridge 是 execution owner。
- **兼容**：新 Mobile + 旧 Bridge 显示 unavailable；旧 Mobile + 新 Bridge 保留旧 live-only 行为。
- **安全例外**：`Disable all` MAY 使用独立、source-scoped、last-write-wins 的 safety outbox；它只收紧 Bridge policy，
  不回答任何 request、不调用 provider，也不能复用普通 input/offline command queue。
- **禁止**：回答 Desktop-owned request、离线排队普通 approval answer。

### 6.5 `ccpocket.thread.settings`

线程设置采用 namespaced typed document：

```text
ThreadSettingsSnapshot {
  thread: ThreadRef
  revision: OpaqueRevision
  values: {
    model?: string
    reasoningEffort?: KnownOrUnknownEnum
    serviceTier?: KnownOrUnknownEnum
    collaborationMode?: "default" | "plan" | FutureValue
    sandboxPolicy?: TypedSandboxPolicy
    approvalPolicy?: TypedApprovalPolicy
    reviewer?: KnownOrUnknownEnum
    personality?: string
    writableRoots?: PathCapabilityRef[]
    providerExtensions?: BoundedTypedMap
  }
  effectiveAt: "current_idle" | "next_turn" | "provider_defined"
}
```

- **policy**：get 是 bounded read；patch 是 `durable_reconcile_only`。
- **target**：vNext durable patch 只接受 exact ThreadRef，MUST NOT 混入 runtimeSessionId/authorityGeneration；它通过 shared writer
  lease 更新后续 Turn 设置，不 attach/resume thread。
- **legacy attached**：private/旧 provider 设置由单独 `runtime.settings.patch` adapter 承担，policy=`live_fenced`，必须 exact
  runtime/authority；不能把它伪装成 durable-thread 成功。
- **precondition**：expected revision + writer lease + writable/idle policy。
- **事件**：durable mutation 只发布 origin-only operation result + content-free `thread.settings.invalidated`；客户端随后精确 get
  snapshot。不扫描 catalog/history，不写 timeline。
- **未知值**：显示只读并保留 raw enum，不把新值回退成 default。
- **App 偏好**：字体、主题、通知等不属于 ThreadSettings，继续由本地 Settings 模块拥有。

### 6.6 Plan 的四种语义

| 名称 | 所属模块 | 存储/协议 |
|---|---|---|
| Plan collaboration mode | thread settings | durable setting，影响下一 Turn |
| Plan/UpdatePlan item | canonical timeline | provider item，经 TurnSpine 投影 |
| ExitPlanMode request | interactions | live approval/request |
| edited plan/allowed prompts | interaction response | typed updatedInput/permissions |

`/plan` 可以是 Mobile 本地 UI intent，用于打开设置或切换 collaboration mode；它不应以普通 chat text 创建 Turn。
Plan item 的 completed 状态不能反向修改 settings，除非 provider 同时返回 settings snapshot。

### 6.7 `ccpocket.thread.goals`

```text
GoalSnapshot {
  thread: ThreadRef
  objective: string
  status: active | paused | blocked | usageLimited | budgetLimited | complete | FutureValue
  tokenBudget?: UInt64
  tokensUsed: UInt64
  timeUsedSeconds: UInt64
  createdAt: Timestamp
  updatedAt: Timestamp
  operationSequence?: UInt64
  revision: OpaqueRevision
}
```

- **语义**：每 materialized thread 一个 provider Goal；`complete` 与 `clear` 不同。
- **policy**：get bounded read；set/clear `durable_reconcile_only`，客户端 transport 必须在线且不进 offline outbox。
- **precondition**：operationId、expected presence/objective/status/budget/createdAt/revision；usage/time 自增不作为编辑冲突。
- **authority**：official Goal RPC、source/thread serialize、writer lease；不需要 resume thread。
- **限制**：ephemeral thread 不支持 Goal；未知 status 只读。
- **兼容**：旧 Bridge 只在 active runtime 能力存在时走 legacy route，否则明确 unsupported。
- **禁止**：把 Goal 写成 user/assistant message、与 Plan 共用状态、断线自动 replay。

### 6.8 `ccpocket.side_chat.persisted`

- **产品默认**：从 parent official thread 创建 materialized child，复用普通 Conversation Core screen。
- **关系**：`persisted_side_chat_of`，记录 parent、child、anchor、provider fork proof。
- **create policy**：`durable_reconcile_only`，key 至少为 parent ThreadRef + operationId，fingerprint 包含 anchor/settings。
- **防重复**：provider dispatch 前持久化；响应丢失后先按 operation/provider relation 对账，不能直接再次 fork。
- **child 功能**：作为普通 durable thread，可按自身 capability 使用 Goal、settings、queue、artifacts。
- **兼容**：Bridge 缺精确 `persisted_side_chat_v1` capability 时才允许显式 fallback legacy；UI 必须标明语义不同。

### 6.9 `ccpocket.side_chat.ephemeral`

- **语义**：official `thread/fork {ephemeral:true}`；只用于短期 related pane。
- **关系**：`ephemeral_side_chat_of`，registry 绑定 authenticated Bridge/source。
- **存储**：Bridge memory-only live registry；Mobile memory-only transcript/overlay。
- **policy**：open/close/input/interaction 全 live-only；open/close/input 仍带 connection-scoped operationId/fingerprint，
  只用于当前 source/registry generation 去重，断线后不 replay。list 是 bounded read。
- **input**：使用独立 `side_chat.ephemeral.input`（复用 `InputPart` 数据结构但 policy 固定 live-fenced），不能复用
  durable `turn.input.submit` message type。
- **限制**：不进 primary catalog、Turn Store、Mirror、SQLite canonical、Goal 或 offline queue。
- **关闭**：只关闭对话运行时，不撤销共享 worktree 文件副作用。

### 6.10 `ccpocket.side_chat.legacy`

- owner-scoped dedicated process，独立 transcript/permission/question maps。
- 仅兼容旧 Mobile/Bridge；现有限流、断线失败和内存队列语义保持。
- 不接新 Goal/settings/subagent/Turn Bundle 能力，不作为 persisted/ephemeral 的实现基础。
- 退役必须另有 capability adoption 与真实旧端门禁；本次架构不删除它。

### 6.11 `ccpocket.subagents`

- **职责**：parent-scoped list/history/activity watch，attached 或 detached read-only。
- **identity**：parent ThreadRef + child provider thread/item relation；detached 请求必须含 authenticated source/thread。
- **历史**：复用统一 bounded `TurnReader/TurnSpine`，但写入 child-scoped query cache，不写 parent timeline。
- **catalog**：internal subagent 默认 `hidden_internal/related_only`，不进 primary session catalog。
- **watch**：client/source/generation scoped memory subscription；disconnect/target change 即取消。
- **authority**：读取绝不 resume/start/fork/抢 owner；未知 descendant/mismatch fail closed。
- **compat**：缺 capability 就隐藏 panel/返回 unsupported，不伪造空列表为“没有 subagent”。

### 6.12 `ccpocket.thread.lifecycle`

包含 start、resume、fork、rename、archive、unarchive、delete 等独立 typed operation；“rewind”不作为跨 provider
generic operation：

- destructive mutation 必须 exact ThreadRef/source、operationId、expected lifecycle revision 和 provider-specific precondition；
- fork 成功写 relation edge，不复制 parent timeline 到新身份；
- rename 只改 catalog presentation，不改身份；
- archive/unarchive/delete 不靠 path/title 定位；
- Codex 会话编辑使用 `conversation_edit_fork_v1`：调用官方 `thread/fork(beforeTurnId/anchor)` 产生新 child/lineage，
  不调用 deprecated `thread/rollback`；provider 不支持精确 anchor 时 fail closed；
- `rewind_files_v1` 是独立 destructive file mutation，需要精确 provider item、受影响文件预览、step-up/用户确认；
- Claude rewind 由 Claude adapter 的独立 manifest/schema 定义，不借用 Codex beforeTurnId，也不伪装成上述 capability；
- 旧无 source route 只保留现有 best-effort 兼容，不能降低新 source-aware 操作校验。

### 6.13 `ccpocket.thread.core_actions`

- manual compact：typed `thread.compact.start`，policy=`live_fenced`，必须 exact runtime/authority/idle owner，永不离线 replay，
  不是 user input；durable thread 未挂接时先执行独立 attachment operation，确认后只发一次 compact。结果可产生 provider
  compact item，或锚定 exact turn 的 typed local decoration `manual_context_compacted`。
- automatic compact：provider process item，进入 TurnSpine；不能被 summary fallback 吞掉。
- review：typed provider action，若产生 child/review thread则写 `review_of` edge。
- MCP status/list：bounded read，不写 timeline。
- 任何 action 均声明 owner、idle/turn precondition、operation policy 与 compatibility。

### 6.14 `ccpocket.artifacts`

- 统一 image/file/diff/artifact `PayloadRef`、authenticated admission、preview、Range 和 content limits。
- 原始 base64 不通过普通 conversation frame。
- file browser 是独立 read capability；打开文件不改变 timeline。
- artifact URL/transfer token 不是持久数据，不进诊断。
- 大 tool result 与 artifact 可 lazy，但 TurnSpine 必须保留类型、digest、availability 和 omission reason。

### 6.15 `ccpocket.conversation.mirror`

- 可选完整离线投影，独立 generation/staging/atomic promote。
- key 使用完整 SourceRef + ThreadRef。
- 只能读取 canonical commits，不参与 live merge、发送或 provider 写回。
- normal hot-window 和 Mirror 可共享 immutable TurnSpine schema/content blob，但不能有两个 item writer。
- Mirror 使用独立 `mirror.begin → mirror.snapshot/patch → mirror.complete → mirror.ack` 批次合同；每个 durable frame
  携带 `MirrorFrameMeta(subscriptionId, batchId, sequence, generation, revision/baseRevision)`，Mobile 原子提交后才 ACK。
  `mirror.status` 是 memory-only 状态，不推进 durable ACK。一次 complete 只结束当前批次，不关闭 subscription；
  `mirror.unsubscribe`、disconnect 或 source epoch 变化才结束 watch。

### 6.16 `ccpocket.session_insights`

- usage、token/cost、context-window、activity summary 是派生读模型。
- 每项标 provenance、observedAt、confidence/revision；不能反向改 Goal、status 或 timeline。
- 未支持或过期显示 unknown/degraded，不能用 0 代替未知。

### 6.17 `ccpocket.desktop_continuity`

- shared/private topology、Desktop continuity、owner/status 通过 feature capability 暴露。
- Control Center 默认只读 topology/health；enable/restart/restore shared 是另行授权的运维操作，不由 conversation
  feature 自动执行。
- shared mutation 必须 known version/schema/socket/owner/writer lease；Bridge 不默认拥有 daemon 生命周期。

### 6.18 `ccpocket.background_delivery`

- `interactive` 可运行正常 subscription；`notifications_only` 只传 content-free activity/attention。
- 前台 Home 可维护每 source 有界 `home_active_priority` watch set，接收 running/attention 会话的 bounded live core；它与
  focused conversation watch 分开，有独立 generation/limit，且不把 overlay 当 canonical。
- 不在后台为全部 P1/COLD session 自动下载完整 Turn Bundle。
- 允许对已经 active-watch 的一个最新 Turn 做有界 finalization，受字节/电量/网络 budget 控制。
- 回前台从 SQLite checkpoint catch-up；missing watch/first full snapshot 不承诺后台完成。

### 6.19 `ccpocket.diagnostics`

- 常驻 ring 默认 hash/ID/state/sequence/revision，不保存 title/path/body/token/URL/raw frame。
- 用户显式 capture 才组装跨层 Projection Lab；上传走现有认证文件传输与幂等 receipt。
- 每个 feature 声明可公开的 state transition 和 redaction；模块不得自行写无界 JSONL。
- UI visible receipt 只在前台采样，不能替代 SQLite/provider/物理设备验收。

## 7. 当前源码迁移矩阵

| 当前路径 | 目标 | 动作 |
|---|---|---|
| `local-features/registry.ts`, `controller.ts`, `runtime.ts` | Feature Host | 保留并增加 manifest/dependency/policy 校验 |
| `local-features/protocol-slot.ts` 与 Mobile `protocol_host.dart` | Protocol Slot Host | 保留，改为 schema 生成的 tagged union |
| `conversation-sync-v2.ts` | canonical/live/sync adapters | 拆内部职责但保留行为与 v2 adapter |
| `input-delivery-ledger.ts` | Operation Kernel/input queue | 迁移状态；删除 dispatch 后自动 replay 语义 |
| `codex-action-broker*.ts` | Interaction Broker Codex adapter | 保留 ledger/lease，统一 legacy/private adapter |
| `codex-goal-controller.ts` + `websocket.ts` Goal 分支 | Goals module | 抽出 root；保留串行、compare、operation semantics |
| `websocket.ts` settings 分支 | Thread Settings module | 抽出 exact target/lease/precondition |
| `side-chat.ts` | Legacy Side Chat adapter | 兼容冻结，不新增核心功能 |
| `persisted-side-chat.ts` | Persisted child module | 补 durable create ledger/relation edge |
| `ephemeral-side-chat.ts` | Ephemeral child module | 保持 memory-only/exact source scope |
| `subagents.ts` | Subagent query/relation module | 复用 bounded reader，独立 main timeline |
| Mobile `ChatSessionCubit` Goal/settings/Plan/interaction 分支 | 独立 controllers | Cubit 只组合 view state |
| Mobile `SideChatController`, `SubagentsController` | feature controllers | 保留独立生命周期并接统一 identity/manifest |
| Mirror/content/file transfer | Content/Mirror services | 复用现有 auth/atomic store，不造平行 upload |

## 8. 新功能接入 checklist

新增任何 Codex/provider 功能必须在 PR 中同时提供：

1. Feature Manifest 与 owner；
2. provider capability probe/unsupported fixture；
3. 完整 request/event/error JSON Schema；
4. TS/Dart generated types 与 golden vectors；
5. target/identity/authority/precondition；
6. delivery/replay policy 与 operation fingerprint；
7. storage namespace/sole writer/retention；
8. disconnect/source/owner/background lifecycle；
9. old/new compatibility 行为；
10. UI surface 与 unknown/degraded 状态；
11. capacity/privacy/diagnostic redaction；
12. unit、full-chain、fault-injection 和真实 UI 验收计划。

缺任一项时，registry 不得启用该 capability；不能先把消息接进根 handler 再“以后补协议”。
