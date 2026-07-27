I'll start by exploring the target files to understand the codebase structure.
Now let me continue reading the file transfer service.
Now let me read the HTTP transport and chunk sizer.
已完成审查（只读，未修改任何文件）。gallery / message_images / generated_image_preview 部分由并行的只读子代理精读后合并进来。以下按 C / D 分组。

---

# C. 传输状态机（客户端侧）

## C-1 [P0] 暂停中的传输一旦取消失败，就永远无法再取消
`/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/apps/mobile/lib/features/file_transfer/file_transfer_service.dart:662-668`

```dart
final paused = _pausedWork;
if (paused?.id != id) return;
final request = paused!.cancelRequest ??= _requestBridgeCancel(paused);
await request;          // 抛出后，cancelRequest 保留着这个"已失败"的 Future
paused.cancelled = true;
```
**触发场景**：暂停的传输点"取消"时 Bridge 恰好断线 / `cancel_busy` / 15s 超时（`_requestBridgeCancel:1687`）。`??=` 之后 `cancelRequest` 被永久钉在一个 rejected Future 上，之后每次点取消都立刻 rethrow 同一个旧错误，checkpoint 与 `.part` 永远留在盘上。
**证据**：对照 `_drain` 的 catch 分支 `file_transfer_service.dart:965-982` 是有复位的 —— `catch (cancelError) { work.cancelRequest = null; ... }`，`cancelTransfer` 的 paused 分支漏了这一句。
**建议**：paused 分支用 `try/catch` 包裹 `await request`，失败时 `paused.cancelRequest = null` 后 rethrow；两条路径抽同一个 helper。

## C-2 [P0] 单个 paused 任务会锁死整个队列，"开始 N 个待接收文件"按钮静默失效
`file_transfer_service.dart:917-941`（`_drain`）、`:477`、`:2252-2261`（`_scheduleRecovery`）

```dart
if (work == null) {
  if (completedOnly || _pausedWork != null) {
    break;                       // ← 只要有 1 个 paused，receive/upload 队列全部不动
  } else if (_receiveQueue.isNotEmpty) { ... }
```
`_scheduleRecovery` 也有 `_pausedWork != null` 直接 return（`:2256`），`startQueuedTransfers()` → `_drainAndScheduleRecovery()` → `_drain()` 立刻 break。
**触发场景**：自动续传关闭 + 某个任务因 `insufficient_storage` / `step_up_required` 暂停 → UI 显示"开始 N 个待接收文件"（`file_transfer_sheet.dart:118-125`），点击后什么都不发生，也没有任何错误提示。
**连锁**：`enqueueDroppedFile` 用的是 `rejectIfBusy: uploadMutationAuthRequired`（`:503`），即无需鉴权时**允许**在 busy 时入队；拖入的文件会永久排在 paused 任务后面 →聊天附件卡在 `uploading` → `sendMessage` 被 `waitForUploads` 挡死（`chat_input_with_overlays.dart:694-698`）。
**建议**：paused 只应阻塞"该条目自身"，不应阻塞队列调度；把 `_pausedWork` 改成 `Map<id, work>` 的旁路集合，`_drain` 跳过它继续取下一条。

## C-3 [P1] `_uploadCompletions` 泄漏 → 上传 ticket 永不 resolve
`file_transfer_service.dart:600-602`、`:2282-2319`、`:2614-2633`

completer 只在 `_remember()` 里、且只有 record 落到 succeeded/failed/paused/cancelled 时才 complete。但 `_recover()` 里有多条**直接丢弃 checkpoint 而不产生任何 record** 的路径：
```dart
if (checkpoint.expiresAt.isBefore(_clock().toUtc())) {
  await _storage.deleteUpload(checkpoint, deleteStaged: true);
  continue;                                   // :2284-2291
}
...
if (secret == null || secret.logicalBridgeIdentity != identity) {
  await _storage.deleteUpload(checkpoint, deleteStaged: true);
  continue;                                   // :2308-2313
}
```
**触发场景**：Keychain 读到旧身份 / 过期。`_uploadCompletions[localId]` 既不 complete 也不 remove → Map 单调增长；调用方 `awaitDroppedUpload`（`chat_input_with_overlays.dart:604-636`）和 `_showHomeTransferResult`（`session_list_screen.dart:875-902`）永久挂起，聊天附件永远停在 `uploading`。
**建议**：`deleteUpload` 的每条 continue 前先 `_failUploadCompletions` 对应 localId；或给 ticket 加超时 / 队列态回调。

## C-4 [P1] 不可恢复失败不清理 checkpoint → 每次重连无限重试同一个坏任务
`file_transfer_service.dart:1024-1037`

```dart
} else {
  _remember(_recordForWork(work, FileTransferStatus.failed, ...));
  if (work is _ReceiveWork) {
    _knownReceiveIds.remove(work.checkpoint.transferId);   // ← 只清内存去重
  }
  _chunkSizers.remove(work.id);
}                                                          // 没有 _cleanupWork()
```
**触发场景**：`download_identity_mismatch`、`commit_tombstone_mismatch`（用户在"文件"App 里删掉了已落地的文件）、`invalid_transfer_url` 等。checkpoint JSON + `.part` 留在盘上 7 天，`_recover()`（`:2328-2412`）每次重连都会重新扫出来重跑一遍并再次失败，`recentResults` 被同一条失败刷屏。
**建议**：非 recoverable 失败时调用 `_cleanupWork(work)`，或给 checkpoint 加 `failedPermanently` 标记让 `_recover` 跳过并回收。

## C-5 [P1] 上传完全没有分块级重试；下载重试退避过短
`file_transfer_service.dart:1741-1795` vs `:1956-2015`

下载有 `_downloadChunkWithRetry` / `_headDownloadWithRetry`（3 次），上传 `_runUpload` 里 `_http.uploadChunk` 是**裸调用**，一次瞬时 socket 抖动就整条 pause，走"重新 prepare → 重新 headUpload → 重新协商 offset"的重代价路径。
下载的退避也极短：
```dart
Future<void> _retryDelay(int attempt) {
  final jitter = Random.secure().nextInt(150);
  return Future<void>.delayed(Duration(milliseconds: 150 * (attempt + 1) + jitter));
}   // :1790-1795  → 最大约 450ms，3 次总计 <1.2s
```
弱网下 3 次 450ms 内的重试几乎必然全部失败。
**建议**：为 `uploadChunk` 加同构的 `_uploadChunkWithRetry`；退避改为指数（如 0.5/2/8s + jitter），与 `_scheduleCompletionRecoveryRetry`（`:1064-1090`，那里是正确的指数退避）保持一致。

## C-6 [P1] 跨机器的临时文件永不回收（`.part` / `.stage` / scope 目录无限增长）
`file_transfer_storage.dart:920-946`、`file_transfer_service.dart:2266-2429`

存储按 `v2/<sha256(logicalIdentity)>/{receive,upload}/` 分目录，但 `_recover()` 只扫**当前连接的那一个** `identity`（`:2270 final identity = _stableIdentity ?? ''`）。
```dart
Future<Directory> _scopeRoot(String bridgeKey) async {
  ... path.join(support.path, 'CCPocketFileTransfers', 'v2', _safeId(bridgeKey))
```
**触发场景**：用户换 Mac / 重装 Bridge 导致 logicalIdentity 变化后，旧 scope 下的 `.part`（最大 15 GiB）、`.stage`、checkpoint JSON **永远没有任何代码会再扫到**，7 天过期逻辑也扫不到。全仓库 grep 确认没有任何遍历 `v2/*` 的 GC。
**建议**：`initialize()` 增加一次全局扫描 `v2/` 下所有 scope 目录，按 `expiresAt`/mtime 删除过期项并删空目录（沿用 `_deleteTreeNoFollow`）。

## C-7 [P2] 过期的"待确认完成"任务被静默丢弃，transferId 却留在 `_knownReceiveIds` → Mac 永远收不到 ACK
`file_transfer_service.dart:924-929` + `:763`

```dart
while (_completionRecoveryQueue.isNotEmpty && work == null) {
  final candidate = _completionRecoveryQueue.removeFirst();
  if (candidate.checkpoint.expiresAt.isAfter(_clock().toUtc())) {
    work = candidate;
  }                                  // 过期 → 直接丢弃，什么都不做
}
```
丢弃时既不发 `_sendReceiveResult`，也不 `_knownReceiveIds.remove()`（该 id 在 `:810` / `:2371` 被加入）。之后 `_handleOffer` 的 `if (_knownReceiveIds.contains(offer.transferId)) return;`（`:763`）会**静默吞掉**同 id 的重发 offer，Mac 端一直挂在等待确认状态。
**建议**：丢弃分支里补 `_knownReceiveIds.remove(...)` + `_completionRecoveryAttempts.remove(...)` + 尝试 `deleteReceive`。

## C-8 [P2] ACK 重试用尽后 checkpoint 永久跳过，成为孤儿
`file_transfer_service.dart:2340-2345`、`:999-1006`

```dart
if (checkpoint.commitState == 'complete' &&
    (_completedReceives.containsKey(checkpoint.transferId) ||
        (_completionRecoveryAttempts[checkpoint.transferId] ?? 0) >=
            completionRecoveryRetryLimit)) {
  continue;                          // 5 次之后永远跳过
}
```
只有 `_resetCompletionRecoveryRetryRound(reopenExhausted: true)`（仅在 capability 由无→有时触发，`:2136-2138`）或 7 天过期能解锁。期间 `notificationPending` 的本地通知也永远发不出去。
**建议**：把重试计数持久化到 checkpoint，或按连接 epoch 重置而非仅按 capability 变化重置。

## C-9 [P2] 续租后重试仍使用旧的 secret / URL
`file_transfer_service.dart:1727-1734`、`:1776-1783`

```dart
if (leaseExpired) {
  await _renewDownloadLease(checkpoint, secret, cancellation, operationGeneration);
}                                    // ← 返回的 refreshedSecret 被丢弃
await _retryDelay(attempt);
```
下一轮循环仍用外层捕获的旧 `secret` 和旧 `url` 重发。当前因为 `downloadToken` 恒定、URL 从同一 `httpBaseUrl` 重建而侥幸能工作；一旦重连后 origin 变化（Tailscale ↔ LAN ↔ SSH 隧道切换，代码注释 `:1612-1616` 明确承认这会发生），重试就会持续打到旧 origin 直到 3 次耗尽。
**建议**：`secret = await _renewDownloadLease(...)` 并同步重建 `url`，`work.secret` 一并更新。

## C-10 [P2] `.tmp` 孤儿文件永不清理
`file_transfer_storage.dart:1121-1139`

`_atomicJson` 写 `${destination.path}.$suffix.tmp` 再 rename，`finally` 里删除；但进程被系统 kill / 断电时 `.tmp` 会留下。`_loadJsonFiles`（`:986-989`）和容量计数（`:900-912`）都只看 `.json`，所以这些 `.tmp` **永远不会被扫到也不会被删**。
**建议**：`_receiveDirectory` / `_uploadDirectory` 首次创建后清一次 `*.tmp`。

## C-11 [P2] `cleanupPickerOrphans()` 会删掉正在写入的暂存目录
`file_transfer_storage.dart:571-580`

```dart
await for (final entity in pickerRoot.list(followLinks: false)) {
  if (!_isOwnedPickerDirectoryName(path.basename(entity.path))) continue;
  await _deleteOwnedPickerDirectory(pickerRoot: pickerRoot, candidate: Directory(entity.path));
}
```
无条件删除所有 `ccpocket-picker-*`，不区分是否在用。`initialize()` 在首帧后异步执行（`main.dart:519`），若此时用户已经拖入文件开始 `stageExternalFile`（`:434-457`），正在写的 `copy.tmp` 会被删掉。
**建议**：加内存中的"在用集合"，或只删 mtime 早于本次进程启动时刻的目录。

## C-12 [P2] cancel 与 resume 竞态：`continuePaused` 丢掉取消状态
`file_transfer_service.dart:630-643`

```dart
if (work case _ReceiveWork(:final checkpoint, :final secret)) {
  work.renewLease = true;
  _enqueueReceive(_ReceiveWork(checkpoint, secret, renewLease: true), first: true);
}
```
新建了 `_ReceiveWork`，旧对象上的 `cancelRequest` / `cancelled` 全部丢失。用户先点"取消"（Bridge 侧已受理）再点"继续"，客户端会重新开始下载，随后 404 失败。
**建议**：`continuePaused` 开头检查 `work.cancelled || work.cancelRequest != null` 则直接 return。

## C-13 [P2] 单并发 + 严格优先级 → 上传被接收饿死
`file_transfer_service.dart:930-939`

`_drain` 是单飞（`_processing`），每轮固定顺序 `completionRecovery > receiveQueue > uploadRecoveryQueue`。Mac 持续推送文件时，`_receiveQueue` 永远非空，用户自己发起的上传永远排不上。
**建议**：接收/上传各留一个配额，或改为按入队时间的公平轮转。

## C-14 [P3] 自动续传对"需要鉴权的上传"永远无效
`file_transfer_service.dart:2236-2248` 调用的是无参 `continuePaused()`，而 `_authorizeUploadMutation`（`:2568-2587`）在 `authorizeMutation == null` 时直接抛 `mutation_auth_required`，错误被 `_launch` 的 `catchError` 静默吞掉（`:2532-2534`）。每次重连都重复失败一次且无任何 UI 反馈。
**建议**：`_resumePausedIfReady` 对 `uploadMutationAuthRequired` 的 upload 跳过自动恢复，并在 UI 上明确提示"需要手动继续"。

## C-15 [P3] 进度语义不准 + 回退
- 上传进度统计的是**从本地文件读出并推入 request sink 的字节**，不是服务端确认字节：`file_transfer_http.dart:302-313` 的 `onProgress?.call(offset + sent)`。
- 分块失败后 `downloadChunk` 的 finally 会 `truncate(offset)`（`file_transfer_http.dart:205-212`），UI 上进度会从 `offset+written` 明显回跳到 `offset`。
- 拖拽入口的 `stageExternalFile` 阶段（可能是 15 GiB 的完整落盘拷贝）**完全没有进度**，UI 只有一个 spinner（`session_list_screen.dart:845-873`）。
- `_progress` 在每个 socket chunk 都会构造 `checkpoint.copyWith()` + `FileTransferRecord`（`:1229-1234`、`:1982-1987`），即使被 100ms 节流丢弃也照样分配。
**建议**：上传进度改用服务端返回的 `upload-offset`；节流判断前置到构造对象之前；给 staging 阶段加字节回调。

## C-16 [P3] `FileTransferCancellation` 的监听器随分块数线性累积
`file_transfer_http.dart:455-468`、`file_transfer_service.dart:1797-1806`

每次 `downloadChunk` / `uploadChunk` / `_sendNoBody` / `_waitWithCancellation` 都往同一个 work 级 cancellation 的 `_cancelled.future` 上挂一个 `.then`，且无法移除。15 GiB / 1 MiB 最小分块 ≈ 15000 个常驻闭包（每个还捕获一个 `abort` Completer）。
**建议**：改为可注销的监听（`onCancel` 回调列表 + 返回 remove 句柄），或每个分块用子 cancellation。

## C-17 [P3] `authoritativeOffset` 采集了却从未使用
`file_transfer_http.dart:53`、`:322-337` 把服务端权威 offset 塞进异常，但全仓库无任何读取点。`upload_offset_mismatch` 被判为 recoverable（`:2828`）后走完整 re-prepare，白白浪费了这个可直接续传的信息。

## C-18 [P3] `cancelTransfer` 清理抛异常会让任务从 UI 消失但残留在盘上
`file_transfer_service.dart:666-670`：`_pausedWork = null` 已执行，若 `await _cleanupWork(paused)` 抛出（`_deleteRegularFileIfExists` 的 `unsafe_cleanup_target`、Keychain 失败），后面的 `_remember(cancelled)` / `_notify` 都不会执行。

---

# D. 常规 bug

## D-1 [P0] `_ImageGenerationResultCard` 在 build 里解 base64 且不传缓存 → 每帧重解码 + ImageCache 爆掉
`/Users/huyiyang/.../apps/mobile/lib/widgets/bubbles/tool_result_bubble.dart:298-300`
```dart
final items = generatedImageItemsFromToolResults([message], httpBaseUrl: httpBaseUrl);
```
对比正确写法 `lib/features/chat_session/widgets/chat_message_list.dart:781-785` 传了 `itemCache: _generatedImageItemCache`。
`MemoryImage` 的 `==` 按 `bytes` 引用比较，每次 build 产出新 `Uint8List` ⇒ 新的 ImageCache key ⇒ 完整重解码并新增一份位图（1024² RGBA = 4 MB，2048² = 16 MB）。ImageCache 上限全仓库未调整（默认 100 MiB / 1000 项，已 grep 确认无 `maximumSizeBytes`）。
**建议**：改 StatefulWidget 持有缓存 Map 传入 `itemCache`，或把 items 计算移出 build。

## D-2 [P1] `image_preview.dart` 把 httpBaseUrl 拼在 data URL 前面，data 图必然显示破图
`lib/widgets/bubbles/image_preview.dart:58-59`、`:120-121`、`:168-169`
```dart
final url = '$httpBaseUrl${image.url}';
final dataBytes = _decodeDataImageUrl(url);   // 内部判 url.startsWith('data:image/')
```
拼完变成 `http://host:8080data:image/png;base64,...`，`_decodeDataImageUrl` 永远返回 null，一律走 `ExtendedImage.network` 失败。正确写法见 `lib/features/generated_image_preview/generated_image_preview_mapper.dart:105-113` 的 `_resolveImageUrl`。同源问题在 `lib/features/message_images/message_images_screen.dart:167` 和 `:251`。
**建议**：抽公共 `_resolveImageUrl` 到 util，三处统一调用。

## D-3 [P1] BuildContext 跨 await 使用（具体行号）
1. `lib/features/file_transfer/file_transfer_sheet.dart:176-179`
```dart
await service.uploadToMac(
  authorizeMutation: (operation) => requestFileMutationAuthorization(context, operation),
);
```
该闭包在 service 内部经过 `_markTransientStorage` → `_picker.pickFile()`（iOS 文档选择器，用户交互可长达数十秒）→ `_storage.adoptPickerCopy()` 之后才被调用（`file_transfer_service.dart:484-592`）。期间底部 sheet 可被用户下滑关闭，此时 `requestFileMutationAuthorization` 内的 `context.read<FileBrowserService>()`（`lib/features/file_browser/file_mutation_authorization.dart:16`）和 `_FileMutationAuthCopy.of(context)`（`:22`）会在已失效的 Element 上抛异常。**闭包内无任何 `context.mounted` 检查。**
2. `lib/features/file_transfer/file_transfer_sheet.dart:470-472` — `continuePaused` 同样问题，且恢复时机更晚（可能在重连事件里）。
3. `lib/features/chat_session/widgets/chat_input_with_overlays.dart:669-671` — `enqueueDroppedFile` 的 `authorizeMutation` 闭包同上。
4. `lib/features/session_list/session_list_screen.dart:860-861` — 同上。
**建议**：闭包首行加 `if (!context.mounted) return null;`；更稳妥的是在调用前把 `FileBrowserService` 与本地化文案取出，闭包只捕获这些值 + 一个 `NavigatorState`/`ScaffoldMessengerState`。
> 复核：gallery / message_images / generated_image_preview 三个目录内**未发现**真正的跨 await 违规，`gallery_content.dart:73,77` 与 `gallery_image_viewer.dart:72,76,108,127` 都有 `context.mounted` 守卫。

## D-4 [P1] 主 isolate 上的大体积 base64 / 图片解码
| 位置 | 问题 |
|---|---|
| `lib/features/generated_image_preview/generated_image_preview_mapper.dart:115-125` | 同步 `base64Decode`；`url.substring(...)` 额外复制一份 ~4/3 大小的 String，瞬时三份内存 |
| `lib/widgets/bubbles/assistant_bubble.dart:485` 和 `:745` | `Image.memory(uri.data!.contentAsBytes())` 写在 **build 内**，每次 rebuild 重新解 base64 并生成新 Uint8List ⇒ ImageCache key 失效 ⇒ 全量重解码 |
| `lib/features/chat_session/state/chat_session_cubit.dart:3547` | `images.map((i) => {'base64': base64Encode(i.bytes), ...})` 同步编码最多 5 张 2048² 图 ⇒ 约 20 MB String，发送消息瞬间掉帧 |
| `lib/services/draft_service.dart:98-101`、`:118-121` | `saveImageDraft` / `migrateImageDraft` 是 **void 同步方法**，内部 `base64Encode` + `jsonEncode` 全部在帧内执行；由 `pickImageFromGallery`（`chat_input_with_overlays.dart:828`）直接调用 |

**建议**：全部改走 `compute()`；`base64.decoder.convert(url, start)` 可省掉 substring 副本；`contentAsBytes()` 结果记忆化到 State 字段。

## D-5 [P1] 全仓库没有任何 `cacheWidth/cacheHeight/maxBytes`，ImageCache 上限也未调整
grep 确认 `cacheWidth|cacheHeight|maximumSizeBytes` 在 `lib/` 下 **零命中**。受影响的展示点：
- `lib/features/gallery/widgets/gallery_tile.dart:45-64`（2 列网格，iPhone 截图 1290×2796 → 解码后约 14.4 MB/张）
- `lib/features/gallery/widgets/gallery_image_viewer.dart:295-318`
- `lib/features/message_images/message_images_screen.dart:282-286`
- `lib/features/generated_image_preview/widgets/generated_image_chat_group.dart:262-267`（最小 4 列约 80px 宽却按原图解码）
- `lib/features/generated_image_preview/widgets/generated_image_preview_page.dart:181-187`
- `lib/widgets/bubbles/image_preview.dart:68`、`:127`（150px 高缩略图全量解码）
- `lib/widgets/bubbles/user_bubble.dart:173-177`（`width: 120` 但无 cacheWidth）

注意 `ExtendedImage.network` 的 `cache: true` 只是**磁盘字节缓存**，与解码分辨率无关；`extended_image 10.0.1` 是支持 `cacheWidth/cacheHeight/maxBytes` 的。
**加剧因素**：`lib/features/generated_image_preview/generated_image_preview_screen.dart:138` 的 `allowImplicitScrolling: true` 让 PageView 常驻左右各一页 → 任意时刻至少 3 张原图位图同时驻留。
**建议**：网格/缩略图加 `cacheWidth: (tileWidth * dpr).round()`；在 `main.dart:117` 之后设置 `PaintingBinding.instance.imageCache..maximumSizeBytes = 64 << 20 ..maximumSize = 120`；全屏页配 `clearMemoryCacheWhenDispose: true`。

## D-6 [P2] `CurvedAnimation` 每次动画都新建且从不 dispose，status listener 无限累积
- `lib/features/gallery/widgets/gallery_image_viewer.dart:277-281`
- `lib/features/generated_image_preview/widgets/generated_image_preview_page.dart:78-88`（`_animateTo` 被 `_handleDoubleTap` 和 `_handleInteractionEnd:124` 两处调用，每次拖拽结束都触发）

`CurvedAnimation` 构造时会 `parent.addStatusListener(_updateCurveDirection)`，只有显式 `dispose()` 才移除。反复双击缩放/滑动切图会让 controller 的 listener 链线性增长，每帧都要遍历这些失效 listener。
**建议**：提为 `late final` 字段复用，或创建新的之前 dispose 旧的，并在 `State.dispose()` 中释放。
> 复核：其余资源释放是干净的 —— `message_images_screen.dart:42/51/104` 的 StreamSubscription、`gallery_image_viewer.dart:246-250` 的 AnimationController + TransformationController、`generated_image_preview_page.dart:48-53`、`generated_image_preview_screen.dart:55-58`、`providers/stream_cubit.dart:15-18` 均正确 cancel/dispose。`FileTransferService.dispose()`（`:2653-2669`）也正确取消了 3 个订阅并关闭 http client。

## D-7 [P2] 整文件读入内存
1. `lib/features/gallery/widgets/gallery_image_viewer.dart:100-136` 分享路径：`http.get(...)` 后用 `response.bodyBytes` 一次性把整图读进内存（无大小上限）；`finally` 里 `tempFile?.delete().ignore()` 在 share 返回后立即删，Android 接收方可能仍在延迟读该 URI；`catch (_)` 吞掉全部异常无日志。
2. `lib/features/chat_session/widgets/chat_input_with_overlays.dart:817` `await file.readAsBytes()` 循环读最多 5 张图。
3. `lib/services/draft_service.dart:13` `_imageCache` 持有全部会话的解码后字节，除显式 delete 外**无淘汰**，长会话下无限增长。
> 反例（正确的）：文件传输链路全程流式 —— `file_transfer_http.dart:172-181` 下载写 sink、`:303-315` 上传 `openRead(offset, offset+len)`、`file_transfer_storage.dart:441-450` staging 用 `RandomAccessFile.writeFrom`；`_readInlineDroppedImage`（`chat_input_with_overlays.dart:1309-1326`）有 20 MB 硬上限，可接受。

## D-8 [P2] 列表 key 缺失 / 非懒加载列表
- `lib/features/gallery/widgets/gallery_content.dart:114-123`：`GridView.builder` 的 `GalleryTile` 无 key（`gallery_tile.dart:31` 的 ValueKey 挂在内部 GestureDetector 上，对 Sliver element 复用无效）。删图或切换项目筛选导致列表位移时，`ExtendedImage` 内部 State 会错位。建议 `key: ValueKey(image.id)`。
  - 另：`gallery_tile.dart:38-39` 的 `Hero(tag: 'gallery_${image.id}')` 在 `GalleryImageViewer` 中无对应目标 Hero，属无效开销；同 id 同时出现在两棵子树时会触发 "multiple heroes share the same tag" 断言。
- `lib/features/message_images/message_images_screen.dart:246-264`：`ListView.separated` 的 item 无 key、无 cacheWidth。
- `lib/features/file_transfer/file_transfer_sheet.dart:97-163`：用的是非懒加载的 `ListView(children: [...])`，`service.receivedFiles` 最多 200 条（`fileTransferReceivedFileListLimit`）会被**一次性全部构建**。建议换 `ListView.builder`。

## D-9 [P2] Gallery 数据源回退会展示上一个会话的图
`lib/features/gallery/gallery_screen.dart:49-51`
```dart
final images = context.watch<GalleryCubit>().state.isNotEmpty
    ? context.watch<GalleryCubit>().state
    : bridge.galleryImages;      // 全局最后一次 gallery 列表
```
`requestGallery` 发出后、响应到达前的窗口内会显示上一个会话/项目的图片，标题计数也是错的。建议用 `null` 表示"未加载"，请求前先清空。

## D-10 [P3] 其他
- `file_transfer_service.dart:2648-2651`：`_notify({bool force = false})` 完全忽略 `force` 参数（全文 30+ 处传 `force: true` 都是空转），是误导性死参数。
- `lib/features/generated_image_preview/generated_image_preview_mapper.dart:47-52`：缓存是 FIFO 不是 LRU，容量硬编码 64；超过 64 张生成图后命中率骤降，退化成 D-1 的重复解码。`cacheKey`(`:33`) 还包含整段 `message.content`，哈希代价与内容长度成正比。
- `lib/features/generated_image_preview/widgets/generated_image_chat_group.dart:170-174`：`didChangeDependencies` 无条件 `_resolveAspectRatio()` 触发完整解码，即使 `initState` 已通过廉价的 `_pngAspectRatio()`(`:239-250`) 拿到宽高比；主题/键盘/MediaQuery 变化都会重来一遍。建议 `if (_aspectRatio != null) return;` 前置短路。
- `lib/features/gallery/widgets/gallery_image_viewer.dart:36`、`:86-90`：删除后只改 hook 的 `currentPage`，没有 `pageController.jumpToPage`；`imageList` 是 `images` 的一次性快照，外部新增/删除不会反映到打开中的查看器。
- `lib/features/message_images/message_images_screen.dart:165` `final imageList = images!;` 依赖隐式状态契约；`onError`(`:83`) 只处理 `TimeoutException`，其他异常把 `'$err'` 原样拼进 UI。

---

### 优先修复建议（按投入产出）
1. **C-2 + C-3**（队列锁死 + ticket 泄漏）：这两条组合起来会让拖拽上传的聊天附件永久卡在 "uploading" 并阻断发送，是最容易被用户命中的可见故障。
2. **C-1**（取消按钮永久失效）与 **C-6**（跨机器 15 GiB 级文件永不回收）。
3. **D-1 + D-5**（重复解码 + 无 cacheWidth + ImageCache 未限制）：中低端设备 OOM 的直接原因，改动量很小。
4. **D-2**（data URL 拼接 bug）：3 行修复，消除一类必现破图。
