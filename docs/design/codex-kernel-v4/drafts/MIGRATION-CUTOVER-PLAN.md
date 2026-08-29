# Codex Kernel v4 迁移、切换与回退草案

状态：`DRAFT / NO_DATA_MIGRATION_AUTHORIZED / NO_CUTOVER_AUTHORIZED / NO_RELEASE_AUTHORIZED`

这里的“迁移”指 owner、source 和 feature activation 的可审计切换，不是把旧数据库内容搬入 v4。默认数据政策是 `NO_IMPORT / NO_DESTRUCTIVE_MIGRATION / PRESERVE_OLD_BYTES`。

## 1. 切换单位

### 1.1 SourcePartition

所有远端会话能力按以下组合切换：

```text
SourcePartition = bridgeIdentityId + bridgeInstanceId + codexSourceId
```

完整三元组同时约束 activation、cache、checkpoint、wire、Mobile FK 与 export。`providerKind` 在本版本只是编译期常量 `codex`，不进入 identity 或 activation key。route/endpoint 只用于 transport，authenticated device principal 只用于 actor；它们都不能替代 SourcePartition。thread/turn/item 再位于 SourcePartition 内。

### 1.2 FeatureKey

切换不是一个总开关，而是稳定、typed 的 feature 单元：

```text
core.read
core.live
core.start_turn
core.queue_control
core.interaction
core.thread_state_relation
product.<capability-id>
```

远端 feature 以 `(SourcePartition, FeatureKey)` 为 activation key。本机 UI/native-only feature 以 `(MobileInstallKey, FeatureKey)` 为 activation key；若它还消费 Bridge/source，则必须同时绑定 SourcePartition。`MobileInstallKey` 只用于本机交付隔离，不参与会话数据身份。

### 1.3 一个 active owner

每个 activation key 只能处于以下一种 owner 状态：

```text
UNAVAILABLE
V4_CANDIDATE_ONLY
V4_ACTIVE
ROLLBACK_BLOCKED
```

不存在 `V2_ACTIVE_WITH_V4_SHADOW`、`DUAL_WRITE`、`TRY_V4_THEN_V2`、`MIRROR_WRITER` 或 `LEGACY_FALLBACK`。开发源树中旧代码可能在端口尚未迁完时暂存，但候选包只允许一个 active owner；旧 owner 必须先停止 publication/dispatch，才可激活 v4 owner。

## 2. 切换清单

每次 rehearsal/cutover 必须先封印一份只读 manifest：

| 字段 | 要求 |
|---|---|
| `sourcePartition` / `mobileInstallKey` | 精确 activation scope |
| `featureKey` | 单一 feature；不允许“all”跳过逐项证据 |
| `previousRelease` | 完整 source/build/runtime/artifact identity |
| `targetRelease` | source HEAD/tree、Bridge/App build、Codex binary、schema/generator hash |
| `previousOwner` / `targetOwner` | 唯一模块、execution location、writer/publication path |
| `enterGate` | 对应 H gate 和原始 evidence run IDs |
| `dataClass` | Provider authority / rebuildable cache / v4 control state / protected local / user file |
| `activationAction` | 停旧 owner、校验 source、启新 owner、读取 capability 的精确顺序 |
| `successObservation` | Repository/UI/Provider/runtime 的真实结果，不是单一 HTTP 码 |
| `rollbackPoint` | 完整 commit SHA、previous artifact hash、data-preservation动作 |
| `rollbackBlockers` | `DISPATCHING/OUTCOME_UNKNOWN`、未完成 transfer、native/base mismatch 等 |
| `authorization` | source、deploy、IPA、OTA、install、device、stable 分开 |

manifest 不得含 token、API key、真实会话正文或用户文件内容。

## 3. 数据政策

### 3.1 永不由 v4 改写的权威/旧数据

- Codex Provider rollout、Provider SQLite、canonical history 和原始资源；CC Pocket只按认证能力只读或通过官方 Provider mutation API操作。
- 现有 CC Pocket/official DB、旧 conversation sync/Mirror DB、旧 input ledger、旧 cache 文件。
- 已有 draft、offline intent、credentials、settings、pairing/trust、transfer checkpoints、用户下载和电脑文件。

不得对旧 DB 做 `ALTER`、rename-in-place、vacuum、delete、truncate、cascade cleanup 或“先备份再清空”。旧文件在 v4 candidate 中默认不打开；probe 只能在隔离副本上只读。

### 3.2 v4 新数据

- Bridge 在专用 state root 创建新 `conversation_kernel_cache_v4.db`。cache/materialization 可重建；operation/interaction/cutover ledger 不是可随意删除的 cache。
- Mobile 创建新 `conversation_replica_v4.db`。conversation replica 可重建；draft/local intent/credentials/settings/transfer checkpoints 必须位于 protected namespace，不得被 replica FK cascade 或普通 cache clear 删除。
- 实际绝对路径、文件名、schema version 和权限必须由最终 accepted DDL/deployment manifest绑定；这里的名称是逻辑边界，不能据此直接改生产 state dir。

### 3.3 默认不导入

- 首次 v4 打开通过 Provider bounded read 重建用户实际访问的范围，不从旧 Mirror/v2/ccpocket DB复制历史。
- 旧完整副本继续留在旧文件中，不自动删除，也不作为 v4缺数据时的 fallback。
- 若未来确需一次性 importer，必须另有用户决定和设计：进程外、显式选择源、只读旧文件、写全新 v4 staging、校验后一次 commit、可删除 importer、运行时零依赖、失败不改源。当前范围没有该授权。

### 3.4 回退时的数据保留

- 可重建 candidate cache 可以在纯隔离环境中按 run manifest 删除；一旦用于候选/生产 rehearsal，默认保留以便审计，删除需单独范围确认。
- v4 operation、interaction、cutover ledger，任何 `DISPATCHING/OUTCOME_UNKNOWN` 记录，transfer checkpoint、proof/audit、draft/local intent和用户文件一律保留。
- whole-version rollback 后旧版本只打开它原有、未改写的 DB；它不得读取、降级或清理 v4 DB。重新进入 v4 时继续按 ledger reconcile。

## 4. SourcePartition 状态机

```text
UNBOUND
  -> FACT_CERTIFIED
  -> V4_READ_ONLY_ARMED
  -> V4_READ_ONLY_ACTIVE
  -> V4_LIVE_ACTIVE
  -> V4_MUTATION_ARMED
  -> V4_CORE_ACTIVE
  -> V4_PRODUCT_FEATURES_ACTIVE
  -> CANDIDATE_ACCEPTED

any pre-dispatch failure -> WHOLE_VERSION_ROLLBACK_READY
post-dispatch ambiguity  -> ROLLBACK_BLOCKED
```

- `FACT_CERTIFIED`：目标 Codex build/schema/source identity 有 H00 证据。
- `V4_READ_ONLY_ACTIVE`：`core.read` 在 Bridge→Mobile Repository→UI 全链只有 v4 owner；旧 read/catalog/Mirror writer 已停止。
- `V4_LIVE_ACTIVE`：新 live owner 接管，同 source不得同时运行旧 observer。
- `V4_MUTATION_ARMED`：H07 已通过但尚未发送真实 canary。
- `V4_CORE_ACTIVE`：单 operation、queue、interaction、thread state/relation 对获准 feature已逐项通过。
- `CANDIDATE_ACCEPTED`：只是候选 source/feature 验收；不等于 deploy/IPA/OTA/install/device/stable。

状态推进必须单调写入 v4 cutover ledger并 readback。它不能由 route reconnect、UI timer、版本号或进程启动成功自动推进。

## 5. 切换顺序

### Step 0 — 设计与事实门禁

1. 用户接受 Phase 1/Phase 2累计设计；C0–C6不作为外部 Phase 2设计前置。
2. 本地实施按 I00–I17完成；所有选定 H gate为 PASS。
3. 重新核对 target source、运行 artifact、Codex binary、SourcePartition和dirty state。
4. 取得候选 rehearsal授权；这仍不授权 production `8765`或发布。

### Step 1 — 隔离候选

- 使用 test port（默认 `8766`）、独立 Bridge/Mobile state dir、throwaway SourcePartition/thread和脱敏 fixtures。
- 候选包 architecture grep 证明无 V2/Mirror/legacy fallback/dual writer active path。
- 运行 read-only全链、live修复、single operation fault matrix；不得连接真实 production source。

### Step 2 — SourcePartition read-only 切换

1. 停止该 SourcePartition 的旧 catalog/history/Mirror publication owner。
2. 校验 authentication、Bridge instance、Codex source、Provider build/capability。
3. 激活 `core.read`，只允许 bounded Provider read和v4 cache/replica commit。
4. 验证 cold read、warm zero-read、partial Gap、last-good、restart。
5. 失败时停止整个 candidate并作 whole-version rollback；candidate内部不得 reroute旧 read path。

### Step 3 — live 切换

1. 确认该 SourcePartition没有旧 observer/live publisher。
2. 激活 `core.live`，验证 generation/source fence和canonical原位晋升。
3. 故障时禁用 candidate live并停止 candidate；不得恢复同一 binary中的旧 observer。

### Step 4 — 单 mutation canary

1. 单独授权一个 throwaway/明确可辨认的 `START_TURN` canary。
2. admission durable commit后才 dispatch；捕获 receipt、durable reread和canonical item。
3. 只有 terminal correlation明确时推进；任何 `OUTCOME_UNKNOWN` 立即进入 `ROLLBACK_BLOCKED`，停止该 SourcePartition所有Provider mutations。

### Step 5 — core feature 逐项激活

按 `core.queue_control → core.interaction → core.thread_state_relation` 逐项激活。一个 feature未通过只保持 `UNAVAILABLE`；不能转发给旧 owner。feature切换commit、capability advertisement和UI入口必须一致。

### Step 6 — Phase 2 feature 逐项激活

Phase 2云端/外部设计可以在 Phase 1接受后并行完成；这里仅指其本地实现切换。每个 capability依据下表独立激活、验证和回退。

### Step 7 — 候选封印

- 运行 H17/H18、固定 source/build/schema/generator/cutover ledger hashes。
- 标记 design/source/build/deploy/IPA/OTA/install/device/stable 九类状态；未执行的一律 `NOT_RUN`。
- 后续 production deploy、IPA、owner OTA、安装、真机、stable各需独立用户授权。

## 6. Core owner 切换表

下表的“当前候选 owner”是 source map 中需要 characterise、停止并删除 active ownership 的位置，不表示整文件删除。最终 owner 名称须由 accepted design/code review确认。

| FeatureKey | 当前候选 owner/热点 | v4 target owner/publication | activation 原子边界 | 失败时 |
|---|---|---|---|---|
| `core.read` | Bridge `sessions-index.ts`、`session-catalog-monitor.ts`、`local-features/conversation-sync-v2.ts`；Mobile catalog cache/Mirror publishers | Bridge `conversation-core/receive+storage` → durable event；Mobile `conversation_core/storage+repository` | 同一 SourcePartition先停止全部旧 catalog/history/Mirror publication，再开始v4 snapshot；首个v4 Repository revision前不显示新数据 | 停整个candidate或保持feature unavailable；不重新路由旧owner |
| `core.live` | `codex-process.ts` notifications、旧 continuity/conversation-sync-v2、`ChatSessionCubit` live reducer | Bridge/Mobile `conversation-core/live` → focused Repository overlay | old observer unsubscribe/ownership release与v4 generation activation形成一个fenced transaction | 丢memory overlay并停candidate live；不持久化、不建第二observer |
| `core.start_turn` | `websocket.ts` input route、`session.ts`、`input-delivery-ledger.ts`、Mobile `BridgeService.send`/Cubit outgoing reducer | v4 `operation` admission/ledger/adapter → Repository receipt/canonical correlation | 旧 input dispatch停止且无in-flight后，v4 admission才可接受首个operation | pre-dispatch可整体回退；post-dispatch按UNKNOWN协议阻断 |
| `core.queue_control` | 旧 input ledger/queue route、Mobile offline queue与queue panel state | v4 operation queue/lane + local intent projection | 按action kind逐个切换；query/update/cancel capability与handler/Repository同一commit激活 | action变UNAVAILABLE；不落回旧queue handler |
| `core.interaction` | `codex-action-broker*.ts`、`websocket.ts` pending maps、Mobile pending interaction handlers | v4 Interaction Broker/claim ledger → typed controller | 旧 broker 停止 response；不导入 pending map，只有从当前 authenticated Provider/runtime fact 以 exact identity 重新 materialize 的 interaction 才开放 UI | 关闭受影响 interaction kind；manual path仍在同一 v4 broker |
| `core.thread_state_relation` | `codex-goal-controller.ts`、core-actions、persisted/ephemeral Side Chat、subagents local features | v4 settings/thread-state/relation owner + ordinary child Repository | Goal/Plan/Side Chat/Fork/subagent按kind独立切；父子/SourcePartition proof先于UI entry | kind变UNAVAILABLE；不恢复CC-owned Goal、第三timeline或legacy Side Chat |
| `core.ui_projection` | `BridgeService` raw dispatch、`messages.dart` mixed models、`ChatSessionCubit`/`SessionListCubit` data reducers | typed envelope → SQLite → Repository → focused controller → thin Cubit/UI | 一个screen/feature只有在旧subscription/reducer停止后订阅v4 Repository | 撤该UI adapter；不让raw frame/旧cache重新成为隐藏owner |

## 7. Phase 2 capability 切换表

| Capability | Stage | activation scope | 前置 | 切换成功证据 | 回退动作 |
|---|---|---|---|---|---|
| P-001 computer/routes | I12 | SourcePartition + Mobile install | core.read、identity contract | signed grouping、route records独立、source cache不串 | 撤 route adapter/UI；保留 identity contract和route records |
| P-002 identity/pairing | I12 | Bridge instance + device principal | authenticated context | challenge/pair/revoke/key recovery E2E | 关闭 pairing入口；保留 trust/revocation记录，不降级 payload actor |
| P-003 discovery | I12 | Mobile install + route | route/source fence | discover/select/cancel/timeout，未自动连 WS | 撤 discovery adapter；已有手工route保持 |
| P-004 readiness | I12 | SourcePartition + connection epoch | P-001–P-003 | transport/auth/catalog/application-ready分层 | 撤进度/UI adapter；不能用 connected布尔代替 ready |
| P-005 file browser | I13 | SourcePartition + actor | ContentRef/execution context | browse/search/pagination/path security E2E | 关闭入口；不删除 pin/cache/user files |
| P-006 transfer | I13 | SourcePartition + transfer ID + Mobile install | protected checkpoint/content plane | resume/digest/atomic landing/inbox | 停新 transfer；保留 checkpoint、partial temp和已落盘文件 |
| P-007 drop/attachments | I13 | Mobile install + focused SourcePartition/thread | composer ingress、P-006 | Home/composer分流且显式 send前无 operation | 撤 ingress UI；保留 draft/attachment/transfer事实 |
| P-008 mutation auth | I13 | SourcePartition + actor + exact target | authenticated actor/resource scope | password/Secure Enclave proof、replay/path-swap拒绝 | 关闭 mutation；保留enrollment/revocation/audit，不信任布尔 fallback |
| P-009 preview | I13 | Mobile install + ContentRef | P-010 ticket | Quick Look/fallback/share/download/back行为 | 撤 preview adapter；保留文件/ref，不外部上传 |
| P-010 artifact refs | I13 | SourcePartition + resource/version | typed ticket | opaque ref、range/digest/expiry/revoke | 关闭发券/入口；保留store/audit，不暴露path/token |
| P-011 gallery/images | I13 | SourcePartition + media lineage | P-010/content plane | 三类media分页、缺失降级、下载分享 | 撤media adapter/UI；保留opaque refs和已下载文件 |
| P-012 Git/worktrees | I14 | SourcePartition + workspace/repo | typed product action | read facts、单独授权mutation、stale conflict | 关闭adapter/UI；不自动逆转Git mutation |
| P-013 capture | I14 | SourcePartition + capture ID | permission + ContentRef | start/stop/list/play/delete/share/capacity | 关闭capture入口；不删除已有capture |
| P-014 notifications | I15 | SourcePartition + device install | post-commit projection/Interaction | in-app/local/remote分开，exact action revalidation | 关闭通道/adapter；不改canonical/read watermark |
| P-015 background | I15 | Mobile install + SourcePartition cursor | lifecycle fence | finite lease/stop/force-quit/foreground repair | 关闭可选后台路径；前台repair保留 |
| P-016 permissions | I15 | Mobile install + plugin version | native snapshot | status/request/open-settings/unsupported | 关闭feature UI；不自动prompt、不伪造grant |
| P-017 updates | I15 | Mobile install + Bridge revision | delivery-state contract | 检查/下载/重启状态准确且无自动发布 | 撤update adapter/UI；不改变channel或已安装版本 |
| P-018 voice | I16 | Mobile install + composer | composer ingress | partial/final/cancel/selection，未自动send | 关闭voice；保留draft原文 |
| P-019 app icon | I16 | Mobile install + native API | native snapshot | set/readback/failure rollback | 恢复真实readback UI；不影响core |
| P-020 commerce | I16 | Mobile install + store scope | none on Session Kernel | offering/purchase/restore/offline，core永久免费 | 关闭commerce UI；保留store事实，不锁core |
| P-021 shell services | I16 | Mobile install | router slots | route/offline/accessibility/review cooldown | 撤局部route/service；不动Session Kernel |
| P-022 host routes | I16 | Mobile install + SourcePartition where needed | product router | Explore/Setup/QR/Settings/Debug保留，Claude不可达 | 撤route改动；Claude仍为unreachable typed seam |
| P-023 localization | I16 | Mobile install + locale | read-only presentation | ARB完整、动态文本allowlist、原文保留 | 关闭翻译；显示原文，不清用户内容 |
| P-024 native host | I15 | MobileInstallKey | exact base IPA/plugin versions | per-plugin snapshot、epoch、late callback丢弃 | 关闭不支持adapter；需要新base IPA的feature隐藏 |
| P-025 effort/motion | I16 | SourcePartition settings + Mobile install | settings ACK | 六档真实ACK；Max/Ultra几何/性能/视觉/许可 | 撤motion/UI；保留authoritative settings值 |
| P-026 cache management | I15 | SourcePartition + Mobile install namespace | protected namespace | per-namespace clear/readback/restart且protected存活 | 关闭clear action；不执行broad cleanup |

表中“关闭”表示 feature 在 v4 candidate 中变为明确 `UNAVAILABLE/UPDATE_REQUIRED`，不是转发到 V2、旧 Bridge handler、Mirror或legacy runtime。

## 8. 回退决策表

| 故障时点 | 是否可 whole-version rollback | 必做动作 | 禁止动作 |
|---|---|---|---|
| 激活前/静态门禁失败 | 是 | 保留失败 evidence，revert未激活commit或丢弃candidate | 不触碰任何数据 |
| read-only切换后，尚无v4 mutation | 是 | 停candidate，验证旧artifact/旧DB身份，再整体恢复 | candidate内切回旧read owner；删除v4 evidence |
| live故障，无mutation | 是 | 停candidate；overlay随进程消失；旧版本重读自身权威路径 | 持久化live body；把v4 replica写回旧DB |
| mutation已明确未写Provider | 是 | ledger记录definitive no-write后整体恢复 | 凭timeout猜未写 |
| mutation已有明确terminal/provider durable correlation | 条件允许 | 先封印terminal evidence；确保旧版本不会重放同一operation | 删除operation ledger或重复发送canary |
| `DISPATCHING/OUTCOME_UNKNOWN` | 否，先阻断 | 停该SourcePartition所有mutation；保留v4 runtime/reader做只读reconcile；必要时请求用户决定 | 启动不知道v4 ledger的旧mutation owner；自动重发；清ledger |
| active interaction response ambiguous | 否，先阻断 | 同上；只读枚举/Provider事实收口或让interaction自然过期 | 从另一个broker重复respond |
| transfer中断 | 核心可回退；transfer数据保留 | 停新transfer；保留checkpoint/temp；恢复时按同一identity验证 | 删除partial/checkpoint；把partial暴露为完成文件 |
| Mobile/native故障 | 需安装授权 | 保留新旧DB；安装精确 previous app/base only after authorization | 用OTA跨native差异；自动降级/安装 |
| owner OTA/device验收失败 | stable不得变化 | 停在owner，报告patch/build/installed identity | 用stable覆盖问题；未经授权rollback/promotion |

## 9. `OUTCOME_UNKNOWN` 的特殊回退协议

这是唯一会主动阻止 whole-version mutation rollback 的核心状态：

1. 原子写入 `ROLLBACK_BLOCKED` 与 source/operation/attempt/digest/provider correlation evidence。
2. 撤销该 SourcePartition 的新 mutation admission；read/resource可继续，前提是不会改变 Provider。
3. 使用同一 v4 build或与其 ledger/schema兼容的 recovery reader做 bounded durable reread；禁止调用 mutation API探测。
4. 观察到唯一 canonical user item/turn时收口为已执行；有确证未写时收口为definitive no-write；证据不足继续UNKNOWN。
5. 只有所有未知operation收口，或用户明确接受冻结/人工处理方案后，才可恢复任何mutation owner。

旧版本不能解析 v4 ledger，因此“整个版本回退”并不自动等于“可以继续发送”。deployment SOP必须把这个阻断条件写入 preflight。

## 10. 九类完成状态

| 状态 | 当前 | 需要的独立证据/授权 |
|---|---|---|
| design | NOT_RUN | 累计设计审核与用户接受 |
| source | NOT_RUN | 实现、测试、commit、diff审核、授权集成 |
| build | NOT_RUN | 精确HEAD的Bridge/Flutter/target artifacts |
| deploy | NOT_RUN | 用户授权的production candidate、PID/listener/config/HTTP/WSS/runtime验收 |
| IPA | NOT_RUN | package/architecture/signing/entitlement审计 |
| OTA | NOT_RUN | exact uploaded base lineage和owner patch证据 |
| install | NOT_RUN | 目标设备实际installed binary readback |
| device | NOT_RUN | 真机native/network/behavior/视觉与用户验收 |
| stable | NOT_RUN | 指定patch的当次明确批准和promotion后快照 |

本计划通过审核也只提升 design 文档质量，不会自动改变以上任何状态。
