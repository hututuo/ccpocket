I'll start by exploring the repository structure and reading the relevant files.
审查完成。以下是全部发现（只看功能正确性，不含安全面），按严重度排序。

---

## P0

**[1] [P0] `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/packages/bridge/src/git-operations.ts:204, 222, 723`（配合 `packages/bridge/src/websocket.ts:11686` 与 `apps/mobile/lib/features/git/widgets/diff_content_list.dart:176`）— hunk 索引在客户端(U3)与服务端(U0)之间不一致，会 stage/revert 错误的代码块（可造成改动丢失）**

- 问题：客户端展示的 diff 来自 `git diff --no-color`（默认 3 行上下文），`hunkIdx` 就是这个 U3 解析结果里的下标；而 Bridge 收到 `hunkIndex` 后重新执行 `git diff --unified=0` 并取第 idx 个 hunk。
- 证据：
  - 客户端：`websocket.ts:11686` `gitArgs("diff", "--no-color")` → `diff_parser.dart:237` 按 `@@` 切分 → `diff_content_list.dart:172-176` `for (var hunkIdx = 0; hunkIdx < file.hunks.length; hunkIdx++)` → `git_view_cubit.dart:381-425` `{'file': ..., 'hunkIndex': hunkIdx}`。
  - 服务端：`git-operations.ts:202-208` `stageHunks` → `diffArgs: ["diff", "--unified=0"]`；`unstageHunks:222`、`revertHunks:723` 同理；`buildHunkPatch:107-111` 直接按 `@@` 出现顺序取第 idx 段。
- 触发场景：同一文件里两处改动相距 ≤ 6 行时，U3 合并成 1 个 hunk，U0 拆成 2 个。UI 显示 2 个 hunk，用户对第 2 个（UI idx=1）执行 Revert → 服务端 U0 的 idx=1 实际是第一个 UI hunk 的后半段 → **回滚了用户没选的代码**。若改动更靠后还会直接 `out of range` 报错。
- 现有测试没覆盖：`packages/bridge/src/git-operations.test.ts:268-292` 特意选了第 2 行和第 17 行（相距 15 行），U3/U0 都是 2 个 hunk，所以掩盖了这个 bug。
- 建议：协议里不要传 `hunkIndex`，改传客户端重建的 patch 文本（已有 `reconstructDiff`），或让 Bridge 用与客户端完全相同的 diff 参数（`git diff` 默认上下文 + `git apply --cached`，去掉 `--unidiff-zero`），或在 `hunkIndex` 之外加上 `hunkHeader`（`@@ -a,b +c,d @@`）做校验，不匹配就报错拒绝。

**[2] [P0] `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/apps/mobile/lib/features/git/state/git_view_cubit.dart:95-113, 57-73` — 所有 git 结果流是全局广播且不带 projectPath，多个缓存 Cubit 会互相串台**

- 问题：`GitViewCacheService` 每个 session 常驻一个 `GitViewCubit`（`git_view_cache_service.dart:38-53`，只在 session 停止时移除），每个 Cubit 都 `listen` 全局的 `_bridge.diffResults / gitStageResults / gitCheckoutBranchResults / ...`。而 `DiffResultMessage`（`apps/mobile/lib/models/messages.dart:3474-3485`）与服务端应答（`websocket.ts:8197` `{ type: "diff_result", diff, imageChanges }`）**都不带 projectPath / sessionId / requestId**。
- 触发场景：先后打开 session A、session B 的 Git 面板 → 两个 Cubit 共存。A 刷新时返回的 `diff_result` 会同时被 B 的 `_diffSub` 消费，B 的 `state.files` 变成 A 仓库的文件列表；此后在 B 界面上滑动 stage/revert，会把 A 的文件路径发到 B 的 projectPath（`stageFile` 用的是 `state.files[fileIdx].filePath`）。stage/unstage/revert 结果同样互相触发 `refreshDiffOnly`。
- 建议：所有 `git_*_result` / `diff_result` 回带 `projectPath`（或客户端生成的 `requestId`），Cubit 侧过滤；短期缓解可在 `GitViewCacheService` 里只保留一个活跃 Cubit。

---

## P1

**[3] [P1] `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/packages/bridge/src/websocket.ts:8170-8173`（及 8307、8326、8344、8420、8485、8503、8521、8539、8557）— 路径不允许时只回 `type:"error"`，客户端 loading/staging 永久卡死**

- 证据：`buildPathNotAllowedError`（`websocket.ts:1605-1613`）返回 `{ type: "error", errorCode: "path_not_allowed" }`，**不是** `diff_result` / `git_stage_result`。客户端 `git_view_cubit.dart:136` `emit(state.copyWith(loading: true))` 后只等 `diffResults`，没有超时也没有 error 通道兜底。
- 后果：Git 页面永久转圈；而且 `git_screen.dart:327` `if (cubit.canRefresh && !state.loading)` 会把刷新按钮隐藏 → 用户无法自救。stage 失败同理会让 `staging=true` 永久为真，底部 `_isBusy`（`git_screen.dart:1039`）永久禁用所有按钮。
- 建议：这些分支改为返回对应的 `*_result{success:false,error}`；客户端所有 in-flight 请求加超时兜底（例如 30s 后 `loading=false` 并给出错误）。

**[4] [P1] `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/apps/mobile/lib/features/git/widgets/branch_selector_sheet.dart:191-196` — checkout 失败被完全吞掉，用户看不到任何提示**

- 证据：
  ```dart
  onTap: isDisabled ? null : () { cubit.checkout(branch); Navigator.of(context).pop(); }
  ```
  弹窗立刻 pop → `BranchCubit` 随 `BlocProvider` 被 close（`branch_cubit.dart:98-104`），`_onCheckoutResult` 里的 `emit(state.copyWith(error: result.error))` 落到已销毁的 cubit，UI 没有任何 sheet 再显示它。而 `GitViewCubit._onCheckoutResult`（`git_view_cubit.dart:610-623`）**只处理 success，失败分支为空**。
- 触发场景：工作区有未提交改动导致 `git checkout` 失败 → 分支没切换、界面还是旧分支、无任何错误提示，用户以为切成功了。
- 建议：checkout 结果由常驻的 `GitViewCubit` 统一处理，失败时 emit 错误并弹 SnackBar；或在 sheet 内先等结果再 pop。

**[5] [P1] `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/apps/mobile/lib/features/git/state/git_view_cubit.dart:86, 107` — 全量 diff 在 UI 线程同步解析，无 isolate / 无截断 / 无分页**

- 证据：`GitViewState(files: parseDiff(initialDiff))` 与 `parseDiff(result.diff)` 直接在 Cubit 里同步调用；全仓库 grep 无 `compute(` / `Isolate.run`（已确认）。服务端 `websocket.ts:11627` `maxBuffer: 10 * 1024 * 1024`，即最大可下发 10MB diff 文本。
- 后果：10MB diff → `split('\n')` 出百万级字符串 + 逐行构造 `DiffLine` 对象，主线程阻塞数秒，动画卡死；超过 10MB 则直接 `ENOBUFS`，用户只看到 "Failed to get diff: ... maxBuffer length exceeded"，没有任何"diff 过大已截断"的降级路径。
- 建议：`parseDiff` 移到 `compute`/isolate；服务端对 diff 做行数/字节截断并回传 `truncated` 标记；客户端按文件懒解析（先只解析文件头，展开时再解析 hunk）。

**[6] [P1] `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/apps/mobile/lib/features/git/widgets/diff_hunk_widget.dart:118-131 与 254-329` — 每行一次 TextPainter.layout + hunk 内所有行一次性建成 Widget，且每次刷新全量重算**

- 证据：
  ```dart
  void _calcMaxContentWidth() {
    for (final line in widget.hunk.lines) { painter.text = ...; painter.layout(); ... }
  }
  ```
  在 `initState` 同步执行；`_DiffHunkBody.build` 用 `Column(children: [for (final line in lines) ...])`（254-280、283-329），hunk 内**没有任何虚拟化**。外层 `diff_content_list.dart:88-99` 虽是 `ListView.builder`，但一个 item = 一整个文件（含全部 hunk 全部行），单个 item 构建成本可能上万个 Widget。
- 叠加问题：`diff_hunk_widget.dart:111` `if (oldWidget.hunk != widget.hunk)` —— `DiffHunk` 没有重写 `==`（`diff_parser.dart:95-118`），每次 `parseDiff` 产生新对象 → 每次 stage/unstage 后的刷新都会对所有可见 hunk 触发一次全量 TextPainter 重算。
- 建议：`_calcMaxContentWidth` 只对前 N 行采样或按字符数估算；hunk body 改用 `SliverList`/按行 builder；给 `DiffHunk`/`DiffLine` 加值相等语义（或用 hunk header+行数做廉价比较）。

**[7] [P1] `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/apps/mobile/lib/features/git/widgets/diff_image_widget.dart:384` + `apps/mobile/lib/services/bridge_service.dart:351, 5052-5058` — 图片全分辨率解码 + 无上限内存缓存，大图 OOM**

- 证据：
  ```dart
  return Image.memory(bytes, fit: BoxFit.contain, ...);   // 无 cacheWidth/cacheHeight
  ```
  容器只有 `maxHeight: 200`（`diff_image_widget.dart:328`），但仍按原始分辨率解码。服务端允许最大 5MB（`websocket.ts:11784-11787` `MAX_IMAGE_SIZE` 默认 5MB），一张 5MB 的 PNG 可能是 8000×8000 → 解码后 ≈256MB ARGB，old/new 各一份。
  缓存侧：`final _diffImageCache = <String, DiffImageCacheEntry>{};` 无容量/字节上限、无 LRU，只有 session 停止或断线才 `clearDiffImageCache()`（`bridge_service.dart:1837, 2038, 3720, 5145`）。浏览含几十张图的 diff 会持续累积原始字节。
- 建议：缩略图路径加 `cacheWidth`（按 devicePixelRatio 计算）；`_diffImageCache` 改为带字节上限的 LRU；服务端可为缩略图返回降采样版本。

---

## P2

**[8] [P2] `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/packages/bridge/src/websocket.ts:11669-11696` — `git add --intent-to-add` 与 `git reset` 之间夹着异步 `git diff`，并发操作会误撤销用户的暂存**

- 证据：unstaged 模式下先同步 `git add --intent-to-add -- <untracked...>`（11672-11678），然后 **异步** `execFile("git", ["diff"...])`，在回调里才 `execFileSync("git", ["reset", "--", ...untrackedFiles])`（11692）。
- 触发场景：diff 请求在途时用户点 "Stage All"（`git_view_cubit.dart:431-442` → `stageFiles` = 同步 `git add`）→ diff 回调到来后执行 `git reset -- <那些原本未跟踪的文件>` → **把用户刚 stage 的新文件又撤了**，UI 切到 staged 视图却看不到它们。
- 另外：整个 Bridge 没有任何 git 串行化（无 mutex/queue），`git-operations.ts` 全部用 `execFileSync`（靠阻塞事件循环"意外"串行），唯独 diff 路径是异步的，形成上述空窗。
- 建议：给同一 repo 的 git 操作加串行队列；或改用 `git diff --no-index` 之外的方案（如对未跟踪文件单独生成 diff），避免修改 index。

**[9] [P2] `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/apps/mobile/lib/features/git/state/git_view_cubit.dart:240-242` + `widgets/diff_image_widget.dart:45-56` — 图片自动加载被限流拒绝后永久转圈**

- 证据：
  ```dart
  if (state.loadingImageIndices.contains(fileIdx)) return;
  if (state.loadingImageIndices.length >= _maxConcurrentLoads) return;   // 静默丢弃
  ```
  `_triggerAutoLoad` 只在 build 时触发一次（`_autoLoadScheduled` 在 post-frame 复位），被限流丢弃后 state 没变化 → widget 不会重建 → 永远停在 `_AutoLoadPlaceholder` 的 spinner。
- 相关：若 `diff_image_result` 永不到达（如路径被拒返回 `type:"error"`，见发现 3），`loadingImageIndices` 里的下标永不移除，3 个槽位被占满后**所有**图片都加载不出来。
- 建议：限流改为排队（pending 队列 + 完成后出队），并给单次图片请求加超时清理。

**[10] [P2] `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/apps/mobile/lib/features/git/state/git_view_cubit.dart:344-353` — 快速切换 staged/unstaged 时响应乱序，视图与 viewMode 不一致**

- 证据：`switchMode` 立刻 `emit(viewMode: mode, loading: true, files: [])` 并发 `get_diff`；`diff_result` 无 mode 标记（同发现 2），先到先赋值、后到覆盖。
- 触发场景：快速点两次分段控件 → 最终 `viewMode = unstaged` 但 `files` 是 staged 的内容；此时滑动做的是 stage 操作，实际针对已暂存文件。
- 建议：请求携带并回带 `staged` 标记（或 requestId），响应与当前 mode 不符时丢弃。

**[11] [P2] `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/apps/mobile/lib/utils/diff_parser.dart:164, 237, 325` — 不支持 combined diff（`@@@`），merge/rebase 冲突期间行号与内容全错**

- 证据：`_hunkHeaderRegex = RegExp(r'^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@')`；`lines[i].startsWith('@@')` 会把 `@@@ -1,5 -1,5 +1,7 @@@` 也当成 hunk 头，正则不匹配 → `oldStart = 1, newStart = 1`（313-314 的 fallback），行号从 1 开始全错；combined diff 的两字符前缀（`++`、`+ `、` -`）也会被按单字符前缀解析。
- 建议：识别 `@@@` 前缀并给出"合并冲突 diff 暂不支持"的明确提示，或实现 combined diff 解析。

**[12] [P2] `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/apps/mobile/lib/utils/diff_parser.dart:361-364` — 空行被无条件跳过，导致其后所有行号偏移**

- 证据：
  ```dart
  } else if (line.isEmpty) {
    // Empty line — likely trailing newline, skip
    i++; continue;
  }
  ```
  这里的意图是吃掉 `split('\n')` 末尾的空元素，但对 hunk **内部**的空行也生效。凡是上下文空行被去掉行尾空格的 diff（tool_result 里的 diff、经过邮件/编辑器处理的 patch），这一行既不计入 `diffLines` 也不递增 `oldLine/newLine` → 该 hunk 后续所有行号都少 1，且屏幕上少了一行上下文。
- 建议：只在"已到达最后一个元素且是空字符串"时跳过，其余空行按空上下文行处理（递增两个计数器）。

**[13] [P2] `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/apps/mobile/lib/features/git/git_screen.dart:819-821` + `state/git_view_cubit.dart:483, 492, 501, 517, 526, 573, 590` — 任何操作失败都会用全屏错误页顶掉整个 diff 列表**

- 证据：`_GitScreenContent.build` 里 `if (state.error != null) return DiffErrorState(...)`；而 stage/unstage/revert/pull/push 失败都是 `emit(state.copyWith(staging: false, error: result.error))`，复用同一个 `error` 字段。
- 后果：一次 stage 失败（比如文件被外部删除），整页 diff 消失，只剩错误文本；错误没有自动清除路径，只能手动点刷新。
- 建议：区分"加载错误"（全屏）与"操作错误"（SnackBar/内联提示），操作错误不清空 `files`。

**[14] [P2] `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/packages/bridge/src/git-operations.ts:739-746, 881-895` — 同步 `execFileSync` 阻塞整个 Bridge 事件循环**

- 证据：`gitFetch` 用 `execFileSync(..., { timeout: 30000 })` —— 最长把 Node 主线程钉死 30 秒；`gitPull` 的 `execFileSync("git", ["pull"])` **没有 timeout**，凭证交互/网络挂起时可无限阻塞。期间所有 WebSocket 会话（包括正在跑的 Claude/Codex 会话）全部停摆。
- 注意：`gitStatus` 在 `includeRemote` 时会内部再调 `gitFetch`（`git-operations.ts:828`），而 `GitStatusCubit.refresh` 会被会话列表频繁触发。
- 建议：git 操作全部改异步（`execFile` + promisify）并加超时；同 repo 加串行队列。

**[15] [P2] `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/packages/bridge/src/websocket.ts:11873-11904, 8194` — 仅为取尺寸就把整张图读进内存，且 `readFile` 无大小上限；`collectImageChanges` 没有 `.catch`**

- 证据：
  ```ts
  oldBuf = result.stdout;               // git show HEAD:<path>，整个 blob
  newBuf = await readFile(absPath);     // 无 size 检查
  const oldSize = oldBuf?.length; ...   // 只用到 length
  ```
  仅为算 `oldSize/newSize` 就把每张图完整读入。一个 200MB 的 `.bmp` 会直接读满内存（`MAX_IMAGE_SIZE` 检查在读之后才做，见 11904-11909）。
  另外 `websocket.ts:8194` `void this.collectImageChanges(...).then(...)` 没有 `.catch` —— 一旦 reject，客户端永远收不到 `diff_result`（配合发现 3 变成永久 loading），Node 侧还是 unhandled rejection。
- 建议：改用 `git cat-file -s HEAD:<path>` 和 `fs.stat` 取尺寸；`readFile` 前先 stat 并对超限文件跳过；补上 `.catch` 并在失败时仍下发 `diff_result`。

---

## P3

**[16] [P3] `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/apps/mobile/lib/utils/diff_parser.dart:199-254` — 重命名 / 模式变更没有识别，渲染成"空文件"**

- 证据：元数据循环只识别 `Binary files` / `new file mode` / `deleted file mode`，没有 `rename from|to`、`similarity index`、`old mode|new mode`、`copy from|to`。纯重命名或纯 chmod 的文件会得到 `hunks: []` 的 `DiffFile` → `diff_content_list.dart:143` 渲染出一个只有文件头、`+0 -0`、下面完全空白的区块，用户不知道发生了什么。重命名时 `_extractFilePath` 只取新路径（681-693），旧路径信息丢失。
- 建议：给 `DiffFile` 增加 `isRenamed/oldPath/isModeChange`，UI 显示 "old → new" 或 "mode changed"。

**[17] [P3] `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/apps/mobile/lib/utils/diff_parser.dart:177` 与 `packages/bridge/src/websocket.ts:11684-11687` — CRLF 与非 UTF-8 编码处理**

- CRLF：`diffText.split('\n')` 后每行残留 `\r`，进入 `DiffLine.content` → 宽度计算多算一个字符，`reconstructUnifiedDiff` 回写时 `writeln` 用 `\n`，产出的 patch 与原文件行尾不一致。
- 非 UTF-8：`execFile` 默认以 utf8 解码（`collectGitDiff` 未指定 encoding，`getStagedDiff` 显式 `encoding: "utf-8"`），Shift_JIS/GBK 文件的 diff 内容会变成 U+FFFD，不可逆；把这样的内容通过 "Request Change" 回传给 AI 会传递乱码。
- 路径侧是好的：`withGitPathConfig` 统一加 `-c core.quotePath=false`（`git-operations.ts:87-89`），客户端 `_decodeGitPathToken`（738-796）也实现了八进制反转义兜底，CJK 路径已有测试覆盖（`apps/mobile/test/diff_parser_test.dart:177-240`）。
- 建议：至少在渲染前 strip 行尾 `\r`；二进制/非 UTF-8 检测失败时标记为不可显示而不是显示乱码。

**[18] [P3] `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/apps/mobile/lib/features/git/state/git_view_cache_service.dart:28-53` — 缓存只按 sessionId 索引，projectPath/worktreePath 变了也返回旧 Cubit**

- 证据：`getOrCreate` 第一件事就是 `final existing = _cubitsBySession[sessionId]; if (existing != null) return ...(created: false)` —— 完全忽略传入的 `projectPath` / `worktreePath`。而调用方 `git_screen.dart:175` 的 key 是 `'$sessionId\n$projectPath\n${worktreePath ?? ''}'`，key 变了会重新 `getOrCreate`，却拿回持有**旧 projectPath** 的 Cubit（`GitViewCubit._projectPath` 是 final）。
- 触发场景：同一 session 后来切到 worktree（或 worktree 被移除回到主仓库），Git 面板仍然对旧路径发 `get_diff`/`git_stage`。
- 建议：缓存 key 用 `sessionId + projectPath + worktreePath`，或在 `getOrCreate` 检测到路径变化时 close 旧 Cubit 重建。

**[19] [P3] `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/apps/mobile/lib/utils/diff_parser.dart:357-360, 536-545, 652-662` — `\ No newline at end of file` 被丢弃，重建的 patch 会凭空加上换行**

- 证据：解析时 `else if (line.startsWith(r'\')) { i++; continue; }` 直接丢掉标记，`DiffHunk` 里没有任何字段记录；`reconstructDiff` / `reconstructUnifiedDiff` 对每行都 `buffer.writeln(...)`。
- 后果：对无末尾换行的文件做 "Request Change"，回传给 AI 的 diff 语义已经变了（末行多了换行）；如果将来把这个重建 patch 用于 `git apply` 会直接失败。
- 建议：在 `DiffLine` 上加 `noNewlineAtEof` 标记并在重建时写回 `\ No newline at end of file`。

**[20] [P3] `/Users/huyiyang/AI agent/Codex/_keep/projects/ccpocket-worktrees/mobile-comprehensive-remediation-20260725/packages/bridge/src/git-operations.ts:700-703` 与 `apps/mobile/lib/utils/diff_parser.dart:688-692` — 路径解析的边界不一致 / 换行符文件名**

- `revertFiles` 用 `git(["ls-files", "--", ...files])` 后 `trackedOutput.split("\n")`（701）：文件名含换行时会被拆成两条，判定为 untracked → 走 `git clean -fd` 删文件。应改用 `ls-files -z` + `\0` 切分。
- 客户端 `_extractFilePath` 用 `payload.lastIndexOf(' b/')`，Bridge 的图片扫描用 `/^diff --git a\/(.+?) b\/(.+)$/`（`websocket.ts:11835`，取**第一个** ` b/`）。对形如 `x b/y.png` 的文件名两侧解析结果不同 → `_mergeImageChanges` 里 `imageMap[file.filePath]` 匹配不上，图片 diff 静默退化为"Binary file"。建议两端统一为"从中点切分"（payload 长度对半 + 校验两侧相等）或统一走 `-z` 的 `--raw` 输出。

---

### 顺带确认没问题的点

- `StreamSubscription` 生命周期：`GitViewCubit.close()`（643 行前）、`BranchCubit.close()`、`CommitCubit.close()`、`GitStatusCubit.close()`、`GitViewCacheService.dispose()` 都取消了订阅；`_GitScreenState.dispose` 也正确 remove listener + dispose controller。`DiffImageViewer` 系列的 `AnimationController`/`TransformationController` 均已 dispose。
- `setState after dispose`：`diff_image_widget.dart:50-55` 的 post-frame 回调有 `if (mounted)` 保护；`git_screen.dart:123-126, 259-261` 同样有。
- 二进制识别、`git_file_list_sheet` 的树构建、`branch_selector_sheet` 的 `checkedOutBranches` 禁用逻辑，功能上没发现问题。
