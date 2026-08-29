# 状态机与语义轴

状态：`ROOT_DECISION / DESIGN_ONLY / MACHINE_BINDING_PENDING`

本文冻结“哪个值属于哪台状态机”。最终枚举由 contract registry 生成；解释稿、TS/Dart、DDL CHECK、UI reducer 和 fault vectors 必须引用同一 machine ID。禁止把多个轴压成一个 `status` 字符串。

## 1. 正交语义轴

| Axis | 唯一 owner | 回答的问题 | 不能推断 |
|---|---|---|---|
| `sourceAuthority` | authenticated transport + SourceRegistry | 这条连接可读写哪个 SourcePartition | route online 不等于 source verified |
| `catalogFact` | ConversationCatalog | thread 是否被当前 verified catalog 观察 | missing/partial 不等于 deleted |
| `timelineFact` | CanonicalTimeline | 哪些 turn/item/order/coverage 已被 durable evidence 证明 | live/operation receipt 不等于 history |
| `liveObservation` | LiveOverlay | 当前 runtime 正在观察什么 | terminal/live text 不等于 canonical |
| `operationLifecycle` | OperationKernel | 一次用户 mutation 是否 admitted/dispatch/observed | Interaction/Relation 不继承 OUTCOME_UNKNOWN |
| `dispatchAttempt` | OperationKernel | Provider call permission 是否发出以及结果是否确定 | PREPARED 不等于 CALL_STARTED |
| `reconcileResolution` | OperationKernel | 对 immutable unknown terminal 后来证明了什么 | 不重开原 operation |
| `interaction` / `claim` | InteractionBroker | request 是否 open、谁持有 lease、是否 resolved | response operation unknown 不等于 interaction resolved |
| `threadState` | ThreadState | settings/Goal 的 Provider-backed snapshot | UI selection/Plan item 不是 authority |
| `relation` | RelationGraph | parent/child edge 是否已证明 | create operation receipt 不等于 child proof |
| `syncApply` | SyncProjection / ReplicaApplyCoordinator | durable publication 是否已事务应用并 ACK | frame received 不等于 applied |
| `availability` | Capability registry + feature owner | 能力是否 supported/currently available | unsupported 不等于 runtime temporary unavailable |
| `presentation` | focused controllers/UI | 用户当前看到的组合结果 | 不写回任何 domain state |

## 2. Source binding `SM-SOURCE`

```text
UNBOUND
  -> TRANSPORT_CONNECTED
  -> AUTHENTICATED
  -> SOURCE_ASSERTED
  -> SOURCE_VERIFIED
  -> REPLICA_BOUND
  -> APPLICATION_READY
```

异常/旁路状态：`AUTH_FAILED`、`IDENTITY_MISMATCH`、`SOURCE_MISMATCH`、`REVOKED`、`OFFLINE_LAST_GOOD`。只有 `SOURCE_VERIFIED` 以后可发 source-scoped read；只有 `APPLICATION_READY` 且 capability/actor 满足时可 admit mutation。旧 partition 可显示 `OFFLINE_LAST_GOOD`，但不能在新 socket 下自动 writable。

任何 reconnect 生成新 connectionEpoch；source switch 生成新 sourceEpoch。旧 epoch work 只能 `DROPPED_STALE_FENCE`，不得回到当前 machine。

## 3. Read/candidate/head

### 3.1 Read attempt `SM-READ-ATTEMPT`

```text
CREATED -> READING -> VERIFYING -> VERIFIED -> COMMITTED
     \        \          \          \
      FAILED   FAILED     REJECTED    CAS_CONFLICT
                           QUARANTINED
```

只有 `COMMITTED` 产生可见 head/PostCommitEvent。`FAILED/REJECTED/QUARANTINED/CAS_CONFLICT` 保留 last-good，不发布 candidate body。

### 3.2 Catalog head `SM-CATALOG-HEAD`

`ABSENT -> ACTIVE_COMPLETE | ACTIVE_PARTIAL | DEGRADED_LAST_GOOD -> SUPERSEDED`。只有 Provider 对完整查询范围证明 empty 时可 `EMPTY_PROVEN`。catalog missing row 的语义是 `NOT_OBSERVED_IN_THIS_COVERAGE`，除非 Provider lifecycle readback 单独证明 delete/archive。

### 3.3 Timeline head `SM-TIMELINE-HEAD`

`ABSENT -> ACTIVE -> DEGRADED_LAST_GOOD -> SUPERSEDED | TOMBSTONED_PROVEN`。每个 active head 绑定 readSpecDigest、coverage islands、Gap、manifest digest 和 CAS version。失败从不产生倒退 transition。

### 3.4 Gap `SM-GAP`

`OPEN -> REPAIR_REQUESTED -> CLOSED_PROVEN | REPAIR_FAILED | UNREPAIRABLE | STALE`。Gap 是 coverage state，不是 timeline item。`REPAIR_FAILED` 仍保留 Gap；新 head 使旧 repair token `STALE`。

## 4. Live overlay `SM-LIVE`

```text
OBSERVED -> ANCHORED -> DISPLAYED -> PROMOTED -> RETIRED
    |          |            |
    -> UNANCHORED_ACTIVITY   -> CONFLICT_REPAIR_REQUIRED
    -> DROPPED_STALE_FENCE / DROPPED_CAPACITY / EXPIRED / LOST_ON_RESTART
```

`PROMOTED` 只表示 canonical commit 后 exact strong identity 对应的 overlay 被 UI 原位替换；promotion 本身不写 canonical。unknown identity 只能 `UNANCHORED_ACTIVITY`，不能靠文本/时间晋升。

## 5. Operation 的四台状态机

### 5.1 Admission/lifecycle `SM-OPERATION`

```text
RECEIVED
  -> REJECTED_BEFORE_ADMISSION
  -> ADMITTED
       -> QUEUED | BLOCKED_PRECONDITION | READY
READY  -> DISPATCHING
DISPATCHING -> PROVIDER_ACCEPTED | FAILED_DEFINITIVE | OUTCOME_UNKNOWN
PROVIDER_ACCEPTED -> AWAITING_EFFECT_OBSERVATION
AWAITING_EFFECT_OBSERVATION -> SUCCEEDED | FAILED_DEFINITIVE
ADMITTED|QUEUED|BLOCKED_PRECONDITION|READY -> CANCELLED_PRE_DISPATCH
```

`OUTCOME_UNKNOWN` 是 immutable dispatch terminal。`FAILED_DEFINITIVE` 必须带 no-side-effect 或 observed failure proof；timeout/socket close/missing history 不足以进入该状态。`SUCCEEDED` 必须由 mutation-specific effect observation 证明，而不是只靠 Provider receipt。

### 5.2 Dispatch attempt `SM-DISPATCH-ATTEMPT`

```text
PREPARED
  -> DEFINITIVE_NOT_DISPATCHED
  -> CALL_STARTED
       -> PROVIDER_ACCEPTED
       -> PROVIDER_REJECTED_NO_SIDE_EFFECT
       -> OUTCOME_UNKNOWN
```

`PREPARED` transaction 保存 exact payload digest、actor、target、lane/entry revision 和 attemptId。只有写入 `CALL_STARTED` 才表示调用权限已发出。crash recovery 不得把 `CALL_STARTED` 解释为可重试。

### 5.3 Effect observation `SM-EFFECT-OBSERVATION`

`NONE -> PENDING -> OBSERVED_MATCH | OBSERVED_CONFLICT | OBSERVATION_UNAVAILABLE`。Session mutation 观察 Provider durable turn/item/settings/Goal/request/child/lifecycle；Product mutation 观察 exact file/Git/gallery/capture/trust generation。`OBSERVED_MATCH` 才允许 lifecycle `SUCCEEDED`。

### 5.4 Reconcile `SM-RECONCILE`

`NONE -> REQUESTED -> STILL_UNKNOWN | EXECUTED_PROVEN | NOT_EXECUTED_PROVEN`。它是 append-only observation axis，不是 `OUTCOME_UNKNOWN` 的 outgoing transition。`EXECUTED_PROVEN` 可派生 resolved UI；`NOT_EXECUTED_PROVEN` 可允许用户用新 operationId 再做一次；两者都不修改原 terminal/attempt/fingerprint。

## 6. Local intent 与 queue

### 6.1 Mobile local intent `SM-LOCAL-INTENT`

`DRAFT -> HELD_OFFLINE -> READY_TO_SUBMIT -> SUBMITTING -> BRIDGE_ACCEPTED`；旁路为 `ADMISSION_UNKNOWN`、`LOCAL_CANCELLED`、`LOCAL_ERROR`。`ADMISSION_UNKNOWN` 只可用 same operationId+fingerprint 查询 admission，不能创建新 dispatch。`BRIDGE_ACCEPTED` 后 Mobile 不再拥有远端 delivery。

### 6.2 Queue entry `SM-QUEUE-ENTRY`

`QUEUED -> DISPATCH_OWNED -> CONSUMED`；pre-dispatch 可 `EDITED`（revision+1）或 `CANCELLED`。edit/cancel/consume 以 laneRevision+entryRevision CAS，任一 stale 都只返回 latest snapshot。没有 reorder state。

## 7. Interaction 与 claim

### 7.1 Interaction `SM-INTERACTION`

```text
OPEN_UNCLAIMED <-> OPEN_CLAIMED
OPEN_CLAIMED -> RESPONSE_PENDING
OPEN_* | RESPONSE_PENDING -> RESOLVED | WITHDRAWN | STALE | EXPIRED
```

response Operation 若 `OUTCOME_UNKNOWN`，Interaction 保持 `RESPONSE_PENDING` 或按 Provider fact 变 `STALE/RESOLVED`；不能把 Interaction 状态写成 OUTCOME_UNKNOWN。

### 7.2 Claim lease `SM-CLAIM`

`NONE -> ACTIVE -> RELEASED | EXPIRED | CONSUMED | REVOKED`。同 Interaction 最多一个 ACTIVE partial-unique row。renew 只是 ACTIVE revision/deadline CAS，不是新 claim。actor 改变、source/runtime fence 失效或 Provider request 关闭都会使旧 token 无效。

## 8. ThreadState

### 8.1 Settings snapshot `SM-SETTINGS-SNAPSHOT`

`UNKNOWN -> SPARSE | COMPLETE -> STALE | CONFLICT`。SPARSE 可显示已知字段，但全对象 mutation 在 unknown preservation 未证明时失败 `UNKNOWN_SETTING_PRESERVATION_UNPROVEN`。UI `PENDING/APPLIED/ROLLED_BACK` 是 operation projection，不写进 settings head。

### 8.2 Goal `SM-GOAL`

`ABSENT | ACTIVE | PAUSED | BUDGET_LIMITED | COMPLETED | CLEARED_PROVEN | UNKNOWN`，另有 read/mutation transient presentation。Goal head 只来自 Provider readback；operation terminal 与 Goal status 两轴分离。

### 8.3 Plan

Plan item 没有独立 aggregate state machine：它是 CanonicalTimeline item revision。collaboration 属 Settings；ExitPlan 属 Interaction。任何 `PlanDocumentStatus`/第二 writer 都是禁止项。

## 9. RelationGraph

### 9.1 Durable relation `SM-RELATION`

`ABSENT -> PROVEN -> ACTIVE | COMPLETED | FAILED_PROVEN | REMOVED_PROVEN`。create/fork/review operation 在 child proof 前即使 Provider receipt 成功，relation 仍 `ABSENT`；operation unknown 不进入 relation state。

### 9.2 Ephemeral child `SM-EPHEMERAL-CHILD`

`OPENING -> ACTIVE -> CLOSING -> CLOSED | LOST_ON_RUNTIME_FENCE`。只存在 RelationGraph memory namespace；restart/disconnect/source switch 后直接 lost，不恢复、不写 durable relation/transcript。

## 10. Sync/apply

### 10.1 Bridge delivery `SM-DURABLE-DELIVERY`

`COMMITTED -> QUEUED -> SENT -> ACKED`，也可 `PAUSED_BACKPRESSURE`、`SNAPSHOT_REQUIRED`、`EXPIRED_AFTER_POLICY`。只有 commit transaction 产生 message；sender receipt audience 与 broadcast invalidation audience 明确分开。

### 10.2 Mobile apply `SM-REPLICA-APPLY`

`RECEIVED -> STAGED -> APPLIED -> READBACK_VERIFIED -> PUBLISHED -> ACKED`；任一步可 `REJECTED`，sequence/base/manifest gap 则 `SNAPSHOT_REQUIRED`。ACK 必须发生在 durable transaction+readback 后。

## 11. Content/transfer/native

### 11.1 ContentOffer `SM-CONTENT-OFFER`

`OFFERED -> TRANSFERRING -> VERIFYING -> FINALIZING -> FINALIZED`，旁路 `FAILED/CANCELLED/EXPIRED`。只有 FINALIZED 才 mint ContentRef。

### 11.2 Transfer `SM-TRANSFER`

`QUEUED -> PREPARING -> ACTIVE <-> PAUSED -> VERIFYING -> COMMITTING -> SUCCEEDED`，旁路 `RETRYING/FAILED/CANCELLED/EXPIRED`。FT/2 的 SUCCEEDED 只能显示 completed；FT/3 digest verified 后才可创建 finalized ContentRef/ComposerAttachmentRef。

### 11.3 Native call `SM-NATIVE-CALL`

`CREATED -> DISPATCHED -> RESULT_COMMITTED | TIMEOUT | PLATFORM_ERROR | CANCELLED`。callback key 包含 capability+hostEpoch+lifecycleEpoch+requestId+kind，并只消费一次；late/duplicate callback 只释放旧资源。

## 12. Capability 与 UI composition

Capability 有两个字段而非一个状态：

- support：`SUPPORTED | UNSUPPORTED | REQUIRES_BASE_APP_UPDATE | UNKNOWN`；
- availability：`AVAILABLE | TEMPORARILY_UNAVAILABLE | POLICY_DISABLED | RESOURCE_EXHAUSTED | UNKNOWN`。

UI 最终状态必须是命名 view model，例如：

```text
ConversationView = sourceAuthority
                 + catalog/timeline head
                 + live overlay
                 + sender-local operation projection
                 + interaction/thread/relation projections
                 + availability
                 + local presentation state
```

Reducer 只能组合并显示，不能通过 spinner、toast、route、notification 或 animation 反推任何 domain transition。

## 13. DDL 与验证门禁

机器源必须为每台状态机登记：owner、initial、terminal、transitions、guard、writer、storage column/table、wire projection、unknown policy 和 deliberate forbidden transition。DDL 至少约束：

- operationId/source 唯一与 fingerprint immutability；
- CALL_STARTED 后不能回 PREPARED/READY；
- OUTCOME_UNKNOWN terminal 不可覆盖，reconcile observation 单独 append；
- 同 interaction 单 ACTIVE claim；
- relation 不能在 child proof 缺失时 PROVEN；
- ContentRef 不能引用非 FINALIZED offer；
- Mobile checkpoint 不能先于 READBACK_VERIFIED；
- catalog/timeline head 分 namespace 且各自单 active CAS head。

最终 fault vectors 必须逐个尝试 forbidden transition 并证明以预期 typed code/SQL constraint 失败。只画状态图或只在应用层 `if` 判断，不构成设计门禁通过。
