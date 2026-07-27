I'll read all four files completely.
Now let me verify a few cross-file assumptions (error handling, equality consumers, base types).
已逐行读完四个文件。先给一条关键上下文（影响所有严重度判断）：

**解码异常的实际后果**：`ServerMessage.fromJson` → `LocalFeatureProtocolHost.tryDecode`（`/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/apps/mobile/lib/models/local_features/protocol_host.dart:129`）在 `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/apps/mobile/lib/services/bridge_service.dart:1431-1877` 的 `try/catch (e, st)` 内执行。所以裸 `as` 抛 TypeError **不会崩溃 App**，但会：整条消息被丢弃 + 向所有监听者广播一条伪造的 `ErrorMessage('Parse error: ...')`。即"严格抛异常"的代价是**整页快照/整个 usage 结果静默丢失 + UI 出现假错误**，且 pending 请求只能等超时。因此下面所有"整条消息被丢弃"类问题都按较高严重度计。

---

## P1

**[P1] /Users/huyiyang/AI agent/Codex/.../slots/session_insights_protocol_slot.dart:355、398、460**
裸 `as List?` 强转 —— 后端传单个对象/Map 代替 List 时抛 TypeError，整条 `session_usage_result` 被丢弃。
触发：bridge 只有一个 provider 时返回 `providers: {...}`；或 `credits: {...}`、`limitCards: {...}`。
证据：`(json['credits'] as List?)`、`(json['limitCards'] as List?)`、`(json['providers'] as List?)`。
修复方向：加 `_sessionUsageList(dynamic v)` helper —— `v is List ? v : (v is Map ? [v] : const [])`，与本文件其它字段的容错风格保持一致。

**[P1] /Users/huyiyang/AI agent/Codex/.../slots/session_insights_protocol_slot.dart:209**
`utilization: (json['utilization'] as num?)?.toDouble() ?? 0` —— 后端传字符串 `"45.2"` 直接 TypeError，整个配额响应丢失；同时**单位语义未定义**：UI 按百分比用（`session_insights_bar.dart:559` `utilization.clamp(0,100)`、`usage_section.dart:403` 同样 clamp(0,100)、`LinearProgressIndicator(value: used/100)`），但模型不做任何归一化/校验。若 bridge 改成 0..1 分数，UI 会一直显示 0%/1% 且无任何告警。
修复方向：改用 `_sessionUsageDoubleOrNull`（num/String 双路径），并在模型层明确单位（建议存 0..1，命名 `utilizationFraction`），显式 clamp。

**[P1] /Users/huyiyang/AI agent/Codex/.../slots/conversation_content_protocol_slot.dart:43-48**
枚举解析无 fallback：`ConversationContentEventKind.parse` 遍历失败后 `throw FormatException('Unsupported conversation content event: $value')`。
触发：bridge 新增事件（如 `snapshot_cancelled`、`resumed`）→ 整条消息被丢弃 + 伪 `Parse error` 广播 → 订阅流卡死，无降级路径。
证据：兄弟文件 mirror 的同类实现（`conversation_mirror_protocol_slot.dart:109/118`）有 `unknown('__unknown__')` 兜底，且 `_validateConversationMirrorEvent:497` 对 unknown 直接 break。两个 slot 对同一形态的协议采用相反策略。
修复方向：加 `unknown` 枚举成员 + 校验时跳过，由上层忽略未知事件（前向兼容）。

**[P1] /Users/huyiyang/AI agent/Codex/.../slots/conversation_content_protocol_slot.dart:498-508**
`_conversationContentRequiredInt` 用 `if (value is! int || value < minimum)` —— JSON 里 `pageCount: 3.0` / `entryCount: 12.0`（任何以 double 形态序列化整数的后端，或经过浮点运算的字段）在 Dart 中是 `double`，直接 FormatException，整条事件丢弃。
证据：mirror 的对应实现是正确的 —— `conversation_mirror_protocol_slot.dart:568` `if (raw is! num || raw.toInt() != raw || raw.toInt() < minimum)`。同一协议族两套数值规则。
修复方向：照抄 mirror 的 `num` + 整数性判定。

---

## P2

**[P2] /Users/huyiyang/AI agent/Codex/.../slots/conversation_mirror_protocol_slot.dart:355**
`notModified: json['notModified'] as bool? ?? false` —— 本文件唯一没走校验 helper 的字段；后端传 `"true"` 或 `1` 抛 TypeError，整条 mirror 事件丢弃（其它字段全部用 `_conversationMirror*` helper）。
修复方向：加 `_conversationMirrorOptionalBool`，非 bool 时按 false 降级或抛 FormatException（至少类型一致）。

**[P2] /Users/huyiyang/AI agent/Codex/.../slots/session_insights_protocol_slot.dart:266-267**
`spendControlReached: json['spendControlReached'] as bool?` 同上；`individualLimit: json['individualLimit']` 直接持有解码出来的原始 `Object?`（可能是可变 Map/List），既无类型约束也无拷贝，属于可变集合泄漏 + 类型逃逸。
修复方向：bool 走容错 helper；`individualLimit` 至少 `_sessionUsageStringKeyedMap` 归一化后 `Map.unmodifiable`。

**[P2] /Users/huyiyang/AI agent/Codex/.../slots/session_insights_protocol_slot.dart:495-511（秒/毫秒启发式）**
```dart
final milliseconds = value.abs() < 100000000000 ? value.toInt() * 1000 : value.toInt();
```
阈值 1e11 把"小于 1e11"一律当秒。后果：(a) 1973-03 之前的**毫秒**时间戳被误当秒（放大 1000 倍）；(b) **微秒/纳秒**时间戳（> 1e11）被当作毫秒，静默算出公元 5 万年，且不触发 `RangeError`（阈值 8.64e15 才抛），UI 显示荒谬的重置时间而无任何错误。
修复方向：由协议显式约定单位（字段名带 `AtMs`/`AtSec`），或按位数分档（10 位=秒、13 位=毫秒、16 位=微秒）并对超出合理年份区间的结果返回 null。

**[P2] /Users/huyiyang/AI agent/Codex/.../slots/session_insights_protocol_slot.dart:210-219、315-322、338-339（时区往返）**
`_sessionUsageDateString` 的**字符串分支**（:510）原样透传，不做任何时区校验；随后 `DateTime.tryParse(resetsAt!)`（:219 / :339）对**无时区标识**的字符串（如 `"2026-07-25T10:00:00"`）会解析成 **local** 时间。而数字分支（:502-505）产出的是带 `Z` 的 UTC 串。同一个 getter 返回值的时区语义取决于后端传的是数字还是字符串。
下游 `usage_section.dart:496` `dt.toLocal()` 对已被误判为 local 的值是 no-op → 倒计时静默偏移一个时区（东八区偏 8 小时），`session_insights_bar.dart:560` 同理。
修复方向：在 `_sessionUsageDateString` 内统一 `DateTime.tryParse` → 若 `!isUtc` 且原串无偏移标记则视为 UTC（`DateTime.utc(...)`）→ 统一 `toIso8601String()` 输出带 `Z`；getter 侧统一 `.toUtc()`，显示侧统一 `.toLocal()`。

**[P2] /Users/huyiyang/AI agent/Codex/.../slots/session_insights_protocol_slot.dart:518-526（以及 session_insights_models_slot.dart:119-127 同款）**
```dart
if (value is! String) {
  return value?.toString().trim().isEmpty == false ? value.toString().trim() : null;
}
```
对任意类型无脑 `toString()`：`errorCode: {"code":5}` 变成字面串 `"{code: 5}"` 直接显示到 UI；`sessionId: 12345` 变成 `"12345"` 并参与 `message.sessionId != sessionId` 的相关性判断（可能错配/漏配）。这是与前述 P1 相反方向的失衡——数值/列表字段过严，字符串字段过松。
修复方向：只接受 String（可选地接受 num 显式转换），Map/List 一律返回 null。

**[P2] /Users/huyiyang/AI agent/Codex/.../slots/session_insights_protocol_slot.dart:405（配合 :274 `hasData`）**
`.where((card) => card.hasData)` 而 `hasData => fiveHour != null || sevenDay != null` —— 只携带 `rateLimitReachedType` / `spendControlReached`（"已限流"信号，通常此时窗口数据缺失）的卡片会被整张丢掉，用户看不到"已达上限"提示。
修复方向：`hasData` 增加 `|| rateLimitReachedType != null || spendControlReached == true`。

**[P2] /Users/huyiyang/AI agent/Codex/.../slots/session_insights_protocol_slot.dart:414**
`provider: _sessionUsageNonEmptyString(json['provider']) ?? ''` + 消费方 `session_insights_controller.dart:65` `if (provider.provider == 'codex')` —— provider 缺失或改名（如 `openai`）时静默降级为空串，`codexUsage` 永远为 null，UI 空白且无错误提示（`hasError` 也因 `error == null` 为 false）。
修复方向：provider 为空时丢弃该条并记录，或让 `SessionUsageResultMessage` 暴露"存在无法识别 provider"的降级标志。

**[P2] 相等性/hashCode 全面缺失**
- `/Users/huyiyang/AI agent/Codex/.../slots/session_insights_models_slot.dart:7`（`ContextTokenUsage`）、`:59`（`ContextUsage`）
- `/Users/huyiyang/AI agent/Codex/.../slots/session_insights_protocol_slot.dart:196/222/278/344/377/434`（Window / LimitCard / ResetCredit(s) / Info / ResultMessage）
- `/Users/huyiyang/AI agent/Codex/.../slots/conversation_mirror_protocol_slot.dart:122/267`、`conversation_content_protocol_slot.dart:84/127`

全部为手写 model 且**无 `==`/`hashCode`**，退化为引用相等。实际影响：`session_insights_controller.dart:168-176` 收到 `context_usage` 就无条件 `_contextUsage = message.usage; notifyListeners();`——流式场景下每个 turn 推送一次，即使 token 数完全相同也强制重建 insights bar，且消费方没有任何手段去重（`ContextUsage() == ContextUsage()` 恒 false）。
修复方向：为这些数据类补值相等（含 List 用 `listEquals`/`DeepCollectionEquality`，切勿只比引用），或改用 freezed/Equatable；controller 侧加 `if (_contextUsage == next) return;`。

**[P2] 可变集合泄漏（构造函数不拷贝）**
- `conversation_mirror_protocol_slot.dart:128-133`（`rawMessage` 直接持有外部 Map）、`:289-307`（`entries`/`deletes`）
- `conversation_content_protocol_slot.dart:85-90`、`:128-148`
- `session_insights_protocol_slot.dart:348-351`（`credits`）、`:386-394`（`limitCards`）、`:441-446`（`providers`）

只有 `fromJson` 路径做了 `List.unmodifiable`/`Map.unmodifiable`；任何其它构造点（测试、mock、`codex_desktop_continuity_protocol_slot.dart:205` 这类转发、录制回放）都会让 model 持有调用方仍可修改的集合，`const` 构造函数还会让人误以为不可变。
修复方向：构造函数体内统一 `List.unmodifiable(...)`（或将字段声明为 `UnmodifiableListView` 并在工厂里包装）。

**[P2] /Users/huyiyang/AI agent/Codex/.../slots/conversation_mirror_protocol_slot.dart:320-326、502-516**
mirror 的 `entries`/`upserts` **无长度上限**，与 content slot 形成鲜明对比（`conversation_content_protocol_slot.dart:4-6, 190-198` 有 `_conversationContentMaxEntries=2000` / `MaxPageEntries=32`）；chunk 消息有严格上限（:234-241）但事件内联 entries 没有。一个异常/恶意 bridge 发来百万条 entries 会被全量物化（每条还做一次 `Map.unmodifiable`）→ 移动端 OOM。
修复方向：补齐与 content 一致的上限常量与校验。

**[P2] 协议版本协商缺位（四个文件通病）**
客户端出站消息都写死 `'protocolVersion': 1`（`conversation_mirror_protocol_slot.dart:435`、`conversation_content_protocol_slot.dart:317/333/344/353`），但**没有任何解码路径读取服务端消息的版本字段**（`tryDecode` 只看 `type`）。v2 bridge 若改变字段语义（例如 `utilization` 由百分比改分数、时间戳单位变化），客户端会按 v1 静默解读，没有降级或拒绝路径。
修复方向：服务端事件里携带 `protocolVersion`，解码时校验；未知高版本走"最小可用字段"降级而非静默误读。

**[P2] /Users/huyiyang/AI agent/Codex/.../slots/conversation_content_protocol_slot.dart:371-376**
`subscribed` 事件强制要求 `hotConversationLimit != null`，缺失即整条拒绝。旧版 bridge（未实现该字段）无法建立订阅，属于"新增必填字段导致老服务端不可用"，与"能力降级"目标相反。
修复方向：新增字段一律可选 + 客户端本地默认值，仅对真正的核心字段（subscriptionId/revision）强校验。

**[P2] /Users/huyiyang/AI agent/Codex/.../slots/conversation_mirror_protocol_slot.dart:86-95**
```dart
final message = error.message.toLowerCase();
return message.contains(request.requestType.toLowerCase()) && RegExp(...).hasMatch(message);
```
该匹配**只按 requestType 字符串匹配，不做 session / requestId 关联**。两个会话并发执行 `conversation_mirror_sync` 时，属于会话 A 的通用错误会消费掉会话 B 的 pending slot——与第 88-89 行注释声称的"unrelated session error can never consume this feature's pending slot"矛盾。
修复方向：要求 `ErrorMessage` 携带 sessionId/requestId 并参与匹配；无法关联时宁可让请求走超时。

---

## P3

**[P3] /Users/huyiyang/AI agent/Codex/.../slots/session_insights_models_slot.dart:108-112**
`if (value is num) return value.toInt();` 缺 `isFinite` 检查 —— `double.nan.toInt()` / `infinity.toInt()` 抛 `UnsupportedError`（非 FormatException，也不在"格式错误"语义内）。同文件同项目的 `session_insights_protocol_slot.dart:491` 是有 `value.isFinite` 的，两处不一致。`conversation_mirror_protocol_slot.dart:568` 的 `raw.toInt() != raw` 同样会在 NaN 上先抛 UnsupportedError。标准 JSON 不产 NaN，故为 P3，但从非 JSON 路径（Dart 内部构造的 Map、宽松解析器）传入即触发。
修复方向：统一 `value.isFinite` 前置判断。

**[P3] /Users/huyiyang/AI agent/Codex/.../slots/session_insights_models_slot.dart:50-54**
`totalTokens: ... ?? input + output` —— 回退值不含 `cachedInputTokens` 与 `reasoningOutputTokens`，而 `ContextUsage.utilization`（:102-105）正是用 `last.totalTokens / modelContextWindow`。bridge 未给 `totalTokens` 时上下文占用被系统性低估（Codex 推理 token 可能占比很大）。
修复方向：回退式改为 `input + output + reasoning`（或明确文档化口径），并在缺失时标记为"估算值"。

**[P3] /Users/huyiyang/AI agent/Codex/.../slots/conversation_content_protocol_slot.dart:122**
`entry.decodeMessage();`（丢弃返回值仅做校验）—— 一次快照最多 2000 条，每条 `ServerMessage.fromJson` 被执行两次（这里 + 消费方再调一次），移动端 CPU 双倍开销；且未知 `type` 在 `messages.dart:1665` 会返回 `ErrorMessage(...)` 而非抛异常，所以这个"校验"抓不到未知类型，反而会让未知消息以错误气泡渲染；而 envelope 缺 `type` 时 `messages.dart:959` 的 `json['type'] as String` 抛 TypeError，**整页**被丢弃（mirror 侧是懒解码 + 消费方 try/catch 逐条跳过，见 `conversation_mirror_service.dart:1790` / `:2172`，容错明显更好）。
修复方向：改为轻量校验（只检查 `type is String`），或缓存解码结果，或对齐 mirror 的"逐条跳过"策略。

**[P3] /Users/huyiyang/AI agent/Codex/.../slots/conversation_mirror_protocol_slot.dart:320-323**
```dart
final rawEntries = switch (event) {
  ConversationMirrorEventKind.patch => json['upserts'],
  _ => json['entries'],
};
```
patch 事件只认 `upserts`。若 bridge（或旧版本）在 patch 里用 `entries` 传增量，客户端得到空列表且**不报错**——静默数据丢失比显式失败更难排查。
修复方向：`json['upserts'] ?? json['entries']`，或在 patch 同时出现两者/两者皆无时显式报错。

**[P3] /Users/huyiyang/AI agent/Codex/.../slots/conversation_mirror_protocol_slot.dart:518-524 与 conversation_content_protocol_slot.dart:225-232**
deletes 列表"全有或全无"：一个非法元素（空串、非 String）导致整个 patch 被丢弃，mirror 与远端 revision 失步、需要全量重拉。
修复方向：过滤非法项 + 记录 warning，仅当核心字段（revision/baseRevision）不一致时才整体拒绝。

**[P3] /Users/huyiyang/AI agent/Codex/.../slots/session_insights_protocol_slot.dart:341**
`status == 'available'` 大小写敏感的裸字符串枚举，无归一化、无未知值处理；`resetType`/`source` 同样是自由字符串。
修复方向：`status.toLowerCase()` 归一，或定义带 `unknown` 兜底的枚举。

**[P3] /Users/huyiyang/AI agent/Codex/.../slots/session_insights_protocol_slot.dart:365-372**
`reported.clamp(0, 1 << 31).toInt()` 魔法上界，且 `availableCount` 与 `credits` 列表可自相矛盾（后端报 5，列表里只有 2 条 available），无一致性校验。
修复方向：取 `min(reported, credits.where(isAvailable).length)` 或至少记录不一致。

**[P3] /Users/huyiyang/AI agent/Codex/.../slots/session_insights_protocol_slot.dart:246-251**
`json['fiveHour'] ?? json['primary']` —— 当 `fiveHour` 存在但不是 Map（例如 `false`、`0`、`"n/a"`）时，`??` 不会回退到 `primary`，`_sessionUsageStringKeyedMap` 返回 null，`primary` 里的有效数据被静默忽略。
修复方向：`_sessionUsageStringKeyedMap(json['fiveHour']) ?? _sessionUsageStringKeyedMap(json['primary'])`。

**[P3] copyWith（审查点 7）— 四个文件均未定义 copyWith**
不存在 `copyWith` 的 null 语义歧义问题。但 `ContextUsage` / `SessionUsageInfo` 是被 controller 长期持有的状态（`session_insights_controller.dart:44/63`），没有安全的局部更新入口，只能整体替换；结合上面"无 `==`"这一点，后续若手写 copyWith 很容易引入"传 null 表示不变 vs 表示清空"的经典缺陷。
修复方向：若要加，统一用 sentinel 对象或 freezed 生成，不要用裸 `Object? x` + `?? this.x`。

---

## 两个 slot 的横向一致性问题（建议统一）

同为"provider + providerSessionId + revision + 分页 entries"的镜像协议，`conversation_mirror` 与 `conversation_content` 在四处采取了相反策略，容易在维护中互相踩坑：

| 维度 | mirror | content | 建议 |
|---|---|---|---|
| 未知枚举 | `unknown` 兜底（:109/118） | 直接抛（:47） | 统一兜底 |
| int 解析 | 接受整数值 double（:568） | 只接受 `int`（:504） | 统一 mirror 版 |
| entry 校验 | 懒解码，消费方逐条 try/catch | 构造时 eager decode，整页失败（:122） | 统一懒解码 |
| entries 上限 | 无 | 2000/32（:4-6） | mirror 补上限 |

以上即全部发现，未修改任何文件。
