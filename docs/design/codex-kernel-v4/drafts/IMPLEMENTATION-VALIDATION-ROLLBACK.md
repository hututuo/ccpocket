# Codex Kernel v4 实施、验证与回退草案

状态：`DRAFT / DESIGN_REVIEW_REQUIRED / IMPLEMENTATION_NOT_AUTHORIZED / ALL_RUNTIME_GATES_NOT_RUN`

本文只定义设计审核通过后的本地实施顺序和证据合同。它不授权修改生产源码、启动 Bridge/App、访问或替换 `8765`、迁移数据、部署、构建 IPA、发布 OTA、安装设备或晋级 stable。

## 1. 绑定输入与适用边界

- 实施设计输入：`docs/design/codex-kernel-v4/` 最终经用户接受的累计设计；本草案本身不是 semantic SSOT。
- 本地设计 source lock：`a706200233c55cc82d7a17e433f80f132d0f280d`，tree `ac85f620445151f45eda856f55f4b96ee442f41a`。
- 本实施草案起点：`d152b118045264abeb8a1760b94113e323e46283`。
- v4 输入包 SHA-256：`d0f597cc089850214ec5aece824a3eb0265e20e0ce0e0bbef27add1381f0e257`。
- 原设计 ZIP SHA-256：`d5c33a5455a1f1375efd4b68e0bb91844a5e6467c7115b3a204b4ea1faeeef76`。
- 历史需求补遗 ZIP SHA-256：`d45f622d5f0824e91b8254d31cb2a62629d1f29e9d23ced6b4f2f0ac45bbc02c`。

真正开工时必须重新记录 repo、worktree、branch、完整 HEAD/tree、dirty state、Codex/Node/Dart/Flutter/SQLite/Xcode/iOS 版本；上述身份只能证明设计输入，不能替代开工时事实。

## 2. 全波次不变量

1. Provider durable history 始终是会话事实权威；Bridge 持久层是可验证、可复用 cache，不是第二 Provider history。
2. 一个 source、一个 feature 在任一时刻只有一个 active owner、一个 writer 和一条 UI publication path。
3. 不建立 V2、Mirror writer、legacy runtime、dual read、dual write、运行时 adapter 或失败时自动回退旧链。
4. live body 只在 generation/source-fenced memory overlay；重启后通过 bounded durable read 修复。
5. operation 必须 admission/idempotency durable commit 在先，dispatch 在后；`OUTCOME_UNKNOWN` 只允许只读 reconcile，禁止盲重发。
6. actor 只从 authenticated connection context 注入。route/IP/URL/title/text/time/generation 都不是数据身份。
7. Mobile 只有在 staging、SQLite transaction、readback 全部成功后才能 ACK 和 Repository publish。
8. 旧 Provider rollout、旧 CC Pocket 数据库、现有 draft、queue、credential、settings、transfer checkpoint 和用户文件不得被修改或删除。
9. v4 使用新文件名和新 namespace；默认不导入旧数据。任何 importer 必须另行设计、进程外、一次性、显式授权、可删除，且不得成为运行时依赖。
10. 每波只增加一个累计可运行的 business slice；schema、生成代码、测试数量或静态调用图不能单独宣告通过。
11. 每波通过后形成一个 Conventional Commit，完整 SHA 记为该波 `R-Ixx` 回退点。失败修复另增提交；禁止以 reset/rebase 改写已审核回退点。
12. `design/source/build/deploy/IPA/OTA/install/device/stable` 是九个独立状态；任一较低层 PASS 不得提升较高层状态。

## 3. 阶段依赖与 C0–C6 的正确位置

本地实施共 19 个累计阶段 `I00–I18`。原输入包的 C0–C6 只映射到本地早期阶段，不是云端/外部 Phase 2 设计的前置：

| 原标签 | 本草案阶段 | 解释 |
|---|---|---|
| C0 | I01 | 合同、有限 codegen、golden/fault vectors |
| C1 | I02 | Bridge domain/ports、memory-only writer |
| C2 | I02–I03 | bounded Codex read、receive/order，再单独落 Bridge persistence 回退点 |
| C3 | I04 | Mobile generated types 与 memory Repository |
| C4 | I05 | 新 Mobile SQLite replica、commit/readback/publication |
| C5 | I06 | live overlay 与 canonical 原位晋升 |
| C6 | I07 | 单个 `START_TURN` operation slice |

Phase 2 设计只依赖 `PHASE1_AMENDMENT_ACCEPTED`，不等待 C0–C6。Phase 2 的本地生产实现则必须等待它消费的 core contract/port 已在对应 I 阶段通过；这是实施依赖，不是云端设计依赖。

## 4. 共同证据格式

每次测试、probe 或 rehearsal 都写入不可覆盖的 run directory，并在 process ledger 中只追加摘要：

```text
docs/design/codex-kernel-v4/validation/runs/<UTC-run-id>/
  identity.json
  commands.jsonl
  results.jsonl
  artifacts.sha256
  raw/                 # 脱敏原始请求、响应、SQLite/fixture 摘要
  RESULT.md            # PASS / FAIL / NOT_RUN / BLOCKED
```

`identity.json` 至少包含 source/tree、实现 HEAD、目标 Codex binary SHA-256、schema/generator hash、state-dir、测试端口、工具版本和 `productionTouched=false`。实验失败必须保留，后续 run 不覆盖旧结果。

## 5. 累计 vertical slices

### I00 — 事实冻结与实施工作树

- 输入：用户已接受的 Phase 1 累计设计、source lock、P0/P1 closure register、当前 source map、原 P-001/P-019/P-022 probes。
- 可改：实施专用 docs/ledger、隔离 probe harness、脱敏 fixtures；不得改 production composition。
- 不得触碰：`index.ts`、`websocket.ts`、`session.ts`、`codex-process.ts` 生产路径，Mobile composition roots，任何现有 DB、`8765`、系统/用户配置。
- 门禁：精确 target Codex build/binary hash、方法面、schema/capability snapshot；可复现 fact-pack；每个 load-bearing 假设标 `SOURCE_PRESENT/PROVIDER_VERIFIED/...`。
- 故障/实验：缺方法、schema drift、相邻 build 差异、损坏/部分 rollout、重复 fact capture；缺证据即禁用相关设计能力，不猜 fallback。
- 回退/数据：`R-I00` 只含事实与 harness；删除隔离 state 即可，用户数据零写入。

### I01 — 机器合同、有限生成与故意失败向量

- 输入：I00 事实包、accepted semantic dictionary、authority/identity/state/error/capacity registry、accepted wire/DDL。
- 可改：`packages/conversation-contract/**`，只生成当前已冻结核心和当下 slice 的 TS/Dart/schema/golden/fault artifacts。
- 不得触碰：Bridge/Mobile runtime、feature modules、52 项空合同、九个预建万能 port、Claude wire/DB/UI。
- 门禁：生成确定性、no-drift、TS↔Dart golden、schema negative vectors、DDL composite FK/partial unique/CAS、draft protection、zero triggers、unknown enum fail-safe。
- 故障/实验：跨 source/thread edge、双 ACTIVE claim、同 lane 双 dispatch、`OUTCOME_UNKNOWN+autoRetry`、invalid digest、oversized control body、draft cascade 均必须故意失败。
- 回退/数据：`R-I01` 为纯合同 commit；无 DB 安装，无 migration。

### I02 — Bridge read-only receive/cache/order 内存切片

- 输入：I01 generated contracts、I00 Provider facts、P-002–P-004/P-006/P-018/P-021/P-024/P-025、C-E01/C-E03/C-E04。
- 可改：`packages/bridge/src/conversation-core/{domain,ports,receive,repository,adapters/codex,testing}/**`；`codex-process.ts` 只允许一个只读、typed、默认未接 production route 的 seam。
- 不得触碰：`websocket.ts` routing、`SessionManager` mutation、Action Broker、InputDeliveryLedger、生产 catalog/history owner。
- 门禁：一 source/一 thread/一 bounded range 从 raw→candidate→verified canonical；disjoint islands 显式 Gap；arrival/time permutation 不改变 durable order；warm memory cache 零 Provider body read。
- 故障/实验：partial/empty/error/timeout/malformed/conflicting overlap/cursor loop/source mismatch/oversized item；last-good byte-for-byte 不变，无法 bounded read 时 capability fail-closed。
- 回退/数据：`R-I02` 只含 disabled read path；内存状态随进程退出消失。

### I03 — Bridge v4 persistence

- 输入：I02 canonical model、accepted Bridge DDL、schema hash、SQLite kill-point plan。
- 可改：`packages/bridge/src/conversation-core/{storage,repository,testing}/**`；只在隔离 `BRIDGE_STATE_DIR` 创建 `conversation_kernel_cache_v4.db`。
- 不得触碰：Provider SQLite/rollout、旧 Bridge DB、production state dir、旧 cache writer、runtime routing。
- 门禁：staging→validate→atomic head commit→readback；same-source FK、sole canonical writer、last-good head、restart recovery、warm DB cache 零 Provider body read。
- 故障/实验：每个 transaction/I/O 边界 kill、WAL partial copy、disk full、busy/lock、hash mismatch、foreign segment/head、schema mismatch；失败不能发布新 head。
- 回退/数据：`R-I03`；此阶段 DB 全是隔离可重建数据，可保留作证据或删除隔离目录，绝不删除旧 DB。

### I04 — Mobile generated types 与 memory Repository

- 输入：I01 generated Dart contracts、I02/I03 golden snapshots、Repository publication contract。
- 可改：`apps/mobile/lib/conversation_core/{domain,protocol,repository,testing}/**` 与 `apps/mobile/test/conversation_core/**`。
- 不得触碰：`main.dart`、`BridgeService` production dispatch、`ChatSessionCubit`、`SessionListCubit`、现有 catalog/Mirror publication。
- 门禁：typed decode/validate、unknown future value fail-safe、one committed snapshot→one Repository revision、late/duplicate/reordered input 收敛；UI consumer 只见 committed objects。
- 故障/实验：malformed frame、wrong source, missing required capability binding、revision rollback、duplicate item、unknown item；不得 optimistic publish。
- 回退/数据：`R-I04`；memory-only，无持久数据。

### I05 — Mobile SQLite replica、ACK 与 Repository publication

- 输入：I04 Repository、accepted Mobile DDL、C-E08 commit chain、I03 durable events。
- 可改：`apps/mobile/lib/conversation_core/{storage,repository,testing}/**`；只创建新 `conversation_replica_v4.db`，protected local-state namespace 独立。
- 不得触碰：旧 `ccpocket.db`、Mirror DB、现有 draft/queue/credentials/settings/transfer checkpoints、旧 UI publication owners。
- 门禁：WSS fixture→staging→SQLite commit→readback→ACK→Repository publish；restart 恢复；source partition；draft/intent survival；200-entry render window 与大历史有界读取。
- 故障/实验：在 decode/staging/commit/readback/ACK/publish 各点 kill；duplicate/reorder/gap/base-revision mismatch/disk full；ACK 永不早于 readback。
- 回退/数据：`R-I05`；隔离 replica 可丢弃，protected local state 不动。任何生产 rehearsal 后默认保留 v4 DB 文件，不自动清理。

### I06 — live overlay、fence 与 durable repair

- 输入：I03/I05 committed chain、P-005/P-007/P-013/P-027、C-E02。
- 可改：Bridge/Mobile 新 `conversation-core` live modules 和 tests；仍不接旧 UI owner。
- 不得触碰：durable tables 增加 live body、第二 observer、production connection、旧 runtime continuity fallback。
- 门禁：同一 item live→canonical 原位晋升；disconnect/restart/source switch/runtime replacement 清 overlay 并 bounded repair；DB audit 证明无 live body。
- 故障/实验：duplicate/reorder/late generation/orphan delta/observer takeover/crash before durable reread；旧 fence 永不恢复 ownership。
- 回退/数据：`R-I06`；禁用/删除 live composition，durable read-only chain继续可用；无 live 数据需迁移。

### I07 — 单个 `START_TURN` operation

- 输入：I01 operation contract、I03 durable ledger、I05 local intent/repository、P-008–P-010/P-023、C-E05/C-E06。
- 可改：Bridge/Mobile 新 `operation/**`；Provider adapter 只增加 typed `START_TURN`；专用 test transport。
- 不得触碰：queue/steer/stop/interaction breadth、generic command、旧 input ledger production owner、真实 user thread。
- 门禁：admission+digest durable commit→dispatch barrier→Provider receipt/correlation→canonical user item→terminal/reconcile；same ID+digest converges，digest conflict rejects。
- 故障/实验：before write/during write/after provider execution before receipt/after receipt before commit 全 kill matrix；ambiguous 必入 `OUTCOME_UNKNOWN`，零盲重发。
- 回退/数据：`R-I07`。未 dispatch 可撤 candidate；一旦 `DISPATCHING/OUTCOME_UNKNOWN`，ledger 必须保留并先用 v4 read-only reconcile 收口，禁止切回不知情的旧 mutation owner。

### I08 — queue、edit/cancel、steer 与 stop

- 输入：I07 operation kernel、accepted queue/lane/revision contract、P-011。
- 可改：新 operation queue modules、typed Mobile controllers/Repository projections；一次只增加一种 action。
- 不得触碰：reorder（未确认能力）、offline draft 与 Bridge queue 合并、Mobile queue authority、generic replay。
- 门禁：online in-flight、offline intent、Bridge queue、Provider accepted 四态分离；exact item/revision update/cancel；每次 input-ready 最多 dispatch FIFO 队首；steer/stop 前置条件与 terminal 完整。
- 故障/实验：cancel-vs-dispatch、edit stale revision、duplicate reconnect、queue full、crash after dequeue、owner unavailable；未知结果不自动重投。
- 回退/数据：每种 action 独立 commit/rollback；operation ledger 保留，未确认动作入口 capability-gated unavailable，不回旧路径。

### I09 — Interaction 与多设备 claim

- 输入：I07 dispatch/reconcile、authenticated actor、P-012/P-026、C-E07。
- 可改：新 `interaction/**`、Mobile interaction controller/renderer、typed approval/question/MCP/ExitPlan variants。
- 不得触碰：client-self-reported actor、第二 pending store、notification delivery 写 timeline、未知 interaction 自动批准。
- 门禁：exact source/thread/turn/request；single active renewable claim；response 复用 operation path；两设备收敛；restart/open enumeration completeness 有事实证据或明确降级。
- 故障/实验：双 claim、lease expiry、late device response、runtime replacement、duplicate notification callback、provider receipt loss；ambiguous response 永不重放。
- 回退/数据：`R-I09`；逐 interaction type 关闭 capability，manual interaction path仍由同一 broker 拥有，不能退回旧 broker。

### I10 — settings、Goal、Plan、relations 与 child conversations

- 输入：I09 Interaction、accepted thread-state/relation contracts、P-014–P-017。
- 可改：新 settings/thread-state/relation modules；Goal Provider adapter；Plan timeline/settings/ExitPlan projection；Fork/review/persisted+ephemeral Side Chat/subagent adapters。
- 不得触碰：CC-owned Goal document、Plan 单一混合 authority、第三 timeline、legacy Side Chat runtime、child history store。
- 门禁：Goal get/set/clear 冲突；Plan item原位更新；collaboration=settings；ExitPlan=Interaction；relation source/boundary/parent-child proof；child 复用普通 repository/live。
- 故障/实验：compact/fork ID changes、duplicate child create、ephemeral disconnect cleanup、cross-source parent、bounded descendants、subagent watcher overflow、unknown relation kind。
- 回退/数据：每个 state/relation feature 独立 commit；关闭 feature adapter/UI，保留已接受普通 conversation/relation core；不恢复旧 runtime。

### I11 — 核心关联产品 controllers

- 输入：I05–I10 Repository/ports，K-003/K-004/K-009/K-010/K-017/K-023/K-025/K-026 的 Phase 2 remainder。
- 可改：archive/prompt history/insights/auto-approval/diagnostics/status/process disclosure/timestamp 的 feature-owned adapter/controller/UI；旧 Cubit 只做窄消费切换。
- 不得触碰：Repository 之外读 raw frame/SQL、quota 推断 settings、diagnostics 成为事实源、auto-approval 第二 interaction store。
- 门禁：每个 feature 有独立 typed adapter、characterization+new-owner tests、one publication owner、feature-local disabled state 和独立 revert point。
- 故障/实验：unknown/degraded/notLoaded/ownedElsewhere 组合、diagnostic redaction/bounds/replay、policy fail-closed、archive error/outcome unknown。
- 回退/数据：逐 feature revert；核心 repository/contract不回退，旧 UI owner 在切换前已停止且不能作为 fallback 保留。

### I12 — 设备、routes、配对与 readiness（P-001–P-004）

- 输入：authenticated execution context、route/source fence、Repository publication、Phase 2 feature designs、P-E01。
- 可改：现有 identity/pairing/auth/readiness/discovery/machine modules及其 UI/tests；在原 owner 内最小适配。
- 不得触碰：route/IP 作为数据身份、冷启动自动连 WS、连接 key 与文件 mutation step-up 混用、未 ready source 发布。
- 门禁：signed computer grouping 不合并 route records；pair/revoke/key recovery；route switch不串 cache/queue；transport/auth/catalog/application ready 分层；旧 epoch丢弃。
- 故障/实验：corrupt identity、wrong signature、token expiry/replay、same endpoint different Bridge、same Bridge multiple routes、readyz timeout。
- 回退/数据：P-001–P-004 各自 commit；保留 route records/trust data，关闭新 adapter/UI；不得把来源重新按 endpoint 合并。

### I13 — 文件、content plane、transfer、mutation、preview 与 media（P-005–P-011）

- 输入：ContentRef/resource ticket、ExecutionContext、protected namespace、composer ingress、P-E02–P-E05。
- 可改：现有 file browser/transfer/mutation/artifact/preview/gallery/image Bridge/Mobile/native modules；bytes 走 HTTP/content plane。
- 不得触碰：WS 大正文、真实 path/token 过线、partial file 可见、`faceIdPassed` 布尔授权、万能 file/resource core、旧 DB 迁移。
- 门禁：browse/read、opaque ref、Range/ETag/digest/resume、15 GiB/2 GiB bounds、no-overwrite/atomic landing、Quick Look fallback、received inbox、composer attachment 全部独立 E2E。
- 故障/实验：traversal/symlink/TOCTOU/path swap、expired/revoked ticket、low disk/low memory/restart/hash mismatch、biometry change/replay、unknown binary。
- 回退/数据：P-005–P-011 逐 feature commit；进行中的 transfer checkpoint 与已落盘文件保留，关闭入口不删除用户文件或 proof/audit records。

### I14 — Git、workspace 与 capture（P-012–P-013）

- 输入：Phase 2 action inventory、workspace identity、ContentRef/authorization ports。
- 可改：现有 Git/worktree/screenshot/recording services、controllers/UI/tests。
- 不得触碰：generic shell RPC、任意 cwd、自动 commit/delete、Git/capture result 写 canonical、无限录制保留。
- 门禁：read-only status/diff先行；mutation单独确认/授权；stale conflict和rollback可见；capture permission/capacity/list/play/delete/share完整。
- 故障/实验：dirty/stale branch、worktree race、missing file、permission denial、recording crash/oversize/privacy redaction。
- 回退/数据：Git/capture独立 commit；不自动逆转用户已完成的 Git mutation，不删除 capture；回退只撤 adapter/UI。

### I15 — 通知、后台、权限、更新、native host 与 cache（P-014–P-017/P-024/P-026）

- 输入：post-commit projection、Interaction、lifecycle fence、protected namespace、P-E06/P-E07。
- 可改：现有 notification/background/permission/update/mobile-host/cache modules和逐 plugin native tests。
- 不得触碰：通知成为 canonical、后台常驻承诺、启动即弹权限、万能 native gateway、版本号冒充兼容性、broad clear 删除 protected state。
- 门禁：in-app/local/remote 分开；force-quit foreground repair；per-plugin capability/API/epoch；late callback丢弃；namespace clear/restart存活；source/build/deploy/IPA/OTA/install/device/stable UI准确。
- 故障/实验：缺 entitlement/profile、APNs/FCM failure、thermal/low-power、permission revoke、old base IPA、duplicate callback、revision mismatch、clear-all攻击向量。
- 回退/数据：每 feature/plugin独立 commit；native change只能随新 base IPA交付；cache rollback不删除任何 protected/旧完整副本。

### I16 — voice、icon、commerce、shell、本地化与 effort 视觉（P-018–P-023/P-025）

- 输入：composer ingress、settings ACK、Phase 2 UI/native designs、P-E08。
- 可改：现有 voice/icon/RevenueCat/router/shell/ARB/translation/effort motion/status UI及 tests。
- 不得触碰：自动发送语音 partial、commerce限制核心、动态翻译 command/path/secret、可达 Claude runtime/route、视觉状态成为 domain authority。
- 门禁：voice partial/final/cancel/selection；icon readback rollback；purchase/restore不影响核心；route inventory与离线内容；ARB完整；六档 effort ACK/conflict；72×6 Max/Ultra几何、速度、RTL、reduced motion、frame budget、GPL attribution。
- 故障/实验：permission unavailable、store offline/cancel、unsupported icon/OS、translation拒绝/超时、stale settings ACK、Ticker pause/resume、old native shell。
- 回退/数据：逐 feature/UI commit；保留原文、购买事实与用户设置；仅撤 adapter/UI，不改 Session Kernel settings contract。

### I17 — 全链 E2E、fault/soak、性能、安全与升级认证

- 输入：I00–I16 全部绿色回退点、相邻两个 Codex builds、真实但隔离的短/长/tool/image/fork/active fixtures。
- 可改：tests、harness、sanitized evidence、确定性修复；修复必须回到 owning stage 的模块并新增 commit。
- 不得触碰：production `8765`、真实用户 thread mutation、部署配置、发布元数据、门禁降级。
- 门禁：8766+独立 state dir 的 WSS→Bridge DB→Mobile DB→ACK→Repository→UI；短/长/同名/fork/tool密集/断线/多设备；冷暖性能、内存/帧/容量、安全、Codex build drift。
- 故障/实验：所有原 P-001–P-027、C-E01–C-E08 和适用 P-E01–P-E08；结果只可 PASS/FAIL/NOT_RUN/BLOCKED。
- 回退/数据：`R-I17` 是候选前最后源码回退点；所有 fixture/state隔离，raw evidence脱敏并 hash。

### I18 — 候选切换演练与封印

- 输入：I17 全绿、source+feature cutover manifest、旧/新全版本 rollback artifacts、用户对候选演练的单独授权。
- 可改：候选构建/packaging ledger与切换脚本；不得在本阶段顺便修业务语义。
- 不得触碰：未授权 production 8765、IPA/OTA/install/stable、旧 DB、网络/LaunchAgent除获准候选演练规定项。
- 门禁：候选包中一个 active kernel；architecture grep无 V2/Mirror/legacy fallback/dual write；source+feature逐项 owner证明；pre/post snapshot；read-only cutover、one-operation canary、rollback rehearsal。
- 故障/实验：候选启动失败、identity mismatch、schema mismatch、ACK loss、post-dispatch crash、old-version rollback；`OUTCOME_UNKNOWN` 情况必须证明 rollback会阻断旧 mutation owner。
- 回退/数据：`R-I18` 为候选封印 commit。实际切换按 `MIGRATION-CUTOVER-PLAN.md`；本草案完成不代表候选已构建、部署或发布。

## 6. 每波提交与审核规则

- 每个 I 阶段至少一个内聚 Conventional Commit；同一阶段多 feature 时按 feature 拆分，最后用一份 gate report 绑定完整 SHA 列表。
- 下一阶段只从上一阶段全部 accepted commit 向前，不 cherry-pick 未通过的试验 commit。
- 回退使用 `git revert` 或停止未激活 composition；不使用 runtime fallback，不把旧 writer 再接回同一 candidate binary。
- 同一 source/feature 的旧 owner 必须先停止 publication/dispatch，再激活新 owner；测试环境也不得让两个 writer同时提交以“比较结果”。
- 自动门禁失败后保留失败 evidence，状态为 FAIL；缺工具/设备/授权是 BLOCKED 或 NOT_RUN，不能写 PASS。

## 7. 当前完成状态

本草案仅完成实施顺序设计。I00–I18、所有 Provider/SQLite/runtime/UI/native/device 实验和九类交付门禁均为 `NOT_RUN`；C0–C6 也未获实施授权。
