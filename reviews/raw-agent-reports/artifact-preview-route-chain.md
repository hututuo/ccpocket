I'll start by exploring the repository structure to understand the codebase layout.
Let me launch parallel investigations while I dig into the preview chain myself.
Now let me focus on the preview decision chain (part A) myself.
Both parallel audits are back. Let me verify one decisive build-provenance fact before writing up.
两个并行深审已返回。以下是完整审查结果。

---

# 结论摘要（先说最关键的一条）

**用户真机上"JSON/HTML/网页预览仍失败"的首要原因不是逻辑 bug，而是安装的 build 里根本没有统一预览路由。**

- 实现"统一 Quick Look + HTML/JSON 回退"的提交是 `34e97866`（2026-07-25，同时改了 Dart 与 Bridge）。
- `git tag --contains 34e97866` → **空**。`git branch -a --contains` → 只有 `fix/mobile-comprehensive-v02-20260726` 与 `integration/mobile-1.109.2-comprehensive-20260725`。
- 最新发布标签 `ios/v1.108.0+196` 指向 `0b793a15`（2026-07-21），`git merge-base --is-ancestor 34e97866 ios/v1.108.0+196` 返回**否**。
- 该提交同时包含 Swift 侧行为依赖，**Shorebird OTA 补丁无法覆盖**（只打 Dart）。
- 已发布 build 里的 `artifact_quick_look_service.dart`（`git show 34e97866^`）：Quick Look 只对 Office 扩展名白名单尝试（JSON/HTML 根本进不去 Quick Look），且 `MethodChannelArtifactQuickLookGateway.previewFile` **不做任何异常翻译**——`PlatformException`/`MissingPluginException` 直接抛给上层的泛化 `catch (_)`，**一次回退都没有**。Bridge 侧 `/artifacts/<token>/sandbox` 路由与 JSON pretty-print 也是同一提交引入的，`packages/bridge/package.json` 是 `1.69.4-compat.1` 而最新 bridge 标签是 `bridge/v1.69.0`。

> 所以在给出任何"代码已修但仍失败"的结论前，必须先确认真机 IPA 与运行中的 Bridge 是否来自本分支。这是交接文档 §11 表格里"待事件线/真机"那一行的直接答案。

即便如此，本分支源码里仍有下列真实缺陷。

---

# A. 预览路由决策链取证

## A.0 完整决策树（本分支源码）

```
入口①Agent artifact 引用   chat_message_list.dart:266 _openArtifact
入口②Markdown 纯超链接     markdown_style.dart:71 handleMarkdownLink / markdown_link_handler.dart:35
入口③手动文件管理           file_browser_screen.dart:298 _openNode → :325 _previewNode
入口④已接收文件收件箱       file_transfer_sheet.dart:264 _preview

Bridge 分类层
  artifact-manager.ts:252  sourceKind()          → kind = "source" | "preview"
  artifact-preview.ts:119  mimeTypeForFilename() → MIME（扩展名表，未知→application/octet-stream）
  artifact-preview.ts:123  previewKindForFile()  → image|pdf|html|text|audio|video|docx|office|unsupported
  file-browser-manager.ts:1028-1036               → previewKind + canPreview(=regularFile && artifactStore && ≤2GiB)

Mobile 路由层
  artifact_quick_look_service.dart:49 shouldTryQuickLookForArtifact()
        = (0 ≤ sizeBytes ≤ 64 MiB) && !isHtmlArtifact()
  artifact_preview_screen.dart:130-142  → _usesQuickLook ? QuickLook : _initializeWebPreview()

Native 层
  ArtifactQuickLookPlugin.swift:236  QLPreviewController.canPreview(item)
        false → FlutterError("unsupported") → ArtifactQuickLookUnsupportedException → 回退 WebView
        其余错误码 busy / no_presenter / file_not_found / invalid_path / presentation_failed
        → PlatformException 原样 rethrow → 无回退

失败态
  artifact_preview_screen.dart:445-452  仅 ArtifactQuickLookUnsupportedException 回退 WebView
  artifact_preview_screen.dart:453-457  其余一律 _quickLookError=true + artifactOpenFailed
```

**决策链断点：Bridge 的 `previewKind` 在 Mobile 侧是死数据。** `apps/mobile/lib/features/file_browser/file_browser_service.dart:610` 解析了它，但 `ArtifactPreviewScreen` 的构造参数里没有它（`artifact_preview_screen.dart:72-92`），全局唯一消费点是 `file_browser_screen.dart:1061 _iconForNode()` 的图标选择——而且那里还匹配了 `'markdown'`/`'code'` 两个 `previewKindForFile()` 永远不会产出的值（死分支）。Mobile 完全用 filename+mimeType 重新推导一遍，Bridge/Mobile 两套判定可以静默漂移。

---

## A.1 JSON 失败点（明确结论）

### [A1] [P0] `.json` 被 Bridge 判为 `kind:"source"`，Agent 引用路径永远走不到统一预览
`packages/bridge/src/artifact-manager.ts:82`（SOURCE_EXTENSIONS 含 `.json`）、`:266-274 sourceKind()`；`apps/mobile/lib/features/chat_session/widgets/chat_message_list.dart:279`

- **触发场景**：Agent 在回答里引用工程内的 `.json`（有 `projectRelativePath`），用户点击。
- **证据**：`sourceKind()` 中 `SOURCE_EXTENSIONS.has(".json") || normalizedMime.startsWith("application/json")` → `isSource = true` → `kind = "source"`；Mobile `if (artifact.isSource) { ... return showFilePeekSheet(...) }` 直接进 File Peek 纯文本表，**根本不构造 `ArtifactPreviewScreen`**，Quick Look / 统一预览 / 下载 / 分享全部不可达。
- 后果：v01 §11.5 写的"JSON 优先尝试 Quick Look，失败自动进入本地格式化/原文预览"，在 Agent 入口下**一步都没执行**；Bridge 的 JSON pretty-print（`artifact-http.ts:300-311`）只在 `/artifacts/<token>` 预览页里，`read_artifact_source` 路径（`websocket.ts:7804-7818`）**不做任何格式化**，用户看到的是压缩后的原文。
- **修复方向**：`sourceKind()` 不应把"能读源码"与"该用哪种预览"绑在一起；或 Mobile 在 File Peek 顶部提供"用统一预览打开/下载/分享"的入口，让 source 与 preview 共用同一套能力。

### [A2] [P1] 压缩 JSON（单行）在 File Peek 里必然卡死主 isolate
`packages/bridge/src/websocket.ts:228`（`FILE_PEEK_TEXT_MAX_BYTES = 8 MiB`）、`:7804 maxLines = msg.maxLines ?? 5000`；`apps/mobile/lib/features/file_peek/file_peek_sheet.dart:560-634 _buildCodeContent`

- **触发场景**：minified JSON（无换行）≤8 MiB。
- **证据**：Bridge 按行截断，单行文件 → 一次性回传全部 8 MiB。Mobile `_buildCodeContent` 在 **build() 内**同步做 `content.split('\n')` → `highlightToTextSpans(source: content)` → `_splitSpansByLine()` → 构造一个 `SelectableText.rich`。8 MiB 单行文本的语法高亮 + 单段文本布局在主 isolate 上执行，且**每次 setState 重跑**（无 memoization）。
- **修复方向**：Bridge 增加字节级截断（不只按行）；Mobile 把高亮移到 `compute()` 并把结果缓存到 State 字段；单行超长内容强制降级为无高亮 + 硬换行。

### [A3] [P1] >8 MiB 的 JSON 在 File Peek 里是死路，没有任何回退
`packages/bridge/src/websocket.ts:7794-7802`；`apps/mobile/lib/features/file_peek/file_peek_sheet.dart:478-479, 513-531`

- **证据**：Bridge 返回 `errorCode: "file_too_large"`，Mobile `_buildError()` 只画一个图标 + 错误文案，**没有下载、分享、或"用统一预览打开"的按钮**。
- **修复方向**：错误态里补 fallback 动作条（复用 `ArtifactPreviewScreen` 的 share/download）。

### [A4] [P0] 除 `unsupported` 外的所有 Quick Look 失败都不回退，直接死在错误卡片上
`apps/mobile/lib/features/artifact_preview/artifact_preview_screen.dart:445-457`

- **证据**：
  ```dart
  } on ArtifactQuickLookUnsupportedException {
    _initializeWebPreview();            // 唯一的回退
  } catch (_) {
    setState(() => _quickLookError = true);
    _showError(...artifactOpenFailed);  // 无回退
  }
  ```
  会落进 `catch (_)` 的真实错误码包括：`ArtifactTransferException('size_mismatch')`（`artifact_transfer_service.dart:110-112`，Content-Length ≠ `widget.sizeBytes`）、`'http_error'`（`:103-108`，token 过期 404 / `openCurrentEntry` 409 file_changed / 410 file_gone）、`'destination_not_reserved'`、以及 Swift 侧的 `busy` / `no_presenter` / `file_not_found` / `presentation_failed`。
- 这与 E.4 §5"不支持**或失败**时回退本地预览器"直接冲突（v01 §11.5 的实现说明写的是"真实传输或 presentation 错误才显示重试"——**需求与实现说明本身就不一致**，需要产品裁决后统一）。
- **修复方向**：把回退条件从"异常类型"改成"是否已成功呈现过"；只要没呈现成功就一律 `_initializeWebPreview()`，并把错误文案降级为顶部提示条。

### [A5] [P1] `expiresAt` 是完全未使用的死字段，10 分钟后所有动作全挂
`apps/mobile/lib/features/artifact_preview/artifact_preview_screen.dart:77, 88`（声明后全文再无引用）；`packages/bridge/src/file-browser-manager.ts:59 PREVIEW_TTL_SECONDS = 600`

- **触发场景**：预览页停留超过 10 分钟后点分享/下载/重试。
- **证据**：token 过期 → `/download` 404 → `http_error` → 走 A4 的死路；WebView 侧 404 因 A7 连提示都没有。屏幕上没有倒计时，也没有重新 `resolveArtifact`/`preview` 的路径，只能退出重进。
- **修复方向**：过期前主动重新签发；或在 404/410 时自动重新 issue 一次再重试。

### [A6] [P2] 每次预览都先把整个文件（≤64 MiB）下载到临时目录，之后才知道 Quick Look 不支持
`apps/mobile/lib/features/artifact_preview/artifact_quick_look_service.dart:117-130`

- **证据**：`previewTemporaryArtifact` 的顺序是 `prepareFile()`（完整 HTTP 下载）→ `isCancelled()` → `_gateway.previewFile()`（此时才做 `canPreview`）。
- **触发场景**：Android / macOS（无该 MethodChannel，`MissingPluginException` → `plugin_missing`）、以及 iOS 上所有无注册 UTI 的文本类型（`.dart/.py/.log/.yaml/.ts/.toml` 等）。这些情况下**先白下一遍整文件，删掉，再让 WebView 从 Bridge 重新下一遍**，双倍流量与等待。
- **修复方向**：把 `canPreview` 判定前移——native 增加一个只按扩展名/UTType 判定的 `canPreview(filename)` 方法，Dart 先问再决定是否下载。

### JSON 结论
**在本分支源码上，JSON 有三个确定失败点（A1/A2/A3）与两个条件失败点（A4/A5）。最主要的一个是 A1：Agent 引用入口下 `.json` 被判为 `source`，统一预览路由整段不执行。** 在已发布 build（v1.108.0）上，JSON 连 Quick Look 都不会尝试，且无任何异常翻译，所以是"必失败"。

**仍需真机取证的具体字段**（当前静态代码无法定论的唯一一点）：
1. `QLPreviewController.canPreview` 对 `.json`（UTI `public.json`，仅 conform 到 `public.text` 而非 `public.plain-text`）在目标 iOS 版本上返回 true 还是 false —— 请打点记录 Swift 侧 `previewFile` 的返回码。
2. 需要采集的字段：`filename` / `extname` / 客户端 `mimeType` / `sizeBytes` / Bridge `previewKind` / native FlutterError.code / `_usesQuickLook` 与 `_quickLookError` 的最终值 / `previewControllerDidDismiss` 是否被调用。

---

## A.2 HTML 失败点（明确结论）

### [A7] [P0] `.html` 同样被判为 `kind:"source"`——Agent 引用入口下"本地 HTML 优先应用内安全预览"完全没生效
`packages/bridge/src/artifact-manager.ts:82`（SOURCE_EXTENSIONS 含 `".html"`）、`:266-274`

- **证据**：与 A1 同一段代码。带 `projectRelativePath` 的 `.html` → `kind:"source"` → `chat_message_list.dart:279` → `showFilePeekSheet` → **显示 HTML 源码文本**，永远不会进 `ArtifactPreviewScreen` → 永远不会加载 `/artifacts/<token>` → 永远不会用到 `artifact-preview.ts:187-189` 的 sandbox iframe。
- 这是 E.4 §5 需求的直接违反，也最贴合用户"HTML 预览失败"的主观描述（点开只看到一堆源码/或什么都不渲染）。
- **修复方向**：`sourceKind()` 对 `previewKindForFile()==="html"` 的文件强制 `kind:"preview"`（同时保留 File Peek 作为"查看源码"的次级动作）。

### [A8] [P1] iOS 上 `onHttpError` 是死代码，HTTP 4xx/410 的预览失败不会被识别，直接把错误 JSON 当成"预览内容"渲染
`apps/mobile/lib/features/artifact_preview/artifact_preview_screen.dart:185-192`

- **证据**：
  ```dart
  onHttpError: (error) {
    if (error.request?.uri.path == widget.previewUrl.path && mounted) { ... }
  }
  ```
  `webview_flutter_wkwebview-3.26.0/lib/src/webkit_webview_controller.dart:1099-1111` 里 iOS 只构造 `HttpResponseError(response: ...)`，**从不传 `request`**（`webview_flutter_platform_interface-2.15.1/lib/src/types/http_response_error.dart:42`）。因此 `error.request` 恒为 `null`，条件恒为 false。
- **后果**：token 过期（404）、`openCurrentEntry` 409 `file_changed`、410 `file_gone`（`artifact-store.ts:356-389`）时，WebView 会把 `sendArtifactError` 返回的 `{"error":"...","errorCode":"file_changed"}` 当作页面正文渲染，`_mainFrameError` 保持 null，用户看到一段裸 JSON 而不是失败提示或重试按钮。Android 侧 `webview_flutter_android` 会传 `request`，所以这是 iOS 独有的洞。
- **修复方向**：改用 `error.response?.statusCode` 判定，不依赖 `request`；≥400 且尚未收到 `onPageFinished` 的正常内容时置 `_mainFrameError`。

### [A9] [P2] `onWebResourceError` 的主帧判定在 iOS 上恒真
`apps/mobile/lib/features/artifact_preview/artifact_preview_screen.dart:172-184`

- **证据**：`webkit_webview_controller.dart:1129-1155` 中 `didFailNavigation` / `didFailProvisionalNavigation` / `webViewWebContentProcessDidTerminate` 三处都硬编码 `isForMainFrame: true`。所以 `error.isForMainFrame == true` 这一分支在 iOS 上永远命中，后面精心写的 URL 比对回退分支（`:176-180`）是死代码。同时 `webViewWebContentProcessDidTerminate`（WebContent 进程被系统回收，大 HTML 常见）也会被当成主帧失败，弹出整屏 `artifactOpenFailed`——而正确处理应该是 `reload`。
- **修复方向**：区分 `WKErrorCode.webContentProcessTerminated` 走自动 reload；其余保持失败态。

### [A10] [P2] 沙箱 HTML 的资源策略会让"看起来正常"的报告变成半破页
`packages/bridge/src/artifact-http.ts:33-38 SANDBOXED_HTML_CSP`

- **证据**：`default-src 'none'; img-src data: blob:; media-src data: blob:; font-src data:; connect-src 'none'`。同目录的相对资源（`<img src="chart.png">`、`<link href="style.css">`）全部被 CSP 拦掉，因为 `/sandbox` 是单文件路由，也没有 `'self'`。
- 这在安全上是刻意的，但需求要求"真实失败样本验收"——**Agent 生成的 HTML 报告绝大多数不是完全自包含的**，用户会看到无图/无样式的页面并判定为"预览失败"。
- **修复方向**：要么在 UI 上明确提示"已阻断外部资源"，要么为 HTML artifact 增加同目录相对资源的受控 `/assets` 白名单路由。

### HTML 结论
**在本分支源码上，HTML 的首要失败点是 A7（Agent 入口整条路由被 `kind:"source"` 短路），其次是 A8（iOS 上 HTTP 错误静默）与 A10（资源被 CSP 拦成破页）。** WebView 侧的导航白名单本身是正确的——已核实 `webkit_webview_controller.dart:1113-1127` 的 `decidePolicyForNavigationAction` 对子帧同样回调，而 `isAllowedArtifactPreviewNavigation`（`artifact_preview_screen.dart:51-55`）显式放行 `/sandbox` 与 `/artifacts/assets/`，iframe 不会被误拦；`Info.plist:63-67` 也已配置 `NSAllowsArbitraryLoadsInWebContent`，明文 `http://` 的 ATS 拦截不成立。

---

## A.3 native dismissal 是否被误判为失败

### 结论：**没有被误判。** 但存在两个衍生问题。

取证链：`ArtifactQuickLookPlugin.swift:56 previewControllerDidDismiss` → `:152 finish(session)` → `:39 complete(nil)` → Dart `invokeMethod` 正常返回 → `artifact_preview_screen.dart:458-467 finally` 只置 `_quickLookBusy = false`，`_quickLookError` 保持 `false`。`ArtifactQuickLookService:127-129` 的 `finally` 正确删除临时文件（含 `:132-146` 的一次 100 ms 重试，处理 QL 控制器消散期的文件占用）。**用户手动关闭不会触发任何错误回退。**

### [A11] [P2] 用户关闭 Quick Look 后落在一张"看起来像失败"的空白卡上
`apps/mobile/lib/features/artifact_preview/artifact_preview_screen.dart:514-557 _buildQuickLookBody`

- 关闭后屏幕上只剩一个文件图标、文件名和一个"预览"按钮。用户主观上会认为"打开失败了"。
- **修复方向**：`previewControllerDidDismiss` 后自动 `Navigator.pop()`（或渲染成明确的"已关闭预览"态 + 分享/下载动作）。

### [A12] [P1] `activeSession` 无超时/无兜底复位，一次未触发 dismissal 就永久 `busy`
`apps/mobile/ios/Runner/ArtifactQuickLookPlugin.swift:85, 152-160, 163-172`

- **证据**：`activeSession` 只在 `previewControllerDidDismiss` / `presentationControllerDidDismiss` / 呈现失败三条路径复位。若 QLPreviewController 被系统或其他 VC 连带 dismiss（`presentationControllerDidDismiss` 在 `.fullScreen` 样式下不触发交互式关闭，`:36`），`activeSession` 永久非 nil，之后**每一次预览**都返回 `FlutterError(code:"busy")` → 落进 A4 的死路。
- 另注：`:275 session.controller.presentationController?.delegate = session` 覆盖了 QLPreviewController 自身的 presentation delegate，属于额外风险面。
- **修复方向**：在 `viewDidDisappear` / `UIApplication.didEnterBackground` 上加兜底复位；或用 `presentingViewController == nil` 做惰性自愈检查。

---

# B. 两套入口是否真的共用能力

## [B1] [P0] 预览判定被复制成三套，且 Agent 入口与手动入口对同类文件给出不同结果
- 入口③手动文件管理：`file_browser_screen.dart:359` → `ArtifactPreviewScreen`（Quick Look → WebView 沙箱 → 分享/下载）。
- 入口①Agent 引用：`chat_message_list.dart:279` → 对 `kind:"source"`（**含 .json/.html/.md/.py/... 共 40+ 扩展名**，`artifact-manager.ts:82-140`）走 File Peek；只有 `kind:"preview"` 才共用 `ArtifactPreviewScreen`。
- 入口④收件箱：`file_transfer_sheet.dart:264` **直接调 `MethodChannelArtifactQuickLookGateway().previewFile()`**，无 `shouldTryQuickLookForArtifact` 判定、无 WebView 回退、无 `unsupported` 翻译——Android/macOS 上必失败，iOS 上不支持的格式也必失败。
- **同一个 `report.html`，从文件管理点开是沙箱渲染页，从 Agent 引用点开是源码文本，从收件箱点开是 Quick Look 或直接报错。** 这是最严重的语义漂移。
- **修复方向**：抽出唯一的 `PreviewRouter`（输入 filename/mimeType/sizeBytes/来源，输出路由决策），三个入口共用；File Peek 降级为"查看源码"的可选动作而非入口级分叉。

## [B2] [P1] 下载被实现了两套，写进同一个目录但用不同的命名与索引
- 入口③：`file_browser_screen.dart:374-387 onDownloadRequested` → `file_browser_service.dart:615 download()` → Bridge file-transfer 管道（transferId、断点续传、收件箱记录、checkpoint）。
- 入口①：`onDownloadRequested` 为 null → `artifact_preview_screen.dart:379-413 _downloadArtifact` → 直接 HTTP 流式写盘，**无 transferId、无断点续传、无收件箱条目、无 checkpoint**。
- 两者的落地目录是**同一个**：`artifact_preview_screen.dart:386-390` 用 `getApplicationDocumentsDirectory()/Downloads`，`file_transfer_service.dart:243-246 defaultFileTransferDownloadsDirectory()` 也是 `Documents/Downloads`。但重名策略不同（前者 `reserveNextAvailableArtifactFile` 的 `" (1)"` 后缀，后者是 FileTransferStorage 自己的一套），且 FileTransferStorage 的清理逻辑不认识前者写入的文件。
- **修复方向**：统一走 file-transfer 管道；若要保留直连快路径，至少写入独立子目录并登记到同一索引。

## [B3] [P1] `supportsEmbeddedArtifactPreview()` 只在 Agent 入口生效，文件管理入口没有平台闸门
`apps/mobile/lib/features/artifact_preview/artifact_preview_screen.dart:67-70`；`chat_message_list.dart:334`（有闸门，非 iOS 走 `launchUrl` 外部浏览器）vs `file_browser_screen.dart:357-359`（无闸门）

- Android 上：Agent 引用 → 系统浏览器（违反 E.4"本地 HTML 优先应用内安全预览"，而 `webview_flutter_android` 明明可用）；文件管理 → 应用内 WebView。同一台设备两种语义。
- macOS 上：文件管理 → `ArtifactPreviewScreen` → Quick Look 插件缺失 → `_initializeWebPreview()` → **`pubspec.lock` 中没有任何 macOS/desktop WebView 实现**（只有 `webview_flutter_android` 与 `webview_flutter_wkwebview`），`WebViewController()` 会因 `WebViewPlatform.instance` 未设置而抛断言。且这个抛出发生在 `on ArtifactQuickLookUnsupportedException` 的处理块内（`:447`），不会被同一 try 的 `catch (_)` 捕获 → 变成未处理的异步异常；HTML 场景更糟：`initState` 里直接调 `_initializeWebPreview()`（`:142`）→ **initState 抛异常 → 红屏**。
- **修复方向**：把平台闸门下沉到 `ArtifactPreviewScreen` 内部，非 WebView 平台直接渲染 metadata + 下载/分享/系统打开三件套。

## [B4] [P1] `file_browser_screen.dart` 绕过了条件导入，Web 构建会因 `dart:io` 直接编译失败
`apps/mobile/lib/features/file_browser/file_browser_screen.dart:9`

- **证据**：存在 `artifact_preview_entry.dart`（`export 'artifact_preview_screen_stub.dart' if (dart.library.io) 'artifact_preview_screen.dart'`）专门解决这个问题，`chat_message_list.dart:21` 用的是它；但 `file_browser_screen.dart:9` 直接 `import '../artifact_preview/artifact_preview_screen.dart'`（该文件 `:2 import 'dart:io'`）。而 `file_browser_screen.dart` 被 `session_list_screen.dart:36` 与 `workspace_shell_screen.dart:11`（首页）引用。CLAUDE.md 把 `flutter build web --release` 列为标准工作流。
- **修复方向**：改用 `artifact_preview_entry.dart`。

## [B5] [P2] 路径解析也有三套
`file_peek_sheet.dart:73-83 _resolveFilePath`（后缀匹配 projectFiles）、`markdown_link_handler.dart:35 classifyMarkdownLink`（Windows 路径/file: scheme/行列号剥离）、`file_browser_service.dart:1145 resolveFileBrowserPreviewUri`（origin 校验），加上 Bridge 侧 `normalizeRelativePath` / `canonicalizeWithinRoot`。语义各不相同（例如 `_resolveFilePath` 的后缀匹配在多候选时弹选择器，而 Agent 直传路径不会）。

## [B6] [P2] 分享路径：入口①③共用 `_shareArtifact`（`artifact_preview_screen.dart:295-338`，带 `safeArtifactDownloadFilename` 与 `sharePositionOrigin`），入口④是独立实现（`file_transfer_sheet.dart:275-290`，`XFile(file.path)` 无 mimeType、无 fileNameOverrides）。

---

# C. 传输状态机

## C-Bridge（`packages/bridge/src/`）

做得好、无需改动的部分先说明：offset 权威完全在服务端（`appendChunk` 校验 `before.size !== entry.offset` 则 409 并回传真实 offset）；同 transfer 的 PUT/PATCH/cancel/prepare 全部经 `withTransferLock` 串行；状态文件为单实例内存 + `mutationQueue` 串行 + tmp+fsync+rename 发布，跨进程有 proper-lockfile（其定时器已 unref）；断电语义有 `rollbackPending`/`rollbackTruncating` 两阶段日志；HTTP 层所有 timer 都 `unref()` + `finally clearTimeout`，fd 全部 `finally close`。**Bridge 侧不存在 progress 事件机制**（进度靠每 chunk 的 `Upload-Offset` 响应），也不存在 totalBytes 未知路径（chunked 无 Content-Length 直接 411）。

| # | 严重度 | 位置 | 问题 |
|---|---|---|---|
| C1 | P1 | `file-transfer-upload-store.ts:351-369` | 过期清理未 try/catch。一个 `.part` 的 inode 被替换 → `controlledPartialPath`/`unlinkIfSameInode` 抛 409 → `removeUpload` 永不执行 → `retainUntil` 永远在过去 → `init()` 与**每一次** `prepare()`（`:181`/`:211` 无条件 await）都重抛，**整个上传子系统永久瘫痪且重启不自愈**。建议：逐条目 try/catch + warn + continue |
| C2 | P1 | `file-transfer-state-store.ts:445-459, :109` + `upload-store.ts:33` | `DEFAULT_MAX_UPLOADS=256`，完成的上传墓碑 `retainUntil = now+7天`，`pruneDownloads()` 只裁 downloads 从不裁 uploads → 7 天内第 257 次 `prepare` 抛裸 Error → `upload_prepare_failed`，此后一周内每次都失败。建议：complete 墓碑用短保留期或按 `updatedAt` 淘汰 |
| C3 | P2 | `file-transfer-upload-store.ts:288-326, :371-402, :531-535` | `pending && offset===sizeBytes` 是死状态：`append` 的 `offset+contentLength > sizeBytes` 恒成立（413），`contentLength<1` 也被 413，`status()`/`resumeLocked()` 都不会重新 finalize。0 字节文件、最后 chunk 落盘后被杀、finalize 抛 EXDEV/ENOSPC 三条路径可达。客户端 `file_transfer_service.dart:1956` 的 while 直接跳过，然后在 `:2016` 等 30s 超时 → 无限 prepare/重试循环。建议：三处统一加 `if (pending && offset===sizeBytes) return finalize(entry)` |
| C4 | P2 | `file-transfer-upload-store.ts:328-349, :635-637` | `.part` 被截短/换 inode 后，`cancel` 也会因强制 reconcile 抛 409 → 既不能续传也不能取消，状态与孤儿文件留满保留期，还会撞上 C1。`committing` 且 `recoverCommit` 无法恢复时同样抛 `upload_state_invalid`。建议：cancel 降级为 best-effort |
| C5 | P2 | `gallery-store.ts:218-235, :237-254, :464-481` | `init()` 不校验 `images/` 下文件是否存在、不回收孤儿；`saveIndex()` 用 `writeFile`+`rename` **无 fsync**（对比 state-store 的 `handle.sync()`+`fsyncDirectory`），掉电后 `init()` 的 catch 静默 `this.index = []` → **整个图库索引一次性丢失**；`delete()` 先 unlink 后 saveIndex，中途崩溃条目复活成 404，且无论 unlink 成败都返回 `true` |
| C6 | P2 | `gallery-store.ts:291-300, :343-351` | `this.index.push(meta)` 在 `saveIndex()` 之前，saveIndex 抛错后 catch 返回 `null`，但内存索引里已有该条：调用方认为失败、`list()` 却列出它、重启后又消失，`images/` 下留孤儿 |
| C7 | P3 | `file-transfer-manager.ts:426-447` | 下载条目仅在 `success && receivedBytes===sizeBytes` 时移除；手机失败路径发 `receivedBytes: 0`（`file_transfer_service.dart:775`）→ 失败条目占位 7 天 → 撞 `DEFAULT_MAX_DOWNLOADS=256` 后 `offerFile` 变 500 |
| C8 | P3 | `file-transfer-upload-store.ts:441, :469` + `state-store.ts:601-639` | 每个 PATCH 至少 2 次全量状态文件重写（最多 8 MiB JSON 序列化 + `handle.sync()` + rename + chmod + 目录 fsync）。15 GiB 文件 → 上万次全量重写 |
| C9 | P3 | `upload-store.ts:311-314` / `file-transfer-http.ts:261-335` | 并发上限检查在 transfer 锁**之内**，只能限制"正在写盘"数量，不能限制排队请求；下载侧有 HTTP 层 `activeDownloads` 同步预留（`http.ts:189-195`），上传侧没有 |
| C10 | P3 | `file-transfer-http.ts:303-305` | 上传只监听已废弃的 `req 'aborted'`，缺 `res.once("close", abort)`（对比 `handleSendControl:131-133`）→ 最长 60s 占着 transfer 锁 |
| C11 | P3 | `file-transfer-manager.ts:568-603, :107-123` | `sendCompletedUpload` 依赖活跃 WS 绑定，最后 chunk 完成时断线则 `upload_result` 直接丢弃，只能靠手机重新 prepare 命中墓碑补发——而墓碑存活受 C2 约束 |

补充：`upsertUpload` 本身不做状态迁移校验，但所有写路径都在同一 `withTransferLock` 下，`complete` 在 `finalize:533`/`cancel:336`/`resumeLocked:388` 三处短路，**当前不存在终态被回退的窗口**；建议加一条 "complete 不可降级" 断言作纵深防御。

## C-Mobile（`apps/mobile/lib/features/file_transfer/`）

| # | 严重度 | 位置 | 问题 |
|---|---|---|---|
| C12 | P0 | `file_transfer_service.dart:662-668` | 暂停中的传输取消失败后，`paused.cancelRequest ??= ...` 把 rejected Future 永久钉住，之后每次点取消都 rethrow 同一旧错误，checkpoint 与 `.part` 永远留盘。对照 `_drain` 的 `:965-982` 有 `work.cancelRequest = null` 复位，paused 分支漏了 |
| C13 | P0 | `file_transfer_service.dart:917-941, :2252-2261` | `if (completedOnly \|\| _pausedWork != null) break;` —— **单个 paused 任务锁死整个队列**。UI 的"开始 N 个待接收文件"按钮点了没反应也没提示；拖入的文件永久排在后面 → 聊天附件卡在 `uploading` → `sendMessage` 被 `waitForUploads` 挡死 |
| C14 | P1 | `file_transfer_service.dart:2282-2319, :2614-2633` | `_recover()` 中多条 `deleteUpload + continue` 路径（过期 `:2284`、身份不匹配 `:2308`）不产生任何 record → `_uploadCompletions[localId]` 既不 complete 也不 remove → Map 单调增长，`awaitDroppedUpload` 永久挂起 |
| C15 | P1 | `file_transfer_service.dart:1024-1037` | 不可恢复失败（`download_identity_mismatch`、`commit_tombstone_mismatch`、`invalid_transfer_url`）只清内存去重集，**不调 `_cleanupWork()`** → checkpoint + `.part` 留 7 天，每次重连 `_recover()` 都重跑并再次失败 |
| C16 | P1 | `file_transfer_service.dart:1741-1795 vs :1956-2015` | 下载有 `_downloadChunkWithRetry`（3 次），**上传的 `_http.uploadChunk` 是裸调用无重试**；且下载退避极短（`:1790-1795`，最大约 450 ms，3 次总计 <1.2 s），弱网下必然全败。对照 `_scheduleCompletionRecoveryRetry:1064-1090` 是正确的指数退避 |
| C17 | P1 | `file_transfer_storage.dart:920-946` + `file_transfer_service.dart:2266-2429` | 存储按 `v2/<sha256(logicalIdentity)>/` 分 scope，但 `_recover()` 只扫**当前连接的那一个** identity（`:2270`）。换 Mac / 重装 Bridge 后，旧 scope 下最大 15 GiB 的 `.part`、`.stage`、checkpoint **永远没有任何代码会再扫到**，7 天过期逻辑也扫不到。全仓库无遍历 `v2/*` 的 GC |
| C18 | P2 | `file_transfer_service.dart:924-929, :763` | 过期的"待确认完成"任务被静默丢弃时既不发 `_sendReceiveResult` 也不 `_knownReceiveIds.remove()` → `_handleOffer:763` 后续静默吞掉同 id 重发，Mac 端永远挂在等待确认 |
| C19 | P2 | `file_transfer_service.dart:2340-2345` | ACK 重试 5 次用尽后 checkpoint 永久跳过成孤儿，只有 capability 由无→有或 7 天过期才解锁；期间 `notificationPending` 通知也发不出 |
| C20 | P2 | `file_transfer_service.dart:1727-1734, :1776-1783` | 续租后 `_renewDownloadLease` 返回的新 secret 被丢弃，重试仍用旧 secret 和旧 URL。当前靠 token 恒定侥幸能工作，但代码注释 `:1612-1616` 已承认 origin 会变（Tailscale ↔ LAN ↔ SSH 隧道切换） |
| C21 | P2 | `file_transfer_storage.dart:1121-1139` | `_atomicJson` 的 `.tmp` 在进程被杀时残留，而 `_loadJsonFiles:986` 与容量计数 `:900` 都只看 `.json` → **永不清理** |
| C22 | P2 | `file_transfer_storage.dart:571-580` | `cleanupPickerOrphans()` 无条件删除所有 `ccpocket-picker-*`，`initialize()` 在首帧后异步执行（`main.dart:519`），可能删掉正在写入的 `copy.tmp` |
| C23 | P2 | `file_transfer_service.dart:630-643` | `continuePaused` 新建 `_ReceiveWork`，丢弃旧对象的 `cancelRequest`/`cancelled` → 先取消再继续会重新下载然后 404 |
| C24 | P2 | `file_transfer_service.dart:930-939` | 单飞 `_drain` + 固定优先级 `completionRecovery > receive > uploadRecovery` → Mac 持续推文件时用户上传永远饿死 |
| C25 | P3 | `file_transfer_http.dart:302-313` | 上传进度统计的是"推入 request sink 的字节"而非服务端确认字节；下载失败后 `finally truncate(offset)`（`:205-212`）导致进度明显回跳；`stageExternalFile`（可能 15 GiB 完整拷贝）阶段完全无进度只有 spinner |
| C26 | P3 | `file_transfer_http.dart:455-468` | 每个 chunk 都往同一 work 级 cancellation 的 `_cancelled.future` 挂一个不可移除的 `.then`。15 GiB / 1 MiB ≈ 15000 个常驻闭包 |
| C27 | P3 | `file_transfer_http.dart:53, :322-337` | `authoritativeOffset` 采集了但全仓库**无任何读取点**，`upload_offset_mismatch` 白白走完整 re-prepare |
| C28 | P3 | `file_transfer_service.dart:2648-2651` | `_notify({bool force = false})` 完全忽略 `force`，全文 30+ 处 `force: true` 都是空转 |

---

# D. 常规 bug

| # | 严重度 | 位置 | 问题 |
|---|---|---|---|
| D1 | P0 | `lib/widgets/bubbles/tool_result_bubble.dart:298-300` | build 内调 `generatedImageItemsFromToolResults(...)` 且**不传 `itemCache`**（对照 `chat_message_list.dart:781-785` 传了）。`MemoryImage` 的 `==` 按 bytes 引用比，每次 build 产生新 `Uint8List` ⇒ 新 ImageCache key ⇒ 全量重解码（1024² RGBA = 4 MB / 2048² = 16 MB）。`maximumSizeBytes` 全仓库未设置 |
| D2 | P1 | `lib/widgets/bubbles/image_preview.dart:58-59, :120-121, :168-169` | `'$httpBaseUrl${image.url}'` 拼在 data URL 前 → `http://host:8080data:image/png;base64,...` → `_decodeDataImageUrl` 恒返回 null → data 图必现破图。正确写法见 `generated_image_preview_mapper.dart:105-113`。同源问题在 `message_images_screen.dart:167, :251` |
| D3 | P1 | `file_transfer_sheet.dart:176-179` `:470-472`；`chat_input_with_overlays.dart:669-671`；`session_list_screen.dart:860-861` | `authorizeMutation` 闭包捕获 `BuildContext`，但它在 service 内部经过 iOS 文档选择器（用户交互可达数十秒）+ `adoptPickerCopy` 之后才被调用（`file_transfer_service.dart:484-592`）。期间 sheet 可被下滑关闭，闭包内 `context.read<FileBrowserService>()`（`file_mutation_authorization.dart:16`）会在失效 Element 上抛异常。**闭包内无任何 `context.mounted` 检查** |
| D4 | P1 | `generated_image_preview_mapper.dart:115-125`；`assistant_bubble.dart:485, :745`；`chat_session_cubit.dart:3547`；`draft_service.dart:98-101, :118-121`；`file_peek_sheet.dart:503-511` | 主 isolate 大体积 base64。其中 `assistant_bubble.dart` 的 `Image.memory(uri.data!.contentAsBytes())` 写在 **build 内**；`draft_service.saveImageDraft` 是 **void 同步方法**，`base64Encode + jsonEncode` 全在帧内；`file_peek_sheet._imageBytes()` 被 `_buildImageContent` 从 `build()` 调用，5 MB 图**每次 rebuild 重解一遍**且无缓存 |
| D5 | P1 | `gallery_tile.dart:45-64`、`gallery_image_viewer.dart:295-318`、`message_images_screen.dart:282-286`、`generated_image_chat_group.dart:262-267`、`generated_image_preview_page.dart:181-187`、`image_preview.dart:68, :127`、`user_bubble.dart:173-177`、`file_peek_sheet.dart:771` | 全仓库 `cacheWidth\|cacheHeight\|maximumSizeBytes` **零命中**。iPhone 截图 1290×2796 在 2 列网格里按原图解码 ≈14.4 MB/张。`ExtendedImage.network` 的 `cache: true` 只是磁盘字节缓存，与解码分辨率无关（`extended_image 10.0.1` 支持这些参数）。`generated_image_preview_screen.dart:138` 的 `allowImplicitScrolling: true` 让至少 3 张原图位图常驻 |
| D6 | P2 | `gallery_image_viewer.dart:277-281`；`generated_image_preview_page.dart:78-88` | `CurvedAnimation` 每次动画新建且从不 dispose，构造时 `parent.addStatusListener` 无法自动移除 → 反复双击缩放/拖拽结束（`:124` 也调 `_animateTo`）导致 listener 链线性增长 |
| D7 | P2 | `artifact_preview_screen.dart:276-281` | `onProgress` 回调**每个网络 chunk 都 setState**，无节流。64 MiB 下载会产生每秒数千次 setState |
| D8 | P2 | `gallery_image_viewer.dart:100-136` | 分享路径 `response.bodyBytes` 整图读内存无上限；`finally` 里 `tempFile?.delete().ignore()` 在 share 返回后立即删，Android 接收方可能仍在延迟读该 URI；`catch (_)` 吞掉全部异常无日志。另 `chat_input_with_overlays.dart:817` 循环 `readAsBytes` 最多 5 张；`draft_service.dart:13` 的 `_imageCache` 除显式 delete 外无淘汰 |
| D9 | P2 | `gallery_content.dart:114-123`；`message_images_screen.dart:246-264`；`file_transfer_sheet.dart:97-163` | 列表 key 缺失（`gallery_tile.dart:31` 的 ValueKey 挂在内部 GestureDetector 上，对 Sliver element 复用无效）；`file_transfer_sheet` 用的是**非懒加载** `ListView(children: [...])`，最多 200 条一次性全建。另 `gallery_tile.dart:38-39` 的 `Hero(tag:'gallery_${image.id}')` 在 `GalleryImageViewer` 中无对应目标，同 id 出现在两棵子树时会触发 "multiple heroes share the same tag" 断言 |
| D10 | P2 | `gallery_screen.dart:49-51` | `state.isNotEmpty ? state : bridge.galleryImages` —— 请求发出到响应到达的窗口内展示上一个会话的图，标题计数也错。建议用 `null` 表示"未加载" |
| D11 | P2 | `file_peek_sheet.dart:560-634` | `_buildCodeContent` 在 build 内做 split + 语法高亮 + span 重组，无 memoization（见 A2） |
| D12 | P3 | `generated_image_preview_mapper.dart:47-52` | 缓存是 FIFO 不是 LRU，容量硬编码 64；`cacheKey`(`:33`) 包含整段 `message.content`，哈希代价与内容长度成正比 |
| D13 | P3 | `generated_image_chat_group.dart:170-174` | `didChangeDependencies` 无条件 `_resolveAspectRatio()` 触发完整解码，即使 `initState` 已通过廉价的 `_pngAspectRatio()`(`:239-250`) 拿到宽高比；主题/键盘/MediaQuery 变化都会重来 |
| D14 | P3 | `gallery_image_viewer.dart:36, :86-90` | 删除后只改 hook 的 `currentPage`，没有 `pageController.jumpToPage`；`imageList` 是一次性快照，外部增删不反映到打开中的查看器 |
| D15 | P3 | `file_browser_screen.dart:71-91` | `_scheduleServiceSync` 对每次 service 通知都 `setState(() {})` 全量重建文件列表 |

> 已复核为**干净**的部分（无需改动）：`message_images_screen.dart:42/51/104` 的 StreamSubscription、`gallery_image_viewer.dart:246-250` 的 AnimationController + TransformationController、`generated_image_preview_page.dart:48-53`、`generated_image_preview_screen.dart:55-58`、`providers/stream_cubit.dart:15-18`、`FileTransferService.dispose():2653-2669` 均正确 cancel/dispose；`gallery`/`message_images`/`generated_image_preview` 三个目录内未发现真正的跨 await context 违规（`gallery_content.dart:73,77`、`gallery_image_viewer.dart:72,76,108,127` 都有 `context.mounted` 守卫）；文件传输链路全程流式（`file_transfer_http.dart:172-181` / `:303-315`、`file_transfer_storage.dart:441-450`）。

---

# 建议的修复顺序

1. **先确认 build 来源**（0 改动）：核对真机 IPA 的 commit 与运行中 Bridge 的版本是否包含 `34e97866`。若不包含，当前所有"预览失败"报告都不构成对本分支源码的有效反馈。
2. **A7 + A1 + B1**：`sourceKind()` 对 html/json 强制 `kind:"preview"`，或抽出统一 `PreviewRouter` 让四个入口共用。这一条同时解决 JSON 与 HTML 两类主诉。
3. **A4 + A12**：把 Quick Look 回退条件从"异常类型"改成"是否已成功呈现"，并给 `activeSession` 加兜底复位。
4. **B4 + B3**：修 web 构建的直接导入，把平台闸门下沉进 `ArtifactPreviewScreen`（macOS 当前会红屏）。
5. **C13 + C14**：队列锁死 + ticket 泄漏组合会让拖拽附件永久卡 `uploading` 并阻断发送，是最易被用户命中的可见故障。
6. **C1 + C2**：两条会造成"整个上传子系统永久不可用"的服务端故障。
7. **D1 + D5 + D2**：改动量很小，直接消除 OOM 主因与一类必现破图。

---

**验收取证清单（真机必须采集的字段）**：`filename` / `extname` / 客户端 `mimeType` / `sizeBytes` / Bridge `previewKind` / Bridge artifact `kind`(source|preview) / `shouldTryQuickLookForArtifact` 返回值 / Swift `previewFile` 的 FlutterError.code / `QLPreviewController.canPreview` 布尔值 / `previewControllerDidDismiss` 是否触发 / WebView `onWebResourceError.description` 与 `onHttpError.response.statusCode` / artifact token 的 `expiresAt` 与点击时刻差值。

**审查过程中未修改任何文件。**
