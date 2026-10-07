# 06. 当前源码事实与目标接线图

本文件记录设计时实际检查到的源码路径，便于实施者区分“当前事实”和“目标方案”。行号基于
`main@a706200233c55cc82d7a17e433f80f132d0f280d`；代码变化后应重新核对，不能把本文件当运行时状态表。

本轮只读审计没有启动/替换 Bridge、没有修改配置、没有构建 App、没有部署、没有真机验收。

## 1. 当前接收链

```text
Claude SDK / Codex app-server
  → sdk-process.ts / codex-process.ts
  → parser.ts ServerMessage union
  → SessionManager history/status/onMessage
  → websocket broadcast + LocalFeaturesController fan-out
  → legacy runtime path OR conversation-sync-v2
  → BridgeService / ConversationContentSyncService
  → SessionRuntimeStore OR SQLite staging/cache
  → ChatSessionCubit / feature controller
  → Flutter widgets
```

### 1.1 Provider normalization

| 当前路径 | 已确认职责 | 目标接线 |
|---|---|---|
| `packages/bridge/src/sdk-process.ts:427-560,1269-1495` | Claude SDK system/assistant/user/tool/result/stream/status → `ServerMessage` | `providers/claude` adapter |
| `packages/bridge/src/codex-process.ts:4950-5055,5817-6790` | Codex JSONL/RPC、turn/item/agent/reasoning/plan/guardian/Goal、completion 映射；user item 保留 provider/client IDs | `providers/codex` adapter + Interaction adapter |
| `packages/bridge/src/codex-process.ts:5232-5455` | request/approval owner、thread/turn/generation fence | `interactions/codex` |
| `packages/bridge/src/parser.ts:736-1028` | Bridge 全局 `ServerMessage` union | 收缩为 normalized domain event 边界；feature 类型由生成 schema 管理 |

应保留 provider-specific decoding；应移走 UI shape、storage policy 和 feature mutation 分支。未知 provider item 进入
bounded `UnknownProviderItem`，不能直接以任意 map 穿透到 Cubit。

### 1.2 SessionManager hot path

| 当前路径 | 已确认职责 | 目标接线 |
|---|---|---|
| `packages/bridge/src/session.ts:941-1536` | 串行 artifact/image enrichment、runtime ownership、history append、status/input receipt、exit boundary | RuntimeBinding + LiveObservationHub；保留兼容 hot history |
| `packages/bridge/src/session.ts:1658-1705,1868-1955` | history seq/revision、gap snapshot、user echo identity merge | characterization tests；强 ID merge 迁 Canonical/Live reconciler |
| `packages/bridge/src/session.ts:2040-2230` | 受限 text/image fallback、trim/low watermark | legacy adapter，不进入新强身份规则 |

当前 SessionManager history 是内存 hot cache，不是 provider canonical。新架构不能把它升级为历史 authority。

### 1.3 Bridge fan-out 与 provider history

| 当前路径 | 已确认职责/风险 | 目标接线 |
|---|---|---|
| `packages/bridge/src/websocket.ts:2158-2454,14717-14747` | session broadcast、runtime wiring、local feature fan-out；stream/thinking batching 会 early return | root 仅认证/envelope/registry dispatch；验证专用 delta 是否完整覆盖 |
| `packages/bridge/src/websocket.ts:4242-4510` | Codex provider page、live baseline merge、canonical IDs | ProviderGateway + ProviderHistoryProjectionWriter |
| `packages/bridge/src/websocket.ts:4620-4900` | history snapshot、cursor/turn-aware read | v2/legacy adapter；领域 read 统一走 TurnReader |
| `packages/bridge/src/local-features/codex-bounded-history.ts:37-43` | bounded official read；items/list → turns/list fallback，不用无界 includeTurns | Codex TurnReader，保留能力 probe/上限 |

### 1.4 Conversation Sync v2

| 当前路径 | 已确认职责 | 目标接线 |
|---|---|---|
| `packages/bridge/src/local-features/conversation-sync-v2.ts:500-935` | runtime/shared/external/providerRefresh taxonomy、catalog/status/projection/revision/generation maps | 拆为 canonical/live/catalog/sync，但先保留行为 |
| 同文件 `:1080-2086` | runtime overlay、shared control/observer、generation fence、有界 buffers、result 触发 refresh | LiveObservationHub；observer 不能写 canonical |
| 同文件 `:3330-3636` | provider failure/empty/incomplete 保留旧 snapshot+gap/backoff；complete coverage 才换 base | ProviderHistoryProjectionWriter 的核心回归合同 |
| 同文件 `:5391-5815` | external monitor lifecycle/cap/buffer | ExternalObserver adapter，默认 invalidation |
| 同文件 `:6915-7315` | strong scoped identity/cross-source alias；歧义分开 | TurnReconciler |
| `slots/conversation-sync-v2-protocol.ts:35-323` | subscribe/read/focus/ACK、catalog/status/timeline/overlay、revision/gap | v2 wire adapter与vNext sync语义基底 |
| `conversation-sync-v2.ts:2410-2913,6648-6764` | subscription、cumulative ACK、batch、outstanding queue | SyncSession/flow control |

`projectionSource=providerRefresh` 是 observer/source tag；`canonicalHistory` 是完整 provider read 的提交边界，不是额外
竞争 writer，也不是独立 durable store。

### 1.5 Mobile receive/store/UI

| 当前路径 | 已确认职责 | 目标接线 |
|---|---|---|
| `apps/mobile/lib/features/conversation_content_sync/conversation_content_sync_service.dart:182-269,2204-2968` | 单 subscription、SQLite staging、generation、cache revision、水位、sequence duplicate/gap、scoped reset、focused overlay | Mobile SyncSession + replica writer；保留 commit-before-ACK |
| 同文件 `:3376-3540` | cumulative ACK、target/subscription/generation fence | vNext `sync.ack` |
| `apps/mobile/lib/services/bridge_service.dart:1989-2490` | connection epoch、stale socket reject、authoritative SessionList/source switch、durable input preservation | authenticated connection/source host |
| 同文件 `:5925-6136` | v2 owns catalog 时抑制 legacy recent list | 单 active protocol owner gate |
| `apps/mobile/lib/services/session_runtime_store.dart:90-351` | legacy history snapshot/delta/cache；忽略 Goal/settings/stream；bounded trim | legacy runtime adapter only |
| `apps/mobile/lib/features/session_list/cache/session_catalog_cache_database.dart:244-760` | source/thread partition、catalog、hot windows、coverage/gap、staging/index/repair | vNext replica schema 的行为参考；不原地破坏 |
| `apps/mobile/lib/features/chat_session/state/chat_session_cubit.dart:232-357,1264-1640,4908-5950` | durable/runtime 身份分离、overlay/alias validation、history merge | Repository + pure reducer + feature controllers |
| `apps/mobile/lib/features/codex_session/codex_session_screen.dart:1695-2068` | durable provider thread route、v2 hot window 初始历史 | Conversation screen 只读 Repository |

当前 durable Codex page 已经把 provider thread ID 与 runtime attachment 分开；新架构必须保留，不能重新把 runtime
session ID 当 cache key。

## 2. 当前发送链

```text
Mobile intent
  → BridgeService send/persistence classification
  → websocket typed/legacy route
  → SessionManager input admission / feature admission
  → InputDeliveryLedger persist
  → provider turn/start or turn/steer
  → receipt/status/canonical observation
  → Mobile outgoing projection/reconcile
```

### 2.1 Mobile

| 当前路径 | 已确认职责/风险 | 目标接线 |
|---|---|---|
| `apps/mobile/lib/services/bridge_service.dart:4511-5108` | ephemeral live RPC、persistent offline queue、input 断线隔离/quarantine | 由 schema/manifest 决定 policy，不用白名单散落分类 |
| `apps/mobile/lib/features/chat_session/state/chat_session_cubit.dart:8424-8815` | Goal live-only、expected facts、UUID mutation、断线不排队 | Goal controller |
| 同文件 `:9209-9990` | permission/Plan/model/speed optimistic state与 rollback | ThreadSettings controller |
| `apps/mobile/lib/models/messages.dart:5712-6317` | attached/detached settings/Goal target、approve/reject/answer delivery shape | 生成的 typed target/operation/interaction types |

当前 `BridgeService` persistence 白名单不等于可靠的 settings outbox；最终协议必须由 operation manifest 明确禁止/允许重放。

### 2.2 Bridge input ledger/queue

| 当前路径 | 已确认职责/风险 | 目标接线 |
|---|---|---|
| `packages/bridge/src/input-delivery-ledger.ts:19-174` | Source/thread/clientMessageId ledger，queued/dispatching/accepted/rejected/unknown/cancelled，max 16 | Operation Kernel/input queue |
| `packages/bridge/src/session.ts:2410-2475` | restart recovery/replay selection | **必须修改**：dispatch 已开始的 turn/start 不自动 replay |
| 同文件 `:2551+` | durable queue/admission、turn/start/turn/steer | 拆分 `turn.input` 与 `turn.steer` policy |

已确认 provider 对相同 `clientUserMessageId` 不保证去重。因此“provider 接受字段”不能作为 restart replay 安全证据；
`provider_dispatching` 后必须 reconcile/outcome_unknown。

## 3. 当前 Feature Host

| 当前路径 | 已确认职责 | 目标接线 |
|---|---|---|
| `packages/bridge/src/local-features/registry.ts:30-54` | 唯一 concrete registry，组合 Action Broker、approval、core actions、continuity、Mirror、content/sync、file、insights、subagents、Side Chat | 保留 composition root，增加 Feature Manifest |
| `packages/bridge/src/local-features/controller.ts:14-299` | message dispatch、input admission fan-out、lifecycle fan-out、AbortController/disconnect cleanup | Feature Host |
| `packages/bridge/src/local-features/runtime.ts` | session/source/runtime/action/background seam | 收缩为显式 service interfaces |
| `packages/bridge/src/local-features/protocol-slot.ts` | removable protocol contributions | schema-generated protocol slot |
| `apps/mobile/lib/models/local_features/protocol_host.dart:1-254` | feature request correlation、old-Bridge error isolation、slot decode | Mobile Protocol Host |
| `apps/mobile/lib/features/local_session_features/` | UI actions/status/mode/pane slots | Ui Surface Host |

这套 slot 设计是可保留资产；问题是部分功能尚未进入它，而不是需要再造一个并行 plugin framework。

## 4. Codex 周边功能现状

### 4.1 Side Chat 三路径

| 路径 | 当前事实 | 目标 |
|---|---|---|
| `local-features/side-chat.ts:60-117,186-402,711-888` | owner-scoped dedicated process；不进 SessionManager/history/catalog；内存 queue/dedup；断线 live lifecycle | legacy compatibility 冻结 |
| `local-features/persisted-side-chat.ts:9-75` + `websocket.ts:3644-3727` | official durable child，进入普通 SessionManager/session list/screen | 产品默认；补 operation ledger/relation graph |
| `local-features/ephemeral-side-chat.ts:14-97` + `websocket.ts:3730-4272` | official ephemeral fork，Bridge registry/live history only | 显式 ephemeral module |
| Mobile `persisted_side_chat_pane.dart` | capability 有时复用普通 Codex screen，缺失才 fallback legacy | 保留 capability fallback |
| Mobile `side_chat_controller.dart` | legacy 独立 transcript/draft/pending，不写 parent Cubit | legacy controller |

最新项目决策以 official persisted child 为默认；更早“只 ephemeral”的段落已被 supersede，实施时不能误用旧决定。

### 4.2 Subagents

| 当前路径 | 当前事实 | 目标 |
|---|---|---|
| `local-features/subagents.ts:113-393,556-1200` | attached/detached bounded read、source/descendant 验证、read-only process、activity watch | Subagent query/relation module |
| Mobile `features/subagents/state/subagents_controller.dart:28-831` | target/request/generation matching、detached capability gate、standalone browser | feature controller |

它不是 main timeline 或 primary catalog 的一部分。child history可复用统一 TurnReader，但仍以 child ThreadRef 查询。

### 4.3 Goal

| 当前路径 | 当前事实 | 目标 |
|---|---|---|
| `packages/bridge/src/codex-goal-controller.ts:110-385` | 串行、merge、conflict/resume lease | Goals module core |
| `websocket.ts:8536-8710,13260-13557` | active/detached durable Goal RPC、source/thread/idempotency/precondition/writer | 从 root 抽出 |
| `codex-process.ts:5895-5935` | provider goal notification → `goal_state` | Codex Goal adapter |
| Mobile Goal router/Cubit `:5053-5125,8424-8815` | scoped route、operation sequence/change/timestamp stale guard、live-only mutation | Goal controller |

Goal 是 thread state，不进 transcript/runtime cache；ephemeral thread 不支持。

### 4.4 Plan/settings/interaction

| 当前路径 | 当前事实 | 目标 |
|---|---|---|
| `codex-process.ts:6006-6046` | plan update → assistant `UpdatePlan` item | canonical Plan item adapter |
| 同文件 `:6273-6297` | ExitPlanMode/plan completion → approval/status | Interaction Broker |
| `websocket.ts:14030-14190` | shared setting exact runtime/thread/source/authority、lease、operation fingerprint/serialize | ThreadSettings module |
| `codex-action-broker.ts`, `-runtime.ts`, `-writer-lease.ts` | identity-only durable request ledger、claim/submitting/submitted/unknown、single-writer lease | Interaction Broker foundation |
| Mobile `chat_message_handler.dart`/`codex_action_broker_interaction_frame.dart` | AskUser/approval mapping与 UI | Interaction controller/surface |

Plan collaboration setting、Plan item、ExitPlanMode interaction、edited plan response 是四种不同领域事实。

## 5. Mirror、background 与 diagnostics

| 当前路径 | 当前事实 | 目标 |
|---|---|---|
| `conversation_mirror_service.dart` + `conversation_mirror_store.dart` | 独立可选投影，source/thread key，shadow generation atomic promote | 保留独立 Mirror reader，复用 immutable Spine |
| `background_sync/*`, `background-delivery-protocol.ts` | interactive vs notifications_only；后台过滤正文 | BackgroundDelivery module |
| `features/diagnostics/session_diagnostic_report.dart` | 汇集 SQLite/Cubit/home 投影并 scrub | Projection Lab Mobile capture |
| `packages/bridge/src/file-transfer-diagnostic.ts` | 通过现有文件传输归档诊断 | 复用认证 transport/receipt，不造平行上传 |

## 6. 实施时的 owning-path 顺序

1. 先在现有 host 加 identity/manifest/interface，不先移动大文件。
2. 先写 characterization tests 固定 v2 failure-retention、coverage、ACK 和 queue 语义。
3. 抽 ProviderAdapter/ProviderHistoryProjectionWriter/Operation Kernel；旧 adapter 调用新内核。
4. root `websocket.ts/parser.ts` 只在对应 module 已有完整 schema/tests 后删除分支。
5. Mobile controller/repository 替代 Cubit 分支时，一次迁一个 feature，保留旧 capability fallback。
6. 不机械复制或删除整个 `conversation-sync-v2.ts`；以 ownership seam 逐段接管。

## 7. 静态审计不能证明的事实

- 当前运行中的 Bridge 是否就是该 HEAD/build/config；
- daemon/shared capability、socket、owner和 writer lease 的现场状态；
- stream/thinking batching 是否在所有 topology 下由专用路径完整覆盖；
- 当前 provider cursor/compact/fork 行为；
- 当前 iPhone/Android 上 v2 DB/outbox/旧 pending 的真实内容；
- WSS→Dart→SQLite→Repository→UI 与物理设备的完整验收。

这些必须按 [04-migration-and-acceptance.md](04-migration-and-acceptance.md) 的门禁现场验证，不能由源码路径推断为已完成。
