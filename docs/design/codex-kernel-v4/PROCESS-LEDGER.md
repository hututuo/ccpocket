# 本地完整设计过程账本

状态值：`NOT_STARTED / IN_PROGRESS / DRAFTED / INTEGRATED / STATIC_VERIFIED / REVIEWED / USER_ACCEPTED / BLOCKED / SUPERSEDED`

## 基线

- worktree：`/Users/developer/AI agent/Codex/_keep/projects/ccpocket-worktrees/ccpocket-codex-kernel-v4-local-design-20260830`
- branch：`codex/codex-kernel-v4-local-design-20260830`
- start HEAD：`a706200233c55cc82d7a17e433f80f132d0f280d`
- start tree：`ac85f620445151f45eda856f55f4b96ee442f41a`
- dirty main：未修改；其既有 untracked 文件不纳入本分支。
- implementation：`NOT_AUTHORIZED`
- deployment/release：`NOT_AUTHORIZED`

## 里程碑

| ID | 内容 | 状态 | 证据/提交 | 未越过门禁 |
|---|---|---|---|---|
| D00 | 输入、决定和源码基线冻结 | STATIC_VERIFIED | `d152b118` | 无实现 |
| D01 | Phase 1 identity/authority/receive/cache/order/live | DRAFTED | source `codex/v4-design-p1-identity-read-20260830@0cd9bbeb`; integrated and root-amended | 无生产路由 |
| D02 | Phase 1 operation/queue/interaction/state/relation | DRAFTED | source `codex/v4-design-p1-operations-20260830@e1c8dbf2`; integrated and root-amended | 无 provider mutation |
| D03 | Phase 1 wire/schema/DDL/ports/semantic SSOT | IN_PROGRESS | Sol xhigh branch `codex/v4-design-p1-protocol-storage-20260830` | 无 DB 创建/迁移 |
| D04 | Phase 2 device/route/files/media/Git/capture | DRAFTED | source `12b647be`; follow-up `bb8fb837`; integrated, root-aligned and candidate bindings closed | 无 native/runtime 变更 |
| D05 | Phase 2 notification/background/native/shell/visual | DRAFTED | source `codex/v4-design-p2-native-product-20260830@6bf661eb`; follow-up `500269ac`; integrated and root-aligned | 无 App 构建/发布 |
| D06 | 52 能力、25 审查问题、9 决定与实验闭环 | IN_PROGRESS | Luna max audit/source branches | 设计闭环不冒充 runtime |
| D07 | 累计 FULL_DESIGN 与实施/回退计划 | IN_PROGRESS | `04-UNIFIED-DOMAIN-AND-DATAFLOW.md`; `05-CONTENT-AND-PRODUCT-OPERATIONS.md` | 审核前不实施 |
| D08 | 机器验证与独立审查 | NOT_STARTED |  | P0/P1 清零后才打包 |
| D09 | 最终审核包 | NOT_STARTED |  | 停在 USER_REVIEW_PENDING |

失败记录不得覆盖；每次集成记录来源 branch/commit、冲突决策、验证结果和最后安全回退点。

## 根决策断点

| ID | 内容 | 状态 | 验证 | 安全回退 |
|---|---|---|---|---|
| R00 | 一次完成两个累计设计阶段；Phase 2 复用 Phase 1 语义和窄接口，不建立第二套架构 | STATIC_VERIFIED | `03-CUMULATIVE-DESIGN-AND-FREEZE-GATES.md`; `git diff --check` | `fc850e00` |
| R01 | 集成实施、验证、迁移与逐 feature cutover 草案 | DRAFTED | source `codex/v4-design-implementation-validation-20260830@bb82d659`; integration `32389376`; 3 files/537 lines; source branch clean | `83f78cfb` |
| R02 | 集成 Phase 1 identity/receive 草案并关闭 root identity/live owner 问题 | DRAFTED | source `codex/v4-design-p1-identity-read-20260830@0cd9bbeb`; integration `9d524919`; CSV 37×22 parse/no blanks; `git diff --check` | `3af1e030` |
| R03 | 集成 52 项 current-source reuse/disposition 事实表 | DRAFTED | source `codex/v4-design-source-reuse-20260830@c3b3dcc9`; integration `76aabf65`; 52×9 parse/no missing paths; root CodeGraph structural cross-check | `10134dec` |
| R04 | 集成 Phase 1 operation/interaction/settings/Goal/relation 草案并去重合同 | DRAFTED | source `codex/v4-design-p1-operations-20260830@e1c8dbf2`; integration `331e7ea0`; root 38×23 parse/no blanks; `git diff --check` | `fc8f5b18` |
| R05 | 集成 112 行 pre-integration 审查/需求/实验 closure 基线 | DRAFTED | source `codex/v4-design-audit-coverage-20260830@49482abf`; integration `69a2066b`; 112×9/unique/no blanks; 23/23 artifact refs | `28769262` |
| R06 | 收口 9 项历史用户决定，区分 7 项待审与 2 项已固定 | STATIC_VERIFIED | `matrices/USER-DECISION-REQUIRED.csv`; 9×8/unique/no blanks; U-008/U-009 user-fixed | `819d48a8` |
| R07 | 集成并对齐 P-014–P-026 native/product shell 设计 | DRAFTED | source `6bf661eb`; follow-up `500269ac`; integrations `ee267415`/`7a7293e9`; CSV 13×14/无空白；`git diff --check` | `00e8418d` |
| R08 | 集成并对齐 P-001–P-013 device/files/media/Git/capture 设计 | DRAFTED | source `12b647be`; follow-up `bb8fb837`; integrations `819d48a8`/`e7edd899`; CSV 13×17/无空白；root content/operation closure | `239cab16` |
| R09 | 统一 SourcePartition、OperationKey、domain owner 与 operation lifecycle owner | DRAFTED | migration uses full triple/no provider key；operation matrix 38×24；ContentRef family and Product variants frozen；`git diff --check` | `e7edd899` |

R01 复核发现：草案沿用了原提案 `P-001…P-027` 表示 Provider probe，同时 Phase 2 又用 `P-001…P-026` 表示产品能力，存在 ID 冲突；最终集成必须把前者迁移到独立 `E-CODEX-*` 实验 ID。`design` 状态也必须在最终包改为 `USER_REVIEW_PENDING`，不能继续写成 `NOT_RUN`。该问题保留在账本中，不能用后续通过结果覆盖。

R02 根裁决：跨进程 `SourcePartition` 固定为 `bridgeIdentityId + bridgeInstanceId + codexSourceId`；`BridgeInstanceId` 迁到独立 `BridgeInstallationStore`；`CodexSourceId` 由 `SourceRegistry` 生成并持久化，路径只作 locator；Provider refresh 从 live producer 列表移除，严格走 durable read/candidate/verify/commit。上述修改只变更设计文档，没有实施源码或运行验证。

R04 根裁决：统一 owner 为 `OperationKernel`；删除重复的 `RETRY_START_AS_NEW` discriminant，重发只能是带 `retryOfOperationId` 的新 `START_TURN`；`EXPIRE_INTERACTION` 明确为内部 transition；fingerprint 使用 RFC 8785 且不改写 Unicode；control envelope 回到 64 KiB；`OUTCOME_UNKNOWN` 是不可再 dispatch 的 terminal，后续只追加只读 reconcile observation；settings 未知字段不得盲目回写。

R05 是“集成前全部 OPEN”的机械基线，不能作为最终 closure 结果。用户已授权本地累计完成两个设计阶段，故原 `Phase 1 后暂停 Phase 2` 条款被当前任务授权取代；只有实施仍受审核后另行授权约束。最终矩阵必须由根 Agent 对已集成合同逐行升级，U/实验仍保持未闭合。

R07 根裁决：P-024/P-026 属于 ProductPlatform/Mobile shared host，不归 Session Kernel；P-025 只有 authoritative effort 归 `ThreadState/settings`，motion/status/insights 均为只读展示；notification action 必须覆盖 approval/question/MCP elicitation/ExitPlan 的 typed variant，未知 variant fail closed。若旧 native action host 不能无损携带 variant/actionId，只允许 Open App，不能猜测并提交交互响应。

R08/R09 根裁决：unfinished bytes 使用 `ContentOffer`，finalized bytes 使用带 required SHA-256 的 `ContentRef`，HTTP lease 统一为 sealed-target `ContentAccessTicket`，composer 使用 immutable `ComposerAttachmentRef`。Product mutation 以 namespaced sealed variant 注册进同一个 operation registry；旧 route-keyed/二元 data cache `NO_IMPORT/NO_RUNTIME_MIGRATION`。mutable Git/event index 分页，可复用/导出 bytes 才物化 ContentRef。`OperationKey=(SourcePartition,operationId)`；operation lifecycle writer 与 domain aggregate owner 在矩阵中分列，InteractionBroker/Product service 不写 operation ledger。

## 隔离异常记录

| ID | 时间 | 事实 | 处理 | 复核 |
|---|---|---|---|---|
| F-001 | 2026-08-30 00:43–00:47 +08:00 | 审查 worker 将 `docs/design/codex-kernel-v4/drafts/.probe`（6 bytes，SHA-256 `25be3235…`）和未完成 `AUDIT-COVERAGE-CLOSURE.csv`（12,322 bytes，SHA-256 `4b327709…`）误写到 dirty main；它们不在任务开始的既有 untracked 清单中，且与 worker 最终文件 hash 不同 | 根 Agent 只删除这两个可明确归因的临时文件及空目录；未触碰用户既有 untracked 文件 | main HEAD `a706200233c55cc82d7a17e433f80f132d0f280d`、tree `ac85f620445151f45eda856f55f4b96ee442f41a`；status 恢复为原 5 项 untracked |
