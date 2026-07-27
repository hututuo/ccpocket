# CC Pocket 全项目代码审查与实施规划 v2（完整合并版）

> **审查基线**：worktree `mobile-comprehensive-remediation-20260725`，分支
> `fix/mobile-comprehensive-v02-20260726`，HEAD `20382de6`（docs），
> 功能 checkpoint `341b2a26`，`upstream/main = aa215a3b`（与交接文档一致）。
> 工作树干净，无他人未提交改动。
>
> **本文是只读审查产出的规划，未修改仓库任何源码。**
>
> **审查方式**：三轮，共 9 路，每路都做两件事——
> (a) 逐条验证交接文档 v02 的既有断言在当前 HEAD 是否仍成立；
> (b) 独立寻找文档未登记的新问题。
>
> | 轮次 | 路数 | 覆盖范围 | 产出 |
> |---|---|---|---|
> | 第 1 轮 | 6 路 | session_list / chat_session / settings / conversation_mirror / side_chat / Bridge 安全 | 83 项 |
> | 第 2 轮 | 8 路 | services / models / utils / git / file_transfer / file_browser / background_sync / permission / preview 三件套 / Bridge 大文件 / menubar / functions / iOS 原生 / l10n | 约 335 项 |
> | 第 3 轮 | 1 路 | 此前从未派过 agent 的 17 个次要 feature + router/providers/screens/main.dart + **测试夹具质量本身** | 见 4.9 |
>
> ---
>
> ## ⚠️ 本文是精选，不是全集 —— 动手前必读
>
> **本文枚举 155 条**（全部 P0 21 条 + 安全 25 条 + 影响面较大的 P1/P2/P3），
> 用于排优先级和定实施顺序。
>
> **但各路 agent 的原始报告共有 1363 处 `file:line` 引用，本文只覆盖 252 处。**
> 差额主要是 P2/P3 长尾与补充证据行。
>
> 原因：本次审查会话中途触发上下文压缩，第 2 轮 8 路 agent 的详细报告被压缩为摘要，
> 只有高严重度条目完整保留。
>
> **27 份原始报告（856 KB，未经任何压缩）已从子代理 transcript 恢复并归档在
> `./raw-agent-reports/`，索引见 `./README.md`。**
>
> 因此：
> - 排优先级、定批次 → 看本文
> - **动手改某个模块前 → 必须去 `raw-agent-reports/` 翻对应那份**，本文在该模块上大概率不全
> - 两者冲突时**以原始报告为准**（更接近一手取证）

---

## 目录

- [第 0 章　执行摘要](#第-0-章执行摘要)
- [第 1 章　P0 全清单](#第-1-章p0-全清单)
- [第 2 章　安全](#第-2-章安全)
- [第 3 章　交接文档 E.1 三项任务的具体方案](#第-3-章交接文档-e1-三项任务的具体方案)
- [第 4 章　按层完整问题清单](#第-4-章按层完整问题清单)
- [第 5 章　交接文档需要回写的断言](#第-5-章交接文档需要回写的断言)
- [第 6 章　推荐实施顺序](#第-6-章推荐实施顺序)
- [第 7 章　测试门禁](#第-7-章测试门禁)
- [第 8 章　需要用户决策的两项](#第-8-章需要用户决策的两项)
- [附录：审查覆盖范围](#附录审查覆盖范围)

---

## 第 0 章　执行摘要

### 0.1 五句话结论

1. **安全优先级高于交接文档中的任何功能项。** Bridge 在默认配置（未设
   `BRIDGE_API_KEY`）下存在两条可组合的 Critical 缺陷，组合结果是**无认证远程代码
   执行**，且其中一条攻击路径不要求攻击者在同一网段（浏览器 drive-by）。交接文档
   把安全审查排在 E.4，这个顺序需要调整。

2. **交接文档中三项"待取证/待部署真机"的疑难问题，本轮已定位到根因**，不再需要
   真机取证即可开工：权限偶发回到 `on-request`、Plan 首次退出后审批消失、
   JSON/HTML/Quick Look 预览失败。详见第 5.3 节。

3. **本轮已提交的两个功能（缓存秒开、点开提升优先级）在手机上是死代码。**
   `ddfb1bed` 和 `167ec16e` 依赖 `durableProviderSessionId` 路由参数，而手机端
   **三条**入口全都不传该参数（第 3 轮新增确认了第三条：deep link 的 session_link
   路径）。交接文档 B 节将其记为"已实现"，在手机这个主要目标平台上不成立。

4. **存在一类系统性的"测试夹具与生产数据形态不符"缺陷，它已经至少掩盖了 3 个真实
   bug**（Git hunk 行距、iOS 通知时间戳、菜单栏用量时间戳）。这不是个别疏忽，是需要
   写进测试门禁的纪律。详见第 7.2 节。

5. **交接文档的断言有 8 条已不成立**（被本轮提交修复），另有若干需加限定语。
   继续照旧文档实施会做重复工作。详见第 5 章。

### 0.2 按严重度统计（三轮合计）

| 等级 | 数量 | 说明 |
|---|---|---|
| Critical（安全） | 2 | 无认证 RCE 的两个组成部分 |
| High（安全） | 6 | 屏幕监控、symlink 逃逸、hook 执行、上传门禁失效、auto-approval 绕过、终端模板注入 |
| P0 | 21 | 数据丢失 / 崩溃 / 主功能不可用 |
| P1 | 约 60 | 功能在目标平台不生效或明显错误 |
| P2 | 约 160 | 特定条件下的错误或退化 |
| P3 | 约 180 | 打磨项 |

### 0.3 与交接文档 E.1「先做当前源码收束」的对应

| E.1 任务 | 审查结论 |
|---|---|
| 1. 审查 `341b2a26` 特殊可见消息与 ToolResult 时间归属 | **已完成取证**，4 类消息缺时间，详见 3.1，可直接实施 |
| 2. 取得"重复两次"故障的五层证据 | **已定位 4 条可疑机制**，其中 `commitReplacement` 字段丢失为新增头号嫌疑，详见 3.2 |
| 3. 复核 optimistic user entry 替换时的 provenance 漂移 | **已确认存在真实缺陷**（无 UUID 同文本消息互相污染），详见 3.3 |

---

## 第 1 章　P0 全清单

> 按"用户可感知的后果"分组。每项都给了精确位置与证据。

### 1.1 安全类（2 Critical，详见第 2 章）

| 编号 | 位置 | 后果 |
|---|---|---|
| SEC-1 | `websocket.ts:1393`、`bridge-http-auth.ts:83-85` | 任意恶意网页可无条件握手 Bridge |
| SEC-2 | `parser.ts:1307-1314` | 权限模式完全由客户端决定，与 SEC-1 组合 = 无认证 RCE |

### 1.2 数据丢失类

#### P0-1　Git hunk 索引口径不一致，会还原错误的代码

**位置**：客户端 `websocket.ts:11686`（默认 `--unified=3`）vs 服务端
`git-operations.ts:107-111`（重跑 `git diff --unified=0` 后取第 idx 个 `@@`）

**事实**：客户端展示的是 U3 diff，`hunkIndex` 由它算出；Bridge 却在 U0 diff 上按同一个
序号取 hunk。**相距 ≤6 行的改动在 U3 会合并成一个 hunk、在 U0 会拆成多个**，
序号随即错位。

**后果**：用户点"还原这一块"，Bridge 还原的是**另一块代码**。属于静默数据破坏。

**掩盖原因**：现有测试 `git-operations.test.ts:268-292` 选的两行相距 15 行，
U3/U0 下 hunk 划分恰好一致 → 测试通过。

**解决方案**：**协议层传递 hunk 的内容指纹而非序号**。客户端发送
`{oldStart, oldLines, newStart, newLines, contextHash}`，Bridge 在自己的 diff 上按
该四元组 + 指纹定位；定位不到则拒绝并回告，绝不"按序号猜"。同时把 Bridge 侧统一到
与客户端相同的 `--unified` 参数。回归测试必须用**相距 2~4 行**的改动
（生产中最常见的形态）。

#### P0-2　Git 结果流跨会话串扰

**位置**：`messages.dart:3474-3485`（`DiffResultMessage`）、`websocket.ts:8197`

**事实**：`diff_result` 消息**不带 projectPath / sessionId / requestId**，而
`GitViewCacheService` 为每个会话保留一个 Cubit，全部监听同一条全局流。

**后果**：同时打开两个不同项目的会话时，A 项目的 diff 会渲染进 B 项目的 Git 视图；
若用户在 B 上执行还原/暂存，操作的是 A 的内容。

**解决方案**：协议加 `requestId`（additive，旧 Bridge 无此字段时回退到"仅单会话可用"
的兼容模式），客户端按 requestId 严格匹配，不匹配即丢弃。

#### P0-3　legacy HistoryMessage 无代际栅栏，迟到全量帧覆盖新消息

**位置**：`session_runtime_store.dart:101-110`、`bridge_service.dart:1509-1526`

```dart
state._messages..clear()..addAll(...); state.historySeq = 0; state.cachedHistorySeq = 0;
```

**事实**：整体替换并把 seq 水位清零，`bridge_service.dart:1520` 无条件
`applyServerMessage`，不比较代际。`contentEpoch`（:100）只是单调计数，不做 fence 判断。

**后果**：迟到的 `get_history` 全量帧覆盖其后已到达的实时消息，并把水位打回 0 →
下一次 delta 请求 `sinceSeq=0` 再次触发全量重拉 → 快照生成后产生的实时消息在这个
窗口内被丢弃后又被重新拉回。**这是"重复两次"的头号嫌疑。**

**解决方案**：每 session 维护 history generation，请求时记录、响应时比对，丢弃旧代际
全量帧；或 legacy 全量帧只在 store 为空时替换。

### 1.3 崩溃 / 进程级风险类

#### P0-4　Bridge 无 `unhandledRejection` 处理器

**位置**：全库 `grep unhandledRejection` 零命中；典型裸 Promise：
`session.ts:881, 890, 1227, 1233` 的 `void saveCodexSessionProfile(...)`，
其内部 `writeFile(join(homedir(), ".codex", ...))` 无 try/catch。

**后果**：磁盘满、权限变更、`~/.codex` 被删等情况下未捕获 rejection 直接**杀掉整个
Bridge 进程**，所有会话中断。

**解决方案**：入口注册 `process.on("unhandledRejection")` 与 `uncaughtException`，
记录后**不退出**（或优雅重启）；同时把这 4 处 `void` 改为显式 `.catch()`。

#### P0-5　stdin 写入无错误处理（EPIPE 崩溃）

**位置**：`codex-transport.ts:101-106`

```ts
write(envelope: Record<string, unknown>): void {
  if (!this.child || this.child.killed) throw new Error("codex app-server is not running");
  this.child.stdin.write(`${JSON.stringify(envelope)}\n`);   // 无 error 回调、stdin 无 'error' 监听
}
```

**事实**：`child.killed` 只在显式 kill 后为 true；子进程**自己崩溃**时它仍是 false，
此时向已关闭的 stdin 写入触发 EPIPE，且没有任何 error 监听器 → 进程级未捕获异常。

**解决方案**：`this.child.stdin.on("error", handler)`；`write` 传回调；写前检查
`stdin.writable`；子进程 exit 后进入明确的"已停止"状态而非依赖 `killed`。

#### P0-6　消息流水线被毒化后永久停摆

**位置**：`session.ts:693-699`

```ts
const trackMessageWork = (work: Promise<void>): void => {
  const tracked = work.finally(() => { if (messageProcessing === tracked) messageProcessing = null; });
  messageProcessing = tracked;                    // 没有 .catch
};
```

**后果**：任一条消息处理抛错即产生未捕获 rejection（与 P0-4 叠加为进程退出），
即使不退出，后续 `await messageProcessing` 也会连锁 reject。

**解决方案**：`tracked` 加 `.catch()` 记录并吞掉；单条消息失败不得影响后续。

#### P0-7　`cast<String>()` 惰性转换在 build 阶段抛错 → 红屏

**位置**：`messages.dart:1371, 1376`（另 1338, 1411, 1430, 1603, 1605, 3349）

**事实**：`(json['x'] as List).cast<String>()` 返回**惰性** `CastList`，元素类型错误时
不在解析处抛错，而在 UI **build 时**才抛 —— 绕过了 `bridge_service.dart:1431..1872`
的所有 try/catch 保护。

**后果**：一条畸形消息 = 整页红屏，且重连不恢复。

**解决方案**：改为 `List<String>.from(...)` 或 `.whereType<String>().toList()`
（立即求值，且在受保护的解析边界内抛出）。

#### P0-8　`SessionInfo` 裸 cast 导致首页永久空白

**位置**：`messages.dart:4764, 4766, 4820-4822`

**事实**：这些裸 cast 位于 `session_list` 的 `.map()` 内 —— **一条畸形 session 会让整个
`session_list` 解析失败**，首页全部消失，且断线重连也不恢复（下次响应同样畸形）。

**解决方案**：`.map()` 内逐条 try/catch，坏条目跳过并计数上报，不牵连整批。

#### P0-9　内层 eager decode 冻结内容镜像

**位置**：`conversation_content_protocol_slot.dart:122` 构造期即 `entry.decodeMessage();`

**对照**：`conversation_mirror_protocol_slot.dart:135` 是**惰性**的 —— 同一问题的正确
写法就在隔壁文件。

**后果**：一个热窗口最多 2000 条，全部在主线程同步解码 → 明显卡顿；其中任一条解码
失败则整个窗口丢弃。

**解决方案**：照抄 mirror slot 的惰性写法。

#### P0-10　menubar 管道死锁

**位置**：`BridgeProcessManager.swift:35-39`

**事实**：先 `process.waitUntilExit()` 再 `readDataToEndOfFile()`。管道缓冲区约 64 KB，
`brew install node` / `npm install -g` 的输出远超此值 → 子进程写满管道后阻塞，
父进程等它退出 → **必然死锁**。

**解决方案**：先异步读（`readabilityHandler` 或后台队列），再 `waitUntilExit`。

### 1.4 权限与审批类

#### P0-11　权限模式失效：Mobile 侧发明默认值

**位置**：`chat_session_state.dart:88-92`（所有 codex 权限字段都有非 null 默认值）+
`chat_session_cubit.dart:4253-4322`

```dart
final codexPermissionsMode = isCodex && state.codexPermissionsMode != custom
    ? state.codexPermissionsMode : null;          // = defaultPermissions（发明值）
final codexApprovalPolicy = codexPermissionsMode != null
    ? state.codexApprovalPolicy.value : null;     // = "on-request"（发明值）
```

**事实**：状态模型**没有"未知"态**，未从 Bridge 收到权威值时也会给出一个具体值。
切换 Plan 模式时把发明出来的 `on-request` 发回 Bridge，而 `websocket.ts:5468-5476`
的重启路径会真的按 `on-request + workspace-write` 重建线程。

**这就是"权限偶发回到 on-request"的 Mobile 侧根因。**

**解决方案**：权限字段全部改为可空 + 显式 `unknown` 态；未收到权威值时**不发送**该字段
（而非发送默认值）。

#### P0-12　权限模式失效：Bridge 侧 getter 兜底

**位置**：`codex-process.ts:687-689`

```ts
get approvalPolicy(): string { return this._approvalPolicy ?? "on-request"; }
```

被决策路径 `websocket.ts:5011-5014` 使用。

**事实**：这是同一故障的**另一半** —— 即使 Mobile 正确地不发送，Bridge 自己也会把
"未知"兜底成 `on-request`。**两半必须同时修，只修一半仍会复现。**

**解决方案**：getter 返回 `string | undefined`，决策路径遇 undefined 时走"询问用户"
而不是假定一个策略。**兜底方向必须选最严格值，不是最宽松值。**

#### P0-13　Plan 审批在权限/沙箱重启时丢失

**位置**：`codex-process.ts:4331-4348` 把合成的 `plan_<uuid>` 只放进
`this.pendingPlanCompletion`（纯内存，不是正式 pending request）；
`websocket.ts:5453` 的 `destroySession(oldSessionId)` 在权限/沙箱重启时销毁它。

**这就是"Plan 首次退出后审批消失"的根因。**

**误诊风险提示**：auto-approval 无条件批准 `ExitPlanMode`（见 SEC-7），会产生**完全
相同的症状**。修复前必须先确认用户是否开了 auto-approval，否则会修错地方。

**解决方案**：合成的 plan 审批纳入与其他 pending request 相同的持久化/迁移路径，
重启时随会话迁移而非销毁。

#### P0-14　Guardian 审批状态解析 fail-open

**位置**：`messages.dart:2211-2216`

```dart
static GuardianApprovalStatus fromString(String? value) => switch (value) {
  'denied' => GuardianApprovalStatus.denied,
  'timedOut' => GuardianApprovalStatus.timedOut,
  'aborted' => GuardianApprovalStatus.aborted,
  _ => GuardianApprovalStatus.approved,     // 兜底选了最宽松的值
};
```

**后果**：拼写变更、新增状态、字段缺失 —— 任何未知值都被当作**已批准**。

**附带**：`'timedOut'` 是 camelCase，而其余 wire 值是 snake_case，**本身就极可能是
一个已存在的不匹配**（需与 Bridge 侧对齐确认）。

**解决方案**：兜底改为 `denied` 或新增 `unknown` 并在 UI 上按"未批准"处理。

#### P0-15　会话永久无法输入

**位置**：`codex-process.ts:2446-2451` 在审批解决后**无条件** `setStatus("running")`

**对照**：正确写法就在同文件 `:5010`：
`this.setStatus(this.pendingTurnId ? "running" : "idle")`

**后果**：没有进行中 turn 时也被置为 running，输入框永久禁用，只能重启会话。

**解决方案**：照抄 `:5010` 的条件式写法。

### 1.5 会话生命周期类

#### P0-16　Side Chat 僵尸会话耗尽配额

**位置**：`session.ts:1149-1175`（`proc.on("exit")` 只把状态置 idle，**不删除**）、
`session.ts:2380-2398`（`evictStaleIdleSessions()` 过滤掉 `!session.auxiliary`）、
`session.ts:1443-1452`（`listEphemeralSideChats()` 不检查存活）

**事实**：三处叠加 → 已退出的 side chat 永远留在表里，且被排除在清理之外。

**后果**：配额（`websocket.ts:2308-2318`，全局 8 / 每父会话 4）被僵尸占满，
用户无法再开 side chat，重启 Bridge 才恢复。

**解决方案**：exit 时对 auxiliary 会话直接删除；`evictStaleIdleSessions` 不再无条件
排除 auxiliary（改为对 auxiliary 用更短的 TTL）；`listEphemeralSideChats` 过滤已退出项。

#### P0-17　预览修复未随任何版本发布

**位置**：commit `34e97866`（2026-07-25，统一 Quick Look + HTML/JSON 回退）

**取证**：`git tag --contains 34e97866` → 空；最新 `ios/v1.108.0+196` 指向 `0b793a15`
（2026-07-21）；`git merge-base --is-ancestor 34e97866 ios/v1.108.0+196` → false。

**关键约束**：该提交含 Swift 改动，**Shorebird OTA 无法投递**，必须重新构建并走
商店/TestFlight。

**附带**：`packages/bridge/package.json` 是 `1.69.4-compat.1`，而最新 tag 是
`bridge/v1.69.0` —— 版本号与 tag 已经脱节。

**解决方案**：这是**发布问题不是代码问题**。需要一次含原生改动的完整构建；不要试图
用 OTA 解决，也不要重复实现已存在的修复。

#### P0-18　`.json`/`.html` 被判为源码，走不到预览路由

**位置**：`artifact-manager.ts:82` 的 `SOURCE_EXTENSIONS` 含 `.json` 和 `.html`；
`sourceKind()`（`:266-274`）→ `kind:"source"` → `chat_message_list.dart:279` →
`showFilePeekSheet` → **永远不会构造 `ArtifactPreviewScreen`**。

**解决方案**：`.json`/`.html` 从 `SOURCE_EXTENSIONS` 移出，或在 `kind:"source"` 分支中
对可预览扩展名开一条通往预览路由的岔路。

#### P0-19　Quick Look 回退面过窄

**位置**：`artifact_preview_screen.dart:445-457`

```dart
} on ArtifactQuickLookUnsupportedException {
  _initializeWebPreview();            // 唯一的回退
} catch (_) {
  setState(() => _quickLookError = true);
  _showError(...artifactOpenFailed);  // 无回退
}
```

**事实**：只有"明确不支持"才回退；**任何其他失败**（presentation 错误、资源竞争、
临时文件问题）直接报错，不尝试 WebView。

**需用户决策**：E.4 §5 要求"不支持**或失败**"都回退，但 v01 实现注记写的是
"真实传输或 presentation 错误才显示重试" —— 需求文本与实现注记互相矛盾。见第 8.2 节。

**附带（A8）**：`artifact_preview_screen.dart:185-192` 的 `onHttpError` 分支测试
`error.request?.uri.path`，但 `webview_flutter_wkwebview-3.26.0/lib/src/webkit_webview_controller.dart:1099-1111`
在 iOS 上**从不传 `request`** → 该分支在 iOS 上是死代码。

#### P0-20　通知长按操作完全失效

**位置**：`NotificationActionHostPlugin.swift:52` 使用默认 `ISO8601DateFormatter()`
（**不含** `.withFractionalSeconds`）

**事实**：生产端产出的时间戳**一定带小数秒** —— `notification_service.dart:31` 的
`toIso8601String()` 与 `websocket.ts:11099` 的 `new Date().toISOString()` 皆然。
故该校验恒为 nil → 长按动作全部被丢弃。

**掩盖原因**：`RunnerTests.swift:322` 用的是 `"2026-07-25T01:02:03Z"`（**无**小数秒）。

**解决方案**：`formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]`，
并**同时接受**两种形态（用两个 formatter 依次尝试）。测试夹具改为带小数秒。

#### P0-21（第 3 轮新增）　菜单栏用量重置倒计时永远显示 "—"

**位置**：`apps/menubar/CCPocketMenubar/Models/UsageInfo.swift:11`

```swift
var resetsAtDate: Date? { ISO8601DateFormatter().date(from: resetsAt) }
```

**数据源**：`packages/bridge/src/usage.ts:60`
`resetsAt: new Date(window.resets_at * 1000).toISOString()` —— `toISOString()`
**必定**输出 `.000Z` 小数秒。

**后果**：`resetsAtDate` 恒为 nil → `resetsInText`（`:17`）走 `guard else { return "—" }`
→ 菜单栏的用量重置倒计时**从未正常工作过**。

**掩盖原因**：**`apps/menubar` 全目录零测试**（`find apps/menubar -iname "*test*"` 无结果）。

**解决方案**：同 P0-20，并把这两处 Swift 日期解析抽成一个共享的宽容解析工具函数。

**意义**：这是与 P0-20 完全同类、但**独立站点**的 bug。两处独立出现说明这不是
个别疏忽，而是缺少跨语言边界的契约测试纪律（详见 7.2）。

---

## 第 2 章　安全

> 说明：这是用户自有项目的防御性审查，以下均为**修复建议**。

### 2.1 [Critical] SEC-1　WebSocket 无 Origin 校验 + 默认无认证

**位置**：`websocket.ts:1393`、`bridge-http-auth.ts:83-91`

```ts
// bridge-http-auth.ts:83-85
acceptsWebSocketRequest(req: IncomingMessage): boolean {
  if (!this.expectedDigest) return true;   // 未配置 key → 全放行
}
// websocket.ts:1393
this.wss = new WebSocketServer({ server });  // 无 verifyClient，无 origin 检查
```

**为什么严重**：WebSocket 不受同源策略和 CORS 约束。用户在自己 Mac 上打开任意恶意
网页，该网页的 JS 就能执行 `new WebSocket("ws://127.0.0.1:8765")` 并成功握手——
**不需要攻击者在同一网段，不需要 Tailscale，不需要任何前置条件**。默认配置
（无 API key）下 100% 可用。

第二条路径：`BRIDGE_HOST` 默认 `0.0.0.0`，未设 key 时同网段/Tailscale 任意主机可连。

**解决方案**（两步，第一步一行代码即可封死浏览器路径）：

1. **立即**：`WebSocketServer` 增加 `verifyClient`，**拒绝任何携带 `Origin` 头的握手**。
   原生 App 客户端（Dart `WebSocket.connect`）不发 `Origin`，浏览器一定发。
   这条规则单独就能封死 drive-by 攻击，且对现有客户端零兼容性代价。

   ```ts
   this.wss = new WebSocketServer({
     server,
     verifyClient: ({ req }, done) => {
       if (req.headers.origin !== undefined) return done(false, 403, "Forbidden");
       done(true);
     },
   });
   ```

2. **随后**：首次启动时自动生成并持久化随机 API key，让"无认证"不再是默认状态。
   项目已有 QR / deep link 分发能力（`startup-info.ts`），用户不需要手输。

**兼容边界**：若未来要支持 Web 版客户端（项目有 `flutter build web` 流程），
Origin 拒绝需改为白名单反射校验，不能简单放开。

### 2.2 [Critical] SEC-2　权限模式由客户端决定，服务端无策略上限

**位置**：`parser.ts:1307-1314, 1504`、`websocket.ts:998-1002, 4010-4020`

```ts
// parser.ts:1307-1314 —— 仅做枚举合法性校验，无策略限制
msg.permissionMode !== undefined &&
![ "default","auto","acceptEdits","bypassPermissions","plan" ].includes(String(msg.permissionMode))
```

`permissionMode: "bypassPermissions"`（Claude）与 `sandboxMode: "danger-full-access"` /
`codexPermissionsMode: "fullAccess"`（Codex）**完全由客户端消息决定**。

**与 SEC-1 组合的完整攻击链**：连接（无需认证）→ 发
`{"type":"start","projectPath":"/Users/x","permissionMode":"bypassPermissions"}`
→ 发一条 `input` 含 Bash 指令 → Agent 以用户身份执行任意命令，
**全程不触发手机端任何 UI 授权**。

**防护层级倒置**：这个项目对**文件写入**做了密码 + Secure Enclave 的 step-up 授权
（实现质量很高），但对危险度更高的**Agent 任意命令执行**反而没有任何门禁。

**解决方案**：
1. 新增 `BRIDGE_ALLOW_BYPASS_PERMISSIONS`（默认 false）、
   `BRIDGE_MAX_PERMISSION_MODE`（默认 `acceptEdits`）服务端上限。
2. 客户端请求的模式与服务端上限取**较严格者**，而不是直接采信客户端值。
3. 未认证连接一律强制降级到 `default`。
4. 降级发生时通过既有的 additive 协议字段回告客户端实际生效模式，
   让 App 能显示"服务端已限制为 X"，而不是静默行为不符预期。

**兼容边界**：这是行为收紧，旧 App 发 `bypassPermissions` 会被降级。默认值选择要
保证正常使用流程不被打断（`acceptEdits` 覆盖绝大多数日常用途）。

### 2.3 [High] 其余高危项

| 编号 | 位置 | 问题 | 修复 |
|---|---|---|---|
| SEC-3 | `websocket.ts:8870-8951`、`screenshot.ts:88,141` | `list_windows`/`take_screenshot` 无 `isPathAllowed`、无 authorizer、无 capability 检查。可枚举全部窗口标题（泄露正在浏览的网页、聊天软件、密码管理器窗口名）+ 全屏截图，截图自动入 gallery 并 `broadcast` **给所有连接的客户端**。完整的屏幕监控能力，不受 `BRIDGE_ALLOWED_DIRS` 约束 | 纳入与文件写入**相同**的 step-up 授权体系（已存在且质量高，**复用勿重写**）。最低限度也要求 API key 已配置才注册这两个消息类型 |
| SEC-4 | `websocket.ts:1573-1578`（词法）vs `worktree.ts:204-205`、`git-operations.ts:83-85`（realpath） | `isPathAllowed` 只做 `path.resolve+normalize` 不解析 symlink，下游却用 realpath。允许目录内的软链（`~/proj/link -> /`）即可逃逸：客户端发 `projectPath: "/Users/x/proj/link/etc"`，`isPathAllowed` 按字面判断在 `$HOME` 内 → 通过；`resolveProject` realpath 到 `/etc` → Agent 以该目录为 cwd 全权读写。`get_diff`/`list_files`/全部 `git_*`/`list_worktrees` 走同一条不一致路径 | 抽出统一 `assertCanonicalProjectPath()`（realpath 后判定，对不存在路径拒绝）。**`read_file`（`websocket.ts:7847-8043`）已正确实现了 realpath + `isCanonicalPathAllowed` 双重校验，直接复用勿重写** |
| SEC-5 | `worktree.ts:249-253, 275-279` | `.gtrconfig` 的 `hook.postCreate` 用带 shell 的 `execSync` 执行：`for (const cmd of config.hook.postCreate) execSync(cmd, {cwd: wtPath, ...})`。用户 clone 任意第三方仓库（**这正是本产品的核心使用场景**）后在手机上点"创建 worktree"，仓库自带配置即以用户权限执行任意命令。无交互确认无授权提示。典型供应链攻击面 | 默认禁用 hook 执行；仅当用户在 **Bridge 端**（不是仓库端）通过环境变量或 `~/.ccpocket` 白名单该项目才启用；执行前必须走 UI 确认并展示将要执行的命令原文 |
| SEC-6 | `index.ts:241-280`、`file-transfer-manager.ts:356-390` | `fileMutationAuthorizer` 仅在设了 `BRIDGE_API_KEY` 时构造，未设时 `authorizer === undefined` → **整个授权分支被跳过**，密码/Secure Enclave 门禁根本不参与判断。默认配置下同网段任意主机可向 `~/Downloads` 写任意文件（上限 15 GiB）——既是磁盘填满 DoS 也是投放恶意 `.dmg`/`.sh` 的落地点。**附带**：即使设了 API key，若用户从未运行 `set-password`，`index.ts:250` 条件同样为 false → 仍无 authorizer，而启动日志写的是 "uploads locked until a Bridge password is configured"，**与实际行为不符**（并未 lock） | 无 authorizer 时**禁用上传能力**（不注册 upload capability），而非静默放行；同步修正启动日志文案 |
| SEC-7 | `auto-approval.ts:495-498, 595-617` | (a) `FileChange`/`Permissions`/`ExitPlanMode` 三类**无条件 `return true`**——含权限变更自身；(b) 重定向被 `__ccpocket_redirection__` 占位符剥离后再匹配，`echo x > ~/.ssh/authorized_keys` 被自动批准；(c) 解释器（python/node/perl）不在 deny 列表，`python -c "..."` 可执行任意代码 | `Permissions` 类**永不**自动批准；重定向目标纳入路径判定而非剥离；解释器加入 deny 或按参数深检 |
| SEC-8 | `terminal_launcher.dart:16-20` + `terminal_app.dart:36-37` | `.replaceAll('{{project_path}}', projectPath)` 注入进 `"blinkshell://run?key=ssh&cmd=ssh {{user}}@{{host}} -t 'cd {{project_path}} && \$SHELL'"`，路径含 `'` 即逃出 shell 引号 | 对替换值做 shell 引用转义；或改用参数化的 URL scheme |

### 2.4 [Medium/Low] 其余安全项

| 编号 | 等级 | 位置 | 问题 | 修复 |
|---|---|---|---|---|
| S-1 | Medium | `bridge-http-auth.ts:93-102` | 私有 HTTP 兜底授权基于"源 IP 曾有认证 WS 连接"，Tailscale exit node / NAT / 跳板机后共享出口地址即可无 token 访问 `/usage` `/doctor` `/api/gallery`（可下载全部截图） | 删除 IP 兜底，改 Bearer token；`<img>` 场景改用一次性签名 URL |
| S-2 | Medium | `websocket.ts:8283-8305`、`worktree.ts:267-286` | `remove_worktree` 只校验 `projectPath`，对客户端提供的 `worktreePath` 无任何校验，直接作为 hook 的 cwd 并传给 `git worktree remove --force` | `worktreePath` 必须 realpath 后校验位于 `<project>-worktrees/` 之下 |
| S-3 | Medium | `websocket.ts:10111-10131`、`sessions-index.ts:960,1218,1271,1692` | `list_recent_sessions`/`get_history`/`resume_session` 直接扫 `~/.claude/projects` 与 `~/.codex/sessions`，**完全不经 `BRIDGE_ALLOWED_DIRS` 过滤**。即使白名单收紧到单个目录，仍可列出所有项目路径并读完整对话历史（含粘贴过的密钥、内网地址） | 结果按 `isPathAllowed(session.projectPath)` 过滤；history/resume 加归属校验 |
| S-4 | Medium | `file-mutation-auth.ts:336-339, 484-511` | 密码失败计数以 **WS 连接对象为键的 WeakMap**，断开即清零 →"每 4 次尝试重连一次"完全绕过 5 次/30 秒限速；并行连接还能放大 scrypt(64MB maxmem) 内存 DoS | 计数改按对端地址 + 进程级 Map（带 TTL）；scrypt 并发信号量（≤2） |
| S-5 | Medium | `websocket.ts:1393, 3746-3748` | 无消息大小限制（ws 默认 maxPayload 100 MiB）、无速率限制、无并发连接上限。单条 100 MiB 消息经 `toString()` + `JSON.parse` 即 ~300 MB 瞬时占用 | `maxPayload: 8*1024*1024`；每连接令牌桶（50 msg/s）；最大并发连接数 |
| S-6 | Medium | `websocket.ts:1251-1254, 4822-4845` | `push_register` token 只校验 `typeof === "string"`，无长度/格式/数量上限，写入 4 个进程级 Map 且**不随连接断开清理** | token 正则 + 长度上限（≤512）；全局注册数上限 + LRU；断开时清理 |
| S-7 | Medium | `index.ts:329-334, 351-369` | `Access-Control-Allow-Origin: *` 无条件下发，`/version` 暴露 Node 版本、平台、**git commit 与分支名**，任意网页可跨源读取用于指纹识别 | 收窄 ACAO；`/version` 移入私有路由或删 git 字段 |
| S-8 | Medium | `functions/src/index.ts` | FCM token 归属未验证 —— 任意客户端可注册他人 token 或注销他人 token；App Check 为 no-op | 绑定 token 与认证身份；启用真实 App Check |
| S-9 | Medium | `session_list_screen.dart:484-490` | `_onDeepLink` → `_connectWithParams` **无任何确认**，随后 `machineManagerCubit.recordConnection(...)` 把攻击者的 host/token 持久化 | 深链连接前必须用户确认（展示 host/端口）。**注意**：QR 扫码路径（`screens/qr_scan_screen.dart:37-50`）需要用户物理对准摄像头，属真实意图，**无需**加确认——两条路径要区别对待，不要一刀切 |
| S-10 | Medium | `debug-trace-store.ts` 全文 | 见 2.5 专节 | 见 2.5 |
| S-11 | Low | `bridge-http-auth.ts:86-87`、`startup-info.ts:56-60,121-133` | API key 经 URL query `?token=` 传递，启动时明文 deep link + 二维码打到 stdout（launchd 日志永久留存） | 支持 `Authorization: Bearer`（Dart WS 支持自定义 header）；日志打码 |
| S-12 | Low | `websocket.ts:3760-3763` | `JSON.parse` 彻底失败时打印 `raw.slice(0,200)`；含密码的消息若因传输截断而解析失败，明文密码入日志 | 只打印长度与前 32 字节哈希 |
| S-13 | Low | `websocket.ts:1215-1220` | `debugEvents` 等以 sessionId 为键，单会话有 800 条上限但**会话数量本身无上限**，反复 `start` 可线性增长内存并 spawn 子进程 | 最大并发会话数；销毁时清理 Map |
| S-14 | Low | `git-operations.ts:683-692` | `createBranch`/`checkoutBranch` 未拒绝 `-` 开头的分支名（argv 形式使其难以实际利用，纵深防御） | 加 `--` 分隔或分支名正则白名单 |
| S-15 | Low | `mdns.ts:53-58, 82-85` | mDNS TXT 广播 `auth: "required"｜"none"`，告知同网段是否设了 key（darwin 默认不广播，实际风险低） | TXT 移除 `auth` 字段 |
| S-16 | Low | 多处，如 `websocket.ts:8296-8302, 8478-8482` | 错误分支普遍 `String(err)` 原样回显，Node fs 错误含完整绝对路径，可枚举白名单外目录结构 | 对外返回稳定 errorCode，详情仅入日志（`file-browser-manager.ts` 的 `normalizeError` 已是正确范式） |
| S-17 | Low | `prompt_history_service.dart:1254-1258` | `_redactBridgeUrl` 用 `uri.replace(query: '')` 去掉 `?token=`（**这部分是对的**），但保留 `userInfo` —— 用户手输 `ws://user:pass@host` 时凭据仍留存 | 一并清空 `userInfo` |

### 2.5 [Medium 安全 / P1 性能] 调试轨迹全量落盘，无门禁无上限无权限未脱敏（第 3 轮新增）

**位置**：`debug-trace-store.ts` 全文、`websocket.ts:12002-12018`（`recordDebugEvent`）、
`websocket.ts:12079-12148`（三个 summarize 方法）

**事实链**（逐条已取证）：

1. **始终开启，无门禁**。`recordingStore` 由 `BRIDGE_RECORDING` 环境变量控制
   （`index.ts:172` `const RECORDING_ENABLED = !!process.env.BRIDGE_RECORDING`），
   但 `debugTraceStore` **没有任何开关** —— `websocket.ts` 中 15 处 `recordDebugEvent`
   调用点全部无条件写盘，其中 `send()`（`:11603`）对**每一条出站消息**都记一次，
   `trackSessionMessage()`（`:10029`）对**每一条会话消息**都记一次。

2. **内容未脱敏**。
   - `summarizeClientMessage` 的 `case "input"`（`:12082-12086`）记录**每条用户提示词
     的前 80 字符**。
   - `summarizeServerMessage`（`:12111-12147`）记录 assistant 正文前 100 字符、
     **`tool_result` 内容前 100 字符**（即 Read/Bash 的输出——若 Agent 读了 `.env` 或
     `cat` 了私钥，前 100 字符即入盘）、`error` 消息原文。
   - **对照**：同一函数里 `push_register` 的 token 被正确截断为 8 字符
     （`:12088` `token=${msg.token.slice(0, 8)}...`）——**说明作者是有脱敏意识的，
     `input` 与 `tool_result` 未脱敏更像疏漏而非有意设计**。

3. **无上限、无清理**。`traces/<sessionId>.jsonl` 用 `appendFile` 永久追加
   （`debug-trace-store.ts:53-59`），`bundles/*.json` 每次请求一个文件，
   二者**都没有任何 prune / retention / 大小上限**。
   **注意内存侧有 `MAX_DEBUG_EVENTS = 800` 的上限**（`websocket.ts:12010-12013`）——
   **磁盘侧的缺失是明确的不对称，属遗漏**。用户当前数据规模已达 26 GiB × 2。

4. **无文件权限控制**。`mkdir`（`:21-22`）与 `writeFile`/`appendFile`（`:39, 57`）
   均未指定 `mode`，落到默认 umask（通常目录 0755 / 文件 0644）。
   **对照** `file-mutation-auth.ts` 对密码文件的处理：`O_NOFOLLOW|O_EXCL` + 0600 +
   `fsync` + 原子 rename + 读取校验 `(mode & 0o077) === 0`。
   **同一代码库里，密码文件保护严密，而包含对话正文的轨迹文件是全局可读的。**

5. **性能**：`record()` 每事件一次 `appendFile`（open+write+close 三个系统调用），
   按 path 串行。活跃会话每条出站消息一次。

**解决方案**（按优先级）：
1. 加环境变量门禁，**默认关闭**（与 `BRIDGE_RECORDING` 对齐）。
2. 开启时：目录 0700、文件 0600。
3. `input` 与 `tool_result` 的 detail 改为只记长度与类型，不记内容；确需内容时
   放在"高调试等级"下并在 UI 明示。
4. 加保留策略：单文件字节上限 + 轮转，bundles 按数量/时间 prune。
5. `record()` 改为带缓冲的批量 append（如 200ms 或 64KB 触发一次）。

### 2.6 [P2 隐私] 调试包内容与"粘贴到 AI 聊天"的 UX 冲突（第 3 轮新增）

**位置**：`utils/debug_bundle_share.dart:37-42, 159-209`、`websocket.ts:12068-12078`

**事实**：`copyDebugBundleForAgent` 把 bundle 转成文本复制到剪贴板，提示语是
`'Agent prompt copied. Paste it into your AI chat.'` —— **明确引导用户把内容粘贴给
第三方 AI**。而 `_buildDebugBundlePayload` 包含：`historySummary`（每条含 assistant
正文/tool_result 前 100 字符）、`debugTrace[].detail`（同上）、
以及**完整 git diff（上限 20 000 字符）**，全部**无脱敏**。

**已确认无问题的部分**：`reproRecipe.wsUrlHint` 是
`ws://localhost:${bridgePort}`（`websocket.ts:12184`），**不含 token** —— 这点是对的，
不要误报。

**评估**：这是用户主动触发的操作，不是漏洞；但用户很可能没有意识到自己正在把私有
代码 diff 与对话正文交给第三方。

**解决方案**：复制前弹一次确认，摘要说明"将包含：N 个文件的代码 diff、M 条对话摘要"，
并提供"不含 diff"选项（`includeDiff` 参数已存在，只是 UI 没暴露）。

### 2.7 [P2 安全] Gallery 在所有层都没有归属模型（第 3 轮新增）

**位置**：`websocket.ts:7627-7650`（`list_gallery`）、`websocket.ts:1403-1405` 与
`:3549-3552`（broadcast）

**事实**：
- `list_gallery` 分支**没有** `isPathAllowed(msg.project)`，也没有任何客户端归属校验。
  `msg.project` 由客户端提供且**可省略** —— 省略时 `galleryStore.list({})` 返回
  **全部项目的全部图片**。
- 新图片通过 `this.broadcast({ type: "gallery_new_image", image: info })`
  推送给**所有**已连接客户端，不区分项目、会话或客户端身份。

**与 SEC-3、S-1 的关系**：三者构成同一个缺口的三个面 —— 截图无授权即可生成、
生成后广播给所有人、且可经 HTTP 端点批量下载。
**应作为一个整体修复，而不是三个独立条目。**

**解决方案**：为 gallery 引入与会话一致的归属维度（bridgeInstanceId + projectPath +
sessionId）；`list_gallery` 按 `isPathAllowed` 过滤；broadcast 改为只发给对该项目
有可见性的客户端。

### 2.8 安全审查中确认实现良好的部分（**勿重写**）

这几处质量明显高于行业平均，后续实施要**复用**而不是重造：

- **`read_file` 的 TOCTOU 处理**（`websocket.ts:7847-8043`）：`lstat` → 拒目录 →
  `open()` 拿 fd → `handle.stat()` → `realpath` → `stat(canonical)` →
  `sameOpenFileStats()` 比对 dev/ino/size/mtime → 对 canonical 路径做
  `isCanonicalPathAllowed` → 后续读取全走已 pin 的 fd。open-then-verify 顺序正确，
  TOCTOU 窗口被 identity 比对覆盖。
- **File Browser 的路径模型**（`file-browser-manager.ts`）：从不序列化绝对路径，
  只暴露不透明 `rootId` + 相对路径；每次操作重新 realpath 并复检；native backend 传
  `sourceParentIdentity`(dev/ino) 防目录被换。
- **密码 verifier**（`file-mutation-auth.ts:161-205, 247-326`）：scrypt N=2^15，
  16 字节盐，`timingSafeEqual`，格式非法时仍走一次 scrypt 保持时序一致；落盘
  `O_NOFOLLOW|O_EXCL` + 0600 + `fsync` + 原子 rename，读取校验
  `(mode & 0o077) === 0`。改密码吊销全部生物识别设备。
- **Secure Enclave challenge**（`file-mutation-auth.ts:369-475`）：challengeId 24 字节
  随机；payload 绑定 `bridgeInstanceId` + nonce + `operationDigest` + `expiresAt`；
  验证时**无论成败先 delete**，杜绝重放；校验 client/deviceId/过期/operationDigest
  精确匹配。
- **API key 比较**：先 SHA-256 再 `timingSafeEqual`，固定 32 字节，无长度泄露；
  输入超 4 KiB 直接拒绝避免哈希 DoS。
- **所有 spawn/exec 点**（约 30 处）均用 argv 数组形式，无 shell，文件列表操作一律带
  `--` 分隔符。唯一例外是 SEC-5 的 hook。
- **无 zip/tar 解压逻辑**，不存在 zip-slip 面。
- **通知隐私门禁无绕过路径**（第 2 轮逐条验证）。
- **per-client 游标隔离**真实实现（以 WebSocket 为键的 WeakMap）。
- **Side Chat 真实使用官方 `thread/fork` + `ephemeral: true`**
  （`codex-process.ts:2698-2705`）并有三重契约校验（`:2745-2761`）；
  **全库无硬编码 30min/1800/TTL**；`ephemeral_side_chat_pane.dart:191-203` 真实复用
  `CodexSessionScreen`。这三点与交接文档的怀疑相反，**已澄清，勿再调查**。
- **`_redactBridgeUrl`**（`prompt_history_service.dart:1254-1258`）正确剥离了
  `?token=` 查询串（仅 userInfo 待补，见 S-17）。
- **`reproRecipe.wsUrlHint` 不含 token**（`websocket.ts:12184`）。
- **QR 扫码路径无需额外确认**（`screens/qr_scan_screen.dart`）——需用户物理对准
  摄像头，属真实意图表达，与深链路径性质不同。

---

## 第 3 章　交接文档 E.1 三项任务的具体方案

### 3.1 任务 1：`341b2a26` 的时间归属收束

`341b2a26` 主干实现是干净的：`_TimestampWidget` 已彻底删除，全库无其他居中时间行
实现；权威时间链路无污染（`receivedAt` 仅在 Bridge 接收时刻打戳 `session.ts:1458`，
合并时 `??=` 保留原值，App 端 `isBridgeReceived` 仅来自 `receivedAt`，
`_preferredTimestamp` 从不把非权威提升为权威）。

**遗留：4 类可见消息完全没有时间显示。**

| 类别 | 位置 | 现状 | 解决方案 |
|---|---|---|---|
| 孤立 ToolResultBubble | `message_bubble.dart:199-215`、`tool_result_bubble.dart:26-49` | `ServerMessageWidget` 收到了 `timestamp`（:137），但构造 `ToolResultBubble` 时**未传递**；组件本身无 timestamp 参数 | 加 `ChatMessageTimestampData? timestamp`，在 `_CollapsedToolResult`（chevron `Icons.chevron_right` :420）与 `_ExpandedToolResult`（`Icons.expand_less` :518-522）头行的**箭头左侧**渲染，与折叠组一致 |
| inferred error | `assistant_bubble.dart:216-229`、`error_bubble.dart:75-79` | 短文本被 `inferStructuredErrorCode` 判为错误时直接 `return ErrorBubble(...)`，`widget.timestamp` 被丢弃；真实 `ErrorMessage` entry 同样无时间 | `ErrorBubble` 增加可选 timestamp，置于气泡内 trailing |
| plan / card | `assistant_bubble.dart:400-407` | 时间只经 `MessageActionBar` 呈现且受 `if (hasTextContent)` 约束；ExitPlanMode 若无 TextContent（真实 SDK 把计划写入文件的形态，见 :316-321 注释），PlanCard 展示但无操作栏 → 无时间 | 无正文时也渲染精简操作栏（仅时间），或 PlanCard 自带 trailing 时间 |
| 图片结果 | `tool_result_bubble.dart:281-359`、`chat_message_list.dart:1091-1092, 598-601`、`tool_result_bubble.dart:526-532` | 三条路径（`_ImageGenerationResultCard`、`GeneratedImageChatGroup` 锚点渲染、展开态内嵌 `ImagePreviewWidget`）全部无时间 | 统一由承载它们的 group/bubble 头行提供时间，不在图片本身加 |

**第二条渲染路径需要单独设计**：`chat_message_list.dart:1409-1426` 的
`_HistoryToolDetailGapView`（按需加载的历史工具结果）**没有 ChatEntry**，
本就拿不到 entry 时间，需要从 detail 响应自身取时间源。

**另需产品决策登记**：`GuardianApprovalNotice`、`ResultChip`、
`PermissionRequestBubble`（`message_bubble.dart:216-238`）是否需要时间。

**同时必须修的溢出问题（P2）**：`chat_process_disclosure.dart:328-334` 的
`ChatCurrentToolActivityLine` 的 `displayName` Text **无 Flexible/ellipsis**。
行内固定宽度 = icon(12) + 间距 + 状态词("正在使用"≈44px) + displayName(不限宽) +
timestamp(≈50px，341b2a26 新增) + chevron(15)。
`getToolDisplayName` 对未知名兜底 `_ => name`（`tool_categories.dart:218`），
MCP 长名（如 `mcp__chrome-devtools__take_screenshot`）原样透出。
窄屏（320/280pt）中文场景必然 RenderFlex 溢出，时间戳/箭头被顶出。
→ `Flexible(child: Text(..., overflow: ellipsis))`。

对比：`ChatProcessDisclosure` 标题有 Flexible+ellipsis（:63-73）、
`ChatIntermediateOutputsDisclosure` 有双 Expanded（:145-172），说明**模式已存在，
只是新增行漏了**。

### 3.2 任务 2："重复两次"的取证 —— 已定位 4 条可疑机制

**候选 A（最可疑，P0-3）**：`session_runtime_store.dart:101-110` +
`bridge_service.dart:1509-1526` 的 legacy HistoryMessage 无代际栅栏。详见 1.2。

**候选 B（第 2 轮新增，与症状高度吻合）**：`session.ts:635-682` 的
`commitReplacement` **不携带**去重状态字段 —— `codexLatestUserInput`、
`codexUserTurnUuidByRawId`、`pendingCodexUserEchoUuids` 三者在每次 Desktop continuity
turn 时全部丢失。去重状态一丢，同一条用户输入的回显就会被当成新消息再插一次，
**症状与"重复两次"完全一致**。

**候选 C**：`bridge_service.dart:1842-1845, 2215-2231` —— 旧 Bridge 的 unscoped
`unsupported_message` 错误会一次性对**所有** pending session 调用
`_fallbackPendingHistoryDeltaRequests()`（`sessionIds = List.from(keys); clear();`
遍历全部 session 各自发 getHistory），一条错误驱动 N 个会话同时全量拉取（雪崩）。

**候选 D**：`chat_message_list.dart` 的 live/persisted 双 surface（见 3.4），
同一内容在两个 surface 间迁移时的视觉重复。

**取证方案**：按交接文档要求做 raw → Bridge → Mirror → reducer → render 五层快照，
但在 reducer 层重点记录 `historySeq` 的变化序列与 `contentEpoch`，以及每次
`applyServerMessage` 的触发来源（哪个 caller）。

**建议**：先直接修候选 B（改动小、风险低、与症状吻合度最高）与候选 A，再看是否复现。

### 3.3 任务 3：optimistic entry 替换的 provenance 漂移 —— 已确认真实缺陷

**位置**：`chat_session_cubit.dart:2295-2313`

```dart
existingUserData['text:${e.text}'] = e;   // :2301，同文本后写覆盖先写
```

无 UUID 时用 `'text:${e.text}'` 作 map key，:2313 按同 key 回查。
**两轮内容相同的用户消息会共享同一 entry**，图片 bytes 与本地时间戳互相污染
（:2324-2339 的合并逻辑用错对象）。

现有测试覆盖了"有 UUID 的重复 prompt"和"重复 assistant text"，
但**没有覆盖**"两个无 UUID、文字相同、图片/时间不同的 user turn"。

**解决方案**：fallback key 加入出现序号（`text:<hash>:<occurrence-index>`），
或改为按顺序双指针匹配而非 map。同时补上述缺失的回归测试。

### 3.4 附加：`78f83eb1` 的过程框统一程度（交接文档记为"已实现并通过定向回归"）

**已完成**：`entry:`/`live:` 双身份已统一为 `_currentProgressKey(turnKey)` =
`'turn:<turnKey>'`（`chat_message_list.dart:1171, 857, 1049`），
测试也已改为 `chat_current_progress_turn:...`。

**但双 surface 本身没有合并**（v02-009 断言的核心，仍成立）：

- persisted viewport key = `process_details_viewport_current_$progressKey`（:711）
- live viewport key = `live_process_details_viewport_$progressKey`（:911-913）
- 且挂在**不同的 ListView item**（persisted 锚在 summary entry，live 锚在列表末端）

thinking delta 会置 `isStreaming=true`（`streaming_state_cubit.dart:73-80`），
而 `isCurrentSegmentEntry` 要求 `!hasStreaming`（:1041-1044）。所以：
**工具运行中（persisted 框）→ thinking 到达 → persisted 框整体消失，live 框在别处
重建，且 live 展开态只渲染 tool line + live thinking（:917-944），不含
`_buildProcessSegmentDetails` 的既有过程内容 → 已展开的过程明细视觉上"蒸发"。**
新工具 assistant 消息到达、streaming reset 后又切回 persisted 框。
每次切换丢失内部滚动位置并重建 State。

**连带缺陷（P2）**：`chat_message_list.dart:1200-1242` 的
`_ProcessDetailsViewportState` 持有 `_guardianTimer`，上述 key 不同导致 State 重建，
`initState → _syncGuardianReview` 把 `_showGuardian` 重新置 true →
**同一 review 的 3 秒 Guardian 通知重复出现、总时长超约**。
→ 把 3 秒计时提到不随 surface 重建的层（cubit 或按 identity 缓存的上层 State）。

**其余两个缺口**：
- streaming 分支 turnKey 回退链 `turn?.key ?? processLayout.latestTurnKey ?? 'session:<id>'`
  （:853-857），布局尚无 turn 时用 `session:` 身份，稍后 turn 出现则 key 变化，
  展开状态丢失。
- `_expandedCurrentProgress` 与 `_expandedProcessSegments`/`_expandedIntermediateTurns`
  相互独立：turn 结束、当前过程降级为历史 segment 后展开状态不迁移，
  用户展开的框会自动收起；旧 key 永不清理（仅 collapse-all 清空）。

**八行框视觉（v02-009 要求）已大部分完成**（:1274-1315 已有边框 `outlineVariant`
alpha 0.8、底色 `surfaceContainerLow`、圆角裁剪、`Scrollbar`），
剩余：Scrollbar 未设 `thumbVisibility`（iOS 静止时不可见，等同无溢出提示）、
无渐隐/"还有 N 项"暗示、框水平 padding 为 0（:1276-1281，边框贴屏幕边缘，
与消息气泡缩进体系不一致）。

---

## 第 4 章　按层完整问题清单

> 第 1~3 章已详述的不再重复。

### 4.1 Mobile —— 连接与会话目录

| 编号 | 级别 | 位置 | 问题 | 解决方案 |
|---|---|---|---|---|
| C-1 | P2 | `bridge_service.dart:3540, 1419, 5033, 3459-3462` | `_lastSessionCatalogRevision` 仅在 bridge 切换或主动 disconnect 时归零，**同目标自动重连不清零**。网络闪断 + Bridge 进程已重启（同 URL）时新进程 revision 从小值重新计数 → `if (revision <= _lastSessionCatalogRevision) return` 把所有 `session_catalog_changed` 当旧事件丢弃，**目录实时刷新静默失效** | 重连成功（connection epoch 变化）或收到新 session_list 时重置该值 |
| C-2 | P2 | `session_list_cubit.dart:630-634` | `_loadCatalogCacheForCurrentTarget` 把 DB 快照写回 `_loadedCacheFingerprint/Revision/Complete/_cachedSessions` 发生在 `networkSerial` 新鲜度检查**之前**（检查只护住 emit），`upsertResponse` 又是 fire-and-forget。load 进行中收到完整 catalog 网络响应时，load 以旧 DB 内容完成 → 旧快照回写 → 下一条响应因 revision 不匹配走 `_loadedCacheComplete = false`，**缓存完整性被误失效** | 赋值移到 `networkSerial == _networkCatalogSerial` 检查之后，或网络路径也递增 `_cacheLoadGeneration` |
| C-3 | P2 | `session_list_cubit.dart:134-136` + `session_catalog_cache_repository.dart:106-147` | 每条 `sessionList` 广播（会话状态每次变化 Bridge 都 broadcast）都无条件触发 `repository.load()`：**全分区 SELECT（上限 10 000 行）+ 主 isolate 上逐行 `jsonDecode`** | 仅当 `_currentCacheTarget()?.fingerprint` 相对上次 load 变化时才重载 |
| C-4 | P2 | `session_list_cubit.dart:222-236, 697-711` | 遗留 Bridge（无 catalogRevision）路径 `canDisplayLegacyCompleteCache` 强制 `hasMore = false` 且 `_mergeCachedSessions` **无 tombstone 机制**，服务器已删除的会话以"幽灵"常驻，且用户无法分页拉真实数据 | legacy 无 revision 时只做展示合并不封死分页；或对 legacy 完整响应以 live 集合为准做删除对齐 |
| C-5 | P2 | `bridge_service.dart:3288-3296` + `session_list_cubit.dart:426-430` | 全局 loadMore 的 `offset: offset ?? _recentSessions.length`，而 `_recentSessions` 会被 project 页合并（:1609-1613）与 catalog 前缀替换（:1614-1622）**撑大**。先展开某项目组加载 20 条再触发全局 loadMore → offset 跳过全局排序中从未加载的区段，**静默丢行** | 单独维护全局分页游标（服务端 offset + 返回条数累计），与 project 合并解耦 |
| C-6 | P2 | `bridge_service.dart:3292`、`session_list_cubit.dart:464-469` | offset 分页仍**无 snapshot token/revision 固定**，响应虽回显 `catalogRevision` 但请求不 pin revision，目录在两页之间变化时重复/丢行 | 新协议用 snapshot revision + opaque cursor；旧 Bridge fallback 把同 query 的 offset 请求串行化 + 响应后 stable-key 去重 |
| C-7 | P3 | `bridge_service.dart:2004, 357-359, 3321-3324` | `_clearBridgeScopedState` 重置 `_currentProjectFilter` 但**不重置** `_currentProvider/_currentNamedOnly/_currentSearchQuery`。切换 Bridge 后、`refreshCatalog` 重发 `switchFilter` 之前的窗口内，`requestRecentSessions()` 会带上一台 Bridge 的过滤条件请求新 Bridge | 一并清空三个字段 |
| C-8 | P3 | `bridge_service.dart:3400-3409, 3426-3427` | 遗留串行队列无超时 watchdog：`_legacyRecentSessionsRequestInFlight` 只在收到 recent_sessions 或重连时释放；旧 Bridge 以 error 响应或丢弃时，**此后所有目录请求滞留队列直到重连** | 为 in-flight 请求加超时释放 |
| C-9 | P3 | `session_list_cubit.dart:36-38` + `bridge_service.dart:3454-3457` | `SessionCatalogQuery.matches` 与 `_recentSessionRequestScopeKey` 的 projectPath 用**原始字符串比较**，而同文件 :784-790 的 `_normalizedProjectPath` 处理尾斜杠/反斜杠。回显形式不一致时响应被静默丢弃，骨架屏悬挂 | 比较前统一归一化 |
| C-10 | P3 | `parser.ts`(02128669 新增校验) + app 侧无兜底 | 新校验对 `searchQuery > 512`、`requestId > 128` 直接令 `parseClientMessage` 返回 null，Bridge **静默丢请求**；app 端搜索框未截断、目录请求无超时 → 粘贴超长文本进搜索框则骨架屏无限等待 | app 侧发送前 clamp searchQuery（≤512）；带 requestId 的请求加超时回退 |
| C-11 | P3 | `session_list_cubit.dart:582-592` + `session_list_screen.dart:1551-1563` | rename 乐观更新只改 `state.sessions`，不触达 `_cachedSessions` 与持久缓存；重命名不在首页 20 条内时，界面会被缓存旧名回退 | `updateSessionName` 同步更新 `_cachedSessions` |
| C-12 | P3 | `session_list_cubit.dart:582-592` | rename 乐观更新仍**只按 raw sessionId 匹配**（`if (s.sessionId == sessionId)`），无 provider/projectPath 维度（A5 残留漏口之一） | 改用与 pin 一致的 provider+projectPath+sessionId 三维键 |
| C-13 | P3 | `session_list_screen.dart:1324, 1334` | 每会话 Claude 设置持久键 `'claude_session_settings_$sessionId'` **无 provider/Bridge 维度**（A5 残留漏口之二） | 键加入 bridgeInstanceId + provider |
| C-14 | P3 | `messages.dart:4490-4494`、`session_card.dart:2896-2901` | `displayText` 仍返回硬编码 `'(no description)'`，`SessionDisplayMode.last` 分支还有第二处硬编码，**且未本地化** | 按 v02-008 区分"尚未加载 / 权威空 / 解析失败"三态；文案入 ARB |
| C-15 | P3 | `messages.dart:113-120`、`session_visual_status.dart:54-80`、`session_card.dart:100-105` | `ProcessStatus.fromString` 兜底 `idle`；`sessionVisualStatusFor` 兜底 Ready（绿色）。未来官方新增 wire status 会被**静默伪装成可用/空闲** | 保留 raw/unknown，显示中性兼容状态，不伪造 idle |
| C-16 | P3 性能 | `home_content.dart:459-470, 489-540` + `session_list_projection.dart:64-125` | 外层 `ListenableBuilder` 合并监听 NotificationService/FileTransferService/shell，**任一通知**都走 `_buildContent`：全量重建 catalogSessions（mirror 元数据映射 + 全字段 lowercase 过滤）+ `buildUnifiedSessionList` 全列表建 map、排序。千级目录 + 高频广播时主线程负载明显 | 对投影结果按 (sessions, recentSessions, filters) memoize，或把过滤/排序下沉到 cubit 状态 |
| C-17 | P3 | `websocket.ts:7054-7060`(02128669) | `catalogRevision: this.sessionCatalogMonitor.currentRevision ?? 0` 在**异步列举的 `.then` 回调里**读取——列举期间 monitor 完成新一轮扫描时，响应把**旧内容标记为新 revision**；与 C-18 组合会把旧列表固化为"当前 revision 的完整缓存" | 开始列举时快照 revision；结束时 revision 已变则标记响应不可作为完整快照 |
| C-18 | P1 | `session-catalog-monitor.ts:93`（`private revision = 0`）+ `websocket.ts`（02128669 引入的 `catalogRevision`）+ `session_list_cubit.dart:214-236` + `session_catalog_cache_repository.dart:851-861` | `catalogRevision` 是 **Bridge 进程内存计数**，Bridge 重启后从 0 重新计数；而分区键 `bridgeInstanceId` 跨重启**稳定持久**。手机持久缓存记录 `complete_revision=N` 后，Bridge 重启、离线期间目录变化、重启后 revision 恰好再次到达 N 时重连 → `canReuseCompleteCache` 仅比较 `response.catalogRevision == _loadedCacheCatalogRevision`（:218-220），命中即 `hasMore = false` 并把**陈旧缓存与首页 20 条合并展示**（:230-236）——**已删除的会话复活，后续分页被封死**。这是 `02128669` + `6cddb80c` 这两个新提交引入的最实质风险 | Bridge 端 revision 以持久单调值（时间戳或持久计数）初始化，或响应中附带 boot epoch；移动端把 `(epoch, revision)` 作为比较元组 |

### 4.2 Mobile —— 会话打开与历史同步

| 编号 | 级别 | 位置 | 问题 | 解决方案 |
|---|---|---|---|---|
| H-1 | P1 | `session_list_screen.dart:1742-1765`、`session_link_screen.dart:99-130`、`lib/router/app_router.gr.dart` | **`durableProviderSessionId` 三条入口全缺**：手机端点 recent/running 会话走 `context.router.push(ClaudeSessionRoute/CodexSessionRoute(...))`，两个 Route 调用均不传该参数；`grep durableProviderSessionId lib/router/app_router.gr.dart` **零命中**（生成的路由类里根本没有这个字段），screen 构造参数恒为 default null。后果链：`_startDurablePreview` 直接 return（`claude_session_screen.dart:208-209`）→ 无缓存秒开、无 `setFocusedConversation` 优先级提升、既有会话仍显示"正在创建会话"（`claude_session_screen.dart:541-546`、codex 同 588-592 的 `durableId == null ? l.creatingSession : l.loadingSessionStatus`）。**只有 embedded workspace 路径（`workspace_shell_screen.dart:1187,1205`）生效** | 1. 给 `ClaudeSessionRoute`/`CodexSessionRoute` 增加 `durableProviderSessionId` 参数并 `dart run build_runner build`；2. **三处** push 调用全部传入；3. **补手机端路径的 widget test**——现有测试只覆盖 embedded 路径，这正是缺陷能通过既有回归的原因 |
| H-2 | P2 | `bridge_service.dart:316-317, 3558-3583` | history pending maps 以 sessionId 为键、无 requestId 关联；`_pendingHistoryDeltaAllowsFullFallback[sessionId] = allowFullFallback` 并有注释 "The latest caller owns the fallback policy"（**明示 latest-writer-wins**）。前台请求（fallback=true）可被随后的后台 delta-only 请求覆盖 | 按 (sessionId, requestId) 关联；策略**合并取 OR** 而非覆盖 |
| H-3 | P2 | `bridge_service.dart:4846-4851` | `messagesForSession()` 的 `.where((pair) => pair.$2 == null \|\| pair.$2 == sessionId)` 仍把无 sessionId 的消息**广播给所有 chat cubit**（含 error、status），造成跨会话串扰 | 基础设施事件进 connection/error channel；无标签消息建单独 legacy 单会话兼容通道 |
| H-4 | P2 | `claude_session_screen.dart:495`、`codex_session_screen.dart:539` | 预览子树 key 含 `cachedPreview.revision`，**每次 Bridge 增量 commit 都整树销毁重建**：全部 cubit/列表/滚动位置销毁，且 `initialHistoryMessages` 对最多 2000 条 entry 在**主线程**逐条 `decodeMessage()`（:503-505）。高频 patch 下预览页持续跳动 + 卡顿 | key 去掉 revision；改为向既有 detached cubit 增量注入新快照 |
| H-5 | P2 | `claude_session_screen.dart:202, 229-257` | 非 pending 的运行会话页面每次 patch commit 做一次"读库 + 全量解码 + 丢弃"的空转：`_startDurablePreview` 无条件订阅 `sync.updates` 并 load，完成后因 `!_isPending` 直接 return（:241-244），**结果被扔掉**。流式输出时每个增量提交触发一次 sqlite 读 + 最多 2000 条 JSON decode | 非 pending 时只 `setFocusedConversation`，不订阅 updates、不 load |
| H-6 | P2 | `conversation_content_sync_service.dart:534-537, 349-403`、`session_catalog_cache_repository.dart:384-388` | `_restartSubscription` **无退避**：快照校验失败或 `entries.length > maxHotWindowEntries(2000)` 抛 StateError → 立即 unsubscribe + 立即 resubscribe → Bridge 再推同一坏快照 → **无限紧凑循环**，每轮传输整个热窗口。`_scheduleRetry` 的 2 秒 timer 不覆盖 restart 路径 | restart 走 `_scheduleRetry`（递增退避）；对同一 (session, revision) 连续失败计数熔断 |
| H-7 | P3 | `conversation_content_sync_service.dart:156-178, 306-309` | subscribe 握手期间的 focus 变更被静默丢弃：`_activeSubscriptionId == null` 时只记录 `_focused` 不发送（:166 return），`subscribed` 到达后不回放差异 → 握手窗口内点开会话，**优先级提升永不生效** | 处理 `subscribed` 时比较当前 `_focused` 与 subscribe 时发送值，不一致则补发 |
| H-8 | P3 | `conversation_content_sync_service.dart:298-309` vs `conversation-content-sync.ts:294` | 客户端**隐式假设** `subscribed` 事件的 `subscriptionId == requestId`（当前 Bridge 恰好如此）。任一侧改为服务端独立分配 id，`subscribed` 会被顶部 guard 吞掉 → `_pendingSubscriptionId` 永不清除、无 error、无 retry，直到断线重连。协议耦合未在两侧注释/测试中固化 | `subscribed` 分支放宽顶部 guard（按 requestId 匹配）+ 协议注释 + 契约测试 |
| H-9 | P3 | `conversation_content_sync_service.dart:479-484` | `error` 事件只处理 pending subscribe 场景；作用于 active subscription 的错误被完全忽略，既不重订阅也不上报，可能静默停摆 | error 无 requestId 匹配但 subscriptionId 为 active 时执行带退避的 restart |
| H-10 | P3 | `conversation_content_sync_service.dart:225-231` | delivery mode 离开 interactive 时只 `_stages.clear()` 保留 active subscription，期间 patch 全被丢弃；恢复后 `_ensureSubscribed` 因 `_activeSubscriptionId != null` 早退，下一个 patch 因 baseRevision 不匹配 → **删除整个本地窗口 + 重订阅全量重传**。能自愈但代价是整窗重建 | 非 interactive 时与 lifecycle 一致地 `_stopSubscription(sendUnsubscribe: true)` |
| H-11 | P3 | `claude_session_screen.dart:229-257` | `_loadingCachedPreview` 防重入 guard **丢更新**：load 在途时到达的 update 被跳过且不重排，若其为最后一次事件，预览停留在旧 revision | in-flight 期间置 dirty 标记，whenComplete 时若 dirty 再 load |
| H-12 | P3 | `chat_session_cubit.dart:284-286, 336-339` | detachedPreview cubit 把状态硬编码 `ProcessStatus.idle` 且跳过 `_respondedToolUseIds` 恢复：正在 running 的会话在预览中显示 idle；缓存 history 中未响应的 approval 会渲染出审批 UI（approve/reject 已 guard 为 no-op，**点击无任何反馈**） | 引入独立 preview 状态标识用于 UI 呈现，隐藏审批交互条 |
| H-13 | P3 | `session_catalog_cache_repository.dart:536-539, 545-549` | `close()` 只 await 当前 `_mutationTail`，await 期间新入队的 mutation 会在 DB close 后执行并报 `StateError`；service 层会把它当普通失败触发重订阅 | close 时置 closed 标志拒绝新 mutation |
| H-14 | P2 | `claude_session_screen.dart:493-508` vs `553-554` | 即使修复 H-1，preview→绑定成功时 key 仍从 `ValueKey('durable-claude-$durableId-$revision')` 切到 `ValueKey(_sessionId)`，**整个 provider 子树销毁重建**，预览期的展开/滚动状态仍丢失 | durable screen identity 与 runtime ID 解耦 |
| H-15 | P1 | `chat_session_cubit.dart:439-453` | starting 状态每 3 秒无限请求 history：`Timer.periodic(const Duration(seconds: 3), ...)` **无总 deadline、无指数退避**。唯一缓和是 mirror bootstrap 成功时跳过 1 个 tick。Timer 只在状态离开 starting 或 `close()`（:5325）时取消。会话永远不 resolve 时，每 3 秒发一次 get_history 直到页面关闭 | 总 deadline（如 30s 后转可重试错误态）+ 指数退避（3s → 6s → 12s，上限 60s）。这也是交接文档 `HistorySyncArbiter` 设计的最小可落地版本 |

**审查中确认良好、不要重写的部分**：repository 的 mutation FIFO 队列保证
snapshot→patch 落库与 ACK 顺序；`applyConversationPatch` 的 baseRevision 比对 +
事务内 count/DISTINCT index 校验 + 失败即删窗重拉是正确的幂等/回退设计；
hot_entries 通过 FK ON DELETE CASCADE 避免孤儿行；`_ensureSubscribed` 的
generation/fingerprint 双重 fence 对迟到帧的防护充分。

### 4.3 Bridge 服务端

| 编号 | 级别 | 位置 | 问题 | 解决方案 |
|---|---|---|---|---|
| B-1 | P1 性能 | `conversation-content-sync.ts:849-859`、`sessions-index.ts:3362-3438` | **每次增量推送都做全目录扫描 + 整文件重解析**。触发：任何 catalog 变化或运行时消息（`websocket.ts:9778` `localFeatures.sessionMessage`，**每条非 delta 消息触发一次**）→ `enqueue` → `drain` → `readDurableHistory`。代价：(a) 路径解析——Claude 侧 `findSessionJsonlPath` **逐个读取所有项目目录的 sessions-index.json 再逐目录 stat**（:3362-3415）；Codex 侧 `findCodexSessionJsonlPath` 全树遍历，文件名不匹配时还要**逐文件流式读 session_meta**（:3417-3438, 3586-3603）；(b) 再从头到尾流式解析**整个 JSONL**（:3609+, :4270+）。**无 path 缓存、无 append-only 增量读**。焦点会话 priority=0 时 `queueMicrotask` 立即 drain（:531-538），活跃 turn 中**每个 tool_result 都触发一轮"全目录扫 + 全文件读"**。用户数据规模：两套 sessions 各约 26 GiB，最大 rollout 约 2.81 GB | per-conversation 缓存 `jsonlPath` + `readOffset`；path 解析结果按 (provider, sessionId) 缓存并用 mtime/inode 失效。**`getCodexDesktopToolTimeline`（:3474-3568）已实现 append-read 增量模式，现成范式直接复用** |
| B-2 | P1 性能 | `conversation-content-sync.ts:140-152, 425-453, 753-763` | catalog 刷新以 `limit=10000` 全量扫描：默认 `catalogReader` 为 `getAllRecentSessions({limit: 10_000, offset: 0})`，不仅触发全量扫描-解析-全排（见 B-3），还使 `supplementLastPrompt`（`sessions-index.ts:1213-1231`）对**整个结果集**中缺 lastPrompt 的 Claude 条目做增长式 tail 读（每条最多 128 KB）——而 catalog **只用到 `provider/sessionId/modified`**（:459-466），**lastPrompt 全部白读**。该刷新在每次 subscribe/warm、每个 unscoped change、以及 45s~5min 的冷扫定时器上反复执行 | 为 catalog 提供轻量 reader（跳过 supplement 与全部文本字段），或给 `GetRecentSessionsOptions` 加 `fields` / `skipLastPrompt` 开关 |
| B-3 | P1 性能 | `sessions-index.ts:946-1238` | `getAllRecentSessions` 每次调用（默认 limit 20）都会：遍历全部项目目录并 hydrate/scanJsonl（:996-1095）→ 走全部 Codex rollout（:1097-1113 → :1961-2021 → `listCodexSessionFiles` 全树遍历）→ 全量排序（:1197-1201）→ 再 `filtered.slice(offset, offset+limit)`（:1205）。**无 mtime 缓存、无增量索引** | 建立按 path + inode/size/mtime 的 metadata cache，只重算变化项；优先使用官方 app-server/SQLite 结构化元数据，JSONL 只做有界尾部校验和兼容 fallback |
| B-4 | P1 | `sessions-index.ts:1271, 1797, 1824, 1857, 1871-1875, 1909-1913, 1948`；Claude 侧 :960, 1218, 1692, 3363 | Codex/Claude 路径**全部硬编码 homedir**，`grep CODEX_HOME` 零命中，无 source registry。而 Codex 子进程（`codex-transport.ts:47/59 env: process.env`）**会继承**用户环境的 CODEX_HOME → Bridge 扫描目录与 app-server 实际写入目录**可能不一致** | 引入 `resolveCodexHome()`（读 env/config），所有路径构造走该入口 |
| B-5 | P1 | `session-catalog-monitor.ts:38, 112-118, 165-173, 184-211` | watcher 上限 1024；`defaultRoots()` 顺序 claudeProjects → codexRoot → codexSessions（:40-59）按序 await，`~/.claude/projects` 下项目 ≥1023 个时 **Codex 目录一个 watcher 都装不上**；且 cap 在子目录层被打到时 `rootInstalled=true` → 不安排 rescan → **永久不自愈** | 按 root 预留配额（codexSessions 保底 N 个）；目录消失时主动清理；cap 命中时上报 degraded |
| B-6 | P1 | `codex-desktop-continuity.ts:587-611` | `watchersByClient` 以 (client, sessionId) 为键，**last-write-wins 且静默移除前一个 watcher，不通知前者**。home tracker 与打开的 chat cubit 共享同一个 WebSocket 客户端对象 → 后注册者踢掉前者，前者永不知情 | 改为引用计数 / 多订阅者模型，或键加订阅者身份 |
| B-7 | P2 | `websocket.ts:10134-10170` | all-provider 路径并行执行 `getAllRecentSessions`（未传 provider → 完整解析所有 Codex rollout）与 `listRecentCodexSessions`（thread/list），合并时 `mergeRecentSessionPages` 按 `provider:sessionId` 保留首个 → **扫描侧对全部 Codex rollout 的 head+tail 解析结果被整体丢弃** | all-provider 路径给 `getAllRecentSessions` 传 `provider: "claude"`；Codex 仅在 thread/list 失败时回退扫描 |
| B-8 | P2 | `sessions-index.ts:2023-2054, 2096-2135` | `getCodexSessionIndexMetadata` 先全树遍历，对每个文件 `for (const threadId of wantedThreadIds) { endsWith(...) }` → **O(files × wanted)**。已存在的优化入口 `getCodexSessionIndexMetadataForFiles`（注释明确说 thread/list 调用方应改用它）**并未被使用**——`websocket.ts:10922` 仍调旧版 | 切换到 ForFiles 变体；否则至少把 endsWith 改为按 uuid 提取后 Set 查找 |
| B-9 | P2 | `conversation-content-sync.ts:328-347, 601-623` | `pendingRevisions` **永不超时**：revision 是内容哈希，客户端应用层丢弃消息（未 ack 也未断线）后，同内容重建被 :607-609 跳过，`focus` 也只是 enqueue → 再次跳过，**客户端在内容变化前永远拿不到数据**。次要：`ack` 仅接受严格相等（:343-344），略旧但仍在缓存中的 revision 被丢弃，cursor 无法前移 | pending 加 TTL 或允许 focus 强制清 pending；ack 接受 snapshot 缓存中的任意 revision |
| B-10 | P2 | `conversation-content-sync.ts:601-623, 686-696`、`websocket.ts:11595-11613` | 推送**无背压**：全程不检查 `bufferedAmount`，`publishSnapshot` 同步循环发给所有 interactive 客户端，慢客户端数据无上限堆积。且 change 驱动推送**不受 `hotConversationLimit=10` 约束**（该限制只管 warm 阶段 :487-503）→ 桌面端任何本地 CLI 会话的写盘活动都会把整窗快照（最多 755 条）推给所有手机客户端 | 发送前检查 `bufferedAmount` 阈值并延迟/降级；change 驱动推送仅限 hot 集合 + focused |
| B-11 | P2 | `conversation-content-sync.ts:555-599` | drain **单飞、无超时**：`await this.historyReader(task)` 无超时，一个数百 MB rollout 全量解析期间，其他会话（含其他客户端的 focused priority=0 任务）全部排队。priority 只在两次读之间生效 | 小并发池（2-3）+ 单任务超时/字节上限 |
| B-12 | P2 | `session-catalog-monitor.ts:301-344` | debounce 窗口内 `pendingConversationKeys.size !== 1` 即发 unscoped（:325-336）→ 触发全量 refreshCatalog（B-2）。**两个会话同时活跃（手机+桌面各开一个，很常见）时几乎每个窗口都是 unscoped → 每 2.5 秒一次全扫** | change 携带 keys 列表（有 cap，超出才 unscoped），handler 逐个 enqueue |
| B-13 | P2 | `session-catalog-monitor.ts:242-248, 186-188` | `watchedDirectories` 条目**仅在 watcher `error` 事件中删除**；macOS 上被删目录的 FSWatcher 往往只发 rename 不发 error → 条目与底层 **fd 永久保留**并计入 1024 上限。worktree 频繁创建/删除的工作流会单调逼近 cap | rescan 时 stat 校验已注册目录，消失即 close + delete |
| B-14 | P2 | `sessions-index.ts:1127-1148` | `getAllRecentSessions` 内 `seen.get(entry.sessionId)` 对 `[...claudeEntries, ...codexEntries]` 用**不带 provider 前缀**的 raw sessionId 去重，跨 provider uuid 碰撞会按"字段丰富度打分"丢掉一条。而 `websocket.ts:1114-1123` 的 `recentSessionDedupeKey` 已是 `provider:sessionId`，**两处口径不一致** | 改 key 为 `${provider}\0${sessionId}`，与 archivedSessionKeys 口径一致 |
| B-15 | P2 | `sessions-index.ts:28-61`、`session-catalog-monitor.ts:306-308`、`conversation-content-sync.ts:1015-1017` | 会话 identity **无 codexHomeId 维度**：`SessionIndexEntry` 无 home 字段，archived key 为 `provider\0sessionId`，39022937/6685185e 引入的 durable key 同样只有两维。双 CODEX_HOME 场景下同 threadId 不同内容互相碰撞/覆盖 revision | 加入 `codexHomeId`；旧客户端 capability-gated 回退单 Home |
| B-16 | P2 | monitor + sessions-index 多处 | **无 degraded health 上报**：`grep degraded\|health` 非测试文件零命中。watcher 失败静默 return（:250-252）、readdir 失败静默 continue（:197-201）、cap 命中无日志、sessions-index.json 解析失败仅 console.error（:1035）。客户端无从得知 catalog 已退化 | monitor 暴露 `coverage`/`degradedReasons`，随 `session_catalog_changed_v1` 或 doctor 上报 |
| B-17 | P3 | `conversation-content-sync.ts:238-249, 469-485` | scoped change 直接 enqueue 但**不更新 catalog 记录的 modified**；下次 `refreshCatalog` 比对 `previous.modified !== record.modified` 会对同一变化**再次 enqueue** `cold_revision` → 同一次磁盘变化至少两次全量 history 读（发布因 revision 相同被跳过，I/O 白费） | scoped 路径同步更新 catalog.modified |
| B-18 | P3 | `controller.ts:106-125`、`websocket.ts:9778, 11268-11279` | `sessionMessage`/`sessionCatalogChanged`/`clientDeliveryModeChanged` 同步遍历 handler **不捕获异常**；`sessionCatalogChanged` 由 monitor 的 `setTimeout` 回调同步调用，handler 抛同步异常即 **uncaughtException（进程级风险）** | controller 各 fan-out 方法逐 handler try/catch + 记录 |
| B-19 | P3 | `conversation-content-sync.ts:274-280, 907-956, 971-995` | `close()` 清 clients/queue/timers 但不清 `snapshots`/`catalog`；`boundHistoryMessage` 只约束 tool_result/assistant，**user_input 文本不设上限**；`paginateEntries` 允许单条超大 entry 突破 `maxPageBytes`；snapshot 总量无字节上限；`boundedText` 的 `end = Math.floor(end*0.9)` 截断可能**劈开 surrogate pair** 产生非法 UTF-16 | 逐项补齐上限；截断按 code point 边界 |
| B-20 | P3 | `session-catalog-monitor.ts:292-298` | durable identity 的 `uuid ?? stem` 回退会把 `rollout-2026-…` 这类 stem 当 providerSessionId 下发 → 对其 `getCodexSessionHistory(garbage)` → 全树扫描 + 逐文件流读后落空，**每次该文件变化都白扫一遍** | 正则不匹配时降级为 unscoped，不携带垃圾 id |
| B-21 | P3 | `sessions-index.ts:1355-1371` | `includeInternal=false`（recent 扫描）路径**没有** `payload.id !== fallbackSessionId` 的祖先过滤（该过滤仅在 includeInternal=true 分支）；fork 文件的祖先 meta 排在子 meta 之后时，条目会顶着**父 threadId** 出现，与真父会话在 B-14 的去重中互相吞并 | recent 扫描也优先采用与文件名 uuid 一致的 meta |
| B-22 | P3 | `codex-transport.ts:108-113, 141-151, 244-251` | `StdioCodexTransport.stop()` 仅 SIGTERM 无 SIGKILL 升级，且**先置 `child=null`**，进程拒杀则失去引用成为孤儿；`WebSocketCodexTransport.write` 未连接时**无界 `queue.push`**；`ManagedCodexAppServer` 把 app-server 的 stdout/stderr 无节流打到 console | SIGTERM → 超时 SIGKILL；write queue 加上限；日志节流 |
| B-23 | P3 | `websocket.ts:11242-11259, 11272` | conversation-content 的变更信号**依赖 catalog-watch 客户端存在**：monitor 启停条件是"存在声明 `session_catalog_changed_v1` 且 interactive 的客户端"；若某客户端只声明 `conversation_content_event_v1`，monitor 被关闭，推送只能靠 45s~5min 冷扫兜底且无提示 | 启停条件把 conversation-content 订阅也计入 |
| B-24 | P1 | `codex-process.ts:3373` | `if (this.stopped || !pendingInput.text) break;` —— 空字符串哨兵与 `stop()` 的 `inputResolve({text:""})` **共用**，用户发送空消息会被当作停止信号 | 用独立的 sentinel 对象或显式标志位 |

**已核验无问题**：`recentSessionsRequestIds` 等均为 WeakMap 无泄漏；ws close 时
`localFeatures.disconnect` 正确清理订阅；`CodexProcess` 在 stop/exit 时
`rejectAllPending`；session 内存 history 有 100 条上限；
stream_delta/thinking_delta 不进入 sessionMessage fan-out（降低了 B-1 的触发频率）。

### 4.4 Mobile —— 设置、缓存管理与悬浮窗

| 编号 | 级别 | 位置 | 问题 | 解决方案 |
|---|---|---|---|---|
| M-1 | P2 | `conversation_mirror_service.dart:557-613` | **删除旧 Bridge 副本会误杀当前 Bridge 的活动 watch**：`_cancelTargetRequests(key)` 按 `provider + providerSessionId` 匹配 pending（:584-590），watch 查找用 bridge 无关的 `_logicalWatchKey`（:578-583），**均不比对 `bridgeInstanceId`**，随后向 Bridge 发 unwatch → 当前会话实时镜像 patch 停止，直到下次 reconcile 才恢复。新增测试只覆盖了"当前 Bridge 无活动 watch"路径 | `_cancelTargetRequests` 增加 bridgeInstanceId 归属判定；跨 Bridge 删除只清元数据 |
| M-2 | P2 | `conversation_mirror_store.dart:978-987` + `cache_management_screen.dart:186` | 每条删除触发一次**无页数上限**的 `PRAGMA incremental_vacuum`（一次性回收整个 freelist），且运行在服务的**串行存储队列内** → 连续删除多个大副本（每个可达 64 MB）时阻塞后续镜像 patch 写入与其他删除，UI 表现为后续行 spinner 长转 | 改 `incremental_vacuum(N)` 分批，或批次结束后统一去抖执行一次 |
| M-3 | P2 | `session_catalog_cache_repository.dart:250-255` + `cache_management_strings.dart:41-45` | "清理会话目录缓存"**实际范围大于 UI 承诺**：`clearAll()` 删 `partitionsTable`，经 ON DELETE CASCADE 连带删除**所有机器分区**的 entries、aliases、**hotWindows、hotEntries**（离线打开会话的第一屏来源），而 `countAllSessions` 只统计 entries。契约核心（完整副本/草稿/凭据在独立库）**未被违反**，但文案与统计低估范围 | 文案注明"包含最近浏览的会话窗口缓存 / 所有已连接机器"；统计并入 hot window 数 |
| M-4 | P3 | `conversation_mirror_models.dart:68-95`、`cache_management_screen.dart:332-342` | Mirror metadata 仍**无 title/summary**；`_displayName` 按 `projectPath` 末段猜标题，猜不到则截断 providerSessionId。而 durable catalog（`session_catalog_cache` 的 `session_json` 里其实存有 `RecentSession.name`）与该列表**完全没有关联** | 按 durable identity 与持久 catalog join（v02-013.1 明确要求，不能按路径猜） |
| M-5 | P3 | `auxiliary_floating_dock.dart:85-100, 187-193` | 拖动**无阈值**：`onPointerMove` 收到任意 delta 就置 `_dragging = true`，`onPointerUp` 即 `_snap()` 强制半隐藏；同时 InkWell 在 slop 内仍判定为 tap → **一次不稳的点击会同时打开面板并把按钮贴边藏起** | 累计位移超 `kTouchSlop` 才进入 dragging |
| M-6 | P3 | `auxiliary_floating_dock.dart:73-83` | 位置**无持久化**、旋转后不重新贴边、键盘开合单向漂移：(a) 切换 session 位置重置；(b) 竖屏右缘旋转到横屏后旧绝对 x 仍在范围内 → dock 悬在屏幕中间；(c) `resizeToAvoidBottomInset` 使 `_top` 被 clamp 上移，键盘收起后不回位 | 记录"左/右侧 + 相对 y 比例"，尺寸变化时按比例重投影并持久化 |
| M-7 | P3 | `codex_session_screen.dart:1627-1630, 1907-1909` + `auxiliary_floating_dock.dart:78-81` | 底部/横屏**安全区未处理**：`_top` 上限为 height-56 且 body Stack 无 SafeArea → 拖到最底部落在 iOS home indicator 手势区；横屏时左右 8px 下限可能进入刘海区 | clamp 边界叠加 `MediaQuery.paddingOf(context)` |
| M-8 | P3 | `cache_management_screen.dart:311`、`conversation_mirror_models.dart:134-141` | 空间统计偏小且口径未标注：`metadata.bytes` 是协议 JSON payload 字节（模型注释明确"不含 SQLite 页开销"），UI 直接当占用展示；目录缓存侧完全无字节统计 | 标注"约"或改用 dbstat/文件大小估算 |
| M-9 | P3 | `conversation_mirror_service.dart:557-558` + `cache_management_screen.dart:184-190` | `removeLocalCopyByKey` 在 `!isAvailable`（存储降级）时**静默 return**，但设置页仍走成功路径弹"已删除" snackbar，列表项不消失 | 不可用时抛错或返回结果供 UI 区分 |
| M-10 | P3 | `conversation_mirror_store.dart:986` | 删除与 vacuum **非事务组合**：vacuum 抛错时删除已生效，UI 报"存储操作失败"造成"删除失败"的假象 | vacuum 失败仅记日志，不向上抛 |
| M-11 | P3 | `cache_management_screen.dart:198-203` | `_showError` 将**原始异常字符串**（含路径/SQL 细节）直接展示给最终用户 | 映射为友好文案，细节进日志 |
| M-12 | P3 | `auxiliary_floating_dock.dart:159-170, 214-240` | 徽标语义混淆：无活动条目时用 `colorScheme.error` **红色**徽标显示总条目数，红+数字通常暗示告警 | 闲置条目用中性色或不同徽标 |
| M-13 | P3 | `cache_management_strings.dart:59-64, 87, 94-95` | `clearing` 字符串定义后从未使用（死代码）；多处硬编码 "Mac/电脑" 但 Bridge 可运行于 Linux/Windows；该文件**绕开 ARB/AppLocalizations 体系**手写四语言，与 settings 其余部分不一致 | 并入 ARB 体系；文案去平台假设 |
| M-14 | P3 | `cache_management_screen.dart:121, 128-142` | 目录缓存计数只在进入页面和清理后刷新；页面停留期间后台同步继续写入 entries，计数不更新（backend 监听的是 mirror service，不含 catalog 仓库），也无下拉刷新 | 监听 catalog 仓库变化或加下拉刷新 |
| M-15 | P2 | `auxiliary_floating_dock.dart:39, 133-150` | （v02-002 断言成立）仍是 `_size = 48.0` 的按钮 + `showModalBottomSheet` + `FractionallySizedBox(heightFactor: 0.86)` **模态**实现，**与用户重新确认的"非模态可展开小窗"产品定义不符** | 按 v02-002 重做为会话页 Stack/Overlay 内的局部 surface |

**确认良好**：取消与 generation fence 总体扎实——删除前先 `_cancelTargetRequests`，
`_acceptedRequestIds` 移除后三处入口都会丢弃迟到帧；分页读取有读前/读后双重
`_pageCursorMetadataMatches` + `identical` 校验；`_publishKeyToRuntime` 同样双检。
`clearAll` 为单条 DELETE + 级联，原子。正在下载的副本被删时 `abortShadowGeneration`
与 `deleteLocalCopy` 的串行队列顺序正确。UI 侧 `_loadGeneration` 防迟到、dispose 移除
listener、await 后均有 mounted 守卫。

**注**：`residentMetadata` 只返回 `autoSync && hasLocalCopy` 属**故意**（Home 常驻区
语义），`ac0f56c0` 已新增 `localCopyMetadata`（:137-150）包含暂停同步与其他 Bridge 的
副本，设置页已改用它——交接文档"设置页漏掉暂停副本"这条**已被本轮提交修复**。

### 4.5 聊天渲染层

| 编号 | 级别 | 位置 | 问题 | 解决方案 |
|---|---|---|---|---|
| U-1 | P2 | `chat_message_list.dart:909-945, 708-737` | 展开态可出现**空的带边框八行框**：live 分支 `expanded=true` 且 thinking 为空时 children 只剩返回 `SizedBox.shrink` 的 BlocSelector，仍渲染出只有边框 + 上下 padding 的空盒；persisted 分支渲染 viewport 前未检查 `segment.detailCount > 0`，`_expandedCurrentProgress` 含 stale key 时同样出空框 | children 有效性判空后再套 DecoratedBox |
| U-2 | P3 | `chat_message_list.dart:645` + `chat_process_layout.dart:340, 459` | **重复时间戳**：`ChatProcessDisclosure` 时间取 `segment.lastEntryIndex`，当 segment 只有内联过程时 `lastEntryIndex == assistantEntryIndex` → 同一时间同时显示在上方 assistant 操作栏和折叠行，相邻两行时间完全相同 | `lastEntryIndex == assistantEntryIndex` 时折叠行不显示时间 |
| U-3 | P3 | `chat_message_list.dart:1004-1012` | 外层中间过程折叠行时间取 `intermediateSegments.last.lastEntryIndex`，**忽略更晚的 auxiliary entry**（后续可见更新、图片组），时间可能比折叠内最新内容更旧 | 改取 `intermediateEntryIndices` 的最大 index |
| U-4 | P3 | `chat_process_layout.dart:49-59` + `chat_process_disclosure.dart:350-353` | `ChatCurrentToolActivityLine` 时间恒为工具**开始** entry 的时间（`completed()` 保留原 `entryIndex`），行文案切到"最新工具/已完成"后时间仍是开始时刻——"开始时间"冒充"最新状态时间" | 完成态取该组最后一个可见事件的权威时间 |
| U-5 | P3 | `user_bubble.dart:445-469` | 用户长文本与 timestamp 同处一个 Row（Flexible 文本 + 固定 timestamp 列），**多行消息的每一行**宽度都被 timestamp 列永久压窄约 60px，而非只影响最后一行 | 改末行内联（Wrap / WidgetSpan）或叠加定位 |
| U-6 | P3 性能 | `chat_message_list.dart:1300-1309` | 八行框内部是 `SingleChildScrollView + Column`，**非懒加载**：长 interval（几十上百条）展开时全部 build+layout，且每次 streaming/guardian setState 全量重建，外加 `ClipRRect` 一层裁剪 | 条目多时换 `ListView`/`SliverList`，至少加 `RepaintBoundary` |
| U-7 | P3 可访问性 | `chat_message_list.dart:1266-1272`、`chat_message_timestamp.dart:594-603` | (a) 八行框高度的 textScale clamp 到 1.6，但行内容随系统字号继续放大 → 辅助字号下可见行数远少于 8；(b) timestamp 固定 fontSize 10（用户气泡内还叠 alpha 0.66），对比度偏低；(c) `~` 前缀无 Semantics，VoiceOver 读作波浪号，**"约"的含义不可达** | 加 `Semantics(label: '大约 xx:xx:xx')`；复核最小字号与对比度 |
| U-8 | P3 | `message_bubble.dart:76-78` | `ChatMessageTimestampData.fromEntry` 对所有 ServerChatEntry 计算并下传，但约 80 个分支不消费（死数据）；同时 `hasTextContent` 门槛使"无正文但有 artifacts"的 assistant 消息无时间 | 在 3.1 收尾时一并梳理归属闭环 |

### 4.6 协议解析层（models / utils）

| 编号 | 级别 | 位置 | 问题 | 解决方案 |
|---|---|---|---|---|
| A-1 | P1 | `side_chat_protocol_slot.dart:508-513`（`_sideChatRequireOnlyKeys`，11 处调用）、`file_transfer_protocol_slot.dart:583-592`、`file_browser_protocol_slot.dart:1202-1260`（result/root/node/statItem **四层**）、`auto_approval_protocol_slot.dart:96-110` | **严格键白名单族**：4 套实现覆盖 6 个 feature / 19 种消息类型，Bridge 新增任何字段都会导致整条消息被拒。这与项目"additive + capability negotiation，未知字段可忽略"的协议原则**直接冲突**。且**当前行为被测试固定住**：`test/features/file_browser/file_browser_protocol_test.dart:565-571` 明确断言 `'rejects unknown fields at result, root, node, and stat-item levels'` | **需用户决策**，见第 8.1 节 |
| A-2 | P0 | `conversation_content_protocol_slot.dart:122` | 构造期 eager `decodeMessage()`（P0-9） | 照抄 mirror slot 的惰性写法 |
| A-3 | P0 | `messages.dart:2211-2216` | Guardian fail-open（P0-14） | 兜底改为最严格值 |
| A-4 | P0 | `messages.dart:1371, 1376, 1338, 1411, 1430, 1603, 1605, 3349` | `cast<String>()` 惰性转换在 build 期抛错（P0-7） | 改 `List<String>.from` |
| A-5 | P0 | `messages.dart:4764, 4766, 4820-4822` | `SessionInfo` 裸 cast 使整个 session_list 失败（P0-8） | `.map()` 内逐条 try/catch |
| A-6 | P2 | `messages.dart:953` | `ServerMessage.fromJson` **无 try/catch**，唯一保护是 `bridge_service.dart:1431..1872`。爆炸半径：R1 单帧 / R2 整批 / R3 逃逸（build 期红屏）/ R4 completer 挂起 | 在 `fromJson` 边界内建立解析防护，不依赖调用方 |
| A-7 | P2 | `diff_parser.dart:181` | `contains` 与 `startsWith` 判定不对称，特定 diff 形态解析错位 | 统一为 `startsWith` |
| A-8 | 良好 | `conversation_mirror_protocol_slot.dart:114-119, 497-498` | **正确范式**：`unknown('__unknown__')` + `_validate` 中 `case unknown: break`。**唯一做对的 slot，其余应向它对齐** | — |

### 4.7 原生宿主与云端

| 编号 | 级别 | 位置 | 问题 | 解决方案 |
|---|---|---|---|---|
| N-1 | P0 | `BridgeProcessManager.swift:35-39` | menubar 管道死锁（P0-10） | 先异步读再 `waitUntilExit` |
| N-2 | P0 | `NotificationActionHostPlugin.swift:52` | 通知长按操作全失效（P0-20） | 加 `.withFractionalSeconds` |
| N-3 | P1 | `UsageInfo.swift:11` | 菜单栏用量倒计时永远显示 "—"（P0-21，第 3 轮新增） | 同上；抽共享宽容解析函数 |
| N-4 | P2 | `websocket.ts:1251-1253` + `functions/src/index.ts:394-398` | `tokenLocales` 是**内存 Map**，Bridge 重启后 `getRegisteredLocales()` → `["en"]`，而 Functions 侧 `if (tokenLocale !== body.locale) return false` → **zh/ja/ko 用户重启后收不到任何通知** | locale 随 token 持久化 |
| N-5 | Medium 安全 | `functions/src/index.ts` | FCM token 归属未验证；App Check 为 no-op（S-8） | 绑定认证身份；启用真实 App Check |
| N-6 | P1 | `mobile_update_models.dart:5`（枚举 `{stable, owner}`）、`patch.sh:67`（`--track=owner`）、`.github/workflows/ios-patch.yml:11-15`（选项 `[staging, stable]` 默认 `staging`） | **三处 track 口径互不一致**：代码认 owner、脚本发 owner、CI 只能选 staging/stable。经 CI 发出的补丁客户端永远收不到 | 统一为同一组 track 常量，CI 选项与代码枚举对齐 |
| N-7 | P1 | `apps/menubar` 全目录 | **零测试**（`find apps/menubar -iname "*test*"` 无结果）。N-1 的死锁与 N-3 的日期 bug 都因此逃逸 | 至少为 `BridgeProcessManager` 与 `UsageInfo` 补单元测试 |

### 4.8 本地化与工程门禁

| 编号 | 级别 | 位置 | 问题 | 解决方案 |
|---|---|---|---|---|
| L-1 | P1 | `app_zh.arb`（949 键）vs 模板 `app_ja.arb`（872 键） | 77 个多出的键中 **76 个永远不会生成 getter**（`l10n.yaml` 的 `template-arb-file: app_ja.arb`）——写了但用不上的死翻译 | 以最全语言为模板，或把缺失键补进模板 |
| L-2 | P2 | `.github/workflows/test.yml:74` | `dart analyze .` **未加 `--fatal-infos`**；flutter_lints 大量规则是 info 级 → **任何 lint 违规都不会让 CI 失败** | 加 `--fatal-infos`（先清理存量告警） |
| L-3 | P3 | `CLAUDE.md` 架构图 | `claude-process.ts` **在当前树中不存在**，Claude 侧进程封装实际是 `sdk-process.ts` | 修正架构图 |

### 4.9 第 3 轮新增：次要 feature / router / providers / screens

**覆盖清单**：本轮实测 `ls lib/features/` 共 33 个目录。此前两轮已覆盖 16 个，
本轮新覆盖 17 个：artifact_preview、auto_approval、chat_selection_add_to_conversation、
codex_core_actions、conversation_content_sync、debug、explore、file_peek、gallery、
generated_image_preview、local_session_features、message_images、mobile_host、
notification_settings、prompt_history、session_archive、session_insights、session_link、
setup_guide、subagents；外加 `lib/screens/`（mock_preview_screen、qr_scan_screen）、
`lib/router/`、`lib/providers/`、`main.dart`。

| 编号 | 级别 | 位置 | 问题 | 解决方案 |
|---|---|---|---|---|
| R-1 | P1 | `session_link/state/session_link_cubit.dart:83-116` | **resume 路径无超时、无断线处理**：`_resume()` 之后 cubit 停在 `resuming()` 等待 `session_created`/`session_resume_failed`。若 Bridge 中途重启、连接断开或 resume 静默失败，**永远等待**。而 `SessionLinkStatusView`（`session_link_screen.dart:150-171`）**只在 `unavailable` 时才渲染带"打开最近会话"按钮的逃生视图**，`resuming` 态只有一个转圈 —— 从冷启动深链进入时通常没有返回栈，**用户只能杀进程**。**对照**：`resolveSessionLink`（`bridge_service.dart:3196-3200`）**有** 10 秒超时并在超时时返回 `unavailable`，说明作者在另一半路径上是考虑了的 | `_resume` 加超时（建议 30s）转 `unavailable`；订阅 `connectionStatus`，断开即转 `unavailable`；`resuming` 态也提供逃生入口 |
| R-2 | P1 | `session_link_screen.dart:99-130`（`_sessionRoute`） | 构造 `CodexSessionRoute`/`ClaudeSessionRoute` 时传了 8 个参数（sessionId、projectPath、gitBranch、worktreePath、initialPermissionMode、initialSandboxMode、initialApprovalPolicy、initialApprovalsReviewer）但**没有 `durableProviderSessionId`** —— 这是 H-1 的**第三条**入口，第 1 轮只点名了 `session_list_screen.dart` | 与 H-1 一并修 |
| R-3 | P2 | `main.dart:894-905`（`_handleUri`） | `SessionLinkParams` 分支**硬编码** `provider: 'claude'`。所幸 `session_link_cubit.dart:68` 与 `session_link_screen.dart:68` 都用 `resolution.provider ?? _provider` 兜底，**多数路径能纠正**；但 `SessionLinkOpenLegacy` 分支（`session_link_screen.dart:78-81`）用的是未经解析的 widget `provider` → **旧 Bridge 上打开 Codex 会话会进 Claude 屏幕** | 深链解析出 provider（或支持 `ccpocket://session/<id>?provider=codex`）；legacy 分支改为先查本地目录再决定 |
| R-4 | Medium 安全 | `debug-trace-store.ts` 全文 | 调试轨迹全量落盘，无门禁/无上限/无权限/未脱敏（详见 2.5） | 见 2.5 |
| R-5 | P2 隐私 | `utils/debug_bundle_share.dart:37-42, 159-209` | 调试包含完整 diff 与对话摘要，UX 引导"粘贴到 AI 聊天"（详见 2.6） | 复制前确认 + 暴露 `includeDiff` 开关 |
| R-6 | P2 安全 | `websocket.ts:7627-7650`、`:1403-1405`、`:3549-3552` | Gallery 无归属模型：`list_gallery` 无 `isPathAllowed`，省略 `project` 即返回全部；新图 `broadcast` 给所有客户端（详见 2.7） | 与 SEC-3、S-1 作为一个整体修复 |
| R-7 | P3 | `bridge_service.dart:3236-3242` | `resolveSessionLink` 的 `finally` 块对**每条排队消息**做 `jsonDecode(message.toJson())` 只为读一个字段 | 队列元素保留结构化 tag，避免反复编解码 |
| R-8 | P3 | `screens/qr_scan_screen.dart:37-50` | `_onDetect` 对无效码每帧都可能弹一次 SnackBar（`_hasPopped` 只护住成功路径） | 无效提示加去抖 |
| R-9 | 良好 | `screens/qr_scan_screen.dart` | 扫码需用户物理对准摄像头，属真实意图表达，**不需要**再加确认弹窗 —— 与 S-9 的深链路径要**区别对待，不要一刀切** | — |
| R-10 | 良好 | 17 个新覆盖 feature 全体 | `grep "as String\|as int\|as List\|as Map\|cast<"` 在这些 feature 内**零命中** —— 解析全部集中在 `models/messages.dart`，分层是干净的。同样 `Completer`/`Timer.periodic` 零命中，无隐藏的悬挂等待或未取消定时器 | — |
| R-11 | 良好 | `features/debug/debug_screen.dart` 全文（111 行） | 调试页本身**不泄露任何凭据**：全文 `grep token\|apiKey\|password\|secret\|url\|host` 零命中，只有主题/语言/support banner/日志查看/mock preview 五个入口。风险不在页面本身，而在它 push 的 `TalkerScreen(talker: logger)` 所展示的日志内容——而日志侧经查也**没有**记录 URL/token（仅 `machine_manager_service.dart:195`、`markdown_style.dart:85,89` 三处提到 URL，均为错误信息不含凭据） | — |

---

## 第 5 章　交接文档需要回写的断言

### 5.1 已不成立（被本轮提交修复）—— 继续照旧文档实施会做重复工作

| 文档位置 | 原断言 | 当前事实 |
|---|---|---|
| v02-001.2 | `_isAutoConnecting` 分支无条件覆盖整个连接表单，只显示中央转圈 | **已修复**（02128669）。`session_list_screen.dart:2597-2623` 在非 connected UI 下始终渲染 `_ConnectFormWidget` 并传 `connectionProgressLabel`；`connect_form.dart:104-144` 只在表单顶部内嵌一条带小 spinner 的进度条，机器列表/扫码/设置向导全程可用 |
| v02-011.2.1 | recent payload 与 metadata 不是原子快照，Cubit 从 `lastRecentSessionsMessage` 旁路读元数据 | **已修复**。Cubit 已改订阅 `recentSessionResponses`（`session_list_cubit.dart:123`），`bridge_service.dart:1637-1657` 把 sessions/hasMore/offset/requestScope/queryGeneration/catalogRevision 原子打包。全库无 `lastRecentSessionsMessage` 外部消费者 |
| v02-011.2.2 | 持久筛选恢复晚于首次网络请求 | **已修复**。`session_list_cubit.dart:743-755` 在发 `switchFilter` 前 `await _preferencesLoaded`；`_loadPreferences` 用 `_filterMutationRevision`（:141-163）避免覆盖用户手动改动；缓存展示路径也先等偏好（:611） |
| v02-011.2.7 | 断线调用 `resetFilters()` 清空用户筛选偏好 | **已修复**。`resetFilters` 全库已不存在；`handleDisconnect()`（:554-565）仅清 loading/分页态，注释声明 "retaining user intent" |
| v02-011.2.5 | 身份键仍有 raw ID 漏口 | **大体修复**。pin 已用 provider+projectPath+sessionId 三维（:46-66）；持久缓存主键四维；统一列表身份键 provider+sessionId。**残留两处**：rename 乐观更新（C-12）、每会话 Claude 设置键（C-13） |
| v02-011.3.6 / A6 | catalog/append/project response 缺 requestId/queryGeneration | **已修复**。`recent_sessions` 响应对所有 requestScope 统一回显 requestId、queryGeneration 并附 catalogRevision（`websocket.ts:7057-7071`），且有 per-ws stale-response 丢弃保护（:7042-7056）。**但 snapshot token 仍缺**（A6 的另一半仍成立，见 C-6） |
| v02-013.1 | `residentMetadata` 只返回 autoSync && hasLocalCopy，设置页会漏掉暂停同步的副本 | **已修复**（ac0f56c0）。新增 `localCopyMetadata`（:137-150），设置页已改用。`residentMetadata` 保留原语义属故意 |
| v02-009.1 / v02-013.2 | `message_timestamp_test.dart` 只断言 `03:04:05` 文本存在，允许任何糟糕布局通过 | **已部分修复**（341b2a26）。已断言 timestamp 是 UserBubble/MessageActionBar/ToolUseSummaryBubble 的 descendant（:47-53, 73-79, 111-117），`chat_message_list_process_disclosure_test.dart:142-156, 180-195` 还断言了 `timestamp.dx < chevron.dx`。**仍缺**：气泡内具体位置断言、窄屏视觉截断检测（现只断言 `takeException == null`）、长工具名 + timestamp 溢出回归 |

### 5.2 需加限定语

- **`ddfb1bed`、`167ec16e` 的"已实现"**：仅 embedded workspace 路径生效，
  **手机端三条入口全部未接线**（H-1 / R-2）。
- **`CLAUDE.md` 架构图**：`claude-process.ts` 不存在，实际是 `sdk-process.ts`（L-3）。
- **`CLAUDE.md` 的 OTA track 说明**与实际 CI 选项不一致（N-6）。

### 5.3 三项"待取证"现已有根因，可直接开工

| 交接文档原状态 | 现结论 |
|---|---|
| "权限偶发回到 on-request" —— 待事件线取证 | **根因已定位**：P0-11（Mobile 发明默认值）+ P0-12（Bridge getter 兜底），**两半都要修**，只修一半仍会复现 |
| "Plan 首次退出后审批消失" —— 待事件线取证 | **根因已定位**：P0-13。**注意 SEC-7 会产生相同症状，动手前先排除 auto-approval** |
| "JSON/HTML/Quick Look 预览失败" —— 待部署真机 | **根因已定位**：P0-17（修复未随任何版本发布，且含 Swift 改动 OTA 投递不了）+ P0-18（`.json`/`.html` 被判为源码走不到预览路由）。**不是新 bug，不要重新实现** |

---

## 第 6 章　推荐实施顺序

**原则**：每项一个内聚 commit，可独立回滚；先补回归再改行为；每层保留旧 Bridge fallback。

### 批次 0：安全（插队，先于一切功能）

理由：默认配置下存在无认证 RCE，其中一条路径不需要攻击者在同一网段。
用户当前正在真机日常使用这套系统。

1. `verifyClient` 拒绝带 Origin 的握手（SEC-1 第一步，一行，零兼容代价）
2. 服务端 permission 上限 + 未认证降级（SEC-2）
3. auto-approval：`Permissions` 类永不自动批准 + 重定向目标纳入判定 + 解释器 deny（SEC-7）
4. 统一 `assertCanonicalProjectPath()`（SEC-4，**复用 `read_file` 现成实现**）
5. 无 authorizer 时禁用上传 + 修正日志文案（SEC-6）
6. 截屏/窗口枚举 + gallery 归属，三者作为一个整体纳入 step-up 授权（SEC-3 / S-1 / R-6）
7. 调试轨迹落盘加门禁 + 权限 + 脱敏 + 保留策略（R-4 / 2.5 节）
8. 默认禁用 `.gtrconfig` hook（SEC-5）
9. `maxPayload` + 速率限制 + push token 边界（S-5、S-6）
10. 首启动自动生成并持久化 API key（SEC-1 第二步）

批次 0 结束后做一次针对性安全回归 + Bridge 全量 test。

### 批次 1：进程稳定性（P0，与安全并列最高）

1. `process.on("unhandledRejection")` + `uncaughtException`（P0-4）
2. stdin `error` 监听 + 写前 writable 检查（P0-5）
3. `trackMessageWork` 加 `.catch`（P0-6）
4. `controller.ts` 各 fan-out 逐 handler try/catch（B-18）
5. menubar 管道死锁（P0-10）

这五项不修，后面所有工作都可能被一次崩溃打断，且难以归因。

### 批次 2：数据正确性（P0）

1. **Git hunk 改为内容指纹定位**（P0-1）—— 这是唯一会静默破坏用户代码的缺陷
2. `diff_result` 加 requestId 并严格匹配（P0-2）
3. legacy HistoryMessage 代际栅栏（P0-3，同时是"重复两次"头号嫌疑）
4. `commitReplacement` 携带三个去重字段（3.2 候选 B，"重复两次"次号嫌疑）
5. 解析层四项：Guardian 兜底反向、`cast<String>` 立即求值、`SessionInfo` 逐条容错、
   内层惰性 decode（P0-14 / P0-7 / P0-8 / P0-9）

### 批次 3：权限与审批（P0）

1. Mobile 权限字段可空 + unknown 态，不发明默认值（P0-11）
2. Bridge `approvalPolicy` getter 去掉 `?? "on-request"`，决策路径遇 undefined 询问用户（P0-12）
3. 合成 plan 审批纳入正式 pending 迁移路径（P0-13）
4. `setStatus` 条件化，照抄 `codex-process.ts:5010`（P0-15）
5. 空字符串哨兵改为独立 sentinel（B-24）

**注意实施顺序**：先做 1+2（两半必须同时修），再做 3；做 3 之前先确认用户是否开了
auto-approval（SEC-7 会产生相同症状）。

### 批次 4：让本轮已提交的功能真正生效

1. **路由补 `durableProviderSessionId` + 重新生成 auto_route + 三处 push 全部传入 +
   手机端 widget test**（H-1 / R-2）—— 同时解决"正在创建会话"文案
2. catalogRevision 加启动纪元（C-18）+ 重连时重置（C-1）+ 列举期间 revision 变化（C-17）
3. 缓存-网络交错的写回顺序（C-2）
4. 删除旧 Bridge 副本误杀当前 watch（M-1）
5. Side Chat 僵尸清理（P0-16）
6. session_link resume 超时与逃生路径（R-1）

这几项修复的是**本轮新提交自身引入或未闭合的缺陷**，不做完就往上叠新功能会让后续
问题难以归因。

### 批次 5：完成交接文档 E.1 的源码收束

1. 4 类可见消息的时间归属 + 长工具名溢出（3.1）
2. 无 UUID 同文本消息的 provenance 漂移（3.3）+ 补缺失回归
3. starting 3 秒轮询加 deadline + 退避（H-15）
4. 若批次 2 的第 3、4 项未消除"重复两次"，再采集五层证据（3.2）

### 批次 6：Bridge 性能（用户数据规模已达 26 GiB × 2）

1. per-conversation path 缓存 + append-read 增量（B-1，**复用 `getCodexDesktopToolTimeline`**）
2. catalog 轻量 reader，跳过 lastPrompt supplement（B-2）
3. `getAllRecentSessions` 的 mtime/inode metadata cache（B-3）
4. all-provider 路径不再重复全扫 Codex（B-7）；`ForFiles` 变体切换（B-8）
5. scoped change 携带 keys 列表（B-12）
6. 推送背压 + drain 并发池/超时（B-10、B-11）
7. watcher 配额、fd 回收、degraded health（B-5、B-13、B-16）
8. watch 归属改引用计数（B-6）

完成后按交接文档要求做一次 Bridge 侧性能基线对比。

### 批次 7：发布与原生

1. 含 Swift 改动的完整构建，让预览修复真正到达用户（P0-17）
2. 两处 Swift 日期解析（P0-20 / P0-21）+ menubar 补测试（N-7）
3. 通知 locale 持久化（N-4）
4. OTA track 三处口径统一（N-6）
5. FCM token 归属 + App Check（N-5）
6. Bridge 版本号与 tag 对齐

### 批次 8：目录一致性与协议身份

1. snapshot token / opaque cursor（C-6）
2. 全局分页游标与 project 合并解耦（C-5）
3. legacy 完整缓存的 tombstone/删除对齐（C-4）
4. raw sessionId 去重口径统一（B-14）+ 残留身份键（C-12、C-13）
5. `resolveCodexHome()` + `codexHomeId` 维度（B-4、B-15）

### 批次 9：产品语义（需用户确认设计后再动）

1. 严格键白名单族的架构决策（A-1，见 8.1）
2. Quick Look 回退语义定齐（P0-19，见 8.2）
3. 非模态可展开悬浮小窗（M-15）—— 完整重做，非修 bug
4. live/persisted 双 surface 合并 + Guardian 计时提层（3.4）
5. Ready/activation 语义拆解 + 未知状态不伪造 idle（C-15）
6. `(no description)` 三态区分 + 本地化（C-14）
7. durable screen identity 与 runtime ID 解耦（H-14）

### 批次 10：收尾

1. 剩余 P3
2. `--fatal-infos` 门禁（L-2，先清存量）+ l10n 模板对齐（L-1）
3. 回写交接文档第 5 章的断言 + `CLAUDE.md` 架构图与 OTA 说明
4. 重新 fetch 并语义合并 `upstream/main`
5. 全 App 性能审查
6. 完整发布门禁：源码 → 集成 → Bridge build → deploy → Flutter test/analyze →
   Simulator → IPA → 重签/安装 → 真机 → owner OTA → 用户批准 stable

---

## 第 7 章　测试门禁

### 7.1 各批次开工前必须先写的测试

**批次 0（安全）**
- 带 Origin 头的 WS 握手被拒；不带 Origin 的正常通过
- 客户端请求 `bypassPermissions` 时服务端实际生效模式为上限值，且回告客户端
- symlink 逃逸：允许目录内软链指向外部时 `start`/git/worktree 全部被拒
- `echo x > ~/.ssh/authorized_keys` 形态的重定向**不被**自动批准
- `python -c "..."` / `node -e "..."` **不被**自动批准
- 无 authorizer 时 upload capability 未注册
- `list_gallery` 省略 project 时不返回白名单外项目的图片
- 调试轨迹默认不落盘；开启时文件权限为 0600

**批次 1（稳定性）**
- 注入一个必然 reject 的后台任务，进程**不退出**且后续会话正常
- 子进程崩溃后再 `write`，不产生未捕获异常
- 单条消息处理抛错后，后续消息仍被处理
- menubar：模拟输出 > 1 MB 的子进程，`BridgeProcessManager` 不死锁

**批次 2（数据正确性）**
- **Git hunk：改动相距 2 行、3 行、4 行**（U3 合并 / U0 拆分的边界）各一例，
  还原后文件内容精确匹配期望 —— 这是掩盖过真实 bug 的形态，必须覆盖
- 两个不同项目的会话同时打开，A 的 diff 不出现在 B 的视图
- 迟到的 legacy 全量帧不得覆盖更新的 delta，水位不得回退
- 未知 Guardian 状态字符串解析为"未批准"
- `cast<String>` 相关：畸形元素在**解析阶段**被捕获，不进入 build
- 一条畸形 session 不影响 session_list 中其余条目

**批次 3（权限）**
- 未收到权威权限值时，客户端**不发送**该字段（断言 payload 中键不存在）
- Bridge 收到无 approvalPolicy 的请求时走"询问用户"而非默认策略
- 权限/沙箱重启后，pending 的 plan 审批仍可被批准
- 审批解决后若无进行中 turn，状态为 idle 而非 running

**批次 4**
- **手机端 push 路径**（非 embedded）点开既有会话：显示"正在加载"而非"正在创建"，
  且触发 `setFocusedConversation`
- **深链 session_link 路径**同上
- Bridge 重启后 revision 归零 + 同值碰撞时不得复用陈旧完整缓存
- 同目标自动重连后 `session_catalog_changed` 不被当旧事件丢弃
- cache load 与网络完整响应交错的两种顺序，缓存完整性标记均正确
- 删除旧 Bridge 副本时当前 Bridge 的 watch 保持存活
- side chat 子进程退出后配额被释放
- session_link resume 超时后进入可逃生的 unavailable 态

**批次 5**
- 孤立 ToolResultBubble / inferred error / 无正文 Plan / 图片结果各自的时间位置
- 长工具名（MCP 全名）+ 窄屏 + 大字号：无 RenderFlex 溢出，chevron 与时间均可见
- 两个无 UUID、文字相同、图片/时间不同的 user turn，canonical replacement 后
  各自保留正确元数据
- starting 永不结束时请求数有界，UI 可恢复

**批次 6**
- 同一会话连续 N 次增量推送，durable 文件只被完整解析 1 次（其余走 append）
- catalog 刷新不读取 lastPrompt（可用 spy/计数断言）
- 两个会话同时活跃时 change 不坍缩为 unscoped
- 慢客户端不导致快客户端阻塞；单个超长会话不饿死其他会话
- watcher cap 命中时上报 degraded；目录删除后 fd 被回收

**批次 7**
- **带小数秒**的 ISO 时间戳能被 iOS 通知宿主与 menubar 双双解析（见 7.2）
- Bridge 重启后 zh/ja/ko 客户端仍收到本地化通知

**批次 8**
- mutable catalog 两页之间插入/删除/归档/改 project，不重复不漏项
- 先展开 project 组再全局 loadMore，不丢行
- Claude/Codex 或两个 Home 使用相同 raw session ID 时均保留，rename/pin 不串线
- authoritative empty 能清旧项目；top-level exhaustion 不误标每个 project cursor

**批次 9**
- 展开小窗时窗外聊天/输入框/滚动仍可操作；20+ 条目时窗内滚动
- 工具 → thinking → 新工具的增量转换中，同一 viewport 与 expansion key 始终存在
- Guardian 同一 review 只出现一次、总时长约 3 秒（surface 切换不重置）

### 7.2 【重点】测试夹具反模式 —— 一条需要写进纪律的教训

本次审查发现的一个**系统性问题**：多个真实 bug 之所以能通过既有全绿测试，
是因为**夹具数据的形态与生产数据不同**。目前已确认三例：

| 掩盖的 bug | 夹具 | 生产实际 | 差异 |
|---|---|---|---|
| Git hunk 索引错位（P0-1） | `git-operations.test.ts:268-292` 选的两行**相距 15 行** | 真实改动常相距 2~6 行 | 15 行间距下 U3 与 U0 的 hunk 划分恰好一致，错位不显现 |
| iOS 通知长按全失效（P0-20） | `RunnerTests.swift:322` 用 `"2026-07-25T01:02:03Z"` | `toIso8601String()` / `toISOString()` **必带**小数秒 | 无小数秒的字符串恰好能被裸 `ISO8601DateFormatter` 解析 |
| menubar 用量倒计时（P0-21） | **完全无测试** | 同上 | 零覆盖 |

**全库统计佐证这不是偶然**：测试中不带小数秒的 ISO 字面量出现约 **130 次**，
带小数秒的约 **90 次** —— 两种形态混用，没有统一约定。

**建议写入贡献指南 / CI 门禁的三条规则**：

1. **夹具必须由生产代码路径生成，不得手写。**
   时间戳用 `DateTime.now().toIso8601String()` / `new Date().toISOString()` 的**真实输出**
   （必要时冻结时钟），而不是手敲一个"看起来对"的字符串。

2. **边界形态优先于典型形态。**
   diff 测试要选**相邻**改动（会触发 hunk 合并/拆分分歧的形态），而不是相距很远的
   两处改动。选夹具时先问："什么形态会让这段代码走另一条分支？"

3. **跨语言边界必须双向验证。**
   凡是一端产出、另一端解析的数据（TS→Swift、TS→Dart、Dart→Swift），
   契约测试必须用**产出端的真实输出**喂给解析端，而不是两端各自用自己的假数据。
   本次三例中有两例正是死在这条边界上。

另外建议补一个**轻量的 lint/CI 检查**：禁止在测试中出现不带小数秒的 ISO 8601
字面量（除非该测试的目的正是验证兼容性），一次性堵住这一整类问题。

---

## 第 8 章　需要用户决策的两项

这两项不是技术难题，是**语义选择**，选错方向会让一批测试和一批代码白写。

### 8.1 严格键白名单族（A-1）：严格拒绝 vs 宽松兼容

**现状**：4 套实现覆盖 6 个 feature / 19 种消息类型
（`side_chat_protocol_slot.dart:508-513` 有 11 处调用点、
`file_transfer_protocol_slot.dart:583-592`、
`file_browser_protocol_slot.dart:1202-1260` 分 result/root/node/statItem **四层**、
`auto_approval_protocol_slot.dart:96-110`），Bridge 新增任何字段都会导致整条消息被拒。

**冲突点**：这与项目自己确立的"additive + capability negotiation，未知字段可忽略"
协议原则直接矛盾。

**且当前行为被测试固定住了** —— `test/features/file_browser/file_browser_protocol_test.dart:565-571`
明确断言 `'rejects unknown fields at result, root, node, and stat-item levels'`。
也就是说改成宽松会**弄红现有测试**，这不是回归，是刻意的语义变更。

| 方案 | 含义 | 代价 |
|---|---|---|
| A. 保持严格 | 把它确立为"防御异常 Bridge"的正式策略 | 每次 Bridge 加字段都必须同步发 App 版本，OTA 之前的旧 App 全部拒收 |
| **B. 改为宽松（推荐）** | 未知字段忽略，向 `conversation_mirror_protocol_slot.dart` 的 `unknown('__unknown__')` 范式对齐 | 需改 4 处实现 + 改现有断言；失去对畸形 payload 的一部分早期拦截 |
| C. 分层 | 顶层宽松、安全敏感字段严格 | 实现最复杂，但语义最准确 |

**建议 B**：项目的协议原则已经写明是 additive，严格白名单是与之相悖的局部实现，
且它带来的"防御"价值在有 capability 协商的前提下很低。

### 8.2 Quick Look 回退语义（P0-19）

**矛盾点**：交接文档 E.4 §5 要求"不支持**或失败**"都回退到 WebView；
但 v01 的实现注记写的是"真实传输或 presentation 错误才显示重试"。
当前代码（`artifact_preview_screen.dart:445-457`）实现的是后者 ——
只有 `ArtifactQuickLookUnsupportedException` 回退，其余一律报错。

需要明确：**Quick Look 抛出非"不支持"类异常时，是回退到 WebView，还是显示重试？**
两种都合理（回退更顺滑，重试更诚实），但必须选一个，否则测试没法写。

---

## 附录：审查覆盖范围

### 已覆盖（三轮合计）

**Mobile**
- `lib/features/` **全部 33 个目录**
- `lib/services/`（bridge_service.dart、session_runtime_store.dart 等）
- `lib/models/`（30 文件 14 001 行）
- `lib/utils/`（19 文件 3 248 行）
- `lib/widgets/`（bubbles、session_card、chat_message_timestamp 等）
- `lib/router/`、`lib/providers/`、`lib/screens/`、`main.dart`
- `lib/l10n/`

**Bridge**
- `packages/bridge/src/` 全部 212 个文件（安全审查逐模块；
  `codex-process.ts` / `session.ts` / `sdk-process.ts` / `websocket.ts` 等大文件
  在第 2 轮做了针对性深审）

**其他**
- `apps/menubar`（Swift）
- `functions/`（Cloud Functions push relay）
- `apps/mobile/ios/`（原生宿主：通知 category、Secure Enclave 客户端侧）
- `.github/workflows/`
- 测试夹具质量（时间戳形态、diff 间距形态两个维度）

**注**：`features/connection/` 目录在当前树中**不存在**，连接 UI 实际位于
`features/session_list/` 下。

### 仍未覆盖，建议后续补审

- **Android / macOS 原生宿主**（本次只审了 iOS 与 menubar 的 macOS 部分）
- `codex-process.ts`（6 965 行）与 `session.ts`（2 413 行）的**逐行**审计
  —— 本次是针对性深审，覆盖了主要路径但非逐行
- Flutter 测试**夹具之外**的测试质量（断言强度、mock 保真度）
  —— 本次只查了夹具数据形态这一个维度
- `apps/mobile/lib/theme/`、`core/` 等基础设施目录

### 审查方法说明

第 1、2 轮共 14 路子代理并行审查。第 3 轮原计划同样派子代理，但子代理调用被账号侧的
Consumer Terms 更新拦截（`API Error: 400 — We've updated our Consumer Terms and Privacy
Policy`），改由主进程直接以 Read/Grep 取证完成，标准与前两轮一致。

**本文所有条目均给出了可复核的 `file:line`，任何一条都可以独立验证。**
