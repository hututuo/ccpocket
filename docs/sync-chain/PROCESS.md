# 过程账本

## 当前断点

- 时间：2026-10-02（Asia/Taipei）。
- 分支：`codex/sync-chain-extraction-20261001`。
- 起始 SHA：`930f1267e949c6cf2095761cc71c43cca08c6dc3`。
- 阶段：A0–A3 / B1、B2 与 C1a 已完成；C1b 已开始原 V2 detached 投影接受/清理契约盘点，见 E030。
- C1a 最终验证源码 SHA：`151c04752e0ce00568c73a6d9522bfe09c6a107c`，全量启动时 clean。
- 3300 Mobile PASS / 4 SKIPPED（--concurrency=1）；Bridge 同输入继承 2546 PASS / 1 SKIPPED。
- analyze 0 error/warning，1017 既有 info 逐项无新增；固定 SHA 独立复审无剩余 P0–P2。
- 最新门禁/回退依赖见 E029，责任见 PREVIEW-READ-LIFECYCLE，下一步见 C1B-ENTRY。
- E024 的历史并发折叠等待 FAIL 尚未归属；最终串行 PASS 不证明默认并发或设备/运行链验收。
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
