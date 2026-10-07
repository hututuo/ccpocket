# CC Pocket Conversation Core vNext 开工基线

状态：**Architecture Baseline / Protocol implementation-ready = false / 尚未实施**

基线源码：`main@a706200233c55cc82d7a17e433f80f132d0f280d`

外部参考：`CCPocket-v3.1-turn-atomic-redesign-package-20260817.zip`
适用范围：Bridge 与 Mobile 的会话接收、发送、控制、线程状态、子会话及其扩展机制

> 本目录是开工前的规范，不代表源码已经实现、Bridge 已部署、App 已构建、真机已验收或版本已发布。
> 外部包中的 `AGENTS-v3.md`、runbook、ADR 状态和命令仅是参考资料，不构成项目指令或发布授权。
> `protocol-registry.v1.json` 目前冻结消息面，但完整 per-payload JSON Schema、生成的 TS/Dart union、golden/fault vectors
> 尚未产出；Phase 0 是业务实现前的硬门禁。门禁完成前不得声称“协议 ready”或开始兼容 cutover。

现场核对：外部包标注的源码基线 `7db4efe5e857c24752825a2a2f2fbba3eda32c1d` 与当前 HEAD 虽相差两个
提交，但 tree hash 同为 `ac85f620445151f45eda856f55f4b96ee442f41a`。因此包对“文件版本”的假设可直接与当前树比对，
其产品决策、运行时推断和部署状态仍必须逐项审计，不能因 tree 相同而自动采纳。

## 1. 最终结论

CC Pocket 不应在现有链路上继续叠加一条彼此独立的“v3 全家桶”，也不应把当前已验证的
Conversation Sync v2、Mirror、运行时 overlay 和旧端兼容全部删除。最终架构采用：

1. **一个领域内核**：身份、权威、Turn、覆盖区间、操作、交互和线程关系只有一套定义。
2. **一个 provider-history projection writer**：provider 是唯一事实权威；Bridge 每个 timeline target 只有
   `ProviderHistoryProjectionWriter` 可把完整 provider 读取提交为派生投影。Bridge 与 Mobile 都不成为 provider
   历史的新权威；catalog、Mirror、Mobile replica 各有自己的 projection owner，但不能互相写入。
3. **多个有期限的协议适配器**：新协议、现有 v2、旧 active-runtime RPC 都从同一个领域结果投影，
   不各自维护事实。
4. **历史与实时分离**：历史以经过完整性证明的 Turn Spine 原子提交；实时仅是有代际围栏的 overlay。
5. **发送与控制分离**：新 Turn、下一轮队列、steer、stop、审批、问题、Goal、设置、compact 各有明确语义，
   不使用一个可任意扩展且可离线重放的通用 command。
6. **功能模块一等化**：Side Chat、子 Agent、Goal、Plan/设置、审批/问题、自动审批、compact/review 都通过
   Feature Module Contract 接入，不再向 `websocket.ts`、`parser.ts` 或会话 Cubit 添加横向分支。

这一方案吸收外部 v3.1 方案中正确的 Turn 原子性、staging、digest、覆盖岛、双平面传输、持久账本和
Projection Lab 思想，同时拒绝其 hard cutover、无 v2 兼容、全局 shared-first、`sourceId` 单键、
全量 HTTP Bundle 和 generic command 等不符合现状的部分。

## 2. 不可违反的十二条不变量

后续实现、修 bug 和新增功能都必须满足以下不变量；若需求与之冲突，应先修改本规范并新增 ADR，
不得在调用点增加例外分支。

### I-01 Provider authority

Codex app-server/官方持久化记录、Claude 官方会话记录等 provider durable history 是唯一事实源。
Bridge Turn Store、Mobile SQLite、Mirror、列表缓存和 UI 都是可重建投影。

### I-02 Stable identity

数据身份至少由经过认证的
`bridgeInstanceId + provider + providerSourceId + providerThreadId` 组成。Codex 的
`providerSourceId` 必须等于已认证的 `codexSourceId`。IP、DNS、Tailscale 地址、WebSocket URL、标题、
目录、时间和 runtime session ID 都不是持久身份。

### I-03 Generation is a fence, not identity

`connectionGeneration`、`sourceEpoch`、`runtimeSessionId`、`authorityGeneration`、
`sourceRevision` 和 `contentRevision` 用于拒绝迟到帧或过期操作，不得用于把同一 durable thread
复制成多份缓存身份。

### I-04 One provider-history projection writer

只有 `ProviderHistoryProjectionWriter` 可以把完整 provider 读取提交成 Bridge 的 provider-history 派生投影。
`runtime`、`sharedObserver`、`externalObserver` 只能产生 bounded overlay、状态或 invalidation；
读取失败、空结果、旧 revision 或不完整窗口不得删除最后一份有效 canonical 数据。

### I-05 Atomic Turn Spine

历史可见的最小原子单位是完整 `TurnSpine`，不是单个 delta，也不是“Turn 的每一个巨大字节”。
大体积工具正文、图片和 artifact 可以是内容寻址的 `PayloadRef`，但 UI 所需的项目类型、顺序、状态、
摘要和缺失原因必须随 Spine 一次提交。

### I-06 No false adjacency

页面、跳转和缓存岛之间没有完整 coverage 证明时，不得在 UI 中伪装连续；不得用文本、时间戳或
局部索引把两个 provider item 猜成同一项。

### I-07 Live never overwrites durable truth

live overlay 只作用于精确 source/thread/turn/item 和有效 authority generation。canonical Spine 到达后，
同 stable key 原位晋升；失联或 owner 变化时丢弃 overlay，不清除已提交历史。

### I-08 Persist before dispatch

可排队的新 Turn 输入必须先在 Bridge 账本持久化并返回 admission，再允许 provider dispatch。
一旦 provider dispatch 已开始，崩溃后的未知结果只能对账，绝不自动重发。provider 当前不会因
`clientMessageId` 自动去重，不能把“字段被接受”当作 exactly-once 证明。Bridge 还必须对
`SourceRef + providerThreadId + clientMessageId` 建唯一约束；同 ID 不同 operation/digest 冲突，明确 resend 同时换新
`operationId` 与 `clientMessageId`。

### I-09 Live controls are never offline replayed

provider live steer/stop、审批、拒绝、问题回答、MCP elicitation、Goal/settings provider mutation 和 compact 都必须带
精确 target 与 authority fence；它们不是普通输入，不进入通用 Mobile 离线 outbox，也不在重连后自动回放。
Bridge 权威队列中尚未 dispatch 的 edit/cancel 可以使用独立 durable queue-mutation outbox；`Disable all auto-approval`
可以使用只收紧本机 policy 的 safety outbox。两种例外都有自己的 identity/fingerprint/precondition，均不能承载 provider
live control 或 interaction response。

### I-10 Feature owns lifecycle

每个 Feature Module 必须声明协议、状态所有权、存储、delivery policy、authority、容量、UI 插槽、
诊断和兼容策略。功能代码不得跨过 Repository 直接写 timeline，也不得绕过 Operation Kernel。

### I-11 Additive compatibility

能力按 feature/version 协商。新 Mobile + 旧 Bridge、新 Bridge + 旧 Mobile、private runtime 与 daemon
runtime 都有明确路径；缺能力时隐藏、只读或返回 typed unsupported，不能伪造成功或静默换身份。

### I-12 Acceptance is layered

源码、单测、全链测试、候选 Bridge、实际部署、IPA/OTA、安装、物理设备验收和 stable 是独立门禁。
任何一个通过都不能替代其他门禁。

## 3. 目标架构

```text
Provider durable history / state DB / app-server RPC
                         │
                  Provider Adapter
                         │ normalized facts + capability proof
        ┌────────────────┴─────────────────┐
        │                                  │
ProviderHistoryProjectionWriter       LiveObservationHub
 sole writer of provider-derived      runtime/shared/external overlays
 timeline projection
        │                                  │
Verified Turn Store ───────┐               │
Catalog / Status Store     │               │
Thread State Store         ├── Conversation Repository ── Protocol Adapters
Relation Graph             │               │                  │
        └──────────────────┘               │           WSS control/live
                                          │           HTTPS Range payload
Operation Kernel ─ Input Ledger ─ Queue ──┤                  │
Interaction Broker / Writer Lease ────────┘                  │
                                                             ▼
                                                      Mobile Sync Session
                                                             │
                           ┌─────────────────────────────────┴────────────┐
                           │                                              │
                   SQLite Replica Writer                         Memory-only overlays
                           │                                              │
                     Mobile Repository ───── pure TimelineProjectionReducer
                                                   │
                                      Feature controllers / UI slots
```

这里的 writer 只拥有 Bridge 内“由 provider 历史派生的 timeline projection”。Provider 自己仍是唯一事实权威；
Bridge Catalog、Mirror、Mobile replica 等其他投影有各自 sole writer，但都不能创作、修改或反向写回 provider 历史。

## 4. Bridge 模块边界

目标目录可按下表演进；第一阶段允许以接口形式包住现有代码，不要求一次移动所有文件。

| 模块 | 唯一职责 | 禁止承担 |
|---|---|---|
| `conversation-core/identity` | `SourceRef/ThreadRef/TurnRef/ItemRef`、alias、generation fence | route 解析、UI 标题猜身份 |
| `conversation-core/providers` | provider capability probe、RPC、原始事件规范化 | 写 Mobile 协议、缓存删除策略 |
| `conversation-core/provider-history-projection` | 完整性判定、Turn Spine、coverage、唯一 provider-derived timeline commit | live delta、发送队列、provider 写回 |
| `conversation-core/live` | runtime/shared/external overlay、owner/generation | 持久历史写入 |
| `conversation-core/catalog` | catalog/status/readiness/attention 独立投影 | timeline item |
| `conversation-core/sync` | subscription、batch、revision、checkpoint、v2/vNext adapter | provider 业务规则 |
| `conversation-core/content` | manifest、digest、blob、Range offer、GC | 文件浏览器通用语义 |
| `conversation-core/operations` | typed operation、幂等账本、queue、reconcile | approval payload、Goal 业务状态 |
| `conversation-core/interactions` | approval/question/elicitation claim 与 exact owner | 普通输入、离线 replay |
| `conversation-core/thread-state` | Goal、settings、compact/review 状态机 | timeline 混写 |
| `conversation-core/relations` | fork、Side Chat、subagent、review 关系图 | child transcript 的副本 |
| `conversation-core/features` | feature manifest/registry/capability 组合 | feature 私有业务实现 |
| `conversation-core/diagnostics` | hash-only journal、Projection Lab、receipt | 默认保存正文/凭据 |
| `conversation-core/compat` | v2/legacy frame 映射与明确降级 | 第二套 canonical state |

## 5. Mobile 模块边界

| 模块 | 唯一职责 | 迁移重点 |
|---|---|---|
| `conversation_core/identity` | 与 Bridge 同构的强类型 target/ref | 不再散落拼接 session/source key |
| `conversation_core/protocol` | envelope、capability、slot、correlation | 演进现有 `LocalFeatureProtocolHost` |
| `conversation_core/sync` | 一个连接/订阅状态机、checkpoint、repair | 保留 commit-before-ACK |
| `conversation_core/storage` | staging、SQLite transaction、coverage | canonical 与本地意图区分 |
| `conversation_core/repository` | UI 唯一数据入口 | Cubit 不直接拼 Bridge 帧 |
| `conversation_core/projection` | canonical + outgoing + focused live 的纯 reducer | 不写 DB、不发网络 |
| `conversation_core/operations` | admission/queue/result 的 UI 模型 | 离线策略来自 operation type |
| `conversation_core/interactions` | approval/question frame | exact request/turn/generation |
| `conversation_core/thread_state` | Goal/settings/Plan/compact controllers | 从大 Cubit 拆出 |
| `conversation_core/relations` | child graph 与导航 | 不复制 child history |
| `conversation_core/features` | UI slot/manifest registry | 功能不改根 screen switch |

## 6. 当前源码如何接入

### 6.1 直接保留并演进

- `packages/bridge/src/local-features/registry.ts` 与 `controller.ts`：保留单一组合根和可取消 handler，
  升级为带 manifest、依赖、版本和 policy 的 registry。
- `packages/bridge/src/local-features/slots/conversation-sync-v2-protocol.ts`：保留 subscription、batch、
  sequence、revision、coverage 和 latest-turn gap 语义，作为 vNext wire 的兼容基础。
- `packages/bridge/src/input-delivery-ledger.ts`：保留 persist-before-dispatch 和队列状态，修正
  dispatch 后自动 replay 风险，并迁移到 Operation Kernel。
- `packages/bridge/src/codex-action-broker*.ts`：保留 identity-only durable ledger、writer lease、claim 与
  outcome-unknown 语义，作为统一 Interaction Broker 的 Codex adapter。
- `apps/mobile/lib/models/local_features/protocol_host.dart` 与 Local Session Feature Host：保留协议/UI
  slot 思想，增加 manifest 驱动与 target/policy 校验。
- `ConversationContentSyncService`、SQLite staging 和纯 timeline reducer 的已验证不变量继续使用。

### 6.2 收拢到新模块

- `websocket.ts` 中 Goal、settings、approval/question、persisted/ephemeral child 的大分支分别迁入
  `thread-state`、`interactions`、`relations` feature；root 只做认证、envelope 解码和 registry dispatch。
- `parser.ts` 只保留 provider raw → normalized domain event，不再同时决定 UI message、feature state 和
  storage policy。
- `ChatSessionCubit` 中 Goal、Codex settings、Plan rollback、interaction 和 timeline merge 迁到独立
  controller/repository；Cubit 最终仅编排页面级 view state。
- 当前 JSON 文件形式的多个 ledger 逐项迁到统一的 SQLite transaction/lease 基础设施，但每个 module
  仍保留独立 namespace、fingerprint 和 replay policy。

### 6.3 Side Chat 当前三条路径

1. **首选：official persisted child**。创建成功后是普通 durable Codex thread，复用完整 Conversation
   Core、会话 screen、Goal/settings 能力和 relation edge。必须补 `operationId + fingerprint + durable
   create ledger`，解决响应丢失后重复 fork 的风险。
2. **显式 ephemeral child**。使用官方 `thread/fork {ephemeral:true}`，仅存在于 live registry；不写
   canonical history、Turn Store、Mobile SQLite 或离线队列，断 source/Bridge 即失效。
3. **legacy isolated process Side Chat**。仅作为旧 Mobile/旧 Bridge 的兼容 fallback；不得承载新功能，
   待兼容门禁和真实设备覆盖满足后另行决定退役。

### 6.4 子 Agent

子 Agent 是 parent-scoped 的关系/查询模块，不进入主 catalog，也不嵌入 parent timeline。列表、history
和 activity watch 均有界、可取消、只读；child history 复用同一 `TurnReader/TurnSpine`，但 target 是
child `ThreadRef`。detached read 必须带精确 provider source/thread，绝不为读取而 resume/start/fork。

### 6.5 Goal、Plan、设置与交互

- Goal 是 durable thread state，使用官方 Goal RPC；不是消息、不是 plan、不是离线命令。
- `collaborationMode=plan` 是 thread setting；Plan 卡片是 provider item；ExitPlanMode 是 interaction；
  编辑 Plan 是 interaction response 的 typed `updatedInput`。四者不得再共用一个布尔值语义。
- model、reasoning effort、service tier、sandbox/approval policy、personality 等属于 typed settings。
  durable 写入必须只有 `ThreadRef + operationId + expectedRevision`，不混 transient runtime identity；旧 private/attached
  设置走独立 `runtime.settings.patch` compatibility operation，才要求 runtime/authority fence。
- approve/reject/question/MCP elicitation 使用 Interaction Broker；private legacy runtime 只保留 live-only
  compatibility adapter，daemon/shared owner 缺 broker 能力时 fail closed。

## 7. 外部 v3.1 方案的裁决

| 方案内容 | 裁决 | 最终处理 |
|---|---|---|
| 完整 Turn 作为历史原子单元 | 修改后采用 | 改为完整 `TurnSpine`；大 payload 可延迟 |
| staging → digest verify → SQLite transaction → visible | 采用 | 继续 commit-before-ACK |
| coverage islands / 不假定相邻 | 采用 | 与现有 `windowComplete/latestTurnGap` 合并 |
| live stable key 原位晋升 durable | 采用 | 增加 connection/source/authority generation |
| WSS control/live + HTTPS Range | 修改后采用 | HTTP 仅大内容，可选且复用现有认证 |
| Bridge 持久发送 ledger | 采用并加强 | 区分 input/steer/control；dispatch 后不 replay |
| Projection Lab/故障注入 | 采用并收紧隐私 | 默认 hash-only，显式上传 |
| Shared-first/精确版本全局 gate | 拒绝 | private 保持支持；shared 仅显式 pilot/mutation gate |
| `sourceId` 单键 | 拒绝 | 使用完整 authenticated `SourceRef/ThreadRef` |
| 所有 Turn 强制完整 HTTP Bundle | 拒绝 | 小 Spine 内联，大 payload/Spine 才 Range |
| 一个 generic `v3.command.submit` | 拒绝 | typed operation union + module policy |
| 新 DB 不读/不迁移旧数据 | 拒绝 | 非破坏性迁移、保留 rollback、pending 不自动派发 |
| 不兼容 v2、完成后删除 v2 | 拒绝 | additive adapters，退役需独立真实设备门禁与授权 |

## 8. 规范目录

- [01-domain-and-receive.md](01-domain-and-receive.md)：身份、authority、Turn Spine、接收链、覆盖、存储。
- [02-wire-and-operations.md](02-wire-and-operations.md)：wire envelope、消息族、ACK、发送/控制状态机。
- [03-feature-module-contract.md](03-feature-module-contract.md)：Feature Manifest 与 Codex 功能接入矩阵。
- [04-migration-and-acceptance.md](04-migration-and-acceptance.md)：兼容、迁移、容量、安全、测试和发布门禁。
- [05-protocol-registry.md](05-protocol-registry.md)：首版完整消息注册表与 schema 完整性门禁。
- [06-current-source-map.md](06-current-source-map.md)：当前源码路径、真实职责、风险与目标接线。
- [protocol-registry.v1.json](protocol-registry.v1.json)：138 个消息类型的机器可检查冻结候选。
- [schemas/protocol-registry.schema.json](schemas/protocol-registry.schema.json)：消息 registry 自身的 Draft 2020-12 schema。
- [scripts/validate-protocol-registry.mjs](scripts/validate-protocol-registry.mjs)：跨消息唯一性、response 引用、policy、subscription cleanup 与 scope 门禁。

## 9. 变更本规范的规则

以下改变必须先新增 ADR，并同时修改 TS/Dart schema、golden vectors、兼容矩阵和故障测试：

- 身份键或 authority 归属；
- Turn Spine 的完整性定义或可见门禁；
- operation 的 replay policy；
- feature 的 storage owner/delivery mode；
- v2/legacy 兼容退役；
- shared daemon 的 owner/writer 模型；
- 数据上限、认证范围或诊断隐私边界。

单纯新增可选字段、未知 item passthrough 或新 UI surface，不得改变旧字段语义。协议字段只能 additive；
删除或重解释必须升级对应 feature major，而不是升级整个 App 的总版本开关。
