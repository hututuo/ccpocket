I'll start by finding all the Dart files in those directories.
已全文精读三个目录下全部 14 个 .dart 文件，并追踪了它们引用的 `generated_image_preview_mapper.dart`、`bridge_service.dart`(gallery/messageImages 部分)、`stream_cubit.dart`、`bridge_cubits.dart`、`models/messages.dart`、`widgets/bubbles/image_preview.dart`、`widgets/bubbles/tool_result_bubble.dart`、`features/chat_session/widgets/chat_message_list.dart`，以及 `extended_image 10.0.1` 的实际 API 签名。

以下用 `<lib>` 代表 `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/apps/mobile/lib`（下面每条都写完整绝对路径）。

---

## P0

### 1. [P0] `<lib>/widgets/bubbles/tool_result_bubble.dart:298-300`
**问题**：`_ImageGenerationResultCard.build()` 里在 **build 方法内**调用 `generatedImageItemsFromToolResults`，且**没有传 `itemCache`**。该函数对 `data:image/...;base64,` URL 会走 `base64Decode`（主 isolate），并且每次 build 都产生**全新的 `Uint8List` 实例**。

**证据**：
```dart
// tool_result_bubble.dart:298
    final items = generatedImageItemsFromToolResults([
      message,
    ], httpBaseUrl: httpBaseUrl);
```
对比 `<lib>/features/chat_session/widgets/chat_message_list.dart:781-785`（这条路径是对的，传了缓存）：
```dart
      final items = generatedImageItemsFromToolResults(
        group.messages,
        httpBaseUrl: widget.httpBaseUrl,
        itemCache: _generatedImageItemCache,
      );
```
下游 `<lib>/features/generated_image_preview/widgets/generated_image_chat_group.dart:262-267` 用 `Image.memory(bytes)`；`MemoryImage` 的 `==` 是按 `bytes` **引用**比较，新 `Uint8List` ⇒ **新的 ImageCache key** ⇒ 每次 rebuild 都重新完整解码一张生成图并在 `ImageCache` 里多占一份位图。

**触发场景**：聊天列表里存在 ImageGeneration 结果卡片，流式输出 / 滚动 / 主题变化触发 bubble rebuild。一张 1024×1024 RGBA = 4 MB，2048×2048 = 16 MB；ImageCache 默认上限 100 MiB 且未调整（全仓库无 `PaintingBinding.instance.imageCache.maximumSizeBytes` 设置，已 grep 确认），几十次 rebuild 就能把缓存塞满并触发中低端 Android OOM，同时每次 rebuild 主 isolate 上同步 `base64Decode` + 解码 ⇒ 明显掉帧。

**建议**：给 `_ImageGenerationResultCard` 改为 `StatefulWidget` 并持有一个 `Map<GeneratedImageItemCacheKey, GeneratedImagePreviewItem>` 传给 `itemCache`（与 `chat_message_list` 一致）；或把 `items` 计算上提到 build 之外/`didUpdateWidget` 中。根本修法是让 base64 解码结果按 `id` 记忆化，保证同一张图始终复用同一个 `Uint8List`。

---

## P1

### 2. [P1] `<lib>/features/generated_image_preview/generated_image_preview_mapper.dart:115-125`（配合 :64、:17-56）
**问题**：base64 解码在主 isolate 同步执行，且被 build 路径调用。

**证据**：
```dart
// generated_image_preview_mapper.dart:115
Uint8List? _decodeDataImageUrl(String url) {
  if (!url.startsWith('data:image/')) return null;
  const marker = ';base64,';
  final markerIndex = url.indexOf(marker);
  if (markerIndex == -1) return null;
  try {
    return base64Decode(url.substring(markerIndex + marker.length));
```
注意 `url.substring(...)` 还会为一张 3 MB 的图额外复制一份 ~4 MB 的 String（base64 膨胀 4/3），瞬时内存是「原 String + substring 副本 + 解码结果」三份。

**触发场景**：ImageGeneration 返回 data URL 的首帧、以及所有未命中 `itemCache` 的 rebuild。

**建议**：`await compute(_decodeDataImageUrl, url)`，把 mapper 改成异步 + `FutureBuilder`/预解码；至少用 `base64.decoder.convert(url, markerIndex + marker.length)`（`Base64Codec.decode` 支持 start/end，可省掉 substring 副本）。

### 3. [P1] 全仓库无任何 `cacheWidth/cacheHeight/maxBytes`，ImageCache 上限也未调整
涉及以下全部展示点（`extended_image 10.0.1` 的 `ExtendedImage.network` **确实支持** `cacheWidth/cacheHeight/compressionRatio/maxBytes`，见 `~/.pub-cache/hosted/pub.dev/extended_image-10.0.1/lib/src/extended_image.dart:331-338`，但一处都没用）：

- `<lib>/features/gallery/widgets/gallery_tile.dart:45-64`（2 列网格，`fit: BoxFit.cover`，全分辨率截图解码）
- `<lib>/features/gallery/widgets/gallery_image_viewer.dart:295-318`
- `<lib>/features/message_images/message_images_screen.dart:282-286`（`_NetworkImage`，被 `_MultiImageList` 列表复用）
- `<lib>/features/generated_image_preview/widgets/generated_image_chat_group.dart:262-267`（`Image.memory` 缩略图，最小 4 列 ≈ 80 px 宽却按原图解码）
- `<lib>/features/generated_image_preview/widgets/generated_image_preview_page.dart:181-187`
- `<lib>/widgets/bubbles/image_preview.dart:68`、`:127`（150 px 高的横向缩略图仍全量解码）

**证据**（gallery_tile.dart:45）：
```dart
                  child: ExtendedImage.network(
                    imageUrl,
                    fit: BoxFit.cover,
                    cache: true,
                    cacheMaxAge: _kCacheMaxAge,
```
`cache: true` 只是**磁盘/字节缓存**，不影响解码分辨率。

**触发场景**：Gallery 网格滚动几十张 iPhone 截图（1290×2796 → 解码后 ≈14.4 MB/张），2 列 + 默认 `cacheExtent` 一屏就同时活着 6-8 张，加上 ImageCache 保留 1000 项/100 MiB，内存峰值直接冲到几百 MB。

**建议**：
- 网格/缩略图：`ExtendedImage.network(..., cacheWidth: (tileWidth * dpr).round())` 或用 `ExtendedResizeImage` + `maxBytes`；`Image.memory(bytes, cacheWidth: ...)`。
- 在 `<lib>/main.dart:117` `WidgetsFlutterBinding.ensureInitialized()` 之后设置 `PaintingBinding.instance.imageCache..maximumSizeBytes = 64 << 20 ..maximumSize = 120`。
- 全屏查看页可以保留原分辨率但配 `clearMemoryCacheWhenDispose: true`（该参数默认 `false`）。

### 4. [P1] `<lib>/widgets/bubbles/image_preview.dart:58-59`、`:120-121`、`:168-169`
**问题**：先把 `httpBaseUrl` 拼到 URL 前，再判断是不是 data URL，导致 data URL **永远判不出来**，被当作网络图请求，必然加载失败。

**证据**：
```dart
// image_preview.dart:58
    final url = '$httpBaseUrl${image.url}';
    final dataBytes = _decodeDataImageUrl(url);   // 内部: url.startsWith('data:image/')
```
`httpBaseUrl` 来自 `<lib>/services/bridge_service.dart:1248-1259`，是 `http://host:port` 这样的非空 origin，拼接后变成 `http://host:8080data:image/png;base64,...`。
对照 `<lib>/features/generated_image_preview/generated_image_preview_mapper.dart:105-113` 的正确写法：
```dart
String? _resolveImageUrl(String imageUrl, String? httpBaseUrl) {
  if (imageUrl.isEmpty) return null;
  final uri = Uri.tryParse(imageUrl);
  if (imageUrl.startsWith('data:image/') || uri?.hasScheme == true) {
    return imageUrl;
  }
```
**触发场景**：ToolResult 里 `ImageRef.url` 为 data URL（`_resolveImageUrl` 的存在证明这是合法输入）时，`tool_result_bubble.dart:528` 的 `ImagePreviewWidget` 一律显示 broken_image。
**建议**：把 `_resolveImageUrl` 提到公共 util，三处调用点统一改用它。

---

## P2

### 5. [P2] CurvedAnimation 未 dispose，双击缩放每次都往 AnimationController 上挂一个永不移除的 status listener
`<lib>/features/gallery/widgets/gallery_image_viewer.dart:277-281`
```dart
    _animation = Matrix4Tween(begin: _transformController.value, end: endMatrix)
        .animate(
          CurvedAnimation(parent: _animController, curve: Curves.easeOutCubic),
        );
    _animController.forward(from: 0);
```
`<lib>/features/generated_image_preview/widgets/generated_image_preview_page.dart:78-88`（`_animateTo` 同样问题，且它被 `_handleDoubleTap` 和 `_handleInteractionEnd:124` 两处调用，频率更高）：
```dart
          CurvedAnimation(
            parent: _animationController,
            curve: Curves.easeOutCubic,
          ),
```
**问题**：`CurvedAnimation` 构造时执行 `parent.addStatusListener(_updateCurveDirection)`，只有显式 `dispose()` 才会移除。这里每次双击/每次单指拖拽结束都 new 一个，旧的全部残留在 `_animationController` 的 listener 链上。
**触发场景**：在预览页反复双击缩放或滑动切图（`_handleInteractionEnd` 每次拖拽结束必调 `_animateTo(Matrix4.identity())`），listener 数量线性增长，每帧动画都要遍历这些无效 listener；Flutter 的 leak tracking 也会告警。
**建议**：把 `CurvedAnimation` 提为 `late final` 字段建一次复用，或在创建新的之前 `_oldCurved?.dispose()`，并在 `State.dispose()` 里 dispose。

### 6. [P2] `<lib>/features/gallery/widgets/gallery_content.dart:114-123` GridView item 缺少 key
```dart
            itemBuilder: (context, index) {
              final image = filtered[index];
              return GalleryTile(
                image: image,
                httpBaseUrl: httpBaseUrl,
                timeAgo: timeAgo(image.addedAt),
```
`GalleryTile` 本身没有 `key`（`gallery_tile.dart:31` 的 `ValueKey` 挂在内部 `GestureDetector` 上，对 Sliver 的 element 复用无效）。
**触发场景**：长按删除某张图后 `GalleryCubit` 推新列表，或切换 `selectedProject` 筛选 chip 导致 `filtered` 顺序整体位移时，Flutter 按 index 复用 element，`ExtendedImage` 的内部 State 会短暂显示上一张图/loading 错位。
**建议**：`return GalleryTile(key: ValueKey(image.id), ...)`。
（另：`gallery_tile.dart:38-39` 的 `Hero(tag: 'gallery_${image.id}')` 在 `GalleryImageViewer` 里没有对应的目标 Hero，属于无效开销；若同一 id 在筛选前后同时出现在两棵子树中还会触发 "multiple heroes share the same tag" 断言。）

### 7. [P2] `<lib>/features/message_images/message_images_screen.dart:167` 与 `:251`
```dart
      return _SingleImageView(url: '$httpBaseUrl${imageList.first.url}');
...
        final url = '$httpBaseUrl${images[index].url}';
```
与第 4 条同源：`get_message_images` 返回的 `ImageRef.url` 若是 data URL 会被无脑拼接成非法 URL；且 `_MultiImageList`(`:246-264`) 的 `ListView.separated` **item 无 key、无 cacheWidth**，一屏多张原图全量解码。
**建议**：复用 `_resolveImageUrl`；`itemBuilder` 加 `key: ValueKey(images[index].id)`；`_NetworkImage` 增加 `cacheWidth`。

### 8. [P2] `<lib>/features/generated_image_preview/generated_image_preview_screen.dart:138`
```dart
              controller: _pageController,
              physics: const NeverScrollableScrollPhysics(),
              allowImplicitScrolling: true,
```
`allowImplicitScrolling: true` 会让 PageView 常驻缓存左右各一页，加上 `generated_image_preview_page.dart:181` 的全分辨率 `Image.memory` ⇒ 任意时刻至少 3 张原图位图同时在内存里（2048² 就是 48 MB）。
**建议**：配合第 3 条给 `Image.memory` 加 `cacheWidth`，或在图片较大时关掉 `allowImplicitScrolling`。

### 9. [P2] `<lib>/features/gallery/gallery_screen.dart:49-51` 数据源回退会显示陈旧/跨会话的图
```dart
    final images = context.watch<GalleryCubit>().state.isNotEmpty
        ? context.watch<GalleryCubit>().state
        : bridge.galleryImages;
```
**问题**：Cubit 状态为空时回退到 `bridge.galleryImages`（`bridge_service.dart:508`），而后者是**全局最后一次 gallery 列表**。以 `sessionId` 进入某个会话相册、服务端返回空列表时（`GalleryListMessage` 会把 `_galleryImages` 覆盖成空，见 `bridge_service.dart:1664-1666`，此时两者一致），但在 `requestGallery` 发出后、响应到达前的这段窗口里，屏幕会展示上一个会话/项目的图片，标题计数也是错的。
**建议**：只用 `GalleryCubit` 单一数据源（用 `null` 而非空列表表示"未加载"），并在 `useEffect`(`gallery_screen.dart:43-46`) 请求前先清空。

---

## P3

### 10. [P3] `<lib>/features/gallery/widgets/gallery_image_viewer.dart:36` + `:86-90` 删除后 PageController 与状态不同步
```dart
    final imageList = useState(List<GalleryImage>.from(images));
...
        imageList.value = newList;
        // Adjust page index
        if (safeIndex >= newList.length) {
          currentPage.value = newList.length - 1;
        }
```
只改了 `currentPage` 这个 hook state，没有 `pageController.jumpToPage(...)`，靠 PageView 在 itemCount 变小后自行 clamp；`onPageChanged` 不会回调。同时 `imageList` 是 `images` 的一次性快照，`GalleryNewImageMessage`/外部删除不会反映到打开中的查看器。
**建议**：删除后显式 `pageController.jumpToPage(newIndex)`；或改为直接 watch `GalleryCubit` 而不是持有快照。

### 11. [P3] `<lib>/features/gallery/widgets/gallery_image_viewer.dart:100-136` 分享路径的整文件内存 + 临时文件竞态
```dart
        final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 30));
...
        await tempFile.writeAsBytes(response.bodyBytes);
        await SharePlus.instance.share(ShareParams(files: [XFile(tempFile.path)]));
      } catch (_) {
...
      } finally {
        tempFile?.delete().ignore();
      }
```
- `response.bodyBytes` 一次性把整图读进内存（非流式），无大小上限；
- `finally` 在 share 返回后立即删文件，Android 上接收方 App 可能还在延迟读取该 URI，存在竞态；
- `catch (_)` 吞掉所有异常（含 `Directory.systemTemp` 不可写），只弹一句 toast，无日志。
**建议**：改用 `http.Client().send()` + `StreamedResponse` 流式写盘；临时文件延迟删除（或写到应用缓存目录 + 定期清理）；catch 中至少记录 error。

### 12. [P3] `<lib>/features/generated_image_preview/generated_image_preview_mapper.dart:47-52` 缓存策略是 FIFO 不是 LRU，且容量硬编码 64
```dart
      if (itemCache != null) {
        if (itemCache.length >= 64) {
          itemCache.remove(itemCache.keys.first);
        }
        itemCache[cacheKey] = item;
      }
```
会话里生成图超过 64 张时，每帧都在淘汰最早插入的项 ⇒ 缓存命中率骤降 ⇒ 退化成第 1 条的 base64 重复解码。另外 `cacheKey` 记录里包含整段 `message.content`（`:33`），哈希/比较代价与内容长度成正比。
**建议**：改成访问即 `remove`+`put` 的 LRU；`cacheKey` 用 `content.hashCode` 或 toolUseId+imageId 即可，不必带全文。

### 13. [P3] `<lib>/features/generated_image_preview/widgets/generated_image_chat_group.dart:170-174` + `:196-214` 冗余 resolve
```dart
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolveAspectRatio();
  }
```
即使 `initState` 已通过 `_pngAspectRatio()`（`:239-250`，只读 PNG 头，很廉价）拿到宽高比，`didChangeDependencies` 仍会无条件 `provider.resolve(...)` 触发一次完整解码；而且首次 `resolve` 时 completer 尚未附着，`stream.key == _imageStream?.key` 的短路（`:200`）在这一帧必定失效，每次依赖变化（主题、MediaQuery、键盘弹出）都会走一遍 add/remove listener。
**建议**：`if (_aspectRatio != null) return;` 前置短路；或只在 `item.bytes == null`（网络图）时才 resolve。
（正面确认：`_removeImageStreamListener()` 在 `dispose`(`:225-228`) 中被调用，listener 本身没有泄漏。）

### 14. [P3] `<lib>/features/message_images/message_images_screen.dart:165`
```dart
    final imageList = images!;
```
当前状态机保证 `loading==false && error==null ⇒ images!=null`，但这是隐式契约；`onError`(`:83`) 只按 `TimeoutException` 分支处理，其他异常（如 bridge 关闭导致 `.first` 抛 `StateError`）会把 `'$err'` 原样拼进 UI 文案。
**建议**：用 sealed 状态类（loading/error/data）替代三个独立字段；`onError` 对非预期异常统一文案并 `debugPrint`。

---

## 复核确认为「无问题」的项（避免误报）

- **资源释放（第 1 类）整体是干净的**：
  - `<lib>/features/message_images/message_images_screen.dart:42/51/104` — `StreamSubscription` 在重试前和 `dispose` 中都 `cancel()`；
  - `<lib>/features/gallery/widgets/gallery_image_viewer.dart:246-250` — `AnimationController` + `TransformationController` 均 dispose；`pageController` 用 `usePageController`(`:37`) 自动释放；
  - `<lib>/features/generated_image_preview/widgets/generated_image_preview_page.dart:48-53` — 先 `removeListener` 再 dispose，最规范；
  - `<lib>/features/generated_image_preview/generated_image_preview_screen.dart:55-58` — `PageController` dispose 并复位 `SystemUiMode`；
  - `<lib>/providers/stream_cubit.dart:15-18` — `StreamCubit.close()` 取消订阅。
  唯一残留是第 5 条的 `CurvedAnimation`。
- **BuildContext 跨 await（第 2 类）：这三个目录内没有发现真正的违规**。所有 await 后的 context 使用都有守卫：`gallery_content.dart:73`、`:77`（`if (!context.mounted) return;`）；`gallery_image_viewer.dart:72`、`:76`、`:108`、`:127`。唯一瑕疵是 `gallery_image_viewer.dart:74-77`，unmount 时提前 return 会让 `isDeleting.value` 停在 `true`（因为组件已销毁所以无实际影响），以及 `handleDelete` 捕获的是 build 期的 `safeIndex/currentImage`（`:64-65`），理论上存在删错索引的窗口（模态对话框挡住了大部分触发路径，故列为 P3）。
- `GridView.builder`(`gallery_content.dart:105`) 的 `addAutomaticKeepAlives` 默认 `true` 但子树没有任何 `KeepAlive`/`AutomaticKeepAliveClientMixin`，**不构成常驻内存问题**；真正的内存问题是第 3 条的解码分辨率，不是 keepAlive。
- `groupGeneratedImageResponses` / `completedGeneratedImageToolUseIds`（`<lib>/features/generated_image_preview/generated_image_response_grouping.dart` 全文）逻辑正确，无副作用、无泄漏。
