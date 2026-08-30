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
| K00 active contract/tooling | `IN_PROGRESS` | worker branch pending integration | `f6158753` | active-profile generator/validator implementation underway |
| K01 memory receive | `IN_PROGRESS` | worker branch pending integration | `f6158753` | pure receive/cache/order/gap/live implementation underway |
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
