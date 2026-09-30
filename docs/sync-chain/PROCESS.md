# 过程账本

## 当前断点

- 时间：2026-10-01（Asia/Taipei）。
- 分支：`codex/sync-chain-extraction-20261001`。
- 起始 SHA：`930f1267e949c6cf2095761cc71c43cca08c6dc3`。
- 阶段：A0 已建立方案与地图；下一步 A1 基线重放和红灯回归。
- 最新提交与验证身份在后续条目登记；不能从本节推断部署状态。

## E001 — 建立隔离执行与文档

动机：用户要求先详细梳理方案并开始执行，必须有中间文档和回归保护，避免接手时改乱。

范围：本目录的 README、PLAN、CHAIN-MAP、TEST-MATRIX、PROCESS；
此时未改业务代码。

证据与发现：
- 原修复分支 clean，HEAD 与前次审核一致。
- main 保留原有未跟踪资料；V4 候选未集成，不作为本批行为来源。
- target 没有 CodeGraph 索引，使用实际源码/调用/测试定位，不引用其他 checkout 的图作为权威。
- mise Flutter 链接失效；现场找到已缓存 Shorebird Flutter 3.44.7 / Dart 3.12.2，
  框架 revision 309dd6573a9fe716410489284cd325a34b950375。将显式调用并记录工具身份。
- 依赖准备限独立 worktree，先用离线缓存；没有修改全局工具选择或生产服务。

状态：方案与源码关系梳理 PASS；本批测试、修复和抽取尚未执行。
下一步：运行基线相关测试，补 R01/R03 的失败用例；不得先搬动修复调度。

## E002 — 基线重放与红灯回归

基线文档提交：`09297c594c4e7a165f84c8acc85f2973ee1c3038`；
业务源码仍与起始 SHA 一致。原始输出目录：
`/Users/developer/AI agent/Codex/_tmp/ccpocket-sync-chain-20261001/`。

运行与信号：
- `baseline-focused.json/.log`：Service、Repository、protocol 三文件 132 tests PASS，exit 0。
- `baseline-analyze.json/.log`：目标 Service/test analyze exit 0，0 error/warning；
  两条重复呈现的既有 use_null_aware_elements info，不属于本批新增问题。
- `baseline-bridge-build.json/.log`：真实 Bridge build PASS，exit 0。
- `baseline-chain.json/.log`：latest-turn-gap receiver 与完整 Codex page 两条真实接收链 PASS，
  最上游为隔离 Provider fixture，不证明真实 Provider/设备。
- `red-repair-regressions.json/.log`：新增/加强三个用例，3 FAIL，exit 1；
  此时没有改变业务代码。R01 epoch 应推进却仍为 1；
  R03 内容变化和缺口变化分别等待下一次 summary 请求超时。

修改：
- Service test 的 bounded-summary 用例增加 updates/epoch 断言，并保留 complete=false 与同内容重放检查。
- 增加同 canonical revision 的内容变化与缺口变化用例，使用真实 SQLite。
- 测试没有用 frame sequence/时间变化代替内容变化。

红灯 checkpoint 用途：保留“已有测试全绿但契约失败”的独立证据，不是可合并版本。
接下来先修 R01，再修 R03；每个修复记录自身绿灯与尚未关闭的失败。
文档首提交 diff-check 提示多余 EOF 空行，本批清理格式；不改写首提交。
