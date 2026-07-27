I'll read the specified file range.
## 审计范围
`/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/apps/mobile/lib/models/messages.dart` 第 2000–4000 行（全部读完，共 4 次 Read）。

**共用前提（决定所有 A 类问题的爆炸半径）**：`/Users/huyiyang/AI agent/Codex/.../lib/services/bridge_service.dart:1431-1877` 中，整个 `ServerMessage.fromJson` 调用被单个 `try/catch` 包住，catch 里只是 `logger.error` 并向流里塞一条 `ErrorMessage(message: 'Parse error: $e')`。所以：

- **stream 不会死**（`onError` 不触发），但
- **整条消息被整体丢弃**，且 UI 上会冒出一条红色 "Parse error" 气泡；
- 若丢的是 `history_page` / `history_tool_details` / `client_delivery_mode_state` 这类**带 requestId 的应答**，`_completeRemoteHistoryPage(msg)` 等 completer 完成逻辑在 throw 点之后（1436-1447 行），**completer 永不完成**，只能等 `future.timeout(...)`（3206/3230/3988/4089 行）超时 → 用户看到长时间转圈后失败。
- 历史类消息是 `List.map` 全量解析，**一条 entry 坏 = 整页/整个快照丢失**。

---

## A. 反序列化健壮性

### A-1 `HistoryEntry.fromJson` 裸转 Map —— 一条坏 entry 拖垮整页历史 【P0】
`messages.dart:2350-2355`
```dart
factory HistoryEntry.fromJson(Map<String, dynamic> json) {
  return HistoryEntry(
    seq: json['seq'] as int? ?? 0,
    message: ServerMessage.fromJson(json['message'] as Map<String, dynamic>),
  );
}
```
- **问题**：`json['message']` 缺失 / 为 `null` / 为 `List` / 为 `String` 时 `as Map<String, dynamic>` 抛 TypeError。`seq as int?` 在 Bridge 侧（Node）把 seq 序列化成 `1.0`/`1e3` 时也抛（Dart 的 `jsonDecode` 会得到 `double`，`as int?` 不做数值转换）。
- **触发场景**：Bridge 新增一种 entry（例如未来的 `{"seq":5,"tombstone":true}`，无 `message` 字段）；或某条 entry 的 message 因 Bridge 侧裁剪变成 `null`。协议号称 additive，但这里新增一种 entry 形态就炸。
- **爆炸半径**：调用点是 `messages.dart:1156`（`history_page`）、`1179`（`history_delta`）、`1190`（`history_snapshot`），全都是 `(json['messages'] as List).map(...).toList()` —— **一条坏 entry ⇒ 整页/整个 delta/整个 snapshot 丢失**；`history_page` 还会导致分页 completer 挂起到超时（见前提）。同一链路上 `1147-1151` 的 `json['requestId'] as String` / `beforeSeq as int` 连 `?` 都没有，缺字段直接同样后果。
- **修复方向**：`HistoryEntry.fromJson` 改成返回 `HistoryEntry?`，`final raw = json['message']; if (raw is! Map) return null;`；`seq` 用 `(json['seq'] as num?)?.toInt() ?? 0`；调用点改成 `.map(...).whereType<HistoryEntry>()`，做到"跳过坏条目而不是丢整页"。

### A-2 `PermissionPresentation` Bash 分支把 `command` 裸转 String —— 审批卡片构建期崩溃 【P0】
`messages.dart:2733`
```dart
case 'Bash':
  final command = input['command'] as String?;
```
- **问题**：`input` 是**完全不可控的工具入参**（来自 Claude/Codex/任意 MCP server）。exec 类审批把 command 写成 argv 数组是极常见形态（`["bash","-lc","..."]`），此时抛 TypeError。
- **触发场景**：Codex exec 审批 / 未来 Bridge 改用 argv 数组 / 某个 MCP server 的 Bash-like 工具。
- **爆炸半径**：`presentation` 在 `2590` 行由 getter 现算，`summary`(2612)/`detailLines`(2614) 都会走到它，而这些 getter 是在 **widget build 期**被调用的 —— 不是被 bridge_service 的 try/catch 保护的，会变成 Flutter build 异常（红屏/错误 widget）。**结果是用户看不到、也无法批准或拒绝这条权限请求，会话彻底卡死在 waiting_approval**。
- **对照（G 类不一致）**：同函数 `default` 分支（2780-2786）用的是 `_firstInputValue` → `_nonEmptyString`（`2871-2875`，做 `is! String` 检查），**是安全的**；只有手写的 `Bash` 分支裸转。
- **修复方向**：`final command = _nonEmptyString(input['command']) ?? _stringifyDetailValue(input['command']);`（`_stringifyDetailValue` 在 3045 行，已能处理 List/Map/num）。

### A-3 `DiffImageChange.filePath` 无 `?` 无兜底 —— 整个 diff 结果丢失 【P1】
`messages.dart:3458-3460`
```dart
factory DiffImageChange.fromJson(Map<String, dynamic> json) =>
    DiffImageChange(
      filePath: json['filePath'] as String,
```
- **触发**：Bridge 新增一种 image change（例如 rename 用 `oldPath`/`newPath` 而无 `filePath`）。
- **爆炸半径**：调用点 `messages.dart:1385` 在 `diff_result` 的 `.map()` 内，**一张图坏 ⇒ 整条 `diff_result` 丢失**，diff 页面拿不到任何内容（连纯文本 diff 一起丢）。
- **修复**：`filePath: json['filePath'] as String? ?? ''`，并在调用点 `.where((c) => c.filePath.isNotEmpty)`。

### A-4 `WindowInfo.windowId as int` 【P1】
`messages.dart:3227-3233`
```dart
windowId: json['windowId'] as int,
ownerName: json['ownerName'] as String? ?? '',
```
- **问题**：唯一一个 `as int` 完全裸转的字段。macOS CGWindowID 可能被 Node 侧序列化为浮点，或未来改成 string 型 id。
- **爆炸半径**：`messages.dart:1320` 的 `.map()` —— 一个窗口坏 ⇒ 整个 `window_list` 丢失，截图选窗口列表全空。
- **修复**：`(json['windowId'] as num?)?.toInt() ?? -1` + 调用点过滤。

### A-5 `PromptHistoryServerEntry` 的 stats 双层裸转 —— 提示词历史同步整体失败 【P1】
`messages.dart:3872-3888`
```dart
clientStats:
    (json['clientStats'] as Map<String, dynamic>?)?.map(
      (key, value) => MapEntry(
        key,
        PromptHistoryClientStat.fromJson(value as Map<String, dynamic>),
      ),
    ) ??
    const {},
```
- **问题**：外层 `as Map<String,dynamic>?`（若 Bridge 把它改成数组形态 `[{clientId,...}]` 立刻抛）、内层 `value as Map<String, dynamic>`（任一 stat 值为 null/数字即抛）。`sessionStats`（3880-3887）同构同病。
- **爆炸半径**：调用点 `messages.dart:1502`（`prompt_history_sync_result` 的 entries `.map()`）和 `1515`（mutation result）。**一个 entry 坏 ⇒ 整个同步结果被丢弃 ⇒ 同步 revision 不推进，反复重试仍然失败（永久卡住）**，而不是"少一条提示词"。
- **修复**：`_stringKeyedMap`（本文件 3040 行已有）+ 逐条 `try`/skip。

### A-6 `HistoryToolDetail` 的 input / toolName 裸转 【P1】
`messages.dart:2412-2428`
```dart
final rawToolUseId = (json['toolUseId'] as String? ?? '').trim();
final rawToolName = (json['toolName'] as String? ?? 'Tool').trim();
...
input: Map<String, dynamic>.from(json['input'] as Map? ?? const {}),
...
toolName: rawResult['toolName'] as String?,
```
- **问题**：① `json['input']` 若是 `String`（Claude 有时把 input 序列化成 JSON 字符串）或 `List` → TypeError。② `Map<String,dynamic>.from` 是**浅拷贝**，嵌套 map 仍是 `Map<dynamic,dynamic>`，下游任何 `as Map<String,dynamic>` 都会二次抛。③ `toolUseId`/`toolName` 若为数字 → TypeError。
- **爆炸半径**：`messages.dart:1163-1171` 的 `.map()` —— 一条 detail 坏 ⇒ 整条 `history_tool_details` 丢 ⇒ 该 requestId 的 completer 挂起到超时，"展开工具详情"永远转圈。
- **修复**：`input: _stringKeyedMap(json['input']) ?? const {}`，并在 map 阶段做 per-item try/skip。

### A-7 `PermissionRequestMessage` 全部 getter 对不可控 `input` 裸转 String 【P1】
`messages.dart:2526, 2529-2530, 2534, 2536, 2538, 2540, 2594, 2600`
```dart
String get suggestedToolName => input['toolName'] as String? ?? displayToolName;
String get toolSuggestionReason =>
    input['suggestReason'] as String? ?? input['message'] as String? ?? suggestedToolName;
String get toolSuggestionInstallState => input['installState'] as String? ?? 'idle';
...
final serverName = input['serverName'] as String?;   // 2600
```
- **问题**：`input` 是任意 MCP/工具入参。任何一个键恰好是数字/对象（MCP server 完全可能返回 `{"message": {"text": "..."}}`）就抛 TypeError。
- **爆炸半径**：同 A-2，**在 build 期抛**，不受 bridge_service try/catch 保护 → 审批卡片渲染失败 → 无法批准/拒绝。
- **修复**：统一改用同文件已有的 `_nonEmptyString(...)`（2871）。

### A-8 `ToolSuggestionApp.fromJson` 全字段裸转 【P2】
`messages.dart:2497-2505`
```dart
id: json['id'] as String? ?? '',
name: json['name'] as String? ?? '',
description: json['description'] as String?,
installUrl: json['installUrl'] as String?,
category: json['category'] as String?,
```
- 数字型 id / 结构化 description 即抛。爆炸半径较小：位于 `2542-2550` 的 getter 内，已有 `.whereType<Map>()`，但异常仍会冒到 build 期。改 `_nonEmptyString`。

### A-9 `DebugReproRecipe` 的 `cast<String>()` 延迟异常 【P2】
`messages.dart:3336-3351`
```dart
resumeSessionMessage:
    (json['resumeSessionMessage'] as Map<String, dynamic>?) ?? const <String, dynamic>{},
...
notes: (json['notes'] as List?)?.cast<String>() ?? const [],
```
- **问题**：`cast<String>()` 是**惰性视图**，不在解析处校验。如果 `notes` 里混入一个数字，异常会在**几百行之外的 debug 页面渲染时**抛出，堆栈完全指不到 Bridge 协议变更，排查成本极高。三个 `as Map<String,dynamic>?` 在字段变成 List 时直接抛。
- **修复**：`(json['notes'] as List?)?.whereType<String>().toList() ?? const []`；map 字段用 `_stringKeyedMap`。

### A-10 `GuardianApprovalMessage.action` 浅拷贝 + 字段裸转 【P2】
`messages.dart:2240-2248`
```dart
risk: GuardianApprovalRisk.fromString(json['risk'] as String?),
status: GuardianApprovalStatus.fromString(json['status'] as String?),
reason: json['reason'] as String? ?? '',
...
action: rawAction is Map ? Map<String, dynamic>.from(rawAction) : null,
```
- `risk`/`status` 若 Bridge 改成对象形态（`{"level":"high"}`）→ TypeError；`action` 浅拷贝导致嵌套仍是 `Map<dynamic,dynamic>`。注意 `rawAction is Map` 这个前置检查写对了，说明作者知道该怎么做——但同一构造器的其余字段没照做（G 类不一致）。

### A-11 数值字段统一的 `as int?` 隐患 【P2】
`messages.dart:2339`（`fromSeq`）、`2352`（`seq`）、`3864`（`totalUseCount`）、`3925`/`3949`（`useCount`）、`3229`（`windowId`）
```dart
fromSeq: json['fromSeq'] as int? ?? 0,      // 2339
totalUseCount: json['totalUseCount'] as int? ?? 0,  // 3864
```
- Bridge 是 Node/TS。JS 侧任何经过 `/`、`Math.*`、或 > 2^53 的计数都会被 `JSON.stringify` 写成带小数/科学计数的数字，Dart `jsonDecode` 得到 `double`，`as int?` **不做转换直接抛**。
- **修复**：全部改 `(json['x'] as num?)?.toInt() ?? 0`。

### A-12 严格白名单/静默截断（非抛异常，但违反 additive 语义）【P2/P3】
- `messages.dart:2021` `static const maxToolUseIds = 200;` + `2060` `if (toolUseIds.length >= maxToolUseIds) break;`
- `messages.dart:2431` `rawImages.whereType<Map>().take(32)`、`2440` `rawArtifacts.take(32)`
- 调用点 `messages.dart:1165` `.take(8)`（history_tool_details）
- **问题**：一个 gap 最多可声明 **200** 个 toolUseId，但一次 `history_tool_details` 应答**最多只解析 8 条**，且 `.take(8)` 发生在 `.where((d) => d.isValid)`（1176）**之前** —— 8 条里若有 3 条 `toolUseId` 为空，本轮只补回 5 条。**协议上限不匹配 ⇒ 大 gap 永远补不完**，UI 上"N 个工具详情"永远缺。
- `messages.dart:2064` `gapId: rawGapId.length <= 128 ? rawGapId : ''` —— 超长 gapId 被静默改成 `''`，随后 `isValid`（2035）判 false，`1073` 行 `.where((gap) => gap.isValid)` 把整个 gap **静默丢弃**，用户看不到任何"有工具详情被折叠"的提示。
- **修复**：对齐两端上限（或让 gap 携带分页游标）；丢弃时记 metric/日志。

**A 类小结（关于"未知 key 抛异常"的检查结论）**：本区间内**没有**发现"遇到未知 key 就抛"的严格白名单解析——所有 `switch`/map 都是忽略未知键。真正的 additive 破坏来自上面的裸转和下面 F 类的枚举兜底。

---

## B. 时间 / 时区

### B-1 ISO 字符串按字典序比较做"取最新" 【P1】
模型侧字段：`messages.dart:3914` `PromptHistoryClientStat.lastUsedAt`（String）、`3926` 解析、`3939`/`3950` `PromptHistorySessionStat.lastUsedAt`。
消费侧：`/Users/huyiyang/AI agent/Codex/.../lib/services/prompt_history_service.dart:19-20`
```dart
String _maxIso(String left, String right) =>
    left.compareTo(right) >= 0 ? left : right;
```
被 `prompt_history_service.dart:131` 和 `:143` 用于合并 clientStats/sessionStats。
- **问题**：`compareTo` 是**纯字典序**。`"2026-07-26T19:00:00+09:00"` 和 `"2026-07-26T10:00:00Z"` 是同一时刻，但字典序里 `'1' > '0'`，前者胜；反过来 `'+'`(0x2B) < `'Z'`(0x5A)，只要小时位相同就会选错。毫秒位数不同（`.1Z` vs `.100Z`）同样错。
- **触发场景**：两台不同时区的 Mac 各跑一个 Bridge，同一条提示词在两边使用 → 合并后 `lastUsedAt` 取到更早的那个 → 提示词历史排序（`prompt_history_service.dart:1206/1209/1213` 用 `b.lastUsedAt.compareTo(a.lastUsedAt)`）错乱。
- **修复**：模型层把这些字段解析成 `DateTime` 并 `.toUtc()` 存储；或 `_maxIso` 改为 `DateTime.tryParse(l)?.toUtc()` 比较后回填原串。

### B-2 缺 `Z`/offset 的 ISO 串被 `DateTime.tryParse` 当作**本地时间** 【P1】
本区间内以裸 String 保存、且下游直接 `tryParse` 的时间字段：

| 模型字段 | 下游消费 |
|---|---|
| `messages.dart:2095` `ArtifactResolvedMessage.expiresAt` | `lib/features/file_transfer/file_transfer_service.dart:1602` `DateTime.tryParse(resumed.expiresAt!)` |
| `messages.dart:3555` `UserInputMessage.timestamp` | `lib/services/chat_message_handler.dart:306` 和 `lib/features/chat_session/state/chat_session_cubit.dart:4919`：`DateTime.tryParse(timestamp)?.toLocal()` |
| `messages.dart:3702` `ArchivedSessionRecord.archivedAt` | `lib/features/session_archive/session_archive_screen.dart:163` `DateTime.tryParse(session.archivedAt)?.toLocal()` |
| `messages.dart:3190` `SessionCatalogChangedMessage.occurredAt` | `lib/main.dart:711`、`lib/services/notification_action_host.dart:33` |
| `messages.dart:2313` `StatusMessage.activityAt` | `lib/services/bridge_service.dart:4458-4460` `DateTime.tryParse` 后比较新旧 |

- **问题**：`DateTime.tryParse("2026-07-26T10:00:00")`（无 Z/offset）返回 **isUtc=false 的本地时间**，随后 `.toLocal()` 是 **no-op**。Bridge 跑在 UTC+9 的 Mac、手机在 UTC+8 时，聊天消息时间戳、归档时间会整体偏移 1 小时且无任何报错。
- **`expiresAt` 尤其危险**：签名 URL 过期判断被整体平移一个时区偏移 → 要么提前判定过期（文件预览全部失败），要么滞后（拿着已失效 URL 反复请求）。
- **不一致证据**：同一代码库里三种写法并存 —— `lib/features/session_list/session_list_projection.dart:235` 用 `?.toUtc()`、`lib/features/conversation_mirror/storage/conversation_mirror_store.dart:1132` 用 `?.toUtc()`、而 `chat_message_handler.dart:306`/`session_archive_screen.dart:163`/`conversation_mirror_service.dart:2219` 用 `?.toLocal()`。**同一批 ISO 串在不同页面被解释成不同时刻**。
- **修复方向**：在 `messages.dart` 这一层就统一：新增 `DateTime? _parseWireInstant(dynamic v)`，实现为 `final s = _nonEmptyString(v); if (s == null) return null; final d = DateTime.tryParse(s); if (d == null) return null; return d.isUtc ? d : (hasExplicitOffset(s) ? d.toUtc() : DateTime.utc(...));`——对**无偏移串按 UTC 解释并打日志**，禁止落到本地时区。上层一律拿 UTC `DateTime`，只在渲染时 `.toLocal()`。

### B-3 纯展示型时间串未做任何校验 【P3】
`messages.dart:3253` `DebugTraceEvent.ts`、`3271` 解析；`3289-3290` `DebugBundleSession.createdAt/lastActivityAt`、`3313-3314` 解析；`3356` `DebugBundleMessage.generatedAt`；`3787`/`3801`/`3822` `backedUpAt`；`3964` `syncedAt`。全部是 `as String? ?? ''`，空串在 UI 上直接显示为空。低危，但 debug bundle 的时间轴排序若用字符串排会重蹈 B-1。

---

## C. 身份 / 缓存键

### C-1 `PromptHistoryServerEntry` 丢失 bridgeInstanceId 维度 【P1】
`messages.dart:3828-3841`（字段）、`3861`（`id`）、`3840-3841`（`clientStats` / `sessionStats` 以裸 clientId / 裸 sessionId 为 key）
```dart
final Map<String, PromptHistoryClientStat> clientStats;
final Map<String, PromptHistorySessionStat> sessionStats;
```
- **问题**：`bridgeInstanceId` 只挂在**信封上**（`messages.dart:3962` `PromptHistorySyncResultMessage.bridgeInstanceId`、`3982` mutation 版），**entry 层完全没有该维度**。`PromptHistoryServerEntry.fromJson`（3859）解析后 bridgeInstanceId 就被丢掉了。
- **触发场景**：用户有两台 Mac（公司/家）各跑 Bridge。两边各自生成 `id`（同为自增/uuid 但作用域是本机），`sessionStats` 的 key 是**裸 sessionId**（Claude 的 session uuid 在两台机器上确实不同，但 Codex 的 rollout id 与手工重放场景会撞）。合并逻辑 `prompt_history_service.dart:608-621` 用 `_displayMergeKey(entry.text)` 合并 → 两台机器的统计被无条件相加（`useCount + other.useCount`，`prompt_history_service.dart` 第 128/141 行），**跨机器的使用次数互相污染**，且 `bridgeIds`/`bridgeNames` 是事后补的旁路字段而非键的一部分。
- **修复**：`fromJson` 增加 `bridgeInstanceId` 参数（由调用点 `messages.dart:1502` 从信封透传），stats 的 key 改为 `'$bridgeInstanceId::$sessionId'`。

### C-2 `AssistantServerMessage.artifactMessageId` 只有 message id，无 session/provider/bridge 维度 【P2】
`messages.dart:2016-2017`
```dart
String get artifactMessageId =>
    message.id.isNotEmpty ? message.id : messageUuid?.trim() ?? '';
```
- **消费点**：`lib/features/chat_session/state/chat_session_cubit.dart:3218-3219`（用它判断 artifact 归属，`existingOwner` vs `incomingOwner`）、`lib/widgets/message_bubble.dart:191-192`、`lib/features/file_peek/file_peek_sheet.dart:702` `messageId: artifactMessageId!`。
- **问题**：`message.id` 来自 Anthropic 的 `msg_xxx`，在**同一次历史重放到两个不同 session**（例如 fork / 会话链接 / 归档恢复）时会重复；`messageUuid` 兜底时更弱。缺 `provider` / `bridgeInstanceId` / `sessionId` 维度 ⇒ 打开 A 会话的附件可能解析到 B 会话的 artifact。
- **对照**：同文件 `messages.dart:2171-2186` 的 `SessionLinkResolutionMessage` **有** `provider` 字段，`3684` 的 `ArchiveResultMessage` **也有** `provider` —— 说明 provider 维度在别处是被认真对待的，唯独 artifact 身份没有（G 类不一致）。
- **修复**：把 `artifactMessageId` 改成 `(bridgeInstanceId, provider, sessionId, messageId)` 的复合键，或至少在 file_peek 解析时把 sessionId 一并传下去。

### C-3 工具详情缓存以裸 `toolUseId` 为键 【P2】
`messages.dart:2023`（`HistoryToolDetailGap.gapId`）、`2024`（`toolUseIds`）、`2397`（`HistoryToolDetail.toolUseId`）
- `toolUseId`（`toolu_xxx`）由模型生成，理论上全局唯一，但**历史重放、归档恢复、两个 Bridge 的同一份 rollout 文件**会产生同 id 的 detail。若上层用 `Map<String, HistoryToolDetail>` 做全局缓存（键只有 toolUseId），跨会话串味。
- 同理 `2023` 的 `gapId` 也没有 session 维度。

### C-4 若干应答消息缺 provider/bridge 维度（横向不一致）【P2】
| 有 provider | 无 provider（仅 sessionId） |
|---|---|
| `messages.dart:2176` `SessionLinkResolutionMessage.provider` | `messages.dart:3669` `RenameResultMessage.sessionId` |
| `messages.dart:3684` `ArchiveResultMessage.provider` | `messages.dart:3781` `BranchUpdateMessage.sessionId` |
| `messages.dart:3700` `ArchivedSessionRecord.provider` | `messages.dart:3660` `RecordingContentMessage.sessionId` |
| `messages.dart:3169` `RecentSessionsMessage.provider` | `messages.dart:3355` `DebugBundleMessage.sessionId` |
| | `messages.dart:3763` `SessionLifecycleResultMessage.sessionId` |
- Claude 与 Codex 的 sessionId 命名空间不同源，同一个 uuid 在两个 provider 下都可能出现。右列消息路由到"错的那个会话"时无从检测。
- 另：`messages.dart:3698-3707` `ArchivedSessionRecord` 有 sessionId+provider+projectPath，但**没有 bridgeInstanceId** ⇒ 两台机器的归档列表合并时同名会话互相覆盖。

---

## D. 路径处理

### D-1 `_changePaths` 不做任何归一化 —— 文件变更计数会虚高 【P2】
`messages.dart:2903-2914`
```dart
List<String> _changePaths(dynamic value) {
  if (value is! List) return const [];
  return value.map((entry) {
      if (entry is! Map) return null;
      return _nonEmptyString(entry['file']) ??
          _nonEmptyString(entry['path']) ??
          _nonEmptyString(entry['target']);
    }).whereType<String>().toList();
}
```
- **问题**：无去重、无 `~` 展开、无 `\` → `/`、无大小写归一（macOS 默认大小写不敏感）、无末尾斜杠处理、无 URL decode。`/a/b.dart`、`/a/./b.dart`、`~/proj/a/b.dart`、`/A/B.dart` 被视作 4 个不同文件。
- **消费点**：`messages.dart:2916-2920` `_fileChangeSummary` 输出 `"Allow changes to 3 files"`、`2922-2926` `_compactFileTargets` 输出 `"x +2 more"`。**用户看到"要改 3 个文件"，其实只有 1 个** —— 这是安全审批文案，误导性直接影响用户判断。
- **修复**：加 `_normalizePath()`（展开 `~`、`\`→`/`、折叠 `//`、去尾 `/`、`path.normalize`），再 `toSet()` 去重。

### D-2 `grantRoot` 与 change paths 未同域归一，用户无法目视比对 【P2】
`messages.dart:2769-2777`
```dart
secondaryDetails: [
  if (_nonEmptyString(input['grantRoot']) case final grantRoot?)
    'Grant root: $grantRoot',
```
- **问题**：`grantRoot` 与 `2756` 行的 `changes` 原样并列展示。若 Bridge 一边给 `~/proj`、一边给 `/Users/x/proj/src/a.dart`，用户在审批界面**看不出这个文件是否真的在授权根之内**。这是权限提升面上的可用性缺陷。
- **修复**：归一化后计算并展示 `changes` 相对 `grantRoot` 的相对路径，越界的用醒目标记。

### D-3 各消息中的路径字段全是裸串，且被当 key 用 【P2】
`messages.dart:3398` `FileContentMessage.filePath`、`3460` `DiffImageChange.filePath`、`3488` `DiffImageResultMessage.filePath`、`3516` `WorktreeRemovedMessage.worktreePath`、`3285-3286` `DebugBundleSession.projectPath/worktreePath`、`3722` `ArchivedSessionRecord.projectPath`、`3831` `PromptHistoryServerEntry.projectPath`。
- `projectPath` 在 `prompt_history_service.dart:611-615`（`matchesFilters`）里做的是 `entry.projectPath != currentProjectPath` 的**精确字符串比较**。末尾斜杠差一个、或 Bridge 某个路径经过 realpath 而另一个没有（`/Users/x` vs `/System/Volumes/Data/Users/x`），过滤器就完全失效。
- `messages.dart:2094` `ArtifactResolvedMessage.relativeUrl` —— 没有约定是否已 percent-encode；文件名含空格/`#`/中文时，与本地拼接 base URL 的一侧若再 encode 一次就会双重编码。本文件没有任何 `Uri.encodeComponent`/`decodeComponent`，说明这个约定完全靠口头。

---

## E. 数值 / 边界

### E-1 `_flattenPermissionValues` 无深度和体积上限 【P2】
`messages.dart:2817-2840`
```dart
List<String> _flattenPermissionValues(dynamic value, [String prefix = '']) {
  if (value is Map) {
    final out = <String>[];
    for (final entry in value.entries) {
      final key = entry.key.toString();
      final nextPrefix = prefix.isEmpty ? key : '$prefix.$key';
      out.addAll(_flattenPermissionValues(entry.value, nextPrefix));
    }
    return out;
  }
```
- **问题**：无递归深度上限（深嵌套 JSON → StackOverflow，Dart 里**不可捕获恢复**，直接杀掉 isolate）；无输出条数上限（`2950` 行 `permissions.join(', ')` 可产生数 MB 单行字符串 → UI 卡死/OOM）。
- **触发**：恶意或异常的 MCP server 返回 10000 层嵌套的 `permissions`。
- **修复**：加 `depth` 参数（上限 ~16）+ 输出条数上限（~200，超出显示 `+N more`）。

### E-2 `presentation` getter 每次访问重新全量 JSON 编码 【P1（性能）】
`messages.dart:2590`、`2612`、`2614`、`2640`
```dart
PermissionPresentation get presentation => PermissionPresentation.from(this);   // 2590
String get summary => presentation.summary;                                     // 2612
List<String> get detailLines => presentation.secondaryDetails;                  // 2614
...
final rawDetails = const JsonEncoder.withIndent('  ').convert(input);           // 2640
```
- **问题**：`presentation` 没有缓存，每次读都重建；`summary` 和 `detailLines` 各调一次 → **一次 build 至少 2 次完整的带缩进 JSON 编码 + 全部正则去重**。`input` 若是一份大 tool input（例如整文件内容的 Write 审批，几 MB），每帧重复编码 → 明显掉帧甚至 OOM。而 `rawDetails` 往往只在"查看原始详情"折叠面板展开时才需要。
- **修复**：`late final PermissionPresentation presentation = PermissionPresentation.from(this);`；`rawDetails` 改成 lazy 闭包 `String Function()`，并对 `input` 大小设阈值截断。

### E-3 `_titleCaseLabel` 按 UTF-16 code unit 取首字符 【P3】
`messages.dart:3067-3077`
```dart
return normalized.split(RegExp(r'\s+')).map((part) {
    if (part.isEmpty) return part;
    return '${part[0].toUpperCase()}${part.substring(1)}';
  }).join(' ');
```
- `part[0]` / `substring(1)` 操作的是 UTF-16 code unit。若参数名以 emoji 或任何星平面字符开头（MCP 工具参数名完全可能是中文/emoji），会把代理对**从中间切开**，产出乱码字符（不崩溃，但显示 `��`）。
- `.first`/`.last`/`substring` 越界检查：本区间内 `2918`/`2924` 的 `changes.first` 都有 `isEmpty` 前置判断，`3082` 的 `line.substring(idx + 1)` 有 `idx == -1` 判断，`2292-2294` 的 `field.substring` 有 `separator == -1` 判断 —— **这几处是对的，无越界风险**。

### E-4 正则 ReDoS 评估：本区间内无实际风险 【P3 / 已澄清】
`messages.dart:2270-2273` 与 `2275-2278`
```dart
RegExp(r'^automatic approval review (approved|denied)\s*\(([^)]*)\)\s*:\s*([\s\S]+)$', caseSensitive: false)
```
- 两端锚定、无嵌套量词、`[^)]*` 为否定字符类，回溯是线性的，**不构成 ReDoS**。但注意 `2263-2265` 只在 `errorCode == 'codex_warning'` 时才走这条路径（2262），输入面本身受限。此项记录为"已检查、无问题"，避免后续重复排查。
- 本区间无 `int.parse` / `double.parse`（全部走 `as int?`，问题见 A-11），无除法，无取模。

---

## F. 枚举兜底把未来值静默映射成已知值

### F-1 `GuardianApprovalStatus` 未知值 → `approved` 【P1，安全语义】
`messages.dart:2205-2217`
```dart
enum GuardianApprovalStatus {
  approved, denied, timedOut, aborted;

  static GuardianApprovalStatus fromString(String? value) => switch (value) {
    'denied' => GuardianApprovalStatus.denied,
    'timedOut' => GuardianApprovalStatus.timedOut,
    'aborted' => GuardianApprovalStatus.aborted,
    _ => GuardianApprovalStatus.approved,     // ← 兜底方向错了
  };
}
```
- **问题**：兜底方向选了**最宽松**的那个值。Bridge 未来新增 `'escalated'` / `'pending'` / `'error'` / `'requiresUserConfirm'`，旧 App 一律显示为**"已批准"**。
- **消费点**：`lib/widgets/bubbles/guardian_approval_notice.dart:37-40` 的 switch 直接把它映射成标题文案 → 用户看到 `guardianApprovalTitle`（批准）。虽然不实际授予权限（授权在 Bridge 侧），但**向用户呈现了错误的安全结论**。
- **修复**：增加 `unknown` 成员并作为兜底，UI 上显示中性文案 + "请更新 Bridge/App"。

### F-2 `GuardianApprovalRisk` 出现新值时整条安全通知被丢弃 【P1】
`messages.dart:2296-2300`
```dart
final risk = GuardianApprovalRisk.fromString(metadata['risk']?.toLowerCase());
final reason = match.group(3)!.trim();
if (risk == GuardianApprovalRisk.unknown || reason.isEmpty) return null;
```
- **问题**：`GuardianApprovalRisk.fromString`（2196-2202）的兜底是 `unknown`（这个方向是对的），但 **2300 行把 `unknown` 当作"解析失败"直接 `return null`**。Bridge 新增一个风险等级（如 `'severe'` / `'blocker'`）后，legacy warning 路径下**整条 Guardian 通知气泡凭空消失** —— 风险越高越可能是新等级，越高的风险越会被吞掉。
- **修复**：`unknown` 不再作为丢弃条件，只要 `reason` 非空就产出通知，risk 以中性徽章展示。

### F-3 `SessionLinkResolutionStatus` 未知值 → `unavailable` 【P2】
`messages.dart:2157-2169`
```dart
static SessionLinkResolutionStatus fromString(String? value) {
  return switch (value) {
    'live' => live,
    'recent' => recent,
    _ => unavailable,
  };
}
```
- Bridge 未来新增 `'archived'` / `'resuming'` / `'remote'` 时，App 告诉用户"该会话不可用"，用户会误以为会话丢了。兜底应为 `unknown` 并给出"需要更新 App"的提示，而不是伪装成一个确定的负面结论。

### F-4 `availableDecisions` 白名单可产生"无出口"的审批卡片 【P1】
`messages.dart:2568-2588`
```dart
List<String> get availableDecisions => _stringList(input['availableDecisions']);

bool get canApprove => !isMalformedAskUserQuestion &&
    (availableDecisions.isEmpty || availableDecisions.contains('accept'));
bool get canApproveForSession => ... availableDecisions.contains('acceptForSession'));
bool get canDecline => isMalformedAskUserQuestion ||
    availableDecisions.isEmpty ||
    availableDecisions.contains('decline') ||
    availableDecisions.contains('cancel');
bool get showsCancelAction =>
    availableDecisions.contains('cancel') && !availableDecisions.contains('decline');
```
- **问题**：这是事实上的**值白名单**。若 Bridge 未来只下发 `["approveOnce","rejectOnce"]`（重命名）或 `["defer"]`，则 `canApprove == false && canDecline == false` —— **审批卡片上一个按钮都没有，用户既不能批准也不能拒绝，会话永久卡在 waiting_approval**。这正是 additive 协议最该防的失败模式。
- **修复**：`canDecline` 增加"无任何已知决策时强制为 true"的保底（永远保留一个"拒绝/取消"出口），并对未识别的决策值渲染成通用按钮直接回传原值。

---

## G. 其他（一致性 / 死代码 / 相等性）

### G-1 `_detailLineValue` 声明可空但永不返回 null —— 死分支 【P3】
`messages.dart:3079-3083`
```dart
String? _detailLineValue(String line) {
  final idx = line.indexOf(':');
  if (idx == -1) return line;
  return line.substring(idx + 1).trim();
}
```
调用点 `messages.dart:3024-3028`
```dart
final normalizedLine = _normalizeDetailValue(_detailLineValue(line));
if (normalizedLine == null || normalizedLine.isEmpty) { ... }
```
- 参数非空 ⇒ 两个 return 都非 null，返回类型的 `?` 是纯噪音（`_normalizeDetailValue` 那层的 null 才是真的）。同时**按第一个 `:` 切分**这一点没有注释说明——对 `'Command: docker run -p 8080:80 img'` 是对的，但对**没有标签、本身以 `X:` 开头的裸行**（Windows 路径 `C:\Users\...`）会把 `C` 当标签切掉，与 D 类路径问题叠加导致去重误判。

### G-2 `_stringMapSummary` 的 `where` 永远为真 —— 死过滤 【P3】
`messages.dart:2842-2850`
```dart
final parts = value.entries
    .map((entry) => '${entry.key}=${entry.value}')
    .where((entry) => entry.isNotEmpty)     // ← '$k=$v' 至少含 '='，恒为 true
    .toList();
```
本意大概是过滤空值，实际什么都没过滤 —— `{"a": null}` 会渲染成 `a=null` 给用户看。应改为对 value 用 `_stringifyDetailValue`（3045 行已有且会正确处理 null）。

### G-3 值类型普遍缺 `==` / `hashCode` 【P2】
本区间内**零个**类实现了 `==`/`hashCode`：
`HistoryToolDetailGap`(2020)、`HistoryWindowInfo`(2323)、`HistoryEntry`(2345)、`HistoryToolDetail`(2396)、`ToolSuggestionApp`(2482)、`PermissionPresentation`(2617)、`WindowInfo`(3216)、`DebugTraceEvent`(3252)、`DebugBundleSession`(3281)、`DebugReproRecipe`(3319)、`DiffImageChange`(3431)、`ArchivedSessionRecord`(3698)、`PromptHistoryServerEntry`(3828)、`PromptHistoryClientStat`(3912)、`PromptHistorySessionStat`(3938)。
- 项目按 CLAUDE.md 用的是 Bloc/Cubit（`chat_session_cubit.dart` 等）。这些对象一旦进入 state，`==` 走 identity ⇒ 每次重新解析都判定为"变了" ⇒ **无条件重建**（历史长列表场景下明显掉帧）；反过来若上层用 `Set`/`Map` 去重（如 `ToolSuggestionApp`、`HistoryToolDetailGap`），去重完全失效。
- 与 C-2/C-3 叠加：没有 `==` 就无法用它们做可靠的缓存键。
- **修复**：这些是纯数据类，直接上 `freezed`（项目 `/flutter-ui-design` 技能已规定 Bloc/Cubit + Freezed），或至少手写 `==`/`hashCode`。

### G-4 手写 fromJson 与生成代码的健壮性姿态不一致 【P3】
- 本文件 4000 行全部是**手写** `fromJson`，防御水平从"极严谨"（`HistoryToolDetailGap.fromJson` 2037-2071：长度上限、去重、忽略非法项、不信任 wire 的 count）到"完全裸奔"（`WindowInfo` 3229、`DiffImageChange` 3460）跨度极大。
- 同仓库的 `lib/models/machine.g.dart:38` 是 json_serializable 生成的 `DateTime.parse(json['lastConnected'] as String)` —— 生成代码天然抛异常。**两套姿态混用**，导致 review 时无法用统一规则判断"这里该不该防"。
- **修复方向**：给本文件建立一套强制的解析原语并全量替换：`_str()` / `_int()` / `_num()` / `_boolOr()` / `_map()` / `_list<T>()` / `_instant()`，禁止在 `fromJson` 中出现裸 `as`。这一条能一次性消掉 A 类和 B-2 的绝大部分。

### G-5 `toJson` 只在部分类上存在，且用了 Dart 3.9 的 null-aware element 【P3】
`messages.dart:3891-3909`、`3931-3935`、`3954-3957`
```dart
'favoriteUpdatedAt': ?favoriteUpdatedAt,
'deletedAt': ?deletedAt,
```
- `?key` 语法（null 时省略该 entry）依赖较新的 Dart SDK；同区间内其他同类（`ArchivedSessionRecord` 3698、`DiffImageChange` 3431）却没有 `toJson`。序列化能力不对称，未来做本地缓存时会出现"能存 prompt history 但存不了 archive"的坑。

---

## 建议的修复优先级

1. **P0**：A-1（HistoryEntry 改为可空 + 调用点跳过坏条目）、A-2（`input['command']` 改用 `_nonEmptyString`/`_stringifyDetailValue`）。
2. **P1**：F-4（永远保留拒绝出口）、F-1/F-2（Guardian 枚举兜底方向）、A-7（审批 getter 全改 `_nonEmptyString`）、A-5、B-1、B-2、E-2、C-1、A-3、A-4。
3. **P2**：A-6/A-8~A-12、D-1/D-2/D-3、E-1、C-2~C-4、F-3、G-3。
4. **P3**：E-3、G-1、G-2、G-4、G-5。

其中 **G-4 的"解析原语统一化"是杠杆最大的一项**：它同时消灭 A-1、A-3~A-11 与 B-2，把"additive 协议"从口头约定变成类型层面的保证。
