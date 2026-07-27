I'll start by exploring the directory structure and then dig into the files.
I'll delegate the slot files to parallel subagents while I review `messages.dart` myself.
Two agents launched; the third hit a concurrency limit. Let me start on `messages.dart` myself.
Now let me review the smaller model files and check how `ServerMessage.fromJson` is called.
Let me retry the third batch of slot files now.
I have completed my pass on `messages.dart` and the small files. Let me verify one last detail while the slot-file agents finish.
Both remaining agents are still running. Let me verify a couple more details in `messages.dart` in the meantime.
All spot-checks confirm the subagent findings. Waiting on the final slot-file agent.
三个并行子代理 + 我本人的审查已全部完成，覆盖 `models/` 全部 30 个文件 / 14,001 行。

---

# ccpocket mobile `lib/models/` 只读审查报告

**路径约定**：下文 `R` = `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/apps/mobile/lib/models`

## 关键前置事实（决定了所有严重度）

顶层 WebSocket 监听器 `.../apps/mobile/lib/services/bridge_service.dart:1431-1877` 对**整条消息**的解析包了 `try/catch`：

```dart
} catch (e, st) {
  logger.error('WS parse error', e, st);
  final errorMsg = ErrorMessage(message: 'Parse error: $e');
  _taggedMessageController.add((errorMsg, null));
}
```

所以裸 `as` 抛 TypeError **不会 crash 进程**，但代价是：**整条 WS 帧被丢弃 + 向 UI 广播一条伪造的 "Parse error" 气泡 + 对应 pending 请求无法被结掉，只能等 TTL 超时**。批量消息（`history` / `history_page` / mirror 快照 / roots 列表）里一个坏元素 = 整批数据静默消失。因此下文「整条丢弃」类问题按较高严重度计。

**唯一的例外见 P1-1** —— 那类问题会逃出这张安全网。

**贯穿全库的根因**：`models/` 目录内并存**三套互相矛盾**的解析风格，且往往在同一协议族的姊妹文件里就相反：
- **严格拒绝式**（未知字段抛、未知枚举抛、`is! int` 抛）：`file_browser` / `file_transfer` / `side_chat` / `auto_approval` / `conversation_content`
- **防御降级式**（`whereType` + `isValid` 过滤 + `unknown` 兜底）：`_parseArtifactRefs`、`HistoryToolDetailGap`、`conversation_mirror`、`add_to_conversation`
- **万能 `toString()` 式**（毫无类型校验）：`subagents_models_slot`、`_sessionUsageNonEmptyString`

`messages.dart` 内部同样分裂：新代码用 `(json['x'] as num?)?.toInt()`（11 处），旧代码用 `as int?`（57 处）；生成代码 `machine.g.dart:33` 反而比手写代码更安全。

---

## P0

### [P0] `R/local_features/protocol_host.dart:129-143` — slot 解码失败无隔离，单特性错误炸掉整帧
- **触发**：任一 slot 抛 `FormatException`/`TypeError`（下面 P0-2、P1-4、P1-5 全部会触发）→ 穿透到 `bridge_service.dart:1872` → 整条 WS 帧丢弃。若是 `subagent_history.messages` / `codex_desktop_continuity_event_v1.message` 这类**嵌套批量**载体，一并丢掉整批历史。
- **证据**：
  ```dart
  final decoded = slot.tryDecode(json);   // 抛出即逃逸
  if (decoded == null) {
    throw FormatException('Invalid local feature message for ${slot.featureId}: $type');
  }
  ```
  讽刺的是核心通道 `R/messages.dart:1665` 已有 `_ => ErrorMessage('Unknown message type: ...')` 降级路径 —— 本地特性通道反而比核心通道脆弱。
- **修复**：循环内加 per-slot `try/catch`，降级为「该特性本条不可用」而非整帧丢失。**这是全部发现里性价比最高的单点修复**。

### [P0] 未知字段硬拒绝 —— Bridge 加一个字段即导致整个功能全线失效
- **位置**：`R/local_features/slots/side_chat_protocol_slot.dart:508-513`、`auto_approval_protocol_slot.dart:96-110`、`file_browser_protocol_slot.dart:1251-1260`、`file_transfer_protocol_slot.dart:583-592`（persisted / ephemeral side chat 同款）
- **触发**：新版 Bridge 给 `side_chat_event` 加 `seq`、给 `file_browser_list_result_v1` 加 `totalCount`、给 `auto_approval_state_v1` 加 `updatedAt` —— 旧 App 的对应功能**不是降级，是完全不可用**，用户看到的是「请求超时」或红色 Parse error。
- **证据**：
  ```dart
  for (final key in json.keys) {
    if (!allowed.contains(key)) {
      throw FormatException('file browser message has unknown field $key');
    }
  }
  ```
- **与项目原则冲突**：`CLAUDE.md` 明确写了 Graceful Degradation 机制（`_unsupportedActions`），但那只覆盖 app→旧 Bridge 方向；反方向（新 Bridge→旧 app）这里是硬失败。App 通过 `client_capabilities.supportedServerMessages`（`R/messages.dart:4892`）做的是**类型名级**协商，没有字段级协商，无法兜住这个洞。
- **修复**：未知字段改为忽略 + debug 日志（严格模式只留给单测）。协议已带 `_v1/_v2/_v3` 版本号，破坏性变更靠版本号即可，字段级白名单是过度约束。

---

## P1

### [P1] `R/messages.dart:1338, 1371, 1376, 1411, 1430, 1603, 1605, 3349` — `.cast<String>()` 是惰性视图，异常逃出 WS 安全网
- **触发**：`(json['files'] as List).cast<String>()` 返回 `CastList` **懒视图**，元素类型错误不在解析时抛，而在**后续迭代时**抛。`FileListMessage.files` 经 `features/explore/state/explore_cubit.dart:30-49` 存入 `state.allFiles` 并在 widget build 中遍历 → TypeError 发生在 build 阶段，**完全不在 `bridge_service` 的 try/catch 覆盖范围内** → 红屏/灰屏。
- **证据**：`files: (json['files'] as List).cast<String>(),`
- **修复**：一律改为 `.whereType<String>().toList()`（立即求值 + 自动过滤），与本文件已有的 `(json['plugins'] as List?)?.whereType<String>()`（:1032）风格统一。**这是本次唯一能真正炸掉 UI 的一类问题，建议最优先修。**

### [P1] `R/messages.dart:1139, 1155, 1178, 1189` + `:2353` — history 批量解析无逐条容错，一坏全丢
- **触发**：`history` / `history_page` / `history_delta` / `history_snapshot` 四种消息都用 `(json['messages'] as List).map((m) => HistoryEntry.fromJson(...))`，内部再调 `ServerMessage.fromJson`。历史里**任意一条**消息缺必填字段（如 `tool_result` 缺 `toolUseId`），整个会话历史全部丢失，用户看到空白对话 + Parse error。
- **证据**：
  ```dart
  entries: (json['messages'] as List)
      .map((m) => HistoryEntry.fromJson(m as Map<String, dynamic>))
      .toList(),
  ```
- **对照**：同文件 `history_tool_details`（:1163-1172）是正确写法 —— `((json['details'] as List?) ?? const []).whereType<Map>().take(8)...where((d) => d.isValid)`。同样 `conversation_mirror_service.dart:1790/1825/2172` 也是逐条 try/catch 跳过。**正确范式就在隔壁，只是没推广。**
- **修复**：逐条 try/catch 跳过坏条目 + 上报 `skippedCount`。

### [P1] `R/messages.dart:32-44` 及 `:84` — 助手消息内容解析裸强转
- **触发**：`json['type'] as String`（type 缺失/非串）、`json['text'] as String`（null）、`json['input'] as Map`（无参工具常传 null）、`(json['content'] as List)`（turn 被中断时 content 可能为 null）→ 整条助手消息丢失。
- **证据**：
  ```dart
  return switch (json['type'] as String) {
    'text' => TextContent(text: json['text'] as String),
    'tool_use' => ToolUseContent(input: Map<String, dynamic>.from(json['input'] as Map)),
  ```
- **修复**：`json['type'] as String? ?? ''`（已有 `_ =>` 兜底分支可复用）、`json['text']?.toString() ?? ''`、`json['input'] as Map? ?? const {}`、`json['content'] as List? ?? const []`。

### [P1] `R/messages.dart:959` — 分发入口的 `as String` 早于已有的降级分支
- **触发**：畸形帧缺 `type` 或 `type` 非串 → 在 `switch` 求值时就抛，**根本走不到 :1665 的 `_ => ErrorMessage('Unknown message type')` 兜底**。同时 `protocol_host.dart:130-131` 对非 String type 返回 null，把畸形帧原样交回给这里。
- **修复**：`switch (json['type'] as String? ?? '')`，复用已有降级路径。

### [P1] 枚举 `parse` 无 fallback，未知值抛异常
| 位置 | 问题 |
|---|---|
| `R/local_features/slots/file_browser_protocol_slot.dart:166-171` | 枚举**已定义 `other('other')` 兜底值却不用**；未知 `kind`（fifo/socket/block device）炸掉**整页 entries** |
| `R/local_features/slots/side_chat_protocol_slot.dart:98-103` | 新增 `thinking`/`tool_call`/`token_usage` 事件即整条丢 |
| `R/local_features/slots/conversation_content_protocol_slot.dart:43-48` | `throw FormatException('Unsupported conversation content event')`；姊妹文件 `conversation_mirror_protocol_slot.dart:109/118` **有 `unknown('__unknown__')` 兜底**，同协议族两套相反策略 |
| `R/local_features/slots/codex_desktop_continuity_protocol_slot.dart:90-100, 305-307` | 枚举**有** `unknown` 兜底，但校验函数 `case ...unknown: throw` 让兜底形同虚设 |
- **修复**：统一「未知枚举 → `unknown` 成员 → 上层忽略本条」，绝不抛。

### [P1] `R/local_features/slots/file_browser_protocol_slot.dart:481-490`（同类 `:467`, `:800-804`）— 把服务端能力声明当作安全边界硬校验
- **触发**：Bridge 把 `FILE_BROWSER_DOWNLOAD_MAX_BYTES` 从 15GB 提到 32GB（`packages/bridge/src/file-browser-manager.ts:60-61` 直接回传常量），mobile 侧常量仍是 15GB → **整条 roots 结果被拒 → 文件浏览器彻底不可用**。用户配了 33 个 root 同理（`:467`）。
- **证据**：`_fileBrowserRequiredSafeInteger(json['downloadMaxBytes'], ..., maximum: maxFileBrowserDownloadBytes)`
- **修复**：能力上限改为 `min(serverValue, localCap)` 钳位；roots 超限截断 + 提示。「服务端更强」不等于「协议非法」。

### [P1] `R/local_features/slots/file_browser_protocol_slot.dart:424-442` vs `:494-510` — 模型声明「可空可选」，fromJson 却「全必填」，两个矛盾契约用异常粘合
- **触发**：旧版/精简 Bridge 不返回 `downloadAvailable`（该字段本身就是能力降级信号）→ 整条 roots 失败 → 连只读浏览都用不了。
- **证据**：字段是 `final bool? downloadAvailable;`，但 `downloadAvailable: _fileBrowserRequiredBool(json['downloadAvailable'], 'downloadAvailable')`，而调用侧 `features/.../file_browser_service.dart:367-372` 又一串 `result.previewMaxBytes!` / `result.downloadAvailable!` 强断言。
- **修复**：能力型字段缺失给安全默认值（`downloadAvailable=false`），改成非空字段 + 默认值，消除调用侧 `!`；只对身份型字段（`requestId`）保持必填。

### [P1] 解码失败无法 fail 掉对应 pending 请求，只能挂到超时
- **位置**：`R/local_features/slots/file_browser_protocol_slot.dart:140-154`、`conversation_mirror_protocol_slot.dart:86-95`、`side_chat_protocol_slot.dart:80-82`、`codex_desktop_continuity_protocol_slot.dart:71-81`
- **触发**：解码异常被转成通用 `ErrorMessage('Parse error: FormatException: ...unknown field x')`，其文案**不含** requestType → 匹配失败 → 请求永不结束 → UI 转圈到 TTL 超时。
- **证据**：
  ```dart
  final message = error.message.toLowerCase();
  return message.contains(request.requestType.toLowerCase()) && RegExp(...).hasMatch(message);
  ```
  更糟的是 mirror 那处**只按 requestType 匹配、不比对 session/requestId** —— 与其第 88-89 行注释声称的「unrelated session error can never consume this feature's pending slot」直接矛盾；两个会话并发 `conversation_mirror_sync` 时，A 的错误会消费掉 B 的 pending slot。
- **修复**：只依赖 `errorCode` + 结构化 `requestId` 归因；为本地解码失败引入显式失败通道（尽力从原始 json 提取 requestId 并 fail）。

### [P1] `R/local_features/slots/session_insights_protocol_slot.dart:355, 398, 460` — 裸 `as List?`
- **触发**：Bridge 只有一个 provider 时返回 `providers: {...}`（对象而非数组）→ TypeError → 整条 `session_usage_result` 丢失。
- **证据**：`(json['credits'] as List?)`、`(json['limitCards'] as List?)`、`(json['providers'] as List?)`
- **修复**：`v is List ? v : (v is Map ? [v] : const [])`。同款：`R/local_features/slots/subagents_protocol_slot.dart:132, 192`。

### [P1] `R/local_features/slots/session_insights_protocol_slot.dart:209` — `utilization` 单位语义未定义
- **触发**：UI 按百分比消费（`session_insights_bar.dart:559` `clamp(0,100)`、`LinearProgressIndicator(value: used/100)`），但模型不做任何归一化。Bridge 若改成 0..1 分数，UI 永远显示 0%/1% 且**无任何告警**。另外传字符串 `"45.2"` 直接 TypeError。
- **修复**：模型层显式定单位（建议存 0..1，命名 `utilizationFraction`）+ 显式 clamp + num/String 双路径解析。

### [P1] `R/local_features/slots/conversation_content_protocol_slot.dart:498-508` — `is! int` 遇 JSON double 崩
- **触发**：`pageCount: 3.0` / `entryCount: 12.0`（任何以 double 形态序列化整数的后端，或经过浮点运算/Firebase relay 的字段）→ FormatException → 整条事件丢弃。
- **对照**：姊妹文件 `conversation_mirror_protocol_slot.dart:568` 写法正确：`if (raw is! num || raw.toInt() != raw || ...)`。同协议族两套数值规则。
- **修复**：照抄 mirror 的 `num` + 整数性判定。同款问题：`R/local_features/slots/auto_approval_protocol_slot.dart:119-139`（且 `> 4096` 硬上限也会把合法大值整条拒掉）、`file_browser_protocol_slot.dart:1382-1391`、`file_transfer_protocol_slot.dart:615-627`。后两处还有 **web/native 行为分裂**：dart2js 上 `1.0 is int` 为 true、native 上为 false → 「模拟器通过、真机失败」。

### [P1] 列表解析无逐条容错（非 history 部分）
- **位置**：`R/local_features/slots/ephemeral_side_chat_protocol_slot.dart:244-257`、`subagents_protocol_slot.dart:191-199`、`file_browser_protocol_slot.dart`（entries 整页失败）
- **触发**：一条侧边会话 `createdAt` 格式异常 → 用户看到「列表为空」而非「少一条」。
- **修复**：逐项 try/catch 跳过 + `skippedCount`。

---

## P2

### [P2] `R/messages.dart:4673-4757` — `SessionInfo.copyWith` 无法把可空字段置回 null（审查点 7）
- **触发**：Codex 会话切走 profile、或 runtime 停止广告 service tier 时，`copyWith(codexServiceTier: null)` 是 **no-op**，陈旧值永久留在 UI。`bridge_service.dart:4725` 正在用 `copyWith(codexServiceTier: serviceTier)` 这条路径。
- **证据**：只有 `name` / `pendingPermission` / `queuedInput` / `codexNativePlanModeSupported` / `codexGoalControlSupported` 有 `clearXxx` 标志；`codexModel` / `codexProfile` / `codexServiceTier` / `codexSandboxMode` / `codexApprovalsReviewer` / `model` 全部只有 `x ?? this.x`。
- **修复**：统一改用 sentinel（`Object? x = _unset`）或 freezed 生成，不要继续手写 `T? x` + `??`。

### [P2] `R/messages.dart` — 全库仅 2 个类实现 `==`/`hashCode`（`CodexGoal:147`、`ArtifactRef:803`）
- **触发**：`ChatSessionState` 是 `@freezed`，其 `==`（`chat_session_state.freezed.dart:378`）对 `queuedInput` / `rewindPreview` 用 `other.x == x`。`QueuedInputItem`（`R/messages.dart:695`）**没有 `==`** → 每条 `conversation_queue` 消息都产生新实例 → state 恒不等 → 整个聊天页全量重建。`CodexGoal` 有 `==` 所以 goal 不会，形成鲜明对照。
- **反向风险**：`UserChatEntry.status`（`R/messages.dart:5887`）、`.messageUuid`（`:5893`）、`StreamingChatEntry.text`（`:5915`）是**可变 public 字段**。freezed 的 `DeepCollectionEquality` 对 entries 逐元素比，而 `ChatEntry` 无 `==` → 按 identity 比。**一旦有人就地改 `entry.status = MessageStatus.sent` 再 emit 同一个 list，bloc 会判定 state 相等而丢弃这次 emit，UI 永远停在「sending」**。目前全仓未发现就地改写（已 grep 确认），属**潜伏隐患**。
- **同类**：全部 slot 文件的 model 类均无 `==`（`FileBrowserNode`、`SubagentInfo`、`EphemeralSideChatEntry`、`ContextUsage`、`SessionUsageWindow` …）。其中 `session_insights_controller.dart:168-176` 收到 `context_usage` 就无条件 `notifyListeners()`，消费方**无手段去重**（`ContextUsage() == ContextUsage()` 恒 false）。
- **修复**：给进入 state / 长期持有的 model 补值相等（List 用 `listEquals`，切勿只比引用）；`FileBrowserNode` 有天然的 `rootId+relativePath+nodeRevision` 可做廉价判等。把 `UserChatEntry` 的可变字段改为 final + copyWith。

### [P2] 时间处理：秒/毫秒启发式 + 时区语义随输入类型漂移
- **位置**：`R/local_features/slots/session_insights_protocol_slot.dart:495-511`、`subagents_models_slot.dart:80-92`
- **证据**：
  ```dart
  final milliseconds = value.abs() < 100000000000 ? value.toInt() * 1000 : value.toInt();
  return DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true).toIso8601String();
  ```
- **三重缺陷**：① 阈值 1e11 把 1973-03 之前的**毫秒**戳误当秒（放大 1000 倍）；② **微秒/纳秒**戳（>1e11）被当毫秒 → 静默算出公元 5 万年，且不触发 `RangeError`（阈值要 8.64e15）；③ **数值分支产出带 `Z` 的 UTC 串，字符串分支原样透传** —— 无时区后缀的 naive 串被 `DateTime.parse` 当**本地时间** → 同一字段混着 UTC 和 local，倒计时/「n 分钟前」整体偏一个时区（东八区偏 8 小时）。
- **`file_transfer` 侧更严重**：`file_transfer_protocol_slot.dart:669-675` 的 `expiresAt` 只校验「能 parse」不校验时区，该值流向 token 过期比较 → **过期判定偏移一个时区**。而 `file_browser_protocol_slot.dart:1398-1405` 反过来强制必须 `Z` 结尾，把 Python `datetime.isoformat()` / Go RFC3339 常见的 `+00:00` 硬拒。三个文件三套规则。
- **修复**：抽共享 `_parseUtcTimestamp`（接受 num 与 String、接受 `Z` 与数字偏移、统一 `.toUtc()`）；模型层字段类型改 `DateTime` 而非 `String`；数值分支加 `if (ms.abs() > 8640000000000000) return null;`；展示侧统一 `.toLocal()`。
- **注**：`R/messages.dart:743`（`UsageWindow.resetsAtDateTime`）与 `usage_section.dart:496` 已正确 `.toLocal()`，这条路径**无问题**。

### [P2] 「显式 null」与「字段缺失」语义不等价
- **位置**：`R/local_features/slots/file_browser_protocol_slot.dart:259-261, 1272-1279, 1299-1306, 1393-1396, 1407-1413`
- **触发**：后端显式写 `"mimeType": null` 即抛。当前 TS Bridge 用条件展开 `...(x === undefined ? {} : {x})` 恰好规避 —— **属于运气而非契约**；换 Go/Python/Rust 实现即炸。
- **证据**：`if (!json.containsKey(field)) return null;` —— 显式 null 走不到这里，落入 required 分支。
- **不一致**：`file_transfer_protocol_slot.dart:594-597` 是 `if (value == null) return null;`，同功能域两套 optional 语义。
- **修复**：统一 `json[field] == null → null`。

### [P2] 数值/字符串校验严松失衡 —— 字符串侧的万能 `toString()`
- **位置**：`R/local_features/slots/subagents_models_slot.dart:94-97`、`session_insights_protocol_slot.dart:518-526`、`session_insights_models_slot.dart:119-127`
- **证据**：
  ```dart
  if (value is! String) {
    return value?.toString().trim().isEmpty == false ? value.toString().trim() : null;
  }
  ```
- **触发**：`errorCode: {"code":5}` 变成字面串 `"{code: 5}"` 直接渲染到 UI；`sessionId: 12345` 变成 `"12345"` 并参与 `message.sessionId != sessionId` 相关性判断（错配/漏配）。与同目录数值字段「过严到抛异常」形成极端反差。
- **修复**：只接受 String（可选显式接受 num），Map/List 一律返回 null。

### [P2] 可变集合泄漏 —— 只有 `fromJson` 路径做了 unmodifiable
- **位置**：`R/local_features/slots/file_browser_protocol_slot.dart:431-442, 522-532, 677-683`、`conversation_mirror_protocol_slot.dart:128-133, 289-307`、`conversation_content_protocol_slot.dart:85-90, 128-148`、`session_insights_protocol_slot.dart:266-267, 348-351, 386-394, 441-446`、`side_chat_protocol_slot.dart:160, 189`
- **触发**：`fromJson` 里包了 `List.unmodifiable(...)`，但**公开构造函数直接赋值**。测试、mock、录制回放、`codex_desktop_continuity_protocol_slot.dart:205` 这类转发路径都会让 model 持有调用方仍可改的集合；`const` 构造函数还会让人误以为不可变。`SideChatQuestionRequest.questions` 外层 unmodifiable 但**内层 Map 可变**，而 `utils/request_user_input.dart` 内部就有 `question['options'] = parsedOptions` 的就地写入习惯。
- **另**：`session_insights_protocol_slot.dart:267` 的 `individualLimit: json['individualLimit']` 直接持有原始 `Object?`，类型逃逸 + 可变泄漏双重问题。
- **修复**：构造函数体内统一 unmodifiable（或字段声明为 `UnmodifiableListView`），Map 逐层 unmodifiable。

### [P2] 交叉字段一致性断言过紧，把展示型不一致升级为致命错误
| 位置 | 断言 | 风险 |
|---|---|---|
| `file_browser_protocol_slot.dart:262-269` | symlink 元数据三重一致性 | Bridge 若重构为「kind 报 target 类型 + isSymlink 标志」（`file-browser-manager.ts:1045-1049` 已是 sourceKind），整个目录不可解码 |
| `file_browser_protocol_slot.dart:621-671` | stat node 路径必须与外层严格相等 | 服务端做路径规范化（去尾斜杠、大小写归一）即整批 stat 失败 |
| `auto_approval_protocol_slot.dart:137` | `(error==null) != (errorCode==null)` XOR | Bridge 只给 `error` 不给 `errorCode`（最常见写法）→ 整条丢 |
| `ephemeral_side_chat_protocol_slot.dart:188-192, 259-263`、`persisted_side_chat_protocol_slot.dart:111-115` | entry 与 error 必须恰好一个 | 「既有结果又有告警」/「pending ack」被判死 |
| `codex_desktop_continuity_protocol_slot.dart:269-273` | `origin != 'desktop_rollout'` 抛 | 新增来源即整条丢 |
| `codex_desktop_continuity_protocol_slot.dart:274-278` | historyReady 与 state 联动 | Bridge 语义微调即整条丢 |
- **修复**：交叉不一致降级为「取其一 + 日志」；`errorCode` 缺失降级为 `'unknown'`；非预期 origin 忽略本条。

### [P2] `R/local_features/slots/side_chat_protocol_slot.dart:174-190` — 一个坏 option 让整个提问消失，侧边会话永久卡死
- **触发**：`utils/request_user_input.dart` 的设计是「任一问题项校验失败 → 返回 `const []`」，这里再用 `questions.length != rawQuestions.length` 把它**升级为 FormatException**。某题多了个非 String 的 `description`、或 `multiSelect` 传了 `"true"` → 整条 `side_chat_event` 丢 → **用户永远收不到这个提问，而 Bridge 在等回答**。
- **修复**：坏问题项跳过；实在无法解析也应下发「无法渲染的提问」占位，让用户至少能中断会话。

### [P2] 集合上限策略不一致 / 客户端静默截断
- `conversation_mirror_protocol_slot.dart:320-326, 502-516`：`entries`/`upserts` **无长度上限**，而姊妹文件 `conversation_content_protocol_slot.dart:4-6, 190-198` 有 `_conversationContentMaxEntries=2000`。异常/恶意 Bridge 发百万条即移动端 OOM。
- `codex_core_actions_protocol_slot.dart:305, 362`：`rawTools.take(128)` 客户端静默截断，但 `toolsTruncated` 只来自服务端 → 服务端返 200 个 tool 且 `truncated:false` 时，UI 展示 128 个并宣称「完整」。修复：`truncated = serverFlag || rawList.length > limit`。
- `file_transfer_protocol_slot.dart:641-655`：token 硬编码 43 字符正则、etag 硬编码 32 字符 → 服务端换算法/加 `W/` 弱校验前缀即上传下载全线中断。修复：放宽为字符集 + 区间。

### [P2] `R/local_features/protocol_host.dart:109-127` — slot 注册表无唯一性校验
- **触发**：两个 slot 声明同一 wire type 时**第一个静默胜出**，且 getter 里的 `.toSet()` 把重复彻底掩盖，连能力广播都看不出异常。
- **兼性能问题**：`:133` 对每条消息做 13 次 `List.contains` 线性扫描；history 批量解析时每条都走这里。
- **修复**：改 `Map<String, LocalFeatureProtocolSlot>` 注册表（顺带 O(1)），构造/测试中断言无重复。

### [P2] 协议版本协商缺位（全部 slot 通病）
- 出站消息都写死 `'protocolVersion': 1`（`conversation_mirror_protocol_slot.dart:435`、`conversation_content_protocol_slot.dart:317/333/344/353`），但**没有任何解码路径读取服务端消息的版本字段**（`tryDecode` 只看 `type`）。v2 Bridge 若改变字段语义（`utilization` 由百分比改分数、时间戳单位变化），客户端会按 v1 **静默误读**，没有降级也没有拒绝。
- `file_transfer_protocol_slot.dart:36-39, 368-380` 的 v2/v3 判定靠 `json['type'] == '..._v3'` 字符串二次比较，降级路径静默丢 `savedPath`。
- **修复**：服务端事件携带 `protocolVersion`，解码时校验；未知高版本走「最小可用字段」降级。版本判定提到 `tryDecode` 显式传参。

### [P2] `R/local_features/slots/conversation_content_protocol_slot.dart:371-376` — 新增必填字段导致老 Bridge 不可用
- `subscribed` 事件强制 `hotConversationLimit != null`，旧 Bridge 无法建立订阅 —— 与能力降级目标相反。
- **修复**：新增字段一律可选 + 客户端本地默认值，只对 `subscriptionId`/`revision` 强校验。

### [P2] 零散裸强转（触发即整条丢弃）
| 位置 | 代码 |
|---|---|
| `R/local_features/slots/conversation_mirror_protocol_slot.dart:355` | `json['notModified'] as bool? ?? false` —— 本文件**唯一**没走 helper 的字段 |
| `R/local_features/slots/codex_desktop_continuity_protocol_slot.dart:199-200` | `historyReady` / `handoffQueued` 裸 `as bool?` |
| `R/local_features/slots/session_insights_protocol_slot.dart:266` | `spendControlReached` 裸 `as bool?` |
| `R/messages.dart:1008, 1012, 1022, 1237, 1240, 1251, 1271` | `.map((e) => e as String)` —— 一个非串元素干掉整个 `session_list`，**用户失去全部会话列表**；同文件 `:1032, 1246, 1280` 用的是安全的 `whereType<String>()` |
| `R/messages.dart:737-738, 761` | `(json['utilization'] as num).toDouble()` / `resetsAt as String` / `provider as String` 全非空 —— 而隔壁 `session_insights_protocol_slot.dart:209` 已是 `as num?)?.toDouble() ?? 0` 的加固版 |
| `R/messages.dart:1078, 1115, 1122-1123, 1149-1151, 1222-1224, 1229-1230, 1358, 1391-1392, 1406, 1409, 3229, 3460, 4402, 4764-4766, 4820-4822, 627-629, 649-654, 682-690` | 必填字段裸 `as String` / `as int` |
| `R/messages.dart` 共 57 处 `as int` / `as int?` | vs 11 处安全的 `as num?)?.toInt()`；`machine.g.dart:33` 生成代码反而正确 |

### [P2] `R/local_features/slots/session_insights_protocol_slot.dart:405`（配合 `:274`）— 限流卡片被整张丢弃
- `hasData => fiveHour != null \|\| sevenDay != null`，而只携带 `rateLimitReachedType`/`spendControlReached` 的卡片（**恰恰是「已达上限」这个最该显示的场景**，此时窗口数据往往缺失）会被 `.where((card) => card.hasData)` 过滤掉。
- **修复**：`hasData` 增加 `|| rateLimitReachedType != null || spendControlReached == true`。

### [P2] `R/local_features/slots/session_insights_protocol_slot.dart:414` — provider 静默降级为空串
- provider 缺失或改名（如 `openai`）→ `?? ''` → `session_insights_controller.dart:65` 的 `provider.provider == 'codex'` 永不命中 → `codexUsage` 恒 null → **UI 空白且 `hasError` 也为 false，无任何提示**。
- **修复**：丢弃并记录，或暴露「存在无法识别 provider」的降级标志。

### [P2] `R/local_features/slots/side_chat_protocol_slot.dart:487-494` — 可选字段空串抛异常
- TS 侧 `field ?? ''` 是极常见默认值，这里 `if (value is! String || value.trim().isEmpty) throw`。同款：`codex_desktop_continuity_protocol_slot.dart:171-178`、`auto_approval_protocol_slot.dart:220-231`。
- **修复**：空串归一为 null。

### [P2] `R/local_features/slots/codex_core_actions_protocol_slot.dart:200-215, 350-358, 394-399`
- `status`/`action` 闭合白名单，Bridge 新增 `'queued'`/`'partial'` → 整条丢 → 待决请求挂死。
- `_codexCoreActionString` 一个 helper 承担矛盾语义：超长 `message` **静默返回 null**（错误详情整段消失），超长 `sessionId` 却变致命错误；且它对 ID 做 `trim()` 而发送端不 trim（`_requireCodexCoreActionId` 只校验），requestId 含首尾空白则 `matchesTerminalResponse` **永远匹配不上，请求挂死**。
- **修复**：白名单外映射为 `unknown`；helper 拆成 `requiredId()`（不 trim、超长报错）与 `optionalText()`（超长截断并标记）。

---

## P3

- **[P3] `R/local_features/slots/conversation_content_protocol_slot.dart:122`** — `entry.decodeMessage();` 丢弃返回值仅做校验：一次快照最多 2000 条，每条 `ServerMessage.fromJson` 被执行**两次**（消费方还会再调）；且未知 `type` 在 `messages.dart:1665` 返回 `ErrorMessage` 而非抛，这个「校验」抓不到未知类型，反而让未知消息以错误气泡渲染。改为懒解码（对齐 mirror 的逐条跳过）或缓存结果。
- **[P3] `R/local_features/protocol_host.dart:145-163`** — `describeRequest` 对每条 ephemeral 消息做一次 `jsonDecode(message.toJson())` 序列化往返只为读 `type`（`ClientMessage.type` getter 就在 `messages.dart:4854`）；非法 descriptor 是 `continue` 静默跳过，后面的 slot 有机会「抢走」请求，形成静默错配。
- **[P3] `R/messages.dart:4497, 4531`** — `RecentSession.copyWithName` / `copyWithCodexApprovalDefaults` 手写枚举全部 27 个字段；新增字段忘了同步会**静默重置为默认值**。建议改 freezed。
- **[P3] `R/messages.dart:1665`** — 未知消息类型降级成 `ErrorMessage` 会作为**红色错误气泡渲染到会话里**（`chat_session_cubit.dart:1672, 3127`）。`supportedServerMessages` 协商能挡住大部分，但 history 回放里的新类型消息会漏。建议改为专门的「已忽略的未知消息」哨兵类型，UI 静默跳过。
- **[P3] `R/messages.dart:919-950, 5867-5878`** — `ServerMessageTimestamp` 走 `Expando` 旁路。`bridge_service.dart:1515-1533` 重建 `HistoryMessage` 时新对象**丢失 Expando 条目** → 时间戳回退到 `DateTime.now()`。目前 HistoryMessage 自身时间戳不渲染故无实害，但旁路设计脆弱。
- **[P3] `R/local_features/slots/subagents_models_slot.dart:50-54`** — `totalTokens` 回退值 `input + output` **不含** `cachedInputTokens` 与 `reasoningOutputTokens`，而 `ContextUsage.utilization`（`:102-105`）正是用它除以上下文窗口 → Codex 推理场景下上下文占用被系统性低估。
- **[P3] `R/local_features/slots/subagents_models_slot.dart:108-112`** — `value.toInt()` 缺 `isFinite`：NaN/Infinity 抛 `UnsupportedError`（不在「格式错误」语义内）。同项目 `session_insights_protocol_slot.dart:491` **有** `isFinite`，两处不一致。
- **[P3] `R/local_features/slots/conversation_mirror_protocol_slot.dart:320-323`** — patch 事件只认 `upserts`；若 Bridge 用 `entries` 传增量，客户端得到空列表且**不报错**（静默数据丢失比显式失败更难排查）。建议 `json['upserts'] ?? json['entries']`。
- **[P3] `R/local_features/slots/conversation_mirror_protocol_slot.dart:518-524` / `conversation_content_protocol_slot.dart:225-232`** — deletes 列表「全有或全无」：一个非法元素导致整个 patch 丢弃，mirror 与远端 revision 失步、需全量重拉。
- **[P3] `R/local_features/slots/session_insights_protocol_slot.dart:246-251`** — `json['fiveHour'] ?? json['primary']`：`fiveHour` 存在但不是 Map（`false`/`0`/`"n/a"`）时 `??` 不回退，`primary` 的有效数据被静默忽略。应改为 `_map(json['fiveHour']) ?? _map(json['primary'])`。
- **[P3] `R/local_features/slots/session_insights_protocol_slot.dart:341, 365-372`** — `status == 'available'` 大小写敏感裸串枚举；`reported.clamp(0, 1 << 31)` 魔法上界，且 `availableCount` 与 `credits` 列表可自相矛盾无校验。
- **[P3] `R/local_features/slots/file_transfer_protocol_slot.dart:94-100, 567`** — cancel direction 出入站不对称：入站按字面量 `'upload'/'download'` switch，出站用 `direction.name`。IDE 重命名枚举会静默破坏线协议且编译期无感知（同仓 `FileBrowserNodeKind` 都有显式 `wireValue`）。
- **[P3] `R/local_features/slots/file_browser_protocol_slot.dart:1262-1270`** — `trim().isEmpty` 校验却返回**未 trim** 的原值；与 `_fileBrowserIsBoundedIdentifier`（`:1281-1286`，要求 `value.trim() == value`）语义不一致。带尾空格的 filename 流到下载保存路径会有跨平台差异。
- **[P3] `R/local_features/slots/file_browser_protocol_slot.dart:575-578, 718-723`** — 路径判重用精确字符串，无 Unicode 归一。macOS APFS 返回 NFD、其他来源 NFC 时既不判重也无法命中本地缓存 key。
- **[P3] `R/local_features/slots/file_browser_protocol_slot.dart:333-347` 与 `file_transfer_protocol_slot.dart:456-458`** — 上传大小上限用了两个不同常量（`maxFileBrowserDownloadBytes` vs `maxFileTransferBytes`），当前同为 15GB 属巧合；任一处调整即产生「授权挑战通过但上传被拒」。
- **[P3] `R/local_features/slots/file_browser_protocol_slot.dart:941-991`** — 认证状态机无降级：`state`/`enrolled` 强制同时具备两个 bool、`challenge` 强制不得出现 state 字段。新增认证方式（passkey）即整条失败 + 挂到超时。
- **[P3] `R/local_features/slots/codex_core_actions_protocol_slot.dart:93-129`** — 参数校验放在 `toJson()` 而非构造函数，`const CodexReviewCommitTarget('')` 可合法构造、发送那刻才抛，错误现场远离根因；`:115` 显式发送 `'title': null`，若 Bridge 用 zod `.optional()` 会被拒。
- **[P3] `R/local_features/slots/ephemeral_side_chat_protocol_slot.dart:37-43, 226`** — 请求侧用伪 session id `'ephemeral-side-chat-registry'` 作 `ownerSessionId`，响应侧 `sessionId` 却是 `null` → `bridge_service.dart:4854-4860` 的 `localFeatureMessagesForSession` 永远匹配不到，只能靠全局流接收。订阅方式与其它 slot 不一致，容易误用。
- **[P3] `R/local_features/slots/subagents_protocol_slot.dart:138` + `subagents_models_slot.dart:39-43`** — 缺 threadId 兜底成 `''`，随后 `.where((a) => a.threadId.isNotEmpty)` 静默丢弃。「空串哨兵 + 静默过滤」双层隐藏，无日志无计数。
- **[P3] `R/messages.dart:2547`** — `app.cast<String, dynamic>()`：`Map.cast` 同样是惰性视图。
- **[P3] `R/messages.dart:3099-3111`（`_stringMapList`）** — 返回的是可变 `LinkedHashMap` 字面量，`QueuedInputItem.skills/mentions` 可被外部改写。

---

## 已检查未见问题的文件清单

以下文件已完整审阅，未发现上述任一类问题：

| 文件（绝对路径） | 说明 |
|---|---|
| `R/app_icon.dart` | `appIconVariantFromId` 的 `firstWhere` **带 `orElse`**，枚举解析正确 |
| `R/code_font_family.dart` | 循环匹配 + 默认值兜底，正确 |
| `R/image_paste_shortcut.dart` | `switch` 带 `_ =>` 兜底，正确 |
| `R/git_diff_interaction_mode.dart` | 同上 |
| `R/notification_preferences.dart` | 全字段 `as bool? ?? default`；`==`/`hashCode` **字段完整**；`allowsRemoteEvent` 有 `_ => true` 前向兼容兜底；`copyWith` 全为非空 bool 无 null 语义问题。**本目录质量最好的文件** |
| `R/terminal_app.dart` | 纯 `as String?`，无必填强转；`urlTemplate`/`displayName` 用 `firstOrNull` + `??` 兜底 |
| `R/new_session_tab.dart` | `fromValue` 返回 `null` 而非抛；`tabsFromJson` 有 try/catch 且空结果返回 null |
| `R/recorded_event.dart` | `fromJsonLine` 内有裸 `as`/`DateTime.parse`，但唯一入口 `parseJsonLines` 逐行 try/catch 跳过畸形行，容错完备 |
| `R/offline_pending_action.dart` | 纯不可变值对象，无序列化 |
| `R/machine.dart` + `R/machine.g.dart` | freezed + json_serializable 注解配置**合理**：`@Default` 覆盖全部可选字段、`$enumDecodeNullable(...) ?? SshAuthType.password` 对未知枚举安全降级、数值用 `(json['port'] as num?)?.toInt()`（比手写代码更安全）。`DateTime` 用 `toIso8601String()`↔`DateTime.parse()` 往返，UTC/local 属性保持一致 |
| `R/machine.freezed.dart` | 生成代码，未逐行审 |
| `R/local_features/slots/add_to_conversation_protocol_slot.dart` | `DisabledLocalFeatureProtocolSlot`，`tryDecode` 恒返回 null —— **本次审查中唯一正确的降级样板**，建议作为其它 slot 的参考模式 |
| `R/local_features/slots/side_chat_models_slot.dart` | 仅一行 `part of`，空文件（可考虑删除或加注释说明保留原因） |

---

## 建议修复顺序（按投入产出比）

1. **`protocol_host.dart:129-143` 加 per-slot try/catch 隔离** —— 一处改动把所有「整帧丢失」降级为「单特性本条不可用」。
2. **移除 4 处未知字段硬拒绝**（side_chat / auto_approval / file_browser / file_transfer）—— 决定 App 与 Bridge 能否跨版本共存。
3. **`messages.dart` 的 8 处 `.cast<String>()` 改 `.whereType<String>().toList()`** —— 消除唯一能逃出安全网、真正炸 UI 的一类。
4. **history 四处批量解析改逐条跳过** —— 消除「一坏全丢」的最大爆炸半径。
5. **枚举 `parse` 全部带 `unknown` 兜底，且 unknown 走「忽略本条」而非抛。**
6. **抽一层公共安全解析工具**（`asString/asInt/asNum/asBool/asList/asDateTimeUtc`），替换现存的三套矛盾风格；时间字段统一 `DateTime` + UTC 归一。
7. 补 `==`/`hashCode`（尤其 `QueuedInputItem`、`FileBrowserNode`、`ContextUsage`）与构造函数集合防御性拷贝；`SessionInfo.copyWith` 改 sentinel 或 freezed。

**未修改任何文件。**
