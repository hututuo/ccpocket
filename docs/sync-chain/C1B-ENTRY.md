# C1b 入口：V2 durable 历史与 overlay 的展示接缝

状态：C1b 已从 clean `96d77007e8ddb4a1c8adc4dc8487d18534812c02` 开始。
最新门禁时间 2026-10-02，Asia/Shanghai；历史条目保留当时记录。
当前 canonical 候选 prepare/admission/compose 与四项状态、History 提示修复已完成。
pending focus 漏发也已确定性 red → 窄修 → 原页面 green，关闭 R35 的选定交错。
产品冻结 `ce51e280`；测试/fixture 输入 `adf337ea` 全量 Mobile 3333 PASS / 4 SKIPPED、
Bridge 2546 PASS / 1 SKIPPED，静态检查与独立复核通过（PROCESS E041）。
旧 FAIL 和全部原断言保留；下一步按 [R29-FOLD-ENTRY](R29-FOLD-ENTRY.md) 定位另一项折叠等待，
不在结果和取消归属尚未证明时扩大 runtime 结构抽取。
C1a 固定源码门禁已完成（PROCESS E029）；同输入基线与本批重放分别记录。
整体计划见 PLAN；读取所有权见 PREVIEW-READ-LIFECYCLE，不能在本批重新实现读取状态。

## 选定范围与已有模块

只选 Codex V2 detached preview 的一次 durable history 更新：
`updateDetachedPreviewHistory` → 原 handler 的只读 `prepareHistory` → canonical admission → `_applyUpdate` →
`_mergeHistoryWithPreservedLiveEntries` 的 V2 detached 分支 → 原 layout/页面。
合法历史应用后才 `commitPreparedHistory` 确认提示；overlay 按应用时的原运行身份筛选再合成。
实现与逐项证据见 DETACHED-CANONICAL-ADMISSION、PROCESS E031–E041。
Service 的订阅焦点修复与本 canonical 接缝分开；其快照、接受及失效仍由原 Service 拥有，
不能移动到 candidate、页面 reader 或原 layout。

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

表中各项是验收契约；当前证明与缺口按 TEST-MATRIX R30–R35 记录，不能仅凭此表宣称全部覆盖。
正确预期取自协议与产品身份规则；旧 Cubit 输出仅作定位对照。
legacy empty 和 V2 authoritative empty 的 C1a 保护必须继续通过。

## 执行顺序与停止扩大范围的条件

1. 核对 HEAD/status，完整读 HANDOFF 与相关 decisions；登记 owner、允许改的文件、
   所有调用者、状态清理接点，以及各矩阵行的现有证明与缺口。
2. 先重放 `detached_timeline_projection_test.dart`、`chat_session_cubit_test.dart`、
   `durable_session_preview_test.dart`、`codex_durable_preview_read_test.dart`、
   `chat_process_layout_test.dart` 和原三个接收/页面黑盒文件（现为六个用例，含新增 held 交错）。local-history paging 用例仅用于
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

E042 复查原 trace：subscribe 已有焦点，wire 有 A/B/final 三个 runtime_overlay；旧 FAIL 的
快照尚无后来新增的 SQL/Cubit/layout disclosure 事实。当前同四文件默认并发组合 50 PASS，
来源、输入及代码已变化，不形成旧问题因果证明。下一批具体步骤与收据见 R29-FOLD-ENTRY。
定位须保留原断言，记录原始 runtime/status 事件、SQLite 有序条目 ID/hash、
Cubit canonical/overlay ID 及 layout turn identity/过程计数，再判断是输入、投影还是测试宿主时序。
不以延长等待、删断言或刷新/重建页面获得绿灯；未复现时明确保留未知。

## 回退与授权边界

C1b 的测试、行为与结构分别提交；新增十五项回归和失败日志保留。
结构回退不能丢掉 E032 整体 admission 或 E035 提示延后确认；接口两端必须一起适配。
E036 观测不是行为修复，移除观测也不得移除原五个黑盒的断言。
E039 产品修复为 `ce51e280`，E040 测试/fixture 为 `adf337ea`；焦点回退保留十七项 wire/SQLite 契约
及 held 原页面的 red 敏感性保护。回退 fixture 不改原五个黑盒或任何 15/60/120 秒期限。
不依赖中间红灯 checkpoint，结构回退必须核对 C1a 的 ticket/dirty 与 deferred read 依赖。
此入口不授权 merge/push、替换运行 Bridge、安装原模拟器/手机应用、OTA 或发布。
