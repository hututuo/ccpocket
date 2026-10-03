# 方案：先证明小闭环，再逐步减少跨层判断

## 目标与范围

让“原始事实 → Bridge → 解码 → SQLite → 通知 → 页面”的责任和完成状态可追踪，
每个批次可验证、可回退、可继续。第一批重点是 Codex 最新轮次缺口修复；
Claude、发送/控制、后台和兼容路径需要各自建立证据，不能借用接收测试的 PASS。

起始 SHA：`930f1267e949c6cf2095761cc71c43cca08c6dc3`。
执行分支：`codex/sync-chain-extraction-20261001`。
main 已有未跟踪资料，不纳入本批、不覆盖；V4 是独立候选线，不在此机械移植。

## 阶段及进入下一阶段的条件

| 阶段 | 工作及具体产物 | 推进条件 |
|---|---|---|
| A0 | 当前源码身份、链路/状态地图、测试与未知项清单、文档入口 | 确认修改的是实际 owning path，现状记录能复现 |
| A1 | 重放现有相关测试；对已确认疑点补失败用例 | 用例可在基线稳定失败，并验证正确事实而非实现细节 |
| A2 | 在原有路径修复提交后通知与修复抑制问题；分别提交 | 回归用例变绿，身份、coverage、重放及取消保护仍成立 |
| A3 | 真实 Bridge/解码/SQLite/页面接收链回放；整理轨迹 | 必须明确 Provider fixture 与真实 Provider 的证明范围 |
| B1 | 单独抽最新轮次自动修复调度，迁移完整状态与取消责任 | A1/A2/A3 对这块所需闭环成立；抽取前后相同输入给出相同结果 |
| B2 | 抽单种历史分页生命周期，再评估共享逻辑 | 请求身份、终态、deadline、过期响应及取消都有验证 |
| C1a | 收拢页面异步缓存读取的 owner、dirty、接受与失效；已完成 E029 | 真实 SQL/原页面契约、完整读取接点、全量源码门禁与固定 SHA review |
| C1b | canonical prepare/admission/compose、后置提示确认及 pending focus 行为修复已完成 E041 | 十五项 canonical、十七项焦点保护及原页面因果 red/green；固定输入全量与独立复核通过 |
| C1c | 终态/ticket/runtime身份及未知 activity 的选定修复已完成 E059/E060；历史R29仍未知 | 公开red→green、原七黑盒、完整门禁与固定SHA复核 |
| C1d | quarantine map/bytes 单 owner 已完成 E059/E060 | 十三项public队列契约；结构保持原策略，完整门禁与取消接点复核；queue-only authority策略未审定 |
| C1e | 已知runtime身份的原mutation接纳已公开red→窄修，保留未绑定只读与旧版/独立target保护，E061–E063 | 26项新契约/相关313项PASS；完整门禁与固定SHA复核待冻结。无ID远端归属仍R49 |
| C2 | 按领域逐批抽 Bridge handler | 连接、认证、序列、权限归属不重复实现 |
| D | 按调用/版本矩阵退役旧分支，更新唯一文档入口 | 确认路径无支持用途；删除对应状态与文档，而非只藏入口 |

第一批 A0–A3 / B1、B2、C1a 分别通过 E010/E021/E029 源码门禁。
C1a 的范围保留在 [C1-ENTRY](C1-ENTRY.md)，责任与回退见 PREVIEW-READ-LIFECYCLE；
C1b 已在原投影模块收拢 canonical 候选准备/接受，并保留 Cubit 的状态应用与 overlay 身份筛选。
接缝与回退见 [C1B-ENTRY](C1B-ENTRY.md) / DETACHED-CANONICAL-ADMISSION。
订阅待确认时的焦点遗漏已在原 owning path 证明并修复；责任与证据见
[RUNTIME-ITEM-BOUNDARY](RUNTIME-ITEM-BOUNDARY.md)。下一步按 [R29-FOLD-ENTRY](R29-FOLD-ENTRY.md)
保留旧折叠等待未知。C1c已证明独立终态契约与runtime身份缺口，C1d已迁移quarantine唯一owner；
责任与缺口见RUNTIME-STATUS-IDENTITY / RUNTIME-QUEUE-ENTRY，最终门禁见E059/E060。
下一批先证明原控制lease的runtime归属；queue-only authority和visual overflow仍不得当已审定策略迁移。
当前默认并发四文件重放50 PASS不关闭旧失败；
运行/展示链未据本次全量 PASS 整体验收。
后续大类不会在同一批重写。
任何失败先记录并定位；在选定段的正确结果仍无法判定时停止扩大抽取范围，继续补证据。

## 第一段的正确性契约

- 部分修复的有效提交必须触发缓存观察者重新读取；不能因 coverage 不完整而隐藏新内容。
- 通知不改变 Provider revision，不把 partial 宣称为 complete。
- 完全相同的观察重放不造成请求风暴；同 canonical revision 的后续内容/缺口变化仍可触发必要修复。
- 切换 focus/source/generation、断线、reset、dispose 后旧操作不能写入新目标或重新取得调度权。
- 已提交的可读内容保留；传输、缓存、渲染的预算各约束自己的对象。
- 整条链的结果以稳定 ID、顺序和内容 hash 对照，不以 spinner、ACK 或测试总数替代。

## 实施纪律

1. 修改前登记本批范围、假设、预期差异和红灯测试。
2. 行为修复与结构抽取分别提交；每次提交包含对应测试和账本变更。
3. 只格式化本批文件；不提交生成缓存或他人的工作。必要的测试依赖必须单独登记，
   不顺带升级；B1 的 fake_async 仅把已有版本声明为直接 dev 依赖。
4. 每个新模块独占自己的状态；通过窄接口接收事实，不传入整个大类供任意访问。
5. 不增加第二套通知总线、数据库写入者或全局恢复 coordinator。
6. 测试完成后根审 diff，再按项目 self-review 流程独立复核有实质规模的改变。
7. 未经本轮另行授权，不 merge/push、替换生产 Bridge、安装原模拟器/真机应用或发布。

## B2 的具体入口与验收

先选 **older turns** 一种生命周期，不同时改 latest repair、user index、items/detail。
实际入口在 SyncService：`loadOlderTurns`、`_loadOlderTurnsWithRetry`、`_loadOlderTurnsOnce`，
状态为 `_historyPageFlights` / `_pendingTurnsPages`；入站处理在 turnsPageResponse / error，
中断出口为 `_failPendingTurnsPages` 与原订阅生命周期。Repository 的
`prependConversationTurnsPage` 继续是接受 revision/cursor 与写入内容的权威。
以上为 E011 起点；B2 抽取后状态归 `OlderTurnsPagingLifecycle`，原 Service 入口保留。
当前责任表和提交依赖见 PAGING-LIFECYCLE / RUNBOOK，旧 map 名称不作为后续修改入口。

1. 登记请求身份表：source/target/provider/session、generation/subscription/requestId、
   expected revision/cursor；列清谁创建、谁核对、谁清理，不能仅移动 map。
2. 列清每个终态：accepted、无更早历史、send/provider error、deadline、订阅替换、
   source/reset/dispose 中断；每个 future 必须恰好结算一次，旧回复不能重新取得写权。
3. 重放已存在的真实 SQLite 分页、ACK、前缀保留与 repair 并发测试，补缺失的
   超时/错误/过期回复/取消顺序用例。预期来自协议与内容/游标事实，不能从旧输出照抄。
4. 若出现行为缺陷，先在原路径红转绿、独立提交；若实际结果还无法判定，继续补证据，暂不搬动状态。
5. 再设计最小生命周期模块，整块迁移 single-flight、pending、deadline、settlement 与取消。
   共享 `_enqueueHistoryOperation`、数据库事务、通知与 source 身份继续留在原 owner；
   不提前泛化成所有请求的 coordinator，也不把完整 Service 传入新模块。
6. 用相同输入重跑抽取前后契约与真实 Bridge 接收闭环；完成静态分析、全量 tests、独立 review，
   更新责任地图、矩阵、收据和回退依赖，再进入 C1。

现场当前值是每次请求 15 秒 deadline、订阅重建等待 8 秒、最多两次尝试、请求 limit 1–20。
这些是源码现状，不等于已经审定的长期产品策略。B2 纯结构批保持这些值；
如需改策略，先记录具体用户失败与红灯，另起行为批。

真实 Provider 与设备验收继续列为独立批：先固定 source identity 与原始记录，
对照 Bridge 帧、SQLite 的 ID/顺序/hash、原页面，再做断线/后台/长会话。
未经该批验证，不能借用本轮 fixture 接收 PASS 宣称整体运行链已通畅。

## 回退与接手

批次提交及精确父 SHA 记在 PROCESS.md；回退使用对应独立提交的 revert，先复核工作树。
保留失败日志与新增回归测试，不能用删除测试获得 PASS。
接手先核对 HEAD/status，再读取账本的“当前断点”；不从旧文档路径猜当前版本。
