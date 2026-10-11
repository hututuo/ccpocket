# 接手、修改与验证操作说明

当前续接工作目录：`/workspace/ccpocket-sync-chain-followup`。
分支：`codex/continue-sync-chain-extraction-20261011`；此前本机路径/分支是历史执行身份。先读 PROCESS 当前断点与最新条目，
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
| subscribe 实际发送快照、匹配接受补发及失效清理 | SyncService._rememberSubscriptionFocusAtSend / _reconcileSubscriptionFocus / 原发送出口 | R35/R36；十七项与 held 原页面 red/green |
| runtime status attachment 身份生产、失效转换与持久 JSON | 原 Bridge statusFromRuntime / Dart protocol / Repository status JSON | R41/R42；不能把runtime ID当authority |
| stream 接受revision、socket终态ticket与新视觉清理 | StreamingStateCubit / 原 Cubit status 接点 | R37–R42/R46；旧mutation lease另看R48 |
| quarantine map/bytes、FIFO快照、容量拒绝、remove/clear | runtime_overlay_quarantine.dart | R43/R44；admission/apply/accepted IDs仍在原Cubit，R47策略未审定 |
| 拒绝已知不同runtime的status，不替换合法当前权限 | 原Cubit.updateDetachedProviderStatus，source/provider/thread后、时间/签名前 | R48；26项公开权限保护；缺字段旧组合R49另证 |
| status观察时间/签名/local receipt、比较及统一clear | detached_status_observation.dart | R55/R57；Cubit仍核对资格/lease/queue，suspend保留观察 |
| runtime 完成、stream 关闭与实际 layout | 原 Bridge/Service/Cubit streaming handler / layout | R09/R29/R35/R37；历史R29归因仍未知 |

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

订阅焦点快照绑定实际发送的 request/generation/target/Bridge/source/协议，只有当前接受可以消费。
syncBegin/subscribed 在首次 await 前核对当前意图，相同不发、不同用原 focus 消息（含 null）。
失效与错误都经原出口退休，补发失败不能继续 bootstrap/notify/ACK；旧接受不能清理新快照。
全部接点与回退保护见 RUNTIME-ITEM-BOUNDARY，不能将该状态塞进 canonical candidate 或页面 reader。

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
  test/features/conversation_content_sync/subscription_focus_admission_test.dart \
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
  test/detached_terminal_streaming_test.dart \
  test/detached_runtime_overlay_queue_test.dart \
  test/detached_runtime_authority_test.dart \
  test/models/conversation_sync_v2_protocol_test.dart \
  test/features/session_list/cache/session_catalog_cache_repository_test.dart
"$CCPOCKET_FLUTTER_BIN" test --no-pub --reporter expanded --concurrency=1 \
  test/blackbox/conversation_latest_turn_gap_receiver_test.dart \
  test/blackbox/conversation_live_segment_receiver_test.dart \
  test/blackbox/conversation_authority_pending_receiver_test.dart \
  test/blackbox/conversation_full_page_test.dart
"$CCPOCKET_DART_BIN" analyze .
"$CCPOCKET_FLUTTER_BIN" test --no-pub --reporter expanded --concurrency=1
```

回到仓库根目录执行 Bridge 门禁：

```bash
cd ../..
cd packages/bridge
"$CCPOCKET_NODE" node_modules/vitest/vitest.mjs run
cd ../..
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
Vitest 位于 packages/bridge/node_modules，TypeScript hoisted 到根 node_modules；不要混用 cwd。
以上并发度对应 C1a–C1d 的最终本地全量收据；完整默认并发与云 CI 未在本轮验收。
R29 原四文件组合在当前 clean adf337ea 默认并发 50 PASS，仅证明这次有限重放。
早期并发 full-page 折叠等待 FAIL 的输入/投影/宿主时序仍待归属，不能因串行 PASS 删除该记录。
另有 C1b 两次 commentary B 可见性 FAIL，见 R35；经确定性交错旧 Service red / 修复 green 关闭选定窗口，
原 FAIL 仍保留。C1b 的产品 ce51e280 / 测试输入 adf337ea 门禁见 E041。
最新 C1c/C1d 完整产品/测试输入为 da3d3f6：3370 PASS / 4 SKIPPED、Bridge 2546 PASS / 1 SKIPPED，
原七黑盒及固定 SHA 独立复核通过（E059）。Bridge build 由 E053 相同 tree 继承；noEmit 是实际重跑。
2f95d6d0 仅测试写法复查，40 项及完整 analyze/format 通过，1017 info 完整文本比对无新增（E060）。
产品、依赖和黑盒 tree 未变化；保留完整 SHA 与样式 SHA 的区别，不虚构第二次全量。
最新C1e完整输入16196f05：3396 PASS / 4 SKIPPED、固定SHA review通过；Bridge tree不变继承E059。
8178295d仅删unused test import，26项与完整analyze/format另查，0 error/warning、1017既有info逐项无新增。
完整收据与警告FAIL保留见E064/E065；精确hash及继承/NOT_RUN/BLOCKED见ACCEPTANCE.json。
C1f固定84493fc6只新增测试与账本：71项组合PASS（8条接收链、3条真实子进程合同、60条公共保护），
目标文件analyze无诊断、format无变化、固定SHA只读复核无新增P0–P2；未重跑完整Mobile/Bridge。
新用例仅延迟原statusUpdater挂载，SQL原status/timeline提交和Provider init分别有因果屏障。
敏感性实验按预期FAIL（pending应1实际0），产品hash finally恢复且Git clean；恢复后新文件4项PASS。
READY超时与非法/缺字段red、fixture启动67/1候选FAIL及各候选green保留在E066–E073。
新的精确补充门禁、原七黑盒/共享helper blob未变证明与review见ACCEPTANCE.json的supplementalC1f。

C1f的同输入71项复跑（在apps/mobile目录、先按上文构建真实Bridge）：

```bash
"$CCPOCKET_FLUTTER_BIN" test --no-pub --reporter expanded --concurrency=1 \
  test/blackbox/conversation_authority_pending_receiver_test.dart \
  test/blackbox/conversation_live_segment_receiver_test.dart \
  test/blackbox/conversation_latest_turn_gap_receiver_test.dart \
  test/blackbox/conversation_full_page_test.dart \
  test/detached_runtime_overlay_queue_test.dart \
  test/detached_runtime_authority_test.dart \
  test/detached_terminal_streaming_test.dart
"$CCPOCKET_DART_BIN" analyze test/blackbox/conversation_authority_pending_receiver_test.dart
"$CCPOCKET_DART_BIN" format --output=none --set-exit-if-changed \
  test/blackbox/conversation_authority_pending_receiver_test.dart
```

页面失败快照含 SQL、Cubit、renderedText/disclosure，跨 await 的快照不是原子快照。
runtime-overlay-origin 在 Provider 发射回调采样，早于生产 sessionMessage，不代替其实际判定事实。
焦点责任与重放见 RUNTIME-ITEM-BOUNDARY；旧折叠等待的下一步见 R29-FOLD-ENTRY。
独立保留两次失败、焦点差异、Service swap 恢复及最终 clean 门禁。

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

C1b 最终产品冻结 ce51e280、完整测试/fixture 输入 adf337ea；全量与独立复核见 E041。
2f64e383/d0f164e5 的 E037 是此前 canonical/观测输入门禁，不覆盖后来的焦点修改。
回退 candidate 结构须适配后续 Cubit 接口，并保留 E032 admission 与 E035 提示确认的行为修复；
E031/E034 红灯 checkpoint 不能作为运行候选。十五项新保护与原 SQL/页面用例均须保留。
E036 只有测试观测，不是 R35 修复，撤掉它也不能删除原断言或改变 15 秒期限。
E039 焦点行为只在 Service，E040 的 held FIFO 闸门只在测试 fixture。
回退行为保留十七项保护与 held-page red；回退 fixture 不移除原五个黑盒/断言或改变期限。
旧 Service 的单文件换回只用于隔离敏感性验证，已在 finally 恢复并核对 hash，不能部署红灯版本。
C1c/C1d 的身份 red ac4d72fc → 修复 1ee38207，future-turn red 4b59aee7 → 修复 c3fcab96，
未知activity red ad94066c → 修复 16529517，与结构抽取 da3d3f6 分开审阅。
回退 da3d3f6 须迁回完整 map/bytes/add/remove/clear，并保留此前行为保护和原 reset/flush/close 出口。
若撤销可选 runtime status 身份，也要处理依赖它的新清理条件；不能保留不成立的验收声明。
authority 清理反向测试仅覆盖已有 visible owner，queue-only waiting 仍按 R47 单独取证。
C1e已按26项public输入窄修已知remote runtime矛盾；产品16196f05与测试import8178295d分开审阅。
回退产品保留旧B拒绝、合法C owner/image lease、unbound只读与旧组合/durable target断言；不把red checkpoint运行。
无字段旧组合完整归属仍R49。C1f的R50正向等待与C1g的Bridge同ID/catalog capacity/ACK组合R52分别取证；
Mobile已收到旧A/未观察新B及完整R47仍按QUEUE-AUTHORITY-ENTRY单独证明。
C1f变更限新conversation_authority_pending_receiver_test.dart与文档，原共享helper/七黑盒不依赖它，产品无需回退。
测试改动由32a8978d、8f671f4f、0cc0c0a9、3eef3b15、84493fc6及各red checkpoint分段记录，先审阅E066–E073。
回退测试设施不能删除已定位的失败合同或更改业务期限以取得PASS；可在隔离checkout适配owned清理与因果屏障。
后续same-ID replacement须保留真实SessionManager callback、capacity/ACK及新旧authority，不能复用R50宣称整段已验收。
[R29-FOLD-ENTRY](R29-FOLD-ENTRY.md) 继续登记旧观察：没有输入/接受/渲染的因果证据便留未知。
visual pending 的 256/257 策略未审定，不因 quarantine 完成就一起抽取。
既有其他分页/控制路径的相似交错仍待各自证明，不从 older 两个出口的修正推断它们已经正确。
不扩大到 Cubit 全面重写、Bridge 总路由重写或 V4 候选整合。

真实 Provider、模拟器、真机、生产 Bridge、OTA 和安装/发布状态单独记在矩阵中。
本轮检查不会自动授权部署、merge、push 或发布。

## C1g的同输入Bridge复跑、证据与回退

固定输入911a4f60新增conversation-authority-replacement-harness.mjs与conversation-authority-replacement.test.ts。
既有tsx在本测试自建child加载实际TS源码，无须替换dist。Provider仍是隔离stdio JSON-RPC fixture，
10,000条synthetic catalog只构建原capacity，不改原64KiB frame、1MiB outstanding及2MiB sync预算。
内部map/budget只读诊断；真实replaceCodexSession/public ACK负责修改，不调用私有send/drop或靠close恢复。

在packages/bridge目录，使用前文CCPOCKET_NODE_BIN对应的Node22路径（本机可显式赋给CCPOCKET_NODE）：

```bash
export CCPOCKET_NODE="/Users/developer/.local/share/mise/installs/node/22.23.1/bin/node"
"$CCPOCKET_NODE" node_modules/vitest/vitest.mjs run src/local-features/conversation-authority-replacement.test.ts
"$CCPOCKET_NODE" node_modules/vitest/vitest.mjs run
```

根目录的静态检查：

```bash
"$CCPOCKET_NODE" node_modules/typescript/bin/tsc --noEmit -p packages/bridge/tsconfig.json
"$CCPOCKET_NODE" --check packages/bridge/scripts/conversation-authority-replacement-harness.mjs
```

最终原input的完整重放2547 PASS / 1 SKIPPED（18.505秒）、noEmit（5.530秒）、语法（0.127秒）及只读review通过。
第一次完整2546/1/1FAIL是原catalog watcher的5秒timeout（R53）；目标9项（1.538秒）和完整重放绿不能解释该旧FAIL。
错误保留旧A策略实验FAIL（1.274秒，pending应0实际1）；finally恢复原source SHA256且clean后才运行最终完整门禁。
public ACK格式错误的首fixture FAIL亦保留；不能把它记作产品authority缺陷。
精确输入/dirty diff、receipt/log hash、五份raw trace和293个既有Bridge文件blob证明见supplementalC1g。

Mobile source/test/依赖对象与84493fc6相同，继承71项；完整3396/4仍归16196f05，没有新Mobile全量。
Bridge整个tree因新增文件改变，因此本次全Bridge实际重跑；原生产文件/依赖相同，build只继承对应原build。
回退仅新测试/harness与相关文档：19b2939f初始合同、1d430fe2合法ACK、911a4f60关闭前直接pending断言分别有checkpoint。
不删除已经定位的敏感性合同、不用放宽期限掩盖FAIL；现有生产路径没有本批产品改动可回退。
C1h接Mobile/SQL/原页面同ID替换，B刚替换尚无新notification与B真正新item分别取证；仍不是部署/发布授权。

## C1h复跑、改动位置与回退

当前接受输入4e6d3d4a；原本3396/4仍是16196f05历史收据，本批完整3412/4是实际新运行。
使用前文CCPOCKET_FLUTTER_BIN/CCPOCKET_DART_BIN和CCPOCKET_NODE，在apps/mobile执行：

```bash
"$CCPOCKET_FLUTTER_BIN" test --no-pub --reporter expanded --concurrency=1 \
  test/blackbox/conversation_authority_replacement_receiver_test.dart \
  test/detached_runtime_status_commit_order_test.dart \
  test/blackbox/conversation_authority_pending_receiver_test.dart \
  test/blackbox/conversation_live_segment_receiver_test.dart \
  test/blackbox/conversation_latest_turn_gap_receiver_test.dart \
  test/blackbox/conversation_full_page_test.dart \
  test/detached_runtime_overlay_queue_test.dart \
  test/detached_runtime_authority_test.dart \
  test/detached_terminal_streaming_test.dart
"$CCPOCKET_FLUTTER_BIN" test --no-pub --reporter expanded --concurrency=1
"$CCPOCKET_DART_BIN" analyze .
```

定向83项（10实际链、3owned清理、70public）；完整3412 PASS/4 SKIP；分析0 error/warning、1017既有info文本/重复数量不变。
实际harness使用自建Node22 --import tsx加载原TS，隔离HOME/Provider/端口/SQL，仅延迟原Updater观察，不改wire顺序或运行Bridge。
新harness语法7028b503实际PASS且blob此后相同。Bridge原295个文件未变，全量2547/1仍属911a4f60；原build/typecheck分别继承精确原输入。
真实equal red b493e9ea→完整equal green4e6d3d4a；公开7/3 red8c5002a9→83/全量green。所有收据/log/hash及28份trace见supplementalC1h。

| 改动 | owning path/提交 | 回退时必须保留 |
|---|---|---|
| 新actual same-ID receiver/harness、正确commit屏障 | 7028b503 / b493e9ea；两新文件 | 不等待原实现不会公开的第二init；actual map/process/UUID和SQL/SessionList B屏障独立；合法新B/canonical仍断言 |
| immutable本地receipt与十项red | protocol_slot / 8c5002a9；新增public test | fromJson不读/toJson不写、缓存自然无票；新consumer API依赖不得留下编译断裂 |
| 完整SQL commit后附顺序、Cubit消费/去旧票 | 原Service/Cubit / 4e6d3d4a | exact authority+turn先apply；同stream严格后继、当前lease/runtime/source；null/source/runtime清票、suspend撤lease；原时间回退与容量不放宽 |
| 原页面false lane历史A正向 | receiver / 8c5002a9 | 同一Updater、真实SQL window、A单次与overlay/pending归零 |

单独撤4e6d3d4a可得到保留三项public red的行为基线，不应运行/部署；完整移除receipt需先适配Service/Cubit/API再处理8c5002a9。
仅回退测试设施不等于撤销产品行为；既有helper/七黑盒/C1f没有依赖新harness。保留red与正向断言，每个适配在隔离分支复查。
暂停投影只撤lease；文档不得声称它一定清receipt，票本身没有authority。cached-only/跨订阅仍保守，完整R47未接受。
C1i现已证明overlay自身capacity await-after replacement（R56 / E085）；下一C1j审无receipt/订阅切换，C2与visual pending迁移仍等待正确性证据。

## C1i自身overlay等待复跑与回退

在packages/bridge使用前文CCPOCKET_NODE运行：

```bash
"$CCPOCKET_NODE" node_modules/vitest/vitest.mjs run \
  src/local-features/conversation-authority-await-replacement.test.ts \
  src/local-features/conversation-authority-replacement.test.ts
"$CCPOCKET_NODE" node_modules/vitest/vitest.mjs run
```

固定d67c8b92的完整2548 PASS/1 SKIP、126 files PASS/1 SKIP、noEmit/语法及只读review通过。
原C1g test读取默认catalog输出，新test子进程设CCPOCKET_REPLACEMENT_GATE=overlay；同一harness共享原owned RPC/Bridge/关闭流程。
新增observer只匹配旧A payload和新增resolver、原样返回原Promise；public oldest-frame ACK负责推进到A-own wait，不改原budget/frame或调用私有send/drop。
60,000字节实际item/frame61,014低于64KiB；actual replacement/B投影/原wait未settle各自断言，关闭前所有budget清零。
移除post-await重查的临时实验直接FAIL（旧A+新B上wire），源码SHA256逐字节恢复且dist不变，恢复后2项PASS。
全部收据、dirty diff/恢复hash、35份trace及独立review见supplementalC1i；旧catalog watcher首次timeout仍R53，不由本次完整绿解释原因。

本批只修改conversation-authority-replacement-harness.mjs并新增conversation-authority-await-replacement.test.ts，原生产/Provider fixture/既有tests/全部Mobile输入不变。
回退d67c8b92的测试部分不会移除C1h receipt产品修复；保留原catalog与新own-await正确性断言，不将临时坏策略应用到产品。
Bridge build继承同原生产TS/依赖；Mobile full3412/4与83项仍精确归4e6d3d4a，不称本次重跑。
强制child timeout后代进程树回收未独立验收；不触碰生产服务作为测试清理。下一C1j只补cached-only/订阅替换/未来authority证据，再决定原owner窄修。

## C1j/C1k续接与结构回退

当前完整接受输入659d，3422/4及93项、0 error/warning、1017 info逐项不变、格式与固定源码只读复核通过。
本轮Linux原始证据在 `/workspace/ccpocket-review-evidence/20261011-sync-chain/`，同名JSON含实际命令/输入/UTC/hash。
Bridge本次实际2528/21；结构批按相同tree继承，不用Mac历史2548/1替代Linux检查。
93项精确命令见c1k-selected-93.json：terminal、queue、authority、commit_order、status_lifecycle及原实际receiver文件。
完整复跑仍用上文concurrency=1与已构建的真实Bridge；云环境工具分别位于 `/workspace/toolchains/flutter/bin/` 和 `/workspace/toolchains/node22/node_modules/node/bin/`。
观察设施修正337c5c5a和结构抽取659d分别提交；回退结构提交时同步更新owner文档/当前断点，保留原接收合同和先前行为修复。
C2需补R47剩余证据，D需调用/支持版本矩阵；不将本批抽取接受写成整体完成。
