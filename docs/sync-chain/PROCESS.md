# 过程账本

## 当前断点

- 时间：2026-10-03（Asia/Shanghai；此前条目保留当时记录）。
- 分支：`codex/sync-chain-extraction-20261001`。
- 起始 SHA：`930f1267e949c6cf2095761cc71c43cca08c6dc3`。
- 阶段：A0–A3 / B1、B2、C1a 与 C1b 选定接缝已完成源码门禁；C1c 89084bcb 全量已绿，但独立复核的 runtime 身份缺口已由 public red 证明，原接点修复后已迁移quarantine唯一owner，最终门禁待E058冻结。
- 最新完整门禁产品 SHA：`ce51e28027087e5fe4d4d79533390203ae3735a8`，canonical 与焦点行为分开提交。
- 最新固定测试/fixture 输入：`adf337ea5f2ddddf3639da4e37b020435033b1d1`，全部门禁启动时 clean。
- 最新全量 Mobile 3333 PASS / 4 SKIPPED（--concurrency=1），Bridge 2546 PASS / 1 SKIPPED；build/typecheck/格式通过。
- analyze 0 error/warning，1017 既有 info 完整文本逐项无新增；产品/fixture 固定 SHA 独立复核无剩余可证明 P0–P2。
- R35 pending focus 缺陷已确定性旧 Service red → 窄修 → 相同原页面 green，关闭选定交错；旧两次 FAIL 与恢复收据保留。
- C1c `095cab00` clean 全量 3344 PASS / 4 SKIPPED / 1 FAIL，不是可验收候选；新 R40 两项 red 和诊断见 E049。
- 已接受门禁证据见 E041；当前调查、提交索引与回退见 E043–E052。
- E024 的历史并发折叠等待 FAIL 尚未归属；当前同四文件默认并发 50 PASS，不能据此关闭旧失败或宣称设备/运行链验收。
- 真实 Provider、模拟器/真机、生产 Bridge、云 CI、OTA/发布 NOT_RUN；原生 UI 自动化工具缺失为 BLOCKED。
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

## E008 — 普通 CI 的黑盒前置条件

父提交：`35b4d031e367f78bdab9aa7e63467c1ae8edbdc6`（E007）。
普通 test.yml 的 Mobile job 没有 Node/依赖/Bridge build，不能使用另一 job 的 dist。
新增沿用仓库已有 pinned setup-node action、Node 22、npm ci、Bridge build，置于 Flutter tests 前。
没有 push 或执行云端 workflow；平台发布 workflow 不在本批配置范围。

本地：YAML 解析及 prerequisites 顺序断言 PASS（`ci-mobile-prerequisites`），diff-check PASS。
actionlint 本机不可用，NOT_RUN；云端 runner、SSH 容器 smoke 和平台发布门禁 NOT_RUN。
依赖/真实 Bridge build 已在隔离本地 checkout 执行；CI 配置检查不冒充云端运行。

并行发现：冻结 E007 源码的全量 Mobile analyze exit 0，0 error/warning，1017 info；
全量 tests 有 3251 PASS、4 SKIPPED、1 FAIL，失败在本批 dirty-success 回归（`full-mobile-tests`）。
独立 reviewer 再指出 manual refresh 跨 target 的旧清理遗漏。
两处先补精确失败用例，再作为独立行为修复 E009；E007 不是全部门禁通过的候选。

## E009 — 排序进度观察与统一跨焦点清理

父提交：`b7944b89c38d1cc49ce2e25b54bdba865c7dc11a`（E008）。
范围：SyncService 与其 Service tests；不再改 scheduler 内部策略、Repository 或页面。

第一处是 E004 进度修复引入的时序窗口，不是 E007 的纯结构迁移改变行为：
timeline 提交后把缓存观察丢到后台；后来的 summary 回复可能先完成，记下新的提交后观察。
延迟的观察随后读到同一内容，误以为没有待处理进度。全量负载暴露此窗口。
新增可控 SQLite 读延迟用例，真实事务仍执行；明确断言较早观察尚未完成时，
较晚 summary 不得开始 repair transaction。父源码确实 FAIL，不依赖碰运气重复跑。

第二处是既有 manual refresh 跨会话遗漏：普通 setFocusedConversation 清理旧调度，
refreshFocusedConversation 自己改焦点时却未清理，旧回调失去归属后留下 running 状态。
新增 A 自动请求未结束 → 手动刷新 B → 接受旧 A 回复 → 返回 A 的回归；
父源码确实 FAIL，返回 A 的新自动请求无法启动。

修改责任：
- timeline 接收在已提交进度与后续回复之间 await **缓存观察**，不等待 repair 网络结果。
  两处 await 后重查 subscription/generation/target fence；观察仍使用既有真实缓存。
  ready helper 只登记 ready/唤醒 waiter，移除重复后台观察。
- 唯一 `_updateFocusedConversation` 入口统一 route 与 manual refresh 的 focus intent、
  refresh interruption、mark-read 与 clearTarget；每条路径继续保留原订阅/发送行为。
- 新增进度/焦点用例的等待截止由 2 秒改为 10 秒，允许全量并发负载；
  不把这当作行为修复，也不声称产品有 2 秒 SLA。确定性 gate 负责证明真实排序缺陷。

证据：
- `red-observation-and-manual-refresh`：上述两个新用例均 FAIL；业务代码尚未修改。
- `green-observation-and-manual-refresh`：scheduler/Service/Repository/protocol 共 144 tests PASS。
- 随后补齐观察后的两个 fence guard，`final-chain-node22` 三个真实接收/页面黑盒 PASS；
  Bridge/CodexProcess 根进程使用显式 Node 22.23.1，fixture 的 env-node 子进程仍用宿主 Node，
  此收据不是 Linux 云 CI 或真实 Provider 验收。
- `final-focused-analyze`：0 error/warning；既有 null-aware info 与新测试缺 braces info。
  提交前补 braces 并格式化；最终全量 analyze/test 尚待冻结后运行。

当前判断：确定性回归与短闭环已绿，全量完成状态仍 FAIL（保留 E008 原失败），
不能提前将 R12 标为 PASS。下一步冻结此提交，独立 reviewer 复核排序/取消/fence，
再记录全量绿灯或新的确切失败；B2 未开始。

## E010 — 最终源码门禁与接手索引

验证冻结点：`45a4498a75d2649021b286eee0ea37f54ef86253`，运行开始时 worktree clean，
收据的 diff SHA256 为 `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`（空 diff）。
后续本条及入口/地图/方案修改仅为文档，不改业务源码、测试、CI 或依赖。

| 检查 | 结果 | 精确收据 / 范围 |
|---|---|---|
| 全 Mobile tests | PASS，3254 PASS / 4 SKIPPED，exit 0 | final-full-mobile-tests.json/.log；冻结点全量，291.444 秒 |
| 全 Mobile analyze | PASS，0 error / 0 warning / 1017 info，exit 0 | final-full-mobile-analyze.json/.log；按路径/消息去掉行号比较 E008，info 无新增/删除 |
| 本批五个 Dart 文件格式 | PASS，0 文件改变，exit 0 | final-source-format.json/.log；同一冻结点 |
| 相关 scheduler/Service/SQLite/protocol | PASS，144 tests | green-observation-and-manual-refresh.json/.log；E009 修改中身份见该 JSON；最终全量再次覆盖 |
| 真实 Bridge / RPC / SQLite / 原页面黑盒 | PASS，3 tests | final-chain-node22.json/.log；完整全量运行亦包含这三项；Provider fixture 上游 |
| Bridge suite | PASS，124 files / 2546 tests；1 file/test SKIPPED | bridge-suite.json/.log；E006 身份，Bridge 业务源码从起点到最终未变化 |
| Bridge TypeScript noEmit | PASS，exit 0 | bridge-typecheck.json/.log；b76c97cc clean；本批后续没有 Bridge 业务改动 |
| 普通 CI 前置条件 | PASS 本地 YAML/步骤顺序 | ci-mobile-prerequisites.json/.log；云 CI、actionlint NOT_RUN |
| 独立源码复核 | PASS，无新增 actionable finding | final-independent-review.md；只读复核冻结点，不重复声称运行了测试 |

本轮证据根目录：`/Users/developer/AI agent/Codex/_tmp/ccpocket-sync-chain-20261001/`。
每个运行保留原 JSON/log；先读 JSON 的 HEAD/status/diff hash，再读结果。
中途红灯、编译/命令失败与原 E008 全量失败都保留，不能只读最后一个绿灯文件。
最终全量黑盒原始轨迹保存在 `final-full-mobile-traces/`；早期 mutation 和链路轨迹分别见 E006。
Mobile 的四项 SKIPPED 为未开启 smoke 环境的 SSH Bridge tunnel / jump host / private key
用例（private key 两项）；未将它们记作 PASS，也未在本轮配置真实 SSH 或容器 smoke 环境。

独立 review 检查了本地观察与有序接收的等待关系、repair readiness、观察后的 fence、
dirty-success、focus-intent flight 和统一 manual refresh 清理。确认初始两项及后续取消遗漏关闭；
该审查仅为源码证据，没有测试、真实 Provider 或设备运行授权扩张。

原 checkout 最终核对：main 仍为 `7de33f815e8448c1836227abb6b04784e40c58c9`，
原有七组未跟踪资料保留；旧修复 checkout 仍为起始 `930f1267...`、clean。
生产 Bridge、原模拟器/真机应用、OTA 与发布没有在本轮改动。

### 提交与回退依赖索引

| 批次 | 完整提交 SHA | 用途 / 当前判断 |
|---|---|---|
| E001 | 09297c594c4e7a165f84c8acc85f2973ee1c3038 | 文档方案；无业务修改 |
| E002 | a511692ad6fd0a214e207436d7e7261a70bef3fc | 红灯回归 checkpoint，3 FAIL；不可作可用候选 |
| E003 | 86b0d49e5107fe92c37c1e19a2f21dd195a703e1 | 部分提交通知；R03 仍 FAIL |
| E004 | 625999f21a17a9eff28d62f329f71968b0f7668b | 观察去重、dirty/token；后来发现排序窗口，由 E009 补齐 |
| E005 | 6ff0ca4692cb2034c372db1c6cc0bdb68924ac45 | focus-intent flight 与目标串行 |
| E006 | b76c97cc9272986344ae6b1a4c7f1818fb663c77 | Provider fixture 与原页面通知回归 |
| E007 | 35b4d031e367f78bdab9aa7e63467c1ae8edbdc6 | scheduler 纯结构抽取；E008 全量失败，不能单独宣称可用 |
| E008 | b7944b89c38d1cc49ce2e25b54bdba865c7dc11a | Mobile CI 自行构建 Bridge 前置 |
| E009 | 45a4498a75d2649021b286eee0ea37f54ef86253 | 排序观察 / 统一焦点清理；本批最终绿灯源码点 |

批次之间有源码依赖，回退步骤见 RUNBOOK；不能以任意挑一个较早 SHA 上线来代替验证。
本条所在最终文档提交身份由 `git log -1` 获取，不在正文内自引用。

本条 E010 当时的接手入口为 PLAN 的 B2；B2 后续执行见 E011 起，当前以本页顶部断点为准。
原始 Provider、发送/控制、后台、Claude、长会话、设备与生产各需要自己的闭环证据；
R13/R14 和云端 runner 仍 NOT_RUN，不从本轮接收 PASS 推断整体链路完全正确。

## E011 — B2 请求契约与缺口盘点

父提交：`03539df14e84d2fc0677e3556eafdd4008cd9255`。该提交与 E010 已验证源码一致，
仅补文档；沿用 E010 的 3254 PASS / 4 SKIPPED 基线，不重复运行未改变的全量测试。

允许修改：SyncService 的 older-turn 路径、对应测试、新的单种分页生命周期模块；
必要时扩展隔离 Provider fixture 与真实接收/原页面黑盒。Bridge 产品源码、Repository 写入权威、
UI 产品行为、其他四种分页和自动 latest repair 策略不在本批结构范围。

当前事实与待证明接缝：
- 正常 page commit/ACK、subscription replacement retry、与 latest repair 串行已有真实 SQLite 回归。
- ordinary turns-page DB exception 未像 latest repair 一样 request-local 捕获，进入全订阅恢复。
- thread syncReset 保留可读窗口/cursor，却没有结算对应 `_pendingTurnsPages`；旧 reply 仍可能被接受。
- older page 的 repeated next cursor 无专门进度保护，需证明是否能造成重复请求/游标停滞。
- 既有三个黑盒没有调用 older paging；隔离 Provider fixture 总返回 null cursor，不证明历史分页。

先补前述请求级失败、reset 与游标进度的红灯用例，再按实测结果修复；
之后迁移完整 single-flight/pending/deadline/settlement/cancel 状态，保持现有 15 秒/8 秒/两次尝试。
身份、事务与通知继续由原 owner 判定；接口/终态和后续测试入口见 PAGING-LIFECYCLE。
CodeGraph 此工作树此前已确认未索引，本批仍用实际源码；没有自行初始化索引。
独立只读 worker 仅盘点现有黑盒夹具，未修改、测试或启动任何服务。

## E012 — B2 三个确定性红灯

父提交：`ad9765747460b93a856526de78215730a02796e7`（E011）。业务源码未变。
新增 Service 用例共用真实 SQLite bootstrap / Provider page DTO；只在一次 prepend 调用边界
注入 DB exception，不模拟本地窗口内容。`b2-red-paging-boundaries.json/.log`：3 FAIL、exit 1。

失败事实：请求级 commit exception 触发全订阅 unsubscribe；repeated non-null cursor 被当作
loaded=true 接受；thread reset 后原 attempt 未结算。不是编译/环境失败。
接下来只修 owning path 的错误结算、游标进度与该 thread 的取消，独立行为提交后才抽取。

## E013 — 请求级失败、游标停滞与 scoped reset 修复

父提交：`193374d265d78d6e6d0b820ae41daf29f481b2c0`（E012 红灯 checkpoint）。
Service 原 older-page 入站出口捕获 DB exception，按原错误只结算该请求，仍累计 ACK，
不进入全订阅 recovery；nextCursor 等于原 non-null cursor 时在事务前明确拒绝。
thread reset 以 generation/target/provider/session 筛选并立即移除/失败旧 pending，
旧 requestId 后续回复只参与有序 ACK，不取得写权；其他 thread 的请求继续。
已提交内容的 transport-facing 通知补当前性检查。

`b2-green-paging-boundaries`：147 相关 tests PASS。
随后补 send/provider error 清理与 late reply、其他 thread 的 scoped-reset 隔离保护。
初次隔离测试误把 wire 的 providerSessionId 读取为嵌套 target，运行 FAIL（b2-paging-error-and-scope）；
按实际扁平协议修正 fixture 断言后，`b2-paging-error-and-scope-corrected`：150 tests PASS。
三个原红灯没有放宽断言；此时尚未结构抽取、真实 older-page 黑盒或全量完成门禁。

## E014 — older pages 的真实接收/原页面闭环

行为父提交：`0817dfbeaa157891e33893721a3bdda39810daf1`。
仅扩展隔离 Provider fixture 和黑盒：两页 summary 以真实 stdio RPC cursor 选择，分别 hold/release。
短内容视口通过生产页面/Cubit 的 older loader 自动请求，测试不直接调用 Service、注入 cache、
刷新或重建页面。独立 user-index 回复保持 hold，避免其他通知掩盖分页通知问题。

验证稳定 Provider item ID、SQLite 顺序/hash、cursor 1→2→null、最新可读内容保留、同一个
页面/updater/Cubit、加载终态；每页只在原窗口前方增加对应 Provider 内容。
`b2-chain-before-extraction`：4 receiver/full-page tests PASS。
Provider fixture 上游不构成真实 Provider 或设备验收。

首轮 `b2-paging-real-page`：两页 body 已记录 PASS，但夹具退出码 1，整体 FAIL。
原 harness-ready 的 stderr 字符串固定在 READY 时，收尾异常没有被显示。
改为保留 stderr buffer；`b2-paging-real-page-diagnostic` 本次 PASS，无法据此断言原异常确切根因。
fixture 后续明确开始 shutdown，再释放 held replies，并拒绝往关闭的 socket 写新回复；
完整 4 项检查通过，原失败收据保留，后续全量仍检查退出码。

`b2-red-page-notification-mutation`：临时关闭 older-page 的原通知出口，SQLite 有新页但原页面
无法显示，测试确实 FAIL。finally 恢复 Service，校验 SHA256
`392cc1575bbb5f42523d0af070060d65a217c0a99814fc81f14184e37cc2c173`；mutation 未提交。
JavaScript fixture 语法检查 PASS；目标 analyze 无 error/warning，随后处理 helper 新增 info。
下一步纯结构抽取：完整迁移 older-only flight/pending/deadline/settlement/cancel，
保留 E013 行为、15 秒 deadline、8 秒订阅等待、最多两次尝试与共享 history serialization。

## E015 — older-only 生命周期抽取与复审缺口

父提交：`55d5deecccccb10a5ad35c25f11e324fcdc98b7b`。
迁移完整 flight、pending immutable facts、15 秒 Timer、成功/失败/超时、scoped/global 取消与
dispose 的 flight join 入口到 `OlderTurnsPagingLifecycle`。结果 DTO 原样迁移并由 Service export。
Service 仍拥有 source/subscription fence、两次 attempt/8 秒等待、共享 history 串行、SQLite 和通知/ACK。

新增 8 个 fake-clock 契约用例：15 秒边界、迟到回复、成功/失败计时器清理、原错误/stack、
旧 handle 与同 ID 新 owner、跨 thread/source/generation/provider 的取消隔离、flight 合并/失败重试、
同步 host error、取消后本地工作仍可 join。

首次 extraction 检查 FAIL：E014 的测试 helper 构造器改用 private initializing formal 后，
调用处未使用 Dart 对应的 public 参数名 `stderrBuffer`，导致黑盒编译失败；并非业务红灯。
修正该参数名后 `b2-lifecycle-extraction-corrected`：81 tests PASS，含 4 项真实接收/原页面黑盒。
对应失败日志、analyze error 和修正后的绿灯收据均保留。

独立只读复审冻结 E013 源码，新增两项 P2：
1. reset 清 pending 看不到正在读取快照/尚在共享队列中的旧 flight；旧 R/C 可在同订阅继续发送。
2. Repository 的 prepend 在事务提交后还会读取 snapshot；若该读取失败，page-local catch
   只抛错误、漏通知，可能让已经更新的 SQLite 与挂载视图暂时分歧。

这两个缺口需要新的 red → fix checkpoint，不能藏在结构 diff 中。下一步先复现再修正；
此提交仍不作为 B2 最终可用候选，全量与最终独立复审尚未运行。

## E016 — 复审两处边界的三个红灯

父提交：`f112f3bd130bfafd99e18a261a19e2fc0591f9a1`。产品源码未变。
两项 real SQLite read barrier 分别覆盖 older 自己准备读取、以及在 latest repair 后排队。
reset ACK 后释放原快照，旧操作仍发送，未按 thread reset 失败。
第三项通过真实 prepend 事务，仅让其后续 snapshot read 抛错：确认 DB 条目/cursor 已更新，
但 cache epoch 未变，原观察者未重读；失败原因是漏通知，不是事务没有提交。

首次 `b2-red-review-boundaries` 误用 plain-name 含正则，exit 79 / No tests ran，不能作红灯。
修正选择器后的 `b2-red-review-boundaries-selected`：3 FAIL、exit 1，分别命中以上三项。
下一步用 flight 的 scoped 失效身份覆盖发请求前的等待；未明确 commit 阶段的异常保留原错误，
同时让当前分区的既有观察者重读，不能把 API 抛错一概解释成未写入。

## E017 — flight 准备/排队取消与不确定提交后的观察者重读

父提交：`42ddc307155f2231e1c9555e2ba007cbebbbd64a`（E016 红灯 checkpoint）。
older flight 在进入共享队列前取得 target/provider/session 的 operation 身份；reset 失效该身份，
Service 在读取前/后检查，因此准备读取和排队都不能在 reset 后登记新请求。
取消身份随 flight 回收，没有累积每个 thread 的 epoch/tombstone。普通订阅替换不失效 operation，
wire pending 仍按原 generation fence 取消，两次尝试和 8 秒等待不变。

older prepend 的 catch 保留原 error/stack，并在 transport 当前时复用原 cache invalidation。
它诚实表示提交状态不确定：若写事务失败，观察者重读未变的缓存；若提交后的快照读取失败，
观察者看见已写内容/cursor。没有清全分区、误报 loaded 或修改 Repository API/SQL schema。

新增 fake-clock 用例证明 scoped reset 不影响其他 thread/source，取消的 flight 结束后新调用可用。
`b2-review-boundaries-fixed` 首次运行有一个旧单测调用漏适配新 scoped 参数的编译失败，保留记录；
修正后的 `b2-review-boundaries-green`：81 related tests PASS（含 E016 三个红灯，9 个 lifecycle tests）。
`b2-review-boundaries-analyze`：exit 0、0 error/warning；一条既有 Service info 被重复列出两次。
此时准备冻结源码进入全量与最终独立复审；源码门禁、真实 Provider、设备和生产仍分别判断。

## E018 — 第一轮 B2 全量门禁与残余 review

冻结源码：`67fbef1ac412994e64bb62e478d1a720be373ef1`，启动时 clean。
`b2-final-full-mobile`：3273 PASS / 4 SKIPPED，exit 0；`b2-final-full-analyze`：0 error/warning，
1017 info，与 E010 完整诊断按 severity/file/text（保留重复数量、忽略迁移后的行列）比对无增减，
见 `b2-analysis-baseline-comparison.json`。format 7 files / 0 changed。
Bridge build/typecheck PASS；`b2-final-full-bridge-corrected`：2546 PASS / 1 SKIPPED、124 files PASS。
首次 Bridge 命令指向 root 的 vitest 而实际安装在 workspace，MODULE_NOT_FOUND、exit 1；
路径修正后全量通过；这次命令失败与所有先前失败收据保留。

独立只读 review 仍有 1 项 P2，所以此绿灯源码不作为最终候选：
已经进入 older prepend 的本地提交若与同源订阅替换交错，无论后续 snapshot 成功或失败，
transport generation fence 都会压掉本地通知。replacement subscribe 的 metadata 本身不重读页面。
下一步针对这个实际时序补 red，通知缓存事实按 partition/current source/dispose 归属检查，
旧 transport 的 ACK/syncUpdates 仍按原 generation 处理，不复活旧订阅。

## E019 — 已提交事实与订阅代次交错的红灯

父提交：`67fbef1ac412994e64bb62e478d1a720be373ef1`。产品源码未变。
真实 prepend 已提交后，在快照返回/抛错处 hold；分别触发同源 subscription replacement、
切换其他 source、dispose，再 release。检测原 partition 的真实条目/cursor、观察者重读与 epoch，
同时检查不向旧 generation 发布 transport timeline。

`b2-red-post-commit-ownership`：4 PASS / 2 FAIL；两个 FAIL 分别是同源替换后的成功与失败读取，
SQLite 已新增条目/cursor2，而观察者没有收到通知。source switch / dispose 的四项保护 PASS。
这说明不能用全量绿灯覆盖尚未被原测试覆盖的时序；新的 red checkpoint 不作可用候选。

## E020 — 缓存事实的分区通知与 transport 归属分别判断

父提交：`9bb11a12950131001afcb453b72b0b0404aa98a5`（E019 红灯 checkpoint）。
只改 older prepend 已进入本地 mutation 后的两个通知出口：success 与 commit/read exception。
本地 epoch/updates 按目标 fingerprint 仍当前、Service 未 dispose 判断，允许同源订阅替换；
transport timeline/syncUpdates/ACK 继续按原 `_isV2Current` 判断，不复活旧订阅。
请求接受前的 source/subscription/sequence/request/SQLite revision/cursor fence 均保留。

`b2-post-commit-ownership-green`：91 tests PASS，包含六种 post-commit interleaving、
所有相关 Service/lifecycle/scheduler 及四个真实接收/原页面黑盒；同源两个 red 转绿，
跨 source / dispose 不通知、旧 transport 不发布的保护未放宽。
源码再次冻结后重跑 Mobile 全量；Bridge 产品、fixture、schema 自 E018 之后未变，
已通过的 Bridge 全量/build/typecheck 不因单纯后续 Mobile 修改重复运行。
独立最终复审将针对此修正与它影响的归属判断闭环。

另补 C1 的具体接手页：优先审页面异步缓存重读生命周期，其产品代码尚未修改。

## E021 — B2 最终门禁、接手与回滚点

最终产品源码：`f735ac6b11f05133ac9e42228dbb11fc5cacfacf`，全量启动时 clean。
最终独立只读 review 确认此前全部 B2 finding 关闭，无剩余 actionable finding；
review receipt 为证据目录的 `b2-independent-review.md`，范围仅 B2，未运行测试或设备。

| 检查 / 原始收据 | 身份与结果 |
|---|---|
| `b2-final-confirmed-full-mobile.json/.log` | f735ac6b clean；3279 PASS / 4 SKIPPED，exit 0，247.292 秒；包含四个接收/原页面黑盒 |
| `b2-final-confirmed-full-analyze.json/.log` | f735ac6b clean；0 error/warning；1021 info，包含新增测试两处大括号 info 各重复一次；未把它们记成既有问题 |
| `b2-final-test-style-related.json/.log` | 仅给新增测试两处 if 补大括号；产品源码不变；87 相关 tests PASS，exit 0 |
| `b2-final-test-style-analyze.json/.log` | 补大括号后全量 analyze exit 0；0 error/warning、1017 info |
| `b2-final-analysis-baseline-comparison.json` | 完整诊断按 severity/file/text 比对 E010，保留重复数量、忽略迁移后行列；无新增/减少 info |
| `b2-final-format-after-test-style.json/.log` | 本批七个 Dart 文件，0 changed，exit 0 |
| `b2-final-bridge-build.json/.log`、`b2-final-bridge-typecheck.json/.log` | E018 的 67fbef1a clean；build/noEmit PASS |
| `b2-final-full-bridge-corrected.json/.log` | 67fbef1a clean；2546 PASS / 1 SKIPPED、124 files PASS，exit 0 |
| `b2-bridge-gate-inheritance.json` | 67fbef1a 与 f735ac6b 的 Bridge tree 都为 2bcc606909b9eb34470eafe264045186a6c1f2b9；Bridge/依赖输入无变化，继承门禁 |

最终测试样式没有改变条件、断言或测试范围；已重跑其完整相关目录与静态检查。
本条所在接手提交只增加文档和该测试样式，未改后续业务行为，提交身份由 `git log -1` 获取。
全量黑盒轨迹为 `b2-final-confirmed-traces/`，保留 RPC / Bridge/client 帧 / SQLite hash / 页面断言。
原输出仍在 `/Users/developer/AI agent/Codex/_tmp/ccpocket-sync-chain-20261001/`，失败收据不覆盖、不删测试。

四个 Mobile SKIPPED：SSH private key 两项、Bridge tunnel 一项、jump host 一项，均 smoke env not set；
Bridge 一项真实链 smoke 未 opt in。它们不计作 PASS，也未配置真实 SSH/Provider 环境。
真实 Provider、模拟器/真机、生产 Bridge、OTA、签名安装、云 CI、merge/push/发布均 NOT_RUN。
本轮只证明选定接收闭环、源码门禁和 review，不能从测试总数推断整条运行链全部正确。

原 checkout 核对收据：`b2-original-checkouts.json`。
main 仍 `7de33f815e8448c1836227abb6b04784e40c58c9`，原七组未跟踪资料保留；
旧修复分支仍 `930f1267e949c6cf2095761cc71c43cca08c6dc3`、clean。

### B2 提交与依赖索引

| 批次 | 完整提交 SHA | 用途 / 当前判断 |
|---|---|---|
| E011 | ad9765747460b93a856526de78215730a02796e7 | older 请求契约与批次边界 |
| E012 | 193374d265d78d6e6d0b820ae41daf29f481b2c0 | 三个红灯 checkpoint；不可作运行候选 |
| E013 | 0817dfbeaa157891e33893721a3bdda39810daf1 | 局部错误、游标停滞、已发送请求 reset 修复；后续补 preparing/queued 与提交后读取 |
| E014 | 55d5deecccccb10a5ad35c25f11e324fcdc98b7b | 两页 older 的真实 RPC/SQLite/原页面及夹具关闭保护 |
| E015 | f112f3bd130bfafd99e18a261a19e2fc0591f9a1 | lifecycle/DTO 结构抽取；后续行为依赖此模块 |
| E016 | 42ddc307155f2231e1c9555e2ba007cbebbbd64a | preparing/queued reset 与 post-commit read 三个红灯 checkpoint |
| E017 | 67fbef1ac412994e64bb62e478d1a720be373ef1 | operation 取消与异常 invalidation；E018 全量绿，但后续 review 找到订阅替换通知缺口 |
| E019 | 9bb11a12950131001afcb453b72b0b0404aa98a5 | 提交期间替换的两个红灯、其他 source/dispose 四个保护 |
| E020 | f735ac6b11f05133ac9e42228dbb11fc5cacfacf | 本地通知与 transport 归属分别判断；B2 最终验证产品源码点 |

回退按 RUNBOOK 的依赖逆序，在隔离 checkout 保留已经证明的行为与回归；
不能将任意红灯或有残余 review 的中间 SHA 当作可用版本。
下一批先读 C1-ENTRY，登记新账本：验证页面异步缓存重读，再决定完整状态的抽取接口。
其他分页、canonical/overlay 投影、发送控制、后台、Claude 和真实 Provider 长会话仍各需自己的证据。

## E022 — C1a 起点与读取接点盘点

起始 SHA：`38c4240e54496a4dd504ea6d029d457d78a90bfb`，当前独立 worktree clean；
产品源码仍是 B2 的 `f735ac6b11f05133ac9e42228dbb11fc5cacfacf`。
完整读 HANDOFF、相关 decisions 与 C1-ENTRY 后，选定 Codex 页面读取接缝。

范围：`_loadDurablePreview`、retry、start/restart/invalidate、identity canonicalization、
didUpdateWidget、runtime attachment 和 dispose 的读取归属；UI 布局和 Cubit 合并权不迁移。
既有页面在成功出口核对 source conflict，但 error 出口仅检查 generation/thread/epoch/dirty；
这是待验证缺口，不能先据此宣布已定位实际故障。

证据计划：先在 clean 起点重放 durable preview 与 B2 四个真实接收/原页面黑盒，
使用原显式 Flutter/Node 工具及 `c1-baseline-*` 收据。随后新增真实 SQLite read barrier，
分别记录通知合并、迟到读取/错误、换目标、保留 last-good 与 retry 的实际页面结果。
纯生命周期测试补 owner 清理边界，不能替代原页面；不把模拟 Provider 当真实 Provider。

只读 Luna 支持仅盘点现有测试和夹具，root 负责诊断、测试、生产修改、整合与验证。
新 red checkpoint 与独立行为修复先登记，再决定结构抽取接口；禁止直接搬动整个页面对象。
源码、设备、生产服务及发布依旧分层。此条登记时 C1a 产品代码尚未改变，测试仍在执行。

基线收据 `c1-baseline-preview-chain.json/.log`：clean 起点 36 tests PASS，exit 0，21.376 秒；
包含既有 durable preview 回归与四个真实接收/原页面黑盒。此结果只作未改动基线，
新真实 SQLite 读取交错及迟到错误的契约尚待补充。

## E023 — 真实 SQLite 页面契约与 source error 红灯

父提交：`83169884338d229273f979e7e67c0f970a7632d3`。产品源码未改。
新增 `codex_durable_preview_read_test.dart`，使用原 SyncService 收件路径、真实 SQLite、
真实 mounted Codex 页面；只在 Service 的页面读返回边界 hold/release/throw，
不覆盖 SQL 查询结果，不手工注入 UI history、epoch 或通知。
上游是受控的 incoming-event fixture，WebSocket/RPC 另由原四个黑盒覆盖。

`c1-red-preview-read-contract.json/.log`：5 PASS / 1 FAIL，exit 1。
已显示 source A，下一次读已读出 A 后暂停；认证 source B，再释放 A 的读取错误。
实际出现旧来源的 Snackbar；成功出口的 source conflict fence 未覆盖 catch，定位闭合。
其余用例证明四次同目标真实 commit 合并为一次 follow-up、旧 thread 成功/error 不清理新读取、
当前失败保留 last-good 并成功 retry、V2 complete empty 清理 canonical。

为让 real-async widget host 可运行，原 full-page 黑盒的字体/拖放平台适配原样移到共享 test helper；
字体来自仓库，平台 stub 不模拟业务数据，也不作为设备视觉证据。
`c1-preview-read-contract-first` 是测试编译准备 FAIL，
`c1-preview-read-contract-compiled` 是缺 native/font test host 的 FAIL；二者保留，
不当作产品 red。修正夹具之后才产生上面的确定性行为红灯。
本 checkpoint 不作可用候选；先补错误出口来源归属，再抽取生命周期。

## E024 — 读取错误补齐来源检查

父 red checkpoint：`5d69872d87b7d42984032848814127e7e6b029e4`。
只给页面 `_loadDurablePreview` 的 catch 增加与成功出口相同的 source conflict 检查；
不变更数据库、revision、Service 通知或 Cubit。

`c1-source-error-fence-green`：并发组合 41 PASS / 1 FAIL；六个新读取用例全部 PASS，
旧来源 red 已转绿。失败是 full-page 黑盒的“完整中间过程折叠”等待超时，缓存已提交，
并非新错误归属断言。保留失败和轨迹，不直接归类为偶发、也不删断言。
同源码/diff 单独重放该黑盒 `c1-error-fence-full-page-isolated`：1 PASS，exit 0，12.030 秒。
本批继续收拢读取状态；后续完整静态/全量门禁仍必须闭合并再次覆盖该黑盒。

## E025 — 冻结读取契约与结构边界

父行为修复：`722e753f4ee422f336e658ad2560ecfb1d0df686`。
额外覆盖 dirty 旧读取抛错、legacy empty、dispose 后成功/error；仍经原 Service 事件处理、
事务与通知。legacy 使用原 v1 snapshot begin/page/complete 及 ACK，
不以 fake epoch 或手工 UI history 代替旧 Bridge 兼容路径。
`c1-expanded-preview-contract`：10 个真实 SQLite/原页面用例全部 PASS，exit 0，7.130 秒。

抽取设计见 PREVIEW-READ-LIFECYCLE：纯同步 helper 拥有 active read ticket、dirty 合并和 invalidate/dispose；
页面继续获取目标/epoch/SQLite、核对来源和应用结果。success 与 error 共用一次接受判定，
旧 ticket 的 finally 不得清理新 ticket。已显示窗口、错误提示和 retry 仍由页面 owning path 管理。
先提交测试与接口边界，再迁移原有全部读取接点，不把整页/Cubit/Repository 传给模块。

## E026 — 完整读取接点迁移与新增审查缺口

父契约提交：`7072ceb5f15a4179f143e01502b066ec439e8af4`。
迁移 loading/dirty/read owner/loading target 到 `DurablePreviewReadLifecycle`；
每次操作用独有 ticket，success/error 共用同一接受入口，finally 仅退休自身 owner。
原 start/restart、identity canonicalization、didUpdateWidget、session_created/attachment 与 dispose
接到同一 invalidate/dispose。已显示窗口和提示继续在页面，原 Service/Repository/Cubit 未改。

`c1-lifecycle-related`：140 tests PASS，exit 0，41.125 秒；含十个 SQL 页面、七个 lifecycle、
原所有相关同步回归和四个黑盒。该收据在补显式 mounted lint guard 前；后续全量覆盖最终 guard。
`c1-lifecycle-mounted-analyze`：本批六个 Dart 文件 0 error/warning，仅屏幕三条既有 localization info。
`c1-lifecycle-format`：六文件 0 changed。初版共享 guard 引起六条 async-context info，
已用 UI 出口显式 mounted 检查解决，失败前的诊断收据保留。

此处只是可回退的结构 checkpoint，尚未作最终候选。
root 与独立 review 另确认现存的 P2 source-return stale preview：
A-next 已提交，A 的 read 因切到 B 被丢弃；跟进读又被 source fence 阻止且 dirty 被消费，
A 再认证时“已加载 A”快捷路径不检查遗漏工作。接下来用独立 red/fix 提交闭合，
不把它描述为纯迁移的一部分，不借用 140 PASS 盖过新失败。

## E027 — 返回原来源的 pending read 红灯

产品结构保持 E026 不变。新增 success/error 两种 read barrier：
先显示 A-initial，提交 A-next，暂停原读；认证 B、释放旧结果，确保无旧 Snackbar；
然后 A 重新认证，仅给出权威 runtime list，不重放已提交正文。
SQL 已是 next，但原页面无法显示 A-next。
`c1-red-return-to-source-compiled`：0 PASS / 2 FAIL，exit 1，在等待新正文处超时，
证明 finally 消耗 dirty、随后 source fence 阻止重读、已加载分区快捷判断共同漏掉 pending 工作。
首个 `c1-red-return-to-source` 为 SessionInfo 必填字段未齐的测试编译 FAIL，保留且不计产品 red。

修法限定：dirty 工作只在实际开始下一次读或显式 invalidate 时消费；
同来源再认证的加载快捷判断须看是否仍有 deferred read。继续保留 source fence 和 last-good，
不增加 epoch/revision 的第二写入者，不用每次 catalog 更新强制查询来掩盖问题。

## E028 — deferred read 恢复与被动绑定保护

父 red：`174842d46c87a369ee42c45c86939553d92abc61`；结构依赖 E026
`99e86306b9c3792d2354885af96b2211f0eac660`。
`finish` 退休 owner 但保留 dirty，直到下一次 `begin` 或 invalidate；
页面已加载目标的快捷判断同时检查 `needsRead`。身份 fence、epoch、last-good 和读出的 snapshot
语义均保留，没有通知总线、轮询或 cache epoch 的第二个写入者。

`c1-deferred-reread-green`：52 PASS，含两个 source-return red 转绿、八个生命周期和既有 durable。
`c1-passive-runtime-read-compiled`：13 个真实 SQL 页面 tests PASS；新增被动 runtime 绑定的正向保护。
被动绑定只改变 runtime receipt/control/overlay，durable 页面仍为 detachedPreview，
runtime 订阅丢弃完整历史帧；SQLite reader 须能导入冷窗口并继续接收原 commit 更新。
独立 review 据此撤回“被动绑定应取消 reader”的假设，未机械应用显式 attachment 的取消逻辑。
首个 `c1-passive-runtime-read` 为测试 getter 名称准备错误导致 compile FAIL，保留而不记产品红灯。

独立只读 review 在当前工作树未发现其他 P0–P2；source-return 的本地 fix 已逐行复核，
将以本提交固定身份再复核，并运行 clean 全量门禁。仅给新增常量 SessionInfo 补 const，
不改变测试场景/断言。当前仍未宣称 C1a 整体门禁完成。

## E029 — C1a 最终源码门禁与接手记录

最终验证源码：`151c04752e0ce00568c73a6d9522bfe09c6a107c`；全部最终检查启动时 clean。
本批十三个真实 SQLite/原页面用例、八个纯生命周期用例均纳入全量；
原四个真实 Bridge/RPC/SQLite/页面黑盒继续通过，最上游仍为隔离 Provider fixture。
只读 GPT-6 Luna/max reviewer 在固定提交重新审核，确认 source-return P2 关闭、
无剩余 P0–P2 actionable finding；未运行测试或操作设备，测试证据由 root 执行。

| 检查 / 原始收据 | 精确结果与证明范围 |
|---|---|
| `c1-final-full-mobile.json/.log` | 151c0475 clean；3300 PASS / 4 SKIPPED，exit 0，440.892 秒；明确使用 --concurrency=1 |
| `c1-final-full-analyze.json/.log` | 151c0475 clean；exit 0，24.517 秒；0 error/warning，1017 info |
| `c1-final-analysis-baseline-comparison.json` | 与 B2 最终诊断按 severity/file/完整 text 比对，保留重复数量、忽略迁移行列；1017→1017，无新增/减少 |
| `c1-final-format.json/.log` | 本批六个 Dart 文件，0 changed，exit 0，0.807 秒 |
| `c1-independent-review.md` | 固定 151c0475 的只读复审 PASS；此前 P2 已关闭，无剩余 P0–P2；来源绑定的反证与保护用例留档 |
| `c1-bridge-gate-inheritance.json` | 67fbef1a 与 151c0475 的 Bridge tree 都为 2bcc606909b9eb34470eafe264045186a6c1f2b9；Bridge/依赖输入无变化 |
| B2 build/noEmit/全 Bridge 收据 | 因上述输入相同而继承 PASS；2546 PASS / 1 SKIPPED，124 files PASS；并非本批重复运行 |
| `c1-original-checkouts.json` | main 7de33f81 与原七组未跟踪资料保留；旧修复分支 930f1267 clean；均与起点相同 |
| `c1-final-acceptance.json` | 接手文档提交后的最终 HEAD/status、与 151c0475 的产品/测试/依赖输入相同检查、收据/日志 hash 与分层验收 |

原始收据、失败日志和轨迹都保存在
`/Users/developer/AI agent/Codex/_tmp/ccpocket-sync-chain-20261001/`；
最终黑盒轨迹为 `c1-final-full-traces/`，含 RPC/Bridge/client 帧、SQL hash 与原页面断言。
本条所在接手提交只更新文档；完整 SHA 由 `git log -1` 和最终 acceptance 收据获取，
不改变已验证产品/测试输入，不为纯文档更新重复运行全量。

四个 Mobile SKIPPED 仍为 SSH private key 两项、Bridge tunnel 一项、jump host 一项，
均 smoke env not set，不计作 PASS；Bridge 一项真实链 smoke 未 opt in。
原生 Dart/Marionette UI 自动化工具本轮不可用，为 BLOCKED；
真实 Provider、原 Simulator/真机、生产 Bridge、OTA、签名安装、云 CI、merge/push/发布均 NOT_RUN。
VM mounted 页面中的真实 SQL/Service 契约不能替代这些验收。

### 已关闭与仍未知的事实

- E023 的旧来源读错误晚到在原页面稳定 red；E024 补 source fence，最终共用 success/error 判定继续保护。
- E027 的 source A 返回后漏掉已提交 A-next 在 success/error 两个用例稳定 red；E028 保留 deferred dirty，
  仅实际 begin/invalidate 消费，同分区快捷入口核对 needsRead，最终原页面显示 SQL 新内容。
- 被动权威 runtime 绑定不停止 durable reader；cold read 与后续 commit 的正向保护通过，
  reviewer 撤回取消 reader 的假设，canonical 写入权仍在 SQL 路径。
- E024 的并发组合 full-page 折叠等待 FAIL 未归属。单独重放、140 项串行相关及最终串行全量 PASS，
  不足以宣称并发问题已修复；默认并发/云 CI NOT_RUN。R29 与 C1B-ENTRY 保留后续定位入口。

### C1a 提交与依赖索引

| 批次 | 完整提交 SHA | 用途 / 当前判断 |
|---|---|---|
| E022 | 83169884338d229273f979e7e67c0f970a7632d3 | 读取接点盘点与范围；基线 38c4240e clean |
| E023 | 5d69872d87b7d42984032848814127e7e6b029e4 | 六个真实 SQL 页面契约，旧来源 error 红灯；不可作运行候选 |
| E024 | 722e753f4ee422f336e658ad2560ecfb1d0df686 | 独立 source error fence 行为修复；组合折叠等待失败单独留档 |
| E025 | 7072ceb5f15a4179f143e01502b066ec439e8af4 | 扩至十个 SQL 契约，冻结生命周期接口与权威边界 |
| E026 | 99e86306b9c3792d2354885af96b2211f0eac660 | 完整读取接点迁移；仍有后来定位的 source-return 缺口，不作最终候选 |
| E027 | 174842d46c87a369ee42c45c86939553d92abc61 | success/error 的 source-return 两个红灯；不可作运行候选 |
| E028 | 151c04752e0ce00568c73a6d9522bfe09c6a107c | deferred read 修复与 passive runtime 保护；C1a 最终验证源码点 |

E028 依赖 E026 的接口，结构回退须在隔离 checkout 适配该行为，保留 E024 来源错误检查、
十三个 SQL 页面与八个 lifecycle 保护，不得直接 revert 中间提交后删除回归。
回退的所有读取、来源与清理接点详见 RUNBOOK/PREVIEW-READ-LIFECYCLE。

下一批按 C1B-ENTRY 先验证 V2 detached 的已有 `projectDetachedTimeline` 与 Cubit 接缝，
独立登记父 SHA、状态接受/清理契约和红灯，不新造 reducer 或把共享 legacy/paged mirror 一同重写。
C1b 目前只有源码盘点与入口文档，不借本批 PASS 宣称该范围的缺口已闭合。

## E030 — C1b 起点与 canonical 候选接受接缝

起点：`96d77007e8ddb4a1c8adc4dc8487d18534812c02`，独立 worktree clean；
日期 2026-10-02（Asia/Taipei），原产品/测试输入仍与 C1a 验证点 `151c0475` 相同。
继续使用同一隔离分支；main、旧修复 checkout、设备和生产服务不在本批操作范围。
完整读 HANDOFF/CLAUDE 及相关 decisions 后，按 C1B-ENTRY 选定一个 V2 detached history 接缝。

实际链路：`updateDetachedPreviewHistory` → 原 handler 的 HistoryMessage → `_applyUpdate` →
`_mergeHistoryWithPreservedLiveEntries` 的 V2 detached 分支 → 原 `projectDetachedTimeline`。
纯投影已存在；shared legacy/paged mirror weaving 和 SQLite/wire 不在本批重写。
当前重复 canonical 检查在合并分支中返回 last-good entries；是否仍应用候选的设置/交互等状态，
须用原 Cubit 契约确认，不能只凭条目列表测试宣布候选拒绝完整。
History 本身不会进入 `_recordOutgoingDraftEvidence` 的清理 case，不能臆断它会直接删除 draft。

本批 root 拥有诊断、测试、产品实现、整合和验证。原 GPT-6 Luna/max worker 只读盘点既有
原 Cubit、纯投影、SQL 页面测试的实际覆盖，使用 native mailbox，不改文件或跑服务。
允许生产改动仅限 Cubit 的 V2 detached candidate/admission 接缝及原投影模块；
新增窄模块须先证明它真正独占职责，不增加 reducer、writer、总线或整个 Cubit/Page 依赖。
相关测试由原 Cubit/draft/runtime overlay 入口与真实 SQL 页面观察提供，不能手工注入正确状态。

证据顺序：登记范围 → 重放选定原入口基线 → 新契约；若有红灯则独立行为 fix；
行为冻结后再收拢选定职责，完成 Mobile 全量 analyze/tests、固定 SHA 独立 review，更新回退与矩阵。
C1a 同输入全量收据只作基线；C1b 新产品行为须有自己的最终门禁。
E024 并发折叠等待仍未归属，保留原断言和输入/SQL/Cubit/layout 轨迹，不延长等待或删除断言。
当前本条登记时产品未变，C1b 新契约/门禁尚未运行。

## E031 — duplicate canonical 的原 Cubit 红灯

父范围提交：`a8a5508b66f41e016f6b5aafe16f6bab78795ee2`，产品代码未改。
`c1b-baseline-preview-projection.json/.log`：clean 起点 331 PASS，exit 0，68.202 秒；
覆盖原 Cubit/投影/durable/十三个 SQL 页面/layout 与四个真实 Bridge 接收/页面黑盒，串行执行。

新增 `detached_canonical_commit_test.dart`，仅调用原 `updateDetachedPreviewHistory`、
原 draft 存储/恢复和公共观察值，复用原 mock Bridge 宿主；不手工 emit 正确状态，也不修改 SQL。
原 Cubit 层的受控 History 输入与真实 SQL/Bridge 黑盒证明范围分别保留。
`c1b-red-canonical-admission`：2 PASS / 3 FAIL，exit 1，2.779 秒。
重复 canonical 已被原 guard 拒绝、last-good assistant 顺序仍在，但实际仍发生：
projectPath 变为 /rejected-project、出现 rejected candidate 的 PermissionApproval、已显示 queue 被清空。
原有 duplicate 用例只检查条目/诊断，没有覆盖候选的其他状态接受。
draft/本地 outgoing ID 在拒绝时保留，合法 exact commit 才消费；不同 client ID 的同正文不能清理他人 draft，
两项正向保护 PASS，未将它们描述为新缺陷。

再补 paging availability 用例：拒绝的候选不应通过 hasEarlier=false 关闭仍有效的历史入口；
独立 `c1b-red-canonical-paging` 红灯收据与实际信号保留。
本 checkpoint 不是可用候选。修复限定为 V2 detached durable history 的整体接受判断前移，
在应用分页/设置/交互/投递等状态前判定候选有效；legacy empty 继续保留原语义。
先独立行为修复，随后才将 prepare/admission 与应用阶段分清，沿用原纯投影 reducer。

## E032 — 候选有效性先于分页与状态应用

父 red checkpoint：`96242441210bdf8d6daeda2321ce44339ae70182`。
独立 paging red 为 0 PASS / 1 FAIL，exit 1，3.518 秒：原 hasMore=true 被拒绝候选的 false 提前覆盖。
修复在原 `updateDetachedPreviewHistory` 解码后、`_applyUpdate` 和 paging availability 之前，
使用已有纯投影的 exact alias 检查；重复 canonical 只记录拒绝诊断并返回。
legacy empty 仍更新原分页观察并保留 last-good；没有变更 wire、SQL、源身份或 runtime control 入口。

`c1b-admission-green`：305 PASS，exit 0，25.125 秒；包含六个新原 Cubit 用例、
全部原 Cubit、十三个真实 SQL 页面、durable 与纯投影保护。四个确定性红灯均转绿。
该提交只作为行为修复 checkpoint；成功候选目前先做 admission、再进入原合并，
存在临时的两次纯投影计算。下一步在同一既有模块中准备不可变候选，原路径只应用同一结果，
完整迁移 acceptance 接点，避免另造 reducer/状态总线。设计见 DETACHED-CANONICAL-ADMISSION。
完整黑盒、全量 Mobile analyze/tests 与固定 SHA 独立复审仍待最终结构实现后执行。

## E033 — 同一 canonical 候选的 prepare / admission / compose

行为父提交：`b22c8a8cad39af376578be246d9bac58ba2cf4bd`。
结构只改原 `detached_timeline_projection.dart` 与 Cubit 接缝：
原 canonical alias 扫描抽为 `prepareDetachedCanonicalHistory`，不可变 candidate 保存原 canonical
输入、canonical 工作基线/索引、duplicate 判定及仅来源于原输入的 client receipt 证据。
现有 `projectDetachedTimeline` API 仍由相同 canonical pass + 原 overlay pass 组成，不增加 reducer。

public durable history 在应用前 admission；合法 candidate 经 _applyUpdate 原 V2 merge 传入。
runtime 归属/过滤仍先由原 owning path 执行，再 compose 当前 overlays；没有提前缓存旧 overlay。
每次 compose 使用工作副本，原 candidate 与其他投影结果不被修改。draft/aliases 只在接受后消费，
不把 overlay enrichment 后获得的 client ID 当作 canonical receipt。
其他 merge 调用者的就地准备、legacy empty、shared weaving、SQLite/wire 和 source authority 未移走。

`c1b-prepared-admission-related`：351 PASS，exit 0，32.976 秒；含六个原 Cubit、新四个纯 candidate、
原 Cubit/local-history paging/十三个 SQL 页面/durable/投影/layout；本次未重复跑四个黑盒，最终全量会覆盖。
`c1b-prepared-target-analyze`：0 error/warning，但 18 info 中有八条新 private constructor 样式提示（四条各重复一次）；
没有把它们当既有 info。改为 private positional initializing formals，语义/输入/断言不变，
相关 `c1b-candidate-constructor-style-related` 十一个用例 PASS；最终全量诊断继续逐项比对基线。
只读 inventory worker 未完成初始化，没有调查产出；root 完成上述原入口盘点和实施，未等待它代替 root 判断。

本结构 checkpoint 等待固定 SHA 独立复审与最终全量 Mobile 门禁；尚不计作 C1b 最终完成。
回退结构须保留 E032 的整体 admission 和四个红灯保护；candidate 接口的后续依赖按逆序处理。

## E034 — 独立复审暴露 History 解码的提示副作用

固定结构 SHA：`60e0c0dcfa98e3e72ed0be163b07cc9210aa5b53`，门禁启动时 clean。
`c1b-final-full-mobile`：3310 PASS / 4 SKIPPED，exit 0，439.991 秒，--concurrency=1；
`c1b-final-full-analyze`：0 error/warning、1017 info；`c1b-final-format`：四文件 0 changed。
这些收据保留，但不能覆盖独立复审指出的缺口，也不是本批最终可接受源码点。

GPT-6 Luna/max 对 `96d77007..60e0c0dc` 固定差异只读复审，确认原四项状态接受修复、
canonical-only prepare / 后置 overlay compose 和 raw canonical receipt 来源成立。
残余 P2：public history 在 admission 前调用共享 handler；History 中的
`SystemMessage(subtype: tip, tipCode: git_not_available)` 会提前设置 `_gitTipShown`。
含 duplicate canonical 的 History 被拒绝后，提示没有进入界面，但后续有效 Git error 会被抑制。
这是原 handler 的真实解码副作用，不能把 E033 的“应用前拒绝”当作解码本身无副作用。

root 增加两个原 Cubit/public history/原 scoped error stream 用例，不注入 handler 私有状态。
`c1b-red-history-handler-tip`：1 PASS / 1 FAIL，exit 1，2.982 秒；
拒绝后有效 error 丢失稳定 FAIL，已接受提示后拒绝仍保留原去重语义的正向保护 PASS。
生产代码此时仍为固定 SHA；该测试 checkpoint 不作为运行候选。

修复范围据实际 owner 扩到 `chat_message_handler.dart` 的 History 解码/确认接点：
只读准备不得记录“已显示”；共享 handler 仅在合法 candidate 实际应用后确认历史提示。
原 live system / 其他 handle(History) 调用者保持兼容，已有 streaming 状态不复制、替换或重置。
先独立修复并重放 handler/Cubit/投影/SQL 相关保护，再冻结新 SHA 做全量与同一 reviewer 复核。

## E035 — History 准备只读，合法应用后确认提示

父 red checkpoint：`6b103406935ec797cbcd28470092a826dffd7b17`。
原 handler 新增 `prepareHistory`，沿用原 History 解码逻辑，但内部 system 解码不记录 Git tip；
`commitPreparedHistory` 只确认实际接受历史中的提示。普通 `handle(History)` 仍准备后立即确认，
live system 默认仍确认，不改变旧调用者入口。已有共享 handler 与 streaming/thinking 状态不替换或重置。
V2 detached public history 先只读准备、canonical admission，再走原分页/_applyUpdate；
成功应用后确认提示。拒绝路径不改变 handler 状态，已有合法 tip 的去重不会被后续拒绝清空。

增加三个 handler 保护：准备阶段不抑制 error、确认后抑制；普通 History 和 live system 的原语义保留。
两项原 Cubit Git tip 顺序、原四项 red、draft/身份正向保护均转绿。
`c1b-history-handler-tip-green`：447 PASS / 1 FAIL，exit 1，27.540 秒；
唯一 FAIL 是 root 命令使用不存在的 `test/local_history_paging_test.dart` 的加载失败，
不是断言失败。原日志保留；实际文件为 `chat_session_local_history_paging_test.dart`。
`c1b-history-handler-paging-path-corrected`：15 PASS，exit 0，2.834 秒，产品/测试 diff 身份相同。
两份收据共同覆盖九个实际文件，不能把前一份 exit 1 改写为单次 462 PASS。
`c1b-history-handler-target-analyze`：0 error/warning、十条原 Cubit 初始化 info，exit 0，15.043 秒。

原 60e0c0dc 的全量 PASS 与复审 P2 均作为中间证据保留；本提交重新冻结完整生产/测试输入，
全量 Mobile analyze/tests、格式与同一独立 reviewer 的修复复核仍须按新 SHA 执行。
结构回退须保留 E032 的整体状态 admission 和本条提示修复，不能将准备/应用后确认两端拆开回退。

## E036 — 全量可见性失败与跨层完成信号观测

产品固定 SHA：`2f64e383cc42776385ec22420d7ec299792bb9c9`。
同一 GPT-6 Luna/max 固定 SHA 复核确认 Git tip P2 关闭、旧调用者语义与 streaming/thinking 对象保留，
无剩余可证明 P0–P2；独立源码审查不代替运行门禁。
`c1b-tipfix-final-full-analyze`：exit 0，18.095 秒，0 error/warning、1017 info；
完整 severity/file/全部诊断正文（含续行，重复计数保留，忽略行列）与 C1a 比对，added/removed 均为空。
`c1b-tipfix-final-format`：六文件 0 changed，exit 0，0.615 秒。

`c1b-tipfix-final-full-mobile`：3314 PASS / 4 SKIPPED / 1 FAIL，exit 1，343.322 秒。
唯一 FAIL：原 full-page 的 assistant-live-segment-b 等待一份可见 Second live commentary 超时；
不是 E024 的 complete intermediate fold 阶段。新十五项 admission/candidate/handler 保护均通过。
`c1b-tipfix-full-page-replay`：相同 clean 产品输入单独原用例 1 PASS，9.028 秒，不能覆盖全量失败。

root 只给原黑盒增加失败/成功诊断快照，保留输入、断言、等待与原页面；
`c1b-full-page-observation-group`：三文件五个用例 4 PASS / 1 FAIL，exit 1，26.603 秒。
SQL 与原 Cubit 已有 A/B 的正确 ID、顺序、hash/正文，页面仍流式累积为 A+B，
runtime overlay event count=0。两条已提交消息被放入 collapsed intermediate，而 transient 仍在。
独立只读成功/失败 Bridge trace 对照：B canonical payload 相同，成功先有 runtime_overlay，失败没有。
结论只缩小到完成信号路径，未确定生成条件/authority/订阅/队列哪个接点导致漏发。

再给原隔离 fixture 增加只读 runtime adapter 观测，另存 runtime-overlay-origin.jsonl，
原 provider-message 格式不变。没有注入状态或改生产 dispatch，也没有保证观测成本对时序无影响。
`c1b-full-page-origin-observation`：三个原 full-page 用例 3 PASS，13.004 秒；
`c1b-origin-observation-group`：三文件五个用例 5 PASS，19.052 秒。
两次 PASS 都不是行为修复；R35 未关闭。观测测试 analyze：0 issues，exit 0，25.118 秒。
先前用“四个黑盒”描述不同接收链路的条目不作为精确用例计数；本三文件实际为五个用例。

本 checkpoint 只提交测试/fixture 观测与事实文档，产品源码仍为 2f64e383。
不会把 runtime 正文改作 canonical writer，也不会用删除断言或延长等待获得通过。
下一步见 RUNTIME-ITEM-BOUNDARY：先明确产生/发送/丢弃条件并建立确定性 red，再决定行为修复；
后续 runtime 隔离队列结构批暂不实施。新观测输入按新固定 SHA 另跑最终检查，不继承旧全量绿灯。

## E037 — canonical admission 固定输入门禁与焦点差异

生产源码保持 `2f64e383cc42776385ec22420d7ec299792bb9c9`；
完整测试/fixture 输入固定为 `d0f164e54fd3c076c3940f21a75e05f1e2a00792`，以下各门禁启动时 clean。
原始 JSON/log 仍在 `/Users/developer/AI agent/Codex/_tmp/ccpocket-sync-chain-20261001/`，不覆盖旧失败。

| 收据 label | 结果 | 退出码 / 时长 |
|---|---|---|
| c1b-observation-final-bridge-build | Bridge build PASS，未替换运行服务 | 0 / 4.894 秒 |
| c1b-observation-final-full-mobile | 3315 PASS / 4 SKIPPED，串行全量，原五个黑盒与十五项新保护均通过 | 0 / 399.411 秒 |
| c1b-observation-final-full-bridge | 2546 PASS / 1 SKIPPED，124 files PASS / 1 SKIPPED | 0 / 24.375 秒 |
| c1b-observation-final-full-analyze | 0 error/warning，1017 info；完整正文含续行与重复计数比对基线 added/removed 为空 | 0 / 36.018 秒 |
| c1b-observation-final-format | 七个本批 Dart 文件，0 changed | 0 / 1.042 秒 |
| c1b-observation-final-bridge-typecheck | noEmit PASS，在 Bridge 全量后执行 | 0 / 4.430 秒 |

`c1b-observation-final-analysis-comparison.json` 保存完整诊断比对；
产品固定 SHA 的复审见 `c1b-independent-review-2f64e383.json`。
同一 GPT-6 Luna/max 对 d0 相对产品 SHA 的两个观测文件另做有界只读复核：
原断言、15 秒期限、segment 输入/路由不变，失败诊断不覆盖原异常，无生产源码改动或额外写入。
局限：UI 与 SQL 快照跨 await，非原子；origin 在生产 listener 之前采样，不能代替实际资格判定，
增加回调执行成本也可能影响后续交错。因此此 PASS 不能关闭 R35。

root 继续对照两次 FAIL 与两次全量 PASS 的原始 client/Bridge 帧，发现更具体的关联：
FAIL 的初始 subscribe 均没有 focused，随后无 focus 请求，失败 diagnostic 却已记录客户端焦点；
PASS 的初始 subscribe 均带 focused，收到 A/B runtime_overlay。canonical B payload 仍一致。
Bridge 的 focusedKey 过滤是原授权边界，不能放宽；待验证 owner 缩到 Mobile Service 的
subscribe 已发出、syncBegin 尚未接受时改变焦点，是否遗漏确认后的补发。
对照文件为 `c1b-runtime-overlay-focus-comparison.json`；这一步没有修改产品，也未宣称归因完成。

更新 README、PLAN、CHAIN-MAP、TEST-MATRIX、C1B-ENTRY、RUNBOOK 与完成信号入口，
使当前产品/测试身份、已完成职责、保留失败、回退依赖与下一步一致。
下一步先在原 Service/真实 SQL 测试建立可控焦点 red，再决定窄行为修复；暂不扩大 runtime 结构。
真实 Provider/设备/生产 Bridge/云 CI/OTA/发布 NOT_RUN；原生 UI 自动化工具缺失为 BLOCKED。

## E038 — 订阅发出后至接受前的焦点遗漏 red

父文档 checkpoint：`5c438e5f05a8727e8a2a1db55e6134939d90689c`，产品仍与 2f64e383 相同。
root 与独立只读调查分别核对原 Service：setFocusedConversation 更新本地焦点后，
active subscription 为空时只尝试 ensureSubscribed；pending ID 阻止重复订阅。
V2 syncBegin / V1 subscribed 接受后没有比较已发送 subscribe 的焦点与最新本地意图。
所以发送之后、接受之前的变化被保留在本地，却没有任何 focus frame；发送之前的变化则会进首帧。
Bridge 的 focusedKey 过滤仍是正确授权边界，不是待放宽对象。

新增 `subscription_focus_admission_test.dart`，经原 Service、原 gateway 测试 helper 与真实 FFI SQLite。
不注入私有订阅状态；通过 outgoing subscribe 与 incoming begin/subscribed 控制顺序。
V1/V2 各覆盖最新焦点、清除、返回原焦点、普通 active 行为、旧订阅、dispose、补发错误；
V2 另覆盖 source 拒绝与缓存读取前改变焦点。共十六项，原断言均有可观察 wire/订阅状态依据。

`c1b-red-pending-subscription-focus`：0 PASS / 1 加载 FAIL，exit 1，4.637 秒；
root 新测试有 FFI options 与 diagnosticSnapshot 两处签名误用，未形成行为 red，日志保留。
修正签名，不改产品或测试预期。
`c1b-red-pending-subscription-focus-signatures-corrected`：7 PASS / 9 行为 FAIL，exit 1，5.619 秒。
最新焦点、清焦点、替换订阅的当前焦点、catch-up send error 在 V1/V2 均 FAIL；V2 正确 source 接受后补发也 FAIL。
返回原焦点、既有 active/dedup、dispose、发送前变化均 PASS，明确缺口位于 send→accept 窗口。

这证明原 owning path 的补发缺陷，且与两次 R35 wire 差异一致；原页面的确定性交错与修复后重放仍待完成。
允许产品修改限 Service 的 subscribe 实际发送快照、接受时对齐、原 focus 发送及失效清理；
协议模型、Bridge 授权、SQL writer、页面 reader/布局不变。V1 同 owner/同缺口一起窄修，保留旧消息类型。
补发必须属于当前 generation/request/source/target，只发送最新意图（含 null），同首帧焦点不重复发；
失败沿原 transport loss 清理，不能确认失败 transport 或让旧订阅消费新意图。
先独立行为 green 与相关 Service/页面回归，再固定新 SHA 全量检查和独立 review。
本 red checkpoint 不作为运行候选；不继续 runtime 队列结构抽取。

## E039 — 仅在当前订阅接受时补发最新焦点

父 red checkpoint：`b95f735205da0ad8571b3db710a67c8a14baf4e1`。
产品只改原 Service：实际发送 V1/V2 subscribe 时保存焦点快照，绑定 generation/request/target/
Bridge/source 与协议类型；匹配接受后、第一次 await 之前，比较当前焦点并仅在不同时补发。
使用原 V1 content-focus / V2 sync-focus 分支和原 transport loss 出口，不放宽 Bridge 授权或更换 writer。
clear/切换/返回首帧焦点均按最新意图；snapshot 在接受、stop/transport loss、发送/读取错误、
V1 subscribe error 处退休，不由旧接受消费。补发失败不继续 notify/SQL bootstrap/ACK。
原 active focus 的去重、mark-read、自动修复仍走既有 owning path。

原十六项均转绿：`c1b-green-pending-subscription-focus`，16 PASS，exit 0，3.513 秒。
再保护 send-error 后可重新订阅且携带当前焦点、V1 无 pending request 的 late subscribed 被忽略；
不对 nullable event request 作无条件断言。当前新文件共十七项。
`c1b-pending-focus-related`：七文件 157 PASS，exit 0，23.795 秒；
`c1b-pending-focus-target-analyze`：0 error/warning、两条既有 use_null_aware_elements info，21.159 秒。
root 盘点全部 pending ID 清理接点，补 V1 error 的快照清理；
`c1b-pending-focus-error-cleanup`：原 Service 与新文件 91 PASS，exit 0，6.358 秒。

尚未提交的 fixture/原页面扩展提供首个 syncBegin 的 FIFO 闸门及实际 client subscribe/focus 查询。
首次固定页面交错 `c1b-fixed-pending-focus-page-first`：1 PASS，exit 0，14.810 秒。
实际 subscribe 无焦点，确认帧尚未送达时原页面已设置焦点；释放后只发送一个匹配 focus，
原 A/B/最终消息可见性、fold、重读、离开返回、离线/重连及乱序/丢帧保护全部通过。
这份收据是 fixed 产品加未提交 fixture 输入，不能作 clean 最终门禁。
下一步保存恢复点，仅换回旧 Service 用同一 fixture/页面/断言形成确定性 red，然后恢复修复，
再提交 fixture、固定新 SHA 全量检查与独立复核。观测不代替行为因果证明。
本提交只保存 Service/十七项测试与过程，不顺带提交尚待 red 敏感性验证的 fixture。

## E040 — 相同原页面输入证明 R35 的行为因果

修复产品提交：`ce51e28027087e5fe4d4d79533390203ae3735a8`。
fixture-only 扩展在连接前启用首个 syncBegin 闸门，暂存其及同订阅后续 V2 原始帧，显式 FIFO 释放。
队列上限 128；原普通 drop/reorder/replay 与 callback 行为保留。控制查询来自已捕获的 client raw frames，
不造订阅、sequence、focus、authority、Provider 消息或页面状态。
原 full-page 注册普通/held 两种输入；普通场景沿用全部原断言，新增场景仅固定前置交错并核对一条补发。
原 15 秒可见性/内容/fold 断言不改；黑盒现在三个文件共六个用例。

先记录修复输入 `c1b-fixed-pending-focus-page-first` 的 1 PASS（14.810 秒）。
再将唯一产品文件 Service 换成 b95f7352 中的原内容，其他页面/fixture/Bridge 输入保留，
`c1b-red-pending-focus-real-page`：0 PASS / 1 FAIL，exit 1，21.023 秒。
FAIL 精确为原 assistant-live-segment-b 的 Second live commentary 独立可见性；
SQL/Cubit 有正确 user/A/B，UI 仍 transient A+B，runtime overlay event count=0，客户端没有 focus frame。
这与 E036 两次失败的症状及 wire 焦点差异一致，不再仅凭成功重放或静态推断归因。
修复输入有且仅有一个匹配订阅的 focus；A/B/最终可见、fold 与后续全部原页面恢复保护 PASS。

两个轨迹均 hold/release 七帧，subscription/sequence/sha256 列表逐项相同，确认按原字节/顺序释放。
对照另存 `c1b-pending-focus-real-page-causal-comparison.json`。
source swap 使用 commit 内容核对和独立备份，finally 已恢复与 ce51e280 完全一致的修复 Service；
`c1b-pending-focus-real-page-service-swap.json` 记录两个 SHA256、backup、退出码与 restored=true。
这是隔离 checkout 的敏感性验证，未部署/替换任何运行服务。
恢复后的 `c1b-pending-focus-restored-blackbox`：三个文件六个用例 PASS，exit 0，24.768 秒。
同一 GPT-6 Luna/max 对 b95..ce51 固定产品/十七项测试只读复核，无可证明 P0–P2；
快照与 payload、首次 await 前补发、协议/fence/清理、原 active/refresh/readmark/repair 均成立。
SQL 未开始的性质由早退顺序证明；新错误测试直接约束 transport 清理与无 ACK。

新增控制/原页面场景与过程作为独立测试 checkpoint；随后固定 clean 新 SHA 执行
Mobile/Bridge 全量、诊断比对、格式与观测 fixture 的独立 review。
R35 在此选定窗口有确定性 red/green 因果，真实 Provider/设备与其他运行交错仍不借用该结论。
旧 R29 的并发 complete-fold 等待仍未归属，不把它与 R35 合并关闭。
回退 Service 行为保留十七项回归与 held-page red；回退 fixture 不能移除原五个黑盒/断言。

## E041 — 焦点修复与完整输入的最终源码门禁

产品冻结 `ce51e28027087e5fe4d4d79533390203ae3735a8`；
测试/fixture 输入固定 `adf337ea5f2ddddf3639da4e37b020435033b1d1`。
以下所有检查启动时 HEAD 为 adf337ea、status 为空、tracked diff SHA256 为 empty hash。
原始 JSON/log 在 `/Users/developer/AI agent/Codex/_tmp/ccpocket-sync-chain-20261001/`，旧失败未覆盖。

| 收据 label | 结果 | 退出码 / 时长 |
|---|---|---|
| c1b-focus-final-bridge-build | Bridge build PASS；仅隔离 checkout 的 dist | 0 / 4.140 秒 |
| c1b-focus-final-full-mobile | 3333 PASS / 4 SKIPPED，--concurrency=1；十五项 canonical、十七项焦点及六个黑盒均通过 | 0 / 329.085 秒 |
| c1b-focus-final-full-bridge | 2546 PASS / 1 SKIPPED，124 files PASS / 1 SKIPPED | 0 / 18.925 秒 |
| c1b-focus-final-full-analyze | 0 error/warning，1017 info；完整正文/续行/重复计数与 C1a 基线一致 | 0 / 21.175 秒 |
| c1b-focus-final-format | 本批九个 Dart 文件，0 changed | 0 / 0.674 秒 |
| c1b-focus-final-bridge-typecheck | noEmit PASS，Bridge 全量完成后执行 | 0 / 3.065 秒 |

`c1b-focus-final-analysis-comparison.json`：added/removed 均为空，保留完整文本而非只比诊断代号。
全量 trace 中普通/held 两个完整页面场景均从 A/B/final、fold 到离开返回、重开/重连、旧订阅、
乱序/丢帧恢复与真实 RPC 断言 PASS；held 场景另记录 pending 焦点和唯一补发。
Bridge 全量与 typecheck 使用显式 Node 22.23.1；build 的宿主 Node 26.4.0 / npm 11.17.0。
Flutter/Dart 身份与 RUNBOOK 一致；不将本机混合工具链声称为 Linux CI 验收。

独立原生 GPT-6 Luna/max 只读复核分别固定：

- b95f7352..ce51e280：唯一产品文件 Service 与十七项新契约，未发现可证明 P0–P2。
  快照与 subscribe payload、首次 await 前补发、当前身份/协议 fence、失效和发送错误出口均一致。
  原 active focus、manual refresh、readmark 与 repair 保留。SQL 未开始由 early-return 顺序支持；
  send-error 测试直接证明 transport 清理与无 ACK，没有额外 SQL spy。
- ce51e280..adf337ea：三处 fixture/原页面测试，无可证明 P0–P2。
  检查真实 client 前置条件、同订阅 raw FIFO、128 帧显式上限、普通故障控制与全部原断言。
  Flutter 用例本身没有 SHA 对照；root 已在 E040 外部 trace 对照证明七帧原字节/顺序。
  原完整页面外层修改前后均 120 秒，partial/older 均 60 秒，内部等待均 15 秒，无期限变更。

独立结果分别保存 `c1b-independent-review-ce51e280.json`、
`c1b-independent-review-adf337ea-fixture.json`；复核者未运行测试/服务或修改文件。
root 核对语义 diff、固定身份与实际完整收据，负责最终集成与质量判断。
R35 只关闭已证明的 pending focus 交错，不扩大为所有完成信号正确；R29 独立保留。
真实 Provider/模拟器/真机/生产部署/云 CI/OTA/发布 NOT_RUN，原生 UI 自动化无可调用工具为 BLOCKED。

### 本轮提交索引与回退关系

| 账本 | 提交 | 用途 / 回退约束 |
|---|---|---|
| E037 | 5c438e5f05a8727e8a2a1db55e6134939d90689c | 前 canonical/观测输入门禁文档，非 R35 行为修复 |
| E038 | b95f735205da0ad8571b3db710a67c8a14baf4e1 | 焦点 red checkpoint，产品未改；不作运行候选 |
| E039 | ce51e28027087e5fe4d4d79533390203ae3735a8 | Service 窄行为修复与十七项保护；回退保留 red 敏感性 |
| E040 | adf337ea5f2ddddf3639da4e37b020435033b1d1 | held 原页面/fixture；普通五用例及全部期限保留 |

canonical 的 E032 admission 与 E035 提示确认不得随焦点回退丢弃，candidate 结构依赖仍按前文处理。
实际 revert 先核对工作树，在隔离 checkout 适配并重跑；不操作共享分支或运行服务。
E041/E042 随后仅更新接手文档；最终文档 HEAD、clean 状态及与 adf337ea 非文档输入一致性
另保存在 `c1b-focus-final-acceptance.json`，不改写此前 `c1b-final-acceptance.json`。

## E042 — R29 旧证据清点与当前默认并发有限重放

旧 E024 收据 `c1-source-error-fence-green`：HEAD 5d69872d、未提交 source-error fence 输入，
四文件默认并发组合 41 PASS / 1 FAIL，exit 1，28.092 秒。
旧单独 `c1-error-fence-full-page-isolated`：1 PASS，12.030 秒，不关闭组合失败。
原 trace 的 A/B/final 可见性均 PASS，FAIL 精确为 final-outside-collapsed-process 的完整过程折叠等待。
实际初始 subscribe 已带目标 focused；wire 有 A/B/final 三个 runtime_overlay，sequence 27/59/76。
它没有 R35 的缺少 wire focus 观察；帧存在也不能单独证明 Service/Cubit 接受或布局正确。
旧 FAIL 快照只含 sync，无后加的 SQL/Cubit/disclosure 快照，因此尚不足以归因。

root 没改源码或断言，在 clean adf337ea 用原四个文件名组合、不指定 --concurrency 重跑：
`c1b-r29-default-concurrency-probe`，50 PASS，exit 0，17.398 秒。
比旧输入多 C1a 契约及 held 页面，源码/fixture 亦已变化；这只证明当前有限重放，
不是旧 SHA 敏感性 red/green，也不代表完整默认并发或云 CI 已验收。
原 FAIL 继续列 R29 FAIL，不反复重跑至绿，不把它归为偶发/负载或 R35 同因。

旧 receipt/有序 stages、实际 subscribe/overlay 与四个 trace 文件 SHA 保存
`c1b-r29-historical-evidence-inventory.json`。下一批具体允许范围、缺少事实、命令、
停止扩大条件见 [R29-FOLD-ENTRY](R29-FOLD-ENTRY.md)。
先记录原接收路径是否接受完成/idle 与 turn identity、stream 状态和布局计数，再形成确定性 red；
在正确结果或取消归属尚不明确时不迁移 runtime queue。

## E043 — C1c 收尾状态交错的范围与 red 契约

起点 clean `aa1b185d71e5e94da89c4242edf53372d5be56de`。
按 R29 入口核对原 owning path：layout 的 active 同时读取 process status、external turn 与 isStreaming。
正常 current runtime 的 `_detachedVisualTurnValidationPending` 为 false；接受当前 idle 时只更新状态，
stream 清理只存在于绑定/source 待验证分支，可能留下使布局持续 active 的 transient。
这是待行为验证的明确接点，不宣称旧 E024 根因已经确定。

允许改动：新 `detached_terminal_streaming_test.dart`、原 full-page 的受控 consumer 交错与诊断；
若 red 证实，仅原 Cubit 的 current terminal 接受/已有 visual 清理接点及对应文档。
Bridge 协议/产品、Service fence/SQL writer、C1a reader、layout 算法与原断言/期限保留。
不迁移 runtime pending queue，也不以终态身份不明的消息取得清理权。

public Cubit 正向契约：当前来源的较新 idle 应退休旧流式输出；合法 canonical final 在 idle 前/后到达，
均呈现 A/B 两个 intermediate、final 在外，晚到旧完成不重新取得权威或复制 canonical。
保护 working/partial、旧时间、其他 provider/thread、旧 attachment authority 与同 turn 重绑继续输出。
随后在原页面只延迟实际 Service 最终 runtime_overlay 的 consumer delivery，保留 FIFO 与原 frame，
让真实状态/SQL 路径先到；原 final/fold 与所有恢复断言仍须通过。
红灯、行为修复、敏感性恢复、固定 SHA 门禁与独立复核逐项记录；旧 R29 未有最终 UI 证据仍保留未知。

实际 red（产品未改，HEAD aa1b185d + 明确测试/文档 diff）：

| 收据 | 结果 | 退出码 / 时长 |
|---|---|---|
| c1c-terminal-status-unit-red | 七项 public Cubit 契约：5 PASS / 2 行为 FAIL，分别为 canonical 在当前 idle 前/后到达；非编译失败 | 1 / 3.285 秒 |
| c1c-terminal-status-page-red | 新受控原页面用例在原 final-outside-collapsed-process 断言 FAIL：missing complete intermediate fold | 1 / 24.350 秒 |

真实页面 trace：`c1c-terminal-status-page-red-traces/2026-10-02T11-41-44.803Z-ae66d373-live-segments/`。
held 的原最终完成帧 sequence 69 已由 Service 接受；gate 只延迟 consumer，不阻塞 SQL/status。
terminal-before-completion 和失败快照均为 chatStatus idle、external=false、activeTurnId=null、
visualTurnValidationPending=false，而 streaming=true / text=Final answer。
SQL 与 Cubit 同为四行 user/A/B/final、稳定 ID/顺序/hash 正确；页面 disclosure active=true、
transient=true、intermediate indices=[1,2,3]，渲染 Current progress / Live / 3 updates。
因此这个受控窗口的故障归属到原 Cubit 接受终态后未退休 transient；不改 layout 取得 green。
原始 receipt/log/trace 以及 `c1c-terminal-status-red-evidence.json` 均独立保存，历史 E024 仍未因果关闭。

只读 GPT-6 Luna/max 复核 Bridge→Service：ordinary status 路径可先于经过异步 FIFO/SQL 的 V2 overlay。
旧 FAIL 与当前 PASS 均是 final assistant→result→普通 idle，final overlay 分别在普通 idle 后约 83ms/3.7ms 提交；
两者的 authority/turn 语义相同，没有丢帧证据。时间差不能直接归因；本 gate 固定合法交错，
没有制造消息/权威/焦点或旁路原 Service fence。

## E044 — 当前终态只在原 Cubit 退休 transient

red checkpoint：`4dfa2e0558db5e61bc226e16e338c54fa7b17998`。
唯一产品改动为 `ChatSessionCubit.updateDetachedProviderStatus` 的原终态接受接点：
在 provider/thread、合法时间/旧时间/重复签名与 rejected attachment authority 检查后，
仅 nextStatus=idle 调用已有 `_clearDetachedVisualTimeline`；其余状态继续原 visual turn 验证。
没有根据 ordinary idle 旁路 committed V2 status，也未扩大 SQL/canonical/控制权。
原 cleanup 清理 StreamingStateCubit、transient entry、desktop continuity 与 pending visual 状态，
保留 durable canonical；原 overlay authority/turn 清理与晚到旧帧拒绝继续运行。

固定 red checkpoint、仅上述产品 diff：
`c1c-terminal-status-unit-green`，7 PASS，exit 0，3.344 秒；
`c1c-terminal-status-page-green`，原页面受控 completion 场景 1 PASS，exit 0，13.496 秒。
内部 15 秒、完整页面外层 120 秒与原 final/count/展开/恢复断言均未改。
受控 terminal-before-completion 快照 idle / streaming=false、intermediate=[1,2]、final index=3；
release 同一真实 final event 后仍保持上述折叠，canonical 四行无重复。
随后 edit、展开、离开返回、离线、重开/重连、旧订阅、乱序/丢帧和原 RPC 检查均 PASS。
`c1c-terminal-status-initial-comparison.json` 对照 red/green 的 canonical 稳定 ID/顺序/hash 与 Cubit 行相同。

此处只证明 R37 窄窗口；当前全量/独立复核/同冻结输入旧 Cubit 敏感性尚待下一条登记。
历史 R29 仍没有失败瞬间布局事实，不随本修复关闭；运行链/设备/生产状态不变。

## E045 — 全量暴露 bootstrap 边界与 alias 清理顺序

E044 产品 `6c0ac738c8f44c4fb4eda2e4074aae47bc8eda91`；
观测安全输入 `dcf0b0865479d3569251b35d7f7f3176ca1c9879` 只把未 mount 时的 streaming snapshot 记 null，
防止诊断自身抛异常，未改原断言。固定该输入、只暂换旧 Cubit 后：
`c1c-terminal-status-old-cubit-sensitive` 在原 fold 再次行为 FAIL，exit 1，21.278 秒；
finally 以外部 backup 恢复修复源 SHA256 `6cc6340a125d2fc4fea2046bcc0ddc929c2ecc03f6b73d4f34b104a4497dc834`，
status 为空；恢复记录 `c1c-terminal-cubit-sensitivity-restore.json`。

随后在 clean dcf0b086 完整检查，未在运行期间改源码或测试：
`c1c-terminal-final-full-mobile`，3340 PASS / 4 SKIPPED / 1 FAIL，exit 1，386.831 秒。
FAIL 为原 live receiver 的 line 564：A completion 预期 ID=[A]，实际为空；
它位于 await committed/mountPreview 之前，不是 SQLite 恢复后的断言。
原 `emitSegment` 等待 sawStreaming 后 streaming=false，把此变化当 completion 到达。
真实 trace `c1c-terminal-final-full-mobile-traces/2026-10-02T11-50-59.082Z-fbb88f9c-live-segments/`：
bootstrap idle seq9 / observedAt 11:50:59.416Z；后续 working seq21、A overlay seq22 / .471Z。
raw delta 可先于旧 bootstrap status 的异步读投影；此时尚未确认 activeTurnId，无条件 idle 清流会提前结算该边界。
不放宽原 receiver 断言/等待，不以再次跑绿将这轮 FAIL 当偶发。
同输入 analyze 0 error/warning、1017 info 完整文本及重复计数与 E041 相同，21.277 秒；
三个本批 Dart 文件格式 0 changed，0.621 秒。此静态 PASS 不覆盖全量 FAIL。

root 与独立 GPT-6 Luna/max 均确认另一个 P2：未入 SQL 的 runtime assistant completion 用 alias 标记为 overlay；
先 visual reset 清 alias、再 runtime filter 会使该行失去临时身份并滞留。
因此补两项 public 行为，而非用私有 spy：bootstrap 未确认 active turn 不清新输出，
以及终态过滤未 commit completion、后续同 ID canonical 恰好一次接受。
`c1c-terminal-boundaries-unit-red`：7 PASS / 2 行为 FAIL，exit 1，3.372 秒，产品仍为 E044。
E044 不作验收候选；下一步在原状态接点限定已确认 turn，并先过滤 runtime overlay 后 reset visual。
缺少 turn ID 的路径维持原验证/完成逻辑，不凭 ordinary state.status 推断 committed V2 活跃证据。

## E046 — 收紧已确认 turn 的终态与先 filter 后 reset

父 red `82f0426c1723e1ce42eb60efa3c47571b1b633ae`。
唯一产品文件仍为原 Cubit；没有增加另一份 last-active 状态。
当前 status 通过原所有 fence 后，先按 runtime generation/authority/turn 过滤 overlay，
在 assistant alias 还完整时完成分类；随后仅 idle 且此前已确认 activeTurnId 时退休 visual。
其他情况继续原 `_validateDetachedVisualTurn`，包括重绑/source 待验证、缺 turn ID 与 legacy。
`state.status` 也能由 ordinary lane 更新，因此不能用它代替 committed V2 turn 证据。
这不是对所有无 ID 终态作新保证；它们保持既有完成消息/验证行为，仍需单独定义未来契约。

固定父输入、仅上述 Cubit diff：

| 收据 | 实际结果 | 退出码 / 时长 |
|---|---|---|
| c1c-terminal-boundaries-unit-green | 九项 public 契约 PASS；bootstrap 与未入库 completion 两个 red 转绿，其余旧时间/身份/同 turn 连续输出保留 | 0 / 3.164 秒 |
| c1c-terminal-boundaries-blackbox-green | 原三文件七用例 PASS，含之前失败的 receiver、三个 complete 页面、partial-summary 与 older-pages | 0 / 32.780 秒 |

原 receiver 源码未改，A/B/final、SQLite 重开、runtime 退休与实际 updater 的断言全部恢复通过；
完整页面三个交错的所有原 fold/count/展开/故障恢复/真实 RPC 断言保留。
新终态场景在 final consumer 尚 held 时已 idle/streaming=false/fold2，release 同一 event 后仍成立。
Bridge source/fixture、Service/SQLite/reader/layout、本批 dependency 与 deadline 均未改变。
接着冻结新 SHA 运行受影响 Mobile 全量、完整诊断文本比对、格式与独立最终复核；
E045 的完整 FAIL 与两项 red 保留，不把分项 PASS 冒充完整验收。

## E047 — 不把旧 active turn 当作新 raw delta 的归属

E046 冻结产品 `29da56707a01f15497fae31c8c0eb07ac396f3ff`。
独立 reviewer 提出上一轮 idle 经 SQL 延迟期间下一轮 raw delta 先到的候选；root 核对实际 wire，
StreamDelta/ThinkingDelta 没有 turn ID，Mobile 解码亦仅保留 text，旧 activeTurnId 无法证明当前 transient 属于它。
不修改 Bridge 协议，也不把旧 ID 直接包装成新的“归属模块”。

补 public 入站序列：T1 working/完成、原 socket idle、随后 running/新 delta、再接纳延迟的 T1 idle；
下次 T2 working/socket idle/committed idle 则应正常结束。另用 fake clock 固定 50ms 合并发布窗口，
新 delta 已进入 pending 但尚未呈现时，旧终态也不能丢它。
现有两项单 turn 正向契约补原 socket idle 接点，与真实页面的入站链一致；断言未减弱。

- `c1c-terminal-next-delta-red`：9 PASS / 1 行为 FAIL，exit 1，3.150 秒。
- `c1c-terminal-buffered-next-delta-red`：9 PASS / 2 行为 FAIL，exit 1，2.367 秒；非编译或 fake-clock 失败。

这是受控 public 双 lane 行为证据，尚不是两个真实 Provider turn 的设备/Bridge 回放。
计划窄修：StreamingStateCubit 独占增量接受 revision，append 时即推进（包括 pending thinking/text），
reset 使旧标记失效；原 Cubit 只在 socket idle 接点记录有界 terminal visual ticket，
含 runtime generation/source/stream revision。较晚 committed idle 仍须原 authority/time/provider/turn fence，
只有 ticket 未被后续增量/重绑/source/reset 改变才取得新增清流资格。
ticket 是防止过期清理的证据，不取得任何 canonical、控制或订阅权；无 ticket/无 turn 保持原完成/validate。
行为修改与新输入分开提交；随后固定源跑全量与独立 review，继续保留历史 R29 未知。

## E048 — 终态清理绑定未变化的 socket 输出

父 red：`9ffd89845c9a693f1200212d9e4fa550581e0ff1`。产品范围为原 Cubit 与 StreamingStateCubit。
StreamingStateCubit 独占 inputRevision，text/thinking 在 append 接受时推进，包含尚未 flush 的增量；
reset 也推进。不另存流正文、不更改发布节奏或公开 StreamingState。
原 Cubit 在经过既有 external desktop guard 的 socket idle 接点记一份有界 ticket：
runtime generation、source fingerprint、stream revision。后续 committed idle 仍先通过原所有身份、
authority、时间和重复检查；先按 alias 过滤 runtime overlay，再核对已确认 activeTurnId 与未变化 ticket。
较新增量、reset、source 或 binding 变化使旧清理失效；ordinary idle 只提供顺序条件，不取得 Provider 权威。
缺少 ticket/turn 的路径仍用原 completion/visual validation，不扩张无 ID 终态的保证。

本轮失败也保留：首次 patch 把 capture 插到相似的 `_setExternalDesktopRunning` 接点，msg 未定义。
`c1c-terminal-ticket-unit-green` 实为编译 FAIL（1.751 秒）；其后误启动的
`c1c-terminal-ticket-blackbox-green` 也是三文件加载 FAIL（7.014 秒）。名称 green 不代表结果。
修正到 `_onMessage` 后，`c1c-terminal-ticket-corrected-unit-green` 为 10 PASS / 1 行为 FAIL，2.321 秒：
bootstrap 测试的后续正向终态缺真实 socket idle。补该接点与 pump，保留原结束输出断言；
前段未确认 turn 的新输出保留断言未改。未改 receiver/page 的等待或断言。

固定父输入加上述三文件 diff（SHA256 `4103b5ef0f8693492a26d214a2b4c2826cfeac28400b22feebeeff21d7200953`）：

| 收据 | 实际结果 | 退出码 / 时长 |
|---|---|---|
| c1c-terminal-ticket-socket-unit-green | 11 项 public 契约 PASS，含下一轮 raw delta、50ms 内未发布 delta 与下次正常终态 | 0 / 1.964 秒 |
| c1c-terminal-ticket-corrected-blackbox-green | 原三文件七项真实 Bridge→SQLite→页面/receiver PASS；原 receiver 源码未改 | 0 / 32.198 秒 |

本记录与产品一起冻结后，运行完整 Mobile、analyze、格式与固定 SHA 独立复核。
这仍不是两轮真实 Provider/设备验收，也不证明每一种 pending runtime overlay 交错。
队列职责与容量、取消、未来 authority 的契约在下一份入口文档梳理；不趁此修复直接迁移队列。
E044/E046 的较宽清理方案及全量 FAIL 均保留，历史 R29 仍未归因。

## E049 — 全量保留失败并证明 turn ID 缺失的终态窗口

E048 产品与输入冻结为 `095cab004e394dcef418f05dc76cbd91df42090c`；检查开始时 clean，运行期间未编辑。
`c1c-ticket-final-full-mobile`：3344 PASS / 4 SKIPPED / 1 FAIL，exit 1，388.062 秒。
失败为原 complete pending-focus 页的 final-outside-collapsed-process，不是新增 fixture 的断言。
trace `c1c-ticket-final-full-mobile-traces/2026-10-02T12-26-08.690Z-25183291-live-segments/`：
A/B/final 可见性与 pending-focus catch-up PASS；SQL/Cubit 四行稳定 ID/顺序/hash 正确；
idle、external=false、activeTurnId=null、validationPending=false，但 streaming=true / Final answer，fold=[1,2,3]。
最终 overlay sequence81 在 wire 存在，原 consumer 记 quarantine 后 rejected，终态 sequence84/96；
原失败缺少 ticket revision/匹配接点事实，不能仅凭 wire 顺序断言原因。
`c1c-ticket-full-failure-evidence.json` 保存所选事实与原 trace SHA，不覆盖旧 R29。

同 clean 输入 analyze exit0 / 20.163 秒，0 error/warning、1017 info；
完整诊断文本及重复计数与 E041 相同（原始行号变化单独保留），见 `c1c-ticket-final-analysis-comparison.json`。
四文件 format 0 changed / 0.643 秒。
独立 GPT-6 Luna/max 当时只读固定 SHA 未见可证明 P0–P2；该结论不覆盖新出现的全量 FAIL，候选不获验收。
Bridge tree、root package/lock 与 Mobile pubspec/lock 同 adf337ea，继承 E041 Bridge 门禁，
对象核对见 `c1c-ticket-final-bridge-input-identity.json`；无新的部署或运行证明。

随后仅加只读诊断：current input revision、ticket revision/匹配快照；
socket capture / terminal admission、provider status 暂缺、overlay quarantine 匹配条件及流操作类型日志，
不记正文或凭证，不改控制、队列、SQL或等待。
`c1c-terminal-ticket-admission-observation` 原单个 pending-focus 页 PASS / 11.258 秒；
`c1c-terminal-ticket-full-page-observation` 原五页 PASS / 25.732 秒。
这些不是旧 fullQA 输入；晚到完成可令 revision7→9 并正常清流，因此 ticket mismatch 本身并非失败。
外部桌面 idle guard 被初步排除；全量那次 quarantine 的具体直接触发仍缺同步 admission 事实，保留未知。

源码核对发现另一明确契约缺口：Provider projection 可以暂缺，或合法 working 不带 turn ID；
二者原本就撤销 activeTurnId，但不代表 socket 正文消失。普通 idle 之后的当前权威 idle 应能退休该流，
不能让一个曾用于控制权限的 turn ID 成为清流的唯一前提。
补两项 public 入站契约，在相同 generation/source、无后续增量的 socket idle 后，分别注入
turnless working 或暂缺 projection，再接受合法 bridgeRuntime idle。ordinary idle 自身仍不清流；
新 delta/旧时间/错误身份/旧 binding 的原十一项保护不改。
`c1c-terminal-turnless-socket-red`：11 PASS / 2 行为 FAIL，exit1，3.196 秒。
这是新确定性缺口，尚不把它冒充上次全量或历史 R29 的完整因果解释。
下一步用当前 Bridge 权威 lease 与未变化 socket ticket 约束清流，替代仅依赖旧 activeTurnId；
增加无权威/外部 host 的反向保护，先分项，再冻结源验原七黑盒与全量。

## E050 — socket 顺序条件必须和当前 Bridge 权威同时成立

E049 诊断与两项 red 输入冻结 `2bc616050e55dbcd3dcc9f5f77ce5f1ab372d621`。
在原十一项和 turnless/暂缺两项之外，补三种反向输入：缺 authorityGeneration、desktopAppServer host、
appServer evidence source。三者即使在 socket idle 后到达，也不能凭旧 activeTurnId 获得新的清流资格。
`c1c-terminal-socket-authority-red`：11 PASS / 5 行为 FAIL，exit1，2.845 秒（按原始收据校正时长）。
此时产品仍是 095cab00 的行为，只有 E049 只读观测；五个失败均发生在 streaming 保留/退休断言。
接下来限定 source=bridgeRuntime、host=bridge、loaded attachment、当前 source/binding 的 authority lease，
再核对原 ticket/input revision。这样不靠已被暂缺/turnless 投影清掉的控制 turn ID，
也不把普通 idle 顺序证据误当作 Provider 权威。原 source/time/provider/rejected-authority fence 不变。
E049 用于追踪的高频流操作与暂缺日志将移除；保留只读 revision/ticket 快照和终态/quarantine 原接点事实。

## E051 — 当前 Bridge lease 与流顺序共同限定清理

红灯输入 `2d5c0a272da98f3140b5caa2138bd18822af0634`。仅修改原 Cubit 的终态资格：
idle、bridgeRuntime source、bridge host、loaded attachment、当前 source/binding authority lease、
未变化的 socket ticket 必须同时成立。暂缺/turnless 不再凭旧控制 turn ID 阻塞合法清流。
保留原 admission/time/rejected authority、runtime alias 先过滤、ordinary external guard 与 pending visual validation；
current lease 只是被原状态投影建立的事实，ticket 不新建 lease，也没有 canonical/control 写权。
没有修改 Service、Bridge、SQL、reader、handler、layout 或两个原 receiver。
移除 E049 高频暂缺/每条流操作诊断，保留原接点的只读 revision/ticket、quarantine 匹配和 hasActiveTurn 事实。

同 red 输入加唯一产品 diff 与 E050 时长校正（diff SHA256 `05591add239e83999684c635d78b2a2883725e5330bee87c7557ca6e1ed75cd4`）：

| 收据 | 实际结果 | 退出码 / 时长 |
|---|---|---|
| c1c-terminal-socket-authority-green | 十六项 public 契约 PASS，五项 red 转绿，旧十一项仍通过 | 0 / 2.750 秒 |
| c1c-terminal-authority-blackbox-green | 原三文件七个黑盒 PASS，含 pending-focus 与 held-final 全部原fold/恢复/RPC断言 | 0 / 31.019 秒 |

`c1c-terminal-authority-page-comparison.json`：held-final 在 Service 接受后延迟到原 consumer，
terminal-before-completion / 原 fold / release 后均 streaming=false、intermediate=[1,2]、final index3。
同一 event 的 sequence/subscription/origin/runtime/authority/turn/time 未变化；
canonical ID/顺序/hash 和四行内容与 E043 red 相同。没有 refresh、重建或改期限来取得通过。
095cab00 全量 FAIL 的直接路径与历史 R29 仍不作因果关闭；分项通过不是完整验收。
接着冻结这版 SHA，完整 Mobile/analyze/format 与固定 SHA 独立复核；队列入口先写职责与未覆盖契约。

## E052 — 全量通过后仍以独立复核补 runtime 归属契约

E051 产品与输入固定 `89084bcbf71b64b90c9af30a1c2848b4a536281e`，检查开始 clean、期间没有编辑。
`c1c-authority-final-full-mobile`：3350 PASS / 4 SKIPPED，exit0，341.244 秒。
`c1c-authority-final-full-analyze`：exit0，16.814 秒，0 error/warning、1017既有info；
完整诊断文本及重复计数逐项同E041，`c1c-authority-final-analysis-comparison.json`新增/消除均空。
`c1c-authority-final-format`：四文件0 changed，0.577 秒。
`c1c-authority-final-input-identity.json`证明 Bridge/deps/两个原receiver未变，继承E041 Bridge门禁。

固定SHA只读GPT-6 Luna/max复核没有P0/P1，指出一项新增清流的P2：
A→B→C连续重绑，B的authority未曾被Cubit观察，旧rejected槽只记A；
同source B缓存随后被重读，并被原接点标成C的local generation。
若重绑时无visual，因此validationPending=false，C新正文/socket idle后B的idle可误清C流。
Root核对status模型无runtimeSessionId，updater/catalog没有可排除此顺序的runtime身份事实。
这不是旧mutation接纳机制的新引入，也不能倒因果解释095cab00全量或历史R29。

先补public输入，不改产品：B缓存在C socket idle前/后两种交错，以及旧Bridge缺字段的反向保护；
后续C匹配状态通过原路径终态的正向断言保留。使用wire JSON输入，未知字段在旧模型被忽略，
故red不是因新增成员无法编译。Bridge现有formal-overlay用例新增真实runtime身份断言；
Dart protocol新增持久JSON round trip和旧版/长度/类型约束。

| 收据 | 真实结果 | 退出码 / 时长 |
|---|---|---|
| c1c-runtime-status-identity-unit-red | 原16 PASS / 新3行为FAIL | 1 / 2.935秒 |
| c1c-runtime-status-identity-bridge-red | 命令目录错误，未找到根node_modules/vitest；不是行为证据 | 1 / 0.123秒 |
| c1c-runtime-status-identity-bridge-red-corrected | producer缺runtimeSessionId，1行为FAIL / 185按筛选跳过 | 1 / 1.009秒 |
| c1c-runtime-status-identity-protocol-red | 18 PASS / JSON身份丢失1行为FAIL | 1 / 1.794秒 |

所以89084bcb测试门禁PASS但复核不予验收；不能因全量绿灯直接搬队列。
方案与兼容/回退关系见RUNTIME-STATUS-IDENTITY.md。新增可选身份由Bridge已有bridgeSessionId提供，
Cubit的新清理核对当前bound runtime；旧Bridge保留原阅读/completion/validation。
这批改变Bridge源码后必须重新build及验Bridge完整门禁，不再继承E041。

## E053 — 用远端 attachment 身份限定新增终态清理

red输入 `ac4d72fc10081f37dada742e1dd38b6261d487fb`。
Bridge statusFromRuntime把已有snapshot.bridgeSessionId写入可选runtimeSessionId；
Provider/shared-control/失效转换剥离旧身份，身份本身不加入hasExplicitRuntimeAuthority。
Dart可选字段验证/序列化保留身份，无SQL列或schema迁移。Cubit签名包含runtime身份，
同时间身份变化不能被旧duplicate guard吞掉；新terminal分支必须精确匹配当前bound runtime。
原控制lease接纳机制、RPC、source/time/turn/authority与visual pending接点不在本批重写。

新增正向保护：相同observedAt只有runtime身份改变仍可被接纳；
实际SQLite同时间替换身份并close/reopen后，list/single status读取都保留当前runtime与authority。
Bridge原runtime生命周期测试核对replacement/reopened两种身份，watchdog失败撤权后不保留旧runtime ID。

冻结red父输入加七文件产品/测试diff，SHA256 `0ea27cc8b00381301ef5e30e1aaebb440ff3ff11b8c61c35d936457fec85e4c5`：

| 收据 | 结果 | 退出码 / 时长 |
|---|---|---|
| c1c-runtime-status-identity-mobile-focused | 初始十九项terminal与十九项protocol共38 PASS | 0 / 3.020秒 |
| c1c-runtime-status-identity-mobile-contracts | 二十项terminal、protocol与真实SQLite相关共103 PASS | 0 / 7.981秒 |
| c1c-runtime-status-identity-bridge-contracts | conversation-sync-v2整文件186 PASS | 0 / 18.145秒 |
| c1c-runtime-status-identity-build | 新Bridge tsc/native helper build通过；host Node26/npm11 | 0 / 5.769秒 |
| c1c-runtime-status-identity-blackbox | 原三文件七黑盒PASS；使用新dist及Node22 | 0 / 30.863秒 |

原两个receiver、原page fold/期限/恢复/RPC断言不改；held-final在实际新status身份经解码/SQL/updater后成立。
完整Bridge/Mobile及最终固定SHA复核留待本轮候选冻结，不能把分项写成已完成验收。
下一批只梳理隔离queue的容量、byte退休与future turn交错；先公开契约，确定缺陷后独立修，再搬单一owner。
同源旧status可能误建原控制lease的既有风险独立记录，当前视觉修复没有证明mutation全链正确。

## E054 — 隔离队列的公开容量/退休契约与未来 turn 丢失

父输入 `1ee3820736d4f7b27c1ad8caa8efa5537013289a`，产品没有改变。
新增detached_runtime_overlay_queue_test.dart，以正式runtime overlay stream/status公开接点输入，
对外部稳定ID/正文顺序、独立UTF-8规范化消息预算、既有只读diagnostic观察做断言；不spy私有方法。

九项容量/退休保护PASS：32/33条、duplicate不占预算、不淘汰已排消息；
含中文的精确65536 bytes、单条65537 bytes；stale删除后byte归零/新owner可用；
accepted event重放、runtime/source/suspend三种失效、close后迟到。canonical user始终保留。
另两项在原代码行为FAIL：同一source/runtime/authority下T2 overlay先于Cubit的T2 status进入隔离队列，
此前T1已经有visible overlay。直接T2 working或先T1 terminal再T2 working，退休T1 tracking时
_resetDetachedRuntimeOverlayTracking无条件清pending，T2合法payload因此丢失。
T2 event observedAt晚于T1 terminal，不属于已证明过期；没有制造authority或绕过runtime envelope fence。
这是public双lane契约，尚非真实两轮Provider/设备时序回放。

- c1d-runtime-queue-contracts-red：0 PASS / 11 FAIL，2.844秒。Root测试误读diagnostic顶层，
  实际指标在timelineProjection内；这是fixture错误，不作为产品red。
- 修正层级、不改产品/正文/边界断言后，c1d-runtime-queue-contracts-red-corrected：
  9 PASS / 2行为FAIL，exit1，2.035秒；diff SHA256 `4cc5ab1bfec23a58de17f252990cb9afde8446acd04bf9a1b573fdae4c6bbe95`。

接下来只分开“退休已呈现T1 tracking”与“作废整个pending owner”。
同runtime/generation/authority的turn退休保留pending，随后原flush匹配当前turn或按时间拒绝；
runtime/source/suspend/close及不匹配authority仍使用原完整清理。先窄修green，再单独迁移queue map/bytes。
不搬visual pending、不改变256/257策略或两个queue的预算/去重边界。

## E055 — 退休可见turn时不作废下一轮隔离消息

red checkpoint `4b59aee7b6e9b31753a1846ff83514dd499c1816`。
产品只改原Cubit清理参数：_resetDetachedRuntimeOverlayTracking/_clearDetachedRuntimeOverlay
默认仍退休pending；在已核对相同generation/runtime/authority后，仅turn退出/替换保留pending，
随后原flush以当前turn/时间决定apply或reject。没有新增admission、write或控制权。
补两项反向保护：authority替换仍退休旧pending；turn终态仍删除已证明旧的隔离消息/bytes。

- c1d-runtime-queue-retirement-green：原十一项queue、二十项terminal与原Cubit共284 PASS，14.113秒。
- 增加反向输入后 c1d-runtime-queue-retirement-boundaries：十三项queue与上述原契约共286 PASS，14.681秒。
- c1d-runtime-queue-retirement-blackbox：原三文件七黑盒PASS，31.403秒。
  两次后者输入diff SHA256 `a20692208746a5cdec4f525143ed3b900026737df39dda6fa083a7c671f236b4`。

源/重绑/suspend/close、authority失效与visible trim保持原完整清理；两项future turn red转green。
当前只关闭选定同authority的公开契约，future authority/真实两轮Provider仍没有被这些fixture证明。
结构迁移另提交：RuntimeOverlayQuarantine独占map/bytes，原Cubit保留所有envelope/time/control/reconcile/apply。

## E056 — 不把保留的未知 activity 当作新终态证据

queue修复父输入 `c3fcab964ae94c99223b3a5aa7bb5c20a6940d7a`。
Root核对statusFromRuntime：controlState为reconciling/blocked/unavailable时保留previous.activity，
confidence明确降为unknown。因此即使runtime身份相符，也不能让这份保留idle取得新清流资格。
原lease getter不检查confidence；新增公开反向输入只在原socket idle之后接受该unknown快照，
应保留正文；随后当前authoritative idle仍应结束。visual validation pending=false，隔离原validator。

`c1c-terminal-confidence-red`：20 PASS / 1行为FAIL，2.849秒。
进一步使controlState=unavailable，与实际producer的未知状态组合一致；
`c1c-terminal-confidence-unavailable-red`仍20 PASS / 1行为FAIL，1.816秒；原收据保留。
产品尚未修改。窄修只给C1c新增分支加入confidence=authoritative，不重写原status呈现或控制lease。

## E057 — 新清理只接受已证明的终态

red checkpoint `ad94066c5176c9ebfec6081e55debf59d403f785`。
仅在C1c新增terminal分支要求confidence=authoritative。Bridge未知/reconciling/blocked/unavailable
仍通过原status呈现/visual validation，不获得这条新增清流资格。其他身份/ticket/revision条件不变。
`c1c-terminal-confidence-green`：二十一项terminal与十三项queue共34 PASS，退出0，2.526秒。
接着只做已保护quarantine map/bytes的结构迁移；不把未知控制lease或visual overflow包装成正确策略。

## E058 — 隔离队列只拥有一个map与一份byte统计

结构父输入 `16529517d54a5071442953e732775b9780f4d183`，行为修复已在E055/E057独立提交。
新增runtime_overlay_quarantine.dart：RuntimeOverlayQuarantine只持有insertion-order map与bytes，
提供contains/add/remove/clear及固定FIFO snapshot；add区分accepted/duplicate/capacityRejected，
超限拒绝新事件而不淘汰旧事件。原规范化预算编码仍由Cubit唯一计算，不另序列化正文。
原map/private record/bytes已删除，不保留第二份状态；diagnostic读新owner。

原Cubit仍负责provider/thread/source/runtime/origin/authority/turn/time admission、
accepted-ID去重、visible rows/aliases、flush remove-before-apply、turn退休和所有取消出口。
helper没有Bridge/Service/Repository/Cubit/Page或callback，不建立状态投影或RPC/SQL写入权。
visual pending、stream buffers与visible overlay独立，不并入helper。

`c1d-runtime-queue-extraction-contracts`：原相同五文件public/JSON/SQLite契约370 PASS，
exit0，17.559秒；diff SHA256 `30d2aae9ed3ff088f68d334e0bae92d5430c4c247334161956a728c8261a5497`。
此结构批没有修改上一批消息、数量/UTF-8预算、身份/拒绝策略或deadline。
接下来冻结source/test/doc输入，完整Mobile/Bridge、analyze/typecheck/format与固定SHA独立复核。
最终全量含原七黑盒；期间不再编辑产品或测试，失败如实保留后才改变下一输入。
