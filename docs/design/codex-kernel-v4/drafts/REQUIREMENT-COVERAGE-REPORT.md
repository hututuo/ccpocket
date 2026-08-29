# CC Pocket Codex Kernel v4 要求覆盖与设计闭环报告

状态：`MECHANICAL_AUDIT_ONLY / DESIGN_ONLY / NO_RUNTIME / NO_RELEASE`

本报告只核查输入包中的要求、设计工件、阶段归属、owner、故意失败向量和当前闭环状态，不制定最终架构。`input-present`、方向一致、源码存在和历史事实均不视为 `CLOSED`。

## 1. 身份与边界

- 审计 worktree：`/Users/developer/AI agent/Codex/_keep/projects/ccpocket-worktrees/ccpocket-v4-design-audit-coverage-20260830`
- branch：`codex/v4-design-audit-coverage-20260830`
- 起点/当前基线：`d152b118045264abeb8a1760b94113e323e46283`
- 输入目录：`/Users/developer/Documents/Downloads/CCPocket-Codex-Kernel-Redesign-20260829-baseline-amendment-two-stage-v4`
- 产品源码事实基线是 `a706200233c55cc82d7a17e433f80f132d0f280d`，tree=`ac85f620445151f45eda856f55f4b96ee442f41a`；`d152b118` 是从该源码基线创建的设计载体提交，只新增设计文件。二者不是冲突的源码 HEAD：前者绑定产品事实，后者绑定设计过程。真正实施时仍须重新绑定用户批准的 exact upstream HEAD/tree。
- 输入锁中的 v4 ZIP SHA-256：`d0f597cc089850214ec5aece824a3eb0265e20e0ce0e0bbef27add1381f0e257`；原设计 ZIP：`d5c33a5455a1f1375efd4b68e0bb91844a5e6467c7115b3a204b4ea1faeeef76`；历史审计补遗 ZIP：`d45f622d5f0824e91b8254d31cb2a62629d1f29e9d23ced6b4f2f0ac45bbc02c`。
- 本次仅应产生 `AUDIT-COVERAGE-CLOSURE.csv` 与本报告；没有启动服务、连接 `8765`、改配置、迁移数据、构建 App、安装、部署、OTA 或发布。

## 2. 覆盖计数

| class | 数量 | ID 范围 | 当前状态计数 |
|---|---:|---|---|
| `REVIEW_PROBLEM` | 25 | P0-01..P0-15（15）+ P1-01..P1-10（10） | `OPEN_NOT_CLOSED` 25 |
| `ROOT_CAPABILITY` | 52 | K-001..K-026（26）+ P-001..P-026（26） | `INPUT_PRESENT_NOT_CLOSED` 52 |
| `CROSS_CUTTING` | 12 | D-001..D-012 | `PARTIAL_INPUT_NOT_CLOSED` 7；`ALIGNED_INPUT_NOT_CLOSED` 3；`CONFLICT_UNRESOLVED` 2 |
| `USER_DECISION` | 9 | U-001..U-009 | `USER_DECISION_REQUIRED` 9 |
| `EXPERIMENT_REQUIRED` | 14 | UNK-001..UNK-014 | `EXPERIMENT_REQUIRED` 14 |
| **总计** | **112** | — | **无任何 `CLOSED` 行** |

CSV 的固定列为：`id,class,required_design_artifact,phase,closure_rule,evidence_input,owner,expected_failing_test,current_status`。每行均有非空关键字段、唯一 ID 和一个明确的 negative/probe/decision gate 名称。

## 3. 闭环判定规则

每一行必须同时绑定设计工件、阶段、唯一语义 owner、执行位置、持久化边界、typed 输入/输出、状态/错误/容量/unknown，以及可故意打破该合同的失败向量。只有后续累计设计、事实或用户裁决与该行对账后才可改为 `CLOSED`。

`expected_failing_test` 是待实现合同的故意失败向量命名，不是本次已通过的测试。当前没有运行 Provider、SQLite、runtime、UI、native 或 device 验收；没有把输入包中的静态表、历史 probe 或推荐项冒充通过证据。

两阶段清单的 C-01..C-13 与 P-01..P-10 均至少被覆盖表的 `required_design_artifact` 引用（23/23）。这些是设计交付工件，不是额外要求行。

## 4. 阶段核查

- K 能力：24 项进入 `PHASE_1_SESSION_CONTRACT_OR_INTERFACE;PHASE_2_UI_REMAINDER_IF_ANY`；K-009、K-010 明确为 `PHASE_1_REVIEW_ONLY;PHASE_2_UI_OR_FEATURE_DESIGN`，不能把折叠/时间显示误报为 Phase 1 核心实现。
- P 能力：5 项为 `PHASE_1_CORE_CONTRACT`（P-001、P-002、P-010、P-025、P-026），11 项为 `PHASE_1_CORE_INTERFACE`（P-003..P-008、P-011、P-014、P-015、P-018、P-024），其余 10 项为 `PHASE_2_PRODUCT_DESIGN_ONLY`（P-009、P-012、P-013、P-016、P-017、P-019、P-020、P-021、P-022、P-023）。Phase 1 只冻结必要核心合同/接口，不能提前重写这些 feature。
- U 决定覆盖 operation、unknown outcome、interaction claim、通知隐私、诊断留存、cache 策略、Provider 版本、旧数据 importer 和 Cloud/Claude 解释；均保持 `USER_DECISION_REQUIRED`。
- UNK 实验按原 Wave 0/2/4/5/6/7 绑定到事实门禁。Wave 是原设计的 probe/实现路线，不等同于两阶段设计已接受；Wave 0 的 build/source 锁必须先于核心合同，Wave 8 的 importer 仍是 post-kernel 取舍。
- 输入 `CAPABILITY-PHASE-ACCEPTANCE-ROLLBACK.csv` 对 52 项统一标注 `DESIGNER_MUST_CONFIRM_AND_BIND`，因此其中的 phase/acceptance/rollback 是候选约束而非闭环证明。

## 5. 冲突与缺口

1. D-008 / P0-06 / K-020：原始提案把 persisted Side Chat、ephemeral Side Chat、ordinary Fork 做三选一；当前固定决定要求前两者都保留且 ordinary Fork 独立。覆盖表保留 `CONFLICT_UNRESOLVED`，必须在 C-07 累计修订工件中消解。
2. D-009 / P0-05 / K-018..K-019：原始提案把 Goal 当 CC Pocket document 并混合 Plan authority；当前固定语义是 Goal=Provider thread-state、Plan item=timeline、collaboration=settings、ExitPlan=interaction。需要 C-07 owner-split 合同和负例，不可仅改文字。
3. D-001 / P0-10：输入包承认没有完成目标 upstream checkout/symbol/真实接缝核对，而锁又给出另一份 source HEAD。根 Agent 必须先固定 exact checkout、commit、tree 和当前源码对照，再接受任何接缝结论。
4. D-004 / U-008：输入仍把 legacy data 留作宽泛待决项；范围锁要求默认 no-import，只有进程外、隔离、低成本且无运行时兼容负担时才可讨论。不能把推荐 importer 当作决定。
5. D-005 / P0-15：原包主要覆盖 Session Kernel，尚未证明 52 项用户可见能力和 Product Platform shell；C-02/P-09 必须补齐全账本，不能以 kernel 设计覆盖产品保留责任。
6. D-006 / P0-14 / P1-02 / P1-03：cache、coverage/gap/order、容量和 resource ticket 有方向性描述，但缺 identity、失效、二次读取预算、ticket 范围/过期/digest 和机器负例，均未闭环。
7. D-010 / P1-01 / P1-10：generic object/prose 不能作为 semantic SSOT；需逐语义唯一 owner、状态、错误、容量、unknown、Schema/DDL/生成类型和负例。
8. P-023：本地化条目包含 `EXPERIMENT_REQUIRED`；on-device translation 事实未验证前不能当作 Phase 2 已关闭能力，也不能翻译命令、路径或 secret。

## 6. 重复、映射与 orphan

- K/P 的同一 ID 同时出现在 preservation、phase acceptance 和 current-to-target 三张表中，这是预期的“能力—阶段—源码”证据分层，不是 156 项需求；CSV 只保留每个根能力一行。
- D-001..D-012 与 K/P 交叉引用是总原则覆盖，不额外加 12 个功能；U 也不是新能力。
- 原始 `UNKNOWN_EXPERIMENT_REQUIRED.csv` 有 14 个 UNK，原始 `07_PROBES_AND_ACCEPTANCE_GATES.md` 有 P-001..P-027 共 27 个 probe。后者是测试/证据目录，不应被误计为 27 个新的需求；本表只把 14 个明确 `UNKNOWN / EXPERIMENT_REQUIRED` 事实列为实验行。
- 当前结论要求的 U-001..U-009 与原始 proposal 的 UDR-001..UDR-013 不是同一 ID 集。可初步映射为 U-001↔UDR-009、U-002↔UDR-003、U-003↔UDR-004、U-004↔UDR-008、U-005↔UDR-007、U-006↔UDR-001/002、U-007↔UDR-010、U-008↔UDR-012；U-009 没有直接 UDR 对应。UDR-005/006 已被 D-008/D-009 固定语义取代，UDR-011/013 应分别归入 reader/resource 能力或另行处置，不能静默塞进 9 个 U。
- 原始 `DECISION_LEDGER.csv` 有 DEC-001..DEC-040；其中 DEC-003 是实验未知，DEC-035..DEC-040 与 U/固定决定交叉，但它们不是本次 9 条 U 的同义副本。根 Agent 需要建立历史 DEC/UDR→D/U/UNK/P 的明确 disposition，否则这些输入项是 orphan。
- 覆盖表自身的 112 个 ID 无重复、无空关键字段；未把 `DEC-*`、`UDR-*` 或 27 个 probe 伪装成额外覆盖行。

## 7. 必须由根 Agent 裁决

1. 继续区分设计载体 `d152b118+` 与产品事实基线 `a706200/tree ac85f6…`，并在实施开始时绑定用户批准的 exact upstream checkout；设计包不得把 carrier commit 冒充产品源码版本。
2. 审核 C-01/C-02/C-09 是否真的覆盖 52/52，确认每项唯一 owner、源码位置、阶段、验收和 rollback，而不是只接受表格存在。
3. 在 C-07 中确认 D-008/D-009 的已固定产品语义，并从原始提案删除三选一/错误 Goal authority 的残留；不得新增第三套 timeline 或 document authority。
4. 对 U-001..U-009 作显式用户裁决；推荐默认不构成决定，未裁决策略不能写入不可迁移的永久 Schema。
5. 为 UNK-001..UNK-014 指定目标 Codex build、fixture、probe 命令、原始输出位置和“失败时禁用/fail-closed”结果；历史 0.146.0 事实不能替代目标版本实验。
6. 确认 P-001..P-026 的 Phase 1 core contract/interface 与 Phase 2 feature-local 边界；只有实际核心压力才可新增 typed seam，不得预建多核心、万能 gateway 或九套空接口。
7. 原输入要求 Phase 1 后暂停，但用户已在本任务明确授权本地一次完成 Phase 1 与 Phase 2 设计；因此 Phase 2 设计可继续累计收口。该授权不包含任何源码实施 C0-C6、生产 `8765`、Bridge/App 构建、IPA/OTA、安装、真机或 stable；最终仍停在 `USER_REVIEW_PENDING`。

## 8. 已执行检查

- Ruby CSV parser：header 精确匹配；112 行；112 个唯一 ID；9 列均无空值。
- 类别计数：25 / 52 / 12 / 9 / 14，合计 112。
- C/P 两阶段清单工件引用：23/23。
- `git diff --check`：通过。
- `AUDIT-COVERAGE-CLOSURE.csv` SHA-256：`483c04b21deff9f7fd2f55feacee03f1f83f6b1b9733f3b3cb88663837e28f1f`。
- 未运行服务、`8765`、Provider、SQLite migration、Bridge/Mobile runtime、UI/native/device、发布或安装检查；这些状态均保持 `NOT_RUN`。
