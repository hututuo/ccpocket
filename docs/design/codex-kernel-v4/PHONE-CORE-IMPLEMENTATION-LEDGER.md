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
| K00 active contract/tooling | `NOT_STARTED` |  | implementation start |  |
| K01 memory receive | `NOT_STARTED` |  |  |  |
| K02 isolated Codex read | `NOT_STARTED` |  |  |  |
| K03 durable receive/repository | `NOT_STARTED` |  |  |  |
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

## 5. 独立交付状态

| Gate | 状态 |
|---|---|
| source implementation | `IN_PROGRESS` |
| Bridge build/tests | `NOT_RUN` |
| Mobile analyze/tests | `NOT_RUN` |
| isolated DB/crash tests | `NOT_RUN` |
| Codex isolated facts | `NOT_RUN` |
| test Bridge 8766 | `NOT_RUN` |
| simulator E2E | `NOT_RUN` |
| phone candidate build | `NOT_RUN` |
| phone install | `NOT_AUTHORIZED / NOT_RUN` |
| merge/push/deploy/release/OTA/stable | `NOT_AUTHORIZED / NOT_RUN` |
