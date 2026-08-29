# 架构与唯一 Owner

状态：`ROOT_DECISION / INTEGRATION_BASELINE`

## 1. 不是多核心，也不是巨型内核

产品只引入一个可独立定义的 `CodexSessionKernel`。它不单独部署，也不取代 CC Pocket 宿主；Bridge 和 Mobile 各自承载它在本进程中的一半。Kernel 内部按状态 owner 分包，避免所有逻辑重新集中到 `websocket.ts`、`BridgeService` 或 `ChatSessionCubit`。

设备、routes、配对、文件、传输、Git、Gallery、通知、后台、权限、更新、Native、Supporter、产品 shell 和视觉继续是宿主产品模块。`ProductPlatform` 只是这些模块的集合称呼，不是新核心、数据库、writer、event bus 或万能 gateway。

## 2. 三层结构

```text
CC Pocket host/composition roots
  ├─ CodexSessionKernel
  │    ├─ ConversationCatalog
  │    ├─ CanonicalTimeline
  │    ├─ LiveOverlay
  │    ├─ OperationKernel
  │    ├─ InteractionBroker
  │    ├─ ThreadState
  │    ├─ RelationGraph
  │    └─ SyncProjection
  ├─ Product modules
  │    ├─ Connectivity
  │    ├─ File/Artifact/Gallery/Git/Capture
  │    ├─ Transfer + FileMutationAuthorization
  │    ├─ Notification/Background/Permission/Update
  │    ├─ Native capability adapters
  │    └─ Voice/Icon/Supporter/Shell/Localization/Motion/Diagnostics
  └─ Product UI
       ├─ Home/computer/routes/session catalog
       ├─ Conversation + focused controllers
       ├─ File/media/workspace surfaces
       └─ Settings/setup/debug/product shell
```

这些名称表示编译与状态 ownership，不自动意味着新的 package、进程、SQLite 文件或网络协议。只有实施波次证明独立生命周期或存储不变量时才增加物理边界。

## 3. Kernel 内部 Owner

| Owner | 唯一职责 | 明确不拥有 |
|---|---|---|
| `ConversationCatalog` | source-scoped thread catalog、archive/metadata projection、bounded discovery | timeline body、route、UI grouping preference |
| `CanonicalTimeline` | Provider evidence read、TurnSpine/item/body refs、coverage/gap/order proof、last-good、唯一 canonical commit | live runtime、outgoing optimistic UI、文件系统 |
| `LiveOverlay` | 当前 source/runtime/subscription fence 下的 memory-only observation 与 repair trigger | durable history、stream checkpoint |
| `OperationKernel` | admission、fingerprint、queue/lane、dispatch barrier、operation terminal、read-only reconcile | Provider history、interaction prompt authority、UI toast |
| `InteractionBroker` | approval/question/MCP/ExitPlan open state、authenticated claim lease、response handoff | response dispatch ledger、Goal/Plan document、secret diagnostics |
| `ThreadState` | Provider-backed Goal、authoritative settings/effort snapshot、collaboration setting | Plan timeline item、ExitPlan、Mobile UI preference |
| `RelationGraph` | Fork、persisted/ephemeral Side Chat、subagent、review-child relation 与 child locator | child timeline、session catalog duplication |
| `SyncProjection` | canonical commit 后的 durable projection、per-client stream/checkpoint/gap 和 capability-bound snapshot | Provider read、live replay、feature-local state |

## 4. Bridge 与 Mobile 的唯一写入口

- Bridge canonical timeline：`CanonicalTimelineWriter`；任何 observer、Product module、transport handler、Operation 或 Relation 不能直接写 timeline。
- Bridge operation/queue：`OperationKernel`；Feature handler 只能提交 typed operation。
- Bridge interaction claim：`InteractionBroker`；actor 由 authenticated connection context 注入。
- Mobile rebuildable replica：`ReplicaApplyCoordinator`；只有 durable inbox 事务能推进 persisted stream checkpoint。
- Mobile local intent：`LocalIntentRepository`；Bridge 接受后不再是 queue authority。
- Mobile draft/local preference：独立 local-state repositories，不依赖 rebuildable session row 的 cascade。
- live：Bridge/Mobile 都只在内存 overlay owner 中存在。

## 5. Host 接缝

实施时优先演进现有组合根，而不是并行建立第二套插件系统：

- Bridge：`packages/bridge/src/index.ts` 继续是唯一 composition root；`local-features/registry.ts` 只登记 typed capability/handler/lifecycle/UI contribution，不能复制 protocol/storage/terminal。
- Mobile：`apps/mobile/lib/main.dart` 继续装配；`LocalSessionFeatureHost`/typed slots 继续承载 UI contribution；`BridgeService` 最终只保留 transport、authentication、connection epoch 和 generated envelope I/O。
- `websocket.ts` 只保留 authenticated transport、capability negotiation 和 dispatch 到 typed handlers。
- `ChatSessionCubit` 最终只组合 page view state；不得 decode raw frame、执行 durable commit 或拥有 feature 状态机。

## 6. 依赖规则

1. Product module 可以读取 Kernel post-commit projection或调用窄 port，不能写 canonical timeline。
2. Kernel 只消费 `AuthenticatedExecutionContext`、`ContentRef` 等抽象，不管理 route、文件路径、iOS entitlement 或购买状态。
3. Provider-native DTO 只存在于 Codex adapter；wire、DB、Mobile 不出现 raw app-server object。
4. 所有跨进程/跨语言/持久化 discriminant 来自同一 registry；内部 UI state 不因 codegen 方便被提升成 wire contract。
5. Feature module 之间不得读写彼此私有表或 pending map；共享语义必须回到唯一 owner。
6. 编译依赖必须无环；运行时 relation graph、callback 和事件序列不被误要求成全局 DAG。
7. Claude unfinished seam 不进入 Kernel identity、wire、DDL、capability snapshot 或 UI route。

## 7. 当前源码处置原则

- 保留当前产品效果、mature UI/native modules、Codex adapter经验和有效 tests。
- 当前 `conversation-sync-v2`、Mirror、legacy Side Chat、巨型 router/Cubit、重复 ledger/cache/pending map 只作行为与失败证据，不成为 production fallback。
- 最终实施宿主使用用户要求的 pinned open-source CC Pocket baseline；当前 `a706...` 是产品能力、源码接缝和回归证据 donor。实施开始前必须重新绑定届时批准的 exact upstream HEAD/tree，不能从本设计载体 branch 推断。
- 每项 source disposition 必须是 `KEEP / ADAPT / REWRITE / DELETE / DEFER_UNREACHABLE`，并绑定行为、测试、首个 vertical slice 和回退。

