I'll read the file in chunks.
## 复核范围与爆炸半径基线

**顶层 dispatch 保护**：`ServerMessage.fromJson`（`messages.dart:953`）**本身没有 try/catch**。唯一的保护在调用方 `services/bridge_service.dart:1431`（`try {` ）… `1872`（`} catch (e, st)`），catch 后把整帧替换为 `ErrorMessage(message: 'Parse error: $e')` 并推入 `_messageController`。

由此得到三档爆炸半径（后文用「半径」标注）：

| 半径 | 含义 |
|---|---|
| **R1 单帧** | 抛异常 → 该 WebSocket 帧被整体丢弃，用户看到一条 "Parse error" 红色气泡 |
| **R2 整批** | 抛异常发生在 `history` / `session_list` / `recent_sessions` / `history_page` / `usage_result` 等聚合消息的元素解析里 → **整个同步响应作废**（一个坏元素 = 整张会话列表/整段历史消失） |
| **R3 逃逸 try/catch** | 使用 `List.cast<String>()` 的惰性视图，TypeError 在 **Widget build 期**才抛 → 绕过 bridge_service 的 catch → **红屏 / 该页面永久不可用** |

其他 `ServerMessage.fromJson` 入口保护情况（已逐一核实）：`conversation_mirror_service.dart:1785/1825` 有 try/catch（良好）、`2161` 有 try/catch；`prompt_history_service.dart:487` 在 `.map()` 里裸调用（stream 转换中抛出 → 该 Future 以错误结束，有外层 try）；`subagents_protocol_slot.dart:196`、`conversation_content_protocol_slot.dart:97`、`codex_desktop_continuity_protocol_slot.dart:205` **均为裸调用**，依赖各自 slot 的上层保护。

---

## A. 反序列化健壮性

### A-0 【P0】`List.cast<String>()` 惰性检查逃逸 try/catch

- **位置**：`messages.dart:1371`、`1376`、`1338`、`1411`、`1430`、`1603`、`1605`
- **证据**：
  ```dart
  1371:  files: (json['files'] as List).cast<String>(),
  1376:  projects: (json['projects'] as List).cast<String>(),
  1603:  branches: (json['branches'] as List?)?.cast<String>() ?? const [],
  1605:  checkedOutBranches: (json['checkedOutBranches'] as List?)?.cast<String>() ?? const [],
  1338:  historySummary: (json['historySummary'] as List?)?.cast<String>() ?? const [],
  1411:  precedingToolUseIds: (json['precedingToolUseIds'] as List?)?.cast<String>() ?? const [],
  1430:  filesChanged: (json['filesChanged'] as List?)?.cast<String>(),
  ```
- **问题**：Dart 的 `List.cast<T>()` 返回 `CastList` 惰性视图，元素类型检查发生在**读取时**而非解析时。异常在 build/渲染阶段抛出，`bridge_service.dart:1431` 的 try/catch 完全捕获不到。
- **触发**：未来 Bridge 把 `files` 升级为 `[{path, size}]` 对象数组（典型的加法式演进），或 `branches` 里混入一个 `null`。
- **半径**：R3 — 文件浏览器 / Git 分支面板红屏，非 "Parse error" 气泡。
- **修复方向**：统一改为 `.whereType<String>().toList(growable: false)`。

### A-1 【P0】`session_list` 中单个坏 `SessionInfo` 摧毁整张会话列表

- **位置**：`messages.dart:1232-1234` → `SessionInfo.fromJson` `messages.dart:4764`、`4766`、`4820-4822`
- **证据**：
  ```dart
  1232:  sessions: (json['sessions'] as List)
  1233:      .map((s) => SessionInfo.fromJson(s as Map<String, dynamic>))
  ...
  4764:  id: json['id'] as String,
  4766:  projectPath: json['projectPath'] as String,
  4820:  toolUseId: permJson['toolUseId'] as String,
  4821:  toolName: permJson['toolName'] as String,
  4822:  input: Map<String, dynamic>.from(permJson['input'] as Map),
  ```
- **问题**：`id` / `projectPath` / pendingPermission 三元组全为裸转换，无 `?` 无兜底。
- **触发**：Bridge 新增一种「无 projectPath 的临时会话」（如纯 side-chat 或远端会话），或 `pendingPermission` 在新版里改为 `{toolUseId, tool: {...}}`。
- **半径**：**R2** — 抛出后整个 `session_list` 帧作废，`bridge_service.dart:1478` 的 `SessionListMessage` 分支永不执行，`_hasAuthoritativeSessionListForCurrentConnection` 永远为 false，**用户主页一个会话都看不到，且重连也无法恢复**。
- **修复方向**：`SessionInfo.fromJson` 返回 `SessionInfo?`，`id`/`projectPath` 缺失时返回 null；列表侧用 `.map(...).whereType<SessionInfo>()` 逐元素跳过。

### A-2 【P0】`history_page` 裸 `as int` → 分页 completer 永不完成

- **位置**：`messages.dart:1148-1157`
- **证据**：
  ```dart
  1148:  requestId: json['requestId'] as String,
  1149:  sessionId: json['sessionId'] as String,
  1150:  beforeSeq: json['beforeSeq'] as int,
  1151:  nextBeforeSeq: json['nextBeforeSeq'] as int,
  1155:  entries: (json['messages'] as List)
  ```
- **问题**：`beforeSeq` / `nextBeforeSeq` 无 `?` 无默认值。而 `history_delta`(1176-1177)、`history_snapshot`(1187-1188) 同名字段却写成 `as int? ?? 0` —— 同协议同语义字段，三处写法不一致。
- **触发**：Bridge 在「已到头」时省略 `nextBeforeSeq`；或改用游标后不再发 `beforeSeq`（`nextBeforeCursor` 已存在于 1152，说明正在往游标迁移，数字字段迟早会被省略）。
- **半径**：R2+ — 抛出后 `bridge_service.dart:1436 _completeRemoteHistoryPage(msg)` 不会被调用，**分页请求的 Completer 永远悬挂，历史"加载更多"永久转圈**。
- **修复方向**：`as int? ?? 0`，并让 `_completeRemoteHistoryPage` 在 catch 分支也能按 requestId 失败兜底。

### A-3 【P1】`error` 帧自身的 `message` 是裸 `as String`

- **位置**：`messages.dart:1115`
- **证据**：
  ```dart
  1112:  'error' =>
  1113:    _guardianReviewFromErrorJson(json) ??
  1114:    ErrorMessage(
  1115:      message: json['message'] as String,
  ```
- **问题**：Bridge 发一条只有 `errorCode` 没有 `message` 的结构化错误（这是错误协议最自然的演进方向）→ TypeError → 被 catch 成 `Parse error: type 'Null' is not a subtype of 'String'`。真实错误码丢失，`chat_message_handler.dart:365` 的 `unsupported_message` 分支永远匹配不到，Graceful Degradation 机制整体失效。
- **半径**：R1，但连带摧毁全部降级逻辑。
- **修复方向**：`json['message'] as String? ?? json['errorCode'] as String? ?? 'Unknown error'`。

### A-4 【P1】流式增量文本裸转换

- **位置**：`messages.dart:1229`、`1230`
- **证据**：
  ```dart
  1229:  'stream_delta' => StreamDeltaMessage(text: json['text'] as String),
  1230:  'thinking_delta' => ThinkingDeltaMessage(text: json['text'] as String),
  ```
- **触发**：Bridge 发送一个只带元数据的 delta（如 `{type:'stream_delta', index:3}`）用于分段标记。
- **半径**：R1，但流式场景下每帧都可能命中 → 屏幕被 "Parse error" 气泡刷屏。
- **修复**：`as String? ?? ''`，并在为空时直接忽略该帧。

### A-5 【P1】`status` 帧裸转换 + `ProcessStatus.fromString` 需要非空

- **位置**：`messages.dart:1135`（另见 F-1）
- **证据**：`status: ProcessStatus.fromString(json['status'] as String),`
- **对比**：同文件 `1181-1183`、`1192-1194` 里对同一字段做了 `json['status'] != null ? ... : null` 的空检查 —— 三处写法不一致。
- **修复**：`fromString(String? value)` + `1135` 传 `json['status'] as String?`。

### A-6 【P1】聚合消息元素级裸转换（一坏全毁清单）

| 行 | 代码 | 半径 |
|---|---|---|
| `1139-1141` | `(json['messages'] as List).map((m) => ServerMessage.fromJson(m as Map<String,dynamic>))` | R2：**一条坏历史消息 → 整段会话历史空白** |
| `1178-1180` / `1189-1191` | 同上（history_delta / history_snapshot） | R2 |
| `1285-1287` | `(json['sessions'] as List).map((s) => RecentSession.fromJson(...))` + `4402: sessionId: json['sessionId'] as String` | R2：整个 recent 列表消失 |
| `1306-1308` | `(json['messages'] as List).map(PastMessage.fromJson)` | R2 |
| `1311-1313` / `1316` | GalleryImage：`681-689` 的 `id/url/mimeType/projectPath/projectName/addedAt` 全裸 | R2：一张坏图 → 整个图库空 |
| `1319-1321` | WindowInfo | R2 |
| `1400-1402` | WorktreeInfo：`650-652` 三个裸 `as String` | R2 |
| `1452-1454` | UsageInfo → `737: (json['utilization'] as num).toDouble()`、`738: json['resetsAt'] as String`、`760: json['provider'] as String` | R2：Bridge 未来加一个 `{provider:'x', error:'...'}` 的窗口 → **整个额度面板不可用** |
| `1457-1459` | RecordingInfo | R2 |
| `1607-1613` | `GitBranchRemoteStatus.fromJson(Map<String,dynamic>.from(value as Map))` | R2 |
| `1082-1084` / `1468-1470` / `1422-1424` | `ImageRef.fromJson`（`626-628` 三裸）/ `(e as Map<String,dynamic>)['url']` | R2 |

**统一修复方向**：为聚合消息引入 `_parseArtifactRefs`（`791-798`）已经示范的模式 —— `whereType<Map>()` + 逐元素 try/catch + `where(isValid)` 过滤。目前只有 artifacts / historyToolDetailGaps / archivedSessions 用了这个模式，其余 20+ 处没用。

### A-7 【P2】其余单帧裸转换

`1061`（assistant.message）、`1078`（toolUseId）、`1122-1123`（session_link requestId/sourceSessionId）、`1224`（permission input）、`1227`（permission_resolved toolUseId）、`1358`（file_content filePath）、`1391-1392`（diff_image filePath/version）、`1406`（worktreePath）、`1409`（tool_use_summary summary）、`1333`（debug session）、`32-37`（AssistantContent type/id/name/input）、`84`（AssistantMessage content）、`171-174`（CodexGoal threadId/objective/status）。半径均为 R1。

### A-8 【P2】三种「字符串列表」写法并存，行为完全不同

- **位置**：`messages.dart:1008/1012/1022/1237/1240/1251/1271`（`.map((e) => e as String)`，抛出）vs `1032/1246/1257/1265/1280`（`.whereType<String>()`，跳过）vs A-0 的 `.cast<String>()`（延迟抛出）
- **证据**：
  ```dart
  1031:  plugins: (json['plugins'] as List?)?.whereType<String>().toList() ?? const [],
  1011:  skills: (json['skills'] as List?)?.map((e) => e as String).toList() ?? const [],
  ```
  `slashCommands` / `skills` / `apps` 会因一个 null 元素炸掉整条 `system` 帧（=会话初始化失败），而紧邻的 `plugins` 不会。
- **修复**：全部统一为 `whereType<String>()`。

### A-9 严格键白名单 / 静默截断

- **`messages.dart:1163-1172`**：`history_tool_details` 用 `.take(8)` 硬截断。【P3】未来 Bridge 一次返回 20 条工具详情时静默丢 12 条，用户看到永久的空 gap。
- **`conversation_mirror_service.dart:1815-1830`**：`const {'user_input','assistant','tool_result'}` 类型白名单 —— **这是正确实现**（保留存储、只跳过渲染、打日志），可作为其他地方的参考模板。
- **`conversation_content_protocol_slot.dart:97-104`**：`throw const FormatException('Conversation content message must be a map.')`【P2】未来把 message 改成数组包裹即整体失败。
- 未发现"遇到未知 key 就 throw"的白名单。

---

## B. 时间 / 时区

### B-1 【P1】无 Z/偏移量的 ISO 串被解释为**手机本地时间**

- **位置**：`messages.dart:929`、`937-939`、`941`、`971`、`980`、`743`、`4229`
- **证据**：
  ```dart
  929:  final receivedAt = DateTime.tryParse(json['receivedAt'] as String? ?? '');
  937:  final sourceTimestamp = DateTime.tryParse(json['sourceTimestamp'] as String? ?? '');
  941:      ? DateTime.tryParse(json['timestamp'] as String? ?? '')
  743:  DateTime? get resetsAtDateTime => DateTime.tryParse(resetsAt);
  4229:  DateTime? get modifiedDate => DateTime.tryParse(modified);
  ```
- **问题**：`DateTime.tryParse('2026-07-25T10:00:00')`（无 Z）返回 `isUtc == false` 的本地时间。Bridge 跑在东京的 Mac、手机在上海 → 全部时间戳偏 1 小时；跨时区出差场景直接错到 12 小时。这些时间戳并非展示用而已 —— `_attachServerMessageTimestamp` 的结果被用于**消息排序与去重**。
- **触发**：Bridge 任一处用 `new Date().toISOString().slice(0,19)`、或 Codex CLI 的 JSONL 里本来就是无时区的本地时间。
- **修复方向**：在 `messages.dart` 里加一个 `DateTime? parseWireTimestamp(String?)`，对不含 `Z`/`+HH:MM` 的串强制 `DateTime.utc(...)` 解释，全文件统一走它。

### B-2 【P1】`toLocal()` / `toUtc()` 不一致

- **证据**：
  - `messages.dart:5873`：`serverMessageTimestamp(message)?.value.toLocal() ?? DateTime.now()`（→ 本地）
  - `session_list_projection.dart:232-236`：`DateTime.tryParse(value)?.toUtc()`（→ UTC）
  - `unseen_sessions_cubit.dart:207`：`candidateTime.toUtc().isAfter(baselineTime.toUtc())`（→ UTC）
- **问题**：同一批 wire 字符串在三个模块被归一化到不同基准。对 B-1 的 naive 串，`toUtc()` 会**再叠加一次**本地偏移，`toLocal()` 则是 no-op —— 两个模块对同一条消息算出的时刻相差一个时区偏移，导致「列表排序」和「气泡时间」互相矛盾。
- **修复**：wire 层一律解析为 UTC，只在 UI 渲染的最后一步 `toLocal()`。

### B-3 【P1】ISO 字符串按**字典序**排序 / 去重

- **位置**：`features/session_list/state/session_list_cubit.dart:705-709`
- **证据**：
  ```dart
  706:  final modifiedOrder = right.modified.compareTo(left.modified);
  708:  return right.created.compareTo(left.created);
  ```
- **问题**：`RecentSession.modified` / `created` 是原始 wire 字符串（`messages.dart:4412-4413`，仅 `as String? ?? ''`），直接 `String.compareTo`。字典序只在**格式完全一致**时等价于时间序。混入 `2026-07-25T10:00:00Z` 与 `2026-07-25T18:00:00+08:00`（同一时刻）时排序完全错乱；`''`（缺失）会排到最前/最后。
- **同类**：`unseen_sessions_cubit.dart:211`（`_isAfter` 的 fallback 分支）、`:217`、`:232`、`prompt_history_section.dart:379`。
- **修复**：`RecentSession` 提供 `modifiedUtc` / `createdUtc`（`DateTime?`），排序基于 `millisecondsSinceEpoch`，null 排末尾。参考 `session_list_projection.dart:118-120` 已经做对了（`activityAt?.millisecondsSinceEpoch ?? -1`）。

---

## C. 身份 / 键

### C-1 【P2】`providerSessionIdentityKey` 缺少 bridge 维度

- **位置**：`messages.dart:230-231`
- **证据**：
  ```dart
  String providerSessionIdentityKey(String provider, String sessionId) =>
      '$provider\u0000$sessionId';
  ```
- **使用方**：`session_list_projection.dart:194/202`、`session_archive_cubit.dart:12`、`session_list_screen.dart:1665`、`home_content.dart:978`。
- **问题**：只有 `provider × sessionId` 两个维度，**没有 `bridgeInstanceId`**。运行时状态由 `bridge_service.dart:1418-1420` 的 `_clearBridgeScopedState(clearOfflineQueue: true)` 在切换 Bridge 时清掉，尚可；但**持久化**的键同样缺维度：
  - `unseen_sessions_cubit.dart:195-196`：`'$provider:${durableId ?? session.id}'` 写入本地持久层，跨 Bridge 复用 → 在公司 Mac 上已读的会话，切到家里 Mac 后若 sessionId 巧合相同则被误判已读；更常见的是**磁盘条目无限增长**（靠 `_pruneSeenAt` 的 200 条上限硬砍，砍的还是字典序最小的，见 B-3）。
- **修复**：增加可选 `bridgeInstanceId` 维度：`'$bridge\u0000$provider\u0000$sessionId'`，持久层必须带。

### C-2 【P2】运行时 id 与持久 id 的双轨制未收敛

- **位置**：`session_list_projection.dart:198-209`
- **证据**：
  ```dart
  String _runningIdentity(SessionInfo session) {
    final durableId = session.claudeSessionId?.trim();
    if (durableId != null && durableId.isNotEmpty) {
      return providerSessionIdentityKey(provider, durableId);
    }
    return 'runtime\u0000$provider\u0000${session.id}';
  }
  ```
- **问题**：`claudeSessionId` 到达前后同一会话的 identity key 会**变化**（`runtime\0...` → `claude\0...`）。此期间列表里会同时存在两条项目，pin/未读状态各自记一份。`SessionInfo.claudeSessionId` 恰恰是 `messages.dart:4767` 的可选字段，`system` init 之前必为 null。
- **修复**：identity 迁移时携带旧 key 做一次显式 rebind（`bridge_service.dart:4233 _rememberProviderSessionBinding` 已有绑定表，projection 层没用上）。

### C-3 【P2】`artifactMessageId` 可能为空串

- **位置**：`messages.dart:2016-2017`
- **证据**：
  ```dart
  String get artifactMessageId =>
      message.id.isNotEmpty ? message.id : messageUuid?.trim() ?? '';
  ```
- **问题**：`AssistantMessage.id` 已在 `88` 行降级为 `?? ''`，`messageUuid` 也可为 null → 返回 `''`。若上层以此为 artifact 缓存键，所有无 id 的 assistant 消息共用 `''` 一个桶，附件互相串台。
- **修复**：返回 `String?`，空时不参与缓存。

---

## D. 路径处理

### D-1 【P2】`pathBasename` 与全局路径比较的规则不一致

- **位置**：`messages.dart:4307-4313`
- **证据**：
  ```dart
  String pathBasename(String path) {
    if (path.isEmpty) return path;
    final normalized = path.replaceAll('\\', '/');
    final parts = normalized.split('/').where((part) => part.isNotEmpty);
    final last = parts.isEmpty ? '' : parts.last;
    return last.isNotEmpty ? last : path;
  }
  ```
- **问题**：`pathBasename` 做了 3 件事 —— 反斜杠归一、忽略尾斜杠、忽略空段。但**路径相等性判断处一件都没做**：
  - `session_list_projection.dart:127`：`if (projectPath != null && session.projectPath != projectPath) return false;`（裸字符串比较）
  - `session_list_projection.dart:163`（recent 版本同样）
  - `_priorityTier` / `pinnedProjectPaths.contains(item.projectPath)`（`session_list_projection.dart:190`）
- **触发**：Bridge 对 `SessionInfo.projectPath` 返回 `/Users/x/proj`，对 `RecentSession.projectPath` 返回 `/Users/x/proj/`（尾斜杠），或 Windows Bridge 返回 `C:\Users\x\proj` —— 项目筛选直接筛不到、pin 失效、running 与 recent 无法合并成一条。
- **另外**：全代码库无 `~` 展开、无 `Uri.decodeComponent`、无 macOS 大小写不敏感处理。`BRIDGE_ALLOWED_DIRS` 默认 `$HOME`，用户很可能在 UI 里输入 `~/proj`。
- **修复**：抽出 `String normalizeProjectPath(String)`（反斜杠归一 + 去尾斜杠 + `~` 展开 + 可选大小写折叠），所有路径**比较**和**字典键**都走它；`pathBasename` 复用同一归一化前置。

---

## E. 数值 / 边界

### E-1 【P1】`as int?` 与 `(num?)?.toInt()` 混用（系统性）

- **证据**：
  ```dart
  839:  sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,        // ArtifactRef — 安全
  690:  sizeBytes: json['sizeBytes'] as int? ?? 0,                   // GalleryImage — double 即抛
  1105-1109: inputTokens/cachedInputTokens/outputTokens/toolCalls/fileEdits: json[...] as int?
  1443:  acceptedSeq: json['acceptedSeq'] as int?,
  1523-1524: revision/entryCount: json[...] as int? ?? 0,
  1647-1653: stagedCount/unstagedCount/untrackedCount/commitsAhead/commitsBehind: as int? ?? 0
  ```
- **问题**：`jsonDecode` 对 JSON 里的 `1.0`、`1e5` 一律产出 `double`，`as int?` 直接 TypeError。而同文件的 `1101-1102`（cost/duration）、`1216`、`1294-1295`、`1301`、`839/842/845/846` 都正确用了 `(json[x] as num?)?.toInt()`。
- **触发**：Bridge 任一处把计数改为平均值/比率，或 TypeScript 侧 `tokensUsed` 从 `number` 计算得到非整数。
- **修复**：全部改为 `(json[x] as num?)?.toInt()`。

### E-2 【P2】`ArtifactRef.sizeLabel` 无负数/异常值保护

- **位置**：`messages.dart:867-873`
- **证据**：`if (sizeBytes < 1024) return '$sizeBytes B';`
- 负数 `sizeBytes` 渲染为 `-1 B`；无除零风险（除数为常量）。`RecordingInfo` 在 `4222-4226` 有一份**完全重复**的实现（见 G-4）。【P3】

### E-3 【P3】正则与字符串边界

- `messages.dart:2270-2273`：
  ```dart
  RegExp(r'^automatic approval review (approved|denied)\s*\(([^)]*)\)\s*:\s*([\s\S]+)$', caseSensitive: false)
  ```
  作用于任意长度的 Bridge 错误文本。无嵌套量词，回溯为线性，ReDoS 风险低；但 `([\s\S]+)$` 对一条 10MB 的错误消息仍会做全量扫描。建议先做 `normalized.length > 4096` 的前置截断。
- `messages.dart:2289-2295`：`match.group(2)!` / `match.group(3)!` 在正则匹配成功后必非 null，安全。`field.substring(0, separator)` 由 `separator == -1` 提前 continue 保护，安全。
- `messages.dart:546`：`word[0]` 由 `.where((word) => word.isNotEmpty)` 保护，安全。
- `messages.dart:3074`：`part[0]` 由 `if (part.isEmpty) return part` 保护，安全。
- `messages.dart:2918/2924/2925`：`changes.first` 由 `changes.length == 1` / 前置非空检查保护，安全。
- **全文件无 `int.parse`**（只有 `tryParse` 风格），这一项通过。

---

## F. 枚举兜底把未知的未来值静默映射到已知值

### F-1 【P0】`GuardianApprovalStatus.fromString` 默认 → **approved**（安全性 fail-open）

- **位置**：`messages.dart:2211-2216`
- **证据**：
  ```dart
  static GuardianApprovalStatus fromString(String? value) => switch (value) {
    'denied' => GuardianApprovalStatus.denied,
    'timedOut' => GuardianApprovalStatus.timedOut,
    'aborted' => GuardianApprovalStatus.aborted,
    _ => GuardianApprovalStatus.approved,
  };
  ```
- **问题**：这是**审批**语义。任何未知值 —— 包括 `null`、拼写变化（`timed_out` vs `timedOut`）、未来新增的 `escalated` / `needsHumanReview` / `partiallyApproved` —— 全部渲染成「已批准」。注意 `'timedOut'` 是 camelCase，而同文件其余 wire 值普遍是 snake_case（`waiting_approval`、`notifications_only`、`on-request`），一旦 Bridge 侧规范化为 `timed_out`，超时会被显示为**已批准**。
- **修复方向**：加 `unknown` 哨兵成员并默认落到它；UI 对 unknown 一律按"未批准/需人工确认"渲染。参考同文件 `CodexSpeed.unknown`（`566-578`）已有的正确范式。

### F-2 【P1】`ProcessStatus.fromString` 默认 → `idle`

- **位置**：`messages.dart:113-122`
- **证据**：
  ```dart
  _ => ProcessStatus.idle,
  ```
- **调用点**：`1135`（status 帧）、`1182`（history_delta）、`1192`（history_snapshot）。
- **问题**：Bridge 未来新增 `reviewing` / `waiting_input` / `queued` / `resuming` → 客户端认为会话空闲，从而放开输入框、隐藏停止按钮、误触发自动续跑，同时不显示 spinner。这是**行为性**误判而非显示性。
- **修复**：加 `unknown` 成员 + 保留 `rawStatus`。同文件 `CodexGoal`（`147-217`）已经实现了完美范式：
  ```dart
  185:  String get effectiveStatus => rawStatus ?? status.value;
  189:  bool get hasUnknownStatus => !CodexThreadGoalStatus.values.any(
  190:    (knownStatus) => knownStatus.value == effectiveStatus,
  191:  );
  ```
  把这套 `rawXxx + hasUnknownXxx` 模式推广到 `ProcessStatus` / `GuardianApprovalStatus`。

### F-3 【P2】`BridgeClientDeliveryMode.fromWire` 二值化

- **位置**：`messages.dart:1838-1842`
- **证据**：
  ```dart
  return value == notificationsOnly.wireValue ? notificationsOnly : interactive;
  ```
- **问题**：未来新增 `silent` / `paused` 投递模式 → 一律当 `interactive`，客户端继续要求全量流式推送，与 Bridge 的节流意图相反（这是省电/省流量语义，误判成本实在）。
- **修复**：`null`-返回 + 调用方保持旧值，而不是硬落到 `interactive`。

### F-4 【P3】其余兜底（fail-safe 方向正确，仅记录）

- `SessionLinkResolutionStatus.fromString`（`2162-2168`）→ `unavailable`：fail-closed，可接受，但未来的 `archived` 状态会丢失语义。
- `GuardianApprovalRisk.fromString`（`2196-2202`）→ `unknown`：正确；且 `2300` 处 `if (risk == unknown ...) return null` 显式拒绝，良好。
- `codexSpeedFromRaw`（`580-584`）→ `unknown` 哨兵 + `codexRuntimeSpeedFromRaw` 保留原始 wire 值：**本文件最佳实践**。
- `AssistantContent.fromJson` 默认分支（`42`）→ `TextContent(text: '[Unknown content type: ${json['type']}]')`：不崩溃，但把调试文本直接呈现给用户【P2】，应改为可跳过的占位或静默丢弃。

### F-5 【P2】`deriveExecutionMode` 硬编码字符串 + 未知模式降级

- **位置**：`messages.dart:450-469`
- **证据**：
  ```dart
  467:  if (approvalPolicy == 'never') return ExecutionMode.fullAccess;
  468:  return ExecutionMode.defaultMode;
  ```
- **问题**：(1) `'never'` 是裸字面量，而同文件 `311-319` 已定义 `CodexApprovalPolicy.never.value`，`365` 处用的正是常量 —— 同一语义两种写法。(2) 未知的 `permissionMode`（未来更严格的模式）静默落到 `defaultMode`，UI 显示"Default"但实际权限未知。
- **修复**：改用常量；未知 permissionMode 时返回 null 并让 UI 显示原始值（只读）。

### F-6 【P2】`ReasoningEffort.fromValue` 生成的实例不在 `values` 里

- **位置**：`messages.dart:539-549` + `533`
- **证据**：
  ```dart
  539:  factory ReasoningEffort.fromValue(String value) {
  548:    return ReasoningEffort._(value, label.isEmpty ? value : label);
  ```
  `533: static const values = [none, minimal, low, medium, high, xhigh, max, ultra];`
- **问题**：设计本身是好的（未知值保留原值 + `==`/`hashCode` 按 value）。但 `widgets/codex_environment_summary.dart:128` 用 `for (final value in ReasoningEffort.values)` 遍历 —— 未来 Bridge 返回 `ultra-max`，该实例不在 `values` 中，若被喂给 `DropdownButton` 的 `value` 而 `items` 由 `values` 生成，会触发 Flutter 的 "exactly one item" 断言崩溃。
- **修复**：所有下拉框构造 items 时用 `{...ReasoningEffort.values, currentValue}` 合并。

---

## G. 杂项

### G-1 【P1】未知消息类型 → 用户可见的红色错误气泡（违反加法式协议原则）

- **位置**：`messages.dart:1665`
- **证据**：
  ```dart
  _ => ErrorMessage(message: 'Unknown message type: ${json['type']}'),
  ```
- **追踪**：该 `ErrorMessage` 的 `errorCode` 为 **null** → `bridge_service.dart:1868-1870` 走 `default:` → `_messageController.add(msg)` → `chat_message_handler.dart:355-377`：`errorCode == 'unsupported_message'` 不成立、`message == 'Invalid message format'` 不成立 → 落到 `376-377`：
  ```dart
  logger.error('[handler] error message: $message');
  return ChatStateUpdate(entriesToAdd: [ServerChatEntry(msg)]);
  ```
  **未知消息作为错误气泡渲染进聊天流**。
- **问题**：CLAUDE.md 明确规定了「Bridge 非对応メッセージの Graceful Degradation」机制，但那套机制只覆盖**App→Bridge 方向**（新 App + 旧 Bridge）。**反方向（新 Bridge + 旧 App）完全没有保护** —— 新 Bridge 每发一种新消息类型，旧 App 就刷一条红字。这正好是加法式协议最该保证的场景。
- **修复方向**：新增 `UnknownServerMessage implements ServerMessage { final String type; final Map<String,dynamic> raw; }` 替代 `1665` 的 ErrorMessage，handler 里默认 suppress（打日志），与 `_unsupportedActions` 的 suppress 语义对齐。

### G-2 【P1】"Parse error" 气泡同样面向用户且丢失 sessionId

- **位置**：`bridge_service.dart:1872-1876`
- **证据**：
  ```dart
  } catch (e, st) {
    logger.error('WS parse error', e, st);
    final errorMsg = ErrorMessage(message: 'Parse error: $e');
    _taggedMessageController.add((errorMsg, null));
    _messageController.add(errorMsg);
  }
  ```
- **问题**：(1) 把 Dart 的 TypeError 文本（`type 'Null' is not a subtype of type 'String' in type cast`）直接展示给终端用户。(2) `sessionId` 传 `null` —— 明明 `1434` 行已经取到过 `json['sessionId']`，但那行在 try 内部、且可能就是抛出点之前的成功行；catch 块无法访问它（作用域）。结果错误无法归属到会话。
- **修复**：把 `sessionId` 提取移到 try 之前用防御式读取（`json is Map ? json['sessionId'] : null`），catch 里带上；用户侧文案本地化，原始异常只进日志。

### G-3 【P2】全手写序列化，与项目规约（Freezed / json_serializable）背离

- **位置**：`messages.dart` 全文件 5922 行，零 `@freezed`、零 `@JsonSerializable`、零 `.g.dart`
- **问题**：项目 `/flutter-ui-design` 技能规定 "Bloc/Cubit + Freezed"，但协议模型层是纯手写，导致 A-1/A-6/A-8/E-1 这一整类不一致（同一语义字段在 20+ 处各写各的）无法被工具约束。
- **修复方向**：不必全量迁移，但至少抽出 4 个共享 helper 并强制使用：`_str/_strOr/_intOr/_stringListOf`，把 `as String` / `as int?` / `.cast<String>()` 从文件里彻底消除。

### G-4 【P2】缺失 `==` / `hashCode`

- **有**：`CodexGoal`（`193-216`）、`ArtifactRef`（`875-904`）、`ReasoningEffort`（`551-557`）。
- **没有**：`SessionInfo`(4572)、`RecentSession`(4315)、`ImageRef`(617)、`GalleryImage`(660)、`QueuedInputItem`(695)、`UsageWindow`(729)、`UsageInfo`(746)、`WorktreeInfo`(635)、`HistoryEntry`(2345)、`HistoryWindowInfo`(2323)、`CodexSkillMetadata`(1673)、`CodexAppMetadata`(1720)、`CodexPluginMetadata`(1758)、`PermissionRequestMessage`(2508) 等全部。
- **后果**：`SessionListMessage` 每次到达都产生全新实例，`BlocBuilder` / `ValueNotifier` 的 `==` 判定恒为 false → 整张会话列表每次心跳全量重建；用 `Set<SessionInfo>` 做去重完全失效（这正是 C 类问题落地时的隐患）。
- **修复**：至少给 `SessionInfo` / `RecentSession` / `QueuedInputItem` 补齐。

### G-5 【P2】`_normalizeToolResultContent` 静默丢弃非 text 内容块

- **位置**：`messages.dart:779-789`
- **证据**：
  ```dart
  return content
      .whereType<Map<String, dynamic>>()
      .where((c) => c['type'] == 'text')
      .map((c) => c['text']?.toString() ?? '')
      .join('\n');
  ```
- **问题**：`type == 'image'` / `'document'` / 未来的 `'json'` 块被彻底丢弃且无任何痕迹。用户看到的是"工具返回空"。另外 `whereType<Map<String, dynamic>>()` 而非 `whereType<Map>()` —— 若嵌套解码产生 `Map<dynamic, dynamic>` 则全部被过滤掉（返回空串）。
- **修复**：非 text 块降级为 `[image]` 之类占位；`whereType<Map>()` 后再 `Map<String,dynamic>.from`。

### G-6 【P3】`Expando` 挂时间戳的脆弱性

- **位置**：`messages.dart:919-950`、`5873`
- **问题**：时间戳不在对象上而挂在 `Expando` 里。`bridge_service.dart:1514-1517` 和 `1532-1535` 会**重建** `HistoryMessage`，`1469` 的 `_withEffectiveGoalSessionId` 也可能重建消息 —— 重建后的新实例在 Expando 里查不到时间戳，`5873` 静默退化为 `DateTime.now()`，历史消息全部显示为"刚刚"。另外 Expando 无法用于 const 规范化对象，一旦将来把某个无参数消息（如 `PermissionResolvedMessage`）改成 const 构造并被规范化，多条消息会共享同一时间戳。
- **修复**：把 `ServerMessageTimestamp` 变成 `ServerMessage` 的实际字段，或在所有重建点显式 `_transferServerMessageTimestamp(old, new)`。

### G-7 【P3】重复代码 / 死代码

- `sizeLabel` 在 `867-873`（ArtifactRef）与 `4220-4227`（RecordingInfo）两份完全相同的实现。
- `messages.dart:1044` `clearContext`、`1051` `tipCode`、`2482-2506` `ToolSuggestionApp` 等字段解析存在但需确认是否仍有消费方（本次未逐一追踪）。
- `messages.dart:1558-1573`：`unarchive_result` 与 `delete_session_result` 两个分支体完全相同，只有 `type` 字符串不同，可合并为 `_ when {'unarchive_result','delete_session_result'}.contains(type)`。

---

## 建议的修复优先级

1. **P0 立即**：A-0（`.cast<String>()` 逃逸 → 红屏）、F-1（审批 fail-open）、A-1（整张会话列表消失）、A-2（分页永久转圈）。
2. **P1 本迭代**：G-1（未知消息类型的红字气泡 —— 这是加法式协议的根本要求）、A-6 聚合消息逐元素容错、E-1 `as int?` 全量替换、B-1/B-2/B-3 时间归一化三件套。
3. **P2 后续**：C-1/C-2 身份键补维度、D-1 路径归一化函数、G-4 `==`/`hashCode`、F-2/F-3/F-5/F-6 枚举哨兵化。

**最有价值的单点改动**：把 `CodexGoal`（`messages.dart:170-191`）的 `rawStatus` + `effectiveStatus` + `hasUnknownStatus` 三件套，以及 `CodexSpeed.unknown`（`566-603`）的哨兵范式，作为本文件所有 `fromString` 的强制模板 —— 这两处已经把"加法式协议"做对了，其余 6 个枚举只是没跟上。
