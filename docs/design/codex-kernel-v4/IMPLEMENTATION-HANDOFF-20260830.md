# CC Pocket V4 手机可验证消息核心实施接手文档

更新时间：`2026-08-30 15:24 +08`

本文是当前实施任务的可恢复接手点，不是完成报告，也不取代权威设计或追加式过程账本。
接手者必须先读本文，再读：

1. `docs/design/codex-kernel-v4/PHONE-CORE-IMPLEMENTATION-LEDGER.md`
2. 干净兼容 checkout 中的
   `/Users/developer/AI agent/Codex/_keep/projects/ccpocket-compat/docs/PROJECT_HANDOFF.md`
3. 同一 checkout 的
   `/Users/developer/AI agent/Codex/_keep/projects/ccpocket-compat/decisions.md`
4. 实施 worktree 根目录的 `AGENTS.md` / `CLAUDE.md`

目标 implementation tree 本身没有 `docs/PROJECT_HANDOFF.md` 和 `decisions.md`；不得把旁支文档
误称为当前 commit 内文件，但其长期产品/验证/授权规则仍是本地兼容项目的治理输入。

## 1. 当前任务与暂停语义

当前唯一交付目标是：

`PHONE_VERIFIABLE_MESSAGE_CORE_CANDIDATE`

K00-K06 只是同一交付批次里的原子提交、验证门禁和回退点，不是分别等待用户审核的产品阶段。
最终必须连续形成真实手机可验证的 Codex 接收、缓存、顺序、发送、队列、控制与 manual
Interaction 链。当前尚未达到该候选点。

本接手点为了保存上下文而暂停集成尚未根审的 worker commit。它不授权推翻已完成调查，也不授权
回追旧 monolithic contract 的全量 PASS。

### 1.1 本批必须完成

- 接收：Codex `thread/turns/list` + live event，经 raw DTO 隔离、exact identity、可复用 cache、
  coverage/order/typed Gap/last-good、generation fence、exact live promotion、Bridge 单一 publication，
  最终进入 Mobile transaction/readback/ConversationRepository/UI。
- 发送：文字、图片、当前 structured refs，经 durable admission、server-derived fingerprint、FIFO
  queue/edit/cancel、`turn/start`、active/queued steer、`turn/interrupt`、dispatch barrier、immutable
  `OUTCOME_UNKNOWN`、read-only reconcile，最终以 Provider canonical observation 收敛。
- Interaction：manual approval/reject、AskUserQuestion、MCP elicitation、ExitPlan；exact
  Source/Thread/Turn/Interaction、authenticated actor、claim/lease；duplicate/expired/wrong source/wrong
  actor 必须零副作用。

### 1.2 本批只保留 seam、不实现完整内部合同/UI

- Goal、Plan、Settings、思考强度火焰滑块
- Side Chat、Fork、subagent
- auto approval / `approve_always`
- 完整文件互传、远程文件、Content 产品 UI
- 设备管理和多 route 产品 UI
- Git/worktree、Gallery、截图、录屏、导出、通知、后台、常驻会话
- plugin/connector 安装
- Claude：只保留 typed `NOT_IMPLEMENTED` seam

### 1.3 仍然有效的授权边界

- 允许：在精确隔离 worktree 内设计、实现、提交、运行 source tests；使用独立测试 DB/state；后续
  测试 Bridge 只能使用 `8766`；模拟器验证与候选构建属于本任务后续门禁。
- 禁止：修改 dirty main；整体 cherry-pick 旧完整 machine checkpoint；机械搬运 giant
  `websocket.ts`/`session.ts`/BridgeService/Cubit；接触生产 `8765`；读取/迁移产品 DB；merge、push、
  部署、发布、OTA、stable、替换生产 Bridge。
- 真机安装：候选构建完成后只向用户请求一次明确授权；当前 `NOT_AUTHORIZED / NOT_RUN`。
- 不保留 V2 Codex runtime fallback；不能为了旧合同/旧数据增加新分支。成熟 UI/连接/结构可保留，
  但 V2/Mirror/legacy 不能成为 V4 canonical writer。

## 2. 精确 Git 与目录身份

### 2.1 被交接的源码检查点（不含本文的 docs-only commit）

```text
worktree  /Users/developer/AI agent/Codex/_keep/projects/ccpocket-worktrees/ccpocket-codex-kernel-v4-implementation-20260830
branch    codex/codex-kernel-v4-implementation-20260830
HEAD      e32ed79c8301c9b6e59becc118541eb0986af847
tree      55343e8e08b9148afc82a824030e430952d548be
status    clean
start     abe0bc83956ec966d895daa393baf82848fb6cce
startTree 21ad12bd7c9ecd854f1b1b9171b17f8faba1cb73
```

最后两个根提交：

```text
45ccc633 fix(contract): preserve transaction recovery evidence
e32ed79c docs(v4): record tooling and identity followups
```

`45ccc633` 已通过现有 15 个 package tests，但后续对抗复审重新发现 4 个 P1；它只能作为失败事实/
可回退 checkpoint，不能当最终 K00 gate。

包含本文的最终 docs-only commit 不在文内自引用；接手时用 `git log -1 --oneline` 和
`git rev-parse HEAD^{tree}` 取得它，确认其相对 `e32ed79c` 只改本文与过程账本。

### 2.2 权威设计分支

```text
worktree /Users/developer/AI agent/Codex/_keep/projects/ccpocket-worktrees/ccpocket-codex-kernel-v4-local-design-20260830
branch   codex/codex-kernel-v4-local-design-20260830
HEAD     8a761580056ce91c37275dd0776c0bb5be11f70e
tree     331e144c867715580cd5a1f8b7469eef62e96c59
status   clean
```

已接受审核点原始身份：

```text
b100a212b9fc134d9adbea872914ea0a906b3dcb
tree c0fcf47dac5fed1aadc91d29ecfa1b747364aa1e
```

随后只按运行事实追加了：

```text
9e9ec10d docs(v4): bind Codex paged read facts
6ab9022b docs(v4): require bounded canonical staging
5f928d49 docs(v4): harden dispatch and storage authority
9f595ed8 docs(v4): compact staged timeline publication
e615860c docs(v4): define bounded message image ingress       [SUPERSEDED]
eb8d28fa docs(v4): use streaming image content plane
8a761580 docs(v4): stabilize partial timeline ordinals
```

`e615860c` 的 WebSocket image chunk 形态已被 `eb8d28fa` 取代；实现必须采用 WS
prepare/commit + 短期 authenticated HTTP PUT ticket，不能复活 chunk wire。

### 2.3 禁止整体提取的 donor

```text
old full machine checkpoint 2f8b984b4ce22c1a0a1b520c04e29085a4fd62d3
dirty main                 a706200233c55cc82d7a17e433f80f132d0f280d
```

它们只提供事实、成熟功能、结构和测试素材；禁止整体 cherry-pick 或复制 giant router/controller。

## 3. 根分支已集成内容与真实状态

| 领域 | 根提交 | 当前结论 | 处置 |
|---|---|---|---|
| ledger/baseline | `c3c5ba32`..`292f7587` | PASS（静态基线） | KEEP |
| contract generator 初版 | `0e12eeb6`,`a94a4b2a`,`a57df860` | fixture PASS | KEEP，仍需 JCS cross-language gate |
| K01 in-memory receive 初版 | `69f36b5a` | tests PASS 后复审重新打开多个 P1 | KEEP AS FAILED CHECKPOINT；由 K02 follow-up supersede |
| Codex fact probe | `ac1ddfd2` | exact read-only facts PASS | KEEP |
| active PVMC-1 authority 初版 | `82da06fc` | 已被 runtime-fact donor `3f59c433` 扩展 | KEEP + selective replay |
| Bridge Store 初版 | `9c1a87c7` | `FAIL P0=3/P1=5` | KEEP AS FAILED CHECKPOINT；绝不接 runtime |
| tooling hardening | `79294193`,`45ccc633` | 第二轮仍 `P0=0/P1=4/P2=2` | REWORK REQUIRED |
| Bridge/source identity | `663d62e4`,`ee836cd5` | 第二轮 `P1=1/P2=4`；修复 donor 已完成 | selective replay `3aef924d` 后重验 |
| design/ledger facts | `8d404935`..`e32ed79c` | append-only history | KEEP；失败记录不得覆盖 |

## 4. 尚未集成的精确 worker 产物

### 4.1 K00 runtime-fact Registry/Vectors — 候选可根审

```text
branch codex/v4-k00-runtime-fact-contract-worker
first  eb2b98b99b191c54c8f953676e0978e6daed09ec [已记录失败中间态]
final  3f59c4338795a0ea89f7e9e3db9dc9fe30aebd51
tree   2d99a211a7e984c5cd3807062a55a22936de8443
status clean
```

最终改动只涉及：

- `docs/design/codex-kernel-v4/contracts/contract-registry.json`
- `docs/design/codex-kernel-v4/contracts/vectors/phone-core-vectors.json`

候选最终统计：85 definitions、81 vectors、23 hard rules/tests、253 digest fields、7 image vectors。
覆盖：

- Provider turn 4 MiB 与 publication page 256 KiB 分层
- pageCount `0..128`、`totalItemCount` exact、typed empty proof
- page 唯一承载 items+gaps；commit 不重复 per-item/ref/gap arrays
- ProviderReadEvidence / exact Codex build / `THREAD_TURNS_LIST`
- signed older prepend：旧页 `-1`、既有页 `0`，无假 Gap
- OperationHeader 删除 client self-reported fingerprint；fingerprint 由 server 计算
- WS image prepare/commit + HTTP PUT ticket + PREPARED/COMMITTED ContentRef
- single image 10 MiB、每 turn 5 images

worker 自验 PASS：JSON parse、formal validate、4/4 contract tests、temporary generate、schema/manifest parse、
ref/digest/capacity/page-chain audit、`git diff --check`。

注意：`3f59c433` 的 parent 是 `eb2b98b9`。接手者必须根审 final diff 后决定按
`eb2b98b9 -> 3f59c433` 重放，或从当前 authority 到 final tree 做一笔可追溯 selective replay；不能只
cherry-pick follow-up 而遗漏 parent 内容。

正式四端 derived outputs 当前仍不存在，尚未运行 mapped generate。

### 4.2 K00 tooling transaction — 仍然 FAIL，禁止宣告 gate 通过

当前集成源码等价于 worker：

```text
worker final 23d4a13f0d031b73d3e81b92422afb3d7cf551a8
root replay  45ccc63347443ab5f932b5bb0837d39fdf5733dc
```

第二份只读复审：`P0=0 / P1=4 / P2=2`。

P1：

1. standalone `--out` 可经父级 symlink 写入词法目标外。
2. mapped target parent 在 preflight 后可被换为 symlink；rename/link 存在跨根 TOCTOU。
3. stage `new`/`backup` 子目录未绑定身份，可被 symlink replacement 污染或覆盖外部 victim。
4. 旧 target 本身为 symlink 时，rollback 用 hard-link 恢复会把 symlink 变成 regular hardlink，旧集
   没有恢复。

P2：

1. 只扫描 projectRoot/common ancestor 直接项，可能漏掉中间目录的 transaction residue。
2. lock cleanup 失败发生在 stage 删除后时，README 声称保留 lock/stage/backup 与真实行为不一致。

下一修复必须使用受绑定的目录句柄/每次 mutation 前 parent identity recheck，至少满足：

- standalone 路径中用户层 nested symlink fail closed，同时兼容 macOS `/var -> /private/var` 系统别名；
- stage/new/backup 记录 dev+ino 并在每次 write/rename/link 前后重验；
- symlink backup 使用 rename 语义恢复，不通过 `link(sourceSymlink, target)`；
- rollback/cleanup 发生歧义时不碰外部对象，并保留真实可恢复证据；
- 新增复审中的四个 exact repro tests 后再复审。

在该修复完成前，禁止对正式四目标运行 `conversation:contract:generate`。

### 4.3 K02 identity 修复 — 候选可根审

```text
branch codex/v4-k02-identity-worker
commit 3aef924d70cba85659cd7574a26839696c92b552
tree   c1d4caa47ae767562d33c4bc81df0292300a8fe3
status clean
```

只改 identity 6 个源码/测试文件。已关闭：

- `sourceEpoch` 不再持久化；每次 authenticated bind/replace 建新内存 fence，旧 epoch 失效。
- proof 外层 methods 必须与 signed canonical methods exact 相等。
- 同 stateDir 增加跨进程 lifecycle writer lease；close 后接管，PID/grace crash recovery。
- candidate/lock/tombstone/release/remove 后 parent directory fsync。
- release 前绑定 dev+ino+pid+token，同 pid/token replacement 不被旧 closure 删除。

worker Node 22 focused 34 tests、Bridge tsc、diff-check PASS；Bridge runtime/端口仍 NOT_RUN。

该 commit 的 parent 是 worker `b53f6074`，而根分支已有等价重放 `ee836cd5`。预计只 cherry-pick
`3aef924d`，但必须先比较 identity 子树，确认没有遗漏/重复，再复跑 34 focused + full Bridge + tsc。

### 4.4 K01/K02 Codex adapter — 最终 worker 候选可根审

```text
worktree /Users/developer/AI agent/Codex/_keep/projects/ccpocket-worktrees/ccpocket-v4-k02-codex-adapter-worker
branch   codex/v4-k02-codex-adapter-worker
base     d74895e2607b01b78d0781797c6922067cfc11e0
followup 7bc5ca1bcaefee09754d95710f8a9720a2f1b6b0
tree     eb92170a4ce16ee796a0b00be828c7ecbb32a018
status   clean
```

第一笔曾被根 authority review 重新打开；第二笔已经按根裁决完成：

```text
branch codex/v4-k02-codex-adapter-worker
commit d74895e2607b01b78d0781797c6922067cfc11e0
```

```text
d74895e2 feat(bridge): add paged Codex conversation adapter
7bc5ca1b fix(bridge): align Codex indexed history evidence
```

最终候选包含：

- notLoaded turn-index cache（20/page）+ on-demand full `limit=1`
- exact method/build/result/readSpec/evidence digest 与 RFC8785
- `(providerTurnId, providerItemId)` composite identity
- oversized/not-full typed Gap 的 bytes/evidence/relative placement/repair disposition
- signed ordinal、island 不跨 unloaded turn
- stale concurrent flight 不覆盖新 health、malformed DTO typed fail closed
- plain JSON/cycle/depth/byte guard、providerInstanceEpoch fence
- exact live promotion payload compatibility/no movement
- input/cache 100,000 entries / 64 MiB、single turn 4 MiB
- render window 200 不能冒充 input cap
- live 第 201 项不拒绝最新内容；保留最新 200 的 memory-only overlay、确定性淘汰最旧，返回
  `capacityEvicted` / `requiresCanonicalRepair`，不修改 canonical
- 256-thread bounded index LRU/release、malformed/stale flight/epoch/JSON clone/promotion guards

旧容量 repro 的最终语义：

- `maxPageSize=1 + 1001` 个小 items：若 turn <=4 MiB 且总预算内，正常接受；known=1001，render
  projection 只返回最新 200。
- 同 generation 300 个 live identities：300 observations 均接受，overlay 只保留最新 200；每次
  淘汰都有 repair evidence。
- 4 MiB+1 turn、100000+1 entries、64 MiB+1 footprint 均 typed reject/Gap，保留 last-good。

worker 最终 PASS：targeted 4 files / 80 tests、full Bridge 45 files / 1152 tests、Bridge tsc、
`git diff --check`；同一 reviewer 复看后剩余 `P0/P1/P2=0`。这些不是 composition/runtime PASS。

根分支尚未包含 `d74895e2`，恢复时必须按 `d74895e2 -> 7bc5ca1b` 顺序根审并重放；不能只
cherry-pick follow-up。

### 4.5 K03 Mobile ConversationRepository — 当前形态禁止集成

```text
branch    codex/v4-k03-mobile-repository-worker
base impl c3cdc2e7e5b3eeab3c123ba983ad6cd8aac2dbb7
followup  cf0ad5ec8fe3f122dcf22796bb7bd8d866521dd8
status    clean
```

原 worker tests 37/37、analyze、format、首份 reviewer 均 PASS，但 Sol xhigh 对抗复审结论：

`FAIL — P0=1 / P1=5 / P2=2`

P0：Repository 建了与 generated contract 不兼容的第二套 digest/evidence authority。

- page digest 只 hash `{items,gaps}`，没有按唯一 contract preimage 绑定 subject/page chain。
- Dart key-sort + `jsonEncode` 不是已证明的 RFC8785；同 body 与 JS/JCS digest 已实测不同。
- typed empty 只接受形式正确的任意 hex digest，不解析/验证 exact ProviderReadEvidence。
- 禁止用 Repository helper 自产 digest 再由同 helper自验；必须由 generated mapper + 共享
  TS/Dart canonical golden 提供唯一 preimage/digest，并在 staging 中重算。

P1：

1. 同 epoch complete `[a,b] rev1 -> [b] rev2` 被合并为 `[a,b]`，但 bounds/lastGood 更新为 rev2，
   形成假 canonical。
2. Runtime projection 没 durable inbox/monotonic projection head；exact retry重复 publish，旧 snapshot
   可删除 newer projection。
3. foreign schema 只比列名；移除全部 PK/UNIQUE/index 后仍 open PASS。
4. 64 MiB/100k 没覆盖 gaps、committed markers、retired epochs、staging、完整 projection 列与 readback；
   多表和 `NOT IN` 参数可无界。
5. public recursive JSON freeze/canonicalize 在 byte gate 前没有 cycle/depth/node guard，自引用 Map 触发
   `StackOverflowError`。

P2：

- 唯一 writer 只靠单实例 `_commitTail` 注释，没有 path lease/owner token。
- 3347 行文件同时承担 DDL、attestation、staging、digest、dominance、timeline/projection writer、
  capacity、readback、lifecycle，已经形成新的 giant controller。

下一版应保留 public facade/单一 owner，但用同一 Dart library 的 private `part` 模块拆分；修复上述
语义后再在根 `e32ed79c+` 上重放。当前两个提交都不要 cherry-pick。

### 4.6 K03 Bridge Store rework — 最终 worker 候选可根审

根分支中的 `9c1a87c7` 是明确失败 checkpoint，已知 `P0=3/P1=5`：

- `OUTCOME_UNKNOWN` 可被取消/拒绝抹掉
- queue ownership/root op/dispatch barrier 非原子，同 root 可有多 active entries
- timeline commit 信任调用方 `verified:true`
- client 自报 fingerprint/actor、假 writer、DDL/容量/claim lifecycle 等缺口

```text
worktree /Users/developer/AI agent/Codex/_keep/projects/ccpocket-worktrees/ccpocket-v4-k03-store-rework-worker
branch   codex/v4-k03-store-rework-worker
commit   c67e53855145c48928868bd93a479d56cec5e774
tree     78b6d956fd7f108d724f90a1db2c7cf8b4a64ef2
parent   64bc007c9e2c2178760e9a9260a3c2845cb7590e
status   clean
```

候选只改 Store/worker/dependency 12 files；没有改 contract、ledger、Mobile、router、Provider、端口。
独立 reviewer 最终 `LGTM / P0=0 / P1=0`。已关闭：

- immutable `OUTCOME_UNKNOWN` + append-only reconcile/block
- server JCS fingerprint、authenticated source/actor admission
- atomic queue root/control/FIFO dispatch barrier/recovery
- timeline staging/page/seal/head/read-time full receipt validation、last-good、typed empty、limits
- Interaction claim/response/resolution barrier
- DDL 对 JSON/bytes/state/event/queue lane-entry-root/claim coupling的约束
- canonical path + persistent writer lease + dedicated worker-only runtime guard/crash fail-all
- fixed Node 22 与 exact native dependency、官方 `registry.npmjs.org` lock

固定 Node `22.23.1` PASS：fresh `npm ci --ignore-scripts` 247 packages、explicit
`npm rebuild better-sqlite3`、ABI modules 127/N-API 10、focused 29/29、full Bridge 43 files/1124、
tsc、`npm run bridge:build`、compiled dist worker open/diagnostics（schema2/WAL/quick_check ok）、diff/hooks。

NOT_RUN：Windows/Linux native runtime、普通 `npm ci`（worktree hook 问题）、真实 Bridge/Provider/
产品 DB/端口/Mobile/device/release。剩余非阻塞 P2：userspace path TOCTOU；以及具备直接 DB 写权的
特权进程可在保持聚合约束时只推进 lane revision 做拒绝服务。业务生产入口禁止 direct Store，
test-only open 需 VITEST。

根分支已含原 Store + `64bc007c` 等价祖先，因此预计只需根审后 cherry-pick `c67e538`；如先修改
package-lock，冲突必须保留 Node `>=22 <23`、`better-sqlite3=12.10.0`、官方 npm URL 与 integrity。

### 4.7 本轮 Agent 收束状态

本接手点没有仍在运行或遗留 uncommitted work 的子 Agent；所有工作均已形成 clean commit 或
只读 review 结论：

| Agent 范围 | 最终状态 |
|---|---|
| K00 runtime-fact contract | clean commit `3f59c433` |
| K00 tooling follow-up review | read-only FAIL `P0=0/P1=4/P2=2` |
| K02 Codex adapter | clean sequence `d74895e2 -> 7bc5ca1b` |
| K02 identity fixes | clean commit `3aef924d` |
| K03 Mobile repository | clean candidate，但 adversarial review FAIL `P0=1/P1=5/P2=2` |
| K03 Bridge Store | clean commit `c67e538`，review `P0=0/P1=0` |

接手者不需要从 Agent mailbox 猜测未保存状态；以本表、精确 commit 和对应 worktree 为准。

## 5. 精确 Codex 运行事实

```text
binary  /Users/developer/.codex/packages/standalone/releases/0.151.0-aarch64-apple-darwin/bin/codex
version codex-cli 0.151.0
sha256  98491713ffb196061003ee148636e743997cc31d76144ba7c53462269896891d
```

- 代表性完整 `thread/read`：14,589,544 bytes、82 turns、6,594 items；重复结构/content hash 稳定，
  无 invalid/duplicate IDs。只作为 oracle，不是常规加载路径。
- `thread/turns/list` runtime 可用，opaque cursor：notLoaded 20 turns 约 3,717 bytes；full 2 turns
  分别约 2.54 MiB/531 items 与 2.81 MiB/728 items，重复稳定。
- `thread/items/list`、`thread/timeline/list` 虽出现在 generated Schema，但精确 build runtime 明确
  `not supported`；必须 advertise unavailable，不能以 full `thread/read` 假装 item paging。
- 常规读取固定：cached notLoaded index + full `limit=1` on demand。
- 单完整 turn 超过 4 MiB：保留 turn identity/relative placement，产生 typed
  `TURN_PAYLOAD_OVERSIZED` Gap，repair disposition 为
  `UNREPAIRABLE_WITH_CURRENT_PROVIDER_API`。
- `thread/read` 不回显 `clientUserMessageId`；`turn/start/steer` 接受它。dispatch 后丢 response 必须
  `OUTCOME_UNKNOWN`，只读对账，不准文本/时间 fuzzy match 或自动 resend。

## 6. 设计/代码接缝图

### 6.1 当前旧链热点（只能逐步退回 adapter）

- Provider RPC/live：`packages/bridge/src/codex-process.ts`
- Provider history normalization：`packages/bridge/src/sessions-index.ts`
- 旧 session/history/single queue：`packages/bridge/src/session.ts`
- wire/router/publication：`packages/bridge/src/websocket.ts`、`parser.ts`
- Mobile transport/runtime cache：`apps/mobile/lib/services/bridge_service.dart`、
  `session_runtime_store.dart`
- Mobile mapper/state/UI：`chat_message_handler.dart`、`chat_session_cubit.dart`、Codex screen/widgets

硬规则：

- `codex-process.ts` 继续是 RPC transport/adapter，不成为会话领域权威。
- `websocket.ts` 只逐步退回 transport/auth/typed dispatch；不能再塞领域状态。
- Mobile UI 只消费 ConversationRepository readback，不直接解析新 raw frame 或 SQL。
- canonical 只有一个 writer；live overlay memory-only；commit/readback 后才 visible。

### 6.2 已新增但尚未 composition 的根模块

- `packages/bridge/src/conversation-core/identity/`
- `packages/bridge/src/conversation-core/receive/`
- `packages/bridge/src/conversation-core/storage/`（当前是失败 checkpoint）
- `packages/conversation-contract/`

正式生成目标当前均 `MISSING`：

```text
docs/design/codex-kernel-v4/contracts/generated/schema.json
docs/design/codex-kernel-v4/contracts/generated/profile-manifest.json
packages/bridge/src/conversation-core/protocol/generated/contract.ts
apps/mobile/lib/conversation_core/protocol/generated/contract.dart
```

## 7. 已跑验证与未跑门禁

### 7.1 已确认 PASS

- 原始 Bridge baseline（Node 22.23.1）：41 files / 1072 tests；Bridge tsc PASS。
- 原始 Mobile baseline（Flutter 3.47.0 / Dart 3.13.0）：format 483 files / 0 changed；analyze exit 0，
  45 条既有 info；Flutter 1728 tests / 4 skips / PASS。
- 当前 tooling package：Node 15/15、fixture TS、Dart fixture、formal validate PASS；但安全复审 FAIL，
  不能提升 K00 状态。
- identity 根旧版：Node22 focused 27、full Bridge 46/1145、tsc PASS；之后复审重新打开，修复 donor
  34 focused PASS，尚未根集成。
- exact Codex static/runtime read facts：PASS（见第 5 节）。

### 7.2 明确 NOT_RUN / 未完成

| 门禁 | 状态 |
|---|---|
| final active contract mapped generate/check | `NOT_RUN` |
| generated TS/Dart cross-JCS/golden | `NOT_IMPLEMENTED / NOT_RUN` |
| final K01/K02 adapter integration/full tests | `NOT_RUN` |
| final Bridge Store Node22/worker/crash gate | `NOT_RUN` |
| final Mobile Repository root integration/full tests | `NOT_RUN` |
| actual Bridge/Mobile composition | `NOT_IMPLEMENTED` |
| durable send/queue/reconcile | `NOT_IMPLEMENTED` |
| manual Interaction full chain | `NOT_IMPLEMENTED` |
| isolated DB runtime | `NOT_RUN` |
| test Bridge `8766` | `NOT_RUN` |
| production `8765` | `FORBIDDEN / UNTOUCHED` |
| simulator/Marionette E2E | `NOT_RUN` |
| phone candidate build | `NOT_RUN` |
| phone install | `NOT_AUTHORIZED / NOT_RUN` |
| merge/push/deploy/release/OTA/stable | `NOT_AUTHORIZED / NOT_RUN` |

`npm ci` 正常路径仍会因上游 hook 把 worktree `.git` 文件误当目录而失败；
`npm ci --ignore-scripts` 只绕过 hook 安装，不能替代后续 build/test。当前 root lock 仍含初版 Store
引入的 `better-sqlite3@12.10.0` npmmirror URL，必须由 Store rework 改为官方 npm registry并重新验证
integrity/Node22 ABI。

磁盘在本接手点为约 `14 GiB` 可用；模拟器/候选构建前必须重测，未经授权不得清理用户数据。

## 8. 推荐恢复顺序（不得跳步）

1. 复核本文件所记 root HEAD/tree/status；若不同，先读新增 commit，不要机械 reset。
2. 根审 K02 adapter `d74895e2 -> 7bc5ca1b` 与 K03 Store `c67e538` 最终原子树；不要把 worker
   tests/reviewer PASS 直接等同集成 PASS。
3. 修 K00 tooling 的 4 个 P1 + 2 个 P2；复跑所有 exact exploit tests并独立复审。正式 generate
   必须等该 gate 关闭。
4. 根审并选择性重放 runtime-fact authority `eb2b98b9 -> 3f59c433` 的 final tree；运行 formal
   validate/temp generate/check，不运行正式目标。
5. 根审并重放 identity `3aef924d`；Node22 focused/full Bridge/tsc；追加 ledger。
6. 根审 K01/K02 final follow-up；特别验证 notLoaded/full limit1、4 MiB、100k/64MiB、composite
   identity、signed ordinals、live latest-200 eviction/repair、stale flight、epoch与payload conflict。
7. 只有 K00 tooling + Registry final 都通过后，运行一次正式
   `npm run conversation:contract:generate`，把四个 derived outputs 同一提交纳入；随后：
   - `conversation:contract:check`
   - generated TS strict / Bridge tsc
   - Dart 3.13 format/analyze/roundtrip
   - 新增 TS↔Dart RFC8785 canonical bytes/digest golden，不能只测对象 roundtrip
8. Store final 必须无 P0/P1 后才 supersede 根 `9c1a87c7`；固定 Node22 fresh install、official registry、
   focused/full/tsc/build/compiled-worker/kill-point。
9. Mobile Repository 必须先关闭第 4.5 节 P0/P1，并拆 private part modules；在当前根重放后再跑
   focused/full analyze/test。不要集成 `c3cdc2e7/cf0ad5ec` 当前形态。
10. 之后才做 composition、K04 send/queue/reconcile、K05 manual Interaction、Mobile UI repository 接线。
11. 最后使用独立 state/DB + `8766` 完成 simulator E2E 和 candidate build；逐项填写用户要求的
    12 条 PASS/FAIL/NOT_RUN。真机安装前只请求一次授权。

## 9. 必须持续写入的证据

每笔后续原子提交都要追加
`docs/design/codex-kernel-v4/PHONE-CORE-IMPLEMENTATION-LEDGER.md`，至少包含：

- branch、完整 HEAD/tree、dirty 状态
- donor commit、root replay commit、rollback commit
- 修改模块/行为变化
- test command、exit、数量、报告路径
- 独立 review P0/P1/P2 与修复 commit
- runtime/DB/8766/simulator/device/release 的独立 PASS/FAIL/NOT_RUN
- 被取代内容标记 `SUPERSEDED`，失败记录绝不覆盖

## 10. 最终完成门禁

只有以下 12 项在真实 Mobile + isolated Bridge/DB 上逐项有证据，才可标记
`PHONE_VERIFIABLE_MESSAGE_CORE_CANDIDATE`：

1. 长 Codex 会话正确显示。
2. 再次打开复用 cache，不重复 Provider read。
3. 上滑加载 earlier；不完整时 Gap 可见且已知顺序正确。
4. partial/empty/timeout/error 不清 last-good。
5. live 持续显示；canonical 到达后不重复、不换位。
6. 发送文字、图片、当前 structured refs。
7. busy 时 FIFO queue/edit/cancel。
8. active/queued steer + turn interrupt。
9. approval/question/MCP elicitation/ExitPlan 在手机完成。
10. 断线/Bridge restart 不丢 confirmed、不重复 send。
11. dispatch 后结果不明进入 immutable `OUTCOME_UNKNOWN`，只 reconcile、不 resend。
12. 退出再进入后 cache/order/send terminal 一致。

当前状态不是候选；不得以 Schema、单元测试或 worker reviewer PASS 代替 runtime/device 事实。
