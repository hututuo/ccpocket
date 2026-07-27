I'll start by mapping out both directories.
Now let me build a fact base with targeted greps while delegating deep reads.
Now I'll read the protocol slots myself, starting with the known problem file.
I have completed my own pass over both directories. Waiting on the four parallel deep-read agents for `messages.dart` and the four large `utils/` files.
Agent 1 (messages.dart 1–2000) returned. Waiting on the remaining three.
Verified agent 1's key claims against source. Waiting on agents 2–4.
Agent 2 (messages.dart 2000–4000) returned. Waiting on agents 3 and 4.
Agent 3 (messages.dart 4000–5922) returned. Only the `utils/` agent remains.
四个并行深读代理已全部返回，我自己完成了 30 个 model 文件中 26 个 + 15 个 utils 文件的逐行阅读。以下是合并去重后的完整结果。

---

# 前提：爆炸半径基线（决定本报告所有严重度）

`ServerMessage.fromJson`（`models/messages.dart:953`）**自身没有 try/catch**。唯一保护在 `services/bridge_service.dart:1431`（`try`）… `:1872`（`} catch (e, st)` → `ErrorMessage(message: 'Parse error: $e')`）。

| 半径 | 含义 |
|---|---|
| **R1 单帧** | 抛异常 → 该 WebSocket 帧整体丢弃 + 用户看到红色 "Parse error" 气泡（含 Dart TypeError 原文）。stream 不死。 |
| **R2 整批** | 异常发生在 `session_list` / `history*` / `recent_sessions` / 各 slot 的 `.map()` 元素解析里 → **一条坏元素 = 整张列表 / 整段历史 / 整页快照消失**，且不重试。 |
| **R3 逃逸** | `List.cast<String>()` 惰性视图、或在 widget getter 里解析 → 异常在 **build 期**抛出，**绕过 bridge_service 的 catch** → 红屏 / 该页面永久不可用。 |
| **R4 挂起** | 抛出点在 completer 完成逻辑（`bridge_service.dart:1436-1447`）之前 → **Completer 永不完成**，只能等超时，UI 永久转圈。 |

各 slot 的 `LocalFeatureProtocolHost.tryDecode`（`protocol_host.dart:129-143`）额外加了一层：slot 返回 null 时**主动 throw FormatException**，所以 slot 内的严格校验一律升级成 R1 以上。

---

# A. 反序列化健壮性（最高优先级）

## A-1 严格 key 白名单：收到新字段就抛异常（协议 additive 要求的直接违反）

用户已知的 `ephemeral_side_chat_protocol_slot.dart` **不是孤例，共 4 套、覆盖 6 个 feature、19 个消息类型**。

### [A01] P1 · `side_chat_protocol_slot.dart:508-513` — `_sideChatRequireOnlyKeys` 家族

```dart
void _sideChatRequireOnlyKeys(Map<String, dynamic> json, List<String> allowed) {
  final allowedSet = allowed.toSet();
  if (json.keys.any((key) => !allowedSet.contains(key))) {
    throw const FormatException('Side chat message contains unknown fields.');
  }
}
```
- **调用点（11 处）**：`side_chat_protocol_slot.dart:127, 152, 175, 200, 242`；`ephemeral_side_chat_protocol_slot.dart:104, 170, 231`；`persisted_side_chat_protocol_slot.dart:94`
- **触发**：新 Bridge 给 `side_chat_event` 加一个 `latencyMs`，或给 `EphemeralSideChatEntry` 加 `model` 字段。
- **半径**：R1；但 `side_chat_event` 若出现在 `history` 数组内（`messages.dart:1139-1141` 逐条 `ServerMessage.fromJson`）→ **升级为 R2，整段会话历史消失**。
- **修复**：删除白名单校验，改为只校验"必需字段存在且类型正确"，未知 key 一律忽略。

### [A02] P1 · `file_transfer_protocol_slot.dart:583-592` — `_fileTransferRequireExactKeys`
```dart
for (final key in json.keys) {
  if (!allowed.contains(key)) {
    throw FormatException('file transfer message has unknown field $key');
  }
}
```
- 调用点：`:74, 147, 227, 292, 370`，覆盖全部 6 种 `file_transfer_*_v2/v3` 消息。
- 注意 `:369-380` 已经用 `if (includesSavedPath) 'savedPath'` 做了 v2/v3 版本分叉 —— 说明作者清楚字段会增长，但解决方式是"每加一个字段就发一个新 type"，而不是让旧客户端忽略它。**这条设计本身就把 additive 协议变成了 breaking 协议。**

### [A03] P1 · `file_browser_protocol_slot.dart:1251-1260 / 1202-1214` — 最严重的一处
```dart
_fileBrowserRequireExactKeys(json, <String>{
  'type', 'requestId', 'success', 'errorCode', 'error', ...payloadKeys,
});
```
`_fileBrowserResultEnvelope` 对**全部 6 种 result 消息**做整体白名单，`FileBrowserRoot.fromJson:186`、`FileBrowserNode.fromJson:243`、`FileBrowserStatResultItem.fromJson:622` 再各做一次**节点级**白名单。
- **触发**：Bridge 给 `FileBrowserNode` 加一个 `isHidden` / `ownerUid` 字段（文件浏览器最自然的演进）。
- **半径**：**R2** — 该字段出现在**每一个** node 上 → 整个目录列表帧丢弃 → 文件浏览器对新 Bridge **完全不可用**，且每次翻页都复现。
- 附带：`:1224-1229` 成功响应不允许出现 `error` key、`:1232-1238` 失败响应不允许出现任何 payload key —— 双向严格。

### [A04] P1 · `auto_approval_protocol_slot.dart:96-110` — 内联白名单 + 闭合值集
```dart
if (json.keys.any((key) => !allowedKeys.contains(key))) {
  throw const FormatException('Unexpected auto-approval state field.');
}
...
!const {'query','updated','disabled_all','legacy_imported','auto_approved'}.contains(reason)
```
新 `reason`（如 `'policy_changed'`）→ 整帧抛。

> **重要背景**：`test/features/file_browser/file_browser_protocol_test.dart:565-571`、`test/features/file_transfer/file_transfer_protocol_test.dart` 里有 `'rejects unknown fields at result, root, node, and stat-item levels'` 这类测试 —— **当前行为是被测试固化的有意设计**。修复时必须同步改测试，并需要一次明确的架构决策：是"严格解析防御恶意 Bridge"还是"宽松解析保证前向兼容"。二者不能兼得，目前文档（CLAUDE.md 的 Graceful Degradation 一节）只写了 App→Bridge 方向。

## A-2 未知枚举值抛异常（同类问题的第二种形态）

| 编号 | 级别 | 位置 | 问题 |
|---|---|---|---|
| **[A05]** | P1 | `side_chat_protocol_slot.dart:98-103` | `SideChatEventKind.parse` 未知事件 → `throw FormatException`。新增 `'compacting'` 事件 → 整条 `side_chat_event` 丢。 |
| **[A06]** | P1 | `conversation_content_protocol_slot.dart:43-48` | `ConversationContentEventKind.parse` 同上。 |
| **[A07]** | P1 | `file_browser_protocol_slot.dart:166-171` | `FileBrowserNodeKind.parse` 抛。**讽刺的是该枚举已定义 `other('other')` 成员**（`:161`）却不用作兜底。新增 `socket`/`fifo`/`blockDevice` → 整个目录列表 R2 丢失。改 `_ => other` 即可。 |
| **[A08]** | P2 | `file_browser_protocol_slot.dart:890-895` | `FileMutationAuthEvent.parse` 抛。 |
| **[A09]** | P1 | `codex_desktop_continuity_protocol_slot.dart:95-100` + `:305-306` | `parse` 正确回退到 `unknown`，但 `_validate` 里 `case unknown: throw const FormatException('Unknown Desktop continuity event.')` —— **兜底被自己抵消**。同文件 `:286-289` 要求 state 必须是 idle/running（新增 `compacting` 即抛）、`:269-273` 要求 `origin == 'desktop_rollout'`（新增 origin 即抛）。 |
| **[A10]** | P2 | `conversation_content_protocol_slot.dart:459-464`；`conversation_mirror_protocol_slot.dart:196-200, 315-319` | provider 硬白名单 `{'claude','codex'}`，第三个 provider 直接抛。 |
| **[A11]** | P2 | `codex_core_actions_protocol_slot.dart:205-215` | `action` 必须是 compact/review、`status` 必须在 4 值集内，否则整条 `codex_action_result` 抛。 |
| **[A12]** | P1 | `messages.dart:2568-2588` | `availableDecisions` 事实白名单：`canApprove` 要求含 `'accept'`、`canDecline` 要求含 `'decline'`/`'cancel'`。Bridge 改名为 `["approveOnce","rejectOnce"]` → **审批卡片上一个按钮都没有，会话永久卡死在 waiting_approval**（不可自愈，比丢帧严重）。additive 协议下默认必须是 permissive。 |

**[A13] P1 · 正确范式对照** — `conversation_mirror_protocol_slot.dart:114-119` 的 `ConversationMirrorEventKind` 有 `unknown('__unknown__')` 且 `_validate:497-498` 是 `case unknown: break`。**这是全仓库唯一做对的 slot**，应作为其余 6 个的模板。

## A-3 急切内层解码 / 元素级放大

### [A14] P0 · `conversation_content_protocol_slot.dart:106-124`
```dart
final entry = ConversationContentWireEntry(...);
entry.decodeMessage();   // ← :122，构造时立即全量解码内层 ServerMessage
return entry;
```
配合 `:199-212`：
```dart
rawEntries.whereType<Map>().map((entry) => ConversationContentWireEntry.fromJson(...))
...
if (rawEntries is List && entries.length != rawEntries.length) throw ...
```
- **问题**：32 条 entry 里任意一条的**内层**消息解析失败（含上面所有白名单 / 枚举问题）→ 整个 snapshot page / patch 抛出 → **revision 永不推进 → 会话内容镜像永久卡在旧版本**，且每次重试都失败。
- **不一致**：`conversation_mirror_protocol_slot.dart:135` 的 `decodeMessage()` 是**惰性 getter，构造时不调用**。两个近乎同构的 slot 采取了相反策略。
- **修复**：删掉 `:122` 的急切解码；`whereType<Map>()` 后逐条 try/skip 而非长度校验。

### [A15] P0 · `messages.dart:2350-2355` `HistoryEntry.fromJson` + 四个调用点
```dart
message: ServerMessage.fromJson(json['message'] as Map<String, dynamic>),
```
调用点 `messages.dart:1139-1141`（history）、`1155-1157`（history_page）、`1178-1180`（history_delta）、`1189-1191`（history_snapshot），全是无保护的 `.map()`。
- **一条坏 entry = 整页历史消失**；`history_page` 额外触发 R4（分页 completer 挂起，"加载更多"永久转圈）。
- **修复**：`fromJson` 返回 `HistoryEntry?`，调用点 `.whereType<HistoryEntry>()`。

### [A16] P0 · `messages.dart:4764, 4766, 4820-4822` `SessionInfo.fromJson`
```dart
id: json['id'] as String,
projectPath: json['projectPath'] as String,
...
toolUseId: permJson['toolUseId'] as String,
toolName: permJson['toolName'] as String,
input: Map<String, dynamic>.from(permJson['input'] as Map),
```
- 调用点 `messages.dart:1232-1234` 的 `session_list` `.map()`。
- **半径最大**：一个无 `projectPath` 的新型会话 → 整个 `session_list` 帧丢弃 → `bridge_service` 的 `_hasAuthoritativeSessionListForCurrentConnection` 永不置位 → **主页永久空白，重连也不恢复**。

### [A17] P0 · `messages.dart:1371, 1376`（另 `1338, 1411, 1430, 1603, 1605, 3349`）— `cast<String>()` 逃逸 try/catch
```dart
files: (json['files'] as List).cast<String>(),
projects: (json['projects'] as List).cast<String>(),
```
`List.cast<T>()` 返回**惰性 CastList**，类型检查发生在读取时 → 异常在 **build 期**抛出（R3），bridge_service 的 catch 完全捕获不到 → **红屏**，堆栈还指不回协议变更。
- **修复**：全部改 `.whereType<String>().toList(growable: false)`。

### [A18] P0 · `messages.dart:2733` + `2526-2540, 2594, 2600` — 对不可控 `input` 裸转 String
```dart
case 'Bash':
  final command = input['command'] as String?;      // :2733
String get suggestedToolName => input['toolName'] as String? ?? displayToolName;  // :2526
final serverName = input['serverName'] as String?;  // :2600
```
`input` 是任意 MCP server / 工具的入参。exec 类审批把 command 写成 argv 数组（`["bash","-lc","..."]`）极常见。
- 这些 getter 在 **widget build 期**被调用（`presentation` 是 `:2590` 的现算 getter）→ **R3 红屏 → 用户既看不到也无法批准/拒绝该权限请求 → 会话彻底卡死**。
- **同文件已有正确写法**：`_nonEmptyString`（`:2871-2875`）做了 `is! String` 检查，`default` 分支（`:2780-2786`）用的正是它 —— 只有手写的 Bash/MCP 分支裸转。

### [A19] P1 · 其余聚合放大清单（一坏全毁）

| 位置 | 内层裸转 | 后果 |
|---|---|---|
| `messages.dart:1285-1287` | `RecentSession:4402 sessionId as String` | 整个 recent 列表消失 |
| `messages.dart:1306-1308` → `4271-4274` → `AssistantContent.fromJson:32-37` | `json['type'] as String` / `text` / `id` / `name` / `input as Map` | 整段 `past_history` 消失。注意 `_ =>` 兜底（`:42`）**只在 type 为"非 null 的未知字符串"时生效**，type 缺失或 text 缺失在进 switch 前就抛 |
| `messages.dart:1311-1316` → `ImageRef:626-628` | id/url/mimeType 三裸 | 整个图库空 / `message_images_result` 整帧丢 |
| `messages.dart:1319-1321` → `WindowInfo:3229` | `windowId as int` | 截图选窗列表全空 |
| `messages.dart:1385` → `DiffImageChange:3460` | `filePath as String` | **整条 `diff_result` 丢失，连纯文本 diff 一起没了** |
| `messages.dart:1400-1402` → `WorktreeInfo:650-652` | 三裸 | worktree 列表空 |
| `messages.dart:1452-1454` → `UsageInfo:737-738, 761` | `(json['utilization'] as num).toDouble()` / `resetsAt as String` / `provider as String` | 整个额度面板不可用 |
| `messages.dart:1163-1171` → `HistoryToolDetail:2412-2428` | `input as Map?` | R4：工具详情 completer 挂起 |
| `messages.dart:1502/1515` → `PromptHistoryServerEntry:3872-3888` | 双层 `as Map<String,dynamic>` | **同步 revision 不推进，反复重试仍失败（永久卡住）** |
| `subagents_protocol_slot.dart:192-199` | `ServerMessage.fromJson` 无逐条保护 | 整个子 Agent 历史丢失 |
| `conversation_mirror_protocol_slot.dart:502-516` | `_conversationMirrorEntryList` 逐条 throw | 整页 mirror snapshot 丢失 |

### [A20] P1 · `messages.dart:1115` — `error` 帧自己的 message 是裸 `as String`
```dart
message: json['message'] as String,
```
Bridge 发一条只有 `errorCode` 无 `message` 的结构化错误 → TypeError → 变成 `Parse error: type 'Null' is not a subtype of 'String'` → **真实 errorCode 丢失 → `chat_message_handler.dart` 的 `unsupported_message` 分支永远匹配不到 → CLAUDE.md 里那套 Graceful Degradation 机制整体失效**。

### [A21] P1 · `diff_parser.dart:558, 569-570, 586-587, 595` — 裸 `as String`
```dart
final filePath = (input['file_path'] ?? input['path'] ?? '') as String;   // :558
final content  = (input['content'] ?? '') as String;                       // :595
```
在 `assistant_bubble.dart:841` 的 `_editDiff` getter 里同步调用，而它在 `build()` 中求值 → **R3 红屏，且 `_editDiffResolved` 已置 true 无法恢复**。函数注释声称"malformed 时返回 null"，实际做不到。

### [A22] P2 · 三种"字符串列表"写法并存，行为完全不同
```dart
messages.dart:1011  skills:  (json['skills']  as List?)?.map((e) => e as String).toList()   // 抛
messages.dart:1031  plugins: (json['plugins'] as List?)?.whereType<String>().toList()       // 跳过
messages.dart:1371  files:   (json['files']   as List).cast<String>()                        // 延迟抛（R3）
```
`slashCommands`/`skills`/`apps` 会因一个 null 元素炸掉整条 `system` 帧（= 会话初始化失败），而紧邻的 `plugins` 不会。

### [A23] P2 · `request_user_input.dart:41, 51, 62, 65, 72-77` — 全有或全无
任何一个 question / option 不合法 → `return const []` → **全部问题被丢弃**（而非跳过坏的那一个）。`side_chat_protocol_slot.dart:182-185` 随后用 `questions.length != rawQuestions.length` 把它升级成 throw。

### [A24] P2 · 其余单帧裸转（R1）
`messages.dart:1061, 1078, 1122-1123, 1148-1151, 1224, 1227, 1229-1230, 1333, 1358, 1391-1392, 1406, 1409, 4400, 4760, 4812-4817, 4854`；`machine.g.dart:11, 30, 32, 38`；`recorded_event.dart:39-41`（有 per-line try/catch，安全）。

---

# B. 时间与时区

### [B01] P1 · `messages.dart:929, 937-939, 941` — 核心时间戳解析没有 UTC 兜底
```dart
final receivedAt = DateTime.tryParse(json['receivedAt'] as String? ?? '');
final sourceTimestamp = DateTime.tryParse(json['sourceTimestamp'] as String? ?? '');
```
`DateTime.tryParse('2026-07-25T10:00:00')`（无 Z / 无 offset）返回 **`isUtc == false` 的本地时间**。随后 `messages.dart:5873` 的 `.toLocal()` 对它是 **no-op**，错误被固化。Bridge 在东京 Mac、手机在上海 → 全部消息时间戳偏 1 小时；这些时间戳**不只用于展示，还参与排序与去重**。

### [B02] P1 · `toLocal()` / `toUtc()` 三处策略互斥
| 位置 | 策略 |
|---|---|
| `messages.dart:5873` `ServerChatEntry` | `.toLocal()` |
| `session_list_projection.dart:230-236` | `.toUtc()` |
| `unseen_sessions_cubit.dart:207` | `.toUtc()` |
| `chat_message_handler.dart:306` / `session_archive_screen.dart:163` | `.toLocal()` |

对 B01 的 naive 串，`toUtc()` 会**再叠加一次本地偏移**，`toLocal()` 是 no-op → **同一条消息在"会话卡片"和"聊天气泡"上算出的时刻相差一个时区偏移**。

### [B03] P1 · ISO 字符串按字典序比较（用户已知的两处之外，models/utils 内确实还有）
- `messages.dart:4328-4329` `RecentSession.created/modified` 存为裸 `String` → `session_list_cubit.dart:706-708` 直接 `right.modified.compareTo(left.modified)`。
- `messages.dart:3914, 3939` `PromptHistoryClientStat/SessionStat.lastUsedAt` 存为裸 `String` → `prompt_history_service.dart:19-20` 的 `_maxIso` 用 `compareTo`。
- **失败例**：`2026-07-25T19:00:00+09:00` 与 `2026-07-25T10:00:00Z` 是同一时刻，字典序里 `'1' > '0'` 前者胜；反向 `'+'`(0x2B) < `'Z'`(0x5A) 时后者胜；小数秒位数不同（`.1Z` vs `.100Z`）同样错序。
- 更糟：缓存层 `session_catalog_cache_repository.dart:587-591` 用的是 `DateTime.tryParse(...).toUtc().millisecondsSinceEpoch` → **缓存渲染与实时刷新排序不一致，列表会"跳动"**。

### [B04] P2 · `file_transfer_protocol_slot.dart:669-675` vs `file_browser_protocol_slot.dart:1398-1405` — 同层两套时间戳契约
```dart
// file_transfer：只要能 parse 就行，不要求 Z
if (DateTime.tryParse(timestamp) == null) throw ...

// file_browser：强制 Z + isUtc
if (!text.endsWith('Z') || parsed == null || !parsed.isUtc) throw ...
```
`file_transfer` 的 `expiresAt` 随后在 `file_transfer_service.dart:1602` 再次 `DateTime.tryParse`，并在 `:926, :1002, :1181, :2284` 与 `_clock().toUtc()` 比较 → **无 Z 时签名 URL 过期判断整体平移一个时区偏移**（要么提前判定过期使预览全挂，要么拿着失效 URL 反复请求）。

### [B05] P2 · `session_insights_protocol_slot.dart:218-219, 338-339`
```dart
DateTime? get resetsAtDateTime => resetsAt == null ? null : DateTime.tryParse(resetsAt!);
DateTime? get expiresAtDateTime => expiresAt == null ? null : DateTime.tryParse(expiresAt!);
```
同 B01。额度重置倒计时会差一个时区。

### [B06] P2 · `machine.g.dart:38, 63` — 本地 DateTime 往返丢时区
```dart
lastConnected: DateTime.parse(json['lastConnected'] as String),   // :38
'lastConnected': instance.lastConnected?.toIso8601String(),       // :63
```
`toIso8601String()` 对 local DateTime **不写偏移量**。用户跨时区后，磁盘上的值被按新时区重新解释 → `lastConnected` 整体漂移。另：Dart 的 `DateTime ==` 同时比较 `isUtc` 标志，`Machine` 的 freezed `==` 会因此产生虚假不等 → 无谓重建。

### [B07] P3 · `utils/diff_parser.dart` / `composer_tokens.dart` / `history_window_policy.dart` / `tool_categories.dart` **完全不涉及时间**（已逐一确认，排除误报）。

---

# C. 身份与键构造

### [C01] P1 · `messages.dart:230-231` — 全局身份键缺 bridge 维度
```dart
String providerSessionIdentityKey(String provider, String sessionId) =>
    '$provider\u0000$sessionId';
```
调用点：`session_list_projection.dart:194, 202`、`session_archive_cubit.dart:12`、`session_list_screen.dart:1665`、`home_content.dart:978`。

**同仓库三套 key 三种维度**：
| 用途 | 维度 |
|---|---|
| `providerSessionIdentityKey` | provider + sessionId |
| `session_list_cubit.dart:46-56` `sessionPinKey` | provider + **projectPath** + sessionId |
| `session_catalog_cache_repository.dart:15-28` 缓存分区 | **bridgeInstanceId**（sha256） |

- **触发**：家里 Mac + 公司 Mac 两个 Bridge；或 `~/.claude/projects` 被 iCloud/rsync 同步到两台机器 → 同一 sessionId 出现在两个 Bridge、两个 projectPath 下 → 去重时合并成一条，另一条**静默消失**；归档一个会同时归档另一个。
- **`bridgeInstanceId` 明明已经拿到了**（`messages.dart:1235` 从 `session_list` 帧解析），只是没下发到 `SessionInfo` / `RecentSession` 条目上。
- **注**：全仓库 `models/` + `utils/` 内 **grep 不到任何 `sourceHome`** —— 这个维度根本不存在。

### [C02] P1 · `conversation_content_protocol_slot.dart:60`
```dart
String get key => '$provider\u0000$providerSessionId';
```
`ConversationContentEventMessage` 的 `bridgeInstanceId`（`:155`，required）就在同一条消息上，却**没有进订阅键**。多 Bridge 场景下两边的 revision 会互相覆盖。

### [C03] P1 · `messages.dart:3828-3841` — `PromptHistoryServerEntry` 丢弃 bridgeInstanceId
`bridgeInstanceId` 只在信封上（`:3962`、`:3982`），`fromJson`（`:3859`）解析后就丢掉。`sessionStats` 的 key 是裸 sessionId。合并逻辑 `prompt_history_service.dart:608-621` 按文本合并、`:128/:141` 无条件 `useCount + other.useCount` → **跨机器的提示词使用次数互相污染**。

### [C04] P2 · `history_window_policy.dart:419-425` — `historyToolDetailGapId` 只哈希 toolUseIds
```dart
final digest = sha256.convert(utf8.encode(jsonEncode(toolUseIds))).toString().substring(0, 24);
return 'tool-gap-v1:${toolUseIds.length}:$digest';
```
无 provider / bridgeInstanceId / sessionId。Codex 的 `call_1` / `item_0` 这类短序号 id 极易跨会话重复 → gapId 碰撞。另 `jsonEncode(List)` 顺序敏感，`[a,b]` 与 `[b,a]` 产出不同 id → 重放历史时 gapId 抖动。**修复**：入参加 sessionId/provider，ids 先 `..sort()`。

### [C05] P2 · `history_window_policy.dart:126, 245` — 用列表下标当稳定 ID
```dart
id: 'streaming-window-$index',          // :126
id: 'history-tool-gap-$sourceIndex',    // :245
```
分页 prepend 更早历史 → 所有 index 位移 → 同一条 gap 气泡 id 从 `history-tool-gap-40` 变成 `-140` → 下游按 id 做 dedupe/ValueKey/滚动锚点的逻辑全部认为是新消息 → 重建 + 滚动跳变。两个 session 同屏时必然碰撞。

### [C06] P2 · `messages.dart:2016-2017` — `artifactMessageId` 只有 message id
```dart
String get artifactMessageId => message.id.isNotEmpty ? message.id : messageUuid?.trim() ?? '';
```
`AssistantMessage.id` 已在 `:88` 降级为 `?? ''` → 可能返回 `''`，所有无 id 的消息共用一个桶，附件互相串台。无 provider / sessionId / bridgeInstanceId 维度。消费点 `chat_session_cubit.dart:3218-3219`、`file_peek_sheet.dart:702`。

### [C07] P2 · `messages.dart:4021-4128` — 全部 Git 结果消息缺关联维度
`GitStage/Unstage/Commit/Push/Branches/CreateBranch/CheckoutBranch/RevertFile/RevertHunks/Fetch/Pull/RemoteStatus` **全部没有 `projectPath` 也没有 `requestId`**；只有 `GitStatusResultMessage`（`:4130-4161`）带了。而 `git_view_cubit.dart:604` / `branch_cubit.dart:63` 都是无过滤订阅 broadcast stream → **同时打开两个项目的 Git 面板时结果串台**。

### [C08] P2 · `file_browser_protocol_slot.dart:8, 103, 420`
```dart
const String fileBrowserOwnerSessionId = '__file_browser__';
```
全部文件浏览器请求共用这一个常量 ownerSessionId，correlation 只靠 requestId。切 Bridge 时旧 Bridge 的迟到响应仍可匹配。

### [C09] P2 · `messages.dart:4010-4017` — `MessageImagesResultMessage` 只有 `messageUuid`
请求侧 `:5590-5597` 明明发了 `claudeSessionId`，响应丢了。历史 fork 后同一 uuid 存在于父/子两条线 → 串图。

### [C10] P3 · `network_endpoint.dart:29-30` — IPv6 zone id 未小写
```dart
final zone = zoneIndex == -1 ? '' : normalized.substring(zoneIndex);
return '${_canonicalIpv6Address(address) ?? address.toLowerCase()}$zone';
```
`fe80::1%eth0` 与 `fe80::1%ETH0` 被当作两台不同机器。另 `machine.dart:173` 的 `uniqueKey` 只有 host:port，不含 `useSsl` → ws 与 wss 两条记录去重成一条。

---

# D. 路径处理（全仓库无统一规范化函数，共 7 套并存）

### [D01] P1（安全）· `terminal_launcher.dart:16-20` — 模板注入，路径完全不转义
```dart
return template
    .replaceAll('{{host}}', host)
    .replaceAll('{{user}}', user)
    .replaceAll('{{port}}', port.toString())
    .replaceAll('{{project_path}}', projectPath);
```
配合 `terminal_app.dart:36-37` 的内置模板：
```dart
"blinkshell://run?key=ssh&cmd=ssh {{user}}@{{host}} -t 'cd {{project_path}} && \$SHELL'"
```
- **触发**：项目路径含单引号（如 `/Users/x/it's a project`）→ 直接**逃出 shell 引号，在远端终端里执行任意命令**。含 `&` / `?` / `#` / 空格则破坏 URL 结构。
- 另：`terminal_launcher.dart:47` 的 `Uri.parse(url)` **在 try 块之外**（try 从 `:51` 才开始）→ FormatException 未捕获。
- **修复**：`Uri.encodeComponent` + shell 单引号转义（`'` → `'\''`），并把 `Uri.parse` 移进 try。

### [D02] P2 · 7 套互不兼容的规范化策略并存

| 位置 | 策略 |
|---|---|
| `messages.dart:4307-4313` `pathBasename` | `\`→`/` + 忽略空段 + 忽略尾斜杠 |
| `tool_categories.dart:329-330, 338-340` | **只认 `/`**；尾斜杠 → 返回**空字符串**；Windows 路径返回整条长串撑爆摘要栏 |
| `file_browser_protocol_slot.dart:1342-1369` | **禁止 `\`**、禁止 `C:`、禁止 `.`/`..` 段 |
| `artifact_link_matcher.dart:90-101` `isSafeProjectRelativePath` | `split(RegExp(r'[\\/]'))` 双分隔符 |
| `artifact_link_matcher.dart:27-56` `artifactHrefsEquivalent` | percent-decode 一次 + 精确相等，无路径归一 |
| `offline_pending_action.dart:26-31` `projectName` | 只 `split('/')` |
| `session_list_projection.dart:127, 163` | **裸字符串 `!=` 比较**（零归一化） |

- **共同缺失**：无 `~` 展开、无尾斜杠归一、无 macOS 大小写折叠、无 Unicode NFC/NFD 归一（macOS APFS 返回 NFD，用户输入是 NFC）、无 realpath（`/Users/x` vs `/System/Volumes/Data/Users/x`）。
- **后果**：`projectPath` 被当作 Map/Set key 用在 `session_list_screen.dart:162-165`、`session_list_cubit.dart:50`、`session_list_state.dart:32-51`（5 个 `Set<String>`）→ **同一项目被拆成两组，置顶/折叠/筛选全部失效**；`file_browser` 侧 `'${item.rootId}\u0000${item.relativePath}'`（`:719`）大小写敏感 → 与响应比对失败被静默丢弃。
- **修复**：抽一个 `String canonicalProjectPath(String)`，所有**比较**与**字典键**统一走它。

### [D03] P2 · `diff_parser.dart:688-693` — `lastIndexOf(' b/')` 取错路径
```dart
final newPathMarker = payload.lastIndexOf(' b/');
if (newPathMarker >= 0) return _decodeGitPathToken(payload.substring(newPathMarker + 1));
```
`diff --git a/docs/a b/c.md b/docs/a b/c.md` → `lastIndexOf` 命中的是**新路径内部**的 ` b/` → 返回 `c.md`。后果：`reconstructDiff` 写出的 header 指向不存在的文件 → **`git apply` 失败或 request-change 被静默丢弃**。修复：按 `payload.length` 对半切（git 保证两侧等长同名）。

### [D04] P2 · `diff_parser.dart:666-678` vs `738-796` — 解码/编码不对称
`_decodeGitPathToken` 会解码八进制转义、去引号，`_writeFileHeader` 写回时**不重新编码** → 含空格/非 ASCII/引号的路径经一次 parse→reconstruct 就产出不可解析的 patch。`filePath` 为空时输出 `diff --git a/ b/`。

### [D05] P2 · `messages.dart:2903-2914` `_changePaths` — 审批文案计数虚高
无去重、无归一。`/a/b.dart`、`/a/./b.dart`、`~/proj/a/b.dart`、`/A/B.dart` 被当作 4 个文件 → `_fileChangeSummary`（`:2916-2920`）显示 **"Allow changes to 4 files"，实际只有 1 个**。这是安全审批文案，误导性直接影响用户判断。

### [D06] P2 · `messages.dart:2769-2777` — `grantRoot` 与 changes 未同域归一
两者原样并列展示，用户在审批界面**看不出这个文件是否真的在授权根之内**。

### [D07] P3 · `debug_bundle_share.dart:227-231`
```dart
final parts = line.split(' ');
var file = parts[2];
```
`diff --git a/my file.txt b/my file.txt` → `parts[2] == "a/my"` → 输出 `my`。不处理 git 的 C-quoted 路径。

### [D08] P3 · `diff_parser.dart:744-746` — 无条件剥 `a/`/`b/`；`:265-277` 三条 `+++` 分支解码方式不一致，且循环不在首个 `@@` 处停止。

---

# E. 数值与边界

### [E01] P1 · `composer_tokens.dart:191-221 + 390-396 + 404` — O(n²) 扫描 × 每字符编译正则 → 主线程冻结
```dart
if (category == null) { index++; continue; }           // :206-209  不前进到 end
...
while (cursor < text.length && !_isWhitespace(text[cursor])) cursor++;   // :392
bool _isWhitespace(String value) => RegExp(r'\s').hasMatch(value);       // :404  每次新建正则
```
- **触发**：粘贴一段**无空白**长文本，含反复出现的边界字符 + 触发符（如 `:$a:$b:$c…`，`:` 在 `:401` 的边界集合内）。每个 `$` 都触发 `_findTokenEnd` 扫到字符串末尾 → O(n)；`_resolveCategory` 返回 null 只 `index++` → 下一个 `$` 重复扫描 → **O(n²)**，且内层每次比较都新建并编译一个 RegExp。
- `buildTextSpan`（`:257`）**每帧/每次按键重跑，无缓存**。100KB 无空白文本 ≈ 2.5e9 次正则编译 → UI 完全冻结。
- **注意**：正则本身（`\s`、字符类、hunk header）均为线性，**不存在灾难性回溯 ReDoS**；DoS 来自扫描算法与正则分配。
- **修复**：① `RegExp` 提为 `static final`；② `:208` 的 `index++` 改 `index = end`；③ 按 `(text, config)` memo；④ 超长文本设上限。

### [E02] P1 · `diff_parser.dart:181` vs `190` — `contains` / `startsWith` 不对称，diff 整体变空
```dart
if (!diffText.contains('diff --git')) {      // :181  无尾空格
  return [_parseSingleFileDiff(lines)];
}
if (!lines[i].startsWith('diff --git ')) {   // :190  有尾空格
```
Edit 工具修改了一个**内容里提到 `diff --git`** 的文件（README、本项目 CLAUDE.md、任何 patch 文档）→ 该串出现在 `+` 前缀行内 → `:181` 判为多文件模式，但无行 `startsWith('diff --git ')` → while 空转 → **`parseDiff` 返回 `[]`，Git 面板完全空白且无任何错误提示**。

### [E03] P1 · `history_window_policy.dart:405-416` — 硬上限可被突破 + 丢掉全部最新回复
```dart
for (var index = 0; index < projected.length; index++) {
  if (projected[index].message is UserInputMessage) selected.add(index);   // :406-408 无上限
}
for (var index = projected.length - 1; index >= 0 && selected.length < limit; index--) { ... }
```
用户消息数 ≥ `limit` 时第二个循环守卫从一开始就为 false → 返回条目数 > `maxRetainedEntries`（硬上限失效），且**结果里一条 assistant 消息都没有，包括最新那条回复**。默认 `rootTurns=5` 使其暂不可达，但 `:57-59` 允许 clamp 到 755。

### [E04] P1 · `messages.dart:2590, 2612, 2614, 2640` — `presentation` 无缓存，每帧全量 JSON 编码
```dart
PermissionPresentation get presentation => PermissionPresentation.from(this);   // :2590
final rawDetails = const JsonEncoder.withIndent('  ').convert(input);           // :2640
```
`summary` 和 `detailLines` 各调一次 → **一次 build 至少 2 次完整带缩进 JSON 编码**。Write 审批的 input 可能是几 MB 整文件内容 → 明显掉帧甚至 OOM。改 `late final` 即可。

### [E05] P2 · `as int?` 不接受 JSON 浮点（系统性）
`jsonDecode` 对 JSON 里的 `1.0` / `1e5` 一律产出 `double`，Dart 的 `as int?` **不做数值转换直接抛 TypeError**。Bridge 是 Node/TS，任何经过除法或 `Math.*` 的计数都可能变成 `1.0`。
- **有问题**：`messages.dart:690, 1105-1109, 1150-1151, 1176-1177, 1187-1188, 1203, 1443, 1523-1524, 1647-1653, 2339, 2352, 3229, 3864, 3925, 3949, 4071-4073, 4200, 4280`
- **同文件已有正确写法**：`:839, 842, 845, 846`（`ArtifactRef`）、`:1101-1102`、`:1216`、`:1294-1295`、`:1301` 用的是 `(json[x] as num?)?.toInt()`；`conversation_mirror_protocol_slot.dart:568` 用的是 `raw is! num || raw.toInt() != raw` —— **一个文件内三套风格并存**。

### [E06] P2 · `subagents_models_slot.dart:80-92` vs `session_insights_protocol_slot.dart:495-511` — 同构 helper 一个防了一个没防
```dart
// subagents_models_slot.dart:82-90  无 isFinite、无 RangeError 捕获
if (value is num) {
  final milliseconds = value.abs() < 100000000000 ? value.toInt() * 1000 : value.toInt();
  return DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true).toIso8601String();
}

// session_insights_protocol_slot.dart:497-508  两者都有
if (value is num && value.isFinite) {
  ...
  try { return DateTime.fromMillisecondsSinceEpoch(...).toIso8601String(); }
  on RangeError { return null; }
}
```
`subagents` 版：NaN/Infinity → `UnsupportedError`；超大数 → `RangeError` → **整个子 Agent 列表丢失**。
同类：`session_insights_models_slot.dart:108-112` 的 `_sessionInsightsIntOrNull` 缺 `isFinite`，而 `session_insights_protocol_slot.dart:489-493` 的同名同构函数有。

### [E07] P2 · `diff_parser.dart:313-314` — `int.parse` 无 tryParse
```dart
final oldStart = match != null ? int.parse(match.group(1)!) : 1;
```
正则 `\d+` 不限位数 → `@@ -99999999999999999999,1 +1,1 @@` 抛 **FormatException**；Web(dart2js) 则静默精度丢失。`parseDiff` 全链路无 try/catch，异常直达 `git_view_cubit.dart:86/108`。

### [E08] P2 · `diff_parser.dart:399-428` / `361-364` — 内容行被吞
- `:399/408/417` 三个分支都用 `startsWith('+++')` 排除文件头 → 新增一行内容为 `++i;`（C/C++/Dart 自增、Markdown `++mark++`）的 diff 行是 `+++i;` → **三个分支全不匹配，该行完全丢弃**，既不显示也不计入 stats。
- `:361-364` 把空行当"尾随换行"跳过 → `oldLine`/`newLine` 不递增 → **该 hunk 后续所有行号少 k**（k = 空行数）。

### [E09] P2 · `messages.dart:2817-2840` `_flattenPermissionValues` — 无深度/体积上限
无递归深度上限（深嵌套 JSON → **StackOverflow，Dart 里不可捕获恢复，直接杀 isolate**）；无输出条数上限（`:2950` 的 `join(', ')` 可产生数 MB 单行 → UI 卡死）。恶意/异常 MCP server 即可触发。

### [E10] P2 · `machine.dart:29-33` — 预发布版本号被当作 0
```dart
final officialCore = version.replaceFirst(RegExp(r'-compat\.\d+$'), '');
return officialCore.split('.').map(int.tryParse).toList();
```
只处理本 fork 的 `-compat.N`。`1.67.4-rc.1` → `["1","67","4-rc","1"]` → `tryParse("4-rc") == null` → `?? 0` → 被当作 **1.67.0** → 错误地提示"需要更新 Bridge"。`1.67.4+build` 同理。

### [E11] P3 · 边界/正则确认无风险（避免后续重复排查）
- `messages.dart:2270-2278` 的正则两端锚定、`[^)]*` 否定字符类、无嵌套量词 → **线性，非 ReDoS**。
- `messages.dart:546` `word[0]`、`:3074` `part[0]`、`:2918/2924` `changes.first`、`:2292-2294` `field.substring`、`network_endpoint.dart:97` 位运算、`text_line_preview.dart:14-22`、`command_completion_matcher.dart:34`、`file_mention_matcher.dart:33-58`、`history_window_policy.dart:423` `substring(0,24)`（sha256 hex 恒 64 位）—— **均有正确的前置守卫，无越界风险**。
- `models/` + `utils/` 内**除 `diff_parser.dart:313-314` 外无其他 `int.parse`**。
- 轻度二次方回溯（P3，输入受限，可不修）：`codex_plan_update.dart:15` 的 `(.+?)\s*$`、`structured_error_inference.dart:83-85` 的 `(^|\n)\s*…`。

### [E12] P3 · 截断劈开代理对
`tool_categories.dart:350, 358, 367`、`messages.dart:3067-3077` `_titleCaseLabel`、`debug_bundle_share.dart:163` 均按 UTF-16 code unit 切 → emoji / 星平面字符被劈成半个代理对 → 渲染成豆腐块。建议用 `characters` 包按字素簇。

---

# F. 枚举兜底把未来值静默伪装成已知值

### [F01] P0 · `messages.dart:2211-2216` — `GuardianApprovalStatus.fromString` 兜底 `approved`（fail-open）
```dart
static GuardianApprovalStatus fromString(String? value) => switch (value) {
  'denied' => GuardianApprovalStatus.denied,
  'timedOut' => GuardianApprovalStatus.timedOut,
  'aborted' => GuardianApprovalStatus.aborted,
  _ => GuardianApprovalStatus.approved,     // ← 兜底方向选了最宽松的值
};
```
- **这是审批语义**。任何未知值（含 `null`、新增的 `escalated`/`pending`/`requiresUserConfirm`）全部渲染成 **"已批准"**。
- **额外脆弱点**：`'timedOut'` 是 camelCase，而同文件其余 wire 值普遍是 snake_case（`waiting_approval`、`notifications_only`、`on-request`）。Bridge 一旦规范化为 `timed_out`，**超时会被显示为已批准**。
- 消费点 `widgets/bubbles/guardian_approval_notice.dart:37-40` 直接据此选标题文案。虽不实际授予权限（授权在 Bridge 侧），但**向用户呈现了错误的安全结论**。
- **修复**：加 `unknown` 哨兵并作为兜底，UI 按"未批准/需人工确认"渲染。

### [F02] P1 · `messages.dart:2296-2300` — `unknown` 被当作"解析失败"直接丢弃整条安全通知
```dart
final risk = GuardianApprovalRisk.fromString(metadata['risk']?.toLowerCase());
if (risk == GuardianApprovalRisk.unknown || reason.isEmpty) return null;
```
`GuardianApprovalRisk.fromString`（`:2196-2202`）兜底 `unknown` 方向**是对的**，但这里把 unknown 当失败 → Bridge 新增 `'severe'`/`'blocker'` 后**整条 Guardian 通知气泡凭空消失**。风险越高越可能是新等级，越高的风险越会被吞掉。

### [F03] P1 · `messages.dart:113-122` — `ProcessStatus.fromString` 兜底 `idle`（用户已知）
```dart
_ => ProcessStatus.idle,
```
调用点 `:1135, 1182, 1193`。新增 `reviewing`/`waiting_input`/`queued`/`resuming` → 客户端认为会话空闲 → **放开输入框、隐藏停止按钮、可能误触发自动续跑，同时不显示 spinner**。这是行为性误判而非显示性。
另 `:1135` 是 `as String`（裸），`:1182/1193` 是 `!= null ? ... : null` —— 同字段三处写法不一致。

### [F04] P1 · `messages.dart:482-498` — Codex `defaultMode` → `acceptEdits`（权限**放宽**方向）
```dart
case ExecutionMode.defaultMode:
  return provider == Provider.codex
      ? PermissionMode.acceptEdits      // ← 默认(需确认) 被翻译成 自动接受编辑
      : PermissionMode.defaultMode;
```
向不认识 `executionMode` 的旧 Bridge 发 legacy `permissionMode` 时触发。另 `:4390, 4668` 的 `provider == Provider.codex.value` 二值化 → **任何未来的第三种 provider 都会被当成 Claude**。

### [F05] P1 · `messages.dart:1665` — 未知消息类型变成用户可见的红色错误气泡
```dart
_ => ErrorMessage(message: 'Unknown message type: ${json['type']}'),
```
追踪链路：该 ErrorMessage 的 `errorCode` 为 **null** → `bridge_service.dart:1868-1870` 走 `default:` → `chat_message_handler.dart:355-377` 三个条件都不成立 → 落到 `:376-377` 作为错误气泡渲染进聊天流。

**CLAUDE.md 里的 Graceful Degradation 机制（`_unsupportedActions` / `suppress`）只覆盖 App→Bridge 方向（新 App + 旧 Bridge）；反方向（新 Bridge + 旧 App）完全没有保护** —— 新 Bridge 每发一种新消息类型，旧 App 就刷一条红字。这恰恰是 additive 协议最该保证的场景。
**修复**：新增 `UnknownServerMessage implements ServerMessage { String type; Map raw; }` 替代，handler 默认 suppress。

### [F06] P2 · 其余静默伪装清单

| 位置 | 兜底 | 后果 |
|---|---|---|
| `messages.dart:143` `CodexThreadGoalStatus` | → `active` | 新终态被显示为"进行中" |
| `messages.dart:2162-2168` `SessionLinkResolutionStatus` | → `unavailable` | 新增 `archived`/`resuming` 时告诉用户"会话不可用"，误以为丢了 |
| `messages.dart:1838-1842` `BridgeClientDeliveryMode.fromWire` | 二值化 → `interactive` | 新增 `silent`/`paused` 时客户端继续要求全量流式，与 Bridge 节流意图相反 |
| `messages.dart:381-399` `_resolveCodexPermissionsMode` | 未知 → `custom` | 新增 `readOnly`/`planOnly` 显示为"Custom"，切换 UI 会用 custom 语义覆盖 |
| `messages.dart:450-469` `deriveExecutionMode` | 未知 → `defaultMode`；且 `:467` 硬编码 `'never'` 字面量（`:365` 用的是 `CodexApprovalPolicy.never.value` 常量） | 权限显示与实际不符 |
| `messages.dart:426-435` `resolveCodexApprovalPolicy` | `on-failure` → `on-request` | 用户"修改并保存"会把 `on-failure` 静默改写成 `on-request`（配置漂移） |
| `messages.dart:233-239` `sanitizeCodexModelName` | `'codex'` → null | 硬编码魔法串，Codex 若真用 `codex` 表示"跟随 profile"则模型丢失 |
| `codex_desktop_continuity_protocol_slot.dart:111-115` `CodexDesktopContinuityState.parse` | → `unknown`，但 `:286-289` 随后 throw | 兜底被抵消 |
| `tool_categories.dart:166 + 218` `getToolDisplayName` | SubAgent 归一化名在 default 分支被丢弃：`_ => name` 返回字面量 `"SubAgent"` 而非 `normalized` | **恰好破坏 `:157-159` 注释宣称的"Unknown tools retain their original name so newer Bridge versions remain forward compatible"**。改 `_ => normalized ?? name` 即可 |
| `tool_categories.dart:30-67` vs `160-220` | 别名集合不一致：`getToolDisplayName` 认 `spawn_agent`/`wait` 等小写变体，`categorizeToolName` **只认 PascalCase** | `spawn_agent` 标题正确但图标是通用扳手，`getToolCollapsedSummary` 走 `other` 分支返回 `''`，丢掉 `agent_name`；`'wait'` 的 `_waitSummary`（`:381-388`）永不被调用 |
| `composer_tokens.dart:46, 365-368` | `$` 触发符与 `Provider.codex` 硬绑定 | 第三个 provider 时 `$` token 静默失效 |
| `app_icon.dart:25-29` / `code_font_family.dart:13-18` / `git_diff_interaction_mode.dart:3-8` / `image_paste_shortcut.dart:3-8` | 均有默认兜底 | **本地设置项，兜底方向正确，无风险**（已确认，排除误报） |
| `notification_preferences.dart:37-47` | `_ => true` | **正确**：未知事件类型默认放行且有注释说明，是本仓库 additive 兜底的正面样本 |

---

# G. 其余常规问题

### [G01] P1 · `bridge_service.dart:1872-1876` — "Parse error" 气泡把 Dart 异常原文给用户看，且丢失 sessionId
```dart
} catch (e, st) {
  logger.error('WS parse error', e, st);
  final errorMsg = ErrorMessage(message: 'Parse error: $e');
  _taggedMessageController.add((errorMsg, null));   // ← sessionId 传 null
```
`:1434` 明明已取到 `json['sessionId']`，但在 try 内部、catch 块作用域外 → **错误无法归属到会话**。用户看到 `type 'Null' is not a subtype of type 'String' in type cast`。

### [G02] P2 · `messages.dart:4450-4482` — `toJson` 把**派生值**当权威值持久化
```dart
'executionMode': executionMode,                     // fromJson 缺失时由 deriveExecutionMode 推导
'codexSettings': {
  'approvalPolicy': codexApprovalPolicy,            // 由 resolveCodexApprovalPolicy 推导
  'codexPermissionsMode': codexPermissionsMode,     // 由 _resolveCodexPermissionsMode 推导
```
推导值写入 sqflite 缓存后，下次读缓存时 `codexPermissionsModeFromRaw` 认为这是**显式**值，走 `:383-386` 的 explicit 分支 → 推导逻辑不再生效。**App 升级后推导规则变了，老缓存里冻结的旧结论仍然生效且永不失效**。

### [G03] P2 · 大面积缺失 `==` / `hashCode`
- **有**：`CodexGoal:193-216`、`ArtifactRef:875-904`、`ReasoningEffort:551-557`、`NotificationPreferences:83-100`、`machine.freezed.dart`（生成）。
- **没有**（30+ 个）：`SessionInfo:4572`、`RecentSession:4315`、`PastMessage:4232`、`RecordingInfo:4176`、`GitBranchRemoteStatus:4058`、`ImageRef:617`、`GalleryImage:660`、`QueuedInputItem:695`、`UsageWindow:729`、`UsageInfo:746`、`WorktreeInfo:635`、`HistoryEntry:2345`、`HistoryWindowInfo:2323`、`HistoryToolDetail:2396`、`HistoryToolDetailGap:2020`、`ToolSuggestionApp:2482`、`WindowInfo:3216`、`DebugTraceEvent:3252`、`DebugReproRecipe:3319`、`DiffImageChange:3431`、`ArchivedSessionRecord:3698`、`PromptHistoryServerEntry:3828`、`PermissionRequestMessage:2508`；`diff_parser.dart:81-161` 的 `DiffLine`/`DiffHunk`/`DiffFile`/`DiffImageData`；`composer_tokens.dart:9-23` 的 `ComposerToken`（**标了 `@immutable` 却没实现**，而同文件的 `ComposerTokenConfig:52-75`、`ComposerTokenPalette:157-180` 都实现了）；`offline_pending_action.dart:5`；`ConversationContentTarget`（`conversation_content_protocol_slot.dart:51`，有 `key` getter 但无 `==`）。
- **后果**：这些对象进入 Bloc state 后列表相等退化为逐元素**引用**比较 → 每次 Bridge 推送都产生"新 state" → **整张会话列表无谓全量重建**；用 `Set`/`Map` 去重完全失效（与 C 类问题叠加）。

### [G04] P2 · 手写 vs 生成代码姿态割裂
- `messages.dart` 全文 5922 行**零 `@freezed`、零 `@JsonSerializable`**，防御水平从"极严谨"（`HistoryToolDetailGap.fromJson:2037-2071`，有长度上限、去重、忽略非法项、不信任 wire 的 count）到"完全裸奔"（`WindowInfo:3229`、`DiffImageChange:3460`）跨度极大。
- 同仓库 `machine.dart` 用了 freezed + json_serializable，生成的 `machine.g.dart:38` 是 `DateTime.parse(json['lastConnected'] as String)` —— 天然抛异常。
- 项目 `/flutter-ui-design` 技能规约是 "Bloc/Cubit + Freezed"。**两套姿态混用导致 review 时无法用统一规则判断"这里该不该防"**。
- **最高杠杆的单点改动**：在 `messages.dart` 建立强制解析原语 `_str() / _int() / _num() / _boolOr() / _map() / _list<T>() / _instant()`，禁止 `fromJson` 中出现裸 `as`。**这一条能一次性消掉 A 类和 B-01 的绝大部分。**

### [G05] P3 · 死代码 / 重复实现

| 位置 | 问题 |
|---|---|
| `tool_categories.dart:126-138` | `getToolCategoryColor` **9 个分支全部返回 `appColors.toolIcon`** —— 完整的死 switch，等价于常量 |
| `diff_parser.dart:532` | `if (file.isBinary) continue;` 不可达（二进制文件 `hunks` 恒为 `const []`，`:529` 已先 continue） |
| `messages.dart:867-873` vs `4220-4227` | `sizeLabel` 逐字重复两份；均无负数保护、无 GB 档（10GB 录像显示 `10240.0 MB`） |
| `messages.dart:5475-5483` | 与 `bridge_service.dart:610-613` 完全重复的参数校验（死代码，且 throw 而非返回 null） |
| `messages.dart:3079-3083` | `_detailLineValue` 声明 `String?` 但两个 return 都非 null |
| `messages.dart:2842-2850` | `.where((entry) => entry.isNotEmpty)` 恒为 true（`'$k=$v'` 至少含 `=`）—— 死过滤，`{"a": null}` 会渲染成 `a=null` |
| `messages.dart:1558-1573` | `unarchive_result` 与 `delete_session_result` 两分支体完全相同 |
| `history_window_policy.dart:23-38, 93-108, 152-181` | `selectTurnAwareServerMessageWindowIndexes` / `selectTurnAwareChatEntryWindowIndexes` 在 `lib/` 下**无任何生产调用方**（仅测试使用） |
| `history_window_policy.dart:117-131` vs `159-173` | 两处 `ChatEntry → ServerMessage` 映射逻辑逐字重复 |
| `history_window_policy.dart:7-11` | `755` 魔数与 `5 + 200 + 300` 无显式推导关系，调参时无从判断安全边界 |
| `messages.dart:4497-4567` + `4673-4757` | 三种手写 `copyWith` 风格，各 27 个字段逐一透传，新增字段漏改不报错只静默丢字段 |

### [G06] P3 · 其他一致性缺陷
- `messages.dart:919-950 + 5873` — 时间戳挂在 `Expando` 而非对象字段。`bridge_service.dart:1514-1517, 1532-1535` 会**重建** `HistoryMessage` → 新实例查不到时间戳 → 静默退化为 `DateTime.now()`，**历史消息全部显示"刚刚"**。
- `messages.dart:4851-4852` — `ClientMessage.raw` **丢弃 `delivery`**（默认 queued），与 `:5214-5217` 的 `approveLiveOnly` 注释直接冲突；目前靠 `bridge_service.dart:2747-2757` 的硬编码类型白名单侥幸兜住。且 `Map.from(json)` 是浅拷贝，`bridge_service.dart:3679-3686` 会就地改写 `json['skills']`。
- `messages.dart:779-789` `_normalizeToolResultContent` — 静默丢弃 image/document 块；`whereType<Map<String, dynamic>>()`（而非 `whereType<Map>()`）在嵌套解码产生 `Map<dynamic,dynamic>` 时会全部过滤掉 → 返回空串。
- `messages.dart:1163-1172` `.take(8)` vs `:2021` `maxToolUseIds = 200` — **协议两端上限不匹配，大 gap 永远补不完**；且 `.take(8)` 发生在 `.where(isValid)` 之前。
- `history_window_policy.dart:291-301` — 空 `id` 的 `ToolUseContent` **既不保留也不记 gap，彻底消失**；而 `:364-369` 的 `ToolResultMessage` 分支里空 `toolUseId` 反而总是保留。同一个空 ID，一个丢一个留。
- `messages.dart:4176-4230` `RecordingInfo` — `projectPath` 从 `meta` 读，`summary`/`firstPrompt`/`lastPrompt` 从顶层读，命名高度同源，很可能三个字段永远为 null。
- `composer_tokens.dart:378-386` — `fileMentions` 存**不带 `@`** 的裸名，其余 token 集合存**带前缀**全串，调用方极易填错。
- `composer_tokens.dart:231-240` — `updateTokenState` 不调 `notifyListeners()`，靠调用点在 build 中同步调用侥幸生效。

---

# 已覆盖文件清单

## `apps/mobile/lib/models/`（30 文件 / 14,001 行）

| 文件 | 行数 | 结论 |
|---|---|---|
| `messages.dart` | 5922 | **重灾区**。F01/F05/A15/A16/A17/A18 均在此。裸转换 100+ 处、三套列表写法、三套整数写法、时间戳 Expando、30+ 类缺 ==/hashCode |
| `local_features/slots/file_browser_protocol_slot.dart` | 1472 | **严格白名单 A03**（result + node + root + statItem 四层）、`FileBrowserNodeKind.parse` 有 `other` 却不兜底、`ownerSessionId` 常量、路径大小写/NFC 未归一。正面：`_fileBrowserRequiredUtcTimestamp` 强制 Z |
| `machine.freezed.dart` | 957 | 标准生成代码，无手改，==/hashCode 齐全。仅提示 `DateTime ==` 含 isUtc 标志的隐患 |
| `local_features/slots/file_transfer_protocol_slot.dart` | 687 | **严格白名单 A02**；`expiresAt` 不要求 Z（与 file_browser 矛盾，B04）；`v2/v3` 双 type 分叉反证白名单是 breaking 设计 |
| `local_features/slots/conversation_mirror_protocol_slot.dart` | 579 | **全仓库唯一正确的 unknown 兜底范式（A13）**；但 provider 白名单抛（A10）、`_conversationMirrorEntryList` 逐条抛。`_conversationMirrorOptionalInt:568` 是正确的整数解析写法 |
| `local_features/slots/session_insights_protocol_slot.dart` | 526 | 解析最宽松的 slot（大量 `?? 0` / `whereType`）。`_sessionUsageDateString:495-511` 有 isFinite + RangeError 捕获（正面）；`resetsAtDateTime:218` 时区陷阱（B05） |
| `local_features/slots/conversation_content_protocol_slot.dart` | 526 | **A14 急切内层解码（P0）**；event/provider 双白名单抛；`ConversationContentTarget.key` 缺 bridgeInstanceId（C02）、缺 ==/hashCode |
| `local_features/slots/side_chat_protocol_slot.dart` | 513 | `_sideChatRequireOnlyKeys` 定义处（A01）+ 5 处调用；`SideChatEventKind.parse` 抛（A05）；role 闭集抛 |
| `local_features/slots/codex_core_actions_protocol_slot.dart` | 407 | action/status 闭集抛（A11）；`_codexCoreActionString` 超长返回 null（静默丢弃长消息） |
| `local_features/slots/codex_desktop_continuity_protocol_slot.dart` | 308 | **A09：unknown 兜底被 `_validate` throw 抵消**；origin/state 双闭集抛 |
| `local_features/slots/ephemeral_side_chat_protocol_slot.dart` | 295 | 用户已知问题确认（3 处 `_sideChatRequireOnlyKeys`）；`:188` "exactly one result" 互斥校验同样脆弱 |
| `local_features/slots/auto_approval_protocol_slot.dart` | 238 | **A04：内联白名单 + reason 闭集** |
| `local_features/protocol_host.dart` | 230 | `tryDecode:129-143` slot 返回 null 时主动 throw，把所有 slot 校验升级为 R1+ |
| `local_features/slots/subagents_protocol_slot.dart` | 209 | `:192-199` 嵌套 `ServerMessage.fromJson` 无逐条保护；`whereType<Map>()` 静默丢非 Map |
| `machine.dart` | 200 | **E10 预发布版本号被当 0**；`uniqueKey` 缺 useSsl 维度 |
| `local_features/slots/persisted_side_chat_protocol_slot.dart` | 140 | 1 处 `_sideChatRequireOnlyKeys`（A01） |
| `local_features/slots/session_insights_models_slot.dart` | 127 | `_sessionInsightsIntOrNull:108-112` 缺 isFinite（E06）。`utilization:102-105` 除零守卫正确 |
| `terminal_app.dart` | 121 | 模板本身安全，风险在 `terminal_launcher` 的展开（D01） |
| `notification_preferences.dart` | 101 | **无问题**。`allowsRemoteEvent` 的 `_ => true` 是 additive 兜底正面样本；==/hashCode 齐全 |
| `new_session_tab.dart` | 100 | `:91` `cast<String>()` 惰性，但在 try/catch 内 → 安全 |
| `local_features/slots/subagents_models_slot.dart` | 97 | **E06：`_subagentDateString` 缺 isFinite + 缺 RangeError 捕获**（与 session_insights 同构 helper 不一致） |
| `machine.g.dart` | 80 | 生成代码，4 处裸转 + `DateTime.parse`；`toIso8601String()` 丢本地偏移（B06） |
| `recorded_event.dart` | 65 | 3 处裸转，但 `parseJsonLines:52-56` per-line try/catch → 安全 |
| `offline_pending_action.dart` | 32 | `projectName:26-31` 只 split `/`（D02）；缺 ==/hashCode |
| `app_icon.dart` | 30 | 无问题（本地设置项，兜底方向正确） |
| `code_font_family.dart` | 18 | 无问题 |
| `git_diff_interaction_mode.dart` | 8 | 无问题 |
| `image_paste_shortcut.dart` | 8 | 无问题 |
| `local_features/slots/add_to_conversation_protocol_slot.dart` | 4 | `DisabledLocalFeatureProtocolSlot`，无逻辑 |
| `local_features/slots/side_chat_models_slot.dart` | 1 | 仅 `part of`，空文件 |

## `apps/mobile/lib/utils/`（19 文件 / 3,248 行）

| 文件 | 行数 | 结论 |
|---|---|---|
| `diff_parser.dart` | 803 | **重灾区**。E02（diff 整体变空）、A21（build 期红屏）、D03/D04（路径提取错误 + 编解码不对称）、E07（int.parse）、E08（`++i` 行被吞 + 空行导致行号漂移）、G05 死代码 |
| `history_window_policy.dart` | 501 | E03（硬上限失效 + 丢最新回复）、C04/C05（ID 缺维度 + 用下标当 ID）、G06（空 id tool_use 消失）、两个函数无生产调用方。**无任何时间处理** |
| `composer_tokens.dart` | 413 | **E01：O(n²) + 每字符编译正则 → 主线程冻结（P1）**；E11 token 边界不剥标点；`ComposerToken` 标 @immutable 无 == |
| `tool_categories.dart` | 396 | F06（SubAgent 归一化名丢失 + 分类/显示名别名不一致）、D02（basename 尾斜杠返回空串）、G05（9 分支死 switch）。**正面：全文无裸 `as`，无严格白名单** |
| `debug_bundle_share.dart` | 240 | D07（split(' ') 路径含空格）、`substring` 劈代理对（P3） |
| `request_user_input.dart` | 132 | A23 全有或全无（一个坏 option 丢弃全部问题）。类型检查本身完备 |
| `command_completion_matcher.dart` | 127 | **无问题**。`segment[0]` 有 isNotEmpty 守卫，`_subsequenceScore` 线性 |
| `network_endpoint.dart` | 122 | C10（zone id 未小写）、`replaceFirst` 只替换首个 `%25`（P3）。IPv6 规范化算法本身正确 |
| `artifact_link_matcher.dart` | 102 | D02（第 5 套路径策略：percent-decode + 精确相等，无路径归一）。安全检查（`%2f`/`%5c`/`%00` 拦截）本身正确 |
| `structured_error_inference.dart` | 90 | E11 轻度二次方回溯（P3，输入受限）。逻辑无误 |
| `codex_plan_update.dart` | 73 | E11 轻度二次方回溯（P3）。`substring` 有 startsWith 守卫 |
| `file_mention_matcher.dart` | 59 | **无问题**。`split('.').first` 对 dotfile 行为可接受，`_subsequenceGapScore` 有界 |
| `terminal_launcher.dart` | 56 | **D01：模板注入（P1 安全）** + `Uri.parse` 在 try 外 |
| `command_parser.dart` | 47 | **无问题**。正则两端有标签锚定，`.*?` + dotAll 线性 |
| `platform_helper_io.dart` | 29 | 无问题。`getSystemLocaleName` 有 try/catch |
| `text_line_preview.dart` | 26 | **无问题**。边界数学正确，maxLines<=0 显式抛 ArgumentError |
| `platform_helper_stub.dart` | 22 | 无问题（Web 桩） |
| `system_message_visibility.dart` | 8 | 无问题 |
| `platform_helper.dart` | 2 | 条件导出，无逻辑 |

**合计：models 30/30 文件 14,001 行、utils 19/19 文件 3,248 行，全部覆盖，无遗漏。**

---

# 建议修复顺序

**P0（本轮必修，4 项，改动均在 10 行内）**
1. **F01** `messages.dart:2215` — 审批状态 fail-open 改 `unknown` 哨兵
2. **A16 + A17** `messages.dart:4764/4766/4820-4822` + 8 处 `cast<String>()` — 前者让主页永久空白且不可自愈，后者绕过 catch 直接红屏
3. **A14** `conversation_content_protocol_slot.dart:122` — 删掉急切 `decodeMessage()`，否则内容镜像会永久卡死
4. **E02** `diff_parser.dart:181` — `contains` 改 `any(startsWith)`

**P1（本迭代）**
5. **A01–A04 白名单族** — 需要先做一次架构决策（严格防御 vs 前向兼容），并同步修改 `test/features/file_browser/` 与 `test/features/file_transfer/` 的现有断言
6. **F05** `messages.dart:1665` — 新增 `UnknownServerMessage` + handler suppress，把 CLAUDE.md 的 Graceful Degradation 补全到 Bridge→App 方向
7. **A12** `messages.dart:2568-2588` — `canDecline` 增加"无已知决策时强制为 true"的保底，否则用户会被永久卡在无按钮的审批卡上
8. **A15/A18/A21** — `HistoryEntry` 改可空、审批 getter 全改 `_nonEmptyString`、diff_parser 改 `?.toString()`
9. **D01** `terminal_launcher.dart:16-20` — 转义（这是唯一一条可导致远端命令执行的问题）
10. **E01** `composer_tokens.dart` — `RegExp` 提 static + `index = end`
11. **B01/B02/B03** — 在 `messages.dart` 新增 `DateTime? parseWireInstant(String?)`，对无偏移串**显式按 UTC 解释**；全仓统一"解析即 toUtc，仅渲染层 toLocal"；`RecentSession` 增加 `modifiedUtc/createdUtc` 供排序

**最高杠杆的单一改动**：**G04** —— 在 `messages.dart` 建立强制解析原语（`_str/_int/_num/_map/_list/_instant`）并全量替换裸 `as`。它一次性消灭 A-3 全部条目、A22、A24、E05 和 B01。其次是把 `conversation_mirror_protocol_slot.dart:114-119`（unknown 哨兵）与 `messages.dart:170-191` 的 `CodexGoal.rawStatus/effectiveStatus/hasUnknownStatus` 三件套定为所有 `fromString`/`parse` 的强制模板 —— 这两处已经把 additive 协议做对了，其余 10 个枚举只是没跟上。
审查已完成，最终报告已在上一条消息中给出。这些通知只是我用来等待四个并行子代理的 sleep 命令陆续退出，没有新增内容。

补充说明三点，便于你判断报告的可信度：

**覆盖情况**：models 30/30 文件（14,001 行）、utils 19/19 文件（3,248 行），全部逐个覆盖。26 个 model 文件和 15 个 utils 文件由我直接逐行阅读，`messages.dart`（5,922 行，分三段）和四个大 utils 文件（`diff_parser` / `history_window_policy` / `composer_tokens` / `tool_categories`）由并行子代理深读，关键结论我已回源码抽样复核（`cast<String>` 的 8 处、`GuardianApprovalStatus.fromString` 兜底、`history*` 四处 `.map()` 放大路径、`file_transfer` 与 `file_browser` 两套时间戳契约）。

**对你几个预设的验证结果**：
- `ephemeral_side_chat_protocol_slot.dart` 的严格白名单**不是孤例**，共 4 套实现覆盖 6 个 feature、19 个消息类型，其中 `file_browser` 那套最严重（result + root + node + statItem 四层）。
- `ProcessStatus.fromString` 兜底 idle 确认存在，但**同类模式里更危险的是 `GuardianApprovalStatus.fromString` 兜底 `approved`**（`messages.dart:2215`），这是审批语义上的 fail-open，我把它列为唯一的 F 类 P0。
- ISO 字符串字典序比较在 models/utils 内确实还有：`RecentSession.created/modified`（`messages.dart:4328`）和 `PromptHistoryClientStat/SessionStat.lastUsedAt`（`:3914, 3939`），且缓存层用的是 epoch 毫秒比较，两者排序结果不一致会导致列表跳动。
- `sourceHome` 维度在这两个目录里**完全不存在**（grep 无命中）；`bridgeInstanceId` 已在协议层解析到，但没有下发进 `providerSessionIdentityKey`（`messages.dart:230`）和 `ConversationContentTarget.key`（`:60`）。

**一处需要你先做决策再动手**：A01–A04 这组白名单是被现有测试固化的有意设计（`test/features/file_browser/file_browser_protocol_test.dart:565` 有 `'rejects unknown fields...'` 断言）。"严格解析防御异常 Bridge" 和 "宽松解析保证前向兼容" 二者不可兼得，修复前需要明确取舍，并同步改测试。

全程只读，未修改任何文件。
审查工作已完成，无新增内容。这些通知是我此前用于等待并行子代理的 sleep 命令陆续退出，不携带审查结果。

完整报告已在前面给出，结论摘要：

- **覆盖**：models 30/30 文件（14,001 行）+ utils 19/19 文件（3,248 行），全部覆盖，清单表格已附。
- **P0 四项**：`messages.dart:2215` 审批状态 fail-open 兜底 `approved`；`messages.dart:4764/4766/4820` 会导致主页永久空白且不自愈；8 处 `cast<String>()` 惰性视图绕过 bridge_service 的 catch 直接红屏；`conversation_content_protocol_slot.dart:122` 急切内层解码使内容镜像永久卡死。
- **最高杠杆的单一改动**：在 `messages.dart` 建立强制解析原语替换全部裸 `as`，可一次性消除 A 类大部分条目、E05 与 B01。
- **需先决策再动手**：A01–A04 那组严格白名单是被现有测试固化的有意设计，需在"严格防御"与"前向兼容"之间做取舍，并同步修改测试。

全程只读，未修改任何文件。
这些是我此前用于等待子代理的 sleep 命令退出通知，没有新增内容。审查已于上一条消息完成并交付。

最终状态：

- **覆盖**：models 30/30 文件（14,001 行）、utils 19/19 文件（3,248 行），零遗漏，清单已附在报告末尾表格中。
- **结论**：完整报告（A–G 分组、逐条编号 + 严重度 + 文件:行号 + 触发场景 + 代码证据 + 修复方向）已在前面给出。
- **P0 四项**：`messages.dart:2215` 审批状态 fail-open、`messages.dart:4764/4766/4820` + 8 处 `cast<String>()`、`conversation_content_protocol_slot.dart:122` 急切内层解码、`diff_parser.dart:181` contains/startsWith 不对称。
- **待你决策**：A01–A04 的严格白名单族是被现有测试固化的有意设计，修复前需要在"严格解析防御异常 Bridge"与"宽松解析保证前向兼容"之间做取舍，并同步修改 `test/features/file_browser/` 与 `test/features/file_transfer/` 的断言。

全程只读，未修改任何文件。无待办任务，无仍在运行的后台进程。
这些是我先前用于等待子代理的 sleep 命令陆续退出的通知，没有新内容。审查已于两条消息前完成并交付。

需要收尾的只有一件事:我还有几个空转的 sleep 后台任务在跑,它们不影响任何结果,会自行退出。

最终交付物回顾:

- **覆盖**:models 30/30 文件(14,001 行)、utils 19/19 文件(3,248 行),全部逐个覆盖,报告末尾附有逐文件结论表。
- **P0 四项**:`GuardianApprovalStatus.fromString` 兜底 `approved`(审批语义 fail-open)、`SessionInfo` 裸转导致主页永久空白、8 处 `cast<String>()` 惰性求值绕过 catch 直接红屏、`conversation_content` 急切内层解码导致内容镜像永久卡死。
- **对你三个预设的核验**:严格白名单不止 ephemeral 一处(共 4 套 / 6 feature / 19 消息类型);`ProcessStatus` 兜底 idle 属实但同类中 `GuardianApprovalStatus` 更危险;ISO 字典序比较在 models/utils 内还有两处(`RecentSession.created/modified`、`PromptHistoryClientStat/SessionStat.lastUsedAt`)。`sourceHome` 维度在这两个目录里根本不存在。
- **需先决策再动手的**:A01–A04 白名单族是被现有测试固化的有意设计,"严格防御"与"前向兼容"需二选一,修复须同步改测试。

全程只读,未修改任何文件。
又一个空转 sleep 后台任务退出,无新内容。

审查任务已完成并交付(完整报告在前面第三条消息)。剩余的几个 sleep 任务会自行退出,不影响任何结果,我不再逐条回应它们的退出通知。

如需继续,可以告诉我:
- 对 A01–A04 白名单族的取舍决策(严格防御 vs 前向兼容),我可以据此给出具体改动方案;
- 或指定某个编号的问题,我展开更详细的修复设计。

全程只读,未修改任何文件。
残留的 sleep 等待任务退出,无新内容。审查早已完成并交付,不需要再做任何事。

任务状态:已完成。models 30/30 文件(14,001 行)、utils 19/19 文件(3,248 行)全部覆盖,完整报告(A–G 分组 + 逐文件覆盖清单表)在前面的消息中。全程只读,未修改任何文件。
又一个残留 sleep 任务退出,无新内容。

审查任务已完成并交付。完整报告(A–G 分组发现 + 逐文件覆盖清单)在前面的消息中,models 30/30 文件(14,001 行)与 utils 19/19 文件(3,248 行)全部覆盖,全程只读,未修改任何文件。

剩余的空转 sleep 任务会自行退出,不影响任何结果。
残留 sleep 任务退出,无新内容。审查已完成交付,不再赘述。
残留 sleep 任务退出。审查已完成交付,无待办事项。
