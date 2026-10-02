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

## 已抽取模块的责任边界

| 责任 | 唯一位置 | 后续改动要同时检查 |
|---|---|---|
| 观察 committed cache、校验 focus/source/generation；保证进度观察先于后续 repair reply | SyncService 的 ordered timeline receiver / _observeAutomaticLatestTurnRepairFromCache | R03/R04/R08 |
| route 与 manual refresh 跨会话的焦点意图与旧状态清理 | SyncService._updateFocusedConversation | R05 |
| 自动修复状态、completed observation、dirty、operation token、retry/cancel | latest_turn_repair_scheduler.dart | R02/R04/R05/R15 |
| 同会话请求串行、焦点内 flight 复用 | SyncService.repairLatestTurn / _enqueueHistoryOperation | R05/R07 |
| older flight、准备/排队取消、pending、deadline、恰好一次结算与 join | older_turns_paging_lifecycle.dart | R17/R18/R20 |
| older 身份、请求参数、订阅重试、Repository 调用 | SyncService.loadOlderTurns / _loadOlderTurnsWithRetry / ordered receiver | R07/R08/R17 |
| 缓存事务与内容/coverage | Repository | R01/R06/R07/R11 |
| 事务后的 epoch/updates；已开始 older mutation 的事实按 cache partition 通知，旧 transport 仍 fence | SyncService 原通知出口 | R01/R09/R19/R21 |
| durable read ticket、dirty、owner 失效/退休 | durable_preview_read_lifecycle.dart | R23/R24/R27 |
| durable window 调用、source 当前性、epoch、last-good/Snackbar/Retry、Cubit 应用 | 原 Codex 页面 | R09/R23–R28 |
| 只读 History 解码与实际接受后提示确认 | handler.prepareHistory / commitPreparedHistory；原 live/handle 兼容 | R33/R34 |
| canonical 不可变准备、duplicate 判定、原输入 receipt 证据 | detached_timeline_projection.dart 的 candidate | R30–R32 |
| 整体 admission、当前 overlay 筛选、状态应用与 receipt/alias 消费 | 原 Cubit / candidate.compose | R26/R28/R30–R34 |
| runtime 完成、stream 关闭与实际 layout | 原 Bridge/Service/Cubit streaming handler / layout | R09/R29/R35；R35 焦点竞态待证明 |

调度器只接受不可变的身份/观察值和三个窄回调：判断当前操作、执行既有修复、重新观察缓存。
它没有数据库、Gateway 或页面对象。route 或 manual refresh 导致 focus 离开，与 thread reset 调用 clearTarget；
订阅开始/结束、断线、生命周期离开、source 更换与 dispose 经原订阅生命周期调用 clearAll。
不能只移走计时器代码却把旧状态留在 Service 中。

older lifecycle 不持有 Gateway、Repository 或页面。Service 把窄的 immutable request facts 提交给模块，
从模块找 active request，再走原 SQLite 路径；不能把每个分页各造一套数据库/全局恢复器。
thread reset 通过 failTarget 失效已登记请求及准备/排队 operation；停止订阅通过 failAll 结算
wire waiter。普通订阅替换仍允许原 wrapper 最多重试一次；dispose 从 flights snapshot 等待本地工作。
read barrier 若尚未释放，这个 join 会等待它结束，不能通过提前关 DB 假装取消完成。

older prepend API 包含 transaction 与提交后的 snapshot read；异常阶段不明确时保留原错误，
在 cache partition 仍当前且未 dispose 时复用 invalidation 通知观察者重读。
success 同样按 cache partition 通知；transport timeline 与 ACK 仍按订阅代次。
修改任一检查时必须同时跑 R21 的 success/error、same-source/other-source/dispose 六种交错。

durable reader 的 begin 只在真正开始下一次读取时消费 dirty；finish 只退休自己的 ticket，
source conflict 阻止 follow-up 时保持 `needsRead`，直到读取开始或显式 invalidate。
success/error 共用 owner、source/thread、原 epoch 和 dirty 判定；旧 finally 不得清理新 owner。
原 start/restart、canonicalization、didUpdateWidget、session_created/attachment 与 dispose
全部接到同一生命周期。被动 runtime 绑定仍保留 canonical reader，不能一律按 attachment 失效。
helper 不接收 Page/Cubit/Service/Repository 对象；当前窗口和 UI 状态留在原页面。

canonical candidate 只拥有不可变准备结果，不持有 Cubit/handler/Service。
拒绝必须先于分页及整个 `_applyUpdate`；合法路径应用后才确认历史提示。
overlay 按应用时的原 runtime/source 身份筛选，不能在 prepare 阶段提前缓存旧 overlays。
receipt/alias 证据来自原 canonical，compose enrichment 不能制造提交凭据。
同一共享 handler 与 streaming/thinking 对象继续使用，不能为消除拒绝副作用替换整个 handler。

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
"$CCPOCKET_FLUTTER_BIN" test --no-pub --reporter expanded --concurrency=1 \
  test/features/conversation_content_sync/latest_turn_repair_scheduler_test.dart \
  test/features/conversation_content_sync/older_turns_paging_lifecycle_test.dart \
  test/features/conversation_content_sync/conversation_content_sync_service_test.dart \
  test/features/session_list/cache/session_catalog_cache_repository_test.dart \
  test/models/conversation_sync_v2_protocol_test.dart
"$CCPOCKET_FLUTTER_BIN" test --no-pub --reporter expanded --concurrency=1 \
  test/codex_durable_preview_read_test.dart \
  test/durable_session_preview_test.dart \
  test/features/conversation_content_sync/durable_preview_read_lifecycle_test.dart
"$CCPOCKET_FLUTTER_BIN" test --no-pub --reporter expanded --concurrency=1 \
  test/detached_canonical_commit_test.dart \
  test/detached_canonical_history_candidate_test.dart \
  test/chat_message_handler_test.dart \
  test/chat_session_local_history_paging_test.dart \
  test/detached_timeline_projection_test.dart \
  test/chat_session_cubit_test.dart \
  test/chat_process_layout_test.dart
"$CCPOCKET_FLUTTER_BIN" test --no-pub --reporter expanded --concurrency=1 \
  test/blackbox/conversation_latest_turn_gap_receiver_test.dart \
  test/blackbox/conversation_live_segment_receiver_test.dart \
  test/blackbox/conversation_full_page_test.dart
"$CCPOCKET_DART_BIN" analyze .
"$CCPOCKET_FLUTTER_BIN" test --no-pub --reporter expanded --concurrency=1
```

回到仓库根目录执行 Bridge 门禁：

```bash
cd ../..
npm run test:bridge
"$CCPOCKET_NODE" node_modules/typescript/bin/tsc --noEmit -p packages/bridge/tsconfig.json
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
以上并发度对应 C1a/C1b 的最终本地收据；默认并发与云 CI 未在本轮验收。
早期并发 full-page 折叠等待 FAIL 的输入/投影/宿主时序仍待归属，不能因串行 PASS 删除该记录。
另有 C1b 两次 commentary B 可见性 FAIL，见 R35；d0f164e5 的观测输入全量 PASS 不关闭该问题。
页面失败快照含 SQL、Cubit、renderedText/disclosure，跨 await 的快照不是原子快照。
runtime-overlay-origin 在 Provider 发射回调采样，早于生产 sessionMessage，不代替其实际判定事实。
当前重放与下一步定位见 RUNTIME-ITEM-BOUNDARY；独立保留两次失败与焦点差异对照。

## 回退与后续批次

先确认工作树及他人改动，按 PROCESS 中的独立提交选择 revert；不要把 checkpoint reset 到共享分支。
行为修复、测试夹具、结构抽取分别有提交，能单独审阅。保留暴露错误的测试和原始日志。

分批提交不意味着可以任意顺序 revert：E009 的 scheduler 清理依赖 B1 抽取，
后续行为批也依赖 E004/E005 的进度与 flight 归属。评估结构回退时先逆序撤掉依赖，
或在隔离 checkout 适配行为修复，再运行完整矩阵。不要直接将中间红灯 checkpoint 当可用候选。
E010 登记的 `45a4498a` 是第一批最终绿灯源码点，B2 最终产品源码为 `f735ac6b`，C1a 为 `151c0475`；
精确提交与测试样式后续检查见 PROCESS。本轮从未部署，撤销源码不需要替换生产运行。

B2 的 E017/E020 行为提交依赖 E015 的生命周期/DTO 抽取；回退结构时先在隔离 checkout
处理后续行为依赖，并恢复 Service export 与所有 pending/deadline/flight/dispose 接点。
E013 的局部失败/游标保护、E017 的 preparing/queued 取消、E020 的分区通知不能顺手丢弃。
E012/E016/E019 是红灯 checkpoint，E015/E018 也有后来发现的残余边界，不能直接作为运行候选。
优先审阅单个提交；实际 revert 按依赖逆序，保留回归用例并运行完整矩阵。

C1a 的 E028 deferred read 行为依赖 E026 lifecycle 接口；直接 revert E026 会破坏后续调用。
先在隔离 checkout 适配并保留 E024 来源错误检查和 E028 deferred read，再选择结构回退方案。
E023/E027 是红灯 checkpoint，E026 仍有后来定位的 source-return 缺口，不能作运行候选。
十三个真实 SQL 页面与八个纯生命周期契约须保留并通过，原 Service/SQL/Cubit 权威不能改变。

C1b 产品冻结 2f64e383、最终测试/fixture 输入 d0f164e5；全量与独立复核见 E037。
回退 candidate 结构须适配后续 Cubit 接口，并保留 E032 admission 与 E035 提示确认的行为修复；
E031/E034 红灯 checkpoint 不能作为运行候选。十五项新保护与原 SQL/页面用例均须保留。
E036 只有测试观测，不是 R35 修复，撤掉它也不能删除原断言或改变 15 秒期限。
下一步按 [RUNTIME-ITEM-BOUNDARY](RUNTIME-ITEM-BOUNDARY.md) 证明 pending subscription 的焦点变化：
subscribe 已发送但 syncBegin 未接受时改变焦点，确认当前焦点是否实际补发。
既有其他分页/控制路径的相似交错仍待各自证明，不从 older 两个出口的修正推断它们已经正确。
不扩大到 Cubit 全面重写、Bridge 总路由重写或 V4 候选整合。

真实 Provider、模拟器、真机、生产 Bridge、OTA 和安装/发布状态单独记在矩阵中。
本轮检查不会自动授权部署、merge、push 或发布。
