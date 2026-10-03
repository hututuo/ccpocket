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

一次早期并发组合的 full-page 折叠等待超时仍保留为未归属观察；当前同四文件组合默认并发
50 PASS，也未形成该旧问题的因果证明。真实 Provider、模拟器/真机、云 CI 与生产部署各自仍为 NOT_RUN；
原生 UI 自动化因本轮工具不可用为 BLOCKED。源码门禁只证明选定接收闭环。

C1b 已修复无效 canonical 仍改变设置/审批/队列/分页，以及解码提前确认 Git tip 的遗漏；
在原投影模块中分开 canonical 准备、接受与后置 overlay 合成，新增十五项保护。
随后确定性证明并修复 R35：subscribe 发出后、接受前变化的焦点没有发到 Bridge，
导致 runtime 完成信号漏发、两条过程消息粘连。原 Service 在匹配接受时只补发最新焦点，
保留原协议、授权与写入路径；新增十七项 V1/V2 保护及一个原页面交错场景。
旧 Service 在相同原页面输入 FAIL，修复版 PASS；原断言和全部期限保持不变。
产品冻结 `ce51e280`，完整测试/fixture 输入 `adf337ea` 全量为 **3333 PASS / 4 SKIPPED**；
Bridge **2546 PASS / 1 SKIPPED**，build/typecheck、格式、1017 条既有诊断完整比对及两项独立复核通过。
最终门禁见 PROCESS E041；R35 选定交错已关闭，旧 FAIL 与恢复收据保留。
完成信号责任见 [运行与焦点边界](RUNTIME-ITEM-BOUNDARY.md)；
历史 [R29 折叠等待入口](R29-FOLD-ENTRY.md) 继续保留旧失败的归因缺口。

C1c/C1d 已通过选定终态修复与隔离队列抽取的源码门禁。
完整产品/测试冻结 `da3d3f610c4507ad15c501a9c8c7ffeceb143dac`：
Mobile **3370 PASS / 4 SKIPPED**、Bridge **2546 PASS / 1 SKIPPED**，包含七个真实接收黑盒。
固定 SHA 独立复核无本次新增 P0–P2；终态清理要求当前远端 runtime 身份及权威 activity，
未来 turn 的合法隔离消息不再被旧可见 turn 退休误删。随后只改一处测试 map 写法，
`2f95d6d0` 的相关 40 项及完整 analyze 复查通过：0 error/warning、1017 既有 info，无新增。
产品、依赖和黑盒树与冻结输入一致；完整收据见 PROCESS E059/E060。

新模块 `RuntimeOverlayQuarantine` 独占 pending map/bytes，原 Cubit 保留接纳、权限及呈现。
责任、容量边界与回退见 [状态身份](RUNTIME-STATUS-IDENTITY.md) / [队列职责](RUNTIME-QUEUE-ENTRY.md)。
authority 替换的反向测试有已显示 owner；只有 pending 时的旧/未来 authority 策略未审定。
C1e随后证明并修复旧B状态与当前C runtime混用权限：16项实际发送/stop/interrupt行为red转green，
另保留合法C的settings/image lease、未绑定只读以及旧组合/独立target，共26项新契约。
最终产品/测试 `16196f05` 完整Mobile **3396 PASS / 4 SKIPPED**，固定SHA独立复核无本次新增P0–P2；
测试unused import后续 `8178295d` 的26项、analyze/format复查PASS，0 error/warning、1017既有info无新增。
产品/依赖/黑盒tree相同，Bridge按相同tree继承E059门禁；精确收据见E064/E065及[门禁记录](ACCEPTANCE.json)。
随后C1f仅补接收与测试设施证据，未改产品、Bridge或依赖。固定测试输入 `84493fc6`：
**71项组合PASS**（8条真实接收链、3条自建Node进程清理合同、60条公共队列/权限/终态保护），
新增文件analyze无诊断、format无变化，固定SHA独立复核无新增P0–P2。
真实producer的status先发送、SQL已提交而页面尚未观察authority时，合法overlay仍隔离、无控制权限；
原Updater接纳后只出现一次，再由canonical在同一页面接替。错误提前删除策略会让该用例FAIL，恢复后4项PASS。
READY超时及非法/缺字段协议导致的自建进程清理缺口均有red→green，原七黑盒及共享helper保持不变。
完整3396/4仍归属16196f05，未把新增测试计作新全量。证据与失败保留见E066–E073 / ACCEPTANCE.json。
下一批按[authority生产/消费入口](QUEUE-AUTHORITY-ENTRY.md)证明同public runtime ID替换与capacity等待组合（R47）；
无runtime身份字段的旧组合远端归属及visual pending 256/257策略仍未验收。

接手顺序：

1. [方案与批次](PLAN.md)：目标、推进门禁与抽取次序。
2. [实际链路地图](CHAIN-MAP.md)：写入者、读取者、身份、完成条件。
3. [回归矩阵](TEST-MATRIX.md)：哪些场景有证据，哪些仍未验证。
4. [过程账本](PROCESS.md)：每批动机、修改位置、测试和下一步。
5. [接手与验证操作](RUNBOOK.md)：责任边界、重跑命令、回退与下批入口。
6. [C1a 范围与契约](C1-ENTRY.md)、[读取生命周期](PREVIEW-READ-LIFECYCLE.md)：已完成的读取接缝。
7. [C1b 入口](C1B-ENTRY.md)、[历史接受职责](DETACHED-CANONICAL-ADMISSION.md)：已实现接缝与回退依赖。
8. [运行与焦点边界](RUNTIME-ITEM-BOUNDARY.md)：R35 根因、焦点快照所有权与回退保护。
9. [R29 折叠等待入口](R29-FOLD-ENTRY.md)：保留失败、当前重放、缺少证据和下批执行顺序。
10. [状态身份](RUNTIME-STATUS-IDENTITY.md)、[队列职责](RUNTIME-QUEUE-ENTRY.md)：C1c/C1d 的选定契约与未知边界。
11. [控制权限入口](RUNTIME-AUTHORITY-ENTRY.md)：C1e 的旧runtime公开失败、兼容保护与修复范围。
12. [下一authority入口](QUEUE-AUTHORITY-ENTRY.md)、[精确门禁记录](ACCEPTANCE.json)：未知策略的证据次序与当前执行身份。

过程记录不得以旧证据覆盖新失败。源码测试通过、真实 Provider、模拟器、真机、部署和发布分别报告。
这组文档与对应代码一同提交；原始测试输出保存为独立文件，账本记录命令、身份、结果和证据路径。

后续修改任何链路模块时，先找到地图中的 owning path 与受影响矩阵行，再选择本批测试。
禁止把现有错误行为当正确预期；稳定身份、条目顺序、内容与 coverage 的预期来自 Provider/协议契约。
