I'll start by mapping out the directory structure and file sizes.
Let me kick off parallel deep-dives on models/ and utils/ while I review services/ myself.
主体审查（services/ 全部 36 个文件 + providers/ 全部）已完成。models/ 与 utils/ 的两路并行深挖尚未返回结果，下面是我直接审查得到的结论。

---

# A. 生命周期与泄漏

**[A-1] [P1] `services/ssh_bridge_tunnel_service.dart:71-118`｜`_ensureTunnel` 无 single-flight，并发调用泄漏 SSH 连接 + 监听端口**

触发场景：`MachineManagerService.checkAllHealth()`（30s 周期定时器 + `_waitForOnline` 每秒一次）、`syncAll` 逐机器 `buildWsUrl`、用户点击连接，都会并发进入同一 `machine.id`。

```dart
final existing = _tunnels[machine.id];
if (existing != null && existing.signature == signature) return existing;
await closeForMachine(machine.id);                 // ← await
final credentials = await _resolveJumpCredentials(...); // ← await（可能弹密码框）
final tunnel = await _BridgeTunnel.start(...);          // ← await（SSH 握手）
_tunnels[machine.id] = tunnel;                     // 后者覆盖前者
```
检查与写入之间有 3 个 await，两个调用都会看到 `null`，各建一条隧道；先完成的那条被覆盖后 **`_jumpClient` / `ServerSocket` / `_serverSubscription` 永不关闭**。`updateBridge` 的 30s 健康轮询会在一次操作里连续泄漏几十条。

修复方向：用 `Map<String, Future<_BridgeTunnel>> _inFlight` 做 per-machine single-flight（参考同仓 `PromptHistoryService._bridgeSyncsInFlight` 的写法）。

**[A-2] [P1] `services/ssh_bridge_tunnel_service.dart:93,116` + `main.dart:200`｜`closeAll` 与在建隧道竞态，隧道逃逸出清理**

`bridge.onDisconnect = sshBridgeTunnelService?.closeAll`。`closeAll()` 先 `_tunnels.clear()` 再逐个 close；若此刻某个 `_ensureTunnel` 正卡在 `_BridgeTunnel.start` 的 await 上，它完成后执行 `_tunnels[machine.id] = tunnel`，这条隧道**没被 closeAll 关掉、也不在任何清理路径里**。修复：清理时递增一个 epoch，`_ensureTunnel` 完成后校验 epoch 未变才注册，否则立即 close。

**[A-3] [P1] `services/ssh_bridge_tunnel_service.dart:213-369`｜隧道无自愈：jump SSH 断开后永久失效**

`_BridgeTunnel` 没有监听 `_jumpClient.done`。SSH 掉线后 `signature` 不变，`_ensureTunnel` 会一直返回这条死隧道（第 89-91 行直接 return），所有走 jump host 的机器**永久无法连接，且无任何错误提示**（`checkHealth` 只显示 offline）。修复：`_jumpClient.done.whenComplete(() => _tunnels.remove(machineId))`。

**[A-4] [P1] `services/voice_input_service.dart:33-49`｜`statusListener` 在 `listen()` 之后才注册，`_isListening` 可能永久卡死**

```dart
await _speech.listen(onResult: ..., listenOptions: SpeechListenOptions(cancelOnError: true, ...));
// SpeechToText calls onDone via statusListener when done
_speech.statusListener = (status) { if (status == 'done' || status == 'notListening') { _isListening = false; onDone(); } };
```
若在 `await listen` 期间就触发了 `done`/`notListening`（权限拒绝、立即错误、`cancelOnError` 生效），回调尚未装上 → `_isListening` 永远为 `true` → 第 31 行 `if (!_isAvailable || _isListening) return;` 使**语音输入此后永久无法启动**，UI 麦克风图标卡在录音态。修复：在 `listen()` 之前赋值 `statusListener` 与 `errorListener`。

**[A-5] [P2] `services/voice_input_service.dart:58-61`｜`dispose()` 不清 `statusListener`，持有已销毁 State 的闭包**

`dispose()` 只 `_speech.cancel()`。`statusListener` 里捕获的 `onDone` 通常是 widget State 的回调，widget 销毁后仍可能被调用 → `setState after dispose`。修复：`_speech.statusListener = null; _speech.errorListener = null;`。

**[A-6] [P2] `services/server_discovery_impl_io.dart:13-31`｜`eventStream.listen` 的 subscription 从不 cancel**

```dart
discovery.eventStream?.listen((event) { ... onResolved(...); ... });  // 返回值被丢弃
```
`stopDiscovery` 只调 `discovery.stop()`，订阅本身及其捕获的 `onResolved`/`onLost`（间接持有 `ServerDiscoveryService`）永不释放。修复：保存 subscription，在 `stopDiscovery` 中 `await sub.cancel()`。

**[A-7] [P2] `services/server_discovery_service.dart:43-65,74-78`｜`startDiscovery` 无 single-flight；`dispose()` 不 await 停止**

两次并发 `startDiscovery()` 都看到 `_discovery == null`（`stopDiscovery` 是 no-op），各起一个 Bonsoir 实例，第二个覆盖 `_discovery`，第一个的组播 socket + 定时器永久泄漏。`dispose()` 里 `stopDiscovery()` 未 await（第 75 行返回 Future 被丢弃），随后立刻 `close()` 控制器。

**[A-8] [P2] `services/in_app_review_service.dart:80-86`｜`dispose()` 不解绑 `bridge.onOutgoingMessage`**

```dart
Future<void> attachToBridge(BridgeService bridge) async { ... bridge.onOutgoingMessage = recordOutgoingMessage; }
void dispose() { _connectionSub?.cancel(); _messageSub?.cancel(); }   // ← 没有 bridge.onOutgoingMessage = null
```
`BridgeService` 是 app 级单例，寿命长于本服务；dispose 后仍会持续回调已销毁的服务并写 prefs。且该字段是单槽赋值，任何其他消费者赋值都会**静默关闭**评价埋点。

**[A-9] [P2] `services/native_paste_bridge.dart:15-31`｜静态单例长期持有 owner State；无 activate 栈**

`_activeTarget` 保存 `(owner, handler)`；owner 未调用 `deactivate` 就销毁则永久泄漏。且 A→B 先后 activate、B 先 deactivate 后，`_activeTarget = null` 且 `_setEnabled(false)`，**A 的粘贴能力被静默摧毁且无法恢复**（无栈式恢复）。

**[A-10] [P2] `providers/machine_manager_cubit.dart:609-616,623-630`｜`close()` 不停周期健康检查**

`startPeriodicHealthCheck()` 由本 cubit 启动，但 `close()` 只 cancel `_machinesSub`，`MachineManagerService._healthCheckTimer` 继续每 30s 全量探测（并叠加 A-1 的隧道泄漏）。且 `_machinesSub?.cancel()` 未 await。

**[A-11] [P2] `services/machine_manager_service.dart:352-354,908-911`｜`dispose()` 后在途 `checkHealth` 会向已关闭的 controller `add`**

`dispose()` 关闭 `_machinesController`，但没有取消在途的 HTTP 探测；每个 `checkHealth` 结尾无条件 `_notifyListeners()` → `_machinesController.add()` → `StateError: Cannot add event after closing`。修复：`_emit` 加 `if (!_machinesController.isClosed)`（同仓 `ServerDiscoveryService._emit` 已经这么做了，此处不一致）。

**[A-12] [P2] `services/revenuecat_service.dart:557-561` vs `563-598`｜dispose 与 initialize 竞态导致「用后即销毁」的 ValueNotifier 被写**

`dispose()` 先 `removeCustomerInfoUpdateListener` 再 `supporterState.dispose()`；但若此时 `_initialize()` 还停在 await 上，它会在**之后**执行第 576 行 `addCustomerInfoUpdateListener(_handleCustomerInfoUpdated)` 重新注册，后续回调 → `_updateState` → 写已 dispose 的 `ValueNotifier` → `FlutterError`。修复：置 `_disposed` 标志，`_initialize` 与 `_updateState` 双重检查。

**[A-13] [P3] `services/performance_probe_extension.dart:43-47`｜`addTimingsCallback(_samples.addAll)` 永不移除，`_samples` 无上界**

60fps 下每小时约 21.6 万个 `FrameTiming` 对象，仅靠手动 `reset()` 释放。仅 `kDebugMode` 生效，故为 P3。建议加环形缓冲上限。

**[A-14] [P3] `services/prompt_history_service.dart:802-804`｜`.first.timeout()` 超时后底层订阅泄漏**

`bridgeService.promptHistorySyncResults.first.timeout(_syncTimeout)`：`Future.timeout` 不会取消 `.first` 建立的订阅，超时后订阅要等到下一条结果才释放。

*已核对无问题*：`WidgetsBindingObserver` 的 add/remove 在 `permission_management_screen`、`session_list_screen`、`conversation_content_sync_service` 中均成对；`MachineManagerService._healthCheckTimer`、`ReplayBridgeService._timers`、`MockBridgeService._timers`、`NotificationApprovalCoordinator`（`_retryTimer` + 两个 sub + `_persistChain`）、`BridgeLatestVersionService`、`UnseenSessionsCubit.close()` 的清理均完整。

---

# B. 并发与竞态

**[B-1] [P1] `providers/machine_manager_cubit.dart` 全文｜长 await 后无 `isClosed` 保护的 emit**

`startBridge`（第 309-361 行，中间 `_waitForOnline` **最长 20 秒**）、`updateBridge`（第 436-501 行，**最长 30 秒**）、`init`、`refreshAll`、`addMachine`、`updateMachine`、`deleteMachine`、`refreshLatestBridgeVersion` 全部形如：

```dart
final status = await _waitForOnline(machineId, timeout: _startHealthTimeout, ...);
emit(state.copyWith(startingMachineId: null, successMessage: 'Bridge Server started'));
```
用户在这 20–30s 内退出连接页 → cubit 已 close → `StateError: Cannot emit new states after calling close`。同仓 `UnseenSessionsCubit:64` 已经用 `if (... && !isClosed)` 做了防护，此处完全缺失。修复：统一 `void _safeEmit(s) { if (!isClosed) emit(s); }`。

**[B-2] [P1] `services/database_service.dart:22-34`｜`database` getter 无 single-flight，可能重复 `openDatabase` 并泄漏句柄**

```dart
if (_initialized) return _database;
try { _database = await _initDatabase(); } catch (e) { ... }
_initialized = true;
```
`_initialized` 只在 await 之后置位。`PromptHistoryService` 在 `syncAll`/`getPrompts`/`_recordCacheUse` 等处高频并发 `await _db`，冷启动时会多次进入 `_initDatabase()`；后写入的 `_database` 覆盖前一个，**前面的 Database 句柄永不关闭**。修复：`Future<Database?>? _initFuture; database => _initFuture ??= _open();`。

**[B-3] [P1] `services/prompt_history_service.dart:563-606`｜`getPrompts` 全表加载 + 每行两次 `jsonDecode`，且分页在 Dart 层做**

```dart
final rows = await db.query('prompt_history_cache');   // 无 LIMIT / 无 WHERE
for (final row in rows) { ... _entryFromCacheRow(row) ... }  // 内部 _decodeClientStats + _decodeSessionStats
final entries = mergeEntriesForDisplay(filtered, sort: sort);
return entries.skip(offset).take(limit).toList();
```
每翻一页都重做一次全表读取 + 2N 次 `jsonDecode` + 全量归并排序，全部在主 isolate 上。数千条 prompt 时滚动会明显卡顿。（同时归入 E 类。）修复：把 `deleted_at IS NULL`、`project_path`、`bridge_id` 下推到 SQL；stats 只在需要 `selfOnly` 过滤时解析；归并结果做缓存。

**[B-4] [P2] `services/machine_manager_service.dart:657-708,741-751`｜`checkAllHealth` 无重入保护 + 每台机器一次 `_notifyListeners`**

`Timer.periodic(30s, (_) => checkAllHealth())` 不等待上一轮完成；`Future.wait` 内每个 `checkHealth` 结束都单独 `_notifyListeners()`，N 台机器 = 每轮 N 次全量 `machinesWithStatus` 重建与流事件。且没有 generation fence：机器被 `deleteMachine` 后，在途 `checkHealth` 会把该 id 重新写回 `_statusCache/_lastChecked/_lastErrors/_versionCache`（第 676、705 行），形成永不回收的幽灵条目。

**[B-5] [P2] `providers/machine_manager_cubit.dart:299-362,426-502`｜`startBridge`/`updateBridge` 无 single-flight，迟到响应覆盖新状态**

`startingMachineId` 只是展示状态，不是互斥量。连点两次 → 两条 SSH 会话 + 两个 20s 轮询；先完成的清空 `startingMachineId`，后完成的再用**过期结果**覆盖 `successMessage`/`error`。

**[B-6] [P2] `services/revenuecat_service.dart:610-637`｜`_updateState` 用 null（非 sentinel）清 `purchasingPackageId`，购买中被 RevenueCat 推送打断**

```dart
void _updateState(info, { ..., String? purchasingPackageId, Object? errorMessage = _copySentinel }) {
  catalogState.value = current.copyWith(
    isRestoring: isRestoring ?? false,       // ← 默认强制 false
    purchasingPackageId: purchasingPackageId, // ← 默认 null，直接清空
```
`errorMessage` 用了 `_copySentinel` 而 `purchasingPackageId`/`isRestoring` 没有。`_handleCustomerInfoUpdated` 是 SDK 侧任意时刻的推送，只要在购买/恢复途中触发，就会把 loading 态清掉，用户可重复点击购买。

**[B-7] [P2] `services/in_app_review_service.dart:240-244`｜`_increment` 读-改-写丢计数**

```dart
final current = _prefs.getInt(key) ?? 0;
await _prefs.setInt(key, current + 1);
```
调用方全部是 `unawaited(_increment(...))`（第 93、108、117 行）。同键短时间多次事件会读到同一 `current`，计数丢失。

**[B-8] [P2] `services/notification_service.dart:73-161`｜`init()` 不可重入**

`_initialized = true` 在多个 await 之后（第 160 行）。`permissionStatus()` 与 `requestPermission()` 都 `await init()`，并发时会**两次** `_plugin.initialize` 和 `createNotificationChannel`，第二次会覆盖 `onDidReceiveNotificationResponse` 回调。修复：memoize `Future<void>? _initFuture`。

**[B-9] [P2] `services/fcm_service.dart:37-72`｜并发 `init()` 使 `getToken()` 误返回 null**

`_initAttempted` 立刻置位但 `_available` 要等到成功才置位。第二个并发调用 `init()` 直接 `return _available`（此时仍为 `false`），`getToken()` 据此 `return null`——**明明初始化会成功却拿不到 token**。修复：memoize `Future<bool>`。

**[B-10] [P2] `services/draft_service.dart:48-64,88-124`｜SharedPreferences 写入全部 fire-and-forget，顺序与失败均不可控**

```dart
void saveDraft(String sessionId, String text) { _cache[...] = text; _prefs.setString('$_prefix$sessionId', text); } // Future 被丢弃
void migrateDraft(String oldId, String newId) { _prefs.setString(new); deleteDraft(oldId); /* → _prefs.remove(old) */ }
```
返回的 Future 全部丢弃：写失败无人知晓（未捕获异步错误），迁移的「写新 + 删旧」无事务性，中途崩溃可能两边都在或都不在。

**[B-11] [P2] `services/app_icon_service.dart:66-92`｜`sync()` 无 single-flight**

并发调用都读到 `_lastAppliedIcon == null`，各自 `getCurrentIcon()` + `setIcon()`。iOS `setAlternateIconName` 会弹系统弹窗，重复调用用户可见；且迟到的 `setIcon` 会把 `_lastAppliedIcon` 写成过期值。

**[B-12] [P2] `services/app_update_service.dart:140-146`｜节流条件写反，无更新时节流完全失效**

```dart
if (elapsed < _checkInterval.inMilliseconds && _cachedUpdate != null) return _cachedUpdate;
```
`_cachedUpdate != null` 是「有可用更新」。绝大多数用户没有更新（`_cachedUpdate == null`），条件不成立 → **1 小时节流形同虚设**，每次调用都打 GitHub API（未认证限流 60/h）。同时 `checkForUpdate` 本身也没有 single-flight。

**[B-13] [P2] `services/notification_action_host.dart:73-118`｜广播流无缓冲，冷启动的通知动作会被丢弃**

`_actions` 是 `.broadcast()` 且无 replay。`initialize()` 在启动早期调用并立刻 `setDartReady`，原生侧可能马上投递排队中的 `approvalAction`，而 `NotificationApprovalCoordinator` 尚未订阅 → 事件被静默丢弃，用户在通知里点了「允许」却毫无反应。同文件的 `NotificationService` 用 `_pendingLaunchResponse` 正确处理了这个问题，此处没有。修复：首个订阅者出现前先缓冲。

**[B-14] [P3] `services/machine_manager_service.dart:847-857`｜`buildWsUrl` 无条件拼接 `?token=`**

当前实现用字符串手工拼接凭据查询参数。`machine.wsUrl` 与隧道 URL 都不带
query 时可以工作，但任何 resolver 一旦返回带 query 的 URL 就会产出两个
问号。建议改用 `Uri.parse(url).replace(queryParameters: {...})`。

*已核对无问题*：`PromptHistoryService.syncBridge`（`_bridgeSyncsInFlight` + `identical` 校验）、`BridgeLatestVersionService`（`_inFlightFetch`）、`AppIconService.isSupported`（`_availabilityFuture`）、`RevenueCatService.initialize`（`_initializeFuture`）、`NotificationApprovalCoordinator._persistChain`、`UnseenSessionsCubit._saveChain` 的 single-flight / 串行化都写得正确。

---

# C. 数据一致性

**[C-1] [P2] `providers/unseen_sessions_cubit.dart:17,188-192`｜未读状态持久化键缺少 Bridge 维度**

```dart
static const _prefsKey = 'unseen_sessions_seen_at';   // 全局唯一，无 bridgeInstanceId
String _stableKey(SessionInfo session) {
  final durableId = session.claudeSessionId?.trim();
  return '$provider:${durableId?.isNotEmpty == true ? durableId : session.id}';  // fallback 用 Bridge 局部 id
}
```
当 `claudeSessionId` 缺失时回退到 `session.id`——这是 Bridge 本地的运行时 id，不同机器之间可能重复。多 Bridge 场景下未读状态会跨机器串号（A 机的会话被 B 机的同名会话标记为已读）。类注释明确声称「a Bridge reconnect that replaces the runtime ID does not erase or misattribute unread state」，但**跨 Bridge 实例这一维度没有覆盖**。修复：`_stableKey` 前缀加 `bridgeInstanceId`，或至少在 fallback 分支加。

**[C-2] [P2] `services/desktop_continuity_backlog.dart:108-122`｜`take()` 只校验 threadId，不校验 bridgeInstanceId**

`_PendingSession` 记录了 `bridgeInstanceId`（第 202 行）却从不用于匹配。切换到另一个 Bridge 实例后，若 sessionId+threadId 碰巧相同，旧 Bridge 的 backlog 会被回放进新会话。修复：`take()` 增加 `expectedBridgeInstanceId` 参数。

**[C-3] [P2] `services/database_service.dart:36-54,159-163`｜无 `onDowngrade`，版本回退后数据库永久不可用且无提示**

```dart
return openDatabase(dbPath, version: _dbVersion, onCreate: _onCreate, onUpgrade: _onUpgrade);  // 没有 onDowngrade
```
sqflite 默认 `onDowngrade` 直接抛异常。用户经 TestFlight / Shorebird 回滚到旧版本后 → `_initDatabase` 抛 → 被 `database` getter 捕获成 `logger.warning('init failed (no-op)')` → `_initialized = true, _database = null` → **整个 Prompt History 功能静默失效，且本次运行内无任何重试与用户提示**。同样适用于数据库文件损坏的情况。修复：`onDowngrade: onDatabaseDowngradeDelete`（或备份后重建），并把失败状态暴露给 UI。

**[C-4] [P2] `services/prompt_history_service.dart:19-20,131,143,1011,1028-1032` + `providers/unseen_sessions_cubit.dart:205-212`｜ISO 时间戳用字符串字典序比较**

```dart
String _maxIso(String left, String right) => left.compareTo(right) >= 0 ? left : right;
```
只有当两端格式与精度完全一致时才正确。本地生成的是 `2026-07-26T10:00:00.000Z`，Bridge 若返回 `2026-07-26T10:00:00Z` 或 `+00:00` 偏移，`'.'(0x2E) < 'Z'(0x5A)`、`'+'(0x2B) < 'Z'`，比较结果与真实时间相反 → `last_used_at`/收藏时间被旧值覆盖。`UnseenSessionsCubit._isAfter` 第 211 行、`_pruneSeenAt` 第 217 行按字符串排序淘汰也是同一问题。修复：统一 `DateTime.parse(...).toUtc()` 后比较。

**[C-5] [P2] `services/prompt_history_service.dart:1047-1093`｜同步时 delete-all + insert，抹掉本地未同步的使用计数**

```dart
for (final id in {bridgeId, ...aliasBridgeIds}) { batch.delete('prompt_history_cache', where: 'bridge_id = ?', whereArgs: [id]); }
for (final entry in entries) { batch.insert(...); }
```
`_recordCacheUse` 在本地累加过的 `total_use_count`、`client_stats_json`、`session_stats_json`，如果 Bridge 尚未处理对应的 `record_prompt_history` 消息，本次同步就会用旧快照整体覆盖。修复：按 `updated_at` 做逐条合并而非整桶替换。

**[C-6] [P2] `services/machine_manager_service.dart:100-207`｜迁移中任一条目类型不符即整批丢弃**

```dart
final host = normalizeHostInput(old['host'] as String);   // 裸 as，null 即 TypeError
final port = old['port'] as int? ?? 8765;                 // 存成 double/String 即 TypeError
```
异常被第 142 行的 `catch` 吞掉并只 `logger.error`，**整个旧机器列表静默丢失**（凭据仍留在 keychain 但已无引用）。URL history 分支第 154 行 `entry['url'] as String` 同理。修复：逐条 try/catch + 跳过坏条目，并保留失败计数上报。

**[C-7] [P3] `services/prompt_history_service.dart:376-386`｜`bridgeUrl!` 空断言**

```dart
if (bridgeService?.isConnected == true && bridgeId != null) {
  ... bridgeUrl: _redactBridgeUrl(bridgeUrl!),
```
`bridgeId` 可以来自 `promptHistoryBridgeId` 而与 `lastUrl` 无关。当前 `_lastUrl` 在连接时必然被赋值所以实际安全，但这是脆弱的隐式契约。

**[C-8] [P3] `services/prompt_history_service.dart:713-720,760-768`｜`int.parse(id.substring(3))` 未防御**

legacy id 形如 `v1_<int>`；若持久化数据被污染成 `v1_abc` 会抛 `FormatException` 并冒泡到 UI 层。

**[C-9] [P3] `services/prompt_history_service.dart:435-442`｜`_pruneSyncStatuses` 会删掉离线机器的同步状态**

`syncAll` 只把 `status == online` 的机器加入 `currentStatusIds`，随后 `_pruneSyncStatuses` 删除不在集合中的行。机器临时离线一次，其历史同步记录（上次同步时间、条目数）就永久消失。

---

# D. 错误处理

**[D-1] [P1] `services/database_service.dart:25-33`｜数据库初始化失败被降级为 warning，无重试无自愈无 UI 反馈**（见 C-3，同时属于 D 类）

**[D-2] [P2] `services/notification_approval_coordinator.dart:262-276,211-260`｜通知审批匹配不到时静默沉默 10 分钟**

`_matchingSession` 在匹配到 0 条或 ≥2 条时返回 `null`（第 275 行 `matches.length == 1 ? ... : null`），`_drain` 只 `continue`，既不重试（除非恰好有流事件）也不告知用户。用户在通知里点了「允许」，最终请求会在 `_maxAge = 10min` 后被静默丢弃，**全程零反馈**。修复：超时或持续歧义时上报一条可见提示。

**[D-3] [P2] `services/in_app_review_service.dart:158-162`｜冷却期先写后用，且 `requestReview` 异常未捕获**

```dart
await _prefs.setInt(_keyLastPromptAt, now.millisecondsSinceEpoch);
await _prefs.setString(_keyLastPromptVersion, version);
await _gateway.requestReview();   // 抛异常则 90 天冷却已白白消耗
```
且该异常会穿过 `maybeRequestReview` → `_handleSuccessfulSessionCompletion` → 第 118 行的 `unawaited(...)`，成为未处理的异步错误。

**[D-4] [P2] `services/notification_service.dart:302-314`｜`!_initialized` 时 `show`/`cancelAll` 静默 no-op**

初始化失败后所有通知彻底消失，日志里只有一条 warning，用户完全无感（会以为通知权限没开）。

**[D-5] [P2] `services/support_banner_service.dart:47-49`｜`dismiss()` 不 `notifyListeners()`**

类继承自 `ChangeNotifier`，`setDebugForceShowOverride` 会通知而 `dismiss()` 不会。依赖该 notifier 的 widget 在用户点「关闭」后不会重建。

**[D-6] [P2] `services/ssh_startup_service.dart:371-396`｜`execute()` 的 Completer 可能被二次完成 + 订阅泄漏**

```dart
session.stdout.listen(output.add, onDone: stdoutDone.complete, onError: stdoutDone.completeError);
session.stderr.listen(output.add, onDone: stderrDone.complete, onError: stderrDone.completeError);
await session.done; await stdoutDone.future; await stderrDone.future;
```
① 若流先 `onError` 再 `onDone`，`Completer` 二次完成抛 `StateError`（在流回调里 → 未处理的 zone 错误）。② `await stdoutDone.future` 抛出后 `stderr` 的订阅永不 cancel。③ 外层 `_executeCommand` 用 `.timeout(_commandTimeout)`，`Future.timeout` 不会取消底层操作，超时后两条订阅与 `BytesBuilder` 继续累积。④ `output` 无大小上限，远端命令输出爆量会直接 OOM。

**[D-7] [P2] `services/chat_message_handler.dart:1036-1059` vs `453-475`｜`stopped` 后不清 `currentThinkingText`，思考文本串到下一轮**

```dart
if (isStopped) { currentStreaming = null; effects.add(ChatSideEffect.clearPlanFeedback); }  // 没有 currentThinkingText = ''
```
用户中断（`ResultMessage(subtype: 'stopped')`）时累积的 thinking delta 被保留，`_handleAssistant` 会把它**注入下一轮的第一条 assistant 消息**（第 455-475 行），显示成属于新问题的思考过程。修复：`isStopped` 分支同时 `currentThinkingText = ''`。

**[D-8] [P2] `providers/unseen_sessions_cubit.dart:39-72,240-244`｜`_loadSeenAt` 只捕获 `FormatException`，`close()` 会重抛**

`SharedPreferences.getInstance()` 的平台通道异常不在 `on FormatException` 覆盖范围内 → `_ready` 以错误完成 → `close()` 里 `await _ready` 抛出 → BlocProvider 销毁失败。修复：`catch (_)` 兜底。

**[D-9] [P3] `services/chat_message_handler.dart:378-379`｜`default` 分支把任何未识别消息塞进聊天记录**

```dart
default: return ChatStateUpdate(entriesToAdd: [ServerChatEntry(msg)]);
```
新增的内部/基础设施类消息（类似已被特判掉的 `ArtifactResolvedMessage`）默认会污染 transcript。建议改为默认 suppress + 白名单显示。

**[D-10] [P3] `services/machine_manager_service.dart:731-737`｜版本探测失败静默降级**

`/version` 失败只 warning 并保留 `_versionCache` 为空，UI 无法区分「未探测」与「不支持」。

---

# E. 性能

**[E-1] [P1] `services/draft_service.dart:19-43`｜构造函数在主 isolate 同步 base64 解码全部图片草稿**

```dart
DraftService(this._prefs) { _loadAll(); }     // main.dart:315 启动路径
// _loadAll → _decodeImageDraftList → base64Decode(...)  逐条同步
```
多个会话各带数 MB 图片时，启动帧直接卡住（Android 上有 ANR 风险）。修复：改为懒加载（首次 `getImageDraft` 时才解码）或 `compute`。

**[E-2] [P1] `services/draft_service.dart:88-101,114-124`｜每次保存图片草稿在主线程 `base64Encode` + `jsonEncode` 全量重编码，并写入 SharedPreferences**

5MB 图片 → 约 6.7MB base64 字符串在 UI 线程构造。且 SharedPreferences / NSUserDefaults 不适合存放 MB 级 blob（Android 每次 commit 重写整个 XML）。修复：图片落盘到应用私有目录，prefs 只存路径。

**[E-3] [P1] `services/prompt_history_service.dart:563-606`｜见 B-3，全表扫描 + 2N 次 jsonDecode + Dart 层分页，每翻页重做一次**

**[E-4] [P2] `services/machine_manager_service.dart:657-708,741-743`｜每台机器一次流事件**

`checkAllHealth` 的 `Future.wait` 中每个 `checkHealth` 单独 `_notifyListeners()`，N 台机器 = N 次全量 `machinesWithStatus` 重建 + N 次 `MachineManagerCubit.emit` + N 次 widget 重建，每 30s 一轮。修复：批量结束后合并成一次通知（可保留 debounce）。

**[E-5] [P2] `providers/unseen_sessions_cubit.dart:74-85`｜每次持久化都在主 isolate `jsonEncode` 最多 1000 条**

`_scheduleSave` 在每次 `persistenceChanged` 时全量 `jsonEncode(Map.of(_seenAt))`；会话列表推送频率高时会反复触发。修复：debounce + 增量。

**[E-6] [P2] `services/app_update_service.dart:298-344`｜主 isolate 上 `jsonDecode` GitHub `releases?per_page=20`**

20 个 release 含全部 assets 的响应可达数百 KB。建议 `compute` 或改用 `releases/latest`。

**[E-7] [P3] `services/prompt_history_service.dart:1272-1274`｜循环内重复编译正则**

```dart
static String _displayMergeKey(String text) => formatCommandText(text).trim().replaceAll(RegExp(r'\s+'), ' ');
```
`mergeEntriesForDisplay` 对每条记录调用一次。提为 `static final _ws = RegExp(r'\s+')`。

**[E-8] [P3] `services/ssh_bridge_tunnel_service.dart:333-344`｜隧道转发无背压**

`localSocket.listen(remoteSocket.sink.add, ...)` 双向直连，没有 pause/resume；大文件传输时数据会无上界堆在内存。

**[E-9] [P3] `services/recording_loader.dart:42-47`｜整文件读入后 `split('\n')`**

大录像文件会一次性占两倍内存；且未处理 CRLF 与结尾空行（下游 `jsonDecode('')` 会抛）。仅调试功能。

---

# F. models / utils（我直接核实的部分）

> models/ 与 utils/ 的完整深挖由另外两路并行审查负责，**其结果尚未返回**。以下只列我在追踪 services 调用链时亲自验证的问题。

**[F-1] [P2] `models/messages.dart:925-950` + `services/chat_message_handler.dart:301-306,478-482,658-663`｜无时区标识的时间戳会被当作本地时间**

```dart
final receivedAt = DateTime.tryParse(json['receivedAt'] as String? ?? '');
```
`DateTime.tryParse` 对不带 `Z`/偏移的 ISO 串返回 **local** DateTime。`chat_message_handler` 随后统一 `.toLocal()`（第 303、481、660 行），对已经是 local 的值是 no-op → 若 Bridge 发的是 naive UTC 串，聊天时间会整体偏移一个时区。修复：解析后强制 `.toUtc()` 需要有明确协议约定，或在 Bridge 侧保证始终带 `Z`。

**[F-2] [P2] `models/messages.dart:959`｜`json['type'] as String` 裸强转**

```dart
final message = switch (json['type'] as String) { ... };
```
缺失或非字符串的 `type` 直接 `TypeError`。在 `services/prompt_history_service.dart:487` 的 `.map((raw) => ServerMessage.fromJson(jsonDecode(raw as String)))` 里，一个畸形帧会让整次同步失败（好在有外层 catch）；在其他没有兜底的解析路径上会更严重。

**[F-3] [P3] `utils/network_endpoint.dart:115-122` vs `109-110`｜IPv6 加括号策略不一致**

`formatHostPort` 显式调 `bracketIpv6Host`，而 `formatUriOrigin` 依赖 `Uri` 内部自动加括号（第 120 行传入的是已被 `normalizeHostInput` 去括号的 host）。两条路径产出目前一致，但对带 zone id 的链路本地地址（`fe80::1%eth0`，`normalizeHostInput` 会把 `%25` 还原成 `%`）行为未定义——`Uri` 的 host 中裸 `%` 不合法。

**[F-4] [P3] `services/connection_url_parser.dart:64-68` vs `69-81`｜端口范围校验只做了 IPv6 分支**

```dart
final hostPortPattern = RegExp(r'^[\w.\-]+:\d+$');
if (hostPortPattern.hasMatch(trimmed)) return ConnectionParams(serverUrl: 'ws://$trimmed');  // 未校验 port ∈ (0,65535]
```
IPv6 分支（第 72-75 行）校验了 `uri.port > 0 && uri.port <= 65535`，普通 host:port 分支没有。`host:99999` 会被接受并传到下游。另：`ccpocket://connect?url=...&token=...` 对目标 host 无任何限制，需确认调用端有用户确认环节，否则是钓鱼向量。

---

# 已检查未见问题（或仅 P3 备注）的文件清单

**services/（36 个文件，`bridge_service.dart` 与 `session_runtime_store.dart` 按要求排除）**

| 文件 | 行数 | 覆盖方式 | 结论 |
|---|---|---|---|
| `codex_goal_request_router.dart` | 198 | 全文 | ✅ 无问题。TTL + `_prune` 有界，`_candidateIndexWhere` 在 `wireSessionId == null` 时要求唯一匹配（第 148 行）避免误路由，设计严谨 |
| `notification_approval_coordinator.dart` | 318 | 全文 | 仅 D-2；`_persistChain` 串行化、`_maxPending`/`_maxAge` 双重上界、`isValid` 长度校验、`dispose` 幂等（`_disposeFuture ??=`）都正确 |
| `bridge_latest_version_service.dart` | 80 | 全文 | ✅ single-flight（`_inFlightFetch` + `identical` 校验）与缓存均正确。P3：`dispose()` 时若有在途请求会抛 `Client is already closed` |
| `replay_bridge_service.dart` | 290 | 全文 | 调试专用。P3：`send()` 未复用 `_isInfrastructureMessage` 过滤，`list_sessions` 会误推进 chunk；`sentMessages` 无上界 |
| `desktop_continuity_backlog.dart` | 288 | 全文 | 仅 C-2；`maxSessions`/`maxItemKeysPerSession`/`maxTransientCharactersPerSession` 三重上界与 `LinkedHashMap` FIFO 淘汰实现正确 |
| `platform_environment_service.dart` | 60 | 全文 | ✅ 无问题，`MissingPluginException`/`PlatformException` 均已分别处理 |
| `bridge_service_base.dart` | 33 | 全文 | ✅ 纯抽象接口 |
| `database_platform.dart` / `_stub.dart` / `_io.dart` | 2/21/50 | 全文 | P3：`getPlatformDatabaseOpenConfig` 每次调用都 `sqfliteFfiInit()` + 目录 I/O（`getDbPath()` 也会触发）；同样缺 `onDowngrade` |
| `server_discovery_impl_stub.dart` | 14 | 全文 | ✅ Web no-op |
| `mock_preview_extension.dart` | 56 | 全文 | ✅ 调试专用，参数校验完整 |
| `recording_loader.dart` | 72 | 全文 | 仅 E-9（调试专用） |
| `mock_bridge_service.dart` | 885 | 关键段 | 调试专用。P3：`loadHistory`（470 行）缺 `isClosed` 守卫（同文件 `_scheduleMessage`:525、`requestFileList`:429 都有），配合 `store_screenshot_extension` 中未加 `mounted` 的 `addPostFrameCallback` 可触发 `Cannot add event after closing`；`_timers` 已触发的 Timer 不回收 |
| `store_screenshot_extension.dart` | 1603 | 关键段 | 全部 `kDebugMode` 门控。P3：第 703/767/1202/1206/1557 行 `addPostFrameCallback` 缺 `mounted` 检查（第 542/939 行有）；`NotificationService.setActiveSession/clearActiveSession` 在 1210/1219 行成对，`draftService` 草稿在 dispose 中已清理 |
| `performance_probe_extension.dart` | 97 | 全文 | 仅 A-13（调试专用） |
| 其余已在正文列出问题的文件 | — | 全文 | `prompt_history_service` / `chat_message_handler` / `ssh_startup_service` / `machine_manager_service` / `ssh_bridge_tunnel_service` / `revenuecat_service` / `notification_service` / `app_update_service` / `in_app_review_service` / `database_service` / `draft_service` / `notification_action_host` / `connection_url_parser` / `app_icon_service` / `server_discovery_service` / `server_discovery_impl_io` / `fcm_service` / `voice_input_service` / `native_paste_bridge` / `support_banner_service` |

**providers/（5 个手写文件，`machine_manager_cubit.freezed.dart` 为生成代码跳过）**

| 文件 | 行数 | 结论 |
|---|---|---|
| `machine_manager_cubit.dart` | 631 | B-1 / B-5 / A-10；另 P3：`refreshLatestBridgeVersion` 先记录尝试时间再请求，失败也消耗 15 分钟节流；`waitUntilLoaded` 的 `firstWhere().timeout()` 超时后订阅泄漏 |
| `unseen_sessions_cubit.dart` | 245 | C-1 / C-4 / E-5 / D-8；其余（`isClosed` 守卫、`_saveChain` 串行、`_pruneSeenAt`/`_prunePendingInitialSeen` 双重上界、`close()` 先 `await _ready`/`_saveChain`）实现正确，是本次审查中质量最高的文件之一 |
| `stream_cubit.dart` | 19 | **P2**：`stream.listen(emit)` 未包 `isClosed` 守卫，`close()` 中 `_sub?.cancel()` 未 await 即调 `super.close()`。对 `StreamController.broadcast` 源当前安全，但对经过异步变换（`asyncMap` 等）的流存在 emit-after-close 风险；且与 `UnseenSessionsCubit` 的防护风格不一致。被 6 个 cubit typedef 复用，建议统一加固 |
| `bridge_cubits.dart` | 28 | ✅ 纯 typedef / 空壳子类 |
| `server_discovery_cubit.dart` | 24 | P3：构造函数中 `_service.startDiscovery()` fire-and-forget；`close()` 中 `_sub?.cancel()` 未 await 即 `_service.dispose()`；`listen(emit)` 同样缺 `isClosed` 守卫 |

**未覆盖**：`models/`（14,001 行）与 `utils/`（3,248 行）的系统性深挖交由两路并行子代理执行，截至本报告完成时尚未返回结果。本报告 F 节仅包含我在追踪 services 调用链时亲自验证的 4 条。

---

## 建议的修复优先级

1. **A-1 / A-2 / A-3**（SSH 隧道三连：泄漏 + 逃逸 + 无自愈）——影响 jump host 用户的可用性与设备资源，且三者相互放大。
2. **B-1**（`MachineManagerCubit` 全量 emit-after-close）——20–30 秒窗口内退出页面即崩，修复成本极低（加一个 `_safeEmit`）。
3. **A-4**（语音输入永久卡死）与 **B-13**（冷启动通知动作丢失）——功能性静默失效，用户无法自行恢复。
4. **B-2 / C-3**（数据库 single-flight + `onDowngrade`）——影响 Prompt History 整体可用性。
5. **E-1 / E-2**（图片草稿的启动期与保存期主线程编解码）——启动卡顿/ANR。
6. **C-1**（未读状态缺 Bridge 维度）——多机用户的数据串号。
