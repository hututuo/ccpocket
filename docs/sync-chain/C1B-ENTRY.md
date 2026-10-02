# C1b 入口：V2 durable 历史与 overlay 的展示接缝

状态：C1b 已从 clean `96d77007e8ddb4a1c8adc4dc8487d18534812c02` 开始（2026-10-02，Asia/Taipei）。
当前已完成候选结构实现和原四项状态修复；固定 SHA 复审又定位到 History 解码提示副作用，
正在按 E034 补红灯与窄修复。当前进展见 PROCESS E030–E034，尚非本批最终通过。
C1a 固定源码门禁已完成（PROCESS E029）；同输入基线与本批重放分别记录。
整体计划见 PLAN；读取所有权见 PREVIEW-READ-LIFECYCLE，不能在本批重新实现读取状态。

## 选定范围与已有模块

只选 Codex V2 detached preview 的一次 durable history 更新：
`updateDetachedPreviewHistory` → 原 handler → `_applyUpdate` →
`_mergeHistoryWithPreservedLiveEntries` 的 V2 detached 分支 → 原 layout/页面。
先验证它与实时 overlay 交错的实际结果，再决定是否收拢该分支的投影接受状态。

该分支已经调用 `projectDetachedTimeline`；不能为了拆分再造一套 canonical/overlay reducer。
当前 Cubit 仍拥有候选 overlay 筛选、投影统计、duplicate canonical 拒绝、
outgoing receipt/draft 清理、assistant alias 消费和结果应用。哪些状态真的能一起移动，
必须由调用顺序和契约确定，不能只把长函数换一个文件。

`_mergeCanonicalHistoryIntoPagedEntries` / `_weavePreservedEntriesIntoCanonicalHistory`
还服务于 paged local mirror、runtime 和 legacy 路径；它们不是本批 V2 分支的统一替代入口。
本批不同时搬动这些共享算法、发送/审批控制、SQLite writer、Bridge handler 或 UI 布局。

## 需要先证明的契约

| 输入/交错 | 必须成立的结果 | 第一层证据入口 |
|---|---|---|
| 合法 canonical commit 与已验证 overlay 并存 | canonical 的稳定 ID、顺序和内容保持权威；overlay 不写回 SQL | 原 Cubit 状态、SQL 行与实际 layout 对照 |
| canonical 首次包含本地 outgoing 的关联 ID | 对应 overlay/receipt 按其稳定关联消费，重复提交不重复副作用 | 原 Cubit 入口与 outgoing receipt/draft 可观察状态 |
| 两个同正文但不同稳定身份的条目 | 仍为两个条目；不能以正文、时间或位置合并 | 原身份契约和可区分的 Provider item/turn ID |
| provisional alias 被 canonical 补齐 | 仅消费对应次数，artifact/工具归属不丢失，重放不重复 | 原 alias/merge 用例与新增输入顺序用例 |
| 损坏候选含 duplicate canonical | 保留 last-good；不可接受的候选不能提前消费 receipt/alias | 原投影入口及清理前后状态，不能只测纯 reducer 输出 |
| source/thread 切换或 passive runtime 绑定期间提交 | 仍走现有 source 与 reader 权威；旧 overlay 不获得新来源写权 | C1a 十三个 SQLite 页面契约及现有 source 回归 |
| partial → complete，或 runtime 完成事件先后到达 | 原页面的过程折叠、最终回复与工具所属轮次一致 | 原 full-page 黑盒，固定 SQLite→Cubit→layout 轨迹 |

表中各项是待核对契约，不能据此宣称已发现缺陷或已经覆盖。
正确预期取自协议与产品身份规则；旧 Cubit 输出仅作定位对照。
legacy empty 和 V2 authoritative empty 的 C1a 保护必须继续通过。

## 执行顺序与停止扩大范围的条件

1. 核对 HEAD/status，完整读 HANDOFF 与相关 decisions；登记 owner、允许改的文件、
   所有调用者、状态清理接点，以及各矩阵行的现有证明与缺口。
2. 先重放 `detached_timeline_projection_test.dart`、`chat_session_cubit_test.dart`、
   `durable_session_preview_test.dart`、`codex_durable_preview_read_test.dart`、
   `chat_process_layout_test.dart` 和原四个接收/页面黑盒。local-history paging 用例仅用于
   确认共享调用边界，不自动扩大本批实现范围。
3. 为缺口补原 Cubit/真实 SQL 页面契约。若定位到错误，独立记录 red → 行为 fix → green；
   若实际正确结果仍无法判定，继续补事实，不先迁移状态。
4. 行为冻结后评估最小接缝；沿用现有纯投影模块。只有确实能独占状态、完整迁移终态和清理、
   不需要整个 Cubit/Page/Service 对象时，才进行独立结构提交。
5. 相同输入重跑原页面，再完成受影响领域的 analyze、全量 tests 和固定 SHA 独立 review；
   更新地图、矩阵、过程、回退依赖和下一批入口。设备/真实 Provider/生产门禁独立记录。

## E024 的折叠等待观察

曾有一次并发组合测试在 canonical 已提交后等待“完整中间过程折叠”超时。
同源码单独重放和后续串行相关测试通过；原因尚未归属，不能称为已经修复或偶发。
C1a 最终全量的并发度与结果单独记在 E029。

下次定位须保留原断言，记录原始 runtime/status 事件、SQLite 有序条目 ID/hash、
Cubit canonical/overlay ID 及 layout turn identity/过程计数，再判断是输入、投影还是测试宿主时序。
不以延长等待、删断言或刷新/重建页面获得绿灯；未复现时明确保留未知。

## 回退与授权边界

C1b 的测试、行为与结构仍分别提交；新增回归和失败日志保留。
不依赖中间红灯 checkpoint，结构回退必须核对 C1a 的 ticket/dirty 与 deferred read 依赖。
此入口不授权 merge/push、替换运行 Bridge、安装原模拟器/手机应用、OTA 或发布。
