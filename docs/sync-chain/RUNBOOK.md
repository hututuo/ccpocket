# 接手、修改与验证操作说明

本轮工作目录：`/Users/developer/.codex/worktrees/sync-chain-20261001/ccpocket-compat`。
分支：`codex/sync-chain-extraction-20261001`。先读 PROCESS 当前断点与最新条目，
核对 HEAD/status；main、旧修复 checkout 或旧设备不能替代此处的验证身份。

## 修改前与修改后

1. 在 PROCESS 登记批次：父 SHA、待解决行为、所属路径、允许改的文件、正确结果与测试行。
2. 行为修复先证明失败；结构迁移先冻结正确行为。两者分开提交。
3. 修改身份、coverage、游标或通知时，同时检查 CHAIN-MAP 与 TEST-MATRIX；
   loaded、ACK、canonical revision、commit epoch 与 complete 各自表示不同事实。
4. 只运行受影响的检查开始定位，再跑本批完成门禁。失败原日志保留，记录修正后新运行的身份。
5. 最终根审与独立 self-review 后，更新当前断点、尚未验证项、下批入口，再提交。

## 第一块抽取的责任边界

| 责任 | 唯一位置 | 后续改动要同时检查 |
|---|---|---|
| 观察 committed cache、校验 focus/source/generation；保证进度观察先于后续 repair reply | SyncService 的 ordered timeline receiver / _observeAutomaticLatestTurnRepairFromCache | R03/R04/R08 |
| route 与 manual refresh 跨会话的焦点意图与旧状态清理 | SyncService._updateFocusedConversation | R05 |
| 自动修复状态、completed observation、dirty、operation token、retry/cancel | latest_turn_repair_scheduler.dart | R02/R04/R05/R15 |
| 同会话请求串行、焦点内 flight 复用 | SyncService.repairLatestTurn / _enqueueHistoryOperation | R05/R07 |
| 缓存事务与内容/coverage | Repository | R01/R06/R07/R11 |
| 事务后的 epoch/updates | SyncService 原通知出口 | R01/R09 |
| durable window 重新读取与展示 | 原 Codex 页面/Cubit/layout | R09 |

调度器只接受不可变的身份/观察值和三个窄回调：判断当前操作、执行既有修复、重新观察缓存。
它没有数据库、Gateway 或页面对象。route 或 manual refresh 导致 focus 离开，与 thread reset 调用 clearTarget；
订阅开始/结束、断线、生命周期离开、source 更换与 dispose 经原订阅生命周期调用 clearAll。
不能只移走计时器代码却把旧状态留在 Service 中。

接收排序中的 await 只等本地缓存观察进入 scheduler，不等待 repair 网络回复。
不要把它恢复成纯后台观察，否则较晚 repair completion 可能抢先记完成值，吞掉较早的 dirty 进度。
也不要等待完整 repair future，否则该 future 可能反过来等待同一接收队列的回复。
新增的可控读延迟回归与全量 tests 共同约束这个顺序；改变 await 后须检查当前性 fence。

失败预算仍按原 revision/turn/repair operation key 生效：最多 4 次失败，重试等待 1/2/4 秒。
预算耗尽后不会仅因 frame/时间变化重新请求；新 revision 或取消该目标/订阅后可重新调度。
本批结构迁移没有改变预算重置策略；调整策略须另起行为批，补失败/进度/请求风暴回归。

## 可复现的检查命令

本轮使用缓存中的 Flutter 3.44.7 / Dart 3.12.2，framework revision
`309dd6573a9fe716410489284cd325a34b950375`。下列路径仅表示本机本轮工具身份，
不要求后续机器安装到同一目录；先核对工具版本，不修改全局 Flutter 选择。

```bash
cd "/Users/developer/.codex/worktrees/sync-chain-20261001/ccpocket-compat"
git rev-parse HEAD
git status --short
CCPOCKET_FLUTTER_BIN="/Users/developer/.shorebird/bin/cache/flutter/309dd6573a9fe716410489284cd325a34b950375/bin/flutter"
CCPOCKET_DART_BIN="/Users/developer/.shorebird/bin/cache/flutter/309dd6573a9fe716410489284cd325a34b950375/bin/cache/dart-sdk/bin/dart"
"$CCPOCKET_FLUTTER_BIN" --version
export CCPOCKET_NODE="/Users/developer/.local/share/mise/installs/node/22.23.1/bin/node"
"$CCPOCKET_NODE" --version
```

依赖首次准备限当前 checkout。初次离线准备没有改变锁文件。
B1 显式声明已存在的 fake_async 测试依赖，pubspec.lock 只将其分类改为 direct dev；版本与 hash 不变。
`npm ci --ignore-scripts` 避免 prepare 修改共享 Git hooks；真实 Bridge build 仍须运行。
CCPOCKET_NODE 指定本轮真实 Bridge 根进程的 Node 22.23.1；fixture 的 env-node 子进程仍取宿主 PATH，
本机这部分使用 Node 26.4.0。精确复核时记录两者，不能当作整个工具链已在 Linux Node 22 验收。

```bash
npm ci --offline --ignore-scripts
npm run bridge:build
cd apps/mobile
"$CCPOCKET_FLUTTER_BIN" pub get --offline
"$CCPOCKET_FLUTTER_BIN" test --no-pub --reporter expanded \
  test/features/conversation_content_sync/latest_turn_repair_scheduler_test.dart \
  test/features/conversation_content_sync/conversation_content_sync_service_test.dart \
  test/features/session_list/cache/session_catalog_cache_repository_test.dart \
  test/models/conversation_sync_v2_protocol_test.dart
"$CCPOCKET_FLUTTER_BIN" test --no-pub --reporter expanded \
  test/blackbox/conversation_latest_turn_gap_receiver_test.dart \
  test/blackbox/conversation_full_page_test.dart
"$CCPOCKET_DART_BIN" analyze .
"$CCPOCKET_FLUTTER_BIN" test --no-pub --reporter expanded
```

回到仓库根目录执行 Bridge 门禁：

```bash
cd ../..
npm run test:bridge
node node_modules/typescript/bin/tsc --noEmit -p packages/bridge/tsconfig.json
git diff --check
```

本轮原始输出：`/Users/developer/AI agent/Codex/_tmp/ccpocket-sync-chain-20261001/`。
每次检查的 JSON 收据含命令、cwd、HEAD、未提交 diff hash、状态、UTC 时间和退出码，旁边保留日志。
新文件必须纳入 diff 身份或另算文件 hash。不要重复使用同一日志名称覆盖失败。
普通 PR CI 的 Mobile job 在全量 Flutter tests 前准备 Node/依赖并构建 Bridge；
不同 CI job 的工作目录互不共享，不能依赖独立 Bridge job 生成的 dist。
调整其他平台发布工作流时，也须确认其黑盒测试前置条件，不能把缺少 dist 改成静默跳过。
黑盒 trace 含隔离 fixture 的原始 RPC、Bridge/client 帧、SQLite 条目 hash 与页面断言；
可设置 CCPOCKET_CHAIN_TRACE_PARENT 将下次 fixture trace 留在持久证据目录。

## 回退与后续批次

先确认工作树及他人改动，按 PROCESS 中的独立提交选择 revert；不要把 checkpoint reset 到共享分支。
行为修复、测试夹具、结构抽取分别有提交，能单独审阅。保留暴露错误的测试和原始日志。

分批提交不意味着可以任意顺序 revert：E009 的 scheduler 清理依赖 B1 抽取，
后续行为批也依赖 E004/E005 的进度与 flight 归属。评估结构回退时先逆序撤掉依赖，
或在隔离 checkout 适配行为修复，再运行完整矩阵。不要直接将中间红灯 checkpoint 当可用候选。
E010 登记的 `45a4498a` 是本批最终绿灯源码点；本轮从未部署，撤销源码不需要替换生产运行。

下一块是 B2 单种历史分页生命周期：先列请求身份、ready/deadline、accepted/interrupted/failed
终态、cursor、reset/dispose 和过期回复；先补其缺失的闭环，再移动完整状态。
在这一块成立前，不扩大到 Cubit 全面拆分、Bridge 总路由重写或 V4 候选整合。

真实 Provider、模拟器、真机、生产 Bridge、OTA 和安装/发布状态单独记在矩阵中。
本轮检查不会自动授权部署、merge、push 或发布。
