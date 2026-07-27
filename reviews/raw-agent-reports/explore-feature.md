I'll start by exploring the directory structure to find all the files in scope.
Let me read the core state management files first.
Now the session_link and session_insights files.
Now the remaining smaller files.
Now let me examine the supporting services and how these are wired up.
审查完成。以下是发现（按严重度排序）。

---

## P1

### [1] P1 — Explorer 无限 loading：没有超时、没有失败通路，`ExploreStatus.error` 是死代码
**文件**：`/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/apps/mobile/lib/features/explore/state/explore_cubit.dart:22-28`、`.../explore/explore_screen.dart:246-251`

**触发场景**：Bridge 未连上 / 目录扫描失败 / 权限拒绝 / 超大仓库扫描超时 → 用户永远看到转圈。

**证据**：初始状态 `@Default(ExploreStatus.loading)`（`explore_state.dart:36`），构造函数里 `_bridge.requestFileList(projectPath)` 是纯 fire-and-forget，没有 requestId、没有 Timer：
```dart
_fileListSub = _bridge.fileListMessages.listen(_onFileListUpdated);
if (initialFiles.isNotEmpty) { _applyFiles(...); }
_bridge.requestFileList(projectPath);   // 无超时、无失败回调
```
`_applyFiles` 只会 emit `ready`/`empty`，且恒定 `error: null`。全局搜索确认 `ExploreStatus.error` 与 `ExploreState.error` **在 lib/ 下没有任何一处被赋值**，`explore_screen.dart:250-251` 的 `case ExploreStatus.error` 永远走不到。

**修复方向**：给 `requestFileList` 加 request-id 关联 + N 秒超时 Timer，超时/断线时 emit `ExploreStatus.error` 并提供重试按钮（错误分支 UI 已经写好了，只差有人 emit）。

---

### [2] P1 — `ExploreCubit` 对 `FileListMessage` 零关联，任何一路文件列表响应都会覆盖当前目录树
**文件**：`.../explore/state/explore_cubit.dart:23, 30-36`

**触发场景**：
- (a) 工作区双栏模式下，Explorer 面板与聊天面板共存，App 从后台恢复时后台会话也会重新请求文件列表；
- (b) 任意断线/会话重置时 Bridge 会广播一个**空**文件列表 → Explorer 直接翻到 "No files to explore" 且永不恢复。

**证据**：`FileListMessage` 结构里**根本没有 projectPath / requestId**（`lib/models/messages.dart:3384-3394`）：
```dart
class FileListMessage implements ServerMessage {
  final List<String> files;
  final int? totalFiles;
  final bool truncated;
}
```
而 cubit 无条件接收：
```dart
void _onFileListUpdated(FileListMessage message) {
  _applyFiles(message.files, truncated: ..., totalFiles: ...);
}
```
广播源 `lib/services/bridge_service.dart:1672-1674` 对所有订阅者一视同仁；`bridge_service.dart:2045` 在会话重置里主动推空列表：
```dart
_fileListMessageController.add(const FileListMessage(files: []));
```
且 `lib/features/codex_session/codex_session_screen.dart:1102-1111` 的 app-resume 回调**没有 `isBackground` 守卫**（对比同文件 1023 行的挂载逻辑是有守卫的），每个常驻会话都会用自己的 `chatFileRoot` 重新请求：
```dart
useAppResumeCallback(lifecycleState, () {
  ...
  if (chatFileRoot != null) { bridge.requestFileList(chatFileRoot); }
```
`claude_session_screen.dart:897` 同款。`chatFileRoot` 在 worktree 会话下 = worktreePath，与 Explorer 的 projectPath 可以不同（`chat_message_list.dart:37-42`）。

**修复方向**：`FileListMessage` 加 `projectPath` + `requestId` 字段，Explorer 只接受自己那一条；至少先按 `projectPath` 过滤，并且忽略"空列表重置"这种非响应事件。

---

### [3] P1 — 归档 Cubit 把"连接抖动"当作"操作失败"上报，与同项目既有的"结果未知"策略自相矛盾（删除是破坏性操作）
**文件**：`.../session_archive/session_archive_cubit.dart:83-87, 283-301`

**触发场景**：用户点"永久删除"→ Bridge 已经执行删除 → 恰好网络抖动/重连 → App 弹"操作失败"。用户以为没删，重试或困惑；列表也不刷新，被删的会话还在。

**证据**：订阅对**任何非 connected 状态**（包括每次重连开头的 `connecting`、`reconnecting`）都触发 `_failAll`：
```dart
_connectionSubscription = _bridge.connectionStatus.listen((status) {
  if (status != BridgeConnectionState.connected) {
    _failAll('Bridge disconnected before confirming the operation.');
  }
});
```
`bridge_service.dart:1424` 每次连接尝试都会先 emit `connecting`，`2287/2293` emit `reconnecting`。`_failRequest` 直接把它写成 `error:`，UI 渲染成 `strings.failed(...)`。

而同一 feature 里的另一条归档路径明确写了相反的纪律（`.../session_archive/session_archive_pending_requests.dart:30-33`）：
> "A timeout or disconnect only releases local busy state and **reports that the result is unknown**. It never sends or replays the destructive request."

对应文案 `session_archive_strings.dart:100-119` 的 `archiveResultUnknown` 已经存在，但 cubit 这条路径没用。

**修复方向**：`_failAll`/超时路径改为"结果未知"语义（复用 `archiveResultUnknown` 文案），只释放 busy 状态；并且只在真正 `disconnected` 时触发，不要对 `connecting`/`reconnecting` 反应。

---

### [4] P1 — `SessionLinkCubit.resolve()` 无 try/catch，抛异常即永久卡在 "Resolving…"
**文件**：`.../session_link/state/session_link_cubit.dart:36-42`；`.../session_link/session_link_screen.dart:31`

**触发场景**：解析过程中 BridgeService 被 dispose（切换机器、退出登录），或消息队列里有异常项。

**证据**：
```dart
Future<void> resolve() async {
  if (_started) return;
  _started = true;
  final result = await _bridge.resolveSessionLink(...);   // 无 try/catch
```
调用方是 fire-and-forget：`SessionLinkCubit(...)..resolve()`（screen:31），异常无人接管。而 `resolveSessionLink` 有两条会抛非 `TimeoutException` 的路径（`bridge_service.dart:3204-3209`）：
```dart
await connectionStatus
    .firstWhere((state) => state == BridgeConnectionState.connected)  // 无 orElse
    .timeout(timeout);
} on TimeoutException {                                               // 只catch超时
```
`connectionStatus` 是普通 broadcast controller，被 close（`bridge_service.dart:5098`）时 `firstWhere` 抛 `StateError`，穿透 `on TimeoutException`。另外 `finally` 块里 `jsonDecode(message.toJson()) as Map<String, dynamic>`（`3237`）也会抛并覆盖返回值。

一旦抛出，state 永远停在 `SessionLinkState.resolving()`，而 `SessionLinkStatusView`（screen:150-171）只在 `unavailable` 时才显示"打开最近会话"逃生按钮 → **死转圈，无出口**。

**修复方向**：`resolve()` 整体 try/catch，任何异常收束到 `emit(SessionLinkState.unavailable())`；`firstWhere` 补 `orElse`；`finally` 里的 `jsonDecode` 用 try 包裹。

---

### [5] P1 — session_link 的 resume 阶段没有超时，等不到 `session_created` 就永久 "Resuming…"
**文件**：`.../session_link/state/session_link_cubit.dart:83-116`

**触发场景**：resume 请求发出后 Bridge 崩溃/断线/静默丢弃，或 Bridge 版本不回 `session_resume_failed`。

**证据**：`resolve()` 侧有 10s 超时兜底，但 `_resume` 完全没有：
```dart
Future<void> _resume(RecentSession session) async {
  await _resumeSubscription?.cancel();
  _resumeSubscription = _bridge.messages.listen(_handleResumeMessage);
  emit(const SessionLinkState.resuming());
  final dispatch = await _resumeCoordinator.resume(session, resumeRequestId: _resumeRequestId);
  if (isClosed) return;
  _resumeGitBranch = dispatch.gitBranch;
  if (dispatch.disposition == SessionResumeDisposition.alreadyQueued) { ... }
  // dispatched 分支：无 Timer，只能等 _handleResumeMessage
}
```
`_handleResumeMessage` 只在收到 `session_created` 或 `session_resume_failed` 时收束（99-116）。没有连接状态订阅、没有 Timer → 断线时状态机永远停在 `resuming`，同样没有逃生按钮。

**修复方向**：`_resume` 加超时 Timer + `connectionStatus` 订阅，两者任一触发就 `emit(unavailable())`；并在 `close()` 中取消该 Timer。

---

## P2

### [6] P2 — `_SessionInsightsPanelState` 缺 `didUpdateWidget`，sessionId 变化后继续展示旧会话的用量
**文件**：`.../session_insights/widgets/session_insights_bar.dart:315-342`

**证据**：`_SessionInsightsBarState` 正确处理了（52-61）：
```dart
if (oldWidget.sessionId == widget.sessionId && ... ) return;
_removeController(); _installController();
```
而 `_SessionInsightsPanelState` 只有 `initState`（319-331）与 `dispose`（337-342），**完全没有 `didUpdateWidget`**。Flutter 复用同一 State（同类型同位置）时，切换会话后 panel 仍绑定旧 `sessionId` 的 controller，显示错误会话的 context/quota，且旧 controller 的订阅泄漏到新会话生命周期。

**修复方向**：把 Bar 的 `didUpdateWidget` 逻辑抽成 mixin 或直接复制到 Panel。

---

### [7] P2 — 底部详情表持有可能已被 dispose 的 controller
**文件**：`.../session_insights/widgets/session_insights_bar.dart:75-78, 226-251`

**触发场景**：详情 sheet 打开期间，底层的 SessionInsightsBar 被移除（切换会话/工作区重排）。

**证据**：`_removeController()` 在 `dispose` 时无条件销毁自有 controller：
```dart
void _removeController() {
  _controller.removeListener(_changed);
  if (_ownsController) _controller.dispose();
}
```
而 sheet 是独立 route，持有同一实例：
```dart
await showModalBottomSheet<void>(context: context, ...
  child: ListenableBuilder(listenable: _controller, ...
    onRefresh: () => _controller.refresh(force: true),
```
`ChangeNotifier` 在 dispose 后被 `addListener`/`notifyListeners` 会命中 `_debugAssertNotDisposed` 断言（debug 崩溃，release 行为未定义）。

**修复方向**：sheet 用 `showModalBottomSheet` 的返回 Future 与 `mounted` 联动，或在 `_removeController` 前先 `Navigator.maybePop`；更稳妥是把 controller 提到 route 之上（Provider）由更长生命周期持有。

---

### [8] P2 — 归档屏幕把"重复点击/不支持"的 `false` 当作失败展示，且拼接的是陈旧的 `state.error`
**文件**：`.../session_archive/session_archive_cubit.dart:152-154`；`.../session_archive/session_archive_screen.dart:200-204, 215-218`

**证据**：`_mutate` 在去重命中时静默返回 false，**不 emit 任何 error**：
```dart
if (!state.supported || state.pendingSessionKeys.contains(identityKey)) {
  return Future.value(false);
}
```
屏幕侧却把所有 false 一律当失败，并读取可能属于上一次无关操作的 `state.error`：
```dart
final success = await cubit.unarchive(session);
messenger.showSnackBar(SnackBar(content: Text(
  success ? strings.restored : strings.failed(cubit.state.error ?? ''))));
```
结果是弹出"操作失败："（空 detail），或者更糟——弹出一条与本次操作无关的旧错误。

**修复方向**：返回值改为枚举/结果对象（`succeeded / rejectedDuplicate / failed(reason)`），UI 按类型分支；至少让 `_mutate` 的拒绝路径不展示 snackbar。

---

### [9] P2 — `_ensureHighlightedVisible()` 在 `build()` 内注册 post-frame 回调，且用的是上一帧的 context
**文件**：`.../explore/explore_screen.dart:140-151, 157`

**证据**：
```dart
builder: (context, state) {
  _ensureHighlightedVisible();      // 每次 rebuild 都调用
```
```dart
void _ensureHighlightedVisible() {
  final currentContext = _highlightedEntryKey.currentContext;   // 上一帧的 element
  if (_highlightedFilePath == null || currentContext == null) return;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted || _highlightedFilePath == null) return;
    Scrollable.ensureVisible(currentContext, ...);              // 未校验 currentContext.mounted
  });
}
```
`_highlightedFilePath` 在 peek 之后**从不清空**（只在点目录/面包屑时才置 null），所以只要高亮着，之后每一次 BlocBuilder 重建都会再排一次 220ms 滚动动画——快速切目录/连续收到文件列表时表现为列表被反复"拽"回去。同时 `currentContext` 捕获自上一帧，若该 tile 已因目录切换被移除，`Scrollable.ensureVisible` 对 deactivated element 会抛异常。

**修复方向**：把滚动触发移到 `_openFilePeek` 的一次性回调里（或用 `didUpdateWidget`/状态变更比较），并在回调内改用 `_highlightedEntryKey.currentContext` 重新取、加 `.mounted` 校验。

---

### [10] P2 — 断线重连后 Explorer 与归档列表都不会自动恢复
**文件**：`.../explore/state/explore_cubit.dart:14-28`；`.../session_archive/session_archive_cubit.dart:83-87`

**证据**：`ExploreCubit` 完全没有 `connectionStatus` 订阅，`requestFileList` 只在构造时发一次。配合 [2] 的空列表重置，断线后 Explorer 停在空状态直到用户手动关闭重开。`SessionArchiveCubit` 虽然订阅了连接状态，但只在断开时 `_failAll`，**`connected` 分支什么都不做**（83-87 只有 `if (status != connected)`），重连后列表保持陈旧（尤其在 [3] 误报失败之后，被删的会话仍显示在列表里）。

**修复方向**：两个 cubit 都在 `connectionStatus == connected` 时重发列表请求（归档侧注意与 `isLoading` 去重）。

---

### [11] P2 — Explorer 与归档列表都没有真正的分页/懒加载，只有截断提示且无"加载更多"
**文件**：`.../explore/explore_screen.dart:218-222, 271-311`；`.../session_archive/session_archive_screen.dart:76-104`

**证据**：Explorer 用 `state.fileListTruncated` 渲染只读横幅 `_FileListTruncatedNotice`（"Showing X of Y entries"），归档屏幕用 `strings.truncated`（"仅显示最近 1000 个归档会话"），两处都**没有任何加载更多的入口**，也没有 offset/limit 参数。归档屏幕更是用裸 `ListView(children: [...])` 一次性构建全部 tile（76-104），千级列表时全部 tile 同时实例化，无 builder 复用。

另外 Explorer 的截断是在**整仓文件列表**层面发生的，而目录树是本地从这份被截断的列表推导的（`buildExploreEntries`，`explore_cubit.dart:115-159`）——这意味着**深层目录可能整个消失**，用户看到的不是"这个目录空"而是目录压根不存在，横幅文案完全无法表达这一点。

**修复方向**：归档列表至少换成 `ListView.builder`；两处补 offset 分页协议，或在截断时明确提示"目录树不完整"。

---

## P3

### [12] P3 — `ExploreCubit.close()` 未 await 订阅取消（与同项目 archive cubit 不一致）
**文件**：`.../explore/state/explore_cubit.dart:108-112`

```dart
@override
Future<void> close() {
  _fileListSub?.cancel();     // 未 await
  return super.close();
}
```
对比 `session_archive_cubit.dart:309-315` 是 `await _messageSubscription.cancel();`。且 `_applyFiles`/`openDirectory`/`goUp` 的 `emit` 均无 `isClosed` 守卫。broadcast stream 下 `cancel()` 同步摘除监听，实际风险低，但这是"Cannot emit after close"最常见的埋雷形态，建议统一。

**修复方向**：`close()` 改 async 并 await；`_onFileListUpdated` 开头加 `if (isClosed) return;`。

---

### [13] P3 — `SessionInsightsController._onSessionMessage` 缺 `_disposed` 守卫
**文件**：`.../session_insights/state/session_insights_controller.dart:148-212, 234-243`

`dispose()` 里 `_sessionSubscription?.cancel()` 未 await，而 `_onSessionMessage` 的四个分支都直接 `notifyListeners()`，没有 `_disposed` 检查——对比同类里 `_minuteTimer`（83-85）和 `_clearLoading`（231）都做了 `!_disposed` 守卫，明显是遗漏。dispose 后 `notifyListeners()` 会命中断言。

**修复方向**：`_onSessionMessage` 首行加 `if (_disposed) return;`。

---

### [14] P3 — session_link 的 `_resumeGitBranch` 赋值晚于订阅启动，存在丢分支名的竞态
**文件**：`.../session_link/state/session_link_cubit.dart:85-92, 99-110`

订阅在 `await _resumeCoordinator.resume(...)` **之前**建立，而 `_resumeGitBranch = dispatch.gitBranch` 在其**之后**：
```dart
_resumeSubscription = _bridge.messages.listen(_handleResumeMessage);
emit(const SessionLinkState.resuming());
final dispatch = await _resumeCoordinator.resume(...);
if (isClosed) return;
_resumeGitBranch = dispatch.gitBranch;      // 可能晚于 session_created 到达
```
若 `session_created` 在 `resume()` 的 future 完成前投递，`_handleResumeMessage` 会用 `gitBranch: null` 构造 `openResumed`，路由跳转时丢失分支信息（screen:64-77 里 `session.worktreeBranch ?? gitBranch`，worktreeBranch 为空时就没了）。

**修复方向**：把 `gitBranch` 从 `RecentSession` 里提前取出（`session.gitBranch` 在 dispatch 前就已知），在建立订阅前赋值。

---

### [15] P3 — `refresh()` 的 `false` 语义与 `RefreshIndicator` 不匹配
**文件**：`.../session_archive/session_archive_cubit.dart:98-99`；`.../session_archive/session_archive_screen.dart:74-75, 35, 59`

```dart
if (!state.supported || state.isLoading) return false;
```
`RefreshIndicator(onRefresh: () => cubit.refresh())` 在已有请求在途时会立刻拿到完成的 Future → 下拉指示器瞬间收起，用户以为刷新完成了但其实什么都没发生。AppBar 的刷新按钮（35）同理，无任何反馈。

**修复方向**：`isLoading` 时返回**当前在途请求的 future** 而非 `false`。

---

### [16] P3 — `normalizeExplorePath` 静默回退，用户不知道自己被弹回了哪一层
**文件**：`.../explore/state/explore_cubit.dart:167-177`

```dart
while (candidate.isNotEmpty) {
  final prefix = '$candidate/';
  if (files.any((file) => file.startsWith(prefix))) return candidate;
  candidate = parentDirectoryOf(candidate);   // 静默上跳
}
return '';                                     // 静默回根
```
恢复 `initialPath`（跨会话/重开面板）时若该目录因为文件列表被截断（见 [11]）而"看不见"，用户会莫名其妙被扔回根目录且无任何提示。另外这是 O(files) 的线性扫描，每层循环一次，在截断上限（数千条）+ 深路径下是 O(depth × n)。

同时注意 `buildExploreEntries` 只从**文件路径**推导目录（123-149），所以**真正的空目录在 Explorer 中不可表达**——空目录、只含被过滤文件的目录、符号链接目录一律不显示，`ExploreEmptyState` 的文案（"Generated and cache directories may be hidden"）只覆盖了其中一种解释。

**修复方向**：回退时给出提示；或把目录信息作为一等公民从 Bridge 返回，而不是从文件路径反推。

---

## 附：确认无问题的点

- `session_archive_pending_requests.dart` 的去重（`register` 同时按 requestId 与 identityKey 查重，56-81）、超时释放、旧 Bridge 无 requestId 时的"唯一候选才认领"策略（85-107）、`_takeAll` 统一取消 Timer（140-147）——设计严谨，`session_list_screen.dart:706` 也正确 `dispose()`。
- `_PermanentDeleteDialogState` 的 `TextEditingController` 正确 dispose（`session_archive_screen.dart:249-253`），删除二次确认（输入 DELETE）到位。
- `SessionArchiveCubit.close()` 正确 await 两个订阅后再 `super.close()`，`_failRequest` 有 `isClosed` 守卫（290）。
- `SessionInsightsController` 的 generation 计数器（`_contextGeneration`/`_quotaGeneration`）+ `_quotaRequestId` 双重竞态守卫是本次审查范围内做得最好的一处，`start()` 的 `_started` 幂等、`dispose()` 里三个 Timer 全部取消。
- `SessionLinkCubit` 的 `resolve()`/`_resume()` 在每个 await 后都检查了 `isClosed`；`_handleResumeMessage` 首行也有 `isClosed` 守卫。
