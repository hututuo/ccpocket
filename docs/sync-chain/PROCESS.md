# 过程账本

## 当前断点

- 时间：2026-10-01（Asia/Taipei）。
- 分支：`codex/sync-chain-extraction-20261001`。
- 起始 SHA：`930f1267e949c6cf2095761cc71c43cca08c6dc3`。
- 阶段：A0–A3 / B1 已完成；用户再次要求继续，开始 B2 older-turn 分页生命周期。
- 最终验证源码 SHA：`45a4498a75d2649021b286eee0ea37f54ef86253`；随后仅补文档，不冒充重新验证过业务源码。
- 当前批：B2 请求契约/失败用例；具体状态与验收见 PAGING-LIFECYCLE，E011 尚无业务修改。
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

后续接手：先核对分支/status 与最终源码身份，读 PLAN 的 B2 入口，再新建账本批次。
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
