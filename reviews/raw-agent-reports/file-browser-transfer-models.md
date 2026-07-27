I'll read both files completely, in segments.
Now let me check how decode errors are handled and how these models are consumed.
两个文件已用 Read 全量读完（file_browser 1–1472、file_transfer 1–687），并交叉核对了消费端 `protocol_host.dart` / `bridge_service.dart` / `file_browser_service.dart` / `file_browser_screen.dart` 与 Bridge 端 `packages/bridge/src/file-browser-manager.ts`。

结论先行：这两个文件采用的是「严格白名单 + 任何偏差立即 FormatException」的解析风格。裸 `as` 强转基本没有（只有 1296 行 `value as String`、104 行 `requestId as String`，都在类型守卫之后，安全），所以**不会有 TypeError 崩溃**；但代价是**几乎没有任何向前兼容/能力降级能力**——服务端任何一点演进都会让整条消息不可解码，且失败路径会让 in-flight 请求悬挂到超时。以下按严重度列出。

---

## P0
无。（没有会导致 crash 的裸强转、没有空安全 `!` 误用在本文件内；`!` 断言在调用侧 file_browser_service.dart:367-372，但被本文件的必填校验兜住了，见 P1-4。）

---

## P1

**[P1] [/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/apps/mobile/lib/models/local_features/slots/file_browser_protocol_slot.dart:166-171 (+258)] 枚举无 fallback，未知 kind 直接炸掉整个目录列表**
- 触发场景：Bridge 未来支持 fifo/socket/block device，或任何非四值 `kind`。
- 证据：
  ```dart
  static FileBrowserNodeKind parse(Object? value) {
    for (final kind in values) { if (value == kind.wireValue) return kind; }
    throw const FormatException('file browser node kind is invalid');
  }
  ```
  该异常从 `FileBrowserNode.fromJson` 冒泡到 `FileBrowserListResultMessage.fromJson`，导致**整页 entries 全部丢失**，而不是丢掉一个条目。
- 讽刺点：枚举本身已经定义了 `other('other')` 这个天然兜底值，却没被用作 fallback。
- 建议：`parse` 未知值返回 `FileBrowserNodeKind.other`（保留 `parseStrict` 供出站使用）；同时 list 解析对单条 entry 失败采用「跳过 + 计数上报」而非整页失败。

**[P1] [file_browser_protocol_slot.dart:1251-1260] 与 [file_transfer_protocol_slot.dart:583-592] 未知字段一律拒绝 = 零向前兼容**
- 触发场景：新版 Bridge 给 `file_browser_list_result_v1` 加一个 `totalCount` 字段，旧版 App 的文件浏览器**整体失效**（不是降级，是完全不可用），且用户看到的是「请求超时」。
- 证据：
  ```dart
  for (final key in json.keys) {
    if (!allowed.contains(key)) {
      throw FormatException('file browser message has unknown field $key');
    }
  }
  ```
- 建议：未知字段改为**忽略并 debug 日志**（保留严格模式给单测用）；真正需要严格性的场景（防降级攻击）应通过 capability 协商而非字段白名单实现。协议本身已带 `_v1/_v2/_v3` 版本号，破坏性变更靠版本号即可，字段级严格白名单是过度约束。

**[P1] [file_browser_protocol_slot.dart:481-490] 服务端广告的能力上限超过客户端常量 → 整条 roots 结果被拒 → 文件浏览器彻底不可用**
- 触发场景：Bridge 把 `FILE_BROWSER_DOWNLOAD_MAX_BYTES` 从 15GB 提到 32GB（已核对 bridge 侧 file-browser-manager.ts:60-61 直接把常量回传），mobile 端 `maxFileBrowserDownloadBytes` 仍是 15GB。
- 证据：
  ```dart
  final downloadMaxBytes = _fileBrowserRequiredSafeInteger(
    json['downloadMaxBytes'], 'downloadMaxBytes', maximum: maxFileBrowserDownloadBytes);
  ```
  这是**服务端能力声明**，不是不可信输入的安全边界；把它当作硬校验会把「服务端更强」误判为「协议非法」。
- 同类：467 行 `rawRoots.length > maxFileBrowserRoots` —— 用户配置了 33 个 root 就整个列表失败；800-804 行 preview `sizeBytes` 同理。
- 建议：能力上限改为 `min(serverValue, localCap)` 钳位；roots 超限改为截断 + 提示，而非抛异常。

**[P1] [file_browser_protocol_slot.dart:424-442 vs 494-510] 模型声明「全可空可选」，fromJson 却「全必填」，没有能力降级路径**
- 触发场景：任意旧版/精简 Bridge 不返回 `downloadAvailable`（该字段本身就是能力降级信号）→ 整条 roots 失败 → 连只读浏览都用不了。
- 证据：字段声明 `final bool? downloadAvailable;` 且构造函数默认 null，但
  ```dart
  downloadAvailable: _fileBrowserRequiredBool(json['downloadAvailable'], 'downloadAvailable'),
  ```
  调用侧 file_browser_service.dart:367-372 又用 `result.bridgeInstanceId!` / `result.previewMaxBytes!` / `result.downloadAvailable!` 一串强断言，等于把「模型允许 null」和「运行时必须非 null」两个矛盾契约用异常粘在一起。
- 建议：能力型字段缺失时给安全默认值（`downloadAvailable=false`、`previewMaxBytes=本地默认`），仅对身份型字段（`requestId`）保持必填；同时消除调用侧的 `!`（把这些字段做成非空 + 默认值）。

**[P1] [file_browser_protocol_slot.dart:140-154] 解码失败时 in-flight 请求无法被 fail，只能等超时**
- 触发场景：上面任一 FormatException 发生时，`protocol_host.dart:129-142` 把它抛出 → `bridge_service.dart:1872-1876` catch 成通用 `ErrorMessage(message: 'Parse error: FormatException: file browser message has unknown field x')`。
- 证据：
  ```dart
  final message = error.message.toLowerCase();
  return message.contains(request.requestType.toLowerCase()) && RegExp(...).hasMatch(message);
  ```
  `'Parse error: ...unknown field x'` 里**不含** `file_browser_list_v1`，匹配失败 → 请求不会被结掉 → 用户界面转圈直到 file_browser_service.dart:798 的超时定时器触发。
- 建议：为「本地解码失败」引入显式失败通道（把 requestId 从原始 json 里尽力提取出来并 fail 对应 pending request），不要依赖错误文案子串匹配。

---

## P2

**[P2] [file_browser_protocol_slot.dart:259-261, 1272-1279, 1299-1306, 1393-1396, 1407-1413] 显式 `null` 与「字段缺失」语义不等价，后端发 `"mimeType": null` 会炸**
- 触发场景：任何用 `JSON.stringify` 之外方式（Go/Python/Rust、或 TS 里显式写 `mimeType: null`）实现的 Bridge。当前 TS Bridge 用条件展开 `...(mimeType === undefined ? {} : { mimeType })` 恰好规避了，属于**运气而非契约**。
- 证据：
  ```dart
  final targetKind = json.containsKey('targetKind')
      ? FileBrowserNodeKind.parse(json['targetKind'])   // null -> throw
      : null;
  ...
  String? _fileBrowserOptionalText(Map json, String field, int maxLength) {
    if (!json.containsKey(field)) return null;          // 显式 null 走不到这里
    return _fileBrowserRequiredText(json[field], field, maxLength);
  }
  ```
- 且与同目录 file_transfer_protocol_slot.dart:594-597 的语义**不一致**（那边是 `if (value == null) return null;`），同一功能域两套 optional 语义。
- 建议：统一成 `json[field] == null → null`；确需区分「缺失 vs 显式 null」的地方（如 `FileBrowserStatResultItem` 的 node 存在性判定，646/659 行）单独显式处理。

**[P2] [file_browser_protocol_slot.dart:1382-1391] 与 [file_transfer_protocol_slot.dart:615-627] `is! int` 严格数值校验：JSON double 与 web/native 行为分裂**
- 触发场景：(a) 后端把 `sizeBytes` 序列化成 `1.0` 或指数形式 `1e10`（JS 对超大数 `JSON.stringify` 会输出 `1e+21`），Dart VM 解析为 `double` → 直接 FormatException；(b) 同一 payload 在 dart2js/web 上 `1.0 is int` 为 **true**、native 上为 **false**，导致「模拟器/web 测试通过、真机失败」这类难查问题。
- 证据：
  ```dart
  if (value is! int || value < 0 || value > maximum) { throw FormatException(...); }
  ```
- 建议：改为 `value is num` + `value == value.truncate()` + `value.toInt()`（并保留范围校验）。同样地，本文件没有任何 `as double`/浮点字段，暂无 `as double` 遇整数的问题，但如未来加入 progress/ratio 字段务必用 `(v as num).toDouble()`。

**[P2] [file_browser_protocol_slot.dart:1398-1405] vs [file_transfer_protocol_slot.dart:669-675] 两个文件的时间戳契约不一致，且 file_transfer 侧不要求时区**
- 触发场景：Bridge 返回 `"2026-07-26T10:00:00"`（无时区）或 `"+00:00"` 偏移。
- 证据：
  ```dart
  // file_browser：强制 UTC，且长度 ≤32
  final text = _fileBrowserRequiredText(value, field, 32);
  if (!text.endsWith('Z') || parsed == null || !parsed.isUtc) { throw ... }

  // file_transfer：只要能 parse 就放行，不校验时区
  final timestamp = _fileTransferRequiredText(value, 'expiresAt', 128);
  if (DateTime.tryParse(timestamp) == null) { throw ... }
  ```
  后者的 `expiresAt` 字符串最终流向 file_transfer_http.dart / file_transfer_storage.dart 的 `DateTime` 比较；无时区串会被 `DateTime.parse` 当作**本地时间**，导致过期判断整体偏移一个时区（东八区可提前/延后 8 小时判定 token 过期）。
- 另外 `+00:00` 形式（Python `datetime.isoformat()`、Go `time.RFC3339` 常见输出）在 file_browser 侧被硬拒。
- 建议：抽一个共享的 `_parseUtcTimestamp`：接受 `Z` 与数字偏移，内部 `.toUtc()` 归一；两个文件共用。

**[P2] [file_browser_protocol_slot.dart:218, 740, 904 / file_transfer_protocol_slot.dart:207, 271] 时间戳以 `String` 穿过模型层，往返与时区处理下放给每个消费者**
- 证据：`final String? modifiedAt;` / `final String expiresAt;`，模型层校验完格式后又原样存字符串。
- 后果：每个消费点各自 `DateTime.tryParse`（file_browser_screen.dart:1075 处理得对，用了 `toLocal()`；但这是逐点约定，没有类型保证），任何一处忘了 `toUtc()/toLocal()` 就是静默的时区 bug。
- 建议：模型层直接暴露 `DateTime`（UTC 归一），需要原样回传时另存 raw 字符串。

**[P2] [file_browser_protocol_slot.dart:262-269] symlink 元数据的硬一致性断言过紧**
- 触发场景：Bridge 若演进为「`kind` 报 target 类型 + `isSymlink` 标志位」（这是很常见的重构方向，当前 bridge file-browser-manager.ts:1045-1049 恰好是 sourceKind），整个目录立刻不可解码。
- 证据：
  ```dart
  if (isSymlink != (kind == FileBrowserNodeKind.symlink) ||
      (targetKind != null && kind != FileBrowserNodeKind.symlink) ||
      targetKind == FileBrowserNodeKind.symlink) {
    throw const FormatException('file browser symlink metadata is inconsistent');
  }
  ```
- 建议：交叉字段的不一致降级为「以 `isSymlink` 为准 + 日志」，不要让展示型元数据不一致阻断整个列表。

**[P2] [file_browser_protocol_slot.dart:174-301, 423-993 / file_transfer_protocol_slot.dart:50-436] 所有 model 均未实现 `==` / `hashCode`**
- 触发场景：`FileBrowserRoot`、`FileBrowserNode`、`FileBrowserStatResultItem` 及全部 ResultMessage 都用默认引用相等。它们被存进 service 状态（file_browser_service.dart 的 `_roots = List.unmodifiable(result.roots)`）并通过 ChangeNotifier 推给 UI；**刷新同一目录得到内容完全相同但引用全新的 Node 列表**，任何基于值相等的 diff / `listEquals` / `Set` 去重 / `AnimatedList` key 比对都会判定「全变了」→ 整列表重建、滚动位置与动画抖动，且无法做「内容未变则跳过 setState」的优化。
- 注意这里**不是**「== 用 List/Map 引用比较导致永不相等」的经典坑（因为压根没写 ==），但后果相同：永远不等。
- 建议：给 `FileBrowserRoot` / `FileBrowserNode` 实现值相等（Node 有天然的 `nodeRevision`，可用 `rootId+relativePath+nodeRevision` 做廉价相等判定）；若给消息类实现 `==`，务必对 `roots`/`entries`/`items` 用 `listEquals` 而不是引用比较。

**[P2] [file_browser_protocol_slot.dart:941-991] 认证状态机无降级分支**
- 触发场景：`state`/`enrolled` 事件强制同时具备 `passwordConfigured` 与 `biometricEnrolled` 两个 bool；`challenge` 事件强制**不得**出现 state 字段。任一端新增认证方式（如 passkey）或返回部分状态，整条认证响应失败 → 用户无法进入文件修改授权流程（且按 P1-5，会挂到超时）。
- 证据：
  ```dart
  if (json.containsKey('passwordConfigured') || json.containsKey('biometricEnrolled')) {
    throw const FormatException('file mutation auth challenge contains state fields');
  }
  ```
- 建议：缺失的能力位默认 `false`（安全方向的默认值），多余字段忽略。

**[P2] [file_transfer_protocol_slot.dart:641-655] token / etag 格式硬编码长度**
- 触发场景：服务端把 token 从 32 字节随机（base64url 43 字符）换成别的长度，或 etag 加上 `W/` 弱校验前缀 / 换成 sha256 摘要。
- 证据：
  ```dart
  final text = _fileTransferRequiredText(value, field, 43);
  if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(text)) { throw ... }
  ...
  if (!RegExp(r'^"[A-Za-z0-9_-]{32}"$').hasMatch(text)) { throw ... }
  ```
- 后果：上传/下载全线中断，且客户端无法感知原因。
- 建议：放宽为字符集 + 合理长度区间（如 16–256），把精确长度交给服务端；etag 只做「非空、有界、无控制字符」校验。

---

## P3

**[P3] [file_transfer_protocol_slot.dart:94-100 与 567] cancel direction 出入站编码不对称**
- 证据：入站按字面量 `'upload'/'download'` switch，出站用 `direction.name`。枚举一旦重命名（Dart 重构工具会静默改 `.name` 的结果），线协议即被破坏且编译期无感知。对比同仓的 `FileBrowserNodeKind` / `FileMutationAuthEvent` 都有显式 `wireValue`。
- 建议：给 `FileTransferCancelDirection` 补 `wireValue` 并双向使用。

**[P3] [file_browser_protocol_slot.dart:431-442, 522-532, 677-683] 公开构造函数直接持有外部集合，未 copy/unmodifiable**
- 证据：`this.roots = const []` / `this.entries = const []` / `this.items = const []` 直接赋值。只有 `fromJson` 路径做了 `List.unmodifiable(...)`（504/596/727）。测试、mock 或任何手工构造的路径传入可变 List 后，外部 mutate 会改到消息内部状态。
- 建议：构造函数体内统一 `List.unmodifiable(...)`（或用 `UnmodifiableListView` 字段类型）。

**[P3] [file_browser_protocol_slot.dart:145-153] 错误归因用文案子串 + 正则，脆弱且可能误伤**
- 证据：
  ```dart
  if (error.errorCode == 'unsupported_capability' &&
      error.message == 'File browser capability was not negotiated') { return true; }
  ```
  英文原文精确比对，服务端改一个字或做本地化即失效；下面的 `message.contains(requestType)` 反过来可能把一条恰好提到该 requestType 且含 "unknown" 的无关错误误判为本请求失败，提前结掉 pending。
- 建议：只依赖 `errorCode` 与结构化的 `requestId` 字段做归因，文案匹配仅作最后兜底。

**[P3] [file_browser_protocol_slot.dart:1262-1270] `trim().isEmpty` 校验但返回未 trim 的原值**
- 证据：`if (value is! String || value.trim().isEmpty || ...) throw; return value;`
- 与 `_fileBrowserIsBoundedIdentifier`（1281-1286，要求 `value.trim() == value`）语义不一致：identifier 类字段禁止首尾空白，text 类字段（`label`、`displayPath`、`filename`、`mimeType`）却允许。带尾空格的 filename 流到下载保存路径可能在不同平台产生不一致行为。
- 建议：要么统一 trim 后返回，要么统一拒绝首尾空白。

**[P3] [file_browser_protocol_slot.dart:575-578, 718-723 + 1342-1369] 唯一性判定用精确字符串，未做 Unicode 归一**
- 证据：`entries.map((e) => e.relativePath).toSet().length != entries.length` 判重；路径校验不做 NFC/NFD 归一。
- 触发场景：macOS（APFS 返回 NFD）与其他来源（NFC）混合时，同一文件的两种表示既不会被判为重复，也无法与本地缓存 key 命中。
- 建议：判重与缓存 key 统一走 `unorm`/`String.normalize` 等价的归一化形式。

**[P3] [file_browser_protocol_slot.dart:621-671] stat 项要求 `node.relativePath` 与外层 `relativePath` 严格相等**
- 证据：`if (node.relativePath != relativePath) throw const FormatException('file browser stat node path mismatch');`
- 触发场景：服务端做路径规范化（去尾斜杠、解析 `.`、大小写归一）后返回规范化路径 → 整批 stat 失败。
- 建议：比较前双方归一化，或降级为以 node 内值为准。

**[P3] [file_browser_protocol_slot.dart:333-347 与 file_transfer_protocol_slot.dart:456-458] 上传大小上限常量重复定义、语义错配**
- 证据：`FileMutationOperation.toJson` 用 `maxFileBrowserDownloadBytes` 校验**上传**大小，而 `prepareFileTransferUpload` 用 `maxFileTransferBytes`。二者当前同为 15GB，属巧合；分处两个文件，任一处调整即产生「授权挑战通过但上传被拒」的不一致。
- 建议：合并为单一 `maxFileTransferBytes` 常量并跨文件复用。

**[P3] [file_transfer_protocol_slot.dart:36-39 + 368-380] v2/v3 版本判定依赖 `json['type']` 字符串，降级路径静默丢字段**
- 证据：`final includesSavedPath = json['type'] == 'file_transfer_upload_result_v3';` —— 若 type 出现别名/大小写差异，会静默走 v2 分支把 `savedPath` 置 null（同时因为 exact-keys 白名单不含 savedPath 而抛异常，行为取决于哪条先触发）。
- 建议：把版本判定提到 slot 的 `tryDecode` 里显式传参（`version: 3`），而不是在 fromJson 内二次字符串比较。

---

## 关于 copyWith
两个文件**完全没有 `copyWith`**，因此不存在「`copyWith(x: null)` 无法清空字段」的经典 null 语义坑。但这也意味着状态层无法增量更新消息对象——`file_browser_service.dart` 因此改用一堆可变私有字段（`_previewMaxBytes` / `_downloadAvailable` / `_roots`）来承载状态，模型层的不可变性优势被抵消。若后续要给 `FileBrowserNode` 加 `copyWith`（例如本地乐观更新重命名后的 name），请一开始就用 sentinel 对象或 `ValueGetter<T?>` 参数区分「不改」与「设为 null」，不要用 `T?` 参数 + `??` 的写法。

## 总体建议排序
1. 先修 P1-2 / P1-3 / P1-4（把「未知字段拒绝 + 能力上限硬校验 + 可选字段必填」三条改为宽容降级）——这三条决定了 App 与 Bridge 能否跨版本共存。
2. 再修 P1-1（枚举 fallback 到 `other`）和 P1-5（解码失败要能 fail 掉对应 pending request，而不是靠错误文案匹配）。
3. 然后统一两个文件的 optional 语义（P2 显式 null）、数值转换（`num`）与时间戳契约（UTC 归一 + 返回 `DateTime`）。
4. 最后补 `==`/`hashCode` 与构造函数集合防御性拷贝。
