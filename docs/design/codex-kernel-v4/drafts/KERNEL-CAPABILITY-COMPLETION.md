# Codex Kernel K-001–K-026 能力补全草案

状态：`DRAFT_FOR_ROOT_INTEGRATION / DESIGN_ONLY / IMPLEMENTATION_NOT_AUTHORIZED / RUNTIME_NOT_RUN`

本文与同目录的 `K-CAPABILITY-COMPLETION.csv` 只补齐 K-001–K-026 的能力绑定。它不是第二份 Kernel 设计，不覆盖 `02-ARCHITECTURE-AND-OWNERS.md`、两个 Phase 1 草案或它们的机器矩阵，也不授权产品源码、数据库、Provider、Bridge/App、`8765`、构建、部署或发布动作。

## 1. 输入、事实和不可越过的边界

- 设计载体起点：`6f659ad7534b28cd1aac299e4a5da5cf4ec48ea7`。
- 当前源码事实仍绑定 `main@a706200233c55cc82d7a17e433f80f132d0f280d`、tree `ac85f620445151f45eda856f55f4b96ee442f41a`；本轮只静态确认 donor source/test 路径存在，不把源码存在写成运行时证明。
- `SourcePartition` 永远是 `(bridgeIdentityId, bridgeInstanceId, codexSourceId)`；route、IP、URL、标题、正文、时间、runtime session ID 都不是数据身份。
- actor 只由 Bridge authenticated connection context 注入。任何业务 payload 中的 `actor/deviceId/claimantId` 都没有授权力。
- Provider durable history 是历史事实权威。Provider refresh 是 bounded durable read，必须走 evidence → candidate → verification → `CanonicalProjectionWriter`；它不是 live producer。
- operation admission、fingerprint、lane、dispatch barrier、terminal 和 reconcile 只归 `OperationKernel`。`OUTCOME_UNKNOWN` 永不自动重发。
- Bridge timeline 只有 `CanonicalProjectionWriter`；Mobile replica 只有 `ReplicaApplyWriter`。UI、feature handler、observer、resource service、diagnostics 和 transport 都不能成为第二 writer。
- live 只有 generation/source-fenced memory overlay；只有 strong Provider turn/item identity 能原位晋升。
- 不存在可达的 V2、Mirror writer、legacy runtime、dual read/write 或 Claude route/wire/DDL/capability。旧源码只作 donor behavior、失败证据和 characterization tests。
- 不创建新 core、owner、DB、event bus 或通用 gateway。本文出现的 controller/presenter 是现有 root owner 下的 Phase 2 适配器，不是新的事实权威。

## 2. 本补全表如何成为薄绑定层

`K-CAPABILITY-COMPLETION.csv` 是 26 条逐项账本，每条均绑定：

1. 用户可见效果；
2. `02-ARCHITECTURE-AND-OWNERS.md` 或 Phase 1 已存在的唯一 owner；
3. Bridge、Mobile、Native 或纯 UI 的执行位置；
4. 当前 donor source/test 路径；
5. Phase 1 semantic/matrix/operation 引用；
6. Phase 2 controller/UI 剩余工作；
7. typed state、typed error、容量和 unknown 行为；
8. 持久化或明确 `NO_STORAGE`；
9. 端到端 data flow；
10. 一条必须故意失败的能力向量；
11. 静态、自动测试、Provider/runtime、WSS/SQLite、UI/device 和 release 分层验收；
12. donor disposition 与实施回退点。

CSV 中的 `SOURCE_PRESENT_STATIC` 只表示本轮在绑定源码树中确认路径存在；`TEST_PATH_PRESENT_NOT_RUN` 表示测试文件存在但没有执行。所有 Provider、runtime、SQLite、WSS、UI、Native、device 和 release 验收当前均为 `NOT_RUN`。

## 3. 目录、生命周期与 timeline 绑定

### 3.1 K-003：ConversationCatalog 只有一个目录事实入口

`ConversationCatalog` 以 `(SourcePartition, providerThreadId)` 为 row identity。Provider catalog refresh 进入 Phase 1 `P1-RD-003` bounded read，并由 `CanonicalProjectionWriter` 提交 catalog head；不允许 V2、Mirror 或 legacy recent list 同时写目录。

目录必须同时表达：

- new-thread discovery、search/filter、Desktop project presentation grouping、recent mode；
- archive/restore/delete fact、pin、unread watermark、important visibility；
- `COMPLETE`、`PARTIAL + Gap`、`DEGRADED + last-good` 和 exact `EMPTY_PROVEN`；
- stable row/project keys，刷新、Working/Need You、pin 或 runtime attach 不能销毁 mounted row state。

project grouping、pin、read watermark 和 display order 是产品投影/本地偏好，不进入 conversation identity。新建 placeholder 只能是 operation-local UI；只有 Provider 返回 strong thread ID 且 catalog/relation fact 提交后才成为 durable catalog row。

### 3.2 K-004：生命周期 mutation 统一通过 OperationKernel

read-only `open` 只挂载 Mobile last-good replica，不 resume、不 attach、不抢 writer。用户首次交互才可请求精确 runtime attachment。`start/rename/archive/restore/delete/fork/edit-from-turn/review` 分别绑定 Phase 1 typed operations；不能在 `websocket.ts` 的 giant switch 中保留另一套终态。

- `start` 以 source-scoped creation target 开始，Provider strong thread ID 返回后再绑定 conversation。
- `fork`、`edit-from-turn` 和 review child 由 `RelationGraph`记录 relation，但 mutation admission/dispatch 仍归 `OperationKernel`。
- archive/restore/delete/rename 的成功只来自 command-specific Provider readback；receipt 不是成功。
- deep link 只解析 exact `ThreadLocator`，然后调用 catalog/replica open；它本身不是 mutation。
- 任何 `OUTCOME_UNKNOWN` 保留 ledger，后续只读 reconcile；不得靠 catalog 暂时缺行推断 delete/archive 成功。

### 3.3 K-005：唯一 TimelineItem registry

Timeline item discriminant 最终只能进入 root `contract-registry.json`；本文冻结需要被同一 registry 覆盖的最小集合，不创建第二 registry：

| item kind | owning fact / relation | Mobile rendering contract |
|---|---|---|
| `USER_INPUT` | Provider durable item；sender-local row 由 operation correlation 原位晋升 | user bubble；不按 text/time 合并 |
| `ASSISTANT_OUTPUT` | Provider turn/item | intermediate 或 final 由 Provider shape/turn completion evidence决定 |
| `REASONING_SEGMENT` | exact turn/item/segment | process disclosure；折叠时不解析重详情 |
| `TOOL_CALL` | exact turn + tool-use ID | summary row；详情按 ID 加载 |
| `TOOL_RESULT` | exact turn + matching tool-use ID | 回挂发起 segment；不能挂到下一 assistant 文本 |
| `PLAN_ITEM` | Provider timeline item | 原位更新；不是 Goal 或 product document |
| `CONTEXT_COMPACTION` | active turn process item | 当前 turn 的 process surface |
| `MANUAL_CONTEXT_COMPACTED` | independent Provider compaction turn | timeline 分割线；不伪装 assistant result/tool |
| `IMAGE_REF` | canonical item 中 opaque content ref | placeholder → authorized bounded preview；collapsed 不取 bytes |
| `ARTIFACT_REF` | canonical item 中 opaque content ref | 复用 ProductPlatform resource/preview/download/share |
| `INTERACTION_MARKER` | exact Interaction identity 的可见投影 | 只显示状态；响应 authority 仍在 InteractionBroker |
| `UNKNOWN_ITEM` | 保留 raw type digest、identity/provenance 和 bounded safe summary | 明确 unsupported/read-only；不得丢弃邻接项或猜 renderer |

所有 item 共用 source/thread/turn/item identity、identity strength、content hash/ref、Provider fact time、provenance 和 coverage island。`UNKNOWN_ITEM` 是 forward-compatible 显示状态，不允许变成 generic command、raw DTO 或 arbitrary JSON renderer。

## 4. 长历史、折叠和时间

### 4.1 K-008：独立的 target-centered 历史 viewport

- ordinary latest surface 只挂载约 200 个 renderable envelopes；产品 ceiling 仍是每 conversation 100,000 normalized entries / 64 MiB。
- user-turn index 覆盖全部已提交真实用户轮次，但索引只存 stable locator/ordinal 和必要摘要，不复制 timeline body。
- 远距跳转先进入 `TARGET_LOADING`，读取目标附近 bounded window 后一次定位；不得逐页挂载中间几万条，也不得替换 latest cache。
- historical viewport 与 latest timeline 分离，拥有 earlier/later edge；最多两个 exact-turn read 并发。edge failure 只让该 edge retryable。
- 返回 latest 只丢 viewport，不丢 canonical cache、live accumulation、draft 或原来的 paging state。
- 每条可见 adjacency 必须来自 Phase 1 order proof；island 边界保留 Gap，时间不能补边。

### 4.2 K-009：两层折叠是 render-only 本地状态

第一层按 assistant update 拥有的 reasoning/tool/result segment 折叠，第二层折叠历史 turn 的 intermediate updates；final result 始终在外层。当前 live progress 与最新工具摘要在外层，Plan/Todo 与当前进度同层原位更新。

折叠 key 使用 strong Provider item/turn ID 或当前 evidence segment 内的 `EvidenceItemKey`；不得使用 `live:`/`entry:` 前缀、正文或 Widget index。mounted page 内的 canonical/live 增量不能把已展开项折回；关闭/重新激活会话默认折叠历史过程。`Collapse all` 只改本地 presentation state。折叠时不构造 tool detail、image/artifact preview；展开后才按 ref/ID 有界加载。该状态不写 canonical、operation 或 replica DB。

### 4.3 K-010：时间只负责展示

`providerFactTime` 来自 Provider/电脑事实，可缺失并带 provenance。Mobile 在 bubble/semantic row 内紧凑显示到秒并按用户时区格式化；tool/process 时间位于 disclosure label 附近，不插入全宽 timeline row。缺失显示 `TIME_UNKNOWN` 或不占位，绝不用手机当前时间补事实。迟到、相同、倒序或跨时区的时间均不能改变 item identity、island adjacency、catalog identity 或 canonical order。

## 5. Composer、outgoing 与操作

### 5.1 K-011：draft/composer 是 protected local state

draft key 绑定 stable source/thread locator 和 composer surface；catalog row 暂时消失、archive、replica clear、source route 切换或 App restart 都不能 cascade 删除。selection-to-conversation 只把选中文本放入 composer，语音、picker/drop 和 prompt history 也只产生 local composer input；都不能绕过 `START_TURN`。

附件必须先成为 immutable `ContentRef` 才能提交。完全离线的新消息按 U-001 默认 `HOLD_FOR_CONFIRMATION`；reconnect 本身不发送。Prompt History 在 application ready 后按 authenticated Bridge identity、revision 和 request correlation 读取，不进入 startup critical path，也不成为 draft authority。

### 5.2 K-012：一个逻辑 outgoing row

Mobile 先创建 `(ThreadLocator, operationId)` sender-local row；Bridge durable admission 后仍更新同一 row，Provider receipt 只变成 `PROVIDER_ACCEPTED`，直到 certified operation/provider correlation 发现 canonical user item 才原位晋升为 canonical。ACK 丢失只能用相同 ID + fingerprint 查询 admission。其他设备接收 canonical user item/operation projection，不接收发送设备的 local ACK。

禁止 text/time/近似 UUID 合并。若 strong correlation 缺失或冲突，保留 local pending 与 Provider fact 两条可解释记录并进入 reconcile；绝不为了“看起来没有重复”删除任意一条。

### 5.3 K-013/K-014：三类输入状态与 typed actions 不混合

- Mobile offline intent：Mobile protected local state，Bridge 未接收；默认等待用户确认。
- ordinary online outgoing：socket/admission 状态，不是 conversation queue。
- Bridge next-turn queue：`OperationKernel` durable FIFO，最多 16，带 lane/entry revision；Mobile 只投影与发送 exact edit/cancel requests。

stop、steer、compact、review、retry-as-new 和 reconcile 均使用 finite typed operations。`reconcile` 不含原 payload 或 dispatch flag；`retry` 不是重开旧 `OUTCOME_UNKNOWN`，而是在策略允许时产生新 operation ID。

## 6. Interaction、自动批准、ThreadState 与 relations

### 6.1 K-016/K-017：一个 InteractionBroker，一个 Bridge policy owner

Approval、Question、MCP elicitation、ExitPlan 共享 `InteractionBroker` 的 exact source/thread/turn/request/runtime fence、单 ACTIVE claim 和 response barrier，但各自使用独立 typed prompt/response。unknown/plugin install/auth form 只读且 manual。

自动批准策略由 Phase 1 已登记的 `AutoApprovalPolicyStore` 在 Bridge 持久化；它不是第二 Interaction store。策略 mutation 使用 `OP-038/OP-039`，actor 由 server context 注入。只有当前 Bridge-owned、live、可 claim 的 request 才能评估；Desktop/private other-owner request 不可批准。rule unknown、shell parse ambiguity、`rm` 与其他 destructive/Git worktree-destroying operation、question、plugin/connector、auth form 全部 fail closed。

Mobile 只显示 policy revision、enabled/disabled/pending、匹配规则和 bounded audit fact。离线 emergency disable 可保留 protected local intent，但在 Bridge ACK 前必须显示 pending，不能声称电脑已关闭策略。

### 6.2 K-015/K-018/K-019：ThreadState 不变成万能文档

- settings 是 complete/sparse authoritative snapshot；每个 mutation 只改目标字段并 readback 全 tuple。未知 enum 可见只读；unknown field 无法安全保留时拒绝写。
- Goal 是 Provider-backed thread state，Bridge 只存 rebuildable head/operation evidence；不 resume thread、不写 timeline/outbox、不建 CC-owned Goal document。
- Plan 是 timeline item；collaboration 是 settings；ExitPlan 是 Interaction。三者各自服从现有唯一 owner，不允许为 K-019 建一个 aggregate owner 或 Plan store。

### 6.3 K-020/K-021：child 复用 ordinary conversation

persisted Side Chat 是 durable child + `PERSISTED_SIDE_CHAT` relation；ephemeral Side Chat 只在 source/provider/runtime fence 下存在于 memory registry；ordinary Fork 继续是独立 relation。subagent 是 Provider relation + ordinary child catalog/timeline/live，Home 主目录不列内部 subagent。

child list/history/watch 必须有界并验证 source、parent、ancestor。subagent cancel 在 Provider exact-child cancellation/terminal 未认证前保持 disabled；不能用 generic stop 猜测实现。relation 只定位 child，不复制 child timeline。

## 7. Insights、resource、diagnostics 与多轴状态

### 7.1 K-023：Insights 是只读 source-scoped projection

context、token、account quota 和 model-specific quota 以 `(SourcePartition, providerThreadId)` 缓存。runtime session ID 只可作为旧 Provider request alias，attach 不能更换 cache identity。新请求必须 request-correlated；legacy uncorrelated lane single-flight，timeout 后 quarantine 到 reconnect。

未知值显示 unknown/unavailable，不能显示 `0`；stale last-good 保留来源和时间。quota 不能推断 model、effort、permission、Plan、activity 或 Provider attachment。refresh 是 read-only action，不创建 runtime、不写 settings。

### 7.2 K-024：timeline 只持有 ref，resource service 才持有 bytes

`CanonicalTimeline` 只提交 `IMAGE_REF`/`ARTIFACT_REF` 及 immutable digest、mime/size/provenance；Bridge ProductPlatform 的现有 `ImageStore`、`ArtifactManager`、`GeneratedArtifactStore` 与 Mobile preview/gallery/share/download 解析 bytes。control wire 不出现 raw base64、本机 path 或 bearer token。

ref 必须绑定 source、content digest、authorization/expiry 和 range policy。过期、缺失、过大、unsupported mime 或 digest mismatch 显示 typed fallback，并保留 metadata、retry/download/share 中仍安全可用的动作。collapsed result 不 fetch。任何 resource failure 都不能删除 canonical item 或把它改写成文本。

### 7.3 K-025：诊断快照读取真实状态，不重写业务算法

诊断 builder 直接捕获当前 Mobile SQLite/Repository/Cubit、ChatMessageList projection、Home grouping/status 和 bounded trace。只有用户显式动作可创建；Mobile 写盘前递归脱敏，Bridge 归档前二次 fail-closed 校验。上传复用 authenticated resumable transfer/receipt，不增加 protocol/event bus；报告绑定完整 `SourcePartition + providerThreadId`。

报告、trace、body 和归档均有界。确定性身份、digest、inode 或脱敏失败时删除本次原始暂存并不留“成功” receipt；不同报告解析串行。diagnostics 永远只是证据，不修写 canonical、operation、settings 或 status。

### 7.4 K-026：状态必须保持六轴以上的组合事实

唯一 `SyncProjection` 输出以下独立轴，UI 再映射成 Need You、Working、Compacting、terminal 等视觉：

| axis | 最小 typed values | 规则 |
|---|---|---|
| `availability` | `AVAILABLE / UNAVAILABLE / DEGRADED / UNKNOWN` | durable conversation 是否可读；不由 runtime attachment 单独决定 |
| `activity` | `STARTING / RUNNING / COMPACTING / IDLE / UNKNOWN` | execution activity；`notLoaded` 不等于 idle |
| `attention` | `NONE / NEEDS_APPROVAL / NEEDS_ANSWER / NEEDS_MCP / NEEDS_EXIT_PLAN / UNKNOWN` | exact Interaction projection；旧请求/正文不能猜 Need You |
| `result` | `NONE / SUCCEEDED / FAILED / CANCELLED / UNKNOWN` | exact turn/operation terminal fact |
| `runtimeAttachment` | `NOT_LOADED / LOADED / ATTACHED / OWNED_ELSEWHERE / RECONCILING / UNKNOWN` | attachment/control fact，不是 availability |
| `executionSource` | `BRIDGE / DESKTOP_APP_SERVER / DETACHED / UNKNOWN` | 一个 conversation 仍只有一个 execution host |
| `confidence` | `AUTHORITATIVE / OBSERVED / STALE / UNKNOWN` | 决定 UI 是否可声称事实，不改变其他轴的 raw value |

status key 绑定 SourcePartition/thread 和 schema revision；旧 sourceEpoch/authorityGeneration 只能丢弃。unknown future value 保留 raw value 并以 unknown/read-only 显示。普通 idle 或 unknown/notLoaded 不显示 Ready badge；sync/download/resource progress 是 action indicator，不成为新 conversation state 轴。

## 8. 持久化归属摘要

| 数据 | 唯一存储归属 | 明确禁止 |
|---|---|---|
| catalog/timeline/coverage/gap/head/publication | Phase 1 logical Bridge cache + Mobile rebuildable replica；分别由 canonical/Mobile sole writer 写 | 第二 DB、Mirror/V2/legacy writer、observer/live body 写入 |
| operation/queue/interaction/settings/Goal/relation projection | Phase 1 已定义的 root logical ledgers/heads；Mobile 只收 durable projection | UI/Cubit/private feature table成为 authority |
| live/ephemeral Side Chat/historical viewport/fold state | bounded memory；fold/viewport 是 mounted presentation state | durable history、sync stream、诊断 payload表 |
| draft/local intent/local preference | Mobile protected local-state repositories，独立于 rebuildable replica | replica/session delete cascade、cache clear、route alias重绑 |
| auto-approval policy | Bridge `AutoApprovalPolicyStore`；Mobile policy replica + pending local disable intent | phone parallel supervisor、第二 Interaction store |
| insight cache/status projection | source-scoped rebuildable projection | quota反推设置、runtime alias改 durable key |
| image/artifact bytes | 现有 ProductPlatform resource stores/content plane；timeline 只存 opaque ref | control wire inline bytes/path/token、resource failure改写 timeline |
| diagnostics package | 用户触发的 bounded temporary/archival storage + transfer receipt | background telemetry、业务 DB、第二上传通道 |

本文不决定物理表数、DB filename 或 migration；最终仍由 root registry/schema/DDL 集成并通过故意失败约束。v4 默认 `NO_IMPORT`，旧数据只读保留且新 runtime 不打开。

## 9. 验收与回退

- 26 条 capability 都必须先通过 CSV 所列 deliberate negative vector；只测 happy path 不算完成。
- H00–H18 中相关 gate 必须按 capability row 逐项给出 `PASS/FAIL/BLOCKED/NOT_RUN`。当前只有 source/test path 的静态存在性已核对；测试执行和所有 runtime gate 都是 `NOT_RUN`。
- K capability 的 Phase 2 adapter/UI 只能在其 Phase 1 owner/port 已通过相应 I-stage 后接回。旧 publication/dispatch owner 必须先停止，再激活新 owner；不能双跑比较。
- 回退按 `IMPLEMENTATION-VALIDATION-ROLLBACK.md` 的 `R-Ixx` 计划使用 feature adapter/UI revert 或整个未激活 slice 停用。operation 一旦到 `DISPATCHING/OUTCOME_UNKNOWN`，ledger 必须保留并先只读 reconcile，禁止切回不知道该副作用的旧 mutation owner。
- resource、diagnostic、draft、queue、credential、settings、transfer checkpoint 和用户文件不得因 feature rollback 或 cache clear 被删除。
- candidate 回退是 whole-version rollback，不是同 binary 内恢复 V2/Mirror/legacy/Claude fallback。

## 10. 根决定冲突审计

以下历史表述已由更晚且更具体的 root/v4 决定收口，不再是未决冲突：

- 历史两元 cache identity `(bridgeInstanceId, codexSourceId)` → v4 cross-process `SourcePartition` 固定三元组并加入 `bridgeIdentityId`。
- 历史 Mobile-owned auto approval → 更晚 `Bridge-owned automatic approval`、Phase 1 `OP-038/OP-039` 与本补全统一为 Bridge policy owner。
- 历史 Mirror/V2/full-download/legacy fallback → v4 明确 no-V2/no-Mirror-writer/no-legacy-runtime/no-import；只保留 donor evidence。
- 历史 ephemeral-only Side Chat → 更晚决定及 Phase 1 固定 persisted + ephemeral 同时保留，ordinary Fork 独立。

本轮没有发现仍会迫使新增 core、owner、DB 或第二 writer 的未决架构冲突。仍开放但已被 root seam 安全包住的用户选择是：U-001 offline ordinary input、U-002 risky resend after `OUTCOME_UNKNOWN`、U-003 claim UX/lease、U-005 diagnostics retention/export、U-006 cache retention/capacity/at-rest protection、U-007 certified Codex version policy。它们在用户裁决前使用 root 推荐的 fail-closed seam，不得由 K capability UI 私自决定。

## 11. 当前结论

本补全只达到 `DESIGN_ROWS_COMPLETE_FOR_ROOT_REVIEW`。它未把草案整合进最终 registry/schema/DDL，也未执行测试、Provider probe、runtime、SQLite/WSS、UI、Native、device 或 release gate；因此不能标记 `PHASE1_DESIGN_FROZEN`、`FULL_DESIGN` 或任何实现完成状态。
