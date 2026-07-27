I'll read each file completely, in parallel batches.
已逐行读完全部 10 个文件（含 `add_to_conversation_protocol_slot.dart`/`side_chat_models_slot.dart` 两个占位文件），并交叉核对了 `messages.dart:952-1146`（`ServerMessage.fromJson` 分发与 `history` 批量解析）、`bridge_service.dart:940-1060 / 1872-1877`（顶层 try/catch 与本地特性路由）、`utils/request_user_input.dart`。

结论先行：这批 slot 的解析策略是"严格拒绝式"（未知字段抛、未知枚举抛、类型不符抛），而承接方是"整条消息丢弃 + Parse error 气泡"。两者叠加后，**任何一个 Bridge 侧的向前兼容性增量（加字段、加枚举值、加 status 取值）都会让整条消息静默消失**，这与 CLAUDE.md 里写明的 Graceful Degradation 原则相反。以下按严重度列出。

---

## P0

**[P0] /Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/apps/mobile/lib/models/local_features/protocol_host.dart:129-143**
问题：`tryDecode` 对 slot 解码失败没有任何隔离，slot 内抛出的 `FormatException`/`TypeError` 直接穿透到 WebSocket 顶层 catch，整条 WS 帧被丢弃并替换成 "Parse error"。
触发场景：Bridge 升级后在 `side_chat_event` / `auto_approval_state_v1` / `codex_desktop_continuity_event_v1` 中新增任一字段或枚举值；或 `subagent_history.messages`、`codex_desktop_continuity_event_v1.message` 里嵌套一条本 App 严格校验不过的子消息。后者会把**整批**历史/镜像内容一并丢掉。
证据：
```dart
final decoded = slot.tryDecode(json);   // 这里抛出即逃逸到 bridge_service:1872
if (decoded == null) {
  throw FormatException('Invalid local feature message for ${slot.featureId}: $type');
}
```
且 `messages.dart:1665` 对未知 `type` 已有 `_ => ErrorMessage('Unknown message type')` 的降级路径 —— 本地特性通道反而比核心通道更脆弱。
建议：在循环内 `try { ... } catch (e) { logger.warn(...); return LocalFeatureDecodeFailureMessage(featureId, type) 或 return null; }`，让单个特性解码失败降级为"该特性本条不可用"，而不是整帧丢失。这是全部问题里性价比最高的单点修复。

**[P0] .../slots/side_chat_protocol_slot.dart:508-513（并波及 persisted/ephemeral 两个 slot）**
问题：`_sideChatRequireOnlyKeys` 对"未知字段"直接抛异常，是彻底的反向前兼容设计。
触发场景：Bridge 在 `side_chat_event` 加一个 `seq` / `providerSessionId` / `createdAt`；或在 `EphemeralSideChatEntry` 加 `provider`。App 侧通过 `client_capabilities.supportedServerMessages`（`messages.dart:4892`）主动向 Bridge 声明"我支持 side_chat_event"，Bridge 因此会照常下发 —— 但只做了**类型名级**协商，没有**字段级/版本级**协商，于是新 Bridge + 旧 App 的组合下整个 side chat 功能全线变成 Parse error。
证据：
```dart
if (json.keys.any((key) => !allowedSet.contains(key))) {
  throw const FormatException('Side chat message contains unknown fields.');
}
```
建议：未知字段应忽略（最多 debug 日志），严格模式只在测试断言中启用；或把消息类型名带上版本（`side_chat_event_v2`）后才允许字段级严格化。

---

## P1

**[P1] .../slots/side_chat_protocol_slot.dart:98-103**
问题：`SideChatEventKind.parse` 未知枚举值直接抛，无 fallback。
触发场景：Bridge 新增事件（如 `thinking`、`tool_call`、`token_usage`）→ 整条消息丢弃。同项目的 `CodexDesktopContinuityEventKind.parse`（continuity slot:95-100）有 `unknown` 兜底，两者不一致。
证据：`throw FormatException('Unknown side chat event: $value');`
建议：加 `unknown` 成员并返回它，在 `fromJson` 尾部对 unknown 事件返回一个"可忽略"的实例（或让 host 层跳过），不要抛。

**[P1] .../slots/codex_desktop_continuity_protocol_slot.dart:90-100 与 305-307**
问题：枚举**有** `unknown` 兜底，但校验函数立刻把 unknown 变成异常，兜底形同虚设。
触发场景：Bridge 新增 continuity 事件类型；由于 continuity 事件承载的是桌面端会话镜像内容（`payload` 是真实对话条目），丢帧等于用户看到镜像会话卡住/缺条目。
证据：
```dart
case CodexDesktopContinuityEventKind.unknown:
  throw const FormatException('Unknown Desktop continuity event.');
```
建议：unknown 事件应静默忽略（`tryDecode` 返回一个 no-op 消息或 null-safe 跳过），不应终止整帧解析。

**[P1] .../slots/auto_approval_protocol_slot.dart:96-110**
问题：同样的未知字段硬拒绝，且 `allowedKeys` 是内联硬编码集合。
触发场景：Bridge 给 `auto_approval_state_v1` 加 `updatedAt`/`scope` → 整条消息丢 → `_clearPendingLocalFeatureRequestForTerminal` 永不触发 → 请求挂到 TTL 超时，UI 上"自动批准"开关一直转圈。
证据：`if (json.keys.any((key) => !allowedKeys.contains(key))) throw const FormatException('Unexpected auto-approval state field.');`
建议：改为忽略未知键。

**[P1] .../slots/ephemeral_side_chat_protocol_slot.dart:244-257**
问题：注册表列表解析无逐项容错，任一条目非法则整个列表丢失。
触发场景：某个子会话的 `createdAt` 格式异常或多了一个字段 → 用户看到的是"侧边会话列表为空/报错"，而不是"少了一条"。
证据：
```dart
rawEntries.map((raw) { ... return EphemeralSideChatEntry.fromJson(...); })  // 无 try/catch
```
建议：逐项 try/catch 跳过坏条目，并回一个 `skippedCount` 供诊断。同类问题见 `subagents_protocol_slot.dart:191-199`（`subagent_history.messages` 逐条 `ServerMessage.fromJson` 无隔离）。

---

## P2

**[P2] .../slots/subagents_protocol_slot.dart:132 与 192**
问题：裸 `as List?` 强转。后端把 `subagents` 传成 `{}`（空对象而非空数组，TS 里很常见）或字符串 → `TypeError` → 整条消息丢。
证据：
```dart
(rawSubagents as List?)?.whereType<Map>()...
(json['messages'] as List?)?.whereType<Map>()...
```
建议：`final list = raw is List ? raw : const [];`。

**[P2] .../slots/codex_desktop_continuity_protocol_slot.dart:199-200**
问题：裸 `as bool?`。后端传 `0/1` 或 `"true"` → `TypeError` → 整条丢。
证据：`historyReady: json['historyReady'] as bool? ?? false,` / `handoffQueued: json['handoffQueued'] as bool? ?? false,`
建议：与同文件其它布尔位保持一致，用 `json['x'] == true` 或写 `_asBool()` helper。注意同文件 `_validateCodexDesktopContinuityEvent:274-278` 还会因 `historyReady` 为 true 但 state 非 idle 而抛 —— Bridge 语义微调即整条丢。

**[P2] .../slots/auto_approval_protocol_slot.dart:119-139**
问题：`is! int` 严格判定，遇 JSON double 崩。Dart 中 `jsonDecode('{"n":2.0}')` 得到 `double`，而 JS 侧 `2.0` 与 `2` 不可区分，Node 序列化边界（如经过某些 JSON 变换、Firebase relay）完全可能给出 `2.0`。
证据：
```dart
enabledConversationCount is! int || enabledConversationCount < 0 || enabledConversationCount > 4096
    || (approvedCount != null && (approvedCount is! int || approvedCount < 0))
```
另外 `> 4096` 的硬上限也会把合法大值直接判成非法整条丢弃。
建议：用 `final n = (raw is num && raw == raw.roundToDouble()) ? raw.toInt() : null;`（同仓 `codex_core_actions_protocol_slot.dart:401-407` 的 `_codexCoreActionInt` 已经是正确写法，直接复用）；上限改为 clamp 而非 reject。

**[P2] .../slots/auto_approval_protocol_slot.dart:137**
问题：`((error == null) != (errorCode == null))` 强制 error 与 errorCode 同生共死。Bridge 只给 `error` 不给 `errorCode`（最常见的写法）→ 整条丢 → 用户既看不到错误也等不到响应。
建议：`errorCode` 缺失时降级为 `'unknown'`，不要拒收。同类过严 XOR：`ephemeral_side_chat_protocol_slot.dart:188-192`、`259-263`，`persisted_side_chat_protocol_slot.dart:111-115`（entry 与 error 必须恰好一个，"既有结果又有告警"或"pending ack"都会被判死）。

**[P2] .../slots/side_chat_protocol_slot.dart:487-494（`_sideChatOptionalString`）**
问题：可选字段为空字符串 `""` 时抛异常而非当作 null。TS 侧 `field ?? ''` 是极常见默认值。
证据：`if (value is! String || value.trim().isEmpty) throw FormatException(...)`
建议：空串归一为 `null`。同一坑：`codex_desktop_continuity_protocol_slot.dart:171-178`、`auto_approval_protocol_slot.dart:220-231`。

**[P2] .../slots/subagents_models_slot.dart:94-97**
问题：与上面相反的另一个极端——`_subagentNonEmptyString` 用 `value?.toString()` 强行把任意类型转字符串，毫无类型校验。
触发场景：`status: 123` → `"123"`；`nickname: {"a":1}` → `"{a: 1}"`；`result: [..]` → `"[...]"`，直接把 Dart 的 `toString()` 结果渲染进 UI。同一代码库内两套截然相反的健壮性策略，说明缺少统一的解析工具层。
建议：`value is String ? value.trim() : null`，数值需要展示时显式格式化。

**[P2] .../slots/subagents_models_slot.dart:80-92（时区与秒/毫秒混用）**
问题：三重不一致。①数值时间戳用 `< 100000000000` 猜秒/毫秒，微秒级（1.7e15）会被当毫秒 → 得到公元 5 万年；②`DateTime.fromMillisecondsSinceEpoch` 在 |ms| > 8.64e15 时抛 `ArgumentError` → 整条消息丢；③数值路径产出 `...Z`（UTC），字符串路径原样透传（可能是无时区后缀的 naive 串），下游 `DateTime.parse` 对无后缀串按**本地时间**解释 → 同一个列表里混着 UTC 和 local 时间，"n 分钟前"整体偏一个时区。
证据：
```dart
final milliseconds = value.abs() < 100000000000 ? value.toInt() * 1000 : value.toInt();
return DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true).toIso8601String();
```
建议：字段类型改成 `DateTime?` 而非 `String?`，解析后统一 `.toUtc()`；数值分支加 `if (ms.abs() > 8640000000000000) return null;`。

**[P2] .../slots/ephemeral_side_chat_protocol_slot.dart:118-128**
问题：时间戳只接受 ISO-8601 字符串（`_sideChatRequiredString` 对 `num` 直接抛），且 `DateTime.tryParse` 对无 `Z`/偏移的串返回**本地时间**、有 `Z` 返回 UTC，两种结果混存在同一字段，排序与展示会出现时区错位；也没有 `.toUtc()`/`.toLocal()` 归一。与 `subagents_models_slot.dart` 接受 epoch 数字的策略又不一致。
建议：接受 num 与 String 两种输入，统一 `.toUtc()` 存储，展示时再 `.toLocal()`。

**[P2] .../slots/codex_core_actions_protocol_slot.dart:200-215、350-358**
问题：`status`/`action` 用闭合白名单，未知取值 → 整条 `FormatException`。
触发场景：Bridge 新增 `'queued'`/`'partial'` 状态 → 结果消息丢 → 待决请求挂死到 TTL。
建议：白名单外的值映射为 `unknown` 并让 UI 走"未知状态"分支。

**[P2] .../slots/codex_core_actions_protocol_slot.dart:394-399**
问题：`_codexCoreActionString` 对超长字符串**静默返回 null**，语义与"字段缺失"无法区分：`message` 超 2000 字符时错误详情整段消失，而 `sessionId` 超 256 字符时又变成致命错误（L205 判 null 抛）。同一个 helper 承担了"截断"和"拒绝"两种矛盾语义。另外它对所有 ID 做 `trim()`，而客户端发出时不 trim（`_requireCodexCoreActionId` 只校验不改写），若 requestId 含首尾空白则 `matchesTerminalResponse` 永远匹配不上，请求挂死。
建议：拆成 `requiredId()`（不 trim、超长报错）与 `optionalText()`（超长截断并标记 truncated）。

**[P2] .../slots/side_chat_protocol_slot.dart:174-190**
问题：`requestUserInputQuestions` 的设计是"任一问题项校验失败 → 返回 `const []`"（见 `utils/request_user_input.dart:41,51,54,57,62,66,70,76`），这里再用 `questions.length != rawQuestions.length` 把它升级为 `FormatException`。
触发场景：某个 option 多了个非 String 的 `description`，或某题的 `multiSelect` 传了 `"true"` → 整条 `side_chat_event` 丢 → **用户永远收不到这个提问，侧边会话就此卡死**（Bridge 在等回答）。
建议：坏问题项跳过而非整体失败；实在无法解析时也应下发一条"无法渲染的提问"占位，让用户至少能中断会话。

**[P2] .../slots/codex_desktop_continuity_protocol_slot.dart:269-273**
问题：`origin != 'desktop_rollout'` 直接抛。任何新增来源（如 `desktop_rollout_v2`、`desktop_live`）导致整条丢。
建议：非预期 origin 应忽略该条事件，而非终止解析。

**[P2] .../lib/models/local_features/protocol_host.dart:109-127**
问题：13 个 slot 的 `supportedServerMessageTypes` 没有唯一性校验，重复声明同一 wire type 时**第一个 slot 静默胜出**；`supportedServerMessageTypes` getter 里的 `.toSet()` 还会把重复彻底掩盖，连能力广播都看不出异常。
建议：加一个静态 `Map<String, LocalFeatureProtocolSlot>` 注册表（同时把 L133 的线性 `List.contains` 扫描降为 O(1)，history 批量解析时每条消息都会走这里），并在构造/测试中断言无重复。

---

## P3

**[P3] 全部 10 个文件：所有 model 类均未实现 `==`/`hashCode`**
涉及 `SideChatEventMessage`、`SideChatTranscriptMessage`、`EphemeralSideChatEntry`、`SubagentInfo`、`CodexMcpServerStatus`、`AutoApprovalStateMessage` 等。影响面：这些对象若进入 Bloc/Cubit state 或 `stream.distinct()`，恒不相等 → 每次轮询/事件都触发全量重建（列表类如 `EphemeralSideChatRegistryMessage.entries`、`SubagentListMessage.subagents` 最明显）。因为是"恒不等"而非"漏字段导致恒相等"，后果是**多余重建**而不是 UI 不更新，故定 P3；但注册表类模型（`EphemeralSideChatEntry`、`SubagentInfo`）建议补 value equality。

**[P3] .../slots/side_chat_protocol_slot.dart:160、189；.../codex_core_actions_protocol_slot.dart:320**
问题：可变集合泄漏/浅不可变。`SideChatPermissionRequest.input` 是 `Map.from()` 的**可变**副本，外部拿到后可就地改写；`SideChatQuestionRequest.questions` 外层 `List.unmodifiable` 但内层 `Map<String,dynamic>` 仍可变（且 `requestUserInputQuestions` 内部就做过 `question['options'] = parsedOptions` 的就地写入，说明确实存在写入习惯）。
建议：`Map.unmodifiable` + 逐层 unmodifiable，或改用 freezed。

**[P3] 全部文件：无一个类提供 `copyWith`**
所以本次审查未发现 `copyWith` 的 null 语义 bug（不存在该 API）。反过来说，若后续要加，注意 `SideChatEventMessage`/`AutoApprovalStateMessage` 有大量可空字段，必须用 sentinel 或 `Object? x = _unset` 模式区分"不改"与"置 null"。

**[P3] .../slots/codex_core_actions_protocol_slot.dart:305、362**
问题：`rawTools.take(128)` / `rawServers.take(64)` 客户端静默截断，但 `toolsTruncated`/`serversTruncated` 只来自服务端。服务端返回 200 个 tool 且 `toolsTruncated: false` 时，UI 会展示 128 个并宣称"完整"。
建议：`truncated = serverFlag || rawList.length > limit`。

**[P3] .../slots/codex_core_actions_protocol_slot.dart:93-129**
问题：参数校验放在 `toJson()` 里而非构造函数。`const CodexReviewCommitTarget('')` 可以合法构造，直到发送那一刻才抛 `ArgumentError`，错误现场远离根因。另 L115 显式发送 `'title': null`，若 Bridge 用 zod `.optional()`（不接受显式 null）会被拒。
建议：校验前移到工厂构造；`title` 为空时省略该键而非发 null。

**[P3] .../slots/side_chat_protocol_slot.dart:80-82；.../codex_desktop_continuity_protocol_slot.dart:71-81**
问题：能力降级的判定依赖**英文错误文案精确匹配**（`error.message == 'Side chat capability was not negotiated'`）。Bridge 改一个字（含大小写、标点）就失效，请求只能等 TTL 超时。continuity 那段更进一步用正则去猜 `unknown|unsupported|not supported`，属于启发式，容易误匹配到无关错误从而错误地终结另一个 pending 请求。
建议：以 `errorCode` 为唯一判据（`unsupported_capability` + 一个结构化的 `capability` 字段），文案匹配仅作为过渡期兜底并加 TODO 期限。

**[P3] .../slots/ephemeral_side_chat_protocol_slot.dart:37-43 与 226**
问题：请求侧用伪 session id `'ephemeral-side-chat-registry'` 作为 `ownerSessionId`，响应侧 `EphemeralSideChatRegistryMessage.sessionId` 却是 `null`。`bridge_service.dart:951` 走 `message.sessionId ?? sessionId`（信封 sessionId 通常也为 null），因此这条消息在 `localFeatureMessagesForSession(...)`（`bridge_service.dart:4854-4860`，按 `pair.$2 == sessionId` 过滤）上**永远匹配不到任何会话订阅者**，只能靠全局 `localFeatureMessages` 流接收。终结匹配本身只比对 requestId 所以不影响完成态，但订阅方式与其它 slot 不一致，容易误用。
建议：让注册表消息返回同一个伪 session id，与 descriptor 对齐。

**[P3] .../slots/subagents_protocol_slot.dart:138 + subagents_models_slot.dart:39-43**
问题：`SubagentInfo.fromJson` 在缺 threadId 时兜底成 `''`，随后 slot 用 `.where((agent) => agent.threadId.isNotEmpty)` 静默丢弃。数据丢失完全不可见（无日志、无计数）。
建议：解析层直接返回 null 并计数记录，避免"空字符串哨兵 + 静默过滤"的双层隐藏。

**[P3] .../lib/models/local_features/protocol_host.dart:145-163**
问题：`describeRequest` 对每一条 ephemeral 消息做一次 `jsonDecode(message.toJson())` 的序列化往返，只为读一个 `type` 字段；且当某 slot 返回**非法** descriptor 时是 `continue` 静默跳过，后面的 slot 有机会"抢走"这个请求，形成静默错配而非显式失败。
建议：让 `ClientMessage` 暴露只读的 `Map` 视图；非法 descriptor 应 assert/日志告警。

**[P3] .../lib/models/local_features/protocol_host.dart:129-131 与 messages.dart:959**
问题：`tryDecode` 在 `json['type']` 不是 String 时返回 null，随后 `messages.dart:959` 的 `json['type'] as String` 立刻抛 `TypeError`。缺 `type` 字段的畸形帧会直接变成 Parse error 气泡，而不是走 L1665 已有的 `'Unknown message type'` 降级分支。
建议：在 `ServerMessage.fromJson` 入口把非 String `type` 归一为 `''` 以复用现有降级路径。

---

## 补充：两个占位文件

- `.../slots/add_to_conversation_protocol_slot.dart:3-4` — `DisabledLocalFeatureProtocolSlot('add_to_conversation')`，`supportedServerMessageTypes` 为空、`tryDecode` 恒返回 null，是本次审查中**唯一正确的降级样板**，无问题。可以把它作为其它 slot 未知消息降级的参考模式。
- `.../slots/side_chat_models_slot.dart` — 仅一行 `part of`，空文件，无问题（可考虑删除或补注释说明为何保留）。

---

## 优先修复建议（按投入产出比排序）

1. `protocol_host.dart:129-143` 加 per-slot try/catch 隔离 —— 一处改动即可把上述所有"整帧丢失"降级为"单特性本条不可用"。
2. 移除三处 `_requireOnlyKeys` / `allowedKeys` 未知字段硬拒绝（side_chat / auto_approval / persisted / ephemeral），改为忽略。
3. 统一枚举 `parse` 全部带 `unknown` 兜底，并让 `unknown` 走"忽略本条"而非抛异常（尤其 continuity 的 L305）。
4. 抽一层公共安全解析工具（`asString/asInt/asDouble/asBool/asList/asDateTimeUtc`），替换本目录内并存的三套风格：严格抛（side_chat）、静默 null（codex_core_actions）、`toString()` 万能转（subagents_models）。
5. 时间字段统一为 `DateTime` + UTC 归一，消除 `subagents_models_slot.dart` 与 `ephemeral_side_chat_protocol_slot.dart` 之间的秒/毫秒、UTC/local 双重不一致。
