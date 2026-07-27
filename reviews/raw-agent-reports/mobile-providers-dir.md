I'll start by exploring the directory structure and reading the files.
审查完成，未修改任何文件。以下为发现清单。

---

# A) providers/ 发现

### [P1] `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/apps/mobile/lib/providers/machine_manager_cubit.dart:103,128,138,299,426,504`
**问题**：全文件 631 行、共 20+ 处 `emit`，**没有任何一处 `if (isClosed) return`**。而同仓库其余 Cubit 共有 63 处 `isClosed` 守卫（`chat_session_cubit.dart`、`settings_cubit.dart`），说明这是明确的项目约定，本文件是唯一漏网的。
**触发场景**：`startBridge()` 的 `_startHealthTimeout` 默认 20s、`updateBridge()` 默认 30s。用户按下"启动 Bridge"后立即退出/热重启（或 widget test 结束 tearDown），BlocProvider 关闭 Cubit，30s 后 SSH 返回 → `emit` 抛 `StateError: Cannot emit new states after calling close`，且发生在无人 await 的 Future 里 → unhandled zone error。
**证据**：
```dart
final result = await _sshService.updateBridgeServer(...);   // 可长达 30s
if (result.success) {
  final status = await _waitForOnline(...);
  ...
  emit(state.copyWith(updatingMachineId: null, ...));       // 无 isClosed 检查
```
**修复方向**：在每个 `await` 之后、`emit` 之前插入 `if (isClosed) return ...;`；或抽一个 `_safeEmit()` 私有方法统一处理。

---

### [P1] `.../providers/machine_manager_cubit.dart:364-390`（`_waitForOnline`）
**问题**：轮询循环不受 `close()` 控制，也没有 cancellation token。
**触发场景**：Cubit 关闭后，该循环仍会以 `_healthRetryDelay`(1s) 为间隔继续发起最多 30 次 `_service.checkHealth()` 网络请求（并可能触发 `promptForPassword` 弹 UI），最后再 emit 崩溃。
**证据**：
```dart
while (status != MachineStatus.online && DateTime.now().isBefore(deadline)) {
  await Future.delayed(_healthRetryDelay);
  status = await _service.checkHealth(machineId, ...);   // 无 isClosed / cancelled 检查
}
```
**修复方向**：循环条件加 `&& !isClosed`；close() 里置一个 `_disposed` 标志并在 `Future.delayed` 后立刻检查。另外 `DateTime.now()` 作为 deadline 依据受系统时钟跳变影响，建议改用 `Stopwatch`。

---

### [P1] `.../providers/unseen_sessions_cubit.dart:39-72`（`_loadSeenAt`）
**问题**：只捕获 `FormatException`。`SharedPreferences.getInstance()` 抛的 `MissingPluginException` / `PlatformException` / 磁盘错误不会被捕获。
**触发场景**：prefs 插件初始化失败时 → (1) `_seenAt` 保持为空，所有 idle 会话被错误标记为"未读"，UI 无任何提示；(2) `_ready` 以错误完成，而 `_ready` 直到 `close()` 才被 await（`session_list_screen.dart:713` 还是 fire-and-forget 调用），Dart 会把它报成 unhandled async error；(3) `close()` 中 `await _ready;` 会重新抛出，导致 `super.close()` 永远不执行 → Cubit 真正泄漏（订阅/状态不释放）。
**证据**：
```dart
try { final prefs = await SharedPreferences.getInstance(); ... }
on FormatException { _seenAt.clear(); }
finally { _loaded = true; ... }
...
Future<void> close() async {
  await _ready;        // 若 _ready 是 error，close 直接抛出，super.close() 不执行
  await _saveChain;
  return super.close();
}
```
**修复方向**：`_loadSeenAt` 改为 `catch (_)` 全捕获（或 `catch (e, s) { logger.error(...) }`）；`close()` 中改成 `await _ready.catchError((_) {})` 与 `await _saveChain.catchError((_) {})`，保证 `super.close()` 一定执行。

---

### [P2] `.../providers/server_discovery_cubit.dart:11-16` + `services/server_discovery_service.dart:43,74`
**问题**：构造函数里 `_service.startDiscovery()` 是 fire-and-forget 的异步方法，`dispose()` 里 `stopDiscovery()` 也没 await。
**触发场景**：Cubit 在 `startDiscovery()` 的 `await impl.startDiscovery(...)` 尚未返回时被 `close()` → `dispose()` → `stopDiscovery()` 看到 `_discovery == null` 直接返回什么都不做；随后 in-flight 的 `impl.startDiscovery` 完成并赋值 `_discovery`，**原生 mDNS browser 永远不会被停止**（原生资源泄漏 + 持续耗电）。
**证据**：
```dart
ServerDiscoveryCubit() : _service = ServerDiscoveryService(), super(const []) {
  _service.startDiscovery();      // 返回 Future<void>，未 await / 未 unawaited
  _sub = _service.servers.listen(emit);
}
```
```dart
void dispose() {
  stopDiscovery();                // 未 await；且此刻 _discovery 可能仍为 null
  _serversController.close();
}
```
**修复方向**：保存 `_startFuture = _service.startDiscovery()`，`dispose()` 改为 `Future<void> dispose() async { await _startFuture; await stopDiscovery(); ... }`；同时把 `ServerDiscoveryService` 改为构造注入以便测试。

---

### [P2] `.../providers/stream_cubit.dart:10-18`
**问题**：通用 Stream 包装器缺三样东西：`onError` 处理、`emit` 前的 `isClosed` 守卫、`close()` 中未 await `cancel()`。
**触发场景**：`StreamCubit` 被 6 个顶层 Provider 复用（`ConnectionCubit`/`ActiveSessionsCubit`/`RecentSessionsCubit`/`GalleryCubit`/`FileListCubit`/`ProjectHistoryCubit`）。当前 `bridge_service.dart` 的这些 controller 尚未 `addError`（已核实），所以只是潜在雷；但任何一次 `_xxxController.addError(...)` 的改动都会立刻变成全局 unhandled error 崩溃，而不是一个可见的错误状态。另外若将来传入的是经过 `asyncMap`/`asyncExpand` 转换的流，`cancel()` 的取消是异步的，事件仍可能在 `super.close()` 之后到达 → `StateError`。
**证据**：
```dart
StreamCubit(super.initial, Stream<T> stream) {
  _sub = stream.listen(emit);           // 无 onError；emit 无 isClosed 保护
}
Future<void> close() {
  _sub?.cancel();                        // 未 await
  return super.close();
}
```
**修复方向**：
```dart
_sub = stream.listen(
  (v) { if (!isClosed) emit(v); },
  onError: (Object e, StackTrace s) => logger.error('[StreamCubit<$T>]', e, s),
  cancelOnError: false,
);
Future<void> close() async { await _sub?.cancel(); return super.close(); }
```

---

### [P2] `.../providers/machine_manager_cubit.dart:299,426,138`（缺 single-flight / 状态互相覆盖）
**问题**：`startBridge` / `updateBridge` / `refreshLatestBridgeVersion` 都没有并发去重，且 `startingMachineId` / `updatingMachineId` 是单值字段。
**触发场景**：(1) 用户连点两次"启动"→ 发起两条 SSH 会话；先返回的那条 `emit(startingMachineId: null)`，UI 提前解除 loading，第二条返回时覆盖 successMessage/error；(2) 对机器 A 启动的同时对机器 B 启动，B 完成后把 `startingMachineId` 置 null，A 的进度指示消失；(3) `refreshLatestBridgeVersion(forceRefresh: true)` 与自动的 `refreshLatestBridgeVersionIfStale()` 并发时，慢的那个响应会覆盖快的（无 generation/epoch fence）。
**证据**：
```dart
emit(state.copyWith(startingMachineId: machineId, ...));
...
emit(state.copyWith(startingMachineId: null, successMessage: 'Bridge Server started'));
```
**修复方向**：改为 `Map<String, Future<bool>> _inFlightStarts`，同 machineId 复用同一个 Future；或把 `startingMachineId` 改成 `Set<String>`；版本刷新加一个自增 `_versionRequestId`，回调时比对后再 emit。

---

### [P2] `.../providers/machine_manager_cubit.dart:116-125`（`waitUntilLoaded`）
**问题**：只捕获 `TimeoutException`。
**触发场景**：等待期间 Cubit 被 close，`stream` 关闭 → `firstWhere` 抛 `StateError: No element`（不是 TimeoutException），调用方（`session_list_screen.dart:178` 的自动连接路径）拿到未捕获异常，自动连接直接失败且无兜底。
**证据**：
```dart
try {
  await stream.firstWhere((s) => !s.isLoading).timeout(timeout);
} on TimeoutException { /* fall back */ }
```
**修复方向**：改为 `catch (_)` 或 `.firstWhere(..., orElse: () => state)`。

---

### [P3] `.../providers/machine_manager_cubit.dart:89-96`（构造函数中 fire-and-forget）
`init();` 未加 `unawaited(...)`（同一构造函数下面第 95 行的 `refreshLatestBridgeVersion` 却加了），风格不一致且掩盖了"构造期异步失败无人处理"的事实。建议 `unawaited(init())` 并在 init 内部做 isClosed 守卫。

### [P3] `.../providers/machine_manager_cubit.dart:139,180-183`（时间处理）
`_lastLatestBridgeVersionRefreshAttemptAt = DateTime.now()` 用墙钟做节流窗口。用户手动改系统时间或跨时区/夏令时切换时，`DateTime.now().difference(lastAttempt)` 可能为负或巨大，导致节流永久失效或永久生效。建议改用 `Stopwatch` 或 `DateTime.timestamp()`(UTC) 单调近似。

### [P3] `.../providers/unseen_sessions_cubit.dart:205-212, 214-223`（时间比较）
`_isAfter` 在任一时间戳 `DateTime.tryParse` 失败时退化为 `candidate.compareTo(baseline)` 字符串比较；`_pruneSeenAt` 直接按字符串排序裁剪。ISO 时间戳如果混用 `Z` 与 `+09:00` 偏移、或小数秒位数不同（`.1Z` vs `.100Z`），字典序结果与真实时序不一致 → 未读标记错乱、裁剪掉错误的条目。建议持久化时统一归一化为 `toUtc().toIso8601String()`，比较前统一 parse。

### [P3] `.../providers/unseen_sessions_cubit.dart:81-84`（静默吞异常）
```dart
.catchError((Object _) { /* Keep the chain usable ... */ });
```
持久化失败完全无日志、无 UI 反馈，未读状态在下次启动静默丢失。建议至少 `logger.warn`。

### [P3] `.../providers/unseen_sessions_cubit.dart:97`
`_latestSessions = List<SessionInfo>.of(sessions)` 在每次会话快照推送时全量复制列表。会话列表频繁刷新时是可避免的 O(n) 分配（该字段仅用于 `_loaded` 之前的重放，加载完成后可直接置 null 不再保存）。

### [P3] `.../providers/machine_manager_cubit.dart:625`
`_machinesSub?.cancel();` 未 await（`close()` 返回类型是 `Future<void>`，完全可以 await）。

---

# B) utils/ 发现

### [P1] `.../apps/mobile/lib/utils/composer_tokens.dart:401,404`
**问题**：**在逐字符循环中重复编译正则**。`_isWhitespace` 每次调用都 `RegExp(r'\s')` 新建一个对象；`_isTokenBoundary` 每次调用都新建 `RegExp(r'[\(\[\{:,;]')`。
**触发场景**：`parseComposerTokens` 由 `ComposerTextEditingController.buildTextSpan`（第 257 行）调用，即输入框**每次重建/每次按键**都跑一遍。`_findTokenEnd` 对 token 内每个字符调 `_isWhitespace`，外层 while 对每个字符调 `_isTokenBoundary`。输入 500 字符 → 单帧内 500+ 次正则编译。
**证据**：
```dart
bool _isTokenBoundary(String text, int index) {
  ...
  return _isWhitespace(previous) || RegExp(r'[\(\[\{:,;]').hasMatch(previous);
}
bool _isWhitespace(String value) => RegExp(r'\s').hasMatch(value);
```
**修复方向**：提到顶层 `final _whitespace = RegExp(r'\s');`，或直接用 code unit 判断（`c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D`），彻底去掉正则。

---

### [P1] `.../apps/mobile/lib/utils/file_mention_matcher.dart:29-31`
**问题**：同样是热路径里重复编译正则，且是**每个候选项**一次。
**触发场景**：`chat_input_with_overlays.dart:337` 在 `build()` 内对 `projectFiles`（大仓库可达数千条）逐个调 `scoreFileMentionPath`。每个候选内部会调 `_compactForFuzzyMatch` 两次（一次 query、一次 path），每次都 `RegExp(r'[^a-z0-9]')` 新建 + 全串 `replaceAll`。@ 提及时每敲一个键 → 数千次正则编译 + 数千次全路径字符串重建，再叠加 `toList()..sort()`。
**证据**：
```dart
String _compactForFuzzyMatch(String value) {
  return value.replaceAll(RegExp(r'[^a-z0-9]'), '');   // 每次调用新建 RegExp
}
```
另外 `q = query.toLowerCase().trim()` 与 `compactQuery` 是 query 的函数，却在每个候选内重算。
**修复方向**：正则提到顶层 final；把 query 侧的预处理（lower/trim/compact）提到调用方或做成一个 `FileMentionQuery` 值对象一次性算好；对 `projectFiles` 的打分结果按 (query, 文件列表版本) 做 memoize，避免每帧重算。

---

### [P1] `.../apps/mobile/lib/utils/diff_parser.dart:462-507`（`summarizeDiffSelection`）
**问题**：为了"数几个数"而在主 isolate 上完整解析整个 diff。
**触发场景**：`widgets/chat_input_bar.dart:670` 在 `_DiffPreview.build()` **内部**调用它。输入框每次重建（每次按键、每次 IME 组字）都会把已附加的 diff 全量 `split('\n')` + 构造全部 `DiffFile`/`DiffHunk`/`DiffLine` 对象，只为得到 3 个整数。选中一个几 MB 的 diff 时会直接掉帧。
**证据**：
```dart
Widget build(BuildContext context) {
  ...
  final previewSummary = summarizeDiffSelection(selection.diffText);   // 全量解析
```
**修复方向**：`summarizeDiffSelection` 改为单遍流式扫描（不构造对象，只在遇到 `diff --git`/`@@`/`+`/`-` 时计数）；或在 `DiffSelection` 创建时算好并缓存在值对象里。

---

### [P2] `.../apps/mobile/lib/utils/diff_parser.dart:558,569-570,595`（未校验的 `as String` 强转）
**问题**：文档注释写"input 畸形时返回 null"，实现却会抛 `TypeError`。
**触发场景**：`input` 来自 wire JSON。若某个 provider/Bridge 版本把 `file_path` 发成数字、把 `old_string` 发成对象/null 以外的类型，`as String` 直接抛。调用点在 `widgets/bubbles/assistant_bubble.dart:841` 的 getter `_editDiff` 里，属于 build 路径 → 整个消息气泡渲染红屏。
**证据**：
```dart
final filePath = (input['file_path'] ?? input['path'] ?? '') as String;
final oldString = (input['old_string'] ?? '') as String;
final content   = (input['content'] ?? '') as String;
```
**修复方向**：全部改成 `input['file_path'] is String ? ... : ''` 或 `?.toString() ?? ''`；`synthesizeEditToolDiff` 外层包 try/catch 返回 null 以兑现文档承诺。

---

### [P2] `.../apps/mobile/lib/utils/terminal_launcher.dart:16-20,47`（模板注入 + 未捕获 FormatException）
**问题**：`expandTerminalUrl` 把 host / user / projectPath **原样**拼进 URL 模板，不做任何 percent-encoding；`Uri.parse(url)` 又在 try 块之外。
**触发场景**：
1. `projectPath` 含空格/`&`/`#`/`?`（很常见，如 `/Users/me/My Project`）→ 生成的 URL 结构被破坏。若模板是 `ssh://{{user}}@{{host}}:{{port}}{{project_path}}` 之类，`#` 之后的路径直接被当 fragment 丢弃。
2. 更严重的是命令注入面：这类终端 App 的自定义 scheme 常带命令参数（如 `xxx://run?cmd=cd%20{{project_path}}%20%26%26%20...`）。若 `projectPath` 或远端返回的 `worktreePath` 含 `&&`、`;`、反引号，会被目标终端 App 当作 shell 命令的一部分执行。projectPath 来自远端 Bridge，属于半可信输入。
3. 拼出的字符串若非法（如 host 为空、模板含中文未编码），`Uri.parse` 抛 `FormatException`，而 try 只包住了 `launchUrl` → 异常逃逸到调用方。
**证据**：
```dart
return template
    .replaceAll('{{host}}', host)
    .replaceAll('{{project_path}}', projectPath);   // 无编码
...
final uri = Uri.parse(url);          // 在 try 之外
try { return await launchUrl(uri, ...); } catch (_) { return false; }
```
**修复方向**：替换时用 `Uri.encodeComponent(value)`（或按占位符在模板中的位置区分 path 段用 `Uri.encodeComponent`、query 段用 `Uri.encodeQueryComponent`）；把 `Uri.parse` 换成 `Uri.tryParse` 并在 null 时返回 false；对 projectPath 做字符白名单校验，拒绝含 `` ` ``、`$(`、`;`、`&&`、换行的路径。

---

### [P2] `.../apps/mobile/lib/utils/history_window_policy.dart:110-181`（重复全量投影）
**问题**：`selectTurnAwareChatEntryWindow` 与 `selectTurnAwareChatEntryWindowIndexes` 各自把整个 `entries` 列表转换成一份新的 `List<ServerMessage>`（对 `StreamingChatEntry` 还要新建 `AssistantMessage` + `TextContent`），然后再跑一遍完整投影。两个函数**逻辑完全重复**，谁也没复用谁的结果。
**触发场景**：`chat_session_cubit.dart:2688` 的 `_canonicalTailForPagedLocalMirror` 在每次 canonical/mirror 合并时调用；紧接着的 for 循环里还对每个投影项调 `_indexOfEquivalentEntry(mirrorEntries, canonical)` → 整体 O(n·m)。长会话（`maxRetainedEntries` 755）+ 高频流式更新时，每条流式增量都要重跑一遍。`_newestOrdinaryEnvelopeIndexes` 里对每条消息调 `_allHeavyToolIdsForMessage`，后者 `_uniqueNonEmpty` 每次都新建 List + Set（`.map().where().toSet().toList()`），即每条消息 3 次中间集合分配。
**证据**：
```dart
List<String> _uniqueNonEmpty(Iterable<String> values) => values
    .map((value) => value.trim()).where((v) => v.isNotEmpty).toSet().toList();
```
**修复方向**：让 `selectTurnAwareChatEntryWindowIndexes` 复用 `projectTurnAwareServerMessageWindow` 的一次结果（把 messages 构造抽成私有函数，两个入口共用）；`_allHeavyToolIdsForMessage` 在只需判空的场景改成短路的 `bool _hasHeavyTool(...)`，避免构造集合。

---

### [P2] `.../apps/mobile/lib/utils/request_user_input.dart:33-85`（重复解析 + 全量丢弃 + 无反馈）
**问题**：
1. `firstRequestUserInputQuestion` → `requestUserInputQuestions` 会把整个 questions/options 结构重新拷贝一遍（`Map<String,dynamic>.from` × N）。而 `requestUserInputOptionLabels`、`requestUserInputHeader`、`requestUserInputQuestionText`、`hasRequestUserInputQuestions`、`isMcpApprovalRequestUserInput` 各自都会再触发一次完整解析。渲染一个审批卡片会重复解析 4–5 次。
2. 校验策略是"一处不合法 → `return const []` 丢弃**全部**问题"，且完全静默：用户看到的是一个什么都没有的空卡片，不知道 Agent 其实在等输入。
**证据**：
```dart
final text = question['question'];
if (text is! String || text.trim().isEmpty) return const [];   // 丢弃全部，非跳过本条
```
**修复方向**：把解析结果缓存（或让调用方一次解析、把 `List<Map>` 传下去）；校验失败改为跳过单条（`continue`）而非清空；全部失败时返回一个可见的降级提示而非空。

---

### [P2] `.../apps/mobile/lib/utils/diff_parser.dart:174-258`（大 diff 主 isolate 解析）
**问题**：`parseDiff` 先 `diffText.contains('diff --git')` 全串扫描，再 `diffText.split('\n')` 一次性物化**全部行**的 List，然后为每一行构造一个 `DiffLine` 对象。没有任何行数/字节上限，也没有 `compute()`/isolate 卸载。
**触发场景**：`git_view_cubit.dart:86/108` 打开一个大改动的 Git 界面（例如 lockfile 或生成代码，几十万行），主 isolate 阻塞数秒 + 内存峰值数百 MB（每行至少一个 String + 一个 DiffLine 对象）。
**修复方向**：加入行数/字节上限并截断提示（"diff 过大，仅显示前 N 行"）；把 `parseDiff` 移到 `compute()`；`DiffLine.content` 考虑保存 (start,end) 偏移而非子串以减少分配。

---

### [P3] `.../apps/mobile/lib/utils/diff_parser.dart:177`（CRLF）
`diffText.split('\n')` 会让每行尾部残留 `\r`。后果：(1) `DiffLine.content` 带 `\r`，在渲染时表现为行尾多一个不可见/方块字符（Windows 仓库的 diff 每一行都受影响）；(2) `_parseHunk` 第 361 行的 `line.isEmpty` 判断对 `"\r"` 失效，会落到第 365 行"未知格式 → 当作 context"分支，凭空多出一行 context 且 oldLine/newLine 双双 +1，导致后续行号全部偏移 1。仓库 `test/diff_parser_test.dart` 中没有任何 CRLF 用例。
**修复方向**：`diffText.split(RegExp(r'\r?\n'))`，或 split 后统一 `line.endsWith('\r') ? line.substring(0, line.length-1) : line`。

### [P3] `.../apps/mobile/lib/utils/diff_parser.dart:205`（二进制 diff 识别不全）
只识别 `Binary files ...` 前缀。`git diff --binary` 产出的是 `GIT binary patch` + base85 数据块，会被当成普通行逐行解析成 context/addition，渲染出大段乱码。建议同时匹配 `GIT binary patch`、`Binary files`、以及 `index ...` 后跟 `literal`/`delta` 的形态。

### [P3] `.../apps/mobile/lib/utils/diff_parser.dart:164`（合并 diff / 无换行结尾）
`_hunkHeaderRegex` 只匹配 `@@ -a +b @@`。merge/combined diff 的 `@@@ -1,2 -1,2 +1,2 @@@` 不匹配 → `oldStart/newStart` 静默回落到 1，行号全错；且 combined diff 的双列 `+`/`-` 前缀会被误判。另外 `\ No newline at end of file` 在第 357 行被直接跳过、不记录，`reconstructUnifiedDiff` 输出时该标记丢失，且末尾 `trimRight()`（第 663/548 行）会连带吃掉最后一行内容的尾随空格——若这段重建 diff 被下游 `git apply`，会应用失败或改坏文件。当前调用点（`git_screen.dart:517/599` 的 `request_change`）只是把它当文本发给 Agent，所以影响有限，但接口本身是有损的，建议在 `DiffLine` 上加 `noNewlineAtEof` 标志并在重建时写回。

### [P3] `.../apps/mobile/lib/utils/debug_bundle_share.dart:219-240` vs `diff_parser.dart:681-736`（路径处理不一致）
两处都在从 `diff --git` 行提取路径，但策略完全不同：`diff_parser._extractFilePath` 支持带空格路径、引号、八进制转义解码；而 `debug_bundle_share._extractChangedFiles` 只做 `line.split(' ')` 取 `parts[2]`。
```dart
final parts = line.split(' ');
if (parts.length < 4) continue;      // 含空格的路径会被整条跳过或取到错误片段
var file = parts[2];
```
含空格的路径（`diff --git a/My Project/a.md b/My Project/a.md`）会被算成 6 段、`parts[2]` = `Project/a.md`，写进给 Agent 的"changed files"清单里就是错的。建议直接复用 `_extractFilePath`。

### [P3] `.../apps/mobile/lib/utils/debug_bundle_share.dart:11-51`（敏感信息 / 竞态 / 静默吞异常）
关于泄漏，逐项核实结论如下：
- `reproRecipe.wsUrlHint` 经核实为 `packages/bridge/src/websocket.ts:12184` 的 `ws://localhost:${bridgePort}`，**不含 apiKey/token**；`startBridgeCommand` 为 `BRIDGE_PORT=... npm run bridge`，也不含密钥。**未发现凭据泄漏**。
- 会进入剪贴板的确实包含：`projectPath` / `worktreePath` / `savedBundlePath` / `traceFilePath`（远端机器绝对路径，含用户名）、`historySummary`（对话内容）、`debugTrace[].detail`、以及最多 20000 字符的 `diff`（源码）。这些是该功能的题中之义，但**用户在点击前没有任何"将要复制哪些内容"的提示**，且结果直接进系统剪贴板（iOS 上其他 App 可读）。建议在 SnackBar 或确认弹窗中列出将包含的项目，并考虑对 `projectPath` 做 `shortenPath` 式脱敏。
- 无临时文件产生（纯剪贴板），**"临时文件未清理"不成立**。
- 竞态：订阅按 `bundle.sessionId` 匹配，没有 request id。同一 session 上有并发/迟到的 bundle 响应时，会用旧响应完成当前 completer。
- 第 44 行 `catch (_)` 把 timeout、Clipboard 失败、prompt 构造异常全部收敛成同一句 "Failed to build debug bundle"，无日志。建议区分并 `logger.error`。

### [P3] `.../apps/mobile/lib/utils/history_window_policy.dart:401-417`（`_hardCapProjectedMessages` 可超出上限）
先无条件把所有 `UserInputMessage` 的下标塞进 `selected`，再按 limit 补齐。若用户消息条数本身就超过 `maxRetainedEntries`(755)，返回长度会大于 limit，"硬上限"名不副实。
```dart
for (var index = 0; index < projected.length; index++) {
  if (projected[index].message is UserInputMessage) selected.add(index);  // 无 limit 约束
}
```
建议对 root turn 也做从新到旧的截断。

### [P3] `.../apps/mobile/lib/utils/tool_categories.dart:350,358,367`（substring 截断可能切断代理对）
`cmd.substring(0, 57)`、`s.substring(0, 47)` 按 UTF-16 code unit 截断。命令/查询里含 emoji 或部分 CJK 扩展字符时会切在代理对中间，产生孤立代理项，渲染成 `�`。建议用 `characters` 包的 `String.characters.take(n)`。

### [P3] `.../apps/mobile/lib/utils/tool_categories.dart:329, 336-340`（路径分隔符不一致）
`_fileSummary` 只按 `'/'` 取 basename：
```dart
final idx = path.lastIndexOf('/');
return idx >= 0 ? path.substring(idx + 1) : path;
```
Windows 远端返回 `C:\src\main.dart` 时整串原样显示。同一仓库内 `artifact_link_matcher.isSafeProjectRelativePath` 用的是 `split(RegExp(r'[\\/]'))`（同时处理两种分隔符），`file_mention_matcher` 只处理 `/`，三者不一致。建议抽一个共用的 `basenameOf(path)` / `splitPathSegments(path)` 工具。

### [P3] `.../apps/mobile/lib/utils/platform_helper_io.dart:4` + `features/session_list/session_list_screen.dart:182-189`（HOME 语义错误）
`getHomeDirectory() => Platform.environment['HOME'] ?? ''`：Windows 上没有 `HOME`（应为 `USERPROFILE`），返回空串；更关键的是唯一调用方 `shortenPath` 用**本机** HOME 去缩短**远端机器**的路径。iOS/Android 上 HOME 是 App 沙盒路径，永不匹配（功能静默失效）；macOS 桌面端则可能用本机 home 误缩短远端路径。建议 `shortenPath` 接收远端 home（从 Bridge 的 session 信息取），或至少加 `Platform.environment['USERPROFILE']` 兜底。

### [P3] `.../apps/mobile/lib/utils/artifact_link_matcher.dart:36-56, 13-24`（每链接重复编译正则 + O(n·m)）
`_decodedSafeHref` 每次调用新建 2 个 `RegExp`；`matchArtifactHref` 对 artifacts 列表逐个调 `artifactHrefsEquivalent`，即渲染一条含 K 个链接、附带 M 个 artifact 的消息 → 2·K·M 次正则编译 + K·M 次 `Uri.decodeFull`。正则本身（`%(?:2f|5c|00)`、`^[^:/\\]+:\d+(?::\d+)?$`）结构线性，**无灾难性回溯 / ReDoS 风险**（已逐条核对，`file_mention_matcher` 与 `artifact_link_matcher` 的正则都不存在嵌套量词或重叠交替）。建议把 4 个正则提到顶层 `final`，并对 artifacts 预建 `Map<decodedHref, List<ArtifactRef>>` 索引。

### [P3] `.../apps/mobile/lib/utils/artifact_link_matcher.dart:90-102`（`isSafeProjectRelativePath` 漏判）
`RegExp(r'^[A-Za-z]:[\\/]')` 要求盘符后必须有分隔符，因此 Windows 的**驱动器相对路径** `C:foo\bar`（等价于"C 盘当前目录下的 foo"）会被判为安全。另外 `~/secret` 也会通过（`~` 未被拦截，若下游做 shell 展开则可越界）。建议同时拒绝 `^[A-Za-z]:` 与以 `~` 开头的路径。

### [P3] `.../apps/mobile/lib/utils/composer_tokens.dart:231-240`（改状态不通知）
```dart
void updateTokenState({...}) {
  if (_config == config && _palette == palette) return;
  _config = config;
  _palette = palette;      // 没有 notifyListeners()
}
```
`TextEditingController` 是 `ValueNotifier`，改了高亮配置却不通知，依赖调用方（`chat_input_with_overlays.dart:207`）恰好在 build 中调用、同帧内 TextField 会重建这一巧合。一旦调用点移出 build（例如放进 `didChangeDependencies` 或某个回调），高亮就会停留在旧配置直到下次按键。建议在实际变更时 `notifyListeners()`（注意避免 build 期间同步通知，可用 `WidgetsBinding.instance.addPostFrameCallback`）。

### [P3] `.../apps/mobile/lib/utils/composer_tokens.dart:52-75`（相等性判断 O(n)）
`ComposerTokenConfig.operator==` / `hashCode` 对 5 个 Set 做全量 `SetEquality`。调用方 `chat_input_with_overlays.dart:200` 每次 build 都新建 `fileMentions: projectFiles.toSet()`（大仓库数千条）再交给 `updateTokenState` 比较 → 每帧一次数千元素的 Set 构造 + 全量比较。建议给文件列表加一个版本号/身份标识参与相等性判断，而不是逐元素比。

### [P3] `.../apps/mobile/lib/utils/network_endpoint.dart:6-12`（`%25` 归一化过宽）
```dart
if (normalized.contains(':')) {
  normalized = normalized.replaceFirst(RegExp('%25', caseSensitive: false), '%');
}
```
`replaceFirst` 替换的是**字符串中第一个** `%25` 而非 zone 分隔符位置，双重编码输入 `fe80::1%2525en0` 只会解一层；且每次调用新建 RegExp（可用常量字符串 + `toLowerCase` 判断替代）。
经测试核实（`test/network_endpoint_test.dart:21-24`），`formatUriOrigin` 依赖 Dart `Uri` 会把 `%` 重新编码回 `%25`，**IPv6 zone id 与 origin 生成是正确的**，此处不构成 bug。

### [P3] `.../apps/mobile/lib/utils/network_endpoint.dart:15-19`（`bracketIpv6Host` 无校验）
凡是含 `:` 就加方括号。用户在 host 输入框里误填 `example.com:8080` 时会得到 `[example.com:8080]`，再经 `formatHostPort` 变成 `[example.com:8080]:8765`，错误形态会一路传到连接层才失败。建议先用 `Uri.parseIPv6Address` 试探，非法则不加括号并向上层报错。

### [P3] `.../apps/mobile/lib/utils/structured_error_inference.dart:9, 83-85`
`message.toLowerCase()` 对可能很长的错误文本整体转小写，随后约 25 次 `contains` 全串扫描（O(25n)）；`_looksLikePathNotAllowed` 每次调用编译一个正则。若该函数在消息渲染路径上被反复调用，建议把正则提到顶层 final，并对超长 message 只取前若干 KB 参与匹配。

### [P3] `.../apps/mobile/lib/utils/codex_plan_update.dart:14-16`
`itemPattern` 在函数体内构造，虽然一次调用只编译一次，但每次调用都重编译；且 `(.+?)\s*$` 是惰性量词紧跟 `\s*$`，对超长行存在 O(n²) 回溯（无嵌套量词，不构成灾难性回溯，但仍是可避免的开销）。建议提到顶层 `final`，并把 `(.+?)\s*$` 改为 `(.*\S)\s*$` 之类的贪婪写法。

### [P3] `.../apps/mobile/lib/utils/command_parser.dart:4-11`
`<command-name>\s*(.*?)\s*</command-name>` 用了 `dotAll: true` 的惰性匹配。若文本中出现多个未闭合的 `<command-name>`，每个起始位置都会向后扫到文本末尾，最坏 O(k·n)。字面量前缀限制了起始位置数量，**不属于灾难性回溯**，但对超大 tool 输出仍建议加长度上限。正则本身为顶层 `final`，无重复编译问题（这点做得比 `composer_tokens` / `file_mention_matcher` 好）。

### [P3] `.../apps/mobile/lib/utils/text_line_preview.dart:14-22`
逻辑正确、无越界（已逐分支验证）。唯一小瑕疵：CRLF 内容返回的行尾会带 `\r`，与 `diff_parser` 是同类问题。

---

## 已检查、未发现问题的文件

- `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/apps/mobile/lib/utils/command_completion_matcher.dart` —— 正则均为顶层 `final`（全目录中做得最规范的一个）；`_subsequenceScore` 是严格 O(n+m) 单指针扫描，`rankCommandCompletions` 的排序比较器提供了完全确定的全序（score → 长度 → 字典序 → 原始下标），无不稳定排序问题。不涉及引号转义解析，故"引号转义"关注点在此文件不适用。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/apps/mobile/lib/utils/system_message_visibility.dart` —— 8 行纯函数。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/apps/mobile/lib/utils/platform_helper.dart` —— 条件导出，写法正确。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/apps/mobile/lib/utils/platform_helper_stub.dart` —— Web 桩实现，与 io 版签名一致。
- `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/apps/mobile/lib/providers/bridge_cubits.dart` —— 仅 typedef/薄子类；注释已正确说明为何 `FileListCubit`/`ProjectHistoryCubit` 必须是独立类而非 typedef（BlocProvider 类型解析）。其风险全部继承自 `stream_cubit.dart`，已在上面单列。
- `machine_manager_cubit.freezed.dart` —— 生成代码，按要求跳过逐行审查。

## 两点补充说明

1. **`debug_bundle_share.dart` 的凭据泄漏结论是否定的**：我追到了 Bridge 侧 `packages/bridge/src/websocket.ts:12178-12210` 的 `buildReproRecipe`，`wsUrlHint`/`startBridgeCommand` 均为写死的 localhost + 端口，不含 API key；也没有临时文件产生。真正需要留意的只是路径/源码/对话内容进剪贴板时缺少事前告知。
2. **ReDoS 关注点的结论也是否定的**：`artifact_link_matcher.dart` 与 `file_mention_matcher.dart`（以及 `command_parser.dart`、`codex_plan_update.dart`）的全部正则我逐条检查了量词结构，不存在嵌套量词或重叠交替，**无灾难性回溯风险**。这两个文件的真实问题是"在循环/热路径中重复编译正则"，属性能而非安全。
