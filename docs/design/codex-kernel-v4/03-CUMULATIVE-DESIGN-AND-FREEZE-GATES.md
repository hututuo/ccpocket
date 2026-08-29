# 累计设计与冻结门禁

状态：`ROOT_DECISION / DESIGN_ONLY`

## 1. 交付方式

本次本地设计一次完成两个累计阶段，但不会把“分阶段”误解为两套架构：

1. **Phase 1 — Kernel Contract Freeze**：修正原 Codex Session Kernel 的身份、权威、接收、缓存、顺序、发送、交互、同步和存储合同，同时冻结现有产品能力真正需要的最小 core-facing interfaces。
2. **Phase 2 — Product Completion Freeze**：在 Phase 1 已冻结的 owner/port 上完成设备、连接、文件、传输、媒体、Git、通知、后台、权限、更新、Native 与产品 shell 的详细设计；不把这些功能重新塞入 Session Kernel。

Phase 2 是 Phase 1 的累计扩展，不得复制 identity、actor、content、operation、stream、error 或 capability 语义。最终只有一个 `FULL_DESIGN`、一个语义 registry 和一组 Bridge/Mobile 写入规则。

## 2. 权威产物

最终权威由以下机器源和解释文档共同组成：

| 产物 | 权威范围 | 不得成为第二权威的内容 |
|---|---|---|
| `contracts/contract-registry.json` | semantic、owner、message、operation、error、limit、port、capability binding 的交叉引用 | 手写 TS/Dart 枚举、调用点字符串 |
| `contracts/schema/*.schema.json` | wire 和持久化边界的数据 shape、required、union、unknown 与容量 | 文档中的示例 JSON |
| `contracts/sql/*.sql` | Bridge/Mobile 逻辑 DDL 及数据库可执行约束 | ORM model、测试 fixture |
| `matrices/*.csv` | 52 能力、25 审查问题、源码处置、实验、决策和验收覆盖 | 汇报性数字 |
| 解释文档 | 算法、生命周期、事务、失败语义、实施顺序与理由 | 新增未登记 discriminant |

若解释文档与机器源冲突，验证必须失败，不能选择性接受其中一份。生成物只由 registry/schema 生成并带 digest；实施阶段禁止手改生成物。

## 3. Phase 1 冻结内容

Phase 1 只有在以下内容无空白、可交叉引用并有故意失败的反例时才可标记 `PHASE1_DESIGN_FROZEN`：

- `ComputerRef / BridgeIdentityRef / BridgeInstanceRef / RouteRef / CodexSourceRef / ThreadRef / TurnRef / ItemRef` 的边界、自然键和 fence；
- actor 从 authenticated connection context 注入，业务 payload 不可自报 authority；
- Provider durable history、read evidence、TurnSpine、coverage/gap/order proof、last-good 与 cache reuse；
- memory-only live overlay、旧 generation 丢弃和 live→canonical 原位晋升；
- typed operation、admission、fingerprint、queue、dispatch barrier、terminal、`OUTCOME_UNKNOWN` 和只读 reconcile；
- Interaction claim/lease、Goal、Plan、settings/effort、Side Chat、Fork 与 subagent relation；
- durable sync、capability binding、Mobile transaction-before-ACK、draft/local intent 隔离；
- Bridge/Mobile sole writer、事务边界、恢复规则和最小 DDL；
- Phase 2 所需的窄接口：authenticated execution context、source binding、content/resource ref、typed operation contribution、post-commit event、native capability snapshot；
- Claude 只留编译期 typed `NOT_IMPLEMENTED` seam，不进入 reachable route、wire、DDL、identity 或 capability snapshot；
- V2、Mirror writer、legacy runtime、dual read/write 和旧 DB migration 不进入新运行时。

Phase 1 不需要为 52 个能力创建 52 个核心模块。只有当某能力会改变 identity、authority、order、writer、wire、DDL 或跨端一致性时，才允许增加 core-facing contract；其余标记 `NO_CORE_CHANGE`。

## 4. Phase 2 冻结内容

Phase 2 对 P-001–P-026 每项都必须给出：

- 用户效果与明确非目标；
- 唯一 owner、执行位置和当前源码证据；
- 使用的 Phase 1 port 或 `NO_CORE_CHANGE`；
- typed request/event/result/error，若为本地能力则明确 `NO_WIRE`；
- state、lifecycle、authentication/authorization、capacity、privacy 和 recovery；
- Bridge/Mobile/Native/UI 接入点；
- 保留、适配、重写或删除的源码；
- 自动测试、runtime、设备和发布各自的验收；
- 首个实施 slice 与安全回退点。

“保留视觉效果”“保留文件功能”不算设计完成；必须绑定可执行语义、源码定位、数据流和验收。反过来，现有模块已能独立承载的能力不得为了形式统一而搬进 Kernel。

## 5. 未决事实和产品选择

- 技术事实只能标为 `CONFIRMED_BY_SOURCE / CONFIRMED_BY_EXPERIMENT / EXPERIMENT_REQUIRED / NOT_RUN`，不得由设计推测成 Provider 保证。
- 产品选择只能进入 `USER_DECISION_REQUIRED`。U-001–U-009 均给出推荐默认、影响面和最晚裁决门禁，但推荐值不等于用户决定。
- Goal、Plan、persisted/ephemeral Side Chat、ordinary Fork、Codex-first、no-V2 和 Claude unfinished seam 已由事实或用户决定关闭，不得重新列成选择题。

## 6. 用户审核门禁

最终设计包通过静态验证和独立复核后，状态只能停在：

`USER_REVIEW_PENDING`

用户审核前禁止：

- 将合同接入生产 composition root；
- 创建或迁移任何真实数据库；
- 发布 vNext capability 或替换 WSS 路由；
- 启动 Bridge/App/provider 实验或接触生产端口 `8765`；
- merge、push、deploy、IPA/OTA、安装、真机验收或 stable。

审核意见必须绑定设计包 SHA 和合同 commit。语义修改先改唯一 registry/schema/DDL，再重新生成、验证和更新解释文档；不得在未来调用点追加例外补丁。

## 7. 实施授权之后的起点

用户审核接受后才从届时批准的 exact open-source baseline 新建实施 worktree。设计分支是合同与证据载体，不是待机械合并的产品分支。第一笔实施只允许建立生成类型、窄 port、内存 read/cache/order vertical slice 和测试；切流、持久化、产品能力接回与发布分别保留独立授权和回退点。
