# 04. 兼容、迁移、容量、安全与验收

## 1. 迁移总原则

本次升级是“以新领域内核逐步接管现有链路”，不是另起一套状态后整夜 hard cutover。

1. 不原地删除 v2 DB、Mirror、ledger 或 protocol handler。
2. 不把 v2 pending/outbox 自动迁移成新 provider dispatch。
3. 不用 shared daemon 作为新接收链的前置条件。
4. 不维护两套 provider-history projection writer；shadow 路径只能比较，不能发布/删除。
5. 每个 feature 独立 capability/cutover/rollback marker，不用全局“v3 已开”布尔值。
6. 退役旧链是未来独立任务，需真实 adoption、回滚窗口、旧端证据和用户授权。

## 2. 兼容矩阵

### 2.1 Mobile × Bridge

| Mobile | Bridge | 核心同步 | 新 feature | 结果 |
|---|---|---|---|---|
| 旧 | 旧 | 现有 legacy/v2 | 现有能力 | 行为不变 |
| 旧 | 新 | 新领域内核 → v2/legacy adapter | 仅旧端可安全表达的功能 | 不要求升级；daemon interaction 等危险操作 fail closed |
| 新 | 旧 | 新 Mobile 的 v2/legacy client adapter | capability 缺失时隐藏/只读/明确 unsupported | 不伪造 vNext/Goal/settings durability |
| 新 | 新 | vNext capability 优先，按 feature 选择 | 完整 manifest contract | 目标路径 |

新 Mobile 不能因为 Bridge 没有 vNext capability 就放弃已有会话；新 Bridge 不能只发新 envelope 导致旧 Mobile 失联。
显式 open/legacy trust 继续支持现有 reduced-capability session/v2/readiness 路径；新私有 content、诊断、destructive 或 shared
mutation 仍要求 paired/key 或相应 step-up capability。

### 2.2 Provider runtime topology

| topology | 历史读取 | 输入 | steer/interaction/settings | 策略 |
|---|---|---|---|---|
| private runtime | provider read + runtime overlay | Bridge owner 时可 dispatch | active-runtime legacy 或 feature capability | 保持默认可用 |
| daemon/shared ready | provider read + shared observer | writer lease/owner 后 dispatch | exact authority + Action Broker | feature-gated |
| daemon/shared read-only | provider read | 拒绝 mutation 或明确排队到 Bridge owner 条件 | fail closed | 可浏览不可越权 |
| unknown/mismatch | 保留最后 cache + bounded probe | 不猜 owner | 不执行 live control | degraded/repair |

exact Codex/daemon version tuple 只用于 shared mutation readiness；不能阻止 private history、old v2 或 Claude 链路。

### 2.3 Feature 降级矩阵

| feature | 新端遇旧 Bridge/provider | 旧端遇新 Bridge |
|---|---|---|
| Turn atomic bundle | 使用 v2 inline/page | Bridge 发 v2 |
| persisted Side Chat | 明确 capability 缺失时可选择 legacy fallback | 保留旧 legacy route |
| ephemeral official child | 隐藏/unsupported，不伪造持久 child | 不主动暴露 |
| subagents | 隐藏 panel 或 unavailable；空列表不能代替 unsupported | 旧端无此入口 |
| Goal | active-runtime legacy 能力存在才使用，否则 unsupported | 保留既有 active-runtime path |
| thread settings | 只显示已知 snapshot；mutation 不安全则只读 | 保留旧 attached setting route |
| interactions | private legacy live route；shared 缺 broker则 update required | daemon/shared 对旧 frame fail closed |
| queue | 使用现有 queue/legacy admission | Bridge 维持旧 ACK/message shape |
| HTTP content | inline/bounded page/file fallback | 不发旧端无法理解的 offer |
| diagnostics | 本地 capture，无新上传 receipt则保存在设备 | 旧端不自动上传 |

## 3. 数据迁移与 rollback

### 3.1 Mobile DB

建议使用新的物理文件 `conversation_replica_vnext.db` 承载 vNext rebuildable replica；最终文件名通过实现 ADR 固定。
现有 `session_catalog_cache_v1.db` 和 `conversation_mirror_v1.db` 在 rollback 窗口内保持原样，不做 destructive
in-place schema rewrite。

启动流程：

1. 打开新 DB，验证 schema/canonicalization version；
2. 读取 authenticated SourceRef；
3. 可选导入仅含强 provider IDs、已 committed、分区完整的旧 hot-window 作为 `legacy_imported`；
4. 在 provider revision/coverage 校准前，不把导入数据标为 `canonical_verified`；
5. provider sync 完成后按精确 scope 晋升或替换；
6. 写 per-source/feature cutover marker；
7. 旧 DB 保留只读，直到独立清理授权。

如果旧缓存没有完整 `bridgeInstanceId/providerSourceId/providerThreadId`，不得跨 source 导入。导入失败不删旧 DB。

旧表到新 namespace 的首版映射固定如下：

| 现有表/文件 | vNext 处理 | 不能做 |
|---|---|---|
| `session_catalog_partitions`, `session_catalog_aliases` | 强身份映射到 `source_registry/legacy_aliases`，记录 provenance | route/path alias 直接变 identity |
| `session_catalog_entries` | 强 SourceRef/ThreadRef 行可导入 `thread_catalog`，状态为 `legacy_imported` | 当作当前 provider catalog proof |
| `conversation_hot_windows`, `conversation_hot_entries` | 导入 legacy staging；按 provider turn/item IDs 重建 Spine/coverage 后才晋升 | 仅按文本/时间组 Turn 或删除新数据 |
| `conversation_sync_states` | 仅作 provider `knownRevision` hint；不能成为 vNext checkpoint | 把旧 sequence/subscription 当新连接 checkpoint |
| `conversation_sync_statuses` | 不导入为 authoritative status；只可短暂显示 stale/unknown | 恢复 running/approval owner |
| `conversation_user_index_*`, `conversation_user_turn_detail_*` | 强 ID locator 作为 unverified navigation hint，provider 校准后晋升 | 把 locator 当 adjacency proof |
| `conversation_read_watermarks` | 搬到 local-state namespace，精确 SourceRef/ThreadRef | cache reset 时删除 |
| `conversation_timeline_stage*`, `latest_turn_repair_*`, replacement temp tables | 不导入未完成 staging；保留旧文件供 rollback | 恢复/dispatch 未完成网络操作 |
| `conversation_mirror_v1.db` 的 metadata/entries/staging | 保持独立 Mirror；不自动并入 hot replica | 让 Mirror 成为 normal timeline writer |

新 DB 内每个 source 有幂等 `migration_checkpoint`：`oldDbSchemaVersion + oldDbChecksum + SourceRef + phase +
lastOldPrimaryKey + importedCounts + providerRevision + verifiedCommitId + status/error`。每批 import 与 checkpoint 在同一 transaction；
crash 后从 last key 继续。source switch 取消当前 importer，但不把 A source checkpoint 应用于 B。校准完成前 Repository 只能选择
一个 active reader：

| 状态 | active reader | shadow/rollback reader |
|---|---|---|
| 新 App、vNext capability 未 ready | 现有 v2 DB/repository | vNext 不发布 |
| vNext shadow compare | 现有 v2 DB/repository | 新 DB只比较 |
| per-source cutover committed | vNext replica/repository | 旧 DB read-only |
| App rollback | 旧 App/旧 DB + provider resync | vNext DB原样保留 |

同一 source/thread 在一个 App 进程中不能被两个 reader 同时发布到 UI。

### 3.2 本地非重建数据

- draft、read watermark、pin、UI preference 迁入独立 local-state namespace；cache reset 不碰它们。
- 未确认旧输入显示为 quarantined/needs-review，不自动提交给 provider。
- Bridge queue 以 Bridge 账本为 authority；Mobile 重连后读取 queue snapshot，不用本地猜测恢复。
- 旧 interaction/Goal/settings/stop/steer intent 一律不迁移 replay。

### 3.3 Bridge stores

- Turn/content store 带 `storeGeneration + schemaVersion + canonicalizationVersion`。
- 旧 input ledger 在迁移前先停止 admission、flush、校验；只迁移明确 `queued-before-dispatch` 的项目。
- `provider_dispatching/provider_accepted` 项迁移为 `outcome_unknown/reconcile_required`，绝不自动重发。
- Action Broker identity-only records保留 generation/lease 语义；敏感 live binding 不迁移。
- persisted child/Goal/settings 新 durable ledger 从启用 capability 后开始，不根据旧响应日志反推成功。

### 3.4 Rollback

每个候选版本必须产出 rollback manifest：

```text
RollbackManifest {
  sourceCommit
  bridgeBuildId
  mobileBuildId
  protocolAdaptersEnabled
  featureCutovers
  mobileDbSchema
  bridgeStoreGeneration
  canonicalizationVersion
  pendingOperationCountsByState
  oldDbPathsAndChecksums
  authModeAndPairedStateFingerprint
  activeContentOffersAndReaderLeases
  operationLedgerChecksumsAndReceiptWatermarks
  migrationCheckpointsBySource
  restoreProcedure
}
```

Rollback 时：停止新 admission → drain/标记在途 → 撤销 content offer/bearer、等待或终止 reader lease → quarantine 未确认
operation/outbox → 关闭 feature cutover → 保留 vNext DB/store/receipts → 恢复旧 adapter/runtime。配对/auth source state 只验证
fingerprint，不导出或重写 secret；旧 reader启动后从 provider重新同步，绝不删除 provider/raw history。
不得把路径只差大小写的 artifact/DB 互相 rename/delete；必须使用明确不同 basename 并重新验证。

## 4. 分阶段实施计划

### Phase 0 — 合同冻结与 provider 实验

**硬门禁：Phase 0 属于开工前 protocol engineering，不允许与 feature 业务实现并行偷跑。**

交付物：

- 本目录规范的 ADR 化；
- 完整 per-payload JSON Schema、TS/Dart generated types、manifest registry，以及检查跨消息唯一性、引用完整性、
  subscription cleanup/ACK 等 JSON Schema 无法表达不变量的 registry validator；
- Node/Dart deterministic encoding golden vectors；
- provider capability fixtures：items/list、turns/list、cursor、compact、fork、Goal/settings、interaction；
- identity/authority/replay threat model；
- capacity defaults 和 error codes 冻结。

退出条件：没有空壳 schema；registry 中每一条消息都有完整 discriminated payload/error schema；JSON Schema 与 registry
validator 同时通过；生成 TS/Dart union 与双向 golden/fault vectors；所有 mutation 都有 policy/fingerprint/reconcile；未知 provider 行为有 typed fallback。未满足时
`implementationReady=false`，Phase 1 之后不得开始。

### Phase 1 — 稳定 seam，行为不变

- 在现有 `local-features` host 上加入 manifest 校验；
- 引入 `SourceRef/ThreadRef` value objects 和边界 adapter；
- 包住 provider、canonical read、live、operation、interaction interface；
- root `websocket.ts/parser.ts/Cubit` 仍可调用旧实现，但不新增功能分支；
- 建立当前行为 characterization tests。

退出条件：当前 v2/legacy full suite 与关键 E2E 不回归；无部署/cutover。

### Phase 2 — Receive Core shadow

- 实现 ProviderAdapter、TurnSpine、CoverageEngine、ProviderHistoryProjectionWriter、LiveObservationHub；
- shadow 只消费与现有链相同的 immutable provider read，生成 compare report，不向 Mobile 发布、不删 cache；
- 对所有分歧分类：身份、order、coverage、unknown item、capacity、旧链缺陷或新链缺陷；
- 独立 oracle 对照真实 provider history。

退出条件：已知 fixtures 100% 一致；真实会话分歧全部有解释；失败/空/partial 不清最后事实。

### Phase 3 — Operation Core 优先修正

- 将 Input Delivery Ledger 迁入 typed Operation Kernel；
- 首先删除 `provider_dispatching` 后自动 replay 的危险语义；
- 加 queue edit/cancel race、operation fingerprint、outcome query；
- 统一 Interaction Broker exact target/lease；
- 为 persisted child、Goal、settings 加 reconcile-only ledger。

退出条件：每个 transition kill/restart fault tests 通过；重复 clientMessageId provider fixture 不产生自动第二 dispatch。

### Phase 4 — Additive vNext wire 与 Mobile replica

- 新 Bridge 从同一 canonical commit 同时提供 v2 adapter 和 vNext adapter；
- 新 Mobile capability 协商后按连接选择一个 active canonical protocol，不能同一 target 双消费；
- 建新 replica/staging/repository；
- 小 Spine inline，大内容接现有认证 HTTP Range；
- 完成 WSS→Dart→SQLite→Repository headless chain。

退出条件：sequence/revision/range/crash tests 和 new/old matrix 通过；v2 adapter仍是完整 fallback。

### Phase 5 — 功能模块收拢

按依赖顺序迁移：

1. catalog/status/queue；
2. interactions/auto-approval；
3. settings/Plan/Goal/core actions；
4. relation graph + persisted/ephemeral Side Chat；
5. subagents；
6. artifacts/Mirror/insights/background/diagnostics。

每个 module 单独 capability/cutover/rollback，不等待“全部 v3 完成”才验收。

### Phase 6 — UI 与真实全链

- Repository 替换 Cubit 内的 raw merge；
- Goal/settings/interaction/relations 各自 controller；
- TimelineProjectionReducer 仅组合 canonical/outgoing/focused live；
- simulator + real Bridge + real provider E2E；
- 前后台、重连、滚动、跳转、child navigation、未知 enum/item 验收。

### Phase 7 — 候选与物理设备门禁

源码完成后仍需分别授权/执行：候选 Bridge build、隔离部署、App candidate、IPA/OTA、安装、物理 iPhone/Android、
shared pilot、rollback、owner/stable。任何一次失败只回退对应 feature/candidate，不破坏旧 v2。

### Phase 8 — 旧链退役（本方案不授权）

只有满足兼容 adoption、至少两个稳定 release 窗口、真实旧端统计、零 pending、rollback 演练和用户明确授权后，
才可另立任务评估删除 legacy/v2。默认结果是“继续保留 adapter”，不是 Phase 7 自动删除。

## 5. 初始容量合同

以下是首版硬上限；握手 capability 可以向下协商。提高上限需要容量 ADR、内存/磁盘/弱网/崩溃证据。

| 资源 | 初始上限 | 超限行为 |
|---|---:|---|
| 普通 control frame | 64 KiB | 改用 content plane 或 `content_too_large` |
| inline TurnSpine | 256 KiB | 改发 `content.offer` |
| required TurnSpine object | 4 MiB | 拆 deferred payload；仍超则 `repair_needed/capacity_exceeded` |
| 单 conversation Turn/payload cache object | 64 MiB | provider locator/unavailable；不标 full |
| 单 conversation normalized entries | 100,000 | 有界 coverage/gap，不静默删旧 |
| 单 conversation hot replica bytes | 64 MiB（content blob/Mirror/local state另计） | LRU/coverage eviction，保留 index/local state |
| Mobile 一次渲染 envelope | 约 200 items | viewport paging |
| Bridge next-turn queue | 16/thread | `queue_full` |
| operation ledger default | 4,096 records / 8 MiB per module/source | unresolved 不 prune；fail closed |
| operation ledger hard maximum | 16,384 records per module/source | 提高需 ADR；terminal compact to tombstone |
| subscription outstanding durable frames | 32/client | 背压/断开并可恢复 |
| observer active threads | 32/source | content-free degraded/gap |
| foreground Home active live watches | 8/source（focus 另计） | 按 priority/status 收缩并报告 rejected targets |
| content download concurrency | 2/device，1/thread | scheduler 排队 |
| diagnostic journal | 1,000 entries/scope | ring overwrite，anomaly pin 有界 |
| Bridge diagnostic raw files | 最多 4，合计 64 MiB | 拒绝新 capture/先过期旧项 |

上述 object/replica quota 仅限 conversation Turn/payload cache，不覆盖用户显式文件传输或 Artifact/File Browser 的独立授权面。
现有文件传输可到 15 GiB、preview 可到 2 GiB 的合同以及图片/差异预览产品上限继续适用；这些大文件必须走各自
capability、step-up、streaming 和磁盘预算，不能被自动纳入 timeline replica。conversation object 上限也不意味着 UI 自动加载
64 MiB 内容。

所有计数同时限制：item 数、解码后 bytes、压缩前 bytes、压缩比、嵌套深度和字符串长度，防止压缩炸弹/JSON 资源耗尽。

## 6. 安全与隐私

### 6.1 Source/operation authorization

- `providerSourceId/codexSourceId` 是 opaque public identity，不是凭据。
- 每个 read/mutation/content offer 都从 authenticated connection context 重新绑定 SourceRef。
- destructive/thread-state/shared mutation 在 provider 调用前后复检 source、writer lease、authority/precondition。
- source mismatch、owner unknown 或 lease health degraded 一律 fail closed。

### 6.2 Content plane

- bearer 是短期、单 object/scope、route-bound、可撤销；Range request 也重新认证 scope。
- ETag/digest 证明 bytes 完整，不证明授权或 provider authority。
- path、URL、token、raw attachment 不进入日志/analytics。
- 临时文件以随机非用户输入 basename 创建，校验后 atomic rename；拒绝 traversal/symlink escape。

### 6.3 Diagnostics

常驻 journal 默认仅包含：hash 后的 identity、state transition、sequence/revision、byte/count、reason code、耗时。
禁止默认保存 prompt、assistant/tool body、Goal objective、title、path、环境变量、cookie、API key、pairing secret、transfer URL。

用户显式 capture 后仍要：Mobile 递归 scrub → 显示大小/范围 → authenticated upload → Bridge 二次 fail-closed scrub
→ receipt → retention/删除。development full-fidelity 只能在隔离 fixture/source 中显式开启，不能继承生产凭据。

## 7. Projection Lab

一次跨层诊断使用同一个 content-free correlation token，记录：

```text
provider_observed
provider_read_started/completed/failed
canonical_staging_started/committed/rejected
wire_batch_sent/acked
content_offered/receipt
mobile_staging_started/committed/rejected
repository_published
ui_frame_sampled (foreground only)
operation_admitted/dispatching/accepted/observed/outcome_unknown
```

每个 milestone 带 SourceRef hash、ThreadRef hash、turn/item hash、generation、revision、sequence 和 reason code。
`ui_frame_sampled` 只说明一次前台 frame 观察，不等于用户看见、物理设备验收或 canonical 正确。

## 8. 测试矩阵

### 8.1 Contract/golden

- 所有 request/event/error 的 JSON Schema 正反例；
- TS encode → Dart decode、Dart encode → TS decode；
- unknown field/enum/item 保留；
- JCS/CBOR Unicode/number/map order golden；
- capability downgrade 与 typed unsupported。

### 8.2 Provider adapter

- items/list 支持与不支持；turns/list fallback；
- empty vs authoritative empty；partial page/cursor loop；
- fresh thread materialization delay；
- compact/fork/edit/archive revision；
- multiple user items、images、large tool payload、unknown future item；
- external/desktop/shared owner 与 approval routing。

### 8.3 Receive/property/fault

- provider IDs 优先、歧义不误删；
- arbitrary page split/reorder/duplicate；
- live delta + completed snapshot + canonical promotion；
- source/connection/authority generation 中途变化；
- focused 与 Home active priority watch 的切换、上限、generation handoff；`notifications_only` 绝不含正文；
- sequence duplicate/gap、base revision mismatch；
- SQLite kill at every staging/commit step；
- Range resume、wrong ETag/digest、token expiry；
- latest-turn gap、coverage islands、bounded jump。

### 8.4 Send/fault

- Bridge kill at every ledger state；
- response loss at admission/provider/canonical observation；
- same operation same/different digest；
- queue edit/cancel/dispatch races；
- provider 对相同 clientMessageId 不去重；
- 两台 Mobile 同时观察同 thread：sender-local admission/state 不串设备，cross-device 只见 queue/canonical broadcast；
- writer lease/owner/source switch；
- interaction claim/submitting/submitted disconnect；
- Goal/settings/persisted child reconcile；
- old offline queue 不能 replay live control。

### 8.5 Feature

- persisted child duplicate-create prevention、关系和普通 screen；
- ephemeral child disconnect/source invalidation 后清理；
- legacy Side Chat fallback 不污染 main timeline；
- subagent descendant/source validation、bounded page/watch cancellation、不进 catalog；
- Goal complete vs clear、unknown status、budget/usage conflict；
- Plan setting/item/ExitPlanMode/edit 四语义不串；
- auto approval 只响应 Bridge owner；
- compact marker 不伪装 user/assistant。

### 8.6 真正的全链与 UI

必须运行真实：

```text
provider/app-server
→ Bridge adapter/projector
→ authenticated WSS (+ optional HTTP)
→ Dart decoder
→ SQLite staging/transaction
→ Repository
→ Timeline reducer / feature controller
→ rendered Flutter UI
```

测试 oracle 直接读取 provider/SQLite/Repository/semantics，不只比较当前 UI snapshot。逻辑测试不能替代 visual、background、
弱网或物理设备验收。

## 9. 当前已知且必须实测的风险

这些是静态源码/本机调查得出的约束，不得在设计中假装已经解决：

1. 当前实测 Codex runtime 曾不支持 schema 中出现的 `thread/items/list`；adapter 必须真实 probe/fallback。
2. 相同 `clientUserMessageId` 可创建两个 provider Turn；不能依赖 provider 去重。
3. `thread/started` 可能早于 durable materialization，立即 resume/read 会失败。
4. runtime、sharedObserver、externalObserver、providerRefresh 会重复报告同一 item；强 identity 不足时可能安全地保留重复。
5. 当前 broadcast 对 stream/thinking 的批量 early-return 与 observer/专用 delta 路径的完整覆盖需运行时验证。
6. summary cursor 到 full page locator、compact/fork 后 cursor 生命周期仍需 fixture 证明。
7. 本次设计审计没有启动生产 Bridge、没有跑真实 daemon capability negotiation、没有做物理手机全链验收。

## 10. 各阶段质量门禁

| 门禁 | 必须证据 | 不能替代它的证据 |
|---|---|---|
| Spec gate | 完整 schema/manifest/ADR/golden | prose 说明 |
| Source gate | typecheck/analyze/unit/property/fault tests | 编译成功 |
| Chain gate | 真实 WSS/HTTP/Dart/SQLite/Repository | mock handler 单测 |
| UI gate | simulator/visual/interaction/background | reducer 单测 |
| Compatibility gate | old/new/private/daemon matrix | 新新组合通过 |
| Candidate Bridge | exact HEAD/build/config/listener/health | 源码测试 |
| Candidate App | exact artifact lineage/install | Flutter build |
| Physical gate | 真机断网/后台/长会话/Side Chat/Goal/interaction | 模拟器 |
| Stable gate | 明确用户授权与 rollback evidence | owner/staging 已上传 |

## 11. 最终开工顺序

正式编码前先完成 Phase 0；随后优先做 identity、provider-history projection writer 和 dispatch-after-start 不重放，因为它们是所有功能共享的
正确性根。再做 additive wire/replica，最后迁移 Goal/Plan/settings/Side Chat/subagents 等 feature。

不得先重写 UI 或删除 v2 再补 protocol；不得先启用 shared daemon 来“验证新架构”；不得把一次 passing test、Bridge build、
IPA 或 OTA 当成整条链交付完成。
