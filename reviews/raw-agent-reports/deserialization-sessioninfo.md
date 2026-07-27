I'll read the file section by section.
Now let me check the helper functions referenced in this range (defined earlier in the file) to assess robustness accurately.
已读完 4000–5922 全部区间，并回溯核对了被引用的辅助函数（`AssistantContent.fromJson`、`ImageRef.fromJson`、`_stringList`、`_resolveCodexPermissionsMode`、`deriveExecutionMode` 等）与外部消费点，用来判断爆炸半径。

**先说爆炸半径的统一前提**（后面各条引用）：
`/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/apps/mobile/lib/services/bridge_service.dart:1431` 有 `try`，`:1872` 是 `} catch (e, st)` → `ErrorMessage(message: 'Parse error: $e')`。所以 `ServerMessage.fromJson` 内任何 throw 的后果是：**整帧 WebSocket 消息被丢弃**，替换成一个错误气泡；WebSocket 流本身不会死。但由于 `session_list` / `recent_sessions` / `past_history` 都是「一帧 = 全量列表」，**单条脏数据 = 整个列表丢失**，且不会重试。

---

# A. 反序列化健壮性

### A1 (P0) `messages.dart:4820-4822` — `pendingPermission` 三处裸转换，一条脏权限请求打掉整个会话列表

```dart
pendingPermission: permJson != null
    ? PermissionRequestMessage(
        toolUseId: permJson['toolUseId'] as String,
        toolName: permJson['toolName'] as String,
        input: Map<String, dynamic>.from(permJson['input'] as Map),
      )
    : null,
```

- 触发场景：协议是 additive 的，未来 Bridge 新增一种**不带 `input`** 的权限类型（例如纯确认类 `Permissions` / `ToolSuggestion` 变体），或 `input` 被序列化成 `[]`/字符串 → `null as Map` 抛 TypeError。
- 爆炸半径：**最大**。它在 `SessionInfo.fromJson` 内，而 `SessionInfo.fromJson` 被 `messages.dart:1233` 在 `session_list` 的 `.map()` 里逐个调用 → 整个 `session_list` 帧被丢弃 → `bridge_service.dart` 的 `_hasAuthoritativeSessionListForCurrentConnection` 永远置不上，主页永远空列表，且每次重连都复现（不可自愈）。
- 修复方向：抽出 `PermissionRequestMessage.tryFromJson`，`toolUseId`/`toolName` 用 `as String? ?? ''`，`input` 用 `(v is Map) ? Map<String,dynamic>.from(v) : const {}`；解析失败返回 null 而非抛出。

### A2 (P0) `messages.dart:4764,4766` — `SessionInfo` 的 `id` / `projectPath` 裸 `as String`

```dart
id: json['id'] as String,
...
projectPath: json['projectPath'] as String,
```

- 触发场景：Bridge 侧对某类会话（如尚未落盘的 worktree 会话、远程 Desktop 接管的会话）省略 `projectPath`。
- 爆炸半径：同 A1，整个 `session_list` 帧丢失。同一帧内其余 N-1 个健康会话全部陪葬。
- 修复方向：`?? ''` 兜底 + 上层 `.where((s) => s.id.isNotEmpty)` 过滤；或把 `.map()` 换成逐条 try/catch skip（参考已有的正确做法 `session_catalog_cache_repository.dart:132-146`，那里每行 try/catch 且注释明确说明「一条坏行不能拖垮全部」——同一代码库里存在两套相反的策略）。

### A3 (P1) `messages.dart:4402` — `RecentSession.sessionId` 裸 `as String`

```dart
sessionId: json['sessionId'] as String,
```

- 触发场景：`recent_sessions` 里混入一条索引损坏 / 新格式（如未来用 `threadId` 替代 `sessionId`）的条目。
- 爆炸半径：整个 `recent_sessions` 分页帧丢弃（调用点 `messages.dart:1286`）；同时 `session_link_resolution` 的内嵌解析（`messages.dart:1130`）也走同一路径，会让「打开链接跳转会话」整条链路失败。
- 修复方向：同 A2。

### A4 (P1) `messages.dart:4271-4274` + `messages.dart:32-37` — 历史消息 content 解析全链路严格

```dart
contentList = (rawContent as List? ?? [])
    .map((c) => AssistantContent.fromJson(c as Map<String, dynamic>))
    .toList();
```
配合 `AssistantContent.fromJson`：
```dart
return switch (json['type'] as String) {          // :32  null → TypeError
  'text' => TextContent(text: json['text'] as String),   // :33 缺 text → TypeError
  'tool_use' => ToolUseContent(
    id: json['id'] as String,                     // :35
    name: json['name'] as String,                 // :36
    input: Map<String, dynamic>.from(json['input'] as Map),  // :37
  ),
```
- 触发场景：content 数组里出现字符串元素（Claude CLI 中断后的混合形态）、或未来新增的 `image`/`redacted_thinking`/`server_tool_use` 块缺少 `text`。注意 `_ =>` 兜底分支形同虚设——**它只在 `type` 是「非 null 的未知字符串」时生效**，`type` 缺失或 `text` 缺失都会在进入 switch 前/内就抛。
- 爆炸半径：整个 `past_history` 帧丢弃 → 用户点开旧会话看到「Parse error」，一条历史都读不到。
- 修复方向：`json['type'] as String? ?? ''`；`text: json['text']?.toString() ?? ''`；`tool_use` 的 id/name 兜底空串并在上层过滤；`.map()` 前先 `.whereType<Map>()`。

### A5 (P1) `messages.dart:4283-4287` → `messages.dart:624-630` — `ImageRef` 三个字段全裸

```dart
factory ImageRef.fromJson(Map<String, dynamic> json) {
  return ImageRef(
    id: json['id'] as String,
    url: json['url'] as String,
    mimeType: json['mimeType'] as String,
  );
}
```
- 触发场景：未来 Bridge 对某些图片省略 `mimeType`（可由 URL 推断）。
- 爆炸半径：`PastMessage` 内 → 整个 `past_history` 帧丢；同时 `message_images_result`（`messages.dart:1468-1471`）也会整帧丢。
- 修复方向：三处加 `?? ''`，上层按 `url.isNotEmpty` 过滤。

### A6 (P2) `messages.dart:4071-4073` — `as int?` 不接受 JSON 浮点

```dart
ahead: json['ahead'] as int? ?? 0,
behind: json['behind'] as int? ?? 0,
```
- 触发场景：Dart 的 `as int?` 对 `1.0`（JSON 里合法的整数写法）直接抛 TypeError。Bridge 端 TS 的 `number` 一旦经过任何除法/JSON 序列化就可能变成 `1.0`。
- 爆炸半径：整个 `git_branches_result` 帧丢失 → 分支面板空白。
- **同类问题清单（全部同样修法）**：`4200` `sizeBytes as int?`、`4280` `imageCount as int?`；对比 `ArtifactRef.fromJson` (`messages.dart:839,842,845,846`) 用的是正确写法 `(json['sizeBytes'] as num?)?.toInt()` —— **同一文件内两套风格并存**（也见 G1）。
- 修复方向：统一 `(json['x'] as num?)?.toInt() ?? 0`。

### A7 (P2) `messages.dart:4400` / `4760` — `codexSettings` 裸 Map 转换

```dart
final codexSettings = json['codexSettings'] as Map<String, dynamic>?;
```
- 触发场景：Bridge 若把 `codexSettings` 降级成 `[]`（空数组）或字符串（TS 侧序列化 bug / 未来改成数组形式的 settings 列表）→ TypeError。
- 爆炸半径：整个 `session_list` / `recent_sessions` 帧。
- 修复方向：`json['codexSettings'] is Map ? Map<String,dynamic>.from(...) : null`。

### A8 (P2) `messages.dart:4812-4817` — 一批 `as bool?`

```dart
codexPermissionApplyStrategySupported: json['codexPermissionApplyStrategySupported'] as bool? ?? false,
externalDesktopTurnActive: json['externalDesktopTurnActive'] as bool? ?? false,
codexNativePlanModeSupported: json['codexNativePlanModeSupported'] as bool?,
codexGoalControlSupported: json['codexGoalControlSupported'] as bool?,
```
- 触发场景：能力位若被改成三态字符串（`"supported"` / `"unsupported"` / `"unknown"`）或 0/1 → TypeError，整帧丢。这是最容易在协议演进中发生的字段类型收窄。
- 修复方向：`_asBool(dynamic)` 助手，接受 bool / 0-1 / "true"，其余返回 null。

### A9 (P3) `messages.dart:4854` — `ClientMessage.type` 裸转换

```dart
String get type => _json['type'] as String;
```
- 触发场景：`ClientMessage.raw()` 从 SharedPreferences 恢复离线队列（`bridge_service.dart:3132`、`:3687`）时，若持久化行被截断/旧版本无 `type` → TypeError。3132 处外层有 try/catch（`:3142`），3687 处没有。
- 爆炸半径：单条离线消息丢失（3132）/ 编辑排队输入抛异常（3687）。
- 修复方向：`_json['type'] as String? ?? ''`，`raw()` 里校验后返回 null。

### A10 (P2) 严格白名单：`bridge_service.dart:2747-2757` `_isPersistableOfflineMessage`

```dart
'input' || 'start' || 'resume_session' || 'rename_session' ||
'update_queued_input' || 'cancel_queued_input' => true,
_ => false,
```
- 这不是「抛异常」型，而是「静默丢弃」型白名单：任何**未来新增的应当离线持久化**的消息类型都会被静默丢掉，且没有任何日志。与 `messages.dart` 中不断新增的 `ClientMessage.*` 工厂（archive/unarchive/delete/goal 等）演进方向相反。
- 修复方向：改为按 `delivery == queued` 判定（见 G4，需先修好 `raw()` 丢 delivery 的问题），而非硬编码类型名。

### A11 (P2) 严格值白名单：`messages.dart:2568-2588` `availableDecisions`（被 4000+ 区间构造的 `PermissionRequestMessage` 直接使用）

```dart
bool get canApprove =>
    !isMalformedAskUserQuestion &&
    (availableDecisions.isEmpty || availableDecisions.contains('accept'));
```
- 触发场景：Bridge 未来把决策词表从 `accept` 改名/扩充（如 `allow`、`accept_once`）→ `availableDecisions` 非空但不含 `accept` → **审批、始终允许、拒绝按钮全部禁用**，用户被永久卡在一个无法处理的权限请求上。
- 爆炸半径：会话完全阻塞（比丢一帧更严重，因为无法自愈）。
- 修复方向：未知词表时降级为「显示所有按钮」而非「隐藏所有按钮」——additive 协议的默认应当是 permissive。

---

# B. 时间 / 时区

### B1 (P2) `messages.dart:4229` — `DateTime.tryParse` 无 Z 时按本地时间解析

```dart
DateTime? get modifiedDate => DateTime.tryParse(modified);
```
- `modified` 来自 `4199`：`json['modified'] as String? ?? ''`，是 Bridge 原样字符串。若形如 `2026-07-25T10:00:00`（无 Z / 无 offset），Dart 返回 **本地时区** DateTime；若形如 `...Z`，返回 UTC。同一列表里两种格式混排时，排序/展示会出现最大 ±14 小时的错位。
- 消费点：`screens/mock_preview_screen.dart:699`。
- 修复方向：解析后统一 `.toUtc()`，或在 Bridge 侧强制 Z；并对无时区串显式按 UTC 处理（`DateTime.tryParse(s.endsWith('Z') ? s : '${s}Z')` 之类的显式策略）。

### B2 (P2) `messages.dart:4328-4329`（`created` / `modified` 存原始 String）→ ISO 串被当排序键做字典序比较

`RecentSession` 把两个时间戳保存为裸 `String`，直接导致外部这样排序：
```dart
// features/session_list/state/session_list_cubit.dart:706
final modifiedOrder = right.modified.compareTo(left.modified);
if (modifiedOrder != 0) return modifiedOrder;
return right.created.compareTo(left.created);
```
- 触发场景：混合 `2026-07-25T10:00:00Z` 与 `2026-07-25T19:00:00+09:00`（同一时刻）→ 字典序把后者排到前面；小数秒位数不同（`.1Z` vs `.100Z`）同样错序。
- 爆炸半径：会话列表顺序错乱、且与缓存层 `session_catalog_cache_repository.dart:587-591` 的 `DateTime.tryParse(...).toUtc().millisecondsSinceEpoch` **排序结果不一致** → 缓存渲染与实时刷新之间列表会「跳动」。
- 修复方向：`RecentSession` 增加 `DateTime? get modifiedUtc`（tryParse + toUtc），所有排序改用它。

### B3 (P2) `messages.dart:4585-4586` + `bridge_service.dart:4457-4466` — 同一字段前后携带两种格式

`SessionInfo.lastActivityAt` 初次来自 `4775`（Bridge 原样字符串），但被 `_patchSessionActivity` 更新后变成 `next.toUtc().toIso8601String()`（强制 Z 形式）。同一字段在生命周期内格式漂移，任何对它做字符串比较的代码都会在「补丁前/补丁后」表现不一致。
- 修复方向：`SessionInfo.fromJson` 里就归一化成 UTC ISO。

### B4 (P2) `messages.dart:5871-5878` — `toLocal()` 与工程其他处 `toUtc()` 策略冲突

```dart
}) : timestamp =
         timestamp ??
         serverMessageTimestamp(message)?.value.toLocal() ??
         DateTime.now(),
```
- `serverMessageTimestamp` 的值来自 `messages.dart:929-943` 的 `DateTime.tryParse`（无 Z 即本地），这里再 `.toLocal()` 对已经「误判为本地」的值是 **no-op**，错误被固化。而 `features/session_list/session_list_projection.dart:230` 的 `_parseDate` 用的是 `.toUtc()`。两套策略混用 → 聊天气泡时间与会话卡片时间对不上。
- 修复方向：全局统一「解析即 toUtc，仅在渲染层 toLocal」。

### B5 (P3) `messages.dart:5875-5878` — `timestampIsAuthoritative` 推导偏保守

```dart
timestampIsAuthoritative =
    timestampIsAuthoritative ??
    (timestamp == null &&
        (serverMessageTimestamp(message)?.isBridgeReceived ?? false));
```
- 调用方显式传入 `timestamp`（哪怕它本身就是 Bridge 的 `receivedAt`）时，`isAuthoritative` 恒为 false。另外 `serverMessageTimestamp(message)` 在同一初始化列表被调用两次（Expando 查两遍）。
- 修复方向：允许调用方传 `timestamp` 的同时保留权威性判断。

### B6 (P3) `messages.dart:4717` — `copyWith(lastActivityAt:)` 无单调性保护

```dart
lastActivityAt: lastActivityAt ?? this.lastActivityAt,
```
目前唯一的写入点 `bridge_service.dart:4443-4455` 外挂了 `_newerSessionActivity` 单调守卫，所以暂时安全；但守卫在调用方而非模型内，新增调用点极易漏掉，乱序到达的帧会把活动时间往回拨。

---

# C. 身份 / 键

### C1 (P2) `messages.dart:4315-4346` — `RecentSession` 缺 `bridgeInstanceId` / `sourceHome` 维度

`RecentSession` 只有 `sessionId` + `provider` + `projectPath`。身份键构造：
```dart
// features/session_list/session_list_projection.dart:194-197
String _recentIdentity(RecentSession session) => providerSessionIdentityKey(
  session.provider ?? Provider.claude.value,
  session.sessionId,
);
```
`providerSessionIdentityKey`（`messages.dart:230-231`）= `'$provider\u0000$sessionId'`，**完全没有 bridge 维度、也没有 projectPath 维度**。
- 触发场景：多 Bridge（家里 Mac + 公司 Mac）；或 `~/.claude/projects` 被 rsync/iCloud 同步到两台机器 → 同一个 `sessionId` 出现在两个 Bridge、两个不同 `projectPath` 下 → 去重时被合并成一条，另一条静默消失。
- 对比：同文件 `session_list_cubit.dart:46-56` 的 `sessionPinKey` **有** projectPath 维度，缓存分区 `session_catalog_cache_repository.dart:15-28` **有** bridgeInstanceId（sha256 分区）。所以是「三套 key 三种维度」的不一致。
- 修复方向：`RecentSession` 增加 `bridgeInstanceId` 字段（`session_list` 帧的 `bridgeInstanceId` 在 `messages.dart:1235` 已经拿到了，只是没下发到条目上），身份键统一为 `bridge \0 provider \0 projectPath \0 sessionId`。

### C2 (P2) `messages.dart:4021-4128` + `4163-4174` — 全部 Git 结果消息缺关联维度

```dart
class GitStageResultMessage implements ServerMessage {
  final bool success;
  final String? error;
```
`GitStage/Unstage/UnstageHunks/Commit/Push/Branches/CreateBranch/CheckoutBranch/RevertFile/RevertHunks/Fetch/Pull/RemoteStatus` **全部没有 `projectPath`，也没有 `requestId`**；只有 `GitStatusResultMessage`（`4130-4161`）带了 `projectPath` + `sessionId`。
- 触发场景：用户同时打开两个项目的 Git 面板（`features/git/state/git_view_cubit.dart:604` 与 `features/git/state/branch_cubit.dart:63` 都是 broadcast stream 无过滤订阅）→ A 项目的分支结果会被写进 B 项目的面板；「切换分支成功」提示可能挂在错误的项目上。
- 修复方向：结果消息加 `projectPath`（Bridge 侧本来就有），客户端订阅时按 projectPath 过滤；或改用 requestId 关联（协议里 `read_file` / `resolve_artifact` 已有 requestId 先例）。

### C3 (P2) `messages.dart:4010-4017` — `MessageImagesResultMessage` 只有 `messageUuid`

```dart
class MessageImagesResultMessage implements ServerMessage {
  final String messageUuid;
  final List<ImageRef> images;
```
请求侧 `ClientMessage.getMessageImages`（`5590-5597`）明明发送了 `claudeSessionId`，响应却把它丢了。消费点 `features/message_images/message_images_screen.dart:61` 只按 uuid 匹配。
- 触发场景：两个会话并发请求图片、或历史 fork 后同一 uuid 存在于父/子两条线 → 串图。
- 修复方向：响应回填 `claudeSessionId` 并在匹配时联合判断。

### C4 (P3) `messages.dart:4573` — `SessionInfo.id` 是运行时 Bridge id，非持久身份

`session_list_projection.dart:199-208` 的 `_runningIdentity` 在 `claudeSessionId` 为空时降级为 `'runtime\0$provider\0${session.id}'`。Bridge 重启后 id 重新分配，旧的 runtime 身份成为孤儿。属于已知设计取舍，但缺注释说明。

---

# D. 路径处理

### D1 (P2) `messages.dart:4307-4313` — `pathBasename` 无条件把反斜杠当分隔符

```dart
String pathBasename(String path) {
  if (path.isEmpty) return path;
  final normalized = path.replaceAll('\\', '/');
  final parts = normalized.split('/').where((part) => part.isNotEmpty);
  final last = parts.isEmpty ? '' : parts.last;
  return last.isNotEmpty ? last : path;
}
```
- 触发场景：macOS/Linux 上 `\` 是**合法文件名字符**。目录名 `my\project` 会被显示成 `project`。Bridge 跑在 macOS（本项目主场景），所以这个 Windows 兼容逻辑是净负收益。
- 另外：`~` 不展开（`~/work/foo` 与 `/Users/me/work/foo` 被视为不同项目）；不做尾斜杠归一（`/a/b` 与 `/a/b/` 的 basename 相同但作为 map key 不同）；不做大小写归一（macOS 默认大小写不敏感文件系统上 `/Users/Me/x` 与 `/Users/me/x` 是同一目录，却是两个 key）。
- 消费点：`4218`、`4486`、`widgets/session_card.dart:130`、`features/session_list/widgets/home_content.dart:69,803`。
- 修复方向：仅按 `/` 切分；新增 `canonicalProjectPath()`（去尾斜杠 + `~` 展开 + 可选 case-fold），所有把 projectPath 当 key 的地方改用它。

### D2 (P2) `projectPath` 直接作 Map/Set key，全程无归一化

- `messages.dart:4415` `projectPath: json['projectPath'] as String? ?? ''` 原样存；
- `features/session_list/session_list_screen.dart:162-165` `seen.add(s.projectPath)` 做项目去重；
- `session_list_cubit.dart:50` `sessionPinKey` 把 projectPath 拼进 key；
- `session_list_state.dart:32,36,39,42,51` 五个 `Set<String>` 全部以 projectPath 为元素。
- 触发场景：Bridge 某个代码路径返回带尾斜杠的 path（例如 `git rev-parse --show-toplevel` 与 `process.cwd()` 混用），同一项目被拆成两组、置顶/折叠状态失效。
- 修复方向：同 D1，入口处（`fromJson`）归一化一次。

### D3 (P3) `messages.dart:4332` `resumeCwd` 与 `projectPath` 双路径无一致性约束

`resumeCwd`（worktree 路径）在 `session_list_screen.dart:208,1372,1782,1852`、`session_resume_coordinator.dart:194` 被优先当作 cwd 使用，但模型层不校验它是否为 `projectPath` 的子路径，`toJson`（`4465`）原样回写并进入 sqflite 缓存。若 worktree 已被删除，缓存会一直用一个不存在的路径去 resume。
- 修复方向：resume 前校验，或让 Bridge 在 `recent_sessions` 里标记 worktree 是否仍存在。

---

# E. 数值 / 边界

**结论：本区间（4000-5922）没有发现 `int.parse` / `double.parse` / `substring` / 空列表 `.first`/`.last` / ReDoS 正则。** 已核对：`4311` 的 `parts.last` 有 `parts.isEmpty` 前置保护；区间内唯一的正则是别处的 `RegExp(r'\s+')`（线性，安全）。

### E1 (P3) `messages.dart:4221-4227` — `sizeLabel` 未处理负数/异常值，且与 `ArtifactRef.sizeLabel` 重复

```dart
String get sizeLabel {
  if (sizeBytes < 1024) return '$sizeBytes B';
  if (sizeBytes < 1024 * 1024) {
    return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
  }
  return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
```
- 无除零风险（除数为常量），但负值渲染成 `-42 B`；无 GB 档，10GB 录像显示 `10240.0 MB`。
- 与 `messages.dart:867-873`（`ArtifactRef.sizeLabel`）**逐字重复**。
- 修复方向：抽成顶层 `formatByteSize(int)`，加 `abs()`/GB 档。

### E2 (P2) 见 A6 —— `as int?` 对 JSON 浮点抛异常，是本区间唯一的实质数值风险（`4071`、`4072`、`4200`、`4280`）。

---

# F. 枚举回退把未来值静默映射成已知值

### F1 (P2) `messages.dart:381-399`（调用点 `4423`、`4798`）— 未知权限模式 → `custom`

```dart
String? _resolveCodexPermissionsMode(Map<String, dynamic>? codexSettings) {
  final explicit = codexPermissionsModeFromRaw(codexSettings['codexPermissionsMode'] as String?);
  if (explicit != null) return explicit.value;
  if (codexSettings['codexPermissionsMode'] != null) {
    return CodexPermissionsMode.custom.value;   // ← 未来新增的模式全部塌陷到 custom
  }
```
- 触发场景：Codex 未来新增 `readOnly` / `planOnly` 权限模式 → 客户端显示为「Custom (config.toml)」，用户看不到真实模式名，切换 UI 会用 custom 的语义覆盖它。
- 修复方向：保留原始字符串（`rawCodexPermissionsMode`）并在 UI 直接回显未知值，只有在需要映射行为时才降级。

### F2 (P2) `messages.dart:450-469`（调用点 `4380`、`4424-4430`、`4655`、`4781-4787`）— 未知 permissionMode → `defaultMode`

```dart
if (permissionMode == PermissionMode.bypassPermissions.value) return ExecutionMode.fullAccess;
if (permissionMode == PermissionMode.acceptEdits.value) { ... }
if (approvalPolicy == 'never') return ExecutionMode.fullAccess;
return ExecutionMode.defaultMode;
```
- 未来若新增一个**比 fullAccess 更宽松**或语义不同的模式，会被静默当成 default。这个方向（宽 → 窄）不会造成越权，可接受；但反过来 F3 会。

### F3 (P2) `messages.dart:4389-4393` + `482-498` — Codex 的 `defaultMode` 被映射成 `acceptEdits`，属于**权限放宽方向**的回退

```dart
// messages.dart:4389
String get permissionMode => legacyPermissionModeFromModes(
  provider == Provider.codex.value ? Provider.codex : Provider.claude,
  executionMode: resolvedExecutionMode,
  planMode: resolvedPlanMode,
).value;
```
```dart
// messages.dart:489-492
case ExecutionMode.defaultMode:
  return provider == Provider.codex
      ? PermissionMode.acceptEdits      // ← 默认 → 自动接受编辑
      : PermissionMode.defaultMode;
```
- 触发场景：向不认识 `executionMode` 的旧 Bridge 发送 legacy `permissionMode` 时，Codex 会话的「默认（需确认）」被翻译成「自动接受编辑」。
- 另外注意 `provider` 判定用的是 `provider == Provider.codex.value` 的二值化——**任何未来的第三种 provider 都会被当成 Claude**（`4390`、`4668`）。
- 修复方向：为 Codex 的 defaultMode 选择一个不放宽权限的 legacy 值；provider 未知时走保守分支。

### F4 (P3) `messages.dart:426-435`（经 `resolveCodexApprovalPolicy` → `4418`、`4793`）— `on-failure` 硬映射成 `on-request`

```dart
if (raw == CodexApprovalPolicy.onFailure.value) {
  return CodexApprovalPolicy.onRequest;
}
```
语义上 `on-failure` 比 `on-request` 宽松，映射方向是收紧（安全），但会导致 UI 显示的策略与 Bridge 实际策略不符，用户「修改并保存」后会把 `on-failure` 改写成 `on-request`（静默配置漂移）。

### F5 (P2) `messages.dart:233-239`（调用点 `4436`、`4800`）— `sanitizeCodexModelName` 把 `'codex'` 当成空

```dart
if (normalized == null || normalized.isEmpty || normalized == 'codex') {
  return null;
}
```
- 若 Codex 未来真的把默认模型标识为 `codex`（或用它表示「跟随 profile」），客户端会认为「未设置模型」，进而在 UI 上显示为空并可能在下次 start 时不带 model 字段。硬编码魔法字符串，无注释说明来源。

### F6 (P3) `messages.dart:113-122` `ProcessStatus.fromString` 未知 → `idle`

未来新增状态（如 `paused`、`waiting_input`）会显示为「空闲」，UI 会允许用户发送输入。方向是「更宽松」，属风险回退。（区间外，但被 `4000+` 的会话模型间接消费。）

---

# G. 杂项：生成 vs 手写不一致、缺 ==/hashCode、死代码

### G1 (P2) 五个模型类缺 `==` / `hashCode`

`RecentSession`(4315)、`SessionInfo`(4572)、`PastMessage`(4232)、`RecordingInfo`(4176)、`GitBranchRemoteStatus`(4058) 全部没有值相等语义。全文件只有三处实现了 `==`：`messages.dart:194`、`:552`、`:876`（`ArtifactRef`）。
- 影响：这些对象被放进 Freezed 的 `List<RecentSession>` / `List<SessionInfo>` state（`features/session_list/state/session_list_state.dart`），列表相等退化为逐元素**引用**比较 → 每次 Bridge 推送都产生「新 state」，`BlocBuilder` 无谓重建整个会话列表；`_mergeCachedSessions`（`session_list_cubit.dart:697-711`）也无法用值相等做幂等判断。
- 修复方向：改用 Freezed/Equatable 生成，或至少给 `RecentSession`/`SessionInfo` 手写 `==`（字段多，更应该用代码生成）。

### G2 (P2) `messages.dart:4450-4482` — `toJson` 把**派生值**当权威值持久化，缓存往返后语义漂移

```dart
'executionMode': executionMode,          // fromJson 在缺失时由 deriveExecutionMode 推导得来
'codexSettings': {
  'approvalPolicy': codexApprovalPolicy, // 由 resolveCodexApprovalPolicy 推导得来
  'codexPermissionsMode': codexPermissionsMode, // 由 _resolveCodexPermissionsMode 推导得来
```
- 触发场景：Bridge 原始数据里 `executionMode` / `approvalPolicy` / `codexPermissionsMode` 均缺失 → `fromJson` 推导出值 → 写入 sqflite 缓存（`session_catalog_cache_repository.dart`）→ 下次读缓存时 `codexPermissionsModeFromRaw` 认为这是**显式**值，走 `explicit` 分支（`messages.dart:383-386`），推导逻辑不再生效。
- 后果：客户端升级后推导规则变了，老缓存里冻结的旧结论仍然生效，且**永不失效**（缓存不会因为 app 版本变化而作废）。
- 修复方向：`toJson` 只回写「来自 Bridge 的原始字段」，或给派生字段加 `_derived: true` 标记，读缓存时忽略。

### G3 (P3) `messages.dart:4497-4529` 与 `4531-4567` — 两个手写 `copyWith`，各 27 个字段逐一透传

```dart
RecentSession copyWithName({String? name, bool clearName = false}) {
  return RecentSession(
    sessionId: sessionId,
    provider: provider,
    ... // 27 行
```
新增字段时必须同步改 3 处构造（`fromJson`、两个 copyWith）+ `toJson`，漏改不会报错、只会静默丢字段。同一个类里 `SessionInfo.copyWith`（4673-4757）是第三种手写风格（带 `clearXxx` 标志位）。
- 修复方向：`RecentSession`/`SessionInfo` 迁移到 Freezed（项目 CLAUDE.md 的 `flutter-ui-design` 规约本身就是 Bloc/Cubit + Freezed）。

### G4 (P3) `messages.dart:4851-4852` — `ClientMessage.raw` 丢弃 `delivery`

```dart
factory ClientMessage.raw(Map<String, dynamic> json) =>
    ClientMessage._(Map<String, dynamic>.from(json));   // delivery 默认 queued
```
- 从磁盘恢复的离线消息一律变成 `queued`。这与 `5214-5217` 的注释直接冲突：

```dart
/// Mobile automation must never replay an approval from the offline queue
/// after its original request may have expired or changed.
factory ClientMessage.approveLiveOnly(...)  => ... delivery: ephemeral
```
- 目前**恰好**安全，因为 `_isPersistableOfflineMessage`（A10）不把 `approve` 写盘；也就是说这条不变量由一个**外部的硬编码类型白名单**兜着，而不是由 `delivery` 本身保证。任何人往白名单里加类型就会破坏它。
- 另外 `Map<String, dynamic>.from(json)` 是**浅拷贝**，嵌套的 `images`/`skills`/`mentions` 列表与原 map 共享；`bridge_service.dart:3679-3686` 正好会就地改写 `json['skills']`。
- 修复方向：`raw()` 增加 `delivery` 参数，持久化时一并写入 `_delivery` 字段；深拷贝或改用不可变结构。

### G5 (P3) `messages.dart:5475-5483` — 与 `bridge_service.dart:610-613` 完全重复的参数校验

```dart
if ([requestId, sessionId, messageId, artifactId, filePath]
    .any((value) => value.trim().isEmpty)) {
  throw ArgumentError('Artifact source request is incomplete.');
}
```
`bridge_service.readArtifactSource` 已在 `:610-613` 做过一次同样的检查（消息文案略有不同：`'Artifact source identity is incomplete.'`）。模型层的这次校验永远不会触发（死代码），但因为它 `throw` 而非返回 null，任何绕过 service 直接构造的调用方会拿到未捕获的 ArgumentError。
- 修复方向：删掉模型层这份，或把校验统一收在模型层、service 层只转译异常。

### G6 (P3) `messages.dart:4834`、`5854-5859` — 未使用/弱约束的类型

- `enum ClientMessageDelivery { queued, ephemeral }`（4834）配合 G4 的缺陷，实际约束力弱于其命名暗示。
- `sealed class ChatEntry`（5856）声明为 sealed，但三个实现（`ServerChatEntry` 5861 / `UserChatEntry` 5881 / `StreamingChatEntry` 5914）都用 `implements` 而非 `extends`，且都没有 `==`；`UserChatEntry.status`（5887）和 `messageUuid`（5893）是**可变字段**，混在一个被当作值对象放进 List 的类里，是状态管理层面的隐患。

### G7 (P3) `messages.dart:4176-4230` `RecordingInfo` 的 `meta` 嵌套读取不对称

```dart
final meta = json['meta'] as Map<String, dynamic>?;
...
projectPath: meta?['projectPath'] as String?,
summary: json['summary'] as String?,        // ← 从顶层读
firstPrompt: json['firstPrompt'] as String?, // ← 从顶层读
```
`projectPath` 从 `meta` 读，而 `summary`/`firstPrompt`/`lastPrompt` 从顶层读——若 Bridge 侧这几个字段实际都在 `meta` 里（命名高度同源，很可能是），则三个字段永远为 null，`displayText`（4209-4213）永远退化到 `name`。同时 `json['meta'] as Map<String, dynamic>?` 又是一处 A7 型裸转换。
- 修复方向：核对 Bridge 端 `list_recordings` 的实际 payload；两处都做 `meta?[k] ?? json[k]` 双读。

---

## 优先级汇总

| 级别 | 条目 |
|---|---|
| **P0** | A1 (4820-4822)、A2 (4764,4766) |
| **P1** | A3 (4402)、A4 (4271-4274 + 32-37)、A5 (4283-4287 + 624-630) |
| **P2** | A6 (4071-4073 等)、A7 (4400,4760)、A8 (4812-4817)、A10、A11、B1、B2、B3、B4、C1、C2、C3、D1、D2、E2、F1、F2、F3、F5、G1、G2 |
| **P3** | A9、B5、B6、C4、D3、E1、F4、F6、G3、G4、G5、G6、G7 |

**最该先修的三件事**：① A1/A2（两行 `as String` + 一行 `as Map` 就能让整个主页永久空白，且不可自愈）；② G2（缓存把推导值冻结成权威值，升级后无法纠正）；③ C2（Git 结果消息无 projectPath，多项目并用时结果串台）。
