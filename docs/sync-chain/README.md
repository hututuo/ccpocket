# 消息链路梳理与渐进抽取

本轮从 `930f1267e949c6cf2095761cc71c43cca08c6dc3` 建立独立分支
`codex/sync-chain-extraction-20261001`。首先验证选定短闭环，再抽取已证明边界的职责。
原始 main、修复分支及生产运行状态不是本分支的操作目标。

第一批 A0–A3 / B1 已完成。源码验证冻结到
`45a4498a75d2649021b286eee0ea37f54ef86253`：Mobile 全量 3254 tests PASS、4 SKIPPED，
analyze 0 error/warning（1017 既有 info），独立只读复核无新增 actionable finding。
自动修复调度已独立；进度观察排序与手动刷新清理的补漏也有回归。
后续文档提交不改变这个源码身份；精确收据与提交索引见 PROCESS 的 E010。

B2 已完成 older-turn 的生命周期抽取及相关边界修复。最终产品源码
`f735ac6b11f05133ac9e42228dbb11fc5cacfacf`：Mobile 全量 3279 PASS / 4 SKIPPED，
Bridge 全量 2546 PASS / 1 SKIPPED，独立源码复核无剩余 actionable finding。
最终静态分析 0 error/warning，1017 既有 info，无新增；仅测试样式后续修正复查亦通过。
分页请求的错误、reset 准备/排队取消、提交后的观察者通知分别有 red → green 记录；
本地缓存事实的通知与旧订阅 transport 归属分别判断。完整门禁及测试样式复查见 PROCESS 的 E021。
具体边界见 [分页生命周期](PAGING-LIFECYCLE.md)。

C1a 已完成页面异步缓存重读的生命周期抽取。最终源码
`151c04752e0ce00568c73a6d9522bfe09c6a107c`：Mobile 全量 **3300 PASS / 4 SKIPPED**
（`--concurrency=1`），analyze 0 error/warning，1017 既有 info 逐项比对无新增；
固定 SHA 独立复审无剩余 P0–P2。新增十三个真实 SQLite/原页面契约与八个纯生命周期用例，
关闭旧来源读取错误晚到、来源返回后遗漏补读两项缺陷，保留被动 runtime 绑定的 canonical reader。
Bridge 与依赖输入未变，继承 B2 门禁。完整收据与回退依赖见 PROCESS 的 E029，
责任见 [读取生命周期](PREVIEW-READ-LIFECYCLE.md)，下一批见 [C1b 入口](C1B-ENTRY.md)。

一次早期并发组合的 full-page 折叠等待超时仍保留为未归属观察；后续单独与串行重放通过，
不能据此宣称并发问题已修复。真实 Provider、模拟器/真机、云 CI 与生产部署各自仍为 NOT_RUN；
原生 UI 自动化因本轮工具不可用为 BLOCKED。源码门禁只证明选定接收闭环。

C1b 当前已修复无效 canonical 仍改变设置/审批/队列/分页，以及解码提前确认 Git tip 的遗漏；
在原投影模块中分开 canonical 准备、接受与后置 overlay 合成，新增十五项保护。
产品冻结 `2f64e383`，加入观测后的固定输入 `d0f164e5` 全量为 **3315 PASS / 4 SKIPPED**；
Bridge **2546 PASS / 1 SKIPPED**，build/typecheck、格式、完整诊断基线比对及独立复核通过。
canonical admission 的源码门禁完成，收据见 PROCESS E037。
之前两次第二条过程消息可见性 FAIL 仍未关闭：SQL/Cubit 内容正确，stream 未关闭；
失败订阅没有携带焦点，成功订阅带焦点。下一步证明订阅等待确认期间的焦点竞态，
不能以这次观测输入 PASS 宣称完成信号已修复。见 [完成信号定位](RUNTIME-ITEM-BOUNDARY.md)。

接手顺序：

1. [方案与批次](PLAN.md)：目标、推进门禁与抽取次序。
2. [实际链路地图](CHAIN-MAP.md)：写入者、读取者、身份、完成条件。
3. [回归矩阵](TEST-MATRIX.md)：哪些场景有证据，哪些仍未验证。
4. [过程账本](PROCESS.md)：每批动机、修改位置、测试和下一步。
5. [接手与验证操作](RUNBOOK.md)：责任边界、重跑命令、回退与下批入口。
6. [C1a 范围与契约](C1-ENTRY.md)、[读取生命周期](PREVIEW-READ-LIFECYCLE.md)：已完成的读取接缝。
7. [C1b 入口](C1B-ENTRY.md)、[历史接受职责](DETACHED-CANONICAL-ADMISSION.md)：已实现接缝与回退依赖。
8. [完成信号定位](RUNTIME-ITEM-BOUNDARY.md)：当前 R35 事实、待证明竞态与后续执行边界。

过程记录不得以旧证据覆盖新失败。源码测试通过、真实 Provider、模拟器、真机、部署和发布分别报告。
这组文档与对应代码一同提交；原始测试输出保存为独立文件，账本记录命令、身份、结果和证据路径。

后续修改任何链路模块时，先找到地图中的 owning path 与受影响矩阵行，再选择本批测试。
禁止把现有错误行为当正确预期；稳定身份、条目顺序、内容与 coverage 的预期来自 Provider/协议契约。
