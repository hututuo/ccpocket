# CC Pocket 综合修复执行日志（2026-07-26）

> 依据：`reviews/ccpocket-full-code-review-and-plan_v2_20260726.md`（主规划）
> + `reviews/raw-agent-reports/`（一手取证，动手前逐模块核对）。
>
> 基线：worktree `mobile-comprehensive-remediation-20260725`，分支
> `fix/mobile-comprehensive-v02-20260726`，起始 HEAD `20382de6`。
>
> 用户确认的范围与取舍（2026-07-26 会话）：
> - **跳过批次 0 的行为收紧项**（SEC-2 权限上限、auto-approval 收紧、上传门禁、
>   API key 自动生成等）——部署在 Tailscale 虚拟局域网内，用户明确不做认证类收紧，
>   避免旧版客户端兼容问题。
> - **保留零兼容代价的 SEC-1 第一步**（拒绝带 Origin 的握手，封死浏览器 drive-by，
>   原生 App 不发 Origin 不受影响）。
> - 执行顺序：SEC-1 一行防护 → 批次 1（进程稳定性）→ 批次 2（数据正确性）→
>   预览链路（P0-18 / P0-19，P0-19 采用"失败也回退 WebView"语义）。
> - P0-17（预览修复随新 IPA 发布）属发布动作，需用户单独授权，本轮不动。
>
> 每项一个内聚 commit，可独立回滚；不 push、不合并、不部署。

## 进度总览

| # | 条目 | 层 | 状态 | Commit |
|---|---|---|---|---|
| 1 | SEC-1 拒绝带 Origin 的 WS 握手 | Bridge | ✅ 完成 | `4ab464f4` |
| 2 | P0-4 unhandledRejection 兜底 + void promise 加 catch | Bridge | ✅ 完成 | `07110f58` |
| 3 | P0-5 codex-transport stdin EPIPE 防护 | Bridge | ✅ 完成 | `6d36637a` |
| 4 | P0-6 trackMessageWork 流水线防毒化 | Bridge | ✅ 完成 | `0c4c6615` |
| 5 | B-18 controller fan-out 逐 handler try/catch | Bridge | ✅ 完成 | `3d41f260` |
| 6 | P0-10 menubar 管道死锁 + 首个测试 | menubar | ✅ 完成 | `a1fdf0a6` |
| 7 | P0-1 Git hunk 内容指纹定位 | Bridge+Mobile | ✅ 完成 | `403ad9f6` |
| 8 | P0-2 diff_result requestId 严格匹配 | Bridge+Mobile | ✅ 完成 | `1d0d3501` |
| 9 | P0-3 legacy history 代际栅栏 | Mobile | ✅ 完成 | `7c3fca5f` |
| 10 | 候选B commitReplacement 去重字段 | Bridge | ✅ 完成 | `13f79023` |
| 11 | 解析层四项 P0-7/8/9/14 | Mobile | ✅ 完成 | `4efc7ac0` |
| 12 | P0-18 .json/.html 走预览路由 | Bridge | ✅ 完成 | `3c1985e5` |
| 13 | P0-19 Quick Look 失败回退 WebView | Mobile | ✅ 完成 | `435c3613` |
| 14 | A1 指纹路径改用未 trim 的 diff 输出 | Bridge | ✅ 完成 | `000f1965` |
| 15 | A2 Origin 门禁放行私网自家 Web 客户端 | Bridge | ✅ 完成 | `5706df52` |
| 16 | A3 legacy history 栅栏重设计（外发计数） | Mobile | ✅ 完成 | `043eb36a` |
| 17 | A4 session_list 缺 sessions 键改为拒帧 | Mobile | ✅ 完成 | `298bc125` |
| 18 | A5 带行号锚点的 .json/.html 保留源码路由 | Bridge | ✅ 完成 | `0244f8ed` |
| 19 | A6 语义去重键剔除 kind/projectRelativePath | Mobile | ✅ 完成 | `5bb08e2f` |

## 补充审查报告（NX 系列）的接收记录 — 2026-07-26

另一 Agent 完成的
[`SUPPLEMENT_native-and-handoff-E_20260726.md`](SUPPLEMENT_native-and-handoff-E_20260726.md)
（原生层 + 交接文档 §E 追溯，NX-1～27）已读取归档。与本轮修复的交点：

- **与当前批次零重叠**：NX 系列集中在 iOS/macOS/Android 原生层与 Bridge 文件
  鉴权模块，我当前的批次 1/2 + 预览链路不受影响，无需返工。
- **相互印证**：§5.5 把「代际栅栏」列为值得推广的正面模式——与本轮 P0-3 的
  修复方向一致；NX-26 确认了本日志开头记录的用户决策（Tailscale 私网跳过
  上传门禁），补审已按此归档不再重提。
- **待用户确认的后续批次**（补充报告第 6 章建议，本轮不执行）：
  - P1 四条：NX-1+NX-2（Secure Enclave 重复密钥 + 误判失效，必须成对修）、
    NX-3（deviceId 静默漂移）、NX-5（Picker 失败永久 busy）、
    NX-20（Android 图标零别名窗口）。修 NX-1/2/3 时按建议补
    `FileMutationAuthPlugin` 生命周期测试。
  - P2 十条与 P3 若干见补充报告第 6 章；NX-7（iCloud 备份）与 §4 的
    hot 会话语义、未读蓝点归属需产品决策后再动。
- 本轮全部确认任务完成后，会在完成报告中把上述 NX-P1 批次作为
  下一步建议一并呈报。

## 分项记录

（按完成顺序追加。每项包含：根因、改动、测试证据、兼容性、commit。）

### 1. SEC-1　拒绝带 Origin 的 WebSocket 握手 — `4ab464f4`

- **根因**：`websocket.ts:1393` `new WebSocketServer({ server })` 无 `verifyClient`；
  `bridge-http-auth.ts` 未配 API key 时全放行。WebSocket 不受同源策略约束，任意网页
  JS 可直连 `ws://127.0.0.1:8765`。
- **改动**：`websocket.ts` 构造 `WebSocketServer` 时加 `verifyClient`，请求头存在
  `origin` 即 `403 Forbidden`。浏览器必发 Origin、原生 App（Dart `WebSocket.connect`）
  从不发，故对现有客户端零影响。
- **测试**：`websocket.test.ts` 新增 describe "handshake Origin gate"：真实起 HTTP
  server + 真实 ws 客户端握手，带 `origin: http://evil.example` 收到 403；不带 Origin
  正常 open。全文件 235 tests 通过，`tsc --noEmit` 通过。
- **兼容性**：若未来要支持 Web 版客户端连 Bridge，需把全拒改为白名单反射校验
  （主文档 SEC-1 已登记该边界）。

### 2. P0-4　unhandledRejection 兜底 — `07110f58`

- **根因**：全库无 `process.on("unhandledRejection")`，Node ≥15 默认
  `--unhandled-rejections=throw`；`session.ts` 四处 `void saveCodexSessionProfile /
  saveCodexSessionAdditionalWritableRoots`（内部 `writeFile(~/.codex/...)` 无
  try/catch）。磁盘满/权限变更即整个 Bridge 进程退出。
- **改动**：新增 `process-guards.ts`（unhandledRejection + uncaughtException 记录不
  退出），`startServer()` 起始处注册；四处 void 改为显式 `.catch` 记录。
- **测试**：`process-guards.test.ts`（handler 注册、emit 不抛、记录 2 次）；
  session.test.ts 58 通过；tsc 通过。
- **兼容性**：无协议/行为变化，纯稳定性。

### 3. P0-5　codex stdin EPIPE 防护 — `6d36637a`

- **根因**：`codex-transport.ts` 的 stdin 无 error 监听；app-server 自行崩溃时
  `child.killed` 仍 false，写入已关管道异步 emit 'error' → 未捕获 → 进程退出。
  spawn 失败（ENOENT）只 emit error 不 emit exit，child 引用不清。
- **改动**：stdin 挂 error 监听（存活上抛 / 已退出记日志）；write 前检查
  `stdin.writable === false`（显式 false 比较，兼容测试替身）+ 写回调记录；
  child error 时清引用。
- **测试**：新增 `codex-transport.test.ts` 5 例（EPIPE 上抛、exit 后仅日志、
  destroy 后同步拒绝、spawn 失败后拒绝、正常写通）；codex-process 136 例回归通过。

### 4. P0-6　消息流水线防毒化 — `0c4c6615`

- **根因**：`trackMessageWork` 存的 promise 无 catch；drain/finish 同步抛错后
  后续 `messageProcessing.then(processMessage)` 全部跳过（管道停摆）+
  unhandled rejection。
- **改动**：tracked 链加 `.catch` 记录吞掉，保证恒 resolve。
- **测试**：新增回归——pin 流水线 → 毒化 drain（sendInputStructured 抛错）→
  紧跟的 assistant 消息仍被处理。session.test.ts 58 通过。

### 5. B-18　local-features fan-out 隔离 — `3d41f260`

- **根因**：`controller.ts` 三个 fan-out（sessionMessage/sessionCatalogChanged/
  clientDeliveryModeChanged）同步遍历不捕获；catalog monitor 从 setTimeout 同步
  调入，handler 抛错即 uncaughtException。
- **改动**：三个 fan-out 逐 handler try/catch + 记录。
- **测试**：新增"抛错 handler 不影响幸存 handler"回归；controller 11 例通过。

### 6. P0-10　menubar 管道死锁 — `a1fdf0a6`

- **根因**：先 `waitUntilExit()` 后 `readDataToEndOfFile()`，输出超 ~64KB 管道
  缓冲必死锁。**原始报告补充了主文档缺的第二处**：`DoctorRunner.swift:49-52`
  同型缺陷，一并修复。
- **改动**：新增 `ProcessRunner.swift`（readabilityHandler 并发排水 +
  waitUntilExit + EOF 有界等待），两处调用点复用；pbxproj 手工注册；
  新增 SwiftPM 测试 harness（`apps/menubar` 此前零测试）。
- **测试**：swift test 5/5（含 2MB 不死锁回归）；xcodebuild Debug 构建成功。
- **兼容性**：行为等价（输出、退出码、超时语义不变）；`Package.swift` 仅供
  `swift test`，不影响 xcodeproj 构建与发布。

### 7. P0-1　Git hunk 内容指纹定位 — `403ad9f6`

- **根因**：客户端展示 `git diff --no-color`（默认 3 行上下文，U3），Bridge 执行
  hunk 操作时却重跑 `--unified=0`（U0）再按 `hunkIndex` 取第 N 个。两处改动相距
  ≤6 行时 U3 合并成 1 个 hunk、U0 拆成 2 个，索引错位 → 静默 stage/revert 错误
  的代码（revert 即丢失用户工作）。
- **方案**（内容寻址，双端契约）：
  - App 端 `diff_parser.dart` 新增 `buildHunkFingerprint(DiffHunk)`：从 hunk 头
    解析四元组 {oldStart, oldLines, newStart, newLines}（省略计数默认 1），对
    +/- 变更行按显示顺序做 sha1（每行 + `\n`，utf8），随
    `{file, hunkIndex}` 一起发送 `fingerprint`。头不可解析（工具合成 diff）
    返回 null → 走旧索引路径。
  - Bridge 端 `parser.ts` 新增 `ClientHunkRef` 校验（fingerprint 可选，但存在
    时必须完整）；`git-operations.ts` 新增 `hashHunkChangeLines` /
    `buildFingerprintPatch`：重跑与客户端**相同的 U3 diff**，按四元组+内容哈希
    定位那个确切的 hunk，构造补丁应用（stage `apply --cached` / unstage
    `apply -R --cached` / revert `apply -R`）。工作区-vs-index 的 diff 上下文行
    两侧一致，U3 补丁必然干净应用，新路径无需 U0/`--unidiff-zero`。
  - 指纹不匹配（diff 已过期）→ 报描述性错误让用户刷新重试，**绝不猜**。
- **兼容性**（加法协议）：旧 App 只发 `{file, hunkIndex}` → Bridge 走原 U0 索引
  路径（回归测试覆盖）；新 App 发多出的 `fingerprint` 键 → 旧 Bridge 解析器仅
  校验 file/hunkIndex、容忍多余键（已核对旧代码），行为同旧路径。
- **测试**：
  - Bridge `git-operations.test.ts` 新增 11 例：真实 git 仓库、改动相距 2/3/4 行
    （U3 合并 / U0 拆分的分界）revert 后文件内容精确匹配；相距远的两 hunk 选择性
    stage/revert；未跟踪文件 stage；过期指纹拒绝且不动文件；无 diff 拒绝；旧索引
    路径回归；金样哈希 `sha1("-old line\n+new line\n") =
    72e37c089cc6615e099c2668f6cd4c797d676f9f` 双端各钉一份。
    全文件 69 例 + parser 160 例通过；全套 vitest 1713/1714（唯一失败
    `session-catalog-monitor` 为并发负载下的计时抖动，单独复跑 2 次均过，
    与本项无关）。
  - App `diff_parser_test.dart` 新增 4 例（同一金样哈希、显示顺序+跳过上下文、
    省略计数默认 1、合成 diff 返回 null）；`git_view_cubit_test.dart` 三个发送
    器断言完整 fingerprint map。`dart analyze` 无新告警，`dart format` 无 diff。
### 8. P0-2　diff_result requestId 严格匹配 — `1d0d3501`

- **根因**（原始报告 D-2 + D-10）：`diff_result` 无 projectPath/sessionId/
  requestId，而 `GitViewCacheService` 每会话常驻一个 Cubit 监听同一全局流 →
  A 项目的 diff 渲染进 B 的 Git 视图，B 上的 stage/revert 把 A 的文件路径发到
  B 的仓库；快速切 staged/unstaged 时迟到响应同样覆盖新视图。
- **改动**：
  - App：`GitViewCubit` 静态单调计数生成 `gitdiff-N` requestId，三个 get_diff
    发送点（初始/刷新/切模式）统一走 `_sendGetDiff` 记录待匹配 id；监听回调里
    `requestId != null && != 待匹配 id` 即丢弃。`ClientMessage.getDiff` 加可选
    requestId；`DiffResultMessage` 解析 requestId。
  - Bridge：`get_diff` 协议加可选 `requestId`（非 string 拒绝），成功/错误
    4 条 diff_result 全部回显；顺带给 `collectImageChanges` 补 `.catch`
    （原始报告 D-15 的挂死路径：图片收集 reject 时客户端永远收不到
    diff_result），失败时退化为纯文本 diff 照常下发。
- **兼容性**（加法协议）：旧 Bridge 对 get_diff 只校验 projectPath、容忍多余键
  且不回显 → 新 App 收到无 requestId 的响应按旧行为接受（单会话兼容模式，
  测试覆盖）；旧 App 不发 requestId → 新 Bridge 不回显，响应与旧版逐字节一致。
- **测试**：Bridge 3 例（成功回显 / 无 requestId 不回显 / 错误路径回显）+
  parser 1 例（可选 requestId 校验），websocket+parser 398 通过；App 5 例
  （外来 id 丢弃、本方 id 接受、快速切模式旧响应丢弃、旧 Bridge 无 id 接受、
  序列化/解析），git_view_cubit + messages + diff_parser 158 通过；
  `dart analyze` 无新告警。

### 9. P0-3　legacy history 代际栅栏 — `7c3fca5f`

- **根因**：`session_runtime_store.dart` 对 legacy `HistoryMessage` 无条件
  `clear()+addAll()` 且把 `historySeq`/`cachedHistorySeq` 打回 0，
  `bridge_service.dart` 不比对任何代际。迟到全量帧（Codex rollout 读盘滞后于
  实时流）覆盖其后已到达的实时消息；水位清零使下一次 delta 以 `sinceSeq=0`
  触发全量重拉——消息"消失又重现"，主文档判为"重复两次"头号嫌疑（候选 A）。
- **改动**（全部在 `bridge_service.dart`，store 行为不变）：
  - 每 session 维护 `_historySyncGenerations`（full/delta 请求都递增）；发
    `get_history` 时压入 FIFO 栅栏 `_LegacyHistoryFence{generation,
    contentEpoch, storeWasEmpty}`（同一 socket 响应按请求序配对）。
  - `history` 帧到达时 `_acceptLegacyHistoryFrame` 判定：空 store 恒接受
    （初次水合）；无栅栏（未请求）拒绝；非最新代际拒绝；请求时为空但期间
    出现 seq 同步内容（`cachedHistorySeq>0`）拒绝；请求时非空则要求
    `contentEpoch` 未变（纯重同步）。拒绝时仍走
    `_emitSessionHistoryReconciliation` 结束同步生命周期（前台 spinner 不挂）。
  - 重连 / 换 Bridge 时清空栅栏（旧 socket 在途响应必然丢失，防 FIFO 错位）。
- **兼容性**：不改协议；delta/snapshot 路径与旧 Bridge 回退路径行为不变，
  仅拒绝会破坏更新状态的全量帧。
- **测试**：新增 `test/services/legacy_history_fence_test.dart` 4 例（真实
  loopback WebSocket 驱动完整 BridgeService）：空 store 水合；旧 Bridge 回退
  链路上迟到帧不覆盖新实时消息（修复前必红）；无新内容时回退帧正常整替；
  未请求的全量帧不能清掉 snapshot 同步内容与水位。全套 flutter test
  2313 通过（仅 2 个已记录的 file_transfer 基线失败）。
- **工程记录**：`bridge_service.dart` 在 HEAD 上本就不满足当前 dart_style
  版本（整文件 format 会产生 ~20 处无关 hunk），故本次仅提交功能 hunk、
  未做整文件格式化，保持 diff 可审。

### 10. 候选B　commitReplacement 携带去重字段 — `13f79023`

- **根因**（主文档 3.2 候选 B，"重复两次"次号嫌疑）：`session.ts`
  `commitReplacement` 在 Desktop continuity 原子换血时重新捕获了队列/Goal/
  命名等手机侧状态，但**漏了**三个用户回显去重字段：`codexLatestUserInput`、
  `pendingCodexUserEchoUuids`、`codexUserTurnUuidByRawId`。换血后新 runtime
  不记得某条用户输入的 app-server 回显已发布过 → 回显被当成全新消息再插一次。
- **改动**：三字段随换血携带；`codexUserTurnUuidByRawId` 与新 session 的
  seed map 合并且**live 映射优先**（客户端已按 live uuid 渲染；seed 可能
  含未经旧 runtime 流转的更早持久化 turn）。
- **测试**：session.test.ts 新增"carries the user-echo dedup state across a
  Codex replacement"（修复前三字段在换血后全为 undefined，必红）。session
  59 通过；全套 vitest 1716/1718（仅 session-catalog-monitor 已知计时抖动，
  单独复跑通过）。tsc 通过。
- **兼容性**：Bridge 内部状态迁移，无协议变化。

- **基线记录**：全套 `flutter test` 有 2 个与本项无关的失败——
  `file_transfer_sheet_test.dart: auto-resume off exposes and runs the
  queued-start action` 在 stash 掉本项改动后的干净 HEAD 上同样失败（基线即红）；
  `file_transfer_service_test.dart: restart truncates crash-only download
  bytes and resumes` 单独复跑即过（负载下计时抖动）。均不在本轮任务清单内，
  记录待后续处理。（本项 #11 完成后的全套复跑：2323 通过，唯一失败仍是
  上述 file_transfer_sheet_test 基线红，另一条抖动用例本轮通过。）

### 11. 解析层四项　P0-7 / P0-8 / P0-9 / P0-14 — `4efc7ac0`

全部在 Mobile 解析边界（`messages.dart` 及协议 slot），一个内聚 commit。
动手前复核了 raw-agent-reports 的解析层复查报告；其中 A-2～A-8 的额外
发现（history_page 裸 int、stream delta 裸 cast 等）**不在**本项范围，
仍留档待后续批次。

- **P0-14　Guardian 审批状态解析 fail-closed**：
  - 根因：`GuardianApprovalStatus.fromString` 的兜底分支是 `approved`——
    未来 Bridge 新增任何状态字面量都会被渲染成"已批准"。
  - 复核修正了主文档的原始处方："missing 也 fail-closed" 会破坏旧 Bridge
    兼容。取证：`guardian_approval` 首版实现（`46ed7943`，2026-07-21）
    **不带 status 字段**，且只在 review 结果为 approved 时才发这条消息；
    现版 Bridge 恒发显式 `status: "approved"`（codex-process.ts:3970）；
    guardianReview 内嵌路径经 `parseGuardianReviewStatus` 白名单，未知值
    整个 review 直接丢弃、不会到达 App。因此最终语义：
    `null`（旧 Bridge 省略）→ approved；**未知非空字面量 → denied**。
    另确认 `timedOut` camelCase 即线上真实值，主文档怀疑的大小写不匹配
    不存在，无需改。
  - 顺带发现：如按原始处方盲改，`messages_test.dart` 既有用例
    "parses structured Guardian approval notices"（无 status 键，期望
    approved）会红——它模拟的正是旧 Bridge 线型。
- **P0-7　惰性 `cast<String>()` 逃逸解析边界**：`List.cast<String>()`
  返回惰性 CastList，异型元素的 TypeError 延迟到 UI build 首次遍历时才炸，
  绕过解析层 try/catch → 红屏。8 处全部改为急切
  `.whereType<String>().toList()`（historySummary、file_list、
  project_history、precedingToolUseIds、rewind filesChanged、
  git branches/checkedOutBranches、DebugReproRecipe notes）。
- **P0-8　session_list 逐条容错**：单条畸形 SessionInfo 之前会让整帧
  `session_list` 抛异常 → 首页会话列表整个变空。提取 `_sessionListFromJson`
  逐条 try/catch（沿用 `_parseArtifactRefs` 模板），跳过并计入新增可选字段
  `droppedSessionCount`（默认 0，additive 兼容）；`bridge_service.dart`
  在 SessionListMessage case 里 `logger.warning` 丢弃计数。同时
  `pendingPermission` 子对象畸形时降级为 null 而不拖垮整个 session
  （`_pendingPermissionFromJson`）。
- **P0-9　conversation_content 急切解码**：`ConversationContentWireEntry
  .fromJson` 末尾的 `entry.decodeMessage()` 会在主线程一口气解码整帧
  （snapshot 最多 2000 条），且一条不可解码的 entry 否决全帧。照抄 mirror
  slot 的惰性写法删除急切调用。消费方审计：快照唯一构造点
  `session_catalog_cache_repository.dart:351` 的逐条 `decodeMessage()`
  探针本就在 try/catch 内（坏行只作废该可重建窗口）；两个 session screen
  只消费经探针校验过的快照，无需加防护。
- **测试**（先证伪后修复）：把 lib 改动 stash 回 HEAD 后跑探针——
  未知 status → 实测 approved（必须 denied）；session_list 单条畸形 →
  整帧 TypeError；file_list 混入 int → 遍历时 TypeError；content slot
  含不可解码 entry → fromJson 当场抛 `type 'Null' is not a subtype`。
  修复后新增用例全绿：guardian 三态（白名单/缺省=approved/未知=denied）、
  session_list 跳过计数、畸形 pendingPermission 存活、file_list 与
  git_branches_result 遍历安全、content slot 惰性解码（坏 entry 只在
  `decodeMessage()` 调用时抛）。定向套件 126 通过（messages、
  conversation_content_protocol、sync service、catalog cache、
  legacy history fence）。`dart analyze` 触及文件零告警。
- **格式纪律**：`messages.dart` 与 content slot 在 HEAD 即 format-clean，
  可整文件 format；`bridge_service.dart` HEAD 非 format-clean（既往已记录
  的坑），仅手工格式化自己的 2 个 hunk。
- **兼容性**：droppedSessionCount 为 additive 可选字段；guardian 缺省
  status 语义与旧 Bridge 完全一致；其余为客户端解析内部行为收紧，
  无协议变化。

### 12. P0-18　.json/.html 走预览路由 — `3c1985e5`

- **根因**（主文档 P0-18 = 原始报告 artifact-preview-route-chain.md A1/A7）：
  `artifact-manager.ts` `sourceKind()` 把 `.json`/`.html`（含 text/html、
  application/json MIME 前缀）判为 `kind:"source"` → App 端
  `chat_message_list.dart` 对 source 走 File Peek 纯文本表 → 统一预览路由
  （HTML 沙箱 iframe、JSON pretty-print、Quick Look、分享/下载）在 Agent
  引用入口下**整段不可达**。这是用户"JSON/HTML 预览失败"主诉在本分支源码
  上的首要根因（另一半 P0-17 是发布问题，本轮不动）。
- **动手前核对原始报告**：A1/A7 全文复核；报告建议的修复方向（对
  previewKind==="html" 强制 preview）与主文档处方（移出 SOURCE_EXTENSIONS）
  取并集——仅移出扩展名集合**不够**，因为 `text/html` 会被
  `normalizedMime.startsWith("text/")` 再次拦成 source；改为在 isSource
  计算**之前**显式早返回。顺带发现并修复同型漏网：`.htm` 不在
  SOURCE_EXTENSIONS 里，但经 text/html MIME 同样被判成 source。
- **改动**（仅 Bridge，`artifact-manager.ts`）：`sourceKind()` 对
  `.html`/`.htm`/`.json` 扩展名及 `text/html`/`application/json` MIME 前缀
  早返回 `"preview"`；SOURCE_EXTENSIONS 移除 `.html`/`.json`、isSource 的
  `application/json` MIME 分支删除（均已被早返回覆盖的死条目）。
- **测试**（先证伪）：artifact-manager.test.ts 新增 "routes project .html
  and .json through the preview chain"——真实临时 git 目录注册
  report.html / legacy.htm / data.json / main.ts 四个候选；修复前
  前三个断言 preview 全红（实际 source），修复后 22/22 通过，main.ts
  仍为 source + projectRelativePath（控制组）。全套 vitest **1719/1719
  全绿**（本轮连 session-catalog-monitor 抖动都没出现）；tsc 通过。
- **兼容性**：`kind` 是既有二值枚举，新老 App 都完整处理 "preview" 值
  （走既有 ArtifactPreviewScreen 路径），无协议扩展；preview ref 按既有
  规则不携带 projectRelativePath，与 pdf/png 等既有 preview 行为一致。
  File Peek 作为"查看源码"次级入口的 UI 增强（报告 B1 的 PreviewRouter
  统一）不在本项范围，留档。

### 13. P0-19　Quick Look 失败也回退 WebView — `435c3613`

- **根因**（主文档 P0-19 = 原始报告 A4）：`artifact_preview_screen.dart` 只有
  `ArtifactQuickLookUnsupportedException` 一种失败会回退 WebView；其余全部
  失败（Swift 侧 busy / no_presenter / presentation_failed、传输层
  size_mismatch / http_error / destination_not_reserved）直接落在错误卡上，
  Retry 大概率原样复现。主文档已注明"需用户决策"，用户已确认采用
  E.4 §5 的"不支持**或失败**都回退"语义。
- **改动**：泛化 catch 镜像 unsupported 分支——`_initializeWebPreview()` +
  `_usesQuickLook = false`，错误降级为非阻塞 snackbar（不加平台闸门：
  Android 的 plugin_missing 路径本就无闸门回退；macOS 只可能走
  plugin_missing→unsupported 分支，泛化 catch 不可达，B3 的 macOS 红屏
  是基线既有问题、留档不在本项）。`_quickLookError` 状态与 Retry 分支
  从此不可达，一并删除（6 处）。
- **测试**（先证伪）：原有用例 "failed Office preview shows Retry instead
  of Preview" 断言的正是被用户决策取代的旧语义，改写为 "failed Quick Look
  preview falls back to the WebView preview"：新增假 WebViewPlatform
  （PlatformWebViewController/NavigationDelegate/WebViewWidget 全 no-op，
  dev 依赖补 `webview_flutter_platform_interface`，与既有
  `url_launcher_platform_interface` 同模式）；stash 掉 lib 改动后该用例红
  （找不到 WebViewWidget），修复后 artifact_preview 相关 18/18 绿。
  全套 flutter test 2323 通过，唯一失败仍是已归档的
  file_transfer_sheet_test 基线红。analyze 零告警；两文件 HEAD 即
  format-clean，整文件 format 无额外 diff；pubspec.lock 仅
  dependency kind 翻转（transitive → direct dev），版本不变。
- **兼容性**：纯客户端行为变化，无协议改动。正常关闭 Quick Look
  （previewControllerDidDismiss）不走异常路径，不受影响。

## 对抗审查回归修复（A 系列）— 2026-07-27

> 依据：`reviews/ADVERSARIAL_REVIEW_RESULT_20260727.md`（18 agent 对抗审查，
> 10 项确认 / 3 项驳回）。确认项中 6 项是本轮修复自己引入的回归，
> 全部按"先红后修"补齐。

### 14. A1　指纹路径改用未 trim 的 diff 输出 — `000f1965`

- **根因**（自引入，P0-1 `403ad9f6`）：`git()` 帮助函数对 stdout 做
  `.trim()`，把 diff 末尾的纯空白 context 行（空行 / 尾随空格 / CR）
  删掉。指纹哈希只覆盖 +/- 行，守卫照常通过，但拼出的补丁行数与
  hunk 头不符 → `git apply` 报 "corrupt patch"；姊妹症状：末行带
  尾随空格时重跑哈希不一致 → 误报 "no longer matches"。展示路径
  （collectGitDiff）发的是未 trim 的原始字节，Bridge 重跑必须逐字节一致。
- **改动**：`git-operations.ts` 新增 `gitDiffText()`（不 trim）+
  `diffLines()`（只去掉末尾换行伪影），applyHunks 的指纹取数路径全部
  换用。legacy `--unified=0` 路径不受影响（U0 hunk 体不会以空白行结尾）。
- **测试**（先红）：三个端到端仓库用例——尾部空行 context、CRLF 文件
  按指纹 revert、末行带尾随空格的新增——旧代码下分别复现
  "corrupt patch at line 12" / "patch does not apply"，修复后全绿。
  Bridge 全套 vitest 通过，tsc 无告警。

### 15. A2　Origin 门禁放行私网自家 Web 客户端 — `5706df52`

- **根因**（自引入，SEC-1 `4ab464f4`）：拒绝一切带 Origin 的握手，
  连自家 `flutter build web` 预览（CLAUDE.md §Web確認 的用户验收通道，
  浏览器必发 Origin）也被 403，"零兼容代价"承诺不成立。
- **改动**：`isPrivateOrigin()` 纯主机名形状判断（不做 DNS 解析，
  天然免疫 rebinding）：localhost/*.localhost/*.local、127/8、10/8、
  192.168/16、172.16-31、100.64-100.127（Tailscale CGNAT）、::1、
  fc00::/7、fe80::/10 放行；公网域名（含 *.ts.net——Funnel 可暴露
  公网页面）、"null"、畸形 Origin 一律拒绝。无 Origin 头（原生 App、
  Node 客户端）不受影响。
- **测试**（先红）：Web 客户端模拟（Origin: http://100.105.41.82:8888）
  旧代码被拒 → 修复后可握手；新增 24 例边界分类（172.15/172.32/
  100.63/100.128 出界、attacker.tail1234.ts.net、localhost.evil.example
  等均拒）。
- **兼容性**：只放宽不收紧——SEC-1 封死的公网 drive-by 面保持不变。

### 16. A3　legacy history 栅栏重设计（外发计数） — `043eb36a`

- **根因**（自引入，P0-3 `7c3fca5f`，对抗审查确认三处误伤）：
  ① 只回 error 的 get_history 应答从不弹栅栏 → FIFO 配对错位，
  重试成功的应答被误配旧栅栏丢弃；② 请求与应答之间任何插帧
  （连 status 都算）都会推进 contentEpoch → 回退整帧被丢且无重试；
  ③ 旧 Bridge 上按 WebSocket FIFO，被请求的整帧必然在已应用的
  实时帧之后生成，是其超集——epoch 比较永远误判，丢的恰是断连
  期积压（本次请求的目的）。
- **改动**：删除 `_LegacyHistoryFence` 队列 + 代际 + contentEpoch
  机制，换成每会话外发计数 `_outstandingLegacyHistoryRequests`：
  history 帧递减；可识别的 get_history 失败应答也递减
  （新 Bridge 的 scoped `session_not_found`，旧 Bridge 的无 scope
  文本 `Session <id> not found`——46ed7943 起从未变过）；连接重建清零。
  接受条件：空 store 直接 hydrate（覆盖 `_requestSessionHistory`
  对"空 store + 旧水位"故意发 legacy 请求的路径）→ seq 水位 > 0
  一律拒（保护快照/增量协议内容）→ 其余仅在有外发请求时应用。
- **测试**（先红验证）：三个新回归——superset 竞速帧必须应用
  （否则丢 h0 积压）、status 插帧不得丢应答、error-only 应答要释放
  门闸——旧栅栏下全红，新实现全绿；原有保护（空 store hydrate、
  纯 resync、无请求帧不得砸快照会话、快照中途落地仍拒 legacy 帧）
  4 例保持绿。
- **兼容性**：纯客户端；对新 Bridge 由 seq 守卫兜底，对旧 Bridge
  恢复了断连积压回填（原栅栏反而丢）。

### 17. A4　session_list 缺 sessions 键改为拒帧 — `298bc125`

- **根因**（自引入，解析层 `4efc7ac0`）：容错解析把"缺 `sessions`
  键 / 非 List"当成空权威列表 → 首页全清空；基线行为是抛错拒帧、
  保留旧列表。
- **改动**：`_sessionListFromJson` 对缺失/非 List 抛 `FormatException`
  （由 WS 解析守卫捕获拒帧），逐条容错（坏条目跳过并计数）不变。
- **测试**（先红）：缺键与 `sessions: 'not-a-list'` 两例断言抛错；
  messages_test 全套 109 绿。

### 18. A5　带行号锚点的 .json/.html 保留源码路由 — `0244f8ed`

- **根因**（自引入，P0-18 `3c1985e5`）：.json/.html 强制走预览路由，
  但预览页完全无视 line 且文本 512KB 截断——`src/config.json:4000`
  这类引用点开后目标行不可达；基线走 File Peek 且滚动到行。
- **改动**：`sourceKind()` 增加 line 参数——带行号锚点的 .html/.htm/
  .json 保持 `kind:"source"`（File Peek 8MiB 上限 + initialLine），
  无锚点引用继续走预览路由（沙箱渲染 / JSON 美化不受影响）。
- **测试**（先红）：`config.json:4` 与 `page.html:2` 断言
  kind:"source" + line + projectRelativePath；artifact-manager 23 例全绿。

### 19. A6　语义去重键剔除 kind/projectRelativePath — `5bb08e2f`

- **根因**（自引入，P0-18 `3c1985e5` 的跨版本连锁）：客户端
  `_markdownArtifactSemanticKey` 把 kind 和 projectRelativePath
  算进去重键，而 P0-18 恰好合法翻转了两者——registry 驱逐后
  历史重拉的再注册合不回旧 chip，出现死重复 chip
  （旧 id 点开 artifact_not_found；普通模式下双 ref 精确匹配同一
  href 反而让行内链接完全失配）。
- **改动**：去重键只保留链接位点的稳定身份
  （source + textContentIndex + originalHref + line + column）；
  kind / projectRelativePath 属于目标的派生属性，变更时应由
  最新 Bridge 描述符原位替换（正是 `_mergeArtifacts` 注释里
  写明要处理的场景）。
- **测试**（先红）：旧 source/带路径 ref 被新 preview/无路径 ref
  原位替换、只剩新 id；chat_session_cubit 全套 144 绿。

## Phase B　性能批次（对抗核实后实施）— 2026-07-27

> 六项挖掘发现先经 6 个只读核实代理逐项对源码验证（防报告过时），
> 结论：1 REAL / 3 PARTIAL / 1 已修复（过时）/ 1 潜在不可触发。
> 按实效导向只做有真实收益的四项。

### 20. D5　七处缩略渲染位点补解码尺寸上限 — `26db9cd9`

- **核实**：REAL、高收益。全仓 0 处 cacheWidth/ResizeImage；画廊网格、
  聊天气泡预览、用户气泡附件、输入栏附件条、生成图网格、行内 diff
  图面板、消息图列表七处均以 80–400 逻辑 px 渲染却全分辨率解码
  （截图/diff PNG 单张 16–24MB），刷回滚动即重解码、长会话易触发
  iOS 内存压杀。
- **改动**：新增 `decodeWidthForLogical()`（物理像素宽度上限），七处
  按渲染宽度传 `cacheWidth`。只限宽不限高——cover/contain 下限宽
  永不放大糊图；方形/竖长 cover 位点（输入条 80px 方块、画廊 0.75
  纵横比瓦片）取 2x/全屏宽富余，杜绝宽源高主导时的上采样。全屏
  可缩放查看器一律不设限；imageCache 字节上限保持默认（解码
  右尺寸化后保留量不再是瓶颈——核实结论明确调上限不是有效杠杆）。
- **测试**：新增 image_decode_bounds_test 5 例，钉住七处 provider 为
  ResizeImage/ExtendedResizeImage、全屏查看器保持 MemoryImage 不包装。
  相关既有套件（gallery/tool_result/chat_input/generated_image）全绿。

### 21. D1　展开态生成图卡补 itemCache — `716d7118`

- **核实**：PARTIAL——「长列表」说法夸大（单消息 1–4 图），但机制
  真实：展开的 ImageGeneration 卡每次 rebuild 重跑 mapper，data: URL
  重新 base64 解码出新 Uint8List → MemoryImage 身份变化 → 引擎全量
  图像重解码 + GC 抖动。主列表早有 _generatedImageItemCache，此处漏传。
- **改动**：ToolResultBubbleState 持有 per-State 缓存，消息变更时清空，
  线程进卡片调用（mapper 缓存键含 toolUseId/imageId/url/content，
  天然防脏数据）。
- **测试**（先红）：新用例断言 rebuild 前后字节 identical()——stash
  修复后红（新字节），恢复后绿。套件 15/15。

### 22. D7　流式合并间隔随文本长度自适应加宽 — `bc36c23b`

- **核实**：PARTIAL——原主张（每 chunk 直接 setState）已由 32ms 合并
  + BlocSelector 子树隔离修复（先前提交），残余问题是每次 flush 对
  **全量**累计文本重跑 Markdown 解析：长代码消息 10KB+ 时 ~31 次/秒
  的 O(全文) 解析，累计二次方，低端机吃帧预算。
- **改动**：flush 间隔按累计长度分级（≥8KB 3x、≥32KB 6x）：短消息
  保持 32ms 灵敏度，长消息降到 ~5-10 次/秒，单位时间解析量近似持平。
- **测试**：新用例证明大文本下 base 间隔不 flush、加宽间隔后 flush
  （对旧实现红——旧代码无此 API/行为）。套件 16/16。

### 23. D6　五处手势 CurvedAnimation 累积泄漏 — `b44418ad`

- **核实**：PARTIAL——「build 里重建/ticker 泄漏」不成立（9 处均
  initState 创建、controller 均 dispose）；真实问题是 5 处手势处理器
  （gallery viewer、生成图预览页、diff viewer 三个 State）每次双击/
  交互结束 new CurvedAnimation——构造时给共享 controller 挂 status
  listener 且从不摘除，屏幕存续期内每手势累积一个滞留对象。
- **改动**：每 State 一个复用 curve（controller 之前 dispose）；动画
  行为不变（同 curve 同 tween）。核实定级"低体感、廉价卫生修复"，
  按此只做最小改动、不铺 leak_tracker 脚手架。
- **测试**：相关套件（generated_image 系列 17 例）全绿，analyze 零告警。

### 未采纳项（实效导向裁决）

- **D2（data:URL 拼接 httpBaseUrl）**：核实为**当前不可触发**——真实
  Bridge 只发相对 URL（data: 前缀在 Bridge 侧已剥离）、App 内 data:
  生产者（mock/商店截图）均配空 base。属潜在脆弱性而非现症 bug，
  已记入 UNFIXED_BACKLOG（建议未来统一走 generated_image_preview_mapper
  的 _resolveImageUrl 守卫模式），本轮不动代码。
- **D11（file_peek 高亮记忆化）**：核实为**已修复/过时**——highlightToTextSpans
  早有 1800 字符上限 + 80 条 LRU（commit 2717842e），且 file_peek 无
  逐键/逐滚动 rebuild 路径。关闭。

## Phase C：挖掘积压 P0 批（核实后实施）— 2026-07-27

来源：`reviews/UNFIXED_BACKLOG_20260727.md` P0 段（24 项中裁剪出可修的
非发布类）。纪律不变：逐项内联核实（报告可能过期）→ 红测 → 修复 →
独立 commit。

### 24. P0-15　Codex 审批晚于 turn 完成时会话永久卡死 — `1358d478`

- **核实**：REAL——`resumeRunningIfNoPendingInteractiveRequest` else 分支
  无条件 `setStatus("running")`（codex-process.ts:2450）；turn/completed
  已把 pendingTurnId 置空但留在 waiting_approval，之后 approve/reject
  一律置 running，无 turn 可把它送回 idle → isWaitingForInput 永远
  false，只有重启能恢复。8 个调用点全经此路径。
- **改动**：改为 `setStatus(pendingTurnId ? "running" : "idle")`，与
  handleServerRequestResolved（~:5010）已有的正确模式一致。
- **测试**：新用例驱动 turn/started → 审批挂起 → turn/completed →
  approve，断言回 idle（红：得 running）。同文件既有用例
  "keeps waiting…" 补驱动 turn/started（原先靠漏洞才断言到 running）。
  套件 137/137，tsc 干净。

### 25. sdk-process 三处清审批不 resolve → SDK 权限门挂起 — `8316707e`

- **核实**：REAL——interrupt()（:825）、stop()（:804）、result 分支
  （:1388）均 `pendingPermissions.clear()` 而不调 resolve：canUseTool
  返回的 Promise 永远悬挂，且 abort 监听器先查 map 成员资格（已被清）
  也不再兜底 → 审批挂起期间打断后 query 卡在权限门内。
- **改动**：新增 `denyAllPendingPermissions(message)`（逐个 resolve
  deny 再 clear），三处站点统一改用。
- **测试**：三个红测（interrupt/result/stop 各一）断言 resolver 以
  deny 被调用且 map 清空。套件 97/97，tsc 干净。

### 26. codex transport error 不结算在途 RPC → ENOENT 启动挂死 — `cb989494`

- **核实**：REAL——codex-transport 注释自证 spawn 级失败（ENOENT/
  EACCES）只发 "error" 永不发 "exit"，而 rejectAllPending 只挂在 exit
  处理器上；bootstrap 的 `await initialize` 永久悬挂，启动失败无法
  向 App 面呈现。
- **改动**：error 处理器改调 `rejectAllPending(err)`（顺带覆盖原先手工
  的 releaseCoreAction 两行）；bootstrap 既有 catch 将拒绝转为
  error+result(error)+idle。双 exit 事件语义与既有 exit 路径一致。
- **测试**：红测断言 child error 后 pendingRpc 清空且发出
  result(subtype:error)（红：map 滞留 1、无 result）。套件 138/138，
  tsc 干净。

### 27. prompt-history 校验缺口 + v1 导入中途失败清空历史 — `7e6d94a8`

- **核实**：REAL——isPromptHistoryEntry 只查 3 个字段，5 个 string 字段、
  commandKind 枚举、stat 记录全不校验；importEntries 先清 entries 再
  逐条导入，中途抛错时旧数据已丢且未落盘，内存态与磁盘态双损。
- **改动**（Agent A 产出，经我逐 diff 复核）：新增
  `isPromptHistoryStatRecord(value, allowClientName)`，isPromptHistoryEntry
  扩展全字段校验；importEntries 以 snapshot/restore 包裹（失败恢复
  `this.data.entries = previous` 后 rethrow）。
- **测试**：红测覆盖坏字段拒收与导入失败后原数据完整。套件绿，tsc 干净。

### 28. iOS 通知审批动作时间戳解析失败 — `3226eafb`

- **核实**：REAL——默认 `ISO8601DateFormatter` 拒绝小数秒，而 JS
  `toISOString()` 恒带 `.SSS` → 通知动作携带的时间戳全部解析失败。
- **改动**（Agent G 产出，经我复核）：`parseIso8601Timestamp(_:)` 静态
  helper，`[.withInternetDateTime, .withFractionalSeconds]` 优先、纯格式
  兜底。Swift 无本地测试设施，靠双格式覆盖逻辑简单可审。

### 29. menubar 用量倒计时 resetsAt 解析失败 — `3325401d`

- **核实**：REAL——同 28 的小数秒问题，`resetsAtDate` 直接返回 nil，
  倒计时不渲染。
- **改动**（Agent G 产出，经我复核）：同款双 formatter 兜底内联实现。

### 30. codex approvalPolicy 未知时被捏造为 on-request — `4528efa8`

- **核实**：原报告指认 codex-process.ts 站点为 NOT-REAL（App 启动会话
  在 start handler 有意置 on-request 默认，产品语义，不改）；但顺藤
  发现真实残留在 websocket.ts：Desktop 建的线程被 resume 接管时 policy
  确属未知，`currentApproval`/两处 codexSettings 持久化把 undefined
  归一成 on-request，权限重启时覆盖用户 `~/.codex` 配置。
- **改动**（我本人）：codex-process 增 `approvalPolicy` getter（不捏造）；
  websocket 增 `normalizeCodexApprovalPolicyIfKnown`，undefined 时持久化
  与重启 payload 均省略该键。
- **测试**：两个红测（collab-only 变更不捏造 / plan 切换重启 payload
  省略）；既有一处断言从捏造值改为 `toBeUndefined`。全套 Bridge
  1734/1734 绿。

### 31. file_transfer C12 暂停分支 cancel 请求永久钉死 — `67836aba`

- **核实**：C12 REAL——paused 分支 cancelRequest 失败后不清引用，重试
  永远短路。C13（暂停冻结全队列）NOT-ADOPTED：`_pausedWork` 单槽暂停
  是有意的熔断设计，多槽重构需产品拍板，已记录建议。
- **改动**（Agent F 产出，经我复核）：catch 内 `identical` 守卫下清
  `paused.cancelRequest = null` 后 rethrow。
- **测试**：红测钉住失败后可重试取消。

### 32. session ghost side-chat 级联销毁缺失 — NOT-REAL（不改）

- **核实**（workflow 修复者 + 对抗审查双确认）：级联销毁自功能引入即
  存在（session.ts:2409-2427），报告指认的泄漏路径不成立。零改动。

### 33. messages.dart 单条坏记录整帧丢弃 — `fd8f6a56`

- **核实**：REAL——history/history_page/history_delta/history_snapshot
  逐条 `as` 强转，一条坏记录抛穿整帧；分页 seq 标量崩溃即丢页；Bash/
  MCP/tool-suggestion 展示字段裸 `as String?` 遇非字符串崩渲染。
- **改动**（workflow 产出，经我逐 diff 复核）：`_historyEntriesFromJson`
  等 helper 逐条 try/catch 只丢坏条目；`_historyPageFromJson` 容忍 seq
  标量、无可用续传游标时强制 `hasMore=false` 防死循环翻页（requestId/
  sessionId 保持严格）；展示字段统一 `_nonEmptyString`。
- **测试**：12 个红测；messages_test 121/121，我本人复跑绿。

### 34. protocol_host 嵌套槽解码失败抛穿载体帧 — `a2f77b66`

- **核实**：REAL——载体帧（subagent_history 等）内嵌槽消息坏帧时
  FormatException 抛穿整批。
- **改动**（workflow 产出，经我复核）：`_decodeDepth` 重入计数，嵌套
  失败降级 ErrorMessage、顶层保持严格 FormatException（8+ 测试文件钉住
  的契约不动）。单 isolate 同步解码下静态计数安全。
- **测试**：两个新用例分别钉嵌套降级与顶层严格；我本人复跑绿。

### 35. side-chat 未知附加字段拒收破坏前向兼容 — `82c40f4e`

- **核实**：REAL——能力协商仅按类型名，新 Bridge 给既有消息加可选字段
  会被 `_sideChatRequireOnlyKeys` 整帧拒收。
- **改动**（workflow 产出，经我复核）：helper 改为带文档的 no-op（保留
  签名与 9 个调用点作为键集文档）；判别器（type/event 枚举/XOR 检查）
  与 malformed/ambiguous 拒收保持严格。
- **测试**：新增内层 `createdAt` 未知键容忍用例（我核实其确实穿透
  `['id','role','text']` 键集，真实钉住新行为）；ephemeral 测试一处
  断言随行为翻转（原用例恰好钉死旧拒收）。side_chat 全套 173/173，
  我本人复跑绿。

### 36. git 结果帧无 projectPath 回显 → 多项目视图串台 — `75722673`

- **核实**：REAL——除 git_status_result 外 13 种 git 结果帧不带
  projectPath；GitViewCubit/CommitCubit/BranchCubit 按类型订阅全局广播
  流，两个项目的 git 视图互吃对方结果：远端 ahead/behind 被别项目数字
  覆盖、别项目 pull 失败显示为本视图错误、外来 stage/commit 结果触发
  多余刷新。
- **改动**：Bridge 侧 13 种结果帧（24 个发送点）回显请求的
  projectPath（parser.ts 类型同步）；App 侧三个 cubit 增
  `_isForeignProject` 守卫（17 个 handler），带异戳丢弃、无戳（旧
  Bridge）照常接受——沿用 diff_result requestId 先例。git_status_cubit
  本就按 projectPath 键控、message_bubble 渲染为空，无需改。
- **测试**：Bridge 新增回显红测（commit 成功帧 + fetch 错误帧）；App
  三个红测（远端状态/pull、commit/push、branches 串台各一）+ 一条
  legacy 无戳兼容用例。websocket 242/242、git 相关 9 套 229/229、tsc
  与 format 干净。

### 37. 收件箱预览绕过 QuickLook 资格策略 — `f7aa3c06`

- **核实**：REAL——file_transfer_sheet 的 `_preview` 直调 QuickLook
  gateway，绕过 `shouldTryQuickLookForArtifact`（HTML 在别处刻意留在
  App 隔离 WebView、64MB 自动上限也被跳过）。
- **改动**：`_preview` 先过资格门；不合格（HTML/超限）降级到分享面板，
  复用既有 `_share` 链路，无新文案。模型无 mimeType，传空串——扩展名
  判定仍覆盖 .html/.htm。
- **测试**：红测 mock 双通道（quick_look + share_plus），断言 .html 走
  share 不走 QuickLook、.txt 走 QuickLook。套件 7/8（唯一失败为已记录
  基线红 auto-resume）。

### 38. chat_session_state 权限字段无 unknown 态 — NOT-ADOPTED（本阶段）

- **核实**：字段（permissionMode/codexApprovalPolicy/codexPermissionsMode
  等）以具体值为默认，无"未知"表达。但 chat_message_handler 在入站帧
  携带时即水合覆盖（:749/:922），默认值对 App 自建会话是瞬态；Bridge
  侧捏造已由 `4528efa8` 在持久层修复。残余影响：Desktop 接管线程在
  水合前 UI 显示默认 on-request；仅当用户显式编辑模式时才会把所见值
  发回（WYSIWYG，语义可接受）。
- **处置**：改为 nullable/unknown 需穿透 state/cubit/mode_bar/
  session_card/resume_coordinator 等 10+ 文件，属权限语义重构——用户
  已明确推迟此类收紧。记为 NX 候选（unknown 态 + UI 占位显示）。

### 39. l10n 两项 — 处置记录（不改）

- **77 个 zh 孤儿键**：仅存在于 zh ARB、模板未引用、不参与生成——纯
  死重，清理属外观整理，按实效导向跳过。
- **getToolDisplayName 仅 zh/en**：ja/ko 用户见英文工具名。修复需成套
  ja/ko 工具名翻译（内容工作非缺陷），且文案验收已推迟——记为 NX 候选。

## Phase D（最终实效审查,20260727）

### 40. side-chat 父进程 duck-check 拒绝未知 approvalPolicy — `48fe6d15`

- **来源**：Phase D workflow(5 维度 finder + 每发现 3 视角对抗验证,
  17 agent)唯一确认项(3/3 维持)。
- **勘误**:此站点即上一阶段 Agent C 所指 side-chat.ts:1043-1054——当时
  我 grep 漏掉 `local-features/` 子目录,误判其为幻觉。本次经 workflow
  三重对抗确认+我本人复核,指认成立。
- **核实**:REAL——`asSideChatParentProcess` 要求
  `typeof process.approvalPolicy === "string"`;`4528efa8` 后该 getter
  在策略未知(Desktop 接管线程)时返回 undefined → duck-check 返回
  null → open_side_chat 报 parent_session_not_found,恰在该修复所服务
  的会话上打断侧聊功能。
- **改动**:duck-check 移除 approvalPolicy 项(附注释);
  `inheritedStartOptions` 本就 `?? "on-request"` 兜底,其余三个 getter
  (model/approvalsReviewer/serviceTier)仍保证判别力。
- **测试**:红测(parent approvalPolicy=undefined → open 成功、无
  error 帧、child.start 收到 on-request 回退;红时报
  parent_session_not_found)。local-features+codex-process+websocket
  617/617,tsc 干净。

### 对抗否决项(记录,不改)

- Private-origin allowlist 阻断 Tailscale MagicDNS web 客户端(1/3)
- history_delta 坏条目钉死 seq 水位导致反复增量拉取(0/3)
- 容忍 fromSeq 强转为 0 清空实时消息时间线(0/3)

### 全套件终验(HEAD=48fe6d15)

- Bridge:1737/1737 全绿(整体跑一次含 session-catalog-monitor 抖动
  失败,隔离 3/3 通过,确认环境负载抖动,该文件未被本次任何 commit
  触碰)。
- Flutter:2356 通过;仅剩 2 个已记录基线项(file_transfer_sheet
  auto-resume 确定性红;file_transfer_service watermark 负载抖动,
  隔离复跑通过)。
- dart analyze:改动文件零新增问题(全库 931 info 均为既有基线,0
  error/warning)。
