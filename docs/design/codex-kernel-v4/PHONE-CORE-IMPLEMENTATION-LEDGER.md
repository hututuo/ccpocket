# PVMC-1 implementation ledger

状态：`IN_PROGRESS / PHONE_VERIFIABLE_MESSAGE_CORE_CANDIDATE_NOT_REACHED`

本账本 append-only。失败、未运行门禁和被后续提交修正的事实不得删除或覆盖。

## 1. 固定身份

| 项目 | 精确身份 |
|---|---|
| L00 accepted review point | `b100a212b9fc134d9adbea872914ea0a906b3dcb` / tree `c0fcf47dac5fed1aadc91d29ecfa1b747364aa1e` |
| R82 authority record | `codex/codex-kernel-v4-local-design-20260830@5a3aa7326473048f0999da6973a10dfbfabe6dc4` / tree `72e5e845f557b18053f73b7c6cc0bde9568e8dbd` |
| implementation start | `codex/codex-kernel-v4-implementation-20260830@abe0bc83956ec966d895daa393baf82848fb6cce` / tree `21ad12bd7c9ecd854f1b1b9171b17f8faba1cb73` |
| old machine donor | `2f8b984b4ce22c1a0a1b520c04e29085a4fd62d3` / tree `79511ceb485233185e140ebd508613649a89669f`；selective donor only |
| dirty donor main | `a706200233c55cc82d7a17e433f80f132d0f280d` / tree `ac85f620445151f45eda856f55f4b96ee442f41a`；未修改 |

## 2. 授权与禁止

允许：active-profile contract/codegen、Bridge/Mobile 源码和测试、fresh isolated DB、精确
Codex isolated probe、测试端口 `8766`、simulator E2E、手机测试候选构建。

禁止：读取/迁移产品 DB、接触生产 `8765`、merge、push、部署、发布、OTA、stable、替换
生产 Bridge、真机安装。真机安装只在候选完成后请求一次授权。

## 3. 内部原子阶段

| Gate | 状态 | implementation commit | rollback | 验证/报告 |
|---|---|---|---|---|
| R82 authority scope | `STATIC_VERIFIED` | design branch `e69a9808`, record `5a3aa732` | `b100a212` | R82 CSV/document parse；dirty main 与 implementation host 身份复核 |
| K00 active contract/tooling | `IN_PROGRESS` | tooling `0e12eeb6`; parity `a94a4b2a`; formatted digest `a57df860`; formal registry pending | `292f7587` | fixture validate/check/golden PASS；Dart 3.13 format PASS；正式 active profile 尚未生成 |
| K01 memory receive | `IMPLEMENTED` | `69f36b5a` | `a57df860` | 21 focused tests + full Bridge 1093 tests + full tsc PASS；independent review/contract alignment pending |
| K02 isolated Codex read | `NOT_STARTED` |  |  |  |
| K03 durable receive/repository | `IN_PROGRESS` | Bridge/Mobile worker branches pending integration | `f6158753` | isolated Bridge store and Mobile replica implementation underway |
| K04 send/queue/control/reconcile | `NOT_STARTED` |  |  |  |
| K05 manual Interaction | `NOT_STARTED` |  |  |  |
| K06 8766/simulator/candidate | `NOT_STARTED` |  |  |  |

## 4. 已发现事实与失败

- `docs/PROJECT_HANDOFF.md`、相关 `decisions.md`、`CLAUDE.md` 以及
  `flutter-ui-design`、`test-bridge`、`test-flutter`、`mobile-automation` 已完整读取。
- CodeGraph 对该 implementation worktree 返回 `no .codegraph/ directory found`；本任务
  不再对该 worktree调用 CodeGraph，改用直接源码检查。该失败不影响编译/测试门禁。
- 当前尚未运行 contract generation、Bridge/Mobile tests、SQLite、Provider、8766、
  simulator 或 candidate build。
- `mise exec node@22.23.1 -- npm ci` 于 `2026-08-30` 失败：上游
  `scripts/setup-hooks.sh` 把 worktree 的 `.git` 文件误当成目录并尝试写入
  `.git/hooks/pre-commit`。失败发生在依赖解包后的 `prepare`，未修改 tracked 文件；记录保留，
  不把它改写成依赖失败。
- 随后使用 `mise exec node@22.23.1 -- npm ci --ignore-scripts` 成功安装锁文件中的
  212 个 package；该替代只跳过上述仓库 hook 安装，不跳过后续 Bridge 构建/测试。
- Node `22.23.1` 的 `node:sqlite` `DatabaseSync(':memory:')` strict table
  create/insert/readback smoke 通过，但该 Node 版本仍输出 `ExperimentalWarning`；这里只记录
  工具链事实，尚未裁定或安装 K03 持久化实现。
- 未修改产品源码的 `c3c5ba32` 基线在 Node `22.23.1` 下通过
  `npm run test:bridge`（41 files / 1072 tests）和
  `npx tsc --noEmit -p packages/bridge/tsconfig.json`。测试日志中的预期 git negative-case
  stderr 不计作失败；这只证明 Bridge source baseline，不证明 V4、Provider、DB 或 runtime。
- 未修改 Mobile 源码的基线使用 `mise` 固定 Flutter `3.47.0` / Dart `3.13.0` 完成：
  `flutter pub get`（lockfile 无漂移）、
  `dart format --output=none --set-exit-if-changed apps/mobile`（483 files / 0 changed）、
  `dart analyze apps/mobile`（exit 0；45 条既有 info，无 error/warning）以及
  `cd apps/mobile && flutter test`（1728 tests / 4 skips / PASS）。测试日志中的
  DatabaseService no-op warning 与 deliberate connection-refused 场景属于既有预期输出；这些结果只证明
  Mobile source baseline，不证明 V4 repository、数据库、simulator 或真机行为。
- 精确 Codex CLI 事实探针使用
  `/Users/developer/.codex/packages/standalone/releases/0.151.0-aarch64-apple-darwin/bin/codex`
  （`codex-cli 0.151.0`，binary SHA-256
  `98491713ffb196061003ee148636e743997cc31d76144ba7c53462269896891d`）执行
  `codex app-server generate-json-schema --experimental`。生成主 Schema 为 804400 bytes，
  SHA-256 `31ae67beb2c94cc9509f6a71968600062dc8c6d7fe45437ed3a9129838f4d2d9`；
  `TurnStartParams`、`TurnSteerParams`、`ThreadReadResponse` 片段 SHA-256 分别为
  `b36fb37326b1cf69f75c8b306f1f886d53a57c4b1b985e08e298e2407ea2ad02`、
  `2e0cdcea6a90d6c8bc584fdc2ff838e824754b1eef0d2d16aa71bec4276fef44`、
  `4632758fd76056d99c81857e85df4de32f252d017d3abeb5224fe96ca149163f`。
- 上述静态 Schema 证明 `turn/start` 和 `turn/steer` 接受可选
  `clientUserMessageId`，但 `thread/read` 历史不会回显它；正常在线路径可以把 operation 绑定到
  `turn/start` 返回的 provider turn ID，崩溃后未拿到返回值的 dispatch 仍必须进入
  `OUTCOME_UNKNOWN`，禁止依赖文本/时间模糊匹配或自动重发。精确 build 还暴露 provider queue RPC，
  但其跨重启持久语义未被证明，PVMC-1 不把队列权威移交给 Provider。
- 以上 Codex 结果是 `STATIC_FACT_PASS / RUNTIME_NOT_RUN`；尚未启动 app-server、执行真实
  thread read/send、触碰 Provider 状态或把临时生成的完整 Schema 纳入 Git。
- K00 tooling worker commit `02e5dd51` 经根分支重放为 `0e12eeb6`。根复核后另外提交
  `a94a4b2a`，要求每条 active hard rule 同时拥有 positive/negative vector，并把 JSON Schema
  integer 限定到 TS `Number.isSafeInteger` 的相同边界；随后提交 `a57df860`，用固定 Dart
  `3.13.0` formatter 处理生成文件后再计算 artifact digest。fixture 的 validate/check/4 golden
  均通过，生成 Dart 再运行 format 为 0 changed。当前根脚本仍指 package fixture，不能冒充
  正式 PVMC-1 profile；formal registry 和产品目标生成仍在进行。
- K01 worker commit `3b349eb8` 经根分支重放为 `69f36b5a`。它新增纯内存
  ProviderHistoryReader/receive core，包含 exact SourcePartition、single-flight 首读、完整 cache
  复用、bounded window、deterministic ordinal/typed Gap、partial/empty/error/timeout last-good、
  generation fence、unknown item 与 live identity promotion。根环境复跑 focused Vitest 21/21、
  完整 `npm run test:bridge`（42 files / 1093 tests）以及完整 Bridge `tsc --noEmit` 全部通过；
  runtime/DB/wire/UI 尚未接入，独立审查尚未回流。

## 5. 独立交付状态

| Gate | 状态 |
|---|---|
| source implementation | `IN_PROGRESS` |
| Bridge baseline build/tests | `PASS`（V4 changes 尚未验证） |
| Mobile baseline analyze/tests | `PASS`（V4 changes 尚未验证） |
| isolated DB/crash tests | `NOT_RUN` |
| Codex static schema facts | `PASS` |
| Codex isolated runtime facts | `NOT_RUN` |
| test Bridge 8766 | `NOT_RUN` |
| simulator E2E | `NOT_RUN` |
| phone candidate build | `NOT_RUN` |
| phone install | `NOT_AUTHORIZED / NOT_RUN` |
| merge/push/deploy/release/OTA/stable | `NOT_AUTHORIZED / NOT_RUN` |

## 6. 2026-08-30 13:50 +08 可恢复检查点

本节追加事实，不改写上文在当时成立的 `NOT_RUN`、PASS 或失败记录。

- 精确检查点：`82da06fcefd7ba877988e484f085818d0d9897be` 后选择性集成 K03 Bridge
  Store 为 `9c1a87c7e3be53f4fcf850e37a9a24f166039d80`，tree
  `8d976a287a1dc57d78fc1cfbec3c87f8722a103a`；集成前后根工作树均 clean。
- 正式 PVMC-1 authority 已由 `82da06fc` 纳入 Git：1 个 active profile、75 个定义、
  18 条 hard rule、51 条向量（31 positive / 20 deliberate negative）。它仍处于
  `IN_PROGRESS`：精确 Codex 运行事实要求在生成前增加 provider instance epoch、read evidence、
  独立 turn/item/timeline ordinal、oversized-turn Gap，并把未实现的 item/timeline paging 标为不可用。
- 精确 Codex `0.151.0` 隔离只读运行事实已取得：代表性长 thread 的两次完整
  `thread/read` 均为 82 turns / 6,594 items / 14,589,544 bytes，结构/content hash 一致，
  provider turn/item ID 无缺失或重复。此完整读取只作为事实 oracle，不作为常规缓存加载路径。
- `thread/turns/list` 真实运行可用并返回 opaque cursors；notLoaded 20-turn 页为 3,717 bytes，
  newest full 2-turn 页约 2.54 MiB / 531 items，older full 2-turn 页约 2.81 MiB / 728 items，
  重复读取 hash 稳定。`thread/items/list` 和 `thread/timeline/list` 虽存在于生成 Schema，
  但精确 build 运行时都明确返回 not supported；这两项记录为
  `RUNTIME_UNAVAILABLE`，禁止伪装成 item paging capability。
- `ac1ddfd2` 仅增加 Codex read-only paged RPC seam、边界验证、测试和脱敏事实脚本；
  targeted Codex tests 82/82、full Bridge tsc PASS。未启动 Bridge、未使用 8765、未写 Provider。
- K01 独立审查在原有 21/21 与 full suite PASS 之后重新打开六个 P1，因此 K01 当前为
  `IN_PROGRESS / REWORK_REQUIRED`，原 PASS 不删除：并发旧 flight 可覆盖新 head health；
  live promotion 可换位且缺少 payload conflict；畸形 Provider DTO 可泄漏 raw TypeError；
  hostile JSON `__proto__`/cycle/depth 未 fail closed；canonical/live cache 无输入容量边界；
  generation 未绑定 providerInstanceEpoch。另需补 read evidence/order proof、typed authoritative-empty、
  refresh single-flight、core deadline、空 turn 保留、Gap 去重和 stronger-partial 合并。修复工作在
  独立 K01/K02 原子分支进行，尚未宣告复审通过。
- K03 Bridge Store 选择性集成提交为 `9c1a87c7`，只新增未接运行路由的显式 SQLite store：
  WAL、foreign keys、FULL synchronous、STRICT schema、timeline/operation/queue/interaction 事务 seam。
  依赖锁定 `better-sqlite3@12.10.0`；根环境重新执行 `npm ci --ignore-scripts`（247 packages）
  和 `npm rebuild better-sqlite3` 成功。仓库 hook 的既有 worktree `.git` 失败仍保留，不冒充已修复。
- K03 根验证：focused store Vitest 23/23 PASS；完整 Bridge Vitest 43 files / 1,118 tests PASS；
  `npx tsc --noEmit -p packages/bridge/tsconfig.json` PASS。独立 Store 审查仍在进行，故 K03 仅为
  `IMPLEMENTED / REVIEW_PENDING`，不是 runtime、DB installation 或手机验收完成。
- 本检查点未创建产品数据库，未启动 8765/8766，未运行 simulator/candidate，也未进行
  merge、push、部署、发布、OTA、stable 或真机安装。

## 7. 2026-08-30 K03 独立审查失败记录

本节取代的只是 K03 “可能成为合格基线”的判断，不删除第 6 节的实现与测试事实。

- 独立只读审查结论：`FAIL / P0=3 / P1=5`。因此 `9c1a87c7` 保留为可回退的原子实施
  checkpoint，但 K03 状态降为 `IN_PROGRESS / REWORK_REQUIRED`，不得接生产或 runtime route。
- P0-1：原状态机允许 `OUTCOME_UNKNOWN -> CANCELLED/REJECTED` 并清除 reconcile block；
  最小复现无需 verified fact 即可抹掉未知 Provider 副作用，违反绝不自动重发门禁。
- P0-2：queue ownership、root operation state 和 dispatch barrier 分属不同事务；重启可留下
  `DISPATCH_OWNED + ADMITTED`，且同一 root operation 可重复进入 16 个 active entry。原容量测试
  把该缺陷当作正例，不能继续作为验收证据。
- P0-3：timeline commit 只信调用方 `verified:true`，没有重新验证 read evidence、coverage island、
  order proof 或 Gap；`[timelineOrdinal 0, 100] + no gap` 可被提交为 healthy canonical。
- P1：operation fingerprint 由调用方自报、authenticated actor 未进入真实 admission boundary；
  degraded/timeout 可创建或推进 canonical head，而 exact authoritative empty 无法表达；唯一 writer
  只有单进程字符串 Set；JSON/容量/terminal 约束未进入 DDL；Interaction response 后 claim 仍
  ACTIVE，actor/source fence 只是调用参数。
- 正向事实仍保留：单 ACTIVE claim partial unique index 能在直接 SQL 层拒绝第二条 ACTIVE claim；
  这不足以关闭其他 claim/actor/response 生命周期缺口。
- 第 6 节的 focused/full PASS 实际由默认 Node `26.4.0` / ABI `147` 执行。独立审查用既有
  ABI 147 node_modules 在 Node `22.23.1` 下打开 DB 会 ABI mismatch；隔离 fresh install 的
  `better-sqlite3@12.10.0` 在 Node 22 macOS arm64 smoke 可用。因此这是依赖安装纪律与尚未完成的
  Node 22 门禁，不是可以忽略的 source PASS。当前 lock 还含本次新增依赖的 `npmmirror.com`
  resolved URL，重构必须切回官方 npm registry 并复核 integrity。
- 已从 `64bc007c` 建立独立 K03 Store rework 分支，目标包括 immutable unknown + append-only
  reconcile、atomic queue/operation barrier、verified materialization staging、authenticated admission、
  bounded canonical JSON/DDL、真实 writer lease + dedicated worker thread 和固定 Node 22 验证。
- 本审查和返工均未创建产品 DB、未启动 Bridge/Provider、未接触 8765/8766，也未授权发布动作。

## 8. 2026-08-30 K00 生成工具加固集成

- 权威设计分支已依据精确 Codex 运行事实追加三笔修订：`9e9ec10d`（paged read facts）、
  `6ab9022b`（bounded canonical staging）和 `5f928d49`（dispatch/storage authority）。这些提交只修订
  已接受架构中被运行事实证伪或补强的边界，没有重新引入 monolithic contract；正式 active
  Registry/Vectors 的对应机械修订仍在独立原子分支进行。
- K00 tooling worker `65a4cbd4` 经根分支选择性集成为 `79294193`。它把正式命令绑定到唯一
  Registry/Vectors 与四个精确项目目标，增加 strict duplicate-key JSON、active dependency cycle、
  empty active authority、TS/Dart namespace、safe integer parity、symlink/并发 writer、失败回滚与
  stale generated file 检查。其跨四目标写入保证的是同一生成进程内的失败回滚；未宣称断电下的
  跨文件系统事务。
- 根环境复跑 `npm test --workspace=packages/conversation-contract`：Node 11/11、fixture TypeScript
  strict compile、Dart 3.13 analyze/roundtrip 全部 PASS；fixture `generate` 后 `check` PASS 且工作树
  无漂移；`npm run conversation:contract:validate` 对当前正式 profile 返回
  `validate: pvmc1.phone-core.v1`。
- 正式四处 derived outputs 尚未生成，因为 runtime-fact Registry/Vectors 原子修订尚未回流；因此
  K00 继续为 `IN_PROGRESS`，不得把本节工具 PASS 写成 active contract generation PASS。
- 本次没有运行 Bridge、Provider、SQLite、8765/8766、Mobile、simulator 或 candidate，也没有
  merge、push、部署、发布、OTA、stable 或真机安装。

## 9. 2026-08-30 集成前合同、接收与 Mobile Store 复核

- runtime-fact contract worker 首次提交 `eb2b98b9` 通过自身 validate/generate/ref audit，但根复核
  暂不集成：它把 4 MiB 单 turn 对象上限误写成 256 KiB publication page 上限；同时 staged
  commit 仍通过 coverage islands、ordered item refs 和 commit gaps 重复整份逐 item 权威，长会话
  仍会形成 MiB 级单帧。该提交保留为失败事实，worker 正在追加修订：4 MiB turn 与 256 KiB page
  分离，items/gaps 进入有界 page，commit 只保留可从 staging 重算的 compact coverage/order proof。
- K01/K02 最新实现虽已通过 focused 44/44 与 Bridge tsc，独立只读复核结论仍为
  `FAIL / P0=0 / P1=4`：retired provider epoch 可 A→B→A 回退；epoch 切换后旧 live overlay 仍可暴露；
  live item lifecycle 可从 completed 回退 started 并清内容；畸形 URL fallback 可能保留 userinfo。
  同轮还要求修复 malformed DTO typed rejection、硬容量不可被配置放宽、core page count 复验、
  notLoaded/image-generation shape、order proof 重算、timeout 后底层 single-flight、live thread 释放和
  known-field-only projection。修订与同一 reviewer 复看正在原子分支进行，尚未集成。
- Mobile staged repository 最新 focused 结果为 30/30、定向 analyze 0 issues，但独立复核仍发现
  `P1=2 / P2=2`：commit 已落盘而 post-commit/readback fault 后，同一 commit 跨重启重试会因 staging
  已删除而失败；弱/空/错误的新 epoch 可能删除旧 last-good Gap。另需补全 foreign-schema exact
  column gate 与 `(providerTurnId,itemOrdinal)` 唯一/跨页校验。worker 正在修订并复看，当前不集成。
- 上述均是 pre-integration review，不改变根分支已通过的 K00 工具测试，也不把 worker 测试写成
  Bridge/Mobile runtime PASS。没有运行 Provider、产品 DB、8765/8766、simulator 或发布动作。

## 10. 2026-08-30 K02 稳定身份与私有状态集成

- identity worker 的首次实现 `507a237d` 与 lifecycle 加固 `b53f6074` 在根分支分别重放为
  `663d62e4`、`ee836cd5`，保留两个独立回退点。它建立持久 Ed25519 `bridgeIdentityId`、独立
  `bridgeInstanceId`，以及只保存 locator digest 的 Codex source registry；route、IP、path 和原始
  locator 不成为 identity，也不写入 registry。
- 首次复核发现 crash 后 lock 永久残留及 close/fsync 生命周期缺口后，没有覆盖失败记录；第二笔
  提交改为 bounded private owner metadata、dead-PID+grace reclaim、claim/tombstone、token+inode
  所有权检查，live/unknown/corrupt owner fail closed；POSIX 强制 directory fsync，Windows 仅容忍
  明确不支持的 errno；`close()` 共享完成 Promise、等待已启动 mutation 并拒绝未启动队列。
- 根环境用固定 Node `22.23.1` 复跑三个 identity focused files：3 files / 27 tests PASS；`mise`
  对无关 Shorebird registry 发出既有 warning，但命令 exit 0。完整 Bridge `tsc --noEmit` PASS；
  默认 Node `26.4.0` 完整 Bridge Vitest 为 46 files / 1,145 tests PASS。该 full PASS 仍不是后续
  persistent store 的固定 Node 22 ABI 门禁。
- identity 目前只作为未接 composition 的 authority module；authenticated connection、Provider
  process epoch、wire welcome 和 Mobile binding 仍未接入，故 K02 继续 `IN_PROGRESS`。
- 本次没有打开产品 state/DB，没有启动 Bridge/Provider/端口/simulator，也没有 merge、push、
  部署、发布、OTA、stable 或真机安装。

## 11. 2026-08-30 K00 工具独立复核与 authority 继续收敛

- 独立只读 tooling 复核结论为 `P0=0 / P1=3 / P2=2`。既有 strict duplicate JSON、active
  dependency/empty authority、TS/Dart namespace、safe integer 和临时 formal generate/check 仍
  PASS，但 `79294193` 尚不能成为最终 K00 gate。
- P1：词法 target-map 检查不能阻止 nested symlink 越出 project root；formal check 会跟随
  same-content target symlink，并忽略 stale symlink/directory；部分安装失败的 rollback 只按文件名
  删除，TOCTOU 下可能删除外部替换后的非生成文件。P2：crash 后 lock/stage 未被 check 暴露，且
  原测试没有覆盖部分 backup/install 后故障。原提交保留，tooling worker 正在追加逐级 realpath、
  exact lstat、stale transaction detection、inode-bound rollback 与故障注入测试。
- 权威设计在 `5f928d49` 后追加 `9f595ed8`：page 承载唯一 items+gaps，commit 只保留 compact
  可重算证明；随后 `e615860c` 定义 narrow message-image begin/chunk/commit ingress，使图片在
  durable admission 前形成 ContentRef，而不把通用文件互传/Gallery 拉进本批。该 ingress 仍待
  active Registry、Bridge/Mobile 和 runtime test 实现。
- 正式 derived outputs 继续 `NOT_GENERATED`；本节没有运行 Provider、DB、端口、Mobile、simulator
  或任何发布动作。
