# 过程账本

## 当前断点

- 时间：2026-10-01（Asia/Taipei）。
- 分支：`codex/sync-chain-extraction-20261001`。
- 起始 SHA：`930f1267e949c6cf2095761cc71c43cca08c6dc3`。
- 阶段：A0–A3 选定闭环已完成；开始 B1 仅抽自动 latest-turn repair 调度。
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

## E003 — 只修复部分提交后的通知

父 checkpoint：`a511692ad6fd0a214e207436d7e7261a70bef3fc`。
修改：SyncService 的 turnsPageResponse/latest-turn repair 成功分支，
将通知条件从 latestTurnComplete 改为当前 subscription/generation/target 仍有效。
数据库继续保留 complete=false 与原 gap；Provider revision 未改。

验证：`green-notification-fenced.json/.log`，三个相关通知/恢复/生命周期用例 PASS，exit 0。
目标用例同时检查真实 SQLite 新内容、epoch、updates、partial 标志与相同内容重放。
根审确认改动在原有通知出口，没有第二个写入者或新刷新总线。

尚未关闭：R03 的两种同 revision 变化仍是已证明的失败，留到下一批；
此提交不是全部门禁通过的可合并候选。下一步建立修复观察进度并补 dirty/cancel 回归。

## E004 — 同版本进度、并发变化与取消归属

父提交：`86b0d49e5107fe92c37c1e19a2f21dd195a703e1`（E003 通知修复）。
范围：SyncService 自动 latest-turn repair 调度及同文件测试；尚未抽取结构。

修改依据与责任：
- 去重使用本地观察值：canonical revision、既有 presentation hash、gap/cursor 与 sourceEntryCount。
  时间、frame sequence 不参与观察值；它不发送给 Provider，也不取代 wire revision。
- summary 接受后记录提交后的观察值，避免自己的缓存增量引起重复请求；有 dirty 变化时重新检查缓存。
- 每次调度保留操作 token，microtask/成功/失败/计时器均先核对归属；取消的旧 flight 不得重新记去重状态。
- loaded 与 coverage 分开；部分成功继续保持 latestTurnComplete=false。

中间发现与验证：
- 初版修复让 134 个 Service/Repository/protocol 用例 PASS（`green-repair-progress`）。
- 独立审查发现：执行中 gap 增大，成功回调把新观察误记为已修复，dirty 重查再次被抑制。
  新用例在该版确实 FAIL（`red-dirty-progress`）；修正为 dirty 时不记录完成观察，再重查。
- `green-progress-and-dirty`：135 个相关用例 PASS。
- 增加相同输入执行中重放、focus 离开再返回两种生命周期用例。
  初次运行因新增测试使用诊断 API 缺少参数而编译 FAIL（`progress-lifecycle`）；
  修正测试调用后 `progress-lifecycle-corrected`：56 个 Service 用例 PASS。
- 所有失败日志均保留，不将后续绿灯覆盖在原日志上。

下一步：冻结这批业务改动供同一独立 reviewer 复核，再通过真实 Bridge/解码/SQLite/页面
验证 partial-summary 提交能触发页面重读。全 Mobile 门禁、真实 Provider、模拟器/真机尚未完成。

## E005 — 返回焦点时不能接管旧请求

父提交：`625999f21a17a9eff28d62f329f71968b0f7668b`（E004）。
独立 reviewer 确认 dirty-success 问题关闭，但指出一个既有遗漏：
离焦期间有进度、在旧请求结束前返回焦点，新 owner 会复用旧 future，误将新观察记为已处理。

验证：新增精确顺序的回归，`red-focus-return-before-settlement` 在父提交业务代码上 FAIL；
第二次 summary 请求超时。修复后 `green-focus-return-before-settlement`，
Service/Repository/protocol 共 138 个用例 PASS。

修改位置：`repairLatestTurn` 分开 historyKey 与 flightKey。
目标/source/session 的 historyKey 继续串行化写入；flightKey 额外包含既有 focusIntentGeneration，
同一焦点操作可共用请求，新焦点操作等旧串行操作结束后重新查询自己的观察。
没有清空已经接受的旧缓存内容，也没有新开并行写入路径。

R05 新增“返回前旧请求尚未完成”的顺序验证；不能把“旧结果先结束再返回”的测试等同于此场景。
测试文件的初次格式化命令误用了相对路径，命令报错后已在正确目录格式化并检查；
该错误未修改业务源码。

## E006 — partial-summary 的实际页面闭环

行为父提交：`6ff0ca4692cb2034c372db1c6cc0bdb68924ac45`（E005）。
修改仅在测试：真实 Bridge harness 添加 partial-summary Provider fixture，
通过真正 CodexProcess stdio JSON-RPC 暂缓 summary 回复。真实 CodexSessionScreen 先显示旧前缀，
再释放回复；测试没有手动刷新页面、注入 window/Cubit，或重建页面。

回归断言：SQLite 新 Provider item ID、条目顺序与内容、epoch 推进、原页面与 Cubit 身份不变，
旧前缀仍可见、新提示只显示一次、canonical revision 不变、coverage 仍 partial。
测试固定接口边界，不声称真实 Provider 的 history reader 本次已经验证。

中间验证：
- 首次 fixture FAIL（`partial-summary-page`）：summary repair 与 user-index 都被暂缓，
  测试等待“恰好一个请求”超时。按生产请求用途分别控制 gate 后修正测试夹具。
- `partial-summary-page-gated` PASS；`current-chain` 三个 receiver/full-page 用例 PASS。
- 临时将通知条件恢复为原错误条件，`red-page-notification-mutation` 确实 FAIL：
  数据已提交而原页面不显示新提示。finally 恢复文件，校验源码 SHA256
  `c7d2502d9163276a4590f72582dabcf1e01d3fcc0713f43478271efd0a3b6d6e`；未提交该 mutation。
- `fixture-analyze` PASS，0 issues；Node 两个 fixture 语法检查 PASS。
- `bridge-suite`：124 files / 2546 tests PASS，1 file/test SKIPPED。
  本次 Bridge 业务源码未改变；并行运行时记录的 diff 包含上述 Mobile mutation，不能当作 Mobile 绿灯。

完整原始 RPC、Bridge/client 帧和页面/SQLite 轨迹从临时目录复制到本轮证据目录
`chain-traces/`；Fixture 上游、native/font mocks、headless Flutter 页面与真实设备的界限仍保留。

下一步 B1 范围冻结：把自动调度的状态、completed observation、retry timer、dirty/operation token
迁入单一 latest_turn_repair_scheduler；Service 保留 source/focus/generation、cache observation、
请求/数据库写入与通知。保留 4 次失败上限、1/2/4 秒退避、128 个观察记忆，以及所有取消接点。
不在结构提交中修改这些策略；新增调度时间/取消保护验证，再重跑同一接收闭环。

## E007 — 第一块结构抽取：自动修复调度

父提交：`b76c97cc9272986344ae6b1a4c7f1818fb663c77`（E006 fixture/页面保护）。
范围：新增 latest_turn_repair_scheduler.dart 及其四个时间/取消测试；
Service 迁移三组状态和四个取消接点，保留原身份、观察与修复执行路径。
Service 减少 229 行；新模块 238 行，目的在于责任归属，并非用行数证明正确性。

抽取后验证：
- `extraction-regressions`：142 个 scheduler/Service/Repository/protocol 用例 PASS。
- `extraction-chain`：与抽取前相同的三个 receiver/full-page 用例 PASS。
- `extraction-analyze`：exit 0，无 error/warning；既有 null-aware info 与新增 fake_async
  间接依赖 info 各重复显示一次。后者通过显式 dev_dependency 处理，离线解析成功，
  仅改变锁文件 dependency 分类，未升级版本或引入运行依赖；全量 analyze 尚待最终门禁。
- Node fixture 语法、Bridge 类型检查已 PASS（`bridge-typecheck`）；Bridge 业务源码仍未改变。
- 新测试首次因 lambda 缺括号编译 FAIL（`extraction-focused`），另一次检查从错误目录运行
  找不到 pubspec（`extraction-focused-corrected`）；修正后才计入 PASS。失败均保留。

根审：三个窄回调没有传入 Service/Repository/Page 对象；状态只保留在 scheduler，
generation/source/focus 当前性仍由 Service 判定；clearTarget/clearAll 迁移覆盖原接点；
事务、Provider/wire revision、partial coverage 与通知逻辑没有在结构批中改变。

下一个完成门禁：冻结提交后的独立 review、全 Mobile analyze/test，
并修正普通 CI 缺少 Bridge build 导致黑盒测试无法启动的前置条件。
真实 Provider、模拟器/真机与部署仍为 NOT_RUN；B2 未开始。
