I'll read all four files in full.
以下为四个文件的完整审查结果。

---

# A. 反序列化健壮性

### A1 · P1 · `diff_parser.dart:558` — 裸 `as String`，直接在 build 期抛 TypeError

```dart
final filePath = (input['file_path'] ?? input['path'] ?? '') as String;
```

- **触发**：Bridge 侧 `Edit/Write/MultiEdit` 的 `input.file_path` 未来变成结构化对象（如 `{path, uri}`）、数字、或 Codex 侧用不同类型承载。协议是 additive，这完全可能。
- **爆炸半径**：`lib/widgets/bubbles/assistant_bubble.dart:841` 在 `_editDiff` getter 里同步调用，而 `_editDiff` 在 `build()`（该文件 L934/L951）中求值 → 整个 assistant 气泡子树红屏，且 `_editDiffResolved` 已置 true 无法恢复。
- **修复方向**：`final filePath = (input['file_path'] ?? input['path'])?.toString() ?? '';`

### A2 · P1 · `diff_parser.dart:569-570` / `586-587` / `595` — 同类裸 `as String`

```dart
final oldString = (input['old_string'] ?? '') as String;   // 569
final newString = (input['new_string'] ?? '') as String;   // 570
final oldString = (edit['old_string'] ?? '') as String;    // 586
final newString = (edit['new_string'] ?? '') as String;    // 587
final content   = (input['content'] ?? '') as String;      // 595
```

- **触发**：`Write.content` 未来允许 content-block 数组（Anthropic 已在别处这么做）；`old_string` 为 null 以外的任意非字符串。
- **修复**：统一 `?.toString() ?? ''`，并对 `synthesizeEditToolDiff` 整体加 `try/catch` 返回 `null`（函数注释已声称"malformed 时返回 null"，但实际做不到）。

### A3 · P2 · `diff_parser.dart:585` — 严格泛型判断导致静默丢弃

```dart
if (edit is Map<String, dynamic>) {
```

- **触发**：`edits` 元素若来自 `Map.from()`/`jsonDecode` 后再经 `cast()` 变成 `Map<dynamic,dynamic>`，或 Bridge 发来 `edits: [[old,new],...]` 之类新形态 → 该 hunk 被无声跳过，UI 显示"空 diff"而非报错。
- **修复**：`if (edit is Map)` + 逐键 `?.toString()`。

### A4 · P2 · `diff_parser.dart:313-314` — `int.parse` 无 `tryParse` 兜底

```dart
final oldStart = match != null ? int.parse(match.group(1)!) : 1;
final newStart = match != null ? int.parse(match.group(2)!) : 1;
```

- **触发**：`@@ -99999999999999999999,1 +1,1 @@`（超 64bit）。正则 `\d+` 不限位数 → `int.parse` 抛 **FormatException**；Web(dart2js) 则静默精度丢失，行号错乱。`parseDiff` 全链路无 try/catch，异常直达 `git_view_cubit.dart:86/108`。
- **修复**：`int.tryParse(...) ?? 1`，并对结果 `clamp(0, 1<<31)`。

### A5 · P2 · `history_window_policy.dart:291-301` — 空 `id` 的 ToolUseContent 被静默删除且不记 gap

```dart
if (content is! ToolUseContent ||
    (content.id.trim().isNotEmpty && retainedToolIds.contains(content.id.trim())))   // 291-293  保留条件
...
if (content is ToolUseContent && content.id.trim().isNotEmpty && ...)                // 298-300  omitted 条件
```

- **触发**：Bridge/Codex 发来无 `id` 或 id 为空白的 tool_use（additive 协议下完全合法的新形态）。该 content 既不在 `retainedContent`（保留失败），也不在 `omittedTools`（不记 gap）→ **工具调用彻底消失，连"已省略 N 个工具"的占位都没有**。
- **对比不一致**：`L364-369` 的 `ToolResultMessage` 分支里，空 `toolUseId` 反而**总是被保留**。同一个空 ID，一个丢一个留。
- **修复**：为空 id 生成合成 id（如 `anon-tool-$index-$position`）后统一走 gap 路径。

### A6 · P3 · `history_window_policy.dart:386` — 裸 `as AssistantServerMessage`

```dart
final message = current.message as AssistantServerMessage;
```
当前三个 `host.outputIndex` 来源（L256 / L331 / L340）都指向刚 add 的 `AssistantServerMessage`，暂时安全；但 L340 的 `projected.length - 1` 是隐式耦合，任何一处新增分支就会变成运行期 TypeError。**修复**：改 `if (current.message case final AssistantServerMessage m)` 模式匹配 + 跳过。

### A7 · P3 · `tool_categories.dart:317-319` — `jsonEncode` 未保护

```dart
String _jsonFallback(Map<String, dynamic> input) =>
    const JsonEncoder.withIndent('  ').convert(input);
```
含非 JSON 可编码值（自定义对象 / 循环引用）时抛 `JsonUnsupportedObjectError`。**修复**：try/catch → `input.toString()`。

> **正面**：`tool_categories.dart` 全文无裸 `as`，一律 `?.toString()`；**没有**任何严格 key 白名单在遇到未知字段时抛异常 —— 未知字段一律被忽略（`_otherFullInput` L310 甚至会遍历全部 key）。这一点是 additive 协议友好的。

---

# B. 时间 / 时区

**四个文件均无 `DateTime` / `tryParse` / `toLocal` / `toUtc` / ISO 字符串比较。** 逐项确认：

- `history_window_policy.dart:141-145` 是唯一触及时间的地方，仅原样透传 `entry.timestamp` 与 `entry.timestampIsAuthoritative` 重建 `ServerChatEntry`，不做解析或比较。
- 整个窗口算法的排序完全基于 **list index**，不基于时间戳 → 不存在 ISO 字典序比较问题。
- 唯一相关风险（P3）：`selectTurnAwareChatEntryWindow:121` 合成 `UserInputMessage(text: text)` 时丢弃时间戳，但输出端 L146 又返回原 `entry`，所以无实际影响。

**本组无 P0-P2 发现。**

---

# C. 身份 / 缓存键

### C1 · P2 · `history_window_policy.dart:245` 与 `126` — 用列表下标构造稳定 ID

```dart
id: 'history-tool-gap-$sourceIndex',        // 245
id: 'streaming-window-$index',              // 126
```

- **问题**：ID 来自当前 list 的**位置**，而非内容或会话身份。
- **触发**：分页加载更早历史时会在列表**头部 prepend** → 所有 index 位移 → 同一条 gap 气泡的 id 从 `history-tool-gap-40` 变成 `history-tool-gap-140`。下游任何按 `message.id` 做 dedupe / ValueKey / 滚动锚点的逻辑都会认为是新消息 → 重建、滚动跳变、重复渲染。
- **不含** `provider` / `bridgeInstanceId` / `sessionId` / `sourceHome`：两个不同 session 同时渲染时 id 必然碰撞。
- **修复**：改用来源消息的 `messageUuid`（L250 已经能拿到）或 `sha256(sessionId + provider + toolUseIds)`。

### C2 · P2 · `history_window_policy.dart:419-425` — `historyToolDetailGapId` 只哈希 toolUseIds

```dart
String historyToolDetailGapId(List<String> toolUseIds) {
  final digest = sha256.convert(utf8.encode(jsonEncode(toolUseIds))).toString().substring(0, 24);
  return 'tool-gap-v1:${toolUseIds.length}:$digest';
}
```

- **缺失维度**：无 `provider`、无 `bridgeInstanceId`、无 `sessionId`、无 `sourceHome`。两台 Bridge / 两个 session 若出现相同的 tool id 集合（Codex 的 `call_1`、`item_0` 这类短序号 id 极易重复），gapId 完全相同 → 跨会话缓存/GlobalKey 冲突。
- **顺序敏感**：`jsonEncode(List)` 使得 `[a,b]` 与 `[b,a]` 产出不同 gapId，但语义上是同一组省略工具 → 重放历史时 gapId 抖动。
- `substring(0, 24)` 本身安全（sha256 hex 恒为 64 字符）。
- **修复**：入参加 `sessionId`/`provider`，并对 ids 先 `..sort()`。

### C3 · P3 · `diff_parser.dart:525` — hunk 键是纯位置键

```dart
if (selectedHunkKeys.contains('$fileIdx:$hunkIdx')) {
```
不含 `filePath`、不含 hunk header。当前唯一调用点 `git_screen.dart:599` 是同步构造同步消费（`reconstructDiff(state.files, {'$fileIdx:$hunkIdx'})`），所以现网安全；但只要有人把选中集合跨一次 `get_diff` 刷新持有（文件顺序会变），就会 **stage/revert 到错误的 hunk**。**修复**：键改为 `'${file.filePath}#${hunk.header}'`。

---

# D. 路径处理

### D1 · P2 · `diff_parser.dart:688-693` — `lastIndexOf(' b/')` 在路径含 " b/" 时取错

```dart
if (!payload.trimLeft().startsWith('"')) {
  final newPathMarker = payload.lastIndexOf(' b/');
  if (newPathMarker >= 0) {
    return _decodeGitPathToken(payload.substring(newPathMarker + 1));
  }
}
```

- **触发**：`diff --git a/docs/a b/c.md b/docs/a b/c.md`（目录名恰好是 `a`，文件在 `b/` 下，或任意含 " b/" 子串的路径）。`lastIndexOf` 命中的是**新路径内部**的 " b/" → 返回 `c.md` 而非 `docs/a b/c.md`。
- **后果**：`isImageFile` 判断错、文件名显示错、`reconstructDiff` 写出的 header 指向不存在的文件 → `git apply` 失败或 **Request-change 请求被静默丢弃**。
- **修复**：先按 `payload.length` 对半切（git 保证 `a/X b/X` 两侧等长同名），或优先用 `---`/`+++` 行。

### D2 · P2 · `diff_parser.dart:735` — 兜底把整行当路径

```dart
return _decodeGitPathToken(payload);
```
tokens < 2 时返回 `a/x b/x` 整串作为 filePath。**修复**：返回 `''` 并让上层跳过该文件。

### D3 · P2 · `diff_parser.dart:666-678` — 反序列化/序列化不对称，无引号与转义

```dart
buffer.writeln('diff --git a/${file.filePath} b/${file.filePath}');
```
`_decodeGitPathToken`（L738-796）会**解码**八进制转义、去引号，但 `_writeFileHeader` 写回时**不重新编码**。含空格 / 非 ASCII / 引号 / 换行的路径经过一次 parse→reconstruct 就变成不可解析的 patch。且 `filePath` 为空时产出 `diff --git a/ b/`（`_parseSingleFileDiff` L262 的默认值就是 `''`）。**修复**：写出前做 git quote-path 逆变换。

### D4 · P3 · `diff_parser.dart:265-277` — 三条 `+++` 分支解码方式不一致

```dart
if (line.startsWith('+++ b/'))  { filePath = line.substring(6); break; }          // 266-268 不解码
if (line.startsWith('+++ "b/')) { filePath = _decodeGitPathToken(line.substring(4)); break; }  // 270-272
if (line.startsWith('+++ ') && !line.startsWith('+++ /dev/null')) { ... }         // 274-277
```
第一分支跳过 `_decodeGitPathToken`；三个分支都不剥离 `diff -u` 附带的 `\t2026-07-26 12:00:00` 时间戳后缀 → 文件名带 tab 与时间戳。

### D5 · P2 · `diff_parser.dart:265-277` — 该循环遍历**全部行**，会把 hunk 正文误判为文件头

同上循环没有在首个 `@@` 处停止。若正文中有一条新增行其内容以 `++` 开头（如 Markdown `++高亮++`、C++ 的 `++i`），该行形如 `+++高亮++`，命中 L274 → 被当成文件路径。**修复**：只在首个 `@@` 之前扫描。

### D6 · P2 · `tool_categories.dart:329-330` 与 `338-340` — 只认 `/`，Windows / 尾斜杠全错

```dart
final idx = path.lastIndexOf('/');
return idx >= 0 ? path.substring(idx + 1) : path;                       // 329-330
final name = path.contains('/') ? path.substring(path.lastIndexOf('/') + 1) : path;  // 338-340
```
- Windows Bridge（`C:\Users\x\main.dart`）→ 返回整条长路径，摘要栏被撑爆。
- 路径以 `/` 结尾 → 返回**空字符串**，摘要栏空白。
- 无 `~` 展开、无大小写归一、无 URL decode。与 `_fileFullInput`（L301-305，原样返回）风格也不统一。
- **修复**：抽一个共用 `basename()`，同时切 `/` 与 `\`，并 `trimRight('/\\')`。

### D7 · P3 · `diff_parser.dart:744-746` — 无条件剥 `a/`/`b/` 前缀

```dart
if (normalized.startsWith('a/') || normalized.startsWith('b/')) {
  normalized = normalized.substring(2);
}
```
在 `_parseSingleFileDiff` L274 分支（工具结果里的裸路径）下，真实存在的顶层目录 `b/` 会被吃掉：`b/foo.dart` → `foo.dart`。

### D8 · P3 · `diff_parser.dart:9-24` — 图片扩展名白名单不可扩展

缺 `.heic` `.heif` `.avif` `.tiff` `.jfif`。additive 协议下 Bridge 新增图片类型，App 侧只会按文本渲染二进制。**修复**：扩展名集合改为可从 Bridge 能力协商注入，或退化为"未知扩展 + isBinary → 尝试图片"。

---

# E. 数值 / 边界 / 正则复杂度

### E1 · P1 · `composer_tokens.dart:191-221 + 390-396 + 404` — O(n²) 扫描 + 每字符编译正则，主线程卡死

```dart
while (index < text.length) {          // 191
  ...
  final end = _findTokenEnd(text, index);   // 198  → 内部逐字符 O(n)
  ...
  if (category == null) { index++; continue; }   // 206-209  不前进到 end！
```
```dart
int _findTokenEnd(String text, int start) {
  var cursor = start + 1;
  while (cursor < text.length && !_isWhitespace(text[cursor])) cursor++;  // 392
  return cursor;
}
bool _isWhitespace(String value) => RegExp(r'\s').hasMatch(value);        // 404
```

- **触发**：粘贴一段**无空白**的长文本，其中反复出现"边界字符 + 触发符"，例如 `:$a:$b:$c...`（`:` 在 L401 的边界集合内）或 Claude provider 下的任意 `$`。每个 `$` 都是边界 → `_findTokenEnd` 从该位置扫到**字符串末尾**（无空白）→ O(n)；`_resolveCategory` 返回 null（L366-368，非 codex 直接 null）→ 只 `index++` → 下一个 `$` 重复扫描。总计 **O(n²)**。
- **放大 60 倍**：`_findTokenEnd` 内层每次比较都 `RegExp(r'\s')` **新建并编译**一个正则（L404），`_isTokenBoundary`（L401）同理每次新建 `RegExp(r'[\(\[\{:,;]')`。
- **执行时机**：`buildTextSpan`（L257）→ 每帧 / 每次按键重跑，无缓存。100KB 无空白文本 ≈ 2.5e9 次正则编译 → UI 完全冻结。
- **说明**：正则本身（`\s`、字符类、`^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@`）**均为线性，无嵌套量词，不存在灾难性回溯**。真正的 DoS 来自扫描算法与正则分配，不是回溯。
- **修复**：① `_isWhitespace` / `_isTokenBoundary` 的 `RegExp` 提升为 `static final` 或直接用 code-unit 比较；② L206-209 的 `index++` 改为 `index = end`（未知类别的 token 整体跳过）；③ `parseComposerTokens` 结果按 `(text, config)` 做一层 memo；④ 对超长文本设上限（如 > 20k 字符直接返回 `const []`）。

### E2 · P1 · `diff_parser.dart:181` vs `190` — `contains` 与 `startsWith` 不对称，整个 diff 被静默丢空

```dart
if (!diffText.contains('diff --git')) {          // 181  无尾空格
  return [_parseSingleFileDiff(lines)];
}
...
if (!lines[i].startsWith('diff --git ')) {       // 190  有尾空格
```

- **触发**：Edit 工具修改了一个**内容里提到 `diff --git`** 的文件（README、本项目 CLAUDE.md、任何 patch 文档）。tool_result 的 diff 文本中该串出现在 `+`/` ` 前缀行内 → L181 判定为"多文件模式"，但没有任何行 `startsWith('diff --git ')` → while 循环空转到结尾 → **`parseDiff` 返回 `[]`**。
- **后果**：Git 面板 / Edit 预览完全空白，无任何错误提示；`summarizeDiffSelection`（L462）返回全 0。
- **修复**：条件统一为 `diffText.split('\n').any((l) => l.startsWith('diff --git '))`；并在多文件模式解析出 0 个文件时回退到 `_parseSingleFileDiff`。

### E3 · P2 · `diff_parser.dart:399-428` — `_parseRawDiffLines` 静默吞掉内容以 `++` / `--` 开头的行

```dart
if (line.startsWith('+') && !line.startsWith('+++')) { ... }            // 399
else if (line.startsWith('-') && !line.startsWith('---')) { ... }       // 408
else if (!line.startsWith('---') && !line.startsWith('+++')) { ... }    // 417
```
新增一行内容为 `++i;`（C/C++/Dart 自增、Markdown `++mark++`）→ diff 行是 `+++i;`：三个分支全部不匹配 → **该行被完全丢弃**，既不显示也不计入 stats。删除 `--foo` 同理（`---foo`）。**修复**：改用"仅当整行等于/以 `+++ ` `--- ` 开头（带空格）时才视为文件头"。

### E4 · P2 · `diff_parser.dart:361-364` — 空行被当作"尾随换行"跳过，导致后续行号整体漂移

```dart
} else if (line.isEmpty) {
  // Empty line — likely trailing newline, skip
  i++;
  continue;
}
```
统一 diff 中"内容为空的上下文行"在很多生成器（以及 `String.split('\n')` 对末尾换行的处理）里就是空串。跳过它 → `oldLine`/`newLine` 不递增 → **该 hunk 后续所有行号少 1**（有 k 个空行就少 k），且空行内容丢失。**修复**：仅跳过位于 hunk 末尾的空行，其余作为空上下文行计入。

### E5 · P2 · `history_window_policy.dart:405-416` — 硬上限可被突破，且极端下丢掉全部最新回复

```dart
final selected = <int>{};
for (var index = 0; index < projected.length; index++) {
  if (projected[index].message is UserInputMessage) selected.add(index);   // 406-408  无上限
}
for (var index = projected.length - 1; index >= 0 && selected.length < limit; index--) {
  selected.add(index);                                                     // 409-415
}
```
第一段无条件收全部 `UserInputMessage`。若其数量 ≥ `limit`，第二个循环的守卫 `selected.length < limit` 从一开始就为 false → **返回条目数 > `maxRetainedEntries`（硬上限失效），且结果里一条 assistant 消息都没有 —— 包括最新的那条回复**。
- **现网可达性**：默认 `rootTurns = 5` 使 `start` 限制在最近 5 轮内，暂不可达；但 `L57-59` 允许 `rootTurns` 被 clamp 到 `maxRetainedEntries`（755），任何调用方传大值即触发。
- **修复**：用户消息也应参与配额（先按从新到旧收 `limit` 个，再保证每个保留区间的首个 user 消息）。

### E6 · P3 · `history_window_policy.dart:57-59` — 量纲错误的 clamp

```dart
final effectiveRootTurns = normalizedRootTurns.clamp(0, maxRetainedEntries).toInt();
```
用"条目数"去 clamp"轮数"；同时 `toolCalls` / `envelopeEntries` 完全不 clamp，三个参数处理方式不一致。另外 `rootTurns == 0` 会让 `_startOfLatestRootTurns`（L474）返回 `values.length` → **整个窗口为空**，而负数反而回落到默认 5，语义反直觉。

### E7 · P3 · `diff_parser.dart:548` / `663` — `trimRight()` 破坏 patch 内容

```dart
return DiffSelection(diffText: buffer.toString().trimRight());   // 548
return buffer.toString().trimRight();                            // 663
```
不仅删掉 patch 必需的结尾换行，还会把**最后一行有意义的尾随空白**一并删掉（如 Markdown 的两空格换行、被 diff 的空白修复）。**修复**：只去掉末尾多余的 `\n`，保留一个。

### E8 · P3 · `diff_parser.dart:164` — hunk header 正则不支持 combined diff / 不校验行数

```dart
final _hunkHeaderRegex = RegExp(r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@');
```
- `diff --cc` / `-c` 的合并 diff 行是 `@@@ -1,2 -1,2 +1,3 @@@`，且正文前缀为**两个**字符。L237 的 `startsWith('@@')` 会命中，正则失配 → `oldStart/newStart` 静默回落为 1（L313-314 的 `: 1`），随后每行前缀解析全错。
- `,count` 被 `(?:,\d+)?` 丢弃，从不校验 → `_parseHunk`（L321-379）只在遇到 `@@` 或 `diff --git ` 时停，无行数上界。headerless 的多文件 diff 里，下一个文件的 `--- a/f2` / `+++ b/f2` 会被解析成一条删除行和一条新增行。
- **修复**：捕获 count 并作为循环上界；对 `@@@` 显式标记为不支持而非静默降级。

### E9 · P3 · `diff_parser.dart:205-209` — `GIT binary patch` 未识别为二进制

只匹配 `Binary files ...`（L205）。`git diff --binary` 产出的是 `GIT binary patch` + base85 块 → `isBinary` 保持 false，整段 base85 被逐行渲染成上下文行。

### E10 · P3 · `tool_categories.dart:350` / `358` / `367` — 截断可劈开代理对

```dart
return cmd.length > 60 ? '${cmd.substring(0, 57)}...' : cmd;   // 350
final truncated = s.length > 50 ? '${s.substring(0, 47)}...' : s;  // 358
return s.length > 50 ? '${s.substring(0, 47)}...' : s;         // 367
```
长度守卫保证不会 RangeError，但按 UTF-16 code unit 截断会把 emoji / 部分 CJK 扩展区字符劈成半个代理对 → 渲染成豆腐块。**修复**：用 `characters` 包按字素簇截断。**正面**：`changes[0]`（L335）有 `isNotEmpty` 守卫，`substring(0,24)`（history L423）对恒长 64 的 sha256 hex 安全，`composer_tokens.dart:336-348` 的 composing 区间数学经推导恒满足 `composingStart <= composingEnd`，无 RangeError。

### E11 · P2 · `composer_tokens.dart:390-396` — token 边界不剥尾随标点

`_findTokenEnd` 只在空白处停。`/help,` `@lib/main.dart。` `@file.dart)` 的 `rawText` 会带上标点 → `_isTokenValid`（L378-387）集合查找必然失败 → **合法的斜杠命令 / 文件提及不高亮**。与 `_isTokenBoundary`（L401）已经把 `([{:,;` 当作起始边界的做法自相矛盾（起始认标点，结束不认）。

---

# F. 枚举 / `fromString` 型回退

### F1 · P2 · `tool_categories.dart:166` + `218` — SubAgent 的归一化名在 default 分支被丢弃，与文档承诺相反

```dart
/// ... Unknown tools retain their original name so newer Bridge versions
/// remain forward compatible.                                    // 157-159 注释
final normalized = name == 'SubAgent' ? input['tool']?.toString() : name;   // 166
return switch (normalized) {
  ...
  _ => name,                                                      // 218
};
```
`SubAgent` 携带未知内层工具（如 `input.tool == 'runTerminalCommand'`）时，default 返回的是 **`name`（即字面量 "SubAgent"）**，而不是 `normalized`。结果：Bridge 新增的子 Agent 工具在 UI 上全部退化成同一个 "SubAgent"，无法区分 —— 恰好破坏注释宣称的前向兼容。`_completedToolDisplayName`（L222-278）的 `_ => name`（L276）反而正确，因为入参已是 `(normalized ?? name)`。**修复**：L218 改为 `_ => normalized ?? name`。

### F2 · P2 · `tool_categories.dart:30-67` vs `160-220` — 分类表与显示名表的别名集合不一致

`getToolDisplayName` 认 camelCase / snake_case 变体（L188-206：`spawnAgent`/`spawn_agent`/`SpawnAgent`、`sendInput`/`send_input`、`wait`…），但 `categorizeToolName` **只认 PascalCase**（L48-63）。
- **触发**：Codex 侧发来 `spawn_agent` → 标题显示"开启子 Agent"，但 `categorizeToolName` 落到 `_ => ToolCategory.other`（L65）→ 图标是通用扳手 `Icons.build_outlined`，且 `getToolCollapsedSummary`（L98-107）走 `other` 分支返回 `''`，丢掉本该显示的 `agent_name`。
- 同理 `'wait'`（小写）在 L197 被当作"等待子 Agent"，但分类是 `other` 而非 `wait` → `_waitSummary`（L381-388）永不被调用。
- **修复**：抽取单一 `_canonicalToolName(name, input)` 供两张表共用。

### F3 · P3 · `tool_categories.dart:65` / `30-31` — 未知与 MCP 工具静默归入 `other`

```dart
if (name.startsWith('mcp__')) return ToolCategory.other;   // 30-31
...
_ => ToolCategory.other,                                   // 65
```
这是**期望**的 additive 行为（不抛异常），但代价是 Bridge 未来新增的 read/write 类工具永远拿不到正确图标、也拿不到 `_fileSummary`。**建议**：保留 `other` 兜底的同时，增加基于 input 键的启发式（存在 `file_path` → read/write；存在 `command` → bash），使未知工具也能降级出有用摘要。

### F4 · P3 · `composer_tokens.dart:43-49` + `364-368` — provider 判定硬编码

```dart
r'$' => provider == Provider.codex,                        // 46
r'$' => config.provider == Provider.codex ? resolveDollarTokenCategory(...) : null,   // 365-368
```
`$` 触发符与 `Provider.codex` 硬绑定。新增第三个 provider（协议是 additive）时 `$` token 直接失效且无任何提示。`_resolveCategory` 的 `_ => null`（L368）与 `resolveDollarTokenCategory` 的 `return null`（L412）都是静默丢弃 —— 对高亮而言可接受，但应由 config 声明触发符集合而非硬编码 enum 比较。

---

# G. 其他 / 死代码 / 一致性

| # | 位置 | 级别 | 问题 |
|---|---|---|---|
| G1 | `tool_categories.dart:126-138` | P3 | `getToolCategoryColor` 的 **9 个分支全部返回 `appColors.toolIcon`** —— 完整的死 switch，函数等价于常量。要么按类别真正着色，要么删除。 |
| G2 | `diff_parser.dart:532` | P3 | `if (file.isBinary) continue;` 不可达：二进制文件 `hunks` 恒为 `const []`（L224），L529 的 `if (selectedHunks.isEmpty) continue;` 已经先行返回。 |
| G3 | `diff_parser.dart:609` | P3 | `_synthesizeWrite` 用 `oldStart: 0`，而 `_buildHunkFromStrings`(L641) 与 `_parseRawDiffLines`(L431) 用 `oldStart: 1`。同一字段三处语义不统一。 |
| G4 | `diff_parser.dart:357-360` | P3 | `\ No newline at end of file` 被解析时丢弃，`_writeFileHeader`/`reconstructDiff` 也从不写回 → 往返后给文件尾部凭空加换行。 |
| G5 | `diff_parser.dart:81-161` | P3 | `DiffLine` / `DiffHunk` / `DiffFile` / `DiffImageData` 全部 **无 `==` / `hashCode`**（`DiffImageData` 还有 `copyWith`）。Cubit state 比较、`didUpdateWidget` 差异检测只能靠引用相等 → 无谓重建或漏更新。 |
| G6 | `composer_tokens.dart:9-23` | P3 | `ComposerToken` 标了 `@immutable` 却**无 `==` / `hashCode`**（同文件的 `ComposerTokenConfig` L52-75、`ComposerTokenPalette` L157-180 都实现了）。 |
| G7 | `composer_tokens.dart:378-386` | P3 | 集合存储约定不一致：`fileMentions` 存**不带 `@`** 的裸名（L381-383 用 `rawText.substring(1)` 查），而 `slashCommands`/`skillTokens`/`appTokens`/`pluginTokens` 存**带前缀**的全串。极易在调用方填错。 |
| G8 | `composer_tokens.dart:231-240` | P3 | `updateTokenState` 变更后不调用 `notifyListeners()`。当前靠调用点 `chat_input_with_overlays.dart:207` 在 build 中同步调用、TextField 随父级一起重建而侥幸生效；若调用点移出 build（如放进 `initState` 或异步回调），高亮将永久停在旧配置。 |
| G9 | `composer_tokens.dart:261-263` | P3 | 无 token 时 `return TextSpan(style: baseStyle, text: text)` 直接丢弃 composing 下划线（IME 组字态），与有 token 时（L273-309 保留下划线）行为不一致 —— 中日文输入时下划线会随打字闪烁出现/消失。 |
| G10 | `history_window_policy.dart:117-131` vs `159-173` | P3 | 两处 `ChatEntry → ServerMessage` 映射逻辑逐字重复（含 `'streaming-window-$index'`）。任一处改动必然漏改另一处。 |
| G11 | `history_window_policy.dart:23-38`、`93-108`、`152-181` | P3 | `selectTurnAwareServerMessageWindowIndexes` / `selectTurnAwareChatEntryWindowIndexes` 在 `lib/` 下**无任何生产调用方**（仅 `test/history_window_policy_test.dart` 使用）。 |
| G12 | `history_window_policy.dart:340` | P3 | `gapHost = _GapHost(projected.length - 1);` 依赖"上一步刚 add 过"的隐式不变量（由 `shouldRetainEnvelope` 保证）。一旦该分支条件被改动即为 `-1` 越界，L385 `projected[host.outputIndex]` 抛 RangeError。应显式复用 L313 的 `outputIndex` 变量。 |
| G13 | `history_window_policy.dart:7-11` | P3 | `755 = ?`，与 `5 + 200 + 300` 无显式推导关系（实际上限约为 5 + 200×2 + 300 + gap hosts）。魔数缺注释，调参时无从判断安全边界。 |
| G14 | `tool_categories.dart:307-315` | P3 | `_otherFullInput` 无条件把 input 全部 key/value `toString()` 拼接，与 L89-93 注释宣称的"刻意省略大对象"策略冲突 —— 展开一个含 base64 图片的 input 会一次性构造数十 MB 字符串。 |

---

## 优先修复建议（按投入产出）

1. **E2**（`diff --git` contains/startsWith 不对称 → diff 整体空白）与 **A1/A2**（build 期 TypeError 红屏）——两者都是用户可直接感知的功能性故障，改动各在 3 行内。
2. **E1**（composer O(n²) + 每字符编译正则）——把两个 `RegExp` 提为 `static final`、L208 的 `index++` 改 `index = end`，即可消除主线程冻结。
3. **A5**（空 id 的 tool_use 无声消失）与 **F1/F2**（SubAgent 归一化名丢失、分类/显示名别名不一致）——直接影响 additive 协议下的前向兼容承诺。
4. **D1/D3/D6**（路径提取与 basename 归一）——建议抽公共 `gitPathCodec` + `basename` 工具，消除四处不一致实现。
